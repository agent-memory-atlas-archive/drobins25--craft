#!/bin/bash
# test-hook-timeouts.sh - Every hook in hooks/hooks.json carries a timeout in
# seconds. Claude Code reads `timeout` as seconds, so a value written as
# milliseconds (3000 for "3 seconds") lets a hung hook hold a turn for 50 minutes.
# A real hook budget is seconds to a few minutes; anything 1000 or more is a slip.
# Usage: bash tests/test-hook-timeouts.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

# Every hook entry, one line each: "<event> <command> <timeout or none> <async>".
entries() {
  jq -r '.hooks | to_entries[] | .key as $ev | .value[] | .hooks[]
    | "\($ev)\t\(.command // .type)\t\(if has("timeout") then .timeout else "none" end)\t\(.async // false)"' "$1"
}
# Entries whose timeout is not a whole number of seconds below 1000.
too_long() {
  jq -r '.hooks | to_entries[] | .key as $ev | .value[] | .hooks[]
    | select(has("timeout") and ((.timeout | type) != "number" or .timeout >= 1000 or .timeout < 1 or .timeout != (.timeout | floor)))
    | "\($ev) \(.command // .type) = \(.timeout)"' "$1"
}
# Non-async entries with no timeout of their own (they would fall back to 600).
missing() {
  jq -r '.hooks | to_entries[] | .key as $ev | .value[] | .hooks[]
    | select((.async // false) != true and (has("timeout") | not))
    | "\($ev) \(.command // .type)"' "$1"
}

begin_test "the checks catch a milliseconds value and a missing timeout (they can fail)"
FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT
cat > "$FIXTURE" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "a.sh", "timeout": 3000}]}],
  "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "b.sh"}]}],
  "PostToolUse": [{"hooks": [{"type": "command", "command": "c.sh", "timeout": 5000, "async": true}]}],
  "PreCompact": [{"hooks": [{"type": "command", "command": "d.sh", "timeout": 10}]}]
}}
EOF
assert_eq "a 3000 and an async 5000 are both flagged" "Stop a.sh = 3000
PostToolUse c.sh = 5000" "$(too_long "$FIXTURE")"
assert_eq "a non-async entry with no timeout is flagged" "PreToolUse b.sh" "$(missing "$FIXTURE")"

begin_test "hooks.json: every hook timeout is in seconds"
assert_eq "hooks.json parses" "ok" "$(jq -e . "$HOOKS_JSON" >/dev/null 2>&1 && echo ok || echo bad)"
assert_not_eq "hooks.json has hook entries" "" "$(entries "$HOOKS_JSON")"
assert_eq "no hook timeout is 1000 or more (seconds, not milliseconds)" "" "$(too_long "$HOOKS_JSON")"
assert_eq "every non-async hook sets its own timeout" "" "$(missing "$HOOKS_JSON")"

finish_tests "test-hook-timeouts"
