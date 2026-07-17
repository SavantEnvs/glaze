#!/usr/bin/env bash
#
# glaze/mayhem/build.sh — build stephenberry/glaze's OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers), AND a self-contained known-answer test program (normal flags)
# for mayhem/test.sh to RUN.
#
# glaze is a HEADER-ONLY C++20/23 JSON/BEVE serialization library (include/glaze/**). Each harness
# #includes <glaze/glaze.hpp> and drives a reader on attacker-controlled bytes — read_json /
# read_beve / read_jsonb / read_cbor / read_msgpack / read_csv / read_jmespath / minify / prettify.
# Because the library is header-only, the parser code is compiled INTO each harness with
# $SANITIZER_FLAGS, so the fuzzed code is instrumented (not just the thin harness).
#
# The harness set mirrors glaze's own OSS-Fuzz build (fuzzing/ossfuzz.sh: every fuzzing/*.cpp except
# the exhaustive sweeps and main.cpp). main.cpp is glaze's own file-input run-once driver — we link
# it as the standalone reproducer main for every harness.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF ≤ 3 symbols required by Mayhem's triage (clang-19 default is DWARF-5; §6.2 item 10).
# Use `=` (not `:=`) so an explicit empty --build-arg is preserved.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
INC="-I$SRC/include"
# glaze's OSS-Fuzz build uses -std=c++23; the base clang-19 supports it.
STD="-std=c++23"

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# The harness set = glaze's OSS-Fuzz set (fuzzing/ossfuzz.sh). Primary focus: JSON + BEVE.
HARNESSES=(
  json_generic
  json_reflection
  json_roundtrip_floating
  json_roundtrip_int
  json_roundtrip_string
  json_with_comments
  json_jmespath
  json_minify
  json_prettify
  binary_reflection
  jsonb_reflection
  cbor_reflection
  cbor_roundtrip_floating
  cbor_roundtrip_int
  cbor_roundtrip_string
  msgpack_reflection
  msgpack_roundtrip_floating
  msgpack_roundtrip_int
  msgpack_roundtrip_string
  csv_parsing
)

# Build parallelism: every compile below is an independent translation unit of a heavy header-only
# C++23 library (~5 s and ~0.3-1 GB each, 41 of them), so a serial build is what ran past the 450 s
# build limit on a slow host. Run up to MAYHEM_JOBS at once, capped so ~1.5 GB of RAM remains per job.
JOBS="$MAYHEM_JOBS"
mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
# Inside a memory-limited container /proc/meminfo still shows host RAM: also honour the cgroup limit
# (v2 memory.max/memory.current, v1 memory.limit_in_bytes/memory.usage_in_bytes) and take the smaller.
cg_limit=""; cg_used=""
if [ -r /sys/fs/cgroup/memory.max ]; then
  cg_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
  cg_used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || true)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
  cg_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
  cg_used=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || true)
fi
case "$cg_limit" in ''|*[!0-9]*) ;; *)
  cg_kb=$(( (cg_limit - ${cg_used:-0}) / 1024 ))
  [ "$cg_kb" -ge 0 ] || cg_kb=0
  if [ -z "${mem_kb:-}" ] || [ "$cg_kb" -lt "$mem_kb" ]; then mem_kb="$cg_kb"; fi ;;
esac
if [ -n "${mem_kb:-}" ]; then
  mem_jobs=$(( mem_kb / 1500000 ))
  [ "$mem_jobs" -ge 1 ] || mem_jobs=1
  [ "$JOBS" -le "$mem_jobs" ] || JOBS="$mem_jobs"
fi
[ "$JOBS" -ge 1 ] || JOBS=1

FAILED=0
# run_job <log-name> <command...>: start in the background; throttle to $JOBS; keep its output in a
# log that is replayed (in launch order) only when it fails.
run_job() {
  local name="$1"; shift
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || FAILED=1; done
  ( "$@" ) > "$BUILD/$name.log" 2>&1 || { echo "FAILED: $name" > "$BUILD/$name.failed"; } &
}
wait_all() {
  wait || true
  for f in "$BUILD"/*.failed; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .failed)"
    echo "=== $n failed; log follows ===" >&2
    cat "$BUILD/$n.log" >&2
    FAILED=1
  done
  [ "$FAILED" -eq 0 ] || { echo "build.sh: one or more compiles failed" >&2; exit 1; }
}
rm -f "$BUILD"/*.failed

# glaze ships its own run-once file-input driver (fuzzing/main.cpp -> mayhem/harnesses/main.cpp).
# Compile it ONCE as the standalone main; link it into each harness (no libFuzzer runtime).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD -c "$HARNESS_DIR/main.cpp" -o "$BUILD/standalone_main.o"

# Build-time LeakSanitizer-off hook (SPEC §6.2 item 15), linked into every fuzz + standalone binary.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"

# ── glaze's OWN test suite needs the network (FetchContent: openalgz/ut, ASIO) and is huge, so it
#    can't run in the hermetic build. Instead build a self-contained known-answer test program
#    (mayhem/glaze_kat.cpp) with NORMAL flags that round-trips real values through glaze's JSON and
#    BEVE codecs and asserts EXACT recovered values — a true PATCH oracle. test.sh only RUNS it. ────
TESTDIR="$SRC/mayhem-tests"
mkdir -p "$TESTDIR"
build_kat() {
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    $CXX $STD $INC -O2 -c "$SRC/mayhem/glaze_kat.cpp" -o "$BUILD/glaze_kat.o" &&
  $CXX "$BUILD/glaze_kat.o" -o "$TESTDIR/glaze_kat"
}
run_job glaze_kat build_kat

# Compile (-c) and link as two steps: a compile that also links is not cacheable by ccache (SPEC §6.2
# item 18), and the compile is the expensive part.
build_fuzz() {   # build_fuzz <harness>: libFuzzer target -> /mayhem/<name>
  $CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS $STD $INC \
      -c "$HARNESS_DIR/$1.cpp" -o "$BUILD/$1.fuzz.o" &&
  $CXX $SANITIZER_FLAGS "$BUILD/$1.fuzz.o" "$BUILD/lsan_off.o" $LIB_FUZZING_ENGINE -o "/mayhem/$1"
}
build_standalone() {   # build_standalone <harness>: glaze's main(): one input file, runs once -> /mayhem/<name>-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
      -c "$HARNESS_DIR/$1.cpp" -o "$BUILD/$1.sa.o" &&
  $CXX $SANITIZER_FLAGS "$BUILD/$1.sa.o" "$BUILD/standalone_main.o" "$BUILD/lsan_off.o" -o "/mayhem/$1-standalone"
}

for h in "${HARNESSES[@]}"; do
  run_job "$h" build_fuzz "$h"
  run_job "$h-standalone" build_standalone "$h"
done
wait_all
for h in "${HARNESSES[@]}"; do echo "built $h (+ standalone)"; done
echo "built glaze_kat known-answer test"

echo "build.sh complete:"
ls -la /mayhem/json_generic /mayhem/binary_reflection /mayhem/json_generic-standalone 2>&1 || true
ls -la "$TESTDIR" 2>&1 || true
