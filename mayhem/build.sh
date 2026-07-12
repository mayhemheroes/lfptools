#!/usr/bin/env bash
#
# mayhem/build.sh — build lfptools' fuzz harness + standalone reproducer + the functional-test binary.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# The harness #includes lfpsplitter.c directly, so compiling it with $SANITIZER_FLAGS instruments the
# parser itself (the fuzzed code), not just the harness. lfpsplitter.c casts unaligned char* to
# uint32_t* (ntohl(*(uint32_t*)ptr)); on the fuzzed x86_64 that misaligned load is benign but UBSan's
# `alignment` check fires on the null-padding-shifted offsets and would halt on nearly every past-magic
# input, masking real memory-safety defects. Relax ONLY `alignment`; ASan and every other UBSan check
# stay ON and HALTING. (Recorded in the PR / repos/lfptools.yaml.)
HARNESS_SANITIZER_FLAGS="$SANITIZER_FLAGS"
case "$SANITIZER_FLAGS" in
  *undefined*) HARNESS_SANITIZER_FLAGS="$SANITIZER_FLAGS -fno-sanitize=alignment" ;;
esac

# 1+2) The fuzz target and its standalone (run-once, non-libFuzzer) reproducer. Both instrument the
#      parser via $SANITIZER_FLAGS and carry DWARF < 4 via $DEBUG_FLAGS.
$CC $HARNESS_SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_lfpsplitter.c" -I"$SRC" -o /mayhem/fuzz_lfpsplitter

$CC $HARNESS_SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" \
    "$SRC/mayhem/fuzz_lfpsplitter.c" -I"$SRC" -o /mayhem/fuzz_lfpsplitter-standalone

# 3) The functional-test binary: the upstream program, built with NORMAL flags (no sanitizers) so
#    mayhem/test.sh only RUNS it. $COVERAGE_FLAGS (empty by default) instruments the oracle build.
$CC -O2 $COVERAGE_FLAGS "$SRC/lfpsplitter.c" -I"$SRC" -o /mayhem/lfpsplitter_selftest $COVERAGE_FLAGS
