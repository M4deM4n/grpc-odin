package grpc

import "base:runtime"
import vmem "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../http2"
import pb "../protobuf"

Method_Kind :: enum u8 {
	Unary,
	Client_Streaming,
	Server_Streaming,
	Bidi_Streaming,
}

// Handler_Proc runs one RPC. `impl` is the pointer given to
// server_register. The returned status is sent to the client.
Handler_Proc :: #type proc(impl: rawptr, call: ^Server_Call) -> Status

Method_Handler :: struct {
	name:    string, // method name, e.g. "SayHello"
	kind:    Method_Kind,
	handler: Handler_Proc,
}

// Service_Desc describes a service implementation; generated code provides
// one per service (<Service>_SERVICE_DESC).
Service_Desc :: struct {
	name:    string, // fully qualified, e.g. "helloworld.Greeter"
	methods: []Method_Handler,
}

Server_Options :: struct {
	conn:                Conn_Options,
	// Maximum number of handler threads (concurrently running RPCs across
	// all connections). Streams beyond it are refused (REFUSED_STREAM).
	max_workers:         int,
	// Idle handler threads exit after this long.
	worker_idle_timeout: time.Duration,
	// Transport read poll interval and write timeout.
	read_poll:           time.Duration,
	write_timeout:       time.Duration,
	// Maximum simultaneous connections; further ones are closed at once.
	max_connections:     int,
}

DEFAULT_MAX_WORKERS :: 1024
DEFAULT_MAX_CONNECTIONS :: 4096
// Servers probe idle clients with keepalive PINGs (conn.keepalive_time;
// negative disables), so half-open connections are eventually reclaimed.
DEFAULT_SERVER_KEEPALIVE_TIME :: 2 * time.Hour
DEFAULT_WORKER_IDLE_TIMEOUT :: 30 * time.Second

@(private)
Registered_Method :: struct {
	impl:    rawptr,
	kind:    Method_Kind,
	handler: Handler_Proc,
}

Server :: struct {
	opts:         Server_Options,
	allocator:    runtime.Allocator,
	mu:           sync.Mutex,
	cond:         sync.Cond, // conns/calls drained
	methods:      map[string]Registered_Method, // by "/service/method"
	services:     [dynamic]string, // registered service names, in order
	listener:     net.TCP_Socket,
	listening:    bool,
	acceptor:     ^thread.Thread,
	conns:        map[^Conn]bool,
	live_conns:   int, // created and not yet freed
	stopping:     bool,
	active_calls: int,
	free_calls:   ^Server_Call,
	// Worker pool (guarded by mu).
	queue_head:   ^Server_Call,
	queue_tail:   ^Server_Call,
	queued:       int,
	workers:      int,
	idle_workers: int,
	work_cond:    sync.Cond,
}

// Server_Call is one RPC on the server. Handlers receive it and use the
// server_* procedures. The call (and its allocator) is only valid until the
// handler returns.
Server_Call :: struct {
	stream:       Stream,
	server:       ^Server,
	method:       Registered_Method,
	path:         string, // points into path_buf
	path_buf:     [128]u8,
	path_heap:    []u8,
	authority:    string, // in the call arena, or empty
	metadata:     Metadata_Storage,
	md_allocator: runtime.Allocator, // owner of `metadata`
	send_buf:     [dynamic]u8, // reused encode buffer (server allocator)
	deadline:     time.Time,
	arena:        vmem.Arena,
	arena_ready:  bool,
	allocator:    runtime.Allocator,
	// Set by the reader when the request is rejected before the handler.
	early_status: Status,
	http_status:  int, // non-zero: reply with this HTTP status only
	// Response state (handler thread only).
	headers_sent: bool,
	trailer_md:   []Metadata_Entry, // copied into the call arena
	next:         ^Server_Call, // free list / work queue
}

// -----------------------------------------------------------------------------
// Setup
// -----------------------------------------------------------------------------

