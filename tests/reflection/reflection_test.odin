package reflection_test

import "core:encoding/hex"
import "core:net"
import "core:testing"
import "core:time"

import "grpc:grpc"
import pb "grpc:protobuf"
import "grpc:reflection"

// FileDescriptorProto of tests/grpc/proto/test_service.proto, serialized by
// Google's protobuf runtime (interop/python/gen_fixtures.py).
FIXTURE_TEST_SERVICE :: #load("testdata/test_service.desc.bin")

// -----------------------------------------------------------------------------
// Descriptor subset conformance
// -----------------------------------------------------------------------------

@(test)
test_descriptor_fixture :: proc(t: ^testing.T) {
	f: reflection.FileDescriptorProto
	testing.expect_value(t, reflection.FileDescriptorProto_unmarshal(&f, FIXTURE_TEST_SERVICE, context.temp_allocator), pb.Error.None)
	testing.expect_value(t, f.name.?, "test_service.proto")
	testing.expect_value(t, f.package_.?, "test.svc")
	testing.expect_value(t, f.syntax.?, "proto3")

	if !testing.expect_value(t, len(f.message_type), 1) {
		return
	}
	echo := &f.message_type[0]
	testing.expect_value(t, echo.name.?, "Echo")
	want := [?]struct {
		name, type: string,
		number:     i32,
	} {
		{"text", "string", 1},
		{"seq", "int32", 2},
		{"payload", "bytes", 3},
		{"sleep_ms", "int32", 4},
		{"fail_code", "int32", 5},
		{"fail_message", "string", 6},
		{"count", "int32", 7},
		{"response_bytes", "int32", 8},
	}
	testing.expect_value(t, len(echo.field), len(want))
	for w, i in want {
		if i >= len(echo.field) {
			break
		}
		fd := &echo.field[i]
		testing.expect_value(t, fd.name.?, w.name)
		testing.expect_value(t, fd.number.?, w.number)
		testing.expect_value(t, reflection.field_type_string(fd, context.temp_allocator), w.type)
	}

	if !testing.expect_value(t, len(f.service), 1) {
		return
	}
	svc := &f.service[0]
	testing.expect_value(t, svc.name.?, "Tester")
	testing.expect_value(t, len(svc.method), 5)
	flags := [?][2]bool{{false, false}, {false, true}, {true, false}, {true, true}, {false, false}}
	for m, i in svc.method {
		testing.expect_value(t, m.input_type.?, ".test.svc.Echo")
		testing.expect_value(t, m.client_streaming.? or_else false, flags[i][0])
		testing.expect_value(t, m.server_streaming.? or_else false, flags[i][1])
	}

	// Re-encoding reproduces the reference bytes (no field lost or reordered).
	out, err := reflection.FileDescriptorProto_marshal(&f, context.temp_allocator)
	testing.expect_value(t, err, pb.Error.None)
	testing.expect_value(t, string(hex.encode(out, context.temp_allocator)), string(hex.encode(FIXTURE_TEST_SERVICE, context.temp_allocator)))
}

// -----------------------------------------------------------------------------
// A reflection server built with this package
// -----------------------------------------------------------------------------

Fake :: struct {
	services: []string,
	// Symbol -> serialized file descriptor.
	files:    map[string][]u8,
}

