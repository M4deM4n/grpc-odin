package protoc

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Symbol_Kind :: enum u8 {
	Package,
	Message,
	Enum,
	Service,
}

Symbol :: struct {
	kind:    Symbol_Kind,
	file:    ^File, // nil for packages
	message: ^Message,
	enum_:   ^Enum,
}

// Compiler loads a set of .proto files with their imports, then resolves and
// validates them as a unit.
Compiler :: struct {
	allocator:     Allocator,
	diags:         Diagnostics,
	include_paths: [dynamic]string,
	// In-memory sources, consulted before the include paths. Used for the
	// embedded well-known types and for tests.
	sources:       map[string]string,
	files:         map[string]^File,
	// Files in dependency order: every file appears after its imports.
	order:         [dynamic]^File,
	// Files named on the command line (as opposed to only imported).
	inputs:        [dynamic]^File,
	loading:       map[string]bool,
	symbols:       map[string]Symbol,
}

compiler_init :: proc(c: ^Compiler, allocator: Allocator) {
	c^ = {}
	c.allocator = allocator
	c.diags.allocator = allocator
	c.diags.list = make([dynamic]Diagnostic, allocator)
	c.include_paths = make([dynamic]string, allocator)
	c.sources = make(map[string]string, allocator)
	c.files = make(map[string]^File, allocator)
	c.order = make([dynamic]^File, allocator)
	c.inputs = make([dynamic]^File, allocator)
	c.loading = make(map[string]bool, allocator)
	c.symbols = make(map[string]Symbol, allocator)
	for wkt in WELL_KNOWN_TYPES {
		c.sources[wkt.path] = wkt.source
	}
}

compiler_add_include_path :: proc(c: ^Compiler, dir: string) {
	append(&c.include_paths, dir)
}

// compiler_add_source registers an in-memory file under an import path.
compiler_add_source :: proc(c: ^Compiler, import_path, source: string) {
	c.sources[import_path] = source
}

// compiler_add_input loads a file to generate code for. Its package is a
// "primary" package: its types keep their plain names in generated code,
// while types from other (imported) packages are prefixed.
compiler_add_input :: proc(c: ^Compiler, import_path: string) -> ^File {
	path := normalize_import_path(import_path, c.allocator)
	for f in c.inputs {
		if f.path == path {
			error_at(&c.diags, {}, "'%s' is given as input more than once (inputs are identified by their path relative to the include directories)", path)
			return nil
		}
	}
	f := compiler_load(c, path)
	if f != nil {
		append(&c.inputs, f)
	}
	return f
}

// compiler_load loads a file by import path, together with everything it
// imports. Errors are recorded in c.diags.
compiler_load :: proc(c: ^Compiler, import_path: string, from: Pos = {}) -> ^File {
	path := normalize_import_path(import_path, c.allocator)
	if f, ok := c.files[path]; ok {
		return f
	}
	if c.loading[path] {
		error_at(&c.diags, from, "import cycle involving '%s'", path)
		return nil
	}
	src, found := read_source(c, path)
	if !found {
		error_at(&c.diags, from, "file not found: '%s'", path)
		return nil
	}
	c.loading[path] = true
	defer delete_key(&c.loading, path)

	f := parse_file(path, src, &c.diags, c.allocator)
	for &imp in f.imports {
		if imp.path == path {
			error_at(&c.diags, imp.pos, "file imports itself")
			continue
		}
		imp.file = compiler_load(c, imp.path, imp.pos)
	}
	c.files[path] = f
	append(&c.order, f)
	return f
}

// normalize_import_path uses forward slashes and resolves "." and ".."
// segments, so that one file is never loaded under two names.
normalize_import_path :: proc(path: string, allocator: Allocator) -> string {
	p, _ := strings.replace_all(path, "\\", "/", allocator)
	parts := strings.split(p, "/", allocator)
	out := make([dynamic]string, allocator)
	for part in parts {
		switch part {
		case "", ".":
		case "..":
			if len(out) > 0 && out[len(out) - 1] != ".." {
				pop(&out)
			} else {
				append(&out, part)
			}
		case:
			append(&out, part)
		}
	}
	return strings.join(out[:], "/", allocator)
}

@(private = "file")
read_source :: proc(c: ^Compiler, path: string) -> (string, bool) {
	if src, ok := c.sources[path]; ok {
		return src, true
	}
	for dir in c.include_paths {
		full, _ := filepath.join({dir, path}, c.allocator)
		if data, err := os.read_entire_file(full, c.allocator); err == nil {
			return string(data), true
		}
	}
	return "", false
}

