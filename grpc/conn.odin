package grpc

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"

import "../hpack"
import "../http2"

/*
Connection core shared by clients and servers.

Threads
  - The reader thread owns the transport's read side, the HPACK decoder and
    all frame processing. It never blocks on anything but the transport.
  - The writer thread owns the transport's write side. Everyone else
    enqueues complete frames into `q`; the writer drains the queue with one
    transport write per batch.
  - Application threads (client callers, server handlers) enqueue HEADERS
    and DATA frames and wait for flow-control window, data and events.

Locks (acquire in this order; never the reverse)
  1. q_mu  - the outgoing frame queue and the HPACK encoder. Holding it
             while encoding a header block keeps encoder state in wire order.
  2. mu    - connection and stream state: stream table, flow-control
             windows, receive queues, stream flags.
  The reader never holds `mu` while taking `q_mu`: control frames produced
  while handling a frame are collected in `ctrl` and enqueued afterwards.

Lifetime
  The Conn is reference counted (`refs`): the reader thread, each live
  stream and the owner (server or channel) hold references. The reader is
  the only thread that closes the transport.
*/

// Conn_Options tune a connection. Zero values select the defaults.
Conn_Options :: struct {
	// Per-stream receive window advertised to the peer.
	initial_window_size:    u32,
	// Connection-level receive window.
	connection_window_size: u32,
	// Largest frame payload accepted (SETTINGS_MAX_FRAME_SIZE).
	max_frame_size:         u32,
	// Largest uncompressed header list accepted.
	max_header_list_size:   u32,
	// Concurrent streams the peer may open (servers).
	max_concurrent_streams: u32,
	// Bounds on a single gRPC message.
	max_recv_message_size:  int,
	max_send_message_size:  int,
	// Time allowed for the peer's connection preface and first SETTINGS;
	// negative disables.
	handshake_timeout:      time.Duration,
	// Send a keepalive PING after this long without receiving anything;
	// close the connection if it is not acknowledged within
	// keepalive_timeout. Zero disables keepalive.
	keepalive_time:         time.Duration,
	keepalive_timeout:      time.Duration,
	// Gracefully close a connection that has had no streams for this long.
	// Zero disables.
	idle_timeout:           time.Duration,
	// Limit on "cheap for the peer, costly for us" frames (PING, SETTINGS,
	// RST_STREAM, refused streams, empty DATA/CONTINUATION) per second.
	// Exceeding it closes the connection with ENHANCE_YOUR_CALM.
	max_control_frames_per_second: int,
}

// The stream window bounds how much one stream buffers; with the default
// concurrency limit a connection buffers at most 100 * 256 KiB.
DEFAULT_INITIAL_WINDOW_SIZE :: 256 << 10
DEFAULT_CONNECTION_WINDOW_SIZE :: 16 << 20
DEFAULT_MAX_HEADER_LIST_SIZE :: 16 << 10
DEFAULT_MAX_CONCURRENT_STREAMS :: 100
DEFAULT_MAX_RECV_MESSAGE_SIZE :: 4 << 20
DEFAULT_MAX_SEND_MESSAGE_SIZE :: 1 << 31 - 1
DEFAULT_HANDSHAKE_TIMEOUT :: 10 * time.Second
DEFAULT_KEEPALIVE_TIMEOUT :: 20 * time.Second
DEFAULT_MAX_CONTROL_FRAMES_PER_SECOND :: 1000

// Outgoing queue thresholds: producers wait above QUEUE_SOFT_LIMIT; the
// reader's control frames alone pushing it past QUEUE_HARD_LIMIT means the
// peer is flooding us (e.g. PINGs) without reading responses.
QUEUE_SOFT_LIMIT :: 256 << 10
QUEUE_HARD_LIMIT :: 4 << 20

// Header blocks (HEADERS + CONTINUATION) larger than this are refused
// before decoding completes (CONTINUATION flood protection).
MAX_HEADER_BLOCK_SIZE :: 256 << 10

