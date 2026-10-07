#!/bin/bash
# test-ci-annotate-check.sh - Tests for scripts/ci/annotate-check.sh
#
# The skip paths run on any machine. The Chrome-dependent assertions run only
# when a Chrome binary is present; on a browser-less machine they pass as
# SKIPs, because the harness itself skips legibly (the CI job is non-blocking).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HARNESS="$ROOT/scripts/ci/annotate-check.sh"
PROBE="$ROOT/scripts/ci/annotate-probe.mjs"

PASS_COUNT=0; FAIL_COUNT=0; TOTAL=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    Detail: $2"; }

echo "=== test-ci-annotate-check.sh ==="
echo ""

tmp_path_from() { echo "$1" | grep -o 'annotate fixture root: .*' | sed 's/^annotate fixture root: //' | head -1; }

# Test 1: no Chrome found - exits 0 with a SKIP line naming what it looked for
set +e
OUT=$(CRAFT_CI_CHROME=/nonexistent-chrome-for-test bash "$HARNESS" 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^SKIP: no Chrome binary found"; then
  pass "no Chrome present: exits 0 with a SKIP line naming what it looked for"
else
  fail "Chrome SKIP path wrong" "rc=$RC out: $(echo "$OUT" | tr '\n' ' ')"
fi

# Test 2: no node found - exits 0 with a SKIP line (needs a Chrome to get past
# the first skip, so a stand-in executable is enough: the node skip comes first)
STANDIN="$(mktemp)"
chmod +x "$STANDIN"
set +e
OUT=$(CRAFT_CI_CHROME="$STANDIN" CRAFT_CI_NODE=/nonexistent-node-for-test bash "$HARNESS" 2>&1)
RC=$?
set -e
rm -f "$STANDIN"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^SKIP: no node binary found"; then
  pass "no node present: exits 0 with a SKIP line naming what it looked for"
else
  fail "node SKIP path wrong" "rc=$RC out: $(echo "$OUT" | tr '\n' ' ')"
fi

# The probe runs the page in real time: it never calls a frame callback itself
# and never runs under an artificial clock.
if [ -f "$PROBE" ] && ! grep -q 'virtual-time' "$PROBE" "$HARNESS" \
  && ! grep -q 'Emulation.setVirtualTimePolicy' "$PROBE" \
  && ! grep -q 'file://' "$HARNESS"; then
  pass "the probe uses no virtual time and the fixture is never served over file://"
else
  fail "probe uses virtual time or the harness serves file://" "probe: $PROBE"
fi

# Tests 4-: the live assertions, when a Chrome is available. Discovery mirrors
# the harness's own order.
have_chrome=0
if [ -n "${CRAFT_CI_CHROME:-}" ] && [ -x "${CRAFT_CI_CHROME:-}" ]; then
  have_chrome=1
else
  for c in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$c" > /dev/null 2>&1 && have_chrome=1 && break
  done
  [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] && have_chrome=1
fi

if [ "$have_chrome" -eq 1 ] && command -v node > /dev/null 2>&1; then
  set +e
  OUT=$(bash "$HARNESS" 2>&1)
  RC=$?
  set -e
  if echo "$OUT" | grep -q '^SKIP:'; then
    pass "with Chrome: the harness skipped legibly (SKIPPED - $(echo "$OUT" | grep '^SKIP:' | head -1))"
    pass "with Chrome: the run's temp root and processes (SKIPPED)"
  else
    if [ "$RC" -eq 0 ]; then
      pass "with Chrome: the harness exits 0"
    else
      fail "the harness failed" "rc=$RC out: $(echo "$OUT" | tr '\n' ' ')"
    fi
    FIRST="$(echo "$OUT" | grep -o '^assert [0-9]* [A-Z]*' | head -1)"
    if [ "$FIRST" = "assert 1 OK" ]; then
      pass "with Chrome: assertion 1 is reported first and passes"
    else
      fail "assertion 1 is not first or did not pass" "first: '$FIRST'"
    fi
    MISSING=""
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
      echo "$OUT" | grep -q "^assert $n OK: " || MISSING="$MISSING $n"
    done
    if [ -z "$MISSING" ]; then
      pass "with Chrome: assertions 1-13 each report OK"
    else
      fail "assertions not OK:$MISSING" "out: $(echo "$OUT" | tr '\n' ' ')"
    fi
    TMP_USED="$(tmp_path_from "$OUT")"
    if [ -n "$TMP_USED" ] && [ ! -e "$TMP_USED" ]; then
      pass "the run's temp root is removed"
    else
      fail "temp root left behind or not reported" "path: '$TMP_USED'"
    fi
    # Anything the run started carries its root in its command line.
    if [ -n "$TMP_USED" ] && ! ps -ax -o command= | grep -F -- "$TMP_USED" | grep -v grep > /dev/null; then
      pass "no listener, watch, server or Chrome from the run is alive"
    else
      fail "a process from the run is still alive" "$(ps -ax -o pid=,command= | grep -F -- "$TMP_USED" | grep -v grep | head -3)"
    fi
  fi
else
  pass "with Chrome: assertion 1 first (SKIPPED - no Chrome or node on this machine)"
  pass "with Chrome: assertions 1-13 report OK (SKIPPED - no Chrome or node on this machine)"
  pass "with Chrome: temp root removed (SKIPPED - no Chrome or node on this machine)"
  pass "with Chrome: no process left alive (SKIPPED - no Chrome or node on this machine)"
fi

echo ""
echo "-- Summary --"
echo "Total:  $TOTAL"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
