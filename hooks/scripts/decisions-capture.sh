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
#     [--quote="<words>"] [--source=session|dossier]
#
#   Rewrites the given sections in place at the same filename: created:,
#   status:, and tags: are left untouched, and so is every section not given. Reopen is room-aware:
#     approved/ - today's ceremony: --quote= is required and a
#       "> Reopen: ..." line is appended to the existing ## Approval block.
#     root      - a quiet reshape: the body is rewritten, status: pending
#       stays untouched, no quote line is written, and --quote= is refused
#       (the quote belongs to the accept that follows).
#     archive/  - refused outright (exit non-zero, file untouched) - the
#       archive is what was deliberately not done.
#   A record whose derived disposition is "crafted" is refused in every
#   room (exit non-zero, names the shipping story, writes nothing). A
#   "claimed" record is written, then one "Claimed: <story>" line per
#   claiming story prints to stdout before the path line.
#
# The record on stdin (create and reopen):
#   decisions-capture.sh --tag=<tag> [--tag=...] --stdin   < body
#   decisions-capture.sh --reopen=<slug|path> --stdin      < body
#
#   The body is record format: an optional first non-blank "# <title>"
#   line, then sections each opened by a line exactly "## Context",
#   "## Options considered", "## Decision", "## Consequences" or
#   "## Approval". A section's text is its lines with leading and trailing
#   blank lines removed. Any other "## " line, a repeated heading, or text
#   before the first heading is refused before any write. The grammar lives
#   in decision-body-parser.py, which the diff-drawing view calls too, so
#   the card and the write read typed text the same way.
#   Create: the title comes from the "# " line, all four content sections
#   are required, and a positional title, --quote= or a section flag
#   alongside --stdin is refused. A non-empty "## Approval" text is the
#   quote (approved/, accepted); absent or empty files it pending in the
#   root. The result is byte-identical to the flag form.
#   Reopen: only the sections given are rewritten, in place - every other
#   byte of the file stays identical. "## Approval" is the reopen quote
#   (required on law, refused in the root). Naming a section the record
#   lacks is refused. The section flags work the same way for a reopen:
#   any subset of --title/--context/--options/--decision/--consequences.
#   stdout: any "Claimed: <story>" lines, then "Sections written: <names>"
#   (record order), then the path.
#
# Dry run:
#   decisions-capture.sh "<title>" --tag=<tag> ... --dry-run
#
#   Runs every create-mode step - required-flag checks, the additional-tag
#   rule, room/status selection, the collision-suffixed slug - and writes
#   nothing: no file, no room directory. Stdout is "SLUG=<dated-slug>" on
#   line 1, then the record body exactly as the real write would have
#   produced it. Create-mode only; combined with --reopen= it is refused.
#   The collision check that derives the slug scans the root and approved/
#   together, on the dry run and the real write alike, so the slug a dry
#   run reports is the slug the file will actually get whichever room the
#   next call targets.
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
# Output (stdout): create prints the record's absolute path only. Reopen
# prints any "Claimed: <story>" lines first, then "Sections written: ...",
# then the record's absolute path as the LAST line.
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
DRY_RUN=""
STDIN_MODE=""

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
    --dry-run)        DRY_RUN=1; shift ;;
    --stdin)          STDIN_MODE=1; shift ;;
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

if [ -n "$DRY_RUN" ] && [ -n "$REOPEN" ]; then
  echo "Error: --dry-run cannot be combined with --reopen= - dry-run only answers what a NEW record would be" >&2
  exit 1
fi

if [ -n "$REOPEN" ]; then
  MODE="reopen"
else
  MODE="create"
fi

# ── The record on stdin - read once, before any python heredoc takes fd 0,
# and never by opening /dev/stdin by path (the eval sandbox refuses that).
# The body is parsed by the grammar in the docstring; the parsed pieces
# come back base64-encoded one KEY=value line each so multi-line text
# survives the trip through the shell, then land in the same variables
# the flags fill. ──────────────────────────────────────────────────────
if [ -n "$STDIN_MODE" ]; then
  if [ -n "$TITLE" ] || [ -n "$TITLE_OVERRIDE" ] || [ -n "$QUOTE" ] \
     || [ -n "$CONTEXT" ] || [ -n "$OPTIONS" ] || [ -n "$DECISION" ] || [ -n "$CONSEQUENCES" ]; then
    echo "Error: --stdin carries the whole record - a title, --title=, --quote= or a section flag cannot be combined with it" >&2
    exit 1
  fi
  STDIN_BODY=$(cat)
  PARSED=$(python3 "$SCRIPT_DIR/decision-body-parser.py" "$STDIN_BODY") || exit 1

  decode_field() {
    local b64
    b64=$(printf '%s\n' "$PARSED" | sed -n "s/^$1=//p")
    [ -n "$b64" ] && printf '%s' "$b64" | base64 -d
    return 0
  }
  STDIN_TITLE=$(decode_field TITLE)
  CONTEXT=$(decode_field CONTEXT)
  OPTIONS=$(decode_field OPTIONS)
  DECISION=$(decode_field DECISION)
  CONSEQUENCES=$(decode_field CONSEQUENCES)
  QUOTE=$(decode_field APPROVAL)
  if [ "$MODE" = "create" ]; then
    TITLE="$STDIN_TITLE"
  else
    TITLE_OVERRIDE="$STDIN_TITLE"
  fi
