package http2_test

import "core:testing"

import "../../http2"

header_of :: proc(buf: []u8) -> http2.Frame_Header {
	return http2.decode_frame_header(buf)
}

@(test)
test_frame_header_roundtrip :: proc(t: ^testing.T) {
	buf := make([dynamic]u8, context.temp_allocator)
	http2.append_frame_header(&buf, 0x123456, .Headers, http2.FLAG_END_HEADERS | http2.FLAG_PADDED, 0x7fffffff)
	testing.expect_value(t, len(buf), 9)
	h := header_of(buf[:])
	testing.expect_value(t, h.length, 0x123456)
	testing.expect_value(t, h.type, u8(http2.Frame_Type.Headers))
	testing.expect_value(t, h.flags, http2.FLAG_END_HEADERS | http2.FLAG_PADDED)
	testing.expect_value(t, h.stream_id, 0x7fffffff)

	// The reserved bit of the stream identifier is ignored on receipt.
	raw := [9]u8{0, 0, 0, 0, 0, 0x80, 0, 0, 1}
	testing.expect_value(t, header_of(raw[:]).stream_id, 1)
}

@(test)
test_check_frame_header :: proc(t: ^testing.T) {
	Case :: struct {
		h:     http2.Frame_Header,
		code:  http2.Error_Code,
		scope: http2.Error_Scope,
		ok:    bool,
	}
	T :: http2.Frame_Type
	cases := []Case {
		{{length = 16385, type = u8(T.Data), stream_id = 1}, .Frame_Size_Error, .Connection, false},
		{{length = 0, type = u8(T.Data), stream_id = 0}, .Protocol_Error, .Connection, false},
		{{length = 0, type = u8(T.Headers), stream_id = 0}, .Protocol_Error, .Connection, false},
		{{length = 0, type = u8(T.Continuation), stream_id = 0}, .Protocol_Error, .Connection, false},
		{{length = 6, type = u8(T.Settings), stream_id = 1}, .Protocol_Error, .Connection, false},
		{{length = 7, type = u8(T.Settings)}, .Frame_Size_Error, .Connection, false},
		{{length = 6, type = u8(T.Settings), flags = http2.FLAG_ACK}, .Frame_Size_Error, .Connection, false},
		{{length = 12, type = u8(T.Settings)}, .No_Error, .Connection, true},
		{{length = 7, type = u8(T.Ping)}, .Frame_Size_Error, .Connection, false},
		{{length = 8, type = u8(T.Ping), stream_id = 3}, .Protocol_Error, .Connection, false},
		{{length = 8, type = u8(T.Ping)}, .No_Error, .Connection, true},
		{{length = 3, type = u8(T.Rst_Stream), stream_id = 1}, .Frame_Size_Error, .Connection, false},
		{{length = 4, type = u8(T.Rst_Stream), stream_id = 0}, .Protocol_Error, .Connection, false},
		{{length = 5, type = u8(T.Window_Update)}, .Frame_Size_Error, .Connection, false},
		{{length = 4, type = u8(T.Window_Update)}, .No_Error, .Connection, true},
		{{length = 4, type = u8(T.Priority), stream_id = 1}, .Frame_Size_Error, .Stream, false},
		{{length = 7, type = u8(T.Goaway)}, .Frame_Size_Error, .Connection, false},
		{{length = 8, type = u8(T.Goaway), stream_id = 1}, .Protocol_Error, .Connection, false},
		// Unknown frame types are ignored, whatever their stream.
		{{length = 100, type = 0xfa, stream_id = 0}, .No_Error, .Connection, true},
	}
	for c, i in cases {
		p := http2.check_frame_header(c.h, http2.DEFAULT_MAX_FRAME_SIZE)
		if c.ok {
			testing.expectf(t, !http2.has_problem(p), "case %d: unexpected problem %v", i, p)
		} else {
			testing.expectf(t, http2.has_problem(p) && p.code == c.code && p.scope == c.scope, "case %d: got %v, want %v/%v", i, p, c.code, c.scope)
		}
	}
}

