package grpc_test

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "grpc:grpc"
import "gen"

// -----------------------------------------------------------------------------
// Test server
// -----------------------------------------------------------------------------

Test_State :: struct {
	cancelled_seen: i32, // atomic: handlers that observed cancellation
	calls:          i32, // atomic
}

impl_unary :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, req: ^gen.Echo, resp: ^gen.Echo) -> grpc.Status {
	state := (^Test_State)(srv.user_data)
	sync.atomic_add(&state.calls, 1)
	if v, ok := grpc.metadata_get(grpc.call_metadata(call), "x-echo"); ok {
		md := []grpc.Metadata_Entry{{"x-echo-header", v}}
		if st := grpc.server_send_header(call, md); st.code != .OK {
			return st
		}
		trailer := []grpc.Metadata_Entry{{"x-echo-trailer", v}, {"x-blob-bin", "\x00\x01\xff"}}
		grpc.server_set_trailer(call, trailer)
	}
	if req.sleep_ms > 0 {
		end := time.time_add(time.now(), time.Duration(req.sleep_ms) * time.Millisecond)
		for time.diff(time.now(), end) > 0 {
			if grpc.call_is_cancelled(call) {
				sync.atomic_add(&state.cancelled_seen, 1)
				return {.Cancelled, "observed cancellation"}
			}
			time.sleep(5 * time.Millisecond)
		}
	}
	if req.fail_code != 0 {
		return {grpc.Status_Code(req.fail_code), req.fail_message}
	}
	resp.text = req.text
	resp.seq = req.seq + 1
	resp.payload = req.payload
	return {}
}

impl_server_stream :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, req: ^gen.Echo, stream: gen.Tester_ServerStream_Server) -> grpc.Status {
	payload := req.payload
	if req.response_bytes > 0 {
		payload = make([]u8, req.response_bytes, grpc.call_allocator(call))
	}
	for i in 0 ..< req.count {
		m := gen.Echo {
			text    = req.text,
			seq     = i,
			payload = payload,
		}
		if st := gen.Tester_ServerStream_Server_send(stream, &m); st.code != .OK {
			return st
		}
	}
	if req.fail_code != 0 {
		return {grpc.Status_Code(req.fail_code), req.fail_message}
	}
	return {}
}

impl_client_stream :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, stream: gen.Tester_ClientStream_Server, resp: ^gen.Echo) -> grpc.Status {
	total := 0
	n := 0
	for {
		m: gen.Echo
		got, st := gen.Tester_ClientStream_Server_recv(stream, &m)
		if st.code != .OK {
			return st
		}
		if !got {
			break
		}
		total += int(m.seq) + len(m.payload)
		n += 1
	}
	resp.count = i32(n)
	resp.seq = i32(total)
	return {}
}

impl_bidi :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, stream: gen.Tester_Bidi_Server) -> grpc.Status {
	state := (^Test_State)(srv.user_data)
	for {
		m: gen.Echo
		got, st := gen.Tester_Bidi_Server_recv(stream, &m)
		if st.code != .OK {
			if grpc.call_is_cancelled(call) {
				sync.atomic_add(&state.cancelled_seen, 1)
			}
			return st
		}
		if !got {
			return {}
		}
		m.seq += 1
		if st = gen.Tester_Bidi_Server_send(stream, &m); st.code != .OK {
			return st
		}
	}
}

Fixture :: struct {
	state:  Test_State,
	impl:   gen.Tester_Server,
	server: grpc.Server,
	ch:     ^grpc.Channel,
	addr:   string,
}

start :: proc(f: ^Fixture, server_opts := grpc.Server_Options{}, channel_opts := grpc.Channel_Options{}) -> bool {
	f.impl = {
		user_data     = &f.state,
		unary         = impl_unary,
		server_stream = impl_server_stream,
		client_stream = impl_client_stream,
		bidi          = impl_bidi,
	}
	grpc.server_init(&f.server, server_opts)
	if !gen.Tester_register(&f.server, &f.impl) {
		return false
	}
	ep, ok := grpc.server_start(&f.server, "127.0.0.1:0")
	if !ok {
		return false
	}
	f.addr = net.endpoint_to_string(ep, context.temp_allocator)
	f.ch = grpc.channel_create(f.addr, channel_opts)
	return f.ch != nil
}

