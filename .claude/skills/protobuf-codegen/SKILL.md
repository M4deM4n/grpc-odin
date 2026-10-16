---
name: protobuf-codegen
description: How to change the .proto compiler (protoc/) and the protobuf runtime (protobuf/) safely - generated-code conventions, naming rules, the regenerate/conformance workflow and reference fixtures. Use when touching protoc/, protobuf/ or generated message code.
---

# Changing odin-protoc and the protobuf runtime

## Pipeline
`lexer.odin` -> `parser.odin` (AST in `ast.odin`) -> `compiler.odin`
(load imports, symbols, scoped name resolution, visibility, validation) ->
`gen.odin` (messages) + `gen_service.odin` (gRPC stubs). Embedded
well-known types live in `well_known.odin`.

## Generated code contract
- One `<path_with_underscores>.pb.odin` per loaded .proto, plus
  `package.groups.odin` (proc groups `size`, `marshal`, `unmarshal`,
  `destroy`). All loaded files go into ONE Odin package.
- Types: nested names joined with `_`; types from packages other than the
  inputs' packages are prefixed (`Google_Protobuf_Timestamp`).
- Field mapping: implicit scalars -> `T`; explicit presence -> `Maybe(T)`;
  singular messages -> `^Msg`; repeated -> `[dynamic]T`; maps ->
  `map[K]V`; oneofs -> union of `distinct` case types
  `<Msg>_<Oneof>_<Field>`; `_unknown_fields: [dynamic]u8` on every message.
- Per message: `_size`, `_encode_fields` (backwards), `_decode_fields`,
  `_marshal`, `_unmarshal`, `_destroy`, `_CODEC` (`pb.Message_Codec`).
- Closed (proto2) enums get `<Enum>_is_known`; undeclared values go to
  unknown fields. proto2 defaults become `<Msg>_<field>_DEFAULT` constants.
- Names that are Odin keywords/builtins get a `_` suffix (made unique);
  type names equal to generated locals (`m`, `d`, `e`, ...) are errors.

## Workflow for a change
1. Edit the generator/runtime.
2. `sh scripts/test.sh protobuf` (rebuilds the CLI and regenerates
   `tests/protobuf/gen`). Generated code must pass `-vet -strict-style`.
3. Inspect generated output for the affected construct in
   `tests/protobuf/gen/*.pb.odin`.
4. If the wire behavior changed, extend `interop/python/gen_fixtures.py`,
   regenerate fixtures
   (`interop/python/.venv/Scripts/python -I interop/python/gen_fixtures.py`)
   and add a conformance test in `tests/protobuf/conformance_test.odin`
   (byte-for-byte both directions).
5. Add edge cases to `tests/protobuf/proto/test_all.proto` /
   `legacy.proto` and compiler diagnostics tests to `tests/protoc`.

Set up the Python venv once:
`python -m venv interop/python/.venv && interop/python/.venv/Scripts/python -m pip install -r interop/python/requirements.txt`.

## Invariants to preserve
- Count pass (`pb.count_repeated`) and decode pass accept exactly the same
  wire types per field.
- Encode writes fields in descending number order so output is ascending.
- `_size` is exact: `marshal` asserts the encoder filled the buffer.
- Decoding never trusts lengths; replaced values are freed unless aliasing.
