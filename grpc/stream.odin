package grpc

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:time"

import "../hpack"
import "../http2"

// Stream is the HTTP/2 stream state shared by client and server calls.
// All fields after `cond` are guarded by conn.mu.
Stream :: struct {
	conn:          ^Conn,
	id:            u32,
	cond:          sync.Cond, // used with conn.mu: data, headers, reset, close
	send_window:   i64,
	recv_window:   i64, // what the peer may still send
	recv_unacked:  i64, // consumed octets not yet returned to the peer
	rq:            Byte_Queue, // received DATA payload not yet consumed
	remote_closed: bool, // peer sent END_STREAM (or the stream was reset)
	local_closed:  bool, // we sent END_STREAM
	reset:         bool,
	reset_code:    http2.Error_Code,
	reset_by_peer: bool,
	refused:       bool, // not processed by the peer: safe to retry
	conn_lost:     bool,
	registered:    bool, // present in conn.streams
	counted:       bool, // counted in conn.active_streams
}

// GRPC_MESSAGE_HEADER_SIZE: compressed flag (1) + big-endian length (4).
GRPC_MESSAGE_HEADER_SIZE :: 5

// -----------------------------------------------------------------------------
// Byte_Queue: received DATA awaiting consumption. Its size is bounded by the
// stream receive window, so it never grows beyond initial_window_size.
// -----------------------------------------------------------------------------

Byte_Queue :: struct {
	buf:  [dynamic]u8,
	head: int,
}

@(private)
bq_len :: #force_inline proc "contextless" (q: ^Byte_Queue) -> int {
	return len(q.buf) - q.head
}

@(private)
bq_push :: proc(q: ^Byte_Queue, data: []u8, allocator: runtime.Allocator) -> bool {
	if q.buf.allocator.procedure == nil {
		q.buf.allocator = allocator
	}
	if q.head > 0 && (q.head == len(q.buf) || len(q.buf) + len(data) > cap(q.buf)) {
		n := copy(q.buf[:], q.buf[q.head:])
		resize(&q.buf, n)
		q.head = 0
	}
	_, err := append(&q.buf, ..data)
	return err == nil
}

// bq_take copies up to len(dst) octets out of the queue.
@(private)
bq_take :: proc(q: ^Byte_Queue, dst: []u8) -> int {
	n := copy(dst, q.buf[q.head:])
	q.head += n
	if q.head == len(q.buf) {
		clear(&q.buf)
		q.head = 0
	}
	return n
}

@(private)
bq_destroy :: proc(q: ^Byte_Queue) {
	delete(q.buf)
	q^ = {}
}

// -----------------------------------------------------------------------------
// Registration and state
// -----------------------------------------------------------------------------

// stream_init_locked registers s under id (conn.mu held). The caller has
// already counted it in conn.active_streams; the stream takes over that
// count and a connection reference, both released by stream_unregister.
@(private)
stream_init_locked :: proc(c: ^Conn, s: ^Stream, id: u32) {
	s.conn = c
	s.id = id
	s.send_window = c.peer.initial_window_size
	s.recv_window = i64(c.opts.initial_window_size)
	c.streams[id] = s
	s.registered = true
	s.counted = true
	conn_retain(c)
}

// stream_unregister removes s from its connection (idempotent). Afterwards
// the reader no longer touches s and it may be freed.
@(private)
stream_unregister :: proc(s: ^Stream) {
	c := s.conn
	if c == nil {
		return
	}
	sync.mutex_lock(&c.mu)
	was_registered := s.registered
	if s.registered {
		delete_key(&c.streams, s.id)
		s.registered = false
	}
	if s.counted {
		c.active_streams -= 1
		s.counted = false
		sync.cond_broadcast(&c.cond)
	}
	if len(c.streams) == 0 {
		c.idle_since = time.tick_now()
	}
	drained := (c.goaway_received || c.goaway_sent) && len(c.streams) == 0
	sync.mutex_unlock(&c.mu)
	bq_destroy(&s.rq)
	if was_registered {
		if drained {
			conn_shutdown(c, "connection drained after GOAWAY")
		}
		conn_release(c)
	}
}

