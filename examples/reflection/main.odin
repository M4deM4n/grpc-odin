// Lists the services of any gRPC server that has server reflection enabled,
// in the style of `grpcurl list` / `grpcurl describe`.
//
//     odin run examples/reflection -collection:grpc=. -- <host:port>            # all services and methods
//     odin run examples/reflection -collection:grpc=. -- <host:port> <symbol>   # one service or message
package reflection_example

import "core:fmt"
import "core:os"
import "core:time"

import "grpc:grpc"
import "grpc:reflection"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: reflection <host:port> [service or message]")
		os.exit(2)
	}
	ch := grpc.channel_create(os.args[1])
	defer grpc.channel_destroy(ch)

	rc: reflection.Client
	if st := reflection.client_init(&rc, ch, 10 * time.Second); st.code != .OK {
		fail(st)
	}
	defer reflection.client_destroy(&rc)
	defer fmt.eprintfln("(server reflection protocol: %v)", reflection.version_in_use(&rc))

	if len(os.args) > 2 {
		describe(&rc, os.args[2])
		return
	}
	services, st := reflection.list_services(&rc)
	if st.code != .OK {
		fail(st)
	}
	for name in services {
		print_service(&rc, name)
	}
}

describe :: proc(rc: ^reflection.Client, symbol: string) {
	if _, st := reflection.describe_service(rc, symbol); st.code == .OK {
		print_service(rc, symbol)
		return
	}
	msg, _, st := reflection.describe_message(rc, symbol)
	if st.code != .OK {
		fail(st)
	}
	fmt.printfln("message %s {{", symbol)
	for &f in msg.field {
		fmt.printfln("  %s %s = %d;", reflection.field_type_string(&f), f.name.? or_else "?", f.number.? or_else 0)
	}
	fmt.println("}")
}

print_service :: proc(rc: ^reflection.Client, name: string) {
	info, st := reflection.describe_service(rc, name)
	if st.code != .OK {
		fmt.printfln("%s (no descriptor: %v %s)", name, st.code, st.message)
		return
	}
	fmt.println(name)
	for m in info.methods {
		fmt.printfln(
			"  rpc %s(%s%s) returns (%s%s)",
			m.name,
			"stream " if m.client_streaming else "",
			m.input_type,
			"stream " if m.server_streaming else "",
			m.output_type,
		)
	}
}

fail :: proc(st: grpc.Status) -> ! {
	fmt.eprintfln("error: %v: %s", st.code, st.message)
	os.exit(1)
}
