package reflection_test

import "core:net"
import "core:slice"
import "core:testing"
import "core:time"

import "grpc:grpc"
import pb "grpc:protobuf"
import "grpc:reflection"
import testpb "../protobuf/gen"
import testsvc "../grpc/gen"

Served :: struct {
	server: grpc.Server,
	refl:   reflection.Server,
	tester: testsvc.Tester_Server, // no methods: reflection only describes it
	ch:     ^grpc.Channel,
}

serve :: proc(s: ^Served) -> bool {
	grpc.server_init(&s.server)
	if !testsvc.Tester_register(&s.server, &s.tester) {
		return false
	}
	if !reflection.server_register(&s.refl, &s.server, testsvc.FILE_DESCRIPTORS[:], testpb.FILE_DESCRIPTORS[:]) {
		return false
	}
	ep, ok := grpc.server_start(&s.server, "127.0.0.1:0")
	if !ok {
		return false
	}
	s.ch = grpc.channel_create(net.endpoint_to_string(ep, context.temp_allocator))
	return true
}

unserve :: proc(s: ^Served) {
	grpc.channel_destroy(s.ch)
	grpc.server_shutdown(&s.server, time.Second)
	reflection.server_destroy(&s.refl)
	grpc.server_destroy(&s.server)
}

file_names :: proc(files: []^reflection.FileDescriptorProto) -> []string {
	names := make([]string, len(files), context.temp_allocator)
	for f, i in files {
		names[i] = f.name.? or_else ""
	}
	return names
}

@(test)
test_reflection_server :: proc(t: ^testing.T) {
	s: Served
	if !testing.expect(t, serve(&s)) {
		return
	}
	defer unserve(&s)

	rc: reflection.Client
	reflection.client_init(&rc, s.ch, 10 * time.Second)
	defer reflection.client_destroy(&rc)

	// Services registered on the grpc.Server, including reflection itself.
	services, st := reflection.list_services(&rc)
	testing.expect_value(t, st.code, grpc.Status_Code.OK)
	testing.expect_value(t, reflection.version_in_use(&rc), reflection.Version.V1)
	testing.expect(t, slice.contains(services, "test.svc.Tester"))
	testing.expect(t, slice.contains(services, "grpc.reflection.v1.ServerReflection"))
	testing.expect(t, slice.contains(services, "grpc.reflection.v1alpha.ServerReflection"))

	info, ist := reflection.describe_service(&rc, "test.svc.Tester")
	testing.expect_value(t, ist.code, grpc.Status_Code.OK)
	if testing.expect_value(t, len(info.methods), 5) {
		testing.expect_value(t, info.methods[3].name, "Bidi")
		testing.expect(t, info.methods[3].client_streaming && info.methods[3].server_streaming)
		testing.expect_value(t, info.methods[0].input_type, "test.svc.Echo")
	}

	// The served descriptor is exactly what Google's protoc produces.
	files, fst := reflection.file_by_filename(&rc, "test_service.proto")
	testing.expect_value(t, fst.code, grpc.Status_Code.OK)
	if len(files) > 0 {
		data, _ := reflection.FileDescriptorProto_marshal(files[0], context.temp_allocator)
		testing.expect(t, string(data) == string(FIXTURE_TEST_SERVICE))
	}

	// A file is sent with its transitive dependencies, once per stream.
	deps, dst := reflection.file_containing_symbol(&rc, "test.all.WithWellKnown")
	testing.expect_value(t, dst.code, grpc.Status_Code.OK)
	names := file_names(deps)
	testing.expect(t, len(names) > 0 && names[0] == "test_all.proto")
	for want in ([]string{"legacy.proto", "google/protobuf/timestamp.proto", "google/protobuf/struct.proto"}) {
		testing.expectf(t, slice.contains(names, want), "missing dependency %s in %v", want, names)
	}
	again, _ := reflection.file_containing_symbol(&rc, "test.legacy.Legacy")
	testing.expect_value(t, len(again), 1) // dependencies already sent

	// Every kind of symbol resolves.
	symbols := []string {
		"test.svc.Tester.Unary", // method
		"test.all.Scalars.f_int32", // field
		"test.all.COLOR_RED", // enum value (sibling of its enum)
		"test.all.Nested.Mode", // nested enum
		"test.all.Nested.Inner.Deepest", // nested message
		"test.all.Choice.kind", // oneof
		".test.all.Tree", // leading dot
	}
	for sym in symbols {
		_, sst := reflection.file_containing_symbol(&rc, sym)
		testing.expectf(t, sst.code == .OK, "symbol %s: %v %s", sym, sst.code, sst.message)
	}

	// Synthesized map entries and nested types are described.
	entry, _, est := reflection.describe_message(&rc, "test.all.Maps.MStringMessageEntry")
	testing.expect_value(t, est.code, grpc.Status_Code.OK)
	if entry != nil && len(entry.field) == 2 {
		testing.expect_value(t, reflection.field_type_string(&entry.field[1], context.temp_allocator), "test.all.Scalars")
	}

	// The reflection service describes itself, under both versions.
	for svc in ([]string{"grpc.reflection.v1.ServerReflection", "grpc.reflection.v1alpha.ServerReflection"}) {
		r, rst := reflection.describe_service(&rc, svc)
		testing.expectf(t, rst.code == .OK && len(r.methods) == 1, "%s: %v", svc, rst.code)
	}
	alpha, _, ast := reflection.describe_message(&rc, "grpc.reflection.v1alpha.ServerReflectionResponse")
	testing.expect_value(t, ast.code, grpc.Status_Code.OK)
	if alpha != nil {
		for &field in alpha.field {
			if field.name.? == "list_services_response" {
				testing.expect_value(t, field.type_name.?, ".grpc.reflection.v1alpha.ListServiceResponse")
			}
		}
	}

	// Unknown names.
	_, nst := reflection.file_containing_symbol(&rc, "no.such.Thing")
	testing.expect_value(t, nst.code, grpc.Status_Code.Not_Found)
	_, nst = reflection.file_by_filename(&rc, "missing.proto")
	testing.expect_value(t, nst.code, grpc.Status_Code.Not_Found)
}

