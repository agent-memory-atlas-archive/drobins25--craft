#!/bin/bash
# test-bugs-wiring.sh - Doc-grep coverage for the /craft:bugs door.
#
# The command opens with a shell-preprocessed line that runs before the model
# reads anything. A non-zero exit from it aborts the whole invocation, and
# outside auto mode it also aborts unless a permission rule allows it. These
# tests freeze the exact injected line, the one rule that allows it, and the
# frontmatter and reference contents the command's behaviour depends on.
# Usage: bash tests/test-bugs-wiring.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

REPO="$PLUGIN_ROOT"
CMD="$REPO/commands/craft-bugs.md"
REF="$REPO/commands/references/bugs-record.md"

begin_test "command and reference files exist"
assert_file_exists "commands/craft-bugs.md" "$CMD"
assert_file_exists "commands/references/bugs-record.md" "$REF"
# Fence-scoped frontmatter of a file
frontmatter_of() { awk '/^---$/{n++; next} n==1{print} n==2{exit}' "$1"; }

if [ ! -e "$CMD" ] || [ ! -e "$REF" ]; then
  begin_test "adhoc description points deferred defects at /craft:bugs"
ADHOC_DESC="$(grep -m1 '^description:' "$REPO/skills/adhoc/SKILL.md")"
assert_contains_literal "adhoc names /craft:bugs for a defect to fix later" \
  'Acts NOW - a defect to file and fix later belongs in /craft:bugs, other deferred work in the notebook.' "$ADHOC_DESC"
assert_not_contains "the old notebook-only sentence is gone" 'Acts NOW - deferred work belongs in the notebook' "$ADHOC_DESC"

begin_test "notebook Not-to-be-Confused list names /craft:bugs, frontmatter untouched"
NOTEBOOK="$REPO/commands/craft-notebook.md"
CONFUSED="$(awk '/^## Not to be Confused With/{p=1; next} p && /^## /{exit} p{print}' "$NOTEBOOK")"
assert_contains_literal "bullet under Not to be Confused With" '- **`/craft:bugs`** - For a defect you are not fixing now' "$CONFUSED"
NB_LAST="$(awk '/^when_to_use: \|/{p=1; next} p && /^argument-hint:/{exit} p{last=$0} END{print last}' "$NOTEBOOK")"
assert_eq "notebook when_to_use last line unchanged" \
  "  Not for: product rulings (decisions) - those belong to /craft:decisions." "$NB_LAST"
assert_not_contains "frontmatter does not mention /craft:bugs" 'craft:bugs' "$(frontmatter_of "$NOTEBOOK")"

finish_tests "test-bugs-wiring"
  exit 1
fi

FRONTMATTER="$(frontmatter_of "$CMD")"

begin_test "frontmatter keys in order, five and no others"
TOP_KEYS="$(printf '%s\n' "$FRONTMATTER" | grep -oE '^[a-zA-Z_-]+:' | sed 's/:$//')"
assert_eq "keys are name, description, when_to_use, argument-hint, allowed-tools" \
  $'name\ndescription\nwhen_to_use\nargument-hint\nallowed-tools' "$TOP_KEYS"
assert_eq "name is bugs" "name: bugs" "$(printf '%s\n' "$FRONTMATTER" | grep '^name:')"

begin_test "description + when_to_use stay within the 1,536-character listing cap"
DESC_VALUE="$(printf '%s\n' "$FRONTMATTER" | grep '^description:' | sed 's/^description: *//')"
WTU="$(printf '%s\n' "$FRONTMATTER" | awk '/^when_to_use:/{p=1; next} p && /^[a-zA-Z_-]+:/{p=0} p{print}')"
TOTAL_LEN=$(( $(printf '%s' "$DESC_VALUE" | wc -c) + $(printf '%s' "$WTU" | wc -c) ))
if [ "$TOTAL_LEN" -le 1536 ] && [ "$TOTAL_LEN" -gt 0 ]; then
  echo "  PASS: combined length $TOTAL_LEN <= 1536"; PASS=$((PASS + 1))
