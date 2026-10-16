package hpack

// Encoder holds the encoding context of one HTTP/2 connection direction.
Encoder :: struct {
	table:          Dynamic_Table,
	// Dynamic table size updates owed to the peer at the start of the next
	// header block (RFC 7541 §4.2): the smallest size set since the last
	// block, then the current size if it differs.
	pending_update: bool,
	pending_min:    int,
	// When false, string literals are always sent raw.
	use_huffman:    bool,
}

// encoder_init prepares an encoder whose dynamic table never exceeds
// capacity octets. The table starts at min(capacity, DEFAULT_TABLE_SIZE),
// the size the peer allows until its SETTINGS say otherwise.
encoder_init :: proc(e: ^Encoder, capacity := DEFAULT_TABLE_SIZE, allocator := context.allocator) -> Error {
	e^ = {}
	table_init(&e.table, capacity, allocator) or_return
	table_set_max_size(&e.table, min(capacity, DEFAULT_TABLE_SIZE))
	e.use_huffman = true
	return .None
}

encoder_destroy :: proc(e: ^Encoder) {
	table_destroy(&e.table)
	e^ = {}
}

// encoder_set_peer_max_table_size applies the peer's
// SETTINGS_HEADER_TABLE_SIZE. The size actually used is capped by the
// encoder's own capacity; the change is announced in the next header block.
encoder_set_peer_max_table_size :: proc(e: ^Encoder, peer_max: int) {
	new_max := min(max(peer_max, 0), e.table.capacity)
	if new_max == e.table.max_size && !e.pending_update {
		return
	}
	if !e.pending_update {
		e.pending_update = true
		e.pending_min = new_max
	} else {
		e.pending_min = min(e.pending_min, new_max)
	}
	table_set_max_size(&e.table, new_max)
}

// encoder_begin_block must be called before the first field of each header
// block; it emits any pending dynamic table size updates.
encoder_begin_block :: proc(e: ^Encoder, dst: ^[dynamic]u8) -> Error {
	if !e.pending_update {
		return .None
	}
	if e.pending_min < e.table.max_size {
		append_integer(dst, e.pending_min, 5, 0x20) or_return
	}
	append_integer(dst, e.table.max_size, 5, 0x20) or_return
	e.pending_update = false
	return .None
}

// encode_field appends the representation of one header field to dst.
// Names must already be lowercase, as HTTP/2 requires.
encode_field :: proc(e: ^Encoder, dst: ^[dynamic]u8, name, value: string, indexing := Indexing.Incremental) -> Error {
	full, name_index := find(e, name, value)
	if full > 0 && indexing != .Never {
		return append_integer(dst, full, 7, 0x80)
	}

	prefix_bits: uint
	flags: u8
	switch indexing {
	case .Incremental:
		prefix_bits, flags = 6, 0x40
	case .Without:
		prefix_bits, flags = 4, 0x00
	case .Never:
		prefix_bits, flags = 4, 0x10
	}
	append_integer(dst, name_index, prefix_bits, flags) or_return
	if name_index == 0 {
		append_string(e, dst, name) or_return
	}
	append_string(e, dst, value) or_return

	if indexing == .Incremental {
		table_insert(&e.table, name, value)
	}
	return .None
}

// find returns the index of an exact (name, value) match, or 0, and the
// index of the best name-only match, or 0. Static entries are preferred.
@(private = "file")
find :: proc(e: ^Encoder, name, value: string) -> (full: int, name_only: int) {
	for f, i in STATIC_TABLE {
		if f.name != name {
			continue
		}
		if f.value == value {
			return i + 1, i + 1
		}
		if name_only == 0 {
			name_only = i + 1
		}
	}
	for i in 1 ..= e.table.count {
		f, _ := table_get(&e.table, i)
		if f.name != name {
			continue
		}
		if f.value == value {
			return STATIC_TABLE_LEN + i, name_only if name_only != 0 else STATIC_TABLE_LEN + i
		}
		if name_only == 0 {
			name_only = STATIC_TABLE_LEN + i
		}
	}
	return 0, name_only
}

@(private = "file")
append_string :: proc(e: ^Encoder, dst: ^[dynamic]u8, s: string) -> Error {
	if e.use_huffman {
		// Ties go to Huffman, matching the reference encoder in RFC 7541
		// Appendix C so its vectors are reproduced byte for byte.
		if n := huffman_encoded_len(s); n <= len(s) && len(s) > 0 {
			append_integer(dst, n, 7, 0x80) or_return
			return append_huffman(dst, s)
		}
	}
	append_integer(dst, len(s), 7, 0x00) or_return
	return push_bytes(dst, s)
}
