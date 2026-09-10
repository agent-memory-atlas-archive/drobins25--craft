#!/bin/bash
# decisions-transition.sh - The only legal state change for a decision record
#
# Usage: decisions-transition.sh <full-dated-slug|path> <accept|decline|deprecate|craft> \
#          [--quote="<words>"] [--source=session|dossier] [--story=<story-name>]
#
#   accept:    root, status: pending      -> approved/, status: accepted   (--quote required)
#   decline:   root, status: pending      -> archive/,  status: declined   (--quote required)
#   deprecate: approved/, status: accepted -> archive/, status: deprecated (--quote required)
#              refused on a record whose derived disposition is "crafted"
#              (exit non-zero, names the shipping story, writes nothing) -
#              shipped law is not retired.
#   craft:     approved/, status: accepted -> unchanged room; writes
#              disposition: crafted and appends --story= to stories: in ONE
#              act, without moving the file. (--story required)
#
#   craft is idempotent on an already-crafted record: the story name is
#   appended to stories: if it is not already present, disposition: is never
#   re-written, CHANGED=0, exit 0.
#
#   disposition: is only ever written with the value "crafted" - this script
#   has no code path that writes "open" or "claimed"
#   (2026-09-05-claimed-is-read-not-written).
#
#   Every move writes the finished record to its destination path first,
#   then removes the source last, so a crash between the two can never leave
#   a half-written record - only, at worst, the same record present in two
#   rooms, which a subsequent call refuses with a distinct message.
#
#   Frontmatter edits are a python3 rewrite scoped to the fenced block,
#   never a whole-file sed, because record bodies (Options considered,
#   Decision) legitimately contain lines that start with field names like
#   "status:" as prose.
#
# Output (stdout) on success, in this order:
#   TITLE=<record H1 title>
#   CHANGED=1|0
#   <record's absolute path>   <- always the LAST line
#
# Exit: 0 on success, non-zero on any failure, with a stderr message naming
# the slug and a reason distinct per failure case: not found, found in more
# than one room, wrong room, wrong status (including "still pending" and
# "in archive/" as their own named cases), and a missing required flag.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_SCRIPT="$SCRIPT_DIR/decisions-list.sh"

# Resolve project root (same ladder as decisions-list.sh / decisions-capture.sh)
if [ -n "$CRAFT_PROJECT_ROOT" ]; then
  ROOT="${CRAFT_PROJECT_ROOT%/}"
else
  source "$SCRIPT_DIR/find-workshop.sh" 2>/dev/null || true
  ROOT="${PROJECT_ROOT%/}"
fi

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
fi

list() {
  CRAFT_PROJECT_ROOT="$ROOT" bash "$LIST_SCRIPT" "$@"
}

SLUG_ARG="$1"
ACTION="$2"
shift 2 2>/dev/null || { echo "Error: a slug and an action (accept|decline|deprecate|craft) are required" >&2; exit 1; }

if [ -z "$SLUG_ARG" ] || [ -z "$ACTION" ]; then
  echo "Error: a slug and an action (accept|decline|deprecate|craft) are required" >&2
  exit 1
fi

case "$ACTION" in
  accept|decline|deprecate|craft) ;;
  *)
    echo "Error: unknown action '$ACTION' - expected accept, decline, deprecate, or craft" >&2
    exit 1
    ;;
esac

QUOTE=""
SOURCE="session"
STORY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quote=*)  QUOTE="${1#*=}"; shift ;;
    --source=*) SOURCE="${1#*=}"; shift ;;
    --story=*)  STORY="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# ── Resolve the slug to its full dated form ──────────────────────────
