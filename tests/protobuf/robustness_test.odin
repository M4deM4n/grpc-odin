package protobuf_test

import "core:math"
import "core:mem"
import "core:testing"

import pb "grpc:protobuf"
import "gen"

// repeat_bytes builds an input consisting of `unit` repeated n times.
repeat_bytes :: proc(unit: []u8, n: int) -> []u8 {
	out := make([]u8, len(unit) * n, context.temp_allocator)
	for i in 0 ..< n {
		copy(out[i * len(unit):], unit)
	}
	return out
}

// Tracked runs decodes through a tracking allocator to measure the total
// number of bytes allocated.
Tracked :: struct {
	tracker: mem.Tracking_Allocator,
}

tracked_init :: proc(t: ^Tracked) -> mem.Allocator {
	mem.tracking_allocator_init(&t.tracker, context.allocator)
	return mem.tracking_allocator(&t.tracker)
}

tracked_destroy :: proc(t: ^Tracked) {
	mem.tracking_allocator_destroy(&t.tracker)
}

// A singular sub-message repeated on the wire merges each time; repeated
// fields inside it must grow geometrically, not by copying every time.
// Doubling the input must roughly double the allocation (quadratic growth
// would quadruple it).
@(test)
test_merge_growth_is_linear :: proc(t: ^testing.T) {
	allocated :: proc(t: ^testing.T, n: int) -> i64 {
		// Tree.left = {children: [{}]}, n times.
		input := repeat_bytes({0x12, 0x02, 0x22, 0x00}, n)
		tr: Tracked
		alloc := tracked_init(&tr)
		defer tracked_destroy(&tr)
		tree: gen.Tree
		testing.expect_value(t, gen.unmarshal(&tree, input, alloc), pb.Error.None)
		testing.expect(t, tree.left != nil && len(tree.left.children) == n)
		total := tr.tracker.total_memory_allocated
		gen.destroy(&tree, alloc)
		testing.expect_value(t, len(tr.tracker.allocation_map), 0)
		return total
	}
	small := allocated(t, 10_000)
	large := allocated(t, 20_000)
	testing.expectf(t, f64(large) < 2.6 * f64(small), "allocation grew from %d to %d bytes", small, large)
}

@(test)
test_unknown_field_growth_is_linear :: proc(t: ^testing.T) {
	N :: 20_000
	// Unknown field 100 (varint 1) alternated with f_string = "a".
	input := repeat_bytes({0xa0, 0x06, 0x01, 0x72, 0x01, 0x61}, N)

	tr: Tracked
	alloc := tracked_init(&tr)
	defer tracked_destroy(&tr)

	s: gen.Scalars
	testing.expect_value(t, gen.unmarshal(&s, input, alloc), pb.Error.None)
	testing.expect_value(t, len(s._unknown_fields), 3 * N)
	total := tr.tracker.total_memory_allocated
	testing.expectf(t, total < i64(16 * len(input)), "allocated %d bytes for %d input bytes", total, len(input))
	gen.destroy(&s, alloc)
	testing.expect_value(t, len(tr.tracker.allocation_map), 0)
}

@(test)
test_duplicate_map_keys_do_not_amplify :: proc(t: ^testing.T) {
	N :: 50_000
	// m_string_message entries with empty key and value, N times.
	input := repeat_bytes({0x22, 0x00}, N)

	tr: Tracked
	alloc := tracked_init(&tr)
	defer tracked_destroy(&tr)

	m: gen.Maps
	testing.expect_value(t, gen.unmarshal(&m, input, alloc), pb.Error.None)
	testing.expect_value(t, len(m.m_string_message), 1)
	total := tr.tracker.total_memory_allocated
	testing.expectf(t, total < 64 * 1024, "allocated %d bytes for a single-entry map", total)
	gen.destroy(&m, alloc)
	testing.expect_value(t, len(tr.tracker.allocation_map), 0)
}

// Values replaced while decoding are released (heap allocator: the test
// runner reports any leak).
@(test)
test_replaced_values_are_freed :: proc(t: ^testing.T) {
	// f_string twice, f_bytes twice.
	s: gen.Scalars
	testing.expect_value(t, gen.unmarshal(&s, unhex("720161" + "720162" + "7a0101" + "7a0102")), pb.Error.None)
	testing.expect_value(t, s.f_string, "b")
	testing.expect_value(t, string(s.f_bytes), "\x02")
	gen.destroy(&s)

	// Oneof: string -> message -> bytes -> message -> int.
	c: gen.Choice
	testing.expect_value(t, gen.unmarshal(&c, unhex("0a0161" + "1a03720161" + "2a0101" + "1a00" + "1007")), pb.Error.None)
	testing.expect_value(t, c.kind.(gen.Choice_Kind_Number), 7)
	gen.destroy(&c)

	// Map: duplicate string key with string values; key repeated inside an entry.
	m: gen.Maps
	testing.expect_value(t, gen.unmarshal(&m, unhex("0a060a016b120131" + "0a090a016b0a016b120132")), pb.Error.None)
	testing.expect_value(t, len(m.m_string_string), 1)
	testing.expect_value(t, m.m_string_string["k"], "2")
	// Duplicate key with message values.
	testing.expect_value(t, gen.unmarshal(&m, unhex("22080a016b1203720161" + "22080a016b1203720162")), pb.Error.None)
	testing.expect_value(t, len(m.m_string_message), 1)
	gen.destroy(&m)

	// proto2 optional string replaced.
	l: gen.Legacy
	testing.expect_value(t, gen.unmarshal(&l, unhex("0801" + "120161" + "120162")), pb.Error.None)
	testing.expect_value(t, l.name.?, "b")
	gen.destroy(&l)
}

