package http2

import "base:intrinsics"

// -----------------------------------------------------------------------------
// Frame header
// -----------------------------------------------------------------------------

// decode_frame_header reads the 9-octet frame header at the start of b.
decode_frame_header :: proc "contextless" (b: []u8) -> Frame_Header {
	assert_contextless(len(b) >= FRAME_HEADER_SIZE)
	return {
		length = u32(b[0]) << 16 | u32(b[1]) << 8 | u32(b[2]),
		type = b[3],
		flags = b[4],
		stream_id = get_u32(b[5:]) & MAX_STREAM_ID,
	}
}

// check_frame_header applies the size and stream-identifier rules that can
// be checked from the header alone (RFC 9113 §4.2, §6). `max_frame_size` is
// the SETTINGS_MAX_FRAME_SIZE this endpoint advertised.
check_frame_header :: proc "contextless" (h: Frame_Header, max_frame_size: u32) -> Problem {
	if h.length > max_frame_size {
		return connection_error(.Frame_Size_Error, "frame exceeds SETTINGS_MAX_FRAME_SIZE")
	}
	if !is_known_type(h.type) {
		return {} // unknown frame types are ignored (§4.1)
	}
	switch Frame_Type(h.type) {
	case .Data, .Headers, .Priority, .Rst_Stream, .Push_Promise, .Continuation:
		if h.stream_id == 0 {
			return connection_error(.Protocol_Error, "frame requires a stream identifier")
		}
	case .Settings, .Ping, .Goaway:
		if h.stream_id != 0 {
			return connection_error(.Protocol_Error, "frame must be sent on stream 0")
		}
	case .Window_Update:
	}
	switch Frame_Type(h.type) {
	case .Settings:
		if h.flags & FLAG_ACK != 0 && h.length != 0 {
			return connection_error(.Frame_Size_Error, "SETTINGS ACK with a payload")
		}
		if h.length % 6 != 0 {
			return connection_error(.Frame_Size_Error, "SETTINGS length is not a multiple of 6")
		}
	case .Ping:
		if h.length != 8 {
			return connection_error(.Frame_Size_Error, "PING payload must be 8 octets")
		}
	case .Rst_Stream:
		if h.length != 4 {
			return connection_error(.Frame_Size_Error, "RST_STREAM payload must be 4 octets")
		}
	case .Window_Update:
		if h.length != 4 {
			return connection_error(.Frame_Size_Error, "WINDOW_UPDATE payload must be 4 octets")
		}
	case .Priority:
		if h.length != 5 {
			return stream_error(.Frame_Size_Error, "PRIORITY payload must be 5 octets")
		}
	case .Goaway:
		if h.length < 8 {
			return connection_error(.Frame_Size_Error, "GOAWAY payload shorter than 8 octets")
		}
	case .Data, .Headers, .Push_Promise, .Continuation:
	}
	return {}
}

// -----------------------------------------------------------------------------
// Payload parsing. `payload` is exactly h.length octets.
// -----------------------------------------------------------------------------

// strip_padding removes the Pad Length field and padding of a PADDED frame
// (§6.1, §6.2). `fixed` is the size of fields between Pad Length and the
// content (5 for a HEADERS frame with PRIORITY).
@(private)
strip_padding :: proc "contextless" (h: Frame_Header, payload: []u8, fixed: int) -> (content: []u8, problem: Problem) {
	if h.flags & FLAG_PADDED == 0 {
		if len(payload) < fixed {
			return nil, connection_error(.Frame_Size_Error, "frame too short")
		}
		return payload, {}
	}
	if len(payload) < 1 + fixed {
		return nil, connection_error(.Frame_Size_Error, "padded frame too short")
	}
	pad := int(payload[0])
	if pad > len(payload) - 1 - fixed {
		return nil, connection_error(.Protocol_Error, "padding exceeds frame payload")
	}
	return payload[1:len(payload) - pad], {}
}

Data_Frame :: struct {
	data:       []u8,
	end_stream: bool,
}

// parse_data parses a DATA frame. Note that the whole payload length,
// including padding, counts against flow control (§6.9).
parse_data :: proc "contextless" (h: Frame_Header, payload: []u8) -> (f: Data_Frame, problem: Problem) {
	f.data, problem = strip_padding(h, payload, 0)
	f.end_stream = h.flags & FLAG_END_STREAM != 0
	return
}

Priority :: struct {
	exclusive:  bool,
	dependency: u32,
	weight:     u8, // weight - 1, as on the wire
}

