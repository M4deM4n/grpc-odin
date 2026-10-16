package protobuf_test

import "base:runtime"
import "core:encoding/hex"
import "core:math"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import pb "grpc:protobuf"
import "gen"

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

unhex :: proc(s: string) -> []u8 {
	b, ok := hex.decode(transmute([]u8)s, context.temp_allocator)
	assert(ok, "bad hex in test vector")
	return b
}

to_hex :: proc(b: []u8) -> string {
	return string(hex.encode(b, context.temp_allocator))
}

// expect_encoding marshals msg and compares it with the expected hex.
expect_encoding :: proc(t: ^testing.T, msg: rawptr, codec: ^pb.Message_Codec, want_hex: string, loc := #caller_location) {
	data, err := pb.marshal(msg, codec, context.temp_allocator)
	testing.expect_value(t, err, pb.Error.None, loc)
	testing.expect_value(t, to_hex(data), want_hex, loc)
	testing.expect_value(t, codec.size(msg), len(data), loc)
}

// Arena gives tests an arena allocator, the recommended decode allocator.
Arena :: struct {
	arena: vmem.Arena,
}

arena_allocator :: proc(a: ^Arena) -> runtime.Allocator {
	err := vmem.arena_init_growing(&a.arena)
	assert(err == nil)
	return vmem.arena_allocator(&a.arena)
}

arena_destroy :: proc(a: ^Arena) {
	vmem.arena_destroy(&a.arena)
}

// -----------------------------------------------------------------------------
// Wire primitives
// -----------------------------------------------------------------------------

@(test)
test_varint_vectors :: proc(t: ^testing.T) {
	Case :: struct {
		value: u64,
		bytes: string,
	}
	cases := []Case {
		{0, "00"},
		{1, "01"},
		{127, "7f"},
		{128, "8001"},
		{300, "ac02"},
		{16383, "ff7f"},
		{16384, "808001"},
		{1 << 63, "80808080808080808001"},
		{max(u64), "ffffffffffffffffff01"},
	}
	for c in cases {
		buf: [16]u8
		e := pb.encoder_make(buf[:])
		pb.write_varint(&e, c.value)
		testing.expect_value(t, to_hex(pb.encoded(&e)), c.bytes)
		testing.expect_value(t, pb.varint_size(c.value), len(c.bytes) / 2)

		d := pb.decoder_make(unhex(c.bytes))
		v, err := pb.read_varint(&d)
		testing.expect_value(t, err, pb.Error.None)
		testing.expect_value(t, v, c.value)
		testing.expect(t, !pb.more(&d))
	}
}

@(test)
test_varint_errors :: proc(t: ^testing.T) {
	// 11 octets.
	d := pb.decoder_make(unhex("ffffffffffffffffffff01"))
	_, err := pb.read_varint(&d)
	testing.expect_value(t, err, pb.Error.Malformed_Varint)
	// 10th octet carrying more than the final bit.
	d = pb.decoder_make(unhex("ffffffffffffffffff02"))
	_, err = pb.read_varint(&d)
	testing.expect_value(t, err, pb.Error.Malformed_Varint)
	// Truncated.
	d = pb.decoder_make(unhex("8080"))
	_, err = pb.read_varint(&d)
	testing.expect_value(t, err, pb.Error.Truncated)
	d = pb.decoder_make({})
	_, err = pb.read_varint(&d)
	testing.expect_value(t, err, pb.Error.Truncated)
}

@(test)
test_zigzag :: proc(t: ^testing.T) {
	testing.expect_value(t, pb.zigzag32(0), 0)
	testing.expect_value(t, pb.zigzag32(-1), 1)
	testing.expect_value(t, pb.zigzag32(1), 2)
	testing.expect_value(t, pb.zigzag32(-2), 3)
	testing.expect_value(t, pb.zigzag32(max(i32)), 0xfffffffe)
	testing.expect_value(t, pb.zigzag32(min(i32)), 0xffffffff)
	testing.expect_value(t, pb.zigzag64(min(i64)), max(u64))

	for v in ([]i64{0, -1, 1, min(i64), max(i64), -123456789}) {
		buf: [10]u8
		e := pb.encoder_make(buf[:])
		pb.write_varint(&e, pb.zigzag64(v))
		d := pb.decoder_make(pb.encoded(&e))
		got, err := pb.read_sint64(&d)
		testing.expect_value(t, err, pb.Error.None)
		testing.expect_value(t, got, v)
	}
	for v in ([]i32{0, -1, 1, min(i32), max(i32)}) {
		buf: [10]u8
		e := pb.encoder_make(buf[:])
		pb.write_varint(&e, u64(pb.zigzag32(v)))
		d := pb.decoder_make(pb.encoded(&e))
		got, err := pb.read_sint32(&d)
		testing.expect_value(t, err, pb.Error.None)
		testing.expect_value(t, got, v)
	}
}

