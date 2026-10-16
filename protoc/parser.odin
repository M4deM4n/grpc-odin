package protoc

import "core:strings"

// Parser is a recursive-descent parser for the .proto language
// (https://protobuf.dev/reference/protobuf/proto3-spec/ and proto2-spec).
// It stops at the first syntax error in a file: parse errors are almost
// always cascading, and one precise message beats a page of noise.
Parser :: struct {
	lex:       Lexer,
	tok:       Token,
	file:      ^File,
	diags:     ^Diagnostics,
	allocator: Allocator,
	failed:    bool,
	depth:     int,
}

// MAX_NESTING bounds message nesting in .proto sources, protecting the
// recursive-descent parser's stack.
MAX_NESTING :: 64

// parse_file parses one .proto source. On syntax errors the diagnostics are
// populated and the partially built File is returned.
parse_file :: proc(path, src: string, diags: ^Diagnostics, allocator: Allocator) -> ^File {
	p := Parser {
		diags     = diags,
		allocator = allocator,
	}
	lexer_init(&p.lex, path, src, diags, allocator)
	p.file = new(File, allocator)
	p.file.path = path
	p.file.syntax = .Proto2 // the default when no syntax statement is present
	init_file(p.file, allocator)
	next(&p)
	parse_top_level(&p)
	return p.file
}

@(private = "file")
init_file :: proc(f: ^File, a: Allocator) {
	f.imports = make([dynamic]Import, a)
	f.messages = make([dynamic]^Message, a)
	f.enums = make([dynamic]^Enum, a)
	f.services = make([dynamic]^Service, a)
}

// -----------------------------------------------------------------------------
// Token helpers
// -----------------------------------------------------------------------------

@(private = "file")
next :: proc(p: ^Parser) {
	p.tok = next_token(&p.lex)
}

@(private = "file")
fail :: proc(p: ^Parser, format: string, args: ..any) -> bool {
	if !p.failed {
		error_at(p.diags, p.tok.pos, format, ..args)
		p.failed = true
	}
	return false
}

@(private = "file")
describe :: proc(t: Token) -> string {
	switch t.kind {
	case .EOF:
		return "end of file"
	case .String:
		return "string literal"
	case .Ident, .Int, .Float, .Symbol:
		return t.text
	}
	return "?"
}

@(private = "file")
is_symbol :: proc(p: ^Parser, s: string) -> bool {
	return p.tok.kind == .Symbol && p.tok.text == s
}

@(private = "file")
is_keyword :: proc(p: ^Parser, kw: string) -> bool {
	return p.tok.kind == .Ident && p.tok.text == kw
}

@(private = "file")
accept_symbol :: proc(p: ^Parser, s: string) -> bool {
	if is_symbol(p, s) {
		next(p)
		return true
	}
	return false
}

@(private = "file")
expect_symbol :: proc(p: ^Parser, s: string) -> bool {
	if p.failed {
		return false
	}
	if accept_symbol(p, s) {
		return true
	}
	return fail(p, "expected '%s', found '%s'", s, describe(p.tok))
}

@(private = "file")
expect_keyword :: proc(p: ^Parser, kw: string) -> bool {
	if p.failed {
		return false
	}
	if is_keyword(p, kw) {
		next(p)
		return true
	}
	return fail(p, "expected '%s', found '%s'", kw, describe(p.tok))
}

@(private = "file")
expect_ident :: proc(p: ^Parser, what: string) -> (name: string, pos: Pos, ok: bool) {
	if p.failed {
		return
	}
	if p.tok.kind != .Ident {
		fail(p, "expected %s, found '%s'", what, describe(p.tok))
		return
	}
	name, pos = p.tok.text, p.tok.pos
	next(p)
	return name, pos, true
}

@(private = "file")
expect_name :: proc(p: ^Parser, what: string) -> (name: string, ok: bool) {
	name, _ = expect_ident(p, what) or_return
	return name, true
}

