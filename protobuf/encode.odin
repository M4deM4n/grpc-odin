package protobuf

import "base:intrinsics"

// Encoder writes a message back to front into a fixed buffer. Errors are
// sticky: once a write does not fit, every later write is ignored and `err`
// is set, so generated code needs no per-field error checks.
Encoder :: struct {
	buf: []u8,
	pos: int, // start of the encoded suffix buf[pos:]
	err: Error,
}

encoder_make :: proc "contextless" (buf: []u8) -> Encoder {
	return {buf = buf, pos = len(buf)}
}

// encoded returns the bytes written so far.
encoded :: proc "contextless" (e: ^Encoder) -> []u8 {
	return e.buf[e.pos:]
}

// -----------------------------------------------------------------------------
// Sizes
// -----------------------------------------------------------------------------

varint_size :: #force_inline proc "contextless" (v: u64) -> int {
	// Each octet carries 7 bits; a zero value still needs one octet.
	bits := 64 - int(intrinsics.count_leading_zeros(v | 1))
	return (bits + 6) / 7
}

tag_size :: #force_inline proc "contextless" (field: u32) -> int {
	return varint_size(u64(field) << 3)
}

zigzag32 :: #force_inline proc "contextless" (v: i32) -> u32 {
	return (u32(v) << 1) ~ u32(v >> 31)
}

zigzag64 :: #force_inline proc "contextless" (v: i64) -> u64 {
	return (u64(v) << 1) ~ u64(v >> 63)
}

// Negative int32 values are sign-extended to 64 bits on the wire.
size_int32 :: #force_inline proc "contextless" (v: i32) -> int {return varint_size(u64(i64(v)))}
size_int64 :: #force_inline proc "contextless" (v: i64) -> int {return varint_size(u64(v))}
size_uint32 :: #force_inline proc "contextless" (v: u32) -> int {return varint_size(u64(v))}
size_uint64 :: #force_inline proc "contextless" (v: u64) -> int {return varint_size(v)}
size_sint32 :: #force_inline proc "contextless" (v: i32) -> int {return varint_size(u64(zigzag32(v)))}
size_sint64 :: #force_inline proc "contextless" (v: i64) -> int {return varint_size(zigzag64(v))}
size_bool :: #force_inline proc "contextless" (v: bool) -> int {return 1}
size_enum :: #force_inline proc "contextless" (v: $E) -> int where intrinsics.type_is_enum(E) {
	return size_int32(i32(v))
}
// size_len returns the size of a length-delimited payload of n octets,
// including its length prefix (but not its tag).
size_len :: #force_inline proc "contextless" (n: int) -> int {return varint_size(u64(n)) + n}

// size_packed returns the payload size of a packed repeated varint field.
size_packed_int32 :: proc "contextless" (vs: []i32) -> (n: int) {for v in vs {n += size_int32(v)};return}
size_packed_int64 :: proc "contextless" (vs: []i64) -> (n: int) {for v in vs {n += size_int64(v)};return}
size_packed_uint32 :: proc "contextless" (vs: []u32) -> (n: int) {for v in vs {n += size_uint32(v)};return}
size_packed_uint64 :: proc "contextless" (vs: []u64) -> (n: int) {for v in vs {n += size_uint64(v)};return}
size_packed_sint32 :: proc "contextless" (vs: []i32) -> (n: int) {for v in vs {n += size_sint32(v)};return}
size_packed_sint64 :: proc "contextless" (vs: []i64) -> (n: int) {for v in vs {n += size_sint64(v)};return}
size_packed_enum :: proc "contextless" (vs: []$E) -> (n: int) where intrinsics.type_is_enum(E) {
	for v in vs {n += size_int32(i32(v))}
	return
}

// -----------------------------------------------------------------------------
// Primitive writes (back to front)
// -----------------------------------------------------------------------------

// claim claims n octets in front of the current suffix.
@(private)
claim :: #force_inline proc "contextless" (e: ^Encoder, n: int) -> (dst: []u8, ok: bool) {
	if e.err != .None || n > e.pos {
		e.err = .Buffer_Too_Small
		return nil, false
	}
	e.pos -= n
	return e.buf[e.pos:e.pos + n], true
}

write_varint :: proc "contextless" (e: ^Encoder, v: u64) {
	n := varint_size(v)
	dst, ok := claim(e, n)
	if !ok {return}
	v := v
	for i in 0 ..< n - 1 {
		dst[i] = u8(v) | 0x80
		v >>= 7
	}
	dst[n - 1] = u8(v)
}

write_tag :: #force_inline proc "contextless" (e: ^Encoder, field: u32, wire: Wire_Type) {
	write_varint(e, u64(field) << 3 | u64(wire))
}

write_fixed32 :: proc "contextless" (e: ^Encoder, v: u32) {
	dst, ok := claim(e, 4)
	if !ok {return}
	intrinsics.unaligned_store((^u32le)(raw_data(dst)), u32le(v))
}

write_fixed64 :: proc "contextless" (e: ^Encoder, v: u64) {
	dst, ok := claim(e, 8)
	if !ok {return}
	intrinsics.unaligned_store((^u64le)(raw_data(dst)), u64le(v))
}

write_raw :: proc "contextless" (e: ^Encoder, b: []u8) {
	dst, ok := claim(e, len(b))
	if !ok {return}
	copy(dst, b)
}