@(test)
test_tags :: proc(t: ^testing.T) {
	d := pb.decoder_make(unhex("00"))
	_, _, err := pb.read_tag(&d)
	testing.expect_value(t, err, pb.Error.Invalid_Tag) // field 0

	d = pb.decoder_make(unhex("0e"))
	_, _, err = pb.read_tag(&d)
	testing.expect_value(t, err, pb.Error.Invalid_Tag) // wire type 6

	// Field number 2^29 is out of range.
	d = pb.decoder_make(unhex("8080808010"))
	_, _, err = pb.read_tag(&d)
	testing.expect_value(t, err, pb.Error.Invalid_Tag)

	d = pb.decoder_make(unhex("f8ffffff0f"))
	field, wire, err2 := pb.read_tag(&d)
	testing.expect_value(t, err2, pb.Error.None)
	testing.expect_value(t, field, u32(pb.MAX_FIELD_NUMBER))
	testing.expect_value(t, wire, pb.Wire_Type.Varint)
}

@(test)
test_encoder_buffer_too_small :: proc(t: ^testing.T) {
	m := gen.Scalars {
		f_string = "hello",
	}
	buf: [3]u8
	_, err := pb.encode_into(&m, &gen.Scalars_CODEC, buf[:])
	testing.expect_value(t, err, pb.Error.Buffer_Too_Small)

	// A larger buffer receives the encoding at its end.
	big: [32]u8
	out, err2 := pb.encode_into(&m, &gen.Scalars_CODEC, big[:])
	testing.expect_value(t, err2, pb.Error.None)
	testing.expect_value(t, to_hex(out), "720568656c6c6f")
	testing.expect(t, raw_data(out) == &big[len(big) - len(out)])
}

// -----------------------------------------------------------------------------
// Known encodings (from the protobuf encoding guide and hand computation)
// -----------------------------------------------------------------------------

@(test)
test_scalar_encodings :: proc(t: ^testing.T) {
	m: gen.Scalars
	expect_encoding(t, &m, &gen.Scalars_CODEC, "") // defaults are not sent

	m = {f_int32 = 150}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "189601")
	m = {f_int32 = -1} // sign-extended to 10 octets
	expect_encoding(t, &m, &gen.Scalars_CODEC, "18ffffffffffffffffff01")
	m = {f_sint32 = -1}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "3801")
	m = {f_sint64 = -2}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "4003")
	m = {f_uint64 = max(u64)}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "30ffffffffffffffffff01")
	m = {f_double = 1.0}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "09000000000000f03f")
	m = {f_double = math.copy_sign_f64(0, -1)} // -0.0 differs from the default
	expect_encoding(t, &m, &gen.Scalars_CODEC, "090000000000000080")
	m = {f_float = 1.0}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "150000803f")
	m = {f_fixed32 = 0xdeadbeef}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "4defbeadde")
	m = {f_fixed64 = 1}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "510100000000000000")
	m = {f_sfixed32 = -2}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "5dfeffffff")
	m = {f_sfixed64 = -2}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "61feffffffffffffff")
	m = {f_bool = true}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "6801")
	m = {f_string = "testing"}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "720774657374696e67")
	m = {f_bytes = {0, 1, 2}}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "7a03000102")
	m = {f_enum = .COLOR_GREEN} // field 16: two-octet tag
	expect_encoding(t, &m, &gen.Scalars_CODEC, "800102")
	m = {f_enum = .COLOR_NEGATIVE}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "8001ffffffffffffffffff01")

	// Fields are emitted in field-number order.
	m = {f_bool = true, f_int32 = 1, f_string = "a"}
	expect_encoding(t, &m, &gen.Scalars_CODEC, "18016801720161")
}

@(test)
test_optional_presence :: proc(t: ^testing.T) {
	m: gen.Optionals
	expect_encoding(t, &m, &gen.Optionals_CODEC, "")
	// Explicitly set zero values are sent.
	m = {o_int32 = 0, o_string = "", o_bool = false, o_double = 0, o_enum = .COLOR_UNSPECIFIED}
	expect_encoding(t, &m, &gen.Optionals_CODEC, "0800120020002900000000000000003000")

	decoded: gen.Optionals
	data, _ := pb.marshal(&m, &gen.Optionals_CODEC, context.temp_allocator)
	testing.expect_value(t, gen.unmarshal(&decoded, data, context.temp_allocator), pb.Error.None)
	v, ok := decoded.o_int32.?
	testing.expect(t, ok && v == 0)
	s, s_ok := decoded.o_string.?
	testing.expect(t, s_ok && s == "")
	_, b_ok := decoded.o_bytes.?
	testing.expect(t, !b_ok)
}

