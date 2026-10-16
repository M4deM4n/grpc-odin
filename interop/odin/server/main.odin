// interop server: serves test.svc.Tester (tests/grpc/proto) with the same
// semantics as the Python reference server, for cross-implementation tests.
//
//     interop_server <host:port> [--forever]
//
// Prints "listening <endpoint>" once ready; exits on stdin EOF, or never
// with --forever (the harness then terminates the process).
package interop_server

import "core:fmt"
import "core:net"
import "core:os"
import "core:time"

import "grpc:grpc"
import "grpc:reflection"
import gen "../gen"

unary :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, req: ^gen.Echo, resp: ^gen.Echo) -> grpc.Status {
	if v, ok := grpc.metadata_get(grpc.call_metadata(call), "x-echo"); ok {
		grpc.server_send_header(call, {{"x-echo-header", v}})
		grpc.server_set_trailer(call, {{"x-echo-trailer", v}, {"x-blob-bin", "\x00\x01\xff"}})
	}
	if req.sleep_ms > 0 {
		end := time.time_add(time.now(), time.Duration(req.sleep_ms) * time.Millisecond)
		for time.diff(time.now(), end) > 0 {
			if grpc.call_is_cancelled(call) {
				return {.Cancelled, "cancelled"}
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
	if req.response_bytes > 0 {
		resp.payload = make([]u8, req.response_bytes, grpc.call_allocator(call))
	}
	return {}
}

server_stream :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, req: ^gen.Echo, stream: gen.Tester_ServerStream_Server) -> grpc.Status {
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

client_stream :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, stream: gen.Tester_ClientStream_Server, resp: ^gen.Echo) -> grpc.Status {
	total, n := 0, 0
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

bidi :: proc(srv: ^gen.Tester_Server, call: ^grpc.Server_Call, stream: gen.Tester_Bidi_Server) -> grpc.Status {
	for {
		m: gen.Echo
		got, st := gen.Tester_Bidi_Server_recv(stream, &m)
		if st.code != .OK {
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

main :: proc() {
	address := os.args[1] if len(os.args) > 1 else "127.0.0.1:50051"
	impl := gen.Tester_Server {
		unary         = unary,
		server_stream = server_stream,
		client_stream = client_stream,
		bidi          = bidi,
	}
	server: grpc.Server
	grpc.server_init(&server)
	gen.Tester_register(&server, &impl)
	// Server reflection (v1 and v1alpha) from the embedded descriptors.
	refl: reflection.Server
	if !reflection.server_register(&refl, &server, gen.FILE_DESCRIPTORS[:]) {
		fmt.eprintln("failed to register server reflection")
		os.exit(1)
	}
	ep, ok := grpc.server_start(&server, address)
	if !ok {
		fmt.eprintfln("failed to listen on %s", address)
		os.exit(1)
	}
	fmt.printfln("listening %s", net.endpoint_to_string(ep))
	os.flush(os.stdout)

	if len(os.args) > 2 && os.args[2] == "--forever" {
		for {
			time.sleep(time.Hour)
		}
	}
	// Run until stdin closes, so the harness controls the lifetime.
	buf: [64]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if n <= 0 || err != nil {
			break
		}
	}
	grpc.server_shutdown(&server, 2 * time.Second)
	reflection.server_destroy(&refl)
	grpc.server_destroy(&server)
}
