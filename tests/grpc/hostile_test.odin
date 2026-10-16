package grpc_test

// Regression tests for the transport review: lifetime bugs, limits and
// hostile peers (driven through raw sockets speaking HTTP/2 directly).

import "base:runtime"
import "core:mem"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "grpc:grpc"
import "grpc:http2"
import "gen"

// -----------------------------------------------------------------------------
// Poisoning allocator: freed memory is overwritten, so use-after-free reads
// garbage (and usually crashes) instead of silently working.
// -----------------------------------------------------------------------------

Poison :: struct {
	backing: runtime.Allocator,
	mu:      sync.Mutex,
	sizes:   map[rawptr]int, // live allocations (heap allocator)
}

poison_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	p := (^Poison)(data)
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	if p.sizes == nil {
		p.sizes = make(map[rawptr]int, runtime.heap_allocator())
	}
	if (mode == .Free || mode == .Resize || mode == .Resize_Non_Zeroed) && old_memory != nil {
		if n, ok := p.sizes[old_memory]; ok {
			if mode == .Free {
				mem.set(old_memory, 0xdd, n)
			}
			delete_key(&p.sizes, old_memory)
		}
	}
	res, err := p.backing.procedure(p.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err == nil && res != nil && mode != .Free && mode != .Free_All {
		p.sizes[raw_data(res)] = len(res)
	}
	return res, err
}

// -----------------------------------------------------------------------------
// Raw HTTP/2 peer
// -----------------------------------------------------------------------------

raw_connect :: proc(addr: string) -> (net.TCP_Socket, bool) {
	ep, ok := net.parse_endpoint(addr)
	if !ok {
		return {}, false
	}
	sock, err := net.dial_tcp(ep)
	if err != nil {
		return {}, false
	}
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	return sock, true
}

raw_send :: proc(sock: net.TCP_Socket, b: []u8) -> bool {
	_, err := net.send_tcp(sock, b)
	return err == nil
}

// read_until_closed reads until EOF (or timeout) and returns the GOAWAY
// error code seen, if any, and whether the peer closed the connection.
read_until_closed :: proc(sock: net.TCP_Socket) -> (goaway: http2.Error_Code, saw_goaway: bool, closed: bool) {
	buf := make([dynamic]u8, context.temp_allocator)
	tmp: [16 << 10]u8
	for {
		n, err := net.recv_tcp(sock, tmp[:])
		if err != nil || n == 0 {
			closed = err == nil || err != .Timeout
			break
		}
		append(&buf, ..tmp[:n])
	}
	rest := buf[:]
	for len(rest) >= http2.FRAME_HEADER_SIZE {
		h := http2.decode_frame_header(rest)
		if len(rest) < http2.FRAME_HEADER_SIZE + int(h.length) {
			break
		}
		payload := rest[http2.FRAME_HEADER_SIZE:][:h.length]
		if h.type == u8(http2.Frame_Type.Goaway) {
			goaway = http2.parse_goaway(payload).code
			saw_goaway = true
		}
		rest = rest[http2.FRAME_HEADER_SIZE + int(h.length):]
	}
	return
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

// A client that disconnects while its handler runs must not make the server
// touch the freed connection (use-after-free found in review).
@(test)
test_client_disconnect_mid_handler :: proc(t: ^testing.T) {
	poison := Poison {
		backing = context.allocator,
	}
	defer delete(poison.sizes)
	alloc := runtime.Allocator{poison_proc, &poison}

	// The handler ignores cancellation, so it finishes only after the
	// connection was torn down and the stream holds its last reference.
	oblivious :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, req: ^gen.Echo, resp: ^gen.Echo) -> grpc.Status {
		time.sleep(time.Duration(req.sleep_ms) * time.Millisecond)
		return {}
	}
	impl := gen.Tester_Server {
		unary = oblivious,
	}
	server: grpc.Server
	grpc.server_init(&server, {}, alloc)
	gen.Tester_register(&server, &impl)
	ep, ok := grpc.server_start(&server, "127.0.0.1:0")
	if !testing.expect(t, ok) {
		return
	}
	addr := net.endpoint_to_string(ep, context.temp_allocator)

	for _ in 0 ..< 2 {
		ch := grpc.channel_create(addr)
		cs, st := grpc.client_new_stream(ch, &gen.Tester_Unary_METHOD, {metadata = {{"x-a", "b"}}})
		if !testing.expect(t, st.code == .OK) {
			grpc.channel_destroy(ch)
			break
		}
		req := gen.Echo {
			sleep_ms = 1000,
		}
		grpc.client_send_last(cs, &req)
		time.sleep(50 * time.Millisecond) // the handler is now running
		grpc.client_destroy(cs)
		grpc.channel_destroy(ch) // the TCP connection closes mid-handler
	}
	// Handlers finish after their connections died; shutdown waits for them.
	grpc.server_shutdown(&server, 3 * time.Second)
	grpc.server_destroy(&server)
}

