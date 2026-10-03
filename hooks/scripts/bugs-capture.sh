#!/bin/bash
# bugs-capture.sh - File a bug record into .craft/bugs
# Usage: bugs-capture.sh --found-during="<text>" [--requirement="<text>"]
#          [--layer=code|spec|judgment] [--worked-before="<text>"]
#          [--verdict=bug|unspecified|spec-gap|not-reproducible]
#          [--tags=a,b] --stdin
#   The body arrives on stdin and starts with the symptom line. Words never sit
#   on the command line: a bug body is multi-line and full of quotes.
#
# Seven fields are required: the symptom line, found_during, Expected, Actual,
# Consequences, Blocks my next step, Reproduce. A field holding only an
# angle-bracket pointer counts as empty. A missing field prints
# `missing required field: <name>` to stderr (one line each) and exits 2 with
# nothing written - no file and no directory.
#
# Output (stdout): the absolute path of the written record as the last line
# Exit: 0 on success, 2 on refusal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$CRAFT_PROJECT_ROOT" ]; then
  ROOT="${CRAFT_PROJECT_ROOT%/}"
else
  source "$SCRIPT_DIR/find-workshop.sh" >/dev/null 2>&1 || true
  ROOT="${PROJECT_ROOT%/}"
fi

# Cold fallback: no initialized project resolved. Anchor to the git toplevel
# (never a subdirectory), else PWD, so filing works before /craft:init. A
# non-git landing spot is announced - an orphaned bug must be loud - but only
# after the record exists, so a refused filing never claims a file.
LOCAL_FILING=0
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$ROOT" ]; then
    ROOT="$PWD"
    LOCAL_FILING=1
  fi
fi

FOUND_DURING=""
REQUIREMENT=""
LAYER=""
WORKED_BEFORE=""
VERDICT=""
TAGS=""
HAVE_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --found-during=*) FOUND_DURING="${1#*=}" ;;
    --requirement=*) REQUIREMENT="${1#*=}" ;;
    --layer=*) LAYER="${1#*=}" ;;
    --worked-before=*) WORKED_BEFORE="${1#*=}" ;;
    --verdict=*) VERDICT="${1#*=}" ;;
    --tags=*) TAGS="${1#*=}" ;;
    --stdin) HAVE_STDIN=1 ;;
  esac
  shift
done

case "$LAYER" in
  ""|code|spec|judgment) ;;
  *) echo "invalid --layer: $LAYER" >&2; exit 2 ;;
esac
case "$VERDICT" in
  ""|bug|unspecified|spec-gap|not-reproducible) ;;
  *) echo "invalid --verdict: $VERDICT" >&2; exit 2 ;;
esac

if [ "$HAVE_STDIN" -ne 1 ]; then
  echo "missing flag: --stdin (the body arrives on stdin)" >&2
  exit 2
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cat > "$WORK_DIR/body.txt"

DATE=$(date +%Y-%m-%d)
CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Validate and assemble in one pass; nothing touches the project until it
# succeeds. The symptom line comes back through a file.
python3 - "$WORK_DIR/body.txt" "$WORK_DIR/record.md" "$WORK_DIR/symptom.txt" \
  "$DATE" "$CAPTURED_AT" "$FOUND_DURING" "$REQUIREMENT" "$LAYER" \
  "$WORKED_BEFORE" "$VERDICT" "$TAGS" <<'PYEOF'
import re
import sys

(body_path, out_path, symptom_path, date, captured_at, found_during,
 requirement, layer, worked_before, verdict, tags) = sys.argv[1:12]

with open(body_path, encoding='utf-8', errors='replace', newline='') as f:
    raw = f.read()

lines = raw.replace('\r\n', '\n').split('\n')
while lines and not lines[0].strip():
    lines.pop(0)
while lines and not lines[-1].strip():
    lines.pop()
body = '\n'.join(lines)


def is_empty(text):
    text = text.strip()
    return not text or re.match(r'^<[^>]*>$', text) is not None


def section(name):
    """Text under '## name' up to the next '## ' heading, or None."""
    m = re.search(r'^## ' + re.escape(name) + r'[ \t]*$', body, re.MULTILINE)
    if not m:
        return None
    rest = body[m.end():]
    nxt = re.search(r'^## ', rest, re.MULTILINE)
    return rest[:nxt.start()] if nxt else rest


def inline_field(label, stops):
    """Text after '**label.**' up to the first stop marker, or None."""
    m = re.search(re.escape('**' + label + '.**'), body)
    if not m:
        return None
    rest = body[m.end():]
    ends = [len(rest)]
    for stop in stops:
        s = re.search(stop, rest, re.MULTILINE)
        if s:
            ends.append(s.start())
    return rest[:min(ends)]


first = lines[0] if lines else ''
missing = []
if is_empty(first) or first.lstrip().startswith('#'):
    missing.append('symptom line')
if is_empty(found_during):
    missing.append('found_during')
if is_empty(inline_field('Expected', [r'\*\*Actual\.\*\*', r'^## ']) or ''):
    missing.append('Expected')
