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

begin_test "the timing lines carry no em dash"
TIMING_LINES="$(printf '%s\n' "$RUNNER_OUT" | grep 'TIMING:' || true)"
case "$TIMING_LINES" in
  *—*) assert_eq "no em dash on a TIMING line" "none" "found" ;;
  *) assert_eq "no em dash on a TIMING line" "none" "none" ;;
esac

finish_tests "test-run-all-timing.sh"
