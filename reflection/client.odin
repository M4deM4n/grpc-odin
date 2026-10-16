/*
Package reflection is a client for the gRPC Server Reflection Protocol
(grpc.reflection.v1 and v1alpha): it lists the services a server exposes and
retrieves their descriptors, without needing the server's .proto files.

    rc: reflection.Client
    reflection.client_init(&rc, channel)
    defer reflection.client_destroy(&rc)

    services, st := reflection.list_services(&rc)
    for name in services {
        info, _ := reflection.describe_service(&rc, name)
        for m in info.methods {
            fmt.println(m.path, m.input_type, "->", m.output_type)
        }
    }

The client speaks v1 first and falls back to v1alpha when the server does
not implement v1 (many servers, e.g. grpcio, only serve v1alpha). Both use
the same messages, so one set of types serves both.

Memory: every result (and every response received) is allocated in an
arena owned by the Client and stays valid until client_destroy. A Client is
meant for a discovery session; for long-running use, recreate it
periodically to release what it accumulated.
*/
package reflection

import "base:runtime"
import vmem "core:mem/virtual"
import "core:strings"
import "core:time"

import "../grpc"

// Version is the reflection protocol version a session speaks.
Version :: enum u8 {
	V1, // grpc.reflection.v1.ServerReflection
	V1_Alpha, // grpc.reflection.v1alpha.ServerReflection (older servers)
}

// DEFAULT_REQUEST_TIMEOUT bounds each request/response exchange.
DEFAULT_REQUEST_TIMEOUT :: 30 * time.Second

// ServerReflectionInfo under its pre-v1 name; the messages are
// wire-identical to v1.
@(private = "file")
v1alpha_method := grpc.Method_Desc {
	path             = "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo",
	client_streaming = true,
	server_streaming = true,
	request          = &ServerReflectionRequest_CODEC,
	response         = &ServerReflectionResponse_CODEC,
}

// Client is a reflection session: one bidirectional stream, reused for
// every request. Not safe for concurrent use; create one per thread.
Client :: struct {
	channel:         ^grpc.Channel,
	request_timeout: time.Duration,
	metadata:        []grpc.Metadata_Entry, // copied into the arena
	arena:           vmem.Arena,
	allocator:       runtime.Allocator,
	stream:          ^grpc.Client_Stream,
	version:         Version,
	// A response arrived on the current protocol version, so it is the
	// one the server implements: no more fallback.
	confirmed:       bool,
	// Decoded file descriptors by file name.
	files:           map[string]^FileDescriptorProto,
}

// Method_Info describes one RPC of a service.
Method_Info :: struct {
	name:             string, // e.g. "SayHello"
	path:             string, // e.g. "/helloworld.Greeter/SayHello"
	input_type:       string, // fully qualified, without leading dot
	output_type:      string,
	client_streaming: bool,
	server_streaming: bool,
}

// Service_Info describes a service and the file that declares it.
Service_Info :: struct {
	name:    string, // fully qualified
	file:    ^FileDescriptorProto,
	methods: []Method_Info,
}

// client_init prepares a session on `channel`. Each request waits at most
// `request_timeout` for its response (<= 0 selects
// DEFAULT_REQUEST_TIMEOUT). `metadata` is sent with the session (copied).
client_init :: proc(c: ^Client, channel: ^grpc.Channel, request_timeout: time.Duration = 0, metadata: []grpc.Metadata_Entry = nil) -> grpc.Status {
	c^ = {}
	c.channel = channel
	if vmem.arena_init_growing(&c.arena) != nil {
		return {.Resource_Exhausted, "out of memory"}
	}
	c.allocator = vmem.arena_allocator(&c.arena)
	c.request_timeout = request_timeout if request_timeout > 0 else DEFAULT_REQUEST_TIMEOUT
	c.metadata = make([]grpc.Metadata_Entry, len(metadata), c.allocator)
	for e, i in metadata {
		c.metadata[i] = {strings.clone(e.key, c.allocator), strings.clone(e.value, c.allocator)}
	}
	c.files = make(map[string]^FileDescriptorProto, c.allocator)
	return {}
}

