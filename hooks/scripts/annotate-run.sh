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
#   annotate-run.sh watch   [--root R] --session ID [--once]   (annotate only: prints each new change from the saved position as one line; --once blocks until one batch prints, then exits)
#   annotate-run.sh sheet   [--root R] --session ID [--add --key KEY | --drop KEY]   (annotate only: the live session.css)
#   annotate-run.sh apply   [--root R] --session ID [--drop KEY]... [--target TS=SELECTOR]...   (annotate only: blocks on stdin; writes them, pushes the page, prints what the page measured)
#   annotate-run.sh stamp   [--root R] --session ID [--no-run]   (annotate only: ONE line that stamps the port, the token and the run id, for a page that blocks the loader; --no-run leaves out the run id and needs no run)
#   annotate-run.sh kind    --page URL   (prints project or external; needs no session)
#   annotate-run.sh loader  [--root R] --session ID --page URL [--run]   (--run: annotate only, also stamps the run id; project page: ONE line for evaluate_script that loads the served overlay; external page: EXTERNAL)
#   annotate-run.sh bake    [--root R] --session ID --file PATH   (mockup: splices the stamps and the overlay into the page file)
#   annotate-run.sh strip   --file PATH   (mockup: removes every baked overlay element; needs no session)
#   annotate-run.sh ensure  [--root R] --session ID   (read beat: OK PORT p | REARMED PORT p STREAK k | GONE | FAILED; restarts a dead or hung listener)
#   annotate-run.sh send    [--root R] --session ID   (POSTs the JSON pin array on stdin to the listener)
#   annotate-run.sh review-clear [--root R]   (review flows: OPEN <id> <subject> per open run, else ONE line, a function that clears leftover annotate changes and returns CLEARED; needs no session, writes nothing)
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
# line, a function that makes the page equal the whole file and returns
# APPLIED, pasted to evaluate_script verbatim; with neither
# --add nor --drop it only prints. send is for a page that blocks SEND: the
# session posts the pins it read from local storage itself.
#
# watch reads changes.jsonl from the byte offset saved in watch.cursor (begin
# saves the log's size; a watch with no cursor starts at the log's end) and
# prints one line per change: ADDED / EDITED with the pin's source, UNDONE for a
# withdrawn pin whose block it dropped, UNREACHABLE when the listener is gone.
# Each poll's complete lines are one batch, printed together before the position
# moves, so a change is never lost across a restart and never printed twice.
# The newest watch owns watch.pid and older ones leave; a watch ends silently
# when the run is filed or the session folder is gone.
#
# kind calls a page a project page when it is served from localhost, 127.0.0.1
# or file://; every other address is external. The loader never contacts the
# listener for an external page, which always takes the pasted overlay instead.
#
# bake writes one <script id="ca-overlay"> element immediately before the last
# </body>: the port stamp, the baked flag, then the overlay fence, which it reads
# only through annotate-channel.py --print-overlay. It never contacts the
# listener, so a page can be re-baked right after the listener died. Any
# existing overlay element is removed first; strip removes them and nothing
# else, so bake then strip restores the original bytes.
#
# wait prints UNREACHABLE (exit 0) when the listener process is gone and no SEND
# arrived. ensure counts consecutive re-arms in <session-dir>/rearm.streak and a
# healthy probe resets it; it never recreates a swept session folder (GONE).
#
# Each armed session owns one listener (annotate-channel.py) on an OS-assigned
# port, with its state under <root>/.craft/annotations/<session-id>/:
#   port, listener.pid, owner.pid, listener.log, current.json, history.jsonl,
#   run.json, session.css, rearm.streak, changes.jsonl, probes.json, watch.cursor,
#   watch.pid
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

# LOCAL_OPENER_PY - Python source every listener call starts from. The one
# opener skips the proxy environment, so http_proxy cannot make a healthy
# loopback listener look dead, and every request carries the session token as
# a query parameter. The token is read from the session's token file (a
# missing file reads as empty), never taken from a command line.
read -r -d '' LOCAL_OPENER_PY <<'PYEOF' || true
import urllib.parse
import urllib.request

