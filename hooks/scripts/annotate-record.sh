#!/bin/bash
# annotate-record.sh - File and graduate a .craft/annotations/<date>-<slug>/ record
# Usage:
#   annotate-record.sh file     [--root R] --session ID --outcome nothing|tweak|story|todo|abandon|error [--graduated-to REF]
#   annotate-record.sh graduate [--root R] --record NAME --to REF [--outcome story|tweak|todo]
#   annotate-record.sh close    [--root R] --record NAME
#   annotate-record.sh cut-short [--root R]
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
# A run cut short is a record that reads status open and outcome error: the run
# was filed by the cleanup after a closed window, or by the next run on the same
# session, with no ending chosen. cut-short lists them, one line each -
#   CUT <name> PINS <pin_count> <subject>
# - newest record.md first (ties by name, descending), prints nothing when there
# are none, and writes nothing, not even the dashboard refresh. close marks a
# record abandoned (its files stay); an abandoned record is left as it is, and a
# graduated one is refused.
#
# A run picked up from a cut-short record (begin --resume NAME) names it as
# "resumes" in run.json. Filing that run puts the old record's pins first, in
# order; a pin of the new run with the same identity replaces its old copy. Once
# the new record is written the old one becomes graduated, with graduated_to
# naming the new record, if it still reads open.
#
# Output (stdout): the full path to record.md (cut-short: the lines above)
# Exit: 0 on success; 1 on a usage error, a missing run.json or record, a
# graduated record given to close, or an invalid outcome (validation fails
# before any write)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where the graduate program finds annotate_write.py, the one atomic write:
# this script's own folder, set here so an inherited value never counts.
export CRAFT_ANNOTATE_SCRIPTS_DIR="$SCRIPT_DIR"

die() {
  echo "annotate-record: $*" >&2
  exit 1
}

# Project folder: --root, then CRAFT_PROJECT_ROOT or the set-up project, then the
# nearest folder above this one that already holds the named session or record.
source "$SCRIPT_DIR/annotate-root.sh"

VERB="${1:-}"
[ -n "$VERB" ] || die "usage: annotate-record.sh file|graduate|close|cut-short [options]"
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

# file names a session, graduate names a record; each is found by that name.
case "$VERB" in
  file)     LOOKUP_NAME="$SESSION" ;;
  graduate|close) LOOKUP_NAME="$RECORD" ;;
  *)        LOOKUP_NAME="" ;;
esac
ROOT="$(annotate_root "$ROOT_ARG" "$LOOKUP_NAME")"
# An empty root is reported by the verb in its own words once it knows what was
# asked for; a verb that names nothing has no better thing to say.
if [ -z "$ROOT" ]; then
  case "$VERB" in
    file|graduate|close) ;;
    *) die "no craft project root (pass --root or set CRAFT_PROJECT_ROOT)" ;;
  esac
fi
ANN_DIR="$ROOT/.craft/annotations"

