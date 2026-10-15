#!/bin/bash
# test-annotate-review-clear.sh - Coverage for `annotate-run.sh review-clear`:
# the one place that decides whether an annotate run is open and, when none is,
# prints the canonical clear as a ready function.
# Usage: bash tests/test-annotate-review-clear.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

RUN="$SCRIPTS_DIR/annotate-run.sh"
CHANNEL="$SCRIPTS_DIR/annotate-channel.py"
REF_REL="commands/references/annotate-overlay.md"

TMP_DIRS=()
trap 'for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT

new_root() {
  NEW_ROOT="$(mktemp -d)"
  TMP_DIRS+=("$NEW_ROOT")
  mkdir -p "$NEW_ROOT/.craft/annotations"
}

# make_run <root> <id> [subject] - a run folder with run.json
make_run() {
  mkdir -p "$1/.craft/annotations/$2"
  python3 -c 'import json,sys; print(json.dumps({"start_seq":0,"subject":sys.argv[1]}))' "${3:-}" > "$1/.craft/annotations/$2/run.json"
}

# dead_pid - a pid that is certainly not running
dead_pid() {
  sleep 0 & local p=$!
  wait "$p" 2>/dev/null || true
  echo "$p"
}

rc_clear() { CRAFT_PROJECT_ROOT="$1" bash "$RUN" review-clear 2>/dev/null || true; }

FUNC_PREFIX="() => { "
FUNC_SUFFIX=" return 'CLEARED'; }"

begin_test "an open run with a live owner prints OPEN and no function"
new_root; make_run "$NEW_ROOT" r1 "the pricing page"
echo "$$" > "$NEW_ROOT/.craft/annotations/r1/owner.pid"
OUT="$(rc_clear "$NEW_ROOT")"
assert_eq "one OPEN line with the subject" "OPEN r1 the pricing page" "$OUT"

begin_test "an empty subject prints a dash"
new_root; make_run "$NEW_ROOT" r1 ""
echo "$$" > "$NEW_ROOT/.craft/annotations/r1/owner.pid"
assert_eq "dash subject" "OPEN r1 -" "$(rc_clear "$NEW_ROOT")"

begin_test "an unreadable run.json still counts as open, subject dash"
new_root; mkdir -p "$NEW_ROOT/.craft/annotations/r1"
echo "not json" > "$NEW_ROOT/.craft/annotations/r1/run.json"
assert_eq "open with dash" "OPEN r1 -" "$(rc_clear "$NEW_ROOT")"

begin_test "a run whose owner is dead does not block the clear"
new_root; make_run "$NEW_ROOT" r1 "old"
dead_pid > "$NEW_ROOT/.craft/annotations/r1/owner.pid"
OUT="$(rc_clear "$NEW_ROOT")"
assert_contains_literal "prints the function" "$FUNC_PREFIX" "$OUT"
assert_not_eq "no OPEN line" "OPEN" "${OUT%% *}"

begin_test "a run with no owner file counts as open"
new_root; make_run "$NEW_ROOT" r1 "mystery"
assert_eq "open" "OPEN r1 mystery" "$(rc_clear "$NEW_ROOT")"

begin_test "several open runs print one line each and no function"
new_root; make_run "$NEW_ROOT" a "one"; make_run "$NEW_ROOT" b "two"
OUT="$(rc_clear "$NEW_ROOT")"
assert_eq "two lines" "2" "$(echo "$OUT" | wc -l | tr -d ' ')"
assert_not_contains "no function line" "CLEARED" "$OUT"

begin_test "a filed record folder is never read as a run"
new_root; make_run "$NEW_ROOT" r1 "filed"; echo "# record" > "$NEW_ROOT/.craft/annotations/r1/record.md"
assert_contains_literal "prints the clear" "$FUNC_PREFIX" "$(rc_clear "$NEW_ROOT")"

begin_test "a folder without run.json is not an open run"
new_root; mkdir -p "$NEW_ROOT/.craft/annotations/armed-only"
assert_contains_literal "prints the clear" "$FUNC_PREFIX" "$(rc_clear "$NEW_ROOT")"

begin_test "no annotations folder prints the clear"
EMPTY="$(mktemp -d)"; TMP_DIRS+=("$EMPTY")
OUT="$(rc_clear "$EMPTY")"
assert_contains_literal "prints the function" "$FUNC_PREFIX" "$OUT"
assert_eq "exactly one line" "1" "$(echo "$OUT" | wc -l | tr -d ' ')"

begin_test "the printed clear carries the fence byte for byte and evaluates to a function"
FENCE="$(python3 "$CHANNEL" --print-clear)"
OUT="$(rc_clear "$EMPTY")"
assert_eq "function wraps the fence" "${FUNC_PREFIX}${FENCE}${FUNC_SUFFIX}" "$OUT"
assert_contains_literal "fence is the annotate clear" "__craftAnnotateInstalled" "$FENCE"
if command -v node >/dev/null 2>&1; then
  RESULT="$(node -e '
const f = eval("(" + process.argv[1] + ")");
globalThis.document = { getElementById: () => null, querySelectorAll: () => [], body: { classList: { remove() {} } } };
globalThis.window = {};
console.log(typeof f, f());
' "$OUT" 2>&1 || true)"
  assert_eq "evaluates to a function returning CLEARED" "function CLEARED" "$RESULT"
