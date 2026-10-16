package protoc

import "core:slice"
import "core:strings"

// Service code layout, for `service Greeter { rpc SayHello(Req) returns (Resp); }`:
//
//   Greeter_SERVICE_NAME            :: "pkg.Greeter"
//   Greeter_SayHello_METHOD         := grpc.Method_Desc{...}
//   Greeter_say_hello               client stub (unary) or stream opener
//   Greeter_<Method>_Client(_*)     typed client stream wrapper (streaming)
//   Greeter_Server                  struct of handler procedures (vtable)
//   Greeter_<Method>_Server(_*)     typed server stream wrapper (streaming)
//   Greeter_<Method>_handler        runtime adapter for one method
//   Greeter_SERVICE_DESC            runtime descriptor
//   Greeter_register                registers a Greeter_Server with a grpc.Server

@(private = "file")
Method_Names :: struct {
	m:          ^Method,
	stub:       string, // <Svc>_<method_snake>: client stub
	field:      string, // escaped, unique field of <Svc>_Server
	desc:       string, // <Svc>_<Method>_METHOD
	handler:    string, // <Svc>_<Method>_handler
	client_t:   string, // <Svc>_<Method>_Client
	server_t:   string, // <Svc>_<Method>_Server
	req, resp:  string, // Odin message types
	req_codec:  string,
	resp_codec: string,
}

@(private = "file")
method_names :: proc(g: ^Generator, s: ^Service) -> []Method_Names {
	a := g.allocator
	out := make([]Method_Names, len(s.methods), a)
	taken := make(map[string]bool, a)
	taken["user_data"] = true
	for m, i in s.methods {
		snake := snake_case(m.name, a)
		field := snake
		if slice.contains(ODIN_RESERVED[:], field) {
			field = strings.concatenate({field, "_"}, a)
		}
		for taken[field] {
			field = strings.concatenate({field, "_"}, a)
		}
		taken[field] = true
		base := strings.concatenate({s.odin_name, "_", m.name}, a)
		out[i] = {
			m          = m,
			stub       = g.stub_names[m],
			field      = field,
			desc       = strings.concatenate({base, "_METHOD"}, a),
			handler    = strings.concatenate({base, "_handler"}, a),
			client_t   = strings.concatenate({base, "_Client"}, a),
			server_t   = strings.concatenate({base, "_Server"}, a),
			req        = m.input.message.odin_name,
			resp       = m.output.message.odin_name,
			req_codec  = strings.concatenate({m.input.message.odin_name, "_CODEC"}, a),
			resp_codec = strings.concatenate({m.output.message.odin_name, "_CODEC"}, a),
		}
	}
	return out
}

@(private = "file")
method_kind :: proc(m: ^Method) -> string {
	switch {
	case m.client_streaming && m.server_streaming:
		return ".Bidi_Streaming"
	case m.client_streaming:
		return ".Client_Streaming"
	case m.server_streaming:
		return ".Server_Streaming"
	}
	return ".Unary"
}

// gen_service emits gRPC client and server code for a service.
gen_service :: proc(g: ^Generator, s: ^Service) {
	names := method_names(g, s)
	svc := s.odin_name

	blank(g)
	line(g, "// -----------------------------------------------------------------------------")
	line(g, "// Service %s", s.full_name)
	line(g, "// -----------------------------------------------------------------------------")
	blank(g)
	line(g, "%s_SERVICE_NAME :: %q", svc, s.full_name)
	for &n in names {
		blank(g)
		open(g, "%s := grpc.Method_Desc{{", n.desc)
		line(g, "path = %q,", sprint(g, "/%s/%s", s.full_name, n.m.name))
		line(g, "client_streaming = %v,", n.m.client_streaming)
		line(g, "server_streaming = %v,", n.m.server_streaming)
		line(g, "request = &%s,", n.req_codec)
		line(g, "response = &%s,", n.resp_codec)
		close(g)
	}
	for &n in names {
		gen_client_method(g, s, &n)
	}
	gen_server(g, s, names)
}

