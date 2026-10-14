#!/bin/bash
# test-annotate-session-lookup.sh - An annotate command that names a session or
# a record finds it from any folder under the folder it was made in, on a
# project that never ran /craft:init, with no --root and no CRAFT_PROJECT_ROOT.
# A never-armed id says so, and nothing that names no session ever walks up.
# Usage: bash tests/test-annotate-session-lookup.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

RUN="$SCRIPTS_DIR/annotate-run.sh"
RESOLVE="$SCRIPTS_DIR/annotate-resolve.sh"
RECORD="$SCRIPTS_DIR/annotate-record.sh"

TMP_ROOTS=()

BOUNDARY_ROOT="$(mktemp -d)"
TMP_ROOTS+=("$BOUNDARY_ROOT")
export CRAFT_ANNOTATE_BOUNDARY_DIR="$BOUNDARY_ROOT/boundary"

cleanup() {
  local r p f
  for r in "${TMP_ROOTS[@]:-}"; do
    [ -n "$r" ] || continue
    for f in "$r"/.craft/annotations/*/listener.pid "$r"/*/.craft/annotations/*/listener.pid; do
      [ -f "$f" ] || continue
      p="$(cat "$f" 2>/dev/null || true)"
      case "$p" in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null || true ;; esac
    done
    rm -rf "$r"
  done
  return 0
}
trap cleanup EXIT

# new_dir - sets NEW_DIR to a fresh folder that is not a git repo
new_dir() {
  NEW_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  TMP_ROOTS+=("$NEW_DIR")
}

# new_repo - sets NEW_DIR to a fresh git repo
new_repo() {
  new_dir
  git -C "$NEW_DIR" init -q
  git -C "$NEW_DIR" config user.name test
  git -C "$NEW_DIR" config user.email test@example.com
}

# in_dir <dir> <script> <args...> - run a script from <dir> with no root hints
in_dir() {
  local dir="$1" script="$2"; shift 2
  ( cd "$dir" && env -u CRAFT_PROJECT_ROOT -u PROJECT_ROOT -u CRAFT_MULTI_PROJECT \
      bash "$script" "$@" 2>&1 ) || true
}

# arm_at <dir> <id> - arm a session with an explicit root (detached, today's launch)
arm_at() {
  ( cd "$1" && env -u CRAFT_PROJECT_ROOT -u PROJECT_ROOT -u CRAFT_MULTI_PROJECT \
      bash "$RUN" arm --root "$1" --session "$2" --owner-pid "$$" 2>&1 ) || true
}

begin_test "a session armed in a non-git folder is found from a sibling subfolder"
new_dir; N="$NEW_DIR"
mkdir -p "$N/a/b" "$N/a/c"
OUT="$(arm_at "$N/a" lk1)"
assert_contains "arm lands under the folder it was given" "^SESSION lk1 PORT [0-9]" "$OUT"
assert_eq "the session folder is under N/a" "yes" "$([ -d "$N/a/.craft/annotations/lk1" ] && echo yes || echo no)"
assert_contains "status finds it from a sibling subfolder" "^SESSION lk1 PORT [0-9]" "$(in_dir "$N/a/c" "$RUN" status --session lk1)"
assert_contains "status finds it from a nested subfolder" "^SESSION lk1 PORT [0-9]" "$(in_dir "$N/a/b" "$RUN" status --session lk1)"
assert_eq "nothing was created in the sibling" "no" "$([ -e "$N/a/c/.craft" ] && echo yes || echo no)"

begin_test "status, begin, ensure, clear and loader find the session from a subfolder of a git repo"
new_repo; G="$NEW_DIR"
mkdir -p "$G/src/deep"
arm_at "$G" lk2 >/dev/null
assert_contains "status" "^SESSION lk2 PORT [0-9]" "$(in_dir "$G/src/deep" "$RUN" status --session lk2)"
assert_contains "ensure" "^OK PORT [0-9]" "$(in_dir "$G/src/deep" "$RUN" ensure --session lk2)"
OUT="$(in_dir "$G/src/deep" "$RUN" begin --session lk2 --subject "lookup check")"
assert_eq "begin writes run.json under the arm root" "yes" "$([ -f "$G/.craft/annotations/lk2/run.json" ] && echo yes || echo no)"
assert_eq "begin names no missing root or session" "0" "$(echo "$OUT" | grep -c 'no craft project root\|no such session' || true)"
OUT="$(in_dir "$G/src" "$RUN" clear --session lk2)"
assert_eq "clear names no missing root or session" "0" "$(echo "$OUT" | grep -c 'no craft project root\|no such session' || true)"
OUT="$(in_dir "$G/src/deep" "$RUN" loader --session lk2 --page http://localhost:3000/)"
assert_eq "loader names no missing root or session" "0" "$(echo "$OUT" | grep -c 'no craft project root\|no such session' || true)"
assert_contains "loader prints a loader" "[A-Za-z]" "$OUT"
assert_eq "no .craft appears in the subfolders" "no" "$([ -e "$G/src/.craft" ] || [ -e "$G/src/deep/.craft" ] && echo yes || echo no)"

begin_test "resolve where and record file find the session with no root"
OUT="$(in_dir "$G/src" "$RESOLVE" where --session lk2 --ts 1)"
assert_eq "resolve where does not say the folder is missing" "0" "$(echo "$OUT" | grep -c 'no session folder\|no craft project root' || true)"
OUT="$(in_dir "$G/src/deep" "$RECORD" file --session lk2 --outcome nothing)"
assert_contains "record file prints a record under the arm root" "^$G/.craft/annotations/.*/record.md$" "$OUT"
assert_eq "no record is made under the subfolder" "no" "$([ -e "$G/src/deep/.craft" ] && echo yes || echo no)"
REC_NAME="$(basename "$(dirname "$(echo "$OUT" | tail -1)")")"

begin_test "graduate finds a record by name from a subfolder"
OUT="$(in_dir "$G/src" "$RECORD" graduate --record "$REC_NAME" --to some-tweak --outcome tweak)"
assert_contains "graduate prints the record path" "$REC_NAME/record.md" "$OUT"
assert_contains "the record now reads graduated" "^status: graduated" "$(cat "$G/.craft/annotations/$REC_NAME/record.md")"

begin_test "a never-armed id says no such session and creates nothing"
new_repo; B="$NEW_DIR"
mkdir -p "$B/sub"
assert_contains "run" "no such session: nope" "$(in_dir "$B/sub" "$RUN" status --session nope)"
assert_contains "run begin" "no such session: nope" "$(in_dir "$B/sub" "$RUN" begin --session nope)"
assert_eq "ensure prints GONE" "GONE" "$(in_dir "$B/sub" "$RUN" ensure --session nope)"
assert_contains "resolve" "no session folder for nope" "$(in_dir "$B/sub" "$RESOLVE" where --session nope --ts 1)"
assert_contains "record file" "no run to file for session nope (run.json is missing)" "$(in_dir "$B/sub" "$RECORD" file --session nope --outcome nothing)"
assert_contains "record graduate" "no such record: nope" "$(in_dir "$B/sub" "$RECORD" graduate --record nope --to x)"
assert_eq "no .craft appears" "no" "$([ -e "$B/.craft" ] || [ -e "$B/sub/.craft" ] && echo yes || echo no)"

begin_test "arm with no root on a bare folder still refuses"
new_dir; E="$NEW_DIR"
OUT="$(in_dir "$E" "$RUN" arm --session bare1 --owner-pid "$$")"
assert_contains "refuses" "no craft project root" "$OUT"
assert_eq "no .craft appears" "no" "$([ -e "$E/.craft" ] && echo yes || echo no)"

begin_test "a set-up project's lookup still wins"
new_dir; S="$NEW_DIR"
mkdir -p "$S/.craft" "$S/other"
echo "name: x" > "$S/.craft/project.md"
arm_at "$S" dup1 >/dev/null
mkdir -p "$S/other/.craft/annotations/dup1"
OUT="$( cd "$S/other" && env -u PROJECT_ROOT CRAFT_PROJECT_ROOT="$S" bash "$RUN" status --session dup1 2>&1 )" || true
assert_contains "resolves to the set-up project's listener" "^SESSION dup1 PORT [0-9]" "$OUT"

begin_test "sweep, status --all and review-clear never walk"
new_dir; W="$NEW_DIR"
mkdir -p "$W/a/b"
arm_at "$W/a" wk1 >/dev/null
assert_contains "status --all has no root" "no craft project root" "$(in_dir "$W/a/b" "$RUN" status --all)"
OUT="$(in_dir "$W/a/b" "$RUN" sweep)"
assert_eq "sweep prints nothing" "" "$OUT"
assert_eq "sweep left the session folder alone" "yes" "$([ -d "$W/a/.craft/annotations/wk1" ] && echo yes || echo no)"
in_dir "$W/a/b" "$RUN" review-clear >/dev/null
assert_eq "review-clear created nothing" "no" "$([ -e "$W/a/b/.craft" ] && echo yes || echo no)"

finish_tests "test-annotate-session-lookup"