@(test)
test_data_padding :: proc(t: ^testing.T) {
	h := http2.Frame_Header {
		length    = 6,
		type      = u8(http2.Frame_Type.Data),
		flags     = http2.FLAG_PADDED | http2.FLAG_END_STREAM,
		stream_id = 1,
	}
	payload := []u8{2, 'a', 'b', 'c', 0, 0}
	f, p := http2.parse_data(h, payload)
	testing.expect(t, !http2.has_problem(p))
	testing.expect_value(t, string(f.data), "abc")
	testing.expect(t, f.end_stream)

	// Padding equal to the remaining length leaves no data: valid.
	f, p = http2.parse_data(h, []u8{5, 0, 0, 0, 0, 0})
	testing.expect(t, !http2.has_problem(p) && len(f.data) == 0)

	// Padding longer than the payload is a connection PROTOCOL_ERROR.
	_, p = http2.parse_data(h, []u8{6, 0, 0, 0, 0, 0})
	testing.expect_value(t, p.code, http2.Error_Code.Protocol_Error)
	testing.expect_value(t, p.scope, http2.Error_Scope.Connection)

	// PADDED with an empty payload.
	h.length = 0
	_, p = http2.parse_data(h, {})
	testing.expect(t, http2.has_problem(p))
}

@(test)
test_headers_padding_and_priority :: proc(t: ^testing.T) {
	h := http2.Frame_Header {
		type      = u8(http2.Frame_Type.Headers),
		flags     = http2.FLAG_PADDED | http2.FLAG_PRIORITY | http2.FLAG_END_HEADERS,
		stream_id = 3,
	}
	payload := []u8{1, 0x80, 0, 0, 1, 15, 'x', 'y', 0}
	h.length = u32(len(payload))
	f, p := http2.parse_headers(h, payload)
	testing.expect(t, !http2.has_problem(p))
	testing.expect_value(t, string(f.fragment), "xy")
	testing.expect(t, f.has_priority && f.priority.exclusive && f.priority.dependency == 1 && f.priority.weight == 15)
	testing.expect(t, f.end_headers && !f.end_stream)

	// Self-dependency is a stream error.
	self := []u8{0, 0, 0, 3, 0}
	h2 := http2.Frame_Header {
		length    = 5,
		type      = u8(http2.Frame_Type.Headers),
		flags     = http2.FLAG_PRIORITY,
		stream_id = 3,
	}
	_, p = http2.parse_headers(h2, self)
	testing.expect_value(t, p.scope, http2.Error_Scope.Stream)

	// PRIORITY flag but fewer than 5 octets.
	h2.length = 4
	_, p = http2.parse_headers(h2, self[:4])
	testing.expect(t, http2.has_problem(p))
}

@(test)
test_headers_split_into_continuations :: proc(t: ^testing.T) {
	block := make([]u8, 40000, context.temp_allocator)
	for i in 0 ..< len(block) {
		block[i] = u8(i)
	}
	buf := make([dynamic]u8, context.temp_allocator)
	http2.append_headers(&buf, 5, block, true, http2.DEFAULT_MAX_FRAME_SIZE)

	reassembled := make([dynamic]u8, context.temp_allocator)
	rest := buf[:]
	frames := 0
	for len(rest) > 0 {
		h := header_of(rest)
		payload := rest[9:9 + h.length]
		expect_type := http2.Frame_Type.Headers if frames == 0 else http2.Frame_Type.Continuation
		testing.expect_value(t, h.type, u8(expect_type))
		testing.expect_value(t, h.stream_id, 5)
		testing.expect(t, h.length <= http2.DEFAULT_MAX_FRAME_SIZE)
		last := len(rest) == 9 + int(h.length)
		testing.expect_value(t, h.flags & http2.FLAG_END_HEADERS != 0, last)
		if frames == 0 {
			testing.expect(t, h.flags & http2.FLAG_END_STREAM != 0)
		}
		append(&reassembled, ..payload)
		rest = rest[9 + h.length:]
		frames += 1
	}
	testing.expect_value(t, frames, 3)
	testing.expect(t, string(reassembled[:]) == string(block))

	// A small block is a single HEADERS frame with END_HEADERS.
	clear(&buf)
	http2.append_headers(&buf, 1, {1, 2, 3}, false, http2.DEFAULT_MAX_FRAME_SIZE)
	h := header_of(buf[:])
	testing.expect_value(t, h.flags, http2.FLAG_END_HEADERS)
	testing.expect_value(t, len(buf), 12)
}