server_init :: proc(s: ^Server, opts := Server_Options{}, allocator := context.allocator) {
	s^ = {}
	s.opts = opts
	if s.opts.max_workers <= 0 {
		s.opts.max_workers = DEFAULT_MAX_WORKERS
	}
	if s.opts.worker_idle_timeout <= 0 {
		s.opts.worker_idle_timeout = DEFAULT_WORKER_IDLE_TIMEOUT
	}
	if s.opts.read_poll <= 0 {
		s.opts.read_poll = DEFAULT_READ_POLL
	}
	if s.opts.write_timeout <= 0 {
		s.opts.write_timeout = DEFAULT_WRITE_TIMEOUT
	}
	if s.opts.max_connections <= 0 {
		s.opts.max_connections = DEFAULT_MAX_CONNECTIONS
	}
	if s.opts.conn.keepalive_time == 0 {
		s.opts.conn.keepalive_time = DEFAULT_SERVER_KEEPALIVE_TIME
	}
	s.allocator = allocator
	s.methods = make(map[string]Registered_Method, allocator)
	s.services = make([dynamic]string, allocator)
	s.conns = make(map[^Conn]bool, allocator)
}

// server_register adds every method of a service. Must be called before
// server_start. Returns false (registering nothing) if the server is
// already serving, or the service or one of its methods is already
// registered.
server_register :: proc(s: ^Server, desc: ^Service_Desc, impl: rawptr) -> bool {
	// Handler threads read the registry without locking once serving.
	if s.listening {
		return false
	}
	for name in s.services {
		if name == desc.name {
			return false
		}
	}
	for m, i in desc.methods {
		path := strings.concatenate({"/", desc.name, "/", m.name}, context.temp_allocator)
		if path in s.methods {
			return false
		}
		for other in desc.methods[:i] {
			if other.name == m.name {
				return false
			}
		}
	}
	append(&s.services, strings.clone(desc.name, s.allocator))
	for m in desc.methods {
		path := strings.concatenate({"/", desc.name, "/", m.name}, s.allocator)
		if path in s.methods {
			delete(path, s.allocator)
			return false
		}
		s.methods[path] = {impl, m.kind, m.handler}
	}
	return true
}

// server_services returns the fully qualified names of the registered
// services (valid until server_destroy).
server_services :: proc(s: ^Server) -> []string {
	return s.services[:]
}

// server_start listens on `address` ("host:port"; port 0 picks a free
// port) and accepts connections on a background thread. Returns the bound
// endpoint.
server_start :: proc(s: ^Server, address: string) -> (bound: net.Endpoint, ok: bool) {
	ep, parsed := net.parse_endpoint(address)
	if !parsed {
		return {}, false
	}
	sock, err := net.listen_tcp(ep)
	if err != nil {
		return {}, false
	}
	bound, err = net.bound_endpoint(sock)
	if err != nil {
		net.close(sock)
		return {}, false
	}
	s.listener = sock
	s.listening = true
	s.acceptor = thread.create(accept_main)
	if s.acceptor == nil {
		net.close(sock)
		s.listening = false
		return {}, false
	}
	s.acceptor.data = s
	thread.start(s.acceptor)
	return bound, true
}

@(private = "file")
accept_main :: proc(t: ^thread.Thread) {
	s := (^Server)(t.data)
	for {
		sock, _, err := net.accept_tcp(s.listener)
		if err != nil {
			sync.mutex_lock(&s.mu)
			stopping := s.stopping
			sync.mutex_unlock(&s.mu)
			if stopping {
				return
			}
			// Transient failures (e.g. out of descriptors): back off briefly.
			time.sleep(10 * time.Millisecond)
			continue
		}
		transport, t_ok := tcp_transport(sock, s.opts.read_poll, s.opts.write_timeout)
		if !t_ok {
			net.close(sock)
			continue
		}
		sync.mutex_lock(&s.mu)
		if s.stopping {
			sync.mutex_unlock(&s.mu)
			net.close(sock)
			return
		}
		if s.live_conns >= s.opts.max_connections {
			sync.mutex_unlock(&s.mu)
			net.close(sock)
			continue
		}
		c, c_ok := conn_create(.Server, transport, s.opts.conn, s, s.allocator)
		if !c_ok {
			sync.mutex_unlock(&s.mu)
			net.close(sock)
			continue
		}
		conn_retain(c) // the server's reference, dropped in server_on_conn_closed
		s.conns[c] = true
		s.live_conns += 1
		if !conn_start(c) {
			delete_key(&s.conns, c)
			sync.mutex_unlock(&s.mu)
			net.close(sock)
			conn_release(c)
			conn_release(c)
			continue
		}
		sync.mutex_unlock(&s.mu)
	}
}

