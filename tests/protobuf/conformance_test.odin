package protobuf_test

import "core:math"
import "core:testing"

import pb "grpc:protobuf"
import "gen"

// Reference encodings produced by Google's protobuf runtime; regenerate
// with interop/python/gen_fixtures.py.
FIXTURE_SCALARS_FULL :: #load("testdata/scalars_full.bin")
FIXTURE_REPEATED :: #load("testdata/repeated.bin")
FIXTURE_NESTED :: #load("testdata/nested.bin")
FIXTURE_CHOICE_SCALARS :: #load("testdata/choice_scalars.bin")
FIXTURE_CHOICE_NUMBER_ZERO :: #load("testdata/choice_number_zero.bin")
FIXTURE_LARGE :: #load("testdata/large.bin")
FIXTURE_MAPS :: #load("testdata/maps.bin")
FIXTURE_LEGACY :: #load("testdata/legacy.bin")
FIXTURE_WELL_KNOWN :: #load("testdata/well_known.bin")

// expect_conformant checks both directions against a reference encoding:
// encoding `msg` must give exactly `want`, and decoding `want` then
// re-encoding must give `want` again.
expect_conformant :: proc(t: ^testing.T, msg: rawptr, decoded: rawptr, codec: ^pb.Message_Codec, want: []u8, loc := #caller_location) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)

	got, err := pb.marshal(msg, codec, alloc)
	testing.expect_value(t, err, pb.Error.None, loc)
	testing.expect_value(t, to_hex(got), to_hex(want), loc)

	testing.expect_value(t, pb.unmarshal(decoded, codec, want, alloc), pb.Error.None, loc)
	again, err2 := pb.marshal(decoded, codec, alloc)
	testing.expect_value(t, err2, pb.Error.None, loc)
	testing.expect_value(t, to_hex(again), to_hex(want), loc)
}

@(test)
test_conformance_scalars :: proc(t: ^testing.T) {
	m := full_scalars()
	out: gen.Scalars
	expect_conformant(t, &m, &out, &gen.Scalars_CODEC, FIXTURE_SCALARS_FULL)
}

@(test)
test_conformance_repeated :: proc(t: ^testing.T) {
	SCALAR_X := gen.Scalars {
		f_string = "x",
	}
	messages := [3]gen.Scalars{full_scalars(), {}, SCALAR_X}
	BYTES_123 := [3]u8{1, 2, 3}
	byte_list := [2][]u8{{}, BYTES_123[:]}
	m := gen.Repeated {
		r_int32    = pb.view([]i32{0, -1, max(i32), min(i32)}),
		r_sint64   = pb.view([]i64{min(i64), 0, max(i64)}),
		r_fixed32  = pb.view([]u32{0, 1, max(u32)}),
		r_double   = pb.view([]f64{math.inf_f64(1), math.copy_sign_f64(0, -1), 1e-300}),
		r_bool     = pb.view([]bool{true, false}),
		r_enum     = pb.view([]gen.Color{.COLOR_RED, .COLOR_NEGATIVE, gen.Color(12345)}),
		r_string   = pb.view([]string{"", "a", "longer string value"}),
		r_bytes    = pb.view(byte_list[:]),
		r_message  = pb.view(messages[:]),
		r_unpacked = pb.view([]i32{7, 8, 9}),
		r_float    = pb.view([]f32{1.5, -2.25}),
		r_uint64   = pb.view([]u64{max(u64), 0}),
		r_sfixed64 = pb.view([]i64{min(i64), -1}),
	}
	out: gen.Repeated
	expect_conformant(t, &m, &out, &gen.Repeated_CODEC, FIXTURE_REPEATED)
}

@(test)
test_conformance_nested :: proc(t: ^testing.T) {
	deepest := gen.Nested_Inner_Deepest {
		name = "deep",
	}
	inner := gen.Nested_Inner {
		value   = 42,
		deepest = &deepest,
	}
	m := gen.Nested {
		inner  = &inner,
		mode   = .MODE_FAST,
		inners = pb.view([]gen.Nested_Inner{{value = 1}, {value = 2, deepest = &deepest}}),
	}
	out: gen.Nested
	expect_conformant(t, &m, &out, &gen.Nested_CODEC, FIXTURE_NESTED)
}

@(test)
test_conformance_oneof :: proc(t: ^testing.T) {
	sc := full_scalars()
	m := gen.Choice {
		kind  = gen.Choice_Kind_Scalars(&sc),
		other = gen.Choice_Other_Flag(false),
		after = 5,
	}
	out: gen.Choice
	expect_conformant(t, &m, &out, &gen.Choice_CODEC, FIXTURE_CHOICE_SCALARS)

	z := gen.Choice {
		kind  = gen.Choice_Kind_Number(0),
		after = 5,
	}
	out2: gen.Choice
	expect_conformant(t, &z, &out2, &gen.Choice_CODEC, FIXTURE_CHOICE_NUMBER_ZERO)
}

@(test)
test_conformance_large_field_numbers :: proc(t: ^testing.T) {
	m := gen.Large {
		f1    = 1,
		f_max = 2,
		f_big = "b",
	}
	out: gen.Large
	expect_conformant(t, &m, &out, &gen.Large_CODEC, FIXTURE_LARGE)
}

@(test)
test_conformance_maps :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)
	m: gen.Maps
	m.m_string_message = make(map[string]gen.Scalars, alloc)
	m.m_string_message["full"] = full_scalars()
	m.m_int32_int64 = make(map[i32]i64, alloc)
	m.m_int32_int64[-1] = min(i64)
	m.m_sint32_double = make(map[i32]f64, alloc)
	m.m_sint32_double[min(i32)] = 2.5
	m.m_fixed64_string = make(map[u64]string, alloc)
	m.m_fixed64_string[7] = "seven"
	out: gen.Maps
	expect_conformant(t, &m, &out, &gen.Maps_CODEC, FIXTURE_MAPS)
}

@(test)
test_conformance_proto2 :: proc(t: ^testing.T) {
	child := gen.Legacy {
		id = 2,
	}
	m := gen.Legacy {
		id       = 1,
		name     = "legacy",
		unpacked = pb.view([]i32{1, 2}),
		packed   = pb.view([]i32{3, 4}),
		level    = gen.Level.HIGH,
		child    = &child,
	}
	out: gen.Legacy
	expect_conformant(t, &m, &out, &gen.Legacy_CODEC, FIXTURE_LEGACY)
}

@(test)
test_conformance_well_known :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)
	ts := gen.Google_Protobuf_Timestamp {
		seconds = 1700000000,
		nanos   = 123,
	}
	attrs := gen.Google_Protobuf_Struct {
		fields = make(map[string]gen.Google_Protobuf_Value, alloc),
	}
	attrs.fields["s"] = {
		kind = gen.Google_Protobuf_Value_Kind_String_Value("str"),
	}
	m := gen.WithWellKnown {
		created    = &ts,
		attributes = &attrs,
	}
	out: gen.WithWellKnown
	expect_conformant(t, &m, &out, &gen.WithWellKnown_CODEC, FIXTURE_WELL_KNOWN)
}