else
  echo "  FAIL: combined length $TOTAL_LEN"; FAIL=$((FAIL + 1))
fi

begin_test "exactly one column-0 injected line, the locked command, no other bang-backtick"
INJECT='!`bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-list.sh --summary`'
assert_eq "one line equals the locked injected command" "1" \
  "$(grep -cxF -- "$INJECT" "$CMD")"
assert_eq "no other bang-backtick sequence anywhere in the file" "1" \
  "$(grep -cF -- '!`' "$CMD")"
H1_LINE="$(grep -n '^# ' "$CMD" | head -1 | cut -d: -f1)"
INJECT_LINE="$(grep -nxF -- "$INJECT" "$CMD" | head -1 | cut -d: -f1)"
FIRST_AFTER_H1="$(awk -v h="$H1_LINE" 'NR>h && NF{print NR; exit}' "$CMD")"
assert_eq "the injected line is the first body line after the H1" "$INJECT_LINE" "$FIRST_AFTER_H1"

begin_test "allowed-tools holds one rule and it prefixes the injected command"
ALLOWED_LINES="$(printf '%s\n' "$FRONTMATTER" | grep -c '^allowed-tools:')"
assert_eq "one allowed-tools key" "1" "$ALLOWED_LINES"
RULE="$(printf '%s\n' "$FRONTMATTER" | grep '^allowed-tools:' | sed 's/^allowed-tools: *//')"
assert_eq "the rule is the locked literal" \
  'Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-list.sh *)' "$RULE"
RULE_BODY="${RULE#Bash(}"; RULE_BODY="${RULE_BODY%)}"; PREFIX="${RULE_BODY% \*}"
INJECT_CMD="${INJECT#!\`}"; INJECT_CMD="${INJECT_CMD%\`}"
case "$INJECT_CMD" in
  "$PREFIX"*) echo "  PASS: rule text before ' *' is a literal prefix of the injected command"; PASS=$((PASS + 1)) ;;
  *) echo "  FAIL: '$PREFIX' is not a prefix of '$INJECT_CMD'"; FAIL=$((FAIL + 1)) ;;
esac

begin_test "when_to_use carries the tiers, both examples, the close trigger, and the Not-for line"
for phrase in '"file a bug"' '"log a bug"' '"bug ticket"' "don't let me forget" "/craft:bugs" \
  "mid-story or mid-chunk" "idle" "Example (person)" "Example (agent)" "fixed" "won't be fixed" "closed"; do
  assert_contains_literal "when_to_use mentions $phrase" "$phrase" "$WTU"
done
assert_contains_literal "offers are ignorable, never a question widget" "never AskUserQuestion" "$WTU"
LAST_WTU_LINE="$(printf '%s\n' "$WTU" | awk 'NF{l=$0} END{print l}')"
case "$LAST_WTU_LINE" in
  "  Not for:"*"/craft:adhoc"*"/craft:notebook"*) echo "  PASS: last line starts 'Not for:' and names adhoc and notebook"; PASS=$((PASS + 1)) ;;
  *) echo "  FAIL: last when_to_use line: $LAST_WTU_LINE"; FAIL=$((FAIL + 1)) ;;
esac

begin_test "exactly two question: lines across command + reference"
assert_eq "two AskUserQuestion blocks" "2" "$(cat "$CMD" "$REF" | grep -c 'question:')"
assert_contains_literal "filing question is What's broken?" "What's broken?" "$(cat "$REF")"
assert_contains_literal "close confirmation exists" "Close this bug?" "$(cat "$REF")"

begin_test "command body routes through the reference inline with the script call form"
BODY="$(cat "$CMD")"
assert_contains_literal "reads the reference by plugin-root path" '${CLAUDE_PLUGIN_ROOT}/commands/references/bugs-record.md' "$BODY"
assert_contains_literal "scripts run in the quoted call form" 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/' "$BODY"
assert_contains_literal "bare invocation shows the pile and stops" "Bare" "$BODY"