// compiler_resolve resolves all type references and validates every loaded
// file. Returns false if any errors were reported.
compiler_resolve :: proc(c: ^Compiler) -> bool {
	if has_errors(&c.diags) {
		return false
	}
	for f in c.order {
		register_file(c, f)
	}
	if has_errors(&c.diags) {
		return false
	}
	for f in c.order {
		visible := visible_files(c, f)
		for m in f.messages {
			resolve_message(c, f, m, visible)
		}
		for s in f.services {
			resolve_service(c, f, s, visible)
		}
		for m in f.messages {
			validate_message(c, f, m)
		}
		for e in f.enums {
			validate_enum(c, f, e)
		}
		for s in f.services {
			validate_service(c, s)
		}
	}
	return !has_errors(&c.diags)
}

// -----------------------------------------------------------------------------
// Symbol registration
// -----------------------------------------------------------------------------

@(private = "file")
join_name :: proc(scope, name: string, allocator: Allocator) -> string {
	if scope == "" {
		return name
	}
	return strings.concatenate({scope, ".", name}, allocator)
}

@(private = "file")
define :: proc(c: ^Compiler, name: string, sym: Symbol, pos: Pos) {
	if existing, ok := c.symbols[name]; ok {
		if existing.kind == .Package && sym.kind == .Package {
			return
		}
		where_ := existing.file.path if existing.file != nil else "a package"
		error_at(&c.diags, pos, "'%s' is already defined (in %s)", name, where_)
		return
	}
	c.symbols[name] = sym
}

@(private = "file")
register_file :: proc(c: ^Compiler, f: ^File) {
	if f.package_name != "" {
		// Every prefix of the package is a package symbol, so that a
		// partially qualified name can resolve through it.
		parts := strings.split(f.package_name, ".", c.allocator)
		prefix := ""
		for part in parts {
			prefix = join_name(prefix, part, c.allocator)
			define(c, prefix, {kind = .Package}, {file = f.path})
		}
	}
	for m in f.messages {
		register_message(c, f, f.package_name, m)
	}
	for e in f.enums {
		e.full_name = join_name(f.package_name, e.name, c.allocator)
		define(c, e.full_name, {kind = .Enum, file = f, enum_ = e}, e.pos)
	}
	for s in f.services {
		s.full_name = join_name(f.package_name, s.name, c.allocator)
		define(c, s.full_name, {kind = .Service, file = f}, s.pos)
	}
}

@(private = "file")
register_message :: proc(c: ^Compiler, f: ^File, scope: string, m: ^Message) {
	m.full_name = join_name(scope, m.name, c.allocator)
	define(c, m.full_name, {kind = .Message, file = f, message = m}, m.pos)
	for nested in m.messages {
		register_message(c, f, m.full_name, nested)
	}
	for e in m.enums {
		e.full_name = join_name(m.full_name, e.name, c.allocator)
		define(c, e.full_name, {kind = .Enum, file = f, enum_ = e}, e.pos)
	}
}

// -----------------------------------------------------------------------------
// Resolution
// -----------------------------------------------------------------------------

// visible_files returns the files whose definitions f may reference: f
// itself, its direct imports, and anything those re-export via
// `import public` (transitively).
@(private = "file")
visible_files :: proc(c: ^Compiler, f: ^File) -> map[^File]bool {
	visible := make(map[^File]bool, c.allocator)
	visible[f] = true
	add_public :: proc(visible: ^map[^File]bool, g: ^File) {
		for imp in g.imports {
			if imp.public && imp.file != nil && !visible[imp.file] {
				visible[imp.file] = true
				add_public(visible, imp.file)
			}
		}
	}
	for imp in f.imports {
		if imp.file != nil {
			visible[imp.file] = true
			add_public(&visible, imp.file)
		}
	}
	return visible
}

@(private = "file")
is_type :: proc(s: Symbol) -> bool {
	return s.kind == .Message || s.kind == .Enum
}

// lookup_type resolves a (possibly relative) type name from `scope`
// following protobuf's C++-like scoping rules: the first component of the
// name is looked up from the innermost scope outwards, and the remaining
// components must then resolve inside whatever it found.
@(private = "file")
lookup_type :: proc(c: ^Compiler, scope, name: string) -> (sym: Symbol, full: string, ok: bool) {
	if strings.has_prefix(name, ".") {
		s, found := c.symbols[name[1:]]
		return s, name[1:], found && is_type(s)
	}
	first := name
	if dot := strings.index_byte(name, '.'); dot >= 0 {
		first = name[:dot]
	}
	s := scope
	for {
		candidate := join_name(s, first, c.allocator)
		if fs, found := c.symbols[candidate]; found {
			if first == name {
				if is_type(fs) {
					return fs, candidate, true
				}
				// A non-type (e.g. package) with this name: keep looking outwards.
			} else {
				full = join_name(s, name, c.allocator)
				rs, rfound := c.symbols[full]
				return rs, full, rfound && is_type(rs)
			}
		}
		if s == "" {
			return {}, "", false
		}
		if dot := strings.last_index_byte(s, '.'); dot >= 0 {
			s = s[:dot]
		} else {
			s = ""
		}
	}
}

