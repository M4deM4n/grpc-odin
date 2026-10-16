package grpc

import "base:runtime"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import "../http2"
import pb "../protobuf"

// Method_Desc describes a method for clients; generated code provides one
// per method (<Service>_<Method>_METHOD).
Method_Desc :: struct {
	path:             string, // "/package.Service/Method"
	client_streaming: bool,
	server_streaming: bool,
	request:          ^pb.Message_Codec,
	response:         ^pb.Message_Codec,
}

Channel_Options :: struct {
	conn:          Conn_Options,
	// Sent as the user-agent header (gRPC appends its own token).
	user_agent:    string,
	// Value of :authority; defaults to the target.
	authority:     string,
	read_poll:     time.Duration,
	write_timeout: time.Duration,
	// Reconnection backoff after a failed connection attempt.
	min_backoff:   time.Duration,
	max_backoff:   time.Duration,
}

DEFAULT_MIN_BACKOFF :: 1 * time.Second
DEFAULT_MAX_BACKOFF :: 120 * time.Second
USER_AGENT :: "grpc-odin/0.1"

// Channel is a client connection to one target ("host:port"). It connects
// lazily and reconnects after failures; calls fail fast with UNAVAILABLE
// while no connection can be established. It is safe for concurrent use.
Channel :: struct {
	target:       string,
	authority:    string,
	user_agent:   string,
	opts:         Channel_Options,
	allocator:    runtime.Allocator,
	mu:           sync.Mutex,
	conn:         ^Conn,
	connecting:   bool, // a connection attempt is in progress (outside mu)
	conn_cond:    sync.Cond, // signalled when an attempt finishes
	live_conns:   int, // created and not yet freed
	freed_cond:   sync.Cond,
	closed:       bool,
	backoff:      time.Duration,
	next_attempt: time.Time,
}

Call_Options :: struct {
	// Relative timeout; zero means none. Ignored if deadline is set.
	timeout:   time.Duration,
	deadline:  time.Time,
	// Request metadata (copied into the request headers).
	metadata:  []Metadata_Entry,
	// Allocator for received messages; defaults to context.allocator.
	allocator: runtime.Allocator,
}

// Client_Stream is one RPC on the client.
Client_Stream :: struct {
	stream:            Stream,
	method:            ^Method_Desc,
	deadline:          time.Time,
	allocator:         runtime.Allocator,
	conn_allocator:    runtime.Allocator,
	// Written by the reader thread, read under conn.mu.
	headers_received:  bool,
	trailers_received: bool,
	header_md:         Metadata_Storage,
	trailer_md:        Metadata_Storage,
	status:            Status, // final status once trailers_received
	status_message:    []u8,
	send_buf:          [dynamic]u8, // reused encode buffer
	// Caller-side state.
	send_closed:       bool,
	finished:          bool,
	final:             Status,
	final_message:     string,
}

// -----------------------------------------------------------------------------
// Channel
// -----------------------------------------------------------------------------

channel_create :: proc(target: string, opts := Channel_Options{}, allocator := context.allocator) -> ^Channel {
	ch := new(Channel, allocator)
	if ch == nil {
		return nil
	}
	ch.allocator = allocator
	ch.opts = opts
	if ch.opts.read_poll <= 0 {ch.opts.read_poll = DEFAULT_READ_POLL}
	if ch.opts.write_timeout <= 0 {ch.opts.write_timeout = DEFAULT_WRITE_TIMEOUT}
	if ch.opts.min_backoff <= 0 {ch.opts.min_backoff = DEFAULT_MIN_BACKOFF}
	if ch.opts.max_backoff <= 0 {ch.opts.max_backoff = DEFAULT_MAX_BACKOFF}
	ch.target = strings.clone(target, allocator)
	ch.authority = strings.clone(opts.authority if opts.authority != "" else target, allocator)
	if opts.user_agent != "" {
		ch.user_agent = strings.concatenate({opts.user_agent, " ", USER_AGENT}, allocator)
	} else {
		ch.user_agent = strings.clone(USER_AGENT, allocator)
	}
	ch.backoff = ch.opts.min_backoff
	return ch
}