@(test)
test_reflection_register_twice :: proc(t: ^testing.T) {
	server: grpc.Server
	grpc.server_init(&server)
	defer grpc.server_destroy(&server)
	a, b: reflection.Server
	testing.expect(t, reflection.server_register(&a, &server, testsvc.FILE_DESCRIPTORS[:]))
	testing.expect(t, !reflection.server_register(&b, &server, testsvc.FILE_DESCRIPTORS[:]))
	reflection.server_destroy(&a)
}

@(test)
test_reflection_register_rules :: proc(t: ^testing.T) {
	server: grpc.Server
	grpc.server_init(&server)
	defer grpc.server_destroy(&server)

	// The same symbol defined by two different files is a conflict.
	// FileDescriptorProto{name: "clash.proto", package: "test.svc",
	//   message_type: [{name: "Echo"}]}
	clash := pb.File_Descriptor {
		name = "clash.proto",
		data = "\x0a\x0bclash.proto\x12\x08test.svc\x22\x06\x0a\x04Echo",
	}
	files := []^pb.File_Descriptor{&clash}
	r: reflection.Server
	testing.expect(t, !reflection.server_register(&r, &server, testsvc.FILE_DESCRIPTORS[:], files))
	testing.expect_value(t, len(grpc.server_services(&server)), 0)

	// The reflection package's own descriptors are accepted (and skipped).
	testing.expect(t, reflection.server_register(&r, &server, reflection.FILE_DESCRIPTORS[:], testsvc.FILE_DESCRIPTORS[:]))
	testing.expect_value(t, len(grpc.server_services(&server)), 2)
	reflection.server_destroy(&r)
}

@(test)
test_register_after_start_is_refused :: proc(t: ^testing.T) {
	server: grpc.Server
	grpc.server_init(&server)
	defer grpc.server_destroy(&server)
	_, ok := grpc.server_start(&server, "127.0.0.1:0")
	testing.expect(t, ok)
	impl: testsvc.Tester_Server
	testing.expect(t, !testsvc.Tester_register(&server, &impl))
	r: reflection.Server
	testing.expect(t, !reflection.server_register(&r, &server, testsvc.FILE_DESCRIPTORS[:]))
	grpc.server_shutdown(&server, time.Second)
}

@(test)
test_reflection_rejects_conflicting_files :: proc(t: ^testing.T) {
	server: grpc.Server
	grpc.server_init(&server)
	defer grpc.server_destroy(&server)
	fake := pb.File_Descriptor {
		name = "test_service.proto",
		data = "\x0a\x03abc",
	}
	files := []^pb.File_Descriptor{testsvc.FILE_DESCRIPTORS[0], &fake}
	r: reflection.Server
	testing.expect(t, !reflection.server_register(&r, &server, files))
	// Nothing was registered by the failed attempt.
	testing.expect_value(t, len(grpc.server_services(&server)), 0)
}