// -----------------------------------------------------------------------------
// Field writes: value first, then tag (the output reads tag, value).
// Generated code checks presence; these write unconditionally.
// -----------------------------------------------------------------------------

put_int32 :: proc "contextless" (e: ^Encoder, field: u32, v: i32) {
	write_varint(e, u64(i64(v)))
	write_tag(e, field, .Varint)
}
put_int64 :: proc "contextless" (e: ^Encoder, field: u32, v: i64) {
	write_varint(e, u64(v))
	write_tag(e, field, .Varint)
}
put_uint32 :: proc "contextless" (e: ^Encoder, field: u32, v: u32) {
	write_varint(e, u64(v))
	write_tag(e, field, .Varint)
}
put_uint64 :: proc "contextless" (e: ^Encoder, field: u32, v: u64) {
	write_varint(e, v)
	write_tag(e, field, .Varint)
}
put_sint32 :: proc "contextless" (e: ^Encoder, field: u32, v: i32) {
	write_varint(e, u64(zigzag32(v)))
	write_tag(e, field, .Varint)
}
put_sint64 :: proc "contextless" (e: ^Encoder, field: u32, v: i64) {
	write_varint(e, zigzag64(v))
	write_tag(e, field, .Varint)
}
put_bool :: proc "contextless" (e: ^Encoder, field: u32, v: bool) {
	write_varint(e, 1 if v else 0)
	write_tag(e, field, .Varint)
}
put_enum :: proc "contextless" (e: ^Encoder, field: u32, v: $E) where intrinsics.type_is_enum(E) {
	put_int32(e, field, i32(v))
}
put_fixed32 :: proc "contextless" (e: ^Encoder, field: u32, v: u32) {
	write_fixed32(e, v)
	write_tag(e, field, .I32)
}
put_fixed64 :: proc "contextless" (e: ^Encoder, field: u32, v: u64) {
	write_fixed64(e, v)
	write_tag(e, field, .I64)
}
put_sfixed32 :: proc "contextless" (e: ^Encoder, field: u32, v: i32) {put_fixed32(e, field, u32(v))}
put_sfixed64 :: proc "contextless" (e: ^Encoder, field: u32, v: i64) {put_fixed64(e, field, u64(v))}
put_float :: proc "contextless" (e: ^Encoder, field: u32, v: f32) {put_fixed32(e, field, transmute(u32)v)}
put_double :: proc "contextless" (e: ^Encoder, field: u32, v: f64) {put_fixed64(e, field, transmute(u64)v)}

put_bytes :: proc "contextless" (e: ^Encoder, field: u32, v: []u8) {
	write_raw(e, v)
	write_varint(e, u64(len(v)))
	write_tag(e, field, .Len)
}
put_string :: proc "contextless" (e: ^Encoder, field: u32, v: string) {
	put_bytes(e, field, transmute([]u8)v)
}

// begin_len / end_len bracket a length-delimited payload (sub-message,
// packed field or map entry) written back to front:
//
//     mark := begin_len(e)
//     ...write payload...
//     end_len(e, field, mark)
begin_len :: #force_inline proc "contextless" (e: ^Encoder) -> int {
	return e.pos
}
end_len :: #force_inline proc "contextless" (e: ^Encoder, field: u32, mark: int) {
	write_varint(e, u64(mark - e.pos))
	write_tag(e, field, .Len)
}

// Packed repeated fields. Elements are written in reverse so they read in order.
put_packed_int32 :: proc "contextless" (e: ^Encoder, field: u32, vs: []i32) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, u64(i64(v)))}
	end_len(e, field, mark)
}
put_packed_int64 :: proc "contextless" (e: ^Encoder, field: u32, vs: []i64) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, u64(v))}
	end_len(e, field, mark)
}
put_packed_uint32 :: proc "contextless" (e: ^Encoder, field: u32, vs: []u32) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, u64(v))}
	end_len(e, field, mark)
}
put_packed_uint64 :: proc "contextless" (e: ^Encoder, field: u32, vs: []u64) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, v)}
	end_len(e, field, mark)
}
put_packed_sint32 :: proc "contextless" (e: ^Encoder, field: u32, vs: []i32) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, u64(zigzag32(v)))}
	end_len(e, field, mark)
}
put_packed_sint64 :: proc "contextless" (e: ^Encoder, field: u32, vs: []i64) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, zigzag64(v))}
	end_len(e, field, mark)
}
put_packed_bool :: proc "contextless" (e: ^Encoder, field: u32, vs: []bool) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, 1 if v else 0)}
	end_len(e, field, mark)
}
put_packed_enum :: proc "contextless" (e: ^Encoder, field: u32, vs: []$E) where intrinsics.type_is_enum(E) {
	mark := begin_len(e)
	#reverse for v in vs {write_varint(e, u64(i64(i32(v))))}
	end_len(e, field, mark)
}
put_packed_fixed32 :: proc "contextless" (e: ^Encoder, field: u32, vs: []$T) where size_of(T) == 4 {
	mark := begin_len(e)
	#reverse for v in vs {write_fixed32(e, transmute(u32)v)}
	end_len(e, field, mark)
}
put_packed_fixed64 :: proc "contextless" (e: ^Encoder, field: u32, vs: []$T) where size_of(T) == 8 {
	mark := begin_len(e)
	#reverse for v in vs {write_fixed64(e, transmute(u64)v)}
	end_len(e, field, mark)
}
