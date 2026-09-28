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

# glaze ships its own run-once file-input driver (fuzzing/main.cpp -> mayhem/harnesses/main.cpp).
# Compile it ONCE as the standalone main; link it into each harness (no libFuzzer runtime).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD -c "$HARNESS_DIR/main.cpp" -o "$BUILD/standalone_main.o"

for h in "${HARNESSES[@]}"; do
  # libFuzzer target -> /mayhem/<name> (parser compiled in with sanitizers + DWARF ≤ 3 debug info)
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
      "$HARNESS_DIR/$h.cpp" $LIB_FUZZING_ENGINE \
      -o "/mayhem/$h"

  # standalone reproducer -> /mayhem/<name>-standalone (glaze's main(): one input file, runs once)
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
      "$HARNESS_DIR/$h.cpp" "$BUILD/standalone_main.o" \
      -o "/mayhem/$h-standalone"

  echo "built $h (+ standalone)"
done

# ── glaze's OWN test suite needs the network (FetchContent: openalgz/ut, ASIO) and is huge, so it
#    can't run in the hermetic build. Instead build a self-contained known-answer test program
#    (mayhem/glaze_kat.cpp) with NORMAL flags that round-trips real values through glaze's JSON and
#    BEVE codecs and asserts EXACT recovered values — a true PATCH oracle. test.sh only RUNS it. ────
TESTDIR="$SRC/mayhem-tests"
mkdir -p "$TESTDIR"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  $CXX $STD $INC -O2 "$SRC/mayhem/glaze_kat.cpp" -o "$TESTDIR/glaze_kat"
echo "built glaze_kat known-answer test"

echo "build.sh complete:"
ls -la /mayhem/json_generic /mayhem/binary_reflection /mayhem/json_generic-standalone 2>&1 || true
ls -la "$TESTDIR" 2>&1 || true
