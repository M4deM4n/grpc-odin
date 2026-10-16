#!/usr/bin/env sh
# Builds the tools, regenerates test code and runs every test suite.
#
#   scripts/test.sh            run all suites
#   scripts/test.sh hpack      run one suite (directory name under tests/)
#
# Extra flags for `odin test` can be passed through ODIN_FLAGS, e.g.
#   ODIN_FLAGS="-sanitize:address" scripts/test.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p build

EXE=""
case "$(uname -s 2>/dev/null || echo unknown)" in
	MINGW* | MSYS* | CYGWIN*) EXE=".exe" ;;
esac

COMMON="-vet -strict-style -collection:grpc=$ROOT"

echo "==> building odin-protoc"
odin build cmd/odin-protoc $COMMON -out:"build/odin-protoc$EXE"

echo "==> generating test code"
rm -rf tests/protobuf/gen
"build/odin-protoc$EXE" -I tests/protobuf/proto -o tests/protobuf/gen --package=testpb tests/protobuf/proto/test_all.proto tests/protobuf/proto/legacy.proto
if [ -d tests/grpc/proto ]; then
	rm -rf tests/grpc/gen
	"build/odin-protoc$EXE" -I tests/grpc/proto -o tests/grpc/gen --package=testsvc tests/grpc/proto/test_service.proto
fi

SUITES=${1:-$(ls tests)}
for suite in $SUITES; do
	[ -d "tests/$suite" ] || continue
	echo "==> testing $suite"
	odin test "tests/$suite" $COMMON ${ODIN_FLAGS:-} -out:"build/test_$suite$EXE"
done
echo "==> all suites passed"
