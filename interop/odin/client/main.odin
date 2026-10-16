// interop client: runs a battery of RPCs against a test.svc.Tester server
// (the Python reference server, or the Odin one) and reports each check.
//
//     interop_client <host:port>
//
// Exit status 0 means every check passed.
package interop_client

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import "grpc:grpc"
import gen "../gen"

failures := 0

check :: proc(name: string, ok: bool, detail := "") {
	if ok {
		fmt.printfln("PASS %s", name)
	} else {
		fmt.printfln("FAIL %s %s", name, detail)
		failures += 1
	}
}

status_text :: proc(st: grpc.Status) -> string {
	return fmt.tprintf("(status %v: %q)", st.code, st.message)
}

main :: proc() {
	target := os.args[1] if len(os.args) > 1 else "127.0.0.1:50051"
	ch := grpc.channel_create(target)
	defer grpc.channel_destroy(ch)
	opts := grpc.Call_Options {
		allocator = context.temp_allocator,
		timeout   = 10 * time.Second,
	}

	{ 	// Unary.
		req := gen.Echo {
			text = "hello interop",
			seq  = 41,
		}
		resp: gen.Echo
		st := gen.Tester_unary(ch, &req, &resp, opts)
		check("unary", st.code == .OK && resp.text == "hello interop" && resp.seq == 42, status_text(st))
	}

	{ 	// Empty request/response.
		req: gen.Echo
		resp: gen.Echo
		st := gen.Tester_unary(ch, &req, &resp, opts)
		check("unary_empty", st.code == .OK && resp.seq == 1, status_text(st))
	}

	{ 	// Metadata in both directions, including binary values.
		md_opts := opts
		md_opts.metadata = {{"x-echo", "meta-value"}, {"x-extra-bin", "\x00\xfe"}}
		cs, st := grpc.client_new_stream(ch, &gen.Tester_Unary_METHOD, md_opts)
		ok := st.code == .OK
		if ok {
			req := gen.Echo {
				text = "md",
			}
			ok = grpc.client_send_last(cs, &req).code == .OK
			header, hst := grpc.client_header(cs)
			v, has := grpc.metadata_get(header, "x-echo-header")
			ok = ok && hst.code == .OK && has && v == "meta-value"
			resp: gen.Echo
			got, rst := grpc.client_recv(cs, &resp)
			ok = ok && got && rst.code == .OK
			fst := grpc.client_finish(cs)
			trailer := grpc.client_trailer(cs)
			tv, t_has := grpc.metadata_get(trailer, "x-echo-trailer")
			blob, b_has := grpc.metadata_get(trailer, "x-blob-bin")
			ok = ok && fst.code == .OK && t_has && tv == "meta-value" && b_has && blob == "\x00\x01\xff"
			grpc.client_destroy(cs)
		}
		check("metadata", ok, status_text(st))
	}

	{ 	// Error status with a message that needs percent-encoding.
		req := gen.Echo {
			fail_code    = i32(grpc.Status_Code.Failed_Precondition),
			fail_message = "bad state: ünïcødé 100% \t done",
		}
		resp: gen.Echo
		st := gen.Tester_unary(ch, &req, &resp, opts)
		check("error_status", st.code == .Failed_Precondition && st.message == "bad state: ünïcødé 100% \t done", status_text(st))
	}

	{ 	// Unimplemented method.
		req: gen.Echo
		resp: gen.Echo
		st := gen.Tester_not_implemented(ch, &req, &resp, opts)
		check("unimplemented", st.code == .Unimplemented, status_text(st))
	}

	{ 	// Server streaming.
		req := gen.Echo {
			text  = "s",
			count = 100,
		}
		c, st := gen.Tester_server_stream(ch, &req, opts)
		n := 0
		ordered := true
		final := st
		if st.code == .OK {
			for {
				m: gen.Echo
				got, rst := gen.Tester_ServerStream_Client_recv(c, &m)
				if !got {
					final = rst
					break
				}
				ordered = ordered && m.seq == i32(n)
				n += 1
			}
			gen.Tester_ServerStream_Client_finish(c)
		}
		check("server_streaming", final.code == .OK && n == 100 && ordered, status_text(final))
	}

	{ 	// Client streaming.
		c, st := gen.Tester_client_stream(ch, opts)
		ok := st.code == .OK
		want := 0
		resp: gen.Echo
		if ok {
			for i in 0 ..< 100 {
				m := gen.Echo {
					seq = i32(i),
				}
				want += i
				ok = ok && gen.Tester_ClientStream_Client_send(c, &m).code == .OK
			}
			ok = ok && gen.Tester_ClientStream_Client_close_send(c).code == .OK
			got, rst := gen.Tester_ClientStream_Client_recv(c, &resp)
			ok = ok && got && rst.code == .OK
			st = gen.Tester_ClientStream_Client_finish(c)
		}
		check("client_streaming", ok && st.code == .OK && resp.count == 100 && int(resp.seq) == want, status_text(st))
	}

	{ 	// Bidirectional ping-pong.
		c, st := gen.Tester_bidi(ch, opts)
		ok := st.code == .OK
		if ok {
			for i in 0 ..< 50 {
				m := gen.Echo {
					seq = i32(i),
				}
				ok = ok && gen.Tester_Bidi_Client_send(c, &m).code == .OK
				resp: gen.Echo
				got, rst := gen.Tester_Bidi_Client_recv(c, &resp)
				ok = ok && got && rst.code == .OK && resp.seq == i32(i + 1)
				if !ok {
					st = rst
					break
				}
			}
			ok = ok && gen.Tester_Bidi_Client_close_send(c).code == .OK
			resp: gen.Echo
			got, rst := gen.Tester_Bidi_Client_recv(c, &resp)
			ok = ok && !got && rst.code == .OK
			gen.Tester_Bidi_Client_finish(c)
		}
		check("bidi_streaming", ok, status_text(st))
	}

	{ 	// Large messages (flow control in both directions).
		payload := make([]u8, 3 << 20, context.temp_allocator)
		for i in 0 ..< len(payload) {
			payload[i] = u8(i * 31)
		}
		req := gen.Echo {
			payload = payload,
		}
		resp: gen.Echo
		st := gen.Tester_unary(ch, &req, &resp, opts)
		check("large_unary", st.code == .OK && string(resp.payload) == string(payload), status_text(st))
	}

	{ 	// Deadline.
		req := gen.Echo {
			sleep_ms = 2000,
		}
		resp: gen.Echo
		d_opts := opts
		d_opts.timeout = 200 * time.Millisecond
		start := time.tick_now()
		st := gen.Tester_unary(ch, &req, &resp, d_opts)
		elapsed := time.tick_since(start)
		check("deadline_exceeded", st.code == .Deadline_Exceeded && elapsed < 1500 * time.Millisecond, status_text(st))
	}

	{ 	// Cancellation mid-stream.
		c, st := gen.Tester_bidi(ch, opts)
		ok := st.code == .OK
		if ok {
			m := gen.Echo {
				seq = 1,
			}
			ok = gen.Tester_Bidi_Client_send(c, &m).code == .OK
			resp: gen.Echo
			got, _ := gen.Tester_Bidi_Client_recv(c, &resp)
			ok = ok && got
			grpc.client_cancel(c.stream)
			st = gen.Tester_Bidi_Client_finish(c)
		}
		check("cancel", ok && st.code == .Cancelled, status_text(st))
	}

	{ 	// Concurrent RPCs multiplexed on one connection.
		Shared :: struct {
			ch:     ^grpc.Channel,
			failed: i32,
		}
		shared := Shared {
			ch = ch,
		}
		threads: [8]^thread.Thread
		for i in 0 ..< len(threads) {
			threads[i] = thread.create_and_start_with_poly_data(&shared, proc(s: ^Shared) {
				for j in 0 ..< 25 {
					req := gen.Echo {
						seq = i32(j),
					}
					resp: gen.Echo
					st := gen.Tester_unary(s.ch, &req, &resp, {allocator = context.temp_allocator, timeout = 10 * time.Second})
					if st.code != .OK || resp.seq != i32(j + 1) {
						sync.atomic_add(&s.failed, 1)
					}
					free_all(context.temp_allocator)
				}
			})
		}
		for t in threads {
			thread.join(t)
			thread.destroy(t)
		}
		check("concurrent", shared.failed == 0, fmt.tprintf("%d failures", shared.failed))
	}

	if failures > 0 {
		fmt.printfln("%d check(s) failed", failures)
		os.exit(1)
	}
	fmt.println("all checks passed")
}
