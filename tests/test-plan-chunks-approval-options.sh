#!/bin/bash
# test-plan-chunks-approval-options.sh - Guard plan-chunks' single-story approval prompt:
# exactly two forward options (neither recommended), a hand-back rule shared by both
# "start implementing" handlers, the dead edit/explore handlers gone, and a visual gate
# that stays silent for non-UI stories. Blocks are extracted by heading so a stray
# match elsewhere in the file cannot satisfy or break an assertion.

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

SKILL="$PLUGIN_ROOT/skills/plan-chunks/SKILL.md"

S4_BLOCK="$(sed -n '/^### S-4: Present Plan for Approval/,/^### S-5/p' "$SKILL")"
S5_BLOCK="$(sed -n '/^### S-5: Finalize Story/,/^### S-6/p' "$SKILL")"
S6_BLOCK="$(sed -n '/^### S-6: Offer Implementation/,/^## Multi-Story Planning/p' "$SKILL")"
NOW_HANDLER="$(sed -n '/^\*\*If "Mark ready and start implementing now":\*\*/,/^### S-6/p' <<< "$S5_BLOCK")"
IMPLEMENT_HANDLER="$(sed -n '/^\*\*If "Yes, implement now":\*\*/,/^\*\*If "Plan another story first":\*\*/p' <<< "$S6_BLOCK")"
BATCH="$PLUGIN_ROOT/skills/plan-chunks/references/batch-triage.md"
BT5_BLOCK="$(sed -n '/^### BT-5: Per-Story Approval/,/^### BT-5: Adjust Feedback/p' "$BATCH")"
P046_BLOCK="$(sed -n '/^## Phase 0.46/,/^## Phase 0.5/p' "$SKILL")"

begin_test "S-4 offers exactly two options, in order, recommending neither"
assert_contains "S-4 block extracted" 'Does this implementation plan look complete?' "$S4_BLOCK"
assert_eq "two labels" "2" "$(echo "$S4_BLOCK" | grep -c 'label:')"
assert_eq "first label" '  - label: "Yes, mark ready"' "$(echo "$S4_BLOCK" | grep 'label:' | sed -n 1p)"
assert_eq "second label" '  - label: "Mark ready and start implementing now"' "$(echo "$S4_BLOCK" | grep 'label:' | sed -n 2p)"
assert_not_contains "nothing marked recommended" '(Recommended)' "$S4_BLOCK"

begin_test "removed approval options and their breadcrumb stay dead"
assert_not_contains "no Explore creatively label" '"Explore creatively"' "$(cat "$SKILL")"
assert_not_contains "no More detail handler" 'More detail on a chunk' "$(cat "$SKILL")"
assert_not_contains "no Adjust the approach handler" 'Adjust the approach' "$(cat "$SKILL")"
assert_not_contains "no orphaned too-big handler" 'This is too big' "$(cat "$SKILL")"
assert_not_contains "no continuation breadcrumb" '\.continuation' "$(cat "$SKILL")"

begin_test "Confirm gate is untouched"
assert_file_contains "Explore creatively first survives" 'Explore creatively first' "$SKILL"
assert_file_contains "Adjust the scope survives" 'Adjust the scope' "$SKILL"

begin_test "new handler marks ready and hands back to a waiting caller"
assert_contains "new handler exists" 'If "Mark ready and start implementing now"' "$S5_BLOCK"
assert_contains "marks the story ready" 'update-story-status.sh' "$NOW_HANDLER"
assert_contains_literal "hand-back trigger" 'a calling flow is waiting to resume' "$S5_BLOCK"
assert_contains_literal "decided from conversation" 'never from the args' "$S5_BLOCK"
assert_contains "names story-implement" 'story-implement' "$NOW_HANDLER"
assert_contains "names cycle-start" 'cycle-start' "$NOW_HANDLER"
assert_contains "direct start invokes story-implement" 'craft:craft-story-implement' "$NOW_HANDLER"
assert_contains "guards against inline implementation" 'DO NOT implement directly' "$NOW_HANDLER"
assert_contains_literal "start-now prompt is skipped" 'S-6 does not run' "$NOW_HANDLER"

