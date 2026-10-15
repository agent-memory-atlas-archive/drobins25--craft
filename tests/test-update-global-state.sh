#!/bin/bash
# test-update-global-state.sh — Tests for update-global-state.sh
# Validates key-value setter for .craft/.global-state

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"
source "$SCRIPT_DIR/fixtures/minimal.sh"

UPDATE_GLOBAL_STATE_SCRIPT="$SCRIPTS_DIR/update-global-state.sh"

# --- Tests ---

echo "=== test-update-global-state.sh ==="
echo ""

# Test 1: Creates a key in existing state file
begin_test "Creates a key in existing state file"

TEST_DIR=$(create_minimal_craft)
trap cleanup_test_dir EXIT

bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "1-auth" "$TEST_DIR"

source "$TEST_DIR/.craft/.global-state"
assert_eq "ACTIVE_CYCLE is 1-auth" "1-auth" "$ACTIVE_CYCLE"

cleanup_test_dir
echo ""

# Test 2: Updates an existing key
begin_test "Updates an existing key"

TEST_DIR=$(create_minimal_craft)
bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "1-auth" "$TEST_DIR"
bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "2-dashboard" "$TEST_DIR"

source "$TEST_DIR/.craft/.global-state"
assert_eq "ACTIVE_CYCLE updated to 2-dashboard" "2-dashboard" "$ACTIVE_CYCLE"

cleanup_test_dir
echo ""

# Test 3: Clears a key (sets to empty)
begin_test "Clears a key (sets to empty)"

TEST_DIR=$(create_minimal_craft)
bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "1-auth" "$TEST_DIR"
bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "" "$TEST_DIR"

source "$TEST_DIR/.craft/.global-state"
assert_eq "ACTIVE_CYCLE is empty" "" "$ACTIVE_CYCLE"

cleanup_test_dir
echo ""

# Test 4: Creates .global-state file if missing
begin_test "Creates .global-state file if missing"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"
# No .global-state file

bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "1-auth" "$TEST_DIR"

assert_file_exists ".global-state created" "$TEST_DIR/.craft/.global-state"
source "$TEST_DIR/.craft/.global-state"
assert_eq "ACTIVE_CYCLE is 1-auth" "1-auth" "$ACTIVE_CYCLE"

rm -rf "$TEST_DIR"
echo ""

# Test 5: No .craft/ directory — exits 1
begin_test "No .craft/ directory — exits 1"

TEST_DIR=$(mktemp -d)

set +e
RESULT=$(bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "test" "$TEST_DIR" 2>/dev/null)
EXIT_CODE=$?
set -e

assert_eq "exits 1 without .craft/" "1" "$EXIT_CODE"

rm -rf "$TEST_DIR"
echo ""

# Test 6: No key argument — exits 1
begin_test "No key argument — exits 1"

set +e
RESULT=$(bash "$UPDATE_GLOBAL_STATE_SCRIPT" 2>/dev/null)
EXIT_CODE=$?
set -e

assert_eq "exits 1 with no args" "1" "$EXIT_CODE"
echo ""

# Test 7: Multiple keys — each independent
begin_test "Multiple keys — each independent"

TEST_DIR=$(create_minimal_craft)
bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "1-auth" "$TEST_DIR"
bash "$UPDATE_GLOBAL_STATE_SCRIPT" CURRENT_STORY "login-form" "$TEST_DIR"
bash "$UPDATE_GLOBAL_STATE_SCRIPT" RUN_MODE "autonomous" "$TEST_DIR"

source "$TEST_DIR/.craft/.global-state"
assert_eq "ACTIVE_CYCLE is 1-auth" "1-auth" "$ACTIVE_CYCLE"
assert_eq "CURRENT_STORY is login-form" "login-form" "$CURRENT_STORY"
assert_eq "RUN_MODE is autonomous" "autonomous" "$RUN_MODE"

cleanup_test_dir
echo ""

# Test 8: Default project root (.) when not provided
begin_test "Default project root is . when not provided"