fi

# ── Reopen lookup - runs before validation so the room is known before the
# quote requirement (approved/ requires one, the root refuses one, archive/
# is refused outright) can be checked. The crafted refusal happens here
# too, before any write. ──────────────────────────────────────────────
CLAIMED_STORIES=""
CUR_ROOM=""
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
  CUR_ROOM=$(echo "$LOOKUP" | sed -n 's/^ROOM=//p')
  CUR_DISPOSITION=$(echo "$LOOKUP" | sed -n 's/^DISPOSITION=//p')
  CUR_STORIES=$(echo "$LOOKUP" | sed -n 's/^STORIES=//p')
  CUR_TITLE=$(echo "$LOOKUP" | sed -n 's/^TITLE=//p')

  if [ "$CUR_DISPOSITION" = "crafted" ]; then
    STORY_NAMES=$(printf '%s' "$CUR_STORIES" | tr ';' ',' | sed 's/,/, /g')
    echo "Error: $SLUG is crafted (shipped by $STORY_NAMES) - frozen law needs a new record" >&2
    exit 1
  fi

  if [ "$CUR_ROOM" = "archive" ]; then
    echo "Error: $SLUG is in archive/ - reopen cannot touch a declined or retired record" >&2
    exit 1
  fi

  if [ "$CUR_DISPOSITION" = "claimed" ]; then
    CLAIMED_STORIES="$CUR_STORIES"
  fi
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
  if [ -z "$TITLE_OVERRIDE" ] && [ -z "$CONTEXT" ] && [ -z "$OPTIONS" ] && [ -z "$DECISION" ] && [ -z "$CONSEQUENCES" ]; then
    echo "Error: a reopen needs at least one of --title, --context, --options, --decision, --consequences (or a body on --stdin)" >&2
    exit 1
  fi
  if [ "$CUR_ROOM" = "approved" ]; then
    [ -z "$QUOTE" ] && { echo "Error: --quote is required for a reopen" >&2; exit 1; }
  else
    [ -n "$QUOTE" ] && { echo "Error: --quote= is refused for a reopen in the root - the quote belongs to the accept that follows" >&2; exit 1; }
  fi
fi

if [ "$MODE" = "create" ]; then
  # First --tag= is free; every additional one must already exist on some
  # other record's tags: field, verified through decisions-list.sh. The
  # check needs only tags, so it passes --no-scan and the story-claim scan
  # never runs for it. The --reopen= lookup below deliberately does NOT -
  # it prints the claiming stories.
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
    EXISTS=$(list --tag="$t" --no-scan)
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

  if [ -z "$DRY_RUN" ]; then
    mkdir -p "$ROOM_DIR"
  fi

  # The letter picked chooses the room, but the slug shown before that
  # letter is typed must be the slug the file actually gets whichever
  # room is chosen - so the collision check scans the root and approved/
  # together, not just ROOM_DIR.
  ROOT_ROOM_DIR="$ROOT/.craft/decisions"
  APPROVED_ROOM_DIR="$ROOT/.craft/decisions/approved"

  FINAL_SLUG="$SLUG"
  TARGET_FILE="$ROOM_DIR/${DATE}-${FINAL_SLUG}.md"
  COUNTER=2
  while [ -e "$ROOT_ROOM_DIR/${DATE}-${FINAL_SLUG}.md" ] || [ -e "$APPROVED_ROOM_DIR/${DATE}-${FINAL_SLUG}.md" ]; do
    FINAL_SLUG="${SLUG}-${COUNTER}"
    TARGET_FILE="$ROOM_DIR/${DATE}-${FINAL_SLUG}.md"
    COUNTER=$((COUNTER + 1))
  done

  if [ -n "$DRY_RUN" ]; then
    echo "SLUG=${DATE}-${FINAL_SLUG}"
  fi

  # printf '%s\n' rather than echo so a section line like "-n" or one
  # holding a backslash reaches the file exactly as given.
  render_record_body() {
    printf '%s\n' "---" "type: decision" "status: $STATUS" "created: $DATE" "source: $SOURCE" "tags: [$ALL_TAGS]" "---"
    printf '%s\n' "# $TITLE" "" "## Context" "$CONTEXT" "" "## Options considered" "$OPTIONS" \
      "" "## Decision" "$DECISION" "" "## Consequences" "$CONSEQUENCES" "" "## Approval"
    if [ -n "$QUOTE" ]; then
      printf '%s\n' "> \"$QUOTE\" - $DATE, $SOURCE"
    fi
  }

  # The eval sandbox refuses to open /dev/stdout by path (macOS Seatbelt),
  # so the dry run prints the body directly instead of redirecting to it.
  # The real write still redirects to its target file exactly as before.
  if [ -n "$DRY_RUN" ]; then
    render_record_body
  else
    render_record_body > "$TARGET_FILE"
  fi

  if [ -z "$DRY_RUN" ]; then
    echo "$TARGET_FILE"
  fi
