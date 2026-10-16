package hpack

// Header_Proc receives each decoded header field in order. The strings are
// only valid for the duration of the call; copy them to retain them.
// `sensitive` is set for fields sent as "never indexed" (RFC 7541 §6.2.3),
// which must keep that representation if re-encoded.
Header_Proc :: #type proc(user: rawptr, field: Header_Field, sensitive: bool)

// Decoder holds the decoding context of one HTTP/2 connection direction.
Decoder :: struct {
	table:                Dynamic_Table,
	// Limit on the uncompressed header list size (RFC 7540 §6.5.2
	// SETTINGS_MAX_HEADER_LIST_SIZE semantics); 0 disables the limit.
	max_header_list_size: int,
	name_buf:             [dynamic]u8,
	value_buf:            [dynamic]u8,
}

// decoder_init prepares a decoder. table_capacity must equal the
// SETTINGS_HEADER_TABLE_SIZE advertised to the peer; the peer may never use a
// larger dynamic table.
decoder_init :: proc(
	d: ^Decoder,
	table_capacity := DEFAULT_TABLE_SIZE,
	max_header_list_size := 0,
	allocator := context.allocator,
) -> Error {
	d^ = {}
	table_init(&d.table, table_capacity, allocator) or_return
	d.max_header_list_size = max_header_list_size
	d.name_buf = make([dynamic]u8, allocator)
	d.value_buf = make([dynamic]u8, allocator)
	return .None
}

decoder_destroy :: proc(d: ^Decoder) {
	table_destroy(&d.table)
	delete(d.name_buf)
	delete(d.value_buf)
	d^ = {}
}

// decode_block decodes one complete header block (the concatenated fragments
// of a HEADERS/PUSH_PROMISE frame and its CONTINUATION frames).
//
// On .Header_List_Too_Large the block was still fully decoded (keeping the
// dynamic table synchronised), but on_field stopped being called once the
// limit was crossed. Any other error is fatal for the connection.
decode_block :: proc(d: ^Decoder, block: []u8, on_field: Header_Proc, user: rawptr) -> Error {
	pos := 0
	seen_field := false
	emitter := Emitter{d = d, on_field = on_field, user = user}

	for pos < len(block) {
		b := block[pos]
		switch {
		case b & 0x80 != 0:
			// Indexed header field (§6.1).
			index := decode_integer(block, &pos, 7) or_return
			field := lookup(d, index) or_return
			emit(&emitter, field, false)
			seen_field = true

		case b & 0xc0 == 0x40:
			// Literal with incremental indexing (§6.2.1).
			field := read_literal(d, block, &pos, 6) or_return
			if table_aliases(&d.table, field.name) {
				// The referenced entry may be evicted by this very insertion.
				clear(&d.name_buf)
				push_bytes(&d.name_buf, field.name) or_return
				field.name = string(d.name_buf[:])
			}
			table_insert(&d.table, field.name, field.value)
			emit(&emitter, field, false)
			seen_field = true

		case b & 0xe0 == 0x20:
			// Dynamic table size update (§6.3); only allowed before the
			// first field of a block (§4.2).
			if seen_field {
				return .Invalid_Table_Size_Update
			}
			size := decode_integer(block, &pos, 5) or_return
			if size > d.table.capacity {
				return .Invalid_Table_Size_Update
			}
			table_set_max_size(&d.table, size)

		case:
			// Literal without indexing (0000xxxx, §6.2.2) or never indexed
			// (0001xxxx, §6.2.3).
			sensitive := b & 0xf0 == 0x10
			field := read_literal(d, block, &pos, 4) or_return
			emit(&emitter, field, sensitive)
			seen_field = true
		}
	}
	return .Header_List_Too_Large if emitter.too_large else .None
}

@(private = "file")
Emitter :: struct {
	d:         ^Decoder,
	on_field:  Header_Proc,
	user:      rawptr,
	list_size: int,
	too_large: bool,
}

// emit accounts for a field against the header list limit and delivers it
// unless the limit has been crossed.
@(private = "file")
emit :: proc(e: ^Emitter, f: Header_Field, sensitive: bool) {
	e.list_size += entry_size(f.name, f.value)
	if e.d.max_header_list_size > 0 && e.list_size > e.d.max_header_list_size {
		e.too_large = true
	}
	if !e.too_large {
		e.on_field(e.user, f, sensitive)
	}
}

@(private = "file")
lookup :: proc(d: ^Decoder, index: int) -> (Header_Field, Error) {
	if index >= 1 && index <= STATIC_TABLE_LEN {
		return STATIC_TABLE[index - 1], .None
	}
	if field, ok := table_get(&d.table, index - STATIC_TABLE_LEN); ok {
		return field, .None
	}
	return {}, .Invalid_Index
}

@(private = "file")
read_literal :: proc(d: ^Decoder, block: []u8, pos: ^int, prefix_bits: uint) -> (field: Header_Field, err: Error) {
	index := decode_integer(block, pos, prefix_bits) or_return
	if index == 0 {
		field.name = read_string(block, pos, &d.name_buf) or_return
	} else {
		indexed := lookup(d, index) or_return
		field.name = indexed.name
	}
	field.value = read_string(block, pos, &d.value_buf) or_return
	return field, .None
}

// read_string reads a string literal (§5.2). Raw literals alias `block`;
// Huffman literals are decoded into buf.
@(private = "file")
read_string :: proc(block: []u8, pos: ^int, buf: ^[dynamic]u8) -> (s: string, err: Error) {
	if pos^ >= len(block) {
		return "", .Truncated
	}
	huffman := block[pos^] & 0x80 != 0
	n := decode_integer(block, pos, 7) or_return
	if n > len(block) - pos^ {
		return "", .Truncated
	}
	raw := block[pos^:pos^ + n]
	pos^ += n
	if !huffman {
		return string(raw), .None
	}
	clear(buf)
	append_huffman_decoded(buf, raw) or_return
	return string(buf[:]), .None
}
