#!/bin/bash
# test-before-init-root-callers.sh - The scripts that file or list records before
# /craft:init take their folder from the shared lookup in find-workshop.sh.
#
# Two things are pinned here:
#   1. A folder handed in through CRAFT_PROJECT_ROOT is used exactly as given,
#      even with no .craft/ in it yet - never replaced by the enclosing git repo.
#      The lookup must only run when nothing was handed in, because sourcing
#      find-workshop.sh unsets a handed-in folder that has no .craft/.
#   2. No script carries its own copy of the folder rule any more.
# Usage: bash tests/test-before-init-root-callers.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

TODAY=$(date +%Y-%m-%d)
TMP_ROOTS=()

cleanup_roots() {
  local r
  for r in "${TMP_ROOTS[@]:-}"; do [ -n "$r" ] && rm -rf "$r"; done
  return 0
}
trap cleanup_roots EXIT

# new_dir - a fresh physical-path folder, tracked for cleanup; sets D
new_dir() {
  D=$(cd "$(mktemp -d)" && pwd -P)
  TMP_ROOTS+=("$D")
}

# run_in <cwd> <handed-in-root> <script> [args...] - runs a script from <cwd>
# with only CRAFT_PROJECT_ROOT set; sets OUT, ERR, RC
run_in() {
  local cwd="$1" handed="$2" script="$3" errf
  shift 3
  errf=$(mktemp)
  OUT=$(cd "$cwd" && env -u PROJECT_ROOT -u CRAFT_PROJECT_NAME -u CRAFT_MULTI_PROJECT \
    CRAFT_PROJECT_ROOT="$handed" bash "$SCRIPTS_DIR/$script" "$@" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
  rm -f "$errf"
}

# tree_of <dir> - every file under <dir> (git internals aside) with its checksum
tree_of() {
  (cd "$1" && find . -type f -not -path './.git/*' -exec shasum {} + | sort)
}

bug_body() {
  printf '%s\n' "$1" '' '## What happened' '' \
    '**Expected.** x' '**Actual.** y' '' \
    '## Consequences' '' 'z' '' \
    '## Blocks my next step' '' 'no' '' \
    '## Reproduce' '' 'Starting state: s' '' '1. r'
}

CAPTURE_SCRIPTS="bugs-capture.sh notebook-capture.sh decisions-capture.sh dials-capture.sh"
ALL_SCRIPTS="bugs-capture.sh bugs-hit.sh bugs-list.sh bugs-close.sh decisions-capture.sh decisions-list.sh decisions-transition.sh dials-capture.sh dials-list.sh notebook-capture.sh notebook-list.sh"

set +e

# --- Handed-in folder wins -------------------------------------------------

# R: a git repo holding records of its own and no .global-state / project.md.
# X: a bare folder, handed in. The cwd is R/sub, so a lookup that ran on the
# handed-in path would resolve R through git and show R's records.
new_dir; R="$D"
git -C "$R" init -q
mkdir -p "$R/sub"
new_dir; X="$D"

bug_body "Repo seeded bug" | CRAFT_PROJECT_ROOT="$R" bash "$SCRIPTS_DIR/bugs-capture.sh" --found-during=seed --stdin >/dev/null 2>&1
CRAFT_PROJECT_ROOT="$R" bash "$SCRIPTS_DIR/notebook-capture.sh" todo "repo seeded todo" >/dev/null 2>&1
CRAFT_PROJECT_ROOT="$R" bash "$SCRIPTS_DIR/decisions-capture.sh" "Repo seeded decision" --tag=t \
  --context=c --options=o --decision=d --consequences=q >/dev/null 2>&1
CRAFT_PROJECT_ROOT="$R" bash "$SCRIPTS_DIR/dials-capture.sh" "repo seeded dial" --surface=s --kind=copy \
  --scope=magnitude --outcome=nothing >/dev/null 2>&1

R_BUG="$R/.craft/bugs/$TODAY-repo-seeded-bug.md"
R_BASELINE=$(tree_of "$R")

begin_test "fixture: the repo holds its own records and is not a set-up project"
# Every seed must land: the "never the repo's records" checks below are only
# meaningful if the repo really holds a record of each kind.
assert_file_exists "repo bug record" "$R_BUG"
assert_file_exists "repo todo record" "$R/.craft/notebook/todos/$TODAY-repo-seeded-todo.md"
assert_file_exists "repo decision record" "$R/.craft/decisions/$TODAY-repo-seeded-decision.md"
assert_file_exists "repo dial record" "$R/.craft/dials/$TODAY-repo-seeded-dial.md"
assert_eq "no .global-state" "no" "$([ -e "$R/.craft/.global-state" ] && echo yes || echo no)"
assert_eq "no project.md" "no" "$([ -e "$R/.craft/project.md" ] && echo yes || echo no)"

begin_test "captures: a handed-in folder with no .craft receives the record"
run_in "$R/sub" "$X" bugs-capture.sh --found-during=probe --stdin < <(bug_body "Handed in bug")
assert_eq "bugs-capture rc" "0" "$RC"
assert_eq "bugs-capture path" "$X/.craft/bugs/$TODAY-handed-in-bug.md" "$(printf '%s\n' "$OUT" | tail -1)"
run_in "$R/sub" "$X" notebook-capture.sh todo "handed in todo"
assert_eq "notebook-capture rc" "0" "$RC"
assert_eq "notebook-capture path" "$X/.craft/notebook/todos/$TODAY-handed-in-todo.md" "$OUT"
assert_eq "notebook-capture says nothing" "" "$ERR"
run_in "$R/sub" "$X" decisions-capture.sh "Handed in decision" --tag=t --context=c --options=o --decision=d --consequences=q
assert_eq "decisions-capture rc" "0" "$RC"
assert_contains_literal "decisions-capture path" "$X/.craft/decisions/" "$OUT"
run_in "$R/sub" "$X" dials-capture.sh "handed in dial" --surface=s --kind=copy --scope=magnitude --outcome=nothing
assert_eq "dials-capture rc" "0" "$RC"
assert_contains_literal "dials-capture path" "$X/.craft/dials/" "$OUT"
assert_eq "no capture announced a non-git landing" "" "$ERR"

begin_test "lists: a handed-in folder is read, never the enclosing repo"
run_in "$R/sub" "$X" bugs-list.sh
assert_not_contains "bugs-list" "Repo seeded bug" "$OUT"
assert_contains_literal "bugs-list sees the handed-in record" "Handed in bug" "$OUT"
assert_eq "bugs-list stderr silent" "" "$ERR"
run_in "$R/sub" "$X" decisions-list.sh
assert_not_contains "decisions-list" "Repo seeded decision" "$OUT"
assert_contains_literal "decisions-list sees the handed-in record" "Handed in decision" "$OUT"
run_in "$R/sub" "$X" dials-list.sh
assert_not_contains "dials-list" "repo seeded dial" "$OUT"
assert_contains_literal "dials-list sees the handed-in record" "handed-in-dial" "$OUT"
run_in "$R/sub" "$X" notebook-list.sh
assert_not_contains "notebook-list" "repo seeded todo" "$OUT"
assert_contains_literal "notebook-list sees the handed-in record" "handed in todo" "$OUT"

begin_test "hit, close and transition look in the handed-in folder only"
new_dir; EMPTY="$D"
run_in "$R/sub" "$EMPTY" bugs-hit.sh "$R_BUG" --where=probe
assert_eq "bugs-hit refuses" "2" "$RC"
run_in "$R/sub" "$EMPTY" bugs-close.sh "$TODAY-repo-seeded-bug" --status=fixed
assert_eq "bugs-close refuses" "2" "$RC"
run_in "$R/sub" "$EMPTY" decisions-transition.sh "$TODAY-repo-seeded-decision" accept --quote="yes"
assert_not_eq "decisions-transition refuses" "0" "$RC"

begin_test "nothing leaked into the repo"
assert_eq "repo files byte-identical" "$R_BASELINE" "$(tree_of "$R")"
assert_eq "empty handed-in folder stays empty" "" "$(ls -A "$EMPTY")"

# --- No copy left ------------------------------------------------------------

begin_test "no script carries its own copy of the rule"
for s in $ALL_SCRIPTS; do
  if grep -q 'craft_before_init_root' "$SCRIPTS_DIR/$s"; then
    assert_eq "$s calls the lookup" "yes" "yes"
  else
    assert_eq "$s calls the lookup" "yes" "no"
  fi
  if grep -q 'show-toplevel' "$SCRIPTS_DIR/$s"; then
    assert_eq "$s has no git-toplevel fallback" "none" "present"
  else
    assert_eq "$s has no git-toplevel fallback" "none" "none"
  fi
done

# --- Dial's cold exits ---------------------------------------------------------

begin_test "dial's before-init exits use the lookup"
DIAL_DOC="$PLUGIN_ROOT/commands/references/dial-inline.md"
PINNED_CALL='bash -c '"'"'source "$1" >/dev/null 2>&1; craft_before_init_root'"'"' _ "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/find-workshop.sh"'
assert_contains_literal "dial doc has the pinned call" "$PINNED_CALL" "$(cat "$DIAL_DOC")"
assert_contains_literal "dial doc prefixes the cold root" 'CRAFT_PROJECT_ROOT="<cold root>"' "$(cat "$DIAL_DOC")"
assert_not_contains "dial doc has no DIAL_ROOT" "DIAL_ROOT" "$(cat "$DIAL_DOC")"

# --- Mockup, status, become and research ------------------------------------

begin_test "mockup, status, become and research run the lookup"
for f in commands/references/mockup-inline.md commands/craft-status.md commands/craft-become.md commands/craft-research.md; do
  assert_contains_literal "$f has the pinned call" "$PINNED_CALL" "$(cat "$PLUGIN_ROOT/$f")"
  assert_not_contains "$f has no git-toplevel fallback" "show-toplevel" "$(cat "$PLUGIN_ROOT/$f")"
done
assert_not_contains "mockup doc has no MOCKUP_ROOT" "MOCKUP_ROOT" "$(cat "$PLUGIN_ROOT/commands/references/mockup-inline.md")"

finish_tests
