#!/bin/bash
# notebook-notes-index.sh - Emit the lightweight one-line-per-note index
# Usage: notebook-notes-index.sh
#
# Output (stdout): a compact markdown block, one bullet per durable note:
#   - <distilled fact> _(facet: <facet>; as of <created>)_ [<slug>]
# Preceded by a single header line, emitted ONLY when at least one note exists.
#
# This index is the staleness mechanism (a MEMORY.md-style always-loaded
# surface). The session-start hook injects it so durable project facts stay in
# peripheral vision; full note bodies are read on demand at recall time.
#
# Notes carry no lifecycle status, so there is no status filtering: every file
# in notes/ is listed.
# Exit: 0 always (no output if there are no notes)

set -e

if [ -n "$CRAFT_PROJECT_ROOT" ]; then
  ROOT="${CRAFT_PROJECT_ROOT%/}"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/find-workshop.sh" 2>/dev/null || true
  ROOT="${PROJECT_ROOT%/}"
fi

if [ -z "$ROOT" ]; then
  exit 0
fi

NOTES_DIR="$ROOT/.craft/notebook/notes"

if [ ! -d "$NOTES_DIR" ]; then
  exit 0
fi

LINES=""
for file in $(ls "$NOTES_DIR"/*.md 2>/dev/null | sort); do
  [ -e "$file" ] || continue

  parsed=$(python3 - "$file" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

m = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
if not m:
    sys.exit(0)
fm, body = m.group(1), m.group(2)

def get(field):
    mm = re.search(r'^' + re.escape(field) + r':\s*(.*)$', fm, re.MULTILINE)
    return mm.group(1).strip() if mm else ''

facet = get('facet')
date = get('created')

fact = ''
for line in body.splitlines():
    s = line.strip()
    if s:
        fact = s
        break

print(f'FACET={facet}')
print(f'DATE={date}')
print(f'FACT={fact}')
PYEOF
)

  facet=$(printf '%s\n' "$parsed" | sed -n 's/^FACET=//p' | head -1)
  date=$(printf '%s\n' "$parsed" | sed -n 's/^DATE=//p' | head -1)
  fact=$(printf '%s\n' "$parsed" | sed -n 's/^FACT=//p' | head -1)

  base=$(basename "$file" .md)
  slug="${base#${date}-}"

  if [ -n "$facet" ]; then
    meta="facet: $facet; as of $date"
  else
    meta="as of $date"
  fi

  LINES="${LINES}- ${fact} _(${meta})_ [${slug}]"$'\n'
done

if [ -n "$LINES" ]; then
  echo "Notebook notes (durable project facts - treat as \"as of\" the date; verify before acting):"
  printf '%s' "$LINES"
fi

exit 0