// channel_destroy closes the channel's connection and frees the channel.
// All Client_Streams created from it must have been destroyed first; it
// waits until its connections are fully closed.
channel_destroy :: proc(ch: ^Channel) {
	sync.mutex_lock(&ch.mu)
	ch.closed = true
	c := ch.conn
	ch.conn = nil
	sync.mutex_unlock(&ch.mu)
	if c != nil {
		send_goaway(c, .No_Error)
		conn_shutdown(c, "channel closed")
		conn_release(c)
	}
	sync.mutex_lock(&ch.mu)
	for ch.live_conns > 0 {
		sync.cond_wait(&ch.freed_cond, &ch.mu)
	}
	sync.mutex_unlock(&ch.mu)
	a := ch.allocator
	delete(ch.target, a)
	delete(ch.authority, a)
	delete(ch.user_agent, a)
	free(ch, a)
}

// channel_get_conn returns a usable connection with a reference the caller
// must release, connecting if needed.
@(private = "file")
channel_get_conn :: proc(ch: ^Channel, deadline: time.Time) -> (^Conn, Status) {
	// A replaced or failed connection is released after unlocking: freeing
	// it notifies the channel (channel_on_conn_freed), which takes ch.mu.
	stale: ^Conn
	defer if stale != nil {
		conn_release(stale)
	}
	sync.mutex_lock(&ch.mu)
	for {
		if ch.closed {
			sync.mutex_unlock(&ch.mu)
			return nil, {.Unavailable, "channel closed"}
		}
		if ch.conn != nil {
			if conn_is_usable(ch.conn) {
				conn_retain(ch.conn)
				c := ch.conn
				sync.mutex_unlock(&ch.mu)
				return c, {}
			}
			stale = ch.conn
			ch.conn = nil
		}
		if !ch.connecting {
			break
		}
		// Another caller is connecting: wait for its result.
		if !wait_locked(&ch.conn_cond, &ch.mu, deadline) {
			sync.mutex_unlock(&ch.mu)
			return nil, {.Deadline_Exceeded, "deadline exceeded waiting for a connection"}
		}
	}
	if ch.next_attempt != {} && time.diff(time.now(), ch.next_attempt) > 0 {
		sync.mutex_unlock(&ch.mu)
		return nil, {.Unavailable, "connection failed recently; waiting to reconnect"}
	}
	ch.connecting = true
	sync.mutex_unlock(&ch.mu)

	// Dial without holding the lock, so other callers can fail fast or
	// time out according to their own deadlines.
	c: ^Conn
	sock, net_err := net.dial_tcp(ch.target)
	st := Status{.Unavailable, "failed to connect"}
	if net_err == nil {
		transport, t_ok := tcp_transport(sock, ch.opts.read_poll, ch.opts.write_timeout)
		if t_ok {
			c_ok: bool
			c, c_ok = conn_create(.Client, transport, ch.opts.conn, ch, ch.allocator)
			if !c_ok {
				c = nil
				st = {.Resource_Exhausted, "out of memory creating a connection"}
			}
		} else {
			st = {.Unavailable, "failed to configure the connection"}
		}
		if c == nil {
			net.close(sock)
		}
	}

	sync.mutex_lock(&ch.mu)
	ch.connecting = false
	sync.cond_broadcast(&ch.conn_cond)
	if c == nil {
		ch.next_attempt = time.time_add(time.now(), ch.backoff)
		ch.backoff = min(ch.backoff * 2, ch.opts.max_backoff)
		sync.mutex_unlock(&ch.mu)
		return nil, st
	}
	ch.live_conns += 1
	if ch.closed || !conn_start(c) {
		net.close(sock)
		stale = c // released after unlocking (see above)
		sync.mutex_unlock(&ch.mu)
		return nil, {.Unavailable, "channel closed or connection threads failed to start"}
	}
	conn_retain(c) // the channel's reference
	ch.conn = c
	ch.backoff = ch.opts.min_backoff
	ch.next_attempt = {}
	conn_retain(c) // the caller's reference
	sync.mutex_unlock(&ch.mu)
	return c, {}
}

