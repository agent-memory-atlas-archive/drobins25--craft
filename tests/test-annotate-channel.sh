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

# stop_job <pid>... - signal a background job of this shell and reap it, so the
# shell never prints a "Terminated: 15" job report into the test output
stop_job() {
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  return 0
}

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
  stop_job "${TMP_PIDS[@]:-}"
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
stop_job "$LIVE_LISTENER" "$STRANGER"
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
S1_PID="$STREAM_PID"
if wait_clients "$PORT" 1; then echo "  PASS: clients 1 while the stream is held"; PASS=$((PASS + 1)); else echo "  FAIL: clients never reached 1 (got $(clients_of "$PORT"))"; FAIL=$((FAIL + 1)); fi
open_stream "$PORT" "$ROOT/s2"
if wait_clients "$PORT" 2; then echo "  PASS: a second stream makes clients 2"; PASS=$((PASS + 1)); else echo "  FAIL: second stream not registered (got $(clients_of "$PORT"))"; FAIL=$((FAIL + 1)); fi
assert_contains "health still reports ok and port" "\"port\": $PORT" "$(curl -s --max-time 5 "http://127.0.0.1:$PORT/health")"
stop_job "$STREAM_PID"
if wait_clients "$PORT" 1; then echo "  PASS: dropping one stream returns clients to 1"; PASS=$((PASS + 1)); else echo "  FAIL: clients did not drop to 1 (got $(clients_of "$PORT"))"; FAIL=$((FAIL + 1)); fi
stop_job "$S1_PID"
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
stop_job "$STREAM_PID"
wait_clients "$PORT" 0 >/dev/null || true
assert_contains "announce after the disconnect delivers to nobody" '"delivered": 0' "$(http POST "$PORT" /announce)"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" announce --session nosuch >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "unknown session exits non-zero" "1" "$RC"

# hist_seqs <root> <sid> - the seq of every history line, space separated
hist_seqs() {
  python3 -c '
import json, sys
print(" ".join(str(json.loads(l)["seq"]) for l in open(sys.argv[1]) if l.strip()))
' "$1/.craft/annotations/$2/history.jsonl" 2>/dev/null || echo MISSING
}

begin_test "history survives a listener restart and seq stays monotonic"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session hist1
http POST "$PORT" /pins "[$(pin_json 1 one)]" >/dev/null
http POST "$PORT" /pins "[$(pin_json 1 two)]" >/dev/null
LPID="$(cat "$ROOT/.craft/annotations/hist1/listener.pid")"
kill "$LPID" 2>/dev/null || true
wait_dead "$LPID" || true
arm_session "$ROOT" --session hist1
RAW="$(http POST "$PORT" /pins "[$(pin_json 1 three)]")"
assert_contains "the restarted listener answers seq 3" '"seq": 3' "$RAW"
assert_eq "history holds every line, nothing truncated" "1 2 3" "$(hist_seqs "$ROOT" hist1)"
assert_eq "current.json holds the third set" "3" "$(json_get "$ROOT/.craft/annotations/hist1/current.json" 'd["seq"]')"

begin_test "a torn trailing history line is skipped when the listener resumes"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session torn1
http POST "$PORT" /pins "[$(pin_json 1 one)]" >/dev/null
LPID="$(cat "$ROOT/.craft/annotations/torn1/listener.pid")"
kill "$LPID" 2>/dev/null || true
wait_dead "$LPID" || true
printf '{"seq": 9, "pins": [' >> "$ROOT/.craft/annotations/torn1/history.jsonl"
rm -f "$ROOT/.craft/annotations/torn1/current.json"
arm_session "$ROOT" --session torn1
RAW="$(http POST "$PORT" /pins "[$(pin_json 1 two)]")"
assert_contains "seq resumes past the last parsable history line only" '"seq": 2' "$RAW"

begin_test "every POST appends one history line in seq order while current.json holds only the latest"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session hist2
D="$ROOT/.craft/annotations/hist2"
http POST "$PORT" /pins "[$(pin_json 1 a)]" >/dev/null
http POST "$PORT" /pins "[$(pin_json 1 b),$(pin_json 2 c)]" >/dev/null
http POST "$PORT" /pins "[$(pin_json 1 d)]" >/dev/null
http POST "$PORT" /clear >/dev/null
assert_eq "four lines in seq order" "1 2 3 4" "$(hist_seqs "$ROOT" hist2)"
assert_eq "current.json holds only the tombstone" "True 4" "$(json_get "$D/current.json" '"%s %s" % (d["cleared"], d["seq"])')"
assert_eq "history line 2 carries both pins" "2" "$(python3 -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).read().splitlines()[1])["pins"]))' "$D/history.jsonl")"
assert_eq "the cleared entry is in history" "True" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[3])["cleared"])' "$D/history.jsonl")"
assert_eq "history line equals the state written to current.json" "$(python3 -c 'import json,sys; print(json.dumps(json.loads(open(sys.argv[1]).read().splitlines()[3]), sort_keys=True))' "$D/history.jsonl")" "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$D/current.json")"

begin_test "begin prints RUN <seq> equal to the last seq on disk, writes run.json, empties session.css"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session run1
D="$ROOT/.craft/annotations/run1"
http POST "$PORT" /pins "[$(pin_json 1 a)]" >/dev/null
http POST "$PORT" /pins "[$(pin_json 1 b)]" >/dev/null
printf '.old{color:red}\n' > "$D/session.css"
OUT="$(run_in "$ROOT" begin --session run1 --subject "Hero polish")"
assert_eq "begin prints RUN 2" "RUN 2" "$OUT"
assert_eq "start_seq recorded" "2" "$(json_get "$D/run.json" 'd["start_seq"]')"
assert_eq "subject recorded" "Hero polish" "$(json_get "$D/run.json" 'd["subject"]')"
assert_contains "started_at is a UTC timestamp" '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z$' "$(json_get "$D/run.json" 'd["started_at"]')"
assert_eq "session.css emptied" "0" "$(wc -c < "$D/session.css" | tr -d ' ')"
rm -f "$D/current.json"
assert_eq "begin reads the max across current.json and history" "RUN 2" "$(run_in "$ROOT" begin --session run1)"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" begin --session nosuch >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "begin on an unknown session exits 1" "1" "$RC"

# lacks_literal <desc> <needle> <text> - literal absence assertion
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

# sheet_literal <apply-statement> - the decoded JSON string literal
sheet_literal() {
  python3 -c '
import json, sys
line = sys.argv[1]
start = line.index("textContent = ") + len("textContent = ")
end = line.rindex("; document.head")
sys.stdout.write(json.loads(line[start:end]))
' "$1"
}

begin_test "the apply statement's literal decodes to session.css byte-for-byte"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session sh1
D="$ROOT/.craft/annotations/sh1"
OUT="$(printf '.a{content:"\\201C;caf\xc3\xa9 \\\\ \x27q\x27";}\n/* semi; colon */\n' | run_in "$ROOT" sheet --session sh1 --add --key 101)"
assert_eq "one line printed" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "starts as a function" "() => {" "${OUT:0:7}"
assert_contains "finds or creates the session style" 'ca-session-css' "$OUT"
assert_contains "marks the style as injected" 'data-craft-annotate-injected' "$OUT"
assert_contains_literal "returns a status" "return 'APPLIED';" "$OUT"
assert_eq "ends as a function body, never invoked in place" "; }" "${OUT: -3}"
lacks_literal "never self-invoking" "})()" "$OUT"
sheet_literal "$OUT" > "$ROOT/decoded.css"
cmp -s "$ROOT/decoded.css" "$D/session.css" && echo "  PASS: literal equals the file" && PASS=$((PASS + 1)) || { echo "  FAIL: literal differs from the file"; FAIL=$((FAIL + 1)); }
assert_eq "literal is ASCII-escaped" "0" "$(printf '%s' "$OUT" | LC_ALL=C grep -c '[^ -~]' || true)"

begin_test "sheet --add appends a keyed block, the same key replaces in place, --drop removes it, output is one line"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session sh2
D="$ROOT/.craft/annotations/sh2"
printf '.a{color:red}\n' | run_in "$ROOT" sheet --session sh2 --add --key 1 >/dev/null
printf '.b{color:blue}' | run_in "$ROOT" sheet --session sh2 --add --key 2 >/dev/null
assert_eq "two keyed blocks" $'/* annotate-key 1 */\n.a{color:red}\n/* annotate-key 2 */\n.b{color:blue}' "$(cat "$D/session.css")"
OUT="$(printf '.a{color:green}\n' | run_in "$ROOT" sheet --session sh2 --add --key 1)"
assert_eq "replaced in place, order kept" $'/* annotate-key 1 */\n.a{color:green}\n/* annotate-key 2 */\n.b{color:blue}' "$(cat "$D/session.css")"
assert_eq "replace prints one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
OUT="$(run_in "$ROOT" sheet --session sh2 --drop 1)"
assert_eq "drop removes the block" $'/* annotate-key 2 */\n.b{color:blue}' "$(cat "$D/session.css")"
assert_eq "drop prints one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "drop of an absent key changes nothing" "$(cat "$D/session.css")" "$(run_in "$ROOT" sheet --session sh2 --drop 99 >/dev/null; cat "$D/session.css")"
OUT="$(run_in "$ROOT" sheet --session sh2)"
assert_eq "print-only decodes to the file" "$(cat "$D/session.css")" "$(sheet_literal "$OUT")"
OUT="$(run_in "$ROOT" sheet --session sh2 --drop 2)"
assert_eq "dropping the last block leaves an empty sheet" "0" "$(wc -c < "$D/session.css" | tr -d ' ')"
assert_eq "an empty sheet decodes to nothing" "" "$(sheet_literal "$OUT")"
set +e
printf '.a{}' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" sheet --session sh2 --add --key 'bad key' >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "an invalid key exits 1" "1" "$RC"

