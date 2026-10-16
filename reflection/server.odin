package reflection

import "base:runtime"
import vmem "core:mem/virtual"
import "core:strings"

import "../grpc"
import pb "../protobuf"

/*
Server-side reflection: serves grpc.reflection.v1 and v1alpha for a
grpc.Server, describing the files whose embedded descriptors are given
(odin-protoc generates them; each generated package lists its files in
FILE_DESCRIPTORS):

    refl: reflection.Server
    reflection.server_register(&refl, &server, pb_a.FILE_DESCRIPTORS[:], pb_b.FILE_DESCRIPTORS[:])
    defer reflection.server_destroy(&refl)   // after grpc.server_shutdown

Register before grpc.server_start. The Server must stay at the same address
while registered (the grpc.Server keeps pointers into it).

list_services reports every service registered on the grpc.Server at the
time of the request (including both reflection services).
*/

// Server holds the descriptor index served by reflection.
Server :: struct {
	arena:         vmem.Arena,
	allocator:     runtime.Allocator,
	grpc_server:   ^grpc.Server,
	files:         map[string]^Indexed_File, // by file name
	symbols:       map[string]^Indexed_File, // fully qualified symbol -> file
	message_types: map[string]bool,
	impl:          ServerReflection_Server,
	v1_desc:       grpc.Service_Desc,
	v1alpha_desc:  grpc.Service_Desc,
}

@(private = "file")
Indexed_File :: struct {
	name: string,
	data: []u8,
	deps: []string,
}

// server_register indexes the given descriptor lists (typically each
// generated package's FILE_DESCRIPTORS) and registers the reflection
// service (v1 and v1alpha) on `server`. `rs` must be zero or destroyed. The
// descriptors must outlive the Server (generated ones are global). Returns
// false (registering nothing) if a descriptor is malformed, two different
// files share a name or define the same symbol, the server is already
// serving, or reflection is already registered.
server_register :: proc(rs: ^Server, server: ^grpc.Server, file_lists: ..[]^pb.File_Descriptor) -> bool {
	rs^ = {}
	// Check both names first, so a failure leaves the server untouched.
	for name in grpc.server_services(server) {
		if name == "grpc.reflection.v1.ServerReflection" || name == "grpc.reflection.v1alpha.ServerReflection" {
			return false
		}
	}
	if vmem.arena_init_growing(&rs.arena) != nil {
		return false
	}
	rs.allocator = vmem.arena_allocator(&rs.arena)
	rs.grpc_server = server
	rs.files = make(map[string]^Indexed_File, rs.allocator)
	rs.symbols = make(map[string]^Indexed_File, rs.allocator)
	rs.message_types = make(map[string]bool, rs.allocator)

	// The reflection protocol's own files, so that clients can describe it.
	own := grpc_reflection_v1_reflection_FILE_DESCRIPTOR
	alpha, alpha_ok := v1alpha_descriptor(transmute([]u8)own.data, rs.allocator)
	if !alpha_ok || !index_file(rs, own.name, transmute([]u8)own.data) || !index_file(rs, V1ALPHA_FILE, alpha) {
		server_destroy(rs)
		return false
	}
	for files in file_lists {
		for f in files {
			// The reflection package's private descriptor.proto subset is an
			// implementation detail, not a schema to serve.
			if f.name == "odin_grpc/descriptor_subset.proto" || f.name == own.name {
				continue
			}
			if !index_file(rs, f.name, transmute([]u8)f.data) {
				server_destroy(rs)
				return false
			}
		}
	}

	rs.impl = {
		user_data              = rs,
		server_reflection_info = serve_stream,
	}
	rs.v1_desc = ServerReflection_SERVICE_DESC
	rs.v1alpha_desc = ServerReflection_SERVICE_DESC
	rs.v1alpha_desc.name = "grpc.reflection.v1alpha.ServerReflection"
	if !grpc.server_register(server, &rs.v1_desc, &rs.impl) {
		server_destroy(rs)
		return false
	}
	// Cannot fail: both names were checked above and the server is not
	// serving (otherwise the first registration would have failed).
	ok := grpc.server_register(server, &rs.v1alpha_desc, &rs.impl)
	assert(ok)
	return true
}

// V1ALPHA_FILE is the synthesized v1alpha reflection file's name (as grpcio
// names it).
@(private = "file")
V1ALPHA_FILE :: "grpc_reflection/v1alpha/reflection.proto"

