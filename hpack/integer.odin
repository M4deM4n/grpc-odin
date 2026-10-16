package hpack

// integer_encoded_len returns the number of octets needed to encode value
// with an N-bit prefix (RFC 7541 §5.1).
integer_encoded_len :: proc "contextless" (value: int, prefix_bits: uint) -> int {
	assert_contextless(prefix_bits >= 1 && prefix_bits <= 8 && value >= 0)
	max_prefix := (1 << prefix_bits) - 1
	if value < max_prefix {
		return 1
	}
	n := 1
	v := value - max_prefix
	for v >= 0x80 {
		v >>= 7
		n += 1
	}
	return n + 1
}

// append_integer appends value encoded with an N-bit prefix. The high bits of
// the first octet (above the prefix) are taken from `flags`.
append_integer :: proc(dst: ^[dynamic]u8, value: int, prefix_bits: uint, flags: u8) -> Error {
	assert(prefix_bits >= 1 && prefix_bits <= 8 && value >= 0)
	max_prefix := (1 << prefix_bits) - 1
	if value < max_prefix {
		return push(dst, flags | u8(value))
	}
	push(dst, flags | u8(max_prefix)) or_return
	v := value - max_prefix
	for v >= 0x80 {
		push(dst, u8(v & 0x7f) | 0x80) or_return
		v >>= 7
	}
	return push(dst, u8(v))
}

// decode_integer decodes an N-bit prefix integer starting at src[pos^] and
// advances pos past it. The flag bits above the prefix are ignored.
decode_integer :: proc "contextless" (src: []u8, pos: ^int, prefix_bits: uint) -> (value: int, err: Error) {
	if pos^ >= len(src) {
		return 0, .Truncated
	}
	max_prefix := (1 << prefix_bits) - 1
	value = int(src[pos^]) & max_prefix
	pos^ += 1
	if value < max_prefix {
		return value, .None
	}
	shift: uint = 0
	for {
		if pos^ >= len(src) {
			return 0, .Truncated
		}
		b := src[pos^]
		pos^ += 1
		// 5 continuation octets carry 35 bits, more than MAX_INTEGER needs;
		// anything longer is either overflow or padding abuse.
		if shift > 28 {
			return 0, .Integer_Overflow
		}
		value += int(b & 0x7f) << shift
		if value > MAX_INTEGER {
			return 0, .Integer_Overflow
		}
		if b & 0x80 == 0 {
			return value, .None
		}
		shift += 7
	}
}

@(private)
push :: #force_inline proc(dst: ^[dynamic]u8, b: u8) -> Error {
	if _, err := append(dst, b); err != nil {
		return .Out_Of_Memory
	}
	return .None
}

@(private)
push_bytes :: #force_inline proc(dst: ^[dynamic]u8, s: string) -> Error {
	if _, err := append(dst, s); err != nil {
		return .Out_Of_Memory
	}
	return .None
}