// Trailers too large for the client must still produce a status quickly
// (review: the response was dropped and the client hung).
@(test)
test_oversized_trailer_reports_internal :: proc(t: ^testing.T) {
	big_trailer :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, req: ^gen.Echo, resp: ^gen.Echo) -> grpc.Status {
		value := make([]u8, 20 << 10, grpc.call_allocator(call))
		for i in 0 ..< len(value) {
			value[i] = 'a'
		}
		grpc.server_set_trailer(call, {{"x-big", string(value)}})
		return {}
	}
	impl := gen.Tester_Server {
		unary = big_trailer,
	}
	server: grpc.Server
	grpc.server_init(&server)
	gen.Tester_register(&server, &impl)
	ep, ok := grpc.server_start(&server, "127.0.0.1:0")
	if !testing.expect(t, ok) {
		return
	}
	ch := grpc.channel_create(net.endpoint_to_string(ep, context.temp_allocator))
	req: gen.Echo
	resp: gen.Echo
	start := time.tick_now()
	st := gen.Tester_unary(ch, &req, &resp, {timeout = 5 * time.Second, allocator = context.temp_allocator})
	testing.expect_value(t, st.code, grpc.Status_Code.Internal)
	testing.expect(t, time.tick_since(start) < 2 * time.Second)
	grpc.channel_destroy(ch)
	grpc.server_shutdown(&server)
	grpc.server_destroy(&server)
}

@(test)
test_concurrent_shutdown :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	grpc.channel_destroy(f.ch)
	Shared :: struct {
		server: ^grpc.Server,
		done:   i32,
	}
	shared := Shared {
		server = &f.server,
	}
	threads: [3]^thread.Thread
	for i in 0 ..< len(threads) {
		threads[i] = thread.create_and_start_with_poly_data(&shared, proc(s: ^Shared) {
			grpc.server_shutdown(s.server, 200 * time.Millisecond)
			sync.atomic_add(&s.done, 1)
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, shared.done, 3)
	grpc.server_destroy(&f.server)
}

@(test)
test_timeout_saturation :: proc(t: ^testing.T) {
	d, ok := grpc.parse_timeout("99999999H")
	testing.expect(t, ok && d == grpc.MAX_TIMEOUT)
	d, ok = grpc.parse_timeout("2562048H")
	testing.expect(t, ok && d == grpc.MAX_TIMEOUT)
	testing.expect(t, grpc.deadline_after(grpc.MAX_TIMEOUT) == {})
	buf: [16]u8
	s := grpc.format_timeout(time.Duration(max(i64)), buf[:])
	back, back_ok := grpc.parse_timeout(s)
	testing.expectf(t, back_ok && back > 0, "format_timeout(max) = %q", s)
}

@(test)
test_handshake_timeout :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f, {conn = {handshake_timeout = 200 * time.Millisecond}})) {
		return
	}
	defer stop(&f)
	sock, ok := raw_connect(f.addr)
	if !testing.expect(t, ok) {
		return
	}
	defer net.close(sock)
	start_time := time.tick_now()
	// Send nothing: the server must give up on us.
	_, _, closed := read_until_closed(sock)
	testing.expect(t, closed)
	testing.expectf(t, time.tick_since(start_time) < 3 * time.Second, "took %v", time.tick_since(start_time))
}