serve_reflection :: proc(srv: ^reflection.ServerReflection_Server, call: ^grpc.Server_Call, stream: reflection.ServerReflection_ServerReflectionInfo_Server) -> grpc.Status {
	fake := (^Fake)(srv.user_data)
	alloc := grpc.call_allocator(call)
	for {
		req: reflection.ServerReflectionRequest
		got, st := reflection.ServerReflection_ServerReflectionInfo_Server_recv(stream, &req)
		if !got {
			return st
		}
		resp := reflection.ServerReflectionResponse {
			original_request = &req,
		}
		switch r in req.message_request {
		case reflection.ServerReflectionRequest_Message_Request_List_Services:
			list := new(reflection.ListServiceResponse, alloc)
			list.service = make([dynamic]reflection.ServiceResponse, alloc)
			for s in fake.services {
				append(&list.service, reflection.ServiceResponse{name = s})
			}
			resp.message_response = reflection.ServerReflectionResponse_Message_Response_List_Services_Response(list)
		case reflection.ServerReflectionRequest_Message_Request_File_Containing_Symbol:
			switch string(r) {
			case "hostile.ZeroCode":
				// error_code 0 ("OK") with an error response.
				e := new(reflection.ErrorResponse, alloc)
				e.error_message = "zero"
				resp.message_response = reflection.ServerReflectionResponse_Message_Response_Error_Response(e)
			case "hostile.NegativeCode":
				e := new(reflection.ErrorResponse, alloc)
				e.error_code = -5
				resp.message_response = reflection.ServerReflectionResponse_Message_Response_Error_Response(e)
			case "hostile.WrongKind":
				// A list_services answer to a file request.
				resp.message_response = reflection.ServerReflectionResponse_Message_Response_List_Services_Response(new(reflection.ListServiceResponse, alloc))
			case "hostile.NoResponse":
				// Never answer, and ignore the client closing its side.
				time.sleep(1500 * time.Millisecond)
				return {}
			}
			if resp.message_response != nil {
				break
			}
			if data, ok := fake.files[string(r)]; ok {
				fd := new(reflection.FileDescriptorResponse, alloc)
				fd.file_descriptor_proto = make([dynamic][]u8, alloc)
				append(&fd.file_descriptor_proto, data)
				resp.message_response = reflection.ServerReflectionResponse_Message_Response_File_Descriptor_Response(fd)
			} else {
				e := new(reflection.ErrorResponse, alloc)
				e^ = {error_code = i32(grpc.Status_Code.Not_Found), error_message = "symbol not found"}
				resp.message_response = reflection.ServerReflectionResponse_Message_Response_Error_Response(e)
			}
		case reflection.ServerReflectionRequest_Message_Request_File_By_Filename, reflection.ServerReflectionRequest_Message_Request_File_Containing_Extension, reflection.ServerReflectionRequest_Message_Request_All_Extension_Numbers_Of_Type:
			e := new(reflection.ErrorResponse, alloc)
			e^ = {error_code = i32(grpc.Status_Code.Unimplemented), error_message = "not supported by the fake"}
			resp.message_response = reflection.ServerReflectionResponse_Message_Response_Error_Response(e)
		}
		if st = reflection.ServerReflection_ServerReflectionInfo_Server_send(stream, &resp); st.code != .OK {
			return st
		}
	}
}

// fake_descriptor builds a file with a nested message and a streaming
// service, encoded with the subset types.
fake_descriptor :: proc() -> []u8 {
	a := context.temp_allocator
	label_repeated := reflection.FieldDescriptorProto_Label.LABEL_REPEATED
	inner := reflection.DescriptorProto {
		name = "Inner",
	}
	inner.field = make([dynamic]reflection.FieldDescriptorProto, a)
	append(&inner.field, reflection.FieldDescriptorProto{name = "values", number = 1, type = .TYPE_SINT64, label = label_repeated})
	outer := reflection.DescriptorProto {
		name = "Outer",
	}
	outer.field = make([dynamic]reflection.FieldDescriptorProto, a)
	append(&outer.field, reflection.FieldDescriptorProto{name = "inner", number = 1, type = .TYPE_MESSAGE, type_name = ".fake.Outer.Inner"})
	append(&outer.field, reflection.FieldDescriptorProto{name = "id", number = 2, type = .TYPE_STRING})
	outer.nested_type = make([dynamic]reflection.DescriptorProto, a)
	append(&outer.nested_type, inner)

	svc := reflection.ServiceDescriptorProto {
		name = "Svc",
	}
	svc.method = make([dynamic]reflection.MethodDescriptorProto, a)
	append(&svc.method, reflection.MethodDescriptorProto{name = "Get", input_type = ".fake.Outer", output_type = ".fake.Outer.Inner"})
	append(&svc.method, reflection.MethodDescriptorProto{name = "Chat", input_type = ".fake.Outer", output_type = ".fake.Outer", client_streaming = true, server_streaming = true})

	f := reflection.FileDescriptorProto {
		name     = "fake.proto",
		package_ = "fake",
		syntax   = "proto3",
	}
	f.message_type = make([dynamic]reflection.DescriptorProto, a)
	append(&f.message_type, outer)
	f.service = make([dynamic]reflection.ServiceDescriptorProto, a)
	append(&f.service, svc)
	data, err := reflection.FileDescriptorProto_marshal(&f, a)
	assert(err == .None)
	return data
}

