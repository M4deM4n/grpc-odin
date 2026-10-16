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
	pos:        Pos,
	file:       ^File,
	// Set during generation.
	odin_name:  string,
}

Oneof :: struct {
	name:           string,
	fields:         [dynamic]^Field,
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
	pos:             Pos,
	odin_name:       string,
}

Enum_Value :: struct {
	name:   string,
	number: i32,
	pos:    Pos,
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
	pos:             Pos,
	odin_name:       string,
}

Method :: struct {
	name:             string,
	input:            Type_Ref,
	output:           Type_Ref,
	client_streaming: bool,
	server_streaming: bool,
	pos:              Pos,
}

Service :: struct {
	name:      string,
	full_name: string,
	file:      ^File,
	methods:   [dynamic]^Method,
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
}
