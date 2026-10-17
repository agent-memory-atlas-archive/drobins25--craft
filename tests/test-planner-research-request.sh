#!/bin/bash
# test-planner-research-request.sh - Guard the planner's outside-world rule and its
# second cord. A load-bearing fact outside the repo is verified with the planner's own
# search; a fact still unsettled after three searches is a claim about a class, which
# comes back as a RESEARCH REQUEST (or, in batch, a Critical Blocker) and never becomes a
# "first test" that captures chosen instances.

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

AGENT="$PLUGIN_ROOT/agents/plan-chunks-agent.md"
GUIDE="$PLUGIN_ROOT/skills/plan-chunks/references/chunk-format-guide.md"
AGENT_TEXT="$(cat "$AGENT")"
GUIDE_TEXT="$(cat "$GUIDE")"

WEB_FORM='[verified: web - <source url or doc name> - <what was checked>]'
CLASS_TAG='unverifiable class claim - research request raised, never a first test'

begin_test "retired external-validation wording is gone"
assert_not_contains "skip line retired" 'Skip external validation unless the story mentions unfamiliar packages' "$AGENT_TEXT"
assert_not_contains "uncertain-packages line retired" 'For packages, APIs, or integrations you' "$AGENT_TEXT"

begin_test "outside-world rule and three-search tell present"
assert_contains_literal "agent web receipt form" "$WEB_FORM" "$AGENT_TEXT"
assert_contains_literal "agent three-search tell" 'three searches' "$AGENT_TEXT"
assert_contains_literal "guide web receipt form" "$WEB_FORM" "$GUIDE_TEXT"
assert_contains_literal "focused research verifies outside facts" 'focused research does not skip them' "$AGENT_TEXT"
assert_contains_literal "capture never satisfies a class" 'A capture of chosen instances never satisfies a class claim' "$AGENT_TEXT"

begin_test "request block carries five fields"
assert_contains_literal "block heading" '## RESEARCH REQUEST' "$AGENT_TEXT"
for f in 'Premise' 'Why load-bearing' 'Without research the plan assumes' 'Question' 'Investigation so far'; do
  assert_contains_literal "field label: $f" "**$f:**" "$(sed -n '/^## RESEARCH REQUEST/,/^```/p' "$AGENT")"
done

begin_test "batch request is a Critical Blocker of type research"
assert_contains_literal "class-claim tag" "$CLASS_TAG" "$AGENT_TEXT"
assert_contains_literal "blocker type column" 'dependency/missing/unverified/research' "$AGENT_TEXT"
assert_contains_literal "blocker recommendation column" 'block/defer/investigate/research' "$AGENT_TEXT"
assert_contains_literal "guide carries the batch tag" "$CLASS_TAG" "$GUIDE_TEXT"
case "$CLASS_TAG" in unverifiable*) echo "  PASS: tag starts with unverifiable"; PASS=$((PASS + 1));; *) echo "  FAIL: tag must start with unverifiable"; FAIL=$((FAIL + 1));; esac

begin_test "class claims never take the first-test escape"
assert_contains_literal "agent carve-out" 'A class claim never takes the first-test escape' "$AGENT_TEXT"
assert_contains_literal "guide carve-out" 'A class claim never takes the first-test escape' "$GUIDE_TEXT"
assert_contains_literal "guide research receipt" 'verified - research: <slug>' "$GUIDE_TEXT"
assert_contains_literal "receipt-audit carve-out" 'a class claim goes to a research request instead' "$(grep -F '**The receipt audit**' "$AGENT")"
assert_contains_literal "one-more-hour carve-out" 'a class claim goes to a research request instead' "$(grep -F '**The one-more-hour question.**' "$AGENT")"
assert_contains_literal "conditions-table carve-out" 'A class claim never takes the first-test escape' "$(grep -F '**The conditions table**' "$AGENT")"
assert_contains_literal "guide first-test rule names single-thing conditions" 'unverifiable single-thing condition MUST become' "$GUIDE_TEXT"

begin_test "research ranks below locked decisions"
assert_contains_literal "weight line" 'outside-world EVIDENCE' "$AGENT_TEXT"
assert_contains_literal "research anchors in file-type table" 'research `_plan.md` and branch files' "$AGENT_TEXT"