// stream_mark_reset_locked records a reset (sent or received) and wakes all
// waiters. conn.mu must be held.
@(private)
stream_mark_reset_locked :: proc(s: ^Stream, code: http2.Error_Code, by_peer: bool) {
	if !s.reset {
		s.reset = true
		s.reset_code = code
		s.reset_by_peer = by_peer
	}
	s.remote_closed = true
	sync.cond_broadcast(&s.cond)
	sync.cond_broadcast(&s.conn.cond)
}

// http2_code_status maps an RST_STREAM error code to a gRPC status
// (PROTOCOL-HTTP2.md, "Errors").
@(private)
http2_code_status :: proc "contextless" (code: http2.Error_Code) -> Status {
	#partial switch code {
	case .Refused_Stream:
		return {.Unavailable, "stream refused by peer"}
	case .Cancel:
		return {.Cancelled, "stream cancelled by peer"}
	case .Enhance_Your_Calm:
		return {.Resource_Exhausted, "peer sent ENHANCE_YOUR_CALM"}
	case .Inadequate_Security:
		return {.Permission_Denied, "peer reported inadequate security"}
	}
	return {.Internal, "stream reset by peer"}
}

// stream_failure returns the status for a stream that can no longer make
// progress, or ok = false if it can. conn.mu must be held.
@(private)
stream_failure_locked :: proc(s: ^Stream) -> (st: Status, failed: bool) {
	switch {
	case s.reset && s.reset_by_peer:
		return http2_code_status(s.reset_code), true
	case s.reset:
		return {.Cancelled, "stream was reset"}, true
	case s.conn_lost:
		return {.Unavailable, "connection closed"}, true
	}
	return {}, false
}

// wait_locked waits on cond (with conn.mu held) until signalled or the
// deadline passes. Returns false on timeout.
@(private)
wait_locked :: proc(cond: ^sync.Cond, mu: ^sync.Mutex, deadline: time.Time) -> bool {
	if deadline == {} {
		sync.cond_wait(cond, mu)
		return true
	}
	remaining := time.diff(time.now(), deadline)
	if remaining <= 0 {
		return false
	}
	sync.cond_wait_with_timeout(cond, mu, remaining)
	return true
}

@(private)
deadline_passed :: proc(deadline: time.Time) -> bool {
	return deadline != {} && time.diff(time.now(), deadline) <= 0
}

// -----------------------------------------------------------------------------
// Header block encoding (q_mu held)
// -----------------------------------------------------------------------------

Header_Out :: struct {
	name, value: string,
	indexing:    hpack.Indexing,
}

// encode_block_locked encodes fixed fields plus application metadata into
// c.hbuf. -bin metadata values are base64-coded on the fly.
@(private)
encode_block_locked :: proc(c: ^Conn, fixed: []Header_Out, md: []Metadata_Entry) -> bool {
	clear(&c.hbuf)
	if hpack.encoder_begin_block(&c.encoder, &c.hbuf) != .None {
		return false
	}
	for h in fixed {
		if hpack.encode_field(&c.encoder, &c.hbuf, h.name, h.value, h.indexing) != .None {
			return false
		}
	}
	scratch: [dynamic]u8
	scratch.allocator = c.allocator
	defer delete(scratch)
	for e in md {
		value := e.value
		if is_binary_key(e.key) {
			clear(&scratch)
			if !append_base64(&scratch, transmute([]u8)e.value) {
				return false
			}
			value = string(scratch[:])
		}
		// Credentials must never enter the dynamic table (RFC 7541 §7.1.3).
		indexing := hpack.Indexing.Never if e.key == "authorization" || e.key == "cookie" else .Incremental
		if hpack.encode_field(&c.encoder, &c.hbuf, e.key, value, indexing) != .None {
			return false
		}
	}
	return true
}

// header_list_size estimates the uncompressed size the peer limits with
// SETTINGS_MAX_HEADER_LIST_SIZE.
@(private)
header_list_size :: proc(fixed: []Header_Out, md: []Metadata_Entry) -> int {
	n := 0
	for h in fixed {
		n += hpack.entry_size(h.name, h.value)
	}
	for e in md {
		v := len(e.value)
		if is_binary_key(e.key) {
			v = base64_encoded_len(v)
		}
		n += len(e.key) + v + hpack.ENTRY_OVERHEAD
	}
	return n
}