@(test)
test_packed_encodings :: proc(t: ^testing.T) {
	// The example from the protobuf encoding guide (3, 270, 86942).
	m := gen.Repeated {
		r_int32 = pb.view([]i32{3, 270, 86942}),
	}
	expect_encoding(t, &m, &gen.Repeated_CODEC, "0a06038e029ea705")

	m = {r_unpacked = pb.view([]i32{1, 2})}
	expect_encoding(t, &m, &gen.Repeated_CODEC, "50015002")

	m = {r_bool = pb.view([]bool{true, false, true})}
	expect_encoding(t, &m, &gen.Repeated_CODEC, "2a03010001")

	m = {r_fixed32 = pb.view([]u32{1, 2})}
	expect_encoding(t, &m, &gen.Repeated_CODEC, "1a080100000002000000")

	m = {r_string = pb.view([]string{"a", "", "bc"})}
	expect_encoding(t, &m, &gen.Repeated_CODEC, "3a01613a003a026263")

	m = {r_sint64 = pb.view([]i64{-1, 1})}
	expect_encoding(t, &m, &gen.Repeated_CODEC, "12020102")
}

@(test)
test_packed_and_unpacked_are_interchangeable :: proc(t: ^testing.T) {
	// r_int32 (packed by default) sent unpacked, and r_unpacked sent packed,
	// interleaved with another field: all elements must be collected.
	data := unhex("0803" + "3a0178" + "088e02" + "52020102" + "0a039ea705")
	m: gen.Repeated
	testing.expect_value(t, gen.unmarshal(&m, data, context.temp_allocator), pb.Error.None)
	testing.expect_value(t, len(m.r_int32), 3)
	if len(m.r_int32) == 3 {
		testing.expect_value(t, m.r_int32[0], 3)
		testing.expect_value(t, m.r_int32[1], 270)
		testing.expect_value(t, m.r_int32[2], 86942)
	}
	testing.expect_value(t, len(m.r_unpacked), 2)
	testing.expect_value(t, len(m.r_string), 1)
}

// -----------------------------------------------------------------------------
// Round trips
// -----------------------------------------------------------------------------

SCALAR_BYTES := [3]u8{0, 0xff, 0x80}

full_scalars :: proc() -> gen.Scalars {
	return {
		f_double = -1.5e300,
		f_float = 3.25,
		f_int32 = min(i32),
		f_int64 = min(i64),
		f_uint32 = max(u32),
		f_uint64 = max(u64),
		f_sint32 = min(i32),
		f_sint64 = max(i64),
		f_fixed32 = 0x01020304,
		f_fixed64 = 0x0102030405060708,
		f_sfixed32 = -5,
		f_sfixed64 = -6,
		f_bool = true,
		f_string = "héllo, 世界",
		f_bytes = SCALAR_BYTES[:],
		f_enum = .COLOR_RED,
	}
}

expect_scalars_equal :: proc(t: ^testing.T, a, b: ^gen.Scalars, loc := #caller_location) {
	testing.expect_value(t, a.f_double, b.f_double, loc)
	testing.expect_value(t, a.f_float, b.f_float, loc)
	testing.expect_value(t, a.f_int32, b.f_int32, loc)
	testing.expect_value(t, a.f_int64, b.f_int64, loc)
	testing.expect_value(t, a.f_uint32, b.f_uint32, loc)
	testing.expect_value(t, a.f_uint64, b.f_uint64, loc)
	testing.expect_value(t, a.f_sint32, b.f_sint32, loc)
	testing.expect_value(t, a.f_sint64, b.f_sint64, loc)
	testing.expect_value(t, a.f_fixed32, b.f_fixed32, loc)
	testing.expect_value(t, a.f_fixed64, b.f_fixed64, loc)
	testing.expect_value(t, a.f_sfixed32, b.f_sfixed32, loc)
	testing.expect_value(t, a.f_sfixed64, b.f_sfixed64, loc)
	testing.expect_value(t, a.f_bool, b.f_bool, loc)
	testing.expect_value(t, a.f_string, b.f_string, loc)
	testing.expect_value(t, string(a.f_bytes), string(b.f_bytes), loc)
	testing.expect_value(t, a.f_enum, b.f_enum, loc)
}

@(test)
test_roundtrip_scalars :: proc(t: ^testing.T) {
	m := full_scalars()
	data, err := gen.marshal(&m, context.temp_allocator)
	testing.expect_value(t, err, pb.Error.None)
	testing.expect_value(t, len(data), gen.size(&m))

	out: gen.Scalars
	testing.expect_value(t, gen.unmarshal(&out, data), pb.Error.None)
	expect_scalars_equal(t, &m, &out)
	gen.destroy(&out) // the tracking allocator reports any leak
}

