---
name: grpc-interop
description: Verify the Odin gRPC transport against the reference gRPC implementation (Python grpcio, i.e. gRPC C-core) in both directions, and debug wire-level interop problems. Use after any change to grpc/, http2/ or hpack/, and when a peer misbehaves.
---

# gRPC interop testing

## Run

```sh
python -m venv interop/python/.venv                                  # once
interop/python/.venv/Scripts/python -m pip install -r interop/python/requirements.txt
sh scripts/interop.sh
```

The script builds `odin-protoc`, generates `interop/odin/gen` from
`tests/grpc/proto/test_service.proto`, builds `interop/odin/{server,client}`
and runs:

1. Odin client (`interop/odin/client`) -> grpcio server (`tester.py serve`)
2. grpcio client (`tester.py client`) -> Odin server (`interop/odin/server`)

Each side prints `PASS/FAIL <check>`; the script exits non-zero on any
failure. Both servers implement identical semantics (see the `Echo`
message fields: `sleep_ms`, `fail_code`, `count`, `response_bytes`, and the
`x-echo` metadata convention).

## Adding a check
Add it to BOTH clients (`interop/odin/client/main.odin`,
`interop/python/tester.py`) so each implementation is exercised as client
and server. If server behavior is needed, implement it identically in
`interop/odin/server/main.odin`, `interop/python/tester.py` and the test
server in `tests/grpc/grpc_test.odin`.

## Process hygiene
Servers run with `--forever` and are stopped by PID (`stop_tree` in the
script; on Windows via `/proc/<pid>/winpid` + `taskkill //T`). Never kill
`python.exe` by image name: it kills unrelated user processes. A stale
`build/interop_server.exe` that is still running blocks the next build;
stop it by PID or by its (unique) image name.

## Debugging wire problems
- Reproduce with a single check, then add a focused loopback test in
  `tests/grpc` (faster to iterate, runs under the leak checker).
- grpcio tracing: set `GRPC_TRACE=http,http2_stream_state` and
  `GRPC_VERBOSITY=debug` in the environment of `tester.py`.
- Typical culprits: header block ordering vs HPACK encoder state (must be
  encoded under `q_mu`), window accounting on padding, trailers-only
  responses, grpc-message percent-encoding, `te: trailers`.
- Windows reserves port ranges (e.g. around 50000): bind to port 0 and read
  the bound endpoint instead of hard-coding ports.
