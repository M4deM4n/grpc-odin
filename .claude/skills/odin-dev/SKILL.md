---
name: odin-dev
description: Build, test and debug Odin code in this repository - commands, compiler flags, stdlib API facts verified for the dev-2026-10 nightly, and Odin/Windows gotchas that have already cost time. Use before writing or debugging any Odin code here.
---

# Odin development in odin-grpc

## Build and test

- All suites: `sh scripts/test.sh` (builds `odin-protoc`, regenerates
  `tests/*/gen`, runs `odin test tests/<suite> -vet -strict-style -collection:grpc=<root>`).
- One suite: `sh scripts/test.sh <suite>`. One test:
  `odin test tests/<suite> -collection:grpc=. -define:ODIN_TEST_NAMES=<pkg>_test.<proc>`.
- Type-check a library package: `odin check <dir> -no-entry-point -vet -strict-style`.
- Debug a crash: build with `-debug`. A bare "Illegal instruction" with no
  message is usually `unreachable()` or a failed `assert` in contextless code.
- Put scratch programs in the session scratchpad, never in the repo.

## Verifying stdlib APIs

Do not read the stdlib sources (project rule). Write a 10-line probe and
compile it. Facts already verified on this toolchain:

- `os.read_entire_file(path, allocator) -> ([]u8, Error)`,
  `os.write_entire_file(path, data) -> Error`, `os.make_directory_all`, `os.exists`.
- `filepath.abs/clean/rel` return `(string, Error)` style results.
- `net.listen_tcp`, `net.accept_tcp` (returns `Interrupted` after the
  listener is closed from another thread), `net.dial_tcp(endpoint)`,
  `net.recv_tcp` (0 bytes = EOF), `net.send_tcp`, `net.bound_endpoint`,
  `net.set_option(s, .TCP_Nodelay | .Receive_Timeout | .Send_Timeout, value)`.
  A receive timeout returns `Timeout` and the socket stays usable.
- `net.shutdown(s, .Both)` from another thread does NOT wake a blocked
  `recv` on Windows; `net.close` from another thread does, but risks
  handle reuse. Pattern used here: receive timeout + closing flag, reader
  thread is the only closer.
- Threads: `thread.create(proc(t: ^thread.Thread))`, set `t.data`,
  `t.flags += {.Self_Cleanup}` for detached threads, `thread.start(t)`.
  `thread.create_and_start_with_poly_data(x, proc(x: T))` + `join`/`destroy`.
- Sync: `sync.Mutex`, `sync.mutex_try_lock`, `sync.Cond`,
  `sync.cond_wait_with_timeout(&c, &m, dur) -> bool`, `sync.Wait_Group`,
  `sync.atomic_load/store/add/compare_exchange_strong`.
- `vmem.arena_init_growing(&a)`, `vmem.arena_allocator`,
  `vmem.arena_free_all` (keeps the first block), `vmem.arena_destroy`.
- Map element pointer: `if p, ok := &m[key]; ok { p^ = v }` (does not insert).
- `runtime.mem_resize(ptr, old, new, align, allocator)`;
  `runtime.nil_allocator()`.
- Tests log with `core:log` (`log.infof`); there is no `testing.logf`.
  `testing.expect(t, cond, msg, loc = loc)` takes `loc` by name.

## Gotchas

- `fmt` format strings treat `{` and `}` as special: write `{{` / `}}` for
  literal braces (this matters in the code generator's `line(g, ...)` calls).
- `or_return` needs the enclosing procedure to have results, and only works
  with error-like last values (enum/bool/pointer), not structs.
- `-strict-style` requires `case` at the same column as `switch`.
- Compound literals of dynamic arrays are disabled by default; build
  repeated fields with `pb.view([]T{...})` or `append`.
- A package-level procedure named like a builtin (`reserve`, `copy`, ...)
  shadows the builtin for the whole package.
- File names cannot start with `_`.
- Returning a compound slice literal from a procedure is rejected
  (stack memory); use a global array or allocate.
- When editing files from a script, open them as UTF-8 explicitly; a
  failed write after `open(..., 'w')` truncates the file. Prefer the Edit
  tool for edits.
