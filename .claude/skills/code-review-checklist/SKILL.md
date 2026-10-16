---
name: code-review-checklist
description: Mandatory pre-commit review for odin-grpc. Walks a diff through spec compliance, hostile-input robustness, memory ownership, concurrency and test coverage. Use before every commit and when asked to review code in this repository.
---

# Pre-commit review checklist

Run this over `git diff --staged` (or the working tree diff). For a large
change, delegate an independent reviewer agent with this checklist and the
rule "do not read outside the repository; do not modify files; verify
findings with reproducers in the scratchpad". Fix every confirmed finding,
add a regression test for it, then run `sh scripts/test.sh`.

## 1. Spec compliance
- Cite the RFC/spec section for each protocol rule touched (RFC 9113,
  RFC 7541, protobuf encoding + language specs, gRPC PROTOCOL-HTTP2.md).
- Connection vs stream error scope correct (RFC 9113 §5.4)?
- Unknown frame types, settings, error codes and fields are ignored or
  preserved, never rejected.
- proto2 vs proto3 differences honored (presence, packed defaults, closed
  enums, required, defaults, UTF-8 validation).

## 2. Hostile input
- Every length/count read from input is checked against remaining input
  *before* use or allocation.
- No allocation proportional to an attacker-controlled number without a
  cap; check amplification ratios (output bytes per input byte) and
  merge/duplicate paths (repeated singular sub-messages, duplicate map keys,
  CONTINUATION floods, PING/SETTINGS floods).
- Recursion is depth-limited; integer arithmetic cannot overflow.
- Run or extend the seeded fuzz tests for new decoders.

## 3. Memory
- Each allocation has one owner and a documented lifetime; no frees of
  memory owned by someone else (aliased input, views, other allocators).
- Error paths release partially built values (or the owner frees them).
- Hot paths reuse buffers; no per-frame/per-message heap allocation unless
  justified.
- Test runner reports no leaks.

## 4. Concurrency (grpc package)
- Lock order respected (see comments in `grpc/conn.odin`); never block on
  the write lock from the reader thread.
- Every wait has a wake-up path for close, reset, cancel and deadline.
- Shared fields are accessed under their documented lock or atomically.
- Socket lifetime: only the owner closes; no use after close.

## 5. API and generated code
- Generated code compiles with `-vet -strict-style` for edge-case schemas
  (keywords, collisions, nesting, recursion, all field kinds).
- Public API documented; breaking changes justified.

## 6. Tests
- New behavior tested, including failure modes; bug fixes have regression
  tests; interop checked against the reference implementation when wire
  behavior changes.