# A record name is one folder name: no path, not hidden.
safe_record_name() {
  case "$1" in
    ''|*/*|.*) return 1 ;;
  esac
  return 0
}

cmd_file() {
  local live resumes new_record filed path
  case "$SESSION" in
    ''|*[!A-Za-z0-9_-]*) die "--session <id> is required" ;;
  esac
  case "$OUTCOME" in
    nothing|tweak|story|todo|abandon|error) ;;
    *) die "outcome must be one of nothing|tweak|story|todo|abandon|error" ;;
  esac
  live="$ANN_DIR/$SESSION"
  [ -n "$ROOT" ] && [ -f "$live/run.json" ] || die "no run to file for session $SESSION (run.json is missing)"

  # The record this run picked up, if any: its pins go first in the new record.
  resumes="$(sed -n 's/.*"resumes": *"\([^"]*\)".*/\1/p' "$live/run.json" 2>/dev/null | head -n 1)"
  safe_record_name "$resumes" || resumes=""

  new_record="$(mktemp)"
  filed=0
  python3 - "$live" "$ANN_DIR" "$SESSION" "$OUTCOME" "$GRADUATED_TO" "$(date +%Y-%m-%d)" "$resumes" > "$new_record" <<'PYEOF' || filed=$?
import json
import os
import re
import sys

live, ann_dir, session, outcome, graduated_to, today, resumes = sys.argv[1:8]


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

def carried_pins():
    """The pins in the resumed record's Pin Data block, or none when it is missing or unreadable."""
    if not resumes:
        return []
    try:
        with open(os.path.join(ann_dir, resumes, "record.md"), "r", encoding="utf-8") as handle:
            lines = handle.read().split("\n")
    except (OSError, UnicodeDecodeError):
        return []
    block = []
    state = "seeking"
    for line in lines:
        if state == "seeking" and line.strip() == "## Pin Data":
            state = "heading"
        elif state == "heading" and line.strip() == "```json":
            state = "inside"
        elif state == "inside":
            if line.strip() == "```":
                break
            block.append(line)
    try:
        pins = json.loads("\n".join(block))
    except ValueError:
        return []
    return [pin for pin in pins if isinstance(pin, dict)] if isinstance(pins, list) else []


PIN_FIELDS = ("selector", "nearText", "candidate", "page", "box", "component", "ts", "x", "y")
order = []
latest = {}
seq_to = start_seq
withdrawn = set()
entries = []
for line in read_text("history.jsonl").splitlines():
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if not isinstance(entry, dict) or as_seq(entry.get("seq")) <= start_seq:
        continue
    entries.append(entry)
    gone = entry.get("deleted")
    if isinstance(gone, list):
        withdrawn.update(str(ts) for ts in gone)

# Pins carried from the record this run picked up come first, in their order; a
# pin of this run with the same identity replaces its old copy where it stands.
for pin in carried_pins():
    if pin.get("ts") is not None and str(pin.get("ts")) in withdrawn:
        continue
    if pin.get("ts") is not None:
        key = (pin.get("page"), pin.get("ts"))
    else:
        key = (pin.get("page"), pin.get("selector"), pin.get("text"))
    if key not in latest:
        order.append(key)
    carried = {"seq": as_seq(pin.get("seq")), "sent_at": pin.get("sent_at"), "text": pin.get("text"), "resolved": pin.get("resolved")}
    for field in PIN_FIELDS:
        carried[field] = pin.get(field)
    latest[key] = carried

for entry in entries:
    seq = as_seq(entry.get("seq"))
    seq_to = max(seq_to, seq)
    pins = entry.get("pins")
    if entry.get("cleared") or not isinstance(pins, list):
        continue
    dicts = [pin for pin in pins if isinstance(pin, dict)]
    dicts.sort(key=lambda pin: as_seq(pin.get("n")))
    for pin in dicts:
        if pin.get("ts") is not None and str(pin.get("ts")) in withdrawn:
            continue
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

def load_resolutions():
    """The run's cached resolutions, or an empty cache when absent, unreadable or from another run."""
    empty = {"pins": {}, "targets": {}}
    try:
        cache = json.loads(read_text("resolutions.json"))
    except ValueError:
        return empty
    if not isinstance(cache, dict):
        return empty
    if cache.get("run") != "%s@%s" % (start_seq, run.get("started_at")):
        return empty
    pins = cache.get("pins")
    targets = cache.get("targets")
    return {
        "pins": pins if isinstance(pins, dict) else {},
        "targets": targets if isinstance(targets, dict) else {},
    }


resolutions = load_resolutions()


def resolved_for(pin):
    """The cached Resolution for a record pin, or None. Cache keys are (page, str(ts))."""
    page = pin["page"]
    page_targets = resolutions["targets"].get(page)
    if not isinstance(page_targets, dict):
        return None
    selector = pin["selector"]
    if pin["ts"] is not None:
        page_pins = resolutions["pins"].get(page)
        if not isinstance(page_pins, dict):
            return None
        selector = page_pins.get(str(pin["ts"]))
    found = page_targets.get(selector) if isinstance(selector, str) else None
    return found if isinstance(found, dict) else None


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
        "resolved": resolved_for(source) or source.get("resolved"),
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
    "`session.css` beside this file holds every change shown live, one keyed block per pin. Its look ports verbatim; a block that stands in for content graduates as a requirement quoting the pin.",
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
  path="$(cat "$new_record")"
  rm -f "$new_record"
  [ "$filed" -eq 0 ] || exit 1
  echo "$path"

  # The picked-up record is continued, not thrown away: it graduates to this one.
  if [ -n "$resumes" ]; then
    python3 -c "$FRONTMATTER_PY" "$ANN_DIR/$resumes/record.md" "open" "status=graduated" "graduated_to=$(basename "$(dirname "$path")")" >/dev/null 2>&1 \
      || echo "annotate-record: could not mark $resumes graduated; it stays as it is" >&2
  fi
}

# Rewrites named frontmatter keys of a record.md in place and keeps every other
# byte. argv: <record.md> <only-if-status or ""> KEY=VALUE...
# Exit 3, nothing written, when only-if-status is given and the record reads
# another status. Prints the path on success. The one atomic write the three
# writers (graduate, close, lineage) share.
read -r -d '' FRONTMATTER_PY <<'PYEOF' || true
import json
import os
import re
import sys