// server_shutdown stops the server: no new connections or RPCs are
// accepted (GOAWAY is sent), in-flight RPCs get up to `grace` to finish,
// then all connections are closed and all handlers are waited for.
server_shutdown :: proc(s: ^Server, grace: time.Duration = 5 * time.Second) {
	sync.mutex_lock(&s.mu)
	if s.stopping {
		// Another thread is shutting down; wait for it to finish.
		for len(s.conns) > 0 || s.live_conns > 0 || s.active_calls > 0 || s.workers > 0 || s.listening {
			sync.cond_wait(&s.cond, &s.mu)
		}
		sync.mutex_unlock(&s.mu)
		return
	}
	s.stopping = true
	sync.cond_broadcast(&s.work_cond)
	conns := make([dynamic]^Conn, 0, len(s.conns), context.temp_allocator)
	for c in s.conns {
		conn_retain(c)
		append(&conns, c)
	}
	sync.mutex_unlock(&s.mu)

	if s.listening {
		net.close(s.listener)
		thread.join(s.acceptor)
		thread.destroy(s.acceptor)
		sync.mutex_lock(&s.mu)
		s.listening = false
		sync.cond_broadcast(&s.cond)
		sync.mutex_unlock(&s.mu)
	}

	// Graceful GOAWAY: streams after the last processed one are refused.
	for c in conns {
		send_goaway(c, .No_Error)
	}
	deadline := time.time_add(time.now(), grace)
	sync.mutex_lock(&s.mu)
	for s.active_calls > 0 {
		if !wait_locked(&s.cond, &s.mu, deadline) {
			break
		}
	}
	sync.mutex_unlock(&s.mu)

	// Force-close what remains: handlers see their streams fail.
	for c in conns {
		conn_shutdown(c, "server shutting down")
		conn_release(c)
	}
	// Wait until every connection is freed and every handler thread is done,
	// so that nothing references the server after shutdown returns.
	sync.mutex_lock(&s.mu)
	for len(s.conns) > 0 || s.live_conns > 0 || s.active_calls > 0 || s.workers > 0 {
		sync.cond_wait(&s.cond, &s.mu)
	}
	sync.mutex_unlock(&s.mu)
}

@(private)
server_on_conn_freed :: proc(s: ^Server) {
	sync.mutex_lock(&s.mu)
	s.live_conns -= 1
	sync.cond_broadcast(&s.cond)
	sync.mutex_unlock(&s.mu)
}

// server_destroy frees the server. Call server_shutdown first.
server_destroy :: proc(s: ^Server) {
	for path in s.methods {
		delete(path, s.allocator)
	}
	delete(s.methods)
	for name in s.services {
		delete(name, s.allocator)
	}
	delete(s.services)
	delete(s.conns)
	for s.free_calls != nil {
		call := s.free_calls
		s.free_calls = call.next
		if call.arena_ready {
			vmem.arena_destroy(&call.arena)
		}
		delete(call.send_buf)
		free(call, s.allocator)
	}
	s^ = {}
}

@(private)
send_goaway :: proc(c: ^Conn, code: http2.Error_Code) {
	sync.mutex_lock(&c.mu)
	if c.goaway_sent || c.closed {
		sync.mutex_unlock(&c.mu)
		return
	}
	c.goaway_sent = true
	last := c.last_peer_stream
	empty := len(c.streams) == 0
	sync.mutex_unlock(&c.mu)
	if queue_lock_urgent(c) {
		http2.append_goaway(&c.q, last, code)
		queue_unlock(c)
	}
	if empty {
		conn_shutdown(c, "GOAWAY sent")
	}
}

@(private)
server_on_conn_closed :: proc(c: ^Conn) {
	s := (^Server)(c.owner)
	sync.mutex_lock(&s.mu)
	if c in s.conns {
		delete_key(&s.conns, c)
		sync.mutex_unlock(&s.mu)
		conn_release(c)
		sync.mutex_lock(&s.mu)
	}
	sync.cond_broadcast(&s.cond)
	sync.mutex_unlock(&s.mu)
}

// -----------------------------------------------------------------------------
// Incoming requests (reader thread)
// -----------------------------------------------------------------------------

