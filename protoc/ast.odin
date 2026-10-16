/*
Package protoc parses .proto files (proto2 and proto3 syntax), resolves and
validates their types, and generates Odin source code that uses the
`protobuf` runtime package and, for services, the `grpc` package.

It is used by the odin-protoc command (cmd/odin-protoc) and can be embedded
in other build tooling.

All memory is allocated from the allocator given to `compiler_init`; the
intended usage is an arena that is freed in one go after generation.
*/
package protoc

import "base:runtime"
import "core:fmt"

Allocator :: runtime.Allocator

Diagnostic :: struct {
	pos:     Pos,
	message: string,
}

Diagnostics :: struct {
	list:      [dynamic]Diagnostic,
	allocator: Allocator,
}

error_at :: proc(d: ^Diagnostics, pos: Pos, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args, allocator = d.allocator)
	append(&d.list, Diagnostic{pos, msg})
}

has_errors :: proc(d: ^Diagnostics) -> bool {
	return len(d.list) > 0
}

Syntax :: enum u8 {
	Proto2,
	Proto3,
}

Scalar :: enum u8 {
	None,
	Double,
	Float,
	Int32,
	Int64,
	Uint32,
	Uint64,
	Sint32,
	Sint64,
	Fixed32,
	Fixed64,
	Sfixed32,
	Sfixed64,
	Bool,
	String,
	Bytes,
}

SCALAR_NAMES := [Scalar]string {
	.None     = "",
	.Double   = "double",
	.Float    = "float",
	.Int32    = "int32",
	.Int64    = "int64",
	.Uint32   = "uint32",
	.Uint64   = "uint64",
	.Sint32   = "sint32",
	.Sint64   = "sint64",
	.Fixed32  = "fixed32",
	.Fixed64  = "fixed64",
	.Sfixed32 = "sfixed32",
	.Sfixed64 = "sfixed64",
	.Bool     = "bool",
	.String   = "string",
	.Bytes    = "bytes",
}

scalar_from_name :: proc(name: string) -> Scalar {
	for n, s in SCALAR_NAMES {
		if s != .None && n == name {
			return s
		}
	}
	return .None
}

Label :: enum u8 {
	// proto3 singular field without `optional`: implicit presence.
	Implicit,
	// proto2 `optional` or proto3 `optional`: explicit presence.
	Optional,
	Required,
	Repeated,
}

// Type_Ref is the type of a field, map value or method input/output.
Type_Ref :: struct {
	scalar:  Scalar, // .None when the type is a message or enum
	name:    string, // unresolved name as written (non-scalar types)
	message: ^Message, // set by resolution
	enum_:   ^Enum, // set by resolution
}

Field :: struct {
	name:       string,
	number:     u32,
	label:      Label,
	type:       Type_Ref,
	// Map fields: key and value types (type is unused).
	is_map:     bool,
	map_key:    Scalar,
	map_value:  Type_Ref,
	oneof:      ^Oneof,
	packed:        Maybe(bool),
	deprecated:    bool,
	// proto2 `[default = ...]`, validated during resolution.
	default_value: Maybe(Constant),
	// `[json_name = "..."]`, if given.
	json_name:     Maybe(string),
	// All `[...]` options as written (for descriptors).
	options:       [dynamic]Option,
	// Extension fields (declared in `extend X { ... }`): the extended type.
	is_extension:  bool,
	extendee:      Type_Ref,
	pos:        Pos,
	file:       ^File,
	// Set during generation.
	odin_name:  string,
}

Oneof :: struct {
	name:           string,
	fields:         [dynamic]^Field,
	options:        [dynamic]Option,
	pos:            Pos,
	odin_name:      string, // struct field name
	odin_type_name: string, // union type name
}

Range :: struct {
	start, end: i64, // inclusive
}

Message :: struct {
	name:            string,
	full_name:       string, // without leading dot, e.g. "pkg.Outer.Inner"
	file:            ^File,
	parent:          ^Message,
	fields:          [dynamic]^Field,
	oneofs:          [dynamic]^Oneof,
	messages:        [dynamic]^Message,
	enums:           [dynamic]^Enum,
	reserved_ranges: [dynamic]Range,
	reserved_names:  [dynamic]string,
	// Extension ranges (`extensions 100 to 199;`), kept for descriptors.
	extension_ranges: [dynamic]Range,
	// Extensions declared inside this message (`extend X { ... }`).
	extensions:      [dynamic]^Field,
	options:         [dynamic]Option,
	// Nested messages and map fields in source order: the descriptor's
	// nested types interleave synthesized map entries in this order.
	nested_order:    [dynamic]Nested_Item,
	pos:             Pos,
	odin_name:       string,
}

Nested_Item :: union {
	^Message,
	^Field, // a map field
}

Enum_Value :: struct {
	name:    string,
	number:  i32,
	options: [dynamic]Option,
	pos:     Pos,
}

Enum :: struct {
	name:            string,
	full_name:       string,
	file:            ^File,
	parent:          ^Message,
	values:          [dynamic]Enum_Value,
	allow_alias:     bool,
	reserved_ranges: [dynamic]Range,
	reserved_names:  [dynamic]string,
	options:         [dynamic]Option,
	pos:             Pos,
	odin_name:       string,
}

Method :: struct {
	name:             string,
	input:            Type_Ref,
	output:           Type_Ref,
	client_streaming: bool,
	server_streaming: bool,
	options:          [dynamic]Option,
	// Declared with a `{ ... }` body (protoc then records options, even
	// empty ones).
	has_body:         bool,
	pos:              Pos,
}

Service :: struct {
	name:      string,
	full_name: string,
	file:      ^File,
	methods:   [dynamic]^Method,
	options:   [dynamic]Option,
	pos:       Pos,
	odin_name: string,
}

Import :: struct {
	path:   string,
	public: bool,
	weak:   bool,
	pos:    Pos,
	file:   ^File, // set when loaded
}

File :: struct {
	path:         string, // import path, relative to an include directory
	syntax:       Syntax,
	package_name: string,
	imports:      [dynamic]Import,
	messages:     [dynamic]^Message,
	enums:        [dynamic]^Enum,
	services:     [dynamic]^Service,
	options:      [dynamic]Option,
	// Top-level extensions (`extend X { ... }`). They appear in descriptors
	// (e.g. custom option declarations); no code is generated for them.
	extensions:   [dynamic]^Field,
	// Record json_name on every field in the descriptor (Google's
	// well-known-type descriptors do; ordinary protoc output only records
	// explicit ones).
	all_json_names: bool,
}
