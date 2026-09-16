#!/bin/bash
# test-decisions-view.sh — Behavior tests for decisions-view.sh
# Usage: bash tests/test-decisions-view.sh
#
# Every subcommand - `shelf`, `group`, `empty`, `archive` and `card` in all
# five faces including reopen - emits plain key=value data (no
# box-drawing character and no ANSI escape anywhere in stdout), and this
# suite draws that data through `draw_rail` - a literal implementation of
# commands/craft-decisions.md's ### The drawing rule - to reproduce story
# 7's normative Shelf and card exhibits line for line. The reopen face's
# diff rows carry a MARK= key the drawing rule colours; the script emits
# no colour itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/../hooks/scripts/decisions-list.sh"
VIEW="$SCRIPT_DIR/../hooks/scripts/decisions-view.sh"
CAPTURE="$SCRIPT_DIR/../hooks/scripts/decisions-capture.sh"

PASS_COUNT=0; FAIL_COUNT=0; TOTAL=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    Expected: $2"; [ -n "${3:-}" ] && echo "    Got:      $3"; }

fresh_root() {
  ROOT=$(mktemp -d)
  export CRAFT_PROJECT_ROOT="$ROOT"
}

# no_box_chars - reads stdin, prints the count of lines holding a
# box-drawing character (U+2500-U+257F). Used against decisions-view.sh's
# stdout for shelf, group, empty and archive, which must hold none.
no_box_chars() {
  python3 -c "
import sys
bad = 0
for line in sys.stdin.read().split(chr(10)):
    if any(0x2500 <= ord(ch) <= 0x257F for ch in line):
        bad += 1
print(bad)
"
}

# draw_rail - reads decisions-view.sh's key=value stdin (one key per
# line, a blank line never appears - BLANK= carries the meaning instead)
# and draws it by the mechanical rule in commands/craft-decisions.md's
# ### The drawing rule: BLANK= -> '│'; HEAD=x -> '│  x'; ROW=x -> '│    x';
# DIV=x -> '├─ x'; a GROUP block -> '├─ <tag> ── <strip> <total>';
# BAND=x -> '┌─ x ' + dashes; CLOSE= -> '└' + dashes. COUNT_*/MORE keys
# carry test-only metadata and draw nothing. Band/close dash lengths are
# NOT an invariant (the drawing rule says so), so callers compare them as
# "prefix + dashes only", never byte for byte.
draw_rail() {
  python3 -c "
import sys
lines = sys.stdin.read().split(chr(10))
out = []
i = 0
pending_group = None
while i < len(lines):
    line = lines[i]
    if line == '':
        i += 1
        continue
    key, _, val = line.partition('=')
    if key == 'BLANK':
        out.append('│')
    elif key == 'HEAD':
        out.append('│  ' + val)
    elif key == 'ROW':
        out.append('│    ' + val)
    elif key == 'DIV':
        out.append('├─ ' + val)
    elif key == 'BAND':
        out.append('┌─ ' + val + ' ' + ('─' * 50))
    elif key == 'CLOSE':
        out.append('└' + ('─' * 51))
    elif key == 'GROUP':
        pending_group = {'tag': val, 'strip': '', 'total': ''}
    elif key == 'STRIP' and pending_group is not None:
        pending_group['strip'] = val
    elif key == 'TOTAL' and pending_group is not None:
        pending_group['total'] = val
    elif key == 'MORE' and pending_group is not None:
        out.append('├─ {} ── {} {}'.format(pending_group['tag'], pending_group['strip'], pending_group['total']))
        pending_group = None
    # COUNT_Q/COUNT_O/COUNT_C/COUNT_D are metadata only - drawn nothing.
    i += 1
print(chr(10).join(out))
"
}

# write_record ROOM SLUG DATE TITLE STATUS TAGS_CSV [DISPOSITION] [STORIES_CSV] [EXTRA_BODY_LINE]
write_record() {
  local room="$1" slug="$2" date="$3" title="$4" status="$5" tags="$6"
  local disposition="${7:-}" stories="${8:-}" extra="${9:-}"
  local dir
  case "$room" in
    root) dir="$ROOT/.craft/decisions" ;;
    approved) dir="$ROOT/.craft/decisions/approved" ;;
    archive) dir="$ROOT/.craft/decisions/archive" ;;
  esac
  mkdir -p "$dir"
  {
    echo "---"
    echo "type: decision"
    echo "status: $status"
    echo "created: $date"
    echo "source: session"
    echo "tags: [$tags]"
    [ -n "$disposition" ] && echo "disposition: $disposition"
    [ -n "$stories" ] && echo "stories: [$stories]"
    echo "---"
    echo "# $title"
    echo ""
    echo "## Context"
    [ -n "$extra" ] && echo "$extra"
    echo ""
    echo "## Options considered"
    echo "## Decision"
    echo "## Consequences"
    echo "## Approval"
    echo "> \"approved\" - $date, session"
  } > "$dir/$date-$slug.md"
}

# write_story NAME STATUS DECISIONS_CSV [SUBDIR]
# SUBDIR defaults to a cycle stories dir so the story scan glob matches it.
write_story() {
  local name="$1" status="$2" decisions="$3" subdir="${4:-.craft/cycles/1-test/stories}"
  local dir="$ROOT/$subdir"
  mkdir -p "$dir"
  cat > "$dir/$name.md" <<EOF
---
name: $name
status: $status
decisions: [$decisions]
---
# $name
EOF
}

# write_archive_record SLUG DATE STATUS TAGS QUOTE_BLOCK
# QUOTE_BLOCK is the raw "> "-prefixed exit-quote lines placed under
# ## Approval, verbatim - so a test can shape a multi-line quote whose
# attribution line is not the block's last line, exactly like the live
# archive records the Investigation names.
write_archive_record() {
  local slug="$1" date="$2" status="$3" tags="$4" quote_block="$5"
  local dir="$ROOT/.craft/decisions/archive"
  mkdir -p "$dir"
  {
    echo "---"
    echo "type: decision"
    echo "status: $status"
    echo "created: $date"
    echo "source: session"
    echo "tags: [$tags]"
    echo "---"
    echo "# Title for $slug"
    echo ""
    echo "## Context"
    echo ""
    echo "## Options considered"
    echo "## Decision"
    echo "## Consequences"
    echo "## Approval"
    printf '%s\n' "$quote_block"
  } > "$dir/$date-$slug.md"
}

# write_options_record ROOM SLUG DATE TITLE STATUS TAGS_CSV OPTIONS_TEXT
# Like write_record, but with an explicit ## Options considered body so
# the pending-state detection tests can pin lettered / dashed / empty
# shapes.
write_options_record() {
  local room="$1" slug="$2" date="$3" title="$4" status="$5" tags="$6" options="$7"
  local dir
  case "$room" in
    root) dir="$ROOT/.craft/decisions" ;;
    approved) dir="$ROOT/.craft/decisions/approved" ;;
    archive) dir="$ROOT/.craft/decisions/archive" ;;
  esac
  mkdir -p "$dir"
  {
    echo "---"
    echo "type: decision"
    echo "status: $status"
    echo "created: $date"
    echo "source: session"
    echo "tags: [$tags]"
    echo "---"
    echo "# $title"
    echo ""
    echo "## Context"
    echo "Some context for $slug."
    echo ""
    echo "## Options considered"
    printf '%s\n' "$options"
    echo ""
    echo "## Decision"
    echo "The pick for $slug."
    echo ""
    echo "## Consequences"
    echo "What follows for $slug."
    echo ""
    echo "## Approval"
  } > "$dir/$date-$slug.md"
}

# build_reference_fixture - 4 tags / 37 non-archive records, reproducing
# the approved 34-line Shelf. Dates are chosen so decisions-list.sh's own
# date-then-filename emission order equals the frame's drawn row order
# (see the story's Investigation - the fixture is test-owned, the live
# store no longer matches it).
build_reference_fixture() {
  local OPEN_RTC=(
    "design-conversation-behavior"
    "no-default-hard-stop"
    "before-you-leave-receipt-instrument"
    "production-boundary-records-versus-artifacts"
    "q5-and-q3-are-derived-not-open"
    "worker-brief-instrument"
    "wright-authors-its-own-run-debrief"
    "public-authoring-convention-derived"
    "room-transitions-are-invisible"
  )
  local i d
  for i in "${!OPEN_RTC[@]}"; do
    d=$(printf "2026-01-%02d" $((i + 1)))
    write_record "approved" "${OPEN_RTC[$i]}" "$d" "RTC open $i" "accepted" "requirement-to-cycle"
  done

  local CLAIMED_RTC=(
    "attention-quiet-while-healthy"
    "claimed-rtc-b" "claimed-rtc-c" "claimed-rtc-d" "claimed-rtc-e"
    "claimed-rtc-f" "claimed-rtc-g" "claimed-rtc-h" "claimed-rtc-i"
  )
  local rtc_slugs=""
  for i in "${!CLAIMED_RTC[@]}"; do
    d=$(printf "2026-02-%02d" $((i + 1)))
    write_record "approved" "${CLAIMED_RTC[$i]}" "$d" "RTC claimed $i" "accepted" "requirement-to-cycle"
    rtc_slugs="${rtc_slugs}${d}-${CLAIMED_RTC[$i]}, "
  done
  write_story "claims-rtc" "planning" "$rtc_slugs"

  local OPEN_GUIDES=(
    "guides-have-an-index-and-a-lifespan"
    "stories-carry-a-guides-section"
    "the-notebook-holds-guides"
  )
  for i in "${!OPEN_GUIDES[@]}"; do
    d=$(printf "2026-01-%02d" $((i + 1)))
    write_record "approved" "${OPEN_GUIDES[$i]}" "$d" "Guides open $i" "accepted" "guides"
  done

  write_record "approved" "the-feature-folder-model-retires-sealed" "2026-01-01" "Wright open" "accepted" "wright"

  local CLAIMED_DEC=(
    "craft-decisions-renders-the-shelf"
    "claimed-dec-b" "claimed-dec-c" "claimed-dec-d" "claimed-dec-e"
  )
  local dec_slugs=""
  for i in "${!CLAIMED_DEC[@]}"; do
    d=$(printf "2026-03-%02d" $((i + 1)))
    write_record "approved" "${CLAIMED_DEC[$i]}" "$d" "Decisions claimed $i" "accepted" "decisions"
    dec_slugs="${dec_slugs}${d}-${CLAIMED_DEC[$i]}, "
  done
  write_story "claims-dec" "planning" "$dec_slugs"

  for i in $(seq -w 1 10); do
    write_record "approved" "crafted-dec-$i" "2026-04-$i" "Decisions crafted $i" "accepted" "decisions" "crafted" "ship-story-dec"
  done
}