@(private)
server_on_headers :: proc(c: ^Conn, id: u32, end_stream: bool) {
	s := (^Server)(c.owner)

	sync.mutex_lock(&c.mu)
	if existing, ok := c.streams[id]; ok {
		// gRPC clients send no trailers; a second header block (trailers)
		// must end the stream and carry no pseudo-headers (§8.1).
		pseudo := false
		for i in 0 ..< len(c.fields.spans) {
			name, _ := field_at(&c.fields, i)
			if len(name) > 0 && name[0] == ':' {
				pseudo = true
			}
		}
		if !end_stream || existing.remote_closed || pseudo {
			sync.mutex_unlock(&c.mu)
			reset_stream_id(c, id, .Protocol_Error)
			return
		}
		existing.remote_closed = true
		sync.cond_broadcast(&existing.cond)
		sync.mutex_unlock(&c.mu)
		return
	}
	if id % 2 == 0 {
		sync.mutex_unlock(&c.mu)
		conn_error(c, .Protocol_Error, "client opened an even-numbered stream")
		return
	}
	if id <= c.last_peer_stream {
		// A stream that was already closed.
		sync.mutex_unlock(&c.mu)
		http2.append_rst_stream(&c.ctrl, id, .Stream_Closed)
		return
	}
	c.last_peer_stream = id
	refuse := c.goaway_sent || c.active_streams >= c.opts.max_concurrent_streams
	if !refuse {
		c.active_streams += 1 // taken over by the stream, or undone below
	}
	sync.mutex_unlock(&c.mu)
	if refuse {
		if note_abuse(c) {
			http2.append_rst_stream(&c.ctrl, id, .Refused_Stream)
		}
		return
	}

	call, malformed := prepare_call(s, c, end_stream)
	if malformed || call == nil {
		sync.mutex_lock(&c.mu)
		c.active_streams -= 1
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mu)
		if call != nil {
			release_call_storage(call)
			return_call(s, call)
		}
		if !note_abuse(c) {
			return
		}
		http2.append_rst_stream(&c.ctrl, id, .Protocol_Error if malformed else .Refused_Stream)
		return
	}

	sync.mutex_lock(&c.mu)
	stream_init_locked(c, &call.stream, id)
	if end_stream {
		call.stream.remote_closed = true
	}
	sync.mutex_unlock(&c.mu)

	if !submit_call(s, call) {
		release_call_storage(call)
		stream_unregister(&call.stream)
		return_call(s, call)
		http2.append_rst_stream(&c.ctrl, id, .Refused_Stream)
	}
}

// prepare_call validates the request header block (c.fields) and builds a
// call. `malformed` requests (RFC 9113 §8.1.1) are answered with
// RST_STREAM; requests that are well-formed HTTP/2 but not acceptable gRPC
// get a call whose early_status/http_status is sent by a worker.
@(private = "file")
prepare_call :: proc(s: ^Server, c: ^Conn, end_stream: bool) -> (call: ^Server_Call, malformed: bool) {
	h := &c.fields
	method, scheme, path, authority, content_type, timeout, encoding: string
	have_method, have_scheme, have_path, have_authority, have_ct, have_timeout, have_encoding := false, false, false, false, false, false, false
	regular_seen := false
	for i in 0 ..< len(h.spans) {
		name, value := field_at(h, i)
		if has_uppercase(name) {
			return nil, true
		}
		if len(name) > 0 && name[0] == ':' {
			if regular_seen {
				return nil, true
			}
			switch name {
			case ":method":
				if have_method {return nil, true}
				method, have_method = value, true
			case ":scheme":
				if have_scheme {return nil, true}
				scheme, have_scheme = value, true
			case ":path":
				if have_path {return nil, true}
				path, have_path = value, true
			case ":authority":
				if have_authority {return nil, true}
				authority, have_authority = value, true
			case:
				return nil, true
			}
			continue
		}
		regular_seen = true
		switch name {
		case "te":
			if value != "trailers" {return nil, true}
		case "content-type":
			content_type, have_ct = value, true
		case "grpc-timeout":
			timeout, have_timeout = value, true
		case "grpc-encoding":
			encoding, have_encoding = value, true
		case:
			if is_connection_header(name) {
				return nil, true
			}
		}
	}
	if !have_method || !have_scheme || !have_path || len(path) == 0 {
		return nil, true
	}
	_ = scheme

	call = take_call(s)
	if call == nil {
		return nil, false
	}
	call.server = s
	call.stream.conn = c
	call.allocator = vmem.arena_allocator(&call.arena)
	set_call_path(call, path)

	md, bad_bin, md_ok := metadata_build(h, include_request_metadata, c.allocator)
	if !md_ok {
		call.early_status = {.Resource_Exhausted, "out of memory reading request metadata"}
	}
	call.metadata = md
	call.md_allocator = c.allocator
	// The handler has not started, so the reader may use the call arena.
	call.authority = strings.clone(authority, call.allocator) if have_authority else ""

	switch {
	case h.too_large:
		call.early_status = {.Resource_Exhausted, "request metadata exceeds the server's limit"}
	case method != "POST":
		call.http_status = 405
	case !have_ct || !is_grpc_content_type(content_type):
		call.http_status = 415
	case have_encoding && encoding != "identity":
		call.early_status = {.Unimplemented, "unsupported grpc-encoding (only identity is supported)"}
	case bad_bin:
		call.early_status = {.Internal, "malformed binary metadata"}
	case:
		if have_timeout {
			d, t_ok := parse_timeout(timeout)
			if !t_ok {
				call.early_status = {.Internal, "malformed grpc-timeout"}
				break
			}
			call.deadline = deadline_after(d)
		}
		m, found := s.methods[path]
		if !found {
			call.early_status = {.Unimplemented, "unknown method"}
			break
		}
		call.method = m
	}
	return call, false
}