begin_test "Yes, mark ready handler and S-6 options unchanged"
assert_contains "mark ready handler survives" 'If "Yes, mark ready":' "$S5_BLOCK"
assert_contains_literal "reconciliation sentence survives" 'Triage answers already landed in the story file at answer time' "$S5_BLOCK"
assert_contains "S-6 question unchanged" 'question: "Story is ready to implement. Start now?"' "$S6_BLOCK"
assert_eq "S-6 keeps three labels" "3" "$(echo "$S6_BLOCK" | grep -c 'label:')"
assert_contains "S-6 implement option" 'label: "Yes, implement now"' "$S6_BLOCK"
assert_contains "S-6 plan-another option" 'label: "Plan another story first"' "$S6_BLOCK"
assert_contains "S-6 later option" 'label: "Come back later"' "$S6_BLOCK"

begin_test "Yes, implement now hands back too"
assert_contains "S-6 handler block extracted" 'DO NOT implement directly' "$IMPLEMENT_HANDLER"
assert_contains_literal "S-6 handler applies the hand-back rule" 'a calling flow is waiting to resume' "$IMPLEMENT_HANDLER"
assert_contains "S-6 handler still invokes story-implement for a direct start" 'craft:craft-story-implement' "$IMPLEMENT_HANDLER"

begin_test "non-UI stories pass the visual gate silently"
assert_contains "0.46 block extracted" 'Creative Spark Prerequisite Check' "$P046_BLOCK"
assert_eq "one visual question (the ui branch)" "1" "$(echo "$P046_BLOCK" | grep -c 'question: "Want to riff visual options')"
assert_contains_literal "non-ui continues with no prompt" 'continue to Phase 0.5 with no prompt' "$P046_BLOCK"
assert_not_contains "no non-UI skip option" 'Skip - not a UI story' "$P046_BLOCK"
assert_not_contains "no riff-anyway option" 'Yes, riff anyway' "$P046_BLOCK"
assert_not_contains "no chunk-approval-time promise" 'chunk-approval time' "$P046_BLOCK"

begin_test "ui visual gate unchanged"
assert_contains_literal "ui riff option" 'Yes, riff with creative-spark (Recommended)' "$P046_BLOCK"
assert_contains_literal "ui skip option" 'Skip - I know what I want' "$P046_BLOCK"

begin_test "batch approval offers Approve, Adjust, Reject"
assert_contains "BT-5 block extracted" 'Approve?' "$BT5_BLOCK"
assert_eq "three labels" "3" "$(echo "$BT5_BLOCK" | grep -c 'label:')"
assert_eq "first label" '  - label: "Approve"' "$(echo "$BT5_BLOCK" | grep 'label:' | sed -n 1p)"
assert_eq "second label" '  - label: "Adjust"' "$(echo "$BT5_BLOCK" | grep 'label:' | sed -n 2p)"
assert_eq "third label" '  - label: "Reject"' "$(echo "$BT5_BLOCK" | grep 'label:' | sed -n 3p)"
assert_not_contains "no Explore in BT-5" 'Explore' "$BT5_BLOCK"

begin_test "batch has no creative re-riff"
assert_not_contains "no creative-spark in batch triage" 'creative-spark' "$(cat "$BATCH")"

begin_test "batch Adjust follow-up intact"
assert_file_contains "Adjust feedback question survives" 'What should change about' "$BATCH"

begin_test "batch summary prose matches"
assert_file_contains "summary names three options" 'Approve/Adjust/Reject' "$SKILL"
assert_not_contains "no Approve/Explore" 'Approve/Explore' "$(cat "$SKILL")"

finish_tests
