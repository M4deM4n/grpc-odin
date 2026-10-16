package protobuf

import "base:intrinsics"
import "base:runtime"
import "core:unicode/utf8"

// Decoder reads a message from data[pos:end]. Sub-messages are decoded by
// narrowing `end` (see enter_len / leave_len) rather than creating new
// decoders, so the allocator and options flow through unchanged.
Decoder :: struct {
	data:            []u8,
	pos:             int,
	end:             int,
	allocator:       runtime.Allocator,
	alias_input:     bool,
	discard_unknown: bool,
	depth:           int,
	max_depth:       int,
}

decoder_make :: proc(data: []u8, allocator := context.allocator, options := Decode_Options{}) -> Decoder {
	return {
		data = data,
		end = len(data),
		allocator = allocator,
		alias_input = options.alias_input,
		discard_unknown = options.discard_unknown,
		max_depth = options.max_depth if options.max_depth > 0 else DEFAULT_MAX_DEPTH,
	}
}

// more reports whether the current message has unread fields.
more :: #force_inline proc "contextless" (d: ^Decoder) -> bool {
	return d.pos < d.end
}

// -----------------------------------------------------------------------------
// Primitive reads
// -----------------------------------------------------------------------------

read_varint :: proc "contextless" (d: ^Decoder) -> (v: u64, err: Error) {
	// Fast path: single-octet varints dominate real traffic.
	if d.pos < d.end && d.data[d.pos] < 0x80 {
		v = u64(d.data[d.pos])
		d.pos += 1
		return v, .None
	}
	shift: uint = 0
	for i in 0 ..< MAX_VARINT_LEN {
		if d.pos >= d.end {
			return 0, .Truncated
		}
		b := d.data[d.pos]
		d.pos += 1
		// The 10th octet may only contribute the single remaining bit.
		if i == MAX_VARINT_LEN - 1 && b > 1 {
			return 0, .Malformed_Varint
		}
		v |= u64(b & 0x7f) << shift
		if b < 0x80 {
			return v, .None
		}
		shift += 7
	}
	return 0, .Malformed_Varint
}

read_fixed32 :: proc "contextless" (d: ^Decoder) -> (v: u32, err: Error) {
	if d.end - d.pos < 4 {
		return 0, .Truncated
	}
	v = u32(intrinsics.unaligned_load((^u32le)(&d.data[d.pos])))
	d.pos += 4
	return v, .None
}

read_fixed64 :: proc "contextless" (d: ^Decoder) -> (v: u64, err: Error) {
	if d.end - d.pos < 8 {
		return 0, .Truncated
	}
	v = u64(intrinsics.unaligned_load((^u64le)(&d.data[d.pos])))
	d.pos += 8
	return v, .None
}

// read_tag reads a field tag, validating the field number and wire type.
read_tag :: proc "contextless" (d: ^Decoder) -> (field: u32, wire: Wire_Type, err: Error) {
	v := read_varint(d) or_return
	w := v & 7
	f := v >> 3
	if f < MIN_FIELD_NUMBER || f > MAX_FIELD_NUMBER || w > 5 {
		return 0, .Varint, .Invalid_Tag
	}
	return u32(f), Wire_Type(w), .None
}

// read_len_raw reads a length prefix and returns the payload, aliasing input.
read_len_raw :: proc "contextless" (d: ^Decoder) -> (payload: []u8, err: Error) {
	n := read_varint(d) or_return
	if n > u64(d.end - d.pos) {
		return nil, .Invalid_Length
	}
	payload = d.data[d.pos:d.pos + int(n)]
	d.pos += int(n)
	return payload, .None
}

// enter_len narrows the decoder to a length-delimited payload (sub-message,
// packed field or map entry). The returned mark restores the outer bound.
enter_len :: proc "contextless" (d: ^Decoder) -> (mark: int, err: Error) {
	n := read_varint(d) or_return
	if n > u64(d.end - d.pos) {
		return 0, .Invalid_Length
	}
	mark = d.end
	d.end = d.pos + int(n)
	return mark, .None
}

