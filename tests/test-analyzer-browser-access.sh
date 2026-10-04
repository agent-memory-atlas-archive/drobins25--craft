#!/bin/bash
# test-analyzer-browser-access.sh - every agent that declares the chrome-devtools
# MCP server can actually reach its tools.
#
# A subagent's `tools:` is a strict allowlist (Claude Code docs, sub-agents:
# "MCP Servers and Tool Allowlists"); `mcpServers:` only attaches the server.
# An analyzer that declares chrome-devtools but allowlists five built-in tools
# never sees the browser and silently falls into code-review mode. So: an agent
# whose frontmatter names chrome-devtools either has no `tools:` allowlist, or
# its allowlist names ToolSearch (the tools are deferred in-session) and the
# server's tool pattern.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "=== test-analyzer-browser-access.sh ==="
echo ""

frontmatter() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$1"; }

CHECKED=0
for agent in "$ROOT"/agents/*.md; do
  fm=$(frontmatter "$agent")
  echo "$fm" | grep -q '^mcpServers:' || continue
  echo "$fm" | grep -A5 '^mcpServers:' | grep -q 'chrome-devtools' || continue
  CHECKED=$((CHECKED+1))
  name=$(basename "$agent" .md)
  tools_line=$(echo "$fm" | grep '^tools:' || true)
  if [ -z "$tools_line" ]; then
    pass "$name: no tools allowlist, inherits ToolSearch and the MCP tools"
    continue
  fi
  if echo "$tools_line" | grep -q 'ToolSearch' && echo "$tools_line" | grep -q 'mcp__plugin_craft_chrome-devtools'; then
    pass "$name: allowlist names ToolSearch and the chrome-devtools tools"
  else
    fail "$name: allowlist hides the browser" "$tools_line"
  fi
done

if [ "$CHECKED" -ge 5 ]; then
  pass "sweep covered $CHECKED chrome-devtools agents"
else
  fail "sweep covered $CHECKED chrome-devtools agents" "expected the four analyzers plus the walkthrough"
fi

echo ""
echo "=== Results (test-analyzer-browser-access): $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