# build_shape_fixture - reproduces the exact 2026-09-10 snapshot story
# 7-the-desk-draws-from-data.md's normative Shelf exhibit was drawn from:
# 18 requirement-to-cycle (10 open, 8 claimed - attention-quiet-while-
# healthy shown, +7 more), 3 guides, 2 wright-journal, 24 decisions (1
# open, 23 crafted - crafted records get no row), 1 wright. The live
# store cannot stand in for this fixture (Chunk 1 added two records to
# the decisions group), so the exhibit is pinned here instead.
build_shape_fixture() {
  local OPEN_RTC=(
    "before-you-leave-receipt-instrument"
    "design-conversation-behavior"
    "no-default-hard-stop"
    "production-boundary-records-versus-artifacts"
    "q5-and-q3-are-derived-not-open"
    "worker-brief-instrument"
    "wright-authors-its-own-run-debrief"
    "public-authoring-convention-derived"
    "room-transitions-are-invisible"
    "the-journal-holds-a-run-s-best-and-worst-moments"
  )
  local i d
  for i in "${!OPEN_RTC[@]}"; do
    d=$(printf "2026-01-%02d" $((i + 1)))
    write_record "approved" "${OPEN_RTC[$i]}" "$d" "RTC open $i" "accepted" "requirement-to-cycle"
  done

  local CLAIMED_RTC=(
    "attention-quiet-while-healthy"
    "claimed-rtc-b" "claimed-rtc-c" "claimed-rtc-d" "claimed-rtc-e"
    "claimed-rtc-f" "claimed-rtc-g" "claimed-rtc-h"
  )
  local rtc_slugs=""
  for i in "${!CLAIMED_RTC[@]}"; do
    d=$(printf "2026-02-%02d" $((i + 1)))
    write_record "approved" "${CLAIMED_RTC[$i]}" "$d" "RTC claimed $i" "accepted" "requirement-to-cycle"
    rtc_slugs="${rtc_slugs}${d}-${CLAIMED_RTC[$i]}, "
  done
  write_story "claims-rtc-shape" "planning" "$rtc_slugs"

  local OPEN_GUIDES=(
    "guides-have-an-index-and-a-lifespan"
    "stories-carry-a-guides-section"
    "the-notebook-holds-guides"
  )
  for i in "${!OPEN_GUIDES[@]}"; do
    d=$(printf "2026-01-%02d" $((i + 1)))
    write_record "approved" "${OPEN_GUIDES[$i]}" "$d" "Guides open $i" "accepted" "guides"
  done

  local OPEN_WJ=(
    "the-journal-is-personal-and-lives-with-the-user"
    "the-ledger-holds-only-what-cannot-be-derived"
  )
  for i in "${!OPEN_WJ[@]}"; do
    d=$(printf "2026-01-%02d" $((i + 1)))
    write_record "approved" "${OPEN_WJ[$i]}" "$d" "WJ open $i" "accepted" "wright-journal"
  done

  write_record "approved" "decisions-assets-holds-whatever-a-record-points-at" "2026-01-01" "Decisions open" "accepted" "decisions"

  for i in $(seq -w 1 23); do
    write_record "approved" "decisions-crafted-$i" "2026-04-$i" "Decisions crafted $i" "accepted" "decisions" "crafted" "ship-story-shape"
  done

  write_record "approved" "the-feature-folder-model-retires-sealed" "2026-01-01" "Wright open" "accepted" "wright"
}

echo "=== test-decisions-view.sh ==="
echo ""

echo "-- Test: decisions-view.sh exists and is executable --"
[ -x "$VIEW" ] && pass "decisions-view.sh exists and is executable" || fail "decisions-view.sh exists and is executable" "executable file" "missing or not executable"

echo "-- Test: the approved Shelf exhibit is reproduced from the view's data by the drawing rule (FIRST test) --"
fresh_root
build_shape_fixture
SHELF_EXHIBIT=$(cat <<'@@SHELF_EXHIBIT@@'
┌─ DECISION SHELF ──────────────────────────────────
│  ? pending   ○ unclaimed   ● claimed   ✓ done
│
├─ requirement-to-cycle ── ○○○○○○○○○○●●●●●●●● 18
│    ○ before-you-leave-receipt-instrument
│    ○ design-conversation-behavior
│    ○ no-default-hard-stop
│    ○ production-boundary-records-versus-artifacts
│    ○ q5-and-q3-are-derived-not-open
│    ○ worker-brief-instrument
│    ○ wright-authors-its-own-run-debrief
│    ○ public-authoring-convention-derived
│    ○ room-transitions-are-invisible
│    ○ the-journal-holds-a-run-s-best-and-worst-moments
│    ● attention-quiet-while-healthy
│      +7 more
│
├─ guides ── ○○○ 3
│    ○ guides-have-an-index-and-a-lifespan
│    ○ stories-carry-a-guides-section
│    ○ the-notebook-holds-guides
│
├─ wright-journal ── ○○ 2
│    ○ the-journal-is-personal-and-lives-with-the-user
│    ○ the-ledger-holds-only-what-cannot-be-derived
│
├─ decisions ── ○✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓✓ 24
│    ○ decisions-assets-holds-whatever-a-record-points-at
│
├─ wright ── ○ 1
│    ○ the-feature-folder-model-retires-sealed
│
└───────────────────────────────────────────────────
@@SHELF_EXHIBIT@@
)
# Bands and the closing rule are decoration, not an invariant - the
# drawing rule says their length is not fixed - so both sides are
# normalized to a single DASHES marker before comparing.
normalize_bands() {
  python3 -c "
import sys, re
for line in sys.stdin.read().split(chr(10)):
    print(re.sub(r'─+', 'DASHES', line))
"
}
DRAWN=$(bash "$LIST" | bash "$VIEW" shelf | draw_rail)
[ "$(printf '%s' "$DRAWN" | normalize_bands)" = "$(printf '%s' "$SHELF_EXHIBIT" | normalize_bands)" ] \
  && pass "the approved Shelf exhibit is reproduced from the view's data by the drawing rule" \
  || fail "the approved Shelf exhibit is reproduced from the view's data by the drawing rule" "$SHELF_EXHIBIT" "$DRAWN"
rm -rf "$ROOT"

echo "-- Test: no line of shelf, group, empty or archive stdout holds a box-drawing character --"
fresh_root
build_shape_fixture
SHELF_BAD=$(bash "$LIST" | bash "$VIEW" shelf | no_box_chars)
[ "$SHELF_BAD" = "0" ] && pass "shelf stdout holds no box-drawing character" || fail "shelf stdout holds no box-drawing character" "0" "$SHELF_BAD"
GROUP_BAD=$(bash "$LIST" --tag=wright-journal | bash "$VIEW" group | no_box_chars)
[ "$GROUP_BAD" = "0" ] && pass "group stdout holds no box-drawing character" || fail "group stdout holds no box-drawing character" "0" "$GROUP_BAD"
rm -rf "$ROOT"

fresh_root
EMPTY_BAD=$(bash "$LIST" | bash "$VIEW" shelf | no_box_chars)
[ "$EMPTY_BAD" = "0" ] && pass "empty view stdout holds no box-drawing character" || fail "empty view stdout holds no box-drawing character" "0" "$EMPTY_BAD"
write_archive_record "declined-idea" "2026-01-01" "declined" "alpha" '> "No." - Darin, 2026-05-01, session'
ARCHIVE_BAD=$(bash "$LIST" --room=archive | bash "$VIEW" archive | no_box_chars)
[ "$ARCHIVE_BAD" = "0" ] && pass "archive stdout holds no box-drawing character" || fail "archive stdout holds no box-drawing character" "0" "$ARCHIVE_BAD"
rm -rf "$ROOT"

echo "-- Test: decisions-view.sh match --"
fresh_root
write_record "root" "match-root-pending" "2026-01-01" "Root pending checkout item" "pending" "checkout"
write_record "approved" "match-approved-open" "2026-01-02" "Approved open checkout item" "accepted" "checkout"
write_record "approved" "match-approved-claimed" "2026-01-03" "Approved claimed checkout item" "accepted" "checkout"
write_story "claims-match-approved-claimed" "planning" "2026-01-03-match-approved-claimed"
write_record "approved" "match-approved-crafted" "2026-01-04" "Approved crafted checkout item" "accepted" "checkout" "crafted"
write_archive_record "match-archive-one" "2026-01-05" "declined" "checkout" '> "No." - Darin, 2026-01-05, session'
write_archive_record "match-archive-two" "2026-01-06" "retired" "checkout" '> "Retired." - Darin, 2026-01-06, session'

MATCH_OUT=$(bash "$LIST" --tag=checkout | bash "$VIEW" match --words=checkout)

echo "$MATCH_OUT" | grep -q '^BAND=6 MATCH "checkout"$' \
  && pass "the match drawer's band names the count and the searched words" \
  || fail "the match drawer's band names the count and the searched words" 'BAND=6 MATCH "checkout"' "$(echo "$MATCH_OUT" | grep '^BAND=')"

NO_WORDS_OUT=$(bash "$LIST" --tag=checkout | bash "$VIEW" match)
echo "$NO_WORDS_OUT" | grep -q '^BAND=6 MATCH$' \
  && pass "the band drops the words segment when --words= is absent" \
  || fail "the band drops the words segment when --words= is absent" 'BAND=6 MATCH' "$(echo "$NO_WORDS_OUT" | grep '^BAND=')"

echo "$MATCH_OUT" | grep -qF 'HEAD=? pending   ○ unclaimed   ● claimed   ✓ done   × archived' \
  && pass "the key band carries the Shelf's four glyphs plus the archived cross" \
  || fail "the key band carries the Shelf's four glyphs plus the archived cross" 'HEAD=? pending   ○ unclaimed   ● claimed   ✓ done   × archived' "$(echo "$MATCH_OUT" | grep '^HEAD=' | head -1)"

ARCHIVE_HEAD_COUNT=$(echo "$MATCH_OUT" | grep -c '^HEAD=×  ' || true)
[ "$ARCHIVE_HEAD_COUNT" = "2" ] \
  && pass "an archived record draws the cross" \
  || fail "an archived record draws the cross" "2" "$ARCHIVE_HEAD_COUNT"

echo "$MATCH_OUT" | grep -qF 'HEAD=?  Root pending checkout item' \
  && echo "$MATCH_OUT" | grep -qF 'HEAD=✓  Approved crafted checkout item' \
  && echo "$MATCH_OUT" | grep -qF 'HEAD=●  Approved claimed checkout item' \
  && echo "$MATCH_OUT" | grep -qF 'HEAD=○  Approved open checkout item' \
  && pass "every other record keeps its Shelf glyph" \
  || fail "every other record keeps its Shelf glyph" "? / ✓ / ● / ○ prefixed HEAD lines" "$(echo "$MATCH_OUT" | grep '^HEAD=' | tail -6)"

echo "$MATCH_OUT" | grep -q "Approved open checkout item" && ! echo "$MATCH_OUT" | grep -q "match-approved-open" \
  && pass "record lines carry the title, not the slug" \
  || fail "record lines carry the title, not the slug" "title present, slug absent" "$MATCH_OUT"

DRAWN_MATCH=$(printf '%s\n' "$MATCH_OUT" | draw_rail)
RECORD_LINES=$(printf '%s\n' "$DRAWN_MATCH" | grep -E '^│  [?○●✓×]  ' || true)
[ "$(printf '%s\n' "$RECORD_LINES" | wc -l | tr -d ' ')" = "6" ] \
  && pass "record lines are HEAD= lines, so the drawn glyph column sits at two spaces" \
  || fail "record lines are HEAD= lines, so the drawn glyph column sits at two spaces" "6 lines at │  <glyph>  " "${RECORD_LINES:-<none>}"

LAST_TWO_RECORD_LINES=$(printf '%s\n' "$MATCH_OUT" | grep '^HEAD=' | tail -3 | head -2)
printf '%s\n' "$LAST_TWO_RECORD_LINES" | grep -q '^HEAD=×' \
  && [ "$(printf '%s\n' "$LAST_TWO_RECORD_LINES" | grep -c '^HEAD=×')" = "2" ] \
  && pass "archived records sort to the bottom, as the list's own room order gives them" \
  || fail "archived records sort to the bottom, as the list's own room order gives them" "the two × lines are last" "$LAST_TWO_RECORD_LINES"

echo "$MATCH_OUT" | grep -qF 'HEAD=Name one, or narrow it.' \
  && [ "$(echo "$MATCH_OUT" | tail -1)" = "CLOSE=" ] \
  && pass "the drawer closes with the ruled line" \
  || fail "the drawer closes with the ruled line" "HEAD=Name one, or narrow it. then CLOSE=" "$(echo "$MATCH_OUT" | tail -2)"