begin_test "reference carries the seven required fields, examples, hierarchy, enums, layers"
REFTEXT="$(cat "$REF")"
REQUIRED_SECTION="$(awk '/^## Required at filing$/{p=1; next} p && /^## /{exit} p{print}' "$REF")"
for field in "symptom line" "found_during" "Expected" "Actual" "Consequences" "Blocks my next step" "Reproduce"; do
  assert_contains_literal "required section lists $field" "$field" "$REQUIRED_SECTION"
done
for heading in "## What happened" "## Consequences" "## Blocks my next step" "## Reproduce" "## Evidence" "## Done when" "## Scope" "## Do not" "## References" "## Notes"; do
  assert_contains_literal "template carries $heading" "$heading" "$REFTEXT"
done
assert_contains_literal "template carries the Expected marker" "**Expected.**" "$REFTEXT"
assert_contains_literal "template carries the Actual marker" "**Actual.**" "$REFTEXT"
assert_contains_literal "example: test automation" "test automation against <sheet>" "$REFTEXT"
assert_contains_literal "example: craft review" "craft review of <story>" "$REFTEXT"
assert_contains_literal "example: conversation" "conversation" "$REFTEXT"
assert_contains_literal "status enum" "open | fixed | wont-fix" "$REFTEXT"
assert_contains_literal "verdict enum" "bug | unspecified | spec-gap | not-reproducible" "$REFTEXT"
assert_contains_literal "layer enum" "code | spec | judgment" "$REFTEXT"
assert_contains_literal "layer code is proven by a test" "a test" "$REFTEXT"
assert_contains_literal "layer judgment is proven by a human eye" "human eye" "$REFTEXT"
HIER="$(awk '/^## Requirement$/{p=1; next} p && /^## /{exit} p{print}' "$REF" | tr '[:upper:]' '[:lower:]')"
assert_contains_literal "hierarchy names approved decisions" "approved decisions" "$HIER"
assert_contains_literal "hierarchy names acceptance criteria" "acceptance criteria" "$HIER"
assert_contains_literal "hierarchy names locked.md" "locked.md" "$HIER"
assert_contains_literal "hierarchy names ground truth" "ground truth" "$HIER"
HIER="$(printf '%s\n' "$HIER" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "hierarchy does not rank any command file" "command" "$HIER"

begin_test "close flow in the reference"
REFLOWER="$(printf '%s\n' "$REFTEXT" | tr '[:upper:]' '[:lower:]')"
for phrase in 'bugs-list.sh" --status=open' 'bugs-close.sh' "one match" "several" "none" "--fixed-by" "spec-gap" "not-reproducible" "layer: judgment" "never reopens"; do
  assert_contains_literal "reference mentions $phrase" "$phrase" "$REFLOWER"
done
assert_contains_literal "filing never summons the user" "Nothing summons the user" "$REFTEXT"
assert_contains_literal "recurrence bumps hits instead of filing twice" "hit again" "$REFTEXT"

begin_test "close and hit-again act on the record's FILE path, never a bare slug"
assert_contains_literal "close passes the FILE path" 'bugs-close.sh" "<FILE>"' "$REFTEXT"
assert_not_contains "close never passes a bare slug" 'bugs-close.sh" <slug>' "$REFTEXT"
HIT_LINE="$(printf '%s\n' "$REFTEXT" | grep 'hit again' | head -1)"
assert_contains_literal "hit-again names where the path comes from" 'FILE=' "$HIT_LINE"

begin_test "hit-again line names bugs-hit.sh on the FILE path"
assert_contains_literal "hit-again runs bugs-hit.sh on the record path" 'bugs-hit.sh" "<FILE>"' "$HIT_LINE"
assert_not_contains "hit-again no longer hand-edits" "with Edit" "$HIT_LINE"
assert_contains_literal "command lists bugs-hit.sh among its scripts" '`bugs-hit.sh` records a repeat on an open bug' "$(cat "$CMD")"

