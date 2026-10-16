// odin-protoc compiles .proto files into Odin source code for the protobuf
// and grpc runtime packages of this repository.
//
//     odin-protoc [options] <file.proto>...
//
// See `odin-protoc --help` for options.
package odin_protoc

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import vmem "core:mem/virtual"

import "../../protoc"

USAGE :: `usage: odin-protoc [options] <file.proto>...

Compiles .proto files (and everything they import) into one Odin package.

options:
  -I <dir>, --proto_path=<dir>   add an import search directory (repeatable);
                                 defaults to the directory of each input file
  -o <dir>, --out=<dir>          output directory (required)
  --package=<name>               Odin package name (default: output dir name)
  --protobuf-import=<path>       import path of the protobuf runtime
                                 (default: "grpc:protobuf")
  --grpc-import=<path>           import path of the grpc runtime
                                 (default: "grpc:grpc")
  --no-services                  do not generate gRPC client/server code
  -h, --help                     show this help
`

main :: proc() {
	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		fmt.eprintln("odin-protoc: out of memory")
		os.exit(1)
	}
	allocator := vmem.arena_allocator(&arena)
	context.allocator = allocator
	code := run(os.args[1:], allocator)
	vmem.arena_destroy(&arena)
	os.exit(code)
}

Args :: struct {
	includes:        [dynamic]string,
	inputs:          [dynamic]string,
	out_dir:         string,
	package_name:    string,
	protobuf_import: string,
	grpc_import:     string,
	no_services:     bool,
}

run :: proc(argv: []string, allocator: protoc.Allocator) -> int {
	args, ok := parse_args(argv)
	if !ok {
		return 2
	}

	c: protoc.Compiler
	protoc.compiler_init(&c, allocator)
	for dir in args.includes {
		protoc.compiler_add_include_path(&c, dir)
	}

	// Map each input to its import path relative to an include directory.
	import_paths := make([dynamic]string)
	for input in args.inputs {
		import_path, found := relative_to_includes(input, args.includes[:])
		if !found {
			dir := filepath.dir(input)
			protoc.compiler_add_include_path(&c, dir)
			import_path = filepath.base(input)
		}
		append(&import_paths, import_path)
	}
	for p in import_paths {
		protoc.compiler_add_input(&c, p)
	}
	if !protoc.compiler_resolve(&c) {
		print_diagnostics(&c)
		return 1
	}

	opts := protoc.Gen_Options {
		package_name      = args.package_name,
		protobuf_import   = args.protobuf_import,
		grpc_import       = args.grpc_import,
		generate_services = !args.no_services,
	}
	files, gen_ok := protoc.generate(&c, opts)
	if !gen_ok {
		print_diagnostics(&c)
		return 1
	}

	if err := os.make_directory_all(args.out_dir); err != nil && !os.exists(args.out_dir) {
		fmt.eprintfln("odin-protoc: cannot create output directory '%s': %v", args.out_dir, err)
		return 1
	}
	for f in files {
		path, _ := filepath.join({args.out_dir, f.name})
		if err := os.write_entire_file(path, transmute([]u8)f.content); err != nil {
			fmt.eprintfln("odin-protoc: cannot write '%s': %v", path, err)
			return 1
		}
	}
	return 0
}

parse_args :: proc(argv: []string) -> (args: Args, ok: bool) {
	args.includes = make([dynamic]string)
	args.inputs = make([dynamic]string)
	value_of :: proc(argv: []string, i: ^int, flag: string) -> (string, bool) {
		arg := argv[i^]
		if eq := strings.index_byte(arg, '='); eq >= 0 {
			return arg[eq + 1:], true
		}
		if i^ + 1 >= len(argv) {
			fmt.eprintfln("odin-protoc: %s requires a value", flag)
			return "", false
		}
		i^ += 1
		return argv[i^], true
	}
	for i := 0; i < len(argv); i += 1 {
		arg := argv[i]
		name := arg
		if eq := strings.index_byte(arg, '='); eq >= 0 {
			name = arg[:eq]
		}
		switch name {
		case "-h", "--help":
			fmt.print(USAGE)
			os.exit(0)
		case "-I", "--proto_path":
			v := value_of(argv, &i, name) or_return
			append(&args.includes, v)
		case "-o", "--out":
			args.out_dir = value_of(argv, &i, name) or_return
		case "--package":
			args.package_name = value_of(argv, &i, name) or_return
		case "--protobuf-import":
			args.protobuf_import = value_of(argv, &i, name) or_return
		case "--grpc-import":
			args.grpc_import = value_of(argv, &i, name) or_return
		case "--no-services":
			args.no_services = true
		case:
			if strings.has_prefix(arg, "-I") && len(arg) > 2 {
				append(&args.includes, arg[2:])
			} else if strings.has_prefix(arg, "-") {
				fmt.eprintfln("odin-protoc: unknown option '%s'\n", arg)
				fmt.eprint(USAGE)
				return args, false
			} else {
				append(&args.inputs, arg)
			}
		}
	}
	if len(args.inputs) == 0 {
		fmt.eprint(USAGE)
		return args, false
	}
	if args.out_dir == "" {
		fmt.eprintln("odin-protoc: --out is required")
		return args, false
	}
	if args.package_name == "" {
		cleaned, _ := filepath.clean(args.out_dir)
		args.package_name = filepath.base(cleaned)
	}
	return args, true
}

// relative_to_includes returns input relative to the first include
// directory that contains it, with forward slashes.
relative_to_includes :: proc(input: string, includes: []string) -> (string, bool) {
	abs_input, err := filepath.abs(input)
	if err != nil {
		return "", false
	}
	for dir in includes {
		abs_dir, dir_err := filepath.abs(dir)
		if dir_err != nil {
			continue
		}
		rel, err := filepath.rel(abs_dir, abs_input)
		if err != nil || strings.has_prefix(rel, "..") {
			continue
		}
		slashed, _ := strings.replace_all(rel, "\\", "/")
		return slashed, true
	}
	return "", false
}

print_diagnostics :: proc(c: ^protoc.Compiler) {
	for d in c.diags.list {
		if d.pos.file != "" {
			fmt.eprintfln("%s:%d:%d: error: %s", d.pos.file, d.pos.line, d.pos.column, d.message)
		} else {
			fmt.eprintfln("error: %s", d.message)
		}
	}
}