@(private)
normalize_options :: proc(o: Conn_Options) -> Conn_Options {
	r := o
	if r.initial_window_size == 0 {r.initial_window_size = DEFAULT_INITIAL_WINDOW_SIZE}
	if r.connection_window_size == 0 {r.connection_window_size = DEFAULT_CONNECTION_WINDOW_SIZE}
	if r.max_frame_size == 0 {r.max_frame_size = http2.DEFAULT_MAX_FRAME_SIZE}
	if r.max_header_list_size == 0 {r.max_header_list_size = DEFAULT_MAX_HEADER_LIST_SIZE}
	if r.max_concurrent_streams == 0 {r.max_concurrent_streams = DEFAULT_MAX_CONCURRENT_STREAMS}
	if r.max_recv_message_size == 0 {r.max_recv_message_size = DEFAULT_MAX_RECV_MESSAGE_SIZE}
	if r.max_send_message_size == 0 {r.max_send_message_size = DEFAULT_MAX_SEND_MESSAGE_SIZE}
	if r.handshake_timeout == 0 {r.handshake_timeout = DEFAULT_HANDSHAKE_TIMEOUT}
	if r.handshake_timeout < 0 {r.handshake_timeout = 0} // disabled
	if r.keepalive_time < 0 {r.keepalive_time = 0} // disabled
	if r.idle_timeout < 0 {r.idle_timeout = 0}
	if r.keepalive_timeout <= 0 {r.keepalive_timeout = DEFAULT_KEEPALIVE_TIMEOUT}
	if r.max_control_frames_per_second <= 0 {r.max_control_frames_per_second = DEFAULT_MAX_CONTROL_FRAMES_PER_SECOND}
	r.initial_window_size = clamp(r.initial_window_size, http2.DEFAULT_INITIAL_WINDOW_SIZE, http2.MAX_WINDOW_SIZE)
	r.connection_window_size = clamp(r.connection_window_size, http2.DEFAULT_INITIAL_WINDOW_SIZE, http2.MAX_WINDOW_SIZE)
	r.max_frame_size = clamp(r.max_frame_size, http2.MIN_MAX_FRAME_SIZE, http2.MAX_MAX_FRAME_SIZE)
	return r
}

Role :: enum u8 {
	Client,
	Server,
}

Peer_Settings :: struct {
	initial_window_size:    i64,
	max_frame_size:         int,
	max_concurrent_streams: u32,
	max_header_list_size:   u32,
}

Conn :: struct {
	role:              Role,
	transport:         Transport,
	opts:              Conn_Options,
	allocator:         runtime.Allocator, // heap; thread-safe
	refs:              i32, // atomic
	owner:             rawptr, // ^Server or ^Channel

	// --- outgoing queue (q_mu) ---
	q_mu:              sync.Mutex,
	q_cond:            sync.Cond, // writer: frames available or closing
	q_space:           sync.Cond, // producers: queue below the soft limit
	q:                 [dynamic]u8,
	q_spare:           [dynamic]u8,
	q_closed:          bool, // no more frames accepted
	encoder:           hpack.Encoder,
	hbuf:              [dynamic]u8, // header block scratch for encoding

	// --- shared state (mu) ---
	mu:                sync.Mutex,
	cond:              sync.Cond, // windows, stream slots, settings, close
	streams:           map[u32]^Stream,
	active_streams:    u32, // streams counted against concurrency limits
	send_window:       i64, // connection-level, peer's grant to us
	recv_window:       i64, // connection-level, our grant to the peer
	recv_unacked:      i64,
	peer:              Peer_Settings,
	next_stream_id:    u32, // client: next id to use
	last_peer_stream:  u32, // server: highest stream id opened by the peer
	goaway_received:   bool,
	goaway_last_id:    u32,
	goaway_sent:       bool,
	closed:            bool, // no new streams, everything failing
	close_reason:      string, // static string describing why

	// --- reader-owned ---
	decoder:           hpack.Decoder,
	rbuf:              []u8,
	rpos, rlen:        int,
	ctrl:              [dynamic]u8, // control frames to enqueue
	hblock:            [dynamic]u8, // CONTINUATION assembly
	hblock_stream:     u32,
	hblock_end_stream: bool,
	hblock_dispatch:   bool, // false: decode only (the stream was reset)
	fields:            Header_Fields,
	closing:           bool, // atomic: reader should stop
	settings_seen:     bool,
	created:           time.Tick,
	last_read:         time.Tick,
	ping_outstanding:  bool,
	ping_sent:         time.Tick,
	idle_since:        time.Tick, // guarded by mu; set when no streams remain
	abuse_window:      time.Tick,
	abuse_count:       int,

	reader:            ^thread.Thread,
	writer:            ^thread.Thread,
}

// Header_Fields collects one decoded header block. Strings point into
// `bytes`, which is reset per block (reader-owned scratch).
Header_Fields :: struct {
	bytes:     [dynamic]u8,
	spans:     [dynamic]Field_Span,
	too_large: bool,
}

Field_Span :: struct {
	name_off, name_len, value_off, value_len: u32,
}

field_at :: proc(h: ^Header_Fields, i: int) -> (name, value: string) {
	s := h.spans[i]
	name = string(h.bytes[s.name_off:s.name_off + s.name_len])
	value = string(h.bytes[s.value_off:s.value_off + s.value_len])
	return
}

// -----------------------------------------------------------------------------
// Creation, start, references
// -----------------------------------------------------------------------------