Headers_Frame :: struct {
	fragment:     []u8, // header block fragment
	end_stream:   bool,
	end_headers:  bool,
	has_priority: bool,
	priority:     Priority,
}

parse_headers :: proc "contextless" (h: Frame_Header, payload: []u8) -> (f: Headers_Frame, problem: Problem) {
	has_priority := h.flags & FLAG_PRIORITY != 0
	content: []u8
	content, problem = strip_padding(h, payload, 5 if has_priority else 0)
	if has_problem(problem) {
		return
	}
	if has_priority {
		f.has_priority = true
		f.priority = decode_priority(content)
		if f.priority.dependency == h.stream_id {
			return f, stream_error(.Protocol_Error, "stream depends on itself")
		}
		content = content[5:]
	}
	f.fragment = content
	f.end_stream = h.flags & FLAG_END_STREAM != 0
	f.end_headers = h.flags & FLAG_END_HEADERS != 0
	return f, {}
}

// parse_priority validates a PRIORITY frame. Priority signals are otherwise
// ignored: RFC 9113 deprecates the priority scheme.
parse_priority :: proc "contextless" (h: Frame_Header, payload: []u8) -> (p: Priority, problem: Problem) {
	p = decode_priority(payload)
	if p.dependency == h.stream_id {
		return p, stream_error(.Protocol_Error, "stream depends on itself")
	}
	return p, {}
}

@(private)
decode_priority :: proc "contextless" (b: []u8) -> Priority {
	v := get_u32(b)
	return {exclusive = v & 0x8000_0000 != 0, dependency = v & MAX_STREAM_ID, weight = b[4]}
}

// parse_rst_stream returns the error code. Unknown codes are valid and must
// not be treated specially (§7).
parse_rst_stream :: proc "contextless" (payload: []u8) -> Error_Code {
	return Error_Code(get_u32(payload))
}

// next_setting iterates a SETTINGS payload:
//
//     for s in http2.next_setting(payload, &offset) { ... }
//
// Unknown identifiers are returned too; callers must ignore them (§6.5.2).
next_setting :: proc "contextless" (payload: []u8, offset: ^int) -> (id: u16, value: u32, ok: bool) {
	if offset^ + 6 > len(payload) {
		return 0, 0, false
	}
	b := payload[offset^:]
	offset^ += 6
	return u16(b[0]) << 8 | u16(b[1]), get_u32(b[2:]), true
}

// check_setting validates a received setting value (§6.5.2).
check_setting :: proc "contextless" (id: u16, value: u32) -> Problem {
	switch Setting_Id(id) {
	case .Enable_Push:
		if value > 1 {
			return connection_error(.Protocol_Error, "SETTINGS_ENABLE_PUSH must be 0 or 1")
		}
	case .Initial_Window_Size:
		if value > MAX_WINDOW_SIZE {
			return connection_error(.Flow_Control_Error, "SETTINGS_INITIAL_WINDOW_SIZE above 2^31-1")
		}
	case .Max_Frame_Size:
		if value < MIN_MAX_FRAME_SIZE || value > MAX_MAX_FRAME_SIZE {
			return connection_error(.Protocol_Error, "SETTINGS_MAX_FRAME_SIZE out of range")
		}
	case .Header_Table_Size, .Max_Concurrent_Streams, .Max_Header_List_Size:
	}
	return {}
}

parse_ping :: proc "contextless" (payload: []u8) -> (data: [8]u8) {
	copy(data[:], payload)
	return
}

Goaway_Frame :: struct {
	last_stream_id: u32,
	code:           Error_Code,
	debug_data:     []u8,
}

parse_goaway :: proc "contextless" (payload: []u8) -> Goaway_Frame {
	return {last_stream_id = get_u32(payload) & MAX_STREAM_ID, code = Error_Code(get_u32(payload[4:])), debug_data = payload[8:]}
}

parse_window_update :: proc "contextless" (h: Frame_Header, payload: []u8) -> (increment: u32, problem: Problem) {
	increment = get_u32(payload) & MAX_WINDOW_SIZE
	if increment == 0 {
		if h.stream_id == 0 {
			return 0, connection_error(.Protocol_Error, "WINDOW_UPDATE with zero increment")
		}
		return 0, stream_error(.Protocol_Error, "WINDOW_UPDATE with zero increment")
	}
	return increment, {}
}

// -----------------------------------------------------------------------------
// Serialization. All writers append to `buf`.
// -----------------------------------------------------------------------------

Write_Error :: enum u8 {
	None,
	Out_Of_Memory,
}