MATCH_EXHIBIT=$(cat <<'@@MATCH_EXHIBIT@@'
┌─ 6 MATCH "checkout" ──────────────────────────────
│  ? pending   ○ unclaimed   ● claimed   ✓ done   × archived
│
│  ?  Root pending checkout item
│  ○  Approved open checkout item
│  ●  Approved claimed checkout item
│  ✓  Approved crafted checkout item
│  ×  Title for match-archive-one
│  ×  Title for match-archive-two
│
│  Name one, or narrow it.
└───────────────────────────────────────────────────
@@MATCH_EXHIBIT@@
)
[ "$(printf '%s' "$DRAWN_MATCH" | normalize_bands)" = "$(printf '%s' "$MATCH_EXHIBIT" | normalize_bands)" ] \
  && pass "the drawer drawn through draw_rail reproduces the ruled shape" \
  || fail "the drawer drawn through draw_rail reproduces the ruled shape" "$MATCH_EXHIBIT" "$DRAWN_MATCH"

MATCH_BAD=$(echo "$MATCH_OUT" | no_box_chars)
[ "$MATCH_BAD" = "0" ] && pass "match stdout holds no box-drawing character" || fail "match stdout holds no box-drawing character" "0" "$MATCH_BAD"

rm -rf "$ROOT"

echo "-- Test: a long title in the match drawer --"
fresh_root
LONG_TITLE=$(printf 'word %.0s' {1..25})
LONG_TITLE="${LONG_TITLE% }"
write_record "approved" "match-long-title" "2026-01-01" "$LONG_TITLE" "accepted" "checkout"
LONG_OUT=$(bash "$LIST" --tag=checkout | bash "$VIEW" match --words=checkout)
LONG_HEAD_LINE=$(echo "$LONG_OUT" | grep '^HEAD=○' || true)
echo "$LONG_OUT" | grep -qF "HEAD=○  $LONG_TITLE" \
  && pass "a long title prints on one line, unwrapped and uncut" \
  || fail "a long title prints on one line, unwrapped and uncut" "HEAD=○  $LONG_TITLE" "${LONG_HEAD_LINE:-<none>}"
echo "$LONG_OUT" | grep -q '…' \
  && fail "no line in the drawer carries an ellipsis" "absent" "present" \
  || pass "no line in the drawer carries an ellipsis"
rm -rf "$ROOT"

echo "-- Test: a single-block stdin still draws a one-row drawer --"
fresh_root
write_record "approved" "match-solo" "2026-01-01" "Solo checkout item" "accepted" "checkout"
SOLO_OUT=$(bash "$LIST" --tag=checkout | bash "$VIEW" match --words=checkout)
SOLO_HEAD_COUNT=$(echo "$SOLO_OUT" | grep -c '^HEAD=' || true)
echo "$SOLO_OUT" | grep -q '^BAND=1 MATCH "checkout"$' \
  && [ "$SOLO_HEAD_COUNT" = "3" ] \
  && pass "a single-block stdin still draws a one-row drawer" \
  || fail "a single-block stdin still draws a one-row drawer" 'BAND=1 and 3 HEAD lines' "$SOLO_OUT"
rm -rf "$ROOT"

echo "-- Test: groups arrive in the ruled sort order - pending first, then most unclaimed, then tag name --"
fresh_root
write_record "root" "the-notebook-holds-a-guides-index" "2026-01-01" "Pending guides idea" "pending" "guides"
write_record "approved" "guides-have-an-index-and-a-lifespan" "2026-01-02" "Guides A" "accepted" "guides"
write_record "approved" "stories-carry-a-guides-section" "2026-01-03" "Guides B" "accepted" "guides"
write_record "approved" "the-notebook-holds-guides" "2026-01-04" "Guides C" "accepted" "guides"
write_record "approved" "has-open-a" "2026-01-01" "Has open A" "accepted" "has-open-tag"
write_record "approved" "zero-a" "2026-01-01" "Zero A" "accepted" "zero-tag"
write_story "claims-zero-a" "planning" "2026-01-01-zero-a"
write_record "approved" "bbb-one" "2026-01-01" "Bbb one" "accepted" "bbb-tag"
write_record "approved" "aaa-one" "2026-01-01" "Aaa one" "accepted" "aaa-tag"
write_record "approved" "aaa-two" "2026-01-02" "Aaa two" "accepted" "aaa-tag"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
GROUP_ORDER=$(echo "$OUT" | grep '^GROUP=' | sed 's/^GROUP=//')
EXPECTED_ORDER=$'guides\naaa-tag\nbbb-tag\nhas-open-tag\nzero-tag'
[ "$GROUP_ORDER" = "$EXPECTED_ORDER" ] && pass "groups arrive pending-first, then most-unclaimed, then tag name" || fail "groups arrive pending-first, then most-unclaimed, then tag name" "$EXPECTED_ORDER" "$GROUP_ORDER"
rm -rf "$ROOT"

echo "-- Test: the full glyph strip survives a group past the old capacity --"
fresh_root
for i in $(seq -w 1 40); do
  write_record "approved" "scale-record-$i" "2026-01-01" "Scale record $i" "accepted" "scale"
done
STRIP=$(bash "$LIST" | bash "$VIEW" shelf | grep '^STRIP=' | sed 's/^STRIP=//')
GLYPH_COUNT=$(printf '%s' "$STRIP" | grep -o '○' | wc -l | tr -d ' ')
[ "$GLYPH_COUNT" = "40" ] && pass "a 40-record group emits 40 glyphs" || fail "a 40-record group emits 40 glyphs" "40" "$GLYPH_COUNT"
echo "$STRIP" | grep -q '…' && fail "the strip carries no ellipsis" "absent" "present" || pass "the strip carries no ellipsis"
rm -rf "$ROOT"

echo "-- Test: claimed rows collapse to one ROW plus MORE --"
fresh_root
write_record "approved" "order-check-claimed" "2026-01-01" "Order check claimed" "accepted" "order-check-tag"
write_story "claims-order-check" "planning" "2026-01-01-order-check-claimed"
write_record "approved" "order-check-claimed-2" "2026-01-02" "Order check claimed 2" "accepted" "order-check-tag"
write_story "claims-order-check-2" "planning" "2026-01-02-order-check-claimed-2"
write_record "approved" "order-check-open-a" "2026-01-03" "Order check open a" "accepted" "order-check-tag"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
MORE_LINE=$(echo "$OUT" | grep '^MORE=')
CLAIMED_ROWS=$(echo "$OUT" | grep '^ROW=● ')
[ "$MORE_LINE" = "MORE=1" ] && pass "MORE= carries the remaining-claimed count" || fail "MORE= carries the remaining-claimed count" "MORE=1" "$MORE_LINE"
[ "$(printf '%s\n' "$CLAIMED_ROWS" | wc -l | tr -d ' ')" = "1" ] && pass "exactly one ● ROW prints, the rest collapse" || fail "exactly one ● ROW prints, the rest collapse" "1" "$CLAIMED_ROWS"
echo "$OUT" | grep -q '^ROW=  +1 more$' && pass "the +N more row carries the drawing rule's baked-in two spaces" || fail "the +N more row carries the drawing rule's baked-in two spaces" "ROW=  +1 more" "$OUT"
rm -rf "$ROOT"

echo "-- Test: a root+pending record claimed by a live story still renders ? --"
fresh_root
write_record "root" "pending-claimed" "2026-01-01" "Pending claimed" "pending" "pending-tag"
write_story "claims-it" "planning" "2026-01-01-pending-claimed"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
echo "$OUT" | grep -q '^ROW=? pending-claimed$' && pass "root+pending renders the ? glyph even when DISPOSITION derives claimed" || fail "root+pending renders the ? glyph even when DISPOSITION derives claimed" "ROW=? pending-claimed" "$OUT"
rm -rf "$ROOT"

echo "-- Test: rows are grouped by glyph class, not raw emission order - a claimed record dated earlier than the open ones still prints after them --"
fresh_root
write_record "approved" "order-check-claimed" "2026-01-01" "Order check claimed" "accepted" "order-check-tag"
write_story "claims-order-check" "planning" "2026-01-01-order-check-claimed"
write_record "approved" "order-check-open-a" "2026-01-02" "Order check open a" "accepted" "order-check-tag"
write_record "approved" "order-check-open-b" "2026-01-03" "Order check open b" "accepted" "order-check-tag"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
CLAIMED_ROW_LINE=$(echo "$OUT" | grep -n '^ROW=● order-check-claimed$' | cut -d: -f1)
OPEN_A_LINE=$(echo "$OUT" | grep -n '^ROW=○ order-check-open-a$' | cut -d: -f1)
OPEN_B_LINE=$(echo "$OUT" | grep -n '^ROW=○ order-check-open-b$' | cut -d: -f1)
[ -n "$OPEN_A_LINE" ] && [ -n "$OPEN_B_LINE" ] && [ -n "$CLAIMED_ROW_LINE" ] && [ "$OPEN_A_LINE" -lt "$CLAIMED_ROW_LINE" ] && [ "$OPEN_B_LINE" -lt "$CLAIMED_ROW_LINE" ] && pass "both ○ rows print before the ● row even though the claimed record is earliest in emission order" || fail "both ○ rows print before the ● row even though the claimed record is earliest in emission order" "○ rows, then ● row" "$OUT"
rm -rf "$ROOT"

echo "-- Test: a group with a pending record sorts to the top and its ? row leads the group --"
fresh_root
write_record "root" "the-notebook-holds-a-guides-index" "2026-01-01" "Pending guides idea" "pending" "guides"
write_record "approved" "guides-have-an-index-and-a-lifespan" "2026-01-02" "Guides A" "accepted" "guides"
write_record "approved" "stories-carry-a-guides-section" "2026-01-03" "Guides B" "accepted" "guides"
write_record "approved" "the-notebook-holds-guides" "2026-01-04" "Guides C" "accepted" "guides"
write_record "approved" "other-a" "2026-01-01" "Other A" "accepted" "other"
write_record "approved" "other-b" "2026-01-02" "Other B" "accepted" "other"
write_record "approved" "other-c" "2026-01-03" "Other C" "accepted" "other"
write_record "approved" "other-d" "2026-01-04" "Other D" "accepted" "other"
write_record "approved" "other-e" "2026-01-05" "Other E" "accepted" "other"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
GUIDES_ROWS=$(printf '%s\n' "$OUT" | awk '/^GROUP=guides$/{f=1} f{print} f && /^ROW=/ && ++n==4{exit}')
echo "$GUIDES_ROWS" | grep -q '^ROW=? the-notebook-holds-a-guides-index$' && pass "the pending row leads the guides group" || fail "the pending row leads the guides group" "ROW=? the-notebook-holds-a-guides-index" "$GUIDES_ROWS"
GUIDES_LINE=$(echo "$OUT" | grep -n '^GROUP=guides$' | cut -d: -f1)
OTHER_LINE=$(echo "$OUT" | grep -n '^GROUP=other$' | cut -d: -f1)
[ "$GUIDES_LINE" -lt "$OTHER_LINE" ] && pass "the pending tag sorts to the top" || fail "the pending tag sorts to the top" "guides before other" "guides=$GUIDES_LINE other=$OTHER_LINE"
rm -rf "$ROOT"

echo "-- Test: groups with zero unclaimed sink below every group that has unclaimed records --"
fresh_root
write_record "approved" "zero-a" "2026-01-01" "Zero A" "accepted" "zero-tag"
write_story "claims-zero-a" "planning" "2026-01-01-zero-a"
write_record "approved" "zero-b" "2026-01-02" "Zero B" "accepted" "zero-tag"
write_story "claims-zero-b" "planning" "2026-01-02-zero-b"
write_record "approved" "has-open-a" "2026-01-01" "Has open A" "accepted" "has-open-tag"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
ZERO_LINE=$(echo "$OUT" | grep -n '^GROUP=zero-tag$' | cut -d: -f1)
OPEN_LINE=$(echo "$OUT" | grep -n '^GROUP=has-open-tag$' | cut -d: -f1)
[ "$OPEN_LINE" -lt "$ZERO_LINE" ] && pass "the group with unclaimed records sorts above the zero-unclaimed group" || fail "the group with unclaimed records sorts above the zero-unclaimed group" "has-open-tag before zero-tag" "has-open-tag=$OPEN_LINE zero-tag=$ZERO_LINE"
rm -rf "$ROOT"