leave_len :: #force_inline proc "contextless" (d: ^Decoder, mark: int) {
	d.end = mark
}

// enter_message is enter_len plus nesting depth accounting.
enter_message :: proc "contextless" (d: ^Decoder) -> (mark: int, err: Error) {
	if d.depth >= d.max_depth {
		return 0, .Depth_Limit_Exceeded
	}
	mark = enter_len(d) or_return
	d.depth += 1
	return mark, .None
}

// leave_message restores the outer bound. The sub-message decoder must have
// consumed its payload exactly.
leave_message :: proc "contextless" (d: ^Decoder, mark: int) -> Error {
	if d.pos != d.end {
		return .Invalid_Length
	}
	d.depth -= 1
	d.end = mark
	return .None
}

// -----------------------------------------------------------------------------
// Typed value reads
// -----------------------------------------------------------------------------

// Varint integers are truncated to their declared width, as the
// specification requires for interoperability.
read_int32 :: proc "contextless" (d: ^Decoder) -> (i32, Error) {v, err := read_varint(d);return i32(v), err}
read_int64 :: proc "contextless" (d: ^Decoder) -> (i64, Error) {v, err := read_varint(d);return i64(v), err}
read_uint32 :: proc "contextless" (d: ^Decoder) -> (u32, Error) {v, err := read_varint(d);return u32(v), err}
read_uint64 :: proc "contextless" (d: ^Decoder) -> (u64, Error) {return read_varint(d)}
read_sint32 :: proc "contextless" (d: ^Decoder) -> (i32, Error) {
	v, err := read_varint(d)
	u := u32(v)
	return i32(u >> 1) ~ -i32(u & 1), err
}
read_sint64 :: proc "contextless" (d: ^Decoder) -> (i64, Error) {
	v, err := read_varint(d)
	return i64(v >> 1) ~ -i64(v & 1), err
}
read_bool :: proc "contextless" (d: ^Decoder) -> (bool, Error) {v, err := read_varint(d);return v != 0, err}
read_enum :: proc "contextless" (d: ^Decoder, $E: typeid) -> (E, Error) where intrinsics.type_is_enum(E) {
	v, err := read_varint(d)
	return E(i32(v)), err
}
read_sfixed32 :: proc "contextless" (d: ^Decoder) -> (i32, Error) {v, err := read_fixed32(d);return i32(v), err}
read_sfixed64 :: proc "contextless" (d: ^Decoder) -> (i64, Error) {v, err := read_fixed64(d);return i64(v), err}
read_float :: proc "contextless" (d: ^Decoder) -> (f32, Error) {v, err := read_fixed32(d);return transmute(f32)v, err}
read_double :: proc "contextless" (d: ^Decoder) -> (f64, Error) {v, err := read_fixed64(d);return transmute(f64)v, err}

