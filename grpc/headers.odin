package grpc

import "base:runtime"
import "core:strings"

// Metadata_Storage owns received metadata: one entry array and one byte
// buffer that all entry strings point into.
Metadata_Storage :: struct {
	entries: []Metadata_Entry,
	bytes:   []u8,
}

// Include_Proc selects which header fields become metadata.
@(private)
Include_Proc :: #type proc(name: string) -> bool

// metadata_build copies the selected fields of a decoded header block into
// owned storage, base64-decoding -bin values. `bad` is set when a -bin
// value is not valid base64 (that entry is dropped).
@(private)
metadata_build :: proc(h: ^Header_Fields, include: Include_Proc, allocator: runtime.Allocator) -> (md: Metadata_Storage, bad: bool, ok: bool) {
	count, size := 0, 0
	for i in 0 ..< len(h.spans) {
		name, value := field_at(h, i)
		if include(name) {
			count += 1
			size += len(name) + len(value) // decoded -bin values are smaller
		}
	}
	if count == 0 {
		return {}, false, true
	}
	entries, e_err := make([]Metadata_Entry, count, allocator)
	if e_err != nil {
		return {}, false, false
	}
	bytes, b_err := make([]u8, size, allocator)
	if b_err != nil {
		delete(entries, allocator)
		return {}, false, false
	}
	n, off := 0, 0
	for i in 0 ..< len(h.spans) {
		name, value := field_at(h, i)
		if !include(name) {
			continue
		}
		copy(bytes[off:], name)
		key := string(bytes[off:off + len(name)])
		off += len(name)
		val: string
		if is_binary_key(name) {
			decoded, dec_ok := base64_decode(bytes[off:], value)
			if !dec_ok {
				bad = true
				off -= len(name)
				continue
			}
			val = string(decoded)
			off += len(decoded)
		} else {
			copy(bytes[off:], value)
			val = string(bytes[off:off + len(value)])
			off += len(value)
		}
		entries[n] = {key, val}
		n += 1
	}
	return {entries[:n], bytes}, bad, true
}

@(private)
metadata_destroy :: proc(md: ^Metadata_Storage, allocator: runtime.Allocator) {
	if md.entries != nil {
		delete(md.entries, allocator)
	}
	if md.bytes != nil {
		delete(md.bytes, allocator)
	}
	md^ = {}
}

// is_grpc_content_type accepts "application/grpc" optionally followed by
// "+<format>" or ";<params>" (PROTOCOL-HTTP2.md: Content-Type).
@(private)
is_grpc_content_type :: proc(v: string) -> bool {
	PREFIX :: "application/grpc"
	if !strings.has_prefix(v, PREFIX) {
		return false
	}
	return len(v) == len(PREFIX) || v[len(PREFIX)] == '+' || v[len(PREFIX)] == ';'
}

// has_uppercase reports field names that are malformed in HTTP/2 (§8.2.1).
@(private)
has_uppercase :: proc "contextless" (s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] >= 'A' && s[i] <= 'Z' {
			return true
		}
	}
	return false
}
