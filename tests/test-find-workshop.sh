#!/bin/bash
# test-find-workshop.sh — Tests for find-workshop.sh
# Validates project root resolution in monorepo scenarios
#
# Key behavior: "nearest wins" — walk up from CWD, first .craft/.global-state wins.
# In a monorepo with multiple .craft/ directories (one per sub-project),
# each sub-project owns its own .craft/. This is intentional.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"
source "$SCRIPT_DIR/fixtures/with-shadow.sh"
source "$SCRIPT_DIR/fixtures/minimal.sh"

FIND_SCRIPT="$SCRIPTS_DIR/find-workshop.sh"

# --- Tests ---

echo "=== test-find-workshop.sh ==="
echo ""

# Test 1: Nearest .craft/ wins — child found before parent
# In a monorepo, each sub-project has its own .craft/. When CWD is inside
# a sub-project, find-workshop should resolve to THAT sub-project.
begin_test "Nearest wins — resolves to child .craft/ from child dir"

TEST_DIR=$(create_craft_with_shadow)
trap cleanup_test_dir EXIT
PARENT_DIR="$TEST_DIR/project"
CHILD_DIR="$TEST_DIR/project/apps/web"

# Source find-workshop.sh from the child dir in a subshell
RESULT=$(cd "$CHILD_DIR" && unset PROJECT_ROOT && unset CRAFT_PROJECT_ROOT && unset CRAFT_MULTI_PROJECT && source "$FIND_SCRIPT" 2>/dev/null && echo "$PROJECT_ROOT")

assert_eq "resolves to child (nearest) project root" "$CHILD_DIR/" "$RESULT"

cleanup_test_dir
echo ""

# Test 2: Nearest wins from deep subdir — walks up to closest .craft/
begin_test "Nearest wins — resolves to child .craft/ from deep subdir"

TEST_DIR=$(create_craft_with_shadow)
PARENT_DIR="$TEST_DIR/project"
CHILD_DIR="$TEST_DIR/project/apps/web"

# Go deeper — from apps/web/src/components/
mkdir -p "$CHILD_DIR/src/components"
RESULT=$(cd "$CHILD_DIR/src/components" && unset PROJECT_ROOT && unset CRAFT_PROJECT_ROOT && unset CRAFT_MULTI_PROJECT && source "$FIND_SCRIPT" 2>/dev/null && echo "$PROJECT_ROOT")

assert_eq "resolves to child from deep subdir" "$CHILD_DIR/" "$RESULT"

cleanup_test_dir
echo ""

# Test 3: Basic — single .craft/.global-state, correct resolution
begin_test "Basic — single .craft/ resolves correctly"

TEST_DIR=$(create_minimal_craft)

RESULT=$(cd "$TEST_DIR" && unset PROJECT_ROOT && unset CRAFT_PROJECT_ROOT && unset CRAFT_MULTI_PROJECT && source "$FIND_SCRIPT" 2>/dev/null && echo "$PROJECT_ROOT")

assert_eq "resolves to project dir" "$TEST_DIR/" "$RESULT"

cleanup_test_dir
echo ""

# Test 4: No .craft/ anywhere — returns empty/error
begin_test "No .craft/ — returns error"

TEST_DIR=$(mktemp -d)

set +e
RESULT=$(cd "$TEST_DIR" && unset PROJECT_ROOT && unset CRAFT_PROJECT_ROOT && unset CRAFT_MULTI_PROJECT && source "$FIND_SCRIPT" 2>/dev/null && echo "$PROJECT_ROOT")
EXIT_CODE=$?
set -e

# PROJECT_ROOT should be empty (script exits 1 or return 1)
if [ -z "$RESULT" ]; then
  echo "  PASS: PROJECT_ROOT is empty when no .craft/ found"
  PASS=$((PASS + 1))
else
  echo "  FAIL: PROJECT_ROOT should be empty, got: $RESULT"
  FAIL=$((FAIL + 1))
fi

cleanup_test_dir
echo ""