@(private = "file")
gen_client_method :: proc(g: ^Generator, s: ^Service, n: ^Method_Names) {
	m := n.m
	blank(g)
	if !m.client_streaming && !m.server_streaming {
		line(g, "// %s calls %s.%s.", n.stub, s.full_name, m.name)
		open(g, "%s :: proc(ch: ^grpc.Channel, req: ^%s, resp: ^%s, opts := grpc.Call_Options{{}}) -> grpc.Status {{", n.stub, n.req, n.resp)
		line(g, "return grpc.invoke(ch, &%s, req, resp, opts)", n.desc)
		close(g)
		return
	}

	line(g, "// %s is the client side of a %s.%s stream.", n.client_t, s.full_name, m.name)
	open(g, "%s :: struct {{", n.client_t)
	line(g, "stream: ^grpc.Client_Stream,")
	close(g)
	blank(g)
	if m.client_streaming {
		line(g, "// %s starts %s.%s. Send requests, close_send, then recv the response(s).", n.stub, s.full_name, m.name)
		open(g, "%s :: proc(ch: ^grpc.Channel, opts := grpc.Call_Options{{}}) -> (%s, grpc.Status) {{", n.stub, n.client_t)
		line(g, "cs, st := grpc.client_new_stream(ch, &%s, opts)", n.desc)
		line(g, "return {{cs}}, st")
		close(g)
		blank(g)
		open(g, "%s_send :: proc(c: %s, req: ^%s) -> grpc.Status {{", n.client_t, n.client_t, n.req)
		line(g, "return grpc.client_send(c.stream, req)")
		close(g)
		blank(g)
		open(g, "%s_close_send :: proc(c: %s) -> grpc.Status {{", n.client_t, n.client_t)
		line(g, "return grpc.client_close_send(c.stream)")
		close(g)
	} else {
		line(g, "// %s sends the request of %s.%s; recv the responses.", n.stub, s.full_name, m.name)
		open(g, "%s :: proc(ch: ^grpc.Channel, req: ^%s, opts := grpc.Call_Options{{}}) -> (%s, grpc.Status) {{", n.stub, n.req, n.client_t)
		line(g, "cs, st := grpc.client_new_stream(ch, &%s, opts)", n.desc)
		open(g, "if st.code != .OK {{")
		line(g, "return {{}}, st")
		close(g)
		open(g, "if st = grpc.client_send_last(cs, req); st.code != .OK {{")
		line(g, "return {{}}, grpc.client_done(cs)")
		close(g)
		line(g, "return {{cs}}, {{}}")
		close(g)
	}
	blank(g)
	line(g, "// %s_recv returns false when the response stream ended; the status is", n.client_t)
	line(g, "// then the RPC's final status.")
	open(g, "%s_recv :: proc(c: %s, resp: ^%s) -> (bool, grpc.Status) {{", n.client_t, n.client_t, n.resp)
	line(g, "return grpc.client_recv(c.stream, resp)")
	close(g)
	blank(g)
	line(g, "// %s_finish ends the RPC (cancelling it if still running), releases", n.client_t)
	line(g, "// it and returns its final status.")
	open(g, "%s_finish :: proc(c: %s) -> grpc.Status {{", n.client_t, n.client_t)
	line(g, "return grpc.client_done(c.stream)")
	close(g)
}