@(private = "file")
resolve_type :: proc(c: ^Compiler, f: ^File, scope: string, t: ^Type_Ref, pos: Pos, visible: map[^File]bool) {
	if t.scalar != .None {
		return
	}
	sym, full, ok := lookup_type(c, scope, t.name)
	if !ok {
		if full != "" {
			error_at(&c.diags, pos, "'%s' resolved to '%s', which is not defined", t.name, full)
		} else {
			error_at(&c.diags, pos, "unknown type '%s'", t.name)
		}
		return
	}
	if !visible[sym.file] {
		error_at(&c.diags, pos, "'%s' is defined in '%s', which is not imported by '%s'", full, sym.file.path, f.path)
		return
	}
	t.message = sym.message
	t.enum_ = sym.enum_
}

@(private = "file")
resolve_message :: proc(c: ^Compiler, f: ^File, m: ^Message, visible: map[^File]bool) {
	for field in m.fields {
		if field.is_map {
			resolve_type(c, f, m.full_name, &field.map_value, field.pos, visible)
		} else {
			resolve_type(c, f, m.full_name, &field.type, field.pos, visible)
		}
	}
	for nested in m.messages {
		resolve_message(c, f, nested, visible)
	}
}

@(private = "file")
resolve_service :: proc(c: ^Compiler, f: ^File, s: ^Service, visible: map[^File]bool) {
	for method in s.methods {
		resolve_type(c, f, f.package_name, &method.input, method.pos, visible)
		resolve_type(c, f, f.package_name, &method.output, method.pos, visible)
	}
}

// -----------------------------------------------------------------------------
// Validation
// -----------------------------------------------------------------------------

@(private = "file")
in_ranges :: proc(ranges: []Range, v: i64) -> bool {
	for r in ranges {
		if v >= r.start && v <= r.end {
			return true
		}
	}
	return false
}

@(private = "file")
validate_message :: proc(c: ^Compiler, f: ^File, m: ^Message) {
	numbers := make(map[u32]^Field, c.allocator)
	names := make(map[string]bool, c.allocator)
	for field in m.fields {
		if prev, dup := numbers[field.number]; dup {
			error_at(&c.diags, field.pos, "field number %d is already used by '%s' in '%s'", field.number, prev.name, m.full_name)
		}
		numbers[field.number] = field
		if names[field.name] {
			error_at(&c.diags, field.pos, "field name '%s' is already used in '%s'", field.name, m.full_name)
		}
		names[field.name] = true
		if in_ranges(m.reserved_ranges[:], i64(field.number)) {
			error_at(&c.diags, field.pos, "field '%s' uses reserved field number %d", field.name, field.number)
		}
		if slice.contains(m.reserved_names[:], field.name) {
			error_at(&c.diags, field.pos, "field name '%s' is reserved", field.name)
		}
		if _, explicit := field.packed.?; explicit && (field.label != .Repeated || field.is_map || !is_packable(field.type)) {
			error_at(&c.diags, field.pos, "[packed] can only be specified for repeated primitive fields")
		}
		if e := field.map_value.enum_; field.is_map && e != nil && len(e.values) > 0 && e.values[0].number != 0 {
			error_at(&c.diags, field.pos, "enum '%s' is used as a map value, so its first value must be zero", e.full_name)
		}
		if dv, has_default := field.default_value.?; has_default {
			validate_default(c, field, dv)
		}
		if f.syntax == .Proto3 {
			// proto3 messages may not use proto2 closed enums.
			e := field.map_value.enum_ if field.is_map else field.type.enum_
			if e != nil && e.file.syntax == .Proto2 {
				error_at(&c.diags, field.pos, "enum '%s' is a proto2 enum and cannot be used in a proto3 message", e.full_name)
			}
		}
	}
	for o in m.oneofs {
		if names[o.name] {
			error_at(&c.diags, o.pos, "oneof name '%s' conflicts with a field name in '%s'", o.name, m.full_name)
		}
	}
	for nested in m.messages {
		validate_message(c, f, nested)
	}
	for e in m.enums {
		validate_enum(c, f, e)
	}
}