// expect_string parses one or more adjacent string literals.
@(private = "file")
expect_string :: proc(p: ^Parser, what: string) -> (s: string, ok: bool) {
	if p.failed {
		return
	}
	if p.tok.kind != .String {
		fail(p, "expected %s, found '%s'", what, describe(p.tok))
		return
	}
	s = p.tok.text
	next(p)
	for p.tok.kind == .String {
		s = strings.concatenate({s, p.tok.text}, p.allocator)
		next(p)
	}
	return s, true
}

// full_ident parses `ident { "." ident }`.
@(private = "file")
full_ident :: proc(p: ^Parser, what: string) -> (name: string, ok: bool) {
	first := expect_name(p, what) or_return
	if !is_symbol(p, ".") {
		return first, true
	}
	b := strings.builder_make(p.allocator)
	strings.write_string(&b, first)
	for accept_symbol(p, ".") {
		part := expect_name(p, what) or_return
		strings.write_byte(&b, '.')
		strings.write_string(&b, part)
	}
	return strings.to_string(b), true
}

// type_name parses `[ "." ] full_ident`.
@(private = "file")
type_name :: proc(p: ^Parser) -> (name: string, ok: bool) {
	if accept_symbol(p, ".") {
		rest := full_ident(p, "type name") or_return
		return strings.concatenate({".", rest}, p.allocator), true
	}
	return full_ident(p, "type name")
}

// -----------------------------------------------------------------------------
// Constants and options
// -----------------------------------------------------------------------------

Constant :: struct {
	kind: enum u8 {
		Ident, // identifier, true, false, inf, nan, enum value name
		Int, // integer; text includes a leading '-' if negative
		Float,
		String,
		Aggregate, // text-format message literal, skipped
	},
	text: string,
	pos:  Pos,
}

@(private = "file")
parse_constant :: proc(p: ^Parser) -> (c: Constant, ok: bool) {
	if p.failed {
		return
	}
	c.pos = p.tok.pos
	if p.tok.kind == .String {
		c.kind = .String
		c.text = expect_string(p, "string") or_return
		return c, true
	}
	if is_symbol(p, "{") {
		c.kind = .Aggregate
		depth := 0
		for {
			if p.tok.kind == .EOF {
				return c, fail(p, "unterminated aggregate value")
			}
			if is_symbol(p, "{") {
				depth += 1
			} else if is_symbol(p, "}") {
				depth -= 1
				if depth == 0 {
					next(p)
					return c, true
				}
			}
			next(p)
		}
	}
	negative := false
	if is_symbol(p, "-") || is_symbol(p, "+") {
		negative = p.tok.text == "-"
		next(p)
	}
	#partial switch p.tok.kind {
	case .Int:
		c.kind = .Int
	case .Float:
		c.kind = .Float
	case .Ident:
		c.kind = .Ident
		if negative && p.tok.text != "inf" && p.tok.text != "nan" {
			return c, fail(p, "expected number after '-', found '%s'", p.tok.text)
		}
		if !negative {
			c.text = full_ident(p, "constant") or_return
			return c, true
		}
		c.kind = .Float
	case:
		return c, fail(p, "expected constant, found '%s'", describe(p.tok))
	}
	c.text = strings.concatenate({"-", p.tok.text}, p.allocator) if negative else p.tok.text
	next(p)
	return c, true
}

// option_name parses `( "(" full_ident ")" | ident ) { "." ( "(" full_ident ")" | ident ) }`.
@(private = "file")
option_name :: proc(p: ^Parser) -> (name: string, ok: bool) {
	b := strings.builder_make(p.allocator)
	for {
		if accept_symbol(p, "(") {
			strings.write_byte(&b, '(')
			n := type_name(p) or_return
			strings.write_string(&b, n)
			expect_symbol(p, ")") or_return
			strings.write_byte(&b, ')')
		} else {
			n := expect_name(p, "option name") or_return
			strings.write_string(&b, n)
		}
		if !accept_symbol(p, ".") {
			break
		}
		strings.write_byte(&b, '.')
	}
	return strings.to_string(b), true
}

