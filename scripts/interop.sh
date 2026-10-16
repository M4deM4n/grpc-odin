#!/usr/bin/env sh
# Cross-implementation tests against the gRPC C-core (Python grpcio):
#   1. Odin client  -> grpcio server
#   2. grpcio client -> Odin server
#
# Requires the Python venv (see .claude/skills/grpc-interop/SKILL.md):
#   python -m venv interop/python/.venv
#   interop/python/.venv/Scripts/python -m pip install -r interop/python/requirements.txt
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p build

EXE=""
PY="interop/python/.venv/bin/python"
case "$(uname -s 2>/dev/null || echo unknown)" in
	MINGW* | MSYS* | CYGWIN*)
		EXE=".exe"
		PY="interop/python/.venv/Scripts/python.exe"
		;;
esac
[ -x "$PY" ] || { echo "Python venv missing: $PY" >&2; exit 2; }

COMMON="-vet -strict-style -collection:grpc=$ROOT"

echo "==> building"
odin build cmd/odin-protoc $COMMON -out:"build/odin-protoc$EXE"
rm -rf interop/odin/gen
"build/odin-protoc$EXE" -I tests/grpc/proto -o interop/odin/gen --package=interop_gen tests/grpc/proto/test_service.proto
odin build interop/odin/server $COMMON -o:speed -out:"build/interop_server$EXE"
odin build interop/odin/client $COMMON -o:speed -out:"build/interop_client$EXE"

# wait_listening <log file>: prints the endpoint once the server is ready.
wait_listening() {
	i=0
	while [ $i -lt 200 ]; do
		if grep -q "^listening " "$1" 2>/dev/null; then
			sed -n 's/^listening //p' "$1" | head -1 | tr -d '\r'
			return 0
		fi
		i=$((i + 1))
		sleep 0.05
	done
	echo "server did not start:" >&2
	cat "$1" >&2
	return 1
}

# stop_tree <pid>: terminates a background server and its children (the
# Windows venv python.exe is a launcher with a child process).
stop_tree() {
	if [ -r "/proc/$1/winpid" ]; then
		taskkill //F //T //PID "$(cat "/proc/$1/winpid")" > /dev/null 2>&1 || true
	else
		kill "$1" 2>/dev/null || true
	fi
	wait "$1" 2>/dev/null || true
}

FAILED=0
LOG=build/interop_server.log

echo "==> Odin client -> grpcio server"
"$PY" -I interop/python/tester.py serve 0 --forever > "$LOG" 2>&1 &
SERVER=$!
TARGET=$(wait_listening "$LOG") || { stop_tree $SERVER; exit 1; }
if ! "build/interop_client$EXE" "$TARGET"; then FAILED=1; fi
stop_tree $SERVER

echo "==> grpcio client -> Odin server"
"build/interop_server$EXE" 127.0.0.1:0 --forever > "$LOG" 2>&1 &
SERVER=$!
TARGET=$(wait_listening "$LOG") || { stop_tree $SERVER; exit 1; }
if ! "$PY" -I interop/python/tester.py client "$TARGET"; then FAILED=1; fi
stop_tree $SERVER

if [ $FAILED -ne 0 ]; then
	echo "==> interop FAILED"
	exit 1
fi
echo "==> interop passed"
