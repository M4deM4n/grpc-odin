package protoc_test

import "core:log"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import "../../protoc"

Result :: struct {
	arena: vmem.Arena,
	c:     protoc.Compiler,
	files: []protoc.Output_File,
	ok:    bool,
}

Source :: struct {
	path, text: string,
}

// compile loads `inputs` (paths of the given in-memory sources) and runs
// resolution and, if that succeeds, generation.
compile :: proc(r: ^Result, sources: []Source, inputs: []string) {
	err := vmem.arena_init_growing(&r.arena)
	assert(err == nil)
	alloc := vmem.arena_allocator(&r.arena)
	protoc.compiler_init(&r.c, alloc)
	for s in sources {
		protoc.compiler_add_source(&r.c, s.path, s.text)
	}
	for p in inputs {
		protoc.compiler_add_input(&r.c, p)
	}
	if !protoc.compiler_resolve(&r.c) {
		return
	}
	r.files, r.ok = protoc.generate(&r.c, {package_name = "out", generate_services = true})
}

destroy :: proc(r: ^Result) {
	vmem.arena_destroy(&r.arena)
}

log_diagnostics :: proc(r: ^Result) {
	for d in r.c.diags.list {
		log.infof("diagnostic: %s:%d:%d: %s", d.pos.file, d.pos.line, d.pos.column, d.message)
	}
}

// expect_error compiles a single file and expects a diagnostic containing
// `fragment`.
expect_error :: proc(t: ^testing.T, src: string, fragment: string, loc := #caller_location) {
	r: Result
	defer destroy(&r)
	compile(&r, {{"test.proto", src}}, {"test.proto"})
	testing.expect(t, !r.ok, "expected compilation to fail", loc = loc)
	found := false
	for d in r.c.diags.list {
		if strings.contains(d.message, fragment) {
			found = true
		}
	}
	if !found {
		log_diagnostics(&r)
	}
	testing.expectf(t, found, "no diagnostic containing %q", fragment, loc = loc)
}

expect_ok :: proc(t: ^testing.T, r: ^Result, loc := #caller_location) {
	if !r.ok {
		log_diagnostics(r)
	}
	testing.expect(t, r.ok, "expected compilation to succeed", loc = loc)
}

output :: proc(r: ^Result, name: string) -> string {
	for f in r.files {
		if f.name == name {
			return f.content
		}
	}
	return ""
}

// -----------------------------------------------------------------------------
// Syntax errors
// -----------------------------------------------------------------------------

@(test)
test_syntax_errors :: proc(t: ^testing.T) {
	expect_error(t, `syntax = "proto3"; message A { int32 x = 1 }`, "expected ';'")
	expect_error(t, `syntax = "proto4";`, "unrecognized syntax")
	expect_error(t, `edition = "2023";`, "editions are not supported")
	expect_error(t, `package a; syntax = "proto3";`, "must be the first statement")
	expect_error(t, `syntax = "proto3"; message A { string s = 1; } /* open`, "unterminated block comment")
	expect_error(t, `syntax = "proto3"; option x = "abc;`, "unterminated string")
	expect_error(t, `syntax = "proto2"; message A { optional group G = 1 {} }`, "groups are not supported")
	expect_error(t, `syntax = "proto3"; message A { int32 x = 0; }`, "out of range")
	expect_error(t, `syntax = "proto3"; message A { int32 x = 536870912; }`, "out of range")
	expect_error(t, `syntax = "proto3"; message A { int32 x = 19500; }`, "reserved for the protobuf implementation")
	expect_error(t, `syntax = "proto3"; message A { map<float, int32> m = 1; }`, "invalid map key type")
	expect_error(t, `syntax = "proto3"; message A { repeated map<int32, int32> m = 1; }`, "map fields cannot have a label")
	expect_error(t, `syntax = "proto3"; enum E { A = 2147483648; }`, "out of int32 range")
	expect_error(t, `syntax = "proto3"; message A { oneof o { repeated int32 x = 1; } }`, "cannot have labels")
	expect_error(t, `syntax = "proto3"; service S { rpc M(int32) returns (A); }`, "must be messages")

	nested := strings.builder_make(context.temp_allocator)
	strings.write_string(&nested, `syntax = "proto3";`)
	for _ in 0 ..< 70 {strings.write_string(&nested, "message M {")}
	for _ in 0 ..< 70 {strings.write_string(&nested, "}")}
	expect_error(t, strings.to_string(nested), "nested more than")
}

