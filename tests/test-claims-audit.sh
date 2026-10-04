#!/bin/bash
# test-claims-audit.sh - Verify the claims-audit contract catches a planted false claim
#
# The claims-auditor agent verifies completion claims against on-disk artifacts
# (validation receipt, git diff, story file) before a story completes. A bash
# test cannot invoke the haiku agent, so these tests plant a false claim against
# a fixture receipt showing a FAILED test and assert the agent's CONTRACT
# resolves it unsupported, plus assert the anti-contamination, anti-transcript,
# and ordering wiring is present in the plugin files.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

AGENT_FILE="$PLUGIN_ROOT/agents/claims-auditor.md"
IMPLEMENT_FILE="$PLUGIN_ROOT/commands/craft-story-implement.md"
INDEX_FILE="$PLUGIN_ROOT/reference/orchestration-index.min"
FIXTURE_RECEIPT="$SCRIPT_DIR/fixtures/claims-audit-receipt-failed.md"

# --- Tests ---

echo "=== test-claims-audit.sh ==="
echo ""

# Test 1: a planted false claim resolves unsupported by contract
# The fixture receipt shows a FAILED test; the planted claim is "all tests pass".
# The agent's verdict rules define unsupported = an artifact CONTRADICTS the claim,
# so this claim-vs-receipt pair must resolve unsupported.
begin_test "false test-pass claim resolves unsupported by contract"

assert_file_exists \
  "fixture receipt exists" \
  "$FIXTURE_RECEIPT"

assert_file_contains \
  "fixture receipt shows a FAILED test row (contradicts the planted claim)" \
  "| Tests + Coverage | FAIL |" \
  "$FIXTURE_RECEIPT"

assert_file_contains \
  "agent defines unsupported as artifact-contradicts-claim" \
  "an artifact you read CONTRADICTS the claim" \
  "$AGENT_FILE"

assert_file_contains \
  "the unsupported rule names the exact planted scenario" \
  'the claim says "all tests pass" but the receipt shows a FAILED row' \
  "$AGENT_FILE"

echo ""

# Test 1b: file claims are judged on the untracked listing too
# story-implement defines files changed as the diff plus new untracked files;
# a diff-only evidence row rules a true claim about a new file unsupported and
# lets "only touched X" pass with an untracked Y sitting in the tree.
begin_test "file-claim evidence includes untracked files"

assert_file_contains \
  "File/diff evidence row names the untracked listing" \
  'git ls-files --others --exclude-standard' \
  "$AGENT_FILE"

assert_file_contains \
  "story-implement's files-changed definition uses the same listing" \
  'git ls-files --others --exclude-standard' \
  "$IMPLEMENT_FILE"

echo ""

# Test 2: agent forbids session-transcript reads
begin_test "agent forbids session-transcript reads"

assert_file_contains \
  "agent body forbids transcript and jsonl reads" \
  "NEVER read session transcripts" \
  "$AGENT_FILE"

echo ""

# Test 3: agent receives no narrative summary
begin_test "agent receives no narrative summary"

assert_file_contains \
  "agent input contract states no narrative is received" \
  "You receive NO orchestrator narrative summary" \
  "$AGENT_FILE"

echo ""

# Test 4: audit is invoked before complete-story.sh in the story-final flow
begin_test "audit invoked before complete-story.sh"

AUDITOR_LINE=$(grep -n "claims-auditor" "$IMPLEMENT_FILE" | head -1 | cut -d: -f1)
COMPLETE_LINE=$(grep -n "hooks/scripts/complete-story.sh" "$IMPLEMENT_FILE" | head -1 | cut -d: -f1)

if [ -n "$AUDITOR_LINE" ] && [ -n "$COMPLETE_LINE" ] && [ "$AUDITOR_LINE" -lt "$COMPLETE_LINE" ]; then
  ORDERING="audit-first"
else
  ORDERING="broken (auditor: ${AUDITOR_LINE:-absent}, complete-story: ${COMPLETE_LINE:-absent})"
fi

assert_eq \
  "claims-auditor invocation precedes the complete-story.sh call" \
  "audit-first" \
  "$ORDERING"

echo ""

# Test 5: the story-final chain references the audit step
begin_test "story-final chain references the audit"

assert_file_contains \
  "orchestration index chain includes claims-audit" \
  "claims-audit" \
  "$INDEX_FILE"

echo ""

# Test 6: agent stays out of the consultable set (description scan)
begin_test "agent description carries no consultable markers"

assert_file_not_contains \
  "description does not contain 'Consult when'" \
  "Consult when" \
  "$AGENT_FILE"

assert_file_not_contains \
  "description does not contain 'Trigger conditions'" \
  "Trigger conditions" \
  "$AGENT_FILE"

assert_file_contains \
  "craft-ask operational name list includes claims-auditor" \
  "claims-auditor" \
  "$PLUGIN_ROOT/commands/craft-ask.md"

echo ""

finish_tests