// server_destroy frees the index. The grpc.Server must be shut down first.
server_destroy :: proc(rs: ^Server) {
	vmem.arena_destroy(&rs.arena)
	rs^ = {}
}

// -----------------------------------------------------------------------------
// Indexing
// -----------------------------------------------------------------------------

@(private = "file")
index_file :: proc(rs: ^Server, name: string, data: []u8) -> bool {
	if existing, dup := rs.files[name]; dup {
		// The same file embedded by two generated packages is fine.
		return string(existing.data) == string(data)
	}
	fd: FileDescriptorProto
	if FileDescriptorProto_unmarshal(&fd, data, rs.allocator, {alias_input = true}) != .None {
		return false
	}
	f := new(Indexed_File, rs.allocator)
	f.name = name
	f.data = data
	f.deps = fd.dependency[:]
	rs.files[name] = f

	pkg := fd.package_.? or_else ""
	ok := true
	for &m in fd.message_type {
		ok &= index_message(rs, f, pkg, &m)
	}
	for &e in fd.enum_type {
		ok &= index_enum(rs, f, pkg, &e)
	}
	for &s in fd.service {
		svc := join(rs, pkg, s.name.? or_else "")
		ok &= define(rs, svc, f)
		for &m in s.method {
			ok &= define(rs, join(rs, svc, m.name.? or_else ""), f)
		}
	}
	for &ext in fd.extension {
		ok &= define(rs, join(rs, pkg, ext.name.? or_else ""), f)
	}
	return ok
}

// define records a symbol; one defined by two different files is a
// conflict (protobuf requires unique fully qualified names).
@(private = "file")
define :: proc(rs: ^Server, name: string, f: ^Indexed_File) -> bool {
	if prev, dup := rs.symbols[name]; dup && prev != f {
		return false
	}
	rs.symbols[name] = f
	return true
}

@(private = "file")
index_message :: proc(rs: ^Server, f: ^Indexed_File, scope: string, m: ^DescriptorProto) -> bool {
	name := join(rs, scope, m.name.? or_else "")
	ok := define(rs, name, f)
	rs.message_types[name] = true
	for &field in m.field {
		ok &= define(rs, join(rs, name, field.name.? or_else ""), f)
	}
	for &o in m.oneof_decl {
		ok &= define(rs, join(rs, name, o.name.? or_else ""), f)
	}
	for &ext in m.extension {
		ok &= define(rs, join(rs, name, ext.name.? or_else ""), f)
	}
	for &n in m.nested_type {
		ok &= index_message(rs, f, name, &n)
	}
	for &e in m.enum_type {
		ok &= index_enum(rs, f, name, &e)
	}
	return ok
}

@(private = "file")
index_enum :: proc(rs: ^Server, f: ^Indexed_File, scope: string, e: ^EnumDescriptorProto) -> bool {
	ok := define(rs, join(rs, scope, e.name.? or_else ""), f)
	// Enum values are scoped as siblings of their enum (C++ scoping).
	for &v in e.value {
		ok &= define(rs, join(rs, scope, v.name.? or_else ""), f)
	}
	return ok
}

@(private = "file")
join :: proc(rs: ^Server, scope, name: string) -> string {
	if scope == "" {
		return name
	}
	return strings.concatenate({scope, ".", name}, rs.allocator)
}

// v1alpha_descriptor derives the v1alpha reflection file from the v1 one:
// same messages, another package.
@(private = "file")
v1alpha_descriptor :: proc(v1: []u8, a: runtime.Allocator) -> ([]u8, bool) {
	fd: FileDescriptorProto
	if FileDescriptorProto_unmarshal(&fd, v1, a) != .None {
		return nil, false
	}
	OLD :: ".grpc.reflection.v1."
	NEW :: ".grpc.reflection.v1alpha."
	rename :: proc(s: ^Maybe(string), a: runtime.Allocator) {
		if v, ok := s.?; ok && strings.has_prefix(v, OLD) {
			s^ = strings.concatenate({NEW, v[len(OLD):]}, a)
		}
	}
	fd.name = V1ALPHA_FILE
	fd.package_ = "grpc.reflection.v1alpha"
	for &m in fd.message_type {
		for &field in m.field {
			rename(&field.type_name, a)
		}
	}
	for &s in fd.service {
		for &m in s.method {
			rename(&m.input_type, a)
			rename(&m.output_type, a)
		}
	}
	out, err := FileDescriptorProto_marshal(&fd, a)
	return out, err == .None
}