@(private = "file")
gen_server :: proc(g: ^Generator, s: ^Service, names: []Method_Names) {
	svc := s.odin_name
	blank(g)
	line(g, "// %s_Server implements %s: set the procedures to implement; unset ones", svc, s.full_name)
	line(g, "// answer UNIMPLEMENTED. Build response messages with grpc.call_allocator(call).")
	open(g, "%s_Server :: struct {{", svc)
	line(g, "user_data: rawptr,")
	for &n in names {
		m := n.m
		switch {
		case !m.client_streaming && !m.server_streaming:
			line(g, "%s: proc(srv: ^%s_Server, call: ^grpc.Server_Call, req: ^%s, resp: ^%s) -> grpc.Status,", n.field, svc, n.req, n.resp)
		case !m.client_streaming:
			line(g, "%s: proc(srv: ^%s_Server, call: ^grpc.Server_Call, req: ^%s, stream: %s) -> grpc.Status,", n.field, svc, n.req, n.server_t)
		case !m.server_streaming:
			line(g, "%s: proc(srv: ^%s_Server, call: ^grpc.Server_Call, stream: %s, resp: ^%s) -> grpc.Status,", n.field, svc, n.server_t, n.resp)
		case:
			line(g, "%s: proc(srv: ^%s_Server, call: ^grpc.Server_Call, stream: %s) -> grpc.Status,", n.field, svc, n.server_t)
		}
	}
	close(g)

	for &n in names {
		m := n.m
		if !m.client_streaming && !m.server_streaming {
			continue
		}
		blank(g)
		line(g, "// %s is the server side of a %s.%s stream.", n.server_t, s.full_name, m.name)
		open(g, "%s :: struct {{", n.server_t)
		line(g, "call: ^grpc.Server_Call,")
		close(g)
		if m.server_streaming {
			blank(g)
			open(g, "%s_send :: proc(s: %s, resp: ^%s) -> grpc.Status {{", n.server_t, n.server_t, n.resp)
			line(g, "return grpc.server_send(s.call, resp, &%s)", n.resp_codec)
			close(g)
		}
		if m.client_streaming {
			blank(g)
			line(g, "// %s_recv returns false (with an OK status) once the client finished sending.", n.server_t)
			open(g, "%s_recv :: proc(s: %s, req: ^%s) -> (bool, grpc.Status) {{", n.server_t, n.server_t, n.req)
			line(g, "return grpc.server_recv(s.call, req, &%s)", n.req_codec)
			close(g)
		}
	}

	for &n in names {
		gen_handler(g, svc, &n)
	}

	blank(g)
	open(g, "%s_SERVICE_DESC := grpc.Service_Desc{{", svc)
	line(g, "name = %q,", s.full_name)
	open(g, "methods = []grpc.Method_Handler{{")
	for &n in names {
		line(g, "{{%q, %s, %s}},", n.m.name, method_kind(n.m), n.handler)
	}
	g.indent -= 1
	line(g, "}},")
	close(g)

	blank(g)
	line(g, "// %s_register adds the service to a server. `impl` must outlive the server.", svc)
	open(g, "%s_register :: proc(s: ^grpc.Server, impl: ^%s_Server) -> bool {{", svc, svc)
	line(g, "return grpc.server_register(s, &%s_SERVICE_DESC, impl)", svc)
	close(g)
}

@(private = "file")
gen_handler :: proc(g: ^Generator, svc: string, n: ^Method_Names) {
	m := n.m
	blank(g)
	open(g, "%s :: proc(impl: rawptr, call: ^grpc.Server_Call) -> grpc.Status {{", n.handler)
	line(g, "srv := (^%s_Server)(impl)", svc)
	open(g, "if srv.%s == nil {{", n.field)
	line(g, "return {{.Unimplemented, %q}}", sprint(g, "method %s is not implemented", m.name))
	close(g)
	recv_unary :: proc(g: ^Generator, n: ^Method_Names) {
		line(g, "req: %s", n.req)
		open(g, "if st := grpc.server_recv_unary(call, &req, &%s); st.code != .OK {{", n.req_codec)
		line(g, "return st")
		close(g)
	}
	switch {
	case !m.client_streaming && !m.server_streaming:
		recv_unary(g, n)
		line(g, "resp: %s", n.resp)
		open(g, "if st := srv.%s(srv, call, &req, &resp); st.code != .OK {{", n.field)
		line(g, "return st")
		close(g)
		line(g, "return grpc.server_send(call, &resp, &%s)", n.resp_codec)
	case !m.client_streaming:
		recv_unary(g, n)
		line(g, "return srv.%s(srv, call, &req, %s{{call}})", n.field, n.server_t)
	case !m.server_streaming:
		line(g, "resp: %s", n.resp)
		open(g, "if st := srv.%s(srv, call, %s{{call}}, &resp); st.code != .OK {{", n.field, n.server_t)
		line(g, "return st")
		close(g)
		line(g, "return grpc.server_send(call, &resp, &%s)", n.resp_codec)
	case:
		line(g, "return srv.%s(srv, call, %s{{call}})", n.field, n.server_t)
	}
	close(g)
}
