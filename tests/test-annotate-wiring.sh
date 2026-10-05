#!/bin/bash
# test-annotate-wiring.sh - Structural contracts on the annotation overlay.
#
# The overlay's on-page behaviour cannot be executed by this suite (there is no
# JavaScript runtime in the repo), so the rules that make it honest are frozen
# here as facts about the one reference file that carries its source: one
# copy, verbatim labels, no hardcoded port, no shared palette reads, an install
# guard, no request before a gesture, a delivery stamp only on a real 200,
# a clear that posts the tombstone, and a teardown that leaves nothing behind.
# Usage: bash tests/test-annotate-wiring.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

REPO="$PLUGIN_ROOT"
REF="$REPO/commands/references/annotate-overlay.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# fenced_block <info-string> <file> - body of the first fence with that info string
fenced_block() {
  awk -v info="$1" '
    $0 == "```" info {inside=1; next}
    inside && $0 == "```" {exit}
    inside {print}
  ' "$2"
}

# fence_count <info-string> <file> - number of fences opened with that info string
fence_count() { grep -cx -- "\`\`\`$1" "$2" || true; }

# fn_body <name> - the top-level `  const <name> = ...` block of $SRC, through its closing `  };`
fn_body() {
  printf '%s\n' "$SRC" | awk -v s="  const $1 = " 'index($0, s) == 1 {on=1} on {print} on && $0 == "  };" {exit}'
}

# line_of <needle> <text> - first line number holding the literal needle (empty when absent)
line_of() { printf '%s\n' "$2" | grep -nF -m1 -- "$1" | cut -d: -f1 || true; }

# count_of <needle> <text> - number of lines holding the literal needle
count_of() { printf '%s\n' "$2" | grep -cF -- "$1" || true; }

# lacks_literal <desc> <needle> <text> - literal absence assertion (assert_not_contains is a regex)
lacks_literal() {
  if printf '%s\n' "$3" | grep -qF -- "$2"; then
    echo "  FAIL: $1"
    echo "    should NOT contain (literal): '$2'"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  fi
}

# pos_of <needle> <text> - character offset of the first literal needle (empty when absent)
pos_of() {
  case "$2" in
    *"$1"*) local head="${2%%"$1"*}"; echo "${#head}" ;;
    *) echo "" ;;
  esac
}

# before <desc> <line-a> <line-b> - both lines found and a strictly earlier than b
before() {
  if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ]; then
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1"
    echo "    line a: '${2:-missing}'  line b: '${3:-missing}'"
    FAIL=$((FAIL + 1))
  fi
}

begin_test "overlay reference exists"
assert_file_exists "commands/references/annotate-overlay.md" "$REF"
if [ ! -f "$REF" ]; then
  finish_tests "test-annotate-wiring"
fi

SRC="$(fenced_block overlay-source "$REF")"
WHOLE="$(cat "$REF")"

begin_test "overlay reference carries exactly one source block"
assert_eq "one overlay-source fence" "1" "$(fence_count overlay-source "$REF")"
assert_eq "the IIFE opener line appears once in the whole file" "1" "$(grep -cx -- '(() => {' "$REF" || true)"
assert_contains_literal "install guard makes a second injection a no-op" \
  'if (window.__craftAnnotateInstalled) return;' "$SRC"
assert_contains_literal "install flag is set after the guard" \
  'window.__craftAnnotateInstalled = true;' "$SRC"
assert_eq "source closes as a single expression" "})();" "$(printf '%s\n' "$SRC" | tail -1)"

begin_test "the control labels appear verbatim"
assert_contains_literal "COMMENT MODE: OFF" "'COMMENT MODE: OFF'" "$SRC"
assert_contains_literal "COMMENT MODE: ON" "'COMMENT MODE: ON'" "$SRC"
assert_contains_literal "CLEAR PINS" "'CLEAR PINS'" "$SRC"
assert_contains_literal "SEND TO CLAUDE" "'SEND TO CLAUDE'" "$SRC"
assert_contains_literal "strip readout prefix" "'MARKUP - '" "$SRC"
assert_contains_literal "strip readout suffix" "' marks'" "$SRC"
assert_contains_literal "CLEARED status" "'CLEARED'" "$SRC"

begin_test "no project design token, tokens.yaml reference, or .craft path appears"
lacks_literal "no tokens.yaml" "tokens.yaml" "$WHOLE"
lacks_literal "no .craft path" ".craft" "$WHOLE"
lacks_literal "no CSS variable read" "var(--" "$WHOLE"
assert_eq "no word 'token' anywhere in the reference" "0" "$(grep -ci 'token' "$REF" || true)"