@(private)
channel_on_conn_freed :: proc(ch: ^Channel) {
	sync.mutex_lock(&ch.mu)
	ch.live_conns -= 1
	sync.cond_broadcast(&ch.freed_cond)
	sync.mutex_unlock(&ch.mu)
}

@(private)
client_on_conn_closed :: proc(c: ^Conn) {
	// Channels notice dead connections when they next use them.
	_ = c
}

// -----------------------------------------------------------------------------
// Opening streams
// -----------------------------------------------------------------------------

@(private = "file")
call_deadline_from :: proc(opts: Call_Options) -> time.Time {
	if opts.deadline != {} {
		return opts.deadline
	}
	if opts.timeout > 0 {
		return deadline_after(opts.timeout)
	}
	return {}
}

// client_new_stream starts an RPC: it opens a stream and sends the request
// headers. Finish it with client_finish (optional) and client_destroy.
client_new_stream :: proc(ch: ^Channel, method: ^Method_Desc, opts := Call_Options{}) -> (cs: ^Client_Stream, st: Status) {
	if st = check_outgoing_metadata(opts.metadata); st.code != .OK {
		return nil, st
	}
	deadline := call_deadline_from(opts)
	// A connection that sent GOAWAY between our check and opening the
	// stream is replaced once.
	for attempt in 0 ..< 2 {
		c: ^Conn
		c, st = channel_get_conn(ch, deadline)
		if st.code != .OK {
			return nil, st
		}
		cs, st = open_stream(ch, c, method, opts, deadline)
		conn_release(c)
		if cs != nil || st.code != .Unavailable || attempt == 1 {
			return cs, st
		}
	}
	return nil, st
}

@(private = "file")
open_stream :: proc(ch: ^Channel, c: ^Conn, method: ^Method_Desc, opts: Call_Options, deadline: time.Time) -> (^Client_Stream, Status) {
	cs, alloc_err := new(Client_Stream, ch.allocator)
	if alloc_err != nil {
		return nil, {.Resource_Exhausted, "out of memory"}
	}
	cs.method = method
	cs.deadline = deadline
	cs.allocator = opts.allocator if opts.allocator.procedure != nil else context.allocator
	cs.conn_allocator = c.allocator

	// Reserve a stream slot within the peer's concurrency limit.
	sync.mutex_lock(&c.mu)
	for c.active_streams >= c.peer.max_concurrent_streams && !c.closed && !c.goaway_received {
		if !wait_locked(&c.cond, &c.mu, deadline) {
			sync.mutex_unlock(&c.mu)
			free(cs, ch.allocator)
			return nil, {.Deadline_Exceeded, "deadline exceeded waiting for a stream slot"}
		}
	}
	if c.closed || c.goaway_received || c.goaway_sent {
		sync.mutex_unlock(&c.mu)
		free(cs, ch.allocator)
		return nil, {.Unavailable, "connection is closing"}
	}
	c.active_streams += 1
	sync.mutex_unlock(&c.mu)

	timeout_buf: [16]u8
	fixed_buf: [8]Header_Out
	fixed_buf[0] = {":method", "POST", .Incremental}
	fixed_buf[1] = {":scheme", "http", .Incremental}
	fixed_buf[2] = {":path", method.path, .Incremental}
	fixed_buf[3] = {":authority", ch.authority, .Incremental}
	fixed_buf[4] = {"content-type", "application/grpc", .Incremental}
	fixed_buf[5] = {"te", "trailers", .Incremental}
	fixed_buf[6] = {"user-agent", ch.user_agent, .Incremental}
	fixed := fixed_buf[:7]
	if deadline != {} {
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 {
			undo_slot(c)
			free(cs, ch.allocator)
			return nil, {.Deadline_Exceeded, "deadline exceeded before the call started"}
		}
		fixed_buf[7] = {"grpc-timeout", format_timeout(remaining, timeout_buf[:]), .Without}
		fixed = fixed_buf[:8]
	}

	sync.mutex_lock(&c.mu)
	limit := c.peer.max_header_list_size
	sync.mutex_unlock(&c.mu)
	if header_list_size(fixed, opts.metadata) > int(limit) {
		undo_slot(c)
		free(cs, ch.allocator)
		return nil, {.Internal, "request metadata exceeds the server's header list limit"}
	}

	// The stream id is allocated in the same critical section that queues
	// HEADERS, so ids appear on the wire in increasing order (§5.1.1).
	if r := queue_lock(c, deadline); r != .Locked {
		undo_slot(c)
		free(cs, ch.allocator)
		return nil, queue_status(r)
	}
	sync.mutex_lock(&c.mu)
	if c.closed || c.goaway_received || c.next_stream_id > http2.MAX_STREAM_ID {
		if c.next_stream_id > http2.MAX_STREAM_ID {
			c.goaway_sent = true // stream ids exhausted: retire the connection
		}
		sync.mutex_unlock(&c.mu)
		queue_unlock(c)
		undo_slot(c)
		free(cs, ch.allocator)
		return nil, {.Unavailable, "connection is closing"}
	}
	id := c.next_stream_id
	c.next_stream_id += 2
	stream_init_locked(c, &cs.stream, id)
	sync.mutex_unlock(&c.mu)
	ok := encode_block_locked(c, fixed, opts.metadata) && queue_headers_locked(c, id, false)
	queue_unlock(c)
	if !ok {
		conn_shutdown(c, "failed to encode request headers")
		client_destroy(cs)
		return nil, {.Internal, "failed to encode request headers"}
	}
	return cs, {}
}

