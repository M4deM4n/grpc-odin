// Greeter server.
//
//     odin run examples/helloworld/server -collection:grpc=. -- 127.0.0.1:50051
package helloworld_server

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"

import "grpc:grpc"
import pb "../pb"

say_hello :: proc(srv: ^pb.Greeter_Server, call: ^grpc.Server_Call, req: ^pb.HelloRequest, resp: ^pb.HelloReply) -> grpc.Status {
	if req.name == "" {
		return {.Invalid_Argument, "name must not be empty"}
	}
	// Memory for the response comes from the per-call arena, which is freed
	// automatically when the RPC completes.
	resp.message = strings.concatenate({"Hello, ", req.name, "!"}, grpc.call_allocator(call))
	return {}
}

say_hello_all :: proc(srv: ^pb.Greeter_Server, call: ^grpc.Server_Call, req: ^pb.HelloRequest, stream: pb.Greeter_SayHelloAll_Server) -> grpc.Status {
	greetings := [?]string{"Hello", "Bonjour", "Hola", "Hallo", "Ciao"}
	for g in greetings {
		if grpc.call_is_cancelled(call) {
			return {.Cancelled, "client went away"}
		}
		reply := pb.HelloReply {
			message = fmt.aprintf("%s, %s!", g, req.name, allocator = grpc.call_allocator(call)),
		}
		if st := pb.Greeter_SayHelloAll_Server_send(stream, &reply); st.code != .OK {
			return st
		}
	}
	return {}
}

main :: proc() {
	address := os.args[1] if len(os.args) > 1 else "127.0.0.1:50051"

	impl := pb.Greeter_Server {
		say_hello     = say_hello,
		say_hello_all = say_hello_all,
	}
	server: grpc.Server
	grpc.server_init(&server)
	defer grpc.server_destroy(&server)
	pb.Greeter_register(&server, &impl)

	ep, ok := grpc.server_start(&server, address)
	if !ok {
		fmt.eprintfln("cannot listen on %s", address)
		os.exit(1)
	}
	fmt.printfln("Greeter listening on %s (press Enter to stop)", net.endpoint_to_string(ep))
	buf: [1]u8
	os.read(os.stdin, buf[:])
	grpc.server_shutdown(&server)
}
