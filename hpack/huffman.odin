package hpack

// huffman_encoded_len returns the number of octets s occupies when Huffman
// coded, including padding.
huffman_encoded_len :: proc "contextless" (s: string) -> int {
	bits := 0
	for i in 0 ..< len(s) {
		bits += int(HUFFMAN_CODES[s[i]].len)
	}
	return (bits + 7) >> 3
}

// append_huffman appends the Huffman coding of s (RFC 7541 §5.2), padded
// with the most significant bits of EOS.
append_huffman :: proc(dst: ^[dynamic]u8, s: string) -> Error {
	n := huffman_encoded_len(s)
	start := len(dst)
	if err := resize(dst, start + n); err != nil {
		return .Out_Of_Memory
	}
	out := dst[start:]
	acc: u64 = 0
	bits: uint = 0
	o := 0
	for i in 0 ..< len(s) {
		c := HUFFMAN_CODES[s[i]]
		acc = (acc << c.len) | u64(c.code)
		bits += uint(c.len)
		for bits >= 8 {
			bits -= 8
			out[o] = u8(acc >> bits)
			o += 1
		}
		acc &= (u64(1) << bits) - 1
	}
	if bits > 0 {
		out[o] = u8(acc << (8 - bits)) | u8(0xff >> bits)
		o += 1
	}
	assert(o == n)
	return .None
}

// huffman_decoded_max_len bounds the decoded length of an n-octet Huffman
// string: the shortest code is 5 bits.
huffman_decoded_max_len :: proc "contextless" (n: int) -> int {
	return (n * 8) / 5
}

// append_huffman_decoded decodes the Huffman string src and appends the
// result to dst.
append_huffman_decoded :: proc(dst: ^[dynamic]u8, src: []u8) -> Error {
	start := len(dst)
	if err := resize(dst, start + huffman_decoded_max_len(len(src))); err != nil {
		return .Out_Of_Memory
	}
	n, err := huffman_decode(dst[start:], src)
	resize(dst, start + n)
	return err
}

// huffman_decode decodes the Huffman string src into dst, which must hold at
// least huffman_decoded_max_len(len(src)) octets, and returns the number of
// octets written.
//
// The code is canonical, so a symbol is found by comparing the next 32 input
// bits (left-justified) against the per-length exclusive upper bounds in
// HUFFMAN_LIMIT; the shortest length whose bound exceeds the bits is the code
// length.
huffman_decode :: proc "contextless" (dst: []u8, src: []u8) -> (n: int, err: Error) {
	if len(dst) < huffman_decoded_max_len(len(src)) {
		return 0, .Buffer_Too_Small
	}
	acc: u64 = 0 // the low `bits` bits are unconsumed input
	bits: uint = 0
	i := 0
	for {
		for bits <= 56 && i < len(src) {
			acc = (acc << 8) | u64(src[i])
			bits += 8
			i += 1
		}
		if bits == 0 {
			break
		}
		// Peek 32 bits, padding past the end of input with 1s (the EOS
		// prefix) so that trailing padding never matches a short code.
		w: u32
		if bits >= 32 {
			w = u32(acc >> (bits - 32))
		} else {
			w = u32(acc << (32 - bits)) | u32((u64(1) << (32 - bits)) - 1)
		}
		l: uint = 5
		for l < HUFFMAN_MAX_CODE_LEN && u64(w) >= HUFFMAN_LIMIT[l] {
			l += 1
		}
		if l > bits {
			// Only padding remains: at most 7 bits, all ones (§5.2).
			if bits > 7 || acc != (u64(1) << bits) - 1 {
				return n, .Invalid_Huffman
			}
			break
		}
		index := u32(HUFFMAN_OFFSET[l]) + (w >> (32 - l)) - HUFFMAN_FIRST_CODE[l]
		sym := HUFFMAN_SORTED_SYMBOLS[index]
		if sym == HUFFMAN_EOS {
			return n, .Invalid_Huffman
		}
		dst[n] = u8(sym)
		n += 1
		bits -= l
		acc &= (u64(1) << bits) - 1
	}
	return n, .None
}
