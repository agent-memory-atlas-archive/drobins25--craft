#!/bin/bash
# decisions-capture.sh - Write a new decision record, or reopen an existing one
#
# New record:
#   decisions-capture.sh "<title>" --tag=<tag> [--tag=<tag2> ...] \
#     --context="..." --options="..." --decision="..." --consequences="..." \
#     [--quote="<verbatim words>"] [--source=session|dossier] [--created=YYYY-MM-DD]
#
#   No --quote= lands the record in the root as status: pending. A --quote=
#   lands it in approved/ as status: accepted, with the quote rendered under
#   ## Approval. Room and status are written together in the same branch, so
#   they can never disagree. The first --tag= is free; every additional
#   --tag= must already appear on some other record's tags: field (checked
#   via decisions-list.sh) or the call is refused before any write.
#
# Reopen:
#   decisions-capture.sh --reopen=<full-dated-slug|path> [--title="<new title>"] \
#     --context="..." --options="..." --decision="..." --consequences="..." \
#     --quote="<words>" [--source=session|dossier]
#
#   Rewrites the body in place at the same filename: created:, status:, and
#   tags: are left untouched, and a "> Reopen: ..." line is appended to the
#   existing ## Approval block. A record whose derived disposition is
#   "crafted" is refused (exit non-zero, names the shipping story, writes
#   nothing). A "claimed" record is written, then one "Claimed: <story>"
#   line per claiming story prints to stdout before the path line.
#
# There is no --by= flag and no attribution of any kind: the approval line
# is always "> "<words>" - <date>, <source>", never a name. Any unrecognized
# --flag is rejected before any write, which is what makes --by= a hard
# error rather than a silently ignored typo.
#
# Capture never writes to a story file - only decisions-transition.sh (via
# the story-completion flip) ever touches stories: on a record, and nothing
# in this script opens a story file for writing.
#
# All validation (required flags, the tag rule, reopen target resolution,
# the crafted refusal) runs before any mkdir or file write.
#
# Output (stdout): any "Claimed: <story>" lines first, then the record's
# absolute path as the LAST line.
# Exit: 0 on success, non-zero on error.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_SCRIPT="$SCRIPT_DIR/decisions-list.sh"

# Resolve project root (same ladder as notebook-capture.sh / dials-capture.sh)
if [ -n "$CRAFT_PROJECT_ROOT" ]; then
  ROOT="${CRAFT_PROJECT_ROOT%/}"
else
  source "$SCRIPT_DIR/find-workshop.sh" 2>/dev/null || true
  ROOT="${PROJECT_ROOT%/}"
fi

# Cold fallback: anchor to the git toplevel (never a subdirectory), else PWD.
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$ROOT" ]; then
    ROOT="$PWD"
    echo "not a git repo - capturing to $ROOT/.craft/decisions/ (local to this directory)" >&2
  fi
fi

list() {
  CRAFT_PROJECT_ROOT="$ROOT" bash "$LIST_SCRIPT" "$@"
}

# ── Argument parsing ──────────────────────────────────────────────────
TITLE=""
REOPEN=""
TITLE_OVERRIDE=""
CONTEXT=""
OPTIONS=""
DECISION=""
CONSEQUENCES=""
QUOTE=""
SOURCE="session"
CREATED=""
TAGS_LIST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tag=*)          TAGS_LIST="${TAGS_LIST}${1#*=}"$'\n'; shift ;;
    --context=*)      CONTEXT="${1#*=}"; shift ;;
    --options=*)      OPTIONS="${1#*=}"; shift ;;
    --decision=*)     DECISION="${1#*=}"; shift ;;
    --consequences=*) CONSEQUENCES="${1#*=}"; shift ;;
    --quote=*)        QUOTE="${1#*=}"; shift ;;
    --source=*)       SOURCE="${1#*=}"; shift ;;
    --created=*)      CREATED="${1#*=}"; shift ;;
    --reopen=*)       REOPEN="${1#*=}"; shift ;;
    --title=*)        TITLE_OVERRIDE="${1#*=}"; shift ;;
    --*)
      echo "Error: unknown flag '$1'" >&2
      exit 1
      ;;
    *)
      if [ -z "$TITLE" ]; then
        TITLE="$1"
      fi
      shift
      ;;
  esac