@(private = "file")
include_request_metadata :: proc(name: string) -> bool {
	if len(name) > 0 && name[0] == ':' {
		return false // :authority is exposed through call_authority
	}
	switch name {
	// "host" is allowed (RFC 9113 §8.3.1) but redundant with :authority.
	case "content-type", "te", "grpc-timeout", "grpc-encoding", "grpc-accept-encoding", "host":
		return false
	}
	return true
}

@(private = "file")
set_call_path :: proc(call: ^Server_Call, path: string) {
	if len(path) <= len(call.path_buf) {
		n := copy(call.path_buf[:], path)
		call.path = string(call.path_buf[:n])
		return
	}
	buf, err := make([]u8, len(path), call.server.allocator)
	if err != nil {
		call.path = ""
		return
	}
	copy(buf, path)
	call.path_heap = buf
	call.path = string(buf)
}

// -----------------------------------------------------------------------------
// Call pool and worker pool
// -----------------------------------------------------------------------------

@(private = "file")
take_call :: proc(s: ^Server) -> ^Server_Call {
	sync.mutex_lock(&s.mu)
	call := s.free_calls
	if call != nil {
		s.free_calls = call.next
	}
	s.active_calls += 1
	sync.mutex_unlock(&s.mu)
	if call == nil {
		err: runtime.Allocator_Error
		call, err = new(Server_Call, s.allocator)
		if err != nil {
			sync.mutex_lock(&s.mu)
			s.active_calls -= 1
			sync.cond_broadcast(&s.cond)
			sync.mutex_unlock(&s.mu)
			return nil
		}
	}
	if !call.arena_ready {
		if vmem.arena_init_growing(&call.arena) != nil {
			free(call, s.allocator)
			sync.mutex_lock(&s.mu)
			s.active_calls -= 1
			sync.cond_broadcast(&s.cond)
			sync.mutex_unlock(&s.mu)
			return nil
		}
		call.arena_ready = true
	}
	return call
}

// release_call_storage frees what a call owns besides its pooled memory.
// It must not touch the connection, which may already be gone.
@(private = "file")
release_call_storage :: proc(call: ^Server_Call) {
	s := call.server
	metadata_destroy(&call.metadata, call.md_allocator)
	if call.path_heap != nil {
		delete(call.path_heap, s.allocator)
	}
	vmem.arena_free_all(&call.arena)
}

// Pooled calls keep their send buffer unless it grew unusually large.
MAX_POOLED_SEND_BUFFER :: 1 << 20

@(private = "file")
return_call :: proc(s: ^Server, call: ^Server_Call) {
	arena := call.arena
	ready := call.arena_ready
	send_buf := call.send_buf
	if cap(send_buf) > MAX_POOLED_SEND_BUFFER {
		delete(send_buf)
		send_buf = {}
	}
	clear(&send_buf)
	call^ = {}
	call.arena = arena
	call.arena_ready = ready
	call.send_buf = send_buf
	sync.mutex_lock(&s.mu)
	call.next = s.free_calls
	s.free_calls = call
	s.active_calls -= 1
	sync.cond_broadcast(&s.cond)
	sync.mutex_unlock(&s.mu)
}