// -----------------------------------------------------------------------------
// Semantic errors
// -----------------------------------------------------------------------------

@(test)
test_semantic_errors :: proc(t: ^testing.T) {
	expect_error(t, `syntax = "proto3"; message A { int32 x = 1; int32 y = 1; }`, "field number 1 is already used")
	expect_error(t, `syntax = "proto3"; message A { int32 x = 1; string x = 2; }`, "field name 'x' is already used")
	expect_error(t, `syntax = "proto3"; message A { reserved 2 to 4; int32 x = 3; }`, "reserved field number 3")
	expect_error(t, `syntax = "proto3"; message A { reserved "x"; int32 x = 1; }`, "is reserved")
	expect_error(t, `syntax = "proto3"; enum E { A = 1; }`, "first enum value must be zero")
	expect_error(t, `syntax = "proto3"; enum E { A = 0; B = 0; }`, "allow_alias")
	expect_error(t, `syntax = "proto3"; enum E { option allow_alias = true; A = 0; B = 1; }`, "no aliased values")
	expect_error(t, `syntax = "proto3"; message A { required int32 x = 1; }`, "not allowed in proto3")
	expect_error(t, `syntax = "proto2"; message A { int32 x = 1; }`, "require a label")
	expect_error(t, `syntax = "proto3"; message A { int32 x = 1 [default = 5]; }`, "not allowed in proto3")
	expect_error(t, `syntax = "proto2"; message A { optional int32 x = 1 [default = "a"]; }`, "invalid default")
	expect_error(t, `syntax = "proto2"; message A { optional uint32 x = 1 [default = -1]; }`, "invalid default")
	expect_error(t, `syntax = "proto2"; message A { optional int32 x = 1 [default = 2147483648]; }`, "invalid default")
	expect_error(t, `syntax = "proto2"; enum E { A = 1; } message M { optional E e = 1 [default = B]; }`, "must be a value of enum")
	expect_error(t, `syntax = "proto3"; message A { repeated string s = 1 [packed = true]; }`, "[packed] can only")
	expect_error(t, `syntax = "proto3"; message A { Missing m = 1; }`, "unknown type 'Missing'")
	expect_error(t, `syntax = "proto3"; message A {} message A {}`, "already defined")
	expect_error(t, `syntax = "proto2"; enum E { X = 1; } message A { map<int32, E> m = 1; }`, "first value must be zero")
	expect_error(t, `syntax = "proto3"; service S { rpc M(A) returns (A); rpc M(A) returns (A); } message A {}`, "already defined in service")
	expect_error(t, `syntax = "proto3"; import "missing.proto";`, "file not found")
}

@(test)
test_import_rules :: proc(t: ^testing.T) {
	// Cycles.
	{
		r: Result
		defer destroy(&r)
		compile(&r, {{"a.proto", `syntax = "proto3"; import "b.proto";`}, {"b.proto", `syntax = "proto3"; import "a.proto";`}}, {"a.proto"})
		testing.expect(t, !r.ok)
	}
	// Types from files that are not imported are invisible, even when
	// loaded...
	{
		r: Result
		defer destroy(&r)
		compile(
			&r,
			{
				{"a.proto", `syntax = "proto3"; package p; import "b.proto"; message A { C c = 1; }`},
				{"b.proto", `syntax = "proto3"; package p; import "c.proto";`},
				{"c.proto", `syntax = "proto3"; package p; message C {}`},
			},
			{"a.proto"},
		)
		testing.expect(t, !r.ok)
	}
	// ...but `import public` re-exports them.
	{
		r: Result
		defer destroy(&r)
		compile(
			&r,
			{
				{"a.proto", `syntax = "proto3"; package p; import "b.proto"; message A { C c = 1; }`},
				{"b.proto", `syntax = "proto3"; package p; import public "c.proto";`},
				{"c.proto", `syntax = "proto3"; package p; message C {}`},
			},
			{"a.proto"},
		)
		expect_ok(t, &r)
	}
	// "dir/../b.proto", "./b.proto" and "b.proto" are the same file.
	{
		r: Result
		defer destroy(&r)
		compile(
			&r,
			{
				{"a.proto", `syntax = "proto3"; import "dir/../b.proto"; import "./b.proto"; message A { B b = 1; }`},
				{"b.proto", `syntax = "proto3"; message B {}`},
			},
			{"a.proto"},
		)
		expect_ok(t, &r)
	}
	// The same input twice.
	{
		r: Result
		defer destroy(&r)
		compile(&r, {{"a.proto", `syntax = "proto3";`}}, {"a.proto", "./a.proto"})
		testing.expect(t, !r.ok)
	}
}