// validate_default checks a proto2 `[default = ...]` against the field type.
@(private = "file")
validate_default :: proc(c: ^Compiler, f: ^Field, v: Constant) {
	if f.label == .Repeated || f.is_map || f.type.message != nil {
		error_at(&c.diags, v.pos, "default values are only allowed on singular scalar and enum fields")
		return
	}
	if e := f.type.enum_; e != nil {
		if v.kind == .Ident {
			for ev in e.values {
				if ev.name == v.text {
					return
				}
			}
		}
		error_at(&c.diags, v.pos, "default value for '%s' must be a value of enum '%s'", f.name, e.full_name)
		return
	}
	ok := false
	#partial switch f.type.scalar {
	case .String, .Bytes:
		ok = v.kind == .String
	case .Bool:
		ok = v.kind == .Ident && (v.text == "true" || v.text == "false")
	case .Float, .Double:
		ok = v.kind == .Int || v.kind == .Float || (v.kind == .Ident && (v.text == "inf" || v.text == "nan"))
	case:
		// Integer types: range-checked by the generator, which converts them.
		ok = v.kind == .Int && integer_default_in_range(f.type.scalar, v.text)
	}
	if !ok {
		error_at(&c.diags, v.pos, "invalid default value '%s' for field '%s' of type %s", v.text, f.name, SCALAR_NAMES[f.type.scalar])
	}
}

// parse_signed_literal parses an Int constant text, which may carry a
// leading '-', into a sign and magnitude.
parse_signed_literal :: proc(text: string) -> (negative: bool, magnitude: u64, ok: bool) {
	t := text
	if len(t) > 0 && t[0] == '-' {
		negative = true
		t = t[1:]
	}
	magnitude, ok = parse_int_literal(t)
	return
}

@(private = "file")
integer_default_in_range :: proc(s: Scalar, text: string) -> bool {
	negative, mag, ok := parse_signed_literal(text)
	if !ok {
		return false
	}
	#partial switch s {
	case .Int32, .Sint32, .Sfixed32:
		return mag <= (u64(max(i32)) + 1 if negative else u64(max(i32)))
	case .Int64, .Sint64, .Sfixed64:
		return mag <= (u64(max(i64)) + 1 if negative else u64(max(i64)))
	case .Uint32, .Fixed32:
		return !negative && mag <= u64(max(u32))
	case .Uint64, .Fixed64:
		return !negative
	}
	return false
}

is_packable :: proc(t: Type_Ref) -> bool {
	if t.enum_ != nil {
		return true
	}
	return t.scalar != .None && t.scalar != .String && t.scalar != .Bytes
}

@(private = "file")
validate_enum :: proc(c: ^Compiler, f: ^File, e: ^Enum) {
	if len(e.values) == 0 {
		return
	}
	if f.syntax == .Proto3 && e.values[0].number != 0 {
		error_at(&c.diags, e.values[0].pos, "the first enum value must be zero in proto3")
	}
	numbers := make(map[i32]string, c.allocator)
	names := make(map[string]bool, c.allocator)
	aliased := false
	for v in e.values {
		if names[v.name] {
			error_at(&c.diags, v.pos, "enum value '%s' is already defined in '%s'", v.name, e.full_name)
		}
		names[v.name] = true
		if prev, dup := numbers[v.number]; dup {
			aliased = true
			if !e.allow_alias {
				error_at(&c.diags, v.pos, "'%s' uses the same value as '%s'; set option allow_alias = true to allow this", v.name, prev)
			}
		} else {
			numbers[v.number] = v.name
		}
		if in_ranges(e.reserved_ranges[:], i64(v.number)) {
			error_at(&c.diags, v.pos, "enum value '%s' uses reserved number %d", v.name, v.number)
		}
		if slice.contains(e.reserved_names[:], v.name) {
			error_at(&c.diags, v.pos, "enum value name '%s' is reserved", v.name)
		}
	}
	if e.allow_alias && !aliased {
		error_at(&c.diags, e.pos, "enum '%s' sets allow_alias but has no aliased values", e.full_name)
	}
}

@(private = "file")
validate_service :: proc(c: ^Compiler, s: ^Service) {
	names := make(map[string]bool, c.allocator)
	for m in s.methods {
		if names[m.name] {
			error_at(&c.diags, m.pos, "method '%s' is already defined in service '%s'", m.name, s.full_name)
		}
		names[m.name] = true
		if m.input.message == nil && m.input.enum_ != nil {
			error_at(&c.diags, m.pos, "method input type '%s' must be a message", m.input.name)
		}
		if m.output.message == nil && m.output.enum_ != nil {
			error_at(&c.diags, m.pos, "method output type '%s' must be a message", m.output.name)
		}
	}
}