// Merging keeps each dynamic array with the allocator that owns it.
@(test)
test_merge_across_allocators :: proc(t: ^testing.T) {
	a: Arena
	arena := arena_allocator(&a)
	defer arena_destroy(&a)

	s: gen.Scalars
	testing.expect_value(t, gen.unmarshal(&s, unhex("a00601"), arena), pb.Error.None)
	testing.expect_value(t, gen.unmarshal(&s, unhex("a00602"), context.allocator), pb.Error.None)
	testing.expect_value(t, to_hex(s._unknown_fields[:]), "a00601a00602")
	testing.expect(t, s._unknown_fields.allocator.data == arena.data)
}

// -----------------------------------------------------------------------------
// proto2 semantics
// -----------------------------------------------------------------------------

@(test)
test_closed_enum_unknown_values :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)

	// level = 7 (undeclared) and level = 2: only HIGH is kept as the field.
	l: gen.Legacy
	testing.expect_value(t, gen.unmarshal(&l, unhex("0801" + "2807" + "2802"), alloc), pb.Error.None)
	testing.expect_value(t, l.level.?, gen.Level.HIGH)
	testing.expect_value(t, to_hex(l._unknown_fields[:]), "2807")

	l2: gen.Legacy
	testing.expect_value(t, gen.unmarshal(&l2, unhex("0801" + "2807"), alloc), pb.Error.None)
	_, has_level := l2.level.?
	testing.expect(t, !has_level)

	// Packed run [1, 9, 2]: 9 becomes an unknown varint field 8.
	l3: gen.Legacy
	testing.expect_value(t, gen.unmarshal(&l3, unhex("0801" + "4203010902"), alloc), pb.Error.None)
	testing.expect_value(t, len(l3.levels), 2)
	testing.expect_value(t, to_hex(l3._unknown_fields[:]), "4009")

	// Map entry {key: 1, value: 5}: undeclared value, so the whole entry is
	// kept as unknown.
	l4: gen.Legacy
	testing.expect_value(t, gen.unmarshal(&l4, unhex("0801" + "4a0408011005" + "4a0408021001"), alloc), pb.Error.None)
	testing.expect_value(t, len(l4.mode_map), 1)
	testing.expect_value(t, l4.mode_map[2], gen.Mode.MODE_ONE)
	testing.expect_value(t, to_hex(l4._unknown_fields[:]), "4a0408011005")

	// Unknown values re-encode unchanged.
	out, _ := gen.marshal(&l, alloc)
	testing.expect_value(t, to_hex(out), "08012802" + "2807")
}

@(test)
test_required_fields :: proc(t: ^testing.T) {
	a: Arena
	alloc := arena_allocator(&a)
	defer arena_destroy(&a)
	l: gen.Legacy
	testing.expect_value(t, gen.unmarshal(&l, unhex("120161"), alloc), pb.Error.Missing_Required_Field)
	// Required fields of sub-messages are checked too.
	l = {}
	testing.expect_value(t, gen.unmarshal(&l, unhex("0801" + "3200"), alloc), pb.Error.Missing_Required_Field)
	l = {}
	testing.expect_value(t, gen.unmarshal(&l, unhex("0801" + "32020802"), alloc), pb.Error.None)
}

@(test)
test_default_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, gen.Legacy_count_DEFAULT, -5)
	testing.expect(t, math.is_inf(gen.Legacy_ratio_DEFAULT, -1))
	testing.expect_value(t, gen.Legacy_scale_DEFAULT, 1.5)
	testing.expect_value(t, gen.Legacy_def_level_DEFAULT, gen.Level.HIGH)
	testing.expect_value(t, gen.Legacy_flag_DEFAULT, true)
	testing.expect_value(t, gen.Legacy_big_DEFAULT, max(u64))
	testing.expect_value(t, gen.Legacy_greeting_DEFAULT, "hi\n")
	testing.expect_value(t, gen.Legacy_data_DEFAULT, "x\x01\"y")

	// Typical use: the default applies when the field is absent.
	l: gen.Legacy
	testing.expect_value(t, l.count.? or_else gen.Legacy_count_DEFAULT, -5)
}

// -----------------------------------------------------------------------------
// Encoding robustness
// -----------------------------------------------------------------------------

@(test)
test_nil_oneof_message_case :: proc(t: ^testing.T) {
	// A nil pointer stored in a message case is treated as unset.
	c := gen.Choice {
		kind  = gen.Choice_Kind_Scalars(nil),
		after = 1,
	}
	expect_encoding(t, &c, &gen.Choice_CODEC, "a00101")
	gen.Choice_Kind_free(&c.kind)
	testing.expect(t, c.kind == nil)
}

@(test)
test_view_is_non_owning :: proc(t: ^testing.T) {
	values := [3]i32{1, 2, 3}
	r := gen.Repeated {
		r_int32 = pb.view(values[:]),
	}
	expect_encoding(t, &r, &gen.Repeated_CODEC, "0a03010203")
	// Decoding (merging) into a view cannot grow it.
	testing.expect_value(t, gen.unmarshal(&r, unhex("0804")), pb.Error.Out_Of_Memory)
}
