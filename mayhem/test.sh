#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS woff2's CLI tools (built by mayhem/build.sh with normal flags) on a committed
# known-input font and asserts exact known outputs (compressed size/hash, round-trip hash, parsed
# table list, rejection of corrupted input). upstream ships no test suite of its own.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

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

BIN="$SRC/mayhem/build-test"
for t in woff2_compress woff2_decompress woff2_info; do
  [ -x "$BIN/$t" ] || { echo "missing $BIN/$t — mayhem/build.sh should have built it" >&2; emit_ctrf woff2-cli 0 1; exit 1; }
done

# Known answers for mayhem/test-data/oracle.ttf (brotli pinned by the submodule gitlink).
EXPECT_TTF_SHA=f47bc9b4c2b39cb6a7a4fc5fe7927030f86c178b752d7e48d4d1a862d96746a1
EXPECT_WOFF2_SIZE=448
EXPECT_WOFF2_SHA=77fadbbba59be53d3686091cb2529a935e48228080ec829c543f3f76d20c0d83
EXPECT_RT_SIZE=888
EXPECT_RT_SHA=283f83ceff41f028e8f3da7f91634b7e39b99e43d93fed9c52ae88c5f8228e8f

passed=0; failed=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$((passed+1)); echo "ok   $1"
  else failed=$((failed+1)); echo "FAIL $1: expected '$2' got '$3'"; fi
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp mayhem/test-data/oracle.ttf "$W/oracle.ttf"
check "fixture sha256" "$EXPECT_TTF_SHA" "$(sha256sum "$W/oracle.ttf" | cut -d' ' -f1)"

"$BIN/woff2_compress" "$W/oracle.ttf" >/dev/null 2>&1; rc=$?
check "compress exit" 0 "$rc"
check "woff2 magic" "wOF2" "$(head -c4 "$W/oracle.woff2" 2>/dev/null)"
check "woff2 size" "$EXPECT_WOFF2_SIZE" "$(stat -c %s "$W/oracle.woff2" 2>/dev/null)"
check "woff2 sha256" "$EXPECT_WOFF2_SHA" "$(sha256sum "$W/oracle.woff2" 2>/dev/null | cut -d' ' -f1)"

info="$("$BIN/woff2_info" "$W/oracle.woff2" 2>&1)"
check "info table count" 10 "$(printf '%s\n' "$info" | awk '$4 ~ /^[A-Za-z0-9\/ ]{4}$/ && $1 ~ /^[0-9]+$/' | wc -l)"
check "info glyf lengths" "220 181" "$(printf '%s\n' "$info" | awk '$4=="glyf"{print $5, $6}')"
check "info loca lengths" "18 0" "$(printf '%s\n' "$info" | awk '$4=="loca"{print $5, $6}')"

mkdir "$W/rt" && cp "$W/oracle.woff2" "$W/rt/rt.woff2"
"$BIN/woff2_decompress" "$W/rt/rt.woff2" >/dev/null 2>&1; rc=$?
check "decompress exit" 0 "$rc"
check "round-trip size" "$EXPECT_RT_SIZE" "$(stat -c %s "$W/rt/rt.ttf" 2>/dev/null)"
check "round-trip sha256" "$EXPECT_RT_SHA" "$(sha256sum "$W/rt/rt.ttf" 2>/dev/null | cut -d' ' -f1)"
check "round-trip sfnt version" "00010000" "$(head -c4 "$W/rt/rt.ttf" 2>/dev/null | od -An -tx1 | tr -d ' \n')"

# Corrupted input (truncated brotli stream) must be rejected: non-zero exit and no output file.
mkdir "$W/bad" && head -c 150 "$W/oracle.woff2" > "$W/bad/bad.woff2"
"$BIN/woff2_decompress" "$W/bad/bad.woff2" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && r=rejected || r="accepted(rc=$rc)"
check "truncated input rejected" rejected "$r"

emit_ctrf woff2-cli "$passed" "$failed"