echo "-- Test: equal-unclaimed groups order by tag name ascending --"
fresh_root
write_record "approved" "bbb-one" "2026-01-01" "Bbb one" "accepted" "bbb-tag"
write_record "approved" "bbb-two" "2026-01-02" "Bbb two" "accepted" "bbb-tag"
write_record "approved" "aaa-one" "2026-01-01" "Aaa one" "accepted" "aaa-tag"
write_record "approved" "aaa-two" "2026-01-02" "Aaa two" "accepted" "aaa-tag"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
AAA_LINE=$(echo "$OUT" | grep -n '^GROUP=aaa-tag$' | cut -d: -f1)
BBB_LINE=$(echo "$OUT" | grep -n '^GROUP=bbb-tag$' | cut -d: -f1)
[ "$AAA_LINE" -lt "$BBB_LINE" ] && pass "equal-unclaimed groups tie-break by tag name ascending" || fail "equal-unclaimed groups tie-break by tag name ascending" "aaa-tag before bbb-tag" "aaa-tag=$AAA_LINE bbb-tag=$BBB_LINE"
rm -rf "$ROOT"

echo "-- Test: done records get no row, archived records get no row and no count --"
fresh_root
write_record "approved" "alpha-one" "2026-01-01" "Alpha one" "accepted" "alpha"
write_record "approved" "alpha-two" "2026-01-02" "Alpha two" "accepted" "alpha" "crafted" "ship-story-alpha"
write_record "archive" "alpha-archived" "2026-01-03" "Alpha archived" "declined" "alpha"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
echo "$OUT" | grep -q "alpha-archived" && fail "archived slug absent from the Shelf" "absent" "present" || pass "archived slug absent from the Shelf"
echo "$OUT" | grep -q "alpha-two" && fail "a crafted (done) record gets no row" "absent" "present" || pass "a crafted (done) record gets no row"
echo "$OUT" | grep -A1 '^GROUP=alpha$' | grep -q '^STRIP=○✓$' && pass "the tag total counts the done record in its strip; the archived record is excluded entirely" || fail "the tag total counts the done record in its strip; the archived record is excluded entirely" "STRIP=○✓" "$OUT"
echo "$OUT" | grep -A2 '^GROUP=alpha$' | grep -q '^TOTAL=2$' && pass "the tag total is 2 (open + crafted), not 3 (archived excluded)" || fail "the tag total is 2 (open + crafted), not 3 (archived excluded)" "TOTAL=2" "$OUT"
rm -rf "$ROOT"

echo "-- Test: the group view emits one group and no band, key line or close --"
fresh_root
write_record "approved" "the-journal-is-personal-and-lives-with-the-user" "2026-01-01" "WJ A" "accepted" "wright-journal"
write_record "approved" "the-ledger-holds-only-what-cannot-be-derived" "2026-01-02" "WJ B" "accepted" "wright-journal"
OUT=$(bash "$LIST" --tag=wright-journal | bash "$VIEW" group)
echo "$OUT" | grep -q '^GROUP=wright-journal$' && pass "the group view emits one GROUP= block" || fail "the group view emits one GROUP= block" "GROUP=wright-journal" "$OUT"
echo "$OUT" | grep -q '^ROW=○ the-journal-is-personal-and-lives-with-the-user$' && pass "the group view emits the group's rows" || fail "the group view emits the group's rows" "ROW=○ the-journal-is-personal-and-lives-with-the-user" "$OUT"
echo "$OUT" | grep -q '^ROW=○ the-ledger-holds-only-what-cannot-be-derived$' && pass "the group view emits every row in the group" || fail "the group view emits every row in the group" "ROW=○ the-ledger-holds-only-what-cannot-be-derived" "$OUT"
echo "$OUT" | grep -q '^BAND=' && fail "the group view emits no BAND=" "absent" "present" || pass "the group view emits no BAND="
echo "$OUT" | grep -q '^HEAD=' && fail "the group view emits no HEAD=" "absent" "present" || pass "the group view emits no HEAD="
echo "$OUT" | grep -q '^CLOSE=' && fail "the group view emits no CLOSE=" "absent" "present" || pass "the group view emits no CLOSE="
rm -rf "$ROOT"

echo "-- Test: the empty view emits the fixed copy verbatim and one real record replaces it entirely --"
fresh_root
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
echo "$OUT" | grep -qF "BAND=DECISION SHELF  ·  empty" && pass "the empty view's title band prints" || fail "the empty view's title band prints" "BAND=DECISION SHELF  ·  empty" "$OUT"
echo "$OUT" | grep -qF "A decision is the one thing you're already sure of about a feature that has no cycle, no story, not even a name." && pass "the empty view's definition sentence prints verbatim" || fail "the definition sentence prints verbatim" "" "$OUT"
echo "$OUT" | grep -qF 'The gameroom has a slot machine' && pass "the today example line prints" || fail "the today example line prints" "" "$OUT"
echo "$OUT" | grep -qF 'The slot machine has a bonus round' && pass "the tomorrow example line prints" || fail "the tomorrow example line prints" "" "$OUT"
echo "$OUT" | grep -qF "The tag is the feature you haven't planned yet" && pass "the closing paragraph prints verbatim" || fail "the closing paragraph prints verbatim" "" "$OUT"
echo "$OUT" | grep -qF 'GROUP=gameroom (example)' && pass "the gameroom example group prints" || fail "the gameroom example group prints" "GROUP=gameroom (example)" "$OUT"
echo "$OUT" | grep -q '^ROW=○ the-gameroom-has-a-slot-machine$' && pass "the gameroom example rows print" || fail "the gameroom example rows print" "" "$OUT"
rm -rf "$ROOT"

fresh_root
mkdir -p "$ROOT/.craft/decisions"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
echo "$OUT" | grep -qF "BAND=DECISION SHELF  ·  empty" && pass "the empty view prints for an empty .craft/decisions directory too" || fail "the empty view prints for an empty .craft/decisions directory too" "" "$OUT"
rm -rf "$ROOT"

echo "-- Test: one real record replaces the empty view entirely and the word gameroom appears nowhere in the output --"
fresh_root
write_record "approved" "a-real-record" "2026-01-01" "A real record" "accepted" "real-tag"
OUT=$(bash "$LIST" | bash "$VIEW" shelf)
echo "$OUT" | grep -q "BAND=DECISION SHELF  ·  empty" && fail "the empty view does not print once a real record exists" "absent" "present" || pass "the empty view does not print once a real record exists"
echo "$OUT" | grep -qi "gameroom" && fail "gameroom appears nowhere once a real record exists" "absent" "present" || pass "gameroom appears nowhere once a real record exists"
rm -rf "$ROOT"

echo "-- Test: the archive emits one ROW per record, labelled, newest exit first --"
fresh_root
write_archive_record "declined-idea" "2026-01-01" "declined" "alpha" '> "No." - Darin, 2026-05-01, session'
write_archive_record "retired-idea" "2026-01-02" "deprecated" "alpha" '> "This was good for its time, but the approach it locks in
> now conflicts with the newer room model. [...] Retiring it."
> - Darin, 2026-05-15, session'
write_archive_record "retired-idea-two" "2026-01-03" "deprecated" "alpha" '> "Superseded." - Darin, 2026-05-10, session'
OUT=$(bash "$LIST" --room=archive | bash "$VIEW" archive)
RETIRED_LINE=$(echo "$OUT" | grep -n '^ROW=retired  retired-idea$' | cut -d: -f1)
RETIRED_TWO_LINE=$(echo "$OUT" | grep -n 'retired-idea-two' | cut -d: -f1)
DECLINED_LINE=$(echo "$OUT" | grep -n 'declined-idea' | cut -d: -f1)
[ -n "$RETIRED_LINE" ] && [ -n "$RETIRED_TWO_LINE" ] && [ -n "$DECLINED_LINE" ] && [ "$RETIRED_LINE" -lt "$RETIRED_TWO_LINE" ] && [ "$RETIRED_TWO_LINE" -lt "$DECLINED_LINE" ] && pass "records order newest exit first" || fail "records order newest exit first" "retired-idea, retired-idea-two, declined-idea" "$OUT"
echo "$OUT" | grep -q '^ROW=declined ' && pass "the declined label prints, padded to 9" || fail "the declined label prints, padded to 9" "" "$OUT"
echo "$OUT" | grep -q '^ROW=retired  ' && pass "the retired label prints, padded to 9" || fail "the retired label prints, padded to 9" "" "$OUT"
echo "$OUT" | grep -qi "good for its time" && pass "the wrapped exit words appear" || fail "the wrapped exit words appear" "good for its time" "$OUT"
echo "$OUT" | grep -q "Retiring it" && pass "the words include the sentence's own end" || fail "the words include the sentence's own end" "Retiring it." "$OUT"
echo "$OUT" | grep -q "Darin, 2026-05-15" && fail "the attribution segment is cut from the words" "absent" "present" || pass "the attribution segment is cut from the words"
echo "$OUT" | grep -q "Darin, 2026-05-01" && fail "the attribution segment is cut from a same-line quote+attribution" "absent" "present" || pass "the attribution segment is cut from a same-line quote+attribution"
echo "$OUT" | grep -q '^ROW= \{9\}"This was good' && pass "the wrapped words indent to the 9-column exit-label field" || fail "the wrapped words indent to the 9-column exit-label field" 'ROW=<9 spaces>"This was good' "$OUT"
rm -rf "$ROOT"

echo "-- Test: exit words that follow the attribution on their own line are kept, not treated as attribution --"
fresh_root
write_archive_record "trailing-after-attribution" "2026-01-01" "deprecated" "alpha" '> "Decisions: keyed to the feature record" - Darin, 2026-08-30, dossier
> Copy paste, filed under the recording-boundary law.'
OUT=$(bash "$LIST" --room=archive | bash "$VIEW" archive)
echo "$OUT" | grep -q "recording-boundary law" && pass "the line after the attribution is kept in the words" || fail "the line after the attribution is kept in the words" "recording-boundary law" "$OUT"
echo "$OUT" | grep -q "Darin, 2026-08-30, dossier" && fail "the inline attribution is still cut from the words" "absent" "present" || pass "the inline attribution is still cut from the words"
rm -rf "$ROOT"

echo "-- Test: --only=declined shows only declined records, drops the label column, and titles the band --"
fresh_root
write_archive_record "declined-idea" "2026-01-01" "declined" "alpha" '> "No." - Darin, 2026-05-01, session'
write_archive_record "retired-idea" "2026-01-02" "deprecated" "alpha" '> "Yes, retire it." - Darin, 2026-05-15, session'
OUT_D=$(bash "$LIST" --room=archive | bash "$VIEW" archive --only=declined)
echo "$OUT_D" | grep -qF 'BAND=ARCHIVE · declined' && pass "--only=declined titles the band" || fail "--only=declined titles the band" "BAND=ARCHIVE · declined" "$OUT_D"
echo "$OUT_D" | grep -q "declined-idea" && pass "--only=declined includes the declined record" || fail "--only=declined includes the declined record" "declined-idea" "$OUT_D"
echo "$OUT_D" | grep -q "retired-idea" && fail "--only=declined excludes retired records" "absent" "present" || pass "--only=declined excludes retired records"
echo "$OUT_D" | grep -q '^ROW=declined ' && fail "--only=declined drops the label column" "no label column" "label column present" || pass "--only=declined drops the label column"
echo "$OUT_D" | grep -q '^ROW=declined-idea$' && pass "--only=declined's ROW is the bare slug" || fail "--only=declined's ROW is the bare slug" "ROW=declined-idea" "$OUT_D"

