#!/bin/bash
# annotate-record.sh - File and graduate a .craft/annotations/<date>-<slug>/ record
# Usage:
#   annotate-record.sh file     [--root R] --session ID --outcome nothing|tweak|story|todo|abandon|error [--graduated-to REF]
#   annotate-record.sh graduate [--root R] --record NAME --to REF [--outcome story|tweak]
#
# file turns one finished /craft:annotate run into a kept record. It reads the
# live session folder (.craft/annotations/<ID>/): run.json names the run's start
# seq and subject, history.jsonl holds every SEND, session.css is the stylesheet
# that was injected live. It writes record.md and a byte copy of session.css into
# a new dated folder, removes run.json (so a run is filed exactly once) and prints
# the path to record.md. Everything else in the live folder stays where it is.
#
# Pins: a SEND posts the whole current set every time, so the same pin repeats
# across history entries. One record pin per identity - (page, ts), or
# (page, selector, text) when a pin has no ts - taken from the LAST entry that
# carries it, ordered by first appearance. Entries at or before start_seq belong
# to other flows sharing the listener and are ignored. A cleared entry adds
# nothing and removes nothing.
#
# Status: abandoned when the outcome is abandon, or the run sent no pins and left
# an empty sheet (nothing worth offering later); graduated when the outcome is
# tweak and a destination name came with it; otherwise open.
#
# Every frontmatter key is written on every record. A record folder never gets
# owner.pid, port or listener.pid - the sweep only reaps folders that hold an
# owner, so a record is never reaped.
#
# graduate rewrites only status, graduated_to and outcome in place.
#
# Output (stdout): the full path to record.md
# Exit: 0 on success; 1 on a usage error, a missing run.json or record, or an
# invalid outcome (validation fails before any write)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "annotate-record: $*" >&2
  exit 1
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

VERB="${1:-}"
[ -n "$VERB" ] || die "usage: annotate-record.sh file|graduate [options]"
shift

ROOT_ARG=""
SESSION=""
OUTCOME=""
GRADUATED_TO=""
RECORD=""
TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)         [ $# -ge 2 ] || die "--root needs a value"; ROOT_ARG="$2"; shift 2 ;;
    --session)      [ $# -ge 2 ] || die "--session needs a value"; SESSION="$2"; shift 2 ;;
    --outcome)      [ $# -ge 2 ] || die "--outcome needs a value"; OUTCOME="$2"; shift 2 ;;
    --graduated-to) [ $# -ge 2 ] || die "--graduated-to needs a value"; GRADUATED_TO="$2"; shift 2 ;;
    --record)       [ $# -ge 2 ] || die "--record needs a value"; RECORD="$2"; shift 2 ;;
    --to)           [ $# -ge 2 ] || die "--to needs a value"; TO="$2"; shift 2 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

ROOT="$(resolve_root "$ROOT_ARG")"
[ -n "$ROOT" ] || die "no craft project root (pass --root or set CRAFT_PROJECT_ROOT)"
ANN_DIR="$ROOT/.craft/annotations"

cmd_file() {
  local live
  case "$SESSION" in
    ''|*[!A-Za-z0-9_-]*) die "--session <id> is required" ;;
  esac
  case "$OUTCOME" in
    nothing|tweak|story|todo|abandon|error) ;;
    *) die "outcome must be one of nothing|tweak|story|todo|abandon|error" ;;
  esac
  live="$ANN_DIR/$SESSION"
  [ -f "$live/run.json" ] || die "no run to file for session $SESSION (run.json is missing)"

  python3 - "$live" "$ANN_DIR" "$SESSION" "$OUTCOME" "$GRADUATED_TO" "$(date +%Y-%m-%d)" <<'PYEOF'
import json
import os
import re
import sys

live, ann_dir, session, outcome, graduated_to, today = sys.argv[1:7]


