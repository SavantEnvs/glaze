#!/usr/bin/env bash
#
# glaze/mayhem/test.sh — RUN the self-contained known-answer test (glaze_kat, built by
# mayhem/build.sh with normal flags) and emit a CTRF summary. exit 0 iff no case failed.
#
# PATCH-grade oracle: glaze_kat round-trips real values through glaze's JSON and BEVE codecs and
# asserts the EXACT recovered values / golden encodings (read_json/write_json/write_beve/read_beve/
# beve_to_json). A no-op / "exit(0)" patch — or any codec regression that perturbs parsing or
# serialization — makes a case mismatch and fails this suite. This script only RUNS the pre-built
# binary; it never compiles. (glaze's own ctest suite needs the network — openalgz/ut + ASIO via
# FetchContent — and is far too large for the hermetic build, hence this curated network-free oracle.)
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"
BIN="$BUILDDIR/glaze_kat"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$BIN" ]; then
  echo "missing $BIN — run mayhem/build.sh first" >&2
  emit_ctrf "glaze-kat" 0 1 0; exit 2
fi

echo "=== running glaze known-answer tests ==="
out="$("$BIN" 2>&1)"; rc=$?
echo "$out"

# Parse the "SUMMARY passed=<P> failed=<F>" line the test program prints.
PASSED=$(printf '%s\n' "$out" | sed -n 's/.*SUMMARY passed=\([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*failed=\([0-9][0-9]*\).*/\1/p' | tail -1)

# If the summary line is missing (binary crashed/aborted), treat as failure.
if [ -z "${PASSED:-}" ] || [ -z "${FAILED:-}" ]; then
  echo "could not parse SUMMARY (exit $rc) — treating as failure" >&2
  emit_ctrf "glaze-kat" 0 1 0; exit 1
fi

emit_ctrf "glaze-kat" "$PASSED" "$FAILED" 0
