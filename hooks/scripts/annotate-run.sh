#!/bin/bash
# annotate-run.sh - the single entry seam for the annotation capture channel.
#
# Usage:
#   annotate-run.sh arm     [--root R] [--session ID] [--owner-pid PID]
#   annotate-run.sh status  [--root R] (--session ID | --all)   (CLIENTS is a count, or 'unreachable' when the listener does not answer)
#   annotate-run.sh wait    [--root R] --session ID --timeout SECONDS [--since SEQ]   (--since: the last seq already acted on; a SEND past it returns at once)
#   annotate-run.sh clear   [--root R] --session ID
#   annotate-run.sh announce [--root R] --session ID
#   annotate-run.sh sweep   [--root R]
#   annotate-run.sh disarm  [--root R] --session ID
#
# announce pushes a reload event to every page holding the session's stream and
# prints the listener's reply ({"ok": true, "delivered": N}). A flow calls it
# after writing a round, never when the user sends pins.
#
# Each armed session owns one listener (annotate-channel.py) on an OS-assigned
# port, with its state under <root>/.craft/annotations/<session-id>/:
#   port, listener.pid, owner.pid, listener.log, current.json
#
# arm prints "SESSION <id> PORT <port>". The listener is started detached and
# lives until its owning session process dies; sweep (run at session start)
# reaps session dirs whose owner is gone. disarm exists for tests and manual
# recovery - flows end a review with clear, never disarm.
#
# Exit: 0 on success; 1 on a usage or runtime error. sweep always exits 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANNEL_PY="$SCRIPT_DIR/annotate-channel.py"

die() {
  echo "annotate-run: $*" >&2
  exit 1
}

is_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Session ids become directory names: letters, digits, dot-free dashes and underscores only.
valid_session_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

pid_alive() {
  is_number "${1:-}" && kill -0 "$1" 2>/dev/null
}

read_file() {
  cat "$1" 2>/dev/null || true
}

# Project root: --root, then CRAFT_PROJECT_ROOT, then the workshop oracle.
resolve_root() {
  local given="${1:-}" found=""
  if [ -n "$given" ]; then
    found="$given"
  elif [ -n "${CRAFT_PROJECT_ROOT:-}" ]; then
    found="$CRAFT_PROJECT_ROOT"
  else
    found="$(source "$SCRIPT_DIR/find-workshop.sh" >/dev/null 2>&1; echo "${PROJECT_ROOT:-}")" || found=""
  fi
  echo "${found%/}"
}

# http_call <METHOD> <port> <path> - prints the response body; non-zero when unreachable
http_call() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
import urllib.request

method, port, path = sys.argv[1:4]
request = urllib.request.Request(
    "http://127.0.0.1:%s%s" % (port, path),
    data=b"" if method == "POST" else None,
    method=method,
)
try:
    with urllib.request.urlopen(request, timeout=5) as response:
        sys.stdout.write(response.read().decode("utf-8"))
except Exception as error:
    sys.stderr.write("request failed: %s\n" % error)
    sys.exit(1)
PYEOF
}

# read_seq <file> - the file's seq, or 0 when absent or unreadable
read_seq() {
  python3 - "$1" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        seq = json.load(handle).get("seq", 0)
    print(seq if isinstance(seq, int) else 0)
except Exception:
    print(0)
PYEOF
}

# The nearest ancestor (this process included) whose command name contains
# "claude" owns the session. Nothing found prints nothing.
resolve_owner_pid() {
  local pid="$$" hops=0 cmd first base
  while is_number "$pid" && [ "$pid" -gt 1 ] && [ "$hops" -lt 40 ]; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    first="${cmd%% *}"
    base="${first##*/}"
    case "$base" in
      *claude*) echo "$pid"; return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    hops=$((hops + 1))
  done
  return 0
}

