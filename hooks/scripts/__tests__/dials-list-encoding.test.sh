#!/bin/bash
# dials-list-encoding.test.sh - A dial record that isn't valid UTF-8 never hides the dials after it
#
# Usage: bash hooks/scripts/__tests__/dials-list-encoding.test.sh
#
# Runs the real dials-list.sh against three dial records where the middle
# one holds a Latin-1 byte, asserting every dial is still listed (the bad one
# included, never skipped) and the script exits 0.

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$TESTS_DIR")"
LIST="$SCRIPTS_DIR/dials-list.sh"

# ── Helpers ──────────────────────────────────────────────────────

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  TOTAL=$((TOTAL + 1))
  echo "  ✓ $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  TOTAL=$((TOTAL + 1))
  echo "  ✗ $1"
  if [ -n "${2:-}" ]; then
    echo "    Expected: $2"
    echo "    Got:      $3"
  fi
}

assert_contains() {
  local output="$1" expected="$2" label="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    pass "$label"
  else
    fail "$label" "$expected" "(not found in output)"
  fi
}

write_dial() {
  local file="$1" date="$2" body="$3"
  printf -- '---\ncreated: %s\nsurface: probe-surface\nkind: color\nscope: approach\n---\n%b\n' "$date" "$body" > "$file"
}

# ── Test 1: A Latin-1 dial does not end the listing ─────────────

echo ""
echo "Test 1: A dial holding a Latin-1 byte is listed, and so is everything after it"

ROOT=$(mktemp -d)
DIALS="$ROOT/.craft/dials"
mkdir -p "$DIALS"
write_dial "$DIALS/2026-10-01-aaa.md" "2026-10-01" "aaa first dial"
write_dial "$DIALS/2026-10-02-bbb.md" "2026-10-02" "bbb caf\xe9 dial"
write_dial "$DIALS/2026-10-03-ccc.md" "2026-10-03" "ccc third dial"

set +e
output=$(env -u PROJECT_ROOT CRAFT_PROJECT_ROOT="$ROOT" bash "$LIST" 2>&1)
list_exit=$?
set -e

if [ "$list_exit" -eq 0 ]; then
  pass "List exits 0"
else
  fail "List exits 0" "0" "$list_exit"
fi
assert_contains "$output" "SLUG=aaa" "Dial before the Latin-1 one is listed"
assert_contains "$output" "SLUG=bbb" "The Latin-1 dial itself is listed, not skipped"
assert_contains "$output" "SLUG=ccc" "Dial after the Latin-1 one is listed"

rm -rf "$ROOT"

# ── Summary ──────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $TOTAL total"
echo "════════════════════════════════════════"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi

exit 0