begin_test "sheet refuses CSS carrying the key header and leaves the file untouched"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session sh3
D="$ROOT/.craft/annotations/sh3"
printf '.a{color:red}\n' | run_in "$ROOT" sheet --session sh3 --add --key 1 >/dev/null
BEFORE="$(cat "$D/session.css")"
set +e
printf '.x{}\n/* annotate-key 7 */\n.y{}\n' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" sheet --session sh3 --add --key 2 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "refused with exit 1" "1" "$RC"
assert_eq "file untouched" "$BEFORE" "$(cat "$D/session.css")"

begin_test "send posts the stdin set; seq advances and history records it"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session snd1
D="$ROOT/.craft/annotations/snd1"
OUT="$(printf '[%s]' "$(pin_json 1 direct)" | run_in "$ROOT" send --session snd1)"
assert_contains "the listener's reply is printed" '"seq": 1' "$OUT"
assert_eq "history records it" "1" "$(hist_seqs "$ROOT" snd1)"
assert_eq "current.json carries the pin" "direct" "$(json_get "$D/current.json" 'd["pins"][0]["text"]')"
set +e
echo '{"not":"an array"}' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" send --session snd1 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "a non-array body is refused with exit 1" "1" "$RC"
LPID="$(cat "$D/listener.pid")"
kill "$LPID" 2>/dev/null || true
wait_dead "$LPID" || true
set +e
echo '[]' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" send --session snd1 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "an unreachable listener exits 1" "1" "$RC"

begin_test "status --all omits a record folder; sweep leaves a record folder that carries a dead owner.pid"
new_root; ROOT="$NEW_ROOT"
mkdir -p "$ROOT/.craft/annotations/2026-10-04-x" "$ROOT/.craft/annotations/live-1"
printf -- '---\nsource: annotate\n---\n' > "$ROOT/.craft/annotations/2026-10-04-x/record.md"
echo 999999 > "$ROOT/.craft/annotations/2026-10-04-x/owner.pid"
echo 999999 > "$ROOT/.craft/annotations/live-1/owner.pid"
OUT="$(run_in "$ROOT" status --all)"
assert_contains "the live folder is listed" '^live-1 ' "$OUT"
assert_not_contains "the record folder is not listed" '2026-10-04-x' "$OUT"
run_in "$ROOT" sweep >/dev/null
assert_file_exists "the record folder survives the sweep" "$ROOT/.craft/annotations/2026-10-04-x/record.md"
assert_eq "the dead live folder is reaped" "MISSING" "$(rd "$ROOT/.craft/annotations/live-1/owner.pid")"

# ---------------------------------------------------------------------------
# The served overlay, the loader line, and project vs external pages.

OVERLAY_REF="$REPO/commands/references/annotate-overlay.md"

# fence_of_ref <ref-file> - the overlay-source fence body, by an independent awk
fence_of_ref() {
  awk '
    $0 == "```overlay-source" {inside=1; next}
    inside && $0 == "```" {exit}
    inside {print}
  ' "$1"
}

begin_test "the loader line falls back when the script cannot load"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ldr1
LOADER="$(run_in "$ROOT" loader --session ldr1 --page http://localhost:3000/)"
assert_eq "exactly one line" "1" "$(printf '%s\n' "$LOADER" | wc -l | tr -d ' ')"
case "$LOADER" in "async () =>"*) STARTS=yes ;; *) STARTS=no ;; esac
assert_eq "starts with the async function head" "yes" "$STARTS"
case "$LOADER" in *")()") ENDS=iife ;; *) ENDS=function ;; esac
assert_eq "is never invoked in place" "function" "$ENDS"
assert_contains_literal "resolves SCRIPT-BLOCKED" "'SCRIPT-BLOCKED'" "$LOADER"
assert_contains_literal "resolves LOADED" "'LOADED'" "$LOADER"
assert_contains_literal "carries an error handler" "onerror" "$LOADER"
assert_contains_literal "gives up after 3000ms" "3000" "$LOADER"
assert_contains_literal "stamps the armed port" "window.__craftAnnotatePort = ${PORT:-none};" "$LOADER"
assert_contains_literal "loads the served script from the armed port" "http://127.0.0.1:${PORT:-none}/overlay.js" "$LOADER"
assert_contains_literal "returns at once when already installed" "window.__craftAnnotateInstalled" "$LOADER"
assert_contains_literal "marks the script as injected" "data-craft-annotate-injected" "$LOADER"
lacks_literal "never stamps the baked flag" "__craftAnnotateBaked" "$LOADER"
lacks_literal "never stamps a context" "__craftAnnotateContext" "$LOADER"

begin_test "GET /overlay.js serves the fence byte-for-byte"
FENCE_FILE="$(mktemp)"; BODY_FILE="$(mktemp)"; PRINT_FILE="$(mktemp)"
fence_of_ref "$OVERLAY_REF" > "$FENCE_FILE"
assert_not_eq "the reference fence is not empty" "0" "$(wc -c < "$FENCE_FILE" | tr -d ' ')"
RESP="$(curl -s -i --max-time 5 "http://127.0.0.1:${PORT:-0}/overlay.js" 2>/dev/null || true)"
assert_eq "status 200" "200" "$(status_of "$RESP")"
curl -s --max-time 5 -o "$BODY_FILE" "http://127.0.0.1:${PORT:-0}/overlay.js" 2>/dev/null || true
CMP_RC=0; cmp -s "$FENCE_FILE" "$BODY_FILE" || CMP_RC=$?
assert_eq "body equals the reference fence" "0" "$CMP_RC"

begin_test "the overlay route carries script, no-store and cross-origin headers"
assert_contains "content type" '^[Cc]ontent-[Tt]ype: text/javascript; charset=utf-8' "$RESP"
assert_contains "no-store" '^[Cc]ache-[Cc]ontrol: no-store' "$RESP"
assert_contains "cross-origin resource policy" '^[Cc]ross-[Oo]rigin-[Rr]esource-[Pp]olicy: cross-origin' "$RESP"
assert_contains "allow-origin" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$RESP"
assert_file_not_exists "serving the script wrote no history" "$ROOT/.craft/annotations/ldr1/history.jsonl"
assert_file_not_exists "serving the script wrote no current.json" "$ROOT/.craft/annotations/ldr1/current.json"

begin_test "--print-overlay prints the route's bytes"
PRINT_RC=0
python3 "$CHANNEL" --print-overlay > "$PRINT_FILE" 2>/dev/null || PRINT_RC=$?
assert_exit_code "exits 0" "0" "$PRINT_RC"
CMP_RC=0; cmp -s "$BODY_FILE" "$PRINT_FILE" || CMP_RC=$?
assert_eq "same bytes as the served body" "0" "$CMP_RC"
rm -f "$FENCE_FILE" "$BODY_FILE" "$PRINT_FILE"

begin_test "a listener with no reference answers 404 and --print-overlay exits 1"
ISO="$(mktemp -d)"; TMP_ROOTS+=("$ISO")
mkdir -p "$ISO/hooks/scripts" "$ISO/sess"
cp "$CHANNEL" "$ISO/hooks/scripts/annotate-channel.py"
python3 "$ISO/hooks/scripts/annotate-channel.py" --dir "$ISO/sess" > "$ISO/log" 2>&1 < /dev/null &
ISO_PID=$!
TMP_PIDS+=("$ISO_PID")
for _ in $(seq 1 50); do grep -q '^PORT ' "$ISO/log" 2>/dev/null && break; sleep 0.1; done
ISO_PORT="$(awk '/^PORT /{print $2; exit}' "$ISO/log")"
RESP="$(curl -s -i --max-time 5 "http://127.0.0.1:${ISO_PORT:-0}/overlay.js" 2>/dev/null || true)"
assert_eq "status 404" "404" "$(status_of "$RESP")"
assert_contains_literal "names the failure" '"error": "overlay source not found"' "$RESP"
PRINT_RC=0
PRINT_ERR="$(python3 "$ISO/hooks/scripts/annotate-channel.py" --print-overlay 2>&1 >/dev/null)" || PRINT_RC=$?
assert_exit_code "--print-overlay exits 1" "1" "$PRINT_RC"
assert_eq "one stderr line" "1" "$(printf '%s\n' "$PRINT_ERR" | wc -l | tr -d ' ')"
stop_job "$ISO_PID"
wait "$ISO_PID" 2>/dev/null || true

begin_test "kind classifies pages"
for U in http://localhost:3000/ http://127.0.0.1:5173/a/b https://localhost/ file:///tmp/mockup.html http://localhost; do
  assert_eq "project: $U" "project" "$(run_in "$ROOT" kind --page "$U")"
