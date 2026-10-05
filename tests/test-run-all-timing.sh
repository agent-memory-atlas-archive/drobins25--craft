#!/bin/bash
# test-run-all-timing.sh - The full-suite runner's timing gate binds: a run
# over its time limit fails the whole run, a run under it passes, and a
# failing test file still fails a run that is on time. Each case runs a copy
# of run-all.sh over a temp tree holding a fake test file, so the real suite
# is never re-entered.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

echo "=== test-run-all-timing.sh ==="
echo ""

TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT

# make_tree NAME FAKE_BODY - a tree with a copy of the runner and one fake
# test file; prints the runner's path
make_tree() {
  local dir="$TREE/$1"
  mkdir -p "$dir/tests" "$dir/hooks/scripts"
  cp "$SCRIPT_DIR/run-all.sh" "$dir/tests/run-all.sh"
  printf '#!/bin/bash\n%s\n' "$2" > "$dir/tests/test-fake.sh"
  echo "$dir/tests/run-all.sh"
}

# run_runner RUNNER LIMIT - sets RUNNER_OUT and RUNNER_RC; an empty LIMIT
# leaves the override unset in effect so the default applies
run_runner() {
  set +e
  if [ -n "$2" ]; then
    RUNNER_OUT="$(CRAFT_SUITE_TIME_LIMIT="$2" bash "$1" 2>&1)"
  else
    RUNNER_OUT="$(env -u CRAFT_SUITE_TIME_LIMIT bash "$1" 2>&1)"
  fi
  RUNNER_RC=$?
  set -e
}

begin_test "a run over its time limit fails the whole run"
SLOW="$(make_tree slow 'sleep 2; echo "3 passed, 0 failed"')"
run_runner "$SLOW" 1
assert_eq "exit code is 1" "1" "$RUNNER_RC"
assert_contains "TIMING line says FAIL" "TIMING: FAIL - " "$RUNNER_OUT"
assert_contains "TIMING line names the overridden limit" "exceeds 1s limit" "$RUNNER_OUT"
assert_contains "RESULT line says FAIL" "RESULT: FAIL (" "$RUNNER_OUT"
assert_contains "RESULT line names the time cause" "over the 1s limit" "$RUNNER_OUT"

begin_test "a run under its limit passes, and the default limit is 240s"
FAST="$(make_tree fast 'echo "3 passed, 0 failed"')"
run_runner "$FAST" ""
assert_eq "exit code is 0" "0" "$RUNNER_RC"
assert_contains "TIMING line is OK against 240s" "(limit: 240s)" "$RUNNER_OUT"
assert_contains "RESULT line says all passed" "RESULT: ALL TESTS PASSED" "$RUNNER_OUT"

begin_test "a failing test file still fails a run that is on time"
BAD="$(make_tree bad 'echo "1 passed, 2 failed"; exit 1')"
run_runner "$BAD" 240
assert_eq "exit code is 1" "1" "$RUNNER_RC"
assert_contains "TIMING line is OK" "TIMING: OK" "$RUNNER_OUT"
assert_contains "RESULT line counts the failures" "RESULT: FAIL (2 failures)" "$RUNNER_OUT"

begin_test "a failing file in a run that is also over time names both causes"
BOTH="$(make_tree both 'sleep 2; echo "1 passed, 2 failed"; exit 1')"
run_runner "$BOTH" 1
assert_eq "exit code is 1" "1" "$RUNNER_RC"
assert_contains "RESULT line names the failures" "2 failures" "$RUNNER_OUT"
assert_contains "RESULT line names the time" "over the 1s limit" "$RUNNER_OUT"

begin_test "files run concurrently, CRAFT_TEST_JOBS sets the width, and 8 is the default"
# four files that each sleep 2s: concurrent they finish inside a 6s limit,
# one at a time they need 8s
make_multi() {
  local dir="$TREE/$1" n
  mkdir -p "$dir/tests" "$dir/hooks/scripts"
  cp "$SCRIPT_DIR/run-all.sh" "$dir/tests/run-all.sh"
  for n in a b c d; do
    printf '#!/bin/bash\nsleep 2\necho "1 passed, 0 failed"\n' > "$dir/tests/test-$n.sh"
  done
  echo "$dir/tests/run-all.sh"
}
PAR="$(make_multi par)"
set +e
PAR_OUT="$(CRAFT_TEST_JOBS=4 CRAFT_SUITE_TIME_LIMIT=6 bash "$PAR" 2>&1)"; PAR_RC=$?
SER_OUT="$(CRAFT_TEST_JOBS=1 CRAFT_SUITE_TIME_LIMIT=6 bash "$PAR" 2>&1)"; SER_RC=$?
DEF_OUT="$(env -u CRAFT_TEST_JOBS CRAFT_SUITE_TIME_LIMIT=6 bash "$PAR" 2>&1)"; DEF_RC=$?
set -e
assert_eq "four 2s files at width 4 pass a 6s limit" "0" "$PAR_RC"
assert_contains "the run names its width" "4 at a time" "$PAR_OUT"
assert_eq "the same files one at a time blow the 6s limit" "1" "$SER_RC"
assert_contains "width 1 runs one at a time" "1 at a time" "$SER_OUT"
assert_eq "the default width also runs them concurrently" "0" "$DEF_RC"
assert_contains "the default width is 8" "8 at a time" "$DEF_OUT"
assert_contains "every file is counted" "Total: 4 passed, 0 failed across 4 files" "$PAR_OUT"