sys.path.insert(0, os.environ["CRAFT_ANNOTATE_SCRIPTS_DIR"])
import annotate_write
del sys.path[0]

path, only_if = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    lines = handle.read().split("\n")


def one_line(text):
    return " ".join(str(text).split())


def scalar(text):
    """A frontmatter value: plain when safe, a JSON string when YAML would misread it."""
    text = one_line(text)
    if re.search(r"(^[-?:,\[\]{}#&*!|>'\"%@`])|(: )|( #)|(:$)", text):
        return json.dumps(text)
    return text


wanted = {}
for pair in sys.argv[3:]:
    key, _, value = pair.partition("=")
    wanted[key] = scalar(value)

if only_if:
    fences = 0
    current = None
    for line in lines:
        if line == "---":
            fences += 1
            if fences == 2:
                break
            continue
        found = re.match(r"status: *(.*)$", line)
        if fences == 1 and found:
            current = found.group(1).strip()
            break
    if current != only_if:
        sys.exit(3)

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

# A temp of this writer's own, so two writers at once never share one; it
# gets the mode a newly created file gets, the mode the filer gave record.md.
umask = os.umask(0)
os.umask(umask)
annotate_write.write_atomic(path, "\n".join(lines), mode=0o666 & ~umask)
print(path)
PYEOF

# frontmatter_value <record.md> <key> - the key's raw value from the first frontmatter block
frontmatter_value() {
  awk -v k="$2" 'BEGIN{n=0} /^---$/{n++; if (n==2) exit; next} n==1 && index($0, k ":")==1 {sub("^" k ": *", ""); print; exit}' "$1"
}

cmd_graduate() {
  local file
  case "$RECORD" in
    ''|*/*|.*) die "--record <name> is required" ;;
  esac
  [ -n "$TO" ] || die "--to <ref> is required"
  case "${OUTCOME:-story}" in
    story|tweak|todo) ;;
    *) die "graduate outcome must be story, tweak or todo" ;;
  esac
  file="$ANN_DIR/$RECORD/record.md"
  [ -n "$ROOT" ] && [ -f "$file" ] || die "no such record: $RECORD"

  python3 -c "$FRONTMATTER_PY" "$file" "" "status=graduated" "graduated_to=$TO" "outcome=${OUTCOME:-story}"
}

cmd_close() {
  local file current
  case "$RECORD" in
    ''|*/*|.*) die "--record <name> is required" ;;
  esac
  file="$ANN_DIR/$RECORD/record.md"
  [ -n "$ROOT" ] && [ -f "$file" ] || die "no such record: $RECORD"

  current="$(frontmatter_value "$file" status)"
  case "$current" in
    abandoned) echo "$file"; return 0 ;;
    graduated) die "record $RECORD is graduated, so it stays as it is" ;;
  esac
  python3 -c "$FRONTMATTER_PY" "$file" "" "status=abandoned"
}

# One line per cut-short record (status open, outcome error), newest first.
cmd_cut_short() {
  [ -d "$ANN_DIR" ] || return 0
  python3 - "$ANN_DIR" <<'PYEOF'
import json
import os
import re
import sys

ann_dir = sys.argv[1]
found = []
for name in os.listdir(ann_dir):
    path = os.path.join(ann_dir, name, "record.md")
    try:
        mtime = os.stat(path).st_mtime
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError):
        continue
    values = {}
    fences = 0
    for line in text.split("\n"):
        if line == "---":
            fences += 1
            if fences == 2:
                break
            continue
        match = re.match(r"([a-z_]+): *(.*)$", line)
        if fences == 1 and match:
            values[match.group(1)] = match.group(2).strip()
    if values.get("status") != "open" or values.get("outcome") != "error":
        continue
    subject = values.get("subject", "")
    if subject.startswith('"'):
        try:
            subject = json.loads(subject)
        except ValueError:
            pass
    found.append((mtime, name, values.get("pin_count") or "0", subject))

found.sort(key=lambda row: (row[0], row[1]), reverse=True)
for _, name, pins, subject in found:
    print("CUT %s PINS %s %s" % (name, pins, " ".join(str(subject).split())))
PYEOF
}

case "$VERB" in
  file)      cmd_file ;;
  graduate)  cmd_graduate ;;
  close)     cmd_close ;;
  cut-short) cmd_cut_short; exit 0 ;;
  *)         die "unknown verb: $VERB" ;;
esac

# Refresh the dashboard graph data. Silenced so callers still read this
# script's own final line; guarded so a missing wrapper never fails a flow.
bash "$SCRIPT_DIR/../../scripts/dashboard/dashboard-run.sh" --root "$ROOT" >/dev/null 2>&1 || true