done

if [ -n "$REOPEN" ]; then
  MODE="reopen"
else
  MODE="create"
fi

# ── Validation - runs before any mkdir or write ──────────────────────
if [ "$MODE" = "create" ]; then
  [ -z "$TITLE" ] && { echo "Error: a title is required" >&2; exit 1; }
  [ -z "$TAGS_LIST" ] && { echo "Error: --tag is required" >&2; exit 1; }
  [ -z "$CONTEXT" ] && { echo "Error: --context is required" >&2; exit 1; }
  [ -z "$OPTIONS" ] && { echo "Error: --options is required" >&2; exit 1; }
  [ -z "$DECISION" ] && { echo "Error: --decision is required" >&2; exit 1; }
  [ -z "$CONSEQUENCES" ] && { echo "Error: --consequences is required" >&2; exit 1; }
else
  [ -z "$CONTEXT" ] && { echo "Error: --context is required" >&2; exit 1; }
  [ -z "$OPTIONS" ] && { echo "Error: --options is required" >&2; exit 1; }
  [ -z "$DECISION" ] && { echo "Error: --decision is required" >&2; exit 1; }
  [ -z "$CONSEQUENCES" ] && { echo "Error: --consequences is required" >&2; exit 1; }
  [ -z "$QUOTE" ] && { echo "Error: --quote is required for a reopen" >&2; exit 1; }
fi

if [ "$MODE" = "create" ]; then
  # First --tag= is free; every additional one must already exist on some
  # other record's tags: field, verified through decisions-list.sh.
  FIRST_TAG=""
  ADDITIONAL_TAGS=""
  IDX=0
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    IDX=$((IDX + 1))
    if [ "$IDX" -eq 1 ]; then
      FIRST_TAG="$t"
    else
      ADDITIONAL_TAGS="${ADDITIONAL_TAGS}${t}"$'\n'
    fi
  done <<< "$TAGS_LIST"

  while IFS= read -r t; do
    [ -z "$t" ] && continue
    EXISTS=$(list --tag="$t")
    if [ -z "$EXISTS" ]; then
      echo "Error: tag '$t' does not exist on any other record" >&2
      exit 1
    fi
  done <<< "$ADDITIONAL_TAGS"

  ALL_TAGS="$FIRST_TAG"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    ALL_TAGS="${ALL_TAGS}, ${t}"
  done <<< "$ADDITIONAL_TAGS"
fi