// client_destroy ends the session and frees every result it returned.
client_destroy :: proc(c: ^Client) {
	close_stream(c)
	vmem.arena_destroy(&c.arena)
	c^ = {}
}

// version_in_use reports which protocol version the session speaks.
version_in_use :: proc(c: ^Client) -> Version {
	return c.version
}

// close_stream releases the stream without waiting for the server:
// client_destroy cancels the RPC if it is still running.
@(private = "file")
close_stream :: proc(c: ^Client) {
	if c.stream != nil {
		grpc.client_destroy(c.stream)
		c.stream = nil
	}
}

@(private = "file")
method_for :: proc(v: Version) -> ^grpc.Method_Desc {
	return &ServerReflection_ServerReflectionInfo_METHOD if v == .V1 else &v1alpha_method
}

@(private = "file")
Response_Kind :: enum u8 {
	List_Services,
	Files,
}

// exchange sends one request and returns its response, (re)opening the
// stream and falling back to v1alpha as needed. Error responses become
// statuses; a response of the wrong kind means the stream is out of step
// with our requests, so it is dropped.
@(private = "file")
exchange :: proc(c: ^Client, req: ^ServerReflectionRequest, want: Response_Kind) -> (resp: ^ServerReflectionResponse, st: grpc.Status) {
	for {
		if c.stream == nil {
			opts := grpc.Call_Options {
				metadata  = c.metadata,
				allocator = c.allocator,
			}
			c.stream, st = grpc.client_new_stream(c.channel, method_for(c.version), opts)
			if st.code != .OK {
				c.stream = nil
				return nil, st
			}
		}
		grpc.client_set_deadline(c.stream, grpc.deadline_after(c.request_timeout))
		st = grpc.client_send(c.stream, req)
		got := false
		r := new(ServerReflectionResponse, c.allocator)
		if st.code == .OK {
			got, st = grpc.client_recv(c.stream, r)
			if st.code == .OK && !got {
				st = {.Internal, "reflection stream ended without a response"}
			}
		}
		if st.code == .OK {
			c.confirmed = true
			if e, is_error := r.message_response.(ServerReflectionResponse_Message_Response_Error_Response); is_error {
				return nil, error_status(e)
			}
			if !response_matches(r, want) {
				close_stream(c)
				return nil, {.Internal, "reflection response does not match the request"}
			}
			return r, {}
		}
		// The stream is unusable after a failure; the next request opens
		// a new one.
		close_stream(c)
		if st.code == .Unimplemented && c.version == .V1 && !c.confirmed {
			c.version = .V1_Alpha
			continue
		}
		return nil, st
	}
}

// error_status converts an ErrorResponse. Codes come from the peer, so
// anything outside the defined non-OK range becomes UNKNOWN.
@(private = "file")
error_status :: proc(e: ServerReflectionResponse_Message_Response_Error_Response) -> grpc.Status {
	if e == nil {
		return {.Unknown, "reflection error response without details"}
	}
	code := grpc.Status_Code.Unknown
	if e.error_code >= 1 && e.error_code <= i32(grpc.Status_Code.Unauthenticated) {
		code = grpc.Status_Code(e.error_code)
	}
	return {code, e.error_message}
}

@(private = "file")
response_matches :: proc(r: ^ServerReflectionResponse, want: Response_Kind) -> bool {
	switch want {
	case .List_Services:
		v, ok := r.message_response.(ServerReflectionResponse_Message_Response_List_Services_Response)
		return ok && v != nil
	case .Files:
		v, ok := r.message_response.(ServerReflectionResponse_Message_Response_File_Descriptor_Response)
		return ok && v != nil
	}
	return false
}

// list_services returns the fully qualified names of the services the
// server exposes (including the reflection service itself).
list_services :: proc(c: ^Client) -> (names: []string, st: grpc.Status) {
	req := ServerReflectionRequest {
		message_request = ServerReflectionRequest_Message_Request_List_Services("*"),
	}
	resp: ^ServerReflectionResponse
	if resp, st = exchange(c, &req, .List_Services); st.code != .OK {
		return nil, st
	}
	list := resp.message_response.(ServerReflectionResponse_Message_Response_List_Services_Response)
	names = make([]string, len(list.service), c.allocator)
	for s, i in list.service {
		names[i] = s.name
	}
	return names, {}
}

