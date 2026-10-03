#!/bin/bash
# bugs-list.sh - List filed bugs from .craft/bugs
# Usage: bugs-list.sh [--summary] [--status=open|fixed|wont-fix|closed]
#   Unknown flags are ignored.
#
# This script runs inside a slash-command shell injection: a non-zero exit
# aborts the whole invocation and stderr is merged into the prompt text. So it
# exits 0 on every path and never writes to stderr (no `set -e`).
#
# A record is a file whose basename is <YYYY-MM-DD>-<slug>.md AND whose text
# opens with a --- fence holding `type: bug`. That keeps README.md and
# _TEMPLATE.md (which carries real fenced frontmatter) from counting.
#
# Rooms: .craft/bugs/*.md is open, .craft/bugs/closed/*.md is closed. The
# folder is the truth: every root-room record is STATUS=open whatever its
# `status:` line says (old records carry `confirmed`). In closed/, STATUS is
# the frontmatter status when it is fixed or wont-fix, else `closed`. A dated
# filename present in both rooms is closed.
#
# --summary stdout:
#   Bugs: <N> open
#   - <title> - found during: <found_during> [blocks my next step]
# Default stdout: one key=value block per record, blank line between:
#   FILE= ROOM= SLUG= DATE= TITLE= STATUS= VERDICT= FOUND_DURING= LAYER= BLOCKS= HITS=
# Both are sorted newest first (captured_at, created, filename).
# --status=closed selects the whole closed room (fixed, wont-fix, and closed).

MODE="blocks"
STATUS_FILTER=""
for arg in "$@"; do
  case "$arg" in
    --summary) MODE="summary" ;;
    --status=*) STATUS_FILTER="${arg#--status=}" ;;
  esac
done

ROOT=""
if [ -n "${CRAFT_PROJECT_ROOT:-}" ]; then
  ROOT="${CRAFT_PROJECT_ROOT%/}"
else
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  ROOT=$(source "$SELF_DIR/find-workshop.sh" >/dev/null 2>&1; echo "${PROJECT_ROOT:-}" 2>/dev/null)
  ROOT="${ROOT%/}"
fi
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
fi
if [ -z "$ROOT" ]; then
  ROOT="$PWD"
fi

if ! command -v python3 >/dev/null 2>&1; then
  if [ "$MODE" = "summary" ]; then
    echo "Bugs: count unavailable (python3 not found)"
  fi
  exit 0
fi

RESULT=$(PYTHONIOENCODING=utf-8 python3 - "$ROOT/.craft/bugs" "$MODE" "$STATUS_FILTER" 2>/dev/null <<'PYEOF'
import os
import re
import sys

bugs_dir, mode, status_filter = sys.argv[1], sys.argv[2], sys.argv[3]

NAME_RE = re.compile(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}-.+\.md$')
FENCE_RE = re.compile(r'^---\n(.*?)\n---\n?(.*)$', re.DOTALL)
TYPE_RE = re.compile(r'^type:[ \t]*bug[ \t]*$', re.MULTILINE)


def one_line(text):
    return ' '.join(text.split())


def parse(path, room):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            text = f.read().replace('\r\n', '\n')
    except Exception:
        return None
    m = FENCE_RE.match(text)
    if not m or not TYPE_RE.search(m.group(1)):
        return None
    fm, body = m.group(1), m.group(2)

    def get(field):
        mm = re.search(r'^' + re.escape(field) + r':[ \t]*(.*)$', fm, re.MULTILINE)
        return one_line(mm.group(1)) if mm else ''

    base = os.path.basename(path)
    title = ''
    blocks = ''
    lines = body.split('\n')
    for line in lines:
        if line.strip():
            title = one_line(line)[:120]
            break
    for i, line in enumerate(lines):
        if re.match(r'^##[ \t]+Blocks my next step[ \t]*$', line, re.IGNORECASE):
            for nxt in lines[i + 1:]:
                if nxt.strip():
                    low = nxt.strip().lower()
                    if low.startswith('yes'):
                        blocks = 'yes'
                    elif low.startswith('no'):
                        blocks = 'no'
                    break
            break

    if room == 'open':
        status = 'open'
    else:
        raw = get('status')
        status = raw if raw in ('fixed', 'wont-fix') else 'closed'

    created = get('created')
    return {
        'file': os.path.abspath(path),
        'room': room,
        'base': base,
        'slug': re.sub(r'\.md$', '', re.sub(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}-', '', base)),
        'date': created or base[:10],
        'title': title,
        'status': status,
        'verdict': get('verdict'),
        'found_during': get('found_during') or get('found_by'),
        'layer': get('layer'),
        'blocks': blocks,
        'hits': get('hits'),
        'sort': (get('captured_at'), created, base),
    }


def names(directory):
    try:
        return sorted(n for n in os.listdir(directory)
                      if NAME_RE.match(n) and os.path.isfile(os.path.join(directory, n)))
    except Exception:
        return []


records = {}
closed_dir = os.path.join(bugs_dir, 'closed')
for n in names(closed_dir):
    rec = parse(os.path.join(closed_dir, n), 'closed')
    if rec:
        records[n] = rec
for n in names(bugs_dir):
    if n in records:
        continue
    rec = parse(os.path.join(bugs_dir, n), 'open')
    if rec:
        records[n] = rec

ordered = sorted(records.values(), key=lambda r: r['sort'], reverse=True)

if mode == 'summary':
    opened = [r for r in ordered if r['room'] == 'open']
    out = ['Bugs: %d open' % len(opened)]
    for r in opened:
        line = '- ' + r['title']
        if r['found_during']:
            line += ' - found during: ' + r['found_during']
        if r['blocks'] == 'yes':
            line += ' [blocks my next step]'
        out.append(line)
    print('\n'.join(out))
else:
    chosen = []
    for r in ordered:
        if status_filter == 'closed':
            if r['room'] != 'closed':
                continue
        elif status_filter and r['status'] != status_filter:
            continue
        chosen.append(r)
    blocks_out = []
    for r in chosen:
        blocks_out.append('\n'.join([
            'FILE=' + r['file'],
            'ROOM=' + r['room'],
            'SLUG=' + r['slug'],
            'DATE=' + r['date'],
            'TITLE=' + r['title'],
            'STATUS=' + r['status'],
            'VERDICT=' + r['verdict'],
            'FOUND_DURING=' + r['found_during'],
            'LAYER=' + r['layer'],
            'BLOCKS=' + r['blocks'],
            'HITS=' + r['hits'],
        ]) + '\n')
    sys.stdout.write('\n'.join(blocks_out))
PYEOF
)

if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT"
elif [ "$MODE" = "summary" ]; then
  echo "Bugs: 0 open"
fi
exit 0