@(private)
conn_create :: proc(role: Role, transport: Transport, opts: Conn_Options, owner: rawptr, allocator := context.allocator) -> (c: ^Conn, ok: bool) {
	new_err: runtime.Allocator_Error
	c, new_err = new(Conn, allocator)
	if new_err != nil {
		return nil, false
	}
	c.role = role
	c.transport = transport
	c.opts = normalize_options(opts)
	c.allocator = allocator
	c.refs = 1 // the reader thread's reference
	c.q = make([dynamic]u8, 0, 64 << 10, allocator)
	c.q_spare = make([dynamic]u8, 0, 64 << 10, allocator)
	c.hbuf = make([dynamic]u8, 0, 1024, allocator)
	c.ctrl = make([dynamic]u8, 0, 256, allocator)
	c.hblock = make([dynamic]u8, allocator)
	c.fields.bytes = make([dynamic]u8, 0, 1024, allocator)
	c.fields.spans = make([dynamic]Field_Span, 0, 32, allocator)
	c.streams = make(map[u32]^Stream, allocator)
	c.send_window = http2.DEFAULT_INITIAL_WINDOW_SIZE
	c.recv_window = i64(c.opts.connection_window_size)
	c.peer = {
		initial_window_size    = http2.DEFAULT_INITIAL_WINDOW_SIZE,
		max_frame_size         = http2.DEFAULT_MAX_FRAME_SIZE,
		max_concurrent_streams = max(u32),
		max_header_list_size   = max(u32),
	}
	c.next_stream_id = 1
	c.created = time.tick_now()
	c.last_read = c.created
	c.idle_since = c.created
	c.abuse_window = c.created
	// The read buffer holds at least two maximal frames so reads batch well.
	c.rbuf = make([]u8, max(64 << 10, 2 * (http2.FRAME_HEADER_SIZE + int(c.opts.max_frame_size))), allocator)
	if hpack.encoder_init(&c.encoder, hpack.DEFAULT_TABLE_SIZE, allocator) != .None ||
	   hpack.decoder_init(&c.decoder, hpack.DEFAULT_TABLE_SIZE, int(c.opts.max_header_list_size), allocator) != .None ||
	   c.rbuf == nil {
		conn_free(c)
		return nil, false
	}

	// Connection preface (client) and initial SETTINGS. The receive window
	// above the 65535 default is granted with a connection WINDOW_UPDATE.
	if role == .Client {
		append(&c.q, http2.CLIENT_PREFACE)
	}
	settings_buf: [6]http2.Setting
	settings := settings_buf[:0]
	settings_buf[0] = {.Max_Frame_Size, c.opts.max_frame_size}
	settings_buf[1] = {.Initial_Window_Size, c.opts.initial_window_size}
	settings_buf[2] = {.Max_Header_List_Size, c.opts.max_header_list_size}
	settings_buf[3] = {.Enable_Push, 0}
	settings = settings_buf[:4]
	if role == .Server {
		settings_buf[4] = {.Max_Concurrent_Streams, c.opts.max_concurrent_streams}
		settings = settings_buf[:5]
	}
	http2.append_settings(&c.q, settings)
	if c.opts.connection_window_size > http2.DEFAULT_INITIAL_WINDOW_SIZE {
		http2.append_window_update(&c.q, 0, c.opts.connection_window_size - http2.DEFAULT_INITIAL_WINDOW_SIZE)
	}
	// Set last: the owner is notified when the connection is freed, and it
	// only counts connections that were created successfully.
	c.owner = owner
	return c, true
}

// conn_start launches the reader and writer threads. Thread structures
// come from the heap allocator: the self-cleaning reader frees its own
// after the connection itself is gone.
@(private)
conn_start :: proc(c: ^Conn) -> bool {
	context.allocator = runtime.heap_allocator()
	c.writer = thread.create(writer_main)
	if c.writer == nil {
		return false
	}
	c.writer.data = c
	c.reader = thread.create(reader_main)
	if c.reader == nil {
		thread.destroy(c.writer)
		c.writer = nil
		return false
	}
	c.reader.data = c
	c.reader.flags += {.Self_Cleanup}
	thread.start(c.writer)
	thread.start(c.reader)
	return true
}

@(private)
conn_retain :: proc(c: ^Conn) {
	sync.atomic_add(&c.refs, 1)
}

@(private)
conn_release :: proc(c: ^Conn) {
	if sync.atomic_sub(&c.refs, 1) == 1 {
		conn_free(c)
	}
}

@(private)
conn_free :: proc(c: ^Conn) {
	role, owner := c.role, c.owner
	defer if owner != nil {
		switch role {
		case .Server:
			server_on_conn_freed((^Server)(owner))
		case .Client:
			channel_on_conn_freed((^Channel)(owner))
		}
	}
	a := c.allocator
	hpack.encoder_destroy(&c.encoder)
	hpack.decoder_destroy(&c.decoder)
	delete(c.q)
	delete(c.q_spare)
	delete(c.hbuf)
	delete(c.ctrl)
	delete(c.hblock)
	delete(c.fields.bytes)
	delete(c.fields.spans)
	delete(c.streams)
	delete(c.rbuf, a)
	free(c, a)
}

// conn_shutdown asks the connection to close: the reader stops at its next
// read poll, the writer flushes everything already queued (responses,
// GOAWAY), then the transport is closed. Safe to call from any thread,
// repeatedly.
@(private)
conn_shutdown :: proc(c: ^Conn, reason: string) {
	sync.mutex_lock(&c.mu)
	if c.close_reason == "" {
		c.close_reason = reason
	}
	sync.mutex_unlock(&c.mu)
	sync.atomic_store(&c.closing, true)
}