# start_listener <session-dir> - launches the listener detached; sets LISTENER_PID and LISTENER_PORT
# The child gets no stdin and writes only to listener.log, so no pipe from the
# caller stays open and this call returns however long the listener lives.
start_listener() {
  local dir="$1" waited=0 line=""
  : > "$dir/listener.log"
  nohup python3 "$CHANNEL_PY" --dir "$dir" >"$dir/listener.log" 2>&1 </dev/null &
  LISTENER_PID=$!
  disown "$LISTENER_PID" 2>/dev/null || true
  LISTENER_PORT=""
  while [ "$waited" -lt 100 ]; do
    line="$(grep -m1 '^PORT ' "$dir/listener.log" 2>/dev/null || true)"
    if [ -n "$line" ]; then
      LISTENER_PORT="${line#PORT }"
      break
    fi
    kill -0 "$LISTENER_PID" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  is_number "$LISTENER_PORT" || die "listener did not report a port (see $dir/listener.log)"
}

cmd_arm() {
  local ann_dir ann_existed=0 sid dir listener_pid_file owner
  [ -n "$ROOT" ] || die "no craft project root (pass --root or set CRAFT_PROJECT_ROOT)"
  ann_dir="$ROOT/.craft/annotations"
  [ -d "$ann_dir" ] && ann_existed=1
  mkdir -p "$ann_dir"
  # Only the run that creates the folder seeds the ignore file, so a user who
  # deletes it has opted the folder back into commits for good.
  if [ "$ann_existed" = "0" ] && [ ! -f "$ann_dir/.gitignore" ]; then
    printf '*\n' > "$ann_dir/.gitignore" 2>/dev/null || true
  fi

  if [ -n "$SESSION" ]; then
    valid_session_id "$SESSION" || die "invalid session id: $SESSION"
    sid="$SESSION"
  else
    sid="$$-$(date +%s)"
  fi
  dir="$ann_dir/$sid"
  mkdir -p "$dir"
  listener_pid_file="$dir/listener.pid"

  if pid_alive "$(read_file "$listener_pid_file")" && is_number "$(read_file "$dir/port")"; then
    echo "SESSION $sid PORT $(read_file "$dir/port")"
    return 0
  fi

  start_listener "$dir"
  echo "$LISTENER_PORT" > "$dir/port"
  echo "$LISTENER_PID" > "$listener_pid_file"

  if [ -n "$OWNER_PID" ]; then
    is_number "$OWNER_PID" || die "--owner-pid must be a pid"
    owner="$OWNER_PID"
  elif is_number "$(read_file "$dir/owner.pid")"; then
    owner="$(read_file "$dir/owner.pid")"
  else
    owner="$(resolve_owner_pid)"
    # No claude ancestor: tie the session to the listener itself. The sweep
    # then reaps only after that pid is gone - never early, only late.
    [ -n "$owner" ] || owner="$LISTENER_PID"
  fi
  echo "$owner" > "$dir/owner.pid"

  echo "SESSION $sid PORT $LISTENER_PORT"
}

session_dir() {
  local dir
  [ -n "$ROOT" ] || die "no craft project root (pass --root or set CRAFT_PROJECT_ROOT)"
  valid_session_id "$SESSION" || die "--session <id> is required"
  dir="$ROOT/.craft/annotations/$SESSION"
  [ -d "$dir" ] || die "no such session: $SESSION"
  echo "$dir"
}