// submit_call hands a call to an idle worker, starting a new worker if
// none is idle. Returns false when the worker limit is reached.
@(private = "file")
submit_call :: proc(s: ^Server, call: ^Server_Call) -> bool {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.stopping {
		return false
	}
	if s.idle_workers <= s.queued {
		if s.workers >= s.opts.max_workers {
			return false
		}
		// Self-cleaning thread: allocated from the heap, not the server's
		// allocator, since it frees itself after the server may be gone.
		t: ^thread.Thread
		{
			context.allocator = runtime.heap_allocator()
			t = thread.create(worker_main)
		}
		if t == nil {
			return false
		}
		t.data = s
		t.flags += {.Self_Cleanup}
		s.workers += 1
		s.idle_workers += 1
		thread.start(t)
	}
	call.next = nil
	if s.queue_tail == nil {
		s.queue_head = call
	} else {
		s.queue_tail.next = call
	}
	s.queue_tail = call
	s.queued += 1
	sync.cond_signal(&s.work_cond)
	return true
}

@(private = "file")
worker_main :: proc(t: ^thread.Thread) {
	s := (^Server)(t.data)
	sync.mutex_lock(&s.mu)
	for {
		for s.queue_head == nil && !s.stopping {
			if !sync.cond_wait_with_timeout(&s.work_cond, &s.mu, s.opts.worker_idle_timeout) && s.queue_head == nil {
				break
			}
		}
		call := s.queue_head
		if call == nil {
			break
		}
		s.queue_head = call.next
		if s.queue_head == nil {
			s.queue_tail = nil
		}
		s.queued -= 1
		s.idle_workers -= 1
		sync.mutex_unlock(&s.mu)

		run_call(call)

		sync.mutex_lock(&s.mu)
		s.idle_workers += 1
	}
	s.idle_workers -= 1
	s.workers -= 1
	sync.cond_broadcast(&s.cond)
	sync.mutex_unlock(&s.mu)
}

@(private = "file")
run_call :: proc(call: ^Server_Call) {
	// Handlers allocate from the call arena by default (temporaries too),
	// so nothing accumulates on the long-lived worker thread.
	context.allocator = call.allocator
	context.temp_allocator = call.allocator
	switch {
	case call.http_status != 0:
		buf: [4]u8
		status_text := format_http_status(call.http_status, buf[:])
		stream_send_headers(&call.stream, {{":status", status_text, .Incremental}}, nil, true)
		finish_stream(call)
	case call.early_status.code != .OK:
		finish_call(call, call.early_status)
	case:
		st := call.method.handler(call.method.impl, call)
		// Once the deadline has passed the RPC failed with DEADLINE_EXCEEDED,
		// whatever the handler reports (it typically bails out with
		// CANCELLED after call_is_cancelled turned true).
		if deadline_passed(call.deadline) {
			st = {.Deadline_Exceeded, "deadline exceeded"}
		}
		finish_call(call, st)
	}
	// Release the call's own storage first: unregistering may drop the
	// last reference to the connection and free it.
	s := call.server
	release_call_storage(call)
	stream_unregister(&call.stream)
	return_call(s, call)
}

@(private = "file")
format_http_status :: proc(code: int, buf: []u8) -> string {
	buf[0] = u8('0' + code / 100)
	buf[1] = u8('0' + code / 10 % 10)
	buf[2] = u8('0' + code % 10)
	return string(buf[:3])
}