// file_containing_symbol asks the server for the file declaring `symbol` (a
// fully qualified service, method, message, enum or field name). The server
// returns that file first, optionally followed by its dependencies.
file_containing_symbol :: proc(c: ^Client, symbol: string) -> (files: []^FileDescriptorProto, st: grpc.Status) {
	req := ServerReflectionRequest {
		message_request = ServerReflectionRequest_Message_Request_File_Containing_Symbol(strings.trim_prefix(symbol, ".")),
	}
	return request_files(c, &req)
}

// file_by_filename returns the descriptor of a file by its path (as used in
// imports, e.g. "google/protobuf/empty.proto"). A file already received in
// this session is returned from the cache, alone; otherwise the server's
// answer is returned, which may include dependencies.
file_by_filename :: proc(c: ^Client, filename: string) -> (files: []^FileDescriptorProto, st: grpc.Status) {
	if f, ok := c.files[filename]; ok {
		out := make([]^FileDescriptorProto, 1, c.allocator)
		out[0] = f
		return out, {}
	}
	req := ServerReflectionRequest {
		message_request = ServerReflectionRequest_Message_Request_File_By_Filename(filename),
	}
	return request_files(c, &req)
}

@(private = "file")
request_files :: proc(c: ^Client, req: ^ServerReflectionRequest) -> (files: []^FileDescriptorProto, st: grpc.Status) {
	resp: ^ServerReflectionResponse
	if resp, st = exchange(c, req, .Files); st.code != .OK {
		return nil, st
	}
	fd := resp.message_response.(ServerReflectionResponse_Message_Response_File_Descriptor_Response)
	files = make([]^FileDescriptorProto, len(fd.file_descriptor_proto), c.allocator)
	for raw, i in fd.file_descriptor_proto {
		f := new(FileDescriptorProto, c.allocator)
		if err := FileDescriptorProto_unmarshal(f, raw, c.allocator); err != .None {
			return nil, {.Internal, "failed to decode a file descriptor"}
		}
		files[i] = f
	}
	for f in files {
		if name, has := f.name.?; has && name not_in c.files {
			c.files[name] = f
		}
	}
	return files, {}
}

// describe_service returns the methods of a service (fully qualified name;
// a leading dot is accepted).
describe_service :: proc(c: ^Client, service: string) -> (info: Service_Info, st: grpc.Status) {
	name := strings.trim_prefix(service, ".")
	if s, f := find_service(c.files, name); s != nil {
		return service_info(c, s, f, name), {}
	}
	files: []^FileDescriptorProto
	if files, st = file_containing_symbol(c, name); st.code != .OK {
		return {}, st
	}
	for f in files {
		if s := find_service_in(f, name); s != nil {
			return service_info(c, s, f, name), {}
		}
	}
	return {}, {.Not_Found, "service not found in the returned descriptors"}
}

@(private = "file")
find_service :: proc(files: map[string]^FileDescriptorProto, name: string) -> (^ServiceDescriptorProto, ^FileDescriptorProto) {
	for _, f in files {
		if s := find_service_in(f, name); s != nil {
			return s, f
		}
	}
	return nil, nil
}

@(private = "file")
find_service_in :: proc(f: ^FileDescriptorProto, name: string) -> ^ServiceDescriptorProto {
	pkg := f.package_.? or_else ""
	for &s in f.service {
		if is_qualified(pkg, s.name.? or_else "", name) {
			return &s
		}
	}
	return nil
}

@(private = "file")
service_info :: proc(c: ^Client, s: ^ServiceDescriptorProto, f: ^FileDescriptorProto, name: string) -> Service_Info {
	methods := make([]Method_Info, len(s.method), c.allocator)
	for &m, i in s.method {
		method := m.name.? or_else ""
		methods[i] = {
			name             = method,
			path             = strings.concatenate({"/", name, "/", method}, c.allocator),
			input_type       = strings.trim_prefix(m.input_type.? or_else "", "."),
			output_type      = strings.trim_prefix(m.output_type.? or_else "", "."),
			client_streaming = m.client_streaming.? or_else MethodDescriptorProto_client_streaming_DEFAULT,
			server_streaming = m.server_streaming.? or_else MethodDescriptorProto_server_streaming_DEFAULT,
		}
	}
	return {name = name, file = f, methods = methods}
}

