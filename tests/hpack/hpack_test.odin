package hpack_test

import "core:encoding/hex"
import "core:math/rand"
import "core:strings"
import "core:testing"

import "../../hpack"

Field :: hpack.Header_Field

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

unhex :: proc(s: string) -> []u8 {
	b, ok := hex.decode(transmute([]u8)s, context.temp_allocator)
	assert(ok, "bad hex in test vector")
	return b
}

Collected :: struct {
	fields:    [dynamic]Field,
	sensitive: [dynamic]bool,
}

collect :: proc(user: rawptr, f: Field, sensitive: bool) {
	c := (^Collected)(user)
	append(&c.fields, Field{strings.clone(f.name, context.temp_allocator), strings.clone(f.value, context.temp_allocator)})
	append(&c.sensitive, sensitive)
}

new_collected :: proc() -> Collected {
	return {fields = make([dynamic]Field, context.temp_allocator), sensitive = make([dynamic]bool, context.temp_allocator)}
}

decode :: proc(d: ^hpack.Decoder, block: []u8) -> ([]Field, hpack.Error) {
	c := new_collected()
	err := hpack.decode_block(d, block, collect, &c)
	return c.fields[:], err
}

expect_fields :: proc(t: ^testing.T, got, want: []Field, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc)
	for i in 0 ..< min(len(got), len(want)) {
		testing.expect_value(t, got[i], want[i], loc)
	}
}

// expect_table checks the dynamic table contents, newest first.
expect_table :: proc(t: ^testing.T, table: ^hpack.Dynamic_Table, size: int, want: []Field, loc := #caller_location) {
	testing.expect_value(t, table.size, size, loc)
	testing.expect_value(t, table.count, len(want), loc)
	for w, i in want {
		f, ok := hpack.table_get(table, i + 1)
		testing.expect(t, ok, "missing table entry", loc = loc)
		testing.expect_value(t, f, w, loc)
	}
}

encode :: proc(e: ^hpack.Encoder, fields: []Field) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	assert(hpack.encoder_begin_block(e, &out) == .None)
	for f in fields {
		assert(hpack.encode_field(e, &out, f.name, f.value) == .None)
	}
	return out[:]
}

// -----------------------------------------------------------------------------
// Integers (RFC 7541 §5.1, Appendix C.1)
// -----------------------------------------------------------------------------

@(test)
test_integer_rfc_examples :: proc(t: ^testing.T) {
	Case :: struct {
		value:  int,
		prefix: uint,
		bytes:  string,
	}
	cases := []Case{{10, 5, "0a"}, {1337, 5, "1f9a0a"}, {42, 8, "2a"}, {31, 5, "1f00"}, {0, 1, "00"}, {127, 7, "7f00"}}
	for c in cases {
		out := make([dynamic]u8, context.temp_allocator)
		testing.expect_value(t, hpack.append_integer(&out, c.value, c.prefix, 0), hpack.Error.None)
		testing.expect_value(t, string(out[:]), string(unhex(c.bytes)))
		testing.expect_value(t, hpack.integer_encoded_len(c.value, c.prefix), len(out))

		pos := 0
		v, err := hpack.decode_integer(out[:], &pos, c.prefix)
		testing.expect_value(t, err, hpack.Error.None)
		testing.expect_value(t, v, c.value)
		testing.expect_value(t, pos, len(out))
	}
}

@(test)
test_integer_flags_preserved :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	hpack.append_integer(&out, 3, 6, 0x40)
	testing.expect_value(t, out[0], 0x43)
	pos := 0
	v, _ := hpack.decode_integer(out[:], &pos, 6)
	testing.expect_value(t, v, 3)
}

@(test)
test_integer_errors :: proc(t: ^testing.T) {
	pos := 0
	_, err := hpack.decode_integer({}, &pos, 5)
	testing.expect_value(t, err, hpack.Error.Truncated)

	pos = 0
	_, err = hpack.decode_integer({0x1f, 0x80}, &pos, 5)
	testing.expect_value(t, err, hpack.Error.Truncated)

	// Value beyond MAX_INTEGER.
	pos = 0
	_, err = hpack.decode_integer({0x1f, 0xff, 0xff, 0xff, 0xff, 0x0f}, &pos, 5)
	testing.expect_value(t, err, hpack.Error.Integer_Overflow)

	// Excessive zero-valued continuation octets.
	pos = 0
	_, err = hpack.decode_integer({0x1f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00}, &pos, 5)
	testing.expect_value(t, err, hpack.Error.Integer_Overflow)
}

