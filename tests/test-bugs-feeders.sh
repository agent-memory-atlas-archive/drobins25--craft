#!/bin/bash
# test-bugs-feeders.sh - Coverage for feeding /craft:bugs from the analyzers.
#
# The filing reference is read by the orchestrator, which turns an analyzer's
# returned report into bug records. Its worked example is the contract with
# the capture script: if the example stops passing capture's seven-field check
# or stops reading back through the list script, every filing built from the
# reference would fail. These tests drive the example through the real scripts.
# Usage: bash tests/test-bugs-feeders.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

REPO="$PLUGIN_ROOT"
REF="$REPO/commands/references/analysis-bug-filing.md"
CAPTURE="$SCRIPTS_DIR/bugs-capture.sh"
LIST="$SCRIPTS_DIR/bugs-list.sh"
TMP_ROOTS=()

cleanup_roots() {
  local r
  for r in "${TMP_ROOTS[@]:-}"; do [ -n "$r" ] && rm -rf "$r"; done
  return 0
}
trap cleanup_roots EXIT

# fenced_block <info-string> <file> - body of the single fence with that info string
fenced_block() {
  awk -v info="$1" '
    $0 == "```" info {inside=1; next}
    inside && $0 == "```" {exit}
    inside {print}
  ' "$2"
}

# fence_count <info-string> <file> - number of fences opened with that info string
fence_count() { grep -cx -- "\`\`\`$1" "$2"; }

begin_test "worked example round trips through capture and list"
assert_file_exists "commands/references/analysis-bug-filing.md" "$REF"
if [ -f "$REF" ]; then
  FOUND="$(fenced_block found-during "$REF")"
  BODY="$(fenced_block bug-body "$REF")"
  ROOT=$(mktemp -d); TMP_ROOTS+=("$ROOT")
  mkdir -p "$ROOT/.craft/bugs"
  CAP_ERR=$(mktemp)
  CAP_OUT="$(printf '%s\n' "$BODY" | CRAFT_PROJECT_ROOT="$ROOT" bash "$CAPTURE" --found-during="$FOUND" --stdin 2>"$CAP_ERR")"
  CAP_RC=$?
  assert_eq "capture accepts the worked body (rc 0)" "0" "$CAP_RC"
  assert_eq "capture stderr is empty" "" "$(cat "$CAP_ERR")"
  rm -f "$CAP_ERR"
  RECORD="$(printf '%s\n' "$CAP_OUT" | tail -1)"
  LISTED="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$LIST" --status=open 2>/dev/null)"
  assert_eq "FOUND_DURING reads back byte-equal to the found-during block" \
    "FOUND_DURING=$FOUND" "$(printf '%s\n' "$LISTED" | grep '^FOUND_DURING=')"
  assert_eq "BLOCKS reads back no" "BLOCKS=no" "$(printf '%s\n' "$LISTED" | grep '^BLOCKS=')"
  RECORD_TEXT="$(cat "$RECORD" 2>/dev/null)"
  assert_contains_literal "record holds a References section" "## References" "$RECORD_TEXT"
  CONSOLE_LINE="$(printf '%s\n' "$BODY" | awk '/^## References/{p=1; next} p && /^## /{exit} p && /rror/{print; exit}')"
  assert_contains_literal "record carries the console line from References" "${CONSOLE_LINE#- }" "$RECORD_TEXT"
fi

begin_test "worked example blocks are single and exact"
assert_eq "one found-during fence" "1" "$(fence_count found-during "$REF")"
assert_eq "one bug-body fence" "1" "$(fence_count bug-body "$REF")"
assert_eq "found-during block is the single scope-first line" \
  "craft analyze qa: the checkout page (Cycle 4: Payments)" "$(fenced_block found-during "$REF")"
assert_eq "bug body has no angle-bracket placeholder lines" "0" \
  "$(fenced_block bug-body "$REF" | grep -cE '<[^>]+>')"

REF_TEXT="$(cat "$REF" 2>/dev/null)"

begin_test "reference states the five found_during forms"
assert_contains_literal "mid-cycle form" 'craft analyze <type>: <scope> (<cycle title>)' "$REF_TEXT"
assert_contains_literal "after-close form" 'craft analyze <type>: <scope> (after <cycle title>)' "$REF_TEXT"
assert_contains_literal "no-cycle form" 'craft analyze <type>: <scope>`' "$REF_TEXT"
assert_contains_literal "whole-cycle form" 'craft analyze <type>: all stories in <Cycle N>' "$REF_TEXT"
assert_contains_literal "cycle-complete form" 'craft cycle-complete walkthrough: <cycle title>' "$REF_TEXT"

