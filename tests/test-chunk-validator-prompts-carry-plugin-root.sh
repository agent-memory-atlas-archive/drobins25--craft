#!/bin/bash
# test-chunk-validator-prompts-carry-plugin-root.sh
#
# The chunk-validator subagent cannot resolve ${CLAUDE_PLUGIN_ROOT}, so every
# dispatch prompt must hand it the resolved path on a PLUGIN_ROOT line, and the
# citation scan it runs must start from the project root. Without the line the
# scan check is skipped; without the cd it reads the wrong relative paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/.."

PASS_COUNT=0; FAIL_COUNT=0; TOTAL=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    Expected: $2"; [ -n "${3:-}" ] && echo "    Got:      $3"; }

PLUGIN_ROOT_LINE='PLUGIN_ROOT: [resolved ${CLAUDE_PLUGIN_ROOT} - the subagent cannot resolve the variable itself]'

# Prints "<blocks found> <blocks missing the line>" for one file. A block is the
# text between a pair of fence lines (which may be indented) that contains the
# chunk-validator dispatch.
check_blocks() {
  awk -v want="$PLUGIN_ROOT_LINE" '
    function flush() {
      if (hit) { found++; if (!has) missing++ }
      hit = 0; has = 0
    }
    /^[ \t]*```/ {
      if (inblock) { flush(); inblock = 0 } else { inblock = 1 }
      next
    }
    inblock {
      if (index($0, "subagent_type: \"craft:chunk-validator\"")) hit = 1
      if (index($0, want)) has = 1
    }
    END { printf "%d %d\n", found, missing }
  ' "$1"
}

check_file() {
  local rel="$1" min="$2" counts found missing
  counts="$(check_blocks "$REPO/$rel")"
  found="${counts% *}"; missing="${counts#* }"
  if [ "$found" -lt "$min" ]; then
    fail "$rel has at least $min chunk-validator blocks" ">= $min" "$found"
  elif [ "$missing" -ne 0 ]; then
    fail "every chunk-validator block in $rel carries PLUGIN_ROOT" "0 blocks missing the line" "$missing of $found missing it"
  else
    pass "every chunk-validator block in $rel carries PLUGIN_ROOT ($found blocks)"
  fi
}

echo "chunk-validator dispatch prompts"
check_file "commands/craft-story-implement.md" 2
check_file "commands/references/validate-fix-loop.md" 1
check_file "skills/validate-chunk/SKILL.md" 2

echo "check 8 scan command"
scan_line="$(grep -F 'check-craft-vocab.py --scan' "$REPO/agents/chunk-validator.md" | head -1 || true)"
if [[ "$scan_line" == *"cd PROJECT_ROOT && "*"python3"* ]]; then
  pass "check 8 scan command runs from PROJECT_ROOT"
else
  fail "check 8 scan command runs from PROJECT_ROOT" "cd PROJECT_ROOT && before python3" "${scan_line:-<no --scan line found>}"
fi

echo ""
echo "$PASS_COUNT passed, $FAIL_COUNT failed ($TOTAL total)"
[ "$FAIL_COUNT" -eq 0 ]