Option :: struct {
	name:  string,
	value: Constant,
}

// option_body parses `name "=" constant` (after the `option` keyword or
// inside a `[...]` list).
@(private = "file")
option_body :: proc(p: ^Parser) -> (o: Option, ok: bool) {
	o.name = option_name(p) or_return
	expect_symbol(p, "=") or_return
	o.value = parse_constant(p) or_return
	return o, true
}

// option_statement parses `option name = constant ;`.
@(private = "file")
option_statement :: proc(p: ^Parser) -> (o: Option, ok: bool) {
	expect_keyword(p, "option") or_return
	o = option_body(p) or_return
	expect_symbol(p, ";") or_return
	return o, true
}

@(private = "file")
bool_option :: proc(p: ^Parser, o: Option) -> (value: bool, ok: bool) {
	if o.value.kind == .Ident {
		switch o.value.text {
		case "true":
			return true, true
		case "false":
			return false, true
		}
	}
	error_at(p.diags, o.value.pos, "option '%s' requires a boolean value", o.name)
	p.failed = true
	return false, false
}

// field_options parses `[ option { "," option } ]` if present.
@(private = "file")
field_options :: proc(p: ^Parser, f: ^Field) -> bool {
	if !accept_symbol(p, "[") {
		return true
	}
	for {
		o := option_body(p) or_return
		switch o.name {
		case "packed":
			f.packed = bool_option(p, o) or_return
		case "deprecated":
			f.deprecated = bool_option(p, o) or_return
		case "default":
			if p.file.syntax == .Proto3 {
				error_at(p.diags, o.value.pos, "explicit default values are not allowed in proto3")
			}
			f.default_value = o.value
		// Other options (json_name, ctype, lazy, custom options...) do not
		// affect the generated code.
		}
		if !accept_symbol(p, ",") {
			break
		}
	}
	return expect_symbol(p, "]")
}

// -----------------------------------------------------------------------------
// Top level
// -----------------------------------------------------------------------------

@(private = "file")
parse_top_level :: proc(p: ^Parser) {
	first := true
	for !p.failed && p.tok.kind != .EOF {
		if accept_symbol(p, ";") {
			continue
		}
		if p.tok.kind != .Ident {
			fail(p, "expected top-level statement, found '%s'", describe(p.tok))
			return
		}
		switch p.tok.text {
		case "syntax":
			if !first {
				fail(p, "the syntax statement must be the first statement in the file")
				return
			}
			next(p)
			expect_symbol(p, "=") or_break
			pos := p.tok.pos
			s := expect_string(p, "syntax string") or_break
			switch s {
			case "proto2":
				p.file.syntax = .Proto2
			case "proto3":
				p.file.syntax = .Proto3
			case:
				error_at(p.diags, pos, "unrecognized syntax %q (expected \"proto2\" or \"proto3\")", s)
				p.failed = true
				return
			}
			expect_symbol(p, ";")
		case "edition":
			fail(p, "protobuf editions are not supported; use syntax = \"proto2\" or \"proto3\"")
			return
		case "package":
			if p.file.package_name != "" {
				fail(p, "multiple package statements")
				return
			}
			next(p)
			p.file.package_name = full_ident(p, "package name") or_break
			expect_symbol(p, ";")
		case "import":
			imp := Import {
				pos = p.tok.pos,
			}
			next(p)
			if is_keyword(p, "public") {
				imp.public = true
				next(p)
			} else if is_keyword(p, "weak") {
				imp.weak = true
				next(p)
			}
			imp.path = expect_string(p, "import path") or_break
			expect_symbol(p, ";") or_break
			append(&p.file.imports, imp)
		case "option":
			option_statement(p)
		case "message":
			m := parse_message(p, nil) or_break
			append(&p.file.messages, m)
		case "enum":
			e := parse_enum(p, nil) or_break
			append(&p.file.enums, e)
		case "service":
			s := parse_service(p) or_break
			append(&p.file.services, s)
		case "extend":
			parse_extend(p)
		case:
			fail(p, "unexpected '%s' at top level", p.tok.text)
			return
		}
		first = false
	}
}