TEST_DIR=$(create_minimal_craft)

set +e
RESULT=$(cd "$TEST_DIR" && bash "$UPDATE_GLOBAL_STATE_SCRIPT" ACTIVE_CYCLE "test" 2>/dev/null)
EXIT_CODE=$?
set -e

assert_eq "exits 0 with default root" "0" "$EXIT_CODE"

source "$TEST_DIR/.craft/.global-state"
assert_eq "ACTIVE_CYCLE is test" "test" "$ACTIVE_CYCLE"

cleanup_test_dir
echo ""

# Test 9: Write gate open/close on a never-inited project writes nothing
# A bare .craft/ (only mockups/, no project.md, no .global-state) is not a
# project the write gate guards. Creating .global-state to record the gate
# would make it one, and the close step would then deny every source edit.
begin_test "CRAFT_WRITE_ENABLED on a never-inited project creates no .global-state"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft/mockups/x"

set +e
bash "$UPDATE_GLOBAL_STATE_SCRIPT" CRAFT_WRITE_ENABLED "true" "$TEST_DIR" >/dev/null 2>&1
OPEN_CODE=$?
bash "$UPDATE_GLOBAL_STATE_SCRIPT" CRAFT_WRITE_ENABLED "" "$TEST_DIR" >/dev/null 2>&1
CLOSE_CODE=$?
set -e

assert_eq "gate open exits 0" "0" "$OPEN_CODE"
assert_eq "gate close exits 0" "0" "$CLOSE_CODE"
assert_file_not_exists "no .global-state on a never-inited project" "$TEST_DIR/.craft/.global-state"

rm -rf "$TEST_DIR"
echo ""

# Test 10: Write gate on a set-up project whose state file is missing still records
# project.md makes the gate guard the project, so opening must create the file.
begin_test "CRAFT_WRITE_ENABLED with project.md and no .global-state creates it"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"
echo "# Project" > "$TEST_DIR/.craft/project.md"

bash "$UPDATE_GLOBAL_STATE_SCRIPT" CRAFT_WRITE_ENABLED "true" "$TEST_DIR"

assert_file_exists ".global-state created for a set-up project" "$TEST_DIR/.craft/.global-state"
source "$TEST_DIR/.craft/.global-state"
assert_eq "CRAFT_WRITE_ENABLED is true" "true" "$CRAFT_WRITE_ENABLED"

rm -rf "$TEST_DIR"
echo ""

# Test 11: A full adhoc open/close on a never-inited project leaves source edits allowed
# Runs the real write gate hook: allowed before, with the gate open, and after it closes.
begin_test "Adhoc open/close on a never-inited project never arms the write gate"

TEST_DIR=$(mktemp -d)
TEST_RESOLVED=$(cd "$TEST_DIR" && pwd -P)
mkdir -p "$TEST_DIR/.craft/mockups/x"
echo "a{}" > "$TEST_DIR/app.css"
JSON="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_RESOLVED/app.css\",\"old_string\":\"a\",\"new_string\":\"b\"},\"cwd\":\"$TEST_RESOLVED\"}"
gate() { (cd "$TEST_RESOLVED" && echo "$JSON" | env -u CRAFT_PROJECT_ROOT python3 "$SCRIPTS_DIR/check-write-permission.py"); }

assert_not_contains "edit allowed before adhoc" "deny" "$(gate)"
bash "$UPDATE_GLOBAL_STATE_SCRIPT" CRAFT_WRITE_ENABLED "true" "$TEST_RESOLVED" >/dev/null 2>&1 || true
assert_not_contains "edit allowed with the gate open" "deny" "$(gate)"
bash "$UPDATE_GLOBAL_STATE_SCRIPT" CRAFT_WRITE_ENABLED "" "$TEST_RESOLVED" >/dev/null 2>&1 || true
assert_not_contains "edit allowed after the gate closes" "deny" "$(gate)"

rm -rf "$TEST_DIR"
echo ""

# --- Summary ---
finish_tests