else
  echo "  SKIP: no node binary, function evaluation not checked"
fi

begin_test "review-clear writes nothing"
new_root; make_run "$NEW_ROOT" r1 "x"; make_run "$NEW_ROOT" r2 "y"
dead_pid > "$NEW_ROOT/.craft/annotations/r2/owner.pid"
BEFORE="$(cd "$NEW_ROOT" && find . | sort | xargs ls -ld 2>/dev/null; find "$NEW_ROOT" -type f -exec cksum {} + | sort)"
rc_clear "$NEW_ROOT" >/dev/null
AFTER="$(cd "$NEW_ROOT" && find . | sort | xargs ls -ld 2>/dev/null; find "$NEW_ROOT" -type f -exec cksum {} + | sort)"
assert_eq "tree identical" "$BEFORE" "$AFTER"

begin_test "exit 0 on both outputs"
set +e
rc_clear "$NEW_ROOT" >/dev/null; RC1=$?
rc_clear "$EMPTY" >/dev/null; RC2=$?
set -e
assert_exit_code "open output exits 0" "0" "$RC1"
assert_exit_code "function output exits 0" "0" "$RC2"

begin_test "a missing fence exits 1 with one stderr line"
COPY="$(mktemp -d)"; TMP_DIRS+=("$COPY")
mkdir -p "$COPY/hooks/scripts" "$COPY/commands/references"
cp "$SCRIPTS_DIR/annotate-run.sh" "$SCRIPTS_DIR/annotate-channel.py" "$SCRIPTS_DIR/annotate_write.py" "$COPY/hooks/scripts/"
grep -v '^```annotate-clear' "$PLUGIN_ROOT/$REF_REL" > "$COPY/$REF_REL"
set +e
ERR="$(CRAFT_PROJECT_ROOT="$EMPTY" bash "$COPY/hooks/scripts/annotate-run.sh" review-clear 2>&1 >/dev/null)"
RC=$?
OUTV="$(CRAFT_PROJECT_ROOT="$EMPTY" bash "$COPY/hooks/scripts/annotate-run.sh" review-clear 2>/dev/null)"
set -e
assert_exit_code "exit 1" "1" "$RC"
assert_eq "one stderr line" "1" "$(echo "$ERR" | wc -l | tr -d ' ')"
assert_eq "nothing on stdout" "" "$OUTV"

# bare_clear <dir> - review-clear as adhoc runs it on a project without init:
# no --root, no CRAFT_PROJECT_ROOT, shell in <dir>
bare_clear() { ( cd "$1" && env -u CRAFT_PROJECT_ROOT -u PROJECT_ROOT bash "$RUN" review-clear 2>/dev/null ) || true; }

begin_test "before init, an open run in the git project is seen from its top and from a subfolder"
G="$(mktemp -d)"; TMP_DIRS+=("$G")
git -C "$G" init -q
mkdir -p "$G/web"
make_run "$G" r1 "hero polish"
echo "$$" > "$G/.craft/annotations/r1/owner.pid"
OUT="$(bare_clear "$G")"
assert_eq "from the top: OPEN, no function" "OPEN r1 hero polish" "$OUT"
OUT="$(bare_clear "$G/web")"
assert_eq "from a subfolder: OPEN, no function" "OPEN r1 hero polish" "$OUT"
assert_eq "nothing created in the subfolder" "no" "$([ -e "$G/web/.craft" ] && echo yes || echo no)"

begin_test "before init outside git, an open run in the current folder is seen"
N="$(mktemp -d)"; TMP_DIRS+=("$N")
make_run "$N" r2 "nav spacing"
echo "$$" > "$N/.craft/annotations/r2/owner.pid"
assert_eq "OPEN, no function" "OPEN r2 nav spacing" "$(bare_clear "$N")"

begin_test "before init with no open run, the clear is still printed"
E="$(mktemp -d)"; TMP_DIRS+=("$E")
git -C "$E" init -q
OUT="$(bare_clear "$E")"
assert_contains_literal "prints the function" "$FUNC_PREFIX" "$OUT"
assert_eq "nothing created" "no" "$([ -e "$E/.craft" ] && echo yes || echo no)"

begin_test "the overlay reference carries the review section and no dial literal"
REF="$PLUGIN_ROOT/$REF_REL"
assert_file_contains "review section exists" "## Clearing leftovers before a review" "$REF"
assert_file_contains "names the verb" "annotate-run.sh review-clear" "$REF"
assert_file_not_contains "no dial literal" "craft-dial" "$REF"
SECTIONS="$(grep '^## ' "$REF" | grep -A1 '^## The canonical annotate clear$' | tail -1)"
assert_eq "section sits directly after the canonical clear" "## Clearing leftovers before a review" "$SECTIONS"

begin_test "the verb is named in the header usage, the die usage and DESIGN.md"
assert_file_contains "header usage" "#   annotate-run.sh review-clear" "$RUN"
assert_file_contains "die usage" "send|review-clear|sweep" "$RUN"
assert_file_contains "DESIGN verb list" "send / review-clear / sweep" "$PLUGIN_ROOT/DESIGN.md"

finish_tests "test-annotate-review-clear"