@(private = "file")
undo_slot :: proc(c: ^Conn) {
	sync.mutex_lock(&c.mu)
	c.active_streams -= 1
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mu)
}

// -----------------------------------------------------------------------------
// Responses (reader thread)
// -----------------------------------------------------------------------------

@(private)
client_on_headers :: proc(c: ^Conn, id: u32, end_stream: bool) {
	sync.mutex_lock(&c.mu)
	s, known := c.streams[id]
	if !known {
		idle := id % 2 == 0 || id >= c.next_stream_id
		sync.mutex_unlock(&c.mu)
		if idle {
			conn_error(c, .Protocol_Error, "HEADERS on idle stream")
		}
		return
	}
	cs := container_of(s, Client_Stream, "stream")
	outcome := Header_Outcome.Ok
	switch {
	case cs.trailers_received || s.remote_closed:
		outcome = .Malformed
	case !cs.headers_received:
		outcome = client_response_headers(c, cs, end_stream)
	case:
		// Trailers must end the stream.
		outcome = .Ok if end_stream && client_trailers(c, cs) else .Malformed
	}
	if end_stream {
		s.remote_closed = true
	}
	sync.cond_broadcast(&s.cond)
	sync.mutex_unlock(&c.mu)
	switch outcome {
	case .Ok:
	case .Malformed:
		reset_stream_id(c, id, .Protocol_Error)
	case .Abort:
		// The status is already decided (e.g. a non-gRPC HTTP response):
		// stop the server from sending a body we would misparse.
		reset_stream_id(c, id, .Cancel)
	}
}

@(private = "file")
Header_Outcome :: enum u8 {
	Ok,
	Malformed, // protocol violation: RST_STREAM(PROTOCOL_ERROR)
	Abort, // valid but the RPC failed: RST_STREAM(CANCEL)
}