OUT_R=$(bash "$LIST" --room=archive | bash "$VIEW" archive --only=retired)
echo "$OUT_R" | grep -qF 'BAND=ARCHIVE · retired' && pass "--only=retired titles the band" || fail "--only=retired titles the band" "BAND=ARCHIVE · retired" "$OUT_R"
echo "$OUT_R" | grep -q "retired-idea" && pass "--only=retired includes the retired record" || fail "--only=retired includes the retired record" "retired-idea" "$OUT_R"
echo "$OUT_R" | grep -q "declined-idea" && fail "--only=retired excludes declined records" "absent" "present" || pass "--only=retired excludes declined records"
rm -rf "$ROOT"

echo "-- Test: view reads no project state --"
UNSET_TEST_DIR=$(mktemp -d)
FAR_RECORD_DIR=$(mktemp -d)
mkdir -p "$FAR_RECORD_DIR/archive"
cat > "$FAR_RECORD_DIR/archive/2026-01-01-far-record.md" <<'EOF'
---
type: decision
status: declined
created: 2026-01-01
source: session
tags: [alpha]
---
# Far record

## Context

## Options considered
## Decision
## Consequences
## Approval
> "No." - Darin, 2026-05-01, session
EOF
(
  unset CRAFT_PROJECT_ROOT
  cd "$UNSET_TEST_DIR"
  SHELF_OUT=$(printf '' | bash "$VIEW" shelf)
  echo "$SHELF_OUT" > "$UNSET_TEST_DIR/shelf-out.txt"
  BLOCK="FILE=$FAR_RECORD_DIR/archive/2026-01-01-far-record.md
ROOM=archive
SLUG=2026-01-01-far-record
DATE=2026-01-01
TITLE=Far record
STATUS=declined
TAGS=alpha
DISPOSITION=
STORIES=
"
  ARCHIVE_OUT=$(printf '%s\n' "$BLOCK" | bash "$VIEW" archive)
  echo "$ARCHIVE_OUT" > "$UNSET_TEST_DIR/archive-out.txt"
)
SHELF_RESULT=$(cat "$UNSET_TEST_DIR/shelf-out.txt")
echo "$SHELF_RESULT" | grep -qF "BAND=DECISION SHELF  ·  empty" && pass "shelf renders the empty view with CRAFT_PROJECT_ROOT unset" || fail "shelf renders the empty view with CRAFT_PROJECT_ROOT unset" "BAND=DECISION SHELF  ·  empty" "$SHELF_RESULT"
ARCHIVE_RESULT=$(cat "$UNSET_TEST_DIR/archive-out.txt")
echo "$ARCHIVE_RESULT" | grep -q "far-record" && pass "archive renders with CRAFT_PROJECT_ROOT unset, reading only the FILE= path handed to it" || fail "archive renders with CRAFT_PROJECT_ROOT unset" "far-record" "$ARCHIVE_RESULT"
rm -rf "$UNSET_TEST_DIR" "$FAR_RECORD_DIR"
echo ""
echo "=== The card: one shape, five faces ==="
echo ""

echo "-- Test: the approved card exhibit is reproduced from the view's data by the drawing rule (FIRST test) --"
CARD_EXHIBIT_FILE=$(mktemp)
cat > "$CARD_EXHIBIT_FILE" <<'@@CARD_EXHIBIT@@'
┌─ ACCEPTED · tags: decisions · source: session ──────────
│  2026-09-03-every-decision-carries-tags
│
│  Every decision carries tags
│
├─ CONTEXT
│    Reopen 2026-09-05: the store held 96 distinct tags across 36
│    records, 67 on one record only, chosen freehand per card. Only
│    the first tag is read by anything. Decisions need to be findable
│    - by tag, by text search, by date, by asking - and two competing
│    label systems (tags AND a feature: field) made every one of those
│    harder.
│
├─ OPTIONS CONSIDERED
│    - Keep both tags and the feature: field (two taxonomies to
│      maintain). Tags as the only sanctioned search method
│      (over-prescriptive). Tags on every record as one way to find
│      them, field retired.
│
├─ DECISION
│    Every decision carries exactly one tag: its group. It is shown on
│    the card, approved with it, and is the Shelf's header. A second
│    tag is added only when the filer can name the existing record it
│    would join. A new group starts with one record, and its tag is
│    the group's name from that moment. Finding records any other way
│    - grep, a script, a question - stays open and is not ruled here.
│    The feature: field is retired; its value is the tag: the 19
│    Wright records get requirement-to-cycle, the 4 TBD records get
│    guides.
│
├─ CONSEQUENCES
│    Reopen 2026-09-05: the 36 records on disk are trimmed to their
│    first tag by hand, since capture is not built. Capture, when
│    built, takes one tag and refuses a second unless it exists on
│    another record. The Shelf row loses its tag column; the Shelf
│    record's "date, slug, tags" row is read as "date, slug". One
│    label system, governed by the user's approvals, usable by any
│    search method now or later. The field-to-tag conversion runs with
│    the restructure.
│
├─ APPROVAL
│    > "approve. I do like having tags as being the motif for searching
│    > though. I wouldn't push back on that, I just didn't want it stated
│    > like it was the only way." - Darin, 2026-09-03, session (card 3 of
│    > 3, terminal ceremony)
│    > Reopen: "a" - Darin, 2026-09-05, session
│    > Reopen: "I'm okay with that, but if we're starting a new group, claude
│    > should propose a new tag so the user is aware of what's being
│    > created." - 2026-09-07, session
│
├─ YOUR MOVE
│    a) approve         moves to approved/ as shown
│    b) keep pending    saves your changes, stays on the Shelf
│    c) decline         moves to the archive with your words
│
│  a, b, c, or just tell me what to change.
└──────────────────────────────────────────────────────────
@@CARD_EXHIBIT@@
CARD_EXHIBIT=$(cat "$CARD_EXHIBIT_FILE")
rm -f "$CARD_EXHIBIT_FILE"
CARD_DRAWN=$(bash "$VIEW" card --variant=pending --file="$SCRIPT_DIR/../.craft/decisions/approved/2026-09-03-every-decision-carries-tags.md" | draw_rail)
[ "$(printf '%s' "$CARD_DRAWN" | normalize_bands)" = "$(printf '%s' "$CARD_EXHIBIT" | normalize_bands)" ] \
  && pass "the approved card exhibit is reproduced from the view's data by the drawing rule" \
  || fail "the approved card exhibit is reproduced from the view's data by the drawing rule" "$CARD_EXHIBIT" "$CARD_DRAWN"

echo "-- Test: every APPROVAL line is byte-identical to the file's '> ' lines --"
APPROVAL_DIFF=$(diff <(grep '^> ' "$SCRIPT_DIR/../.craft/decisions/approved/2026-09-03-every-decision-carries-tags.md") \
  <(bash "$VIEW" card --variant=pending --file="$SCRIPT_DIR/../.craft/decisions/approved/2026-09-03-every-decision-carries-tags.md" | sed -n 's/^ROW=//p' | grep '^> '))
[ -z "$APPROVAL_DIFF" ] && pass "every APPROVAL line is byte-identical to the file's '> ' lines" || fail "every APPROVAL line is byte-identical to the file's '> ' lines" "(no diff)" "$APPROVAL_DIFF"

echo "-- Test: a fresh card's text equals capture's file once the data transform is undone --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "The notebook holds a guides index" --tag=guides \
  --context="Wright offers proposals. This one needs a home." \
  --options="- Keep the index in the README.
- Give guides their own index file." \
  --decision="Guides get their own index file." \
  --consequences="One more file, easier to scan." \
  --dry-run)
REAL_PATH=$(bash "$CAPTURE" "The notebook holds a guides index" --tag=guides \
  --context="Wright offers proposals. This one needs a home." \
  --options="- Keep the index in the README.
- Give guides their own index file." \
  --decision="Guides get their own index file." \
  --consequences="One more file, easier to scan.")
CARD_OUT=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh)
DIFF=$(python3 -c "
import re, sys

with open('$REAL_PATH') as f:
    content = f.read()
m = re.match(r'^---\n.*?\n---\n?(.*)\$', content, re.DOTALL)
expected_text = m.group(1)

# The card's own data is BAND=/HEAD=/DIV=/ROW=/BLANK=/CLOSE= lines, not
# a frame - this undoes THAT transform (labels back to '## ', title
# back to '# ') and collapses whitespace runs to single spaces on BOTH
# sides before comparing, since line breaks may legitimately differ
# now that the card wraps at 65 instead of the file's own 55.
LABELS = {
    'CONTEXT': 'Context',
    'OPTIONS CONSIDERED': 'Options considered',
    'DECISION': 'Decision',
    'CONSEQUENCES': 'Consequences',
    'APPROVAL': 'Approval',
}
kv_lines = []
for raw in '''$CARD_OUT'''.split(chr(10)):
    if raw == '':
        continue
    key, _, val = raw.partition('=')
    kv_lines.append((key, val))

heads = [v for k, v in kv_lines if k == 'HEAD']
title = heads[1] if len(heads) > 1 else ''
out_lines = ['# ' + title]
started = False
for key, val in kv_lines:
    if key == 'DIV' and val == 'YOUR MOVE':
        break
    if not started:
        if key == 'DIV':
            started = True
        else:
            continue
    if key == 'DIV':
        out_lines.append('## ' + LABELS.get(val, val))
    elif key == 'ROW':
        out_lines.append(val)
    elif key == 'BLANK':
        out_lines.append('')
got_text = '\n'.join(out_lines)

norm = lambda s: re.sub(r'\s+', ' ', s).strip()
if norm(got_text) == norm(expected_text):
    print('MATCH')
else:
    print('MISMATCH')
    print('expected:', norm(expected_text))
    print('got:     ', norm(got_text))
")
echo "$DIFF" | grep -q '^MATCH$' && pass "the fresh card's text equals capture's file once the data transform is undone" || fail "the fresh card's text equals capture's file once the data transform is undone" "MATCH" "$DIFF"
rm -rf "$ROOT"

echo "-- Test: a record authored at 57 columns renders with no one-word orphan lines --"
fresh_root
LIVE_SHAPED_CONTEXT="The letters record rules that anything not a letter is
the user's words, and words redraw the card and never
file anything. So a sentence typed at a question card
would pick, redraw, and then wait for a letter that the
sentence had already said."
DRY_OUT=$(bash "$CAPTURE" "A live-shaped card" --tag=guides \
  --context="$LIVE_SHAPED_CONTEXT" --options="- A." --decision="A." --consequences="Fine." --dry-run)
ORPHAN_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh)
ORPHAN_CHECK=$(python3 -c "
import sys
# Only the CONTEXT section's ROW= lines matter here - the paragraph is
# many words long, so if reflow worked, no physical line inside it is
# a single word.
rows = []
in_context = False
for raw in '''$ORPHAN_CARD'''.split(chr(10)):
    if raw == '':
        continue
    key, _, val = raw.partition('=')
    if key == 'DIV' and val == 'CONTEXT':
        in_context = True
        continue
    if in_context:
        if key == 'BLANK':
            break
        if key == 'ROW':
            rows.append(val)
orphans = [l for l in rows if len(l.split()) == 1]
print('ORPHANS=' + str(len(orphans)))
")
echo "$ORPHAN_CHECK" | grep -q "ORPHANS=0" && pass "a record authored at 57 columns renders with no one-word orphan lines" || fail "a record authored at 57 columns renders with no one-word orphan lines" "ORPHANS=0" "$ORPHAN_CHECK"
rm -rf "$ROOT"

echo "-- Test: the dated slug sits on its own HEAD= line, whole and unbroken --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "Guides get an index of the right length" --tag=guides --created=2026-01-01 \
  --context="Context." --options="- A." --decision="A." --consequences="Fine." --dry-run)
REPORTED_SLUG=$(printf '%s\n' "$DRY_OUT" | head -1 | sed 's/^SLUG=//')
SLUG_LEN=${#REPORTED_SLUG}
[ "$SLUG_LEN" = "50" ] && pass "the fixture's dated slug is exactly 50 characters" || fail "the fixture's dated slug is exactly 50 characters" "50" "$SLUG_LEN"
FIRST_HEAD=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh | grep '^HEAD=' | sed -n '1p' | sed 's/^HEAD=//')
[ "$FIRST_HEAD" = "$REPORTED_SLUG" ] && pass "the 50-character slug sits whole on its own HEAD= line" || fail "the 50-character slug sits whole on its own HEAD= line" "$REPORTED_SLUG" "$FIRST_HEAD"
echo "$FIRST_HEAD" | grep -q ' ' && fail "the slug is not broken mid-word" "no internal space" "space present" || pass "the slug is not broken mid-word"
rm -rf "$ROOT"

echo "-- Test: section labels sit on their own DIV= line and body rows carry no extra indent (the rail supplies it) --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A labelled card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
FRESH_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh)
for LABEL in CONTEXT "OPTIONS CONSIDERED" DECISION CONSEQUENCES APPROVAL "YOUR MOVE"; do
  echo "$FRESH_CARD" | grep -qF "DIV=$LABEL" && pass "the $LABEL label sits on its own DIV= line" || fail "the $LABEL label sits on its own DIV= line" "DIV=$LABEL" "$FRESH_CARD"