begin_test "reference names the scripts, the capture call, and blocks no"
assert_contains_literal "open pile listing" 'bugs-list.sh" --status=open' "$REF_TEXT"
assert_contains_literal "hit on the FILE path" 'bugs-hit.sh" "<FILE>" --where="<found_during>"' "$REF_TEXT"
assert_contains_literal "capture with found-during" 'bugs-capture.sh" --found-during="<found_during>"' "$REF_TEXT"
assert_contains_literal "capture reads stdin" '--stdin <<'"'"'BODY'"'"'' "$REF_TEXT"
assert_contains_literal "blocks line starts no" 'no - found by' "$REF_TEXT"

begin_test "reference routes feels-off and nitpick to ux.yaml with source: walkthrough"
assert_contains_literal "ux queue path" '.craft/analysis/pending/ux.yaml' "$REF_TEXT"
assert_contains_literal "walkthrough source key" 'source: walkthrough' "$REF_TEXT"
assert_contains_literal "feels-off named" 'feels-off' "$REF_TEXT"
assert_contains_literal "nitpick named" 'nitpick' "$REF_TEXT"

begin_test "reference carries no browser tool name, question block, or dated slug"
assert_not_contains "no chrome-devtools" 'chrome-devtools' "$REF_TEXT"
assert_not_contains "no AskUserQuestion" 'AskUserQuestion' "$REF_TEXT"
assert_not_contains "no question: line" 'question:' "$REF_TEXT"
assert_not_contains "no dated slug" '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[a-z]' "$REF_TEXT"
assert_not_contains "no em dash" '—' "$REF_TEXT"

ANALYZE="$REPO/commands/craft-analyze.md"
QA_AGENT="$REPO/agents/qa-analyzer.md"
WT_AGENT="$REPO/agents/walkthrough-analyzer.md"
ANALYZE_TEXT="$(cat "$ANALYZE" 2>/dev/null)"
QA_TEXT="$(cat "$QA_AGENT" 2>/dev/null)"
WT_TEXT="$(cat "$WT_AGENT" 2>/dev/null)"

begin_test "analyze never names qa.yaml or walkthrough.yaml"
assert_not_contains "analyze has no qa.yaml" 'qa\.yaml' "$ANALYZE_TEXT"
assert_not_contains "analyze has no walkthrough.yaml" 'walkthrough\.yaml' "$ANALYZE_TEXT"
assert_not_contains "qa-analyzer has no qa.yaml" 'qa\.yaml' "$QA_TEXT"
assert_not_contains "walkthrough-analyzer has no walkthrough.yaml" 'walkthrough\.yaml' "$WT_TEXT"
assert_contains_literal "pending check names ux.yaml" 'ux.yaml' "$ANALYZE_TEXT"
assert_contains_literal "pending check names creative.yaml" 'creative.yaml' "$ANALYZE_TEXT"
assert_contains_literal "pending check names style.yaml" 'style.yaml' "$ANALYZE_TEXT"

begin_test "analyze reads the filing reference and get-latest-cycle --status=complete"
assert_contains_literal "reference path" '${CLAUDE_PLUGIN_ROOT}/commands/references/analysis-bug-filing.md' "$ANALYZE_TEXT"
assert_contains_literal "completed-cycle lookup" 'get-latest-cycle.sh" "$PROJECT" --status=complete' "$ANALYZE_TEXT"
assert_contains_literal "global state read" '.craft/.global-state' "$ANALYZE_TEXT"

begin_test "analyze offers Last completed cycle (<title>)"
assert_contains_literal "last completed option" 'Last completed cycle (<title>)' "$ANALYZE_TEXT"
assert_contains_literal "quick command default" 'current cycle, or the last completed one' "$ANALYZE_TEXT"
assert_contains_literal "bugs filed pointer" '.craft/bugs/' "$ANALYZE_TEXT"

begin_test "analyze Phase 2 has no QA or Walkthrough create-story question"
assert_not_contains "no QA create-story question" 'Create story for this QA finding' "$ANALYZE_TEXT"
assert_not_contains "no walkthrough create-story question" 'Create story for this walkthrough finding' "$ANALYZE_TEXT"

begin_test "qa and walkthrough templates are gone; ux, creative, style remain"
assert_file_not_exists "qa template deleted" "$REPO/templates/analysis/pending/qa.yaml"
assert_file_not_exists "walkthrough template deleted" "$REPO/templates/analysis/pending/walkthrough.yaml"
assert_file_exists "ux template stays" "$REPO/templates/analysis/pending/ux.yaml"
assert_file_exists "creative template stays" "$REPO/templates/analysis/pending/creative.yaml"
assert_file_exists "style template stays" "$REPO/templates/analysis/pending/style.yaml"