begin_test "the ca-* constants are defined in the script and nowhere else"
assert_contains_literal "proof border" "2px solid #c8102e" "$SRC"
assert_contains_literal "pin mark" "#c8102e" "$SRC"
assert_contains_literal "strip background" "rgba(16,16,19,0.95)" "$SRC"
assert_contains_literal "strip action hover" "rgba(210,215,225,0.55)" "$SRC"
assert_contains_literal "comment surface" "#ffffff" "$SRC"
assert_contains_literal "comment shadow" "0 8px 30px rgba(0,0,0,0.35)" "$SRC"
assert_contains_literal "comment text" "#111111" "$SRC"
assert_eq "the marker red appears only inside the source fence" \
  "$(grep -c '#c8102e' <<< "$SRC" || true)" "$(grep -c '#c8102e' "$REF" || true)"
OUTSIDE="$(cd "$REPO" && grep -rlE '#c8102e|ca-proof-border|ca-pin-mark|ca-strip-bg|ca-strip-action|ca-comment-surface' \
  commands skills agents hooks scripts templates .craft/design 2>/dev/null | grep -v '^commands/references/annotate-overlay.md$' || true)"
assert_eq "no other shipped file or design bible carries them" "" "$OUTSIDE"

begin_test "no 127.0.0.1:<digits> literal - the base reads window.__craftAnnotatePort"
assert_eq "no loopback port literal in the file" "0" "$(grep -cE '(127\.0\.0\.1|localhost):[0-9]' "$REF" || true)"
assert_contains_literal "base is the stamped port" "'http://127.0.0.1:' + window.__craftAnnotatePort" "$SRC"
assert_contains_literal "an absent stamp means no base" "window.__craftAnnotatePort ?" "$SRC"