// describe_message finds the descriptor of a message type by its fully
// qualified name (e.g. "helloworld.HelloRequest" or "pkg.Outer.Inner"; a
// leading dot is accepted).
describe_message :: proc(c: ^Client, full_name: string) -> (msg: ^DescriptorProto, file: ^FileDescriptorProto, st: grpc.Status) {
	name := strings.trim_prefix(full_name, ".")
	for _, f in c.files {
		if m := find_message_in(f, name); m != nil {
			return m, f, {}
		}
	}
	files: []^FileDescriptorProto
	if files, st = file_containing_symbol(c, name); st.code != .OK {
		return nil, nil, st
	}
	for f in files {
		if m := find_message_in(f, name); m != nil {
			return m, f, {}
		}
	}
	return nil, nil, {.Not_Found, "message not found in the returned descriptors"}
}

@(private = "file")
find_message_in :: proc(f: ^FileDescriptorProto, name: string) -> ^DescriptorProto {
	pkg := f.package_.? or_else ""
	rest, ok := strip_scope(pkg, name)
	if !ok {
		return nil
	}
	for &m in f.message_type {
		if found := find_nested(&m, rest); found != nil {
			return found
		}
	}
	return nil
}

// find_nested matches `rest` ("Outer" or "Outer.Inner...") against m and its
// nested types without allocating.
@(private = "file")
find_nested :: proc(m: ^DescriptorProto, rest: string) -> ^DescriptorProto {
	name := m.name.? or_else ""
	if rest == name {
		return m
	}
	inner, ok := strip_scope(name, rest)
	if !ok {
		return nil
	}
	for &n in m.nested_type {
		if found := find_nested(&n, inner); found != nil {
			return found
		}
	}
	return nil
}

// strip_scope removes "scope." from the front of name (an empty scope
// strips nothing).
@(private = "file")
strip_scope :: proc(scope, name: string) -> (rest: string, ok: bool) {
	if scope == "" {
		return name, true
	}
	if len(name) > len(scope) && name[len(scope)] == '.' && strings.has_prefix(name, scope) {
		return name[len(scope) + 1:], true
	}
	return "", false
}

// is_qualified reports whether full == scope + "." + name (or name when
// the scope is empty), without allocating.
@(private = "file")
is_qualified :: proc(scope, name, full: string) -> bool {
	rest, ok := strip_scope(scope, full)
	return ok && rest == name
}

// field_type_string renders a field's type the way it is written in a
// .proto file: "string", "repeated int32", "pkg.Message". Map fields
// appear as their repeated nested *Entry message.
field_type_string :: proc(f: ^FieldDescriptorProto, allocator := context.allocator) -> string {
	base: string
	t := f.type.? or_else .TYPE_MESSAGE
	switch t {
	case .TYPE_MESSAGE, .TYPE_ENUM, .TYPE_GROUP:
		base = strings.trim_prefix(f.type_name.? or_else "", ".")
	case .TYPE_DOUBLE:
		base = "double"
	case .TYPE_FLOAT:
		base = "float"
	case .TYPE_INT64:
		base = "int64"
	case .TYPE_UINT64:
		base = "uint64"
	case .TYPE_INT32:
		base = "int32"
	case .TYPE_FIXED64:
		base = "fixed64"
	case .TYPE_FIXED32:
		base = "fixed32"
	case .TYPE_BOOL:
		base = "bool"
	case .TYPE_STRING:
		base = "string"
	case .TYPE_BYTES:
		base = "bytes"
	case .TYPE_UINT32:
		base = "uint32"
	case .TYPE_SFIXED32:
		base = "sfixed32"
	case .TYPE_SFIXED64:
		base = "sfixed64"
	case .TYPE_SINT32:
		base = "sint32"
	case .TYPE_SINT64:
		base = "sint64"
	}
	if (f.label.? or_else .LABEL_OPTIONAL) == .LABEL_REPEATED {
		return strings.concatenate({"repeated ", base}, allocator)
	}
	return base
}