begin_test "removed researcher name stays absent"
bash "$PLUGIN_ROOT/tests/test-plan-researcher-removed.sh" >/dev/null 2>&1 \
  && { echo "  PASS: test-plan-researcher-removed.sh passes"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL: test-plan-researcher-removed.sh fails"; FAIL=$((FAIL + 1)); }

begin_test "no em dash in the new request block"
EM_DASH="$(printf '\xe2\x80\x94')"
assert_not_contains "block has no em dash" "$EM_DASH" "$(sed -n '/^### 2.7b/,/^---/p' "$AGENT")"

SKILL_FILE="$PLUGIN_ROOT/skills/plan-chunks/SKILL.md"
TRIAGE_FILE="$PLUGIN_ROOT/skills/plan-chunks/references/batch-triage.md"
DESIGN_FILE="$PLUGIN_ROOT/DESIGN.md"

begin_test "S-2 handles a research request inside the fork span"
FORK_BLOCK="$(sed -n '/\*\*Step 0 - PLAN FORK check:\*\*/,/\*\*Step 1 - Validate/p' "$SKILL_FILE")"
for t in '## RESEARCH REQUEST' 'R1. If the output' 'research-inline.md' 'DOOR=planner' 'planner door' 'alignment-check.md' 'sets `alignment: complete`' 'BT-2 item'; do
  assert_contains_literal "fork span carries: $t" "$t" "$FORK_BLOCK"
done

begin_test "batch prompt names the request"
BATCH_LINE="$(grep -A2 'BATCH MODE: PLAN FORK is unavailable' "$SKILL_FILE")"
assert_contains_literal "request unavailable in batch" 'RESEARCH REQUEST is unavailable too' "$BATCH_LINE"
assert_contains_literal "recorded as a research blocker" '`research` Critical Blocker' "$BATCH_LINE"
assert_file_not_contains "plan-chunks never names craft:research as something to invoke" 'craft:research' "$SKILL_FILE"

begin_test "batch triage runs research blockers before BT-2"
TRIAGE_TEXT="$(cat "$TRIAGE_FILE")"
assert_contains_literal "research blockers are not BT-2 questions" 'type `research` are not asked as BT-2 questions' "$TRIAGE_TEXT"
assert_contains_literal "run before BT-2" 'RESEARCH REQUEST steps R1-R3' "$TRIAGE_TEXT"
assert_contains_literal "triage names where the request block lives" 'output_file' "$TRIAGE_TEXT"
assert_contains_literal "triage never asks a research item directly" 'never asks it directly' "$TRIAGE_TEXT"
assert_contains_literal "held premise retags the conditions row" "retag the story's class-claim conditions row" "$TRIAGE_TEXT"
assert_contains_literal "BT-2 answer retags the same row" 'user ruled at triage' "$TRIAGE_TEXT"
assert_contains_literal "held premise line" 'kept as planned - research confirmed' "$TRIAGE_TEXT"
assert_contains_literal "overturned premise re-plans" 'Adjusted Story Re-Planning' "$(grep -i 'research' "$TRIAGE_FILE")"

begin_test "every writer of a contract line names the outside-fact receipt"
IMPLEMENT_TEXT="$(cat "$PLUGIN_ROOT/commands/craft-story-implement.md")"
CHUNKS_LAYOUT="$(grep -A1 '^## Chunks$' "$AGENT")"
assert_contains_literal "triage write list names the web form" "$WEB_FORM" "$TRIAGE_TEXT"
assert_contains_literal "triage write list names visual-source" '`[visual-source: ...]`' "$TRIAGE_TEXT"
assert_contains_literal "contract amendment names the web form" "$WEB_FORM" "$IMPLEMENT_TEXT"
assert_contains_literal "investigation receipt is never for an outside fact" 'Never for a fact outside the repo' "$GUIDE_TEXT"
assert_contains_literal "planner's Chunks layout carries the rule" "a fact from outside the repo is $WEB_FORM, never [investigation:]" "$CHUNKS_LAYOUT"

begin_test "DESIGN names the second cord"
DESIGN_TEXT="$(cat "$DESIGN_FILE")"
assert_contains_literal "design names the request" 'RESEARCH REQUEST' "$DESIGN_TEXT"
assert_contains_literal "design names the shared flow" 'research-inline.md' "$DESIGN_TEXT"

finish_tests