else
  REOPEN_DATE=$(date +%Y-%m-%d)

  # Each given section is spliced into the file where it already sits;
  # no other byte is re-emitted. Everything is checked before the one
  # write, so a record that lacks a named section is left untouched.
  python3 - "$TARGET_FILE" "$TITLE_OVERRIDE" "$CONTEXT" "$OPTIONS" "$DECISION" "$CONSEQUENCES" "$QUOTE" "$REOPEN_DATE" "$SOURCE" "$CUR_ROOM" <<'PYEOF'
import sys, re

path, title, context, options, decision, consequences, quote, date, source, room = sys.argv[1:11]

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

m = re.match(r'^(---\n.*?\n---\n?)(.*)$', content, re.DOTALL)
frontmatter_block = m.group(1)
body = m.group(2)

HEADING = re.compile(r'^## .*$', re.MULTILINE)


def section_span(text, name):
    # (start, end) of the text between a heading line and the next
    # "## " line (or the end), or None if the heading is absent.
    heading = re.search(r'^## ' + re.escape(name) + r'$\n?', text, re.MULTILINE)
    if heading is None:
        return None
    nxt = HEADING.search(text, heading.end())
    return heading.end(), (nxt.start() if nxt else len(text))


def splice(text, span, new_core):
    # Replace the section's text, keeping the blank lines around it.
    start, end = span
    region = text[start:end]
    if region.strip('\n') == '':
        return text[:start] + new_core + '\n' + region + text[end:]
    lead = region[:len(region) - len(region.lstrip('\n'))]
    trail = region[len(region.rstrip('\n')):]
    return text[:start] + lead + new_core + trail + text[end:]


given = [(n, t) for n, t in (('Context', context), ('Options considered', options),
                             ('Decision', decision), ('Consequences', consequences)) if t]
for name, _ in given:
    if section_span(body, name) is None:
        sys.stderr.write("Error: the record has no '## {}' section to rewrite\n".format(name))
        sys.exit(1)

new_body = body
if title:
    t = re.search(r'^# (.*)$', new_body, re.MULTILINE)
    if t is None:
        sys.stderr.write("Error: the record has no title line to rewrite\n")
        sys.exit(1)
    new_body = new_body[:t.start(1)] + title + new_body[t.end(1):]

for name, text in given:
    new_body = splice(new_body, section_span(new_body, name), text)

# Today's ceremony in approved/: append a "> Reopen: ..." quote line. The
# root reshape carries no quote and leaves the Approval block untouched -
# the quote belongs to the accept that follows.
if room == "approved":
    reopen_line = '> Reopen: "{}" - {}, {}'.format(quote, date, source)
    span = section_span(new_body, 'Approval')
    if span is None:
        sep = '' if new_body.endswith('\n\n') else ('\n' if new_body.endswith('\n') else '\n\n')
        new_body = new_body + sep + '## Approval\n' + reopen_line + '\n'
    else:
        start, end = span
        region = new_body[start:end]
        trail = region[len(region.rstrip('\n')):] or '\n'
        new_body = new_body[:start] + region.rstrip('\n') + '\n' + reopen_line + trail + new_body[end:]

with open(path, 'w', encoding='utf-8') as f:
    f.write(frontmatter_block + new_body)
PYEOF

  if [ -n "$CLAIMED_STORIES" ]; then
    printf '%s\n' "$CLAIMED_STORIES" | tr ';' '\n' | while IFS= read -r s; do
      [ -n "$s" ] && echo "Claimed: $s"
    done
  fi

  SECTIONS_WRITTEN=""
  for pair in "Title:$TITLE_OVERRIDE" "Context:$CONTEXT" "Options considered:$OPTIONS" "Decision:$DECISION" "Consequences:$CONSEQUENCES"; do
    [ -n "${pair#*:}" ] && SECTIONS_WRITTEN="${SECTIONS_WRITTEN:+$SECTIONS_WRITTEN, }${pair%%:*}"
  done
  echo "Sections written: $SECTIONS_WRITTEN"

  echo "$TARGET_FILE"
fi
