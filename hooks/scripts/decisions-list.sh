#!/bin/bash
# decisions-list.sh - Emit structured list of decision records across all
# three rooms (root, approved/, archive/), with a derived claimed/crafted
# disposition and the stories that carry each record.
#
# Usage: decisions-list.sh [--room=root|approved|archive] [--tag=<tag>]
#          [--status=pending|accepted|declined|deprecated]
#          [--disposition=open|claimed|crafted] [--slug=<full-dated-slug>]
#          [--no-scan]
#        decisions-list.sh --claimants=<full-dated-slug>
#   Filters AND together. Unknown flags are ignored.
#
#   --no-scan skips the story-claim scan entirely, for callers that only
#   need the records and their tags (decisions-capture.sh's additional-tag
#   existence check, decisions-transition.sh's record lookup). Every block
#   still prints all nine keys in the same order; DISPOSITION and STORIES
#   print empty, because with no scan there is nothing to derive them from.
#   Without the flag, behaviour is exactly as it has always been. A
#   --disposition= filter is therefore meaningless alongside --no-scan and
#   will match nothing.
#
#   --claimants=<slug> is its own mode: it prints, for every non-complete
#   story file (.craft/cycles/*/stories/*.md and .craft/backlog/*.md) whose
#   decisions: list carries the slug, one line
#     <status> <story> <absolute story path>
#   with single spaces and the path last, sorted by path. Nothing prints,
#   and the exit is still 0, when no story claims the slug. Every other
#   flag is ignored in this mode and no record is read. The story name is
#   the same identity the STORIES= key carries. Complete stories never
#   print - law claimed only by complete stories reads as unclaimed.
#
# Output (stdout): key=value blocks, one per record, separated by a blank
# line. Keys are always present (empty value when unknown), in this order:
#   FILE=<absolute path>
#   ROOM=root|approved|archive
#   SLUG=<full dated slug - filename without .md, date NOT stripped>
#   DATE=<YYYY-MM-DD, from frontmatter created:, falling back to filename>
#   TITLE=<body's first "# " line, falling back to SLUG>
#   STATUS=<frontmatter status:>
#   TAGS=<semicolon-separated>
#   DISPOSITION=open|claimed|crafted (derived - see below)
#   STORIES=<semicolon-separated, meaning depends on DISPOSITION>
#
# Disposition is never read verbatim from disk. Frontmatter disposition:
# crafted wins outright and STORIES then comes from the record's own
# stories: field. Otherwise DISPOSITION is claimed - with STORIES set to
# the claiming story names - when any non-complete story file's decisions:
# list carries this record's SLUG, and open (STORIES empty) otherwise. A
# disk value of "claimed" is never trusted or emitted - claimed is derived
# from the story files every time, never written to a record.
#
# Frontmatter parsing is fence-scoped: every field lookup searches only the
# text between the opening and closing "---" markers, because record bodies
# (Options considered, Decision) legitimately contain lines that start with
# field names like "disposition:" as prose, not data.
#
# Exactly ONE python3 invocation happens per run - the record parse, the
# story-claim scan, and the block emission all happen inside it, so store
# and story-corpus scale never costs more than one interpreter spawn.
#
# Anything under assets/ is never treated as a record.
# Exit: 0 always (empty output if .craft/decisions is absent, or a filter
# matches nothing).

set -e

if [ -n "$CRAFT_PROJECT_ROOT" ]; then
  ROOT="${CRAFT_PROJECT_ROOT%/}"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/find-workshop.sh" 2>/dev/null || true
  ROOT="${PROJECT_ROOT%/}"
fi

# Cold fallback: mirror dials-list.sh / notebook-list.sh's anchor (git
# toplevel, else PWD) so records are listable before /craft:init.
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
fi

ROOM_FILTER=""
TAG_FILTER=""
STATUS_FILTER=""
DISPOSITION_FILTER=""
SLUG_FILTER=""
NO_SCAN=""
CLAIMANTS_SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --room=*)        ROOM_FILTER="${1#*=}"; shift ;;
    --tag=*)         TAG_FILTER="${1#*=}"; shift ;;
    --status=*)      STATUS_FILTER="${1#*=}"; shift ;;
    --disposition=*) DISPOSITION_FILTER="${1#*=}"; shift ;;
    --slug=*)        SLUG_FILTER="${1#*=}"; shift ;;
    --no-scan)       NO_SCAN="1"; shift ;;
    --claimants=*)   CLAIMANTS_SLUG="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

DECISIONS_DIR="$ROOT/.craft/decisions"

# A claimants lookup reads stories only, so it runs without a decisions dir.
if [ ! -d "$DECISIONS_DIR" ] && [ -z "$CLAIMANTS_SLUG" ]; then
  exit 0
fi

