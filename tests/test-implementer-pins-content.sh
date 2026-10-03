#!/bin/bash
# test-implementer-pins-content.sh - Verify the implementer is told to prove
# "unchanged" by a file's content, never by diffing the project's own tree.
#
# A test that compares the working tree against the last commit passes only
# while the change is uncommitted, then fails forever once it is committed.
# The implementer decides how to write tests in "What Needs Tests", so the
# rule must live there, as the last paragraph before the section's divider.
#
# Assertions are SECTION-SCOPED (fence-aware awk from the ### heading to the
# next --- divider or heading). The control assertion proves the section
# lookup itself works, so a red on the paragraph can only mean it is missing
# or misplaced.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

# Working-tree file - guards THIS repo's edits, not the installed plugin copy
IMPLEMENTER_MD="$SCRIPT_DIR/../agents/implementer.md"

PARAGRAPH='**Pin content, never the repo'"'"'s uncommitted diff.** When a criterion says a file is unchanged or gained one line, check the file'"'"'s content - the text it must or must not contain - never `git diff HEAD` or `git status` of the project'"'"'s own tree. That check passes only until the change is committed, then fails forever. A throwaway git repo that a test builds for itself is fine.'
CONTROL='**Principle: Test behavior, not existence.**'

# Prints the "### What Needs Tests" body, up to the next --- divider or
# heading. Fence-aware: lines inside a ``` block never end the section.
what_needs_tests() {
  awk '
    /^```/ { fence = !fence }
    /^### What Needs Tests/ { found = 1; next }
    found && !fence && (/^---$/ || /^#{1,3} /) { exit }
    found
  ' "$IMPLEMENTER_MD"
}

echo "=== test-implementer-pins-content.sh ==="
echo ""

SECTION="$(what_needs_tests)"
# Last non-blank line of the section; '|| true' keeps set -e from aborting on
# an empty section, which would be a red that proves nothing
LAST_LINE="$(printf '%s\n' "$SECTION" | grep -v '^[[:space:]]*$' | tail -1 || true)"

begin_test "What Needs Tests section is found (control)"
assert_contains_literal \
  "the section contains the test-behavior principle" \
  "$CONTROL" \
  "$SECTION"

echo ""

begin_test "the pin-content paragraph closes What Needs Tests"
assert_eq \
  "the last line before the divider is the pin-content paragraph" \
  "$PARAGRAPH" \
  "$LAST_LINE"

echo ""

finish_tests "test-implementer-pins-content.sh"