begin_test "qa-analyzer and walkthrough-analyzer say filed as a bug and keep no Stories to Create section"
assert_contains_literal "qa-analyzer says filed as a bug" 'filed as one bug record' "$QA_TEXT"
assert_contains_literal "qa-analyzer never fixes" 'never fixed by you' "$QA_TEXT"
assert_not_contains "qa-analyzer has no Stories to Create" 'Stories to Create' "$QA_TEXT"
assert_not_contains "qa-analyzer has no Story Candidates" 'Story Candidates' "$QA_TEXT"
assert_contains_literal "walkthrough-analyzer says filed as bugs" 'are filed as bugs' "$WT_TEXT"
assert_not_contains "walkthrough-analyzer has no Stories to Create" 'Stories to Create' "$WT_TEXT"
assert_contains_literal "qa-analyzer keeps chrome-devtools" 'chrome-devtools' "$QA_TEXT"
assert_contains_literal "walkthrough-analyzer keeps chrome-devtools" 'chrome-devtools' "$WT_TEXT"

begin_test "walkthrough-analyzer drops Complexity and Quick Fixes"
assert_not_contains "no Complexity classification" 'Complexity' "$WT_TEXT"
assert_not_contains "no Quick Fixes section" 'Quick Fixes' "$WT_TEXT"
assert_not_contains "no quick-fix grade" 'quick-fix' "$WT_TEXT"
assert_contains_literal "fix hint stays" '**Fix hint:**' "$WT_TEXT"

CYCLE_COMPLETE="$REPO/commands/craft-cycle-complete.md"
CC_TEXT=$(cat "$CYCLE_COMPLETE")
CC_STEP_2B=$(awk '/^### Step 2b/{inside=1} /^### Step 3:/{inside=0} inside' "$CYCLE_COMPLETE")

begin_test "cycle-complete carries no repair-loop strings"
for lit in 'Walkthrough Fix Loop' 'attempt' '-fix-[slug]' 'Re-run' 'blocks-ship' 'qa.yaml' 'walkthrough.yaml' 'chrome-devtools'; do
  if grep -qiF -- "$lit" "$CYCLE_COMPLETE"; then
    echo "  FAIL: cycle-complete still carries '$lit'"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: cycle-complete has no '$lit'"
    PASS=$((PASS + 1))
  fi
done

begin_test "cycle-complete Step 2b reads the filing reference with the cycle-complete found_during form"
assert_contains_literal "Step 2b section was extracted" '### Step 2b' "$CC_STEP_2B"
assert_contains_literal "Step 2b names the filing reference" 'commands/references/analysis-bug-filing.md' "$CC_STEP_2B"
assert_contains_literal "Step 2b uses the cycle-complete found_during form" 'craft cycle-complete walkthrough: <title>' "$CC_STEP_2B"

begin_test "Step 2b has no AskUserQuestion block"
assert_not_contains "no question: in Step 2b" 'question:' "$CC_STEP_2B"
assert_not_contains "no AskUserQuestion in Step 2b" 'AskUserQuestion' "$CC_STEP_2B"

begin_test "cycle-complete summary reports bugs filed and Remember says the walkthrough never fixes"
assert_contains_literal "Step 5 Bugs filed line" 'Bugs filed: <N>' "$CC_TEXT"
assert_contains_literal "Remember line" 'The walkthrough files bugs and never fixes; bug then /craft:adhoc is the fix path.' "$CC_TEXT"

begin_test "no doc names a retired queue"
for f in DESIGN.md docs/decision-tree.md scripts/check-doc-drift.sh; do
  for lit in 'qa.yaml' 'walkthrough.yaml'; do
    if grep -qF -- "$lit" "$REPO/$f"; then
      echo "  FAIL: $f still names '$lit'"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS: $f has no '$lit'"
      PASS=$((PASS + 1))
    fi
  done
done

begin_test "agent-catalog drops the quick-fix exception"
assert_not_contains "no quick-fix exception" 'Quick-fix exception' "$(cat "$REPO/docs/agent-catalog.md")"

begin_test "check-doc-drift.sh exits 0"
if (cd "$REPO" && bash scripts/check-doc-drift.sh >/dev/null 2>&1); then
  echo "  PASS: check-doc-drift.sh exits 0"
  PASS=$((PASS + 1))
else
  echo "  FAIL: check-doc-drift.sh exits non-zero"
  FAIL=$((FAIL + 1))
fi

finish_tests "test-bugs-feeders"
