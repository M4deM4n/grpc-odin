// gen_hpack_tables regenerates hpack/tables_generated.odin from the text of
// RFC 7541 (https://www.rfc-editor.org/rfc/rfc7541.txt).
//
// Usage:
//     odin run tools/gen_hpack_tables -- <rfc7541.txt> <output.odin>
//
// The static table (Appendix A) and the Huffman code (Appendix B) are parsed
// straight from the RFC so that no table entry is ever transcribed by hand.
// The generator also validates that the Huffman code is complete and
// canonical, which the decoder in hpack/huffman.odin relies on.
package gen_hpack_tables

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

HUFFMAN_SYMBOLS :: 257
STATIC_ENTRIES :: 61
MAX_CODE_LEN :: 30

Code :: struct {
	code: u32,
	len:  u32,
}

Static_Entry :: struct {
	name:  string,
	value: string,
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: gen_hpack_tables <rfc7541.txt> <output.odin>")
		os.exit(2)
	}
	data, read_err := os.read_entire_file(os.args[1], context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: cannot read %s: %v", os.args[1], read_err)
		os.exit(1)
	}
	text := string(data)

	static_section := section(text, "Appendix A.  Static Table Definition", "Appendix B.  Huffman Code")
	huffman_section := section(text, "Appendix B.  Huffman Code", "Appendix C.  Examples")

	statics := parse_static_table(static_section)
	codes := parse_huffman(huffman_section)
	validate_canonical(&codes)

	out := emit(&statics, &codes)
	if write_err := os.write_entire_file(os.args[2], transmute([]u8)out); write_err != nil {
		fmt.eprintfln("error: cannot write %s: %v", os.args[2], write_err)
		os.exit(1)
	}
	fmt.printfln("wrote %s", os.args[2])
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("error: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

// section returns the text between the line that starts with `start` and the
// line that starts with `end` (both at column 0, which skips the TOC entries).
section :: proc(text, start, end: string) -> string {
	begin := -1
	offset := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_start := offset
		offset += len(line) + 1
		if begin < 0 {
			if strings.has_prefix(line, start) {
				begin = offset
			}
		} else if strings.has_prefix(line, end) {
			return text[begin:line_start]
		}
	}
	fail("section %q not found", start)
}

parse_static_table :: proc(text: string) -> (entries: [STATIC_ENTRIES]Static_Entry) {
	seen: [STATIC_ENTRIES]bool
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "|") {
			continue
		}
		cells := strings.split(trimmed, "|", context.temp_allocator)
		// "| 1 | :authority | |" splits into ["", " 1 ", " :authority ", " ", ""].
		if len(cells) != 5 {
			continue
		}
		index, ok := strconv.parse_int(strings.trim_space(cells[1]), 10)
		if !ok {
			continue // header row
		}
		if index < 1 || index > STATIC_ENTRIES || seen[index - 1] {
			fail("bad static table index %d", index)
		}
		seen[index - 1] = true
		entries[index - 1] = {strings.trim_space(cells[2]), strings.trim_space(cells[3])}
	}
	for s, i in seen {
		if !s {
			fail("static table entry %d missing", i + 1)
		}
	}
	return
}

parse_huffman :: proc(text: string) -> (codes: [HUFFMAN_SYMBOLS]Code) {
	seen: [HUFFMAN_SYMBOLS]bool
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		// Rows look like: "    'a' ( 97)  |00011                     3  [ 5]"
		// The printable-symbol column may itself be "'('" or "'|'", so locate
		// the "(NNN)" group that is directly followed by the bit column.
		sym, bar, found := find_symbol(line)
		if !found {
			continue
		}
		fields := strings.fields(line[bar:], context.temp_allocator)
		// fields: [bits, hex, "[", "5]"] or [bits, hex, "[13]"]
		if len(fields) < 3 {
			fail("malformed huffman row: %q", line)
		}
		hex, hex_ok := strconv.parse_u64_of_base(fields[1], 16)
		length_text := strings.join(fields[2:], "", context.temp_allocator)
		length_text = strings.trim(length_text, "[]")
		length, len_ok := strconv.parse_int(length_text, 10)
		if !hex_ok || !len_ok || sym < 0 || sym >= HUFFMAN_SYMBOLS || seen[sym] {
			fail("malformed huffman row: %q", line)
		}
		if length < 5 || length > MAX_CODE_LEN || hex >= 1 << uint(length) {
			fail("huffman row out of range: %q", line)
		}
		seen[sym] = true
		codes[sym] = {u32(hex), u32(length)}
	}
	for s, i in seen {
		if !s {
			fail("huffman symbol %d missing", i)
		}
	}
	return
}

// find_symbol locates "(NNN)" followed by whitespace and '|' and returns the
// symbol number and the index of that '|'.
find_symbol :: proc(line: string) -> (sym: int, bar: int, ok: bool) {
	for open := 0; open < len(line); open += 1 {
		if line[open] != '(' {
			continue
		}
		close := strings.index_byte(line[open:], ')')
		if close < 0 {
			return
		}
		close += open
		n, n_ok := strconv.parse_int(strings.trim_space(line[open + 1:close]), 10)
		if !n_ok {
			continue
		}
		after := strings.trim_left_space(line[close + 1:])
		if !strings.has_prefix(after, "|") {
			continue
		}
		return n, len(line) - len(after), true
	}
	return
}