@(test)
test_roundtrip_repeated :: proc(t: ^testing.T) {
	inner := []gen.Scalars{full_scalars(), {}, {f_string = "x"}}
	m := gen.Repeated {
		r_int32    = pb.view([]i32{0, -1, max(i32), min(i32)}),
		r_sint64   = pb.view([]i64{min(i64), 0, max(i64)}),
		r_fixed32  = pb.view([]u32{0, 1, max(u32)}),
		r_double   = pb.view([]f64{math.inf_f64(1), -0.0, 1e-300}),
		r_bool     = pb.view([]bool{true, false}),
		r_enum     = pb.view([]gen.Color{.COLOR_RED, .COLOR_NEGATIVE, gen.Color(12345)}),
		r_string   = pb.view([]string{"", "a", "longer string value"}),
		r_bytes    = pb.view([][]u8{{}, {1, 2, 3}}),
		r_message  = pb.view(inner),
		r_unpacked = pb.view([]i32{7, 8, 9}),
		r_float    = pb.view([]f32{1.5, -2.25}),
		r_uint64   = pb.view([]u64{max(u64), 0}),
		r_sfixed64 = pb.view([]i64{min(i64), -1}),
	}
	data, err := gen.marshal(&m, context.temp_allocator)
	testing.expect_value(t, err, pb.Error.None)

	out: gen.Repeated
	testing.expect_value(t, gen.unmarshal(&out, data), pb.Error.None)
	defer gen.destroy(&out)

	testing.expect_value(t, len(out.r_int32), len(m.r_int32))
	for v, i in m.r_int32 {testing.expect_value(t, out.r_int32[i], v)}
	for v, i in m.r_sint64 {testing.expect_value(t, out.r_sint64[i], v)}
	for v, i in m.r_fixed32 {testing.expect_value(t, out.r_fixed32[i], v)}
	testing.expect_value(t, len(out.r_double), 3)
	testing.expect(t, math.is_inf(out.r_double[0], 1))
	testing.expect(t, math.sign_bit(out.r_double[1]))
	for v, i in m.r_enum {testing.expect_value(t, out.r_enum[i], v)}
	for v, i in m.r_string {testing.expect_value(t, out.r_string[i], v)}
	testing.expect_value(t, len(out.r_bytes), 2)
	testing.expect_value(t, string(out.r_bytes[1]), "\x01\x02\x03")
	testing.expect_value(t, len(out.r_message), 3)
	for i in 0 ..< min(len(out.r_message), 3) {
		expect_scalars_equal(t, &out.r_message[i], &inner[i])
	}
	for v, i in m.r_unpacked {testing.expect_value(t, out.r_unpacked[i], v)}
	for v, i in m.r_float {testing.expect_value(t, out.r_float[i], v)}
	for v, i in m.r_uint64 {testing.expect_value(t, out.r_uint64[i], v)}
	for v, i in m.r_sfixed64 {testing.expect_value(t, out.r_sfixed64[i], v)}
	for v, i in m.r_bool {testing.expect_value(t, out.r_bool[i], v)}

	// Re-encoding the decoded message reproduces the same bytes.
	again, _ := gen.marshal(&out, context.temp_allocator)
	testing.expect_value(t, to_hex(again), to_hex(data))
}

@(test)
test_roundtrip_maps :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)

	m: gen.Maps
	m.m_string_string = make(map[string]string, alloc)
	m.m_string_string["k1"] = "v1"
	m.m_string_string[""] = ""
	m.m_int32_int64 = make(map[i32]i64, alloc)
	m.m_int32_int64[-1] = min(i64)
	m.m_int32_int64[0] = 0
	m.m_bool_enum = make(map[bool]gen.Color, alloc)
	m.m_bool_enum[true] = .COLOR_GREEN
	m.m_string_message = make(map[string]gen.Scalars, alloc)
	m.m_string_message["full"] = full_scalars()
	m.m_string_message["empty"] = {}
	m.m_uint64_bytes = make(map[u64][]u8, alloc)
	m.m_uint64_bytes[max(u64)] = {9, 8}
	m.m_sint32_double = make(map[i32]f64, alloc)
	m.m_sint32_double[min(i32)] = 2.5
	m.m_fixed64_string = make(map[u64]string, alloc)
	m.m_fixed64_string[7] = "seven"

	data, err := gen.marshal(&m, alloc)
	testing.expect_value(t, err, pb.Error.None)

	out: gen.Maps
	testing.expect_value(t, gen.unmarshal(&out, data), pb.Error.None)
	defer gen.destroy(&out)

	testing.expect_value(t, len(out.m_string_string), 2)
	testing.expect_value(t, out.m_string_string["k1"], "v1")
	_, has_empty := out.m_string_string[""]
	testing.expect(t, has_empty)
	testing.expect_value(t, out.m_int32_int64[-1], min(i64))
	testing.expect_value(t, len(out.m_int32_int64), 2)
	testing.expect_value(t, out.m_bool_enum[true], gen.Color.COLOR_GREEN)
	testing.expect_value(t, len(out.m_string_message), 2)
	full := out.m_string_message["full"]
	want := full_scalars()
	expect_scalars_equal(t, &full, &want)
	testing.expect_value(t, string(out.m_uint64_bytes[max(u64)]), "\x09\x08")
	testing.expect_value(t, out.m_sint32_double[min(i32)], 2.5)
	testing.expect_value(t, out.m_fixed64_string[7], "seven")
}