@(test)
test_settings :: proc(t: ^testing.T) {
	buf := make([dynamic]u8, context.temp_allocator)
	http2.append_settings(&buf, {{.Max_Frame_Size, 32768}, {.Enable_Push, 0}})
	h := header_of(buf[:])
	testing.expect_value(t, h.length, 12)
	payload := buf[9:]
	offset := 0
	id, value, ok := http2.next_setting(payload, &offset)
	testing.expect(t, ok && id == u16(http2.Setting_Id.Max_Frame_Size) && value == 32768)
	id, value, ok = http2.next_setting(payload, &offset)
	testing.expect(t, ok && id == u16(http2.Setting_Id.Enable_Push) && value == 0)
	_, _, ok = http2.next_setting(payload, &offset)
	testing.expect(t, !ok)

	testing.expect(t, http2.has_problem(http2.check_setting(u16(http2.Setting_Id.Enable_Push), 2)))
	p := http2.check_setting(u16(http2.Setting_Id.Initial_Window_Size), 1 << 31)
	testing.expect_value(t, p.code, http2.Error_Code.Flow_Control_Error)
	testing.expect(t, http2.has_problem(http2.check_setting(u16(http2.Setting_Id.Max_Frame_Size), 16383)))
	testing.expect(t, http2.has_problem(http2.check_setting(u16(http2.Setting_Id.Max_Frame_Size), 1 << 24)))
	testing.expect(t, !http2.has_problem(http2.check_setting(u16(http2.Setting_Id.Max_Frame_Size), (1 << 24) - 1)))
	testing.expect(t, !http2.has_problem(http2.check_setting(0xabcd, 12345))) // unknown: ignored

	clear(&buf)
	http2.append_settings_ack(&buf)
	h = header_of(buf[:])
	testing.expect(t, h.length == 0 && h.flags == http2.FLAG_ACK)
}

@(test)
test_control_frames :: proc(t: ^testing.T) {
	buf := make([dynamic]u8, context.temp_allocator)
	http2.append_ping(&buf, {1, 2, 3, 4, 5, 6, 7, 8}, true)
	h := header_of(buf[:])
	testing.expect(t, h.type == u8(http2.Frame_Type.Ping) && h.flags == http2.FLAG_ACK && h.length == 8)
	testing.expect_value(t, http2.parse_ping(buf[9:]), [8]u8{1, 2, 3, 4, 5, 6, 7, 8})

	clear(&buf)
	http2.append_goaway(&buf, 7, .Enhance_Your_Calm, "calm down")
	g := http2.parse_goaway(buf[9:])
	testing.expect_value(t, g.last_stream_id, 7)
	testing.expect_value(t, g.code, http2.Error_Code.Enhance_Your_Calm)
	testing.expect_value(t, string(g.debug_data), "calm down")

	clear(&buf)
	http2.append_rst_stream(&buf, 9, .Cancel)
	testing.expect_value(t, http2.parse_rst_stream(buf[9:]), http2.Error_Code.Cancel)
	// Unknown codes survive.
	testing.expect_value(t, u32(http2.parse_rst_stream([]u8{0, 0, 0xff, 0xff})), 0xffff)

	clear(&buf)
	http2.append_window_update(&buf, 0, http2.MAX_WINDOW_SIZE)
	h = header_of(buf[:])
	inc, p := http2.parse_window_update(h, buf[9:])
	testing.expect(t, !http2.has_problem(p) && inc == http2.MAX_WINDOW_SIZE)

	zero := []u8{0x80, 0, 0, 0} // reserved bit set, increment 0
	_, p = http2.parse_window_update({length = 4, type = u8(http2.Frame_Type.Window_Update)}, zero)
	testing.expect(t, p.code == .Protocol_Error && p.scope == .Connection)
	_, p = http2.parse_window_update({length = 4, type = u8(http2.Frame_Type.Window_Update), stream_id = 1}, zero)
	testing.expect(t, p.code == .Protocol_Error && p.scope == .Stream)
}
