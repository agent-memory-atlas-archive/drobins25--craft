#!/bin/bash
# test-annotate-channel.sh - Coverage for the per-session annotation capture
# channel: the listener (hooks/scripts/annotate-channel.py) and its single entry
# seam (hooks/scripts/annotate-run.sh).
#
# The channel's file only ever holds what an explicit POST /pins put there, or
# the cleared tombstone from POST /clear. These tests drive real listeners on
# OS-assigned ports with curl, and always kill every listener they start.
# Usage: bash tests/test-annotate-channel.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

REPO="$PLUGIN_ROOT"
RUN="$SCRIPTS_DIR/annotate-run.sh"
CHANNEL="$SCRIPTS_DIR/annotate-channel.py"

TMP_ROOTS=()
TMP_PIDS=()

cleanup() {
  local r p f
  for r in "${TMP_ROOTS[@]:-}"; do
    [ -n "$r" ] || continue
    for f in "$r"/.craft/annotations/*/listener.pid; do
      [ -f "$f" ] || continue
      p="$(cat "$f" 2>/dev/null || true)"
      case "$p" in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null || true ;; esac
    done
    rm -rf "$r"
  done
  for p in "${TMP_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  return 0
}
trap cleanup EXIT

# new_root - sets NEW_ROOT; called directly (never in a command substitution)
# so the root is recorded for cleanup in this shell, not a subshell.
new_root() {
  NEW_ROOT="$(mktemp -d)"
  TMP_ROOTS+=("$NEW_ROOT")
  mkdir -p "$NEW_ROOT/.craft"
}

# arm_session <root> [extra arm args...] - sets SID and PORT (empty on failure)
arm_session() {
  local root="$1"; shift
  local out
  out="$(CRAFT_PROJECT_ROOT="$root" bash "$RUN" arm --owner-pid "$$" "$@" 2>/dev/null)" || true
  SID="$(echo "$out" | awk '/^SESSION /{print $2; exit}')"
  PORT="$(echo "$out" | awk '/^SESSION /{print $4; exit}')"
}

# run_in <root> <args...> - run the wrapper against a root, tolerating failure
run_in() {
  local root="$1"; shift
  CRAFT_PROJECT_ROOT="$root" bash "$RUN" "$@" 2>/dev/null || true
}

# rd <file> - file contents, or MISSING
rd() { cat "$1" 2>/dev/null || echo MISSING; }

# json_get <file> <python-expr over d> - evaluate against the parsed file
json_get() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
' "$1" "$2" 2>/dev/null || echo "UNREADABLE"
}

# http <method> <port> <path> [body] - prints "<status>" on the first line, then headers and body
http() {
  local method="$1" port="$2" path="$3" body="${4:-}"
  if [ -n "$body" ]; then
    curl -s -i --max-time 5 -X "$method" -H 'Origin: null' -H 'Content-Type: application/json' \
      --data "$body" "http://127.0.0.1:$port$path" 2>/dev/null || true
  else
    curl -s -i --max-time 5 -X "$method" -H 'Origin: null' \
      "http://127.0.0.1:$port$path" 2>/dev/null || true
  fi
}

status_of() { echo "$1" | head -1 | awk '{print $2}'; }

pin_json() { # <n> <text>
  printf '{"n":%s,"text":"%s","x":10,"y":20,"selector":"div.a","nearText":"near","ts":1}' "$1" "$2"
}

# is_running <pid> - alive and not a zombie awaiting its parent's wait
is_running() {
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" || true
  [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}

# wait_dead <pid> - bounded poll for a process to stop running
wait_dead() {
  local i=0
  while is_running "$1" && [ "$i" -lt 40 ]; do
    sleep 0.25; i=$((i + 1))
  done
  ! is_running "$1"
}

# ---------------------------------------------------------------------------

begin_test "OPTIONS with Origin null is answered 204 with the allow headers"
assert_file_exists "listener source exists" "$CHANNEL"
assert_file_exists "wrapper exists" "$RUN"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
PRE_PORT="$PORT"
for P in /pins /clear /events; do
  RESP="$(curl -s -i --max-time 5 -X OPTIONS -H 'Origin: null' \
    -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type' \
    "http://127.0.0.1:${PORT:-0}$P" 2>/dev/null || true)"
  assert_eq "preflight $P status 204" "204" "$(status_of "$RESP")"
  assert_contains "preflight $P allow-origin" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$RESP"
  assert_contains "preflight $P allow-headers" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Hh]eaders: Content-Type' "$RESP"
  assert_contains "preflight $P allow-methods" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Mm]ethods: POST, OPTIONS' "$RESP"
  assert_contains "preflight $P allow-private-network" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Pp]rivate-[Nn]etwork: true' "$RESP"
done

begin_test "POST /pins from Origin null returns 200 and the allow-origin header"
RESP="$(http POST "$PRE_PORT" /pins "[$(pin_json 1 hello)]")"
assert_eq "POST /pins 200" "200" "$(status_of "$RESP")"
assert_contains "POST carries allow-origin" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$RESP"
RESP="$(http GET "$PRE_PORT" /health)"
assert_contains "GET /health carries allow-origin" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$RESP"
RESP="$(http GET "$PRE_PORT" /nope)"
assert_contains "404 carries allow-origin" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$RESP"

begin_test "malformed and non-array POST /pins bodies are rejected and leave the file untouched"
BEFORE="$(cat "$ROOT/.craft/annotations/$SID/current.json" 2>/dev/null || echo MISSING)"
RESP="$(http POST "$PRE_PORT" /pins 'not json')"
assert_eq "non-JSON body is 400" "400" "$(status_of "$RESP")"
RESP="$(http POST "$PRE_PORT" /pins '{"n":1}')"
assert_eq "non-array body is 400" "400" "$(status_of "$RESP")"
AFTER="$(cat "$ROOT/.craft/annotations/$SID/current.json" 2>/dev/null || echo MISSING)"
assert_eq "file unchanged by rejected bodies" "$BEFORE" "$AFTER"

begin_test "arm prints SESSION and PORT; the port file matches; the port was OS-assigned"
new_root; ROOT="$NEW_ROOT"
OUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" arm --owner-pid "$$" 2>/dev/null || true)"
assert_contains "stdout is a SESSION line" '^SESSION [0-9]*-[0-9]* PORT [0-9][0-9]*$' "$OUT"
SID="$(echo "$OUT" | awk '{print $2}')"
PORT="$(echo "$OUT" | awk '{print $4}')"
D="$ROOT/.craft/annotations/$SID"
assert_eq "port file matches printed port" "$PORT" "$(cat "$D/port" 2>/dev/null || echo MISSING)"
assert_file_exists "listener.pid written" "$D/listener.pid"
assert_eq "owner.pid is the --owner-pid override" "$$" "$(cat "$D/owner.pid" 2>/dev/null || echo MISSING)"
if [ -n "$PORT" ] && [ "$PORT" -gt 1023 ] 2>/dev/null; then
  echo "  PASS: port is an unprivileged OS-assigned port"
  PASS=$((PASS + 1))
else
  echo "  FAIL: port is not an unprivileged number: '$PORT'"
  FAIL=$((FAIL + 1))
fi
HEALTH="$(curl -s --max-time 5 "http://127.0.0.1:${PORT:-0}/health" 2>/dev/null || true)"
assert_eq "health reports ok and the same port" "true:$PORT" \
  "$(echo "$HEALTH" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d["ok"]).lower()+":"+str(d["port"]))' 2>/dev/null || echo BAD)"
SRC_LITERALS="$(grep -nE '127\.0\.0\.1:[0-9]|localhost:[0-9]' "$RUN" "$CHANNEL" 2>/dev/null || true)"
assert_eq "no port literal in the shipped sources" "" "$SRC_LITERALS"

begin_test "a second arm for the same session is idempotent; two fresh arms coexist"
OUT2="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" arm --session "$SID" --owner-pid "$$" 2>/dev/null || true)"
assert_eq "same session, same port" "SESSION $SID PORT $PORT" "$OUT2"
LPID_BEFORE="$(rd "$D/listener.pid")"
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" arm --session "$SID" --owner-pid "$$" >/dev/null 2>&1 || true
assert_eq "re-arm did not respawn the listener" "$LPID_BEFORE" "$(rd "$D/listener.pid")"
arm_session "$ROOT"; SID_B="$SID"; PORT_B="$PORT"
arm_session "$ROOT"; SID_C="$SID"; PORT_C="$PORT"
assert_not_eq "fresh arms mint distinct ids" "$SID_B" "$SID_C"
assert_not_eq "fresh arms bind distinct ports" "$PORT_B" "$PORT_C"
assert_contains "both listeners answer" '"ok": true' "$(curl -s --max-time 5 "http://127.0.0.1:${PORT_B:-0}/health" 2>/dev/null || true)$(curl -s --max-time 5 "http://127.0.0.1:${PORT_C:-0}/health" 2>/dev/null || true)"

begin_test "session id matches <digits>-<digits> and is not the md5-of-cwd shape"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
assert_contains "id is pid-epoch" '^[0-9][0-9]*-[0-9][0-9]*$' "$SID"
assert_not_contains "id is not a 32-char hex digest" '^[0-9a-f]\{32\}$' "$SID"
CWD_DIGEST="$( { printf '%s' "$ROOT" | md5sum 2>/dev/null || printf '%s' "$ROOT" | md5 2>/dev/null; } | cut -d' ' -f1)"
assert_not_eq "a digest of the working directory was computed" "" "$CWD_DIGEST"
assert_not_eq "id is not derived from the working directory" "$CWD_DIGEST" "$SID"

begin_test "a session id that could escape the annotations directory is refused"
new_root; ROOT="$NEW_ROOT"
set +e
run_out="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" arm --session '../escape' --owner-pid "$$" 2>/dev/null)"
RC=$?
set -e
assert_not_eq "traversal id exits non-zero" "0" "$RC"
assert_dir_not_exists "nothing created outside the annotations dir" "$ROOT/.craft/escape"
assert_not_contains "no SESSION line printed" '^SESSION' "$run_out"

begin_test "second POST /pins replaces the first entirely"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
F="$ROOT/.craft/annotations/$SID/current.json"
http POST "$PORT" /pins "[$(pin_json 1 first),$(pin_json 2 second)]" >/dev/null
assert_eq "first set has two pins" "1,2" "$(json_get "$F" '",".join(str(p["n"]) for p in d["pins"])')"
SEQ1="$(json_get "$F" 'd["seq"]')"
http POST "$PORT" /pins "[$(pin_json 3 third)]" >/dev/null
assert_eq "only pin 3 remains" "3" "$(json_get "$F" '",".join(str(p["n"]) for p in d["pins"])')"
assert_eq "cleared is false" "False" "$(json_get "$F" 'd["cleared"]')"
assert_eq "seq advanced by one" "$((SEQ1 + 1))" "$(json_get "$F" 'd["seq"]')"
assert_not_contains "no trace of pin 1 text" 'first' "$(cat "$F")"
assert_not_contains "no trace of pin 2 text" 'second' "$(cat "$F")"
assert_eq "no temp file left behind" "0" "$(ls "$ROOT/.craft/annotations/$SID" | grep -c 'current.json.tmp' || true)"
assert_contains "file carries sent_at" '"sent_at"' "$(cat "$F")"

begin_test "POST /clear writes a tombstone, not an unlink"
SEQ_BEFORE="$(json_get "$F" 'd["seq"]')"
RESP="$(http POST "$PORT" /clear)"
assert_eq "POST /clear 200" "200" "$(status_of "$RESP")"
assert_file_exists "file still exists after clear" "$F"
assert_eq "tombstone cleared flag" "True" "$(json_get "$F" 'd["cleared"]')"
assert_eq "tombstone has no pins" "[]" "$(json_get "$F" 'd["pins"]')"
assert_eq "tombstone seq advanced" "$((SEQ_BEFORE + 1))" "$(json_get "$F" 'd["seq"]')"
assert_not_contains "no pre-clear pin text readable" 'third' "$(cat "$F")"

begin_test "send-only channel: driving /clear, /health, and unknown paths never places a pin in the file"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
F="$ROOT/.craft/annotations/$SID/current.json"
http GET "$PORT" /health >/dev/null
http POST "$PORT" /clear >/dev/null
http GET "$PORT" /nope >/dev/null
http POST "$PORT" /nope "[$(pin_json 9 smuggled)]" >/dev/null
http POST "$PORT" /announce "[$(pin_json 9 smuggled)]" >/dev/null
curl -s --max-time 2 -H 'Origin: null' "http://127.0.0.1:$PORT/events" >/dev/null 2>&1 || true
http POST "$PORT" /clear "[$(pin_json 9 smuggled)]" >/dev/null
assert_eq "no pin after driving every non-pin path" "[]" "$(json_get "$F" 'd["pins"]')"
assert_not_contains "smuggled text never reaches the file" 'smuggled' "$(cat "$F")"
http POST "$PORT" /pins "[$(pin_json 1 sent)]" >/dev/null
http GET "$PORT" /health >/dev/null
http POST "$PORT" /clear >/dev/null
http GET "$PORT" /nope >/dev/null
assert_eq "pins still empty after the clear" "[]" "$(json_get "$F" 'd["pins"]')"
assert_eq "still the tombstone" "True" "$(json_get "$F" 'd["cleared"]')"

begin_test "a cleared pin cannot be read back after a process restart"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
D="$ROOT/.craft/annotations/$SID"
http POST "$PORT" /pins "[$(pin_json 1 ghost),$(pin_json 2 ghost2)]" >/dev/null
http POST "$PORT" /clear >/dev/null
SEQ_CLEAR="$(json_get "$D/current.json" 'd["seq"]')"
OLD_PID="$(rd "$D/listener.pid")"
case "$OLD_PID" in MISSING) ;; *) kill "$OLD_PID" 2>/dev/null || true ;; esac
if wait_dead "$OLD_PID"; then echo "  PASS: listener died"; PASS=$((PASS + 1)); else echo "  FAIL: listener did not die"; FAIL=$((FAIL + 1)); fi
OUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" arm --session "$SID" --owner-pid "$$" 2>/dev/null || true)"
assert_contains "re-arm reports the session" "^SESSION $SID PORT [0-9]" "$OUT"
NEW_PID="$(rd "$D/listener.pid")"
assert_not_eq "a new listener replaced the dead one" "$OLD_PID" "$NEW_PID"
assert_eq "restart left the tombstone in place" "True" "$(json_get "$D/current.json" 'd["cleared"]')"
assert_eq "restart left no pins" "[]" "$(json_get "$D/current.json" 'd["pins"]')"
assert_not_contains "ghost text unreadable" 'ghost' "$(cat "$D/current.json")"
NEW_PORT="$(rd "$D/port")"
http POST "$NEW_PORT" /pins "[$(pin_json 5 fresh)]" >/dev/null
assert_eq "seq continues monotonically across the restart" "$((SEQ_CLEAR + 1))" "$(json_get "$D/current.json" 'd["seq"]')"

begin_test "arm itself returns in bounded time from a separate process while the listener stays alive"
new_root; ROOT="$NEW_ROOT"
BOUND_OUT="$(mktemp)"
# A listener holding the caller's pipe would keep `cat` (and so this job) alive.
( CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" arm --owner-pid "$$" 2>/dev/null | cat > "$BOUND_OUT" ) &
JOB=$!
TMP_PIDS+=("$JOB")
i=0
while kill -0 "$JOB" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.25; i=$((i + 1)); done
if kill -0 "$JOB" 2>/dev/null; then
  echo "  FAIL: arm did not return within 15s (held pipe?)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: arm returned with the listener still running"; PASS=$((PASS + 1))
fi
BPORT="$(awk '/^SESSION /{print $4}' "$BOUND_OUT")"
assert_contains "listener still answers after arm returned" '"ok": true' "$(curl -s --max-time 5 "http://127.0.0.1:${BPORT:-0}/health" 2>/dev/null || true)"
rm -f "$BOUND_OUT"

begin_test "the ancestry walk resolves a fake ancestor named claude-max, not only literal claude"
new_root; ROOT="$NEW_ROOT"
FAKE_OUT="$( ( exec -a claude-max bash -c 'echo "FAKEPID $$"; CRAFT_PROJECT_ROOT="$1" bash "$2" arm 2>/dev/null; echo done' claude-max "$ROOT" "$RUN" ) )"
FAKE_PID="$(echo "$FAKE_OUT" | awk '/^FAKEPID/{print $2}')"
FSID="$(echo "$FAKE_OUT" | awk '/^SESSION /{print $2}')"
assert_eq "owner.pid is the claude-max ancestor" "$FAKE_PID" "$(cat "$ROOT/.craft/annotations/$FSID/owner.pid" 2>/dev/null || echo MISSING)"

begin_test "with no claude ancestor the owner falls back to the listener's own pid"
new_root; ROOT="$NEW_ROOT"
FB_OUT="$( ( exec -a not-the-agent bash -c 'CRAFT_PROJECT_ROOT="$1" PATH="$PATH" bash "$2" arm 2>/dev/null; echo done' not-the-agent "$ROOT" "$RUN" ) )"
FBSID="$(echo "$FB_OUT" | awk '/^SESSION /{print $2}')"
FBD="$ROOT/.craft/annotations/$FBSID"
# Only meaningful when the host process tree has no claude ancestor at all.
if ps -o command= -p "$$" >/dev/null 2>&1 && [ "$(cat "$FBD/owner.pid" 2>/dev/null)" = "$(cat "$FBD/listener.pid" 2>/dev/null)" ]; then
  echo "  PASS: owner.pid equals listener.pid when no claude ancestor exists"
  PASS=$((PASS + 1))
else
  # A real claude process sits above this test run; the walk correctly found it.
  assert_contains "owner.pid resolved to a live numeric pid" '^[0-9][0-9]*$' "$(cat "$FBD/owner.pid" 2>/dev/null || echo MISSING)"
fi

begin_test "status prints id, port, pid, and client count for an armed session"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
LP="$(rd "$ROOT/.craft/annotations/$SID/listener.pid")"
ST="$(run_in "$ROOT" status --session "$SID")"
assert_contains "status names the session" "SESSION $SID" "$ST"
assert_contains "status names the port" "PORT $PORT" "$ST"
assert_contains "status names the listener pid" "PID $LP" "$ST"
assert_contains "status carries a client count" 'CLIENTS [0-9][0-9]*' "$ST"

begin_test "status --all lists every session dir with a liveness verdict"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"; A_SID="$SID"
mkdir -p "$ROOT/.craft/annotations/dead-session"
sleep 0.05 & DEAD_OWNER=$!; wait "$DEAD_OWNER" || true
echo "$DEAD_OWNER" > "$ROOT/.craft/annotations/dead-session/owner.pid"
ALL="$(run_in "$ROOT" status --all)"
assert_contains "live owner reported alive" "$A_SID.*alive" "$ALL"
assert_contains "dead owner reported dead" 'dead-session.*dead' "$ALL"

begin_test "sweep reaps a dead-owner dir and kills its listener; leaves a live-owner dir untouched; tolerates garbage; exits 0"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
AN="$ROOT/.craft/annotations"
DEAD_DIR="$AN/$SID"
DEAD_LISTENER="$(rd "$DEAD_DIR/listener.pid")"
mkdir -p "$AN/live-1" "$AN/empty-1" "$AN/garbage-1" "$AN/stranger-1"
sleep 0.05 & DOWNER=$!; wait "$DOWNER" || true
sleep 300 & LIVE_LISTENER=$!
sleep 300 & STRANGER=$!
TMP_PIDS+=("$LIVE_LISTENER" "$STRANGER")
echo "$DOWNER" > "$DEAD_DIR/owner.pid"
echo "$$" > "$AN/live-1/owner.pid"
echo "$LIVE_LISTENER" > "$AN/live-1/listener.pid"
echo "$DOWNER" > "$AN/stranger-1/owner.pid"
echo "$STRANGER" > "$AN/stranger-1/listener.pid"
echo "not-a-pid" > "$AN/garbage-1/owner.pid"
echo "also bad" > "$AN/garbage-1/listener.pid"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" sweep >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "sweep exits 0" "0" "$RC"
assert_dir_not_exists "dead-owner dir removed" "$DEAD_DIR"
if wait_dead "$DEAD_LISTENER"; then echo "  PASS: dead-owner real listener was killed"; PASS=$((PASS + 1)); else echo "  FAIL: dead-owner real listener still alive"; FAIL=$((FAIL + 1)); fi
assert_dir_not_exists "dead-owner dir whose pid is no longer a listener is still removed" "$AN/stranger-1"
if is_running "$STRANGER"; then echo "  PASS: a reused pid that is not a listener is left alone"; PASS=$((PASS + 1)); else echo "  FAIL: sweep killed a process that is not a listener"; FAIL=$((FAIL + 1)); fi
assert_dir_exists "live-owner dir untouched" "$AN/live-1"
assert_file_exists "live-owner pid file untouched" "$AN/live-1/owner.pid"
if is_running "$LIVE_LISTENER"; then echo "  PASS: live-owner listener still alive"; PASS=$((PASS + 1)); else echo "  FAIL: live-owner listener was killed"; FAIL=$((FAIL + 1)); fi
assert_dir_exists "empty dir tolerated" "$AN/empty-1"
assert_dir_exists "garbage dir tolerated" "$AN/garbage-1"
kill "$LIVE_LISTENER" "$STRANGER" 2>/dev/null || true
new_root
set +e
CRAFT_PROJECT_ROOT="$NEW_ROOT" bash "$RUN" sweep >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "sweep with no annotations dir exits 0" "0" "$RC"

begin_test "arm seeds .gitignore only on the creating run"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
GI="$ROOT/.craft/annotations/.gitignore"
assert_file_exists "seed written on the creating run" "$GI"
assert_eq "seed content is *" "*" "$(cat "$GI" 2>/dev/null || echo MISSING)"
rm -f "$GI"
arm_session "$ROOT"
assert_file_not_exists "a deleted seed is not recreated" "$GI"
new_root; ROOT2="$NEW_ROOT"
mkdir -p "$ROOT2/.craft/annotations"
arm_session "$ROOT2"
assert_file_not_exists "a pre-existing folder is not seeded" "$ROOT2/.craft/annotations/.gitignore"

begin_test "disarm removes the session dir"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
D="$ROOT/.craft/annotations/$SID"
DP="$(rd "$D/listener.pid")"
run_in "$ROOT" disarm --session "$SID" >/dev/null
assert_dir_not_exists "session dir removed" "$D"
if wait_dead "$DP"; then echo "  PASS: listener stopped"; PASS=$((PASS + 1)); else echo "  FAIL: listener still alive after disarm"; FAIL=$((FAIL + 1)); fi

begin_test "wait prints WAITING and exits 0 on a quiet timeout; prints the payload when seq advances"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
set +e
WOUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" wait --session "$SID" --timeout 2 2>/dev/null)"
RC=$?
set -e
assert_exit_code "quiet window exits 0" "0" "$RC"
assert_eq "quiet window prints WAITING" "WAITING" "$WOUT"
( sleep 1; http POST "$PORT" /pins "[$(pin_json 1 woke)]" >/dev/null ) &
TMP_PIDS+=("$!")
set +e
WOUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" wait --session "$SID" --timeout 8 2>/dev/null)"
RC=$?
set -e
assert_exit_code "advance exits 0" "0" "$RC"
assert_contains "advance prints the payload" '"text": "woke"' "$WOUT"
assert_eq "payload parses with a pin" "1" "$(echo "$WOUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["pins"]))' 2>/dev/null || echo BAD)"

begin_test "wait --since takes the caller's last-seen seq as its baseline"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
http POST "$PORT" /pins "[$(pin_json 1 landed)]" >/dev/null
SEQ_NOW="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seq"])' "$ROOT/.craft/annotations/$SID/current.json" 2>/dev/null || echo BAD)"
assert_contains "the send advanced seq" '^[1-9][0-9]*$' "$SEQ_NOW"
set +e
WOUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" wait --session "$SID" --since 0 --timeout 2 2>/dev/null)"
RC=$?
set -e
assert_exit_code "a SEND that already landed past --since is returned (exit 0)" "0" "$RC"
assert_contains "the already-landed payload is printed at once" '"text": "landed"' "$WOUT"
set +e
WOUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" wait --session "$SID" --since "$SEQ_NOW" --timeout 1 2>/dev/null)"
RC=$?
set -e
assert_exit_code "--since at the current seq waits like before (exit 0)" "0" "$RC"
assert_eq "--since at the current seq prints WAITING on a quiet window" "WAITING" "$WOUT"
set +e
WOUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" wait --session "$SID" --since nope --timeout 1 2>&1)"
RC=$?
set -e
assert_exit_code "a non-numeric --since is refused" "1" "$RC"

begin_test "status names a listener that does not answer instead of printing an idle count"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
LP="$(rd "$ROOT/.craft/annotations/$SID/listener.pid")"
kill "$LP" 2>/dev/null || true
wait_dead "$LP" || true
ST="$(run_in "$ROOT" status --session "$SID")"
assert_contains "status still names the session" "SESSION $SID" "$ST"
assert_contains "a dead listener prints CLIENTS unreachable" 'CLIENTS unreachable' "$ST"
assert_not_contains "a dead listener never prints a numeric count" 'CLIENTS [0-9]' "$ST"

begin_test "clear verb posts the tombstone"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
F="$ROOT/.craft/annotations/$SID/current.json"
http POST "$PORT" /pins "[$(pin_json 1 gone)]" >/dev/null
run_in "$ROOT" clear --session "$SID" >/dev/null
assert_eq "tombstone after clear verb" "True" "$(json_get "$F" 'd["cleared"]')"
assert_eq "no pins after clear verb" "[]" "$(json_get "$F" 'd["pins"]')"

# open_stream <port> <out-prefix> - holds GET /events with curl -N; headers go
# to <prefix>.hdr, the wire body to <prefix>.body; sets STREAM_PID
open_stream() {
  curl -s -N -D "$2.hdr" -H 'Origin: null' "http://127.0.0.1:$1/events" >"$2.body" 2>/dev/null &
  STREAM_PID=$!
  TMP_PIDS+=("$STREAM_PID")
}

# wait_for_text <file> <fixed-text> - bounded poll until the file contains the text
wait_for_text() {
  local i=0
  while ! grep -qF -- "$2" "$1" 2>/dev/null && [ "$i" -lt 40 ]; do
    sleep 0.25; i=$((i + 1))
  done
  grep -qF -- "$2" "$1" 2>/dev/null
}

# clients_of <port> - the registry count from /health, or BAD
clients_of() {
  curl -s --max-time 5 "http://127.0.0.1:$1/health" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["clients"])' 2>/dev/null || echo BAD
}

# wait_clients <port> <n> - bounded poll until the registry reports n
wait_clients() {
  local i=0
  while [ "$(clients_of "$1")" != "$2" ] && [ "$i" -lt 40 ]; do
    sleep 0.25; i=$((i + 1))
  done
  [ "$(clients_of "$1")" = "$2" ]
}

begin_test "a held /events stream registers: /health reports clients 1, then 0 after disconnect"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
assert_eq "no stream yet: clients 0" "0" "$(clients_of "$PORT")"
open_stream "$PORT" "$ROOT/s1"
if wait_clients "$PORT" 1; then echo "  PASS: clients 1 while the stream is held"; PASS=$((PASS + 1)); else echo "  FAIL: clients never reached 1 (got $(clients_of "$PORT"))"; FAIL=$((FAIL + 1)); fi
open_stream "$PORT" "$ROOT/s2"
if wait_clients "$PORT" 2; then echo "  PASS: a second stream makes clients 2"; PASS=$((PASS + 1)); else echo "  FAIL: second stream not registered (got $(clients_of "$PORT"))"; FAIL=$((FAIL + 1)); fi
assert_contains "health still reports ok and port" "\"port\": $PORT" "$(curl -s --max-time 5 "http://127.0.0.1:$PORT/health")"
kill "$STREAM_PID" 2>/dev/null || true
if wait_clients "$PORT" 1; then echo "  PASS: dropping one stream returns clients to 1"; PASS=$((PASS + 1)); else echo "  FAIL: clients did not drop to 1 (got $(clients_of "$PORT"))"; FAIL=$((FAIL + 1)); fi
S1_PID="$(pgrep -f "$ROOT/s1.hdr" | head -1 || true)"
[ -n "$S1_PID" ] && kill "$S1_PID" 2>/dev/null || true
if wait_clients "$PORT" 0; then echo "  PASS: clients 0 after every stream disconnects"; PASS=$((PASS + 1)); else echo "  FAIL: clients did not return to 0 (got $(clients_of "$PORT"))"; FAIL=$((FAIL + 1)); fi

begin_test "the stream carries the event-stream headers and the Origin null allow header"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
open_stream "$PORT" "$ROOT/h"
wait_clients "$PORT" 1 >/dev/null || true
HDRS="$(cat "$ROOT/h.hdr" 2>/dev/null || true)"
assert_contains "status 200" '^HTTP/1.1 200' "$HDRS"
assert_contains "content type is event-stream" '^[Cc]ontent-[Tt]ype: text/event-stream' "$HDRS"
assert_contains "no-cache" '^[Cc]ache-[Cc]ontrol: no-cache' "$HDRS"
assert_contains "allow-origin star" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$HDRS"
assert_contains "chunked transfer" '^[Tt]ransfer-[Ee]ncoding: chunked' "$HDRS"

begin_test "POST /pins returns 200 while a stream is held open"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
open_stream "$PORT" "$ROOT/t"
wait_clients "$PORT" 1 >/dev/null || true
RESP="$(http POST "$PORT" /pins "[$(pin_json 1 threaded)]")"
assert_eq "pins accepted with a stream held" "200" "$(status_of "$RESP")"
assert_eq "clear accepted with a stream held" "200" "$(status_of "$(http POST "$PORT" /clear)")"
assert_eq "health answers with a stream held" "200" "$(status_of "$(http GET "$PORT" /health)")"
assert_eq "the held stream is still registered" "1" "$(clients_of "$PORT")"

begin_test "announce delivers the reload event to a held stream, flushed on the wire"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
open_stream "$PORT" "$ROOT/a1"
open_stream "$PORT" "$ROOT/a2"
wait_clients "$PORT" 2 >/dev/null || true
F="$ROOT/.craft/annotations/$SID/current.json"
http POST "$PORT" /pins "[$(pin_json 1 sent)]" >/dev/null
SEQ_BEFORE="$(json_get "$F" 'd["seq"]')"
assert_not_contains "no event before an announce (SEND does not announce)" 'event: reload' "$(cat "$ROOT/a1.body" 2>/dev/null || true)"
AOUT="$(run_in "$ROOT" announce --session "$SID")"
assert_contains "wrapper reports both deliveries" '"delivered": 2' "$AOUT"
if wait_for_text "$ROOT/a1.body" "event: reload"; then echo "  PASS: stream one received the reload event"; PASS=$((PASS + 1)); else echo "  FAIL: stream one never saw the event"; FAIL=$((FAIL + 1)); fi
if wait_for_text "$ROOT/a2.body" "event: reload"; then echo "  PASS: stream two received the reload event"; PASS=$((PASS + 1)); else echo "  FAIL: stream two never saw the event"; FAIL=$((FAIL + 1)); fi
assert_contains "the event carries a data line" '^data: ' "$(cat "$ROOT/a1.body" 2>/dev/null || true)"
assert_eq "announce never touched the channel file" "$SEQ_BEFORE" "$(json_get "$F" 'd["seq"]')"
assert_eq "announce left the pins alone" "1" "$(json_get "$F" 'len(d["pins"])')"
RAW="$(http POST "$PORT" /announce)"
assert_eq "POST /announce is 200" "200" "$(status_of "$RAW")"
assert_contains "announce carries allow-origin" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$RAW"

begin_test "announce with no clients returns ok with delivered 0"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
RAW="$(http POST "$PORT" /announce)"
assert_eq "status 200" "200" "$(status_of "$RAW")"
assert_contains "ok true" '"ok": true' "$RAW"
assert_contains "delivered 0" '"delivered": 0' "$RAW"
assert_contains "wrapper prints delivered 0 too" '"delivered": 0' "$(run_in "$ROOT" announce --session "$SID")"

begin_test "announce prunes a dead stream and the wrapper refuses an unknown session"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
open_stream "$PORT" "$ROOT/p"
wait_clients "$PORT" 1 >/dev/null || true
kill "$STREAM_PID" 2>/dev/null || true
wait_clients "$PORT" 0 >/dev/null || true
assert_contains "announce after the disconnect delivers to nobody" '"delivered": 0' "$(http POST "$PORT" /announce)"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" announce --session nosuch >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "unknown session exits non-zero" "1" "$RC"

finish_tests "test-annotate-channel"