done
for U in https://example.com/ http://[::1]:3000/ http://127.0.0.2:3000/ http://app.localhost:3000/ http://localhost.example.com/ about:blank; do
  assert_eq "external: $U" "external" "$(run_in "$ROOT" kind --page "$U")"
done

begin_test "loader on an external page prints EXTERNAL"
assert_eq "an external page prints EXTERNAL" "EXTERNAL" "$(run_in "$ROOT" loader --session ldr1 --page https://example.com/app)"
kill "$(cat "$ROOT/.craft/annotations/ldr1/listener.pid")" 2>/dev/null || true
wait_dead "$(cat "$ROOT/.craft/annotations/ldr1/listener.pid")" || true
assert_eq "still EXTERNAL with the listener dead" "EXTERNAL" "$(run_in "$ROOT" loader --session ldr1 --page https://example.com/app)"
assert_eq "even for a session that does not exist" "EXTERNAL" "$(run_in "$ROOT" loader --session nosuch --page https://example.com/app)"

begin_test "loader exits 1 when the listener does not answer"
set +e
LOADER_ERR="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" loader --session ldr1 --page http://localhost:3000/ 2>&1 >/dev/null)"
RC=$?
LOADER_OUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" loader --session ldr1 --page http://localhost:3000/ 2>/dev/null)"
set -e
assert_exit_code "exit 1" "1" "$RC"
assert_contains_literal "stderr names the session" "annotate-run: listener for ldr1 is not answering" "$LOADER_ERR"
assert_eq "prints no loader" "" "$LOADER_OUT"

# ---------------------------------------------------------------------------
# The listener heals itself: wait wakes on a dead listener, ensure restarts it.

begin_test "wait wakes with UNREACHABLE when the listener dies"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session heal1
HEAL_DIR="$ROOT/.craft/annotations/heal1"
HEAL_PID="$(cat "$HEAL_DIR/listener.pid")"
HEAL_OUT="$(mktemp)"
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" wait --session heal1 --timeout 30 > "$HEAL_OUT" 2>/dev/null &
WAIT_PID=$!
TMP_PIDS+=("$WAIT_PID")
sleep 0.5
kill "$HEAL_PID" 2>/dev/null || true
for _ in $(seq 1 40); do kill -0 "$WAIT_PID" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$WAIT_PID" 2>/dev/null; then WOKE=no; stop_job "$WAIT_PID"; else WOKE=yes; wait "$WAIT_PID" 2>/dev/null || true; fi
wait "$WAIT_PID" 2>/dev/null || true
assert_eq "the wait woke within the poll window" "yes" "$WOKE"
assert_eq "it printed UNREACHABLE" "UNREACHABLE" "$(cat "$HEAL_OUT")"
rm -f "$HEAL_OUT"

begin_test "ensure restarts a dead listener on a new port, STREAK 1, owner kept"
OLD_PORT="$(cat "$HEAL_DIR/port")"
OWNER_BEFORE="$(cat "$HEAL_DIR/owner.pid")"
OUT="$(run_in "$ROOT" ensure --session heal1)"
case "$OUT" in "REARMED PORT "*" STREAK 1") SHAPE=yes ;; *) SHAPE="no: $OUT" ;; esac
assert_eq "REARMED with streak 1" "yes" "$SHAPE"
NEW_PORT="$(cat "$HEAL_DIR/port")"
assert_eq "the port file follows the print" "REARMED PORT $NEW_PORT STREAK 1" "$OUT"
assert_contains_literal "the new listener answers" '"ok"' "$(http GET "$NEW_PORT" /health)"
assert_eq "the owner is kept" "$OWNER_BEFORE" "$(cat "$HEAL_DIR/owner.pid")"
assert_eq "the streak is a file" "1" "$(cat "$HEAL_DIR/rearm.streak")"

begin_test "a POST after a re-arm advances past the old seq"
http POST "$NEW_PORT" /pins "[$(pin_json 1 first)]" >/dev/null
SEQ_A="$(json_get "$HEAL_DIR/current.json" "d['seq']")"
kill "$(cat "$HEAL_DIR/listener.pid")" 2>/dev/null || true
wait_dead "$(cat "$HEAL_DIR/listener.pid")" || true
run_in "$ROOT" ensure --session heal1 >/dev/null
http POST "$(cat "$HEAL_DIR/port")" /pins "[$(pin_json 2 second)]" >/dev/null
SEQ_B="$(json_get "$HEAL_DIR/current.json" "d['seq']")"
assert_eq "the seq continues past the old listener's" "yes" "$([ "$SEQ_B" -gt "$SEQ_A" ] 2>/dev/null && echo yes || echo "no: $SEQ_A $SEQ_B")"

begin_test "ensure reports a streak of 2 on a second consecutive failure"
# Two re-arms above (one per kill) with no OK in between.
assert_eq "the streak counts both" "2" "$(cat "$HEAL_DIR/rearm.streak")"
kill "$(cat "$HEAL_DIR/listener.pid")" 2>/dev/null || true
wait_dead "$(cat "$HEAL_DIR/listener.pid")" || true
OUT="$(run_in "$ROOT" ensure --session heal1)"
case "$OUT" in *" STREAK 3") S3=yes ;; *) S3="no: $OUT" ;; esac
assert_eq "a third failure keeps counting" "yes" "$S3"

begin_test "ensure prints OK and resets the streak on a live listener"
OUT="$(run_in "$ROOT" ensure --session heal1)"
assert_eq "OK with the port" "OK PORT $(cat "$HEAL_DIR/port")" "$OUT"
assert_eq "the streak is back to 0" "0" "$(cat "$HEAL_DIR/rearm.streak")"

begin_test "ensure replaces a hung listener"
HUNG_PID="$(cat "$HEAL_DIR/listener.pid")"
kill -STOP "$HUNG_PID"
OUT="$(run_in "$ROOT" ensure --session heal1)"
case "$OUT" in "REARMED PORT "*" STREAK 1") HUNG=yes ;; *) HUNG="no: $OUT" ;; esac
kill -CONT "$HUNG_PID" 2>/dev/null || true
assert_eq "REARMED at streak 1" "yes" "$HUNG"
wait_dead "$HUNG_PID" || true
assert_eq "the hung listener is gone" "no" "$(is_running "$HUNG_PID" && echo yes || echo no)"

begin_test "ensure never signals a recycled pid that is not a listener"
SLEEPER_PID="$(sleep 60 >/dev/null 2>&1 & echo $!)"
TMP_PIDS+=("$SLEEPER_PID")
kill "$(cat "$HEAL_DIR/listener.pid")" 2>/dev/null || true
wait_dead "$(cat "$HEAL_DIR/listener.pid")" || true
echo "$SLEEPER_PID" > "$HEAL_DIR/listener.pid"
run_in "$ROOT" ensure --session heal1 >/dev/null
assert_eq "the unrelated process survives" "yes" "$(is_running "$SLEEPER_PID" && echo yes || echo no)"
kill "$SLEEPER_PID" 2>/dev/null || true

begin_test "ensure on a missing session folder prints GONE and creates nothing"
set +e
OUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" ensure --session nosuch 2>/dev/null)"
RC=$?
set -e
assert_eq "prints GONE" "GONE" "$OUT"
assert_exit_code "exit 1" "1" "$RC"
assert_file_not_exists "no folder was created" "$ROOT/.craft/annotations/nosuch"

# ---------------------------------------------------------------------------
# change stream, sheet route, page reports and the change log

# open_changes <port> <out-prefix> - holds GET /changes with curl -N
open_changes() {
  curl -s -N -D "$2.hdr" -H 'Origin: null' "http://127.0.0.1:$1/changes" >"$2.body" 2>/dev/null &
  STREAM_PID=$!
  TMP_PIDS+=("$STREAM_PID")
}

# change_kinds <root> <sid> - "kind:ts" for every change line, space separated
change_kinds() {
  python3 -c '
import json, sys
out = []
for l in open(sys.argv[1]):
    try:
        c = json.loads(l)
    except ValueError:
        continue
    out.append(c["kind"] + ":" + str(c.get("ts", "")))
print(" ".join(out))
' "$1/.craft/annotations/$2/changes.jsonl" 2>/dev/null || echo MISSING
}

cpin() { # <ts> <page> <text>
  printf '{"n":1,"text":"%s","x":1,"y":2,"selector":"div.a","nearText":"n","ts":%s,"page":"%s"}' "$3" "$1" "$2"
}

begin_test "a GET /changes stream is invisible to /health and to announce"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
open_changes "$PORT" "$ROOT/c1"
if wait_for_text "$ROOT/c1.body" ": connected"; then echo "  PASS: the change stream greets"; PASS=$((PASS + 1)); else echo "  FAIL: no greeting on /changes"; FAIL=$((FAIL + 1)); fi
assert_contains "event-stream content type" '^[Cc]ontent-[Tt]ype: text/event-stream' "$(cat "$ROOT/c1.hdr" 2>/dev/null || true)"
assert_eq "health counts only /events streams" "0" "$(clients_of "$PORT")"
assert_contains "announce delivers to nobody" '"delivered": 0' "$(http POST "$PORT" /announce)"
sleep 0.6
assert_not_contains "the change stream never sees a reload" 'event: reload' "$(cat "$ROOT/c1.body" 2>/dev/null || true)"

