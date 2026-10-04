#!/bin/bash
# test-triage-ledger.sh — Tests for triage-ledger.sh
# Atomic writes, story identity, never-re-ask lookup, pending representation,
# bounded list-untriaged.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

LEDGER_SCRIPT="$SCRIPTS_DIR/triage-ledger.sh"

echo "=== test-triage-ledger.sh ==="
echo ""

# Test 1: Append is atomic and carries the story field
begin_test "Append is atomic and carries story field"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"

bash "$LEDGER_SCRIPT" append "secret.env" "pending" "36-commit-custody-chain" "$TEST_DIR"

if [ -f "$TEST_DIR/.craft/.triage-ledger.tmp" ]; then
  echo "  FAIL: .tmp file left behind - write was not completed atomically"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: no .tmp left behind (mv completed)"
  PASS=$((PASS + 1))
fi
assert_file_exists "ledger created" "$TEST_DIR/.craft/.triage-ledger"
LEDGER_CONTENT=$(cat "$TEST_DIR/.craft/.triage-ledger")
assert_contains "entry has path" "path: secret.env" "$LEDGER_CONTENT"
assert_contains "entry has story identity" "story: 36-commit-custody-chain" "$LEDGER_CONTENT"
assert_contains "entry is pending" "decision: pending" "$LEDGER_CONTENT"

rm -rf "$TEST_DIR"
echo ""

# Test 2: Lookup returns the prior decision (never-re-ask source of truth)
begin_test "Lookup returns prior decision from the file"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"

bash "$LEDGER_SCRIPT" append "scratch.txt" "leave" "story-a" "$TEST_DIR"
DECISION=$(bash "$LEDGER_SCRIPT" lookup "scratch.txt" "$TEST_DIR")
assert_eq "lookup returns leave" "leave" "$DECISION"

# Decision transition: pending entry overwritten by the triage decision
bash "$LEDGER_SCRIPT" append "later.txt" "pending" "story-a" "$TEST_DIR"
bash "$LEDGER_SCRIPT" append "later.txt" "ignore" "story-a" "$TEST_DIR"
DECISION=$(bash "$LEDGER_SCRIPT" lookup "later.txt" "$TEST_DIR")
assert_eq "pending overwritten by ignore" "ignore" "$DECISION"
ENTRY_COUNT=$(grep -c "path: later.txt" "$TEST_DIR/.craft/.triage-ledger")
assert_eq "upsert did not duplicate the entry" "1" "$ENTRY_COUNT"

rm -rf "$TEST_DIR"
echo ""

# Test 3: Absent ledger — lookup and list return empty without error
begin_test "Absent ledger returns empty, exit 0"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"

set +e
DECISION=$(bash "$LEDGER_SCRIPT" lookup "anything.txt" "$TEST_DIR")
LOOKUP_EXIT=$?
UNTRIAGED=$(bash "$LEDGER_SCRIPT" list-untriaged "$TEST_DIR")
LIST_EXIT=$?
set -e

assert_eq "lookup exits 0" "0" "$LOOKUP_EXIT"
assert_eq "lookup returns empty" "" "$DECISION"
assert_eq "list-untriaged exits 0" "0" "$LIST_EXIT"
assert_eq "list-untriaged returns empty" "" "$UNTRIAGED"

rm -rf "$TEST_DIR"
echo ""

# Test 4: list-untriaged is bounded to decision:pending entries
begin_test "list-untriaged returns only pending entries (bounded)"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"

bash "$LEDGER_SCRIPT" append "decided-1.txt" "leave" "story-a" "$TEST_DIR"
bash "$LEDGER_SCRIPT" append "decided-2.txt" "ignore" "story-a" "$TEST_DIR"
bash "$LEDGER_SCRIPT" append "decided-3.txt" "claim" "story-b" "$TEST_DIR"
bash "$LEDGER_SCRIPT" append "awaiting.txt" "pending" "story-c" "$TEST_DIR"

UNTRIAGED=$(bash "$LEDGER_SCRIPT" list-untriaged "$TEST_DIR")
assert_eq "only the pending path returned" "awaiting.txt" "$UNTRIAGED"

rm -rf "$TEST_DIR"
echo ""

# Test 5: Crashed-mid-triage — a surfaced-but-undecided entry stays pending
begin_test "Crashed-mid-triage leftover stays pending"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"

# Surfacing writes pending; the session dies before a decision lands
bash "$LEDGER_SCRIPT" append "mid-triage.txt" "pending" "story-x" "$TEST_DIR"

DECISION=$(bash "$LEDGER_SCRIPT" lookup "mid-triage.txt" "$TEST_DIR")
assert_eq "entry still pending after crash" "pending" "$DECISION"
UNTRIAGED=$(bash "$LEDGER_SCRIPT" list-untriaged "$TEST_DIR")
assert_contains "pending entry visible to the gate" "mid-triage.txt" "$UNTRIAGED"

rm -rf "$TEST_DIR"
echo ""

# Test 6: Path prefix safety — exact-line matching, no substring collisions
begin_test "Lookup matches exact paths, not prefixes"

TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/.craft"

bash "$LEDGER_SCRIPT" append "foo.txt" "leave" "story-a" "$TEST_DIR"
bash "$LEDGER_SCRIPT" append "foo.txt.bak" "pending" "story-a" "$TEST_DIR"

DECISION=$(bash "$LEDGER_SCRIPT" lookup "foo.txt" "$TEST_DIR")
assert_eq "exact path returns its own decision" "leave" "$DECISION"
DECISION=$(bash "$LEDGER_SCRIPT" lookup "foo.txt.bak" "$TEST_DIR")
assert_eq "longer path returns its own decision" "pending" "$DECISION"

rm -rf "$TEST_DIR"
echo ""

# Test 7: The Ignore recipe in craft-story-implement.md writes a line git honors
# (gitignore has no inline comments - a `#` mid-line is part of the pattern).
begin_test "Ignore recipe produces a .gitignore line that git actually matches"

STORY_IMPLEMENT="$PLUGIN_ROOT/commands/craft-story-implement.md"
RECIPE=$(grep -m1 "ignored during" "$STORY_IMPLEMENT" | sed 's/^[[:space:]]*//')
assert_contains "the Ignore recipe is a printf into .gitignore" ">> .gitignore" "$RECIPE"

TEST_DIR=$(mktemp -d)
(
  cd "$TEST_DIR" && git init -q . && touch scratch.log
  # Fill the recipe's placeholders and run it exactly as the orchestrator would.
  CMD=$(printf '%s' "$RECIPE" | sed 's/\[path\]/scratch.log/g; s/\[story-name\]/1-demo-story/g')
  bash -c "$CMD"
)
IGNORED=$(cd "$TEST_DIR" && git check-ignore -q scratch.log && echo yes || echo no)
assert_eq "git check-ignore matches the path after the recipe runs" "yes" "$IGNORED"
PROVENANCE=$(grep -c "craft: ignored during 1-demo-story" "$TEST_DIR/.gitignore")
assert_eq "the provenance comment is still written" "1" "$PROVENANCE"
STILL_UNTRACKED=$(cd "$TEST_DIR" && git status --porcelain --untracked-files=all | grep -c "scratch.log" || true)
assert_eq "git status no longer lists the path" "0" "$STILL_UNTRACKED"

rm -rf "$TEST_DIR"
echo ""

# --- Summary ---
finish_tests
