package grpc

import "core:strings"

// Metadata_Entry is one metadata key/value pair. Keys are lowercase ASCII.
// Values of keys ending in "-bin" are arbitrary octets (they are base64
// coded on the wire transparently); other values are printable ASCII.
Metadata_Entry :: struct {
	key:   string,
	value: string,
}

// metadata_get returns the first value of `key` (which must be lowercase).
metadata_get :: proc "contextless" (md: []Metadata_Entry, key: string) -> (value: string, ok: bool) {
	for e in md {
		if e.key == key {
			return e.value, true
		}
	}
	return "", false
}

// metadata_count returns the number of values of `key`.
metadata_count :: proc "contextless" (md: []Metadata_Entry, key: string) -> (n: int) {
	for e in md {
		if e.key == key {
			n += 1
		}
	}
	return
}

is_binary_key :: proc "contextless" (key: string) -> bool {
	return len(key) > 4 && key[len(key) - 4:] == "-bin"
}

// valid_metadata_key: 1+ of [0-9a-z-_.], per the gRPC wire spec.
valid_metadata_key :: proc "contextless" (key: string) -> bool {
	if len(key) == 0 {
		return false
	}
	for i in 0 ..< len(key) {
		c := key[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

// valid_ascii_value: printable ASCII (0x20-0x7E), per the gRPC wire spec.
valid_ascii_value :: proc "contextless" (value: string) -> bool {
	for i in 0 ..< len(value) {
		if value[i] < 0x20 || value[i] > 0x7e {
			return false
		}
	}
	return true
}

// Headers that are part of the gRPC protocol itself. Applications may not
// send them as custom metadata, and they are not exposed as metadata.
@(private)
is_reserved_header :: proc "contextless" (key: string) -> bool {
	switch key {
	case "content-type", "te", "grpc-timeout", "grpc-encoding", "grpc-accept-encoding", "grpc-status", "grpc-message",
	     "user-agent":
		return true
	}
	// HTTP/2 connection-specific headers are forbidden outright, and "host"
	// is redundant with :authority.
	return key == "host" || is_connection_header(key)
}

// Connection-specific header fields are malformed in HTTP/2 (RFC 9113 §8.2.2).
@(private)
is_connection_header :: proc "contextless" (key: string) -> bool {
	switch key {
	case "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade":
		return true
	}
	return false
}

// check_outgoing_metadata validates application metadata before sending.
check_outgoing_metadata :: proc(md: []Metadata_Entry) -> Status {
	for e in md {
		if !valid_metadata_key(e.key) {
			return {.Internal, "invalid metadata key"}
		}
		if strings.has_prefix(e.key, "grpc-") || is_reserved_header(e.key) {
			return {.Internal, "metadata key is reserved for gRPC"}
		}
		if !is_binary_key(e.key) && !valid_ascii_value(e.value) {
			return {.Internal, "metadata value contains non-printable characters (use a -bin key for binary values)"}
		}
	}
	return {}
}

// -----------------------------------------------------------------------------
// Base64 for -bin values (RFC 4648, standard alphabet). Values are sent
// unpadded and accepted with or without padding, as the spec requires.
// -----------------------------------------------------------------------------

@(private, rodata)
B64_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

base64_encoded_len :: proc "contextless" (n: int) -> int {
	return (n * 8 + 5) / 6
}

// append_base64 appends the unpadded base64 encoding of b.
append_base64 :: proc(dst: ^[dynamic]u8, b: []u8) -> bool {
	start := len(dst)
	if resize(dst, start + base64_encoded_len(len(b))) != nil {
		return false
	}
	out := dst[start:]
	o := 0
	i := 0
	for ; i + 3 <= len(b); i += 3 {
		v := u32(b[i]) << 16 | u32(b[i + 1]) << 8 | u32(b[i + 2])
		out[o] = B64_ALPHABET[v >> 18]
		out[o + 1] = B64_ALPHABET[(v >> 12) & 63]
		out[o + 2] = B64_ALPHABET[(v >> 6) & 63]
		out[o + 3] = B64_ALPHABET[v & 63]
		o += 4
	}
	switch len(b) - i {
	case 1:
		v := u32(b[i]) << 16
		out[o] = B64_ALPHABET[v >> 18]
		out[o + 1] = B64_ALPHABET[(v >> 12) & 63]
	case 2:
		v := u32(b[i]) << 16 | u32(b[i + 1]) << 8
		out[o] = B64_ALPHABET[v >> 18]
		out[o + 1] = B64_ALPHABET[(v >> 12) & 63]
		out[o + 2] = B64_ALPHABET[(v >> 6) & 63]
	}
	return true
}

@(private)
b64_value :: #force_inline proc "contextless" (c: u8) -> (u32, bool) {
	switch c {
	case 'A' ..= 'Z':
		return u32(c - 'A'), true
	case 'a' ..= 'z':
		return u32(c - 'a' + 26), true
	case '0' ..= '9':
		return u32(c - '0' + 52), true
	case '+', '-':
		return 62, true // also accept the URL-safe alphabet
	case '/', '_':
		return 63, true
	}
	return 0, false
}

// base64_decode decodes s into dst (which must hold at least len(s)*3/4
// octets) and returns the decoded prefix, or ok = false if s is malformed.
base64_decode :: proc "contextless" (dst: []u8, s: string) -> (out: []u8, ok: bool) {
	s := s
	for len(s) > 0 && s[len(s) - 1] == '=' {
		s = s[:len(s) - 1]
	}
	if len(s) % 4 == 1 {
		return nil, false
	}
	n := 0
	acc: u32 = 0
	bits: uint = 0
	for i in 0 ..< len(s) {
		v := b64_value(s[i]) or_return
		acc = acc << 6 | v
		bits += 6
		if bits >= 8 {
			bits -= 8
			dst[n] = u8(acc >> bits)
			n += 1
			acc &= (1 << bits) - 1
		}
	}
	return dst[:n], true
}