stop :: proc(f: ^Fixture) {
	grpc.channel_destroy(f.ch)
	grpc.server_shutdown(&f.server, 2 * time.Second)
	grpc.server_destroy(&f.server)
}

expect_ok :: proc(t: ^testing.T, st: grpc.Status, loc := #caller_location) -> bool {
	testing.expectf(t, st.code == .OK, "status %v: %s", st.code, st.message, loc = loc)
	return st.code == .OK
}

// -----------------------------------------------------------------------------
// Unit tests of helpers
// -----------------------------------------------------------------------------

@(test)
test_timeout_format_and_parse :: proc(t: ^testing.T) {
	buf: [16]u8
	testing.expect_value(t, grpc.format_timeout(1500 * time.Millisecond, buf[:]), "1500000u")
	// The most precise unit that fits in 8 digits is chosen.
	testing.expect_value(t, grpc.format_timeout(time.Hour * 100000, buf[:]), "6000000M")
	testing.expect_value(t, grpc.format_timeout(time.Hour * 2_000_000, buf[:]), "2000000H")
	testing.expect_value(t, grpc.format_timeout(1, buf[:]), "1n")
	testing.expect_value(t, grpc.format_timeout(100 * time.Second, buf[:]), "100000m")
	for s in ([]string{"1H", "2M", "3S", "4m", "5u", "6n", "99999999S"}) {
		_, ok := grpc.parse_timeout(s)
		testing.expectf(t, ok, "failed to parse %q", s)
	}
	d, _ := grpc.parse_timeout("250m")
	testing.expect_value(t, d, 250 * time.Millisecond)
	for s in ([]string{"", "1", "1x", "123456789S", "-1S", "1.5S"}) {
		_, ok := grpc.parse_timeout(s)
		testing.expectf(t, !ok, "accepted %q", s)
	}
	// Formatting never shortens the deadline and fits 8 digits.
	for ns in ([]i64{1, 999, 100_000_001, 123_456_789_123, i64(max(i32)) * 1000}) {
		s := grpc.format_timeout(time.Duration(ns), buf[:])
		back, ok := grpc.parse_timeout(s)
		testing.expect(t, ok && i64(back) >= ns && len(s) <= 9)
	}
}

@(test)
test_percent_encoding :: proc(t: ^testing.T) {
	enc := make([dynamic]u8, context.temp_allocator)
	grpc.append_percent_encoded(&enc, "a b%c\n\xe2\x82\xac")
	testing.expect_value(t, string(enc[:]), "a b%25c%0A%E2%82%AC")
	out := make([]u8, len(enc), context.temp_allocator)
	testing.expect_value(t, grpc.percent_decode(out, string(enc[:])), "a b%c\n\xe2\x82\xac")
	// Malformed escapes are kept.
	out2 := make([]u8, 8, context.temp_allocator)
	testing.expect_value(t, grpc.percent_decode(out2, "%zz%4"), "%zz%4")
}

@(test)
test_base64 :: proc(t: ^testing.T) {
	cases := [][2]string{{"", ""}, {"f", "Zg"}, {"fo", "Zm8"}, {"foo", "Zm9v"}, {"foob", "Zm9vYg"}, {"\x00\xff\xfe", "AP/+"}}
	for c in cases {
		enc := make([dynamic]u8, context.temp_allocator)
		grpc.append_base64(&enc, transmute([]u8)c[0])
		testing.expect_value(t, string(enc[:]), c[1])
		dst := make([]u8, len(c[1]) + 4, context.temp_allocator)
		dec, ok := grpc.base64_decode(dst, c[1])
		testing.expect(t, ok && string(dec) == c[0])
		PAD := "=="
		padded := strings.concatenate({c[1], PAD[:(4 - len(c[1]) % 4) % 4]}, context.temp_allocator)
		dec, ok = grpc.base64_decode(dst, padded)
		testing.expect(t, ok && string(dec) == c[0])
	}
	dst: [8]u8
	_, ok := grpc.base64_decode(dst[:], "A")
	testing.expect(t, !ok)
	_, ok = grpc.base64_decode(dst[:], "A*A")
	testing.expect(t, !ok)
}