if is_empty(inline_field('Actual', [r'^## ']) or ''):
    missing.append('Actual')
if is_empty(section('Consequences') or ''):
    missing.append('Consequences')
blocks = section('Blocks my next step') or ''
blocks_first = next((l.strip() for l in blocks.split('\n') if l.strip()), '')
if is_empty(blocks_first) or not re.match(r'(?i)^(yes|no)\b', blocks_first):
    missing.append('Blocks my next step')
if is_empty(section('Reproduce') or ''):
    missing.append('Reproduce')

if missing:
    for name in missing:
        sys.stderr.write('missing required field: ' + name + '\n')
    sys.exit(2)


def one_line(text):
    return re.sub(r'\s+', ' ', text).strip()


def field(key, value):
    value = one_line(value)
    return key + ':' + (' ' + value if value else '')


def add_log(text, entry):
    """Append entry inside '## Log'; else add the section before '## Notes'
    if present, else at the end."""
    ls = text.split('\n')
    log = next((i for i, l in enumerate(ls) if re.match(r'^## Log[ \t]*$', l)), None)
    if log is not None:
        end = next((j for j in range(log + 1, len(ls)) if ls[j].startswith('## ')), len(ls))
        k = end
        while k > log + 1 and not ls[k - 1].strip():
            k -= 1
        ls.insert(k, entry)
        return '\n'.join(ls)
    notes = next((i for i, l in enumerate(ls) if re.match(r'^## Notes[ \t]*$', l)), None)
    if notes is not None:
        before = ls[:notes]
        while before and not before[-1].strip():
            before.pop()
        return '\n'.join(before + ['', '## Log', '', entry, ''] + ls[notes:])
    return text.rstrip('\n') + '\n\n## Log\n\n' + entry


tag_list = []
for t in tags.split(','):
    t = t.strip().lower()
    if t and re.match(r'^[a-z0-9][a-z0-9-]*$', t) and t not in tag_list:
        tag_list.append(t)

front = [
    '---',
    'type: bug',
    'created: ' + date,
    'captured_at: ' + captured_at,
    'status: open',
    field('verdict', verdict),
    field('found_during', found_during),
    field('requirement', requirement),
    field('layer', layer),
    field('worked_before', worked_before),
    'hits: 1',
    'fixed_by:',
    'tags: [' + ', '.join(tag_list) + ']',
    '---',
    '',
]

record = '\n'.join(front) + add_log(body, '- ' + date + ' filed')
with open(out_path, 'w', encoding='utf-8') as f:
    f.write(record.rstrip('\n') + '\n')
with open(symptom_path, 'w', encoding='utf-8') as f:
    f.write(first)
PYEOF
RC=$?
if [ "$RC" -ne 0 ]; then
  exit "$RC"
fi

SYMPTOM=$(cat "$WORK_DIR/symptom.txt")

# ── Slug (the notebook rule, applied to the symptom line) ─────────────
RAW_SLUG=$(printf '%s' "$SYMPTOM" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g' \
  | sed -E 's/^-//' \
  | sed -E 's/-$//')

# Cap at 50 chars (cut at the last hyphen when that leaves 20 or more)
if [ ${#RAW_SLUG} -gt 50 ]; then
  TRUNC="${RAW_SLUG:0:50}"
  LAST_HYPHEN_TRUNC="${TRUNC%-*}"
  if [ -n "$LAST_HYPHEN_TRUNC" ] && [ "$LAST_HYPHEN_TRUNC" != "$TRUNC" ] && [ ${#LAST_HYPHEN_TRUNC} -ge 20 ]; then
    SLUG="$LAST_HYPHEN_TRUNC"
  else
    SLUG="$TRUNC"
  fi
else
  SLUG="$RAW_SLUG"
fi
if [ -z "$SLUG" ]; then
  SLUG="untitled"
fi

# ── Folder on demand, collision suffix ────────────────────────────────
TARGET_DIR="$ROOT/.craft/bugs"
mkdir -p "$TARGET_DIR"

# Create the file with noclobber (an exclusive open), so two captures racing for
# the same name never overwrite each other: the loser bumps the suffix and retries.
TARGET_FILE="$TARGET_DIR/${DATE}-${SLUG}.md"
COUNTER=2
until ( set -C; cat "$WORK_DIR/record.md" > "$TARGET_FILE" ) 2>/dev/null; do
  if [ ! -e "$TARGET_FILE" ]; then
    echo "cannot write: $TARGET_FILE" >&2
    exit 1
  fi
  TARGET_FILE="$TARGET_DIR/${DATE}-${SLUG}-${COUNTER}.md"
  COUNTER=$((COUNTER + 1))
done

if [ "$LOCAL_FILING" -eq 1 ]; then
  echo "not a git repo - filed to $TARGET_FILE (local to this directory)" >&2
fi

# Refresh the dashboard graph data. Silenced so callers still read this
# script's own final line; guarded so a missing wrapper never fails a flow.
bash "$SCRIPT_DIR/../../scripts/dashboard/dashboard-run.sh" --root "$ROOT" >/dev/null 2>&1 || true

echo "$TARGET_FILE"
