package protoc

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

/*
Descriptor generation: builds the google.protobuf.FileDescriptorProto of a
parsed file, serialized exactly as Google's protoc does (fields in number
order, synthesized map-entry messages, synthetic oneofs for proto3
`optional`, computed json_name, standard options). Generated code embeds
these bytes so that servers can offer gRPC server reflection.

Custom options (extensions such as `(google.api.http)`) are not encoded:
odin-protoc does not resolve extensions.
*/

// -----------------------------------------------------------------------------
// Minimal forward protobuf writer
// -----------------------------------------------------------------------------

@(private = "file")
W :: struct {
	buf: [dynamic]u8,
}

@(private = "file")
w_make :: proc(a: Allocator) -> W {
	return {buf = make([dynamic]u8, a)}
}

@(private = "file")
w_varint :: proc(w: ^W, v: u64) {
	v := v
	for v >= 0x80 {
		append(&w.buf, u8(v) | 0x80)
		v >>= 7
	}
	append(&w.buf, u8(v))
}

@(private = "file")
w_tag :: proc(w: ^W, field, wire: u32) {
	w_varint(w, u64(field) << 3 | u64(wire))
}

@(private = "file")
w_string :: proc(w: ^W, field: u32, s: string) {
	w_tag(w, field, 2)
	w_varint(w, u64(len(s)))
	append(&w.buf, s)
}

@(private = "file")
w_int :: proc(w: ^W, field: u32, v: i64) {
	w_tag(w, field, 0)
	w_varint(w, u64(v)) // negative int32 values are sign-extended
}

@(private = "file")
w_bool :: proc(w: ^W, field: u32, v: bool) {
	w_tag(w, field, 0)
	w_varint(w, 1 if v else 0)
}

@(private = "file")
w_message :: proc(w: ^W, field: u32, sub: ^W) {
	w_tag(w, field, 2)
	w_varint(w, u64(len(sub.buf)))
	append(&w.buf, ..sub.buf[:])
}

// -----------------------------------------------------------------------------
// Standard options
// -----------------------------------------------------------------------------

@(private = "file")
Option_Kind :: enum u8 {
	Bool,
	String,
	Enum,
}

@(private = "file")
Option_Spec :: struct {
	name:   string,
	number: u32,
	kind:   Option_Kind,
	values: []string, // enum value names; index = number
}

@(private = "file", rodata)
FILE_OPTIONS := [?]Option_Spec {
	{"java_package", 1, .String, nil},
	{"java_outer_classname", 8, .String, nil},
	{"optimize_for", 9, .Enum, {"", "SPEED", "CODE_SIZE", "LITE_RUNTIME"}},
	{"java_multiple_files", 10, .Bool, nil},
	{"go_package", 11, .String, nil},
	{"cc_generic_services", 16, .Bool, nil},
	{"java_generic_services", 17, .Bool, nil},
	{"py_generic_services", 18, .Bool, nil},
	{"java_generate_equals_and_hash", 20, .Bool, nil},
	{"deprecated", 23, .Bool, nil},
	{"java_string_check_utf8", 27, .Bool, nil},
	{"cc_enable_arenas", 31, .Bool, nil},
	{"objc_class_prefix", 36, .String, nil},
	{"csharp_namespace", 37, .String, nil},
	{"swift_prefix", 39, .String, nil},
	{"php_class_prefix", 40, .String, nil},
	{"php_namespace", 41, .String, nil},
	{"php_metadata_namespace", 44, .String, nil},
	{"ruby_package", 45, .String, nil},
}
@(private = "file", rodata)
MESSAGE_OPTIONS := [?]Option_Spec {
	{"message_set_wire_format", 1, .Bool, nil},
	{"no_standard_descriptor_accessor", 2, .Bool, nil},
	{"deprecated", 3, .Bool, nil},
	{"map_entry", 7, .Bool, nil},
}
@(private = "file", rodata)
FIELD_OPTIONS := [?]Option_Spec {
	{"ctype", 1, .Enum, {"STRING", "CORD", "STRING_PIECE"}},
	{"packed", 2, .Bool, nil},
	{"deprecated", 3, .Bool, nil},
	{"lazy", 5, .Bool, nil},
	{"jstype", 6, .Enum, {"JS_NORMAL", "JS_STRING", "JS_NUMBER"}},
	{"weak", 10, .Bool, nil},
	{"unverified_lazy", 15, .Bool, nil},
	{"debug_redact", 16, .Bool, nil},
}
@(private = "file", rodata)
ENUM_OPTIONS := [?]Option_Spec{{"allow_alias", 2, .Bool, nil}, {"deprecated", 3, .Bool, nil}}
@(private = "file", rodata)
ENUM_VALUE_OPTIONS := [?]Option_Spec{{"deprecated", 1, .Bool, nil}, {"debug_redact", 3, .Bool, nil}}
@(private = "file", rodata)
SERVICE_OPTIONS := [?]Option_Spec{{"deprecated", 33, .Bool, nil}}
@(private = "file", rodata)
METHOD_OPTIONS := [?]Option_Spec {
	{"deprecated", 33, .Bool, nil},
	{"idempotency_level", 34, .Enum, {"IDEMPOTENCY_UNKNOWN", "NO_SIDE_EFFECTS", "IDEMPOTENT"}},
}