// conn_abort closes the connection without flushing: used when the
// transport itself failed. The transport shutdown wakes blocked I/O.
@(private)
conn_abort :: proc(c: ^Conn, reason: string) {
	conn_shutdown(c, reason)
	c.transport.shutdown(c.transport.data)
}

// conn_is_usable reports whether new streams may be opened.
@(private)
conn_is_usable :: proc(c: ^Conn) -> bool {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return !c.closed && !c.goaway_received && !c.goaway_sent
}

// -----------------------------------------------------------------------------
// Outgoing queue
// -----------------------------------------------------------------------------

Queue_Lock_Result :: enum u8 {
	Locked,
	Closed, // the connection no longer accepts frames
	Timeout, // the deadline passed while waiting for space
}

// queue_lock acquires the queue for a producer, waiting while it is over
// the soft limit (backpressure) until `deadline`. Anything but .Locked
// leaves the queue unlocked.
@(private)
queue_lock :: proc(c: ^Conn, deadline: time.Time = {}) -> Queue_Lock_Result {
	sync.mutex_lock(&c.q_mu)
	for len(c.q) > QUEUE_SOFT_LIMIT && !c.q_closed {
		if !wait_locked(&c.q_space, &c.q_mu, deadline) {
			sync.mutex_unlock(&c.q_mu)
			return .Timeout
		}
	}
	if c.q_closed {
		sync.mutex_unlock(&c.q_mu)
		return .Closed
	}
	return .Locked
}

// queue_lock_urgent acquires the queue without waiting for space, for small
// frames that relieve the peer or end streams (RST_STREAM, WINDOW_UPDATE,
// GOAWAY). Returns false (unlocked) if the connection is closed.
@(private)
queue_lock_urgent :: proc(c: ^Conn) -> bool {
	sync.mutex_lock(&c.q_mu)
	if c.q_closed {
		sync.mutex_unlock(&c.q_mu)
		return false
	}
	return true
}

// queue_status maps a failed queue_lock to an RPC status.
@(private)
queue_status :: proc "contextless" (r: Queue_Lock_Result) -> Status {
	if r == .Timeout {
		return {.Deadline_Exceeded, "deadline exceeded waiting to send"}
	}
	return {.Unavailable, "connection closed"}
}

// queue_unlock wakes the writer if frames were added.
@(private)
queue_unlock :: proc(c: ^Conn) {
	if len(c.q) > 0 {
		sync.cond_signal(&c.q_cond)
	}
	sync.mutex_unlock(&c.q_mu)
}

// apply_peer_table_size forwards a peer SETTINGS_HEADER_TABLE_SIZE to the
// encoder. Called by the reader; q_mu is never held long.
@(private)
apply_peer_table_size :: proc(c: ^Conn, size: u32) {
	sync.mutex_lock(&c.q_mu)
	hpack.encoder_set_peer_max_table_size(&c.encoder, int(min(size, u32(max(i32)))))
	sync.mutex_unlock(&c.q_mu)
}

// flush_ctrl moves the reader's pending control frames into the queue.
// The reader never waits for queue space; a queue growing past the hard
// limit is treated as a flood.
@(private)
flush_ctrl :: proc(c: ^Conn) {
	if len(c.ctrl) == 0 {
		return
	}
	sync.mutex_lock(&c.q_mu)
	flood := false
	if !c.q_closed {
		if len(c.q) + len(c.ctrl) > QUEUE_HARD_LIMIT {
			flood = true
		} else {
			append(&c.q, ..c.ctrl[:])
			sync.cond_signal(&c.q_cond)
		}
	}
	sync.mutex_unlock(&c.q_mu)
	clear(&c.ctrl)
	if flood {
		conn_error(c, .Enhance_Your_Calm, "too many unanswered control frames")
	}
}

@(private)
writer_main :: proc(t: ^thread.Thread) {
	c := (^Conn)(t.data)
	for {
		sync.mutex_lock(&c.q_mu)
		for len(c.q) == 0 && !c.q_closed {
			sync.cond_wait(&c.q_cond, &c.q_mu)
		}
		if len(c.q) == 0 && c.q_closed {
			sync.mutex_unlock(&c.q_mu)
			return
		}
		c.q, c.q_spare = c.q_spare, c.q
		sync.cond_broadcast(&c.q_space)
		sync.mutex_unlock(&c.q_mu)

		err := c.transport.write(c.transport.data, c.q_spare[:])
		clear(&c.q_spare)
		if err != .None {
			// The peer is gone or stopped reading: drop everything queued
			// and make the reader tear the connection down.
			sync.mutex_lock(&c.q_mu)
			c.q_closed = true
			clear(&c.q)
			sync.cond_broadcast(&c.q_space)
			sync.mutex_unlock(&c.q_mu)
			conn_abort(c, "connection write failed")
			return
		}
	}
}