// finish_call sends the final status (trailers, or a trailers-only
// response if nothing was sent yet).
@(private = "file")
finish_call :: proc(call: ^Server_Call, st: Status) {
	sbuf: [16]u8
	code_text := format_status_code(st.code, sbuf[:])
	msg: [dynamic]u8
	msg.allocator = call.allocator
	if st.message != "" {
		append_percent_encoded(&msg, st.message)
	}
	fixed_buf: [5]Header_Out
	fixed := fixed_buf[:0]
	if !call.headers_sent {
		fixed_buf[0] = {":status", "200", .Incremental}
		fixed_buf[1] = {"content-type", "application/grpc", .Incremental}
		fixed = fixed_buf[:2]
	}
	fixed_buf[len(fixed)] = {"grpc-status", code_text, .Incremental}
	fixed = fixed_buf[:len(fixed) + 1]
	if len(msg) > 0 {
		fixed_buf[len(fixed)] = {"grpc-message", string(msg[:]), .Without}
		fixed = fixed_buf[:len(fixed) + 1]
	}
	if call.early_status.code == .Unimplemented && strings.has_prefix(call.early_status.message, "unsupported grpc-encoding") {
		fixed_buf[len(fixed)] = {"grpc-accept-encoding", "identity", .Incremental}
		fixed = fixed_buf[:len(fixed) + 1]
	}
	sync.mutex_lock(&call.stream.conn.mu)
	reset := call.stream.reset || call.stream.conn_lost
	sync.mutex_unlock(&call.stream.conn.mu)
	if !reset {
		if sent := stream_send_headers(&call.stream, fixed, call.trailer_md, true); sent.code != .OK {
			// Typically the trailers exceed the client's header list limit:
			// report INTERNAL without metadata, or failing that reset.
			n := 0 if call.headers_sent else 2
			fixed_buf[n] = {"grpc-status", "13", .Incremental}
			fixed_buf[n + 1] = {"grpc-message", "response%20metadata%20could%20not%20be%20sent", .Without}
			if stream_send_headers(&call.stream, fixed_buf[:n + 2], nil, true).code != .OK {
				stream_send_reset(&call.stream, .Internal_Error)
			}
		}
		call.headers_sent = true
	}
	finish_stream(call)
}

// finish_stream ends the client's half of the stream if it is still open:
// after a complete response the server tells the client to stop sending
// with RST_STREAM(NO_ERROR) (RFC 9113 §8.1).
@(private = "file")
finish_stream :: proc(call: ^Server_Call) {
	c := call.stream.conn
	sync.mutex_lock(&c.mu)
	open := !call.stream.remote_closed && !call.stream.reset
	sync.mutex_unlock(&c.mu)
	if open {
		stream_send_reset(&call.stream, .No_Error)
	}
}

@(private)
format_status_code :: proc(code: Status_Code, buf: []u8) -> string {
	v := u32(code)
	i := len(buf)
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	return string(buf[i:])
}

// -----------------------------------------------------------------------------
// Handler API
// -----------------------------------------------------------------------------

// call_metadata returns the request metadata (valid during the handler).
call_metadata :: proc(call: ^Server_Call) -> []Metadata_Entry {
	return call.metadata.entries
}

// call_method returns the full method path, e.g. "/helloworld.Greeter/SayHello".
call_method :: proc(call: ^Server_Call) -> string {
	return call.path
}

// call_authority returns the request's :authority, if any.
call_authority :: proc(call: ^Server_Call) -> string {
	return call.authority
}

// call_deadline returns the client's deadline, if it set one.
call_deadline :: proc(call: ^Server_Call) -> (deadline: time.Time, ok: bool) {
	return call.deadline, call.deadline != {}
}

// call_allocator returns the per-call arena, freed when the handler returns.
// Decoded request messages live in it.
call_allocator :: proc(call: ^Server_Call) -> runtime.Allocator {
	return call.allocator
}

// call_is_cancelled reports whether the RPC can no longer succeed: the
// client cancelled or reset it, the connection was lost, or the deadline
// passed. Long-running handlers should check it periodically.
call_is_cancelled :: proc(call: ^Server_Call) -> bool {
	if deadline_passed(call.deadline) {
		return true
	}
	c := call.stream.conn
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return call.stream.reset || call.stream.conn_lost
}

// server_send_header sends the response headers with `md` now. Optional:
// headers are sent automatically with the first message or the status.
server_send_header :: proc(call: ^Server_Call, md: []Metadata_Entry = nil) -> Status {
	if call.headers_sent {
		return {.Internal, "response headers already sent"}
	}
	if st := check_outgoing_metadata(md); st.code != .OK {
		return st
	}
	st := stream_send_headers(&call.stream, {{":status", "200", .Incremental}, {"content-type", "application/grpc", .Incremental}}, md, false, call.deadline)
	if st.code == .OK {
		call.headers_sent = true
	}
	return st
}