// -----------------------------------------------------------------------------
// Messages
// -----------------------------------------------------------------------------

@(private = "file")
new_message :: proc(p: ^Parser, name: string, pos: Pos, parent: ^Message) -> ^Message {
	a := p.allocator
	m := new(Message, a)
	m.name = name
	m.pos = pos
	m.file = p.file
	m.parent = parent
	m.fields = make([dynamic]^Field, a)
	m.oneofs = make([dynamic]^Oneof, a)
	m.messages = make([dynamic]^Message, a)
	m.enums = make([dynamic]^Enum, a)
	m.reserved_ranges = make([dynamic]Range, a)
	m.reserved_names = make([dynamic]string, a)
	return m
}

@(private = "file")
parse_message :: proc(p: ^Parser, parent: ^Message) -> (m: ^Message, ok: bool) {
	expect_keyword(p, "message") or_return
	if p.depth >= MAX_NESTING {
		return nil, fail(p, "messages nested more than %d levels deep", MAX_NESTING)
	}
	p.depth += 1
	defer p.depth -= 1
	name, pos := expect_ident(p, "message name") or_return
	m = new_message(p, name, pos, parent)
	expect_symbol(p, "{") or_return
	parse_message_body(p, m) or_return
	return m, true
}

@(private = "file")
parse_message_body :: proc(p: ^Parser, m: ^Message) -> bool {
	for !p.failed {
		if accept_symbol(p, "}") {
			return true
		}
		if accept_symbol(p, ";") {
			continue
		}
		if is_symbol(p, ".") {
			// A field whose type is fully qualified (".pkg.Type name = 1;").
			f := parse_field(p, m, nil) or_return
			append(&m.fields, f)
			continue
		}
		if p.tok.kind != .Ident {
			return fail(p, "expected message element, found '%s'", describe(p.tok))
		}
		switch p.tok.text {
		case "message":
			nested := parse_message(p, m) or_return
			append(&m.messages, nested)
		case "enum":
			e := parse_enum(p, m) or_return
			append(&m.enums, e)
		case "option":
			option_statement(p) or_return
		case "oneof":
			parse_oneof(p, m) or_return
		case "reserved":
			parse_reserved(p, &m.reserved_ranges, &m.reserved_names, MAX_FIELD) or_return
		case "extensions":
			// Extension ranges only matter for extensions, which are not
			// generated; parse and discard.
			next(p)
			for !p.failed && !is_symbol(p, ";") && p.tok.kind != .EOF {
				if is_symbol(p, "[") {
					skip_bracketed(p) or_return
				} else {
					next(p)
				}
			}
			expect_symbol(p, ";") or_return
		case "extend":
			parse_extend(p) or_return
		case:
			f := parse_field(p, m, nil) or_return
			append(&m.fields, f)
		}
	}
	return false
}

MAX_FIELD :: (1 << 29) - 1