// queue_headers_locked appends the encoded block as HEADERS(+CONTINUATION).
// q_mu held. Takes conn.mu briefly to read the peer's frame size.
@(private)
queue_headers_locked :: proc(c: ^Conn, id: u32, end_stream: bool) -> bool {
	sync.mutex_lock(&c.mu)
	mfs := c.peer.max_frame_size
	sync.mutex_unlock(&c.mu)
	return http2.append_headers(&c.q, id, c.hbuf[:], end_stream, mfs) == .None
}

// stream_send_headers sends a header block on an existing stream.
@(private)
stream_send_headers :: proc(s: ^Stream, fixed: []Header_Out, md: []Metadata_Entry, end_stream: bool, deadline: time.Time = {}) -> Status {
	c := s.conn
	sync.mutex_lock(&c.mu)
	limit := c.peer.max_header_list_size
	sync.mutex_unlock(&c.mu)
	if header_list_size(fixed, md) > int(limit) {
		return {.Internal, "header list exceeds the peer's SETTINGS_MAX_HEADER_LIST_SIZE"}
	}
	if r := queue_lock(c, deadline); r != .Locked {
		return queue_status(r)
	}
	ok := encode_block_locked(c, fixed, md) && queue_headers_locked(c, s.id, end_stream)
	if ok && end_stream {
		sync.mutex_lock(&c.mu)
		s.local_closed = true
		sync.mutex_unlock(&c.mu)
	}
	queue_unlock(c)
	if !ok {
		// The encoder may hold a partially encoded block: the connection's
		// compression state is no longer trustworthy.
		conn_shutdown(c, "out of memory encoding headers")
		return {.Internal, "failed to encode headers"}
	}
	return {}
}

// stream_send_reset sends RST_STREAM and fails the stream locally.
@(private)
stream_send_reset :: proc(s: ^Stream, code: http2.Error_Code) {
	c := s.conn
	sync.mutex_lock(&c.mu)
	already := s.reset
	stream_mark_reset_locked(s, code, false)
	sync.mutex_unlock(&c.mu)
	if already {
		return
	}
	if queue_lock_urgent(c) {
		http2.append_rst_stream(&c.q, s.id, code)
		queue_unlock(c)
	}
}

// -----------------------------------------------------------------------------
// DATA
// -----------------------------------------------------------------------------

// stream_send_data sends data as DATA frames, waiting for flow-control
// window as needed. With end_stream, the last frame carries END_STREAM
// (an empty data slice sends a lone END_STREAM frame).
@(private)
stream_send_data :: proc(s: ^Stream, data: []u8, end_stream: bool, deadline: time.Time) -> Status {
	c := s.conn
	data := data
	for {
		sync.mutex_lock(&c.mu)
		n := 0
		for len(data) > 0 {
			if st, failed := stream_failure_locked(s); failed {
				sync.mutex_unlock(&c.mu)
				return st
			}
			if s.local_closed {
				sync.mutex_unlock(&c.mu)
				return {.Internal, "send after the stream was closed"}
			}
			avail := min(s.send_window, c.send_window, i64(c.peer.max_frame_size))
			if avail > 0 {
				n = int(min(i64(len(data)), avail))
				s.send_window -= i64(n)
				c.send_window -= i64(n)
				break
			}
			if !wait_locked(&c.cond, &c.mu, deadline) {
				sync.mutex_unlock(&c.mu)
				return {.Deadline_Exceeded, "deadline exceeded waiting for flow-control window"}
			}
		}
		if len(data) == 0 {
			if st, failed := stream_failure_locked(s); failed {
				sync.mutex_unlock(&c.mu)
				return st
			}
		}
		sync.mutex_unlock(&c.mu)

		last := end_stream && n == len(data)
		if r := queue_lock(c, deadline); r != .Locked {
			// The window taken above is not returned: the stream is
			// abandoned (deadline) or the connection is gone.
			return queue_status(r)
		}
		http2.append_data(&c.q, s.id, data[:n], last)
		if last {
			sync.mutex_lock(&c.mu)
			s.local_closed = true
			sync.mutex_unlock(&c.mu)
		}
		queue_unlock(c)
		data = data[n:]
		if len(data) == 0 {
			return {}
		}
	}
}

// consume_locked accounts for n octets consumed by the application and
// returns the stream WINDOW_UPDATE increment to send, if one is due.
@(private)
consume_locked :: proc(s: ^Stream, n: int) -> u32 {
	s.recv_unacked += i64(n)
	threshold := i64(s.conn.opts.initial_window_size) / 4
	if s.recv_unacked < threshold || s.remote_closed {
		return 0
	}
	inc := u32(s.recv_unacked)
	s.recv_window += s.recv_unacked
	s.recv_unacked = 0
	return inc
}