// read_bytes reads a bytes field, copying it unless aliasing is enabled.
read_bytes :: proc(d: ^Decoder) -> (v: []u8, err: Error) {
	raw := read_len_raw(d) or_return
	if d.alias_input || len(raw) == 0 {
		return raw if len(raw) > 0 else nil, .None
	}
	out, alloc_err := make([]u8, len(raw), d.allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	copy(out, raw)
	return out, .None
}

// read_string reads a proto3 string field, which must be valid UTF-8.
read_string :: proc(d: ^Decoder) -> (v: string, err: Error) {
	start := d.pos
	raw := read_len_raw(d) or_return
	if !utf8.valid_string(string(raw)) {
		d.pos = start
		return "", .Invalid_UTF8
	}
	b := read_bytes_from_raw(d, raw) or_return
	return string(b), .None
}

// read_string_unchecked reads a proto2 string field (no UTF-8 validation).
read_string_unchecked :: proc(d: ^Decoder) -> (v: string, err: Error) {
	raw := read_len_raw(d) or_return
	b := read_bytes_from_raw(d, raw) or_return
	return string(b), .None
}

@(private)
read_bytes_from_raw :: proc(d: ^Decoder, raw: []u8) -> ([]u8, Error) {
	if d.alias_input || len(raw) == 0 {
		return raw if len(raw) > 0 else nil, .None
	}
	out, alloc_err := make([]u8, len(raw), d.allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	copy(out, raw)
	return out, .None
}

// -----------------------------------------------------------------------------
// Unknown fields
// -----------------------------------------------------------------------------

// skip_value skips the value of a field whose tag was just read, including
// nested groups.
skip_value :: proc "contextless" (d: ^Decoder, field: u32, wire: Wire_Type) -> Error {
	switch wire {
	case .Varint:
		_ = read_varint(d) or_return
	case .I64:
		if d.end - d.pos < 8 {return .Truncated}
		d.pos += 8
	case .I32:
		if d.end - d.pos < 4 {return .Truncated}
		d.pos += 4
	case .Len:
		_ = read_len_raw(d) or_return
	case .Start_Group:
		if d.depth >= d.max_depth {
			return .Depth_Limit_Exceeded
		}
		d.depth += 1
		for {
			if d.pos >= d.end {
				return .Invalid_Group
			}
			f, w := read_tag(d) or_return
			if w == .End_Group {
				if f != field {
					return .Invalid_Group
				}
				break
			}
			skip_value(d, f, w) or_return
		}
		d.depth -= 1
	case .End_Group:
		return .Invalid_Group
	}
	return .None
}

// skip_unknown skips a field that the message does not declare (or whose
// wire type does not match its declaration) and, unless discarding,
// appends its raw encoding (tag included) to `unknown`.
//
// tag_start is the decoder position before the tag was read.
skip_unknown :: proc(d: ^Decoder, tag_start: int, field: u32, wire: Wire_Type, unknown: ^[dynamic]u8) -> Error {
	skip_value(d, field, wire) or_return
	return store_unknown(d, tag_start, unknown)
}

// store_unknown appends the raw field d.data[tag_start:d.pos] (already
// consumed) to `unknown`. Used for skipped fields and for proto2 closed enum
// values outside the enum's range.
store_unknown :: proc(d: ^Decoder, tag_start: int, unknown: ^[dynamic]u8) -> Error {
	if d.discard_unknown {
		return .None
	}
	return append_bytes(d, unknown, d.data[tag_start:d.pos])
}

// store_unknown_varint appends `field: v` as an unknown varint field. Used
// for unrecognized closed-enum values found inside packed runs.
store_unknown_varint :: proc(d: ^Decoder, field: u32, v: u64, unknown: ^[dynamic]u8) -> Error {
	if d.discard_unknown {
		return .None
	}
	buf: [2 * MAX_VARINT_LEN]u8
	n := put_varint_forward(buf[:], u64(field) << 3)
	n += put_varint_forward(buf[n:], v)
	return append_bytes(d, unknown, buf[:n])
}

@(private)
put_varint_forward :: proc "contextless" (dst: []u8, v: u64) -> int {
	v := v
	i := 0
	for v >= 0x80 {
		dst[i] = u8(v) | 0x80
		v >>= 7
		i += 1
	}
	dst[i] = u8(v)
	return i + 1
}

@(private)
append_bytes :: proc(d: ^Decoder, dst: ^[dynamic]u8, b: []u8) -> Error {
	ensure_allocator(d, dst)
	if _, err := append(dst, ..b); err != nil {
		return .Out_Of_Memory
	}
	return .None
}

// ensure_allocator makes an unallocated dynamic array use the decoder's
// allocator. Arrays that already have an allocator keep it, so memory is
// always grown and freed by its owner.
@(private)
ensure_allocator :: #force_inline proc(d: ^Decoder, a: ^[dynamic]$T) {
	raw := (^runtime.Raw_Dynamic_Array)(a)
	if raw.allocator.procedure == nil {
		raw.allocator = d.allocator
	}
}

// -----------------------------------------------------------------------------
// Replaced values
// -----------------------------------------------------------------------------

// free_bytes releases a string/bytes value that decoding is about to
// replace. Nothing is freed when aliasing the input. Messages decoded into
// must therefore be zero or own their memory with the decoder's allocator.
free_bytes :: #force_inline proc(d: ^Decoder, b: []u8) {
	if !d.alias_input && len(b) > 0 {
		delete(b, d.allocator)
	}
}

