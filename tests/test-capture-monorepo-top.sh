#!/bin/bash
# test-capture-monorepo-top.sh - A capture from a monorepo's top level writes nothing.
#
# A bug or notebook entry filed at a monorepo's top level, with no project
# picked, would sit where no project's session lists it. Both capture scripts
# refuse there: non-zero exit, one line naming the projects found and pointing
# to /craft:project or CRAFT_PROJECT_ROOT, nothing on disk. Every other
# landing spot behaves as before: an explicit CRAFT_PROJECT_ROOT, a folder
# inside a project, a pinned project, a top level that is itself a project,
# and a repo with no workshop at all (the cold anchor).
# Usage: bash tests/test-capture-monorepo-top.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

BUGS="$SCRIPTS_DIR/bugs-capture.sh"
NOTE="$SCRIPTS_DIR/notebook-capture.sh"
LIST="$SCRIPTS_DIR/bugs-list.sh"
TODAY=$(date +%Y-%m-%d)
TMP_ROOTS=()

cleanup_roots() {
  local r
  for r in "${TMP_ROOTS[@]:-}"; do [ -n "$r" ] && rm -rf "$r"; done
  return 0
}
trap cleanup_roots EXIT

# new_repo - a fresh git repo (physical path, so it matches git's toplevel); sets M
new_repo() {
  M=$(cd "$(mktemp -d)" && pwd -P)
  TMP_ROOTS+=("$M")
  git -C "$M" init -q
}

# workshop <dir> - an initialized project workshop at <dir>
workshop() {
  mkdir -p "$1/.craft"
  printf 'ACTIVE_CYCLE=""\nCURRENT_STORY=""\n' > "$1/.craft/.global-state"
}

body_with() {
  printf '%s\n' "$1" '' '## What happened' '' \
    '**Expected.** x' '**Actual.** y' '' \
    '## Consequences' '' 'z' '' \
    '## Blocks my next step' '' 'no' '' \
    '## Reproduce' '' 'Starting state: s' '' '1. r'
}