// server_set_trailer sets metadata sent with the status. It is copied, so
// it may point to temporary memory.
server_set_trailer :: proc(call: ^Server_Call, md: []Metadata_Entry) -> Status {
	if st := check_outgoing_metadata(md); st.code != .OK {
		return st
	}
	copied, err := make([]Metadata_Entry, len(md), call.allocator)
	if err != nil {
		return {.Resource_Exhausted, "out of memory"}
	}
	for e, i in md {
		copied[i] = {strings.clone(e.key, call.allocator), strings.clone(e.value, call.allocator)}
	}
	call.trailer_md = copied
	return {}
}

// server_send sends one response message.
server_send :: proc(call: ^Server_Call, msg: rawptr, codec: ^pb.Message_Codec) -> Status {
	if !call.headers_sent {
		if st := server_send_header(call); st.code != .OK {
			return st
		}
	}
	// The encode buffer is reused for every message of the call (and kept
	// with the pooled call): sending copies the bytes into the queue.
	if call.send_buf.allocator.procedure == nil {
		call.send_buf.allocator = call.server.allocator
	}
	buf, st := encode_message_into(&call.send_buf, msg, codec, call.stream.conn.opts.max_send_message_size)
	if st.code != .OK {
		return st
	}
	return stream_send_data(&call.stream, buf, false, call.deadline)
}

// server_recv receives the next request message into msg, decoded with the
// call allocator (zero-copy: strings point into the received buffer).
// Returns false with an OK status when the client has finished sending.
//
// Everything received lives until the handler returns. Long-running
// streaming handlers should use server_recv_with and an allocator they
// reset between messages, to keep memory bounded.
server_recv :: proc(call: ^Server_Call, msg: rawptr, codec: ^pb.Message_Codec) -> (got: bool, st: Status) {
	return server_recv_with(call, msg, codec, call.allocator)
}

// server_recv_with is server_recv decoding into `allocator`: the message
// (and the buffer its strings point into) live as long as that allocator's
// memory, typically an arena the handler frees after each message.
server_recv_with :: proc(call: ^Server_Call, msg: rawptr, codec: ^pb.Message_Codec, allocator: runtime.Allocator) -> (got: bool, st: Status) {
	data, result, rst := stream_recv_message(&call.stream, call.stream.conn.opts.max_recv_message_size, allocator, call.deadline)
	switch result {
	case .End:
		return false, {}
	case .Failed, .Rejected:
		// The handler returns this status; finishing the call sends it and
		// then stops the client with RST_STREAM(NO_ERROR).
		return false, rst
	case .Message:
	}
	if err := pb.unmarshal(msg, codec, data, allocator, {alias_input = true}); err != .None {
		return false, {.Internal, "failed to decode the request message"}
	}
	return true, {}
}

// server_recv_unary receives the single request of a unary or
// server-streaming RPC: exactly one message followed by END_STREAM.
server_recv_unary :: proc(call: ^Server_Call, msg: rawptr, codec: ^pb.Message_Codec) -> Status {
	got, st := server_recv(call, msg, codec)
	if st.code != .OK {
		return st
	}
	if !got {
		return {.Internal, "request message missing"}
	}
	data, result, rst := stream_recv_message(&call.stream, 0, call.allocator, call.deadline)
	_ = data
	switch result {
	case .End:
		return {}
	case .Rejected:
		if rst.code == .Resource_Exhausted {
			return {.Internal, "more than one request message for a unary method"}
		}
		return rst
	case .Failed:
		return rst
	case .Message:
	}
	return {.Internal, "more than one request message for a unary method"}
}

// encode_message_into encodes msg with its 5-octet gRPC prefix into dst
// (resized to fit) and returns the framed bytes.
@(private)
encode_message_into :: proc(dst: ^[dynamic]u8, msg: rawptr, codec: ^pb.Message_Codec, max_size: int) -> ([]u8, Status) {
	n := codec.size(msg)
	if n > max_size {
		return nil, {.Resource_Exhausted, "message larger than the maximum send size"}
	}
	if resize(dst, GRPC_MESSAGE_HEADER_SIZE + n) != nil {
		return nil, {.Resource_Exhausted, "out of memory encoding a message"}
	}
	buf := dst[:]
	if _, enc_err := pb.encode_into(msg, codec, buf[GRPC_MESSAGE_HEADER_SIZE:]); enc_err != .None {
		return nil, {.Internal, "failed to encode a message"}
	}
	frame_message(buf, n)
	return buf, {}
}
