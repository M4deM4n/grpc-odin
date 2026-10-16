package protoc

import "core:strings"

Pos :: struct {
	file:   string,
	line:   int,
	column: int,
}

Token_Kind :: enum u8 {
	EOF,
	Ident, // identifiers and keywords (keywords are contextual in .proto)
	Int, // decimal, hex or octal integer literal (sign excluded)
	Float, // floating point literal, including "inf" / "nan" in value context
	String, // decoded string literal (adjacent literals are concatenated)
	Symbol, // single punctuation character
}

Token :: struct {
	kind: Token_Kind,
	text: string, // source text; for String the decoded value
	pos:  Pos,
}

Lexer :: struct {
	src:       string,
	file:      string,
	offset:    int,
	line:      int,
	col:       int,
	allocator: Allocator,
	err:       ^Diagnostics,
}

lexer_init :: proc(l: ^Lexer, file, src: string, diags: ^Diagnostics, allocator: Allocator) {
	l^ = {src = src, file = file, line = 1, col = 1, allocator = allocator, err = diags}
}

@(private = "file")
peek_byte :: #force_inline proc(l: ^Lexer, ahead := 0) -> u8 {
	i := l.offset + ahead
	return l.src[i] if i < len(l.src) else 0
}

@(private = "file")
advance :: proc(l: ^Lexer) -> u8 {
	c := l.src[l.offset]
	l.offset += 1
	if c == '\n' {
		l.line += 1
		l.col = 1
	} else {
		l.col += 1
	}
	return c
}

@(private = "file")
skip_space_and_comments :: proc(l: ^Lexer) {
	for l.offset < len(l.src) {
		c := peek_byte(l)
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v':
			advance(l)
		case c == '/' && peek_byte(l, 1) == '/':
			for l.offset < len(l.src) && peek_byte(l) != '\n' {
				advance(l)
			}
		case c == '/' && peek_byte(l, 1) == '*':
			start := Pos{l.file, l.line, l.col}
			advance(l)
			advance(l)
			closed := false
			for l.offset < len(l.src) {
				if peek_byte(l) == '*' && peek_byte(l, 1) == '/' {
					advance(l)
					advance(l)
					closed = true
					break
				}
				advance(l)
			}
			if !closed {
				error_at(l.err, start, "unterminated block comment")
			}
		case:
			return
		}
	}
}

is_ident_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_ident_char :: proc(c: u8) -> bool {
	return is_ident_start(c) || is_digit(c)
}

// next_token scans the next token. Errors are reported to the diagnostics
// and scanning continues, so that several errors can be reported at once.
next_token :: proc(l: ^Lexer) -> Token {
	skip_space_and_comments(l)
	pos := Pos{l.file, l.line, l.col}
	if l.offset >= len(l.src) {
		return {kind = .EOF, pos = pos}
	}
	start := l.offset
	c := peek_byte(l)

	switch {
	case is_ident_start(c):
		for l.offset < len(l.src) && is_ident_char(peek_byte(l)) {
			advance(l)
		}
		return {kind = .Ident, text = l.src[start:l.offset], pos = pos}

	case is_digit(c) || (c == '.' && is_digit(peek_byte(l, 1))):
		return scan_number(l, pos)

	case c == '"' || c == '\'':
		return scan_string(l, pos)
	}

	advance(l)
	return {kind = .Symbol, text = l.src[start:l.offset], pos = pos}
}

@(private = "file")
scan_number :: proc(l: ^Lexer, pos: Pos) -> Token {
	start := l.offset
	is_float := false
	if peek_byte(l) == '0' && (peek_byte(l, 1) == 'x' || peek_byte(l, 1) == 'X') {
		advance(l)
		advance(l)
		digits := 0
		for l.offset < len(l.src) && is_hex_digit(peek_byte(l)) {
			advance(l)
			digits += 1
		}
		if digits == 0 {
			error_at(l.err, pos, "malformed hexadecimal literal")
		}
	} else {
		for l.offset < len(l.src) && is_digit(peek_byte(l)) {
			advance(l)
		}
		if peek_byte(l) == '.' {
			is_float = true
			advance(l)
			for l.offset < len(l.src) && is_digit(peek_byte(l)) {
				advance(l)
			}
		}
		if peek_byte(l) == 'e' || peek_byte(l) == 'E' {
			is_float = true
			advance(l)
			if peek_byte(l) == '+' || peek_byte(l) == '-' {
				advance(l)
			}
			exp_digits := 0
			for l.offset < len(l.src) && is_digit(peek_byte(l)) {
				advance(l)
				exp_digits += 1
			}
			if exp_digits == 0 {
				error_at(l.err, pos, "malformed exponent in float literal")
			}
		}
	}
	// protoc accepts an "f" suffix on float literals.
	if is_float && (peek_byte(l) == 'f' || peek_byte(l) == 'F') {
		advance(l)
	}
	if l.offset < len(l.src) && is_ident_char(peek_byte(l)) {
		error_at(l.err, pos, "invalid character %q after number", rune(peek_byte(l)))
		for l.offset < len(l.src) && is_ident_char(peek_byte(l)) {
			advance(l)
		}
	}
	return {kind = .Float if is_float else .Int, text = l.src[start:l.offset], pos = pos}
}

