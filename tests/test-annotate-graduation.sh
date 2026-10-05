#!/bin/bash
# test-annotate-graduation.sh - Structural contracts on the two ramps that carry
# an annotate record out of the browser: story-new's "From annotate" source and
# story-from-annotate.md, plus adhoc's annotate-sourced tweak paragraph. These
# are prompts, so the rules that keep them honest are frozen as facts about text.
# Usage: bash tests/test-annotate-graduation.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

REPO="$PLUGIN_ROOT"
STORY_NEW="$REPO/commands/craft-story-new.md"
REF="$REPO/commands/references/story-from-annotate.md"
TWEAK="$REPO/skills/adhoc/references/tweak.md"

# step25 - the Step 2.5 section of story-new, up to Step 3
step25() { awk '/^### Step 2.5:/ {on=1; next} /^### Step 3:/ {on=0} on {print}' "$STORY_NEW"; }

begin_test "story-new scans open annotate records and offers From annotate only when matched"
S=$(step25)
assert_contains_literal "scan greps open records" 'grep -l "^status: open" "$CRAFT_PROJECT_ROOT"/.craft/annotations/*/record.md 2>/dev/null | head -20' "$S"
assert_contains_literal "skip rule covers all three scans" 'If all come back empty' "$S"
assert_contains_literal "option labelled From annotate" 'label: "From annotate"' "$S"
assert_contains_literal "option is conditional on a match" '(only if annotate records matched)' "$S"
assert_contains_literal "question names the annotation count" 'annotations in .craft/annotations/' "$S"

begin_test "the Step 2.5 option set has at most four labels"
LABELS=$(printf '%s\n' "$S" | grep -c '^  - label: ')
assert_eq "planning, mockup, annotate, Freeform" "4" "$LABELS"

begin_test "the From annotate branch reads the reference inline and forbids the Skill tool"
BRANCH=$(printf '%s\n' "$S" | awk '/^\*\*If "From annotate":\*\*/ {on=1} /^\*\*If "Freeform":\*\*/ {on=0} on {print}')
assert_contains_literal "branch exists" 'If "From annotate"' "$BRANCH"
assert_contains_literal "chain-break rule" 'never via the Skill tool' "$BRANCH"
assert_contains_literal "reads the reference" 'Read "${CLAUDE_PLUGIN_ROOT}/commands/references/story-from-annotate.md"' "$BRANCH"
assert_contains_literal "parent flow is done" 'the parent flow is DONE' "$BRANCH"

begin_test "story-from-annotate delegates frontmatter to Step 10 and carries no fence"
assert_file_exists "reference exists" "$REF"
assert_file_contains "delegates to craft-story-new Step 10" 'see craft-story-new Step 10' "$REF"
assert_file_contains "a flow entered from the exit reads the Step 10 block first" 'commands/craft-story-new.md' "$REF"
assert_file_not_contains "no frontmatter fence of its own" '^---$' "$REF"
assert_file_contains "type ui" 'type: ui' "$REF"
assert_file_contains "alignment pending" 'alignment: pending' "$REF"
for n in 1 2 3 4; do
  assert_file_contains "phase $n present" "^## Phase $n:" "$REF"
done

begin_test "the reference writes the annotate: backlink and graduates through annotate-record.sh graduate"
assert_file_contains "annotate backlink" '^annotate: ' "$REF"
assert_file_contains "graduate verb" 'annotate-record.sh"\? graduate --record' "$REF"
assert_file_contains "names status: graduated" 'status: graduated' "$REF"
assert_file_contains "graduated_to is set" 'graduated_to' "$REF"

begin_test "the binding table source names the session.css block; selector and component are anchors"
assert_file_contains "normative sentence" 'session.css values port verbatim' "$REF"
assert_file_contains "selectors are anchors, never ported" 'never ported as structural selectors' "$REF"
assert_file_contains "four-column table" '| Part | Role/State | Token | Value/Source |' "$REF"
assert_file_contains "row example names the block" 'session.css `annotate-key ' "$REF"
assert_file_contains "anchors ride the cell" 'anchors: selector `' "$REF"
assert_file_contains "component anchor" 'component `' "$REF"
assert_file_contains "unblocked pins become scope lines" '## Scope' "$REF"
assert_file_contains "annotation files category" 'Annotation files:' "$REF"

begin_test "Pin source cites each binding row and the source column is unchanged"
assert_file_contains "pin source category" 'Pin source (resolved during the run):' "$REF"
assert_file_contains "read from the pin's resolved key" '`resolved`' "$REF"
assert_file_contains "one entry per annotate-key block" 'one entry per `annotate-key` block' "$REF"
assert_file_contains "matched by the pin's ts" 'str(ts)' "$REF"
assert_file_contains "rule anchored by line and selector" 'anchored by `line N`' "$REF"
assert_file_contains "class-search labelled" 'found by class name' "$REF"
assert_file_contains "source column still names the session.css rule" 'The Value/Source cell still names the session.css rule' "$REF"
assert_file_contains "the table example is unchanged" 'session.css `annotate-key 1728000000000` - `.toolbar .save { padding: 12px 20px }`; anchors:' "$REF"

begin_test "an unresolved row names its notes without a path"
assert_file_contains "one line naming the block and notes" 'one line naming the block and its `notes`, with no path' "$REF"

begin_test "the surface re-check names the resolved files"
assert_file_contains "re-check confirms resolved files" 'confirm each resolved file still exists and the rule text still appears in it' "$REF"

begin_test "the reference names no question widget"
assert_eq "every AskUserQuestion mention is the prohibition" "$(grep -c 'AskUserQuestion' "$REF")" "$(grep -c 'no AskUserQuestion' "$REF")"
assert_file_contains "says no widget" 'no AskUserQuestion' "$REF"

begin_test "tweak.md honors a pre-minted name for an annotate-sourced brief"
assert_file_contains "heading" 'Annotate-sourced tweaks' "$TWEAK"
assert_file_contains "brief trigger" 'direction pre-settled, annotate record at' "$TWEAK"
assert_file_contains "verbatim name" 'record name: tweak-<slug> (use verbatim)' "$TWEAK"
assert_file_contains "session.css is normative" 'session.css' "$TWEAK"

begin_test "hygiene: no em dashes, no decision slugs"
for f in "$REF" "$TWEAK"; do
  assert_file_not_contains "no em dash in $(basename "$f")" '—' "$f"
done
assert_eq "no em dash in the Step 2.5 block" "0" "$(step25 | grep -c '—' || true)"
assert_file_not_contains "no dated decision slug in the reference" '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[a-z]' "$REF"

begin_test "hygiene: vocabulary scan exits 0"
bash "$REPO/tests/check-vocabulary-prose-drift.sh" >/dev/null 2>&1
assert_eq "vocab scan exit" "0" "$?"

finish_tests "test-annotate-graduation"