// -----------------------------------------------------------------------------
// Huffman (RFC 7541 §5.2, Appendix B)
// -----------------------------------------------------------------------------

@(test)
test_huffman_rfc_strings :: proc(t: ^testing.T) {
	Case :: struct {
		plain, coded: string,
	}
	cases := []Case {
		{"www.example.com", "f1e3c2e5f23a6ba0ab90f4ff"},
		{"no-cache", "a8eb10649cbf"},
		{"custom-key", "25a849e95ba97d7f"},
		{"custom-value", "25a849e95bb8e8b4bf"},
		{"302", "6402"},
		{"private", "aec3771a4b"},
		{"Mon, 21 Oct 2013 20:13:21 GMT", "d07abe941054d444a8200595040b8166e082a62d1bff"},
		{"https://www.example.com", "9d29ad171863c78f0b97c8e9ae82ae43d3"},
		{"", ""},
	}
	for c in cases {
		out := make([dynamic]u8, context.temp_allocator)
		testing.expect_value(t, hpack.append_huffman(&out, c.plain), hpack.Error.None)
		testing.expect_value(t, string(out[:]), string(unhex(c.coded)))
		testing.expect_value(t, hpack.huffman_encoded_len(c.plain), len(out))

		dec := make([dynamic]u8, context.temp_allocator)
		testing.expect_value(t, hpack.append_huffman_decoded(&dec, unhex(c.coded)), hpack.Error.None)
		testing.expect_value(t, string(dec[:]), c.plain)
	}
}

@(test)
test_huffman_roundtrip_all_octets :: proc(t: ^testing.T) {
	all: [256]u8
	for i in 0 ..< 256 {
		all[i] = u8(i)
	}
	r := rand.create(0x5eed)
	gen := rand.default_random_generator(&r)
	buf := make([]u8, 300, context.temp_allocator)
	inputs := [][]u8{all[:], buf}
	for iter in 0 ..< 200 {
		n := rand.int_max(len(buf), gen)
		for i in 0 ..< n {
			buf[i] = u8(rand.uint32(gen))
		}
		inputs[1] = buf[:n]
		// The full octet range is checked once, random strings every time.
		for in_bytes in inputs[0 if iter == 0 else 1:] {
			enc := make([dynamic]u8, context.temp_allocator)
			hpack.append_huffman(&enc, string(in_bytes))
			dec := make([dynamic]u8, context.temp_allocator)
			err := hpack.append_huffman_decoded(&dec, enc[:])
			testing.expect_value(t, err, hpack.Error.None)
			testing.expect(t, string(dec[:]) == string(in_bytes), "huffman roundtrip mismatch")
		}
	}
}

@(test)
test_huffman_invalid :: proc(t: ^testing.T) {
	dec := make([dynamic]u8, context.temp_allocator)
	// 30 one-bits is EOS, which must never be decoded.
	testing.expect_value(t, hpack.append_huffman_decoded(&dec, {0xff, 0xff, 0xff, 0xff}), hpack.Error.Invalid_Huffman)
	// Padding longer than 7 bits: 'a' (00011) followed by 11 one-bits.
	clear(&dec)
	testing.expect_value(t, hpack.append_huffman_decoded(&dec, {0x1f, 0xff}), hpack.Error.Invalid_Huffman)
	// '0' (00000) followed by "000": the padding is not a prefix of EOS.
	clear(&dec)
	testing.expect_value(t, hpack.append_huffman_decoded(&dec, {0x00}), hpack.Error.Invalid_Huffman)
	// '0' (00000) followed by "111": valid.
	clear(&dec)
	testing.expect_value(t, hpack.append_huffman_decoded(&dec, {0x07}), hpack.Error.None)
	testing.expect_value(t, string(dec[:]), "0")
	// A whole octet of padding.
	clear(&dec)
	testing.expect_value(t, hpack.append_huffman_decoded(&dec, {0xff}), hpack.Error.Invalid_Huffman)
}