// client_response_headers processes the first header block (conn.mu held).
@(private = "file")
client_response_headers :: proc(c: ^Conn, cs: ^Client_Stream, end_stream: bool) -> Header_Outcome {
	h := &c.fields
	if len(h.spans) == 0 {
		return .Malformed
	}
	name, value := field_at(h, 0)
	if name != ":status" || len(value) != 3 {
		return .Malformed
	}
	if value[0] == '1' {
		// Informational (1xx) responses precede the real one and must not
		// end the stream (RFC 9113 §8.1).
		return .Malformed if end_stream else .Ok
	}
	cs.headers_received = true
	if value != "200" {
		// Not a gRPC response (PROTOCOL-HTTP2.md: HTTP to gRPC status mapping).
		cs.status = http_status_to_grpc(value)
		cs.trailers_received = true
		return .Ok if end_stream else .Abort
	}
	content_type, has_ct := "", false
	for i in 1 ..< len(h.spans) {
		n, v := field_at(h, i)
		if n == "content-type" {
			content_type, has_ct = v, true
		}
	}
	if end_stream {
		// Trailers-only response.
		return .Ok if client_trailers(c, cs) else .Malformed
	}
	if !has_ct || !is_grpc_content_type(content_type) {
		cs.status = {.Unknown, "response has an invalid content-type"}
		cs.trailers_received = true
		return .Abort
	}
	if h.too_large {
		cs.status = {.Resource_Exhausted, "response metadata exceeds the client's limit"}
		cs.trailers_received = true
		return .Abort
	}
	md, _, ok := metadata_build(h, include_response_metadata, c.allocator)
	if !ok {
		cs.status = {.Resource_Exhausted, "out of memory reading response metadata"}
		cs.trailers_received = true
		return .Abort
	}
	cs.header_md = md
	return .Ok
}

// client_trailers extracts the status and trailer metadata (conn.mu held).
@(private = "file")
client_trailers :: proc(c: ^Conn, cs: ^Client_Stream) -> bool {
	h := &c.fields
	code_text, message := "", ""
	has_code := false
	for i in 0 ..< len(h.spans) {
		n, v := field_at(h, i)
		switch n {
		case "grpc-status":
			code_text, has_code = v, true
		case "grpc-message":
			message = v
		}
	}
	cs.trailers_received = true
	if h.too_large {
		cs.status = {.Resource_Exhausted, "response trailers exceed the client's limit"}
		return true
	}
	if !has_code {
		cs.status = {.Internal, "response is missing grpc-status"}
		return true
	}
	code, parsed := parse_status_code(code_text)
	if !parsed {
		cs.status = {.Unknown, "response has an invalid grpc-status"}
		return true
	}
	if len(message) > 0 {
		buf, err := make([]u8, len(message), c.allocator)
		if err == nil {
			cs.status_message = buf
			message = percent_decode(buf, message)
		} else {
			message = ""
		}
	}
	cs.status = {code, message}
	md, _, ok := metadata_build(h, include_response_metadata, c.allocator)
	if ok {
		cs.trailer_md = md
	}
	return true
}

@(private = "file")
include_response_metadata :: proc(name: string) -> bool {
	if len(name) > 0 && name[0] == ':' {
		return false
	}
	switch name {
	case "content-type", "grpc-status", "grpc-message", "grpc-encoding", "grpc-accept-encoding":
		return false
	}
	return true
}

@(private = "file")
http_status_to_grpc :: proc(status: string) -> Status {
	switch status {
	case "400":
		return {.Internal, "HTTP status 400"}
	case "401":
		return {.Unauthenticated, "HTTP status 401"}
	case "403":
		return {.Permission_Denied, "HTTP status 403"}
	case "404":
		return {.Unimplemented, "HTTP status 404"}
	case "429", "502", "503", "504":
		return {.Unavailable, "HTTP status indicates the server is unavailable"}
	}
	return {.Unknown, "unexpected HTTP status"}
}

// -----------------------------------------------------------------------------
// Client stream API
// -----------------------------------------------------------------------------

// client_send sends one request message.
client_send :: proc(cs: ^Client_Stream, msg: rawptr) -> Status {
	if cs.send_closed {
		return {.Internal, "send after close_send"}
	}
	buf, st := encode_request(cs, msg)
	if st.code != .OK {
		return st
	}
	if st = stream_send_data(&cs.stream, buf, false, cs.deadline); st.code != .OK {
		return settle_send_failure(cs, st)
	}
	return {}
}

