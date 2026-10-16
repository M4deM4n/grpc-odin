"""Generate reference protobuf encodings with Google's official runtime.

The Odin test suite (tests/protobuf) embeds these files and checks that
odin-protoc generated code decodes them and re-encodes the same messages to
identical bytes.

Usage (from the repository root):
    interop/python/.venv/Scripts/python -I interop/python/gen_fixtures.py
"""

import importlib
import math
import os
import sys
import tempfile

from grpc_tools import protoc

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROTO_DIR = os.path.join(ROOT, "tests", "protobuf", "proto")
OUT_DIR = os.path.join(ROOT, "tests", "protobuf", "testdata")


def compile_protos(out):
    import grpc_tools

    include = os.path.join(os.path.dirname(grpc_tools.__file__), "_proto")
    for name in ("legacy.proto", "test_all.proto"):
        rc = protoc.main(["protoc", f"-I{PROTO_DIR}", f"-I{include}", f"--python_out={out}", name])
        if rc != 0:
            sys.exit(f"protoc failed for {name}")
    sys.path.insert(0, out)
    return importlib.import_module("test_all_pb2"), importlib.import_module("legacy_pb2")


def full_scalars(pb):
    return pb.Scalars(
        f_double=-1.5e300,
        f_float=3.25,
        f_int32=-(2**31),
        f_int64=-(2**63),
        f_uint32=2**32 - 1,
        f_uint64=2**64 - 1,
        f_sint32=-(2**31),
        f_sint64=2**63 - 1,
        f_fixed32=0x01020304,
        f_fixed64=0x0102030405060708,
        f_sfixed32=-5,
        f_sfixed64=-6,
        f_bool=True,
        f_string="héllo, 世界",
        f_bytes=bytes([0, 0xFF, 0x80]),
        f_enum=pb.COLOR_RED,
    )


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        pb, legacy = compile_protos(tmp)
        fixtures = {}

        fixtures["scalars_full"] = full_scalars(pb)

        fixtures["repeated"] = pb.Repeated(
            r_int32=[0, -1, 2**31 - 1, -(2**31)],
            r_sint64=[-(2**63), 0, 2**63 - 1],
            r_fixed32=[0, 1, 2**32 - 1],
            r_double=[math.inf, -0.0, 1e-300],
            r_bool=[True, False],
            r_enum=[pb.COLOR_RED, pb.COLOR_NEGATIVE, 12345],
            r_string=["", "a", "longer string value"],
            r_bytes=[b"", b"\x01\x02\x03"],
            r_message=[full_scalars(pb), pb.Scalars(), pb.Scalars(f_string="x")],
            r_unpacked=[7, 8, 9],
            r_float=[1.5, -2.25],
            r_uint64=[2**64 - 1, 0],
            r_sfixed64=[-(2**63), -1],
        )

        deepest = pb.Nested.Inner.Deepest(name="deep")
        fixtures["nested"] = pb.Nested(
            inner=pb.Nested.Inner(value=42, deepest=deepest),
            mode=pb.Nested.MODE_FAST,
            inners=[pb.Nested.Inner(value=1), pb.Nested.Inner(value=2, deepest=deepest)],
        )

        fixtures["choice_scalars"] = pb.Choice(scalars=full_scalars(pb), flag=False, after=5)
        fixtures["choice_number_zero"] = pb.Choice(number=0, after=5)

        fixtures["large"] = pb.Large(f1=1, f_max=2, f_big="b")

        # Single-entry maps only: map entry order is unspecified.
        maps = pb.Maps()
        maps.m_string_message["full"].CopyFrom(full_scalars(pb))
        maps.m_int32_int64[-1] = -(2**63)
        maps.m_sint32_double[-(2**31)] = 2.5
        maps.m_fixed64_string[7] = "seven"
        fixtures["maps"] = maps

        lg = legacy.Legacy(id=1, name="legacy", unpacked=[1, 2], packed=[3, 4], level=legacy.HIGH)
        lg.child.id = 2
        fixtures["legacy"] = lg

        wk = pb.WithWellKnown()
        wk.created.seconds = 1700000000
        wk.created.nanos = 123
        wk.attributes.fields["s"].string_value = "str"
        fixtures["well_known"] = wk

        for name, msg in fixtures.items():
            path = os.path.join(OUT_DIR, name + ".bin")
            with open(path, "wb") as f:
                f.write(msg.SerializeToString(deterministic=True))
            print(f"wrote {os.path.relpath(path, ROOT)} ({msg.ByteSize()} bytes)")


if __name__ == "__main__":
    main()