@(private = "file")
parse_field :: proc(p: ^Parser, m: ^Message, oneof: ^Oneof) -> (f: ^Field, ok: bool) {
	f = new(Field, p.allocator)
	f.pos = p.tok.pos
	f.file = p.file
	f.oneof = oneof
	f.label = .Implicit
	has_label := false
	if oneof == nil {
		switch p.tok.text {
		case "optional":
			f.label = .Optional
			has_label = true
			next(p)
		case "required":
			f.label = .Required
			has_label = true
			next(p)
		case "repeated":
			f.label = .Repeated
			has_label = true
			next(p)
		}
	}

	if is_keyword(p, "group") {
		return nil, fail(p, "groups are not supported (deprecated proto2 feature)")
	}

	if is_keyword(p, "map") {
		// "map" is only a keyword when followed by "<".
		save_lex, save_tok := p.lex, p.tok
		next(p)
		if is_symbol(p, "<") {
			next(p)
			if has_label {
				return nil, fail(p, "map fields cannot have a label")
			}
			if oneof != nil {
				return nil, fail(p, "map fields are not allowed in oneofs")
			}
			f.is_map = true
			f.label = .Repeated
			key_pos := p.tok.pos
			key_name := expect_name(p, "map key type") or_return
			f.map_key = scalar_from_name(key_name)
			if f.map_key == .None || f.map_key == .Double || f.map_key == .Float || f.map_key == .Bytes {
				error_at(p.diags, key_pos, "invalid map key type '%s'", key_name)
				p.failed = true
				return nil, false
			}
			expect_symbol(p, ",") or_return
			f.map_value = parse_type_ref(p) or_return
			expect_symbol(p, ">") or_return
		} else {
			p.lex, p.tok = save_lex, save_tok
		}
	}

	if !f.is_map {
		f.type = parse_type_ref(p) or_return
	}

	f.name, _ = expect_ident(p, "field name") or_return
	expect_symbol(p, "=") or_return
	if p.tok.kind != .Int {
		return nil, fail(p, "expected field number, found '%s'", describe(p.tok))
	}
	number, num_ok := parse_int_literal(p.tok.text)
	if !num_ok || number < 1 || number > MAX_FIELD {
		return nil, fail(p, "field number %s out of range (1 to %d)", p.tok.text, MAX_FIELD)
	}
	if number >= 19000 && number <= 19999 {
		return nil, fail(p, "field numbers 19000 through 19999 are reserved for the protobuf implementation")
	}
	f.number = u32(number)
	next(p)
	field_options(p, f) or_return
	expect_symbol(p, ";") or_return

	if p.file.syntax == .Proto2 && !has_label && oneof == nil && !f.is_map {
		error_at(p.diags, f.pos, "proto2 fields require a label (optional, required or repeated)")
	}
	if p.file.syntax == .Proto3 && f.label == .Required {
		error_at(p.diags, f.pos, "required fields are not allowed in proto3")
	}
	if p.file.syntax == .Proto2 && f.label == .Optional {
		// In proto2 `optional` is the explicit-presence default.
		f.label = .Optional
	} else if p.file.syntax == .Proto2 && f.label == .Implicit {
		// Oneof members and other unlabelled proto2 fields track presence.
		f.label = .Optional
	}
	return f, true
}

@(private = "file")
parse_type_ref :: proc(p: ^Parser) -> (t: Type_Ref, ok: bool) {
	if p.tok.kind == .Ident {
		if s := scalar_from_name(p.tok.text); s != .None {
			// A scalar name followed by "." would be a qualified message name
			// such as "string.Foo", which no sane schema uses; treat scalars
			// as reserved.
			next(p)
			return {scalar = s}, true
		}
	}
	t.name = type_name(p) or_return
	return t, true
}

@(private = "file")
parse_oneof :: proc(p: ^Parser, m: ^Message) -> bool {
	expect_keyword(p, "oneof") or_return
	o := new(Oneof, p.allocator)
	o.pos = p.tok.pos
	o.fields = make([dynamic]^Field, p.allocator)
	o.name = expect_name(p, "oneof name") or_return
	expect_symbol(p, "{") or_return
	for !p.failed {
		if accept_symbol(p, "}") {
			break
		}
		if accept_symbol(p, ";") {
			continue
		}
		if is_keyword(p, "option") {
			option_statement(p) or_return
			continue
		}
		if is_keyword(p, "optional") || is_keyword(p, "required") || is_keyword(p, "repeated") {
			return fail(p, "oneof fields cannot have labels")
		}
		f := parse_field(p, m, o) or_return
		f.label = .Optional
		append(&o.fields, f)
		append(&m.fields, f)
	}
	if p.failed {
		return false
	}
	if len(o.fields) == 0 {
		error_at(p.diags, o.pos, "oneof '%s' must have at least one field", o.name)
	}
	append(&m.oneofs, o)
	return true
}