// -----------------------------------------------------------------------------
// Serving
// -----------------------------------------------------------------------------

@(private = "file")
serve_stream :: proc(srv: ^ServerReflection_Server, call: ^grpc.Server_Call, stream: ServerReflection_ServerReflectionInfo_Server) -> grpc.Status {
	rs := (^Server)(srv.user_data)
	// Files already sent on this stream (dependencies are sent once).
	sent := make(map[string]bool, grpc.call_allocator(call))
	// Each request/response pair lives in a scratch arena reset per message,
	// so a long-lived reflection stream does not accumulate memory.
	scratch: vmem.Arena
	if vmem.arena_init_growing(&scratch) != nil {
		return {.Resource_Exhausted, "out of memory"}
	}
	defer vmem.arena_destroy(&scratch)
	for {
		vmem.arena_free_all(&scratch)
		a := vmem.arena_allocator(&scratch)
		req: ServerReflectionRequest
		got, st := grpc.server_recv_with(call, &req, &ServerReflectionRequest_CODEC, a)
		if !got {
			return st
		}
		resp := ServerReflectionResponse {
			valid_host       = req.host,
			original_request = &req,
		}
		switch r in req.message_request {
		case ServerReflectionRequest_Message_Request_List_Services:
			list := new(ListServiceResponse, a)
			services := grpc.server_services(rs.grpc_server)
			list.service = make([dynamic]ServiceResponse, 0, len(services), a)
			for name in services {
				append(&list.service, ServiceResponse{name = name})
			}
			resp.message_response = ServerReflectionResponse_Message_Response_List_Services_Response(list)
		case ServerReflectionRequest_Message_Request_File_By_Filename:
			if f, ok := rs.files[string(r)]; ok {
				resp.message_response = files_response(rs, f, &sent, a)
			} else {
				resp.message_response = error_response(.Not_Found, "file not found", a)
			}
		case ServerReflectionRequest_Message_Request_File_Containing_Symbol:
			if f, ok := rs.symbols[strings.trim_prefix(string(r), ".")]; ok {
				resp.message_response = files_response(rs, f, &sent, a)
			} else {
				resp.message_response = error_response(.Not_Found, "symbol not found", a)
			}
		case ServerReflectionRequest_Message_Request_File_Containing_Extension:
			resp.message_response = error_response(.Not_Found, "extensions are not supported", a)
		case ServerReflectionRequest_Message_Request_All_Extension_Numbers_Of_Type:
			name := strings.trim_prefix(string(r), ".")
			if rs.message_types[name] {
				nums := new(ExtensionNumberResponse, a)
				nums.base_type_name = name
				resp.message_response = ServerReflectionResponse_Message_Response_All_Extension_Numbers_Response(nums)
			} else {
				resp.message_response = error_response(.Not_Found, "type not found", a)
			}
		case:
			resp.message_response = error_response(.Invalid_Argument, "empty reflection request", a)
		}
		if st = ServerReflection_ServerReflectionInfo_Server_send(stream, &resp); st.code != .OK {
			return st
		}
	}
}

@(private = "file")
error_response :: proc(code: grpc.Status_Code, message: string, a: runtime.Allocator) -> ServerReflectionResponse_Message_Response {
	e := new(ErrorResponse, a)
	e.error_code = i32(code)
	e.error_message = message
	return ServerReflectionResponse_Message_Response_Error_Response(e)
}

// files_response returns f and, depth first, its transitive dependencies
// that were not sent on this stream yet (the requested file always is).
@(private = "file")
files_response :: proc(rs: ^Server, f: ^Indexed_File, sent: ^map[string]bool, a: runtime.Allocator) -> ServerReflectionResponse_Message_Response {
	out := new(FileDescriptorResponse, a)
	out.file_descriptor_proto = make([dynamic][]u8, a)
	append(&out.file_descriptor_proto, f.data)
	sent[f.name] = true
	add_deps :: proc(rs: ^Server, f: ^Indexed_File, sent: ^map[string]bool, out: ^FileDescriptorResponse) {
		for dep in f.deps {
			d, known := rs.files[dep]
			if !known || sent[dep] {
				continue
			}
			sent[dep] = true
			append(&out.file_descriptor_proto, d.data)
			add_deps(rs, d, sent, out)
		}
	}
	add_deps(rs, f, sent, out)
	return ServerReflectionResponse_Message_Response_File_Descriptor_Response(out)
}