@(test)
test_huffman_decode_buffer_too_small :: proc(t: ^testing.T) {
	dst: [1]u8
	_, err := hpack.huffman_decode(dst[:], unhex("f1e3c2e5f23a6ba0ab90f4ff"))
	testing.expect_value(t, err, hpack.Error.Buffer_Too_Small)
}

// -----------------------------------------------------------------------------
// Header field representations (Appendix C.2)
// -----------------------------------------------------------------------------

@(test)
test_c2_representations :: proc(t: ^testing.T) {
	d: hpack.Decoder
	hpack.decoder_init(&d)
	defer hpack.decoder_destroy(&d)

	// C.2.1 Literal with indexing.
	got, err := decode(&d, unhex("400a637573746f6d2d6b65790d637573746f6d2d686561646572"))
	testing.expect_value(t, err, hpack.Error.None)
	expect_fields(t, got, {{"custom-key", "custom-header"}})
	expect_table(t, &d.table, 55, {{"custom-key", "custom-header"}})

	// C.2.2 Literal without indexing.
	hpack.decoder_destroy(&d)
	hpack.decoder_init(&d)
	got, err = decode(&d, unhex("040c2f73616d706c652f70617468"))
	testing.expect_value(t, err, hpack.Error.None)
	expect_fields(t, got, {{":path", "/sample/path"}})
	expect_table(t, &d.table, 0, {})

	// C.2.3 Literal never indexed.
	c := new_collected()
	err = hpack.decode_block(&d, unhex("100870617373776f726406736563726574"), collect, &c)
	testing.expect_value(t, err, hpack.Error.None)
	expect_fields(t, c.fields[:], {{"password", "secret"}})
	testing.expect_value(t, c.sensitive[0], true)
	expect_table(t, &d.table, 0, {})

	// C.2.4 Indexed field.
	got, err = decode(&d, {0x82})
	testing.expect_value(t, err, hpack.Error.None)
	expect_fields(t, got, {{":method", "GET"}})
}

// -----------------------------------------------------------------------------
// Request/response sequences (Appendix C.3 - C.6)
// -----------------------------------------------------------------------------

Step :: struct {
	block:  string,
	fields: []Field,
	size:   int,
	table:  []Field,
}