@(private)
send_window_update :: proc(s: ^Stream, inc: u32) {
	if inc == 0 {
		return
	}
	c := s.conn
	if queue_lock_urgent(c) {
		http2.append_window_update(&c.q, s.id, inc)
		queue_unlock(c)
	}
}

Recv_Result :: enum u8 {
	Message, // a message was received
	End, // the peer finished sending (END_STREAM) cleanly
	Failed, // the stream failed (reset, connection lost); see the status
	Rejected, // a local error: limit exceeded, malformed message, deadline
}

// stream_recv_message reads one length-prefixed gRPC message. The message
// buffer is allocated from `allocator` (which only the calling thread may
// use).
@(private)
stream_recv_message :: proc(s: ^Stream, max_size: int, allocator: runtime.Allocator, deadline: time.Time) -> (msg: []u8, result: Recv_Result, st: Status) {
	c := s.conn
	sync.mutex_lock(&c.mu)

	prefix: [GRPC_MESSAGE_HEADER_SIZE]u8
	have := 0
	for have < GRPC_MESSAGE_HEADER_SIZE {
		if bq_len(&s.rq) > 0 {
			have += bq_take(&s.rq, prefix[have:])
			continue
		}
		if f, failed := stream_failure_locked(s); failed {
			sync.mutex_unlock(&c.mu)
			return nil, .Failed, f
		}
		if s.remote_closed {
			sync.mutex_unlock(&c.mu)
			if have == 0 {
				return nil, .End, {}
			}
			return nil, .Rejected, {.Internal, "stream ended inside a message header"}
		}
		if !wait_locked(&s.cond, &c.mu, deadline) {
			sync.mutex_unlock(&c.mu)
			return nil, .Rejected, {.Deadline_Exceeded, "deadline exceeded"}
		}
	}
	inc := consume_locked(s, GRPC_MESSAGE_HEADER_SIZE)
	sync.mutex_unlock(&c.mu)
	send_window_update(s, inc)

	switch prefix[0] {
	case 0:
	case 1:
		// We never advertise compression (grpc-accept-encoding: identity).
		return nil, .Rejected, {.Internal, "received a compressed message without a negotiated encoding"}
	case:
		return nil, .Rejected, {.Internal, "invalid message compression flag"}
	}
	length := int(u32(intrinsics.unaligned_load((^u32be)(&prefix[1]))))
	if length > max_size {
		return nil, .Rejected, {.Resource_Exhausted, "received message larger than the maximum allowed size"}
	}

	buf, alloc_err := make([]u8, length, allocator)
	if alloc_err != nil {
		return nil, .Rejected, {.Resource_Exhausted, "out of memory receiving a message"}
	}
	// The buffer is released on every failure path below.
	ok := false
	defer if !ok {
		delete(buf, allocator)
	}
	filled := 0
	sync.mutex_lock(&c.mu)
	for filled < length {
		if bq_len(&s.rq) > 0 {
			k := bq_take(&s.rq, buf[filled:])
			filled += k
			if inc = consume_locked(s, k); inc > 0 {
				sync.mutex_unlock(&c.mu)
				send_window_update(s, inc)
				sync.mutex_lock(&c.mu)
			}
			continue
		}
		if f, failed := stream_failure_locked(s); failed {
			sync.mutex_unlock(&c.mu)
			return nil, .Failed, f
		}
		if s.remote_closed {
			sync.mutex_unlock(&c.mu)
			return nil, .Rejected, {.Internal, "stream ended inside a message"}
		}
		if !wait_locked(&s.cond, &c.mu, deadline) {
			sync.mutex_unlock(&c.mu)
			return nil, .Rejected, {.Deadline_Exceeded, "deadline exceeded"}
		}
	}
	sync.mutex_unlock(&c.mu)
	ok = true
	return buf, .Message, {}
}

// frame_message writes the 5-octet gRPC message header in front of an
// encoded message of length n at buf[GRPC_MESSAGE_HEADER_SIZE:].
@(private)
frame_message :: proc "contextless" (buf: []u8, n: int) {
	buf[0] = 0
	intrinsics.unaligned_store((^u32be)(&buf[1]), u32be(u32(n)))
}