// write_options encodes the recognized standard options (in field-number
// order; the last occurrence of an option wins). Returns false if none.
@(private = "file")
write_options :: proc(out: ^W, field: u32, options: []Option, specs: []Option_Spec, a: Allocator, extra_bool: Maybe(u32) = nil, force := false) -> bool {
	Entry :: struct {
		spec:  ^Option_Spec,
		value: Constant,
	}
	found := make([dynamic]Entry, a)
	for &spec in specs {
		#reverse for o in options {
			if o.name == spec.name {
				append(&found, Entry{&spec, o.value})
				break
			}
		}
	}
	if len(found) == 0 && extra_bool == nil && !force {
		return false
	}
	slice.sort_by(found[:], proc(x, y: Entry) -> bool {return x.spec.number < y.spec.number})
	sub := w_make(a)
	for e in found {
		switch e.spec.kind {
		case .Bool:
			w_bool(&sub, e.spec.number, e.value.text == "true")
		case .String:
			w_string(&sub, e.spec.number, e.value.text)
		case .Enum:
			for name, i in e.spec.values {
				if name != "" && name == e.value.text {
					w_int(&sub, e.spec.number, i64(i))
				}
			}
		}
	}
	if n, ok := extra_bool.?; ok {
		w_bool(&sub, n, true)
	}
	w_message(out, field, &sub)
	return true
}

// -----------------------------------------------------------------------------
// Descriptor building
// -----------------------------------------------------------------------------

// build_file_descriptor returns the serialized FileDescriptorProto of f.
build_file_descriptor :: proc(f: ^File, a: Allocator) -> []u8 {
	w := w_make(a)
	w_string(&w, 1, f.path)
	if f.package_name != "" {
		w_string(&w, 2, f.package_name)
	}
	for imp in f.imports {
		w_string(&w, 3, imp.path)
	}
	for m in f.messages {
		sub := message_descriptor(m, a)
		w_message(&w, 4, &sub)
	}
	for e in f.enums {
		sub := enum_descriptor(e, a)
		w_message(&w, 5, &sub)
	}
	for s in f.services {
		sub := service_descriptor(s, a)
		w_message(&w, 6, &sub)
	}
	for ext in f.extensions {
		sub := field_descriptor(nil, ext, nil, a)
		w_message(&w, 7, &sub)
	}
	write_options(&w, 8, f.options[:], FILE_OPTIONS[:], a)
	for imp, i in f.imports {
		if imp.public {
			w_int(&w, 10, i64(i))
		}
	}
	for imp, i in f.imports {
		if imp.weak {
			w_int(&w, 11, i64(i))
		}
	}
	if f.syntax == .Proto3 {
		w_string(&w, 12, "proto3")
	}
	return w.buf[:]
}