// client_send_last sends the final request message together with
// END_STREAM (one frame sequence instead of two).
client_send_last :: proc(cs: ^Client_Stream, msg: rawptr) -> Status {
	if cs.send_closed {
		return {.Internal, "send after close_send"}
	}
	buf, st := encode_request(cs, msg)
	if st.code != .OK {
		return st
	}
	cs.send_closed = true
	if st = stream_send_data(&cs.stream, buf, true, cs.deadline); st.code != .OK {
		return settle_send_failure(cs, st)
	}
	return {}
}

// encode_request encodes a request into the stream's reusable buffer
// (sending copies the bytes into the connection's queue).
@(private = "file")
encode_request :: proc(cs: ^Client_Stream, msg: rawptr) -> ([]u8, Status) {
	if cs.send_buf.allocator.procedure == nil {
		cs.send_buf.allocator = cs.conn_allocator
	}
	return encode_message_into(&cs.send_buf, msg, cs.method.request, cs.stream.conn.opts.max_send_message_size)
}

// client_close_send signals that no more request messages will be sent.
client_close_send :: proc(cs: ^Client_Stream) -> Status {
	if cs.send_closed {
		return {}
	}
	cs.send_closed = true
	if st := stream_send_data(&cs.stream, nil, true, cs.deadline); st.code != .OK {
		return settle_send_failure(cs, st)
	}
	return {}
}

// A send can fail because the server already finished the RPC; the real
// outcome is then the status it sent.
@(private = "file")
settle_send_failure :: proc(cs: ^Client_Stream, st: Status) -> Status {
	if st.code == .Deadline_Exceeded {
		stream_send_reset(&cs.stream, .Cancel)
		return st
	}
	c := cs.stream.conn
	sync.mutex_lock(&c.mu)
	done := cs.trailers_received
	final := cs.status
	sync.mutex_unlock(&c.mu)
	if done {
		return final
	}
	return st
}

// client_recv receives the next response message into msg (allocated from
// the call's allocator). Returns false when the response stream ended; the
// status is then the RPC's final status.
client_recv :: proc(cs: ^Client_Stream, msg: rawptr) -> (got: bool, st: Status) {
	c := cs.stream.conn
	data, result, rst := stream_recv_message(&cs.stream, c.opts.max_recv_message_size, cs.allocator, cs.deadline)
	switch result {
	case .Message:
		defer delete(data, cs.allocator)
		if err := pb.unmarshal(msg, cs.method.response, data, cs.allocator); err != .None {
			stream_send_reset(&cs.stream, .Cancel)
			return false, {.Internal, "failed to decode the response message"}
		}
		return true, {}
	case .End:
		return false, client_finish(cs)
	case .Rejected:
		// A local error (limit, malformed message, deadline) wins over
		// whatever the server reported.
		stream_send_reset(&cs.stream, .Cancel)
		return false, rst
	case .Failed:
		// The stream failed; if the server already reported a status, that
		// is the RPC's outcome.
		sync.mutex_lock(&c.mu)
		done := cs.trailers_received
		final := cs.status
		sync.mutex_unlock(&c.mu)
		if done {
			return false, final
		}
		return false, rst
	}
	return false, rst
}

// client_header waits for the response headers and returns their metadata
// (valid until client_destroy).
client_header :: proc(cs: ^Client_Stream) -> ([]Metadata_Entry, Status) {
	c := cs.stream.conn
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for !cs.headers_received {
		if f, failed := stream_failure_locked(&cs.stream); failed {
			return nil, f
		}
		if !wait_locked(&cs.stream.cond, &c.mu, cs.deadline) {
			return nil, {.Deadline_Exceeded, "deadline exceeded"}
		}
	}
	return cs.header_md.entries, {}
}

// client_trailer returns the trailer metadata once the RPC has finished.
client_trailer :: proc(cs: ^Client_Stream) -> []Metadata_Entry {
	c := cs.stream.conn
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return cs.trailer_md.entries if cs.trailers_received else nil
}

