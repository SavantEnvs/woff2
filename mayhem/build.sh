#!/usr/bin/env bash
#
# mayhem/build.sh — builds (1) the sanitized fuzz harnesses + standalone reproducers and
# (2) the project's own CLI tools with NORMAL flags for mayhem/test.sh. Runs in /mayhem as `mayhem`.
# woff2 vendors brotli as a git submodule (brotli/), compiled straight from source like upstream's
# Makefile does, so nothing is fetched at build time once the submodule is present.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"

cd "$SRC"

[ -d brotli/c/common ] || git submodule update --init brotli

FUZZ_DIR="$SRC/mayhem/build-fuzz"
TEST_DIR="$SRC/mayhem/build-test"
rm -rf "$FUZZ_DIR" "$TEST_DIR"
mkdir -p "$FUZZ_DIR" "$TEST_DIR"

WOFF2_SRCS="font glyph normalize table_tags transform woff2_dec woff2_enc woff2_common woff2_out variable_length"
INC="-I$SRC/brotli/c/include -I$SRC/src -I$SRC/include"
BROTLI_SRCS="$(ls brotli/c/common/*.c brotli/c/dec/*.c brotli/c/enc/*.c)"

# compile_all <outdir> <extra C flags> <extra C++ flags>  — one object per source, in parallel
compile_all() {
  local out="$1" cflags="$2" cxxflags="$3"
  {
    for f in $BROTLI_SRCS; do
      printf '%s\0' "$CC $cflags $INC -c $f -o $out/brotli_$(basename "$(dirname "$f")")_$(basename "$f" .c).o"
    done
    for n in $WOFF2_SRCS; do
      printf '%s\0' "$CXX $cxxflags -std=c++11 $INC -c src/$n.cc -o $out/$n.o"
    done
  } | xargs -0 -P "$MAYHEM_JOBS" -I{} bash -c '{}'
}

# 1) Sanitized + DWARF<=3 library. fuzzer-no-link adds SanCov to the fuzzed code unconditionally.
#    Quiet logging (no -DFONT_COMPRESSION_BIN), as upstream/OSS-Fuzz do for fuzzing.
FUZZ_COMMON="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 -D__STDC_FORMAT_MACROS"
compile_all "$FUZZ_DIR" "$FUZZ_COMMON" "$FUZZ_COMMON"
rm -f "$FUZZ_DIR/libwoff2.a"
ar crs "$FUZZ_DIR/libwoff2.a" "$FUZZ_DIR"/*.o

# LSan off at build time (ASan + UBSan stay on).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_DIR/standalone_main.o"

# 2) The two upstream (OSS-Fuzz) harnesses, each as libFuzzer binary + standalone reproducer.
for h in convert_woff2ttf_fuzzer convert_woff2ttf_fuzzer_new_entry; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++11 $INC $LIB_FUZZING_ENGINE \
      "src/$h.cc" "$FUZZ_DIR/lsan_off.o" "$FUZZ_DIR/libwoff2.a" -o "$SRC/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++11 $INC \
      "src/$h.cc" "$FUZZ_DIR/standalone_main.o" "$FUZZ_DIR/lsan_off.o" "$FUZZ_DIR/libwoff2.a" -o "$SRC/$h-standalone"
done

# 3) The project's CLI tools with NORMAL flags (clean, unsanitized oracle build) for mayhem/test.sh.
TEST_COMMON="-O2 -fno-omit-frame-pointer -DFONT_COMPRESSION_BIN -D__STDC_FORMAT_MACROS $COVERAGE_FLAGS"
compile_all "$TEST_DIR" "$TEST_COMMON" "$TEST_COMMON"
for t in woff2_compress woff2_decompress woff2_info; do
  $CXX $TEST_COMMON -std=c++11 $INC -c "src/$t.cc" -o "$TEST_DIR/tool_$t.o"
  $CXX $COVERAGE_FLAGS $(ls "$TEST_DIR"/*.o | grep -v '/tool_') "$TEST_DIR/tool_$t.o" -o "$TEST_DIR/$t"
done
