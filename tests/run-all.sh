#!/bin/bash
# run-all.sh — Run all Craft plugin tests and report results
#
# Usage: bash tests/run-all.sh
#
# Discovers all tests/test-*.sh files, runs each, aggregates results.
# Prints per-file summary table + regression report.
# Exit code: 0 if all tests pass within the time limit, 1 if any fail or the
# run exceeds CRAFT_SUITE_TIME_LIMIT seconds (default 240).

set -e

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_FILES=0
FAILED_FILES=""
START_TIME=$(date +%s)

# Arrays for summary table (bash 3.x compatible — use strings with delimiters)
TABLE_DATA=""

echo "========================================"
echo "  Craft Plugin Test Suite"
echo "========================================"
echo ""

# Find all test files (tests/ plus the hook-script tests beside the code they cover)
FILES=()
for test_file in "$TESTS_DIR"/test-*.sh "$TESTS_DIR/../hooks/scripts/__tests__"/*.test.sh; do
  [ -f "$test_file" ] && FILES+=("$test_file")
done

# Run them CRAFT_TEST_JOBS at a time (default 8; 1 runs one at a time). Each file
# writes its output, exit code and time to its own slot, and nothing reads the
# runner's stdin; the blocks then print in file order, so the report reads the
# same however the runs interleaved.
JOBS="${CRAFT_TEST_JOBS:-8}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=8 ;; esac
RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT
echo "  Running ${#FILES[@]} files, $JOBS at a time"
echo ""

i=0
for test_file in "${FILES[@]}"; do
  printf '%s\0%s\0' "$i" "$test_file"
  i=$((i + 1))
done | RUN_DIR="$RUN_DIR" xargs -0 -n 2 -P "$JOBS" bash -c '
  s=$(date +%s)
  bash "$2" > "$RUN_DIR/$1.out" 2>&1 < /dev/null
  echo $? > "$RUN_DIR/$1.rc"
  echo $(( $(date +%s) - s )) > "$RUN_DIR/$1.time"
' _

i=0
for test_file in "${FILES[@]}"; do
  test_name=$(basename "$test_file")
  TOTAL_FILES=$((TOTAL_FILES + 1))
  echo "--- $test_name ---"

  output="$(cat "$RUN_DIR/$i.out" 2>/dev/null || true)"
  exit_code="$(cat "$RUN_DIR/$i.rc" 2>/dev/null || echo 1)"
  file_time="$(cat "$RUN_DIR/$i.time" 2>/dev/null || echo 0)"
  i=$((i + 1))

  echo "$output"

  # Extract PASS/FAIL counts from the file's last result line, in either format
  # the suite uses: "N passed, M failed" or a "Passed: N" / "Failed: M" summary
  file_pass=$(echo "$output" | grep -oE '[0-9]+ passed|Passed: *[0-9]+' | tail -1 | grep -oE '[0-9]+' || true)
  file_fail=$(echo "$output" | grep -oE '[0-9]+ failed|Failed: *[0-9]+' | tail -1 | grep -oE '[0-9]+' || true)
  file_pass="${file_pass:-0}"
  file_fail="${file_fail:-0}"

  TOTAL_PASS=$((TOTAL_PASS + file_pass))
  TOTAL_FAIL=$((TOTAL_FAIL + file_fail))

  # Store for summary table
  TABLE_DATA="${TABLE_DATA}${test_name}|${file_pass}|${file_fail}|${file_time}\n"

  if [ "$exit_code" -ne 0 ]; then
    FAILED_FILES="$FAILED_FILES  - $test_name ($file_fail failures)\n"
  fi

  echo "(${file_time}s)"
  echo ""
done

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# Summary Table
echo "========================================"
echo "  SUMMARY TABLE"
echo "========================================"
echo ""
printf "  %-40s %6s %6s %5s\n" "File" "Pass" "Fail" "Time"
printf "  %-40s %6s %6s %5s\n" "$(printf '%0.s-' {1..40})" "------" "------" "-----"

echo -e "$TABLE_DATA" | while IFS='|' read -r name pass fail time; do
  [ -z "$name" ] && continue
  if [ "$fail" -gt 0 ] 2>/dev/null; then
    printf "  %-40s %6s %6s %4ss\n" "$name" "$pass" "**$fail**" "$time"
  else
    printf "  %-40s %6s %6s %4ss\n" "$name" "$pass" "$fail" "$time"
  fi
done

echo ""
echo "  Total: $TOTAL_PASS passed, $TOTAL_FAIL failed across $TOTAL_FILES files (${TOTAL_TIME}s)"
echo ""

# Regression Report
echo "========================================"
echo "  REGRESSION REPORT"
echo "========================================"
echo ""
echo "  Story 8 (template + frontmatter pipeline): ALL FIXED"
echo "    - Templates quoted, create-story escapes special chars, backlog has current_chunk"
echo "    - move-story.sh awk insertion fixed with fallback + post-insertion validation"
echo ""
echo "  Story 9 (scripts using relative .craft paths): ALL FIXED"
echo "    - export-progress.sh, handle-tool-failure.py, create-story.sh, statusline.sh"
echo "    - All use CRAFT_PROJECT_ROOT with find-workshop.sh fallback"
echo ""
echo "  Other known bugs (not yet in a story):"
echo "    - create-story.sh: {{PRIORITY}} and {{STORY_NUMBER}} placeholders never substituted"
echo "    - move-story.sh: story_name sed corrupts hyphenated names (login-form -> form)"
echo "    - move-story.sh: sets status to planning unconditionally (regresses ready stories)"
echo "    - complete-chunk.sh: env contamination (CRAFT_PROJECT_ROOT inheritance)"
echo "    - update-cycle-state.sh: name-based fallback with wildcard matches real cycles"
echo "    - handle-tool-failure.py: relative .craft path (FIXED in story 9)"
echo "    - start-cycle.sh: empty PROJECT_ROOT in name-based lookup"
echo "    - statusline.sh: malformed UTF-8 in progress bar (e2e2 byte sequence)"
echo ""

# Timing check. Budget is process-spawn headroom, not a hang detector: the suite is
# well over a hundred separate bash files (git, python3, mktemp per file), run
# CRAFT_TEST_JOBS at a time, so wall-clock is set by the slowest files rather than
# the file count. 240s is generous headroom over a parallel run on a busy machine.
# The check is local only: CI runs the group runner, which has no timing check.
# CRAFT_SUITE_TIME_LIMIT overrides the limit (the runner's own test sets it).
LIMIT="${CRAFT_SUITE_TIME_LIMIT:-240}"
TIME_EXCEEDED=""
if [ "$TOTAL_TIME" -gt "$LIMIT" ]; then
  TIME_EXCEEDED="1"
  echo "  TIMING: FAIL - ${TOTAL_TIME}s exceeds ${LIMIT}s limit"
elif [ "$TOTAL_TIME" -gt $((LIMIT * 3 / 4)) ]; then
  echo "  TIMING: WARN - ${TOTAL_TIME}s approaching ${LIMIT}s limit"
else
  echo "  TIMING: OK - ${TOTAL_TIME}s (limit: ${LIMIT}s)"
fi
echo ""

# Final verdict: a failing file or a blown time limit fails the run
if [ -n "$FAILED_FILES" ] || [ -n "$TIME_EXCEEDED" ]; then
  CAUSES=""
  [ -n "$FAILED_FILES" ] && CAUSES="$TOTAL_FAIL failures"
  if [ -n "$TIME_EXCEEDED" ]; then
    [ -n "$CAUSES" ] && CAUSES="$CAUSES, "
    CAUSES="${CAUSES}${TOTAL_TIME}s, over the ${LIMIT}s limit"
  fi
  if [ -n "$FAILED_FILES" ]; then
    echo "Failed files:"
    echo -e "$FAILED_FILES"
  fi
  echo "========================================"
  echo "  RESULT: FAIL ($CAUSES)"
  echo "========================================"
  exit 1
else
  echo "========================================"
  echo "  RESULT: ALL TESTS PASSED"
  echo "========================================"
  exit 0
fi