@(test)
test_metadata_validation :: proc(t: ^testing.T) {
	testing.expect_value(t, grpc.check_outgoing_metadata({{"x-ok", "v"}}).code, grpc.Status_Code.OK)
	testing.expect_value(t, grpc.check_outgoing_metadata({{"X-Upper", "v"}}).code, grpc.Status_Code.Internal)
	testing.expect_value(t, grpc.check_outgoing_metadata({{"grpc-x", "v"}}).code, grpc.Status_Code.Internal)
	testing.expect_value(t, grpc.check_outgoing_metadata({{"x", "\n"}}).code, grpc.Status_Code.Internal)
	testing.expect_value(t, grpc.check_outgoing_metadata({{"x-bin", "\n\x00"}}).code, grpc.Status_Code.OK)
	testing.expect_value(t, grpc.check_outgoing_metadata({{"connection", "close"}}).code, grpc.Status_Code.Internal)
}

// -----------------------------------------------------------------------------
// RPCs over loopback
// -----------------------------------------------------------------------------

@(test)
test_unary :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	for i in 0 ..< 20 {
		req := gen.Echo {
			text = "hello",
			seq  = i32(i),
		}
		resp: gen.Echo
		st := gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator})
		if !expect_ok(t, st) {
			return
		}
		testing.expect_value(t, resp.text, "hello")
		testing.expect_value(t, resp.seq, i32(i + 1))
	}
}

@(test)
test_unary_errors :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	req := gen.Echo {
		fail_code    = i32(grpc.Status_Code.Not_Found),
		fail_message = "no such thing: ünïcødé 100%\n",
	}
	resp: gen.Echo
	st := gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator})
	testing.expect_value(t, st.code, grpc.Status_Code.Not_Found)
	testing.expect_value(t, st.message, "no such thing: ünïcødé 100%\n")

	// A method the server does not implement.
	st = gen.Tester_not_implemented(f.ch, &req, &resp, {allocator = context.temp_allocator})
	testing.expect_value(t, st.code, grpc.Status_Code.Unimplemented)

	// A method the server does not know.
	unknown := gen.Tester_Unary_METHOD
	unknown.path = "/test.svc.Tester/Nope"
	st = grpc.invoke(f.ch, &unknown, &req, &resp, {allocator = context.temp_allocator})
	testing.expect_value(t, st.code, grpc.Status_Code.Unimplemented)
	unknown.path = "/no.Such/Service"
	st = grpc.invoke(f.ch, &unknown, &req, &resp, {allocator = context.temp_allocator})
	testing.expect_value(t, st.code, grpc.Status_Code.Unimplemented)

	// Invalid outgoing metadata is rejected before sending.
	st = gen.Tester_unary(f.ch, &req, &resp, {metadata = {{"Bad Key", "v"}}, allocator = context.temp_allocator})
	testing.expect_value(t, st.code, grpc.Status_Code.Internal)
}

@(test)
test_metadata_roundtrip :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	opts := grpc.Call_Options {
		metadata  = {{"x-echo", "value-1"}, {"authorization", "Bearer secret"}},
		allocator = context.temp_allocator,
	}
	cs, st := grpc.client_new_stream(f.ch, &gen.Tester_Unary_METHOD, opts)
	if !expect_ok(t, st) {
		return
	}
	defer grpc.client_destroy(cs)
	req := gen.Echo {
		text = "md",
	}
	expect_ok(t, grpc.client_send_last(cs, &req))
	header, hst := grpc.client_header(cs)
	expect_ok(t, hst)
	v, ok := grpc.metadata_get(header, "x-echo-header")
	testing.expect(t, ok && v == "value-1")
	resp: gen.Echo
	got, rst := grpc.client_recv(cs, &resp)
	testing.expect(t, got && rst.code == .OK)
	expect_ok(t, grpc.client_finish(cs))
	trailer := grpc.client_trailer(cs)
	v, ok = grpc.metadata_get(trailer, "x-echo-trailer")
	testing.expect(t, ok && v == "value-1")
	blob, has_blob := grpc.metadata_get(trailer, "x-blob-bin")
	testing.expect(t, has_blob && blob == "\x00\x01\xff")
}

