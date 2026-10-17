#!/bin/bash
# test-plan-chunks-direction-gate-skip.sh - Guard the plan-chunks direction gate's skip
# conditions. When the user's own words already asked to plan (a direct
# /craft:plan-chunks, "plan this", or a yes to an offer to plan), Phase 0.5 must not
# ask "Ready to plan this story?" a second time. The batch gate skips only on the flag. Command
# hand-offs keep the DIRECTION_CONFIRMED flag, and the never-auto-invoke guard stays.

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

SKILL="$PLUGIN_ROOT/skills/plan-chunks/SKILL.md"

DIRECTION_BLOCK="$(sed -n '/^## Phase 0.5: Direction Confirmation Gate/,/^## Single-Story Planning/p' "$SKILL")"
REMEMBER_BLOCK="$(sed -n '/^## Remember/,$p' "$SKILL")"

begin_test "direction gate skips when the user already asked to plan"
assert_contains "direction gate block extracted" 'Ready to plan this story?' "$DIRECTION_BLOCK"
assert_contains "flag skip survives" 'Args contain `DIRECTION_CONFIRMED: true`' "$DIRECTION_BLOCK"
assert_contains "user-ask skip present" "The user's own words in this session asked to plan this story:" "$DIRECTION_BLOCK"
assert_contains "user-ask skip needs the story named" 'they invoked `/craft:plan-chunks` naming it, said "plan this" or similar about it' "$DIRECTION_BLOCK"
assert_contains "user-ask skip names the yes to an offer" 'answered yes to a question that offered to plan it' "$DIRECTION_BLOCK"
assert_contains "no-ask paths still gated" 'It does not count when the story was reached with no ask from the user' "$DIRECTION_BLOCK"
assert_contains "unnamed pick still gated" 'or a story picked because none was named' "$DIRECTION_BLOCK"
assert_not_contains "user-ask skip covers one story only" 'these stories' "$DIRECTION_BLOCK"

begin_test "batch gate skips only on the flag"
assert_contains "batch keeps the flag-only skip" 'Same skip logic - if `DIRECTION_CONFIRMED: true`, skip the gate.' "$DIRECTION_BLOCK"
assert_not_contains "batch never borrows the user-ask skip" 'Same skip conditions as above.' "$DIRECTION_BLOCK"

begin_test "never-auto-invoke guard still stated"
assert_file_contains "CRITICAL guard survives" 'Never auto-invoke this skill.' "$SKILL"
assert_contains "Remember guard survives" 'Never auto-invoke' "$REMEMBER_BLOCK"
assert_contains "Remember names the user-ask skip" "It skips when the user's own words already asked to plan" "$REMEMBER_BLOCK"

finish_tests