// client_finish waits for the RPC's final status. The status message stays
// valid until client_destroy.
client_finish :: proc(cs: ^Client_Stream) -> Status {
	if cs.finished {
		return cs.final
	}
	c := cs.stream.conn
	sync.mutex_lock(&c.mu)
	st: Status
	for {
		if cs.trailers_received {
			st = cs.status
			break
		}
		if f, failed := stream_failure_locked(&cs.stream); failed {
			st = f
			if cs.stream.refused {
				st = {.Unavailable, "stream refused before processing"}
			}
			break
		}
		if !wait_locked(&cs.stream.cond, &c.mu, cs.deadline) {
			st = {.Deadline_Exceeded, "deadline exceeded"}
			break
		}
	}
	sync.mutex_unlock(&c.mu)
	if st.code == .Deadline_Exceeded {
		stream_send_reset(&cs.stream, .Cancel)
	}
	cs.finished = true
	cs.final = st
	return st
}

// client_cancel aborts the RPC (RST_STREAM CANCEL).
client_cancel :: proc(cs: ^Client_Stream) {
	stream_send_reset(&cs.stream, .Cancel)
}

// client_destroy releases the stream, cancelling the RPC if it has not
// completed.
client_destroy :: proc(cs: ^Client_Stream) {
	c := cs.stream.conn
	sync.mutex_lock(&c.mu)
	complete := cs.trailers_received && cs.stream.remote_closed
	open := !complete && !cs.stream.reset && !cs.stream.conn_lost
	sync.mutex_unlock(&c.mu)
	if open {
		stream_send_reset(&cs.stream, .Cancel)
	}
	stream_unregister(&cs.stream)
	metadata_destroy(&cs.header_md, cs.conn_allocator)
	metadata_destroy(&cs.trailer_md, cs.conn_allocator)
	if cs.status_message != nil {
		delete(cs.status_message, cs.conn_allocator)
	}
	delete(cs.send_buf)
	a := cs.conn_allocator
	free(cs, a)
}

// client_done finishes the RPC (cancelling it if it is still running),
// releases the stream and returns the final status. The status message is
// copied with the call's allocator.
client_done :: proc(cs: ^Client_Stream) -> Status {
	st := client_finish(cs)
	st = copy_status(st, {allocator = cs.allocator})
	client_destroy(cs)
	return st
}

// invoke performs a unary RPC: one request, one response. The response is
// decoded with opts.allocator (default context.allocator).
invoke :: proc(ch: ^Channel, method: ^Method_Desc, req: rawptr, resp: rawptr, opts := Call_Options{}) -> Status {
	// A stream the server refused before processing it (REFUSED_STREAM or
	// GOAWAY) is retried transparently, a bounded number of times.
	MAX_ATTEMPTS :: 3
	for attempt in 0 ..< MAX_ATTEMPTS {
		cs, st := client_new_stream(ch, method, opts)
		if st.code != .OK {
			return st
		}
		st = client_send_last(cs, req)
		got := false
		if st.code == .OK {
			got, st = client_recv(cs, resp)
			if st.code == .OK && got {
				st = client_finish(cs)
			} else if st.code == .OK && !got {
				st = {.Internal, "server finished a unary RPC without a response"}
			}
		}
		refused := cs.stream.refused
		if st.code != .OK {
			st = copy_status(st, opts)
		}
		client_destroy(cs)
		if !refused || attempt == MAX_ATTEMPTS - 1 {
			return st
		}
	}
	unreachable()
}

// copy_status moves a status message out of stream-owned memory before the
// stream is destroyed.
@(private = "file")
copy_status :: proc(st: Status, opts: Call_Options) -> Status {
	if st.message == "" {
		return st
	}
	a := opts.allocator if opts.allocator.procedure != nil else context.allocator
	msg, err := strings.clone(st.message, a)
	if err != nil {
		return {st.code, ""}
	}
	return {st.code, msg}
}