# Test 5: CRAFT_PROJECT_ROOT env var takes precedence
begin_test "Env var CRAFT_PROJECT_ROOT takes precedence"

TEST_DIR=$(create_minimal_craft)
# Create a second dir that CRAFT_PROJECT_ROOT points to
ALT_DIR=$(create_minimal_craft)

RESULT=$(cd "$TEST_DIR" && unset PROJECT_ROOT && export CRAFT_PROJECT_ROOT="$ALT_DIR" && unset CRAFT_MULTI_PROJECT && source "$FIND_SCRIPT" 2>/dev/null && echo "$PROJECT_ROOT")

assert_eq "uses env var, not walk-up" "$ALT_DIR/" "$RESULT"

rm -rf "$ALT_DIR"
cleanup_test_dir
echo ""

# Test 6: Invalid CRAFT_PROJECT_ROOT falls through to walk-up
begin_test "Invalid env var falls through to walk-up"

TEST_DIR=$(create_minimal_craft)

RESULT=$(cd "$TEST_DIR" && unset PROJECT_ROOT && export CRAFT_PROJECT_ROOT="/nonexistent/path" && unset CRAFT_MULTI_PROJECT && source "$FIND_SCRIPT" 2>/dev/null && echo "$PROJECT_ROOT")

assert_eq "falls through to walk-up" "$TEST_DIR/" "$RESULT"

cleanup_test_dir
echo ""

# Test 7: Bare .craft/ fallback skipped — walks past rogue directory
begin_test "Bare .craft/ skipped — fallback ignores rogue dir without project.md"

TEST_DIR=$(create_craft_with_rogue_shadow)
PARENT_DIR="$TEST_DIR/project"
ROGUE_DIR="$TEST_DIR/project/apps/web"

# From apps/web/ (which has bare .craft/), should walk up to parent
RESULT=$(cd "$ROGUE_DIR" && unset PROJECT_ROOT && unset CRAFT_PROJECT_ROOT && unset CRAFT_MULTI_PROJECT && source "$FIND_SCRIPT" 2>/dev/null && echo "$PROJECT_ROOT")

assert_eq "skips rogue .craft/, resolves to parent" "$PARENT_DIR/" "$RESULT"

cleanup_test_dir
echo ""

# --- craft_before_init_root ---
# The lookup is run the way instruction files run it: a fresh bash that sources
# find-workshop.sh (a cold source ends in `return 1`) and then calls the function.