// -----------------------------------------------------------------------------
// Reader
// -----------------------------------------------------------------------------

// conn_error reports a connection error (RFC 9113 §5.4.1): GOAWAY with the
// last processed stream, then the connection is torn down.
@(private)
conn_error :: proc(c: ^Conn, code: http2.Error_Code, reason: string) {
	sync.mutex_lock(&c.mu)
	last := c.last_peer_stream
	already := c.goaway_sent
	c.goaway_sent = true
	sync.mutex_unlock(&c.mu)
	if !already {
		http2.append_goaway(&c.ctrl, last, code, reason)
		// Bypass flush_ctrl's flood check: this is the final frame.
		sync.mutex_lock(&c.q_mu)
		if !c.q_closed {
			append(&c.q, ..c.ctrl[:])
			sync.cond_signal(&c.q_cond)
		}
		sync.mutex_unlock(&c.q_mu)
		clear(&c.ctrl)
	}
	conn_shutdown(c, reason)
}

// fill ensures n unread octets are buffered. Returns false when the
// connection closed or is being shut down.
@(private = "file")
fill :: proc(c: ^Conn, n: int) -> bool {
	for c.rlen - c.rpos < n {
		if c.rpos > 0 {
			copy(c.rbuf, c.rbuf[c.rpos:c.rlen])
			c.rlen -= c.rpos
			c.rpos = 0
		}
		if sync.atomic_load(&c.closing) {
			return false
		}
		got, err := c.transport.read(c.transport.data, c.rbuf[c.rlen:])
		switch err {
		case .None:
			c.rlen += got
			c.last_read = time.tick_now()
		case .Timeout:
			if !poll_timers(c) {
				return false
			}
		case .Closed, .Failed:
			return false
		}
	}
	return true
}

KEEPALIVE_PING_DATA :: [8]u8{'k', 'e', 'e', 'p', 'a', 'l', 'i', 'v'}

// poll_timers runs on every idle read poll: handshake timeout, keepalive
// PINGs and idle-connection closing. Returns false to stop reading.
@(private = "file")
poll_timers :: proc(c: ^Conn) -> bool {
	now := time.tick_now()
	o := &c.opts
	if !c.settings_seen && o.handshake_timeout > 0 && time.tick_diff(c.created, now) > o.handshake_timeout {
		conn_error(c, .Settings_Timeout, "connection preface not received in time")
		return false
	}
	if o.keepalive_time > 0 {
		if c.ping_outstanding {
			if time.tick_diff(c.ping_sent, now) > o.keepalive_timeout {
				conn_abort(c, "keepalive PING not acknowledged")
				return false
			}
		} else if time.tick_diff(c.last_read, now) > o.keepalive_time {
			http2.append_ping(&c.ctrl, KEEPALIVE_PING_DATA, false)
			c.ping_outstanding = true
			c.ping_sent = now
			flush_ctrl(c)
		}
	}
	if o.idle_timeout > 0 {
		sync.mutex_lock(&c.mu)
		idle := len(c.streams) == 0 && c.active_streams == 0 && time.tick_diff(c.idle_since, now) > o.idle_timeout
		sync.mutex_unlock(&c.mu)
		if idle {
			send_goaway(c, .No_Error)
		}
	}
	return !sync.atomic_load(&c.closing)
}

// note_abuse counts a frame that is cheap for the peer but costs us work
// (PING, SETTINGS, RST_STREAM, refused or reset streams, empty DATA or
// CONTINUATION). Returns false (after closing the connection with
// ENHANCE_YOUR_CALM) when the peer exceeds the per-second budget.
@(private)
note_abuse :: proc(c: ^Conn) -> bool {
	now := time.tick_now()
	if time.tick_diff(c.abuse_window, now) > time.Second {
		c.abuse_window = now
		c.abuse_count = 0
	}
	c.abuse_count += 1
	if c.abuse_count > c.opts.max_control_frames_per_second {
		conn_error(c, .Enhance_Your_Calm, "too many control frames")
		return false
	}
	return true
}

@(private)
reader_main :: proc(t: ^thread.Thread) {
	c := (^Conn)(t.data)
	read_loop(c)
	conn_teardown(c)
}

@(private = "file")
read_loop :: proc(c: ^Conn) {
	if c.role == .Server {
		preface := http2.CLIENT_PREFACE
		if !fill(c, len(preface)) {
			return
		}
		if string(c.rbuf[c.rpos:c.rpos + len(preface)]) != preface {
			conn_error(c, .Protocol_Error, "invalid connection preface")
			return
		}
		c.rpos += len(preface)
	}
	for !sync.atomic_load(&c.closing) {
		if !fill(c, http2.FRAME_HEADER_SIZE) {
			return
		}
		h := http2.decode_frame_header(c.rbuf[c.rpos:])
		if p := http2.check_frame_header(h, c.opts.max_frame_size); http2.has_problem(p) {
			if p.scope == .Connection {
				conn_error(c, p.code, p.message)
				return
			}
		}
		if !fill(c, http2.FRAME_HEADER_SIZE + int(h.length)) {
			return
		}
		payload := c.rbuf[c.rpos + http2.FRAME_HEADER_SIZE:][:h.length]
		c.rpos += http2.FRAME_HEADER_SIZE + int(h.length)
		handle_frame(c, h, payload)
		flush_ctrl(c)
	}
}

