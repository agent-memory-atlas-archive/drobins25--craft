#!/bin/bash
# test-muse-lock-asks-in-prose.sh - The muse's fourth turn presents the Emotional Core
# and asks "Does this capture it?" as prose: no widget spec, no option labels, and the
# turn-presentation rule covers only the three open questions (Steps 3-5). The outcome
# rules (a yes locks, a change is applied and re-presented, 2 refinements max) stay.

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

MUSE="$PLUGIN_ROOT/commands/references/muse-inline.md"

STEP6_BLOCK="$(sed -n '/^### Step 6/,/^### The horizon line/p' "$MUSE")"

begin_test "turn-presentation rule scoped to the open questions"
assert_file_contains "heading names Steps 3-5" '### Turn presentation (applies to the open questions, Steps 3-5)' "$MUSE"
assert_file_not_contains "heading no longer spans Step 6" 'applies to every turn, Steps 3-6' "$MUSE"
assert_file_contains "Step 6 line names the ask, not a widget" 'the ask is only "Does this capture it?"' "$MUSE"
assert_file_not_contains "no widget named at Step 6" 'the widget asks only' "$MUSE"

begin_test "Step 6 closes in prose with the outcome rules"
assert_contains "Step 6 block extracted" 'Does this capture it? Anything to refine?' "$STEP6_BLOCK"
assert_contains "a yes locks" 'A yes locks it.' "$STEP6_BLOCK"
assert_contains "a change is applied and re-presented" 'A change is applied to the field it names and the four fields are re-presented.' "$STEP6_BLOCK"
assert_contains "refinement cap survives" 'Up to 2 refinements before forced lock' "$STEP6_BLOCK"
assert_not_contains "no widget spec" 'AskUserQuestion' "$STEP6_BLOCK"
assert_not_contains "no Muse 4/4 header" 'Muse 4/4' "$STEP6_BLOCK"
assert_not_contains "no lock option label" 'Yes, lock it' "$STEP6_BLOCK"
assert_not_contains "no refine option label" 'Refine one field' "$STEP6_BLOCK"
assert_not_contains "no wrap option label" 'Wrap with what we have' "$STEP6_BLOCK"

finish_tests