done
echo "$FRESH_CARD" | grep -q '^ROW=Context\.$' && pass "the Context body row carries no extra indent" || fail "the Context body row carries no extra indent" "ROW=Context." "$FRESH_CARD"
echo "$FRESH_CARD" | grep -q '^ROW=- A\.$' && pass "an option body row keeps its dash marker" || fail "an option body row keeps its dash marker" "ROW=- A." "$FRESH_CARD"

mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-labelled-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Labelled law

## Context
Context.

## Options considered
- A.

## Decision
A.

## Consequences
Fine.

## Approval
> "approve" - 2026-01-01, session
EOF
RETIRE_CARD=$(bash "$VIEW" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-labelled-law.md")
echo "$RETIRE_CARD" | grep -qF 'DIV=APPROVAL' && pass "retire's APPROVAL label sits on its own DIV= line" || fail "retire's APPROVAL label sits on its own DIV= line" "DIV=APPROVAL" "$RETIRE_CARD"
echo "$RETIRE_CARD" | grep -q '^ROW=> "approve"' && pass "retire's approval quote is verbatim, with the '> ' prefix intact" || fail "retire's approval quote is verbatim, with the '> ' prefix intact" 'ROW=> "approve"' "$RETIRE_CARD"

PENDING_CARD_STATE=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --state=question --proposed=a)
echo "$PENDING_CARD_STATE" | grep -qF 'DIV=YOUR OPTIONS' && pass "the question state's YOUR OPTIONS label sits on its own DIV= line" || fail "the question state's YOUR OPTIONS label sits on its own DIV= line" "DIV=YOUR OPTIONS" "$PENDING_CARD_STATE"
echo "$PENDING_CARD_STATE" | grep -q '^ROW=(a) Proposed: A\.$' && pass "a lettered option row carries no extra indent" || fail "a lettered option row carries no extra indent" "ROW=(a) Proposed: A." "$PENDING_CARD_STATE"
rm -rf "$ROOT"

echo "-- Test: on a reopen card a removed bullet reads '- - text' and an unchanged bullet reads '  - text' --"
fresh_root
mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-bullet-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Bullet law

## Context
Context.

## Options considered
- Keep it as is.
- Change it.

## Decision
Keep it as is.

## Consequences
Fine.

## Approval
> "approve" - 2026-01-01, session
EOF
BULLET_DIFF=$(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-bullet-law.md" \
  --context="Context." --options="- Keep it as is.
- A brand new option." --decision="Keep it as is." --consequences="Fine.")
echo "$BULLET_DIFF" | grep -q '^ROW=- - Change it\.$' && pass "the removed bullet's marker and dash never share a column" || fail "the removed bullet's marker and dash never share a column" "ROW=- - Change it." "$BULLET_DIFF"
echo "$BULLET_DIFF" | grep -q '^ROW=+ - A brand new option\.$' && pass "the added bullet's marker and dash never share a column" || fail "the added bullet's marker and dash never share a column" "ROW=+ - A brand new option." "$BULLET_DIFF"
echo "$BULLET_DIFF" | grep -q '^ROW=  - Keep it as is\.$' && pass "the unchanged bullet keeps the blank two-space indent before its own dash" || fail "the unchanged bullet keeps the blank two-space indent before its own dash" "ROW=  - Keep it as is." "$BULLET_DIFF"
echo "$BULLET_DIFF" | grep -B1 -- '^ROW=- - Change it\.$' | head -1 | grep -qx 'MARK=-' && pass "the removed bullet's ROW= is preceded by MARK=-" || fail "the removed bullet's ROW= is preceded by MARK=-" "MARK=-" "$BULLET_DIFF"
echo "$BULLET_DIFF" | grep -B1 -- '^ROW=+ - A brand new option\.$' | head -1 | grep -qx 'MARK=+' && pass "the added bullet's ROW= is preceded by MARK=+" || fail "the added bullet's ROW= is preceded by MARK=+" "MARK=+" "$BULLET_DIFF"
echo "$BULLET_DIFF" | grep -B1 -- '^ROW=  - Keep it as is\.$' | head -1 | grep -qx 'MARK=' && pass "the unchanged bullet's ROW= is preceded by an unmarked MARK=" || fail "the unchanged bullet's ROW= is preceded by an unmarked MARK=" "MARK=" "$BULLET_DIFF"
rm -rf "$ROOT"

echo "-- Test: the header shows the collision-suffixed slug the file will actually get --"
fresh_root
bash "$CAPTURE" "Collision title" --tag=guides --quote="a" \
  --context="Some context." --options="- One." --decision="One." --consequences="Fine." > /dev/null
DRY_OUT=$(bash "$CAPTURE" "Collision title" --tag=guides \
  --context="Some context." --options="- One." --decision="One." --consequences="Fine." --dry-run)
CARD_HEADER_SLUG=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh | grep '^HEAD=' | sed -n '1p' | sed 's/^HEAD=//')
REPORTED_SLUG=$(printf '%s\n' "$DRY_OUT" | head -1 | sed 's/^SLUG=//')
echo "$REPORTED_SLUG" | grep -q -- '-2$' && pass "the dry run itself reports the collision-suffixed slug" || fail "the dry run itself reports the collision-suffixed slug" "*-2" "$REPORTED_SLUG"
[ "$CARD_HEADER_SLUG" = "$REPORTED_SLUG" ] && pass "the card's first HEAD= line carries the collision-suffixed slug" || fail "the card's first HEAD= line carries the collision-suffixed slug" "$REPORTED_SLUG" "$CARD_HEADER_SLUG"
rm -rf "$ROOT"

echo "-- Test: no card face, including reopen, emits a box-drawing character or an ANSI escape --"
fresh_root
mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" <<EOF
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Wide law

## Context
$(printf 'x%.0s' $(seq 1 642))

## Options considered
- Keep it as is.

## Decision
Keep it as is.

## Consequences
Nothing changes.