append_frame_header :: proc(buf: ^[dynamic]u8, length: int, type: Frame_Type, flags: u8, stream_id: u32) -> Write_Error {
	assert(length >= 0 && length <= MAX_MAX_FRAME_SIZE)
	assert(stream_id <= MAX_STREAM_ID)
	hdr := [FRAME_HEADER_SIZE]u8 {
		u8(length >> 16),
		u8(length >> 8),
		u8(length),
		u8(type),
		flags,
		u8(stream_id >> 24),
		u8(stream_id >> 16),
		u8(stream_id >> 8),
		u8(stream_id),
	}
	return append_bytes(buf, hdr[:])
}

// append_data writes one DATA frame; data must fit the peer's max frame size.
append_data :: proc(buf: ^[dynamic]u8, stream_id: u32, data: []u8, end_stream: bool) -> Write_Error {
	append_frame_header(buf, len(data), .Data, FLAG_END_STREAM if end_stream else 0, stream_id) or_return
	return append_bytes(buf, data)
}

// append_headers writes a header block as a HEADERS frame followed by as
// many CONTINUATION frames as needed to respect max_frame_size.
append_headers :: proc(buf: ^[dynamic]u8, stream_id: u32, block: []u8, end_stream: bool, max_frame_size: int) -> Write_Error {
	assert(max_frame_size >= MIN_MAX_FRAME_SIZE)
	first := min(len(block), max_frame_size)
	flags := FLAG_END_STREAM if end_stream else 0
	if first == len(block) {
		flags |= FLAG_END_HEADERS
	}
	append_frame_header(buf, first, .Headers, flags, stream_id) or_return
	append_bytes(buf, block[:first]) or_return
	rest := block[first:]
	for len(rest) > 0 {
		n := min(len(rest), max_frame_size)
		append_frame_header(buf, n, .Continuation, FLAG_END_HEADERS if n == len(rest) else 0, stream_id) or_return
		append_bytes(buf, rest[:n]) or_return
		rest = rest[n:]
	}
	return .None
}

append_settings :: proc(buf: ^[dynamic]u8, settings: []Setting) -> Write_Error {
	append_frame_header(buf, 6 * len(settings), .Settings, 0, 0) or_return
	for s in settings {
		b := [6]u8{u8(u16(s.id) >> 8), u8(s.id), 0, 0, 0, 0}
		put_u32(b[2:], s.value)
		append_bytes(buf, b[:]) or_return
	}
	return .None
}

append_settings_ack :: proc(buf: ^[dynamic]u8) -> Write_Error {
	return append_frame_header(buf, 0, .Settings, FLAG_ACK, 0)
}

append_ping :: proc(buf: ^[dynamic]u8, data: [8]u8, ack: bool) -> Write_Error {
	append_frame_header(buf, 8, .Ping, FLAG_ACK if ack else 0, 0) or_return
	data := data
	return append_bytes(buf, data[:])
}

append_goaway :: proc(buf: ^[dynamic]u8, last_stream_id: u32, code: Error_Code, debug_data: string = "") -> Write_Error {
	append_frame_header(buf, 8 + len(debug_data), .Goaway, 0, 0) or_return
	b: [8]u8
	put_u32(b[:], last_stream_id & MAX_STREAM_ID)
	put_u32(b[4:], u32(code))
	append_bytes(buf, b[:]) or_return
	return append_bytes(buf, transmute([]u8)debug_data)
}

append_rst_stream :: proc(buf: ^[dynamic]u8, stream_id: u32, code: Error_Code) -> Write_Error {
	append_frame_header(buf, 4, .Rst_Stream, 0, stream_id) or_return
	b: [4]u8
	put_u32(b[:], u32(code))
	return append_bytes(buf, b[:])
}

append_window_update :: proc(buf: ^[dynamic]u8, stream_id: u32, increment: u32) -> Write_Error {
	assert(increment >= 1 && increment <= MAX_WINDOW_SIZE)
	append_frame_header(buf, 4, .Window_Update, 0, stream_id) or_return
	b: [4]u8
	put_u32(b[:], increment)
	return append_bytes(buf, b[:])
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

get_u32 :: #force_inline proc "contextless" (b: []u8) -> u32 {
	return u32(intrinsics.unaligned_load((^u32be)(raw_data(b))))
}

put_u32 :: #force_inline proc "contextless" (b: []u8, v: u32) {
	intrinsics.unaligned_store((^u32be)(raw_data(b)), u32be(v))
}

@(private)
append_bytes :: proc(buf: ^[dynamic]u8, b: []u8) -> Write_Error {
	if _, err := append(buf, ..b); err != nil {
		return .Out_Of_Memory
	}
	return .None
}