@(private = "file")
message_descriptor :: proc(m: ^Message, a: Allocator) -> W {
	w := w_make(a)
	w_string(&w, 1, m.name)

	// Oneof indexes: real oneofs first, then one synthetic oneof per proto3
	// `optional` field, in field order.
	oneof_index := make(map[^Field]int, a)
	synthetic := make([dynamic]^Field, a)
	for o, i in m.oneofs {
		for f in o.fields {
			oneof_index[f] = i
		}
	}
	for f in m.fields {
		if is_proto3_optional(f) {
			oneof_index[f] = len(m.oneofs) + len(synthetic)
			append(&synthetic, f)
		}
	}

	for f in m.fields {
		sub := field_descriptor(m, f, oneof_index, a)
		w_message(&w, 2, &sub)
	}
	for item in m.nested_order {
		switch v in item {
		case ^Message:
			sub := message_descriptor(v, a)
			w_message(&w, 3, &sub)
		case ^Field:
			sub := map_entry_descriptor(v, a)
			w_message(&w, 3, &sub)
		}
	}
	for e in m.enums {
		sub := enum_descriptor(e, a)
		w_message(&w, 4, &sub)
	}
	message_set := false
	for o in m.options {
		if o.name == "message_set_wire_format" {
			message_set = o.value.text == "true"
		}
	}
	for r in m.extension_ranges {
		sub := w_make(a)
		w_int(&sub, 1, r.start)
		// Message sets allow any int32 extension number ("max").
		end := r.end + 1 // exclusive
		if message_set && r.end == MAX_FIELD {
			end = i64(max(i32))
		}
		w_int(&sub, 2, end)
		w_message(&w, 5, &sub)
	}
	for ext in m.extensions {
		sub := field_descriptor(m, ext, nil, a)
		w_message(&w, 6, &sub)
	}
	write_options(&w, 7, m.options[:], MESSAGE_OPTIONS[:], a)
	for o in m.oneofs {
		sub := w_make(a)
		w_string(&sub, 1, o.name)
		w_message(&w, 8, &sub)
	}
	for f in synthetic {
		sub := w_make(a)
		w_string(&sub, 1, strings.concatenate({"_", f.name}, a))
		w_message(&w, 8, &sub)
	}
	for r in m.reserved_ranges {
		sub := w_make(a)
		w_int(&sub, 1, r.start)
		w_int(&sub, 2, r.end + 1) // exclusive
		w_message(&w, 9, &sub)
	}
	for n in m.reserved_names {
		w_string(&w, 10, n)
	}
	return w
}

@(private = "file")
is_proto3_optional :: proc(f: ^Field) -> bool {
	return f.file.syntax == .Proto3 && f.label == .Optional && f.oneof == nil
}

// Descriptor field type numbers (FieldDescriptorProto.Type).
@(private = "file")
type_number :: proc(t: Type_Ref) -> i64 {
	if t.message != nil {
		return 11
	}
	if t.enum_ != nil {
		return 14
	}
	switch t.scalar {
	case .Double:
		return 1
	case .Float:
		return 2
	case .Int64:
		return 3
	case .Uint64:
		return 4
	case .Int32:
		return 5
	case .Fixed64:
		return 6
	case .Fixed32:
		return 7
	case .Bool:
		return 8
	case .String:
		return 9
	case .Bytes:
		return 12
	case .Uint32:
		return 13
	case .Sfixed32:
		return 15
	case .Sfixed64:
		return 16
	case .Sint32:
		return 17
	case .Sint64:
		return 18
	case .None:
	}
	unreachable()
}

@(private = "file")
type_name_of :: proc(t: Type_Ref, a: Allocator) -> string {
	if t.message != nil {
		return strings.concatenate({".", t.message.full_name}, a)
	}
	if t.enum_ != nil {
		return strings.concatenate({".", t.enum_.full_name}, a)
	}
	return ""
}