@(test)
test_max_connections :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f, {max_connections = 1})) {
		return
	}
	defer stop(&f)
	// The channel's connection is the one allowed.
	req: gen.Echo
	resp: gen.Echo
	expect_ok(t, gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator}))
	sock, ok := raw_connect(f.addr)
	if !testing.expect(t, ok) {
		return
	}
	defer net.close(sock)
	_, _, closed := read_until_closed(sock)
	testing.expect(t, closed)
}

@(test)
test_ping_flood_is_cut_off :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f, {conn = {max_control_frames_per_second = 100}})) {
		return
	}
	defer stop(&f)
	sock, ok := raw_connect(f.addr)
	if !testing.expect(t, ok) {
		return
	}
	defer net.close(sock)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, http2.CLIENT_PREFACE)
	http2.append_settings(&out, {})
	for i in 0 ..< 1000 {
		http2.append_ping(&out, {u8(i), 0, 0, 0, 0, 0, 0, 0}, false)
	}
	raw_send(sock, out[:])
	code, saw, closed := read_until_closed(sock)
	testing.expect(t, saw && code == .Enhance_Your_Calm)
	testing.expect(t, closed)
}

@(test)
test_rapid_reset_is_cut_off :: proc(t: ^testing.T) {
	// HEADERS immediately followed by RST_STREAM, many times (CVE-2023-44487).
	f: Fixture
	if !testing.expect(t, start(&f, {conn = {max_control_frames_per_second = 100}})) {
		return
	}
	defer stop(&f)
	sock, ok := raw_connect(f.addr)
	if !testing.expect(t, ok) {
		return
	}
	defer net.close(sock)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, http2.CLIENT_PREFACE)
	http2.append_settings(&out, {})
	// A minimal request header block, literal without indexing:
	// :method POST (static 3), :scheme http (static 6), :path /x.
	block := []u8{0x83, 0x86, 0x04, 0x02, '/', 'x'}
	for i in 0 ..< 500 {
		id := u32(2 * i + 1)
		http2.append_headers(&out, id, block, false, http2.DEFAULT_MAX_FRAME_SIZE)
		http2.append_rst_stream(&out, id, .Cancel)
	}
	raw_send(sock, out[:])
	code, saw, closed := read_until_closed(sock)
	testing.expect(t, saw && code == .Enhance_Your_Calm)
	testing.expect(t, closed)
}

@(test)
test_keepalive_keeps_healthy_connections :: proc(t: ^testing.T) {
	// Both sides ping aggressively; RPCs keep working across idle periods.
	ka := grpc.Conn_Options {
		keepalive_time    = 100 * time.Millisecond,
		keepalive_timeout = 500 * time.Millisecond,
	}
	f: Fixture
	if !testing.expect(t, start(&f, {conn = ka}, {conn = ka})) {
		return
	}
	defer stop(&f)
	for _ in 0 ..< 3 {
		req: gen.Echo
		resp: gen.Echo
		expect_ok(t, gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator}))
		time.sleep(400 * time.Millisecond)
	}
}

@(test)
test_idle_timeout_closes_connection :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f, {conn = {idle_timeout = 100 * time.Millisecond}})) {
		return
	}
	defer stop(&f)
	req: gen.Echo
	resp: gen.Echo
	expect_ok(t, gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator}))
	time.sleep(800 * time.Millisecond)
	// The server closed the idle connection; the channel reconnects.
	expect_ok(t, gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator}))
}