BI_TMP=()
bi_cleanup() {
  local d
  for d in "${BI_TMP[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
trap bi_cleanup EXIT

# bi_dir - a fresh physical temp folder, so expected paths match git's toplevel
bi_dir() {
  BI_DIR=$(cd "$(mktemp -d)" && pwd -P)
  BI_TMP+=("$BI_DIR")
}

# bi_env <dir> <bash -c script> - run the script from <dir> with no project variables
bi_env() {
  local dir="$1"; shift
  (cd "$dir" && env -u CRAFT_PROJECT_ROOT -u PROJECT_ROOT -u CRAFT_PROJECT_NAME -u CRAFT_MULTI_PROJECT "$@")
}

bi_print() {
  bi_env "$1" bash -c 'source "$1" >/dev/null 2>&1; craft_before_init_root' _ "$FIND_SCRIPT"
}

bi_from() {
  bi_env "$1" bash -c 'source "$1" >/dev/null 2>&1; craft_before_init_root >/dev/null; echo "$CRAFT_BEFORE_INIT_FROM"' _ "$FIND_SCRIPT"
}

begin_test "before-init lookup: project set up by .global-state, from its folder and a subfolder"
bi_dir; P="$BI_DIR"
mkdir -p "$P/.craft" "$P/sub/deep"
printf 'ACTIVE_CYCLE=""\n' > "$P/.craft/.global-state"
assert_eq "prints the project from its folder" "$P" "$(bi_print "$P")"
assert_eq "prints the project from a subfolder" "$P" "$(bi_print "$P/sub/deep")"
assert_eq "FROM is project" "project" "$(bi_from "$P/sub")"
echo ""

begin_test "before-init lookup: project set up by project.md alone"
bi_dir; P="$BI_DIR"
mkdir -p "$P/.craft" "$P/sub"
printf -- '---\nname: x\n---\n' > "$P/.craft/project.md"
assert_eq "prints the project from its folder" "$P" "$(bi_print "$P")"
assert_eq "prints the project from a subfolder" "$P" "$(bi_print "$P/sub")"
assert_eq "FROM is project" "project" "$(bi_from "$P/sub")"
echo ""

begin_test "before-init lookup: git repo with no set-up project, from a subfolder"
bi_dir; R="$BI_DIR"
git -C "$R" init -q
mkdir -p "$R/a/b"
assert_eq "prints the repo top, not the subfolder" "$R" "$(bi_print "$R/a/b")"
assert_eq "FROM is git" "git" "$(bi_from "$R/a/b")"
echo ""

begin_test "before-init lookup: no git and no project"
bi_dir; N="$BI_DIR"
assert_eq "prints the current folder" "$N" "$(bi_print "$N")"
assert_eq "FROM is folder" "folder" "$(bi_from "$N")"
echo ""

begin_test "before-init lookup: CRAFT_PROJECT_ROOT naming a set-up project wins over the folder's own repo"
bi_dir; A="$BI_DIR"
mkdir -p "$A/.craft"
printf 'ACTIVE_CYCLE=""\n' > "$A/.craft/.global-state"
bi_dir; R="$BI_DIR"
git -C "$R" init -q
GOT=$(cd "$R" && env -u PROJECT_ROOT -u CRAFT_PROJECT_NAME -u CRAFT_MULTI_PROJECT CRAFT_PROJECT_ROOT="$A" \
  bash -c 'source "$1" >/dev/null 2>&1; craft_before_init_root' _ "$FIND_SCRIPT")
assert_eq "prints the set-up project" "$A" "$GOT"
echo ""

begin_test "before-init lookup: monorepo top with several projects and none picked"
bi_dir; M="$BI_DIR"
git -C "$M" init -q
mkdir -p "$M/.craft/projects" "$M/p1/.craft" "$M/p2/.craft"
printf 'ACTIVE_CYCLE=""\n' > "$M/.craft/.global-state"
printf -- '---\nname: p1\npath: p1\n---\n' > "$M/.craft/projects/p1.md"
printf -- '---\nname: p2\npath: p2\n---\n' > "$M/.craft/projects/p2.md"
assert_eq "prints the top" "$M" "$(bi_print "$M")"
MULTI=$(bi_env "$M" bash -c 'source "$1" >/dev/null 2>&1; craft_before_init_root >/dev/null; echo "$CRAFT_MULTI_PROJECT"' _ "$FIND_SCRIPT")
assert_eq "several-projects flag survives the call" "true" "$MULTI"
echo ""

begin_test "before-init lookup: under set -eu, nothing on stderr, exit 0"
bi_dir; N="$BI_DIR"
ERR_FILE="$N/stderr.txt"
RC=0
OUT=$(bi_env "$N" bash -c 'set -eu; source "$1" >/dev/null 2>&1 || true; craft_before_init_root' _ "$FIND_SCRIPT" 2>"$ERR_FILE") || RC=$?
assert_eq "exit status 0" "0" "$RC"
assert_eq "prints the current folder" "$N" "$OUT"
assert_eq "stderr is empty" "" "$(cat "$ERR_FILE")"
echo ""

begin_test "sourcing alone leaves the lookup's variables unset"
bi_dir; P="$BI_DIR"
mkdir -p "$P/.craft"
printf 'ACTIVE_CYCLE=""\n' > "$P/.craft/.global-state"
OUT=$(bi_env "$P" bash -c 'source "$1"; echo "[${CRAFT_BEFORE_INIT_ROOT-unset}][${CRAFT_BEFORE_INIT_FROM-unset}]"' _ "$FIND_SCRIPT")
assert_eq "no output from the source, both variables unset" "[unset][unset]" "$OUT"
echo ""

# --- Summary ---
finish_tests