// json_name follows protoc: underscores removed, the following letter
// upper-cased.
json_name_of :: proc(name: string, a: Allocator) -> string {
	b := strings.builder_make(a)
	upper := false
	for i in 0 ..< len(name) {
		c := name[i]
		if c == '_' {
			upper = true
			continue
		}
		if upper && c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		upper = false
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// map_entry_name follows protoc: "by_name" -> "ByNameEntry".
@(private = "file")
map_entry_name :: proc(field: string, a: Allocator) -> string {
	b := strings.builder_make(a)
	upper := true
	for i in 0 ..< len(field) {
		c := field[i]
		if c == '_' {
			upper = true
			continue
		}
		if upper && c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		upper = false
		strings.write_byte(&b, c)
	}
	strings.write_string(&b, "Entry")
	return strings.to_string(b)
}

@(private = "file")
field_descriptor :: proc(m: ^Message, f: ^Field, oneof_index: map[^Field]int, a: Allocator) -> W {
	w := w_make(a)
	w_string(&w, 1, f.name)
	if f.is_extension && f.extendee.message != nil {
		w_string(&w, 2, strings.concatenate({".", f.extendee.message.full_name}, a))
	}
	w_int(&w, 3, i64(f.number))
	label: i64 = 1
	#partial switch f.label {
	case .Required:
		label = 2
	case .Repeated:
		label = 3
	}
	w_int(&w, 4, label)
	if f.is_map {
		w_int(&w, 5, 11)
		w_string(&w, 6, strings.concatenate({".", m.full_name, ".", map_entry_name(f.name, a)}, a))
	} else {
		w_int(&w, 5, type_number(f.type))
		if tn := type_name_of(f.type, a); tn != "" {
			w_string(&w, 6, tn)
		}
	}
	if dv, has := f.default_value.?; has {
		w_string(&w, 7, default_text(f, dv, a))
	}
	write_options(&w, 8, f.options[:], FIELD_OPTIONS[:], a)
	if idx, ok := oneof_index[f]; ok {
		w_int(&w, 9, i64(idx))
	}
	// Like protoc's embedded descriptors, json_name is only recorded when it
	// was given explicitly (readers derive the default, json_name_of), except
	// for files that record it everywhere (the well-known types).
	if jn, explicit := f.json_name.?; explicit {
		w_string(&w, 10, jn)
	} else if f.file.all_json_names {
		w_string(&w, 10, json_name_of(f.name, a))
	}
	if is_proto3_optional(f) {
		w_bool(&w, 17, true)
	}
	return w
}

@(private = "file")
map_entry_descriptor :: proc(f: ^Field, a: Allocator) -> W {
	w := w_make(a)
	w_string(&w, 1, map_entry_name(f.name, a))
	entry_field :: proc(w: ^W, name: string, number: i64, t: Type_Ref, json: bool, a: Allocator) {
		sub := w_make(a)
		w_string(&sub, 1, name)
		w_int(&sub, 3, number)
		w_int(&sub, 4, 1)
		w_int(&sub, 5, type_number(t))
		if tn := type_name_of(t, a); tn != "" {
			w_string(&sub, 6, tn)
		}
		if json {
			w_string(&sub, 10, name)
		}
		w_message(w, 2, &sub)
	}
	entry_field(&w, "key", 1, {scalar = f.map_key}, f.file.all_json_names, a)
	entry_field(&w, "value", 2, f.map_value, f.file.all_json_names, a)
	write_options(&w, 7, nil, MESSAGE_OPTIONS[:], a, extra_bool = u32(7))
	return w
}

@(private = "file")
enum_descriptor :: proc(e: ^Enum, a: Allocator) -> W {
	w := w_make(a)
	w_string(&w, 1, e.name)
	for v in e.values {
		sub := w_make(a)
		w_string(&sub, 1, v.name)
		w_int(&sub, 2, i64(v.number))
		write_options(&sub, 3, v.options[:], ENUM_VALUE_OPTIONS[:], a)
		w_message(&w, 2, &sub)
	}
	write_options(&w, 3, e.options[:], ENUM_OPTIONS[:], a)
	for r in e.reserved_ranges {
		sub := w_make(a)
		w_int(&sub, 1, r.start)
		w_int(&sub, 2, r.end) // inclusive for enums
		w_message(&w, 4, &sub)
	}
	for n in e.reserved_names {
		w_string(&w, 5, n)
	}
	return w
}

@(private = "file")
service_descriptor :: proc(s: ^Service, a: Allocator) -> W {
	w := w_make(a)
	w_string(&w, 1, s.name)
	for m in s.methods {
		sub := w_make(a)
		w_string(&sub, 1, m.name)
		w_string(&sub, 2, type_name_of(m.input, a))
		w_string(&sub, 3, type_name_of(m.output, a))
		// A method declared with a `{...}` body records options even when
		// none are standard ones (protoc writes an empty MethodOptions).
		write_options(&sub, 4, m.options[:], METHOD_OPTIONS[:], a, force = m.has_body)
		if m.client_streaming {
			w_bool(&sub, 5, true)
		}
		if m.server_streaming {
			w_bool(&sub, 6, true)
		}
		w_message(&w, 2, &sub)
	}
	write_options(&w, 3, s.options[:], SERVICE_OPTIONS[:], a)
	return w
}

// -----------------------------------------------------------------------------
// Default values, formatted like protoc
// -----------------------------------------------------------------------------

@(private = "file")
default_text :: proc(f: ^Field, v: Constant, a: Allocator) -> string {
	if f.type.enum_ != nil {
		return v.text
	}
	#partial switch f.type.scalar {
	case .String:
		return v.text
	case .Bytes:
		return c_escape(v.text, a)
	case .Bool:
		return v.text
	case .Float, .Double:
		text := v.text
		switch text {
		case "inf", "-inf", "nan":
			return text
		case "-nan":
			return "nan"
		}
		if v.kind == .Int {
			negative, mag, ok := parse_signed_literal(text)
			x := f64(mag)
			if !ok {
				// Too large for u64 (e.g. 1e20 written as an integer).
				x, _ = strconv.parse_f64(strings.trim_prefix(text, "-"))
			}
			return format_g(-x if negative else x, f.type.scalar == .Float, a)
		}
		x, _ := strconv.parse_f64(strings.trim_right(text, "fF"))
		return format_g(x, f.type.scalar == .Float, a)
	}
	negative, mag, _ := parse_signed_literal(v.text)
	return fmt.aprintf("%s%d", "-" if negative else "", mag, allocator = a)
}

