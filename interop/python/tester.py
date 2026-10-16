"""Reference peer for interop tests: grpcio (gRPC C-core) server and client
for test.svc.Tester (tests/grpc/proto/test_service.proto).

    python -I tester.py serve <port> [--forever]   # prints "listening <addr>"; runs until stdin EOF
    python -I tester.py client <target>   # runs the battery against <target>, exit 0 if all pass

Semantics match interop/odin/server and tests/grpc.
"""

import importlib
import os
import sys
import tempfile
import threading
import time

import grpc
from grpc_tools import protoc

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROTO_DIR = os.path.join(ROOT, "tests", "grpc", "proto")


def load_stubs(out):
    rc = protoc.main(
        ["protoc", f"-I{PROTO_DIR}", f"--python_out={out}", f"--grpc_python_out={out}", "test_service.proto"]
    )
    if rc != 0:
        sys.exit("protoc failed")
    sys.path.insert(0, out)
    return importlib.import_module("test_service_pb2"), importlib.import_module("test_service_pb2_grpc")


# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------


def make_servicer(pb, pb_grpc):
    class Tester(pb_grpc.TesterServicer):
        def Unary(self, req, ctx):
            md = dict(ctx.invocation_metadata())
            if "x-echo" in md:
                ctx.send_initial_metadata((("x-echo-header", md["x-echo"]),))
                ctx.set_trailing_metadata((("x-echo-trailer", md["x-echo"]), ("x-blob-bin", b"\x00\x01\xff")))
            if req.sleep_ms > 0:
                end = time.time() + req.sleep_ms / 1000
                while time.time() < end:
                    if not ctx.is_active():
                        return pb.Echo()
                    time.sleep(0.005)
            if req.fail_code:
                ctx.abort(grpc.StatusCode(self._code(req.fail_code)), req.fail_message)
            payload = req.payload
            if req.response_bytes > 0:
                payload = bytes(req.response_bytes)
            return pb.Echo(text=req.text, seq=req.seq + 1, payload=payload)

        def ServerStream(self, req, ctx):
            payload = bytes(req.response_bytes) if req.response_bytes > 0 else req.payload
            for i in range(req.count):
                yield pb.Echo(text=req.text, seq=i, payload=payload)
            if req.fail_code:
                ctx.abort(grpc.StatusCode(self._code(req.fail_code)), req.fail_message)

        def ClientStream(self, it, ctx):
            total = n = 0
            for m in it:
                total += m.seq + len(m.payload)
                n += 1
            return pb.Echo(count=n, seq=total)

        def Bidi(self, it, ctx):
            for m in it:
                m.seq += 1
                yield m

        @staticmethod
        def _code(n):
            for c in grpc.StatusCode:
                if c.value[0] == n:
                    return c.value
            return grpc.StatusCode.UNKNOWN.value

    return Tester()


def serve(port):
    with tempfile.TemporaryDirectory() as tmp:
        pb, pb_grpc = load_stubs(tmp)
        from concurrent import futures

        server = grpc.server(futures.ThreadPoolExecutor(max_workers=32))
        pb_grpc.add_TesterServicer_to_server(make_servicer(pb, pb_grpc), server)
        bound = server.add_insecure_port(f"127.0.0.1:{port}")
        server.start()
        print(f"listening 127.0.0.1:{bound}", flush=True)
        if "--forever" in sys.argv:
            while True:
                time.sleep(3600)
        sys.stdin.read()
        server.stop(grace=1).wait()


# -----------------------------------------------------------------------------
# Client
# -----------------------------------------------------------------------------

failures = 0


def check(name, ok, detail=""):
    global failures
    print(f"{'PASS' if ok else 'FAIL'} {name} {'' if ok else detail}", flush=True)
    if not ok:
        failures += 1


def run(name, fn):
    try:
        fn()
    except Exception as e:  # report and continue with the next check
        check(name, False, repr(e))


