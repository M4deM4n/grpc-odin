/*
Package hpack implements HPACK, the HTTP/2 header compression format
(RFC 7541): prefix-coded integers, Huffman-coded string literals, the static
and dynamic tables, and a header block encoder/decoder.

Memory model:
  - Encoders and decoders own a fixed-capacity dynamic table that is
    allocated once at init time; encoding/decoding a header block does not
    allocate beyond amortised growth of caller-owned or scratch buffers.
  - Decoded header fields are delivered to a callback. The strings passed to
    the callback are only valid for the duration of that call.
*/
package hpack

// STATIC_TABLE_LEN is the number of entries in the HPACK static table.
STATIC_TABLE_LEN :: 61
// HUFFMAN_SYMBOLS is the number of symbols in the HPACK Huffman code (256 octets + EOS).
HUFFMAN_SYMBOLS :: 257
// HUFFMAN_EOS is the end-of-string symbol, which must never appear in a string literal.
HUFFMAN_EOS :: 256
// HUFFMAN_MAX_CODE_LEN is the longest Huffman code in bits.
HUFFMAN_MAX_CODE_LEN :: 30

// ENTRY_OVERHEAD is the per-entry overhead used in table size accounting (RFC 7541 §4.1).
ENTRY_OVERHEAD :: 32

// DEFAULT_TABLE_SIZE is the initial SETTINGS_HEADER_TABLE_SIZE of HTTP/2.
DEFAULT_TABLE_SIZE :: 4096

// MAX_INTEGER bounds decoded prefix integers. Every HPACK integer is a length,
// an index or a table size, none of which may legitimately exceed this.
MAX_INTEGER :: 1 << 30

Header_Field :: struct {
	name:  string,
	value: string,
}

Huffman_Code :: struct {
	code: u32, // LSB-aligned code bits
	len:  u32, // number of bits
}

Error :: enum u8 {
	None,
	// The block ended in the middle of a representation.
	Truncated,
	// A prefix integer exceeded MAX_INTEGER or used too many continuation octets.
	Integer_Overflow,
	// An index referred to neither the static nor the dynamic table (or was 0).
	Invalid_Index,
	// A Huffman string had invalid padding or contained EOS.
	Invalid_Huffman,
	// A dynamic table size update exceeded the allowed maximum, or appeared
	// after the first header field of a block.
	Invalid_Table_Size_Update,
	// The decoded header list exceeded the configured limit. This error is
	// not fatal for the compression context: the whole block was processed and
	// the dynamic table is still synchronised with the peer.
	Header_List_Too_Large,
	// The destination buffer could not hold the output.
	Buffer_Too_Small,
	// A memory allocation failed.
	Out_Of_Memory,
}

// is_fatal reports whether err leaves the compression context unusable, which
// in HTTP/2 must be treated as a connection error of type COMPRESSION_ERROR.
is_fatal :: proc "contextless" (err: Error) -> bool {
	return err != .None && err != .Header_List_Too_Large
}

// Indexing controls how a literal header field is represented (RFC 7541 §6.2).
Indexing :: enum u8 {
	// Literal with incremental indexing: added to the dynamic table.
	Incremental,
	// Literal without indexing: not added, but intermediaries may re-index it.
	Without,
	// Literal never indexed: for sensitive values such as credentials.
	Never,
}

// entry_size returns the table size accounted for a header field.
entry_size :: proc "contextless" (name, value: string) -> int {
	return len(name) + len(value) + ENTRY_OVERHEAD
}
