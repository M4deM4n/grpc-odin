/*
Package http2 implements the HTTP/2 framing layer (RFC 9113): frame header
and payload parsing with full validation, and frame serialization. It
performs no I/O and keeps no connection state; connection and stream state
machines are built on top of it (see the grpc package).
*/
package http2

// CLIENT_PREFACE is sent by the client before its first SETTINGS frame (§3.4).
CLIENT_PREFACE :: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

FRAME_HEADER_SIZE :: 9

// Protocol limits and initial values (§6.5.2).
DEFAULT_HEADER_TABLE_SIZE :: 4096
DEFAULT_INITIAL_WINDOW_SIZE :: 65_535
DEFAULT_MAX_FRAME_SIZE :: 16_384
MIN_MAX_FRAME_SIZE :: 16_384
MAX_MAX_FRAME_SIZE :: (1 << 24) - 1
MAX_WINDOW_SIZE :: (1 << 31) - 1
MAX_STREAM_ID :: (1 << 31) - 1

Frame_Type :: enum u8 {
	Data          = 0x0,
	Headers       = 0x1,
	Priority      = 0x2,
	Rst_Stream    = 0x3,
	Settings      = 0x4,
	Push_Promise  = 0x5,
	Ping          = 0x6,
	Goaway        = 0x7,
	Window_Update = 0x8,
	Continuation  = 0x9,
}

FRAME_TYPE_COUNT :: 10

// Frame flags. Their meaning depends on the frame type.
FLAG_END_STREAM :: u8(0x1) // DATA, HEADERS
FLAG_ACK :: u8(0x1) // SETTINGS, PING
FLAG_END_HEADERS :: u8(0x4) // HEADERS, PUSH_PROMISE, CONTINUATION
FLAG_PADDED :: u8(0x8) // DATA, HEADERS, PUSH_PROMISE
FLAG_PRIORITY :: u8(0x20) // HEADERS

Error_Code :: enum u32 {
	No_Error            = 0x0,
	Protocol_Error      = 0x1,
	Internal_Error      = 0x2,
	Flow_Control_Error  = 0x3,
	Settings_Timeout    = 0x4,
	Stream_Closed       = 0x5,
	Frame_Size_Error    = 0x6,
	Refused_Stream      = 0x7,
	Cancel              = 0x8,
	Compression_Error   = 0x9,
	Connect_Error       = 0xa,
	Enhance_Your_Calm   = 0xb,
	Inadequate_Security = 0xc,
	Http_1_1_Required   = 0xd,
}

Setting_Id :: enum u16 {
	Header_Table_Size      = 0x1,
	Enable_Push            = 0x2,
	Max_Concurrent_Streams = 0x3,
	Initial_Window_Size    = 0x4,
	Max_Frame_Size         = 0x5,
	Max_Header_List_Size   = 0x6,
}

Setting :: struct {
	id:    Setting_Id,
	value: u32,
}

Frame_Header :: struct {
	length:    u32, // payload length (24 bits)
	type:      u8, // raw type: unknown types must be ignored, not rejected
	flags:     u8,
	stream_id: u32, // reserved bit cleared
}

// Problem describes why a frame is invalid. `scope` tells the caller
// whether the error affects the whole connection or a single stream
// (RFC 9113 §5.4).
Error_Scope :: enum u8 {
	Connection,
	Stream,
}

Problem :: struct {
	code:    Error_Code,
	scope:   Error_Scope,
	message: string, // static description, for diagnostics
}

has_problem :: #force_inline proc "contextless" (p: Problem) -> bool {
	return p.message != ""
}

connection_error :: #force_inline proc "contextless" (code: Error_Code, message: string) -> Problem {
	return {code, .Connection, message}
}

stream_error :: #force_inline proc "contextless" (code: Error_Code, message: string) -> Problem {
	return {code, .Stream, message}
}

is_known_type :: #force_inline proc "contextless" (t: u8) -> bool {
	return t < FRAME_TYPE_COUNT
}
