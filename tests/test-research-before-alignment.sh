#!/bin/bash
# test-research-before-alignment.sh - Guard the orchestrator's research door.
# The alignment check catches an outside premise the project does not hold before any
# investigation: a single fact is settled in one line, anything bigger runs the shared
# research reference inline. Research that lands on the story reaches the Explore agent
# as ranked, non-binding evidence.

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

AC="$PLUGIN_ROOT/commands/references/alignment-check.md"
AC_TEXT="$(cat "$AC")"

begin_test "new step precedes the empty-codebase shortcut"
NEW_LINE="$(grep -nF -- '### Before Step 0: Research What Nobody in the Room Knows' "$AC" | head -1 | cut -d: -f1)"
STEP0_LINE="$(grep -nF -- '### Step 0: Empty-Codebase Short-Circuit' "$AC" | head -1 | cut -d: -f1)"
if [ -n "$NEW_LINE" ] && [ -n "$STEP0_LINE" ] && [ "$NEW_LINE" -lt "$STEP0_LINE" ]; then
  echo "  PASS: research step (line $NEW_LINE) sits above Step 0 (line $STEP0_LINE)"; PASS=$((PASS + 1))
else
  echo "  FAIL: research step missing or not above Step 0 (new=$NEW_LINE step0=$STEP0_LINE)"; FAIL=$((FAIL + 1))
fi
STEP_TEXT="$(sed -n '/^### Before Step 0:/,/^### Step 0:/p' "$AC")"

begin_test "door Reads the shared reference with the alignment door"
assert_contains_literal "reads the shared reference" 'research-inline.md' "$STEP_TEXT"
assert_contains_literal "passes the alignment door" 'DOOR=alignment' "$STEP_TEXT"
assert_contains_literal "passes the story" 'STORY' "$STEP_TEXT"
assert_file_not_contains "never names the research command to invoke" 'craft:research' "$AC"

begin_test "single fact and one-run rules present"
assert_contains_literal "checked line template" 'Checked: <fact> (<source>).' "$STEP_TEXT"
assert_contains_literal "three-search bound" 'three web searches' "$STEP_TEXT"
assert_contains_literal "one run per door" 'alignment door' "$STEP_TEXT"
assert_contains_literal "depth follows the shape of the question" '--quick' "$STEP_TEXT"
assert_contains_literal "receipt form for a settled fact" '- OUTSIDE FACT: <fact> - <source>' "$AC_TEXT"

begin_test "detection widened without breaking its pins"
DET_LINE_NUM="$(grep -nF -- '**Detection:**' "$AC" | head -1 | cut -d: -f1)"
DET="$(sed -n "${DET_LINE_NUM}p" "$AC")"
assert_contains_literal "source_concept pin" 'source_concept:' "$DET"
assert_contains_literal "decisions pin" 'decisions:' "$DET"
assert_contains_literal "OR pin" ' OR ' "$DET"
assert_contains_literal "skip sentence pin" 'skip directly to Step 1 with the existing prompt unchanged' "$DET"
assert_contains_literal "citation-entry clause" 'holds at least one citation entry' "$DET"

begin_test "research tier sits beside siblings, above mockups"
SIB_LINE="$(grep -nF -- 'Sibling story precedents and research findings' "$AC" | head -1 | cut -d: -f1)"
CON_LINE="$(grep -nF -- 'Concept Locked Decisions sections' "$AC" | head -1 | cut -d: -f1)"
MOCK_LINE="$(grep -nF -- 'Mockups (visual contracts' "$AC" | head -1 | cut -d: -f1)"
if [ -n "$SIB_LINE" ] && [ -n "$CON_LINE" ] && [ -n "$MOCK_LINE" ] && [ "$CON_LINE" -lt "$SIB_LINE" ] && [ "$SIB_LINE" -lt "$MOCK_LINE" ]; then
  echo "  PASS: research tier is between the Concept and Mockups tiers"; PASS=$((PASS + 1))
else
  echo "  FAIL: research tier misplaced (concept=$CON_LINE sibling=$SIB_LINE mockups=$MOCK_LINE)"; FAIL=$((FAIL + 1))
fi
assert_contains_literal "research anchor rule" '-> "Convergence Points"' "$AC_TEXT"

begin_test "research is evidence, never law"
assert_contains_literal "placeholder renamed" '[STORIES CARRYING REFERENCE MATERIALS' "$AC_TEXT"
assert_file_not_contains "old placeholder gone" 'PLANNING-SOURCED STORIES ONLY' "$AC"
assert_contains_literal "research contradiction is a CONFLICT" 'evidence, not law' "$AC_TEXT"

begin_test "re-run appends the receipt and batch names the backstop"
assert_contains_literal "re-run appends a Checked block" 'append a new `_Checked: <date>_` block' "$AC_TEXT"
assert_contains_literal "batch line names the planner backstop" "planner's research request is the backstop" "$AC_TEXT"

begin_test "new step carries no em dash and no date-shaped slug"
# Build the em dash from its bytes so this file does not carry one itself.
EM_DASH="$(printf '\xe2\x80\x94')"
assert_not_contains "research step carries no em dash" "$EM_DASH" "$STEP_TEXT"
assert_file_not_contains "no date-shaped slug" 'YYYY-MM-DD-slug' "$AC"

finish_tests