@(test)
test_server_streaming :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	req := gen.Echo {
		text  = "stream",
		count = 200,
	}
	c, st := gen.Tester_server_stream(f.ch, &req, {allocator = context.temp_allocator})
	if !expect_ok(t, st) {
		return
	}
	n := 0
	for {
		m: gen.Echo
		got, rst := gen.Tester_ServerStream_Client_recv(c, &m)
		if !got {
			expect_ok(t, rst)
			break
		}
		testing.expect_value(t, m.seq, i32(n))
		n += 1
	}
	testing.expect_value(t, n, 200)
	expect_ok(t, gen.Tester_ServerStream_Client_finish(c))

	// Status after some messages.
	req.count = 3
	req.fail_code = i32(grpc.Status_Code.Aborted)
	req.fail_message = "stopped"
	c, st = gen.Tester_server_stream(f.ch, &req, {allocator = context.temp_allocator})
	n = 0
	final: grpc.Status
	for {
		m: gen.Echo
		got, rst := gen.Tester_ServerStream_Client_recv(c, &m)
		if !got {
			final = rst
			break
		}
		n += 1
	}
	testing.expect_value(t, n, 3)
	testing.expect_value(t, final.code, grpc.Status_Code.Aborted)
	testing.expect_value(t, final.message, "stopped")
	gen.Tester_ServerStream_Client_finish(c)
}

@(test)
test_client_streaming :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	c, st := gen.Tester_client_stream(f.ch, {allocator = context.temp_allocator})
	if !expect_ok(t, st) {
		return
	}
	want := 0
	for i in 0 ..< 100 {
		m := gen.Echo {
			seq = i32(i),
		}
		want += i
		if !expect_ok(t, gen.Tester_ClientStream_Client_send(c, &m)) {
			break
		}
	}
	expect_ok(t, gen.Tester_ClientStream_Client_close_send(c))
	resp: gen.Echo
	got, rst := gen.Tester_ClientStream_Client_recv(c, &resp)
	testing.expect(t, got)
	expect_ok(t, rst)
	testing.expect_value(t, resp.count, 100)
	testing.expect_value(t, int(resp.seq), want)
	expect_ok(t, gen.Tester_ClientStream_Client_finish(c))
}

@(test)
test_bidi_ping_pong :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	c, st := gen.Tester_bidi(f.ch, {allocator = context.temp_allocator})
	if !expect_ok(t, st) {
		return
	}
	for i in 0 ..< 100 {
		m := gen.Echo {
			seq  = i32(i),
			text = "ping",
		}
		if !expect_ok(t, gen.Tester_Bidi_Client_send(c, &m)) {
			break
		}
		resp: gen.Echo
		got, rst := gen.Tester_Bidi_Client_recv(c, &resp)
		if !testing.expect(t, got && rst.code == .OK) {
			break
		}
		testing.expect_value(t, resp.seq, i32(i + 1))
	}
	expect_ok(t, gen.Tester_Bidi_Client_close_send(c))
	resp: gen.Echo
	got, rst := gen.Tester_Bidi_Client_recv(c, &resp)
	testing.expect(t, !got)
	expect_ok(t, rst)
	expect_ok(t, gen.Tester_Bidi_Client_finish(c))
}

// Messages far larger than the flow-control windows exercise
// WINDOW_UPDATE handling in both directions.
@(test)
test_large_messages_and_flow_control :: proc(t: ^testing.T) {
	// Small windows force many window updates.
	small := grpc.Conn_Options {
		initial_window_size    = 65535,
		connection_window_size = 65535,
	}
	f: Fixture
	if !testing.expect(t, start(&f, {conn = small}, {conn = small})) {
		return
	}
	defer stop(&f)

	payload := make([]u8, 3 << 20, context.temp_allocator)
	for i in 0 ..< len(payload) {
		payload[i] = u8(i * 7)
	}
	req := gen.Echo {
		payload = payload,
	}
	resp: gen.Echo
	st := gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator})
	if expect_ok(t, st) {
		testing.expect_value(t, len(resp.payload), len(payload))
		testing.expect(t, string(resp.payload) == string(payload))
	}

	// Server streaming of large messages.
	req.count = 4
	req.payload = payload[:1 << 20]
	c, sst := gen.Tester_server_stream(f.ch, &req, {allocator = context.temp_allocator})
	if expect_ok(t, sst) {
		n := 0
		for {
			m: gen.Echo
			got, rst := gen.Tester_ServerStream_Client_recv(c, &m)
			if !got {
				expect_ok(t, rst)
				break
			}
			testing.expect_value(t, len(m.payload), 1 << 20)
			n += 1
		}
		testing.expect_value(t, n, 4)
		gen.Tester_ServerStream_Client_finish(c)
	}
}

