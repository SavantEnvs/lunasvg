#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the KAT oracle probe mayhem/build.sh already built (/mayhem/kat_lunasvg).
#
# lunasvg ships no test suite of its own, so this is a small known-answer probe (mayhem/kat/
# kat_lunasvg.cpp) rather than a wrapper around an upstream runner. It is a behavioral oracle: it
# asserts EXACT values (a nullptr on garbage input, parsed width/height, a raw attribute string, an
# id lookup, and one exact rendered pixel), not just an exit code — a no-op/neutered binary fails it.
#
# EXPECTED_ASSERTIONS is the number of `check(...)` calls in kat_lunasvg.cpp (six — see the source).
# We do NOT just count ASSERT_OK/ASSERT_FAIL lines that happen to be present: a binary neutered to
# _exit(0) before printing anything would then report "0 passed, 0 failed" — a false PASS. Instead
# any assertion that isn't accounted for by an ASSERT_OK or ASSERT_FAIL line counts as FAILED, so a
# neutered run is unconditionally caught (tests=6, passed=0, failed=6).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

EXPECTED_ASSERTIONS=6
KAT_BIN="/mayhem/kat_lunasvg"

if [ ! -x "$KAT_BIN" ]; then
  echo "test.sh: $KAT_BIN missing or not executable — mayhem/build.sh should have produced it" >&2
  emit_ctrf "lunasvg-kat" 0 "$EXPECTED_ASSERTIONS"
  exit $?
fi

out="$("$KAT_BIN" 2>&1)" || true
echo "$out"

ok_count="$(printf '%s\n' "$out" | grep -c '^ASSERT_OK: ' || true)"
fail_count="$(printf '%s\n' "$out" | grep -c '^ASSERT_FAIL: ' || true)"
accounted=$(( ok_count + fail_count ))
missing=$(( EXPECTED_ASSERTIONS - accounted ))
[ "$missing" -lt 0 ] && missing=0
failed=$(( fail_count + missing ))
passed="$ok_count"

emit_ctrf "lunasvg-kat" "$passed" "$failed"