begin_test "GET /session.css serves the sheet byte-for-byte with the CORS headers, and an absent sheet serves an empty 200"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
SD="$ROOT/.craft/annotations/$SID"
rm -f "$SD/session.css"
RESP="$(http GET "$PORT" /session.css)"
assert_eq "absent sheet is 200" "200" "$(status_of "$RESP")"
assert_eq "absent sheet body is empty" "0" "$(curl -s --max-time 5 "http://127.0.0.1:$PORT/session.css" | wc -c | tr -d ' ')"
printf '/* annotate-key 7 */\n.a { color: red; }\n/* caf\xc3\xa9 */\n' > "$SD/session.css"
curl -s --max-time 5 "http://127.0.0.1:$PORT/session.css" > "$ROOT/served.css"
assert_eq "served bytes equal the file" "$(shasum "$SD/session.css" | awk '{print $1}')" "$(shasum "$ROOT/served.css" | awk '{print $1}')"
RESP="$(http GET "$PORT" /session.css)"
assert_contains "css content type" '^[Cc]ontent-[Tt]ype: text/css; charset=utf-8' "$RESP"
assert_contains "allow-origin star" '^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: \*' "$RESP"
assert_contains "no-store" '^[Cc]ache-[Cc]ontrol: no-store' "$RESP"
assert_contains "cross-origin resource policy" '^[Cc]ross-[Oo]rigin-[Rr]esource-[Pp]olicy: cross-origin' "$RESP"

begin_test "POST /sheet reaches a held /changes stream and reports delivered; a held /events stream receives nothing"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
assert_contains "no stream: delivered 0" '"delivered": 0' "$(http POST "$PORT" /sheet '{"id":"a0","measure":[],"targets":[]}')"
open_changes "$PORT" "$ROOT/c1"
open_stream "$PORT" "$ROOT/e1"
wait_clients "$PORT" 1 >/dev/null || true
wait_for_text "$ROOT/c1.body" ": connected" >/dev/null || true
RESP="$(http POST "$PORT" /sheet '{"id":"a1","measure":["101"],"targets":[{"ts":101,"selector":".x"}]}')"
assert_eq "sheet is 200" "200" "$(status_of "$RESP")"
assert_contains "one stream got it" '"delivered": 1' "$RESP"
if wait_for_text "$ROOT/c1.body" "event: sheet"; then echo "  PASS: the change stream received the sheet event"; PASS=$((PASS + 1)); else echo "  FAIL: no sheet event"; FAIL=$((FAIL + 1)); fi
assert_contains "the event carries the job" '"id": "a1"' "$(cat "$ROOT/c1.body" 2>/dev/null || true)"
sleep 0.5
assert_not_contains "the /events stream received nothing" 'event: sheet' "$(cat "$ROOT/e1.body" 2>/dev/null || true)"
assert_eq "no id is 400" "400" "$(status_of "$(http POST "$PORT" /sheet '{"measure":[]}')")"
assert_eq "an array body is 400" "400" "$(status_of "$(http POST "$PORT" /sheet '[1]')")"
assert_eq "a non-JSON body is 400" "400" "$(status_of "$(http POST "$PORT" /sheet 'nope')")"

begin_test "GET /applied returns a report posted after the wait began, and times out with 404 when none comes"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
( sleep 1; http POST "$PORT" /applied '{"id":"r1","page":"http://localhost/x","blocks":{},"probes":[]}' >/dev/null ) &
LATE_PID=$!
TMP_PIDS+=("$LATE_PID")
RESP="$(curl -s -i --max-time 8 "http://127.0.0.1:$PORT/applied?id=r1&wait=5" 2>/dev/null || true)"
assert_eq "the late report is delivered" "200" "$(status_of "$RESP")"
assert_contains "the report body is the posted JSON" '"page": "http://localhost/x"' "$RESP"
assert_eq "a held report is returned at once" "200" "$(status_of "$(http GET "$PORT" '/applied?id=r1&wait=1')")"
http POST "$PORT" /applied '{"id":"r1","page":"http://localhost/second","blocks":{},"probes":[]}' >/dev/null
assert_contains "the first report for an id wins" '"page": "http://localhost/x"' "$(http GET "$PORT" '/applied?id=r1&wait=1')"
RESP="$(curl -s -i --max-time 8 "http://127.0.0.1:$PORT/applied?id=none&wait=1" 2>/dev/null || true)"
assert_eq "no report times out with 404" "404" "$(status_of "$RESP")"
assert_contains "the 404 says why" '"error": "no report"' "$RESP"
assert_eq "a report without an id is 400" "400" "$(status_of "$(http POST "$PORT" /applied '{"page":"p"}')")"

begin_test "an object SEND stores pins and deleted, merges probes into probes.json, and probes.json is on disk before the change line"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
SD="$ROOT/.craft/annotations/$SID"
BODY='{"pins":['"$(cpin 11 http://localhost/a hello)"'],"deleted":[5],"probes":[{"page":"http://localhost/a","ts":11,"selector":".n","found":true,"component":null,"inline":false,"blocked":[],"rules":[]}]}'
RESP="$(http POST "$PORT" /pins "$BODY")"
assert_eq "object body is 200" "200" "$(status_of "$RESP")"
assert_eq "current.json holds the pins" "1" "$(json_get "$SD/current.json" 'len(d["pins"])')"
assert_eq "current.json carries deleted" "[5]" "$(json_get "$SD/current.json" 'd["deleted"]')"
assert_eq "history carries deleted" "[5]" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["deleted"])' "$SD/history.jsonl")"
assert_eq "probes.json keyed by ts" ".n" "$(json_get "$SD/probes.json" 'd["11"]["selector"]')"
http POST "$PORT" /pins '{"pins":[],"probes":[{"page":"http://localhost/a","ts":11,"selector":".m","found":true,"component":null,"inline":false,"blocked":[],"rules":[]},{"page":"http://localhost/a","ts":12,"selector":".o","found":false,"component":null,"inline":false,"blocked":[],"rules":[]}]}' >/dev/null
assert_eq "an incoming item replaces its ts" ".m" "$(json_get "$SD/probes.json" 'd["11"]["selector"]')"
assert_eq "other ts items are kept" ".o" "$(json_get "$SD/probes.json" 'd["12"]["selector"]')"
http POST "$PORT" /pins "[$(cpin 13 http://localhost/a plain)]" >/dev/null
assert_eq "an array body writes no deleted key" "False" "$(json_get "$SD/current.json" '"deleted" in d')"
assert_eq "an object without a pins array stays 400" "400" "$(status_of "$(http POST "$PORT" /pins '{"n":1}')")"
assert_eq "a non-array pins value is 400" "400" "$(status_of "$(http POST "$PORT" /pins '{"pins":"x"}')")"
SRC="$(cat "$CHANNEL")"
POS_PROBES="$(printf '%s' "$SRC" | grep -n 'merge_probes(' | tail -1 | cut -d: -f1)"
POS_STATE="$(printf '%s' "$SRC" | grep -n 'self.server.replace_state(' | head -1 | cut -d: -f1)"
if [ -n "$POS_PROBES" ] && [ -n "$POS_STATE" ] && [ "$POS_PROBES" -lt "$POS_STATE" ]; then echo "  PASS: probes are merged before replace_state is called"; PASS=$((PASS + 1)); else echo "  FAIL: probes merge does not precede replace_state"; FAIL=$((FAIL + 1)); fi

begin_test "two SENDs with different pins append two added lines; a resent identical SEND appends nothing"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
SD="$ROOT/.craft/annotations/$SID"
A="http://localhost/a"
http POST "$PORT" /pins "[$(cpin 1 $A x)]" >/dev/null
assert_eq "one added" "added:1" "$(change_kinds "$ROOT" "$SID")"
assert_eq "the change carries the page, the seq and the pin" "True" "$(python3 -c '
import json, sys
c = json.loads(open(sys.argv[1]).readline())
print(c["page"] == "http://localhost/a" and c["seq"] == 1 and c["pin"]["text"] == "x" and c["ts"] == "1")
' "$SD/changes.jsonl")"
http POST "$PORT" /pins "[$(cpin 1 $A x),$(cpin 2 $A y)]" >/dev/null
assert_eq "the second SEND adds only the new pin" "added:1 added:2" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /pins "[$(cpin 1 $A x),$(cpin 2 $A y)]" >/dev/null
assert_eq "a resent identical SEND appends nothing" "added:1 added:2" "$(change_kinds "$ROOT" "$SID")"
assert_eq "history still advanced for the resent SEND" "1 2 3" "$(hist_seqs "$ROOT" "$SID")"
http POST "$PORT" /pins "[$(cpin 5 $A a),$(cpin 6 $A b)]" >/dev/null
assert_eq "two new pins in one SEND are one write of two lines" "added:1 added:2 added:5 added:6" "$(change_kinds "$ROOT" "$SID")"
assert_eq "both lines of one write share its seq" "4 4" "$(python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(" ".join(str(r["seq"]) for r in rows[-2:]))
' "$SD/changes.jsonl")"
http POST "$PORT" /pins "[{\"text\":\"no page\",\"ts\":9},{\"text\":\"no ts\",\"page\":\"$A\"}]" >/dev/null
assert_eq "a pin without a page or a usable ts makes no change" "added:1 added:2 added:5 added:6" "$(change_kinds "$ROOT" "$SID")"