@(test)
test_map_entry_edge_cases :: proc(t: ^testing.T) {
	// Entries with missing key or value use defaults; duplicate keys keep
	// the last value; unknown fields inside entries are skipped.
	data := unhex(
		"0a051203" + "616263" + // {value: "abc"} -> key ""
		"0a090a016b1201311a017a" + // {key: "k", value: "1", 3: "z"}
		"0a060a016b120132", // {key: "k", value: "2"}
	)
	m: gen.Maps
	testing.expect_value(t, gen.unmarshal(&m, data, context.temp_allocator), pb.Error.None)
	testing.expect_value(t, len(m.m_string_string), 2)
	testing.expect_value(t, m.m_string_string[""], "abc")
	testing.expect_value(t, m.m_string_string["k"], "2")
}

@(test)
test_roundtrip_nested_and_oneof :: proc(t: ^testing.T) {
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
	data, _ := gen.marshal(&m, context.temp_allocator)
	out: gen.Nested
	testing.expect_value(t, gen.unmarshal(&out, data), pb.Error.None)
	defer gen.destroy(&out)
	testing.expect(t, out.inner != nil && out.inner.value == 42)
	testing.expect(t, out.inner.deepest != nil && out.inner.deepest.name == "deep")
	testing.expect_value(t, out.mode, gen.Nested_Mode.MODE_FAST)
	testing.expect_value(t, len(out.inners), 2)
	testing.expect(t, out.inners[1].deepest != nil && out.inners[1].deepest.name == "deep")

	// Each oneof case round-trips.
	sc := full_scalars()
	ci := gen.Choice_Inner {
		x = 9,
	}
	cases := []gen.Choice_Kind {
		gen.Choice_Kind_Text("text"),
		gen.Choice_Kind_Number(0), // zero values in a oneof are still sent
		gen.Choice_Kind_Scalars(&sc),
		gen.Choice_Kind_Color(.COLOR_UNSPECIFIED),
		gen.Choice_Kind_Blob({}),
		gen.Choice_Kind_Inner(&ci),
	}
	for kind in cases {
		c := gen.Choice {
			kind  = kind,
			other = gen.Choice_Other_Flag(false),
			after = 5,
		}
		cdata, _ := gen.marshal(&c, context.temp_allocator)
		cout: gen.Choice
		testing.expect_value(t, gen.unmarshal(&cout, cdata), pb.Error.None)
		testing.expect_value(t, cout.after, 5)
		_, flag_set := cout.other.(gen.Choice_Other_Flag)
		testing.expect(t, flag_set)
		switch v in kind {
		case gen.Choice_Kind_Text:
			testing.expect_value(t, cout.kind.(gen.Choice_Kind_Text), v)
		case gen.Choice_Kind_Number:
			testing.expect_value(t, cout.kind.(gen.Choice_Kind_Number), v)
		case gen.Choice_Kind_Scalars:
			got, ok := cout.kind.(gen.Choice_Kind_Scalars)
			testing.expect(t, ok)
			if ok {expect_scalars_equal(t, (^gen.Scalars)(got), &sc)}
		case gen.Choice_Kind_Color:
			testing.expect_value(t, cout.kind.(gen.Choice_Kind_Color), v)
		case gen.Choice_Kind_Blob:
			got, ok := cout.kind.(gen.Choice_Kind_Blob)
			testing.expect(t, ok && len(got) == 0)
		case gen.Choice_Kind_Inner:
			got, ok := cout.kind.(gen.Choice_Kind_Inner)
			testing.expect(t, ok && got.x == 9)
		}
		gen.destroy(&cout)
	}
}

@(test)
test_oneof_last_case_wins_and_merges :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)
	// text, then number: number wins.
	m: gen.Choice
	testing.expect_value(t, gen.unmarshal(&m, unhex("0a0161" + "1007"), alloc), pb.Error.None)
	testing.expect_value(t, m.kind.(gen.Choice_Kind_Number), 7)

	// Two occurrences of the same message case merge.
	m = {}
	testing.expect_value(t, gen.unmarshal(&m, unhex("1a021801" + "1a026801"), alloc), pb.Error.None)
	sc, ok := m.kind.(gen.Choice_Kind_Scalars)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, sc.f_int32, 1)
		testing.expect_value(t, sc.f_bool, true)
	}
}