begin_test "the stream client sits behind the __craftAnnotateBaked guard"
GUARD_LINE="$(line_of 'if (window.__craftAnnotateBaked' "$SRC")"
EVENTS_LINE="$(line_of "'/events'" "$SRC")"
before "the /events connection comes after the baked guard" "$GUARD_LINE" "$EVENTS_LINE"
assert_eq "exactly one /events literal" "1" "$(count_of "/events" "$SRC")"
assert_eq "exactly one EventSource construction" "1" "$(count_of "new EventSource(" "$SRC")"
assert_contains_literal "reload event listener" "addEventListener('reload'" "$SRC"
assert_contains_literal "reconnect backoff is bounded" "Math.min(" "$SRC"

begin_test "no Last-Modified polling survives"
lacks_literal "no Last-Modified" "Last-Modified" "$SRC"
lacks_literal "no interval loop" "setInterval" "$SRC"
lacks_literal "no HEAD request" "'HEAD'" "$SRC"
lacks_literal "no done endpoint" "/done" "$SRC"
lacks_literal "no option payload field" "option:" "$SRC"

begin_test "inert when unarmed: the only requests are the two gesture handlers"
assert_eq "exactly two fetch calls" "2" "$(count_of "fetch(" "$SRC")"
assert_eq "exactly one /pins literal (send-only)" "1" "$(count_of "'/pins'" "$SRC")"
assert_eq "exactly one /clear literal" "1" "$(count_of "'/clear'" "$SRC")"
lacks_literal "no beacon" "sendBeacon" "$SRC"
lacks_literal "no XMLHttpRequest" "XMLHttpRequest" "$SRC"
assert_contains_literal "/pins fetch lives in the send handler" "'/pins'" "$(fn_body send)"
assert_contains_literal "/clear fetch lives in the clear handler" "'/clear'" "$(fn_body clearAll)"

begin_test "the RETURNED stamp literal appears only inside the POST success region"
SEND_BODY="$(fn_body send)"
THEN_PART="$(printf '%s\n' "$SEND_BODY" | awk 'index($0, ".then(res =>") {on=1} on {print} on && index($0, ".catch(") {exit}')"
assert_eq "RETURNED appears once in the source" "1" "$(count_of "RETURNED" "$SRC")"
assert_contains_literal "RETURNED sits in the resolved .then region" "RETURNED" "$THEN_PART"
before "the ok check precedes the stamp" "$(line_of 'res.ok' "$THEN_PART")" "$(line_of 'RETURNED' "$THEN_PART")"
assert_contains_literal "stamps for delivered pins are applied in the same region" "markSent()" "$THEN_PART"
assert_eq "markSent is called nowhere else" "1" "$(count_of "markSent()" "$SRC" | tr -d ' ')"

begin_test "the NOT ARMED string names its unmet condition on screen"
assert_contains_literal "NOT ARMED - no craft session listening" "NOT ARMED - no craft session listening" "$SRC"
assert_contains_literal "non-200 is treated as not armed" "if (!res.ok)" "$SEND_BODY"
assert_contains_literal "a rejected request is treated as not armed" ".catch(" "$SEND_BODY"

begin_test "a refused SEND is named BLOCKED BY PAGE, never NOT ARMED"
assert_contains_literal "BLOCKED BY PAGE string names its condition on screen" "BLOCKED BY PAGE - ask Claude to read pins directly" "$SRC"
assert_eq "BLOCKED_BY_PAGE is defined once in the source" "1" "$(count_of "const BLOCKED_BY_PAGE = " "$SRC" | tr -d ' ')"
CATCH_PART="$(printf '%s\n' "$SEND_BODY" | awk 'index($0, ".catch(") {on=1} on {print}')"
assert_contains_literal "the catch branch says BLOCKED BY PAGE" "say(BLOCKED_BY_PAGE)" "$CATCH_PART"
lacks_literal "the catch branch no longer says NOT ARMED" "say(NOT_ARMED)" "$CATCH_PART"
assert_contains_literal "a non-200 reply still says NOT ARMED" "say(NOT_ARMED)" "$THEN_PART"
assert_contains_literal "the reference prose names BLOCKED BY PAGE" "BLOCKED BY PAGE" "$(printf '%s\n' "$WHOLE" | grep -F "Honest confirmation" || true)"

begin_test "delete and edit handlers exist and the renumber routine is called on delete"
assert_contains_literal "DELETE control" "'DELETE'" "$SRC"
assert_contains_literal "EDIT control" "'EDIT'" "$SRC"
assert_contains_literal "removeEntry exists" "  const removeEntry = " "$SRC"
assert_contains_literal "renumber exists" "  const renumber = " "$SRC"
assert_contains_literal "removeEntry renumbers survivors" "renumber()" "$(fn_body removeEntry)"
assert_contains_literal "edit stales the delivered flag" "sent = false" "$(fn_body editEntry)"

begin_test "the detached state literal exists"
assert_contains_literal "detached class" "ca-detached" "$SRC"
assert_contains_literal "detached label" "DETACHED" "$SRC"
assert_contains_literal "anchor resolution is guarded" "document.querySelector(" "$SRC"

begin_test "the SEND handler commits the open box before collecting the set"
before "commitOpenBox precedes currentSet inside send" \
  "$(line_of 'commitOpenBox()' "$SEND_BODY")" "$(line_of 'currentSet()' "$SEND_BODY")"

begin_test "no ca-sheet-cast and no full-viewport background layer in the source"
lacks_literal "no ca-sheet-cast" "ca-sheet-cast" "$WHOLE"
lacks_literal "no backdrop filter" "backdrop-filter" "$SRC"
SHEET_RULE="$(printf '%s\n' "$SRC" | grep -F "'#ca-sheet{" || true)"
assert_contains_literal "sheet ignores pointer events" "pointer-events:none" "$SHEET_RULE"
lacks_literal "sheet rule sets no background" "background" "$SHEET_RULE"
assert_contains_literal "sheet is the proof border" "CA.proofBorder" "$SHEET_RULE"

begin_test "the canonical annotate clear appears verbatim and mentions no dial marker"
cat > "$TMP_DIR/expected-clear" <<'EOF'
document.getElementById('ca-style')?.remove(); document.getElementById('ca-sheet')?.remove(); document.getElementById('ca-strip')?.remove(); document.querySelectorAll('[data-craft-annotate-injected],.ca-pin,.ca-popover,.ca-box').forEach(el => el.remove()); document.body.classList.remove('ca-mode'); delete window.__craftAnnotateInstalled;
EOF
fenced_block annotate-clear "$REF" > "$TMP_DIR/actual-clear"
assert_eq "one annotate-clear fence" "1" "$(fence_count annotate-clear "$REF")"
CLEAR_RC=0; cmp -s "$TMP_DIR/expected-clear" "$TMP_DIR/actual-clear" || CLEAR_RC=$?
assert_eq "the clear matches the contract byte for byte" "0" "$CLEAR_RC"
lacks_literal "no dial marker anywhere in the file" "data-craft-dial-injected" "$WHOLE"
lacks_literal "no dial handles anywhere in the file" "craft-dial" "$WHOLE"
assert_contains_literal "nodes carry the annotate marker" "data-craft-annotate-injected" "$SRC"

begin_test "prefers-reduced-motion block is present and zeroes durations"
RM_LINE="$(printf '%s\n' "$SRC" | grep -F 'prefers-reduced-motion: reduce' || true)"
assert_contains_literal "reduced-motion media query" "@media (prefers-reduced-motion: reduce)" "$RM_LINE"
assert_contains_literal "transition duration zeroed" "transition-duration:0ms" "$RM_LINE"
assert_contains_literal "animation duration zeroed" "animation-duration:0ms" "$RM_LINE"

begin_test "CLEAR posts the tombstone before the wipe, and neither waits on the other"
CLEAR_BODY="$(fn_body clearAll)"
before "the /clear post precedes the storage purge" \
  "$(line_of "'/clear'" "$CLEAR_BODY")" "$(line_of 'localStorage.removeItem' "$CLEAR_BODY")"
before "the /clear post precedes the DOM wipe" \
  "$(line_of "'/clear'" "$CLEAR_BODY")" "$(line_of '.remove()' "$CLEAR_BODY")"
lacks_literal "the wipe is not chained on the post" ".then(" "$CLEAR_BODY"
assert_contains_literal "the counter is reset" "seq = 0" "$CLEAR_BODY"
assert_contains_literal "the readout reports zero marks" "CLEARED" "$CLEAR_BODY"

begin_test "teardown is total: listeners, stream and nodes all die with the strip"
assert_contains_literal "handlers check the strip is still attached" "strip.isConnected" "$SRC"
assert_contains_literal "handlers unregister themselves" "removeEventListener(" "$SRC"
assert_contains_literal "the stream is closed on teardown" ".close()" "$SRC"
assert_contains_literal "the flag is deleted by the clear so re-install works" "delete window.__craftAnnotateInstalled" "$WHOLE"

begin_test "comments render as text, never markup"
lacks_literal "no innerHTML" "innerHTML" "$SRC"
lacks_literal "no insertAdjacentHTML" "insertAdjacentHTML" "$SRC"
lacks_literal "no outerHTML" "outerHTML" "$SRC"
assert_contains_literal "textContent is the write path" ".textContent = " "$SRC"

begin_test "pins persist keyed by page path, best-effort"
assert_contains_literal "storage key includes the page path" "location.pathname" "$SRC"
assert_contains_literal "storage reads sit in try/catch" "catch (e)" "$SRC"
assert_contains_literal "rehydrate reads the keyed entry" "localStorage.getItem(STORE_KEY)" "$SRC"

begin_test "pin payload shape"
for field in "n:" "text:" "x:" "y:" "selector:" "nearText:" "ts:"; do
  assert_contains_literal "payload field $field" "$field" "$(fn_body makeData)"
done
assert_contains_literal "candidate copied from the context global" "window.__craftAnnotateContext" "$SRC"
assert_contains_literal "nearText is sliced to 60" "slice(0, 60)" "$SRC"
assert_contains_literal "cssPath is 5 deep" "p.length < 5" "$SRC"

begin_test "popover: one at a time, outside click in capture phase, Escape closes"
assert_contains_literal "outside-click listener registers in the capture phase" "}, true);" "$SRC"
assert_contains_literal "Escape closes" "e.key === 'Escape'" "$SRC"
assert_contains_literal "comment hint" "Enter = save / Esc = cancel" "$SRC"

begin_test "strip isolation and placement"
STRIP_RULE="$(printf '%s\n' "$SRC" | grep -F "'#ca-strip{" || true)"
for needle in "position:fixed" "z-index:2147483000" "font-family" "font-size" "line-height" "color:" "background:" "box-sizing"; do
  assert_contains_literal "strip rule sets $needle" "$needle" "$STRIP_RULE"
done
assert_contains_literal "style goes in head" "document.head.appendChild(" "$SRC"
assert_contains_literal "handles: style id" "'ca-style'" "$SRC"
assert_contains_literal "handles: sheet id" "'ca-sheet'" "$SRC"
assert_contains_literal "handles: strip id" "'ca-strip'" "$SRC"

begin_test "the reference documents the port stamp and the channel protocol"
assert_eq "one annotate-stamp fence" "1" "$(fence_count annotate-stamp "$REF")"
assert_contains_literal "raw tab stamp" "window.__craftAnnotatePort" "$(fenced_block annotate-stamp "$REF")"
assert_contains_literal "baked stamp" "window.__craftAnnotateBaked" "$(fenced_block annotate-stamp "$REF")"
assert_contains_literal "POST /pins documented" "POST /pins" "$WHOLE"
assert_contains_literal "POST /clear documented" "POST /clear" "$WHOLE"
assert_contains_literal "GET /events documented" "GET /events" "$WHOLE"
assert_contains_literal "reload event documented" "event: reload" "$WHOLE"

begin_test "reference hygiene"
EM_DASH="$(printf '\xe2\x80\x94')"
assert_eq "no em dashes" "0" "$(grep -c "$EM_DASH" "$REF" || true)"
assert_eq "no chrome-devtools mention (the dial sweep arrays are not extended here)" "0" "$(grep -c 'chrome-devtools' "$REF" || true)"
VOCAB_RC=0; python3 "$SCRIPTS_DIR/check-craft-vocab.py" --scan "$REF" >/dev/null 2>&1 || VOCAB_RC=$?
assert_eq "vocab scan exits 0" "0" "$VOCAB_RC"

begin_test "raw-tab flow: clear order, stamp order, injection"
FLOW="$REPO/commands/references/annotate-inline.md"
SHELL_FILE="$REPO/commands/craft-annotate.md"
FLOW_TEXT="$(cat "$FLOW" 2>/dev/null || true)"
SHELL_TEXT="$(cat "$SHELL_FILE" 2>/dev/null || true)"
assert_file_exists "flow reference exists" "$FLOW"
assert_file_exists "command shell exists" "$SHELL_FILE"
assert_contains_literal "flow carries the dial clear literal" "craft-dial-style" "$FLOW_TEXT"
assert_contains_literal "flow carries the annotate clear byte-exact" "$(fenced_block annotate-clear "$REF")" "$FLOW_TEXT"
assert_contains_literal "flow names the overlay source fence it injects" "overlay-source" "$FLOW_TEXT"
assert_contains_literal "flow names the stamp fence" "annotate-stamp" "$FLOW_TEXT"
L_ARM="$(line_of 'annotate-run.sh" arm' "$FLOW_TEXT")"
L_DIAL="$(line_of "craft-dial-style" "$FLOW_TEXT")"
L_STAMP="$(line_of "annotate-stamp" "$FLOW_TEXT")"
L_SRC="$(line_of "overlay-source" "$FLOW_TEXT")"
L_WAIT="$(line_of "run_in_background" "$FLOW_TEXT")"
before "arm precedes the dial clear" "$L_ARM" "$L_DIAL"
before "dial clear precedes the port stamp" "$L_DIAL" "$L_STAMP"
before "the port stamp precedes the overlay source" "$L_STAMP" "$L_SRC"
before "injection precedes the wait" "$L_SRC" "$L_WAIT"
assert_contains_literal "no baked flag is stamped by this flow" "never stamp" "$FLOW_TEXT"
assert_contains_literal "re-injection after navigation is named" "re-inject" "$FLOW_TEXT"
assert_contains_literal "navigation named as the trigger" "navigation" "$FLOW_TEXT"
assert_contains_literal "reuse goes through status before arming" 'annotate-run.sh" status' "$FLOW_TEXT"

begin_test "raw-tab flow: the one background wait"
assert_contains_literal "wait verb with the one-hour timeout" 'wait --session' "$FLOW_TEXT"
assert_contains_literal "wait timeout is 3600" '--timeout 3600' "$FLOW_TEXT"
assert_contains_literal "the wait carries the last-seen seq so a SEND between waits is never lost" '--since' "$FLOW_TEXT"
assert_contains_literal "Step 2 reads the unreachable word from status" 'CLIENTS unreachable' "$FLOW_TEXT"
assert_contains_literal "wait runs in the background" "run_in_background: true" "$FLOW_TEXT"
assert_contains_literal "SEND wake-up named" "SEND" "$FLOW_TEXT"
assert_contains_literal "exit wakes the session" "wakes the session" "$FLOW_TEXT"
assert_contains_literal "WAITING restart named" "WAITING" "$FLOW_TEXT"
assert_contains_literal "restart is silent" "silently" "$FLOW_TEXT"
assert_contains_literal "no tool timeout is set" "No tool timeout" "$FLOW_TEXT"

begin_test "raw-tab flow: no question widget, verbatim pins, teardown, degradation"
assert_eq "flow never names the question widget" "0" "$(grep -c 'AskUserQuestion' "$FLOW" || true)"
assert_eq "shell never names the question widget" "0" "$(grep -c 'AskUserQuestion' "$SHELL_FILE" || true)"
assert_contains_literal "verbatim rule at the read site" "exact words" "$FLOW_TEXT"
assert_contains_literal "teardown covers every exit path" "EVERY exit path" "$FLOW_TEXT"
assert_contains_literal "teardown posts the tombstone via the clear verb" 'annotate-run.sh" clear' "$FLOW_TEXT"
assert_contains_literal "tombstone named" "tombstone" "$FLOW_TEXT"
assert_eq "flow never calls the disarm verb or names it" "0" "$(grep -ci 'disarm' "$FLOW" || true)"
assert_contains_literal "listener lives until session end" "until the session ends" "$FLOW_TEXT"
assert_contains_literal "no connection means one plain line and stop" "no offer" "$FLOW_TEXT"

begin_test "command shell: routing only, inline read, no Skill tool"
assert_contains_literal "shell reads the flow inline" 'commands/references/annotate-inline.md' "$SHELL_TEXT"
assert_contains_literal "shell executes it inline" "inline" "$SHELL_TEXT"
assert_contains_literal "shell forbids the Skill tool" "Never invoke the flow via the Skill tool" "$SHELL_TEXT"
assert_contains_literal "name field" "name: annotate" "$SHELL_TEXT"
assert_contains_literal "when_to_use routes visual-value questions to dial" "dial" "$SHELL_TEXT"
assert_eq "shell grants no allowed-tools change" "0" "$(grep -c '^allowed-tools' "$SHELL_FILE" || true)"

begin_test "annotate is user-invoked only and documented"
assert_eq "no routing line in the warm index" "0" "$(grep -c 'craft:annotate' "$REPO/reference/orchestration-index.min" || true)"
assert_eq "no routing line in the cold index" "0" "$(grep -c 'craft:annotate' "$REPO/reference/cold-start-index.min" || true)"
assert_contains_literal "decision-tree Commands Reference row" '| `/craft:annotate` |' "$(cat "$REPO/docs/decision-tree.md")"
assert_contains_literal "DESIGN.md Included commands list" "craft:annotate" "$(grep -F 'Included commands:' "$REPO/DESIGN.md")"
assert_contains_literal "DESIGN.md tree names the shell" "craft-annotate.md" "$(cat "$REPO/DESIGN.md")"
assert_contains_literal "DESIGN.md tree names the flow" "annotate-inline.md" "$(cat "$REPO/DESIGN.md")"
assert_contains_literal "DESIGN.md tree names the overlay reference" "annotate-overlay.md" "$(cat "$REPO/DESIGN.md")"
assert_contains_literal "DESIGN.md tree names the run script" "annotate-run.sh" "$(cat "$REPO/DESIGN.md")"
assert_contains_literal "DESIGN.md tree names the channel script" "annotate-channel.py" "$(cat "$REPO/DESIGN.md")"

begin_test "flow file hygiene"
for f in "$FLOW" "$SHELL_FILE"; do
  assert_eq "no em dashes in $(basename "$f")" "0" "$(grep -c "$EM_DASH" "$f" 2>/dev/null || true)"
  FV_RC=0; python3 "$SCRIPTS_DIR/check-craft-vocab.py" --scan "$f" >/dev/null 2>&1 || FV_RC=$?
  assert_eq "vocab scan exits 0 on $(basename "$f")" "0" "$FV_RC"
done

# section_of <heading-prefix> <text> - from the heading line through the line before the next heading of the same or higher level
begin_test "the raw-tab flow probes the listener from the page and falls back to a direct read"
L_S4="$(line_of "## Step 4" "$FLOW_TEXT")"; L_S5="$(line_of "## Step 5" "$FLOW_TEXT")"; L_S6="$(line_of "## Step 6" "$FLOW_TEXT")"; L_NAV="$(line_of "## Navigation" "$FLOW_TEXT")"
L_PROBE="$(line_of "fetch(base + '/health')" "$FLOW_TEXT")"
assert_not_eq "Step 4 probes /health from the page" "" "$L_PROBE"
before "the probe sits in Step 4" "$L_S4" "$L_PROBE"
before "the probe precedes Step 5" "$L_PROBE" "$L_S5"
assert_contains_literal "the probe warns up front that SEND will not work here" "SEND will not work on this page" "$FLOW_TEXT"
L_FALL="$(line_of "ca-annotations:" "$FLOW_TEXT")"
assert_not_eq "Step 6 names the localStorage key" "" "$L_FALL"
before "the fallback sits in Step 6" "$L_S6" "$L_FALL"
before "the fallback precedes the navigation section" "$L_FALL" "$L_NAV"
assert_contains_literal "the fallback is keyed on the strip string" "BLOCKED BY PAGE" "$FLOW_TEXT"
assert_contains_literal "the fallback reads through the devtools connection" "localStorage" "$FLOW_TEXT"
assert_contains_literal "the shell says SEND needs localhost reach" "reach localhost" "$SHELL_TEXT"
assert_contains_literal "the shell names the direct-read fallback" "read the pins directly" "$SHELL_TEXT"

section_of() {
  printf '%s\n' "$2" | awk -v h="$1" '
    index($0, h) == 1 {on=1; level=0; while (substr(h, level + 1, 1) == "#") level++; print; next}
    on && /^#+ / {n=0; while (substr($0, n + 1, 1) == "#") n++; if (n <= level) exit}
    on {print}
  '
}

MOCKUP="$REPO/commands/references/mockup-inline.md"
DIAL="$REPO/commands/references/dial-inline.md"
MOCKUP_TEXT="$(cat "$MOCKUP" 2>/dev/null || true)"
DIAL_TEXT="$(cat "$DIAL" 2>/dev/null || true)"
SHEET="$(section_of '### The proof sheet' "$MOCKUP_TEXT")"

begin_test "mockup: bakes the overlay, port stamp, and baked flag at round write"
assert_contains_literal "the proof sheet section exists" "### The proof sheet" "$MOCKUP_TEXT"
assert_contains_literal "the script element id" '<script id="ca-overlay">' "$SHEET"
assert_contains_literal "baked immediately before the closing body tag" 'immediately before `</body>`' "$SHEET"
assert_contains_literal "names the overlay source fence" "overlay-source" "$SHEET"
assert_contains_literal "names the stamp fence" "annotate-stamp" "$SHEET"
assert_contains_literal "stamps the port" "window.__craftAnnotatePort" "$SHEET"
assert_contains_literal "stamps the baked flag" "window.__craftAnnotateBaked = true;" "$SHEET"
before "the stamps precede the source in the baked script" "$(pos_of 'annotate-stamp' "$SHEET")" "$(pos_of 'overlay-source' "$SHEET")"
assert_contains_literal "installed by the orchestrator" "orchestrator" "$SHEET"
assert_contains_literal "the alchemist is forbidden to touch it" "never touches" "$SHEET"
assert_contains_literal "comment mode stays opt-in" "COMMENT MODE" "$SHEET"
assert_contains_literal "arms the listener lazily at the first round shown" "first round" "$SHEET"
assert_contains_literal "arms through the run script" 'annotate-run.sh" arm' "$SHEET"
assert_contains_literal "the page stays a local file" "file://" "$SHEET"
assert_contains_literal "the overlay is not a ledger line" "NOT a ledger line" "$SHEET"
lacks_literal "the flow never stamps a candidate context" "__craftAnnotateContext" "$SHEET"

begin_test "mockup: every browser-open instruction is gated on a clients == 0 registry read"
assert_contains_literal "reads /health directly" "/health" "$SHEET"
assert_contains_literal "clients >= 1 announces" "clients >= 1" "$SHEET"
assert_contains_literal "only clients == 0 permits opening" "clients == 0" "$SHEET"
assert_contains_literal "never opens while a page is connected" "never opens a browser while a page is connected" "$SHEET"
assert_eq "no open-the-page instruction lives outside the proof sheet section" \
  "$(grep -ciE 'open (a browser|the page)' <<< "$SHEET" || true)" \
  "$(grep -ciE 'open (a browser|the page)' "$MOCKUP" || true)"
before "the registry read precedes the open instruction" \
  "$(pos_of 'clients == 0' "$SHEET")" "$(pos_of 'open the page' "$SHEET")"

begin_test "mockup: announces on round write, never at SEND"
assert_contains_literal "announce runs through the run script" 'annotate-run.sh" announce' "$SHEET"
assert_contains_literal "announce fires when the round is written" "round is written" "$SHEET"
assert_contains_literal "never at SEND" "never at SEND" "$SHEET"
assert_contains_literal "the page reloads itself" "reloads itself" "$SHEET"

begin_test "mockup: delivered == 0 means the page is gone, whatever the pre-check said"
assert_contains_literal "the delivered count decides" "delivered == 0" "$SHEET"
assert_contains_literal "the pre-check is not trusted alone" "never trusted alone" "$SHEET"
assert_contains_literal "a closed tab can still read connected" "clients >= 1" "$SHEET"
assert_contains_literal "no round reload is silently lost" "silently lost" "$SHEET"

begin_test "mockup: the reviewing tab is the driven tab, a refresh is explained"
assert_contains_literal "the reviewing tab is the driven tab" "reviewing tab is the driven tab" "$SHEET"
assert_contains_literal "hidden instances are for verification only" "verification" "$SHEET"
assert_contains_literal "a refresh during polish is explained, not blocked" "explain" "$MOCKUP_TEXT"

begin_test "mockup: reads the channel at the top of every beat, never waits, quotes verbatim"
assert_contains_literal "reads current.json" "current.json" "$SHEET"
assert_contains_literal "acts on a seq advance" "seq" "$SHEET"
assert_contains_literal "top of every live-loop beat" "top of every" "$SHEET"
assert_contains_literal "never blocks" "never blocks" "$SHEET"
lacks_literal "no wait verb in the flow" 'annotate-run.sh" wait' "$MOCKUP_TEXT"
lacks_literal "no wait flag in the flow" "wait --session" "$MOCKUP_TEXT"
lacks_literal "no background command in the flow" "run_in_background" "$MOCKUP_TEXT"
assert_contains_literal "verbatim rule at the read site" "exact words" "$SHEET"
assert_contains_literal "pins become round reactions" "## Reactions" "$SHEET"
assert_contains_literal "pins pass the settle gate" "settle gate" "$SHEET"

begin_test "mockup: the sheet is stripped before the Save write and from archived rounds"
POLISH="$(section_of '## Step 5' "$MOCKUP_TEXT")"
before "the strip precedes the remaining-state write on acceptance" \
  "$(pos_of 'strip the sheet' "$POLISH")" "$(pos_of 'write any remaining settled state' "$POLISH")"
assert_contains_literal "strip names the script element" '<script id="ca-overlay">' "$POLISH"
assert_contains_literal "acceptance posts the tombstone" 'annotate-run.sh" clear' "$POLISH"
assert_contains_literal "abandon strips too" "abandon" "$(printf '%s\n' "$MOCKUP_TEXT" | tail -1)"
assert_contains_literal "abandon posts the tombstone" "tombstone" "$(printf '%s\n' "$MOCKUP_TEXT" | tail -1)"
assert_contains_literal "archived rounds are stripped" 'rounds/*.html' "$SHEET"
assert_contains_literal "a converged page never ships with chrome" "never ships" "$MOCKUP_TEXT"
assert_contains_literal "the tab is cleared with the annotate clear" "annotate clear" "$POLISH"

begin_test "mockup: no new widget and no new task"
assert_eq "AskUserQuestion mentions are frozen" "10" "$(grep -c 'AskUserQuestion' "$MOCKUP" || true)"
assert_eq "TaskCreate mentions are frozen" "1" "$(grep -c 'TaskCreate' "$MOCKUP" || true)"
assert_eq "the proof sheet section names no widget" "0" "$(grep -c 'AskUserQuestion' <<< "$SHEET" || true)"
assert_contains_literal "arming is a substep" "substep" "$SHEET"

begin_test "dial: Step 7 arms comment mode and stamps the candidate at every switch"
STEP7="$(section_of '## Step 7' "$DIAL_TEXT")"
assert_contains_literal "arms through the run script" 'annotate-run.sh" arm' "$STEP7"
assert_contains_literal "reuses a held session through status" 'annotate-run.sh" status' "$STEP7"
assert_contains_literal "armed on request" "on request" "$STEP7"
assert_contains_literal "stamps the port" "window.__craftAnnotatePort" "$STEP7"
assert_contains_literal "pastes the overlay source fence" "overlay-source" "$STEP7"
assert_contains_literal "alongside the dial injection, not instead of it" "not instead of" "$STEP7"
assert_contains_literal "never stamps the baked flag" "never stamp the baked flag" "$STEP7"
assert_contains_literal "the context stamp is the bare letter string" 'window.__craftAnnotateContext = "<letter>"' "$STEP7"
assert_contains_literal "stamped at every candidate switch" "every candidate switch" "$STEP7"
assert_contains_literal "never an object" "never an object" "$STEP7"

begin_test "dial: reads the channel at the top of every beat, never waits, quotes verbatim"
assert_contains_literal "reads current.json" "current.json" "$STEP7"
assert_contains_literal "acts on a seq advance" "seq" "$STEP7"
assert_contains_literal "top of every beat" "top of every" "$STEP7"
assert_contains_literal "never blocks" "never blocks" "$STEP7"
lacks_literal "no wait verb in the flow" 'annotate-run.sh" wait' "$DIAL_TEXT"
lacks_literal "no wait flag in the flow" "wait --session" "$DIAL_TEXT"
lacks_literal "no background command in the flow" "run_in_background" "$DIAL_TEXT"
assert_contains_literal "verbatim rule at the read site" "exact words" "$STEP7"

begin_test "dial: Step 8 teardown runs the annotate clear and the tombstone, no disarm"
STEP8="$(section_of '## Step 8' "$DIAL_TEXT")"
TEARDOWN_LINE="$(printf '%s\n' "$STEP8" | grep -F '**Then teardown' || true)"
assert_contains_literal "teardown still runs the dial CLEAR" "Run CLEAR" "$TEARDOWN_LINE"
assert_contains_literal "teardown names the annotate clear" "annotate clear" "$TEARDOWN_LINE"
assert_contains_literal "teardown names the tombstone" "tombstone" "$TEARDOWN_LINE"
assert_contains_literal "tombstone goes through the clear verb" 'annotate-run.sh" clear' "$TEARDOWN_LINE"
assert_contains_literal "the listener lives until the session ends" "until the session ends" "$TEARDOWN_LINE"
assert_eq "dial flow never names the disarm verb" "0" "$(grep -ci 'disarm' "$DIAL" || true)"
assert_contains_literal "dial flow still carries the dial clear literal" "craft-dial-style" "$DIAL_TEXT"

begin_test "dial: no question widget is added"
assert_eq "AskUserQuestion appears once, as the prohibition" "1" "$(grep -c 'AskUserQuestion' "$DIAL" || true)"
assert_contains_literal "the prohibition stands" "No AskUserQuestion anywhere in this flow" "$DIAL_TEXT"
assert_eq "no task rail entry" "0" "$(grep -c 'TaskCreate' "$DIAL" || true)"

begin_test "both flows: file hygiene"
for f in "$MOCKUP" "$DIAL"; do
  assert_eq "no em dashes in $(basename "$f")" "0" "$(grep -c "$EM_DASH" "$f" 2>/dev/null || true)"
  FV_RC=0; python3 "$SCRIPTS_DIR/check-craft-vocab.py" --scan "$f" >/dev/null 2>&1 || FV_RC=$?
  assert_eq "vocab scan exits 0 on $(basename "$f")" "0" "$FV_RC"
done
assert_eq "no new chrome-devtools mention in mockup flow" "0" "$(grep -c 'chrome-devtools' "$MOCKUP" || true)"
assert_eq "no new chrome-devtools mention in dial flow" "0" "$(grep -c 'chrome-devtools' "$DIAL" || true)"

finish_tests "test-annotate-wiring"