@(private = "file")
handle_frame :: proc(c: ^Conn, h: http2.Frame_Header, payload: []u8) {
	// The peer's first frame must be SETTINGS (§3.4).
	if !c.settings_seen {
		if h.type != u8(http2.Frame_Type.Settings) || h.flags & http2.FLAG_ACK != 0 {
			conn_error(c, .Protocol_Error, "first frame must be SETTINGS")
			return
		}
		c.settings_seen = true
	}
	// While a header block is open, only its CONTINUATION frames may follow
	// (§6.10).
	if c.hblock_stream != 0 && (h.type != u8(http2.Frame_Type.Continuation) || h.stream_id != c.hblock_stream) {
		conn_error(c, .Protocol_Error, "expected CONTINUATION frame")
		return
	}
	if !http2.is_known_type(h.type) {
		return
	}
	// Frame-header problems that are stream-scoped (PRIORITY size).
	if p := http2.check_frame_header(h, c.opts.max_frame_size); http2.has_problem(p) {
		reset_stream_id(c, h.stream_id, p.code)
		return
	}
	switch http2.Frame_Type(h.type) {
	case .Data:
		handle_data(c, h, payload)
	case .Headers:
		f, p := http2.parse_headers(h, payload)
		dispatch := true
		if http2.has_problem(p) {
			if p.scope == .Connection {
				conn_error(c, p.code, p.message)
				return
			}
			// The block is still decoded (including any CONTINUATION frames)
			// to keep HPACK in sync, but not dispatched.
			reset_stream_id(c, h.stream_id, p.code)
			dispatch = false
		}
		if f.end_headers {
			decode_header_block(c, h.stream_id, f.fragment, f.end_stream, dispatch)
		} else {
			clear(&c.hblock)
			append(&c.hblock, ..f.fragment)
			c.hblock_stream = h.stream_id
			c.hblock_end_stream = f.end_stream
			c.hblock_dispatch = dispatch
		}
	case .Continuation:
		if c.hblock_stream == 0 {
			conn_error(c, .Protocol_Error, "unexpected CONTINUATION frame")
			return
		}
		if len(payload) == 0 && h.flags & http2.FLAG_END_HEADERS == 0 && !note_abuse(c) {
			return
		}
		if len(c.hblock) + len(payload) > MAX_HEADER_BLOCK_SIZE {
			conn_error(c, .Enhance_Your_Calm, "header block too large")
			return
		}
		append(&c.hblock, ..payload)
		if h.flags & http2.FLAG_END_HEADERS != 0 {
			id := c.hblock_stream
			c.hblock_stream = 0
			decode_header_block(c, id, c.hblock[:], c.hblock_end_stream, c.hblock_dispatch)
		}
	case .Priority:
		if _, p := http2.parse_priority(h, payload); http2.has_problem(p) {
			reset_stream_id(c, h.stream_id, p.code)
		}
	case .Rst_Stream:
		handle_rst_stream(c, h, http2.parse_rst_stream(payload))
	case .Settings:
		handle_settings(c, h, payload)
	case .Push_Promise:
		// We advertise SETTINGS_ENABLE_PUSH = 0 (clients) and servers never
		// receive pushes (§8.4).
		conn_error(c, .Protocol_Error, "PUSH_PROMISE not allowed")
	case .Ping:
		if h.flags & http2.FLAG_ACK != 0 {
			if http2.parse_ping(payload) == KEEPALIVE_PING_DATA {
				c.ping_outstanding = false
			}
		} else if note_abuse(c) {
			http2.append_ping(&c.ctrl, http2.parse_ping(payload), true)
		}
	case .Goaway:
		handle_goaway(c, http2.parse_goaway(payload))
	case .Window_Update:
		handle_window_update(c, h, payload)
	}
}

// is_idle reports whether a stream id has never been opened (§5.1).
@(private = "file")
is_idle :: proc(c: ^Conn, id: u32) -> bool {
	if c.role == .Server {
		// Peer-initiated streams are odd; we never open even ones.
		return id % 2 == 0 || id > c.last_peer_stream
	}
	return id % 2 == 0 || id >= c.next_stream_id
}

// reset_stream_id sends RST_STREAM for a stream error and fails the stream
// locally if it is still known.
@(private)
reset_stream_id :: proc(c: ^Conn, id: u32, code: http2.Error_Code) {
	sync.mutex_lock(&c.mu)
	if s, ok := c.streams[id]; ok {
		stream_mark_reset_locked(s, code, false)
	}
	sync.mutex_unlock(&c.mu)
	http2.append_rst_stream(&c.ctrl, id, code)
}

