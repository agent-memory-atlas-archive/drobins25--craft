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
#   annotate-run.sh begin   [--root R] --session ID [--subject TEXT]   (annotate only: marks the run's start seq)
#   annotate-run.sh sheet   [--root R] --session ID [--add --key KEY | --drop KEY]   (annotate only: the live session.css)
#   annotate-run.sh send    [--root R] --session ID   (POSTs the JSON pin array on stdin to the listener)
#   annotate-run.sh disarm  [--root R] --session ID
#
# announce pushes a reload event to every page holding the session's stream and
# prints the listener's reply ({"ok": true, "delivered": N}). A flow calls it
# after writing a round, never when the user sends pins.
#
# A run that never reached an exit is filed by begin (the next run on the same
# session) and by sweep (before reaping) as outcome error, status open.
#
# begin prints "RUN <start_seq>" (the highest seq on disk), writes run.json and
# empties session.css. sheet keeps session.css as keyed blocks and prints ONE
# line, the statement that makes the page equal the whole file; with neither
# --add nor --drop it only prints. send is for a page that blocks SEND: the
# session posts the pins it read from local storage itself.
#
# Each armed session owns one listener (annotate-channel.py) on an OS-assigned
# port, with its state under <root>/.craft/annotations/<session-id>/:
#   port, listener.pid, owner.pid, listener.log, current.json, history.jsonl,
#   run.json, session.css
# Any directory holding record.md is a filed record, not a live session: status
# --all and sweep never list or touch it.
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

