#!/bin/bash
# test-adhoc-fix-validation.sh - Verify the adhoc fix flow makes a newly added
# check prove itself against the broken version before it counts as validation.
#
# A fix with no implementer has no tests-first rule, so Step 5 of fix.md must
# ask for it: run the added test or structural check before the edit and see it
# fail on exactly the bug, run it after and see it pass, record both runs. A
# check that never ran against the broken version has proven nothing.
#
# Assertions are SECTION-SCOPED (fence-aware awk between ## headings): the
# bullet must live inside Step 5, directly above the All fixes bullet. A
# file-wide grep would pass if a later edit moved it elsewhere. The control
# assertion proves the section lookup itself works, so a red on the bullet
# assertions can only mean the bullet is missing or misplaced.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

# Working-tree file - guards THIS repo's edits, not the installed plugin copy
FIX_MD="$SCRIPT_DIR/../skills/adhoc/references/fix.md"

BULLET='- **A fix that adds a test or a structural check**: Before applying the edit (or against a copy without it), run the new check and confirm it fails on exactly the bug and nothing else. After the edit, run it again and confirm it passes. Record both runs in the Validation section - a check never run against the broken version has not proven anything. This never asks a fix to add a check it would not otherwise have.'
ALL_FIXES='- **All fixes**:'
# assert_contains_literal passes the needle to grep without "--", so a needle
# starting with "- " is read as an option; the contains-checks drop the marker
# and the adjacency check below compares the whole line, marker included
BULLET_BODY="${BULLET#- }"
ALL_FIXES_BODY="${ALL_FIXES#- }"

# Prints a ## section's body (heading to next ## heading or EOF).
# Fence-aware: a "## " line inside a ``` code block is content, not a boundary.
section() {
  awk -v h="$1" '
    /^```/ { fence = !fence }
    $0 ~ "^## " h { found = 1; next }
    /^## / { if (found && !fence) exit }
    found
  ' "$2"
}

echo "=== test-adhoc-fix-validation.sh ==="
echo ""

STEP5="$(section "Step 5: Validate the Symptom" "$FIX_MD")"
# '|| true' keeps set -e from aborting on an empty match, which would be a
# red that proves nothing
ABOVE_ALL_FIXES="$(echo "$STEP5" | grep -B1 -F -- "$ALL_FIXES" | head -1 || true)"

begin_test "Step 5 section is found (control)"
assert_contains_literal \
  "Step 5 contains the All fixes bullet" \
  "$ALL_FIXES_BODY" \
  "$STEP5"

echo ""

begin_test "Step 5 carries the fails-first bullet verbatim"
assert_contains_literal \
  "Step 5 contains the full fails-first bullet" \
  "$BULLET_BODY" \
  "$STEP5"

echo ""

begin_test "the fails-first bullet sits directly above All fixes"
assert_eq \
  "line preceding All fixes is the fails-first bullet" \
  "$BULLET" \
  "$ABOVE_ALL_FIXES"

echo ""

finish_tests "test-adhoc-fix-validation.sh"