def read_text(name):
    try:
        with open(os.path.join(live, name), "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def as_seq(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def slugify(text):
    raw = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if len(raw) > 50:
        trunc = raw[:50]
        cut = trunc.rsplit("-", 1)[0]
        raw = cut if cut and cut != trunc and len(cut) >= 20 else trunc
    return raw or "annotate"


def one_line(text):
    return " ".join(str(text).split())


def scalar(text):
    """A frontmatter value: plain when safe, a JSON string when YAML would misread it."""
    text = one_line(text)
    if re.search(r"(^[-?:,\[\]{}#&*!|>'\"%@`])|(: )|( #)|(:$)", text):
        return json.dumps(text)
    return text


try:
    run = json.loads(read_text("run.json"))
    if not isinstance(run, dict):
        raise ValueError("run.json is not an object")
except ValueError as error:
    sys.stderr.write("annotate-record: run.json is unreadable (%s)\n" % error)
    sys.exit(1)

start_seq = as_seq(run.get("start_seq"))
subject = one_line(run.get("subject") or "")

PIN_FIELDS = ("selector", "nearText", "candidate", "page", "box", "component", "ts", "x", "y")
order = []
latest = {}
seq_to = start_seq
for line in read_text("history.jsonl").splitlines():
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if not isinstance(entry, dict) or as_seq(entry.get("seq")) <= start_seq:
        continue
    seq = as_seq(entry.get("seq"))
    seq_to = max(seq_to, seq)
    pins = entry.get("pins")
    if entry.get("cleared") or not isinstance(pins, list):
        continue
    dicts = [pin for pin in pins if isinstance(pin, dict)]
    dicts.sort(key=lambda pin: as_seq(pin.get("n")))
    for pin in dicts:
        if pin.get("ts") is not None:
            key = (pin.get("page"), pin.get("ts"))
        else:
            key = (pin.get("page"), pin.get("selector"), pin.get("text"))
        if key not in latest:
            order.append(key)
        record_pin = {"seq": seq, "sent_at": entry.get("sent_at"), "text": pin.get("text")}
        for field in PIN_FIELDS:
            record_pin[field] = pin.get(field)
        latest[key] = record_pin

pins_out = []
for ordinal, key in enumerate(order, start=1):
    source = latest[key]
    pins_out.append({
        "n": ordinal,
        "seq": source["seq"],
        "sent_at": source["sent_at"],
        "text": source["text"],
        "selector": source["selector"],
        "nearText": source["nearText"],
        "candidate": source["candidate"],
        "page": source["page"],
        "box": source["box"],
        "component": source["component"],
        "ts": source["ts"],
        "x": source["x"],
        "y": source["y"],
    })

sheet = read_text("session.css")
rule_count = len(re.findall(r"^/\* annotate-key [A-Za-z0-9_-]+ \*/$", sheet, re.M))

if outcome == "abandon" or (not pins_out and not sheet.strip()):
    status = "abandoned"
elif outcome == "tweak" and graduated_to:
    status = "graduated"
else:
    status = "open"

os.makedirs(ann_dir, exist_ok=True)
base = "%s-%s" % (today, slugify(subject))
name = base
counter = 2
while True:
    try:
        os.mkdir(os.path.join(ann_dir, name))
        break
    except FileExistsError:
        name = "%s-%d" % (base, counter)
        counter += 1
folder = os.path.join(ann_dir, name)

reading = []
for pin in pins_out:
    anchor = pin["component"] or pin["nearText"]
    parts = ['%d. "%s"' % (pin["n"], one_line(pin["text"] if pin["text"] is not None else ""))]
    if pin["selector"]:
        parts.append("`%s`" % one_line(pin["selector"]))
    if anchor:
        parts.append(one_line(anchor))
    reading.append(" - ".join(parts))

lines = [
    "---",
    "source: annotate",
    "name: %s" % name,
    "created: %s" % today,
    "subject: %s" % scalar(subject),
    "status: %s" % status,
    "outcome: %s" % outcome,
    "graduated_to: %s" % scalar(graduated_to),
    "session: %s" % session,
    "seq_from: %d" % start_seq,
    "seq_to: %d" % seq_to,
    "pin_count: %d" % len(pins_out),
    "rule_count: %d" % rule_count,
    "---",
    "",
    "# %s" % (subject or "annotate"),
    "",
    "## Pins",
    "",
]
lines += reading if reading else ["No pins were sent."]
lines += [
    "",
    "## Pin Data",
    "",
    "```json",
    json.dumps(pins_out, indent=2),
    "```",
    "",
    "## Sheet",
    "",
    "`session.css` beside this file holds every change injected live, keyed by pin, and is normative.",
    "",
]

try:
    with open(os.path.join(folder, "session.css"), "w", encoding="utf-8") as handle:
        handle.write(sheet)
    with open(os.path.join(folder, "record.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    os.remove(os.path.join(live, "run.json"))
except OSError as error:
    for leftover in ("record.md", "session.css"):
        try:
            os.remove(os.path.join(folder, leftover))
        except OSError:
            pass
    os.rmdir(folder)
    sys.stderr.write("annotate-record: could not write the record (%s)\n" % error)
    sys.exit(1)

print(os.path.join(folder, "record.md"))
PYEOF
}

cmd_graduate() {
  local file
  case "$RECORD" in
    ''|*/*|.*) die "--record <name> is required" ;;
  esac
  [ -n "$TO" ] || die "--to <ref> is required"
  case "${OUTCOME:-story}" in
    story|tweak) ;;
    *) die "graduate outcome must be story or tweak" ;;
  esac
  file="$ANN_DIR/$RECORD/record.md"
  [ -f "$file" ] || die "no such record: $RECORD"

  python3 - "$file" "$TO" "${OUTCOME:-story}" <<'PYEOF'
import os
import re
import sys

path, destination, outcome = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as handle:
    lines = handle.read().split("\n")

wanted = {"status": "graduated", "graduated_to": destination, "outcome": outcome}
fences = 0
for index, line in enumerate(lines):
    if line == "---":
        fences += 1
        if fences == 2:
            break
        continue
    found = re.match(r"([a-z_]+):", line)
    if fences == 1 and found and found.group(1) in wanted:
        lines[index] = "%s: %s" % (found.group(1), wanted[found.group(1)])

tmp_path = path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
os.replace(tmp_path, path)
print(path)
PYEOF
}

case "$VERB" in
  file)     cmd_file ;;
  graduate) cmd_graduate ;;
  *)        die "unknown verb: $VERB" ;;
esac

# Refresh the dashboard graph data. Silenced so callers still read this
# script's own final line; guarded so a missing wrapper never fails a flow.
bash "$SCRIPT_DIR/../../scripts/dashboard/dashboard-run.sh" --root "$ROOT" >/dev/null 2>&1 || true