# file_bug <dir> <symptom> - runs bugs-capture from <dir> with no project
# variables set; sets OUT, ERR, RC
file_bug() {
  local errf
  errf=$(mktemp)
  OUT=$(cd "$1" && body_with "$2" | env -u CRAFT_PROJECT_ROOT -u PROJECT_ROOT -u CRAFT_PROJECT_NAME -u CRAFT_MULTI_PROJECT bash "$BUGS" --found-during=probe --stdin 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
  rm -f "$errf"
}

# capture_todo <dir> <text> - runs notebook-capture the same way; sets OUT, ERR, RC
capture_todo() {
  local errf
  errf=$(mktemp)
  OUT=$(cd "$1" && env -u CRAFT_PROJECT_ROOT -u PROJECT_ROOT -u CRAFT_PROJECT_NAME -u CRAFT_MULTI_PROJECT bash "$NOTE" todo "$2" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
  rm -f "$errf"
}

records_under() {
  find "$1" -path '*/.craft/*' -name '*.md' -not -path '*/.craft/projects/*' | wc -l | tr -d ' '
}

set +e

begin_test "two projects below a bare top level: bug capture refuses and writes nothing"
new_repo; workshop "$M/app"; workshop "$M/api"
file_bug "$M" "Top level probe"
assert_eq "rc" "2" "$RC"
assert_eq "no stdout path" "" "$OUT"
assert_eq "one stderr line" "1" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
assert_contains_literal "says nothing was written" "nothing written: $M is a monorepo's top level" "$ERR"
assert_contains_literal "names the projects" "Projects found: api, app." "$ERR"
assert_contains_literal "points to /craft:project" "/craft:project" "$ERR"
assert_contains_literal "points to CRAFT_PROJECT_ROOT" "CRAFT_PROJECT_ROOT" "$ERR"
assert_eq "no top-level .craft" "no" "$([ -e "$M/.craft" ] && echo yes || echo no)"
assert_eq "no record anywhere" "0" "$(records_under "$M")"

begin_test "two projects below a bare top level: todo capture refuses and writes nothing"
capture_todo "$M" "top level probe todo"
assert_eq "rc" "1" "$RC"
assert_eq "no stdout path" "" "$OUT"
assert_contains_literal "says nothing was written" "nothing written: $M is a monorepo's top level, and a notebook entry" "$ERR"
assert_contains_literal "names the projects" "Projects found: api, app." "$ERR"
assert_eq "no top-level .craft" "no" "$([ -e "$M/.craft" ] && echo yes || echo no)"
assert_eq "no record anywhere" "0" "$(records_under "$M")"

begin_test "a folder in the top level that belongs to no project refuses too"
mkdir -p "$M/docs/notes"
file_bug "$M/docs/notes" "Docs folder probe"
assert_eq "rc" "2" "$RC"
assert_eq "no record anywhere" "0" "$(records_under "$M")"

begin_test "one project below a bare top level is still refused"
new_repo; workshop "$M/app"
file_bug "$M" "Single nested probe"
assert_eq "rc" "2" "$RC"
assert_contains_literal "names the one project" "Projects found: app." "$ERR"
assert_eq "no record anywhere" "0" "$(records_under "$M")"

begin_test "CRAFT_PROJECT_ROOT set at the top level files into that project, as before"
new_repo; workshop "$M/app"; workshop "$M/api"
OUT=$(cd "$M" && body_with "Pinned by env" | CRAFT_PROJECT_ROOT="$M/app" bash "$BUGS" --found-during=probe --stdin 2>/dev/null); RC=$?
assert_eq "rc" "0" "$RC"
assert_eq "lands in the app project" "$M/app/.craft/bugs/$TODAY-pinned-by-env.md" "$(printf '%s\n' "$OUT" | tail -1)"
assert_contains "the app session lists it" "^Bugs: 1 open" "$(CRAFT_PROJECT_ROOT="$M/app" bash "$LIST" --summary)"
OUT=$(cd "$M" && CRAFT_PROJECT_ROOT="$M/api" bash "$NOTE" todo "pinned todo" 2>/dev/null); RC=$?
assert_eq "todo rc" "0" "$RC"
assert_eq "todo lands in the api project" "$M/api/.craft/notebook/todos/$TODAY-pinned-todo.md" "$OUT"
assert_eq "no top-level .craft" "no" "$([ -e "$M/.craft" ] && echo yes || echo no)"

begin_test "from inside a project folder, the capture lands in that project, as before"
mkdir -p "$M/app/src"
file_bug "$M/app/src" "Inside app"
assert_eq "rc" "0" "$RC"
assert_eq "lands in the app project" "$M/app/.craft/bugs/$TODAY-inside-app.md" "$(printf '%s\n' "$OUT" | tail -1)"
capture_todo "$M/app/src" "inside app todo"
assert_eq "todo rc" "0" "$RC"
assert_eq "todo lands in the app project" "$M/app/.craft/notebook/todos/$TODAY-inside-app-todo.md" "$OUT"

begin_test "a registered hub with several projects and none picked refuses"
new_repo; workshop "$M"; workshop "$M/app"; workshop "$M/api"
mkdir -p "$M/.craft/projects"
printf -- '---\nname: app\npath: app\n---\n' > "$M/.craft/projects/app.md"
printf -- '---\nname: api\npath: api\n---\n' > "$M/.craft/projects/api.md"
file_bug "$M" "Hub probe"
assert_eq "rc" "2" "$RC"
assert_contains_literal "names the registered projects" "Projects found: api, app." "$ERR"
assert_eq "no hub bugs folder" "no" "$([ -e "$M/.craft/bugs" ] && echo yes || echo no)"
capture_todo "$M" "hub probe todo"
assert_eq "todo rc" "1" "$RC"
assert_eq "no hub notebook folder" "no" "$([ -e "$M/.craft/notebook" ] && echo yes || echo no)"

begin_test "a registered hub with a pinned project files into the pinned project, as before"
printf '%s\n%s\n' "$M/api" "api" > "$M/.craft/.pinned-project"
file_bug "$M" "Pinned hub"
assert_eq "rc" "0" "$RC"
assert_eq "lands in the pinned project" "$M/api/.craft/bugs/$TODAY-pinned-hub.md" "$(printf '%s\n' "$OUT" | tail -1)"

begin_test "a top level that is itself a project is never refused, even with workshops below it"
new_repo; workshop "$M"; workshop "$M/scripts/map"
file_bug "$M" "Top project"
assert_eq "rc" "0" "$RC"
assert_eq "no refusal" "" "$ERR"
assert_eq "lands in the top-level project" "$M/.craft/bugs/$TODAY-top-project.md" "$(printf '%s\n' "$OUT" | tail -1)"
capture_todo "$M" "top project todo"
assert_eq "todo rc" "0" "$RC"
assert_eq "todo lands in the top-level project" "$M/.craft/notebook/todos/$TODAY-top-project-todo.md" "$OUT"

begin_test "a top level that is a project by project.md alone is never refused"
new_repo; mkdir -p "$M/.craft"; echo "# project" > "$M/.craft/project.md"; workshop "$M/sub"
file_bug "$M" "Project md top"
assert_eq "rc" "0" "$RC"
assert_eq "lands in the top-level project" "$M/.craft/bugs/$TODAY-project-md-top.md" "$(printf '%s\n' "$OUT" | tail -1)"

begin_test "a repo with no workshop anywhere keeps the cold anchor at the git toplevel"
new_repo; mkdir -p "$M/a/b"
file_bug "$M/a/b" "Cold probe"
assert_eq "rc" "0" "$RC"
assert_eq "lands at the toplevel" "$M/.craft/bugs/$TODAY-cold-probe.md" "$(printf '%s\n' "$OUT" | tail -1)"
capture_todo "$M/a/b" "cold probe todo"
assert_eq "todo rc" "0" "$RC"
assert_eq "todo lands at the toplevel" "$M/.craft/notebook/todos/$TODAY-cold-probe-todo.md" "$OUT"

finish_tests test-capture-monorepo-top
