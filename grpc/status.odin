package grpc

import "core:fmt"
import "core:strconv"
import "core:time"

// Status_Code is a gRPC status code
// (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
Status_Code :: enum u32 {
	OK                  = 0,
	Cancelled           = 1,
	Unknown             = 2,
	Invalid_Argument    = 3,
	Deadline_Exceeded   = 4,
	Not_Found           = 5,
	Already_Exists      = 6,
	Permission_Denied   = 7,
	Resource_Exhausted  = 8,
	Failed_Precondition = 9,
	Aborted             = 10,
	Out_Of_Range        = 11,
	Unimplemented       = 12,
	Internal            = 13,
	Unavailable         = 14,
	Data_Loss           = 15,
	Unauthenticated     = 16,
}

// Status is the outcome of an RPC. The message must stay valid until the
// status has been sent (server) or is no longer needed (client); received
// messages are allocated from the call's allocator.
Status :: struct {
	code:    Status_Code,
	message: string,
}

STATUS_OK :: Status{}

status_ok :: #force_inline proc "contextless" (s: Status) -> bool {
	return s.code == .OK
}

// status_errorf formats a status message with the given allocator (the
// per-call allocator on servers is a good choice).
status_errorf :: proc(code: Status_Code, format: string, args: ..any, allocator := context.temp_allocator) -> Status {
	return {code, fmt.aprintf(format, ..args, allocator = allocator)}
}

STATUS_CODE_NAMES := [Status_Code]string {
	.OK                  = "OK",
	.Cancelled           = "CANCELLED",
	.Unknown             = "UNKNOWN",
	.Invalid_Argument    = "INVALID_ARGUMENT",
	.Deadline_Exceeded   = "DEADLINE_EXCEEDED",
	.Not_Found           = "NOT_FOUND",
	.Already_Exists      = "ALREADY_EXISTS",
	.Permission_Denied   = "PERMISSION_DENIED",
	.Resource_Exhausted  = "RESOURCE_EXHAUSTED",
	.Failed_Precondition = "FAILED_PRECONDITION",
	.Aborted             = "ABORTED",
	.Out_Of_Range        = "OUT_OF_RANGE",
	.Unimplemented       = "UNIMPLEMENTED",
	.Internal            = "INTERNAL",
	.Unavailable         = "UNAVAILABLE",
	.Data_Loss           = "DATA_LOSS",
	.Unauthenticated     = "UNAUTHENTICATED",
}

// status_code_string returns the canonical name, or "UNKNOWN(n)" style text
// written to buf for codes outside the defined range.
status_code_string :: proc(code: Status_Code, buf: []u8) -> string {
	if code <= .Unauthenticated {
		return STATUS_CODE_NAMES[code]
	}
	return fmt.bprintf(buf, "CODE(%d)", u32(code))
}

// parse_status_code parses a grpc-status value. Codes outside the known
// range are mapped to UNKNOWN, as the specification requires.
parse_status_code :: proc(s: string) -> (code: Status_Code, ok: bool) {
	if len(s) == 0 || len(s) > 10 {
		return .Unknown, false
	}
	v, parsed := strconv.parse_u64_of_base(s, 10)
	if !parsed {
		return .Unknown, false
	}
	if v > u64(Status_Code.Unauthenticated) {
		return .Unknown, true
	}
	return Status_Code(v), true
}

// -----------------------------------------------------------------------------
// grpc-message percent-encoding
// -----------------------------------------------------------------------------

// Octets outside the printable ASCII range, and '%', are percent-encoded in
// grpc-message (PROTOCOL-HTTP2.md: "Status-Message").
@(private)
needs_percent :: #force_inline proc "contextless" (c: u8) -> bool {
	return c < 0x20 || c > 0x7e || c == '%'
}

// append_percent_encoded appends s, percent-encoded, to dst.
append_percent_encoded :: proc(dst: ^[dynamic]u8, s: string) -> bool {
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		if needs_percent(c) {
			if _, err := append(dst, '%', HEX[c >> 4], HEX[c & 0xf]); err != nil {
				return false
			}
		} else if _, err := append(dst, c); err != nil {
			return false
		}
	}
	return true
}

// percent_decode decodes s into dst (which must hold len(s) octets) and
// returns the decoded prefix. Malformed escapes are kept verbatim, as the
// specification asks decoders to be lenient.
percent_decode :: proc "contextless" (dst: []u8, s: string) -> string {
	n := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			hi, ok_hi := hex_digit(s[i + 1])
			lo, ok_lo := hex_digit(s[i + 2])
			if ok_hi && ok_lo {
				dst[n] = hi << 4 | lo
				n += 1
				i += 2
				continue
			}
		}
		dst[n] = c
		n += 1
	}
	return string(dst[:n])
}

@(private)
hex_digit :: #force_inline proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// -----------------------------------------------------------------------------
// grpc-timeout
// -----------------------------------------------------------------------------

// format_timeout renders a positive duration as a grpc-timeout value: at
// most 8 digits followed by a unit, rounding up so the deadline is never
// shortened.
format_timeout :: proc(d: time.Duration, buf: []u8) -> string {
	Unit :: struct {
		nanos:  i64,
		symbol: u8,
	}
	UNITS := [?]Unit {
		{1, 'n'},
		{1_000, 'u'},
		{1_000_000, 'm'},
		{1_000_000_000, 'S'},
		{60 * 1_000_000_000, 'M'},
		{3600 * 1_000_000_000, 'H'},
	}
	MAX_VALUE :: 99_999_999
	ns := max(i64(d), 1)
	for u in UNITS {
		// Round up without overflowing for durations near max(i64).
		v := ns / u.nanos + (1 if ns % u.nanos != 0 else 0)
		if v <= MAX_VALUE {
			return fmt.bprintf(buf, "%d%c", v, rune(u.symbol))
		}
	}
	return fmt.bprintf(buf, "%dH", MAX_VALUE)
}

// parse_timeout parses a grpc-timeout header value.
parse_timeout :: proc(s: string) -> (d: time.Duration, ok: bool) {
	if len(s) < 2 || len(s) > 9 {
		return 0, false
	}
	digits := s[:len(s) - 1]
	for c in transmute([]u8)digits {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	v, parsed := strconv.parse_i64_of_base(digits, 10)
	if !parsed {
		return 0, false
	}
	unit: time.Duration
	switch s[len(s) - 1] {
	case 'H':
		unit = time.Hour
	case 'M':
		unit = time.Minute
	case 'S':
		unit = time.Second
	case 'm':
		unit = time.Millisecond
	case 'u':
		unit = time.Microsecond
	case 'n':
		unit = time.Nanosecond
	case:
		return 0, false
	}
	// Saturate instead of overflowing: peers send e.g. "99999999H" to mean
	// "practically no deadline".
	if v >= i64(MAX_TIMEOUT / unit) {
		return MAX_TIMEOUT, true
	}
	return time.Duration(v) * unit, true
}

// MAX_TIMEOUT caps timeouts; deadlines this far away are treated as no
// deadline at all, which also keeps time arithmetic from overflowing.
MAX_TIMEOUT :: 10 * 365 * 24 * time.Hour

// deadline_after returns now + d, or no deadline ({}) for d >= MAX_TIMEOUT.
deadline_after :: proc(d: time.Duration) -> time.Time {
	if d >= MAX_TIMEOUT {
		return {}
	}
	return time.time_add(time.now(), d)
}
