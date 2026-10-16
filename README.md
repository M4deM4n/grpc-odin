# odin-grpc

A pure-[Odin](https://odin-lang.org/) implementation of
[Protocol Buffers](https://protobuf.dev/) and [gRPC](https://grpc.io/):
a `.proto` compiler that generates Odin code, a protobuf runtime, and a gRPC
client and server over HTTP/2. No C dependencies, no `protoc` needed.

Verified against the reference implementations: protobuf encodings are
checked byte-for-byte against Google's protobuf runtime, and the gRPC client
and server are cross-tested against gRPC C-core (`grpcio`) in both
directions.

## Contents

| Package | What it is |
|---------|-----------|
| `grpc/` | gRPC client (`Channel`) and server: unary and all streaming kinds, metadata, deadlines, cancellation, status codes, flow control, graceful shutdown |
| `protobuf/` | Protobuf wire-format runtime used by generated code |
| `protoc/`, `cmd/odin-protoc/` | `.proto` (proto2/proto3) compiler generating Odin messages and gRPC stubs |
| `http2/` | HTTP/2 framing (RFC 9113) |
| `hpack/` | HPACK header compression (RFC 7541) |

## Quick start

```sh
# 1. Build the compiler
odin build cmd/odin-protoc -o:speed -out:odin-protoc

# 2. Generate code (one Odin package for the .proto files and their imports)
./odin-protoc -I examples/helloworld -o examples/helloworld/pb --package=helloworld_pb \
    examples/helloworld/helloworld.proto

# 3. Run the example (the repository is mounted as the `grpc` collection)
odin run examples/helloworld/server -collection:grpc=. -- 127.0.0.1:0
odin run examples/helloworld/client -collection:grpc=. -- 127.0.0.1:<port> Odin
```

Generated code imports `"grpc:protobuf"` and `"grpc:grpc"`; pass
`-collection:grpc=<path to this repository>` when building (or use
`--protobuf-import` / `--grpc-import` to change the import paths).

### Server

```odin
say_hello :: proc(srv: ^pb.Greeter_Server, call: ^grpc.Server_Call, req: ^pb.HelloRequest, resp: ^pb.HelloReply) -> grpc.Status {
	resp.message = strings.concatenate({"Hello, ", req.name}, grpc.call_allocator(call))
	return {} // OK
}

impl := pb.Greeter_Server{say_hello = say_hello}   // unset methods answer UNIMPLEMENTED
server: grpc.Server
grpc.server_init(&server)
pb.Greeter_register(&server, &impl)
endpoint, ok := grpc.server_start(&server, "0.0.0.0:50051")
// ...
grpc.server_shutdown(&server)   // graceful: GOAWAY, wait for in-flight RPCs
grpc.server_destroy(&server)
```

### Client

```odin
ch := grpc.channel_create("127.0.0.1:50051")
defer grpc.channel_destroy(ch)

req := pb.HelloRequest{name = "Odin"}
reply: pb.HelloReply
st := pb.Greeter_say_hello(ch, &req, &reply, {timeout = 2 * time.Second, allocator = arena_allocator})
if st.code != .OK { fmt.println(st.code, st.message) }

// Streaming RPCs return a typed stream wrapper:
stream, _ := pb.Greeter_say_hello_all(ch, &req)
for {
	m: pb.HelloReply
	got, st := pb.Greeter_SayHelloAll_Client_recv(stream, &m)
	if !got { break }    // st is the final status
}
pb.Greeter_SayHelloAll_Client_finish(stream)
```

## Generated code

For each message `Foo`: a struct, `Foo_size`, `Foo_encode_fields`,
`Foo_decode_fields`, `Foo_marshal`, `Foo_unmarshal`, `Foo_destroy` and
`Foo_CODEC`, plus package-wide proc groups `marshal`, `unmarshal`, `size`,
`destroy`.

| Proto | Odin |
|-------|------|
| scalar (proto3, implicit presence) | `T` (`f64`, `i32`, `string`, `[]u8`, ...) |
| `optional` / proto2 scalar | `Maybe(T)` |
| message field | `^Msg` (nil = unset) |
| `repeated T` | `[dynamic]T` (build from slices with `pb.view([]T{...})`) |
| `map<K, V>` | `map[K]V` |
| `oneof` | `union` of `distinct` case types `Msg_Oneof_Field` |
| enum | `enum i32`; proto2 (closed) enums get `Enum_is_known` |

Nested types are joined with `_` (`Outer_Inner`); types from imported
packages other than the inputs' are prefixed (`Google_Protobuf_Timestamp`).
Unknown fields are preserved. proto2 `required` fields are checked on
decode; `[default = ...]` values become `Msg_field_DEFAULT` constants.
Well-known types `empty`, `timestamp`, `duration`, `wrappers`, `any`,
`field_mask` and `struct` are built in.

## Memory model

- **Encoding allocates nothing** except the output buffer: the exact size is
  computed first and messages are written back-to-front into it.
- **Decoding allocates from the allocator you pass**; arenas are the
  intended allocator. Repeated fields are pre-counted so each is normally
  allocated once.
- **Server handlers** get a per-call arena (`grpc.call_allocator(call)`):
  requests are decoded into it zero-copy, and it is reset when the RPC ends.
  Call objects and arenas are pooled.
- **Clients** decode responses with `Call_Options.allocator`.

## Behavior and limits

- Transport: HTTP/2 over cleartext TCP (h2c, prior knowledge). TLS is not
  implemented; the `Transport` interface (`grpc/transport.odin`) is where a
  TLS implementation plugs in. Deploy behind a TLS-terminating proxy or mesh
  otherwise.
- Compression: only `identity`; compressed requests are rejected with
  UNIMPLEMENTED and `grpc-accept-encoding: identity`.
- Defaults: 4 MiB max received message, 256 KiB stream / 16 MiB connection
  windows, 100 concurrent streams per connection, 16 KiB header lists,
  4096 connections per server, 10 s handshake timeout, server keepalive
  PINGs after 2 h of silence. All are configurable through `Conn_Options`
  and `Server_Options`.
- Hostile-peer protections: flow-control enforcement, header-block and
  CONTINUATION limits, a per-connection budget for cheap-to-send frames
  (PING/SETTINGS/RST_STREAM floods, rapid reset) answered with
  `ENHANCE_YOUR_CALM`, stream concurrency limits that count reset streams
  until their handler finishes, decode depth limits and
  allocation-amplification guards.
- Streaming handlers: messages received with `server_recv` live in the call
  arena until the handler returns. Long-lived streams should use
  `server_recv_with` and an arena they reset per message.
- Graceful shutdown sends one GOAWAY with the last processed stream;
  streams the client opened concurrently are refused (REFUSED_STREAM),
  which clients retry transparently.
- Not supported: protobuf editions, extensions, groups, JSON mapping, gRPC
  reflection/health services, client-side load balancing, retries beyond
  transparent retry of streams the server refused.

## Development

See [AGENTS.md](AGENTS.md). Run all tests with `sh scripts/test.sh` and the
cross-implementation tests with `sh scripts/interop.sh`.
