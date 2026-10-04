#!/bin/bash
# bugs-hit.sh - Record a recurrence on an open bug: bump hits, stamp the Log
# Usage: bugs-hit.sh <FILE> --where="<text>"
#
# <FILE> is the exact path bugs-list.sh prints on a record's FILE= line. Only
# the text between the --- fences changes in the frontmatter: `hits:` becomes
# the old integer plus one (an absent or non-integer value counts as 1, so the
# result is 2). A body line that merely looks like `hits: ...` is never
# touched. One line, `- <date> hit again: <where>`, is appended to `## Log`
# (the section is created when the record has none).
#
# The target must be an existing dated record directly inside .craft/bugs/
# whose fence holds `type: bug`. A record in closed/ is refused. Every refusal
# exits 2 with nothing written.
#
# Output (stdout): TITLE=<symptom line>, HITS=<n>, then the record's path
# Exit: 0 on success, 2 on any refusal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$CRAFT_PROJECT_ROOT" ]; then
  ROOT="${CRAFT_PROJECT_ROOT%/}"
else
  source "$SCRIPT_DIR/find-workshop.sh" >/dev/null 2>&1 || true
  ROOT="${PROJECT_ROOT%/}"
fi
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$ROOT" ]; then
  ROOT="$PWD"
fi

OPEN_DIR="$ROOT/.craft/bugs"
CLOSED_DIR="$OPEN_DIR/closed"

TARGET=""
WHERE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --where=*) WHERE="${1#*=}" ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) [ -z "$TARGET" ] && TARGET="$1" ;;
  esac
  shift
done

if [ -z "$TARGET" ]; then
  echo "missing target: the FILE= path of an open bug" >&2
  exit 2
fi
# The Log entry would read "hit again: " with nothing after it.
if [ -z "$(printf '%s' "$WHERE" | tr -d '[:space:]')" ]; then
  echo "missing --where" >&2
  exit 2
fi

# ── Resolve the target: a file directly inside the open room ──────────
DATED_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-.+\.md$'
BASE="$(basename "$TARGET")"
NAME="${BASE%.md}"

if [ ! -f "$TARGET" ]; then
  echo "not found: $NAME" >&2
  exit 2
fi

TARGET_DIR="$(cd "$(dirname "$TARGET")" && pwd -P)"
if [ "$TARGET_DIR" = "$(cd "$CLOSED_DIR" 2>/dev/null && pwd -P)" ]; then
  echo "already closed: $NAME" >&2
  exit 2
fi
if [ "$TARGET_DIR" != "$(cd "$OPEN_DIR" 2>/dev/null && pwd -P)" ] || ! [[ "$BASE" =~ $DATED_RE ]]; then
  echo "not an open bug record: $NAME" >&2
  exit 2
fi
SRC="$OPEN_DIR/$BASE"

# ── Build the finished file (fence-scoped frontmatter edit, Log line) ──
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
TODAY=$(date +%Y-%m-%d)

python3 - "$SRC" "$WORK_DIR/hit.md" "$WORK_DIR/title.txt" "$WORK_DIR/hits.txt" \
  "$WHERE" "$TODAY" "$NAME" <<'PYEOF'
import re
import sys

src, out, title_path, hits_path, where, today, name = sys.argv[1:8]

# newline='' keeps every byte we do not edit exactly as it was
with open(src, encoding='utf-8', errors='surrogateescape', newline='') as f:
    content = f.read()

m = re.match(r'^(---\n)(.*?)(\n---\n?)(.*)$', content, re.DOTALL)
if not m or not re.search(r'^type:[ \t]*bug[ \t]*$', m.group(2), re.MULTILINE):
    sys.stderr.write('not an open bug record: ' + name + '\n')
    sys.exit(2)
head, fm, fence_tail, body = m.groups()


def one_line(text):
    return re.sub(r'\s+', ' ', text).strip()


def set_key(fm, key, value):
    line = key + ': ' + value
    pattern = r'^' + re.escape(key) + r':.*$'
    if re.search(pattern, fm, re.MULTILINE):
        return re.sub(pattern, lambda mm: line, fm, count=1, flags=re.MULTILINE)
    return fm + '\n' + line


current = re.search(r'^hits:[ \t]*(\d+)[ \t]*$', fm, re.MULTILINE)
hits = (int(current.group(1)) if current else 1) + 1
fm = set_key(fm, 'hits', str(hits))

entry = '- ' + today + ' hit again: ' + one_line(where)


def add_log(text, entry):
    """Append entry as the last line of '## Log'; else create the section
    before '## Notes' if present, else at the end."""
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
    return text.rstrip('\n') + '\n\n## Log\n\n' + entry + '\n'


body = add_log(body, entry)
if not body.endswith('\n'):
    body += '\n'

title = next((l.strip() for l in body.split('\n') if l.strip()), '')
with open(title_path, 'w', encoding='utf-8', errors='surrogateescape') as f:
    f.write(title)
with open(hits_path, 'w') as f:
    f.write(str(hits))
with open(out, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
    f.write(head + fm + fence_tail + body)
PYEOF
RC=$?
if [ "$RC" -ne 0 ]; then
  exit "$RC"
fi

# ── Write a temp sibling, then move it over the source ────────────────
cat "$WORK_DIR/hit.md" > "$SRC.tmp" && mv "$SRC.tmp" "$SRC"
if [ -e "$SRC.tmp" ]; then
  rm -f "$SRC.tmp"
  echo "could not write $BASE" >&2
  exit 1
fi

echo "TITLE=$(cat "$WORK_DIR/title.txt")"
echo "HITS=$(cat "$WORK_DIR/hits.txt")"
echo "$SRC"