CLAIMED_STORIES=""
if [ "$MODE" = "reopen" ]; then
  case "$REOPEN" in
    */*) SLUG="$(basename "$REOPEN")"; SLUG="${SLUG%.md}" ;;
    *.md) SLUG="${REOPEN%.md}" ;;
    *) SLUG="$REOPEN" ;;
  esac

  LOOKUP=$(list --slug="$SLUG")
  if [ -z "$LOOKUP" ]; then
    echo "Error: $SLUG not found" >&2
    exit 1
  fi

  TARGET_FILE=$(echo "$LOOKUP" | sed -n 's/^FILE=//p')
  CUR_DISPOSITION=$(echo "$LOOKUP" | sed -n 's/^DISPOSITION=//p')
  CUR_STORIES=$(echo "$LOOKUP" | sed -n 's/^STORIES=//p')
  CUR_TITLE=$(echo "$LOOKUP" | sed -n 's/^TITLE=//p')

  if [ "$CUR_DISPOSITION" = "crafted" ]; then
    STORY_NAMES=$(printf '%s' "$CUR_STORIES" | tr ';' ',' | sed 's/,/, /g')
    echo "Error: $SLUG is crafted (shipped by $STORY_NAMES) - frozen law needs a new record" >&2
    exit 1
  fi

  if [ "$CUR_DISPOSITION" = "claimed" ]; then
    CLAIMED_STORIES="$CUR_STORIES"
  fi
fi

# ── Write ──────────────────────────────────────────────────────────────
if [ "$MODE" = "create" ]; then
  DATE="${CREATED:-$(date +%Y-%m-%d)}"

  # ── Slug generation (mirrors notebook-capture.sh / dials-capture.sh) ──
  RAW_SLUG=$(printf '%s' "$TITLE" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' \
    | sed -E 's/^-//' \
    | sed -E 's/-$//')

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

  # Room and status are written together, in the same branch, so they can
  # never disagree.
  if [ -n "$QUOTE" ]; then
    ROOM_DIR="$ROOT/.craft/decisions/approved"
    STATUS="accepted"
  else
    ROOM_DIR="$ROOT/.craft/decisions"
    STATUS="pending"
  fi
  mkdir -p "$ROOM_DIR"

  FINAL_SLUG="$SLUG"
  TARGET_FILE="$ROOM_DIR/${DATE}-${FINAL_SLUG}.md"
  COUNTER=2
  while [ -e "$TARGET_FILE" ]; do
    FINAL_SLUG="${SLUG}-${COUNTER}"
    TARGET_FILE="$ROOM_DIR/${DATE}-${FINAL_SLUG}.md"
    COUNTER=$((COUNTER + 1))
  done

  {
    echo "---"
    echo "type: decision"
    echo "status: $STATUS"
    echo "created: $DATE"
    echo "source: $SOURCE"
    echo "tags: [$ALL_TAGS]"
    echo "---"
    echo "# $TITLE"
    echo ""
    echo "## Context"
    echo "$CONTEXT"
    echo ""
    echo "## Options considered"
    echo "$OPTIONS"
    echo ""
    echo "## Decision"
    echo "$DECISION"
    echo ""
    echo "## Consequences"
    echo "$CONSEQUENCES"
    echo ""
    echo "## Approval"
    if [ -n "$QUOTE" ]; then
      echo "> \"$QUOTE\" - $DATE, $SOURCE"
    fi
  } > "$TARGET_FILE"

  echo "$TARGET_FILE"
else
  REOPEN_DATE=$(date +%Y-%m-%d)
  TITLE_FOR_BODY="${TITLE_OVERRIDE:-$CUR_TITLE}"

  python3 - "$TARGET_FILE" "$TITLE_FOR_BODY" "$CONTEXT" "$OPTIONS" "$DECISION" "$CONSEQUENCES" "$QUOTE" "$REOPEN_DATE" "$SOURCE" <<'PYEOF'
import sys, re

path, title, context, options, decision, consequences, quote, date, source = sys.argv[1:10]

with open(path, 'r') as f:
    content = f.read()

m = re.match(r'^(---\n.*?\n---\n?)(.*)$', content, re.DOTALL)
frontmatter_block = m.group(1)
body = m.group(2)

approval_match = re.search(r'(## Approval\n.*)$', body, re.DOTALL)
existing_approval = approval_match.group(1) if approval_match else "## Approval\n"

new_reopen_line = '> Reopen: "{}" - {}, {}\n'.format(quote, date, source)
approval_section = existing_approval.rstrip('\n') + '\n' + new_reopen_line

new_body = (
    "# {title}\n\n"
    "## Context\n{context}\n\n"
    "## Options considered\n{options}\n\n"
    "## Decision\n{decision}\n\n"
    "## Consequences\n{consequences}\n\n"
    "{approval_section}"
).format(
    title=title,
    context=context,
    options=options,
    decision=decision,
    consequences=consequences,
    approval_section=approval_section,
)

with open(path, 'w') as f:
    f.write(frontmatter_block + new_body)
PYEOF

  if [ -n "$CLAIMED_STORIES" ]; then
    printf '%s\n' "$CLAIMED_STORIES" | tr ';' '\n' | while IFS= read -r s; do
      [ -n "$s" ] && echo "Claimed: $s"
    done
  fi

  echo "$TARGET_FILE"
fi