@(test)
test_name_resolution :: proc(t: ^testing.T) {
	r: Result
	defer destroy(&r)
	compile(
		&r,
		{
			{
				"a.proto",
				`syntax = "proto3";
package foo.bar;
message Outer {
  message Inner { int32 x = 1; }
  Inner a = 1;            // innermost scope
  Outer.Inner b = 2;      // partially qualified
  .foo.bar.Outer c = 3;   // fully qualified
  bar.Outer d = 4;        // through a package component
  Sibling e = 5;          // package scope
}
message Sibling { Outer.Inner x = 1; }`,
			},
		},
		{"a.proto"},
	)
	expect_ok(t, &r)
	if !r.ok {
		return
	}
	f := r.c.files["a.proto"]
	outer := f.messages[0]
	testing.expect_value(t, outer.fields[0].type.message.full_name, "foo.bar.Outer.Inner")
	testing.expect_value(t, outer.fields[1].type.message.full_name, "foo.bar.Outer.Inner")
	testing.expect_value(t, outer.fields[2].type.message.full_name, "foo.bar.Outer")
	testing.expect_value(t, outer.fields[3].type.message.full_name, "foo.bar.Outer")
	testing.expect_value(t, outer.fields[4].type.message.full_name, "foo.bar.Sibling")

	// Once the first component resolves, the rest must resolve inside it.
	expect_error(t, `syntax = "proto3"; package p; message X { message Y {} } message A { message X {} X.Y y = 1; }`, "which is not defined")
}

// -----------------------------------------------------------------------------
// Naming in generated code
// -----------------------------------------------------------------------------

@(test)
test_generated_names :: proc(t: ^testing.T) {
	r: Result
	defer destroy(&r)
	compile(
		&r,
		{
			{
				"svc/api.proto",
				`syntax = "proto3";
package my.api;
import "google/protobuf/empty.proto";
message Empty {}
message Uses { google.protobuf.Empty e = 1; Empty mine = 2; int32 proc = 3; int32 proc_ = 4; }
enum Kw { in = 0; map = 1; }`,
			},
		},
		{"svc/api.proto"},
	)
	expect_ok(t, &r)
	api := output(&r, "svc_api.pb.odin")
	wkt := output(&r, "google_protobuf_empty.pb.odin")
	// Primary package types keep their names; imported packages are prefixed.
	testing.expect(t, strings.contains(api, "\nEmpty :: struct {"))
	testing.expect(t, strings.contains(wkt, "\nGoogle_Protobuf_Empty :: struct {"))
	testing.expect(t, strings.contains(api, "e: ^Google_Protobuf_Empty,"))
	// Field and enum value escaping, with uniqueness after escaping.
	testing.expect(t, strings.contains(api, "\tproc_: i32,"))
	testing.expect(t, strings.contains(api, "\tproc__: i32,"))
	testing.expect(t, strings.contains(api, "\tin_ = 0,"))
	testing.expect(t, strings.contains(api, "\tmap_ = 1,"))

	testing.expect_value(t, protoc.snake_case("SayHello", context.temp_allocator), "say_hello")
	testing.expect_value(t, protoc.snake_case("HTTPGetURL", context.temp_allocator), "http_get_url")
	testing.expect_value(t, protoc.snake_case("Get2Things", context.temp_allocator), "get2_things")
}

@(test)
test_naming_collisions_are_errors :: proc(t: ^testing.T) {
	// Types named like generated locals or builtins.
	expect_error(t, `syntax = "proto3"; message m {}`, "collides with an identifier used inside generated procedures")
	expect_error(t, `syntax = "proto3"; message Maybe {}`, "cannot be used as an Odin identifier")
	// Nested type vs top-level type with the same flattened name.
	expect_error(t, `syntax = "proto3"; message A { message B {} } message A_B {}`, "collides")
	// Output file names.
	{
		r: Result
		defer destroy(&r)
		compile(&r, {{"a/b.proto", `syntax = "proto3"; package x;`}, {"a_b.proto", `syntax = "proto3"; package y;`}}, {"a/b.proto", "a_b.proto"})
		testing.expect(t, !r.ok)
	}
}