begin_test "a changed text appends edited; a deleted ts appends once, and neither a resent delete nor a re-posted deleted pin appends again; CLEAR appends one cleared"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
SD="$ROOT/.craft/annotations/$SID"
A="http://localhost/a"
http POST "$PORT" /pins "[$(cpin 1 $A x)]" >/dev/null
http POST "$PORT" /pins "[$(cpin 1 $A y)]" >/dev/null
assert_eq "an edit" "added:1 edited:1" "$(change_kinds "$ROOT" "$SID")"
assert_eq "the edited change carries the new pin" "y" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["pin"]["text"])' "$SD/changes.jsonl")"
http POST "$PORT" /pins '{"pins":[],"deleted":[1]}' >/dev/null
assert_eq "a delete of a live ts" "added:1 edited:1 deleted:1" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /pins '{"pins":[],"deleted":[1]}' >/dev/null
assert_eq "a resent delete appends nothing" "added:1 edited:1 deleted:1" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /pins "[$(cpin 1 $A y)]" >/dev/null
http POST "$PORT" /pins "[$(cpin 1 $A z)]" >/dev/null
assert_eq "a deleted pin re-posted by a second tab appends nothing" "added:1 edited:1 deleted:1" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /pins '{"pins":[],"deleted":[77,"88"]}' >/dev/null
assert_eq "a delete naming no live entry appends nothing" "added:1 edited:1 deleted:1" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /pins "[$(cpin 3 http://localhost/b q)]" >/dev/null
http POST "$PORT" /pins '{"pins":[],"deleted":["3"]}' >/dev/null
assert_eq "a string ts meets the number it was logged under" "added:1 edited:1 deleted:1 added:3 deleted:3" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /clear >/dev/null
assert_eq "CLEAR appends one cleared" "added:1 edited:1 deleted:1 added:3 deleted:3 cleared:" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /pins "[$(cpin 4 $A w)]" >/dev/null
http POST "$PORT" /pins "[$(cpin 4 $A w)]" >/dev/null
assert_eq "after CLEAR a new pin is added once and CLEAR left the map alone" "added:1 edited:1 deleted:1 added:3 deleted:3 cleared: added:4" "$(change_kinds "$ROOT" "$SID")"
http POST "$PORT" /pins "[$(cpin 1 $A z)]" >/dev/null
assert_eq "a pin logged before CLEAR with the same text appends nothing" "added:1 edited:1 deleted:1 added:3 deleted:3 cleared: added:4" "$(change_kinds "$ROOT" "$SID")"

begin_test "a restarted listener folds the log and appends nothing for a set it already logged"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
SD="$ROOT/.craft/annotations/$SID"
A="http://localhost/a"
http POST "$PORT" /pins "[$(cpin 1 $A x),$(cpin 2 $A y)]" >/dev/null
http POST "$PORT" /pins '{"pins":[],"deleted":[2]}' >/dev/null
OLD_PID="$(cat "$SD/listener.pid")"
kill "$OLD_PID" 2>/dev/null || true
wait_dead "$OLD_PID" || true
printf '{"seq": 9, "kind": "added", "pa' >> "$SD/changes.jsonl"
OUT="$(run_in "$ROOT" ensure --session "$SID")"
case "$OUT" in "REARMED PORT "*) RE=yes ;; *) RE="no: $OUT" ;; esac
assert_eq "the listener was replaced" "yes" "$RE"
NEWPORT="$(cat "$SD/port")"
http POST "$NEWPORT" /pins "[$(cpin 1 $A x)]" >/dev/null
http POST "$NEWPORT" /pins '{"pins":[],"deleted":[2]}' >/dev/null
http POST "$NEWPORT" /pins "[$(cpin 2 $A y)]" >/dev/null
assert_eq "nothing re-delivered after the restart" "added:1 added:2 deleted:2" "$(change_kinds "$ROOT" "$SID")"
http POST "$NEWPORT" /pins "[$(cpin 7 $A n)]" >/dev/null
assert_contains "a genuinely new pin still arrives" 'added:7$' "$(change_kinds "$ROOT" "$SID")"