// parse_reserved parses `reserved` ranges or names.
@(private = "file")
parse_reserved :: proc(p: ^Parser, ranges: ^[dynamic]Range, names: ^[dynamic]string, max_value: i64) -> bool {
	expect_keyword(p, "reserved") or_return
	if p.tok.kind == .String {
		for {
			s := expect_string(p, "reserved name") or_return
			append(names, s)
			if !accept_symbol(p, ",") {
				break
			}
		}
		return expect_symbol(p, ";")
	}
	for {
		lo := reserved_number(p, max_value) or_return
		hi := lo
		if is_keyword(p, "to") {
			next(p)
			if is_keyword(p, "max") {
				next(p)
				hi = max_value
			} else {
				hi = reserved_number(p, max_value) or_return
			}
		}
		if hi < lo {
			return fail(p, "reserved range end is before its start")
		}
		append(ranges, Range{lo, hi})
		if !accept_symbol(p, ",") {
			break
		}
	}
	return expect_symbol(p, ";")
}

@(private = "file")
reserved_number :: proc(p: ^Parser, max_value: i64) -> (v: i64, ok: bool) {
	negative := accept_symbol(p, "-")
	if p.tok.kind != .Int {
		fail(p, "expected number in reserved range, found '%s'", describe(p.tok))
		return
	}
	u, u_ok := parse_int_literal(p.tok.text)
	if !u_ok || u > u64(max(i64)) {
		fail(p, "reserved number out of range")
		return
	}
	v = -i64(u) if negative else i64(u)
	if v > max_value {
		fail(p, "reserved number out of range")
		return
	}
	next(p)
	return v, true
}

@(private = "file")
skip_bracketed :: proc(p: ^Parser) -> bool {
	depth := 0
	for p.tok.kind != .EOF {
		if is_symbol(p, "[") {
			depth += 1
		} else if is_symbol(p, "]") {
			depth -= 1
			if depth == 0 {
				next(p)
				return true
			}
		}
		next(p)
	}
	return fail(p, "unterminated '['")
}

// parse_extend parses and discards an `extend` block. Extensions (other than
// custom options, which have no runtime effect) are not supported by the
// generator; the declaration is accepted so that common option-defining
// files still parse.
@(private = "file")
parse_extend :: proc(p: ^Parser) -> bool {
	expect_keyword(p, "extend") or_return
	type_name(p) or_return
	expect_symbol(p, "{") or_return
	depth := 1
	for p.tok.kind != .EOF {
		if is_symbol(p, "{") {
			depth += 1
		} else if is_symbol(p, "}") {
			depth -= 1
			if depth == 0 {
				next(p)
				return true
			}
		}
		next(p)
	}
	return fail(p, "unterminated extend block")
}

// -----------------------------------------------------------------------------
// Enums
// -----------------------------------------------------------------------------