@(test)
test_recursive_tree :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)

	// A left-leaning chain 50 deep plus repeated/map recursion.
	root := new(gen.Tree, alloc)
	root.label = "root"
	node := root
	for i in 0 ..< 50 {
		child := new(gen.Tree, alloc)
		child.label = "n"
		node.left = child
		node = child
		_ = i
	}
	root.children = make([dynamic]gen.Tree, 2, alloc)
	root.children[1].label = "second"
	root.named = make(map[string]gen.Tree, alloc)
	root.named["x"] = gen.Tree {
		label = "named",
	}

	data, err := gen.marshal(root, alloc)
	testing.expect_value(t, err, pb.Error.None)
	out: gen.Tree
	testing.expect_value(t, gen.unmarshal(&out, data, alloc), pb.Error.None)
	depth := 0
	for n := out.left; n != nil; n = n.left {
		depth += 1
	}
	testing.expect_value(t, depth, 50)
	testing.expect_value(t, len(out.children), 2)
	testing.expect_value(t, out.children[1].label, "second")
	testing.expect_value(t, out.named["x"].label, "named")
}

@(test)
test_depth_limit :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)

	build :: proc(depth: int, alloc: runtime.Allocator) -> []u8 {
		root := new(gen.Tree, alloc)
		node := root
		for _ in 0 ..< depth {
			node.left = new(gen.Tree, alloc)
			node = node.left
		}
		data, _ := gen.marshal(root, alloc)
		return data
	}
	ok_data := build(pb.DEFAULT_MAX_DEPTH, alloc)
	out: gen.Tree
	testing.expect_value(t, gen.unmarshal(&out, ok_data, alloc), pb.Error.None)

	deep := build(pb.DEFAULT_MAX_DEPTH + 1, alloc)
	out = {}
	testing.expect_value(t, gen.unmarshal(&out, deep, alloc), pb.Error.Depth_Limit_Exceeded)

	out = {}
	testing.expect_value(t, gen.unmarshal(&out, ok_data, alloc, {max_depth = 10}), pb.Error.Depth_Limit_Exceeded)
}

@(test)
test_keyword_fields_and_large_numbers :: proc(t: ^testing.T) {
	k := gen.Keywords {
		proc_    = 1,
		map_     = "m",
		context_ = true,
		string_  = pb.view([]string{"s"}),
		len_     = 2,
	}
	data, _ := gen.marshal(&k, context.temp_allocator)
	out: gen.Keywords
	testing.expect_value(t, gen.unmarshal(&out, data, context.temp_allocator), pb.Error.None)
	testing.expect_value(t, out.proc_, 1)
	testing.expect_value(t, out.map_, "m")
	testing.expect_value(t, out.context_, true)
	testing.expect_value(t, out.len_, 2)

	l := gen.Large {
		f1    = 1,
		f_max = 2,
		f_big = "b",
	}
	// Tags: field 1 (1 octet), 100000 (3 octets), 536870911 (5 octets).
	expect_encoding(t, &l, &gen.Large_CODEC, "0801" + "82ea300162" + "f8ffffff0f02")
}

@(test)
test_well_known_and_proto2 :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)

	ts := gen.Google_Protobuf_Timestamp {
		seconds = 1700000000,
		nanos   = 123,
	}
	list := gen.Google_Protobuf_ListValue {
		values = pb.view([]gen.Google_Protobuf_Value{{kind = gen.Google_Protobuf_Value_Kind_Number_Value(1.5)}, {kind = gen.Google_Protobuf_Value_Kind_Null_Value(.NULL_VALUE)}}),
	}
	attrs := gen.Google_Protobuf_Struct {
		fields = make(map[string]gen.Google_Protobuf_Value, alloc),
	}
	attrs.fields["list"] = {
		kind = gen.Google_Protobuf_Value_Kind_List_Value(&list),
	}
	attrs.fields["s"] = {
		kind = gen.Google_Protobuf_Value_Kind_String_Value("str"),
	}
	child := gen.Legacy {
		id = 2,
	}
	legacy := gen.Legacy {
		id       = 1,
		name     = "legacy",
		unpacked = pb.view([]i32{1, 2}),
		packed   = pb.view([]i32{3, 4}),
		level    = gen.Level.HIGH,
		child    = &child,
	}
	m := gen.WithWellKnown {
		created    = &ts,
		attributes = &attrs,
		legacy     = &legacy,
	}
	data, err := gen.marshal(&m, alloc)
	testing.expect_value(t, err, pb.Error.None)

	out: gen.WithWellKnown
	testing.expect_value(t, gen.unmarshal(&out, data, alloc), pb.Error.None)
	testing.expect(t, out.created != nil && out.created.seconds == 1700000000 && out.created.nanos == 123)
	testing.expect(t, out.attributes != nil && len(out.attributes.fields) == 2)
	lv, lv_ok := out.attributes.fields["list"].kind.(gen.Google_Protobuf_Value_Kind_List_Value)
	testing.expect(t, lv_ok && len(lv.values) == 2)
	testing.expect_value(t, out.attributes.fields["s"].kind.(gen.Google_Protobuf_Value_Kind_String_Value), "str")

	l := out.legacy
	testing.expect(t, l != nil)
	testing.expect_value(t, l.id.?, 1)
	testing.expect_value(t, l.name.?, "legacy")
	testing.expect_value(t, l.level.?, gen.Level.HIGH)
	testing.expect_value(t, len(l.unpacked), 2)
	testing.expect_value(t, len(l.packed), 2)
	testing.expect(t, l.child != nil && l.child.id.? == 2)

	// proto2: `unpacked` is sent unpacked, `packed` packed.
	enc, _ := gen.marshal(&legacy, alloc)
	testing.expect(t, strings.contains(to_hex(enc), "18011802"))
	testing.expect(t, strings.contains(to_hex(enc), "22020304"))
}