cmd_status() {
  local dir id port pid clients health owner verdict
  if [ "$ALL" = "1" ]; then
    [ -n "$ROOT" ] || die "no craft project root (pass --root or set CRAFT_PROJECT_ROOT)"
    for dir in "$ROOT"/.craft/annotations/*/; do
      [ -d "$dir" ] || continue
      id="$(basename "$dir")"
      owner="$(read_file "$dir/owner.pid")"
      if ! is_number "$owner"; then
        verdict="unknown"
      elif pid_alive "$owner"; then
        verdict="alive"
      else
        verdict="dead"
      fi
      echo "$id owner=${owner:-none} $verdict"
    done
    return 0
  fi

  dir="$(session_dir)"
  port="$(read_file "$dir/port")"
  pid="$(read_file "$dir/listener.pid")"
  clients=unreachable
  if is_number "$port" && health="$(http_call GET "$port" /health 2>/dev/null)"; then
    clients="$(echo "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("clients", 0))' 2>/dev/null || echo 0)"
  fi
  echo "SESSION $SESSION PORT ${port:-none} PID ${pid:-none} CLIENTS $clients"
}

cmd_wait() {
  local dir file baseline now ticks=0 limit
  dir="$(session_dir)"
  is_number "$TIMEOUT" || die "--timeout <seconds> is required"
  file="$dir/current.json"
  if [ -n "$SINCE" ]; then
    is_number "$SINCE" || die "--since must be a number (the last seq already acted on)"
    baseline="$SINCE"
  else
    baseline="$(read_seq "$file")"
  fi
  limit=$((TIMEOUT * 4))
  while [ "$ticks" -lt "$limit" ]; do
    now="$(read_seq "$file")"
    if [ "$now" -gt "$baseline" ]; then
      cat "$file"
      return 0
    fi
    sleep 0.25
    ticks=$((ticks + 1))
  done
  now="$(read_seq "$file")"
  if [ "$now" -gt "$baseline" ]; then
    cat "$file"
  else
    echo "WAITING"
  fi
}

cmd_clear() {
  local dir port
  dir="$(session_dir)"
  port="$(read_file "$dir/port")"
  is_number "$port" || die "session $SESSION has no port"
  http_call POST "$port" /clear >/dev/null || die "listener for $SESSION is not answering"
}

cmd_announce() {
  local dir port
  dir="$(session_dir)"
  port="$(read_file "$dir/port")"
  is_number "$port" || die "session $SESSION has no port"
  http_call POST "$port" /announce || die "listener for $SESSION is not answering"
}

cmd_disarm() {
  local dir pid
  dir="$(session_dir)"
  pid="$(read_file "$dir/listener.pid")"
  if is_number "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -rf "$dir"
}

# Reaps session dirs whose owning session process is dead. A dir with no
# readable owner is left alone: unknown is never treated as dead.
sweep_all() {
  local dir owner listener
  [ -n "$ROOT" ] || return 0
  for dir in "$ROOT"/.craft/annotations/*/; do
    [ -d "$dir" ] || continue
    owner="$(read_file "$dir/owner.pid")"
    is_number "$owner" || continue
    pid_alive "$owner" && continue
    listener="$(read_file "$dir/listener.pid")"
    # Kill only a process that is still a listener: the recorded pid may have been
    # reused by an unrelated process after a listener died on its own.
    if is_number "$listener" && ps -o command= -p "$listener" 2>/dev/null | grep -q "annotate-channel"; then
      kill "$listener" 2>/dev/null || true
    fi
    rm -rf "$dir" 2>/dev/null || true
  done
  return 0
}

VERB="${1:-}"
[ -n "$VERB" ] || die "usage: annotate-run.sh arm|status|wait|clear|announce|sweep|disarm [options]"
shift

ROOT_ARG=""
SESSION=""
OWNER_PID=""
TIMEOUT=""
SINCE=""
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      [ $# -ge 2 ] || die "--root needs a value"; ROOT_ARG="$2"; shift 2 ;;
    --session)   [ $# -ge 2 ] || die "--session needs a value"; SESSION="$2"; shift 2 ;;
    --owner-pid) [ $# -ge 2 ] || die "--owner-pid needs a value"; OWNER_PID="$2"; shift 2 ;;
    --timeout)   [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
    --since)     [ $# -ge 2 ] || die "--since needs a value"; SINCE="$2"; shift 2 ;;
    --all)       ALL=1; shift ;;
    *)           die "unknown argument: $1" ;;
  esac
done

if [ "$VERB" = "sweep" ]; then
  ROOT="$(resolve_root "$ROOT_ARG" 2>/dev/null || true)"
  sweep_all 2>/dev/null || true
  exit 0
fi

ROOT="$(resolve_root "$ROOT_ARG")"

case "$VERB" in
  arm)    cmd_arm ;;
  status) cmd_status ;;
  wait)   cmd_wait ;;
  clear)  cmd_clear ;;
  announce) cmd_announce ;;
  disarm) cmd_disarm ;;
  *)      die "unknown verb: $VERB" ;;
esac