@(private = "file")
handle_data :: proc(c: ^Conn, h: http2.Frame_Header, payload: []u8) {
	f, p := http2.parse_data(h, payload)
	if http2.has_problem(p) {
		conn_error(c, p.code, p.message)
		return
	}
	if len(f.data) == 0 && !f.end_stream && !note_abuse(c) {
		return
	}
	n := i64(h.length) // padding counts against flow control (§6.9.1)

	sync.mutex_lock(&c.mu)
	if is_idle(c, h.stream_id) {
		sync.mutex_unlock(&c.mu)
		conn_error(c, .Protocol_Error, "DATA on idle stream")
		return
	}
	c.recv_window -= n
	if c.recv_window < 0 {
		sync.mutex_unlock(&c.mu)
		conn_error(c, .Flow_Control_Error, "connection flow-control window exceeded")
		return
	}
	// The connection window is returned as soon as data is received: the
	// per-stream windows already bound how much each stream buffers.
	c.recv_unacked += n
	conn_update: u32 = 0
	if c.recv_unacked >= i64(c.opts.connection_window_size) / 2 {
		conn_update = u32(c.recv_unacked)
		c.recv_window += c.recv_unacked
		c.recv_unacked = 0
	}

	s, known := c.streams[h.stream_id]
	reset_code: http2.Error_Code
	reset := false
	switch {
	case !known:
	// A stream we already closed or reset: in-flight data is discarded.
	case s.remote_closed:
		reset, reset_code = true, .Stream_Closed
	case:
		s.recv_window -= n
		if s.recv_window < 0 {
			reset, reset_code = true, .Flow_Control_Error
			break
		}
		// Padding is consumed immediately.
		s.recv_unacked += n - i64(len(f.data))
		if len(f.data) > 0 && !bq_push(&s.rq, f.data, c.allocator) {
			reset, reset_code = true, .Internal_Error
			break
		}
		if f.end_stream {
			s.remote_closed = true
		}
		sync.cond_broadcast(&s.cond)
	}
	if reset && known {
		stream_mark_reset_locked(s, reset_code, false)
	}
	sync.mutex_unlock(&c.mu)

	if reset {
		http2.append_rst_stream(&c.ctrl, h.stream_id, reset_code)
	}
	if conn_update > 0 {
		http2.append_window_update(&c.ctrl, 0, conn_update)
	}
}

@(private = "file")
handle_rst_stream :: proc(c: ^Conn, h: http2.Frame_Header, code: http2.Error_Code) {
	if !note_abuse(c) {
		return
	}
	sync.mutex_lock(&c.mu)
	if is_idle(c, h.stream_id) {
		sync.mutex_unlock(&c.mu)
		conn_error(c, .Protocol_Error, "RST_STREAM on idle stream")
		return
	}
	if s, ok := c.streams[h.stream_id]; ok {
		// REFUSED_STREAM guarantees the peer did not process the stream,
		// so the request may be retried (§8.7).
		if code == .Refused_Stream {
			s.refused = true
		}
		stream_mark_reset_locked(s, code, true)
	}
	sync.mutex_unlock(&c.mu)
}

@(private = "file")
handle_settings :: proc(c: ^Conn, h: http2.Frame_Header, payload: []u8) {
	if h.flags & http2.FLAG_ACK != 0 {
		return
	}
	if !note_abuse(c) {
		return
	}
	offset := 0
	for {
		id, value, ok := http2.next_setting(payload, &offset)
		if !ok {
			break
		}
		if p := http2.check_setting(id, value); http2.has_problem(p) {
			conn_error(c, p.code, p.message)
			return
		}
		switch http2.Setting_Id(id) {
		case .Header_Table_Size:
			apply_peer_table_size(c, value)
		case .Initial_Window_Size:
			// Adjust every stream's send window by the delta (§6.9.2).
			sync.mutex_lock(&c.mu)
			delta := i64(value) - c.peer.initial_window_size
			c.peer.initial_window_size = i64(value)
			overflow := false
			for _, s in c.streams {
				s.send_window += delta
				if s.send_window > http2.MAX_WINDOW_SIZE {
					overflow = true
				}
			}
			sync.cond_broadcast(&c.cond)
			sync.mutex_unlock(&c.mu)
			if overflow {
				conn_error(c, .Flow_Control_Error, "SETTINGS_INITIAL_WINDOW_SIZE overflows a stream window")
				return
			}
		case .Max_Frame_Size:
			sync.mutex_lock(&c.mu)
			c.peer.max_frame_size = int(value)
			sync.mutex_unlock(&c.mu)
		case .Max_Concurrent_Streams:
			sync.mutex_lock(&c.mu)
			c.peer.max_concurrent_streams = value
			sync.cond_broadcast(&c.cond)
			sync.mutex_unlock(&c.mu)
		case .Max_Header_List_Size:
			sync.mutex_lock(&c.mu)
			c.peer.max_header_list_size = value
			sync.mutex_unlock(&c.mu)
		case .Enable_Push:
			if c.role == .Client && value != 0 {
				conn_error(c, .Protocol_Error, "servers must not enable push")
				return
			}
		}
	}
	http2.append_settings_ack(&c.ctrl)
}

