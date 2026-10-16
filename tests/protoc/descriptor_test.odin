package protoc_test

import "core:encoding/hex"
import "core:log"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import "../../protoc"

// Reference descriptors serialized by Google's protoc
// (interop/python/gen_fixtures.py).
REF_DESCRIPTOR_TEST3 :: #load("testdata/descriptor_test3.desc.bin")
REF_DESCRIPTOR_TEST2 :: #load("testdata/descriptor_test2.desc.bin")
REF_TEST_ALL :: #load("testdata/test_all.desc.bin")
REF_LEGACY :: #load("testdata/legacy.desc.bin")
REF_TEST_SERVICE :: #load("testdata/test_service.desc.bin")
REF_HELLOWORLD :: #load("testdata/helloworld.desc.bin")

// expect_descriptor compiles `input` (relative to include_dir; run from the
// repository root) and compares its descriptor with Google's.
expect_descriptor :: proc(t: ^testing.T, include_dir, input: string, want: []u8, loc := #caller_location) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	a := vmem.arena_allocator(&arena)

	c: protoc.Compiler
	protoc.compiler_init(&c, a)
	protoc.compiler_add_include_path(&c, include_dir)
	f := protoc.compiler_add_input(&c, input)
	if !protoc.compiler_resolve(&c) || f == nil {
		for d in c.diags.list {
			log.infof("diagnostic: %s:%d:%d: %s", d.pos.file, d.pos.line, d.pos.column, d.message)
		}
		testing.fail_now(t, "compilation failed", loc)
	}
	got := protoc.build_file_descriptor(f, a)
	if string(got) == string(want) {
		return
	}
	first := 0
	for first < len(got) && first < len(want) && got[first] == want[first] {
		first += 1
	}
	lo := max(0, first - 16)
	testing.expectf(
		t,
		false,
		"%s: descriptor differs at offset %d (got %d bytes, want %d)\n  got:  ...%s\n  want: ...%s",
		input,
		first,
		len(got),
		len(want),
		hex.encode(got[lo:min(len(got), first + 24)], a),
		hex.encode(want[lo:min(len(want), first + 24)], a),
		loc = loc,
	)
}

@(test)
test_descriptors_match_protoc :: proc(t: ^testing.T) {
	expect_descriptor(t, "tests/protoc/proto", "descriptor_test3.proto", REF_DESCRIPTOR_TEST3)
	expect_descriptor(t, "tests/protoc/proto", "descriptor_test2.proto", REF_DESCRIPTOR_TEST2)
	expect_descriptor(t, "tests/protobuf/proto", "test_all.proto", REF_TEST_ALL)
	expect_descriptor(t, "tests/protobuf/proto", "legacy.proto", REF_LEGACY)
	expect_descriptor(t, "tests/grpc/proto", "test_service.proto", REF_TEST_SERVICE)
	expect_descriptor(t, "examples/helloworld", "helloworld.proto", REF_HELLOWORLD)
}

@(test)
test_json_names :: proc(t: ^testing.T) {
	cases := [][2]string{{"foo_bar", "fooBar"}, {"foo", "foo"}, {"_foo", "Foo"}, {"foo__bar", "fooBar"}, {"foo_1x", "foo1x"}, {"FOO_BAR", "FOOBAR"}}
	for c in cases {
		testing.expect_value(t, protoc.json_name_of(c[0], context.temp_allocator), c[1])
	}
}

WKT_REFERENCES := [?][2]string {
	{"google/protobuf/empty.proto", #load("testdata/wkt/empty.desc.bin", string)},
	{"google/protobuf/timestamp.proto", #load("testdata/wkt/timestamp.desc.bin", string)},
	{"google/protobuf/duration.proto", #load("testdata/wkt/duration.desc.bin", string)},
	{"google/protobuf/wrappers.proto", #load("testdata/wkt/wrappers.desc.bin", string)},
	{"google/protobuf/any.proto", #load("testdata/wkt/any.desc.bin", string)},
	{"google/protobuf/field_mask.proto", #load("testdata/wkt/field_mask.desc.bin", string)},
	{"google/protobuf/struct.proto", #load("testdata/wkt/struct.desc.bin", string)},
}

// The embedded well-known types produce exactly Google's descriptors, so
// reflection clients that already know them see no conflicting definition.
@(test)
test_well_known_descriptors_match_google :: proc(t: ^testing.T) {
	for ref in WKT_REFERENCES {
		expect_descriptor(t, ".", ref[0], transmute([]u8)ref[1])
	}
}

// Integer literals beyond u64 are rejected, never wrapped; as float defaults
// they are parsed as floating point.
@(test)
test_integer_literal_overflow :: proc(t: ^testing.T) {
	v, ok := protoc.parse_int_literal("18446744073709551615")
	testing.expect(t, ok && v == max(u64))
	_, ok = protoc.parse_int_literal("18446744073709551616")
	testing.expect(t, !ok)
	_, ok = protoc.parse_int_literal("0x1FFFFFFFFFFFFFFFF")
	testing.expect(t, !ok)
	_, ok = protoc.parse_int_literal("09") // not octal
	testing.expect(t, !ok)
	expect_error(t, `syntax = "proto2"; message A { optional uint64 x = 1 [default = 18446744073709551616]; }`, "invalid default")

	// A huge integer default for a double field: C99 %g text (the format
	// Linux protoc emits; MSVC builds print three exponent digits).
	r: Result
	defer destroy(&r)
	compile(&r, {{"big.proto", `syntax = "proto2"; message A { optional double d = 1 [default = 100000000000000000000]; }`}}, {"big.proto"})
	expect_ok(t, &r)
	if r.ok {
		desc := protoc.build_file_descriptor(r.c.files["big.proto"], context.temp_allocator)
		testing.expect(t, strings.contains(string(desc), "1e+20"))
	}
}