is_hex_digit :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

@(private = "file")
hex_value :: proc(c: u8) -> u32 {
	switch c {
	case '0' ..= '9':
		return u32(c - '0')
	case 'a' ..= 'f':
		return u32(c - 'a' + 10)
	case 'A' ..= 'F':
		return u32(c - 'A' + 10)
	}
	return 0
}

// scan_string scans one quoted string literal, decoding escapes.
@(private = "file")
scan_string :: proc(l: ^Lexer, pos: Pos) -> Token {
	quote := advance(l)
	b := strings.builder_make(l.allocator)
	for {
		if l.offset >= len(l.src) || peek_byte(l) == '\n' {
			error_at(l.err, pos, "unterminated string literal")
			break
		}
		c := advance(l)
		if c == quote {
			break
		}
		if c != '\\' {
			strings.write_byte(&b, c)
			continue
		}
		if l.offset >= len(l.src) {
			error_at(l.err, pos, "unterminated string literal")
			break
		}
		e := advance(l)
		switch e {
		case 'a':
			strings.write_byte(&b, '\a')
		case 'b':
			strings.write_byte(&b, '\b')
		case 'f':
			strings.write_byte(&b, '\f')
		case 'n':
			strings.write_byte(&b, '\n')
		case 'r':
			strings.write_byte(&b, '\r')
		case 't':
			strings.write_byte(&b, '\t')
		case 'v':
			strings.write_byte(&b, '\v')
		case '\\', '\'', '"', '?':
			strings.write_byte(&b, e)
		case 'x', 'X':
			v: u32 = 0
			n := 0
			for n < 2 && is_hex_digit(peek_byte(l)) {
				v = v * 16 + hex_value(advance(l))
				n += 1
			}
			if n == 0 {
				error_at(l.err, pos, "invalid \\x escape in string literal")
			}
			strings.write_byte(&b, u8(v))
		case '0' ..= '7':
			v := u32(e - '0')
			n := 1
			for n < 3 && peek_byte(l) >= '0' && peek_byte(l) <= '7' {
				v = v * 8 + u32(advance(l) - '0')
				n += 1
			}
			if v > 255 {
				error_at(l.err, pos, "octal escape out of range in string literal")
			}
			strings.write_byte(&b, u8(v))
		case 'u', 'U':
			want := 4 if e == 'u' else 8
			v: u32 = 0
			for _ in 0 ..< want {
				if !is_hex_digit(peek_byte(l)) {
					error_at(l.err, pos, "invalid \\%c escape in string literal", rune(e))
					break
				}
				v = v * 16 + hex_value(advance(l))
			}
			if v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff) {
				error_at(l.err, pos, "invalid unicode code point in string literal")
			} else {
				strings.write_rune(&b, rune(v))
			}
		case:
			error_at(l.err, pos, "invalid escape sequence \\%c", rune(e))
		}
	}
	return {kind = .String, text = strings.to_string(b), pos = pos}
}

// parse_int_literal converts an Int token (decimal, 0x hex or 0 octal).
// Returns ok = false for malformed literals and for values above max(u64).
parse_int_literal :: proc(text: string) -> (value: u64, ok: bool) {
	base: u64 = 10
	digits := text
	if len(text) > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') {
		base, digits = 16, text[2:]
	} else if len(text) > 1 && text[0] == '0' {
		base, digits = 8, text[1:]
	}
	if len(digits) == 0 {
		return 0, false
	}
	for i in 0 ..< len(digits) {
		c := digits[i]
		d: u64
		switch c {
		case '0' ..= '9':
			d = u64(c - '0')
		case 'a' ..= 'f':
			d = u64(c - 'a' + 10)
		case 'A' ..= 'F':
			d = u64(c - 'A' + 10)
		case:
			return 0, false
		}
		if d >= base || value > (max(u64) - d) / base {
			return 0, false
		}
		value = value * base + d
	}
	return value, true
}
