#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for lfptools' lfpsplitter.
#
# Upstream ships NO test suite (just a Makefile + docs), so this is an authored BEHAVIORAL oracle:
# it drives the pre-built program (mayhem/build.sh -> /mayhem/lfpsplitter_selftest) on crafted inputs
# and asserts OUTPUT / exit behaviour (known-answer + rejection), not merely "exit 0". A patch that
# no-ops the program (e.g. exit(0) without extracting anything) FAILS here. Emits a CTRF summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

BIN=/mayhem/lfpsplitter_selftest
[ -x "$BIN" ] || { echo "test.sh: $BIN missing — build.sh should have produced it" >&2; exit 1; }

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

PASS=0; FAIL=0
ok(){ echo "ok - $1"; PASS=$((PASS+1)); }
no(){ echo "FAIL - $1" >&2; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d /tmp/lfptest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---- build a well-formed Lytro v1 .lfp fixture with a single JSON table-of-contents section --------
# Layout: 12B file magic + 4B len(0) | section: 12B magic("CTOC"+pad) + 4B BE len + 45B sha1 + 35B blank + data
TOC='{"picture":{"frameArray":[]}}'                 # 29 bytes of known-answer JSON
FIX="$WORK/sample.lfp"
{
  printf '\x89\x4c\x46\x50\x0d\x0a\x1a\x0a\x00\x00\x00\x01'   # file magic (12)
  printf '\x00\x00\x00\x00'                                   # file section length (4)
  printf 'CTOC\x00\x00\x00\x00\x00\x00\x00\x00'               # section magic (12)
  printf '\x00\x00\x00\x1d'                                   # section length = 29 (BE)
  printf 'sha1-0000000000000000000000000000000000000000'      # sha1 (45 chars)
  printf '\x00%.0s' $(seq 1 35)                               # blank (35)
  printf '%s' "$TOC"                                          # section data (29)
} > "$FIX"

# Test 1 — known-answer extraction: the TOC section must be written verbatim to <name>_table.json.
( cd "$WORK" && "$BIN" sample.lfp >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$WORK/sample_table.json" ] && [ "$(cat "$WORK/sample_table.json")" = "$TOC" ]; then
  ok "extracts table-of-contents JSON verbatim (sample_table.json == known answer)"
else
  no "TOC extraction (rc=$rc, got: $(cat "$WORK/sample_table.json" 2>/dev/null))"
fi

# Test 2 — a file without the LFP magic is rejected (exit 1 + diagnostic).
printf 'NOT-AN-LFP-FILE-just some arbitrary bytes here' > "$WORK/bad.lfp"
out="$( "$BIN" "$WORK/bad.lfp" 2>&1 )"; rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "does not look like an lfp"; then
  ok "rejects a non-LFP file (exit 1 + diagnostic)"
else
  no "non-LFP rejection (rc=$rc, out='$out')"
fi

# Test 3 — no argument prints usage and exits 1.
out="$( "$BIN" 2>&1 )"; rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "Usage:"; then
  ok "prints usage with no argument (exit 1)"
else
  no "usage message (rc=$rc, out='$out')"
fi

# Test 4 — a missing input file fails cleanly (exit 1 + diagnostic).
out="$( "$BIN" "$WORK/does_not_exist.lfp" 2>&1 )"; rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "Failed to open file"; then
  ok "reports a missing input file (exit 1 + diagnostic)"
else
  no "missing-file handling (rc=$rc, out='$out')"
fi

echo "== $PASS passed, $FAIL failed =="
emit_ctrf "lfpsplitter-oracle" "$PASS" "$FAIL" 0
