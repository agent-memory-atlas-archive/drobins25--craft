#!/bin/bash
# notebook-notes-index-encoding.test.sh - A note that isn't valid UTF-8 never blanks the notes index
#
# Usage: bash hooks/scripts/__tests__/notebook-notes-index-encoding.test.sh
#
# Runs the real notebook-notes-index.sh against three notes where the middle
# one holds a Latin-1 byte. Session start shows this index in every session,
# so one bad note must never empty it: every note is listed and the exit is 0.

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$TESTS_DIR")"
LIST="$SCRIPTS_DIR/notebook-notes-index.sh"

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

write_note() {
  local file="$1" date="$2" body="$3"
  printf -- '---\ncreated: %s\ntags: []\n---\n%b\n' "$date" "$body" > "$file"
}

# ── Test 1: A Latin-1 note does not empty the index ─────────────

echo ""
echo "Test 1: A note holding a Latin-1 byte is indexed, and so is every other note"

ROOT=$(mktemp -d)
NOTES="$ROOT/.craft/notebook/notes"
mkdir -p "$NOTES"
write_note "$NOTES/2026-10-01-aaa.md" "2026-10-01" "aaa first note"
write_note "$NOTES/2026-10-02-bbb.md" "2026-10-02" "bbb caf\xe9 note"
write_note "$NOTES/2026-10-03-ccc.md" "2026-10-03" "ccc third note"

set +e
output=$(env -u PROJECT_ROOT CRAFT_PROJECT_ROOT="$ROOT" bash "$LIST" 2>&1)
list_exit=$?
set -e

if [ "$list_exit" -eq 0 ]; then
  pass "Index exits 0"
else
  fail "Index exits 0" "0" "$list_exit"
fi
assert_contains "$output" "Notebook notes" "The index header is printed"
assert_contains "$output" "aaa first note" "Note before the Latin-1 one is indexed"
assert_contains "$output" "[bbb]" "The Latin-1 note itself is indexed, not skipped"
assert_contains "$output" "ccc third note" "Note after the Latin-1 one is indexed"

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