case "$SLUG_ARG" in
  */*) SLUG="$(basename "$SLUG_ARG")"; SLUG="${SLUG%.md}" ;;
  *.md) SLUG="${SLUG_ARG%.md}" ;;
  *) SLUG="$SLUG_ARG" ;;
esac

# ── Find the record. decisions-list.sh is the single source of truth for
# room/status/title - re-implementing the parse here would let the two
# scripts drift apart. Only room and status are needed for accept, decline
# and craft, so those actions pass --no-scan and never pay for the
# story-claim scan. deprecate additionally needs the derived disposition
# to refuse a crafted record, so it runs WITH the scan. ────────────────
if [ "$ACTION" = "deprecate" ]; then
  LOOKUP=$(list --slug="$SLUG")
else
  LOOKUP=$(list --slug="$SLUG" --no-scan)
fi
if [ -z "$LOOKUP" ]; then
  echo "Error: $SLUG not found in .craft/decisions (root, approved/, or archive/)" >&2
  exit 1
fi

ROOMS_FOUND=$(echo "$LOOKUP" | sed -n 's/^ROOM=//p')
NUM_ROOMS=$(echo "$ROOMS_FOUND" | grep -c . || true)
if [ "$NUM_ROOMS" -gt 1 ]; then
  ROOMS_LIST=$(echo "$ROOMS_FOUND" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
  echo "Error: $SLUG found in more than one room ($ROOMS_LIST) - state is ambiguous, resolve manually" >&2
  exit 1
fi

CUR_FILE=$(echo "$LOOKUP" | sed -n 's/^FILE=//p')
CUR_ROOM=$(echo "$LOOKUP" | sed -n 's/^ROOM=//p')
CUR_STATUS=$(echo "$LOOKUP" | sed -n 's/^STATUS=//p')
CUR_TITLE=$(echo "$LOOKUP" | sed -n 's/^TITLE=//p')

if [ "$ACTION" = "deprecate" ]; then
  CUR_DISPOSITION=$(echo "$LOOKUP" | sed -n 's/^DISPOSITION=//p')
  CUR_STORIES=$(echo "$LOOKUP" | sed -n 's/^STORIES=//p')
  if [ "$CUR_DISPOSITION" = "crafted" ]; then
    STORY_NAMES=$(printf '%s' "$CUR_STORIES" | tr ';' ',' | sed 's/,/, /g')
    echo "Error: $SLUG is crafted (shipped by $STORY_NAMES) - shipped law is not retired" >&2
    exit 1
  fi
fi

# ── Preconditions per action, validated before any write or mv ───────
case "$ACTION" in
  accept)   EXPECTED_ROOM="root";     EXPECTED_STATUS="pending";  DEST_ROOM="approved" ;;
  decline)  EXPECTED_ROOM="root";     EXPECTED_STATUS="pending";  DEST_ROOM="archive" ;;
  deprecate) EXPECTED_ROOM="approved"; EXPECTED_STATUS="accepted"; DEST_ROOM="archive" ;;
  craft)    EXPECTED_ROOM="approved"; EXPECTED_STATUS="accepted"; DEST_ROOM="approved" ;;
esac

if [ "$CUR_ROOM" != "$EXPECTED_ROOM" ]; then
  if [ "$CUR_ROOM" = "archive" ]; then
    echo "Error: $SLUG is in archive/ - $ACTION cannot act on an archived record" >&2
    exit 1
  elif [ "$EXPECTED_ROOM" = "approved" ] && [ "$CUR_ROOM" = "root" ]; then
    echo "Error: $SLUG is still pending - $ACTION requires it to be accepted first" >&2
    exit 1
  else
    echo "Error: $SLUG is in $CUR_ROOM/, not $EXPECTED_ROOM/ - $ACTION requires a record in $EXPECTED_ROOM/" >&2
    exit 1
  fi
fi

if [ "$CUR_STATUS" != "$EXPECTED_STATUS" ]; then
  echo "Error: $SLUG has status '$CUR_STATUS', not '$EXPECTED_STATUS' - $ACTION requires status $EXPECTED_STATUS" >&2
  exit 1
fi

if [ "$ACTION" != "craft" ] && [ -z "$QUOTE" ]; then
  echo "Error: --quote is required for $ACTION" >&2
  exit 1
fi

if [ "$ACTION" = "craft" ] && [ -z "$STORY" ]; then
  echo "Error: --story is required for craft" >&2
  exit 1
fi

TODAY=$(date +%Y-%m-%d)
SRC_FILE="$CUR_FILE"
DEST_DIR="$ROOT/.craft/decisions"
[ "$DEST_ROOM" != "root" ] && DEST_DIR="$DEST_DIR/$DEST_ROOM"
DEST_FILE="$DEST_DIR/$SLUG.md"
TMP_FILE="$DEST_FILE.tmp"

mkdir -p "$DEST_DIR"

if [ "$ACTION" = "craft" ]; then
  CHANGED=$(python3 - "$SRC_FILE" "$TMP_FILE" "$STORY" <<'PYEOF'
import sys, re

src, tmp, story = sys.argv[1:4]

with open(src, 'r') as f:
    content = f.read()

m = re.match(r'^(---\n)(.*?)(\n---\n?)(.*)$', content, re.DOTALL)
if not m:
    sys.exit("no frontmatter fence found in " + src)
head, fm, fence_tail, body = m.groups()


def get(field):
    mm = re.search(r'^' + re.escape(field) + r':\s*(.*)$', fm, re.MULTILINE)
    return mm.group(1).strip() if mm else None


def parse_list(raw):
    if not raw:
        return []
    mm = re.match(r'\[(.*)\]', raw)
    if not mm:
        return []
    return [p.strip() for p in mm.group(1).split(',') if p.strip()]


disposition = get('disposition')
stories_raw = get('stories')
stories = parse_list(stories_raw)

changed = 0 if disposition == 'crafted' else 1
if story not in stories:
    stories.append(story)

stories_field = 'stories: [{}]'.format(', '.join(stories))
disposition_field = 'disposition: crafted'

if disposition is None:
    fm = re.sub(
        r'^(tags:.*)$',
        lambda mm: mm.group(1) + '\n' + disposition_field + '\n' + stories_field,
        fm, count=1, flags=re.MULTILINE,
    )
elif stories_raw is None:
    fm = re.sub(
        r'^(disposition:.*)$',
        lambda mm: mm.group(1) + '\n' + stories_field,
        fm, count=1, flags=re.MULTILINE,
    )
else:
    fm = re.sub(r'^disposition:.*$', disposition_field, fm, count=1, flags=re.MULTILINE)
    fm = re.sub(r'^stories:.*$', lambda mm: stories_field, fm, count=1, flags=re.MULTILINE)

with open(tmp, 'w') as f:
    f.write(head + fm + fence_tail + body)

print(changed)
PYEOF
)
else
  NEW_STATUS="$EXPECTED_ROOM"  # placeholder, overwritten below per action
  case "$ACTION" in
    accept)    NEW_STATUS="accepted" ;;
    decline)   NEW_STATUS="declined" ;;
    deprecate) NEW_STATUS="deprecated" ;;
  esac

  python3 - "$SRC_FILE" "$TMP_FILE" "$NEW_STATUS" "$QUOTE" "$TODAY" "$SOURCE" <<'PYEOF'
import sys, re

src, tmp, new_status, quote, date, source = sys.argv[1:7]

with open(src, 'r') as f:
    content = f.read()

m = re.match(r'^(---\n)(.*?)(\n---\n?)(.*)$', content, re.DOTALL)
if not m:
    sys.exit("no frontmatter fence found in " + src)
head, fm, fence_tail, body = m.groups()

fm = re.sub(r'^status:.*$', 'status: ' + new_status, fm, count=1, flags=re.MULTILINE)

new_content = head + fm + fence_tail + body
if not new_content.endswith('\n'):
    new_content += '\n'
new_content += '> "{}" - {}, {}\n'.format(quote, date, source)

with open(tmp, 'w') as f:
    f.write(new_content)
PYEOF
  CHANGED=1
fi

# Write the finished record to its destination first, then remove the
# source last - a crash between the two can, at worst, leave the record in
# two rooms, which a subsequent call refuses rather than silently picking
# one.
mv "$TMP_FILE" "$DEST_FILE"
if [ "$SRC_FILE" != "$DEST_FILE" ]; then
  rm -f "$SRC_FILE"
fi

echo "TITLE=$CUR_TITLE"
echo "CHANGED=$CHANGED"
echo "$DEST_FILE"