def client(target):
    with tempfile.TemporaryDirectory() as tmp:
        pb, pb_grpc = load_stubs(tmp)
        channel = grpc.insecure_channel(
            target, options=[("grpc.max_receive_message_length", 8 << 20), ("grpc.max_send_message_length", 8 << 20)]
        )
        stub = pb_grpc.TesterStub(channel)
        T = 10

        def unary():
            r = stub.Unary(pb.Echo(text="hello interop", seq=41), timeout=T)
            check("unary", r.text == "hello interop" and r.seq == 42)

        def unary_empty():
            r = stub.Unary(pb.Echo(), timeout=T)
            check("unary_empty", r.seq == 1)

        def metadata():
            r, call = stub.Unary.with_call(
                pb.Echo(text="md"), metadata=(("x-echo", "meta-value"), ("x-extra-bin", b"\x00\xfe")), timeout=T
            )
            initial = dict(call.initial_metadata())
            trailing = dict(call.trailing_metadata())
            check(
                "metadata",
                initial.get("x-echo-header") == "meta-value"
                and trailing.get("x-echo-trailer") == "meta-value"
                and trailing.get("x-blob-bin") == b"\x00\x01\xff",
                f"{initial} {trailing}",
            )

        def error_status():
            msg = "bad state: ünïcødé 100% \t done"
            try:
                stub.Unary(pb.Echo(fail_code=9, fail_message=msg), timeout=T)
                check("error_status", False, "no error")
            except grpc.RpcError as e:
                check("error_status", e.code() == grpc.StatusCode.FAILED_PRECONDITION and e.details() == msg, f"{e.code()} {e.details()!r}")

        def unimplemented():
            try:
                stub.NotImplemented(pb.Echo(), timeout=T)
                check("unimplemented", False, "no error")
            except grpc.RpcError as e:
                check("unimplemented", e.code() == grpc.StatusCode.UNIMPLEMENTED, str(e.code()))

        def server_streaming():
            seqs = [m.seq for m in stub.ServerStream(pb.Echo(text="s", count=100), timeout=T)]
            check("server_streaming", seqs == list(range(100)), str(seqs[:5]))

        def server_streaming_error():
            got = []
            try:
                for m in stub.ServerStream(pb.Echo(count=3, fail_code=10, fail_message="stopped"), timeout=T):
                    got.append(m.seq)
                check("server_streaming_error", False, "no error")
            except grpc.RpcError as e:
                check("server_streaming_error", got == [0, 1, 2] and e.code() == grpc.StatusCode.ABORTED and e.details() == "stopped", f"{got} {e.code()}")

        def client_streaming():
            r = stub.ClientStream(iter([pb.Echo(seq=i) for i in range(100)]), timeout=T)
            check("client_streaming", r.count == 100 and r.seq == sum(range(100)), f"{r.count} {r.seq}")

        def bidi_streaming():
            out = [m.seq for m in stub.Bidi(iter([pb.Echo(seq=i) for i in range(50)]), timeout=T)]
            check("bidi_streaming", out == list(range(1, 51)), str(out[:5]))

        def large_unary():
            payload = bytes((i * 31) & 0xFF for i in range(3 << 20))
            r = stub.Unary(pb.Echo(payload=payload), timeout=T)
            check("large_unary", r.payload == payload)

        def large_streams():
            r = list(stub.ServerStream(pb.Echo(count=4, response_bytes=1 << 20), timeout=T))
            ok = len(r) == 4 and all(len(m.payload) == 1 << 20 for m in r)
            total = stub.ClientStream(iter([pb.Echo(payload=bytes(1 << 20)) for _ in range(4)]), timeout=T)
            check("large_streams", ok and total.seq == 4 << 20, f"{len(r)} {total.seq}")

        def deadline():
            start = time.time()
            try:
                stub.Unary(pb.Echo(sleep_ms=2000), timeout=0.2)
                check("deadline_exceeded", False, "no error")
            except grpc.RpcError as e:
                check("deadline_exceeded", e.code() == grpc.StatusCode.DEADLINE_EXCEEDED and time.time() - start < 1.5, str(e.code()))

        def cancel():
            q = []
            ev = threading.Event()

            def gen():
                yield pb.Echo(seq=1)
                ev.wait(5)

            it = stub.Bidi(gen(), timeout=T)
            first = next(it)
            it.cancel()
            ev.set()
            try:
                for m in it:
                    q.append(m)
                check("cancel", False, "stream continued")
            except grpc.RpcError as e:
                check("cancel", first.seq == 2 and e.code() == grpc.StatusCode.CANCELLED, str(e.code()))

        def concurrent():
            errors = []

            def worker():
                for j in range(25):
                    try:
                        r = stub.Unary(pb.Echo(seq=j), timeout=T)
                        if r.seq != j + 1:
                            errors.append(j)
                    except Exception as e:
                        errors.append(e)

            ts = [threading.Thread(target=worker) for _ in range(8)]
            for t in ts:
                t.start()
            for t in ts:
                t.join()
            check("concurrent", not errors, str(errors[:3]))

        for name, fn in [
            ("unary", unary),
            ("unary_empty", unary_empty),
            ("metadata", metadata),
            ("error_status", error_status),
            ("unimplemented", unimplemented),
            ("server_streaming", server_streaming),
            ("server_streaming_error", server_streaming_error),
            ("client_streaming", client_streaming),
            ("bidi_streaming", bidi_streaming),
            ("large_unary", large_unary),
            ("large_streams", large_streams),
            ("deadline_exceeded", deadline),
            ("cancel", cancel),
            ("concurrent", concurrent),
        ]:
            run(name, fn)
        channel.close()
        if failures:
            print(f"{failures} check(s) failed")
            sys.exit(1)
        print("all checks passed")


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("serve", "client"):
        sys.exit(__doc__)
    if sys.argv[1] == "serve":
        serve(int(sys.argv[2]))
    else:
        client(sys.argv[2])