free_string :: #force_inline proc(d: ^Decoder, s: string) {
	if !d.alias_input && len(s) > 0 {
		delete(s, d.allocator)
	}
}

// -----------------------------------------------------------------------------
// Repeated fields
// -----------------------------------------------------------------------------

// Count_Kind describes how a repeated field appears on the wire, for the
// pre-count pass that sizes repeated slices exactly.
Count_Kind :: enum u8 {
	Varint, // packable varint scalars and enums
	Fixed32, // packable 4-octet scalars
	Fixed64, // packable 8-octet scalars
	Len, // strings, bytes and messages (never packed)
}

Count_Spec :: struct {
	field: u32,
	kind:  Count_Kind,
}

// count_repeated scans the remaining fields of the current message and
// counts the elements of each repeated field in `specs`, using the same
// wire-type acceptance rules as the generated decoders. The decoder position
// is left unchanged. Maps are not counted: duplicate keys would make the
// count an overestimate that hostile input could inflate.
count_repeated :: proc "contextless" (d: ^Decoder, specs: []Count_Spec, counts: []int) -> Error {
	saved := d.pos
	defer d.pos = saved
	for d.pos < d.end {
		field, wire := read_tag(d) or_return
		value_start := d.pos
		skip_value(d, field, wire) or_return
		for spec, i in specs {
			if spec.field != field {
				continue
			}
			switch spec.kind {
			case .Varint:
				if wire == .Varint {
					counts[i] += 1
				} else if wire == .Len {
					payload := len_payload(d, value_start)
					for b in payload {
						if b < 0x80 {counts[i] += 1}
					}
				}
			case .Fixed32:
				if wire == .I32 {
					counts[i] += 1
				} else if wire == .Len {
					counts[i] += len(len_payload(d, value_start)) / 4
				}
			case .Fixed64:
				if wire == .I64 {
					counts[i] += 1
				} else if wire == .Len {
					counts[i] += len(len_payload(d, value_start)) / 8
				}
			case .Len:
				if wire == .Len {
					counts[i] += 1
				}
			}
			break
		}
	}
	return .None
}

// len_payload returns the payload of the already validated length-delimited
// value that starts at value_start and ends at the decoder position.
@(private)
len_payload :: proc "contextless" (d: ^Decoder, value_start: int) -> []u8 {
	pos := value_start
	n: u64
	shift: uint
	for {
		b := d.data[pos]
		pos += 1
		n |= u64(b & 0x7f) << shift
		if b < 0x80 {break}
		shift += 7
	}
	return d.data[pos:d.pos]
}

// reserve_repeated makes room for `extra` more elements. Growth is
// geometric, so repeated merging (a singular sub-message occurring many
// times on the wire) stays linear in the input size.
reserve_repeated :: proc(d: ^Decoder, a: ^[dynamic]$T, extra: int) -> Error {
	ensure_allocator(d, a)
	need := len(a) + extra
	if need <= cap(a) {
		return .None
	}
	if reserve(a, max(need, 2 * cap(a))) != nil {
		return .Out_Of_Memory
	}
	return .None
}

// append_repeated appends v, growing geometrically if needed.
append_repeated :: #force_inline proc(d: ^Decoder, a: ^[dynamic]$T, v: T) -> Error {
	if len(a) == cap(a) {
		reserve_repeated(d, a, 1) or_return
	}
	append(a, v)
	return .None
}

// append_repeated_zeroed appends a zero element and returns a pointer to it,
// for message elements that are decoded in place.
append_repeated_zeroed :: proc(d: ^Decoder, a: ^[dynamic]$T) -> (^T, Error) {
	if len(a) == cap(a) {
		if err := reserve_repeated(d, a, 1); err != .None {
			return nil, err
		}
	}
	append(a, T{})
	return &a[len(a) - 1], .None
}
