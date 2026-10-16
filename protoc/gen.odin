package protoc

import "core:fmt"
import "core:slice"
import "core:strings"

Gen_Options :: struct {
	// Name of the generated Odin package.
	package_name:      string,
	// Import paths of the runtime packages.
	protobuf_import:   string,
	grpc_import:       string,
	// Generate gRPC client/server code for services.
	generate_services: bool,
}

DEFAULT_PROTOBUF_IMPORT :: "grpc:protobuf"
DEFAULT_GRPC_IMPORT :: "grpc:grpc"

// GROUPS_FILE_NAME holds the package-wide procedure groups. Per-proto files are
// "<stem>.pb.odin" with no dots in the stem, so it cannot collide.
GROUPS_FILE_NAME :: "package.groups.odin"

Output_File :: struct {
	name:    string,
	content: string,
}

Generator :: struct {
	c:                ^Compiler,
	opts:             Gen_Options,
	allocator:        Allocator,
	b:                strings.Builder,
	indent:           int,
	// Every package-level identifier emitted, to detect collisions.
	globals:          map[string]string,
	messages:         [dynamic]^Message,
	// Proto packages whose types keep unprefixed names.
	primary_packages: map[string]bool,
	// Escaped Odin names of enum values, by enum.
	enum_value_names: map[^Enum][]string,
	// Client stub procedure name per method (made unique, e.g. an RPC
	// named Register becomes <Svc>_register_ next to <Svc>_register).
	stub_names:       map[^Method]string,
}

// generate emits one Odin source file per loaded .proto file plus a file of
// package-wide procedure groups. All loaded files are generated into the
// same Odin package, so imported types are always available.
//
// Types keep their proto names (nested types joined with '_') when they
// belong to the package of an input file; types from other packages are
// prefixed with their package (google.protobuf.Timestamp becomes
// Google_Protobuf_Timestamp), which keeps imports from colliding.
generate :: proc(c: ^Compiler, opts: Gen_Options) -> (files: []Output_File, ok: bool) {
	g := Generator {
		c                = c,
		opts             = opts,
		allocator        = c.allocator,
		globals          = make(map[string]string, c.allocator),
		messages         = make([dynamic]^Message, c.allocator),
		primary_packages = make(map[string]bool, c.allocator),
		enum_value_names = make(map[^Enum][]string, c.allocator),
		stub_names       = make(map[^Method]string, c.allocator),
	}
	if g.opts.protobuf_import == "" {
		g.opts.protobuf_import = DEFAULT_PROTOBUF_IMPORT
	}
	if g.opts.grpc_import == "" {
		g.opts.grpc_import = DEFAULT_GRPC_IMPORT
	}
	if !is_valid_odin_identifier(g.opts.package_name) {
		error_at(&c.diags, {}, "invalid Odin package name '%s'", g.opts.package_name)
		return nil, false
	}
	inputs := c.inputs[:] if len(c.inputs) > 0 else c.order[:]
	for f in inputs {
		g.primary_packages[f.package_name] = true
	}

	reserve_global(&g, "pb", "the protobuf runtime import", {})
	reserve_global(&g, "grpc", "the grpc runtime import", {})
	for name in PROC_GROUPS {
		reserve_global(&g, name, "a generated procedure group", {})
	}
	for name in GENERATED_LOCALS {
		reserve_global(&g, name, "an identifier used inside generated procedures", {})
	}
	for f in c.order {
		assign_names(&g, f)
	}
	if has_errors(&c.diags) {
		return nil, false
	}

	out := make([dynamic]Output_File, c.allocator)
	names := make(map[string]string, c.allocator)
	for f in c.order {
		name := output_name(&g, f)
		// Compare case-insensitively: Windows and macOS file systems are.
		key := strings.to_lower(name, g.allocator)
		if prev, taken := names[key]; taken {
			error_at(&c.diags, {}, "'%s' and '%s' would both be generated as '%s'", prev, f.path, name)
			continue
		}
		names[key] = f.path
		append(&out, Output_File{name, gen_file(&g, f)})
	}
	if has_errors(&c.diags) {
		return nil, false
	}
	append(&out, Output_File{GROUPS_FILE_NAME, gen_groups(&g)})
	return out[:], true
}

@(private = "file")
output_name :: proc(g: ^Generator, f: ^File) -> string {
	stem := strings.trim_suffix(f.path, ".proto")
	b := strings.builder_make(g.allocator)
	for i in 0 ..< len(stem) {
		c := stem[i]
		strings.write_byte(&b, c if is_ident_char(c) else '_')
	}
	strings.write_string(&b, ".pb.odin")
	return strings.to_string(b)
}

// -----------------------------------------------------------------------------
// Naming
// -----------------------------------------------------------------------------

PROC_GROUPS := [?]string{"size", "marshal", "unmarshal", "destroy"}

// Parameter and local variable names used by generated procedures. Types
// with these names would be shadowed inside them, so they are rejected.
GENERATED_LOCALS := [?]string {
	"m", "d", "e", "n", "v", "k", "u", "ok", "old", "key", "value", "mark", "entry", "entry_mark",
	"entry_field", "entry_wire", "target", "is_set", "elem", "field", "wire", "tag_start",
	"counts", "count_specs", "allocator", "exists", "entry_done",
}

// Odin keywords and predeclared identifiers that cannot (or should not) be
// used as names; such field and enum value names get a trailing underscore,
// and such type names are rejected.
ODIN_RESERVED := [?]string {
	"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue",
	"defer", "distinct", "do", "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if",
	"import", "in", "map", "matrix", "not_in", "or_break", "or_continue", "or_else", "or_return",
	"package", "proc", "return", "struct", "switch", "transmute", "typeid", "union", "using",
	"when", "where", "nil", "true", "false", "bool", "b8", "b16", "b32", "b64", "int", "uint",
	"i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "uintptr", "f16",
	"f32", "f64", "complex64", "complex128", "quaternion128", "quaternion256", "rune", "string",
	"cstring", "rawptr", "any", "byte", "len", "cap", "size_of", "align_of", "offset_of",
	"type_of", "type_info_of", "typeid_of", "swizzle", "complex", "quaternion", "real", "imag",
	"jmag", "kmag", "conj", "expand_values", "min", "max", "abs", "clamp", "soa_zip", "soa_unzip",
	"raw_data", "Maybe", "new", "make", "delete", "free", "reserve", "append", "clear", "resize",
	"pop", "copy", "assert", "panic", "unreachable", "_unknown_fields",
}

is_valid_odin_identifier :: proc(s: string) -> bool {
	if len(s) == 0 || !is_ident_start(s[0]) || s == "_" {
		return false
	}
	for i in 1 ..< len(s) {
		if !is_ident_char(s[i]) {
			return false
		}
	}
	return !slice.contains(ODIN_RESERVED[:], s)
}

@(private = "file")
escape_name :: proc(g: ^Generator, name: string) -> string {
	if slice.contains(ODIN_RESERVED[:], name) {
		return strings.concatenate({name, "_"}, g.allocator)
	}
	return name
}