begin_test "command wording agrees with the reference on the no-defect case"
assert_not_contains "naming line no longer promises no question" "No offer, no question" "$WTU"
assert_contains_literal "naming line asks only when nothing identifies a defect" \
  "ask only if nothing in the text or session identifies a defect" "$WTU"
assert_contains_literal "bare row stops only when the session holds no defect" \
  "no defect in the session" "$BODY"

begin_test "no dated slug, no cd, no Skill-tool invocation in shipped text"
ALL="$(cat "$CMD" "$REF")"
DATED="$(printf '%s\n' "$ALL" | grep -E '[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z]' || true)"
assert_eq "no dated slug pattern" "" "$DATED"
CDLINES="$(printf '%s\n' "$ALL" | grep -E '(^|[^a-z])cd ' || true)"
assert_eq "no cd" "" "$CDLINES"
SKILLCALL="$(printf '%s\n' "$ALL" | grep -E 'Skill\(|Skill tool' | grep -vi 'never' || true)"
assert_eq "Skill tool is mentioned only under a prohibition" "" "$SKILLCALL"

begin_test "no status: <value> outside open | fixed | wont-fix in the reference"
STRAY="$(grep -oE 'status: [a-z-]+' "$REF" | grep -vE '^status: (open|fixed|wont-fix)$' || true)"
assert_eq "only the three status words appear after status:" "" "$STRAY"

begin_test "only craft-bugs.md carries a frontmatter allowed-tools key"
CARRIERS=""
for f in "$REPO"/commands/craft*.md; do
  if frontmatter_of "$f" | grep -q '^allowed-tools:'; then CARRIERS="$CARRIERS $(basename "$f")"; fi
done
assert_eq "one command carries allowed-tools" " craft-bugs.md" "$CARRIERS"

begin_test "README, DESIGN, and the decision tree name /craft:bugs"
assert_file_contains "README command table" '| `/craft:bugs` |' "$REPO/README.md"
assert_file_contains "decision tree commands reference" '| `/craft:bugs` |' "$REPO/docs/decision-tree.md"
assert_file_contains "DESIGN commands tree" 'craft-bugs.md' "$REPO/DESIGN.md"
assert_file_contains "DESIGN says 35 commands" '35 commands' "$REPO/DESIGN.md"

begin_test "the doc drift check passes"
(cd "$REPO" && bash scripts/check-doc-drift.sh >/dev/null 2>&1) && RC=0 || RC=$?
assert_eq "check-doc-drift.sh exits 0" "0" "$RC"

begin_test "adhoc description points deferred defects at /craft:bugs"
ADHOC_DESC="$(grep -m1 '^description:' "$REPO/skills/adhoc/SKILL.md")"
assert_contains_literal "adhoc names /craft:bugs for a defect to fix later" \
  'Acts NOW - a defect to file and fix later belongs in /craft:bugs, other deferred work in the notebook.' "$ADHOC_DESC"
assert_not_contains "the old notebook-only sentence is gone" 'Acts NOW - deferred work belongs in the notebook' "$ADHOC_DESC"

begin_test "notebook Not-to-be-Confused list names /craft:bugs, frontmatter untouched"
NOTEBOOK="$REPO/commands/craft-notebook.md"
CONFUSED="$(awk '/^## Not to be Confused With/{p=1; next} p && /^## /{exit} p{print}' "$NOTEBOOK")"
assert_contains_literal "bullet under Not to be Confused With" '- **`/craft:bugs`** - For a defect you are not fixing now' "$CONFUSED"
NB_LAST="$(awk '/^when_to_use: \|/{p=1; next} p && /^argument-hint:/{exit} p{last=$0} END{print last}' "$NOTEBOOK")"
assert_eq "notebook when_to_use last line unchanged" \
  "  Not for: product rulings (decisions) - those belong to /craft:decisions." "$NB_LAST"
assert_not_contains "frontmatter does not mention /craft:bugs" 'craft:bugs' "$(frontmatter_of "$NOTEBOOK")"

finish_tests "test-bugs-wiring"