@(test)
test_message_size_limits :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f, {conn = {max_recv_message_size = 1024}}, {conn = {max_recv_message_size = 1200}})) {
		return
	}
	defer stop(&f)

	big := make([]u8, 1500, context.temp_allocator)
	req := gen.Echo {
		payload = big,
	}
	resp: gen.Echo
	// Request too large for the server.
	st := gen.Tester_unary(f.ch, &req, &resp, {allocator = context.temp_allocator})
	testing.expect_value(t, st.code, grpc.Status_Code.Resource_Exhausted)

	// Responses up to the client's limit are fine...
	sreq := gen.Echo {
		response_bytes = 900,
		count          = 3,
	}
	c, sst := gen.Tester_server_stream(f.ch, &sreq, {allocator = context.temp_allocator})
	if expect_ok(t, sst) {
		m: gen.Echo
		got, rst := gen.Tester_ServerStream_Client_recv(c, &m)
		testing.expect(t, got && rst.code == .OK)
		gen.Tester_ServerStream_Client_finish(c)
	}
	// ...but a response too large for the client is rejected.
	sreq.response_bytes = 1500
	sreq.count = 1
	c, sst = gen.Tester_server_stream(f.ch, &sreq, {allocator = context.temp_allocator})
	if expect_ok(t, sst) {
		m: gen.Echo
		got, rst := gen.Tester_ServerStream_Client_recv(c, &m)
		testing.expect(t, !got)
		testing.expect_value(t, rst.code, grpc.Status_Code.Resource_Exhausted)
		gen.Tester_ServerStream_Client_finish(c)
	}

	// The connection is still healthy afterwards.
	ok_req := gen.Echo {
		text = "fine",
	}
	expect_ok(t, gen.Tester_unary(f.ch, &ok_req, &resp, {allocator = context.temp_allocator}))
}

@(test)
test_deadline_exceeded :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	req := gen.Echo {
		sleep_ms = 2000,
	}
	resp: gen.Echo
	start_time := time.tick_now()
	st := gen.Tester_unary(f.ch, &req, &resp, {timeout = 150 * time.Millisecond, allocator = context.temp_allocator})
	elapsed := time.tick_since(start_time)
	testing.expect_value(t, st.code, grpc.Status_Code.Deadline_Exceeded)
	testing.expectf(t, elapsed < 1500 * time.Millisecond, "deadline took %v", elapsed)

	// The server handler observes the cancellation (deadline or RST).
	for _ in 0 ..< 200 {
		if sync.atomic_load(&f.state.cancelled_seen) > 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&f.state.cancelled_seen) > 0)

	// An already expired deadline fails immediately.
	st = gen.Tester_unary(f.ch, &req, &resp, {deadline = time.time_add(time.now(), -time.Second)})
	testing.expect_value(t, st.code, grpc.Status_Code.Deadline_Exceeded)
}

@(test)
test_client_cancel :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	c, st := gen.Tester_bidi(f.ch, {allocator = context.temp_allocator})
	if !expect_ok(t, st) {
		return
	}
	m := gen.Echo {
		seq = 1,
	}
	expect_ok(t, gen.Tester_Bidi_Client_send(c, &m))
	resp: gen.Echo
	got, _ := gen.Tester_Bidi_Client_recv(c, &resp)
	testing.expect(t, got)
	grpc.client_cancel(c.stream)
	final := gen.Tester_Bidi_Client_finish(c)
	testing.expect_value(t, final.code, grpc.Status_Code.Cancelled)
	for _ in 0 ..< 200 {
		if sync.atomic_load(&f.state.cancelled_seen) > 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&f.state.cancelled_seen) > 0)
}

Concurrent :: struct {
	ch:     ^grpc.Channel,
	failed: i32,
	done:   i32,
}

@(test)
test_concurrent_calls :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	defer stop(&f)

	THREADS :: 16
	CALLS :: 40
	shared := Concurrent {
		ch = f.ch,
	}
	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		threads[i] = thread.create_and_start_with_poly_data(&shared, proc(s: ^Concurrent) {
			for j in 0 ..< CALLS {
				text := fmt.tprintf("call-%d", j)
				req := gen.Echo {
					text = text,
					seq  = i32(j),
				}
				resp: gen.Echo
				st := gen.Tester_unary(s.ch, &req, &resp, {allocator = context.temp_allocator})
				if st.code != .OK || resp.text != text || resp.seq != i32(j + 1) {
					sync.atomic_add(&s.failed, 1)
				}
				free_all(context.temp_allocator)
			}
			sync.atomic_add(&s.done, 1)
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, shared.failed, 0)
	testing.expect_value(t, shared.done, THREADS)
}