// unique_name appends underscores until name is not in `taken`, then adds it.
@(private = "file")
unique_name :: proc(g: ^Generator, taken: ^map[string]bool, name: string) -> string {
	n := name
	for taken[n] {
		n = strings.concatenate({n, "_"}, g.allocator)
	}
	taken[n] = true
	return n
}

// ada_case converts snake_case or camelCase to Ada_Case segments.
@(private = "file")
ada_case :: proc(g: ^Generator, name: string) -> string {
	b := strings.builder_make(g.allocator)
	upper_next := true
	for i in 0 ..< len(name) {
		c := name[i]
		if c == '_' || c == '.' {
			if strings.builder_len(b) > 0 {
				strings.write_byte(&b, '_')
			}
			upper_next = true
			continue
		}
		if upper_next && c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		upper_next = false
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// snake_case converts CamelCase method names (SayHello) to say_hello.
snake_case :: proc(name: string, allocator: Allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 'A' && c <= 'Z' {
			prev_lower := i > 0 && ((name[i - 1] >= 'a' && name[i - 1] <= 'z') || is_digit(name[i - 1]))
			next_lower := i + 1 < len(name) && name[i + 1] >= 'a' && name[i + 1] <= 'z'
			prev_upper := i > 0 && name[i - 1] >= 'A' && name[i - 1] <= 'Z'
			if i > 0 && name[i - 1] != '_' && (prev_lower || (prev_upper && next_lower)) {
				strings.write_byte(&b, '_')
			}
			strings.write_byte(&b, c + ('a' - 'A'))
		} else {
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
reserve_global :: proc(g: ^Generator, name, what: string, pos: Pos) -> bool {
	if prev, taken := g.globals[name]; taken {
		error_at(&g.c.diags, pos, "generated identifier '%s' for %s collides with %s", name, what, prev)
		return false
	}
	g.globals[name] = what
	return true
}

// unique_global appends underscores until name is unused.
@(private = "file")
unique_global :: proc(g: ^Generator, name, what: string) -> string {
	n := name
	for {
		if _, taken := g.globals[n]; !taken {
			break
		}
		n = strings.concatenate({n, "_"}, g.allocator)
	}
	g.globals[n] = what
	return n
}

// package_prefix is "" for primary packages and e.g. "Google_Protobuf_" for
// others.
@(private = "file")
package_prefix :: proc(g: ^Generator, f: ^File) -> string {
	if f.package_name == "" || g.primary_packages[f.package_name] {
		return ""
	}
	return strings.concatenate({ada_case(g, f.package_name), "_"}, g.allocator)
}

@(private = "file")
odin_type_path :: proc(g: ^Generator, f: ^File, parent: ^Message, name: string) -> string {
	if parent == nil {
		return strings.concatenate({package_prefix(g, f), name}, g.allocator)
	}
	return strings.concatenate({parent.odin_name, "_", name}, g.allocator)
}

@(private = "file")
assign_names :: proc(g: ^Generator, f: ^File) {
	for m in f.messages {
		assign_message_names(g, m)
	}
	for e in f.enums {
		assign_enum_names(g, e)
	}
	for s in f.services {
		s.odin_name = strings.concatenate({package_prefix(g, f), s.name}, g.allocator)
		what := fmt.aprintf("service %s", s.full_name, allocator = g.allocator)
		if !is_valid_odin_identifier(s.odin_name) {
			error_at(&g.c.diags, s.pos, "service name '%s' cannot be used as an Odin identifier", s.odin_name)
		}
		for suffix in SERVICE_SUFFIXES {
			reserve_global(g, strings.concatenate({s.odin_name, suffix}, g.allocator), what, s.pos)
		}
		for m in s.methods {
			method_snake := snake_case(m.name, g.allocator)
			g.stub_names[m] = unique_global(g, strings.concatenate({s.odin_name, "_", method_snake}, g.allocator), what)
			reserve_global(g, strings.concatenate({s.odin_name, "_", m.name, "_METHOD"}, g.allocator), what, m.pos)
			reserve_global(g, strings.concatenate({s.odin_name, "_", m.name, "_handler"}, g.allocator), what, m.pos)
			if m.client_streaming || m.server_streaming {
				for suffix in STREAM_SUFFIXES {
					reserve_global(g, strings.concatenate({s.odin_name, "_", m.name, suffix}, g.allocator), what, m.pos)
				}
			}
		}
	}
}

SERVICE_SUFFIXES := [?]string{"_Server", "_register", "_SERVICE_DESC", "_SERVICE_NAME"}
STREAM_SUFFIXES := [?]string {
	"_Client",
	"_Client_send",
	"_Client_close_send",
	"_Client_recv",
	"_Client_finish",
	"_Server",
	"_Server_send",
	"_Server_recv",
}

MESSAGE_PROC_SUFFIXES := [?]string {
	"_size",
	"_encode_fields",
	"_decode_fields",
	"_marshal",
	"_unmarshal",
	"_destroy",
	"_CODEC",
}

@(private = "file")
assign_message_names :: proc(g: ^Generator, m: ^Message) {
	m.odin_name = odin_type_path(g, m.file, m.parent, m.name)
	what := fmt.aprintf("message %s", m.full_name, allocator = g.allocator)
	if !is_valid_odin_identifier(m.odin_name) {
		error_at(&g.c.diags, m.pos, "message name '%s' cannot be used as an Odin identifier", m.odin_name)
	}
	reserve_global(g, m.odin_name, what, m.pos)
	for suffix in MESSAGE_PROC_SUFFIXES {
		reserve_global(g, strings.concatenate({m.odin_name, suffix}, g.allocator), what, m.pos)
	}
	append(&g.messages, m)
	for nested in m.messages {
		assign_message_names(g, nested)
	}
	for e in m.enums {
		assign_enum_names(g, e)
	}

	// Struct field names: escaped, then made unique (e.g. `proc` and
	// `proc_` both present).
	taken := make(map[string]bool, g.allocator)
	taken["_unknown_fields"] = true
	for field in m.fields {
		if field.oneof == nil {
			field.odin_name = unique_name(g, &taken, escape_name(g, field.name))
		}
		if dv, has := field.default_value.?; has {
			_ = dv
			reserve_global(g, default_const_name(g, m, field), what, field.pos)
		}
	}
	for o in m.oneofs {
		o.odin_name = unique_name(g, &taken, escape_name(g, o.name))
		o.odin_type_name = unique_global(
			g,
			strings.concatenate({m.odin_name, "_", ada_case(g, o.name)}, g.allocator),
			fmt.aprintf("oneof %s.%s", m.full_name, o.name, allocator = g.allocator),
		)
		reserve_global(g, strings.concatenate({o.odin_type_name, "_free"}, g.allocator), what, o.pos)
		for field in o.fields {
			field.odin_name = unique_global(
				g,
				strings.concatenate({o.odin_type_name, "_", ada_case(g, field.name)}, g.allocator),
				fmt.aprintf("oneof case %s.%s", m.full_name, field.name, allocator = g.allocator),
			)
		}
	}
}

@(private = "file")
default_const_name :: proc(g: ^Generator, m: ^Message, f: ^Field) -> string {
	return strings.concatenate({m.odin_name, "_", f.name, "_DEFAULT"}, g.allocator)
}

@(private = "file")
assign_enum_names :: proc(g: ^Generator, e: ^Enum) {
	e.odin_name = odin_type_path(g, e.file, e.parent, e.name)
	what := fmt.aprintf("enum %s", e.full_name, allocator = g.allocator)
	if !is_valid_odin_identifier(e.odin_name) {
		error_at(&g.c.diags, e.pos, "enum name '%s' cannot be used as an Odin identifier", e.odin_name)
	}
	reserve_global(g, e.odin_name, what, e.pos)
	if is_closed(e) {
		reserve_global(g, strings.concatenate({e.odin_name, "_is_known"}, g.allocator), what, e.pos)
	}
	taken := make(map[string]bool, g.allocator)
	names := make([]string, len(e.values), g.allocator)
	for v, i in e.values {
		names[i] = unique_name(g, &taken, escape_name(g, v.name))
	}
	g.enum_value_names[e] = names
}

// is_closed reports whether e is a closed enum: proto2 enums reject values
// they do not declare (those are kept as unknown fields instead).
@(private = "file")
is_closed :: proc(e: ^Enum) -> bool {
	return e.file.syntax == .Proto2
}

@(private = "file")
enum_value_name :: proc(g: ^Generator, e: ^Enum, proto_name: string) -> string {
	for v, i in e.values {
		if v.name == proto_name {
			return g.enum_value_names[e][i]
		}
	}
	unreachable()
}

// -----------------------------------------------------------------------------
// Output helpers
// -----------------------------------------------------------------------------

@(private)
line :: proc(g: ^Generator, format: string, args: ..any) {
	for _ in 0 ..< g.indent {
		strings.write_byte(&g.b, '\t')
	}
	fmt.sbprintf(&g.b, format, ..args)
	strings.write_byte(&g.b, '\n')
}

@(private)
blank :: proc(g: ^Generator) {
	strings.write_byte(&g.b, '\n')
}

@(private)
open :: proc(g: ^Generator, format: string, args: ..any) {
	line(g, format, ..args)
	g.indent += 1
}

@(private)
close :: proc(g: ^Generator) {
	g.indent -= 1
	line(g, "}}")
}

@(private = "file")
header :: proc(g: ^Generator, source: string, imports: []string) {
	g.b = strings.builder_make(g.allocator)
	g.indent = 0
	line(g, "// Code generated by odin-protoc. DO NOT EDIT.")
	if source != "" {
		line(g, "// source: %s", source)
	}
	blank(g)
	line(g, "package %s", g.opts.package_name)
	if len(imports) > 0 {
		blank(g)
		for imp in imports {
			line(g, "%s", imp)
		}
	}
}

@(private)
sprint :: proc(g: ^Generator, format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = g.allocator)
}

// -----------------------------------------------------------------------------
// Type mapping
// -----------------------------------------------------------------------------

@(private = "file")
scalar_odin_type :: proc(s: Scalar) -> string {
	switch s {
	case .Double:
		return "f64"
	case .Float:
		return "f32"
	case .Int32, .Sint32, .Sfixed32:
		return "i32"
	case .Int64, .Sint64, .Sfixed64:
		return "i64"
	case .Uint32, .Fixed32:
		return "u32"
	case .Uint64, .Fixed64:
		return "u64"
	case .Bool:
		return "bool"
	case .String:
		return "string"
	case .Bytes:
		return "[]u8"
	case .None:
	}
	unreachable()
}

// value_type is the Odin type of one value of t (no presence wrapper).
@(private = "file")
value_type :: proc(t: Type_Ref) -> string {
	if t.message != nil {
		return t.message.odin_name
	}
	if t.enum_ != nil {
		return t.enum_.odin_name
	}
	return scalar_odin_type(t.scalar)
}

@(private = "file")
field_odin_type :: proc(g: ^Generator, f: ^Field) -> string {
	if f.is_map {
		return sprint(g, "map[%s]%s", scalar_odin_type(f.map_key), value_type(f.map_value))
	}
	vt := value_type(f.type)
	switch f.label {
	case .Repeated:
		return strings.concatenate({"[dynamic]", vt}, g.allocator)
	case .Optional, .Required:
		if f.type.message != nil {
			return strings.concatenate({"^", vt}, g.allocator)
		}
		return sprint(g, "Maybe(%s)", vt)
	case .Implicit:
		if f.type.message != nil {
			return strings.concatenate({"^", vt}, g.allocator)
		}
		return vt
	}
	unreachable()
}

// Wire classification of a value type.
Kind :: enum u8 {
	Varint,
	Fixed32,
	Fixed64,
	Len,
	Message,
}

@(private = "file")
kind_of :: proc(t: Type_Ref) -> Kind {
	if t.message != nil {
		return .Message
	}
	if t.enum_ != nil {
		return .Varint
	}
	switch t.scalar {
	case .Int32, .Int64, .Uint32, .Uint64, .Sint32, .Sint64, .Bool:
		return .Varint
	case .Fixed32, .Sfixed32, .Float:
		return .Fixed32
	case .Fixed64, .Sfixed64, .Double:
		return .Fixed64
	case .String, .Bytes:
		return .Len
	case .None:
	}
	unreachable()
}

// field_kind is kind_of for a field; map fields are sequences of
// length-delimited entries.
@(private = "file")
field_kind :: proc(f: ^Field) -> Kind {
	return .Len if f.is_map else kind_of(f.type)
}

@(private = "file")
wire_of :: proc(k: Kind) -> string {
	switch k {
	case .Varint:
		return ".Varint"
	case .Fixed32:
		return ".I32"
	case .Fixed64:
		return ".I64"
	case .Len, .Message:
		return ".Len"
	}
	unreachable()
}

// codec_name is the suffix of the runtime put_/read_/size_ procedures.
@(private = "file")
codec_name :: proc(t: Type_Ref) -> string {
	if t.enum_ != nil {
		return "enum"
	}
	return SCALAR_NAMES[t.scalar]
}

@(private = "file")
is_packed :: proc(f: ^Field) -> bool {
	if f.label != .Repeated || f.is_map || !is_packable(f.type) {
		return false
	}
	if p, explicit := f.packed.?; explicit {
		return p
	}
	// proto3 packs repeated primitives by default; proto2 only on request.
	return f.file.syntax == .Proto3
}

// size_expr returns an expression for the encoded size of value `v` of type
// t, excluding the tag.
@(private = "file")
size_expr :: proc(g: ^Generator, t: Type_Ref, v: string) -> string {
	switch kind_of(t) {
	case .Varint:
		return sprint(g, "pb.size_%s(%s)", codec_name(t), v)
	case .Fixed32:
		return "4"
	case .Fixed64:
		return "8"
	case .Len:
		return sprint(g, "pb.size_len(len(%s))", v)
	case .Message:
		return sprint(g, "pb.size_len(%s_size(%s))", t.message.odin_name, v)
	}
	unreachable()
}

// uses_var reports whether a generated size expression refers to its
// operand (fixed-size types do not), to keep generated loops -vet clean.
@(private = "file")
uses_var :: proc(expr: string) -> bool {
	return expr != "4" && expr != "8"
}

// nonzero_check returns a condition that is true when implicit-presence
// value v differs from its default (proto3: only non-defaults are sent).
@(private = "file")
nonzero_check :: proc(g: ^Generator, t: Type_Ref, v: string) -> string {
	if t.enum_ != nil {
		return sprint(g, "i32(%s) != 0", v)
	}
	#partial switch t.scalar {
	case .String, .Bytes:
		return sprint(g, "len(%s) > 0", v)
	case .Bool:
		return v
	case .Float:
		// -0.0 is not the default and must be sent.
		return sprint(g, "transmute(u32)%s != 0", v)
	case .Double:
		return sprint(g, "transmute(u64)%s != 0", v)
	}
	return sprint(g, "%s != 0", v)
}

// map_value_ref is how a map value is passed to size/encode procedures:
// message values are iterated by reference and passed by pointer.
@(private = "file")
map_value_ref :: proc(f: ^Field, v: string) -> string {
	if f.map_value.message != nil {
		return strings.concatenate({"&", v})
	}
	return v
}

// map_loop_vars returns the iteration variables for a map loop, using `_`
// for whichever of key and value is unused.
@(private = "file")
map_loop_vars :: proc(f: ^Field, need_key, need_value: bool) -> string {
	by_ref := f.map_value.message != nil
	switch {
	case need_key && need_value:
		return "k, &v" if by_ref else "k, v"
	case need_key:
		return "k"
	case need_value:
		return "_, &v" if by_ref else "_, v"
	}
	return "_"
}

// oneof_value converts a oneof case value (a distinct type) back to its
// underlying type.
@(private = "file")
oneof_value :: proc(g: ^Generator, f: ^Field, v: string) -> string {
	return sprint(g, "(%s)(%s)", oneof_underlying(g, f), v)
}

@(private = "file")
oneof_underlying :: proc(g: ^Generator, f: ^Field) -> string {
	vt := value_type(f.type)
	if f.type.message != nil {
		return strings.concatenate({"^", vt}, g.allocator)
	}
	return vt
}

// oneof_case_check is the condition testing whether a oneof is set to
// case f (message cases must also be non-nil).
@(private = "file")
oneof_case_check :: proc(g: ^Generator, f: ^Field, var: string) -> string {
	if f.type.message != nil {
		return sprint(g, "%s, ok := m.%s.(%s); ok && %s != nil", var, f.oneof.odin_name, f.odin_name, var)
	}
	return sprint(g, "%s, ok := m.%s.(%s); ok", var, f.oneof.odin_name, f.odin_name)
}

@(private = "file")
tag_len :: proc(field: u32) -> int {
	v := u64(field) << 3
	n := 1
	for v >= 0x80 {
		v >>= 7
		n += 1
	}
	return n
}

// -----------------------------------------------------------------------------
// File generation
// -----------------------------------------------------------------------------

@(private = "file")
gen_file :: proc(g: ^Generator, f: ^File) -> string {
	imports := make([dynamic]string, g.allocator)
	if len(f.messages) > 0 {
		append(&imports, sprint(g, "import pb \"%s\"", g.opts.protobuf_import))
	}
	if g.opts.generate_services && len(f.services) > 0 {
		append(&imports, sprint(g, "import \"%s\"", g.opts.grpc_import))
	}
	header(g, f.path, imports[:])

	for e in f.enums {
		gen_enum(g, e)
	}
	for m in f.messages {
		gen_message_tree(g, m)
	}
	if g.opts.generate_services {
		for s in f.services {
			gen_service(g, s)
		}
	}
	return strings.to_string(g.b)
}

@(private = "file")
gen_message_tree :: proc(g: ^Generator, m: ^Message) {
	for e in m.enums {
		gen_enum(g, e)
	}
	gen_message(g, m)
	for nested in m.messages {
		gen_message_tree(g, nested)
	}
}

@(private = "file")
gen_enum :: proc(g: ^Generator, e: ^Enum) {
	names := g.enum_value_names[e]
	blank(g)
	line(g, "// %s", e.full_name)
	open(g, "%s :: enum i32 {{", e.odin_name)
	for v, i in e.values {
		line(g, "%s = %d,", names[i], v.number)
	}
	close(g)
	if !is_closed(e) {
		return
	}
	// Closed (proto2) enums: decoding keeps undeclared values as unknown
	// fields, so a field never holds a value outside the enum.
	seen := make(map[i32]bool, g.allocator)
	numbers := make([dynamic]string, g.allocator)
	for v in e.values {
		if !seen[v.number] {
			seen[v.number] = true
			append(&numbers, sprint(g, "%d", v.number))
		}
	}
	blank(g)
	line(g, "// %s_is_known reports whether v is a declared value of the closed enum.", e.odin_name)
	open(g, "%s_is_known :: proc \"contextless\" (v: %s) -> bool {{", e.odin_name, e.odin_name)
	line(g, "switch i32(v) {{")
	line(g, "case %s:", strings.join(numbers[:], ", ", g.allocator))
	line(g, "\treturn true")
	line(g, "}}")
	line(g, "return false")
	close(g)
}

@(private = "file")
fields_by_number :: proc(g: ^Generator, m: ^Message) -> []^Field {
	fields := slice.clone(m.fields[:], g.allocator)
	slice.sort_by(fields, proc(a, b: ^Field) -> bool {return a.number < b.number})
	return fields
}

@(private = "file")
gen_message :: proc(g: ^Generator, m: ^Message) {
	blank(g)
	line(g, "// %s", m.full_name)
	open(g, "%s :: struct {{", m.odin_name)
	emitted_oneofs := make(map[^Oneof]bool, g.allocator)
	for f in m.fields {
		if f.oneof != nil {
			if !emitted_oneofs[f.oneof] {
				emitted_oneofs[f.oneof] = true
				line(g, "%s: %s,", f.oneof.odin_name, f.oneof.odin_type_name)
			}
			continue
		}
		line(g, "%s: %s,", f.odin_name, field_odin_type(g, f))
	}
	line(g, "// Fields not declared in the schema, preserved for re-encoding.")
	line(g, "_unknown_fields: [dynamic]u8,")
	close(g)

	first_default := true
	for f in m.fields {
		if dv, has := f.default_value.?; has {
			if first_default {
				blank(g)
				line(g, "// proto2 default values, for fields that are not set.")
				first_default = false
			}
			line(g, "%s :: %s", default_const_name(g, m, f), default_literal(g, f, dv))
		}
	}

	for o in m.oneofs {
		gen_oneof_types(g, o)
	}

	gen_size(g, m)
	gen_encode(g, m)
	gen_decode(g, m)
	gen_destroy(g, m)
	gen_codec(g, m)
}

@(private = "file")
gen_oneof_types :: proc(g: ^Generator, o: ^Oneof) {
	blank(g)
	open(g, "%s :: union {{", o.odin_type_name)
	for f in o.fields {
		line(g, "%s,", f.odin_name)
	}
	close(g)
	for f in o.fields {
		line(g, "%s :: distinct %s", f.odin_name, oneof_underlying(g, f))
	}

	// <Union>_free releases memory owned by the current case and clears it.
	blank(g)
	line(g, "// %s_free frees memory owned by the current case of u and clears u.", o.odin_type_name)
	open(g, "%s_free :: proc(u: ^%s, allocator := context.allocator) {{", o.odin_type_name, o.odin_type_name)
	owning := false
	for f in o.fields {
		if k := kind_of(f.type); k == .Len || k == .Message {
			owning = true
		}
	}
	if owning {
		line(g, "#partial switch v in u {{")
		for f in o.fields {
			switch kind_of(f.type) {
			case .Len:
				line(g, "case %s:", f.odin_name)
				line(g, "\tdelete(%s, allocator)", oneof_value(g, f, "v"))
			case .Message:
				line(g, "case %s:", f.odin_name)
				line(g, "\tif v != nil {{")
				line(g, "\t\t%s_destroy(%s, allocator)", f.type.message.odin_name, oneof_value(g, f, "v"))
				line(g, "\t\tfree(%s, allocator)", oneof_value(g, f, "v"))
				line(g, "\t}}")
			case .Varint, .Fixed32, .Fixed64:
			}
		}
		line(g, "}}")
	} else {
		line(g, "_ = allocator")
	}
	line(g, "u^ = nil")
	close(g)
}

// default_literal renders a validated proto2 default as an Odin constant
// expression. Bytes defaults are string constants.
@(private = "file")
default_literal :: proc(g: ^Generator, f: ^Field, v: Constant) -> string {
	if e := f.type.enum_; e != nil {
		return sprint(g, "%s.%s", e.odin_name, enum_value_name(g, e, v.text))
	}
	#partial switch f.type.scalar {
	case .String, .Bytes:
		return odin_string_literal(g, v.text)
	case .Bool:
		return v.text
	case .Float, .Double:
		is_f32 := f.type.scalar == .Float
		text := v.text
		switch text {
		case "inf":
			return "0h7f800000" if is_f32 else "0h7ff0000000000000"
		case "-inf":
			return "0hff800000" if is_f32 else "0hfff0000000000000"
		case "nan", "-nan":
			return "0h7fc00000" if is_f32 else "0h7ff8000000000000"
		}
		if v.kind == .Int {
			negative, mag, _ := parse_signed_literal(text)
			return sprint(g, "%s(%s%d)", scalar_odin_type(f.type.scalar), "-" if negative else "", mag)
		}
		// protoc accepts an "f" suffix on float literals; Odin does not.
		return sprint(g, "%s(%s)", scalar_odin_type(f.type.scalar), strings.trim_right(text, "fF"))
	}
	negative, mag, _ := parse_signed_literal(v.text)
	return sprint(g, "%s(%s%d)", scalar_odin_type(f.type.scalar), "-" if negative else "", mag)
}

// odin_string_literal quotes s, escaping everything outside printable ASCII.
@(private = "file")
odin_string_literal :: proc(g: ^Generator, s: string) -> string {
	b := strings.builder_make(g.allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case c >= 0x20 && c < 0x7f:
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "\\x%02x", c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// -----------------------------------------------------------------------------
// Size
// -----------------------------------------------------------------------------

@(private = "file")
gen_size :: proc(g: ^Generator, m: ^Message) {
	blank(g)
	line(g, "// %s_size returns the exact encoded size of m in octets.", m.odin_name)
	open(g, "%s_size :: proc(m: ^%s) -> (n: int) {{", m.odin_name, m.odin_name)
	for f in fields_by_number(g, m) {
		tag := tag_len(f.number)
		access := sprint(g, "m.%s", f.odin_name)
		switch {
		case f.oneof != nil:
			size := size_expr(g, f.type, oneof_value(g, f, "v"))
			open(g, "if %s {{", oneof_case_check(g, f, "v" if uses_var(size) || f.type.message != nil else "_"))
			line(g, "n += %d + %s", tag, size)
			close(g)
		case f.is_map:
			// Map entries are messages {key = 1; value = 2}, both always sent.
			key_size := size_expr(g, {scalar = f.map_key}, "k")
			value_size := size_expr(g, f.map_value, map_value_ref(f, "v"))
			open(g, "for %s in %s {{", map_loop_vars(f, uses_var(key_size), uses_var(value_size)), access)
			line(g, "entry := 1 + %s + 1 + %s", key_size, value_size)
			line(g, "n += %d + pb.size_len(entry)", tag)
			close(g)
		case f.label == .Repeated:
			gen_size_repeated(g, f, access, tag)
		case f.type.message != nil:
			open(g, "if %s != nil {{", access)
			line(g, "n += %d + %s", tag, size_expr(g, f.type, access))
			close(g)
		case f.label == .Optional || f.label == .Required:
			size := size_expr(g, f.type, "v")
			open(g, "if %s, ok := %s.?; ok {{", "v" if uses_var(size) else "_", access)
			line(g, "n += %d + %s", tag, size)
			close(g)
		case:
			open(g, "if %s {{", nonzero_check(g, f.type, access))
			line(g, "n += %d + %s", tag, size_expr(g, f.type, access))
			close(g)
		}
	}
	line(g, "n += len(m._unknown_fields)")
	line(g, "return")
	close(g)
}

@(private = "file")
gen_size_repeated :: proc(g: ^Generator, f: ^Field, access: string, tag: int) {
	k := kind_of(f.type)
	if is_packed(f) {
		open(g, "if len(%s) > 0 {{", access)
		switch k {
		case .Fixed32:
			line(g, "n += %d + pb.size_len(4 * len(%s))", tag, access)
		case .Fixed64:
			line(g, "n += %d + pb.size_len(8 * len(%s))", tag, access)
		case .Varint:
			if f.type.scalar == .Bool {
				line(g, "n += %d + pb.size_len(len(%s))", tag, access)
			} else {
				line(g, "n += %d + pb.size_len(pb.size_packed_%s(%s[:]))", tag, codec_name(f.type), access)
			}
		case .Len, .Message:
			unreachable()
		}
		close(g)
		return
	}
	switch k {
	case .Fixed32:
		line(g, "n += len(%s) * %d", access, tag + 4)
	case .Fixed64:
		line(g, "n += len(%s) * %d", access, tag + 8)
	case .Message:
		open(g, "for &v in %s {{", access)
		line(g, "n += %d + %s", tag, size_expr(g, f.type, "&v"))
		close(g)
	case .Varint, .Len:
		open(g, "for v in %s {{", access)
		line(g, "n += %d + %s", tag, size_expr(g, f.type, "v"))
		close(g)
	}
}

// -----------------------------------------------------------------------------
// Encode (fields are written in descending number order, back to front)
// -----------------------------------------------------------------------------

@(private = "file")
put_value :: proc(g: ^Generator, t: Type_Ref, field: u32, v: string) {
	if t.message != nil {
		line(g, "mark := pb.begin_len(e)")
		line(g, "%s_encode_fields(%s, e)", t.message.odin_name, v)
		line(g, "pb.end_len(e, %d, mark)", field)
		return
	}
	line(g, "pb.put_%s(e, %d, %s)", codec_name(t), field, v)
}

@(private = "file")
gen_encode :: proc(g: ^Generator, m: ^Message) {
	blank(g)
	line(g, "// %s_encode_fields writes m back to front; see pb.Encoder.", m.odin_name)
	open(g, "%s_encode_fields :: proc(m: ^%s, e: ^pb.Encoder) {{", m.odin_name, m.odin_name)
	line(g, "pb.write_raw(e, m._unknown_fields[:])")
	fields := fields_by_number(g, m)
	#reverse for f in fields {
		access := sprint(g, "m.%s", f.odin_name)
		switch {
		case f.oneof != nil:
			open(g, "if %s {{", oneof_case_check(g, f, "v"))
			put_value(g, f.type, f.number, oneof_value(g, f, "v"))
			close(g)
		case f.is_map:
			open(g, "for k, &v in %s {{", access)
			line(g, "entry := pb.begin_len(e)")
			if f.map_value.message != nil {
				open(g, "{{")
				put_value(g, f.map_value, 2, "&v")
				close(g)
			} else {
				put_value(g, f.map_value, 2, "v")
			}
			put_value(g, {scalar = f.map_key}, 1, "k")
			line(g, "pb.end_len(e, %d, entry)", f.number)
			close(g)
		case f.label == .Repeated:
			if is_packed(f) {
				open(g, "if len(%s) > 0 {{", access)
				switch kind_of(f.type) {
				case .Fixed32:
					line(g, "pb.put_packed_fixed32(e, %d, %s[:])", f.number, access)
				case .Fixed64:
					line(g, "pb.put_packed_fixed64(e, %d, %s[:])", f.number, access)
				case .Varint:
					line(g, "pb.put_packed_%s(e, %d, %s[:])", codec_name(f.type), f.number, access)
				case .Len, .Message:
					unreachable()
				}
				close(g)
			} else if f.type.message != nil {
				open(g, "#reverse for &v in %s {{", access)
				put_value(g, f.type, f.number, "&v")
				close(g)
			} else {
				open(g, "#reverse for v in %s {{", access)
				put_value(g, f.type, f.number, "v")
				close(g)
			}
		case f.type.message != nil:
			open(g, "if %s != nil {{", access)
			put_value(g, f.type, f.number, access)
			close(g)
		case f.label == .Optional || f.label == .Required:
			open(g, "if v, ok := %s.?; ok {{", access)
			put_value(g, f.type, f.number, "v")
			close(g)
		case:
			open(g, "if %s {{", nonzero_check(g, f.type, access))
			put_value(g, f.type, f.number, access)
			close(g)
		}
	}
	close(g)
}

// -----------------------------------------------------------------------------
// Decode
// -----------------------------------------------------------------------------

@(private = "file")
read_call :: proc(g: ^Generator, t: Type_Ref, f: ^Field) -> string {
	if t.enum_ != nil {
		return sprint(g, "pb.read_enum(d, %s)", t.enum_.odin_name)
	}
	if t.scalar == .String && f.file.syntax == .Proto2 {
		return "pb.read_string_unchecked(d)"
	}
	return sprint(g, "pb.read_%s(d)", SCALAR_NAMES[t.scalar])
}

@(private = "file")
count_kind :: proc(f: ^Field) -> string {
	switch kind_of(f.type) {
	case .Varint:
		return ".Varint"
	case .Fixed32:
		return ".Fixed32"
	case .Fixed64:
		return ".Fixed64"
	case .Len, .Message:
		return ".Len"
	}
	unreachable()
}

// decode_message_into emits code decoding a length-delimited sub-message
// into the message pointed to by `target`.
@(private = "file")
decode_message_into :: proc(g: ^Generator, msg: ^Message, target: string) {
	line(g, "mark := pb.enter_message(d) or_return")
	line(g, "%s_decode_fields(%s, d) or_return", msg.odin_name, target)
	line(g, "pb.leave_message(d, mark) or_return")
}

// closed_enum_guard emits, for closed enums, a check that routes undeclared
// values to the unknown fields.
@(private = "file")
closed_enum_guard :: proc(g: ^Generator, t: Type_Ref) {
	if t.enum_ == nil || !is_closed(t.enum_) {
		return
	}
	open(g, "if !%s_is_known(v) {{", t.enum_.odin_name)
	line(g, "pb.store_unknown(d, tag_start, &m._unknown_fields) or_return")
	line(g, "continue")
	close(g)
}

// free_value emits code releasing memory owned by value v of type t.
// `by_pointer` is set for message values held through a pointer.
@(private = "file")
free_value :: proc(g: ^Generator, t: Type_Ref, v: string, by_pointer: bool, allocator: string) {
	switch kind_of(t) {
	case .Len:
		line(g, "delete(%s, %s)", v, allocator)
	case .Message:
		if by_pointer {
			line(g, "%s_destroy(%s, %s)", t.message.odin_name, v, allocator)
			line(g, "free(%s, %s)", v, allocator)
		} else {
			line(g, "%s_destroy(&%s, %s)", t.message.odin_name, v, allocator)
		}
	case .Varint, .Fixed32, .Fixed64:
	}
}

@(private = "file")
owns_memory :: proc(t: Type_Ref) -> bool {
	k := kind_of(t)
	return k == .Len || k == .Message
}

@(private = "file")
gen_decode :: proc(g: ^Generator, m: ^Message) {
	blank(g)
	line(g, "// %s_decode_fields decodes fields from d into m, merging with its contents.", m.odin_name)
	open(g, "%s_decode_fields :: proc(m: ^%s, d: ^pb.Decoder) -> pb.Error {{", m.odin_name, m.odin_name)

	repeated := make([dynamic]^Field, g.allocator)
	for f in m.fields {
		if f.label == .Repeated && !f.is_map {
			append(&repeated, f)
		}
	}
	if len(repeated) > 0 {
		// Pre-count repeated elements so that each array is normally
		// allocated once, at its final size.
		line(g, "@(static, rodata) count_specs := [%d]pb.Count_Spec{{", len(repeated))
		g.indent += 1
		for f in repeated {
			line(g, "{{%d, %s}},", f.number, count_kind(f))
		}
		g.indent -= 1
		line(g, "}}")
		line(g, "counts: [%d]int", len(repeated))
		line(g, "pb.count_repeated(d, count_specs[:], counts[:]) or_return")
		for f, i in repeated {
			line(g, "pb.reserve_repeated(d, &m.%s, counts[%d]) or_return", f.odin_name, i)
		}
	}

	open(g, "for pb.more(d) {{")
	line(g, "tag_start := d.pos")
	line(g, "field, wire := pb.read_tag(d) or_return")
	if len(m.fields) > 0 {
		line(g, "switch field {{")
		for f in fields_by_number(g, m) {
			line(g, "case %d:", f.number)
			g.indent += 1
			gen_decode_field(g, f)
			g.indent -= 1
		}
		line(g, "}}")
	}
	line(g, "pb.skip_unknown(d, tag_start, field, wire, &m._unknown_fields) or_return")
	close(g)

	for f in m.fields {
		if f.label != .Required {
			continue
		}
		if f.type.message != nil {
			line(g, "if m.%s == nil {{return .Missing_Required_Field}}", f.odin_name)
		} else {
			line(g, "if _, ok := m.%s.?; !ok {{return .Missing_Required_Field}}", f.odin_name)
		}
	}
	line(g, "return .None")
	close(g)
}

@(private = "file")
gen_decode_field :: proc(g: ^Generator, f: ^Field) {
	access := sprint(g, "m.%s", f.odin_name)
	k := field_kind(f)
	switch {
	case f.is_map:
		gen_decode_map_entry(g, f, access)

	case f.label == .Repeated:
		open(g, "if wire == %s {{", wire_of(k))
		if k == .Message {
			line(g, "elem := pb.append_repeated_zeroed(d, &%s) or_return", access)
			decode_message_into(g, f.type.message, "elem")
		} else {
			line(g, "v := %s or_return", read_call(g, f.type, f))
			closed_enum_guard(g, f.type)
			line(g, "pb.append_repeated(d, &%s, v) or_return", access)
		}
		line(g, "continue")
		close(g)
		if is_packable(f.type) {
			// Parsers must accept both packed and unpacked encodings.
			open(g, "if wire == .Len {{")
			line(g, "mark := pb.enter_len(d) or_return")
			open(g, "for pb.more(d) {{")
			line(g, "v := %s or_return", read_call(g, f.type, f))
			if e := f.type.enum_; e != nil && is_closed(e) {
				open(g, "if !%s_is_known(v) {{", e.odin_name)
				line(g, "pb.store_unknown_varint(d, %d, u64(i64(i32(v))), &m._unknown_fields) or_return", f.number)
				line(g, "continue")
				close(g)
			}
			line(g, "pb.append_repeated(d, &%s, v) or_return", access)
			close(g)
			line(g, "pb.leave_len(d, mark)")
			line(g, "continue")
			close(g)
		}

	case f.oneof != nil:
		union_access := sprint(g, "m.%s", f.oneof.odin_name)
		open(g, "if wire == %s {{", wire_of(k))
		if k == .Message {
			// Merge into the existing message if this case is already set.
			line(g, "target, is_set := %s.(%s)", union_access, f.odin_name)
			open(g, "if !is_set || target == nil {{")
			line(g, "if !d.alias_input {{%s_free(&%s, d.allocator)}}", f.oneof.odin_type_name, union_access)
			line(g, "target = %s(new(%s, d.allocator) or_else nil)", f.odin_name, f.type.message.odin_name)
			line(g, "if target == nil {{return .Out_Of_Memory}}")
			line(g, "%s = target", union_access)
			close(g)
			decode_message_into(g, f.type.message, oneof_value(g, f, "target"))
		} else {
			line(g, "v := %s or_return", read_call(g, f.type, f))
			closed_enum_guard(g, f.type)
			line(g, "if !d.alias_input {{%s_free(&%s, d.allocator)}}", f.oneof.odin_type_name, union_access)
			line(g, "%s = %s(v)", union_access, f.odin_name)
		}
		line(g, "continue")
		close(g)

	case k == .Message:
		open(g, "if wire == .Len {{")
		open(g, "if %s == nil {{", access)
		line(g, "%s = new(%s, d.allocator) or_else nil", access, f.type.message.odin_name)
		line(g, "if %s == nil {{return .Out_Of_Memory}}", access)
		close(g)
		decode_message_into(g, f.type.message, access)
		line(g, "continue")
		close(g)

	case f.label == .Optional || f.label == .Required:
		open(g, "if wire == %s {{", wire_of(k))
		line(g, "v := %s or_return", read_call(g, f.type, f))
		closed_enum_guard(g, f.type)
		if k == .Len {
			line(g, "if old, has := %s.?; has {{pb.free_%s(d, old)}}", access, "bytes" if f.type.scalar == .Bytes else "string")
		}
		line(g, "%s = v", access)
		line(g, "continue")
		close(g)

	case:
		open(g, "if wire == %s {{", wire_of(k))
		if k == .Len {
			line(g, "v := %s or_return", read_call(g, f.type, f))
			line(g, "pb.free_%s(d, %s)", "bytes" if f.type.scalar == .Bytes else "string", access)
			line(g, "%s = v", access)
		} else if f.type.enum_ != nil && is_closed(f.type.enum_) {
			line(g, "v := %s or_return", read_call(g, f.type, f))
			closed_enum_guard(g, f.type)
			line(g, "%s = v", access)
		} else {
			line(g, "%s = %s or_return", access, read_call(g, f.type, f))
		}
		line(g, "continue")
		close(g)
	}
}

@(private = "file")
gen_decode_map_entry :: proc(g: ^Generator, f: ^Field, access: string) {
	key_owns := f.map_key == .String
	value_owns := owns_memory(f.map_value)
	open(g, "if wire == .Len {{")
	line(g, "entry_mark := pb.enter_message(d) or_return")
	line(g, "key: %s", scalar_odin_type(f.map_key))
	line(g, "value: %s", value_type(f.map_value))
	if key_owns || value_owns {
		// Until the entry is stored, its key and value belong to this scope
		// and are released on every exit path (errors included).
		line(g, "entry_done := false")
		open(g, "defer if !entry_done && !d.alias_input {{")
		if key_owns {
			line(g, "delete(key, d.allocator)")
		}
		if value_owns {
			free_value(g, f.map_value, "value", false, "d.allocator")
		}
		close(g)
	}
	open(g, "for pb.more(d) {{")
	line(g, "entry_field, entry_wire := pb.read_tag(d) or_return")
	open(g, "if entry_field == 1 && entry_wire == %s {{", wire_of(kind_of({scalar = f.map_key})))
	if key_owns {
		line(g, "k := %s or_return", read_call(g, {scalar = f.map_key}, f))
		line(g, "pb.free_string(d, key)")
		line(g, "key = k")
	} else {
		line(g, "key = %s or_return", read_call(g, {scalar = f.map_key}, f))
	}
	line(g, "continue")
	close(g)
	vk := kind_of(f.map_value)
	open(g, "if entry_field == 2 && entry_wire == %s {{", wire_of(vk))
	switch vk {
	case .Message:
		decode_message_into(g, f.map_value.message, "&value")
	case .Len:
		line(g, "v := %s or_return", read_call(g, f.map_value, f))
		line(g, "pb.free_%s(d, value)", "bytes" if f.map_value.scalar == .Bytes else "string")
		line(g, "value = v")
	case .Varint, .Fixed32, .Fixed64:
		line(g, "value = %s or_return", read_call(g, f.map_value, f))
	}
	line(g, "continue")
	close(g)
	line(g, "pb.skip_value(d, entry_field, entry_wire) or_return")
	close(g)
	line(g, "pb.leave_message(d, entry_mark) or_return")
	if e := f.map_value.enum_; e != nil && is_closed(e) {
		// An entry whose value is not a declared closed-enum value is kept,
		// whole, as an unknown field.
		open(g, "if !%s_is_known(value) {{", e.odin_name)
		line(g, "pb.store_unknown(d, tag_start, &m._unknown_fields) or_return")
		line(g, "continue")
		close(g)
	}
	open(g, "if %s == nil {{", access)
	line(g, "%s = make(%s, d.allocator)", access, field_odin_type(g, f))
	close(g)
	// Duplicate keys: the last entry wins. The value is replaced in place,
	// so the map keeps its original key; the replaced value and the
	// duplicate key copy are released.
	open(g, "if old, exists := &%s[key]; exists {{", access)
	if key_owns || value_owns {
		open(g, "if !d.alias_input {{")
		if key_owns {
			line(g, "delete(key, d.allocator)")
		}
		if value_owns {
			free_value(g, f.map_value, "old^", false, "d.allocator")
		}
		close(g)
	}
	line(g, "old^ = value")
	if key_owns || value_owns {
		line(g, "entry_done = true")
	}
	line(g, "continue")
	close(g)
	open(g, "if reserve(&%s, len(%s) + 1) != nil {{", access, access)
	line(g, "return .Out_Of_Memory")
	close(g)
	line(g, "%s[key] = value", access)
	if key_owns || value_owns {
		line(g, "entry_done = true")
	}
	line(g, "continue")
	close(g)
}

// -----------------------------------------------------------------------------
// Destroy
// -----------------------------------------------------------------------------

@(private = "file")
gen_destroy :: proc(g: ^Generator, m: ^Message) {
	blank(g)
	line(g, "// %s_destroy frees everything decoding allocated for m with `allocator`.", m.odin_name)
	line(g, "// Do not use it on messages decoded with Decode_Options.alias_input or")
	line(g, "// whose memory the caller provided; prefer arena allocators instead.")
	open(g, "%s_destroy :: proc(m: ^%s, allocator := context.allocator) {{", m.odin_name, m.odin_name)
	line(g, "if m == nil {{return}}")
	for o in m.oneofs {
		line(g, "%s_free(&m.%s, allocator)", o.odin_type_name, o.odin_name)
	}
	for f in m.fields {
		if f.oneof != nil {
			continue
		}
		access := sprint(g, "m.%s", f.odin_name)
		switch {
		case f.is_map:
			key_owns := f.map_key == .String
			value_owns := owns_memory(f.map_value)
			if key_owns || value_owns {
				vars: string
				switch {
				case key_owns && value_owns:
					vars = "k, &v"
				case key_owns:
					vars = "k"
				case:
					vars = "_, &v"
				}
				open(g, "for %s in %s {{", vars, access)
				if key_owns {
					line(g, "delete(k, allocator)")
				}
				if value_owns {
					free_value(g, f.map_value, "v", false, "allocator")
				}
				close(g)
			}
			line(g, "delete(%s)", access)
		case f.label == .Repeated:
			if kind_of(f.type) == .Len {
				open(g, "for v in %s {{", access)
				free_value(g, f.type, "v", false, "allocator")
				close(g)
			} else if f.type.message != nil {
				open(g, "for &v in %s {{", access)
				free_value(g, f.type, "v", false, "allocator")
				close(g)
			}
			line(g, "delete(%s)", access)
		case f.type.message != nil:
			open(g, "if %s != nil {{", access)
			free_value(g, f.type, access, true, "allocator")
			close(g)
		case kind_of(f.type) == .Len && (f.label == .Optional || f.label == .Required):
			open(g, "if v, ok := %s.?; ok {{", access)
			free_value(g, f.type, "v", false, "allocator")
			close(g)
		case kind_of(f.type) == .Len:
			free_value(g, f.type, access, false, "allocator")
		}
	}
	line(g, "delete(m._unknown_fields)")
	line(g, "m^ = {{}}")
	close(g)
}

// -----------------------------------------------------------------------------
// Codec and typed helpers
// -----------------------------------------------------------------------------

@(private = "file")
gen_codec :: proc(g: ^Generator, m: ^Message) {
	n := m.odin_name
	blank(g)
	open(g, "%s_CODEC := pb.Message_Codec{{", n)
	line(g, "full_name = %q,", m.full_name)
	line(g, "size = proc(m: rawptr) -> int {{return %s_size((^%s)(m))}},", n, n)
	line(g, "encode_fields = proc(m: rawptr, e: ^pb.Encoder) {{%s_encode_fields((^%s)(m), e)}},", n, n)
	line(g, "decode_fields = proc(m: rawptr, d: ^pb.Decoder) -> pb.Error {{return %s_decode_fields((^%s)(m), d)}},", n, n)
	close(g)
	blank(g)
	line(g, "// %s_marshal encodes m into a new buffer of exactly its size.", n)
	open(g, "%s_marshal :: proc(m: ^%s, allocator := context.allocator) -> ([]u8, pb.Error) {{", n, n)
	line(g, "return pb.marshal(m, &%s_CODEC, allocator)", n)
	close(g)
	blank(g)
	line(g, "// %s_unmarshal decodes data into m, allocating from `allocator`.", n)
	open(g, "%s_unmarshal :: proc(m: ^%s, data: []u8, allocator := context.allocator, options := pb.Decode_Options{{}}) -> pb.Error {{", n, n)
	line(g, "return pb.unmarshal(m, &%s_CODEC, data, allocator, options)", n)
	close(g)
}

@(private = "file")
gen_groups :: proc(g: ^Generator) -> string {
	header(g, "", {})
	if len(g.messages) == 0 {
		return strings.to_string(g.b)
	}
	blank(g)
	line(g, "// Procedure groups over all generated messages.")
	groups := [?]struct {
		name, suffix: string,
	}{{"size", "_size"}, {"marshal", "_marshal"}, {"unmarshal", "_unmarshal"}, {"destroy", "_destroy"}}
	for grp in groups {
		blank(g)
		open(g, "%s :: proc {{", grp.name)
		for m in g.messages {
			line(g, "%s%s,", m.odin_name, grp.suffix)
		}
		close(g)
	}
	return strings.to_string(g.b)
}