// validate_canonical checks that assigning codes in (length, symbol) order
// reproduces the RFC codes exactly, i.e. the code is canonical and complete.
validate_canonical :: proc(codes: ^[HUFFMAN_SYMBOLS]Code) {
	counts: [MAX_CODE_LEN + 1]u32
	for c in codes {
		counts[c.len] += 1
	}
	next: [MAX_CODE_LEN + 2]u64
	code: u64 = 0
	for l in 1 ..= MAX_CODE_LEN {
		next[l] = code
		code = (code + u64(counts[l])) << 1
	}
	// Complete code: the final shifted code value must equal 2^(MAX+1).
	if code != 1 << (MAX_CODE_LEN + 1) {
		fail("huffman code is not complete")
	}
	for sym in 0 ..< HUFFMAN_SYMBOLS {
		c := codes[sym]
		if u64(c.code) != next[c.len] {
			fail("huffman code is not canonical at symbol %d", sym)
		}
		next[c.len] += 1
	}
}

emit :: proc(statics: ^[STATIC_ENTRIES]Static_Entry, codes: ^[HUFFMAN_SYMBOLS]Code) -> string {
	counts: [MAX_CODE_LEN + 1]u32
	for c in codes {
		counts[c.len] += 1
	}
	first_code: [MAX_CODE_LEN + 1]u32
	offsets: [MAX_CODE_LEN + 1]u32
	limits: [MAX_CODE_LEN + 1]u64
	code: u64 = 0
	offset: u32 = 0
	for l in 1 ..= MAX_CODE_LEN {
		first_code[l] = u32(code)
		offsets[l] = offset
		limits[l] = (code + u64(counts[l])) << uint(32 - l)
		offset += counts[l]
		code = (code + u64(counts[l])) << 1
	}
	sorted: [dynamic]u16
	for l in 1 ..= MAX_CODE_LEN {
		for c, sym in codes {
			if int(c.len) == l {
				append(&sorted, u16(sym))
			}
		}
	}

	b := strings.builder_make()
	w :: strings.write_string
	w(&b, "// Code generated by tools/gen_hpack_tables from RFC 7541. DO NOT EDIT.\n\n")
	w(&b, "package hpack\n\n")

	w(&b, "// STATIC_TABLE is the HPACK static table (RFC 7541 Appendix A), 0-based.\n")
	w(&b, "@(rodata)\nSTATIC_TABLE := [STATIC_TABLE_LEN]Header_Field{\n")
	for e in statics {
		fmt.sbprintfln(&b, "\t{{%q, %q}},", e.name, e.value)
	}
	w(&b, "}\n\n")

	w(&b, "// HUFFMAN_CODES holds {code (LSB-aligned), bit length} per symbol; 256 is EOS.\n")
	w(&b, "@(rodata)\nHUFFMAN_CODES := [HUFFMAN_SYMBOLS]Huffman_Code{\n")
	for c, sym in codes {
		fmt.sbprintfln(&b, "\t{{0x%08x, %d}}, // %d", c.code, c.len, sym)
	}
	w(&b, "}\n\n")

	w(&b, "// HUFFMAN_SORTED_SYMBOLS lists symbols ordered by (code length, symbol).\n")
	w(&b, "@(rodata)\nHUFFMAN_SORTED_SYMBOLS := [HUFFMAN_SYMBOLS]u16{")
	for s, i in sorted {
		if i % 16 == 0 {
			w(&b, "\n\t")
		} else {
			w(&b, " ")
		}
		fmt.sbprintf(&b, "%d,", s)
	}
	w(&b, "\n}\n\n")

	w(&b, "// Per code length L: first canonical code, index of its first symbol in\n")
	w(&b, "// HUFFMAN_SORTED_SYMBOLS, and the exclusive upper bound of codes of length\n")
	w(&b, "// <= L when left-justified in 32 bits.\n")
	w(&b, "@(rodata)\nHUFFMAN_FIRST_CODE := [HUFFMAN_MAX_CODE_LEN + 1]u32{")
	for v in first_code {
		fmt.sbprintf(&b, "%d, ", v)
	}
	w(&b, "}\n\n@(rodata)\nHUFFMAN_OFFSET := [HUFFMAN_MAX_CODE_LEN + 1]u16{")
	for v in offsets {
		fmt.sbprintf(&b, "%d, ", v)
	}
	w(&b, "}\n\n@(rodata)\nHUFFMAN_LIMIT := [HUFFMAN_MAX_CODE_LEN + 1]u64{\n")
	for v, l in limits {
		fmt.sbprintfln(&b, "\t0x%09x, // %d", v, l)
	}
	w(&b, "}\n")
	return strings.to_string(b)
}