Fixture :: struct {
	fake:   Fake,
	impl:   reflection.ServerReflection_Server,
	desc:   grpc.Service_Desc,
	server: grpc.Server,
	ch:     ^grpc.Channel,
}

// start_server serves reflection under the given service name
// ("" = no reflection service at all).
start_server :: proc(f: ^Fixture, service_name: string) -> bool {
	desc := fake_descriptor()
	// Heap (temp) memory: a slice literal here would point into this frame.
	f.fake.services = make([]string, 3, context.temp_allocator)
	f.fake.services[0] = "fake.Svc"
	f.fake.services[1] = "test.svc.Tester"
	f.fake.services[2] = service_name
	f.fake.files = make(map[string][]u8, context.temp_allocator)
	f.fake.files["fake.Svc"] = desc
	f.fake.files["fake.Outer"] = desc
	f.fake.files["fake.Outer.Inner"] = desc
	f.fake.files["test.svc.Tester"] = FIXTURE_TEST_SERVICE
	f.impl = {
		user_data              = &f.fake,
		server_reflection_info = serve_reflection,
	}
	grpc.server_init(&f.server)
	if service_name != "" {
		f.desc = reflection.ServerReflection_SERVICE_DESC
		f.desc.name = service_name
		if !grpc.server_register(&f.server, &f.desc, &f.impl) {
			return false
		}
	}
	ep, ok := grpc.server_start(&f.server, "127.0.0.1:0")
	if !ok {
		return false
	}
	f.ch = grpc.channel_create(net.endpoint_to_string(ep, context.temp_allocator))
	return true
}

stop_server :: proc(f: ^Fixture) {
	grpc.channel_destroy(f.ch)
	grpc.server_shutdown(&f.server, time.Second)
	grpc.server_destroy(&f.server)
}

expect_reflection_works :: proc(t: ^testing.T, f: ^Fixture, want_version: reflection.Version, loc := #caller_location) {
	rc: reflection.Client
	reflection.client_init(&rc, f.ch, 10 * time.Second)
	defer reflection.client_destroy(&rc)

	services, st := reflection.list_services(&rc)
	testing.expectf(t, st.code == .OK, "list_services: %v %s", st.code, st.message, loc = loc)
	testing.expect_value(t, len(services), 3, loc)
	testing.expect_value(t, reflection.version_in_use(&rc), want_version, loc)

	// Several requests share one stream.
	info, dst := reflection.describe_service(&rc, "fake.Svc")
	testing.expect_value(t, dst.code, grpc.Status_Code.OK, loc)
	if testing.expect_value(t, len(info.methods), 2, loc) {
		testing.expect_value(t, info.methods[0].path, "/fake.Svc/Get", loc)
		testing.expect_value(t, info.methods[0].output_type, "fake.Outer.Inner", loc)
		testing.expect(t, !info.methods[0].client_streaming && !info.methods[0].server_streaming, loc = loc)
		testing.expect(t, info.methods[1].client_streaming && info.methods[1].server_streaming, loc = loc)
	}

	tester, tst := reflection.describe_service(&rc, ".test.svc.Tester") // leading dot accepted
	testing.expect_value(t, tst.code, grpc.Status_Code.OK, loc)
	testing.expect_value(t, len(tester.methods), 5, loc)

	inner, file, mst := reflection.describe_message(&rc, "fake.Outer.Inner")
	testing.expect_value(t, mst.code, grpc.Status_Code.OK, loc)
	if inner != nil && file != nil {
		testing.expect_value(t, file.name.?, "fake.proto", loc)
		testing.expect_value(t, reflection.field_type_string(&inner.field[0], context.temp_allocator), "repeated sint64", loc)
	}
	outer, _, ost := reflection.describe_message(&rc, ".fake.Outer") // leading dot accepted
	testing.expect_value(t, ost.code, grpc.Status_Code.OK, loc)
	if outer != nil {
		testing.expect_value(t, reflection.field_type_string(&outer.field[0], context.temp_allocator), "fake.Outer.Inner", loc)
	}

	// Server-side errors arrive as statuses; the session stays usable.
	_, est := reflection.describe_service(&rc, "no.Such")
	testing.expect_value(t, est.code, grpc.Status_Code.Not_Found, loc)
	_, _, est = reflection.describe_message(&rc, "fake.Missing")
	testing.expect_value(t, est.code, grpc.Status_Code.Not_Found, loc)
	_, again := reflection.list_services(&rc)
	testing.expect_value(t, again.code, grpc.Status_Code.OK, loc)
}