# http_post_body <port> <path> - POSTs stdin as the body; prints the reply, non-zero when unreachable or refused
http_post_body() {
  local source
  # The script rides in -c so stdin stays free for the body.
  read -r -d '' source <<'PYEOF' || true
import sys
import urllib.error
import urllib.request

port, path = sys.argv[1:3]
request = urllib.request.Request(
    "http://127.0.0.1:%s%s" % (port, path),
    data=sys.stdin.buffer.read(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=5) as response:
        sys.stdout.write(response.read().decode("utf-8"))
except urllib.error.HTTPError as error:
    sys.stderr.write("listener refused the set (%s)\n" % error.code)
    sys.exit(1)
except Exception as error:
    sys.stderr.write("request failed: %s\n" % error)
    sys.exit(1)
PYEOF
  python3 -c "$source" "$1" "$2"
}

# last_seq_on_disk <session-dir> - the max seq across current.json and history.jsonl, 0 when neither reads
last_seq_on_disk() {
  python3 - "$1" <<'PYEOF'
import json
import os
import sys

dir_path = sys.argv[1]
best = 0


def as_seq(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


try:
    with open(os.path.join(dir_path, "current.json"), "r", encoding="utf-8") as handle:
        best = as_seq(json.load(handle).get("seq", 0))
except Exception:
    pass
try:
    with open(os.path.join(dir_path, "history.jsonl"), "r", encoding="utf-8") as handle:
        for line in handle:
            try:
                best = max(best, as_seq(json.loads(line).get("seq", 0)))
            except Exception:
                continue
except Exception:
    pass
print(best)
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
      [ -f "$dir/record.md" ] && continue
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

# file_orphan <session-dir> - a run that never reached an exit (closed terminal,
# forgotten exit) is filed as outcome error before anything is overwritten or
# reaped. A filing failure never stops the caller.
file_orphan() {
  local dir="$1"
  [ -f "$dir/run.json" ] || return 0
  bash "$SCRIPT_DIR/annotate-record.sh" file --root "$ROOT" --session "$(basename "$dir")" --outcome error >/dev/null 2>&1 || true
  return 0
}

cmd_begin() {
  local dir start
  dir="$(session_dir)"
  file_orphan "$dir"
  start="$(last_seq_on_disk "$dir")"
  python3 - "$dir" "$start" "$SUBJECT" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

dir_path, start, subject = sys.argv[1:4]
run = {
    "start_seq": int(start),
    "subject": subject,
    "started_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
for name, content in (("run.json", json.dumps(run) + "\n"), ("session.css", "")):
    tmp_path = os.path.join(dir_path, name + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.replace(tmp_path, os.path.join(dir_path, name))
PYEOF
  echo "RUN $start"
}

# The sheet is a run of keyed blocks: a header line "/* annotate-key KEY */"
# then that key's CSS. The page only ever receives the whole file, as one
# statement that replaces the session style's text, so page == sheet after
# every apply.
cmd_sheet() {
  local dir mode="print"
  dir="$(session_dir)"
  if [ "$SHEET_ADD" = "1" ] && [ -n "$SHEET_DROP" ]; then
    die "sheet takes --add or --drop, not both"
  fi
  if [ "$SHEET_ADD" = "1" ]; then
    mode="add"
    valid_session_id "$KEY" || die "--add needs --key KEY (letters, digits, dash, underscore)"
  elif [ -n "$SHEET_DROP" ]; then
    mode="drop"
    KEY="$SHEET_DROP"
    valid_session_id "$KEY" || die "--drop needs a KEY (letters, digits, dash, underscore)"
  fi
  local source
  # The script rides in -c so stdin stays free for the CSS.
  read -r -d '' source <<'PYEOF' || true
import json
import os
import re
import sys

path, mode, key = sys.argv[1:4]
HEADER = re.compile(r"^/\* annotate-key ([A-Za-z0-9_-]+) \*/$")
MARKER = "/* annotate-key "


def parse(text):
    """Ordered [key, css] blocks. A header must open its own line."""
    blocks = []
    for line in text.splitlines(keepends=True):
        found = HEADER.match(line.rstrip("\n"))
        if found:
            blocks.append([found.group(1), ""])
        elif blocks:
            blocks[-1][1] += line
    return blocks


def render(blocks):
    out = ""
    for block_key, css in blocks:
        if css and not css.endswith("\n"):
            css += "\n"
        out += "%s%s */\n%s" % (MARKER, block_key, css)
    return out


try:
    with open(path, "r", encoding="utf-8") as handle:
        current = handle.read()
except OSError:
    current = ""

if mode == "print":
    text = current
else:
    blocks = parse(current)
    if mode == "add":
        css = sys.stdin.read()
        if MARKER in css:
            sys.stderr.write("annotate-run: CSS must not carry an annotate-key header\n")
            sys.exit(1)
        for block in blocks:
            if block[0] == key:
                block[1] = css
                break
        else:
            blocks.append([key, css])
    else:
        blocks = [block for block in blocks if block[0] != key]
    text = render(blocks)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp_path, path)

literal = json.dumps(text)
sys.stdout.write(
    "(() => { let s = document.getElementById('ca-session-css'); "
    "if (!s) { s = document.createElement('style'); s.id = 'ca-session-css'; "
    "s.setAttribute('data-craft-annotate-injected', ''); } "
    "s.textContent = %s; document.head.appendChild(s); })()\n" % literal
)
PYEOF
  python3 -c "$source" "$dir/session.css" "$mode" "$KEY"
}

cmd_send() {
  local dir port
  dir="$(session_dir)"
  port="$(read_file "$dir/port")"
  is_number "$port" || die "session $SESSION has no port"
  http_post_body "$port" /pins || die "listener for $SESSION is not answering"
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
    [ -f "$dir/record.md" ] && continue
    owner="$(read_file "$dir/owner.pid")"
    is_number "$owner" || continue
    pid_alive "$owner" && continue
    file_orphan "$dir"
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
[ -n "$VERB" ] || die "usage: annotate-run.sh arm|status|wait|clear|announce|begin|sheet|send|sweep|disarm [options]"
shift

ROOT_ARG=""
SESSION=""
OWNER_PID=""
TIMEOUT=""
SINCE=""
ALL=0
SUBJECT=""
KEY=""
SHEET_ADD=0
SHEET_DROP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      [ $# -ge 2 ] || die "--root needs a value"; ROOT_ARG="$2"; shift 2 ;;
    --session)   [ $# -ge 2 ] || die "--session needs a value"; SESSION="$2"; shift 2 ;;
    --owner-pid) [ $# -ge 2 ] || die "--owner-pid needs a value"; OWNER_PID="$2"; shift 2 ;;
    --timeout)   [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
    --since)     [ $# -ge 2 ] || die "--since needs a value"; SINCE="$2"; shift 2 ;;
    --all)       ALL=1; shift ;;
    --subject)   [ $# -ge 2 ] || die "--subject needs a value"; SUBJECT="$2"; shift 2 ;;
    --key)       [ $# -ge 2 ] || die "--key needs a value"; KEY="$2"; shift 2 ;;
    --add)       SHEET_ADD=1; shift ;;
    --drop)      [ $# -ge 2 ] || die "--drop needs a value"; SHEET_DROP="$2"; shift 2 ;;
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
  begin)  cmd_begin ;;
  sheet)  cmd_sheet ;;
  send)   cmd_send ;;
  disarm) cmd_disarm ;;
  *)      die "unknown verb: $VERB" ;;
esac