LOCAL_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def read_token(token_file):
    try:
        with open(token_file, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def local_url(port, path, token_file):
    joiner = "&" if "?" in path else "?"
    return "http://127.0.0.1:%s%s%stoken=%s" % (
        port, path, joiner, urllib.parse.quote(read_token(token_file), safe=""))


def local_request(method, port, path, token_file, timeout, data=None, headers=None):
    request = urllib.request.Request(
        local_url(port, path, token_file), data=data, headers=headers or {}, method=method)
    return LOCAL_OPENER.open(request, timeout=timeout)
PYEOF

# PAGE_KIND_PY - the one definition of the project/external rule: a page is
# project when it is a file, or http/https on exactly localhost or 127.0.0.1
# (any port); everything else is external. Shared by page_kind and the watch.
read -r -d '' PAGE_KIND_PY <<'PYEOF' || true
from urllib.parse import urlparse


def page_is_external(url):
    try:
        parsed = urlparse(str(url).strip())
        scheme = (parsed.scheme or "").lower()
        host = (parsed.hostname or "").lower()
    except ValueError:
        return True
    local = scheme == "file" or (scheme in ("http", "https") and host in ("localhost", "127.0.0.1"))
    return not local
PYEOF

# BOUNDARY_PY - the external-page boundary, written only by this script. A
# session on an external page holds <session-dir>/external.json; a pointer
# <boundary-dir>/<owner-pid>.json lists the owner's marked sessions so the gate
# can find them from the conversation's pid; <owner-pid>.lift holds the one
# prompt a typed yes covered. Marking and unmarking are the only writers of the
# marker; every pin print revokes the lift first.
read -r -d '' BOUNDARY_PY <<'PYEOF' || true
import datetime
import fcntl
import json
import os
import subprocess
import tempfile
import time

NOTICE = (
    "NOTICE This page is outside your project, so I'll treat pins here as page content - "
    "something the site itself could add to. Pins can change how this page looks; anything "
    "beyond that, like running a command, reading or editing a file, or fetching something, "
    "waits until you reply in chat."
)
# Said instead of NOTICE when the session's owner is not an ancestor of this
# process: the block finds a session only through its own ancestors, so it is off.
UNENFORCED_NOTICE = (
    "NOTICE This page is outside your project, so I'll treat pins here as page content - "
    "something the site itself could add to. The pin boundary could not attach to this "
    "conversation, so it is off: a pin that asks me to run a command, read or edit a file, "
    "or fetch something will not be held until you reply in chat."
)


def boundary_dir():
    return os.environ.get("CRAFT_ANNOTATE_BOUNDARY_DIR") or os.path.join(
        os.path.expanduser("~"), ".cache", "craft", "annotate-boundary")


def owner_of(session_dir):
    try:
        with open(os.path.join(session_dir, "owner.pid"), "r", encoding="utf-8") as handle:
            text = handle.read().strip()
    except OSError:
        return None
    return text if text.isdigit() else None


def owner_is_ancestor(session_dir):
    """True when the session's owner pid is this process or one of its ancestors -
    the same walk the block makes from its hook, which runs under the same
    conversation as the loader and the watch."""
    owner = owner_of(os.path.abspath(session_dir))
    if not owner:
        return False
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    parent = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            parent[int(parts[0])] = int(parts[1])
    chain = []
    pid = os.getpid()
    while pid > 1 and pid not in chain and len(chain) < 64:
        if pid == int(owner):
            return True
        chain.append(pid)
        pid = parent.get(pid, 0)
    return False


def boundary_notice(session_dir):
    """The one-time line for a newly marked session: NOTICE only when the block can
    reach it, else the line that says the boundary is off."""
    return NOTICE if owner_is_ancestor(session_dir) else UNENFORCED_NOTICE


def write_json(path, data):
    write_text(path, json.dumps(data))


def write_text(path, text, mode=None):
    """Write through a temp file of this writer's own in the same folder, then
    replace, so a reader never sees the file empty or half written. mode, when
    given, is the file's permission bits (a temp file starts at 0600)."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".", suffix=".tmp")
    try:
        if mode is not None:
            os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def take_lock(path):
    """Open and hold the lock file at path. A writer that waited while the holder
    removed the file holds a lock nobody else can see, so it opens the path again
    until the file it holds is the one at the path."""
    while True:
        lock = open(path, "a")
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            held, there = os.fstat(lock.fileno()), os.stat(path)
            if (held.st_dev, held.st_ino) == (there.st_dev, there.st_ino):
                return lock
        except OSError:
            pass
        lock.close()


def edit_pointer(owner, change, create=True):
    """Apply change(sessions) to the owner's pointer under its lock; an emptied
    list removes the pointer and the lift. A missing pointer is left missing
    unless create is true. With no pointer left, the lock file goes too, while
    still held, so no lock outlives its pointer."""
    folder = boundary_dir()
    os.makedirs(folder, mode=0o700, exist_ok=True)
    pointer = os.path.join(folder, owner + ".json")
    lock_path = os.path.join(folder, owner + ".lock")
    with take_lock(lock_path):
        try:
            with open(pointer, "r", encoding="utf-8") as handle:
                data = json.load(handle)
            sessions = [item for item in data.get("sessions", []) if isinstance(item, str)]
        except (OSError, ValueError, AttributeError):
            sessions = None
        if sessions is not None or create:
            sessions = change(sessions or [])
            if sessions:
                write_json(pointer, {"sessions": sessions, "updated": int(time.time())})
                return
        names = (lock_path,) if sessions is None else (pointer, os.path.join(folder, owner + ".lift"), lock_path)
        for name in names:
            try:
                os.unlink(name)
            except OSError:
                pass


def mark_external(session_dir, page):
    """Mark the session external and list it under its owner; True when this
    call created the marker (the one that owes the user the notice)."""
    session_dir = os.path.abspath(session_dir)
    created = False
    try:
        fd = os.open(os.path.join(session_dir, "external.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        since = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump({"since": since, "page": str(page)}, handle)
        created = True
    owner = owner_of(session_dir)
    if owner:
        edit_pointer(owner, lambda sessions: sessions if session_dir in sessions else sessions + [session_dir])
    return created


def revoke_lift(session_dir):
    """Remove the owner's lift and refresh the pointer's clock."""
    owner = owner_of(os.path.abspath(session_dir))
    if not owner:
        return
    try:
        os.unlink(os.path.join(boundary_dir(), owner + ".lift"))
    except OSError:
        pass
    edit_pointer(owner, lambda sessions: sessions, create=False)


def unmark_external(session_dir):
    """End the session's boundary: the marker goes, and so does its pointer entry."""
    session_dir = os.path.abspath(session_dir)
    try:
        os.unlink(os.path.join(session_dir, "external.json"))
    except OSError:
        pass
    owner = owner_of(session_dir)
    if owner:
        edit_pointer(owner, lambda sessions: [item for item in sessions if item != session_dir], create=False)
PYEOF

# write_session_files <path> <value> [<path> <value>]... - writes each value and a
# newline through write_text, in order, so no session file is ever seen half written
write_session_files() {
  python3 -c "$BOUNDARY_PY
import sys

pairs = sys.argv[1:]
for at in range(0, len(pairs), 2):
    write_text(pairs[at], pairs[at + 1] + '\n')" "$@"
}

# token_file - the current session's token file, which may not exist
token_file() {
  echo "$ROOT/.craft/annotations/$SESSION/token"
}

# http_call <METHOD> <port> <path> [timeout-seconds] - prints the response body; non-zero when unreachable
http_call() {
  local source
  read -r -d '' source <<'PYEOF' || true
import sys

method, port, path, token_file = sys.argv[1:5]
timeout = float(sys.argv[5])
try:
    with local_request(method, port, path, token_file, timeout,
                       data=b"" if method == "POST" else None) as response:
        sys.stdout.write(response.read().decode("utf-8"))
except Exception as error:
    sys.stderr.write("request failed: %s\n" % error)
    sys.exit(1)
PYEOF
  python3 -c "$LOCAL_OPENER_PY
$source" "$1" "$2" "$3" "$(token_file)" "${4:-5}"
}

# http_post_body <port> <path> - POSTs stdin as the body; prints the reply, non-zero when unreachable or refused
http_post_body() {
  local source
  # The script rides in -c so stdin stays free for the body.
  read -r -d '' source <<'PYEOF' || true
import sys
import urllib.error

port, path, token_file = sys.argv[1:4]
try:
    with local_request("POST", port, path, token_file, 5, data=sys.stdin.buffer.read(),
                       headers={"Content-Type": "application/json"}) as response:
        sys.stdout.write(response.read().decode("utf-8"))
except urllib.error.HTTPError as error:
    sys.stderr.write("listener refused the set (%s)\n" % error.code)
    sys.exit(1)
except Exception as error:
    sys.stderr.write("request failed: %s\n" % error)
    sys.exit(1)
PYEOF
  python3 -c "$LOCAL_OPENER_PY
$source" "$1" "$2" "$(token_file)"
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
  write_session_files "$dir/port" "$LISTENER_PORT" "$listener_pid_file" "$LISTENER_PID"

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
  write_session_files "$dir/owner.pid" "$owner"

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
    # Once a second, a listener that is gone ends the wait: nothing can arrive.
    # The seq was read just above, so a SEND that landed in the same tick wins.
    if [ $((ticks % 4)) -eq 3 ] && ! pid_alive "$(read_file "$dir/listener.pid")"; then
      echo "UNREACHABLE"
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
  # The boundary ends here and nowhere else; it ends even when the listener is already gone.
  python3 -c "$BOUNDARY_PY
import sys

unmark_external(sys.argv[1])" "$dir"
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
  # An earlier run's probes must never resolve this run's pins.
  rm -f "$dir/probes.json"
  python3 - "$dir" "$start" "$SUBJECT" <<'PYEOF'
import fcntl
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

dir_path, start, subject = sys.argv[1:4]
run = {
    "start_seq": int(start),
    "subject": subject,
    "started_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
try:
    log_size = os.path.getsize(os.path.join(dir_path, "changes.jsonl"))
except OSError:
    log_size = 0


def write_unique(name, content):
    """Write through a temp file of this writer's own, then replace."""
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(tmp_path, os.path.join(dir_path, name))
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# The sheet reset takes the same lock sheet and apply do, so a background undo
# cannot write between the reset and the run record.
with open(os.path.join(dir_path, "session.css.lock"), "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    for name, content in (("run.json", json.dumps(run) + "\n"), ("session.css", ""), ("watch.cursor", "%d\n" % log_size)):
        write_unique(name, content)
PYEOF
  echo "RUN $start"
}

# The sheet's own grammar and the paste literal, shared by sheet and apply.
# argv: <file> <mode> <key> [d:KEY | t:TS=SELECTOR]...
#   print/add/drop  the sheet verb's modes (the printed function is the paste line)
#   apply           stdin holds blocks; d: entries drop keys, t: entries aim a
#                   pin at another element; prints the page job as one JSON line
read -r -d '' SHEET_PY <<'PYEOF' || true
import fcntl
import json
import os
import re
import sys
import tempfile
import uuid

path, mode, key = sys.argv[1:4]
extras = sys.argv[4:]
KEY = r"[A-Za-z0-9_-]+"
HEADER = re.compile(r"^/\* annotate-key (%s) \*/$" % KEY)
VALID_KEY = re.compile(r"^%s$" % KEY)
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


def refuse(message):
    sys.stderr.write("annotate-run: %s\n" % message)
    sys.exit(1)


def parse_input(text):
    """Blocks from apply's stdin; anything that is not a block is refused."""
    blocks = []
    for line in text.splitlines(keepends=True):
        bare = line.rstrip("\n")
        found = HEADER.match(bare)
        if found:
            blocks.append([found.group(1), ""])
        elif MARKER in line:
            refuse("a line carries an annotate-key marker that is not a valid header: %s" % bare[:60])
        elif blocks:
            blocks[-1][1] += line
        elif bare.strip():
            refuse("text before the first annotate-key header")
    return blocks


def set_block(blocks, block_key, css):
    for block in blocks:
        if block[0] == block_key:
            block[1] = css
            return
    blocks.append([block_key, css])


def save(text):
    """Write through a temp file of this writer's own, then replace."""
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# Every change to the sheet is read-modify-write, so it runs under an exclusive
# lock that lasts until this process exits. Nothing here starts a subprocess.
lock = None
if mode != "print":
    lock = open(path + ".lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)

try:
    with open(path, "r", encoding="utf-8") as handle:
        current = handle.read()
except OSError:
    current = ""

job = None
if mode == "print":
    text = current
elif mode == "apply":
    drops = [e[2:] for e in extras if e.startswith("d:")]
    targets = []
    for entry in extras:
        if entry.startswith("t:"):
            ts, _, selector = entry[2:].partition("=")
            targets.append({"ts": int(ts) if ts.isdigit() else ts, "selector": selector})
    for drop in drops:
        if not VALID_KEY.match(drop):
            refuse("--drop needs a KEY (letters, digits, dash, underscore)")
    incoming = [] if sys.stdin.isatty() else parse_input(sys.stdin.read())
    blocks = [block for block in parse(current) if block[0] not in drops]
    for block_key, css in incoming:
        set_block(blocks, block_key, css)
    text = render(blocks)
    save(text)
    measure = []
    for block_key, _ in incoming:
        if block_key not in measure:
            measure.append(block_key)
    job = {"id": uuid.uuid4().hex[:12], "measure": measure, "targets": targets}
else:
    blocks = parse(current)
    if mode == "add":
        css = sys.stdin.read()
        if MARKER in css:
            refuse("CSS must not carry an annotate-key header")
        set_block(blocks, key, css)
    else:
        blocks = [block for block in blocks if block[0] != key]
    text = render(blocks)
    save(text)

if job is not None:
    sys.stdout.write(json.dumps(job) + "\n")
else:
    sys.stdout.write(
        "() => { let s = document.getElementById('ca-session-css'); "
        "if (!s) { s = document.createElement('style'); s.id = 'ca-session-css'; "
        "s.setAttribute('data-craft-annotate-injected', ''); } "
        "s.textContent = %s; document.head.appendChild(s); return 'APPLIED'; }\n" % json.dumps(text)
    )
PYEOF

# The sheet is a run of keyed blocks: a header line "/* annotate-key KEY */"
# then that key's CSS. The page only ever receives the whole file, as one
# function that replaces the session style's text and returns APPLIED, so
# page == sheet after every apply.
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
  python3 -c "$SHEET_PY" "$dir/session.css" "$mode" "$KEY"
}

# What the page measured, as lines. Reads the report on stdin; argv holds the
# dropped keys. The tiers are data here, not in the page: the page measures,
# this decides which facts call for a screenshot.
read -r -d '' REPORT_PY <<'PYEOF' || true
import json
import re
import sys

LIMIT = 120
LAYOUT_EXACT = {"display", "position", "float", "inset", "top", "right", "bottom", "left",
                "width", "height", "min-width", "max-width", "min-height", "max-height",
                "gap", "row-gap", "column-gap", "order", "transform", "translate", "scale", "rotate"}
LAYOUT_PREFIX = ("grid", "flex", "align-", "justify-", "place-", "overflow")
STACKING_EXACT = {"z-index", "isolation", "mix-blend-mode"}
REASON_ORDER = ["matched nothing", "zero-size", "off-screen", "covered", "out of view",
                "layout", "stacking", "drawn content"]


def one_line(text, limit=None):
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text[:limit] if limit else text


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def box_of(rule):
    box = rule.get("box")
    if not isinstance(box, dict):
        return None
    parts = [number(box.get(k)) for k in ("x", "y", "w", "h")]
    return None if None in parts else [int(round(p)) for p in parts]


def visibility_of(rule):
    if rule.get("inView") is False:
        return "out of view"
    top = rule.get("top")
    if top is True:
        return "visible"
    if top is False:
        return "covered by %s" % one_line(rule.get("coveredBy") or "another element", 60)
    if "top" in rule and top is None and rule.get("inView") is True:
        return "not checked"
    return None


def reasons_of(rule, page_size):
    found = set()
    if rule.get("matched") == 0:
        found.add("matched nothing")
        return found
    box = box_of(rule)
    if box is not None:
        x, y, w, h = box
        if w == 0 or h == 0:
            found.add("zero-size")
        elif page_size is not None and (x + w <= 0 or y + h <= 0 or x >= page_size[0] or y >= page_size[1]):
            found.add("off-screen")
    if rule.get("top") is False:
        found.add("covered")
    if rule.get("inView") is False:
        found.add("out of view")
    values = rule.get("values") if isinstance(rule.get("values"), dict) else {}
    for prop in values:
        if prop in LAYOUT_EXACT or prop.startswith(LAYOUT_PREFIX):
            found.add("layout")
        if prop in STACKING_EXACT or (prop.startswith("background") and rule.get("container") is True):
            found.add("stacking")
        if prop == "content":
            found.add("drawn content")
    return found


def rule_line(key, rule):
    key = one_line(key)
    selector = one_line(rule.get("selector", ""))
    if rule.get("matched") == 0:
        return "%s %s x0" % (key, selector)
    line = "%s %s x%s" % (key, selector, one_line(rule.get("matched", 1)))
    box = box_of(rule)
    if box is not None:
        line += " box %d,%d %dx%d" % tuple(box)
    visibility = visibility_of(rule)
    if visibility:
        line += " " + visibility
    values = rule.get("values") if isinstance(rule.get("values"), dict) else {}
    pairs = ["%s %s" % (one_line(p), one_line(v, LIMIT)) for p, v in values.items()]
    if pairs:
        line += (": " if visibility else " ") + "; ".join(pairs)
    return line


report = json.load(sys.stdin)
drops = sys.argv[1:]
view = report.get("view") if isinstance(report.get("view"), dict) else {}
size = report.get("pageSize") if isinstance(report.get("pageSize"), dict) else {}
vx, vy, vw, vh = (number(view.get(k)) for k in ("x", "y", "w", "h"))
pw, ph = number(size.get("w")), number(size.get("h"))
page_size = (pw, ph) if pw is not None and ph is not None else None
head = "APPLIED %s" % one_line(report.get("page", ""))
if None not in (vx, vy, vw, vh):
    head += " view %d,%d %dx%d" % (round(vx), round(vy), round(vw), round(vh))
if page_size is not None:
    head += " page %dx%d" % (round(pw), round(ph))
out = [head]
shots = []
blocks = report.get("blocks") if isinstance(report.get("blocks"), dict) else {}
for key, rules in blocks.items():
    reasons = set()
    for rule in rules if isinstance(rules, list) else []:
        if not isinstance(rule, dict):
            continue
        out.append(rule_line(key, rule))
        reasons |= reasons_of(rule, page_size)
    if reasons:
        shots.append("SHOT %s %s" % (one_line(key), ", ".join(r for r in REASON_ORDER if r in reasons)))
out.extend("%s dropped" % one_line(key) for key in drops)
out.extend(shots)
sys.stdout.write("\n".join(out) + "\n")
PYEOF

# json_field <field> - a top-level field of the JSON on stdin; prints nothing when absent or unreadable
json_field() {
  python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    sys.exit(0)
if value is not None:
    print(value)
' "$1" 2>/dev/null || true
}

# cmd_apply - writes the blocks and drops, asks the page to apply and measure,
# and prints what it measured. A page that cannot be reached, or did not
# confirm, gets the paste line instead; the file is the truth once written.
cmd_apply() {
  local dir port job id reply delivered report args=() targets=() entry probes target_count=0
  dir="$(session_dir)"
  for entry in ${APPLY_DROPS[@]+"${APPLY_DROPS[@]}"}; do
    args+=("d:$entry")
  done
  for entry in ${APPLY_TARGETS[@]+"${APPLY_TARGETS[@]}"}; do
    args+=("t:$entry")
    targets+=(--target "$entry")
    target_count=$((target_count + 1))
  done
  job="$(python3 -c "$SHEET_PY" "$dir/session.css" apply "" ${args[@]+"${args[@]}"})" || exit 1
  port="$(read_file "$dir/port")"
  report=""
  if is_number "$port" \
     && reply="$(printf '%s' "$job" | http_post_body "$port" /sheet 2>/dev/null)"; then
    delivered="$(printf '%s' "$reply" | json_field delivered)"
    if is_number "$delivered" && [ "$delivered" -ge 1 ]; then
      id="$(printf '%s' "$job" | json_field id)"
      report="$(http_call GET "$port" "/applied?id=$id&wait=5" 8 2>/dev/null)" || report=""
    fi
  fi
  if [ -z "$report" ] || [ -n "$(printf '%s' "$report" | json_field error)" ]; then
    echo "PASTE"
    python3 -c "$SHEET_PY" "$dir/session.css" print ""
    return 0
  fi
  if [ "$target_count" -gt 0 ]; then
    probes="$(printf '%s' "$report" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("probes") or []))' 2>/dev/null)" || probes="[]"
    printf '%s' "$probes" | bash "$SCRIPT_DIR/annotate-resolve.sh" resolve --root "$ROOT" --session "$SESSION" ${targets[@]+"${targets[@]}"} >/dev/null 2>&1 || true
  fi
  printf '%s' "$report" | python3 -c "$REPORT_PY" ${APPLY_DROPS[@]+"${APPLY_DROPS[@]}"} \
    || { echo "PASTE"; python3 -c "$SHEET_PY" "$dir/session.css" print ""; }
}

# The standby reader. Embedded program; argv: dir root session run.sh resolve.sh once
read -r -d '' WATCH_PY <<'PYEOF' || true
import json
import os
import re
import subprocess
import sys
import tempfile
import time

dir_path, root, session, run_sh, resolve_sh, once = sys.argv[1:7]
once = once == "1"
POLL = 0.25
LOG = os.path.join(dir_path, "changes.jsonl")
CURSOR = os.path.join(dir_path, "watch.cursor")
PID_FILE = os.path.join(dir_path, "watch.pid")
KEY_HEADER = re.compile(r"^/\* annotate-key ([A-Za-z0-9_-]+) \*/$", re.M)
LINE_BREAKS = {"\u0085": "\\u0085", " ": "\\u2028", " ": "\\u2029"}


def read_json(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return fallback


def run_id():
    run = read_json(os.path.join(dir_path, "run.json"), None)
    if not isinstance(run, dict):
        return None
    start = run.get("start_seq")
    start = start if isinstance(start, int) and not isinstance(start, bool) else 0
    return "%d@%s" % (start, run.get("started_at") or "")


def quoted(text):
    out = json.dumps("" if text is None else str(text), ensure_ascii=False)
    for char, escaped in LINE_BREAKS.items():
        out = out.replace(char, escaped)
    return out


def log_size():
    try:
        return os.path.getsize(LOG)
    except OSError:
        return 0


def read_cursor():
    try:
        with open(CURSOR, "r", encoding="utf-8") as handle:
            value = int(handle.read().strip())
        return min(max(value, 0), log_size())
    except (OSError, ValueError):
        return log_size()


def write_cursor(offset):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CURSOR), prefix=os.path.basename(CURSOR) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("%d\n" % offset)
        os.replace(tmp, CURSOR)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def new_batch(offset):
    """The complete lines past offset and the offset after them."""
    try:
        with open(LOG, "rb") as handle:
            handle.seek(offset)
            data = handle.read()
    except OSError:
        return [], offset
    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    changes = []
    for raw in data[:end + 1].split(b"\n"):
        try:
            change = json.loads(raw.decode("utf-8"))
        except ValueError:
            continue
        if isinstance(change, dict):
            changes.append(change)
    return changes, offset + end + 1


def sheet_keys():
    try:
        with open(os.path.join(dir_path, "session.css"), "r", encoding="utf-8") as handle:
            return set(KEY_HEADER.findall(handle.read()))
    except OSError:
        return set()


def resolve(changes):
    """One resolver call for every added or edited pin that has a probe item."""
    probes = read_json(os.path.join(dir_path, "probes.json"), {})
    probes = probes if isinstance(probes, dict) else {}
    items = []
    for change in changes:
        if change.get("kind") in ("added", "edited"):
            item = probes.get(str(change.get("ts")))
            if isinstance(item, dict) and item not in items:
                items.append(item)
    if items:
        subprocess.run(["bash", resolve_sh, "resolve", "--root", root, "--session", session],
                       input=json.dumps(items), capture_output=True, text=True)
    return probes


def source_of(ts, probes):
    if str(ts) not in probes:
        return "not probed"
    result = subprocess.run(["bash", resolve_sh, "where", "--root", root, "--session", session, "--ts", str(ts)],
                            capture_output=True, text=True)
    return " ".join(result.stdout.split()) or "not probed"


def drop(keys):
    """One apply call that removes the blocks; True when the page confirmed."""
    args = ["bash", run_sh, "apply", "--root", root, "--session", session]
    for key in keys:
        args += ["--drop", key]
    result = subprocess.run(args, input="", capture_output=True, text=True)
    return result.stdout.startswith("APPLIED")


def session_external():
    return os.path.isfile(os.path.join(dir_path, "external.json"))


def pin_page(change):
    pin = change.get("pin") if isinstance(change.get("pin"), dict) else {}
    page = pin.get("page")
    return page.strip() if isinstance(page, str) else ""


def guard_external(changes):
    """Run before a batch is printed. When any pin line will be external - the
    session is marked, or a pin's own page is outside the project - mark the
    session and remove the lift, so no pin arrives covered by an earlier yes.
    Returns the notice line when this call created the marker, else None."""
    pins = [c for c in changes if c.get("kind") in ("added", "edited")]
    first_page = None
    for change in pins:
        page = pin_page(change)
        if page and page_is_external(page):
            first_page = page
            break
    if first_page is None and not (pins and session_external()):
        return None
    created = mark_external(dir_path, first_page or "")
    revoke_lift(dir_path)
    return boundary_notice(dir_path) if created else None


def lines_for(changes):
    probes = resolve(changes)
    blocks = sheet_keys()
    doomed = []
    for change in changes:
        key = str(change.get("ts"))
        if change.get("kind") == "deleted" and key in blocks and key not in doomed:
            doomed.append(key)
    confirmed = drop(doomed) if doomed else False
    out = []
    for change in changes:
        kind, key = change.get("kind"), str(change.get("ts"))
        if kind in ("added", "edited"):
            pin = change.get("pin") if isinstance(change.get("pin"), dict) else {}
            tagged = session_external() or (pin_page(change) != "" and page_is_external(pin_page(change)))
            out.append("%s%s %s #%s %s at %s near %s source %s" % (
                "EXTERNAL " if tagged else "", kind.upper(), key, pin.get("n", "?"), quoted(pin.get("text")),
                quoted(pin.get("selector")), quoted(pin.get("nearText")),
                quoted(source_of(key, probes))))
        elif kind == "deleted" and key in doomed:
            out.append("UNDONE %s page %s" % (key, "confirmed" if confirmed else "did not confirm"))
    return out


def emit(lines):
    sys.stdout.write("".join(line + "\n" for line in lines))
    sys.stdout.flush()


def listener_answers():
    try:
        with open(os.path.join(dir_path, "port"), "r", encoding="utf-8") as handle:
            port = handle.read().strip()
        with local_request("GET", port, "/health", os.path.join(dir_path, "token"), 2) as response:
            return response.status == 200
    except (OSError, ValueError):
        return False


def listener_alive():
    try:
        with open(os.path.join(dir_path, "listener.pid"), "r", encoding="utf-8") as handle:
            os.kill(int(handle.read().strip()), 0)
        return True
    except (OSError, ValueError):
        return False


my_run = run_id()
if my_run is None:
    sys.stderr.write("annotate-run: no run in progress (run begin first)\n")
    sys.exit(1)
write_text(PID_FILE, "%d\n" % os.getpid())


def still_mine():
    try:
        with open(PID_FILE, "r", encoding="utf-8") as handle:
            owner = handle.read().strip()
    except OSError:
        return False
    return os.path.isdir(dir_path) and run_id() == my_run and owner == str(os.getpid())


offset = read_cursor()
tick = 0
failed_health = 0
reported = False
try:
    while still_mine():
        changes, end = new_batch(offset)
        if end != offset:
            notice = guard_external(changes)
            lines = lines_for(changes)
            if notice and lines:
                lines.insert(0, notice)
            if not still_mine():
                break
            # Source matching can take seconds, and a message typed meanwhile
            # writes a new lift; remove it again with nothing slow before the print.
            if any(line.startswith("EXTERNAL ") for line in lines):
                revoke_lift(dir_path)
            if lines:
                emit(lines)
            write_cursor(end)
            offset = end
            if lines and once:
                break
        # Once a second: a dead listener is an outage at once; a live one that
        # fails /health on two checks five seconds apart is too. After an outage
        # is reported the check runs every second so recovery re-arms the notice.
        if tick % 4 == 3:
            alive = listener_alive()
            if alive and (reported or tick % 20 == 19):
                failed_health = 0 if listener_answers() else failed_health + 1
            down = (not alive) or failed_health >= 2
            if down and not reported:
                emit(["UNREACHABLE"])
                reported = True
                if once:
                    break
            elif reported and not down and failed_health == 0:
                reported = False
        tick += 1
        time.sleep(POLL)
except (BrokenPipeError, KeyboardInterrupt):
    pass
PYEOF

cmd_watch() {
  local dir
  dir="$(session_dir)"
  [ -f "$dir/run.json" ] || die "no run in progress (run begin first)"
  exec python3 -c "$LOCAL_OPENER_PY
$PAGE_KIND_PY
$BOUNDARY_PY
$WATCH_PY" "$dir" "$ROOT" "$SESSION" "$SCRIPT_DIR/annotate-run.sh" "$SCRIPT_DIR/annotate-resolve.sh" "$WATCH_ONCE"
}

# cmd_kind - project when the page is a local one (file, or http/https on
# exactly localhost or 127.0.0.1, any port), external for everything else
cmd_kind() {
  [ -n "$PAGE" ] || die "--page <url> is required"
  page_kind "$PAGE"
}

page_kind() {
  python3 -c "$PAGE_KIND_PY
import sys
print('external' if page_is_external(sys.argv[1]) else 'project')" "$1"
}

# cmd_loader - the one line that loads the served overlay. It is an async
# function because evaluate_script awaits a function's return value but only
# runs an immediately invoked expression while building its handle. The session
# is resolved before the page kind on purpose: an external page is marked in its
# session folder and listed under that folder's owner, so a missing session dies
# here like every session verb rather than print EXTERNAL with nothing marked.
cmd_loader() {
  local dir port source stamp=""
  [ -n "$PAGE" ] || die "--page <url> is required"
  dir="$(session_dir)"
  if [ "$(page_kind "$PAGE")" != "project" ]; then
    echo "EXTERNAL"
    python3 -c "$BOUNDARY_PY
import sys

if mark_external(sys.argv[1], sys.argv[2]):
    print(boundary_notice(sys.argv[1]))" "$dir" "$PAGE"
    return 0
  fi
  port="$(read_file "$dir/port")"
  is_number "$port" || die "session $SESSION has no port"
  http_call GET "$port" /health >/dev/null 2>&1 || die "listener for $SESSION is not answering"
  [ "$RUN_STAMP" = "0" ] || stamp="$(run_stamp_js "$dir")"
  read -r -d '' source <<'PYEOF' || true
import json
import sys

port = int(sys.argv[1])
stamp = sys.argv[2]
token = read_token(sys.argv[3])
sys.stdout.write(
    "async () => { "
    "window.__craftAnnotatePort = %(port)d; "
    "window.__craftAnnotateToken = %(token_js)s; "
    "%(stamp)s"
    "if (window.__craftAnnotateInstalled) return 'LOADED'; "
    "try { "
    "return await new Promise((resolve) => { "
    "let timer = null; "
    "const settle = (status) => { clearTimeout(timer); resolve(status); }; "
    "const el = document.createElement('script'); "
    "el.src = 'http://127.0.0.1:%(port)d/overlay.js?token=%(token_q)s'; "
    "el.setAttribute('data-craft-annotate-injected', ''); "
    "el.onload = () => settle(window.__craftAnnotateInstalled ? 'LOADED' : 'SCRIPT-BLOCKED'); "
    "el.onerror = () => settle('SCRIPT-BLOCKED'); "
    "timer = setTimeout(() => settle('SCRIPT-BLOCKED'), 3000); "
    "document.head.appendChild(el); "
    "}); "
    "} catch (error) { return 'SCRIPT-BLOCKED'; } "
    "}\n" % {
        "port": port, "stamp": stamp, "token_js": json.dumps(token),
        "token_q": urllib.parse.quote(token, safe=""),
    }
)
PYEOF
  python3 -c "$LOCAL_OPENER_PY
$source" "$port" "$stamp" "$(token_file)"
}

# run_stamp_js <session-dir> - the statement that stamps the run id, with its
# trailing space; exits 1 when the session has no run
run_stamp_js() {
  python3 - "$1/run.json" <<'PYEOF' || die "session $SESSION has no run (begin writes run.json)"
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        run = json.load(handle)
    run_id = "%d@%s" % (run["start_seq"], run["started_at"])
except Exception:
    sys.exit(1)
sys.stdout.write("window.__craftAnnotateRun = %s; " % json.dumps(run_id))
PYEOF
}

# token_stamp_js <session-dir> - the statement that stamps the session token,
# with its trailing space; an empty string literal when the session has no token
token_stamp_js() {
  local source
  read -r -d '' source <<'PYEOF' || true
import json
import sys

sys.stdout.write("window.__craftAnnotateToken = %s; " % json.dumps(read_token(sys.argv[1])))
PYEOF
  python3 -c "$LOCAL_OPENER_PY
$source" "$1/token"
}

# cmd_stamp - the paste-path stamp for a page that blocks the loader: the port,
# the token and (unless --no-run) the run id, set without loading anything
cmd_stamp() {
  local dir port stamp="" token_js
  dir="$(session_dir)"
  port="$(read_file "$dir/port")"
  is_number "$port" || die "session $SESSION has no port"
  [ "$NO_RUN" = "1" ] || stamp="$(run_stamp_js "$dir")" || exit 1
  token_js="$(token_stamp_js "$dir")"
  echo "() => { window.__craftAnnotatePort = $port; ${token_js}${stamp}return 'STAMPED'; }"
}

# strip_overlay_py - Python source shared by bake and strip: removes every
# <script id="ca-overlay"> ... </script> element plus one following newline, and
# writes the page; it rides after BOUNDARY_PY, whose write_text it calls
read -r -d '' STRIP_PY <<'PYEOF' || true
import os
import re

OVERLAY_ELEMENT = re.compile(r'<script id="ca-overlay">.*?</script>\n?', re.DOTALL)


def strip_overlay(text):
    return OVERLAY_ELEMENT.subn("", text)


def write_page(path, text):
    """The page through write_text: a temp of this writer's own, so two bakes or
    strips at once never share one, and the mode a newly created file gets."""
    umask = os.umask(0)
    os.umask(umask)
    write_text(path, text, 0o666 & ~umask)
PYEOF

cmd_bake() {
  local dir port fence_file out
  [ -n "$FILE" ] || die "--file <path> is required"
  [ -f "$FILE" ] || die "no such file: $FILE"
  dir="$(session_dir)"
  port="$(read_file "$dir/port")"
  is_number "$port" || die "session $SESSION has no port"
  fence_file="$(mktemp)"
  if ! python3 "$CHANNEL_PY" --print-overlay > "$fence_file" 2>/dev/null; then
    rm -f "$fence_file"
    die "overlay source not found"
  fi
  if out="$(python3 -c "$BOUNDARY_PY
$STRIP_PY
$LOCAL_OPENER_PY
import json, os, sys

path, port, fence_path, token_file = sys.argv[1:5]
with open(path, encoding='utf-8', newline='') as handle:
    text = handle.read()
with open(fence_path, encoding='utf-8', newline='') as handle:
    fence = handle.read()
text, _ = strip_overlay(text)
at = text.rfind('</body>')
if at < 0 or not fence:
    sys.stderr.write('annotate-run: %s has no </body> to bake before\n' % path)
    sys.exit(1)
element = (
    '<script id=\"ca-overlay\">\n'
    'window.__craftAnnotatePort = %s;\n'
    'window.__craftAnnotateBaked = true;\n'
    'window.__craftAnnotateToken = %s;\n'
    '%s</script>\n' % (port, json.dumps(read_token(token_file)), fence)
)
write_page(path, text[:at] + element + text[at:])
" "$FILE" "$port" "$fence_file" "$(token_file)")"; then
    rm -f "$fence_file"
    echo "BAKED $FILE PORT $port"
  else
    rm -f "$fence_file"
    exit 1
  fi
}

cmd_strip() {
  local count
  [ -n "$FILE" ] || die "--file <path> is required"
  [ -f "$FILE" ] || die "no such file: $FILE"
  count="$(python3 -c "$BOUNDARY_PY
$STRIP_PY
import sys

path = sys.argv[1]
with open(path, encoding='utf-8', newline='') as handle:
    text = handle.read()
text, count = strip_overlay(text)
if count:
    write_page(path, text)
print(count)
" "$FILE")" || die "could not strip $FILE"
  echo "STRIPPED $count"
}

# ensure: the read-beat health check. A live listener resets the failure streak;
# a dead or hung one is terminated (only if the pid is still a listener), restarted
# through the arm path, and counted. The streak lives in a file because "did the
# last beat re-arm?" is exactly what a model forgets.
cmd_ensure() {
  local dir port pid streak ticks=0 out new_port
  [ -n "$ROOT" ] || die "no craft project root (pass --root or set CRAFT_PROJECT_ROOT)"
  dir="$ROOT/.craft/annotations/$SESSION"
  # A swept or never-armed folder stays gone: re-creating it would apply an empty sheet.
  if ! valid_session_id "$SESSION" || [ ! -d "$dir" ]; then
    echo "GONE"
    return 1
  fi
  port="$(read_file "$dir/port")"
  if is_number "$port" && http_call GET "$port" /health >/dev/null 2>&1; then
    write_session_files "$dir/rearm.streak" 0
    echo "OK PORT $port"
    return 0
  fi

  pid="$(read_file "$dir/listener.pid")"
  if is_number "$pid" && ps -o command= -p "$pid" 2>/dev/null | grep -q "annotate-channel"; then
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$ticks" -lt 10 ] && pid_alive "$pid"; do
      sleep 0.1
      ticks=$((ticks + 1))
    done
    pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
  fi
  # arm returns early on any live pid in this file, so a recycled pid must not stay in it.
  rm -f "$dir/listener.pid"

  if ! out="$(cmd_arm 2>/dev/null)"; then
    echo "FAILED"
    return 1
  fi
  new_port="$(read_file "$dir/port")"
  streak="$(read_file "$dir/rearm.streak")"
  is_number "$streak" || streak=0
  streak=$((streak + 1))
  write_session_files "$dir/rearm.streak" "$streak"
  echo "REARMED PORT $new_port STREAK $streak"
}

cmd_send() {
  local dir port body
  dir="$(session_dir)"
  port="$(read_file "$dir/port")"
  is_number "$port" || die "session $SESSION has no port"
  body="$(cat)"
  # An external pin must never ride an earlier yes: the lift goes before the post.
  printf '%s' "$body" | python3 -c "$PAGE_KIND_PY
$BOUNDARY_PY
import json
import os
import sys

session_dir = sys.argv[1]
try:
    pins = json.load(sys.stdin)
except ValueError:
    pins = []
pages = [pin.get('page') for pin in pins if isinstance(pin, dict)] if isinstance(pins, list) else []
external = any(isinstance(page, str) and page.strip() and page_is_external(page) for page in pages)
if external or os.path.isfile(os.path.join(session_dir, 'external.json')):
    revoke_lift(session_dir)" "$dir"
  printf '%s' "$body" | http_post_body "$port" /pins || die "listener for $SESSION is not answering"
}

cmd_disarm() {
  local dir pid
  dir="$(session_dir)"
  pid="$(read_file "$dir/listener.pid")"
  if is_number "$pid"; then
    kill "$pid" 2>/dev/null || true
  fi
  # The folder is going, so its external-page entry goes first, the way clear
  # drops it; the owner's other sessions stay listed.
  python3 -c "$BOUNDARY_PY
import sys

unmark_external(sys.argv[1])" "$dir"
  rm -rf "$dir"
}

# An open run is a folder with run.json, no record.md and an owner that is not a
# dead pid. An unreadable or missing owner counts as open: unknown is never
# treated as dead. Prints OPEN <id> <subject> per open run; with none, prints the
# canonical clear as one function line. Writes nothing and contacts no listener.
cmd_review_clear() {
  local dir id owner subject open=0 clear
  if [ -n "$ROOT" ]; then
    for dir in "$ROOT"/.craft/annotations/*/; do
      [ -d "$dir" ] || continue
      [ -f "$dir/record.md" ] && continue
      [ -f "$dir/run.json" ] || continue
      owner="$(read_file "$dir/owner.pid")"
      if is_number "$owner" && ! pid_alive "$owner"; then
        continue
      fi
      id="$(basename "$dir")"
      subject="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        text = str(json.load(fh).get("subject", "")).replace("\n", " ").strip()
except Exception:
    text = ""
print(text or "-")
' "$dir/run.json" 2>/dev/null || echo "-")"
      echo "OPEN $id $subject"
      open=1
    done
  fi
  [ "$open" = "0" ] || return 0
  clear="$(python3 "$CHANNEL_PY" --print-clear)" || exit 1
  echo "() => { $clear return 'CLEARED'; }"
}

# Reaps session dirs whose owning session process is dead. A dir with no
# readable owner is left alone: unknown is never treated as dead.
sweep_all() {
  local dir owner listener boundary pointer dead=""
  # Boundary pointers are per user, not per project: one whose owner is gone keeps
  # the block's cheap path off for every session, and the block never reaches it.
  # A dead owner's pointer, lift and lock go together, under that lock; a lock
  # with no pointer is one an older version left behind.
  boundary="${CRAFT_ANNOTATE_BOUNDARY_DIR:-$HOME/.cache/craft/annotate-boundary}"
  for pointer in "$boundary"/*.json "$boundary"/*.lock; do
    [ -f "$pointer" ] || continue
    owner="${pointer##*/}"
    owner="${owner%.*}"
    is_number "$owner" || continue
    case " $dead " in *" $owner "*) continue ;; esac
    pid_alive "$owner" || dead="$dead $owner"
  done
  if [ -n "$dead" ]; then
    # $dead is unquoted on purpose: it holds digit-only owners split on spaces.
    python3 -c "$BOUNDARY_PY
import sys

for owner in sys.argv[1:]:
    edit_pointer(owner, lambda sessions: [])" $dead || true
  fi
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
[ -n "$VERB" ] || die "usage: annotate-run.sh arm|status|wait|clear|announce|begin|watch|sheet|kind|apply|stamp|loader|bake|strip|ensure|send|review-clear|sweep|disarm [options]"
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
APPLY_DROPS=()
APPLY_TARGETS=()
RUN_STAMP=0
NO_RUN=0
WATCH_ONCE=0
PAGE=""
FILE=""
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
    --page)      [ $# -ge 2 ] || die "--page needs a value"; PAGE="$2"; shift 2 ;;
    --file)      [ $# -ge 2 ] || die "--file needs a value"; FILE="$2"; shift 2 ;;
    --add)       SHEET_ADD=1; shift ;;
    --drop)      [ $# -ge 2 ] || die "--drop needs a value"; SHEET_DROP="$2"; APPLY_DROPS+=("$2"); shift 2 ;;
    --target)    [ $# -ge 2 ] || die "--target needs a value"; case "$2" in ?*=?*) ;; *) die "--target must look like TS=SELECTOR" ;; esac; APPLY_TARGETS+=("$2"); shift 2 ;;
    --run)       RUN_STAMP=1; shift ;;
    --no-run)    NO_RUN=1; shift ;;
    --once)      WATCH_ONCE=1; shift ;;
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
  watch)  cmd_watch ;;
  sheet)  cmd_sheet ;;
  apply)  cmd_apply ;;
  stamp)  cmd_stamp ;;
  kind)   cmd_kind ;;
  loader) cmd_loader ;;
  bake)   cmd_bake ;;
  strip)  cmd_strip ;;
  ensure) cmd_ensure ;;
  send)   cmd_send ;;
  review-clear) cmd_review_clear ;;
  disarm) cmd_disarm ;;
  *)      die "unknown verb: $VERB" ;;
esac