## Approval
> "approve" - 2026-01-01, session
EOF
FRESH_DRY=$(bash "$CAPTURE" "A fresh card" --tag=guides \
  --context="Fresh context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
BOX_BAD=0
BOX_BAD=$((BOX_BAD + $(printf '%s\n' "$FRESH_DRY" | bash "$VIEW" card --variant=fresh | no_box_chars)))
BOX_BAD=$((BOX_BAD + $(printf '%s\n' "$FRESH_DRY" | bash "$VIEW" card --variant=fresh --state=question --proposed=a | no_box_chars)))
BOX_BAD=$((BOX_BAD + $(bash "$VIEW" card --variant=pending --file="$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" | no_box_chars)))
BOX_BAD=$((BOX_BAD + $(bash "$VIEW" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" --claimed-by="story-a:ready" | no_box_chars)))
BOX_BAD=$((BOX_BAD + $(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" --context="New context." --options="- Keep it as is." --decision="Change it." --consequences="Nothing changes." --claimed-by="story-a:ready" | no_box_chars)))
[ "$BOX_BAD" -eq 0 ] && pass "the fresh, pending, retire and reopen faces emit no box-drawing character" || fail "the fresh, pending, retire and reopen faces emit no box-drawing character" "0" "$BOX_BAD"
REOPEN_ESCAPE=$(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" \
  --context="New context." --options="- Keep it as is." --decision="Change it." --consequences="Nothing changes." | python3 -c "import sys; print('yes' if chr(27) in sys.stdin.read() else 'no')")
[ "$REOPEN_ESCAPE" = "no" ] && pass "the reopen face emits no ANSI escape - colour is the command file's job now" || fail "the reopen face emits no ANSI escape - colour is the command file's job now" "no" "$REOPEN_ESCAPE"
rm -rf "$ROOT"

echo "-- Test: the question and decision states render from ONE input --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A forked card" --tag=guides \
  --context="Two ways to go." --options="- Option one text.
- Option two text." --decision="Option one text." --consequences="Fine either way." --dry-run)
QUESTION=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --state=question --proposed=a)
echo "$QUESTION" | grep -q "YOUR OPTIONS" && pass "the question state relabels the options header" || fail "the question state relabels the options header" "YOUR OPTIONS" "$QUESTION"
echo "$QUESTION" | grep -q '(a) Proposed: Option one text.' && pass "the question state marks the proposed option" || fail "the question state marks the proposed option" "(a) Proposed:" "$QUESTION"
echo "$QUESTION" | grep -q "DECISION if (a)" && pass "the question state labels DECISION if (<letter>)" || fail "the question state labels DECISION if (<letter>)" "DECISION if (a)" "$QUESTION"
echo "$QUESTION" | grep -q "CONSEQUENCES if (a)" && pass "the question state labels CONSEQUENCES if (<letter>)" || fail "the question state labels CONSEQUENCES if (<letter>)" "CONSEQUENCES if (a)" "$QUESTION"
echo "$QUESTION" | grep -q "a) pick" && pass "the question state offers picking letters" || fail "the question state offers picking letters" "a) pick" "$QUESTION"
rm -rf "$ROOT"

echo "-- Test: the decision state is the default --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A default card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
DEFAULT_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh)
echo "$DEFAULT_CARD" | grep -q "a) approve" && echo "$DEFAULT_CARD" | grep -q "b) keep pending" && echo "$DEFAULT_CARD" | grep -q "c) decline" && pass "with no --state, a fresh card arrives in the decision state (a/b/c)" || fail "with no --state, a fresh card arrives in the decision state (a/b/c)" "a) approve / b) keep pending / c) decline" "$DEFAULT_CARD"
rm -rf "$ROOT"

echo "-- Test: --proposed= is required in the question state and refused in the decision state --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --state=question > /dev/null 2>&1 && fail "--state=question with no --proposed= is refused" "exit 1" "exit 0" || pass "--state=question with no --proposed= is refused"
printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --state=decision --proposed=a > /dev/null 2>&1 && fail "--proposed= in the decision state is refused" "exit 1" "exit 0" || pass "--proposed= in the decision state is refused"
rm -rf "$ROOT"

echo "-- Test: each face offers exactly its ruled letters, effects and closing line --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)

FRESH_DECISION=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh)
echo "$FRESH_DECISION" | grep -q "a) approve" || fail "fresh decision offers a) approve" "a) approve" "$FRESH_DECISION"
echo "$FRESH_DECISION" | grep -q "b) keep pending" || fail "fresh decision offers b) keep pending" "b) keep pending" "$FRESH_DECISION"
echo "$FRESH_DECISION" | grep -q "c) decline" || fail "fresh decision offers c) decline" "c) decline" "$FRESH_DECISION"
echo "$FRESH_DECISION" | grep -q "a, b, c, or just tell me what to change." && pass "fresh decision's closing line names a, b, c" || fail "fresh decision's closing line names a, b, c" "a, b, c, or just tell me what to change." "$FRESH_DECISION"

FRESH_QUESTION=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --state=question --proposed=a)
echo "$FRESH_QUESTION" | grep -q "c) keep pending" && pass "fresh question offers one letter per option then keep pending" || fail "fresh question offers one letter per option then keep pending" "c) keep pending" "$FRESH_QUESTION"
echo "$FRESH_QUESTION" | grep -q "a, b, c, or just tell me what to change." && pass "fresh question's closing line names a, b, c" || fail "fresh question's closing line names a, b, c" "a, b, c, or just tell me what to change." "$FRESH_QUESTION"

mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-letters-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Letters law

## Context
Context.

## Options considered
- A.

## Decision
A.

## Consequences
Fine.

## Approval
> "approve" - 2026-01-01, session
EOF
REOPEN=$(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-letters-law.md" \
  --context="Context." --options="- A." --decision="B." --consequences="Fine.")
echo "$REOPEN" | grep -q "a) approve" && echo "$REOPEN" | grep -q "the law changes to this" && pass "reopen offers a) approve, effect 'the law changes to this'" || fail "reopen offers a) approve, effect 'the law changes to this'" "a) approve ... the law changes to this" "$REOPEN"
echo "$REOPEN" | grep -q "a, or just tell me what to change." && pass "reopen's closing line names only a" || fail "reopen's closing line names only a" "a, or just tell me what to change." "$REOPEN"

RETIRE=$(bash "$VIEW" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-letters-law.md")
echo "$RETIRE" | grep -q "a) retire" && echo "$RETIRE" | grep -q "no longer applies" && echo "$RETIRE" | grep -q "archive" && echo "$RETIRE" | grep -q "your words" && pass "retire offers a) retire, effect 'no longer applies...'" || fail "retire offers a) retire, effect 'no longer applies...'" "a) retire ... no longer applies ... your words" "$RETIRE"
echo "$RETIRE" | grep -q "a, or just tell me what to change." && pass "retire's closing line names only a" || fail "retire's closing line names only a" "a, or just tell me what to change." "$RETIRE"
rm -rf "$ROOT"

echo "-- Test: a pending card reads its state from the file's own Options shape --"
fresh_root
write_options_record "root" "lettered-one" "2026-01-01" "Lettered one" "pending" "guides" \
'(a) Keep it.
(b) Proposed: Change it.'
write_options_record "root" "dashed-one" "2026-01-02" "Dashed one" "pending" "guides" \
'- Keep it.
- Change it.'
write_options_record "root" "empty-one" "2026-01-03" "Empty one" "pending" "guides" ""

LETTERED_OUT=$(bash "$VIEW" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-01-lettered-one.md")
echo "$LETTERED_OUT" | grep -q "YOUR OPTIONS" && pass "a pending card with lettered options draws as a question" || fail "a pending card with lettered options draws as a question" "YOUR OPTIONS" "$LETTERED_OUT"
echo "$LETTERED_OUT" | grep -q '(b) Proposed: Change it.' && pass "the Proposed option is marked from the file's own marker" || fail "the Proposed option is marked from the file's own marker" "(b) Proposed:" "$LETTERED_OUT"

DASHED_OUT=$(bash "$VIEW" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-02-dashed-one.md")
echo "$DASHED_OUT" | grep -q "OPTIONS CONSIDERED" && pass "a pending card with dashed options draws as a decision" || fail "a pending card with dashed options draws as a decision" "OPTIONS CONSIDERED" "$DASHED_OUT"
echo "$DASHED_OUT" | grep -q "a) approve" && pass "the dashed pending card offers approve/keep pending/decline" || fail "the dashed pending card offers approve/keep pending/decline" "a) approve" "$DASHED_OUT"

EMPTY_OUT=$(bash "$VIEW" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-03-empty-one.md")
echo "$EMPTY_OUT" | grep -q "OPTIONS CONSIDERED" && pass "a pending card with no options draws as a decision" || fail "a pending card with no options draws as a decision" "OPTIONS CONSIDERED" "$EMPTY_OUT"

FORCED_DECISION=$(bash "$VIEW" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-01-lettered-one.md" --state=decision)
echo "$FORCED_DECISION" | grep -q "OPTIONS CONSIDERED" && pass "an explicit --state=decision overrides the file's lettered shape" || fail "an explicit --state=decision overrides the file's lettered shape" "OPTIONS CONSIDERED" "$FORCED_DECISION"
rm -rf "$ROOT"

echo "-- Test: a single lettered option still draws as a question --"
fresh_root
write_options_record "root" "single-lettered" "2026-01-01" "Single lettered" "pending" "guides" \
'(a) Proposed: The only option.'
SINGLE_OUT=$(bash "$VIEW" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-01-single-lettered.md")
echo "$SINGLE_OUT" | grep -q "YOUR OPTIONS" && pass "a single lettered option still draws as a question" || fail "a single lettered option still draws as a question" "YOUR OPTIONS" "$SINGLE_OUT"
rm -rf "$ROOT"

echo "-- Test: the decision state never prints a lettered option and the question state never prints a dashed one --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
DEC=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --state=decision)
QUE=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --state=question --proposed=a)
echo "$DEC" | grep -qE '\(a\)|\(b\)' && fail "the decision state never prints a lettered option" "no (a)/(b)" "$DEC" || pass "the decision state never prints a lettered option"
echo "$QUE" | grep -q '^ROW=- ' && fail "the question state never prints a dashed option" "no dash lines" "$QUE" || pass "the question state never prints a dashed option"
rm -rf "$ROOT"

echo "-- Test: a wide body line reflows across more than one ROW line, never past the card's 65-column wrap width --"
fresh_root
LONG_TEXT=$(printf 'word%.0s ' $(seq 1 120))
DRY_OUT=$(bash "$CAPTURE" "A wide card" --tag=guides \
  --context="$LONG_TEXT" --options="- A." --decision="A." --consequences="Fine." --dry-run)
WIDE_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh)
echo "$WIDE_CARD" | grep -q "word word word" && pass "a wide body line is present, wrapped" || fail "a wide body line is present, wrapped" "word word word" "$WIDE_CARD"
CONTEXT_ROW_COUNT=$(printf '%s\n' "$WIDE_CARD" | awk '/^DIV=CONTEXT$/{f=1; next} f && /^BLANK=$/{exit} f && /^ROW=/{c++} END{print c+0}')
[ "$CONTEXT_ROW_COUNT" -gt 1 ] && pass "the 120-word context reflows across more than one ROW line" || fail "the 120-word context reflows across more than one ROW line" ">1" "$CONTEXT_ROW_COUNT"
LONGEST=$(printf '%s\n' "$WIDE_CARD" | grep '^ROW=' | sed 's/^ROW=//' | awk '{ print length }' | sort -rn | head -1)
[ "$LONGEST" -le 65 ] && pass "no ROW line exceeds the card's 65-column wrap width" || fail "no ROW line exceeds the card's 65-column wrap width" "<=65" "$LONGEST"
rm -rf "$ROOT"

echo "-- Test: reopen diff rows never exceed the card's 65-column wrap width either - the diff marker comes off the width first --"
fresh_root
write_record "approved" "reopen-width" "2026-01-01" "Reopen width" "accepted" "alpha"
REOPEN_FILE="$ROOT/.craft/decisions/approved/2026-01-01-reopen-width.md"
LONG_TEXT=$(printf 'word%.0s ' $(seq 1 120))
REOPEN_CARD=$(bash "$VIEW" card --variant=reopen --file="$REOPEN_FILE" \
  --context="$LONG_TEXT" --options="- $LONG_TEXT" --decision="Changed." --consequences="Changed.")
echo "$REOPEN_CARD" | grep -q '^MARK=+' && pass "the reopen diff carries added rows to measure" || fail "the reopen diff carries added rows to measure" "MARK=+" "$REOPEN_CARD"
# APPROVAL rows are the file's own "> " lines, verbatim by ruling, and may
# be any width - measure every body section except that one.
LONGEST=$(printf '%s\n' "$REOPEN_CARD" | awk -F= '/^DIV=/{sec=$2} /^ROW=/ && sec!="APPROVAL"{print length(substr($0,5))}' | sort -rn | head -1)
[ "$LONGEST" -le 65 ] && pass "no reopen body ROW line exceeds 65 columns, plain paragraph or bullet (approval quotes excluded)" || fail "no reopen body ROW line exceeds 65 columns (approval quotes excluded)" "<=65" "$LONGEST"
rm -rf "$ROOT"

echo "-- Test: the CLAIMED BY STORIES / SHIPPED BY STORY band --"
fresh_root
mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Claimed law

## Context
Context.

## Options considered
- A.

## Decision
A.

## Consequences
Fine.

## Approval
> "approve" - 2026-01-01, session
EOF

CLAIMED_RETIRE=$(bash "$VIEW" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" \
  --claimed-by="track-alpha:planning" --claimed-by="track-beta-two:ready")
echo "$CLAIMED_RETIRE" | grep -qF 'DIV=CLAIMED BY STORIES' && pass "the retire card prints a CLAIMED BY STORIES divider" || fail "the retire card prints a CLAIMED BY STORIES divider" "DIV=CLAIMED BY STORIES" "$CLAIMED_RETIRE"
PLANNING_ROW=$(echo "$CLAIMED_RETIRE" | grep '^ROW=track-alpha')
READY_ROW=$(echo "$CLAIMED_RETIRE" | grep '^ROW=track-beta-two')
PLANNING_START=$(python3 -c "print('$PLANNING_ROW'.find('planning'))")
READY_START=$(python3 -c "print('$READY_ROW'.find('ready'))")
[ "$PLANNING_START" = "$READY_START" ] && pass "each story's status starts in the same left-anchored fixed column" || fail "each story's status starts in the same left-anchored fixed column" "$PLANNING_START" "$READY_START"

CLAIMED_REOPEN=$(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" \
  --context="Context." --options="- A." --decision="A." --consequences="Fine." --claimed-by="story-planning:planning")
echo "$CLAIMED_REOPEN" | grep -qF 'DIV=CLAIMED BY STORIES' && pass "the reopen card also prints a CLAIMED BY STORIES band" || fail "the reopen card also prints a CLAIMED BY STORIES band" "DIV=CLAIMED BY STORIES" "$CLAIMED_REOPEN"

SHIPPED=$(bash "$VIEW" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" --shipped-by="ship-story")
echo "$SHIPPED" | grep -qF 'DIV=SHIPPED BY STORY' && pass "SHIPPED BY STORY divider prints" || fail "SHIPPED BY STORY divider prints" "DIV=SHIPPED BY STORY" "$SHIPPED"
echo "$SHIPPED" | grep -q '^ROW=ship-story$' && pass "the shipping story prints with no status" || fail "the shipping story prints with no status" "ROW=ship-story" "$SHIPPED"

NEITHER=$(bash "$VIEW" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md")
echo "$NEITHER" | grep -q "CLAIMED BY STORIES\|SHIPPED BY STORY" && fail "the band is omitted with neither flag" "no band" "$NEITHER" || pass "the band is omitted with neither flag"

bash "$VIEW" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" \
  --claimed-by="a:planning" --shipped-by="b" > /dev/null 2>&1 && fail "the two flags together are refused" "exit 1" "exit 0" || pass "the two flags together are refused"
rm -rf "$ROOT"

echo "-- Test: --new-group=<tag> marks that tag NEW GROUP in the header --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A new group card" --tag=gameroom \
  --context="Context." --options="- A." --decision="A." --consequences="Fine." --dry-run)
MARKED=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh --new-group=gameroom)
UNMARKED=$(printf '%s\n' "$DRY_OUT" | bash "$VIEW" card --variant=fresh)
echo "$MARKED" | grep -q "gameroom (NEW GROUP)" && pass "--new-group= marks the tag NEW GROUP" || fail "--new-group= marks the tag NEW GROUP" "gameroom (NEW GROUP)" "$MARKED"
echo "$UNMARKED" | grep -q "NEW GROUP" && fail "without the flag the tag renders plain" "no NEW GROUP" "$UNMARKED" || pass "without the flag the tag renders plain"
rm -rf "$ROOT"

echo "-- Test: a reopen card marks removed/added rows and leaves unchanged rows unmarked --"
fresh_root
mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-diff-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Diff law

## Context
Unchanged context line.

## Options considered
- Keep it as is.

## Decision
Keep it as is.

## Consequences
Nothing changes.

## Approval
> "approve" - 2026-01-01, session
EOF
DIFF_OUT=$(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-diff-law.md" \
  --context="Unchanged context line." --options="- Keep it as is." --decision="Change it now." --consequences="Nothing changes.")
echo "$DIFF_OUT" | grep -q '^ROW=- Keep it as is\.$' && pass "the removed decision row's ROW= carries a - marker" || fail "the removed decision row's ROW= carries a - marker" "ROW=- Keep it as is." "$DIFF_OUT"
echo "$DIFF_OUT" | grep -q '^ROW=+ Change it now\.$' && pass "the added decision row's ROW= carries a + marker" || fail "the added decision row's ROW= carries a + marker" "ROW=+ Change it now." "$DIFF_OUT"
echo "$DIFF_OUT" | grep -q '^ROW=  Unchanged context line\.$' && pass "the unchanged context row keeps the blank two-space indent" || fail "the unchanged context row keeps the blank two-space indent" "ROW=  Unchanged context line." "$DIFF_OUT"
echo "$DIFF_OUT" | grep -B1 -- '^ROW=- Keep it as is\.$' | head -1 | grep -qx 'MARK=-' && pass "the removed row's MARK= is -" || fail "the removed row's MARK= is -" "MARK=-" "$DIFF_OUT"
echo "$DIFF_OUT" | grep -B1 -- '^ROW=+ Change it now\.$' | head -1 | grep -qx 'MARK=+' && pass "the added row's MARK= is +" || fail "the added row's MARK= is +" "MARK=+" "$DIFF_OUT"
echo "$DIFF_OUT" | grep -B1 -- '^ROW=  Unchanged context line\.$' | head -1 | grep -qx 'MARK=' && pass "the unchanged row's MARK= is unmarked" || fail "the unchanged row's MARK= is unmarked" "MARK=" "$DIFF_OUT"

echo "-- Test: the title diff marks at the gutter (HEAD=), not the body indent (ROW=) --"
TITLE_DIFF=$(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-diff-law.md" \
  --title="New title" --context="Unchanged context line." --options="- Keep it as is." --decision="Keep it as is." --consequences="Nothing changes.")
echo "$TITLE_DIFF" | grep -q '^HEAD=- Diff law$' && pass "the removed title line is a HEAD=, not a ROW=" || fail "the removed title line is a HEAD=, not a ROW=" "HEAD=- Diff law" "$TITLE_DIFF"
echo "$TITLE_DIFF" | grep -q '^HEAD=+ New title$' && pass "the added title line is a HEAD=, not a ROW=" || fail "the added title line is a HEAD=, not a ROW=" "HEAD=+ New title" "$TITLE_DIFF"
echo "$TITLE_DIFF" | grep -qx 'ROW=- Diff law' && fail "the title diff never lands in the body indent" "absent" "ROW=- Diff law present" || pass "the title diff never lands in the body indent"
echo "$TITLE_DIFF" | grep -B1 -- '^HEAD=- Diff law$' | head -1 | grep -qx 'MARK=-' && pass "the title's removed HEAD= is preceded by MARK=-" || fail "the title's removed HEAD= is preceded by MARK=-" "MARK=-" "$TITLE_DIFF"
rm -rf "$ROOT"

echo "-- Test: a one-word edit marks one paragraph, not every wrapped line --"
fresh_root
mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-paragraph-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Paragraph law

## Context
First paragraph stays exactly the same and does not change in this reopen at all, no matter what.

Second paragraph will change by exactly one word from apple to banana in this edit.

Third paragraph also stays exactly the same and is not touched by this reopen at all, no matter what.

## Options considered
- Keep it as is.

## Decision
Keep it as is.

## Consequences
Nothing changes.

## Approval
> "approve" - 2026-01-01, session
EOF
PARA_DIFF=$(bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-paragraph-law.md" \
  --context="First paragraph stays exactly the same and does not change in this reopen at all, no matter what.

Second paragraph will change by exactly one word from banana to banana in this edit.

Third paragraph also stays exactly the same and is not touched by this reopen at all, no matter what." \
  --options="- Keep it as is." --decision="Keep it as is." --consequences="Nothing changes.")
CONTEXT_BLOCK=$(printf '%s\n' "$PARA_DIFF" | awk '/^DIV=CONTEXT$/{f=1; next} f && /^BLANK=$/{exit} f{print}')
FIRST_MARK=$(printf '%s\n' "$CONTEXT_BLOCK" | grep -B1 "First paragraph" | grep '^MARK=' | sort -u)
THIRD_MARK=$(printf '%s\n' "$CONTEXT_BLOCK" | grep -B1 "Third paragraph" | grep '^MARK=' | sort -u)
[ "$FIRST_MARK" = "MARK=" ] && pass "the untouched first paragraph's rows are unmarked" || fail "the untouched first paragraph's rows are unmarked" "MARK=" "$FIRST_MARK"
[ "$THIRD_MARK" = "MARK=" ] && pass "the untouched third paragraph's rows are unmarked" || fail "the untouched third paragraph's rows are unmarked" "MARK=" "$THIRD_MARK"
CHANGED_MARKS=$(printf '%s\n' "$CONTEXT_BLOCK" | grep -B1 -E "apple|banana" | grep '^MARK=' | sort -u | tr '\n' ' ')
echo "$CHANGED_MARKS" | grep -q "MARK=-" && echo "$CHANGED_MARKS" | grep -q "MARK=+" && pass "the one-word-changed second paragraph marks removed and added rows only - the surrounding paragraphs stay untouched" || fail "the one-word-changed second paragraph marks removed and added rows only - the surrounding paragraphs stay untouched" "MARK=- and MARK=+" "$CHANGED_MARKS"
rm -rf "$ROOT"

echo "-- Test: no reopen output holds an ANSI escape or a box-drawing character, and the script no longer reads CRAFT_DECISIONS_FORCE_COLOR --"
fresh_root
mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-diff-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Diff law

## Context
Unchanged context line.

## Options considered
- Keep it as is.

## Decision
Keep it as is.

## Consequences
Nothing changes.

## Approval
> "approve" - 2026-01-01, session
EOF
grep -q "CRAFT_DECISIONS_FORCE_COLOR" "$VIEW" && fail "the script no longer reads CRAFT_DECISIONS_FORCE_COLOR" "absent" "present" || pass "the script no longer reads CRAFT_DECISIONS_FORCE_COLOR"
FORCE_COLOR_OUT=$(CRAFT_DECISIONS_FORCE_COLOR=1 bash "$VIEW" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-diff-law.md" \
  --context="Unchanged context line." --options="- Keep it as is." --decision="Change it now." --consequences="Nothing changes.")
HAS_ESCAPE=$(printf '%s' "$FORCE_COLOR_OUT" | python3 -c "import sys; print('yes' if chr(27) in sys.stdin.read() else 'no')")
[ "$HAS_ESCAPE" = "no" ] && pass "no ANSI escape even with CRAFT_DECISIONS_FORCE_COLOR=1 set - colour is the command file's job now" || fail "no ANSI escape even with CRAFT_DECISIONS_FORCE_COLOR=1 set - colour is the command file's job now" "no" "$HAS_ESCAPE"
FORCE_COLOR_BOX=$(printf '%s\n' "$FORCE_COLOR_OUT" | no_box_chars)
[ "$FORCE_COLOR_BOX" -eq 0 ] && pass "no box-drawing character even with CRAFT_DECISIONS_FORCE_COLOR=1 set" || fail "no box-drawing character even with CRAFT_DECISIONS_FORCE_COLOR=1 set" "0" "$FORCE_COLOR_BOX"
rm -rf "$ROOT"

echo "-- Test: card reads no project state --"
UNSET_CARD_DIR=$(mktemp -d)
FAR_FILE_DIR=$(mktemp -d)
mkdir -p "$FAR_FILE_DIR"
cat > "$FAR_FILE_DIR/2026-01-01-far-card.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Far card

## Context
Context.

## Options considered
- A.

## Decision
A.

## Consequences
Fine.

## Approval
> "approve" - 2026-01-01, session
EOF
(
  unset CRAFT_PROJECT_ROOT
  cd "$UNSET_CARD_DIR"
  bash "$VIEW" card --variant=retire --file="$FAR_FILE_DIR/2026-01-01-far-card.md" > "$UNSET_CARD_DIR/card-out.txt"
)
CARD_UNSET_RESULT=$(cat "$UNSET_CARD_DIR/card-out.txt")
echo "$CARD_UNSET_RESULT" | grep -q "Far card" && pass "card renders with CRAFT_PROJECT_ROOT unset, reading only the --file= path handed to it" || fail "card renders with CRAFT_PROJECT_ROOT unset" "Far card" "$CARD_UNSET_RESULT"
rm -rf "$UNSET_CARD_DIR" "$FAR_FILE_DIR"

echo "-- Test: no view or face emits a box-drawing character (the consolidated sweep) --"
fresh_root
build_shape_fixture
write_archive_record "declined-idea" "2026-01-01" "declined" "alpha" '> "No." - Darin, 2026-05-01, session'
mkdir -p "$ROOT/.craft/decisions/approved"
cat > "$ROOT/.craft/decisions/approved/2026-01-01-sweep-law.md" <<'EOF'
---
type: decision
status: accepted
created: 2026-01-01
source: session
tags: [guides]
---
# Sweep law

## Context
Context.

## Options considered
- A.

## Decision
A.

## Consequences
Fine.

## Approval
> "approve" - 2026-01-01, session
EOF
SWEEP_DRY=$(bash "$CAPTURE" "A sweep card" --tag=guides \
  --context="Sweep context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
SWEEP_FILE="$ROOT/.craft/decisions/approved/2026-01-01-sweep-law.md"
SWEEP_BAD=0
SWEEP_BAD=$((SWEEP_BAD + $(bash "$LIST" | bash "$VIEW" shelf | no_box_chars)))
SWEEP_BAD=$((SWEEP_BAD + $(bash "$LIST" --tag=wright-journal | bash "$VIEW" group | no_box_chars)))
SWEEP_BAD=$((SWEEP_BAD + $(bash "$LIST" --room=archive | bash "$VIEW" archive | no_box_chars)))
SWEEP_BAD=$((SWEEP_BAD + $(bash "$LIST" --tag=guides | bash "$VIEW" match --words=guides | no_box_chars)))
SWEEP_BAD=$((SWEEP_BAD + $(printf '%s\n' "$SWEEP_DRY" | bash "$VIEW" card --variant=fresh | no_box_chars)))
SWEEP_BAD=$((SWEEP_BAD + $(bash "$VIEW" card --variant=pending --file="$SWEEP_FILE" | no_box_chars)))
SWEEP_BAD=$((SWEEP_BAD + $(bash "$VIEW" card --variant=retire --file="$SWEEP_FILE" --claimed-by="story-a:ready" | no_box_chars)))
SWEEP_BAD=$((SWEEP_BAD + $(bash "$VIEW" card --variant=reopen --file="$SWEEP_FILE" --context="New context." --options="- A." --decision="Change it." --consequences="Fine." | no_box_chars)))
rm -rf "$ROOT"
# The empty view holds no non-archive record on stdin.
fresh_root
SWEEP_BAD=$((SWEEP_BAD + $(bash "$LIST" | bash "$VIEW" shelf | no_box_chars)))
rm -rf "$ROOT"
[ "$SWEEP_BAD" -eq 0 ] && pass "no view or face - shelf, group, match, empty, archive, card fresh/pending/retire/reopen - emits a box-drawing character" \
  || fail "no view or face emits a box-drawing character" "0" "$SWEEP_BAD"

echo ""
echo "=== Summary: $PASS_COUNT/$TOTAL passed ==="
[ "$FAIL_COUNT" -eq 0 ]