begin_test "array bodies, the non-JSON 400 and the {\"n\":1} 400 are unchanged"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT"
SD="$ROOT/.craft/annotations/$SID"
RESP="$(http POST "$PORT" /pins "[$(cpin 1 http://localhost/a x)]")"
assert_eq "array body is 200" "200" "$(status_of "$RESP")"
assert_contains "reply keeps seq and count" '"count": 1' "$RESP"
assert_eq "current.json shape is unchanged" "cleared,pins,seq,sent_at" "$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys(), key=lambda k: ["cleared","pins","seq","sent_at"].index(k))))' "$SD/current.json")"
assert_eq "non-JSON is 400" "400" "$(status_of "$(http POST "$PORT" /pins 'not json')")"
assert_eq "{n:1} is 400" "400" "$(status_of "$(http POST "$PORT" /pins '{"n":1}')")"
assert_eq "the rejected bodies appended no change" "added:1" "$(change_kinds "$ROOT" "$SID")"

# ---------------------------------------------------------------------------
# apply: one command writes the blocks, pushes the page and prints its measurement

# apply_with_page <root> <sid> <port> <blocks> <report-json> [apply args...]
# A fake page holds /changes, reads the job id from the sheet event it receives
# and posts <report-json> (its __ID__ replaced by that id). Sets APPLY_OUT.
APPLY_N=0
apply_with_page() {
  local root="$1" sid="$2" port="$3" blocks="$4" report="$5" jid body apid cpid
  shift 5
  APPLY_N=$((APPLY_N + 1))
  open_changes "$port" "$root/ap$APPLY_N"
  cpid="$STREAM_PID"
  wait_for_text "$root/ap$APPLY_N.body" ": connected" >/dev/null || true
  ( printf '%s' "$blocks" | CRAFT_PROJECT_ROOT="$root" bash "$RUN" apply --session "$sid" "$@" >"$root/ap$APPLY_N.out" 2>/dev/null ) &
  apid=$!
  TMP_PIDS+=("$apid")
  if wait_for_text "$root/ap$APPLY_N.body" "event: sheet"; then
    jid="$(sed -n 's/^data: .*"id": "\([^"]*\)".*/\1/p' "$root/ap$APPLY_N.body" | head -1)"
    body="${report//__ID__/$jid}"
    http POST "$port" /applied "$body" >/dev/null
  fi
  wait "$apid" 2>/dev/null || true
  stop_job "$cpid"
  APPLY_OUT="$(cat "$root/ap$APPLY_N.out")"
}

PAGE_X='"page":"http://localhost/x","view":{"x":0,"y":0,"w":800,"h":600},"pageSize":{"w":800,"h":2000}'

begin_test "apply round trip prints what the page measured"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ap1
D="$ROOT/.craft/annotations/ap1"
apply_with_page "$ROOT" ap1 "$PORT" $'/* annotate-key 101 */\n.a{color:red}\n' \
  '{"id":"__ID__",'"$PAGE_X"',"blocks":{"101":[{"selector":".a","matched":1,"values":{"color":"rgb(255, 0, 0)"},"box":{"x":0,"y":0,"w":100,"h":20},"top":true,"inView":true,"container":false}]},"probes":[]}'
assert_eq "the block is in the file" $'/* annotate-key 101 */\n.a{color:red}' "$(cat "$D/session.css")"
assert_eq "line 1 is the page, the view and the page size" "APPLIED http://localhost/x view 0,0 800x600 page 800x2000" "$(printf '%s\n' "$APPLY_OUT" | sed -n 1p)"
assert_eq "line 2 is the measured rule" "101 .a x1 box 0,0 100x20 visible: color rgb(255, 0, 0)" "$(printf '%s\n' "$APPLY_OUT" | sed -n 2p)"
assert_eq "a plain color change prints nothing else" "2" "$(printf '%s\n' "$APPLY_OUT" | wc -l | tr -d ' ')"

begin_test "apply prints SHOT for layout, stacking on a container, drawn content, covered, zero-size, off-screen, out of view and matched nothing, and no SHOT for plain values"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ap2
BLOCKS=""
for k in 201 202 203 204 205 206 207 208 209 210 211 212 213; do BLOCKS="$BLOCKS"$'/* annotate-key '"$k"$' */\n.k'"$k"$'{color:red}\n'; done
REPORT='{"id":"__ID__",'"$PAGE_X"',"blocks":{
"201":[{"selector":".panel","matched":1,"values":{"background-color":"rgb(0, 0, 0)"},"box":{"x":0,"y":0,"w":400,"h":320},"top":true,"inView":true,"container":true}],
"202":[{"selector":".card","matched":1,"values":{"color":"red"},"box":{"x":10,"y":10,"w":50,"h":50},"top":false,"inView":true,"coveredBy":"div.cover","container":false}],
"203":[{"selector":".n::after","matched":1,"values":{"content":"\"Ada\""},"box":{"x":10,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":false}],
"204":[{"selector":".z","matched":1,"values":{"color":"red"},"box":{"x":10,"y":10,"w":0,"h":50},"top":true,"inView":true,"container":false}],
"205":[{"selector":".gone","matched":0,"values":{}}],
"206":[{"selector":".p","matched":1,"values":{"padding-top":"8px","margin-left":"2px","font-size":"14px"},"box":{"x":10,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":true}],
"207":[{"selector":".f","matched":1,"values":{"color":"red"},"box":{"x":10,"y":1500,"w":50,"h":50},"top":null,"inView":false,"container":false}],
"208":[{"selector":".g","matched":1,"values":{"color":"red"},"box":{"x":10,"y":10,"w":50,"h":50},"top":null,"inView":true,"container":false}],
"209":[{"selector":".off","matched":1,"values":{"color":"red"},"box":{"x":5000,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":false}],
"210":[{"selector":".l","matched":1,"values":{"display":"grid","grid-template-columns":"1fr 1fr"},"box":{"x":10,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":false}],
"211":[{"selector":".leaf","matched":1,"values":{"background-color":"rgb(0, 0, 0)"},"box":{"x":10,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":false}],
"212":[{"selector":".z2","matched":1,"values":{"z-index":"5"},"box":{"x":10,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":false}],
"213":[{"selector":".m","matched":1,"values":{"max-width":"10px"},"box":{"x":10,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":false},{"selector":".m2","matched":1,"values":{"content":"x"},"box":{"x":10,"y":10,"w":50,"h":50},"top":true,"inView":true,"container":false}]
},"probes":[]}'
apply_with_page "$ROOT" ap2 "$PORT" "$BLOCKS" "$REPORT"
SHOTS="$(printf '%s\n' "$APPLY_OUT" | grep '^SHOT ' | tr '\n' '|')"
assert_eq "exactly the flagged keys, with their reasons" "SHOT 201 stacking|SHOT 202 covered|SHOT 203 drawn content|SHOT 204 zero-size|SHOT 205 matched nothing|SHOT 207 out of view|SHOT 209 off-screen|SHOT 210 layout|SHOT 212 stacking|SHOT 213 layout, drawn content|" "$SHOTS"
assert_contains_literal "a covered rule names what covers it" "202 .card x1 box 10,10 50x50 covered by div.cover: color red" "$APPLY_OUT"
assert_contains_literal "a rule that matched nothing is one short line" "205 .gone x0" "$APPLY_OUT"
assert_contains_literal "out of view is the visibility word" "207 .f x1 box 10,1500 50x50 out of view: color red" "$APPLY_OUT"
assert_contains_literal "an element that cannot be hit-tested says so" "208 .g x1 box 10,10 50x50 not checked: color red" "$APPLY_OUT"
assert_contains_literal "plain values list every property" "206 .p x1 box 10,10 50x50 visible: padding-top 8px; margin-left 2px; font-size 14px" "$APPLY_OUT"
SHOT_LINES="$(printf '%s\n' "$APPLY_OUT" | grep -n '^SHOT ' | head -1 | cut -d: -f1)"
LAST_RULE="$(printf '%s\n' "$APPLY_OUT" | grep -n '^213 ' | tail -1 | cut -d: -f1)"
assert_eq "SHOT lines follow every rule line" "True" "$([ "$SHOT_LINES" -gt "$LAST_RULE" ] && echo True || echo False)"

begin_test "apply cuts a measured value at 120 characters"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ap3
LONG="$(python3 -c 'print("v" * 300)')"
apply_with_page "$ROOT" ap3 "$PORT" $'/* annotate-key 1 */\n.a{color:red}\n' \
  '{"id":"__ID__",'"$PAGE_X"',"blocks":{"1":[{"selector":".a","matched":1,"values":{"font-family":"'"$LONG"'"},"box":{"x":0,"y":0,"w":10,"h":10},"top":true,"inView":true,"container":false}]},"probes":[]}'
assert_eq "the value is 120 characters" "120" "$(printf '%s\n' "$APPLY_OUT" | sed -n 2p | sed 's/.*font-family //' | tr -d '\n' | wc -c | tr -d ' ')"

begin_test "apply with no listening page prints PASTE and a literal that decodes to session.css"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ap4
D="$ROOT/.craft/annotations/ap4"
OUT="$(printf '/* annotate-key 9 */\n.a{content:"caf\xc3\xa9";}\n' | run_in "$ROOT" apply --session ap4)"
assert_eq "line 1 is PASTE" "PASTE" "$(printf '%s\n' "$OUT" | sed -n 1p)"
assert_eq "two lines" "2" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "line 2 is the sheet function" "() => {" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -c1-7)"
LINE2="$(printf '%s\n' "$OUT" | sed -n 2p)"
cmp -s <(sheet_literal "$LINE2") "$D/session.css" && echo "  PASS: the literal equals the file" && PASS=$((PASS + 1)) || { echo "  FAIL: the literal differs from the file"; FAIL=$((FAIL + 1)); }
assert_eq "identical to what sheet prints" "$(run_in "$ROOT" sheet --session ap4)" "$LINE2"

begin_test "apply falls to PASTE when the page reports an error, and exits 0"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ap5
apply_with_page "$ROOT" ap5 "$PORT" $'/* annotate-key 1 */\n.a{color:red}\n' \
  '{"id":"__ID__","page":"http://localhost/x","error":"fetch failed","blocks":{},"probes":[]}'
assert_eq "PASTE first" "PASTE" "$(printf '%s\n' "$APPLY_OUT" | sed -n 1p)"
set +e
printf '' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" apply --session ap5 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "an outcome without a page exits 0" "0" "$RC"

begin_test "apply takes several keyed blocks and drops in one call; refused input leaves the file untouched"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ap6
D="$ROOT/.craft/annotations/ap6"
printf '.old{color:red}\n' | run_in "$ROOT" sheet --session ap6 --add --key 5 >/dev/null
printf '.keep{color:blue}\n' | run_in "$ROOT" sheet --session ap6 --add --key 6 >/dev/null
apply_with_page "$ROOT" ap6 "$PORT" $'/* annotate-key 7 */\n.a{color:red}\n/* annotate-key 8 */\n.b{color:green}\n' \
  '{"id":"__ID__",'"$PAGE_X"',"blocks":{},"probes":[]}' --drop 5 --drop 99
printf '%s\n' "$APPLY_OUT" > "$ROOT/out6"
assert_eq "drops removed, blocks appended in order" $'/* annotate-key 6 */\n.keep{color:blue}\n/* annotate-key 7 */\n.a{color:red}\n/* annotate-key 8 */\n.b{color:green}' "$(cat "$D/session.css")"
assert_contains_literal "each drop is reported" "5 dropped" "$(cat "$ROOT/out6")"
assert_contains_literal "a drop of an absent key is reported too" "99 dropped" "$(cat "$ROOT/out6")"
printf '/* annotate-key 7 */\n.a{color:black}\n' | run_in "$ROOT" apply --session ap6 >/dev/null
assert_eq "an existing key is replaced in place" $'/* annotate-key 6 */\n.keep{color:blue}\n/* annotate-key 7 */\n.a{color:black}\n/* annotate-key 8 */\n.b{color:green}' "$(cat "$D/session.css")"
BEFORE="$(cat "$D/session.css")"
set +e
printf 'stray text\n/* annotate-key 9 */\n.x{}\n' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" apply --session ap6 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "text before the first header exits 1" "1" "$RC"
assert_eq "and the file is untouched" "$BEFORE" "$(cat "$D/session.css")"
set +e
printf '/* annotate-key bad key */\n.x{}\n' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" apply --session ap6 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "an invalid key exits 1" "1" "$RC"
assert_eq "the file is untouched again" "$BEFORE" "$(cat "$D/session.css")"
set +e
printf '' | CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" apply --session ap6 --drop 'bad key' >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "an invalid drop key exits 1" "1" "$RC"

begin_test "apply --target maps the pin to the ancestor's resolution"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ap7
D="$ROOT/.craft/annotations/ap7"
http POST "$PORT" /pins "[$(cpin 111 http://localhost:5173/ x)]" >/dev/null
apply_with_page "$ROOT" ap7 "$PORT" $'/* annotate-key 111 */\n.card{color:red}\n' \
  '{"id":"__ID__","page":"http://localhost:5173/",'"$(printf '%s' '"view":{"x":0,"y":0,"w":800,"h":600},"pageSize":{"w":800,"h":600}')"',"blocks":{"111":[{"selector":".card","matched":1,"values":{"color":"red"},"box":{"x":0,"y":0,"w":10,"h":10},"top":true,"inView":true,"container":false}]},"probes":[{"page":"http://localhost:5173/","ts":111,"selector":".card","found":true,"component":null,"inline":false,"blocked":[],"rules":[]}]}' \
  --target "111=.card"
assert_eq "the pin maps to the ancestor" ".card" "$(json_get "$D/resolutions.json" 'd["pins"]["http://localhost:5173/"]["111"]')"
assert_not_contains "nothing about the resolution is printed" 'resolv' "$APPLY_OUT"

begin_test "loader --run stamps the run id before the install check; without it the line is unchanged"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session ld2
run_in "$ROOT" begin --session ld2 --subject t >/dev/null
RUNID="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("%d@%s" % (r["start_seq"], r["started_at"]))' "$ROOT/.craft/annotations/ld2/run.json")"
PLAIN="$(run_in "$ROOT" loader --session ld2 --page http://localhost:3000/)"
STAMPED="$(run_in "$ROOT" loader --run --session ld2 --page http://localhost:3000/)"
assert_eq "the plain line carries no run stamp" "0" "$(printf '%s' "$PLAIN" | grep -c '__craftAnnotateRun' || true)"
assert_contains_literal "the plain line is the dial line" "async () => { window.__craftAnnotatePort = $PORT; if (window.__craftAnnotateInstalled) return 'LOADED'; try {" "$PLAIN"
assert_contains_literal "the stamp follows the port stamp" "window.__craftAnnotatePort = $PORT; window.__craftAnnotateRun = \"$RUNID\"; if (window.__craftAnnotateInstalled)" "$STAMPED"
assert_eq "removing the stamp gives the plain line" "$PLAIN" "$(printf '%s' "$STAMPED" | sed "s/window.__craftAnnotateRun = \"$RUNID\"; //")"
assert_eq "still one line" "1" "$(printf '%s\n' "$STAMPED" | wc -l | tr -d ' ')"
rm -f "$ROOT/.craft/annotations/ld2/run.json"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" loader --run --session ld2 --page http://localhost:3000/ >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "--run with no run.json exits 1" "1" "$RC"

begin_test "stamp prints both stamps; begin removes probes.json"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session st1
D="$ROOT/.craft/annotations/st1"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" stamp --session st1 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "stamp without run.json exits 1" "1" "$RC"
run_in "$ROOT" begin --session st1 --subject t >/dev/null
RUNID="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("%d@%s" % (r["start_seq"], r["started_at"]))' "$D/run.json")"
assert_eq "the stamp function" "() => { window.__craftAnnotatePort = $PORT; window.__craftAnnotateRun = \"$RUNID\"; return 'STAMPED'; }" "$(run_in "$ROOT" stamp --session st1)"
echo '{}' > "$D/probes.json"
run_in "$ROOT" begin --session st1 --subject t >/dev/null
assert_file_not_exists "begin removed the earlier run's probes" "$D/probes.json"

# ---------------------------------------------------------------------------
# watch: changes from a saved position

# start_watch <root> <sid> <out-file> [extra args...] - sets WATCH_PID; the pid is recorded for cleanup
start_watch() {
  local root="$1" sid="$2" out="$3"
  shift 3
  CRAFT_PROJECT_ROOT="$root" bash "$RUN" watch --session "$sid" "$@" >"$out" 2>/dev/null &
  WATCH_PID=$!
  TMP_PIDS+=("$WATCH_PID")
}

# wait_lines <file> <count> - bounded poll until the file holds that many lines
wait_lines() {
  local i=0
  while [ "$(wc -l < "$1" 2>/dev/null | tr -d ' ')" -lt "$2" ] && [ "$i" -lt 40 ]; do
    sleep 0.25; i=$((i + 1))
  done
  [ "$(wc -l < "$1" 2>/dev/null | tr -d ' ')" -ge "$2" ]
}

# cursor_of <dir> - the saved position, or MISSING
cursor_of() { rd "$1/watch.cursor" | tr -d '\n'; }

# size_of <file> - byte size, 0 when absent
size_of() { wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

# probe_item <ts> <page> <selector> - one probe item for the pin's ts
probe_item() {
  printf '{"page":"%s","ts":%s,"selector":"%s","found":true,"component":null,"inline":false,"blocked":[],"rules":[]}' "$2" "$1" "$3"
}

begin_test "a change written while no watch runs is delivered when the watch restarts, and never twice"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt1
D="$ROOT/.craft/annotations/wt1"
A="http://localhost/a"
run_in "$ROOT" begin --session wt1 --subject t >/dev/null
assert_eq "begin saves the log's end as the position" "0" "$(cursor_of "$D")"
start_watch "$ROOT" wt1 "$ROOT/w1.out"; W1="$WATCH_PID"
sleep 0.5
http POST "$PORT" /pins "[$(cpin 1 $A first)]" >/dev/null
if wait_lines "$ROOT/w1.out" 1; then echo "  PASS: pin A arrived"; PASS=$((PASS + 1)); else echo "  FAIL: pin A never arrived"; FAIL=$((FAIL + 1)); fi
assert_contains_literal "the line names the pin" 'ADDED 1 #1 "first" at "div.a" near "n" source ' "$(cat "$ROOT/w1.out")"
sleep 0.6
assert_eq "the position moved to the log's end" "$(size_of "$D/changes.jsonl")" "$(cursor_of "$D")"
stop_job "$W1"
http POST "$PORT" /pins "[$(cpin 1 $A first),$(cpin 2 $A second)]" >/dev/null
start_watch "$ROOT" wt1 "$ROOT/w2.out"; W2="$WATCH_PID"
if wait_lines "$ROOT/w2.out" 1; then echo "  PASS: pin B arrived on re-arm"; PASS=$((PASS + 1)); else echo "  FAIL: pin B was lost"; FAIL=$((FAIL + 1)); fi
sleep 1
assert_eq "only the missed pin printed" "1" "$(wc -l < "$ROOT/w2.out" | tr -d ' ')"
assert_contains_literal "it is pin B" 'ADDED 2 #1 "second"' "$(cat "$ROOT/w2.out")"
assert_not_contains "pin A was not printed again" '"first"' "$(cat "$ROOT/w2.out")"
stop_job "$W2"

begin_test "watch --once prints a batch written before launch at once and exits; a batch written while it blocks wakes it; the position moves once per run; a silent batch does not end it"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt2
D="$ROOT/.craft/annotations/wt2"
A="http://localhost/a"
run_in "$ROOT" begin --session wt2 --subject t >/dev/null
http POST "$PORT" /pins "[$(cpin 1 $A one)]" >/dev/null
START="$SECONDS"
set +e
OUT="$(CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" watch --once --session wt2 2>/dev/null)"
RC=$?
set -e
assert_exit_code "the one-shot exits 0" "0" "$RC"
assert_contains_literal "the waiting batch printed" 'ADDED 1 #1 "one"' "$OUT"
assert_eq "it was quick" "True" "$([ $((SECONDS - START)) -le 3 ] && echo True || echo False)"
assert_eq "the position is the log's end" "$(size_of "$D/changes.jsonl")" "$(cursor_of "$D")"
start_watch "$ROOT" wt2 "$ROOT/o2.out" --once; W="$WATCH_PID"
sleep 1
assert_eq "with nothing waiting it blocks" "yes" "$(is_running "$W" && echo yes || echo no)"
BEFORE="$(cursor_of "$D")"
http POST "$PORT" /pins "[$(cpin 1 $A one),$(cpin 2 $A two)]" >/dev/null
wait_dead "$W" || true
assert_eq "a batch written while it blocked woke it" "no" "$(is_running "$W" && echo yes || echo no)"
assert_contains_literal "it printed the new pin" 'ADDED 2 #1 "two"' "$(cat "$ROOT/o2.out")"
assert_eq "one line" "1" "$(wc -l < "$ROOT/o2.out" | tr -d ' ')"
assert_not_eq "the position moved" "$BEFORE" "$(cursor_of "$D")"
assert_eq "to the log's end" "$(size_of "$D/changes.jsonl")" "$(cursor_of "$D")"
start_watch "$ROOT" wt2 "$ROOT/o3.out" --once; W="$WATCH_PID"
sleep 0.6
http POST "$PORT" /clear >/dev/null
sleep 1.2
assert_eq "a silent batch (cleared) does not end the one-shot" "yes" "$(is_running "$W" && echo yes || echo no)"
assert_eq "it printed nothing" "0" "$(wc -c < "$ROOT/o3.out" | tr -d ' ')"
assert_eq "the position moved past the silent batch" "$(size_of "$D/changes.jsonl")" "$(cursor_of "$D")"
http POST "$PORT" /pins "[$(cpin 3 $A three)]" >/dev/null
wait_dead "$W" || true
assert_contains_literal "a printed batch ends it" 'ADDED 3 #1 "three"' "$(cat "$ROOT/o3.out")"
assert_eq "and the position is the end again" "$(size_of "$D/changes.jsonl")" "$(cursor_of "$D")"

begin_test "DELETE-then-SEND drops the block and prints UNDONE; CLEAR prints nothing and leaves session.css byte-identical"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt3
D="$ROOT/.craft/annotations/wt3"
A="http://localhost/a"
run_in "$ROOT" begin --session wt3 --subject t >/dev/null
printf '/* annotate-key 555 */\n.a{color:red}\n' | run_in "$ROOT" apply --session wt3 >/dev/null
start_watch "$ROOT" wt3 "$ROOT/u.out"; W="$WATCH_PID"
sleep 0.5
http POST "$PORT" /pins "[$(cpin 555 $A drop)]" >/dev/null
wait_lines "$ROOT/u.out" 1 || true
http POST "$PORT" /pins '{"pins":[],"deleted":[555]}' >/dev/null
wait_lines "$ROOT/u.out" 2 || true
assert_eq "the UNDONE line says the page did not confirm" 'UNDONE 555 page did not confirm' "$(sed -n 2p "$ROOT/u.out")"
assert_eq "the block is gone from session.css" "" "$(cat "$D/session.css")"
printf '/* annotate-key 556 */\n.b{color:blue}\n' | run_in "$ROOT" apply --session wt3 >/dev/null
cp "$D/session.css" "$ROOT/sheet.before"
http POST "$PORT" /clear >/dev/null
sleep 1.2
assert_eq "CLEAR printed nothing" "2" "$(wc -l < "$ROOT/u.out" | tr -d ' ')"
assert_eq "the position reached the log's end" "$(size_of "$D/changes.jsonl")" "$(cursor_of "$D")"
assert_eq "session.css is byte-identical" "" "$(cmp "$ROOT/sheet.before" "$D/session.css" 2>&1 || true)"
http POST "$PORT" /pins "[$(cpin 777 $A late)]" >/dev/null
http POST "$PORT" /pins '{"pins":[],"deleted":[777]}' >/dev/null
sleep 1.2
assert_not_contains "a delete of a pin with no block prints nothing" 'UNDONE 777' "$(cat "$ROOT/u.out")"
stop_job "$W"

begin_test "a page that confirms the drop gets UNDONE with page confirmed"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt3b
D="$ROOT/.craft/annotations/wt3b"
A="http://localhost/a"
run_in "$ROOT" begin --session wt3b --subject t >/dev/null
printf '/* annotate-key 9 */\n.a{color:red}\n' | run_in "$ROOT" apply --session wt3b >/dev/null
http POST "$PORT" /pins "[$(cpin 9 $A x)]" >/dev/null
start_watch "$ROOT" wt3b "$ROOT/uc.out" --once; W="$WATCH_PID"
open_changes "$PORT" "$ROOT/uc"; CPID="$STREAM_PID"
wait_for_text "$ROOT/uc.body" ": connected" >/dev/null || true
wait_dead "$W" || true
http POST "$PORT" /pins '{"pins":[],"deleted":[9]}' >/dev/null
start_watch "$ROOT" wt3b "$ROOT/uc2.out" --once; W="$WATCH_PID"
if wait_for_text "$ROOT/uc.body" "event: sheet"; then
  JID="$(sed -n 's/^data: .*"id": "\([^"]*\)".*/\1/p' "$ROOT/uc.body" | head -1)"
  http POST "$PORT" /applied '{"id":"'"$JID"'","page":"http://localhost/a","view":{"x":0,"y":0,"w":800,"h":600},"pageSize":{"w":800,"h":600},"blocks":{},"probes":[]}' >/dev/null
fi
wait_dead "$W" || true
assert_eq "the confirmed drop" "UNDONE 9 page confirmed" "$(cat "$ROOT/uc2.out")"
stop_job "$CPID"

begin_test "one SEND's changes print as adjacent lines after one resolve call; a pin text holding a newline stays one line"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt4
D="$ROOT/.craft/annotations/wt4"
A="http://localhost/a"
run_in "$ROOT" begin --session wt4 --subject t >/dev/null
SPY="$ROOT/spy"
mkdir -p "$SPY"
start_watch "$ROOT" wt4 "$ROOT/n.out"; W="$WATCH_PID"
sleep 0.5
http POST "$PORT" /pins '{"pins":[{"n":1,"text":"a\nb","x":1,"y":2,"selector":"div.a","nearText":"n","ts":31,"page":"'"$A"'"},{"n":2,"text":"two","x":1,"y":2,"selector":"div.b","nearText":"m","ts":32,"page":"'"$A"'"}],"probes":['"$(probe_item 31 $A div.a)"','"$(probe_item 32 $A div.b)"']}' >/dev/null
wait_lines "$ROOT/n.out" 2 || true
sleep 0.5
assert_eq "two lines, one per pin" "2" "$(wc -l < "$ROOT/n.out" | tr -d ' ')"
assert_contains_literal "the newline is escaped inside the JSON string" 'ADDED 31 #1 "a\nb" at "div.a"' "$(sed -n 1p "$ROOT/n.out")"
assert_contains_literal "the second pin follows at once" 'ADDED 32 #2 "two" at "div.b"' "$(sed -n 2p "$ROOT/n.out")"
assert_eq "both pins mapped by the one call" "True" "$(json_get "$D/resolutions.json" '"31" in d["pins"]["http://localhost/a"] and "32" in d["pins"]["http://localhost/a"]')"
stop_job "$W"

begin_test "the source is the page's probe; a pin with no probe says not probed; a pin absent from current.json still resolves"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt5
D="$ROOT/.craft/annotations/wt5"
A="http://localhost/a"
run_in "$ROOT" begin --session wt5 --subject t >/dev/null
start_watch "$ROOT" wt5 "$ROOT/s.out"; W="$WATCH_PID"
sleep 0.5
http POST "$PORT" /pins '{"pins":['"$(cpin 41 $A probed)"'],"probes":['"$(probe_item 41 $A div.a)"']}' >/dev/null
wait_lines "$ROOT/s.out" 1 || true
assert_contains_literal "a probed pin names its source" 'source "no component name; no stylesheet rule' "$(sed -n 1p "$ROOT/s.out")"
http POST "$PORT" /pins "[$(cpin 41 $A probed),$(cpin 42 $A unprobed)]" >/dev/null
wait_lines "$ROOT/s.out" 2 || true
assert_contains_literal "an unprobed pin says so" 'ADDED 42 #1 "unprobed" at "div.a" near "n" source "not probed"' "$(sed -n 2p "$ROOT/s.out")"
http POST "$PORT" /pins '{"pins":['"$(cpin 43 http://localhost/b routed)"'],"probes":['"$(probe_item 43 http://localhost/b div.a)"']}' >/dev/null
wait_lines "$ROOT/s.out" 3 || true
http POST "$PORT" /pins '{"pins":['"$(cpin 44 http://localhost/b routed2)"'],"probes":['"$(probe_item 44 http://localhost/b div.a)"']}' >/dev/null
wait_lines "$ROOT/s.out" 4 || true
assert_eq "pin 41 is no longer in current.json and still reads its cache" "True" "$(json_get "$D/resolutions.json" '"41" in d["pins"]["http://localhost/a"]')"
stop_job "$W"

begin_test "a second watch supersedes the first; removing run.json ends the watch silently; a changed run id ends it; begin moves the position to the log's end"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt6
D="$ROOT/.craft/annotations/wt6"
A="http://localhost/a"
set +e
CRAFT_PROJECT_ROOT="$ROOT" bash "$RUN" watch --session wt6 >/dev/null 2>&1
RC=$?
set -e
assert_exit_code "no run.json is exit 1" "1" "$RC"
run_in "$ROOT" begin --session wt6 --subject t >/dev/null
start_watch "$ROOT" wt6 "$ROOT/p1.out"; W1="$WATCH_PID"
sleep 0.6
start_watch "$ROOT" wt6 "$ROOT/p2.out"; W2="$WATCH_PID"
wait_dead "$W1" || true
assert_eq "the older watch left" "no" "$(is_running "$W1" && echo yes || echo no)"
assert_eq "the newer watch stays" "yes" "$(is_running "$W2" && echo yes || echo no)"
assert_eq "watch.pid names the newer one" "$W2" "$(cat "$D/watch.pid")"
rm -f "$D/run.json"
wait_dead "$W2" || true
assert_eq "removing run.json ends the watch" "no" "$(is_running "$W2" && echo yes || echo no)"
assert_eq "silently" "0" "$(wc -c < "$ROOT/p2.out" | tr -d ' ')"
run_in "$ROOT" begin --session wt6 --subject t >/dev/null
start_watch "$ROOT" wt6 "$ROOT/p3.out"; W3="$WATCH_PID"
sleep 1.2
run_in "$ROOT" begin --session wt6 --subject again >/dev/null
wait_dead "$W3" || true
assert_eq "a new run id ends the old watch" "no" "$(is_running "$W3" && echo yes || echo no)"
http POST "$PORT" /pins "[$(cpin 1 $A x)]" >/dev/null
run_in "$ROOT" begin --session wt6 --subject once-more >/dev/null
assert_eq "begin moves the position to the log's end" "$(size_of "$D/changes.jsonl")" "$(cursor_of "$D")"
assert_eq "which is not zero" "True" "$([ "$(cursor_of "$D")" -gt 0 ] && echo True || echo False)"

begin_test "UNREACHABLE prints once when the listener dies, and again only after it recovered"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt7
D="$ROOT/.craft/annotations/wt7"
run_in "$ROOT" begin --session wt7 --subject t >/dev/null
start_watch "$ROOT" wt7 "$ROOT/x.out"; W="$WATCH_PID"
sleep 0.6
LP="$(cat "$D/listener.pid")"
kill "$LP" 2>/dev/null || true
wait_dead "$LP" || true
wait_lines "$ROOT/x.out" 1 || true
sleep 3
assert_eq "one UNREACHABLE for the outage" "UNREACHABLE" "$(cat "$ROOT/x.out")"
assert_eq "the watch keeps running" "yes" "$(is_running "$W" && echo yes || echo no)"
run_in "$ROOT" ensure --session wt7 >/dev/null
sleep 3
LP="$(cat "$D/listener.pid")"
kill "$LP" 2>/dev/null || true
wait_dead "$LP" || true
wait_lines "$ROOT/x.out" 2 || true
sleep 1
assert_eq "a second outage after recovery prints again" "UNREACHABLE
UNREACHABLE" "$(cat "$ROOT/x.out")"
stop_job "$W"

begin_test "wait prints the payload JSON as before"
new_root; ROOT="$NEW_ROOT"
arm_session "$ROOT" --session wt8
http POST "$PORT" /pins "[$(cpin 1 http://localhost/a x)]" >/dev/null
OUT="$(run_in "$ROOT" wait --session wt8 --timeout 1 --since 0)"
assert_eq "the current payload" "1" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["seq"])')"

finish_tests "test-annotate-channel"