@(private = "file")
handle_goaway :: proc(c: ^Conn, g: http2.Goaway_Frame) {
	sync.mutex_lock(&c.mu)
	c.goaway_received = true
	c.goaway_last_id = g.last_stream_id
	// Streams we opened above last_stream_id were not processed and can be
	// retried elsewhere (§6.8).
	if c.role == .Client {
		for id, s in c.streams {
			if id > g.last_stream_id {
				s.refused = true
				stream_mark_reset_locked(s, .Refused_Stream, true)
			}
		}
	}
	empty := len(c.streams) == 0
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mu)
	if empty || g.code != .No_Error {
		conn_shutdown(c, "peer sent GOAWAY")
	}
}

@(private = "file")
handle_window_update :: proc(c: ^Conn, h: http2.Frame_Header, payload: []u8) {
	inc, p := http2.parse_window_update(h, payload)
	if http2.has_problem(p) {
		if p.scope == .Connection {
			conn_error(c, p.code, p.message)
		} else {
			reset_stream_id(c, h.stream_id, p.code)
		}
		return
	}
	sync.mutex_lock(&c.mu)
	if h.stream_id == 0 {
		c.send_window += i64(inc)
		if c.send_window > http2.MAX_WINDOW_SIZE {
			sync.mutex_unlock(&c.mu)
			conn_error(c, .Flow_Control_Error, "connection window overflow")
			return
		}
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mu)
		return
	}
	if is_idle(c, h.stream_id) {
		sync.mutex_unlock(&c.mu)
		conn_error(c, .Protocol_Error, "WINDOW_UPDATE on idle stream")
		return
	}
	overflow := false
	if s, ok := c.streams[h.stream_id]; ok && !s.reset {
		s.send_window += i64(inc)
		if s.send_window > http2.MAX_WINDOW_SIZE {
			overflow = true
			stream_mark_reset_locked(s, .Flow_Control_Error, false)
		}
		sync.cond_broadcast(&c.cond)
	}
	sync.mutex_unlock(&c.mu)
	if overflow {
		http2.append_rst_stream(&c.ctrl, h.stream_id, .Flow_Control_Error)
	}
}

// decode_header_block decodes a complete header block and hands it to the
// role-specific handler. Decoding always happens (even for refused
// streams) so that the HPACK context stays synchronised.
@(private = "file")
decode_header_block :: proc(c: ^Conn, stream_id: u32, block: []u8, end_stream: bool, dispatch: bool) {
	clear(&c.fields.bytes)
	clear(&c.fields.spans)
	c.fields.too_large = false
	err := hpack.decode_block(&c.decoder, block, collect_field, c)
	if hpack.is_fatal(err) {
		conn_error(c, .Compression_Error, "header block decoding failed")
		return
	}
	c.fields.too_large = err == .Header_List_Too_Large
	if !dispatch {
		return
	}
	switch c.role {
	case .Server:
		server_on_headers(c, stream_id, end_stream)
	case .Client:
		client_on_headers(c, stream_id, end_stream)
	}
}

@(private = "file")
collect_field :: proc(user: rawptr, f: hpack.Header_Field, sensitive: bool) {
	c := (^Conn)(user)
	h := &c.fields
	span := Field_Span {
		name_off  = u32(len(h.bytes)),
		name_len  = u32(len(f.name)),
		value_off = u32(len(h.bytes) + len(f.name)),
		value_len = u32(len(f.value)),
	}
	_, e1 := append(&h.bytes, f.name)
	_, e2 := append(&h.bytes, f.value)
	_, e3 := append(&h.spans, span)
	if e1 != nil || e2 != nil || e3 != nil {
		h.too_large = true
	}
}

// conn_teardown runs on the reader thread when reading stops: it drains and
// stops the writer, closes the transport, fails all streams and drops the
// reader's reference.
@(private = "file")
conn_teardown :: proc(c: ^Conn) {
	sync.atomic_store(&c.closing, true)

	// Let the writer flush what is queued (e.g. GOAWAY), then stop it.
	sync.mutex_lock(&c.q_mu)
	c.q_closed = true
	sync.cond_broadcast(&c.q_cond)
	sync.cond_broadcast(&c.q_space)
	sync.mutex_unlock(&c.q_mu)
	thread.join(c.writer)
	thread.destroy(c.writer)
	c.writer = nil
	c.transport.close(c.transport.data)

	sync.mutex_lock(&c.mu)
	c.closed = true
	if c.close_reason == "" {
		c.close_reason = "connection closed"
	}
	for _, s in c.streams {
		s.conn_lost = true
		sync.cond_broadcast(&s.cond)
	}
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mu)

	switch c.role {
	case .Server:
		server_on_conn_closed(c)
	case .Client:
		client_on_conn_closed(c)
	}
	conn_release(c)
}