begin_test "output stays in file order and each file's block stays whole"
ORD="$TREE/ord"
mkdir -p "$ORD/tests" "$ORD/hooks/scripts"
cp "$SCRIPT_DIR/run-all.sh" "$ORD/tests/run-all.sh"
printf '#!/bin/bash\nsleep 2\necho "alpha line"\necho "1 passed, 0 failed"\n' > "$ORD/tests/test-a.sh"
printf '#!/bin/bash\necho "beta line"\necho "1 passed, 0 failed"\n' > "$ORD/tests/test-b.sh"
set +e
ORD_OUT="$(CRAFT_TEST_JOBS=2 bash "$ORD/tests/run-all.sh" 2>&1)"
set -e
L_A="$(printf '%s\n' "$ORD_OUT" | grep -n -- '--- test-a.sh ---' | cut -d: -f1)"
L_ALPHA="$(printf '%s\n' "$ORD_OUT" | grep -n 'alpha line' | cut -d: -f1)"
L_B="$(printf '%s\n' "$ORD_OUT" | grep -n -- '--- test-b.sh ---' | cut -d: -f1)"
L_BETA="$(printf '%s\n' "$ORD_OUT" | grep -n 'beta line' | cut -d: -f1)"
assert_eq "test-a's block prints before test-b's although b finished first" "yes" "$([ -n "$L_A" ] && [ -n "$L_B" ] && [ "$L_A" -lt "$L_B" ] && echo yes || echo no)"
assert_eq "test-a's output sits inside its own block" "yes" "$([ -n "$L_ALPHA" ] && [ "$L_A" -lt "$L_ALPHA" ] && [ "$L_ALPHA" -lt "$L_B" ] && echo yes || echo no)"
assert_eq "test-b's output follows its header" "yes" "$([ -n "$L_BETA" ] && [ "$L_B" -lt "$L_BETA" ] && echo yes || echo no)"

begin_test "a test file never reads the runner's stdin"
STD="$TREE/std"
mkdir -p "$STD/tests" "$STD/hooks/scripts"
cp "$SCRIPT_DIR/run-all.sh" "$STD/tests/run-all.sh"
printf '#!/bin/bash\nif read -r -t 1 line; then echo "got stdin: $line"; fi\necho "1 passed, 0 failed"\n' > "$STD/tests/test-s.sh"
set +e
STD_OUT="$(echo "leaked" | bash "$STD/tests/run-all.sh" 2>&1)"
set -e
assert_not_contains "no runner stdin reaches a test" "got stdin" "$STD_OUT"

begin_test "both result formats count toward the totals"
CAP="$(make_tree cap 'printf "%s\\n" "-- Summary --" "Total:  5" "Passed: 5" "Failed: 0"')"
run_runner "$CAP" 240
assert_eq "a Passed: N file passes" "0" "$RUNNER_RC"
assert_contains "Passed: N counts" "Total: 5 passed, 0 failed across 1 files" "$RUNNER_OUT"
CAPF="$(make_tree capf 'printf "%s\\n" "Passed: 1" "Failed: 2"; exit 1')"
run_runner "$CAPF" 240
assert_contains "Failed: N counts" "RESULT: FAIL (2 failures)" "$RUNNER_OUT"

begin_test "the timing lines carry no em dash"
TIMING_LINES="$(printf '%s\n' "$RUNNER_OUT" | grep 'TIMING:' || true)"
case "$TIMING_LINES" in
  *—*) assert_eq "no em dash on a TIMING line" "none" "found" ;;
  *) assert_eq "no em dash on a TIMING line" "none" "none" ;;
esac

finish_tests "test-run-all-timing.sh"