@(test)
test_v1_server :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start_server(&f, "grpc.reflection.v1.ServerReflection")) {
		return
	}
	defer stop_server(&f)
	expect_reflection_works(t, &f, .V1)
}

@(test)
test_v1alpha_fallback :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start_server(&f, "grpc.reflection.v1alpha.ServerReflection")) {
		return
	}
	defer stop_server(&f)
	expect_reflection_works(t, &f, .V1_Alpha)
}

@(test)
test_server_without_reflection :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start_server(&f, "")) {
		return
	}
	defer stop_server(&f)
	rc: reflection.Client
	reflection.client_init(&rc, f.ch, 10 * time.Second)
	defer reflection.client_destroy(&rc)
	_, st := reflection.list_services(&rc)
	testing.expect_value(t, st.code, grpc.Status_Code.Unimplemented)
}

@(test)
test_unreachable_server :: proc(t: ^testing.T) {
	ep, _ := net.parse_endpoint("127.0.0.1:0")
	sock, _ := net.listen_tcp(ep)
	bound, _ := net.bound_endpoint(sock)
	net.close(sock)
	ch := grpc.channel_create(net.endpoint_to_string(bound, context.temp_allocator))
	defer grpc.channel_destroy(ch)
	rc: reflection.Client
	reflection.client_init(&rc, ch)
	defer reflection.client_destroy(&rc)
	_, st := reflection.list_services(&rc)
	testing.expect_value(t, st.code, grpc.Status_Code.Unavailable)
}

// Hostile or broken reflection servers produce statuses, never crashes or
// hangs (review findings).
@(test)
test_hostile_reflection_server :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, start_server(&f, "grpc.reflection.v1.ServerReflection")) {
		return
	}
	defer stop_server(&f)
	rc: reflection.Client
	reflection.client_init(&rc, f.ch, 300 * time.Millisecond, {{"x-session", "1"}})

	_, st := reflection.file_containing_symbol(&rc, "hostile.ZeroCode")
	testing.expect_value(t, st.code, grpc.Status_Code.Unknown)
	_, st = reflection.file_containing_symbol(&rc, "hostile.NegativeCode")
	testing.expect_value(t, st.code, grpc.Status_Code.Unknown)
	_, st = reflection.describe_service(&rc, "hostile.ZeroCode")
	testing.expect_value(t, st.code, grpc.Status_Code.Unknown)
	_, st = reflection.file_containing_symbol(&rc, "hostile.WrongKind")
	testing.expect_value(t, st.code, grpc.Status_Code.Internal)
	// The session recovers on a new stream.
	_, st = reflection.list_services(&rc)
	testing.expect_value(t, st.code, grpc.Status_Code.OK)

	// A server that never answers: the request times out, and destroying
	// the session does not wait for the server.
	start := time.tick_now()
	_, st = reflection.file_containing_symbol(&rc, "hostile.NoResponse")
	testing.expect_value(t, st.code, grpc.Status_Code.Deadline_Exceeded)
	_, st = reflection.list_services(&rc)
	testing.expect_value(t, st.code, grpc.Status_Code.OK)
	reflection.client_destroy(&rc)
	testing.expectf(t, time.tick_since(start) < 1200 * time.Millisecond, "took %v", time.tick_since(start))
}
