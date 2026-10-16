# AGENTS.md: development guide for odin-grpc

A pure-Odin, production-grade implementation of Protocol Buffers and gRPC
(HTTP/2, cleartext h2c). Read this file before changing anything; the
project-specific skills in `.claude/skills/` hold the detailed checklists.

## Hard rules

1. **Pure Odin.** Library code uses only `core:`/`base:` packages. No C, no
   foreign imports, no vendored code. Python and Go appear *only* under
   `interop/` as reference peers for testing.
2. **Do not look outside the repository** for reference code (that includes
   the Odin standard library sources on disk). Use the specs (RFC 9113,
   RFC 7541, protobuf encoding spec, gRPC PROTOCOL-HTTP2.md) and verify
   stdlib APIs by compiling small probes in a scratch directory.
3. **Never panic on untrusted input.** Every byte from the network or a
   decoder input must be bounds-checked and turned into an error value.
   `assert` is only for programmer errors (violated preconditions).
4. **Avoid unnecessary dynamic allocation.** Prefer caller-provided buffers,
   arenas, reused scratch buffers and exact-size allocations. Every
   allocation must have an obvious owner and lifetime (see "Memory").
5. **Everything compiles with `-vet -strict-style`**, including generated code.
6. **Review before commit.** Run the `code-review-checklist` skill over the
   diff, fix findings, run `sh scripts/test.sh`, then commit. Never commit
   with failing tests or leaks reported by the test runner.

## Layout

| Path | Package | Purpose |
|------|---------|---------|
| `hpack/` | `hpack` | RFC 7541 header compression (tables generated from the RFC) |
| `http2/` | `http2` | RFC 9113 framing: parse/validate/serialize, no I/O |
| `protobuf/` | `protobuf` | Wire-format runtime used by generated code |
| `protoc/` | `protoc` | `.proto` lexer/parser/resolver and Odin code generator |
| `grpc/` | `grpc` | gRPC client and server over HTTP/2 |
| `cmd/odin-protoc/` | | CLI for `protoc` |
| `tools/gen_hpack_tables/` | | Regenerates `hpack/tables_generated.odin` from RFC 7541 |
| `tests/<suite>/` | `<suite>_test` | One test package per library package |
| `interop/` | | Reference-implementation peers (Python grpcio) and fixture generator |
| `examples/` | | Runnable examples |

Library packages import each other with relative paths (`"../protobuf"`).
Generated code imports the runtime through the `grpc` collection
(`"grpc:protobuf"`, `"grpc:grpc"`), so builds that include generated code pass
`-collection:grpc=<repo root>`.

## Commands

```sh
sh scripts/test.sh              # build odin-protoc, regenerate test code, run all suites
sh scripts/test.sh protobuf     # one suite (directory name under tests/)
ODIN_FLAGS="-sanitize:address" sh scripts/test.sh   # extra flags for odin test
odin check <pkg> -no-entry-point -vet -strict-style   # fast type check of a library package
```

Toolchain: Odin `dev-2026-10` nightly. Generated test code (`tests/*/gen/`)
is rebuilt by the test script; never edit it by hand.

## Coding conventions

- Match the surrounding code: Odin naming (`snake_case` procs and fields,
  `Ada_Case` types, `SCREAMING_CASE` constants), tabs, doc comments on every
  exported declaration explaining *why* as well as what.
- Mark helpers `@(private)` or `@(private = "file")`.
- Errors are small enums (`Error`) returned as the last value; use
  `or_return`. Struct "problem" values (e.g. `http2.Problem`) cannot be used
  with `or_return`, so check them with `has_problem`.
- Prefer `proc "contextless"` for leaf procedures that cannot allocate.
- Keep protocol constants and limits named and documented with their RFC
  section.

## Memory

- **Encoding** (protobuf) is allocation-free: `<Msg>_size` then a backwards
  `<Msg>_encode_fields` into an exactly sized buffer.
- **Decoding** allocates from the allocator passed in; arenas are the
  intended allocator. Repeated fields are `[dynamic]T` (they remember their
  allocator), pre-counted to their exact size and grown geometrically when
  merging. Values replaced during decoding are freed (unless
  `alias_input`), so a decode target must be zero or own its memory with the
  decoder's allocator.
- Use `pb.view(slice)` to build outgoing messages from existing memory
  without allocating.
- HPACK tables are allocated once at init; header blocks are decoded through
  a callback whose strings are only valid during the call.
- Tests run under the tracking allocator: a leak fails review.

## Testing requirements

- Every bug fix comes with a regression test.
- Protocol code is tested against spec vectors (RFC 7541 Appendix C,
  protobuf encoding guide) **and** against the reference implementation:
  `tests/protobuf/testdata/*.bin` are produced by Google's protobuf runtime
  (`interop/python/gen_fixtures.py`) and must round-trip byte for byte.
- Decoders get hostile-input tests: truncation, overlong lengths, depth
  bombs, allocation amplification, and a seeded fuzz loop.
- Concurrency code is tested with real sockets on loopback, including
  cancellation, deadlines, resets, and connection loss.

## Platform notes (verified on Windows)

- `net.shutdown` from another thread does **not** reliably wake a blocked
  `recv` on Windows. Connection readers use a receive timeout and check a
  closing flag; only the reader thread closes its socket (avoids handle-reuse
  races). See the `odin-dev` skill.
- Odin file names cannot start with `_`.