@(test)
test_proto2_strings_skip_utf8_validation :: proc(t: ^testing.T) {
	// name (field 2) with invalid UTF-8.
	data := unhex("0801" + "1202ff00")
	l: gen.Legacy
	testing.expect_value(t, gen.unmarshal(&l, data, context.temp_allocator), pb.Error.None)
	testing.expect_value(t, l.name.?, "\xff\x00")

	// The same octets in a proto3 string field are rejected.
	s: gen.Scalars
	testing.expect_value(t, gen.unmarshal(&s, unhex("7202ff00"), context.temp_allocator), pb.Error.Invalid_UTF8)
}

// -----------------------------------------------------------------------------
// Unknown fields, merging, aliasing
// -----------------------------------------------------------------------------

@(test)
test_unknown_fields_preserved :: proc(t: ^testing.T) {
	m := full_scalars()
	data, _ := gen.marshal(&m, context.temp_allocator)

	// Decoding as Empty keeps everything as unknown fields...
	e: gen.Empty
	testing.expect_value(t, gen.unmarshal(&e, data), pb.Error.None)
	testing.expect_value(t, len(e._unknown_fields), len(data))
	again, _ := gen.marshal(&e, context.temp_allocator)
	testing.expect_value(t, to_hex(again), to_hex(data))
	gen.destroy(&e) // several unknown fields: must not leak

	// ...unless discarded.
	e2: gen.Empty
	testing.expect_value(t, gen.unmarshal(&e2, data, context.temp_allocator, {discard_unknown = true}), pb.Error.None)
	testing.expect_value(t, len(e2._unknown_fields), 0)

	// Known field with the wrong wire type is kept as unknown, not an error.
	s: gen.Scalars
	testing.expect_value(t, gen.unmarshal(&s, unhex("1d01000000"), context.temp_allocator), pb.Error.None)
	testing.expect_value(t, s.f_int32, 0)
	testing.expect_value(t, to_hex(s._unknown_fields[:]), "1d01000000")

	// Unknown groups are skipped as a unit.
	g: gen.Empty
	testing.expect_value(t, gen.unmarshal(&g, unhex("0b" + "1001" + "0c" + "1802"), context.temp_allocator), pb.Error.None)
	testing.expect_value(t, to_hex(g._unknown_fields[:]), "0b10010c1802")
}

@(test)
test_merge_semantics :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)
	first := gen.Repeated {
		r_int32  = pb.view([]i32{1, 2}),
		r_string = pb.view([]string{"a"}),
	}
	second := gen.Repeated {
		r_int32  = pb.view([]i32{3}),
		r_string = pb.view([]string{"b"}),
	}
	d1, _ := gen.marshal(&first, alloc)
	d2, _ := gen.marshal(&second, alloc)
	m: gen.Repeated
	gen.unmarshal(&m, d1, alloc)
	gen.unmarshal(&m, d2, alloc)
	testing.expect_value(t, len(m.r_int32), 3)
	testing.expect_value(t, m.r_int32[2], 3)
	testing.expect_value(t, len(m.r_string), 2)
	testing.expect_value(t, m.r_string[1], "b")

	// Singular scalars: last one wins; sub-messages merge.
	n: gen.Nested
	gen.unmarshal(&n, unhex("0a020801" + "1001" + "0a0412020a00"), alloc)
	testing.expect(t, n.inner != nil && n.inner.value == 1 && n.inner.deepest != nil)
	testing.expect_value(t, n.mode, gen.Nested_Mode.MODE_FAST)
}