python3 - "$ROOT" "$ROOM_FILTER" "$TAG_FILTER" "$STATUS_FILTER" "$DISPOSITION_FILTER" "$SLUG_FILTER" "$NO_SCAN" "$CLAIMANTS_SLUG" <<'PYEOF'
import sys, os, re, glob

(root, room_filter, tag_filter, status_filter, disposition_filter, slug_filter,
 no_scan_raw, claimants_slug) = sys.argv[1:9]
no_scan = bool(no_scan_raw)

FENCE_RE = re.compile(r'^---\n(.*?)\n---\n?(.*)$', re.DOTALL)


def fence_parse(content):
    m = FENCE_RE.match(content)
    if not m:
        return None, ''
    return m.group(1), m.group(2)


def get(frontmatter, field):
    mm = re.search(r'^' + re.escape(field) + r':\s*(.*)$', frontmatter, re.MULTILINE)
    return mm.group(1).strip() if mm else ''


def parse_inline_list(raw):
    if not raw:
        return []
    mm = re.match(r'\[(.*)\]', raw)
    if not mm:
        return []
    inner = mm.group(1)
    return [p.strip() for p in inner.split(',') if p.strip()]


def read(path):
    try:
        with open(path, 'r') as f:
            return f.read()
    except OSError:
        return None


def story_identity(story_path, frontmatter):
    name = get(frontmatter, 'name')
    if name:
        return name
    base = os.path.basename(story_path)[:-3]
    return re.sub(r'^[0-9][0-9]*[a-z]?-', '', base)


# Build slug -> [claiming story names] for every non-complete story that
# lists the slug in its decisions: field. One glob, one pass, memoized
# before any record is emitted. Under --no-scan the whole block is skipped
# - no glob, no story reads - and DISPOSITION/STORIES emit empty.
story_map = {}
story_files = []
claimant_lines = []
if not no_scan or claimants_slug:
    story_files = glob.glob(os.path.join(root, '.craft/cycles/*/stories/*.md'))
    story_files += glob.glob(os.path.join(root, '.craft/backlog/*.md'))
for story_path in story_files:
    content = read(story_path)
    if content is None:
        continue
    fm, _ = fence_parse(content)
    if fm is None:
        continue
    if get(fm, 'status') == 'complete':
        continue
    name = story_identity(story_path, fm)
    for slug in parse_inline_list(get(fm, 'decisions')):
        story_map.setdefault(slug, []).append(name)
        if claimants_slug and slug == claimants_slug:
            claimant_lines.append((story_path, f"{get(fm, 'status')} {name} {story_path}"))

if claimants_slug:
    for _, line in sorted(claimant_lines):
        print(line)
    sys.exit(0)

ROOMS = (
    ('root', os.path.join(root, '.craft/decisions')),
    ('approved', os.path.join(root, '.craft/decisions/approved')),
    ('archive', os.path.join(root, '.craft/decisions/archive')),
)

for room_name, dir_path in ROOMS:
    if room_filter and room_filter != room_name:
        continue
    if not os.path.isdir(dir_path):
        continue
    for fname in sorted(os.listdir(dir_path)):
        if not fname.endswith('.md'):
            continue
        full = os.path.join(dir_path, fname)
        if not os.path.isfile(full):
            continue
        content = read(full)
        if content is None:
            continue
        fm, body = fence_parse(content)
        if fm is None:
            continue

        slug = fname[:-len('.md')]

        date = get(fm, 'created')
        if not date:
            mm = re.match(r'^(\d{4}-\d{2}-\d{2})-', fname)
            date = mm.group(1) if mm else ''

        title = ''
        for line in body.splitlines():
            mm = re.match(r'^# (.*)$', line)
            if mm:
                title = mm.group(1).strip()
                break
        if not title:
            title = slug

        status = get(fm, 'status')
        tags = parse_inline_list(get(fm, 'tags'))

        fm_disposition = get(fm, 'disposition')
        if no_scan:
            disposition = ''
            stories = []
        elif fm_disposition == 'crafted':
            disposition = 'crafted'
            stories = parse_inline_list(get(fm, 'stories'))
        else:
            claimants = story_map.get(slug, [])
            if claimants:
                disposition = 'claimed'
                stories = claimants
            else:
                disposition = 'open'
                stories = []

        if tag_filter and tag_filter not in tags:
            continue
        if status_filter and status_filter != status:
            continue
        if disposition_filter and disposition_filter != disposition:
            continue
        if slug_filter and slug_filter != slug:
            continue

        print(f"FILE={full}")
        print(f"ROOM={room_name}")
        print(f"SLUG={slug}")
        print(f"DATE={date}")
        print(f"TITLE={title}")
        print(f"STATUS={status}")
        print(f"TAGS={';'.join(tags)}")
        print(f"DISPOSITION={disposition}")
        print(f"STORIES={';'.join(stories)}")
        print()
PYEOF

exit 0
