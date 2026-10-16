// Greeter client.
//
//     odin run examples/helloworld/client -collection:grpc=. -- 127.0.0.1:50051 Odin
package helloworld_client

import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:time"

import "grpc:grpc"
import pb "../pb"

main :: proc() {
	target := os.args[1] if len(os.args) > 1 else "127.0.0.1:50051"
	name := os.args[2] if len(os.args) > 2 else "world"

	ch := grpc.channel_create(target)
	defer grpc.channel_destroy(ch)

	// Responses are decoded into an arena: one free_all releases them.
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil {
		os.exit(1)
	}
	defer vmem.arena_destroy(&arena)
	opts := grpc.Call_Options {
		timeout   = 5 * time.Second,
		allocator = vmem.arena_allocator(&arena),
	}

	// Unary call.
	req := pb.HelloRequest {
		name = name,
	}
	reply: pb.HelloReply
	if st := pb.Greeter_say_hello(ch, &req, &reply, opts); st.code != .OK {
		fmt.eprintfln("SayHello failed: %v: %s", st.code, st.message)
		os.exit(1)
	}
	fmt.println(reply.message)

	// Server-streaming call.
	stream, st := pb.Greeter_say_hello_all(ch, &req, opts)
	if st.code != .OK {
		fmt.eprintfln("SayHelloAll failed: %v: %s", st.code, st.message)
		os.exit(1)
	}
	for {
		m: pb.HelloReply
		got, rst := pb.Greeter_SayHelloAll_Client_recv(stream, &m)
		if !got {
			st = rst
			break
		}
		fmt.println(" ", m.message)
	}
	pb.Greeter_SayHelloAll_Client_finish(stream)
	if st.code != .OK {
		fmt.eprintfln("SayHelloAll ended with %v: %s", st.code, st.message)
		os.exit(1)
	}
}