@(test)
test_alias_input :: proc(t: ^testing.T) {
	data := unhex("720568656c6c6f" + "7a03010203")
	s: gen.Scalars
	testing.expect_value(t, gen.unmarshal(&s, data, context.temp_allocator, {alias_input = true}), pb.Error.None)
	testing.expect_value(t, s.f_string, "hello")
	testing.expect(t, raw_data(s.f_string) == &data[2])
	testing.expect(t, raw_data(s.f_bytes) == &data[9])
}

// -----------------------------------------------------------------------------
// Malformed input
// -----------------------------------------------------------------------------

@(test)
test_malformed_inputs :: proc(t: ^testing.T) {
	Case :: struct {
		hex: string,
		err: pb.Error,
	}
	cases := []Case {
		{"18", .Truncated}, // tag without value
		{"7205616263", .Invalid_Length}, // string longer than input
		{"09000000", .Truncated}, // short fixed64
		{"15000080", .Truncated}, // short fixed32
		{"0c", .Invalid_Group}, // stray END_GROUP
		{"0b1001", .Invalid_Group}, // unterminated group
		{"0b0c", .None}, // empty group: fine
		{"0b14", .Invalid_Group}, // mismatched END_GROUP (field 2)
		{"0f", .Invalid_Tag}, // wire type 7
		{"8001ffffffffffffffffff7f", .Malformed_Varint},
	}
	for c in cases {
		s: gen.Scalars
		err := gen.unmarshal(&s, unhex(c.hex), context.temp_allocator)
		testing.expectf(t, err == c.err, "input %s: got %v, want %v", c.hex, err, c.err)
	}

	// A sub-message whose length cuts a field in half.
	n: gen.Nested
	testing.expect_value(t, gen.unmarshal(&n, unhex("0a01" + "08"), context.temp_allocator), pb.Error.Truncated)
	// A packed run whose length cuts a varint in half.
	r: gen.Repeated
	testing.expect_value(t, gen.unmarshal(&r, unhex("0a0180"), context.temp_allocator), pb.Error.Truncated)
	// A packed fixed32 run that is not a multiple of 4.
	r = {}
	testing.expect_value(t, gen.unmarshal(&r, unhex("1a03010203"), context.temp_allocator), pb.Error.Truncated)
}

// Random and mutated inputs must only ever produce errors, never crashes,
// out-of-bounds accesses or leaks.
@(test)
test_fuzz_decoders :: proc(t: ^testing.T) {
	r := rand.create(t.seed)
	gen_ := rand.default_random_generator(&r)

	seed_msgs: [3][]u8
	sc := full_scalars()
	seed_msgs[0], _ = gen.marshal(&sc, context.temp_allocator)
	rep := gen.Repeated {
		r_int32   = pb.view([]i32{1, 300, -5}),
		r_message = pb.view([]gen.Scalars{full_scalars()}),
		r_string  = pb.view([]string{"x", "yz"}),
	}
	seed_msgs[1], _ = gen.marshal(&rep, context.temp_allocator)
	tree := gen.Tree {
		label    = "t",
		children = pb.view([]gen.Tree{{label = "c"}}),
	}
	seed_msgs[2], _ = gen.marshal(&tree, context.temp_allocator)

	buf := make([]u8, 256, context.temp_allocator)
	for iter in 0 ..< 3000 {
		input: []u8
		if iter % 2 == 0 {
			n := rand.int_max(len(buf), gen_)
			for i in 0 ..< n {buf[i] = u8(rand.uint32(gen_))}
			input = buf[:n]
		} else {
			src := seed_msgs[iter % 3]
			n := copy(buf, src)
			for _ in 0 ..< 1 + rand.int_max(4, gen_) {
				if n == 0 {break}
				buf[rand.int_max(n, gen_)] = u8(rand.uint32(gen_))
			}
			input = buf[:rand.int_max(n + 1, gen_)]
		}

		a: Arena
		alloc := arena_allocator(&a)
		s: gen.Scalars
		_ = gen.unmarshal(&s, input, alloc)
		rp: gen.Repeated
		_ = gen.unmarshal(&rp, input, alloc)
		mp: gen.Maps
		_ = gen.unmarshal(&mp, input, alloc)
		tr: gen.Tree
		_ = gen.unmarshal(&tr, input, alloc)
		ch: gen.Choice
		_ = gen.unmarshal(&ch, input, alloc)
		// Whatever decoded successfully must re-encode within its size.
		if err := gen.unmarshal(&rp, input, alloc); err == .None {
			out, merr := gen.marshal(&rp, alloc)
			testing.expect_value(t, merr, pb.Error.None)
			testing.expect_value(t, len(out), gen.size(&rp))
		}
		arena_destroy(&a)
	}
}