REQUEST_1 := []Field{{":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":authority", "www.example.com"}}
REQUEST_2 := []Field {
	{":method", "GET"},
	{":scheme", "http"},
	{":path", "/"},
	{":authority", "www.example.com"},
	{"cache-control", "no-cache"},
}
REQUEST_3 := []Field {
	{":method", "GET"},
	{":scheme", "https"},
	{":path", "/index.html"},
	{":authority", "www.example.com"},
	{"custom-key", "custom-value"},
}
REQUEST_TABLE_1 := []Field{{":authority", "www.example.com"}}
REQUEST_TABLE_2 := []Field{{"cache-control", "no-cache"}, {":authority", "www.example.com"}}
REQUEST_TABLE_3 := []Field{{"custom-key", "custom-value"}, {"cache-control", "no-cache"}, {":authority", "www.example.com"}}

RESPONSE_1 := []Field {
	{":status", "302"},
	{"cache-control", "private"},
	{"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
	{"location", "https://www.example.com"},
}
RESPONSE_2 := []Field {
	{":status", "307"},
	{"cache-control", "private"},
	{"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
	{"location", "https://www.example.com"},
}
RESPONSE_3 := []Field {
	{":status", "200"},
	{"cache-control", "private"},
	{"date", "Mon, 21 Oct 2013 20:13:22 GMT"},
	{"location", "https://www.example.com"},
	{"content-encoding", "gzip"},
	{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"},
}
RESPONSE_TABLE_1 := []Field {
	{"location", "https://www.example.com"},
	{"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
	{"cache-control", "private"},
	{":status", "302"},
}
RESPONSE_TABLE_2 := []Field {
	{":status", "307"},
	{"location", "https://www.example.com"},
	{"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
	{"cache-control", "private"},
}
RESPONSE_TABLE_3 := []Field {
	{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"},
	{"content-encoding", "gzip"},
	{"date", "Mon, 21 Oct 2013 20:13:22 GMT"},
}

C3 := []Step {
	{"828684410f7777772e6578616d706c652e636f6d", REQUEST_1, 57, REQUEST_TABLE_1},
	{"828684be58086e6f2d6361636865", REQUEST_2, 110, REQUEST_TABLE_2},
	{"828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565", REQUEST_3, 164, REQUEST_TABLE_3},
}
C4 := []Step {
	{"828684418cf1e3c2e5f23a6ba0ab90f4ff", REQUEST_1, 57, REQUEST_TABLE_1},
	{"828684be5886a8eb10649cbf", REQUEST_2, 110, REQUEST_TABLE_2},
	{"828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf", REQUEST_3, 164, REQUEST_TABLE_3},
}
C5 := []Step {
	{
		"4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d",
		RESPONSE_1,
		222,
		RESPONSE_TABLE_1,
	},
	{"4803333037c1c0bf", RESPONSE_2, 222, RESPONSE_TABLE_2},
	{
		"88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31",
		RESPONSE_3,
		215,
		RESPONSE_TABLE_3,
	},
}
C6 := []Step {
	{
		"488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3",
		RESPONSE_1,
		222,
		RESPONSE_TABLE_1,
	},
	{"4883640effc1c0bf", RESPONSE_2, 222, RESPONSE_TABLE_2},
	{
		"88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007",
		RESPONSE_3,
		215,
		RESPONSE_TABLE_3,
	},
}

run_decode_steps :: proc(t: ^testing.T, steps: []Step, table_size: int, loc := #caller_location) {
	d: hpack.Decoder
	testing.expect_value(t, hpack.decoder_init(&d, table_size), hpack.Error.None, loc)
	defer hpack.decoder_destroy(&d)
	for s in steps {
		got, err := decode(&d, unhex(s.block))
		testing.expect_value(t, err, hpack.Error.None, loc)
		expect_fields(t, got, s.fields, loc)
		expect_table(t, &d.table, s.size, s.table, loc)
	}
}

run_encode_steps :: proc(t: ^testing.T, steps: []Step, table_size: int, huffman: bool, loc := #caller_location) {
	e: hpack.Encoder
	testing.expect_value(t, hpack.encoder_init(&e, table_size), hpack.Error.None, loc)
	defer hpack.encoder_destroy(&e)
	e.use_huffman = huffman
	for s in steps {
		got := encode(&e, s.fields)
		testing.expect_value(t, string(got), string(unhex(s.block)), loc)
		expect_table(t, &e.table, s.size, s.table, loc)
	}
}

@(test)
test_c3_requests_raw :: proc(t: ^testing.T) {
	run_decode_steps(t, C3, 4096)
	run_encode_steps(t, C3, 4096, false)
}

@(test)
test_c4_requests_huffman :: proc(t: ^testing.T) {
	run_decode_steps(t, C4, 4096)
	run_encode_steps(t, C4, 4096, true)
}

@(test)
test_c5_responses_raw_with_eviction :: proc(t: ^testing.T) {
	run_decode_steps(t, C5, 256)
	run_encode_steps(t, C5, 256, false)
}

@(test)
test_c6_responses_huffman_with_eviction :: proc(t: ^testing.T) {
	run_decode_steps(t, C6, 256)
	run_encode_steps(t, C6, 256, true)
}

// -----------------------------------------------------------------------------
// Dynamic table and error handling
// -----------------------------------------------------------------------------

@(test)
test_table_size_update :: proc(t: ^testing.T) {
	d: hpack.Decoder
	hpack.decoder_init(&d)
	defer hpack.decoder_destroy(&d)

	decode(&d, unhex("828684410f7777772e6578616d706c652e636f6d"))
	testing.expect_value(t, d.table.count, 1)

	// Size update to 0 empties the table, then back to 4096.
	got, err := decode(&d, {0x20, 0x3f, 0xe1, 0x1f, 0x82})
	testing.expect_value(t, err, hpack.Error.None)
	expect_fields(t, got, {{":method", "GET"}})
	testing.expect_value(t, d.table.count, 0)
	testing.expect_value(t, d.table.max_size, 4096)

	// Exceeding the advertised capacity is an error.
	_, err = decode(&d, {0x3f, 0xe2, 0x1f})
	testing.expect_value(t, err, hpack.Error.Invalid_Table_Size_Update)

	// Size update after a field is an error.
	_, err = decode(&d, {0x82, 0x20})
	testing.expect_value(t, err, hpack.Error.Invalid_Table_Size_Update)
}

@(test)
test_encoder_size_update_signalling :: proc(t: ^testing.T) {
	e: hpack.Encoder
	hpack.encoder_init(&e, 4096)
	defer hpack.encoder_destroy(&e)

	// Shrink then grow before the next block: both the minimum and the
	// final size must be signalled (RFC 7541 §4.2).
	hpack.encoder_set_peer_max_table_size(&e, 100)
	hpack.encoder_set_peer_max_table_size(&e, 8192) // capped at capacity
	want := []u8{0x3f, 0x45, 0x3f, 0xe1, 0x1f, 0x82}
	out := encode(&e, {{":method", "GET"}})
	testing.expect_value(t, string(out), string(want))

	// Nothing pending afterwards.
	out = encode(&e, {{":method", "GET"}})
	testing.expect_value(t, string(out), "\x82")

	// The decoder must accept what the encoder produced.
	d: hpack.Decoder
	hpack.decoder_init(&d)
	defer hpack.decoder_destroy(&d)
	got, err := decode(&d, want)
	testing.expect_value(t, err, hpack.Error.None)
	expect_fields(t, got, {{":method", "GET"}})
}

@(test)
test_entry_larger_than_table_clears_it :: proc(t: ^testing.T) {
	d: hpack.Decoder
	hpack.decoder_init(&d, 64)
	defer hpack.decoder_destroy(&d)

	// "a: b" fits (34 octets).
	_, err := decode(&d, {0x40, 0x01, 'a', 0x01, 'b'})
	testing.expect_value(t, err, hpack.Error.None)
	testing.expect_value(t, d.table.count, 1)

	// A 40-octet value (73 octets total) does not fit: table emptied.
	block := make([dynamic]u8, context.temp_allocator)
	append(&block, 0x40, 0x01, 'c', 40)
	for _ in 0 ..< 40 {
		append(&block, 'x')
	}
	got, err2 := decode(&d, block[:])
	testing.expect_value(t, err2, hpack.Error.None)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, len(got[0].value), 40)
	testing.expect_value(t, d.table.count, 0)
	testing.expect_value(t, d.table.size, 0)
}

@(test)
test_name_reference_to_evicted_entry :: proc(t: ^testing.T) {
	// The table fits exactly one entry. Inserting a literal whose name
	// refers to the current (soon evicted) entry must still use that name.
	d: hpack.Decoder
	hpack.decoder_init(&d, 50)
	defer hpack.decoder_destroy(&d)

	_, err := decode(&d, {0x40, 0x04, 'n', 'a', 'm', 'e', 0x02, 'v', '1'})
	testing.expect_value(t, err, hpack.Error.None)
	// 0x7e = incremental, name index 62 (the dynamic entry "name").
	got, err2 := decode(&d, {0x7e, 0x02, 'v', '2'})
	testing.expect_value(t, err2, hpack.Error.None)
	expect_fields(t, got, {{"name", "v2"}})
	expect_table(t, &d.table, 38, {{"name", "v2"}})
}

@(test)
test_compaction_preserves_entries :: proc(t: ^testing.T) {
	// Many insertions through a small table force repeated compaction of
	// the data buffer; encoder and decoder must stay in sync throughout.
	e: hpack.Encoder
	d: hpack.Decoder
	hpack.encoder_init(&e, 200)
	hpack.decoder_init(&d, 200)
	defer hpack.encoder_destroy(&e)
	defer hpack.decoder_destroy(&d)
	hpack.encoder_set_peer_max_table_size(&e, 200)

	r := rand.create(42)
	gen := rand.default_random_generator(&r)
	for i in 0 ..< 500 {
		name := strings.repeat("k", 1 + rand.int_max(20, gen), context.temp_allocator)
		value := strings.repeat("v", rand.int_max(60, gen), context.temp_allocator)
		fields := []Field{{name, value}, {"x-req", value}}
		block := encode(&e, fields)
		got, err := decode(&d, block)
		testing.expect_value(t, err, hpack.Error.None)
		expect_fields(t, got, fields)
		testing.expect_value(t, d.table.size, e.table.size)
		testing.expect_value(t, d.table.count, e.table.count)
		if i % 50 == 0 {
			free_all(context.temp_allocator)
		}
	}
}

@(test)
test_invalid_indices :: proc(t: ^testing.T) {
	d: hpack.Decoder
	hpack.decoder_init(&d)
	defer hpack.decoder_destroy(&d)

	_, err := decode(&d, {0x80}) // index 0
	testing.expect_value(t, err, hpack.Error.Invalid_Index)
	_, err = decode(&d, {0xbe}) // index 62, empty dynamic table
	testing.expect_value(t, err, hpack.Error.Invalid_Index)
	_, err = decode(&d, {0x7e, 0x00}) // literal with name index 62
	testing.expect_value(t, err, hpack.Error.Invalid_Index)
}

@(test)
test_truncated_literals :: proc(t: ^testing.T) {
	d: hpack.Decoder
	hpack.decoder_init(&d)
	defer hpack.decoder_destroy(&d)

	_, err := decode(&d, {0x40})
	testing.expect_value(t, err, hpack.Error.Truncated)
	_, err = decode(&d, {0x40, 0x05, 'a', 'b'})
	testing.expect_value(t, err, hpack.Error.Truncated)
	_, err = decode(&d, {0x04})
	testing.expect_value(t, err, hpack.Error.Truncated)
	testing.expect(t, hpack.is_fatal(.Truncated))
}

@(test)
test_header_list_limit_is_non_fatal :: proc(t: ^testing.T) {
	d: hpack.Decoder
	hpack.decoder_init(&d, 4096, 100)
	defer hpack.decoder_destroy(&d)

	// Two incremental literals of 50 and 70 octets: the limit (100) is
	// crossed by the second, but both must still enter the table.
	block := make([dynamic]u8, context.temp_allocator)
	append(&block, 0x40, 0x01, 'a', 17)
	for _ in 0 ..< 17 {append(&block, 'x')}
	append(&block, 0x40, 0x01, 'b', 37)
	for _ in 0 ..< 37 {append(&block, 'y')}
	got, err := decode(&d, block[:])
	testing.expect_value(t, err, hpack.Error.Header_List_Too_Large)
	testing.expect(t, !hpack.is_fatal(err))
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, d.table.count, 2)
}

@(test)
test_never_indexed_roundtrip :: proc(t: ^testing.T) {
	e: hpack.Encoder
	d: hpack.Decoder
	hpack.encoder_init(&e)
	hpack.decoder_init(&d)
	defer hpack.encoder_destroy(&e)
	defer hpack.decoder_destroy(&d)

	out := make([dynamic]u8, context.temp_allocator)
	hpack.encoder_begin_block(&e, &out)
	hpack.encode_field(&e, &out, "authorization", "Bearer secret", .Never)
	hpack.encode_field(&e, &out, "grpc-timeout", "100m", .Without)
	testing.expect_value(t, e.table.count, 0)

	c := new_collected()
	testing.expect_value(t, hpack.decode_block(&d, out[:], collect, &c), hpack.Error.None)
	expect_fields(t, c.fields[:], {{"authorization", "Bearer secret"}, {"grpc-timeout", "100m"}})
	testing.expect_value(t, c.sensitive[0], true)
	testing.expect_value(t, c.sensitive[1], false)
	testing.expect_value(t, d.table.count, 0)
}

@(test)
test_zero_capacity_table :: proc(t: ^testing.T) {
	e: hpack.Encoder
	d: hpack.Decoder
	hpack.encoder_init(&e, 0)
	hpack.decoder_init(&d, 0)
	defer hpack.encoder_destroy(&e)
	defer hpack.decoder_destroy(&d)
	fields := []Field{{"x-a", "1"}, {"x-a", "1"}}
	got, err := decode(&d, encode(&e, fields))
	testing.expect_value(t, err, hpack.Error.None)
	expect_fields(t, got, fields)
	testing.expect_value(t, d.table.count, 0)
}
