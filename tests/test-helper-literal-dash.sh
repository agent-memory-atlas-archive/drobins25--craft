#!/bin/bash
# test-helper-literal-dash.sh - Verify assert_contains_literal handles text that
# starts with a dash, like a markdown bullet.
#
# grep reads a leading "-" as an option unless the pattern follows "--", so a
# dash-led needle made the check error out instead of passing or failing. Each
# probe runs the helper in a subshell and reads the verdict it prints, so a
# probe that is supposed to fail cannot leak into this file's own counts.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

HAYSTACK=$'Step 5 notes\n- **A dash-led bullet**: some text\nlast line'

# Prints PASS or FAIL - the verdict the helper itself gave for one probe
verdict() {
  (
    source "$SCRIPT_DIR/test_helper.sh"
    assert_contains_literal "probe" "$1" "$HAYSTACK" 2>/dev/null
  ) | grep -oE '(PASS|FAIL):' | head -1 | tr -d ':' || true
}

echo "=== test-helper-literal-dash.sh ==="
echo ""

begin_test "a plain needle that is present passes (control)"
assert_eq "plain present needle" "PASS" "$(verdict 'Step 5 notes')"

echo ""

begin_test "a dash-led needle that is present passes"
assert_eq "dash-led present needle" "PASS" "$(verdict '- **A dash-led bullet**')"

echo ""

begin_test "a dash-led needle that is absent fails"
assert_eq "dash-led absent needle" "FAIL" "$(verdict '- **Not in the text**')"

echo ""

finish_tests "test-helper-literal-dash.sh"