@(private = "file")
parse_enum :: proc(p: ^Parser, parent: ^Message) -> (e: ^Enum, ok: bool) {
	expect_keyword(p, "enum") or_return
	a := p.allocator
	e = new(Enum, a)
	e.pos = p.tok.pos
	e.file = p.file
	e.parent = parent
	e.values = make([dynamic]Enum_Value, a)
	e.reserved_ranges = make([dynamic]Range, a)
	e.reserved_names = make([dynamic]string, a)
	e.name = expect_name(p, "enum name") or_return
	expect_symbol(p, "{") or_return
	for !p.failed {
		if accept_symbol(p, "}") {
			break
		}
		if accept_symbol(p, ";") {
			continue
		}
		if is_keyword(p, "option") {
			o := option_statement(p) or_return
			if o.name == "allow_alias" {
				e.allow_alias = bool_option(p, o) or_return
			}
			continue
		}
		if is_keyword(p, "reserved") {
			parse_reserved(p, &e.reserved_ranges, &e.reserved_names, i64(max(i32))) or_return
			continue
		}
		v: Enum_Value
		v.name, v.pos = expect_ident(p, "enum value name") or_return
		expect_symbol(p, "=") or_return
		negative := accept_symbol(p, "-")
		if p.tok.kind != .Int {
			return nil, fail(p, "expected enum value number, found '%s'", describe(p.tok))
		}
		u, u_ok := parse_int_literal(p.tok.text)
		limit: u64 = u64(max(i32)) + 1 if negative else u64(max(i32))
		if !u_ok || u > limit {
			return nil, fail(p, "enum value %s is out of int32 range", p.tok.text)
		}
		v.number = i32(-i64(u)) if negative else i32(u)
		next(p)
		if accept_symbol(p, "[") {
			for {
				option_body(p) or_return
				if !accept_symbol(p, ",") {
					break
				}
			}
			expect_symbol(p, "]") or_return
		}
		expect_symbol(p, ";") or_return
		append(&e.values, v)
	}
	if p.failed {
		return nil, false
	}
	if len(e.values) == 0 {
		error_at(p.diags, e.pos, "enum '%s' must have at least one value", e.name)
	}
	return e, true
}

// -----------------------------------------------------------------------------
// Services
// -----------------------------------------------------------------------------

@(private = "file")
parse_service :: proc(p: ^Parser) -> (s: ^Service, ok: bool) {
	expect_keyword(p, "service") or_return
	s = new(Service, p.allocator)
	s.pos = p.tok.pos
	s.file = p.file
	s.methods = make([dynamic]^Method, p.allocator)
	s.name = expect_name(p, "service name") or_return
	expect_symbol(p, "{") or_return
	for !p.failed {
		if accept_symbol(p, "}") {
			break
		}
		if accept_symbol(p, ";") {
			continue
		}
		if is_keyword(p, "option") {
			option_statement(p) or_return
			continue
		}
		if !is_keyword(p, "rpc") {
			return nil, fail(p, "expected 'rpc' or 'option' in service, found '%s'", describe(p.tok))
		}
		next(p)
		m := new(Method, p.allocator)
		m.name, m.pos = expect_ident(p, "method name") or_return
		m.client_streaming, m.input = method_type(p) or_return
		expect_keyword(p, "returns") or_return
		m.server_streaming, m.output = method_type(p) or_return
		if accept_symbol(p, "{") {
			for !p.failed && !accept_symbol(p, "}") {
				if accept_symbol(p, ";") {
					continue
				}
				option_statement(p) or_return
			}
		} else {
			expect_symbol(p, ";") or_return
		}
		append(&s.methods, m)
	}
	if p.failed {
		return nil, false
	}
	return s, true
}

// method_type parses `"(" [ "stream" ] message_type ")"`.
@(private = "file")
method_type :: proc(p: ^Parser) -> (streaming: bool, t: Type_Ref, ok: bool) {
	expect_symbol(p, "(") or_return
	if is_keyword(p, "stream") {
		// "stream" could also be a message type named `stream`.
		save_lex, save_tok := p.lex, p.tok
		next(p)
		if is_symbol(p, ")") {
			p.lex, p.tok = save_lex, save_tok
		} else {
			streaming = true
		}
	}
	pos := p.tok.pos
	t = parse_type_ref(p) or_return
	if t.scalar != .None {
		error_at(p.diags, pos, "method input and output types must be messages")
		p.failed = true
		return
	}
	expect_symbol(p, ")") or_return
	return streaming, t, true
}