@(test)
test_stream_concurrency_limit :: proc(t: ^testing.T) {
	// The server allows two streams at once; the client queues the rest.
	f: Fixture
	if !testing.expect(t, start(&f, {conn = {max_concurrent_streams = 2}})) {
		return
	}
	defer stop(&f)

	shared := Concurrent {
		ch = f.ch,
	}
	threads: [6]^thread.Thread
	for i in 0 ..< len(threads) {
		threads[i] = thread.create_and_start_with_poly_data(&shared, proc(s: ^Concurrent) {
			req := gen.Echo {
				sleep_ms = 100,
			}
			resp: gen.Echo
			st := gen.Tester_unary(s.ch, &req, &resp, {timeout = 10 * time.Second, allocator = context.temp_allocator})
			if st.code != .OK {
				sync.atomic_add(&s.failed, 1)
			}
			sync.atomic_add(&s.done, 1)
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, shared.failed, 0)
}

@(test)
test_no_server_is_unavailable :: proc(t: ^testing.T) {
	// Find a port with nothing listening.
	ep, _ := net.parse_endpoint("127.0.0.1:0")
	sock, _ := net.listen_tcp(ep)
	bound, _ := net.bound_endpoint(sock)
	net.close(sock)
	ch := grpc.channel_create(net.endpoint_to_string(bound, context.temp_allocator))
	defer grpc.channel_destroy(ch)
	req: gen.Echo
	resp: gen.Echo
	st := gen.Tester_unary(ch, &req, &resp)
	testing.expect_value(t, st.code, grpc.Status_Code.Unavailable)
	// Fails fast while backing off.
	st = gen.Tester_unary(ch, &req, &resp)
	testing.expect_value(t, st.code, grpc.Status_Code.Unavailable)
}

@(test)
test_graceful_shutdown_completes_inflight :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	shared := Concurrent {
		ch = f.ch,
	}
	th := thread.create_and_start_with_poly_data(&shared, proc(s: ^Concurrent) {
		req := gen.Echo {
			sleep_ms = 300,
			text     = "slow",
		}
		resp: gen.Echo
		st := gen.Tester_unary(s.ch, &req, &resp, {allocator = context.temp_allocator})
		if st.code != .OK || resp.text != "slow" {
			sync.atomic_add(&s.failed, 1)
		}
		sync.atomic_add(&s.done, 1)
	})
	// Wait until the call is running on the server.
	for _ in 0 ..< 200 {
		if sync.atomic_load(&f.state.calls) > 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	grpc.server_shutdown(&f.server, 5 * time.Second)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, shared.failed, 0)
	testing.expect_value(t, shared.done, 1)

	// New calls fail: the server is gone.
	req: gen.Echo
	resp: gen.Echo
	st := gen.Tester_unary(f.ch, &req, &resp)
	testing.expect_value(t, st.code, grpc.Status_Code.Unavailable)
	grpc.channel_destroy(f.ch)
	grpc.server_destroy(&f.server)
}

@(test)
test_forced_shutdown_fails_inflight :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start(&f)) {
		return
	}
	shared := Concurrent {
		ch = f.ch,
	}
	th := thread.create_and_start_with_poly_data(&shared, proc(s: ^Concurrent) {
		req := gen.Echo {
			sleep_ms = 3000,
		}
		resp: gen.Echo
		st := gen.Tester_unary(s.ch, &req, &resp, {allocator = context.temp_allocator})
		if st.code == .Unavailable || st.code == .Cancelled {
			sync.atomic_add(&s.done, 1)
		} else {
			sync.atomic_add(&s.failed, 1)
		}
	})
	for _ in 0 ..< 200 {
		if sync.atomic_load(&f.state.calls) > 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	start_time := time.tick_now()
	grpc.server_shutdown(&f.server, 50 * time.Millisecond)
	thread.join(th)
	thread.destroy(th)
	testing.expectf(t, time.tick_since(start_time) < 2500 * time.Millisecond, "shutdown took %v", time.tick_since(start_time))
	testing.expect_value(t, shared.failed, 0)
	testing.expect_value(t, shared.done, 1)
	grpc.channel_destroy(f.ch)
	grpc.server_destroy(&f.server)
}