// c_escape escapes bytes like protoc's CEscape (octal for non-printables).
@(private = "file")
c_escape :: proc(s: string, a: Allocator) -> string {
	b := strings.builder_make(a)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case '"':
			strings.write_string(&b, "\\\"")
		case '\'':
			strings.write_string(&b, "\\'")
		case '\\':
			strings.write_string(&b, "\\\\")
		case:
			if c < 0x20 || c >= 0x7f {
				fmt.sbprintf(&b, "\\%03o", c)
			} else {
				strings.write_byte(&b, c)
			}
		}
	}
	return strings.to_string(b)
}

// format_g renders x like C's printf("%.*g") with the shortest of 15/17
// (double) or 6/9 (float) significant digits that round-trips, which is
// what protoc's SimpleDtoa/SimpleFtoa do.
@(private = "file")
format_g :: proc(x: f64, is_float: bool, a: Allocator) -> string {
	short, long := 15, 17
	if is_float {
		short, long = 6, 9
	}
	s := c_format_g(x, short, a)
	back, _ := strconv.parse_f64(s)
	ok := back == x
	if is_float {
		ok = f32(back) == f32(x)
	}
	if !ok {
		s = c_format_g(x, long, a)
	}
	return s
}

// c_format_g implements C's %.<p>g for finite x.
@(private = "file")
c_format_g :: proc(x: f64, p: int, a: Allocator) -> string {
	if x == 0 {
		return "-0" if math.sign_bit(x) else "0"
	}
	// %.<p-1>e gives the correctly rounded mantissa and exponent.
	e_text := fmt.aprintf(fmt.aprintf("%%.%de", p - 1, allocator = a), x, allocator = a)
	e_pos := strings.index_any(e_text, "eE")
	mantissa := e_text[:e_pos]
	exp, _ := strconv.parse_int(e_text[e_pos + 1:])
	negative := strings.has_prefix(mantissa, "-")
	digits, _ := strings.remove_all(strings.trim_prefix(mantissa, "-"), ".", a)
	b := strings.builder_make(a)
	if negative {
		strings.write_byte(&b, '-')
	}
	if exp < -4 || exp >= p {
		// Exponential: d.ddd, trailing zeros removed, exponent >= 2 digits.
		frac := strings.trim_right(digits[1:], "0")
		strings.write_byte(&b, digits[0])
		if len(frac) > 0 {
			strings.write_byte(&b, '.')
			strings.write_string(&b, frac)
		}
		sign := "-" if exp < 0 else "+"
		fmt.sbprintf(&b, "e%s%02d", sign, abs(exp))
		return strings.to_string(b)
	}
	// Fixed notation with p - 1 - exp decimals, trailing zeros removed.
	if exp < 0 {
		strings.write_string(&b, "0.")
		for _ in 0 ..< -exp - 1 {
			strings.write_byte(&b, '0')
		}
		strings.write_string(&b, strings.trim_right(digits, "0"))
		return strings.to_string(b)
	}
	int_part := digits[:exp + 1]
	frac := strings.trim_right(digits[exp + 1:], "0")
	strings.write_string(&b, int_part)
	if len(frac) > 0 {
		strings.write_byte(&b, '.')
		strings.write_string(&b, frac)
	}
	return strings.to_string(b)
}
