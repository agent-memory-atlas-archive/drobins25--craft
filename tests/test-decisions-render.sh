#!/bin/bash
# test-decisions-render.sh — Behavior tests for decisions-render.sh
# Usage: bash tests/test-decisions-render.sh
#
# Chunk 2 covers the `shelf` and `archive` subcommands: the two byte-exact
# frames (the DECISION SHELF and the empty Shelf, carried verbatim from
# story 4-decisions-skill.md's Reference rendering) and the words-open-
# the-archive frame. Chunk 3 appends the `card` section.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/../hooks/scripts/decisions-list.sh"
RENDER="$SCRIPT_DIR/../hooks/scripts/decisions-render.sh"
CAPTURE="$SCRIPT_DIR/../hooks/scripts/decisions-capture.sh"

PASS_COUNT=0; FAIL_COUNT=0; TOTAL=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    Expected: $2"; [ -n "${3:-}" ] && echo "    Got:      $3"; }

fresh_root() {
  ROOT=$(mktemp -d)
  export CRAFT_PROJECT_ROOT="$ROOT"
}

# all_lines_63 - reads stdin, prints the count of lines whose CHARACTER
# length (unicode codepoints, escape sequences stripped) is not 63.
all_lines_63() {
  python3 -c "
import sys, re
esc = re.compile(r'\x1b\[[0-9;]*m')
bad = 0
for line in sys.stdin.read().split(chr(10)):
    if line == '':
        continue
    if len(esc.sub('', line)) != 63:
        bad += 1
print(bad)
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

# strip_card_frame - reads a card's stdout and prints the content-field
# text of every non-border, non-color line: "│  " and trailing "  │"
# removed, right padding stripped. TOP/BOT/DIV (box-drawing) lines are
# dropped entirely, so what remains is a list of content rows in order.
strip_card_frame() {
  python3 -c "
import sys, re
esc = re.compile(r'\x1b\[[0-9;]*m')
for raw in sys.stdin.read().split(chr(10)):
    line = esc.sub('', raw)
    if line == '' or line[0] in '┌└├':
        continue
    inner = line[3:-3] if len(line) >= 6 else ''
    print(inner.rstrip())
"
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

echo "=== test-decisions-render.sh ==="
echo ""

echo "-- Test: decisions-render.sh exists and is executable --"
[ -x "$RENDER" ] && pass "decisions-render.sh exists and is executable" || fail "decisions-render.sh exists and is executable" "executable file" "missing or not executable"

echo "-- Test: the approved 34-line Shelf renders byte for byte (FIRST test) --"
fresh_root
build_reference_fixture
SHELF_FRAME=$(cat <<'@@SHELF_FRAME@@'
┌─────────────────────────────────────────────────────────────┐
│  DECISION SHELF                                             │
├─────────────────────────────────────────────────────────────┤
│  ? pending   ○ unclaimed   ● claimed   ✓ done               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  decisions by tag               progress             total  │
│  ────────────────               ────────             ─────  │
│  requirement-to-cycle           ○○○○○○○○○●●●●●●●●●      18  │
│    ○ design-conversation-behavior                           │
│    ○ no-default-hard-stop                                   │
│    ○ before-you-leave-receipt-instrument                    │
│    ○ production-boundary-records-versus-artifacts           │
│    ○ q5-and-q3-are-derived-not-open                         │
│    ○ worker-brief-instrument                                │
│    ○ wright-authors-its-own-run-debrief                     │
│    ○ public-authoring-convention-derived                    │
│    ○ room-transitions-are-invisible                         │
│    ● attention-quiet-while-healthy                          │
│      +8 more                                                │
│                                                             │
│  guides                         ○○○                      3  │
│    ○ guides-have-an-index-and-a-lifespan                    │
│    ○ stories-carry-a-guides-section                         │
│    ○ the-notebook-holds-guides                              │
│                                                             │
│  wright                         ○                        1  │
│    ○ the-feature-folder-model-retires-sealed                │
│                                                             │
│  decisions                      ●●●●●✓✓✓✓✓✓✓✓✓✓         15  │
│    ● craft-decisions-renders-the-shelf                      │
│      +4 more                                                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
@@SHELF_FRAME@@
)
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
[ "$OUT" = "$SHELF_FRAME" ] && pass "the approved 34-line Shelf renders byte for byte" || fail "the approved 34-line Shelf renders byte for byte" "$SHELF_FRAME" "$OUT"
rm -rf "$ROOT"

echo "-- Test: every emitted line is exactly 63 characters (reference fixture, a 40-record group, and the archive frame) --"
fresh_root
build_reference_fixture
BAD=$(bash "$LIST" | bash "$RENDER" shelf | all_lines_63)
[ "$BAD" = "0" ] && pass "every line is 63 characters (reference fixture)" || fail "every line is 63 characters (reference fixture)" "0" "$BAD"
rm -rf "$ROOT"

fresh_root
for i in $(seq -w 1 40); do
  write_record "approved" "scale-record-$i" "2026-01-01" "Scale record $i" "accepted" "scale"
done
BAD=$(bash "$LIST" | bash "$RENDER" shelf | all_lines_63)
[ "$BAD" = "0" ] && pass "every line is 63 characters (40-record group)" || fail "every line is 63 characters (40-record group)" "0" "$BAD"
rm -rf "$ROOT"

fresh_root
write_archive_record "declined-idea" "2026-05-01" "declined" "alpha" '> "No." - Darin, 2026-05-01, session'
write_archive_record "retired-idea" "2026-05-15" "deprecated" "alpha" '> "This was good for its time, but the approach it locks in
> now conflicts with the newer room model. [...] Retiring it."
> - Darin, 2026-05-15, session'
BAD=$(bash "$LIST" --room=archive | bash "$RENDER" archive | all_lines_63)
[ "$BAD" = "0" ] && pass "every line is 63 characters (archive frame)" || fail "every line is 63 characters (archive frame)" "0" "$BAD"
rm -rf "$ROOT"

echo "-- Test: a group past the strip's capacity prints 22 glyphs, an ellipsis, and the real total --"
fresh_root
for i in $(seq -w 1 30); do
  write_record "approved" "overflow-record-$i" "2026-01-$i" "Overflow record $i" "accepted" "overflow"
done
ROW=$(bash "$LIST" | bash "$RENDER" shelf | grep '^│  overflow ')
GLYPH_COUNT=$(printf '%s' "$ROW" | grep -o '○' | wc -l | tr -d ' ')
ELLIPSIS_COUNT=$(printf '%s' "$ROW" | grep -o '…' | wc -l | tr -d ' ')
[ "$GLYPH_COUNT" = "22" ] && pass "overflow row prints exactly 22 glyphs" || fail "overflow row prints exactly 22 glyphs" "22" "$GLYPH_COUNT"
[ "$ELLIPSIS_COUNT" = "1" ] && pass "overflow row prints one ellipsis" || fail "overflow row prints one ellipsis" "1" "$ELLIPSIS_COUNT"
echo "$ROW" | grep -q "30  │\$" && pass "overflow row's total is the real count (30)" || fail "overflow row's total is the real count (30)" "...30  │" "$ROW"
rm -rf "$ROOT"

echo "-- Test: archive records get no row, no glyph, and no count on the Shelf --"
fresh_root
write_record "approved" "alpha-one" "2026-01-01" "Alpha one" "accepted" "alpha"
write_record "approved" "alpha-two" "2026-01-02" "Alpha two" "accepted" "alpha"
write_record "archive" "alpha-archived" "2026-01-03" "Alpha archived" "declined" "alpha"
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
echo "$OUT" | grep -q "alpha-archived" && fail "archived slug absent from Shelf" "absent" "present" || pass "archived slug absent from Shelf"
echo "$OUT" | grep '^│  alpha ' | grep -q "2  │\$" && pass "archived record not counted in the tag total" || fail "archived record not counted in the tag total" "total 2" "$(echo "$OUT" | grep '^│  alpha ')"
rm -rf "$ROOT"

echo "-- Test: a root+pending record claimed by a live story still renders ? --"
fresh_root
write_record "root" "pending-claimed" "2026-01-01" "Pending claimed" "pending" "pending-tag"
write_story "claims-it" "planning" "2026-01-01-pending-claimed"
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
echo "$OUT" | grep '^│  pending-tag ' | grep -q '?' && pass "root+pending renders ? even when DISPOSITION derives claimed" || fail "root+pending renders ? even when DISPOSITION derives claimed" "? in the strip" "$(echo "$OUT" | grep '^│  pending-tag ')"
echo "$OUT" | grep -q '│    ? pending-claimed' && pass "the sub-row shows the ? glyph" || fail "the sub-row shows the ? glyph" "│    ? pending-claimed ..." "$OUT"
rm -rf "$ROOT"

echo "-- Test: rows are grouped by glyph class, not raw emission order - a claimed record dated earlier than the open ones still prints after them --"
fresh_root
write_record "approved" "order-check-claimed" "2026-01-01" "Order check claimed" "accepted" "order-check-tag"
write_story "claims-order-check" "planning" "2026-01-01-order-check-claimed"
write_record "approved" "order-check-open-a" "2026-01-02" "Order check open a" "accepted" "order-check-tag"
write_record "approved" "order-check-open-b" "2026-01-03" "Order check open b" "accepted" "order-check-tag"
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
CLAIMED_ROW_LINE=$(echo "$OUT" | grep -n '│    ● order-check-claimed' | cut -d: -f1)
OPEN_A_LINE=$(echo "$OUT" | grep -n '│    ○ order-check-open-a' | cut -d: -f1)
OPEN_B_LINE=$(echo "$OUT" | grep -n '│    ○ order-check-open-b' | cut -d: -f1)
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
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
FRAGMENT=$(printf '%s' "$OUT" | grep -A4 '^│  guides ')
EXPECTED_FRAGMENT=$(cat <<'FRAGEOF'
│  guides                         ?○○○                     4  │
│    ? the-notebook-holds-a-guides-index                      │
│    ○ guides-have-an-index-and-a-lifespan                    │
│    ○ stories-carry-a-guides-section                         │
│    ○ the-notebook-holds-guides                              │
FRAGEOF
)
[ "$FRAGMENT" = "$EXPECTED_FRAGMENT" ] && pass "the pending fragment renders byte for byte" || fail "the pending fragment renders byte for byte" "$EXPECTED_FRAGMENT" "$FRAGMENT"
GUIDES_LINE=$(echo "$OUT" | grep -n '^│  guides ' | cut -d: -f1)
OTHER_LINE=$(echo "$OUT" | grep -n '^│  other ' | cut -d: -f1)
[ "$GUIDES_LINE" -lt "$OTHER_LINE" ] && pass "the pending tag sorts to the top" || fail "the pending tag sorts to the top" "guides before other" "guides=$GUIDES_LINE other=$OTHER_LINE"
rm -rf "$ROOT"

echo "-- Test: groups with zero unclaimed sink below every group that has unclaimed records --"
fresh_root
write_record "approved" "zero-a" "2026-01-01" "Zero A" "accepted" "zero-tag"
write_story "claims-zero-a" "planning" "2026-01-01-zero-a"
write_record "approved" "zero-b" "2026-01-02" "Zero B" "accepted" "zero-tag"
write_story "claims-zero-b" "planning" "2026-01-02-zero-b"
write_record "approved" "has-open-a" "2026-01-01" "Has open A" "accepted" "has-open-tag"
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
ZERO_LINE=$(echo "$OUT" | grep -n '^│  zero-tag ' | cut -d: -f1)
OPEN_LINE=$(echo "$OUT" | grep -n '^│  has-open-tag ' | cut -d: -f1)
[ "$OPEN_LINE" -lt "$ZERO_LINE" ] && pass "the group with unclaimed records sorts above the zero-unclaimed group" || fail "the group with unclaimed records sorts above the zero-unclaimed group" "has-open-tag before zero-tag" "has-open-tag=$OPEN_LINE zero-tag=$ZERO_LINE"
rm -rf "$ROOT"

echo "-- Test: equal-unclaimed groups order by tag name ascending --"
fresh_root
write_record "approved" "bbb-one" "2026-01-01" "Bbb one" "accepted" "bbb-tag"
write_record "approved" "bbb-two" "2026-01-02" "Bbb two" "accepted" "bbb-tag"
write_record "approved" "aaa-one" "2026-01-01" "Aaa one" "accepted" "aaa-tag"
write_record "approved" "aaa-two" "2026-01-02" "Aaa two" "accepted" "aaa-tag"
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
AAA_LINE=$(echo "$OUT" | grep -n '^│  aaa-tag ' | cut -d: -f1)
BBB_LINE=$(echo "$OUT" | grep -n '^│  bbb-tag ' | cut -d: -f1)
[ "$AAA_LINE" -lt "$BBB_LINE" ] && pass "equal-unclaimed groups tie-break by tag name ascending" || fail "equal-unclaimed groups tie-break by tag name ascending" "aaa-tag before bbb-tag" "aaa-tag=$AAA_LINE bbb-tag=$BBB_LINE"
rm -rf "$ROOT"

echo "-- Test: an empty store renders the 21-line empty frame and nothing else --"
EMPTY_FRAME=$(cat <<'@@EMPTY_FRAME@@'
┌─────────────────────────────────────────────────────────────┐
│  DECISION SHELF  ·  empty                                   │
├─────────────────────────────────────────────────────────────┤
│  A decision is the one thing you're already sure of about   │
│  a feature that has no cycle, no story, not even a name.    │
├─────────────────────────────────────────────────────────────┤
│  today      "The gameroom has a slot machine."    gameroom  │
│  tomorrow   "The slot machine has a bonus round." gameroom  │
├─────────────────────────────────────────────────────────────┤
│  ? pending   ○ unclaimed   ● claimed   ✓ done               │
├─────────────────────────────────────────────────────────────┤
│  decisions by tag               progress             total  │
│  ────────────────               ────────             ─────  │
│  gameroom (example)             ○○                       2  │
│    ○ the-gameroom-has-a-slot-machine                        │
│    ○ the-slot-machine-has-a-bonus-round                     │
├─────────────────────────────────────────────────────────────┤
│  The tag is the feature you haven't planned yet. When a     │
│  story or a cycle picks the gameroom decisions up, it is    │
│  born already knowing both. Nothing gets re-decided.        │
└─────────────────────────────────────────────────────────────┘
@@EMPTY_FRAME@@
)

fresh_root
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
[ "$OUT" = "$EMPTY_FRAME" ] && pass "the empty frame renders byte for byte with no .craft/decisions directory" || fail "the empty frame renders byte for byte with no .craft/decisions directory" "$EMPTY_FRAME" "$OUT"
rm -rf "$ROOT"

fresh_root
mkdir -p "$ROOT/.craft/decisions"
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
[ "$OUT" = "$EMPTY_FRAME" ] && pass "the empty frame renders byte for byte with an empty .craft/decisions directory" || fail "the empty frame renders byte for byte with an empty .craft/decisions directory" "$EMPTY_FRAME" "$OUT"
rm -rf "$ROOT"

echo "-- Test: one real record replaces the empty frame entirely and the word gameroom appears nowhere in the output --"
fresh_root
write_record "approved" "a-real-record" "2026-01-01" "A real record" "accepted" "real-tag"
OUT=$(bash "$LIST" | bash "$RENDER" shelf)
[ "$OUT" != "$EMPTY_FRAME" ] && pass "one real record replaces the empty frame entirely" || fail "one real record replaces the empty frame entirely" "not the empty frame" "the empty frame"
echo "$OUT" | grep -qi "gameroom" && fail "gameroom appears nowhere in non-empty output" "absent" "present" || pass "gameroom appears nowhere in non-empty output"
rm -rf "$ROOT"

echo "-- Test: the archive frame prints two lines per record, labelled, newest exit first --"
fresh_root
write_archive_record "declined-idea" "2026-01-01" "declined" "alpha" '> "No." - Darin, 2026-05-01, session'
write_archive_record "retired-idea" "2026-01-02" "deprecated" "alpha" '> "This was good for its time, but the approach it locks in
> now conflicts with the newer room model. [...] Retiring it."
> - Darin, 2026-05-15, session'
write_archive_record "retired-idea-two" "2026-01-03" "deprecated" "alpha" '> "Superseded." - Darin, 2026-05-10, session'
OUT=$(bash "$LIST" --room=archive | bash "$RENDER" archive)
RETIRED_LINE=$(echo "$OUT" | grep -n 'retired-idea  ' | cut -d: -f1)
RETIRED_TWO_LINE=$(echo "$OUT" | grep -n 'retired-idea-two' | cut -d: -f1)
DECLINED_LINE=$(echo "$OUT" | grep -n 'declined-idea' | cut -d: -f1)
[ "$RETIRED_LINE" -lt "$RETIRED_TWO_LINE" ] && [ "$RETIRED_TWO_LINE" -lt "$DECLINED_LINE" ] && pass "records order newest exit first" || fail "records order newest exit first" "retired-idea, retired-idea-two, declined-idea" "$OUT"
echo "$OUT" | grep -q '^│  declined ' && pass "the declined label prints" || fail "the declined label prints" "declined" "$OUT"
echo "$OUT" | grep -q '^│  retired ' && pass "the retired label prints" || fail "the retired label prints" "retired" "$OUT"
echo "$OUT" | grep -qi "good for its time" && pass "the wrapped exit words appear" || fail "the wrapped exit words appear" "good for its time" "$OUT"
echo "$OUT" | grep -q "Retiring it" && pass "the words include the sentence's own end" || fail "the words include the sentence's own end" "Retiring it." "$OUT"
echo "$OUT" | grep -q "Darin, 2026-05-15" && fail "the attribution segment is cut from the words" "absent" "present" || pass "the attribution segment is cut from the words"
echo "$OUT" | grep -q "Darin, 2026-05-01" && fail "the attribution segment is cut from a same-line quote+attribution" "absent" "present" || pass "the attribution segment is cut from a same-line quote+attribution"
echo "$OUT" | grep -q '^│ \{11\}"This was good' && pass "the wrapped words indent to the slug's column (index 12), not the gutter" || fail "the wrapped words indent to the slug's column (index 12), not the gutter" "11 leading spaces before the quote" "$OUT"
rm -rf "$ROOT"

echo "-- Test: exit words that follow the attribution on their own line are kept, not treated as attribution --"
fresh_root
write_archive_record "trailing-after-attribution" "2026-01-01" "deprecated" "alpha" '> "Decisions: keyed to the feature record" - Darin, 2026-08-30, dossier
> Copy paste, filed under the recording-boundary law.'
OUT=$(bash "$LIST" --room=archive | bash "$RENDER" archive)
echo "$OUT" | grep -q "recording-boundary law" && pass "the line after the attribution is kept in the words" || fail "the line after the attribution is kept in the words" "recording-boundary law" "$OUT"
echo "$OUT" | grep -q "Darin, 2026-08-30, dossier" && fail "the inline attribution is still cut from the words" "absent" "present" || pass "the inline attribution is still cut from the words"
rm -rf "$ROOT"

echo "-- Test: --only=declined shows only declined records, drops the label column, and titles the frame --"
fresh_root
write_archive_record "declined-idea" "2026-01-01" "declined" "alpha" '> "No." - Darin, 2026-05-01, session'
write_archive_record "retired-idea" "2026-01-02" "deprecated" "alpha" '> "Yes, retire it." - Darin, 2026-05-15, session'
OUT_D=$(bash "$LIST" --room=archive | bash "$RENDER" archive --only=declined)
echo "$OUT_D" | grep -q "ARCHIVE  ·  declined" && pass "--only=declined titles the frame" || fail "--only=declined titles the frame" "ARCHIVE  ·  declined" "$OUT_D"
echo "$OUT_D" | grep -q "declined-idea" && pass "--only=declined includes the declined record" || fail "--only=declined includes the declined record" "declined-idea" "$OUT_D"
echo "$OUT_D" | grep -q "retired-idea" && fail "--only=declined excludes retired records" "absent" "present" || pass "--only=declined excludes retired records"
echo "$OUT_D" | grep -q '^│  declined ' && fail "--only=declined drops the label column" "no label column" "label column present" || pass "--only=declined drops the label column"

OUT_R=$(bash "$LIST" --room=archive | bash "$RENDER" archive --only=retired)
echo "$OUT_R" | grep -q "ARCHIVE  ·  retired" && pass "--only=retired titles the frame" || fail "--only=retired titles the frame" "ARCHIVE  ·  retired" "$OUT_R"
echo "$OUT_R" | grep -q "retired-idea" && pass "--only=retired includes the retired record" || fail "--only=retired includes the retired record" "retired-idea" "$OUT_R"
echo "$OUT_R" | grep -q "declined-idea" && fail "--only=retired excludes declined records" "absent" "present" || pass "--only=retired excludes declined records"
rm -rf "$ROOT"

echo "-- Test: render reads no project state --"
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
  SHELF_OUT=$(printf '' | bash "$RENDER" shelf)
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
  ARCHIVE_OUT=$(printf '%s\n' "$BLOCK" | bash "$RENDER" archive)
  echo "$ARCHIVE_OUT" > "$UNSET_TEST_DIR/archive-out.txt"
)
SHELF_RESULT=$(cat "$UNSET_TEST_DIR/shelf-out.txt")
[ "$SHELF_RESULT" = "$EMPTY_FRAME" ] && pass "shelf renders with CRAFT_PROJECT_ROOT unset from an empty directory" || fail "shelf renders with CRAFT_PROJECT_ROOT unset from an empty directory" "$EMPTY_FRAME" "$SHELF_RESULT"
ARCHIVE_RESULT=$(cat "$UNSET_TEST_DIR/archive-out.txt")
echo "$ARCHIVE_RESULT" | grep -q "far-record" && pass "archive renders with CRAFT_PROJECT_ROOT unset, reading only the FILE= path handed to it" || fail "archive renders with CRAFT_PROJECT_ROOT unset" "far-record" "$ARCHIVE_RESULT"
rm -rf "$UNSET_TEST_DIR" "$FAR_RECORD_DIR"

echo ""
echo "=== The card: one shape, five faces ==="
echo ""

echo "-- Test: a fresh card's text equals capture's file once the frame transform is undone (FIRST test) --"
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
CARD_OUT=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh)
DIFF=$(python3 -c "
import re, sys
esc = re.compile(r'\x1b\[[0-9;]*m')
card_lines = []
for raw in '''$CARD_OUT'''.split(chr(10)):
    line = esc.sub('', raw)
    if line == '' or line[0] in '┌└├':
        continue
    card_lines.append((line[3:-3] if len(line) >= 6 else '').rstrip())

with open('$REAL_PATH') as f:
    content = f.read()
m = re.match(r'^---\n.*?\n---\n?(.*)\$', content, re.DOTALL)
expected_text = m.group(1)

# Header is two lines (status/tags/source, then the dated slug alone);
# the title (bare, unindented) is the first content row after them.
# Line breaks may legitimately differ now that the frame reflows
# paragraphs at 55 instead of relaying the file's own breaks - so this
# undoes the frame transform (labels back to '## ', title back to
# '# ', body indent stripped) and collapses whitespace runs to single
# spaces on BOTH sides before comparing, per the story's Chunk 3
# contract: 'the sequence of words and punctuation is identical, line
# breaks may differ'.
LABELS = {
    'CONTEXT': 'Context',
    'OPTIONS CONSIDERED': 'Options considered',
    'DECISION': 'Decision',
    'CONSEQUENCES': 'Consequences',
    'APPROVAL': 'Approval',
}
title = card_lines[2]
out_lines = ['# ' + title]
idx = 3
while idx < len(card_lines) and card_lines[idx] != 'YOUR MOVE':
    line = card_lines[idx]
    if line in LABELS:
        out_lines.append('## ' + LABELS[line])
    elif line == '':
        out_lines.append('')
    else:
        out_lines.append(line[2:] if line.startswith('  ') else line)
    idx += 1
got_text = '\n'.join(out_lines)

norm = lambda s: re.sub(r'\s+', ' ', s).strip()
if norm(got_text) == norm(expected_text):
    print('MATCH')
else:
    print('MISMATCH')
    print('expected:', norm(expected_text))
    print('got:     ', norm(got_text))
")
echo "$DIFF" | grep -q '^MATCH$' && pass "the fresh card's text equals capture's file once the frame transform is undone" || fail "the fresh card's text equals capture's file once the frame transform is undone" "MATCH" "$DIFF"
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
ORPHAN_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh)
ORPHAN_CHECK=$(python3 -c "
import re, sys
esc = re.compile(r'\x1b\[[0-9;]*m')
lines = []
for raw in '''$ORPHAN_CARD'''.split(chr(10)):
    line = esc.sub('', raw)
    if line == '' or (line and line[0] in '┌└├'):
        continue
    inner = (line[3:-3] if len(line) >= 6 else '').rstrip()
    lines.append(inner)
# Only the CONTEXT section's body lines matter here - the paragraph is
# many words long, so if reflow worked, no physical line inside it is
# a single word.
start = lines.index('CONTEXT') + 1
end = start
while end < len(lines) and lines[end] != '':
    end += 1
body = [l[2:] if l.startswith('  ') else l for l in lines[start:end]]
orphans = [l for l in body if len(l.split()) == 1]
print('ORPHANS=' + str(len(orphans)))
")
echo "$ORPHAN_CHECK" | grep -q "ORPHANS=0" && pass "a record authored at 57 columns renders with no one-word orphan lines" || fail "a record authored at 57 columns renders with no one-word orphan lines" "ORPHANS=0" "$ORPHAN_CHECK"
rm -rf "$ROOT"

echo "-- Test: the card header is two lines and a 50-character slug sits whole on the second --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "Guides get an index of the right length" --tag=guides --created=2026-01-01 \
  --context="Context." --options="- A." --decision="A." --consequences="Fine." --dry-run)
REPORTED_SLUG=$(printf '%s\n' "$DRY_OUT" | head -1 | sed 's/^SLUG=//')
SLUG_LEN=${#REPORTED_SLUG}
[ "$SLUG_LEN" = "50" ] && pass "the fixture's dated slug is exactly 50 characters" || fail "the fixture's dated slug is exactly 50 characters" "50" "$SLUG_LEN"
CARD_STRIPPED=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh | strip_card_frame)
HEADER_LINE2=$(echo "$CARD_STRIPPED" | sed -n '2p')
[ "$HEADER_LINE2" = "$REPORTED_SLUG" ] && pass "the 50-character slug sits whole on the header's second line" || fail "the 50-character slug sits whole on the header's second line" "$REPORTED_SLUG" "$HEADER_LINE2"
echo "$HEADER_LINE2" | grep -q ' ' && fail "the slug is not broken mid-word" "no internal space" "space present" || pass "the slug is not broken mid-word"
rm -rf "$ROOT"

echo "-- Test: labels are CAPS at the gutter and body lines are indented two beneath them --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A labelled card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
FRESH_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh)
for LABEL in CONTEXT "OPTIONS CONSIDERED" DECISION CONSEQUENCES APPROVAL "YOUR MOVE"; do
  echo "$FRESH_CARD" | grep -qF "│  $LABEL" && pass "the $LABEL label sits at the gutter" || fail "the $LABEL label sits at the gutter" "│  $LABEL" "$FRESH_CARD"
done
echo "$FRESH_CARD" | grep -q '^│    Context\.' && pass "the Context body line is indented two beneath its label" || fail "the Context body line is indented two beneath its label" "│    Context." "$FRESH_CARD"
echo "$FRESH_CARD" | grep -q '^│    - A\.' && pass "an option body line is indented two beneath its label" || fail "an option body line is indented two beneath its label" "│    - A." "$FRESH_CARD"

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
RETIRE_CARD=$(bash "$RENDER" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-labelled-law.md")
echo "$RETIRE_CARD" | grep -qF '│  APPROVAL' && pass "retire's APPROVAL label sits at the gutter" || fail "retire's APPROVAL label sits at the gutter" "│  APPROVAL" "$RETIRE_CARD"
echo "$RETIRE_CARD" | grep -q '^│    > "approve"' && pass "retire's approval quote is indented two beneath its label" || fail "retire's approval quote is indented two beneath its label" '│    > "approve"' "$RETIRE_CARD"

PENDING_CARD_STATE=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --state=question --proposed=a)
echo "$PENDING_CARD_STATE" | grep -qF '│  YOUR OPTIONS' && pass "the question state's YOUR OPTIONS label sits at the gutter" || fail "the question state's YOUR OPTIONS label sits at the gutter" "│  YOUR OPTIONS" "$PENDING_CARD_STATE"
echo "$PENDING_CARD_STATE" | grep -q '^│    (a) Proposed: A\.' && pass "a lettered option is indented two beneath YOUR OPTIONS" || fail "a lettered option is indented two beneath YOUR OPTIONS" "│    (a) Proposed: A." "$PENDING_CARD_STATE"
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
BULLET_DIFF=$(bash "$RENDER" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-bullet-law.md" \
  --context="Context." --options="- Keep it as is.
- A brand new option." --decision="Keep it as is." --consequences="Fine.")
echo "$BULLET_DIFF" | grep -q '^│  - - Change it\.' && pass "the removed bullet's marker and dash never share a column" || fail "the removed bullet's marker and dash never share a column" "│  - - Change it." "$BULLET_DIFF"
echo "$BULLET_DIFF" | grep -q '^│  + - A brand new option\.' && pass "the added bullet's marker and dash never share a column" || fail "the added bullet's marker and dash never share a column" "│  + - A brand new option." "$BULLET_DIFF"
echo "$BULLET_DIFF" | grep -q '^│    - Keep it as is\.' && pass "the unchanged bullet keeps the blank two-space indent before its own dash" || fail "the unchanged bullet keeps the blank two-space indent before its own dash" "│    - Keep it as is." "$BULLET_DIFF"
rm -rf "$ROOT"

echo "-- Test: the header shows the collision-suffixed slug the file will actually get --"
fresh_root
bash "$CAPTURE" "Collision title" --tag=guides --quote="a" \
  --context="Some context." --options="- One." --decision="One." --consequences="Fine." > /dev/null
DRY_OUT=$(bash "$CAPTURE" "Collision title" --tag=guides \
  --context="Some context." --options="- One." --decision="One." --consequences="Fine." --dry-run)
CARD_HEADER_SLUG=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh | strip_card_frame | sed -n '2p')
REPORTED_SLUG=$(printf '%s\n' "$DRY_OUT" | head -1 | sed 's/^SLUG=//')
echo "$REPORTED_SLUG" | grep -q -- '-2$' && pass "the dry run itself reports the collision-suffixed slug" || fail "the dry run itself reports the collision-suffixed slug" "*-2" "$REPORTED_SLUG"
[ "$CARD_HEADER_SLUG" = "$REPORTED_SLUG" ] && pass "the card header's second line carries the collision-suffixed slug" || fail "the card header's second line carries the collision-suffixed slug" "$REPORTED_SLUG" "$CARD_HEADER_SLUG"
rm -rf "$ROOT"

echo "-- Test: every card line is exactly 63 characters, across all five faces --"
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
BAD=0
BAD=$((BAD + $(printf '%s\n' "$FRESH_DRY" | bash "$RENDER" card --variant=fresh | all_lines_63)))
BAD=$((BAD + $(printf '%s\n' "$FRESH_DRY" | bash "$RENDER" card --variant=fresh --state=question --proposed=a | all_lines_63)))
BAD=$((BAD + $(bash "$RENDER" card --variant=pending --file="$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" | all_lines_63)))
BAD=$((BAD + $(bash "$RENDER" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" --claimed-by="story-a:ready" | all_lines_63)))
BAD=$((BAD + $(bash "$RENDER" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-wide-law.md" \
  --context="New context." --options="- Keep it as is." --decision="Change it." --consequences="Nothing changes." | all_lines_63)))
[ "$BAD" -eq 0 ] && pass "every line across all five faces, including the widest body line, is 63 characters" || fail "every line across all five faces, including the widest body line, is 63 characters" "0" "$BAD"
rm -rf "$ROOT"

echo "-- Test: the question and decision states render from ONE input --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A forked card" --tag=guides \
  --context="Two ways to go." --options="- Option one text.
- Option two text." --decision="Option one text." --consequences="Fine either way." --dry-run)
QUESTION=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --state=question --proposed=a)
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
DEFAULT_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh)
echo "$DEFAULT_CARD" | grep -q "a) approve" && echo "$DEFAULT_CARD" | grep -q "b) keep pending" && echo "$DEFAULT_CARD" | grep -q "c) decline" && pass "with no --state, a fresh card arrives in the decision state (a/b/c)" || fail "with no --state, a fresh card arrives in the decision state (a/b/c)" "a) approve / b) keep pending / c) decline" "$DEFAULT_CARD"
rm -rf "$ROOT"

echo "-- Test: --proposed= is required in the question state and refused in the decision state --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --state=question > /dev/null 2>&1 && fail "--state=question with no --proposed= is refused" "exit 1" "exit 0" || pass "--state=question with no --proposed= is refused"
printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --state=decision --proposed=a > /dev/null 2>&1 && fail "--proposed= in the decision state is refused" "exit 1" "exit 0" || pass "--proposed= in the decision state is refused"
rm -rf "$ROOT"

echo "-- Test: each face offers exactly its ruled letters, effects and closing line --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)

FRESH_DECISION=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh)
echo "$FRESH_DECISION" | grep -q "a) approve" || fail "fresh decision offers a) approve" "a) approve" "$FRESH_DECISION"
echo "$FRESH_DECISION" | grep -q "b) keep pending" || fail "fresh decision offers b) keep pending" "b) keep pending" "$FRESH_DECISION"
echo "$FRESH_DECISION" | grep -q "c) decline" || fail "fresh decision offers c) decline" "c) decline" "$FRESH_DECISION"
echo "$FRESH_DECISION" | grep -q "a, b, c, or just tell me what to change." && pass "fresh decision's closing line names a, b, c" || fail "fresh decision's closing line names a, b, c" "a, b, c, or just tell me what to change." "$FRESH_DECISION"

FRESH_QUESTION=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --state=question --proposed=a)
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
REOPEN=$(bash "$RENDER" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-letters-law.md" \
  --context="Context." --options="- A." --decision="B." --consequences="Fine.")
echo "$REOPEN" | grep -q "a) approve" && echo "$REOPEN" | grep -q "the law changes to this" && pass "reopen offers a) approve, effect 'the law changes to this'" || fail "reopen offers a) approve, effect 'the law changes to this'" "a) approve ... the law changes to this" "$REOPEN"
echo "$REOPEN" | grep -q "a, or just tell me what to change." && pass "reopen's closing line names only a" || fail "reopen's closing line names only a" "a, or just tell me what to change." "$REOPEN"

RETIRE=$(bash "$RENDER" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-letters-law.md")
echo "$RETIRE" | grep -q "a) retire" && echo "$RETIRE" | grep -q "no longer applies" && echo "$RETIRE" | grep -q "archive" && echo "$RETIRE" | grep -q "with your words" && pass "retire offers a) retire, effect 'no longer applies...'" || fail "retire offers a) retire, effect 'no longer applies...'" "a) retire ... no longer applies ... with your words" "$RETIRE"
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

LETTERED_OUT=$(bash "$RENDER" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-01-lettered-one.md")
echo "$LETTERED_OUT" | grep -q "YOUR OPTIONS" && pass "a pending card with lettered options draws as a question" || fail "a pending card with lettered options draws as a question" "YOUR OPTIONS" "$LETTERED_OUT"
echo "$LETTERED_OUT" | grep -q '(b) Proposed: Change it.' && pass "the Proposed option is marked from the file's own marker" || fail "the Proposed option is marked from the file's own marker" "(b) Proposed:" "$LETTERED_OUT"

DASHED_OUT=$(bash "$RENDER" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-02-dashed-one.md")
echo "$DASHED_OUT" | grep -q "OPTIONS CONSIDERED" && pass "a pending card with dashed options draws as a decision" || fail "a pending card with dashed options draws as a decision" "OPTIONS CONSIDERED" "$DASHED_OUT"
echo "$DASHED_OUT" | grep -q "a) approve" && pass "the dashed pending card offers approve/keep pending/decline" || fail "the dashed pending card offers approve/keep pending/decline" "a) approve" "$DASHED_OUT"

EMPTY_OUT=$(bash "$RENDER" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-03-empty-one.md")
echo "$EMPTY_OUT" | grep -q "OPTIONS CONSIDERED" && pass "a pending card with no options draws as a decision" || fail "a pending card with no options draws as a decision" "OPTIONS CONSIDERED" "$EMPTY_OUT"

FORCED_DECISION=$(bash "$RENDER" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-01-lettered-one.md" --state=decision)
echo "$FORCED_DECISION" | grep -q "OPTIONS CONSIDERED" && pass "an explicit --state=decision overrides the file's lettered shape" || fail "an explicit --state=decision overrides the file's lettered shape" "OPTIONS CONSIDERED" "$FORCED_DECISION"
rm -rf "$ROOT"

echo "-- Test: a single lettered option still draws as a question --"
fresh_root
write_options_record "root" "single-lettered" "2026-01-01" "Single lettered" "pending" "guides" \
'(a) Proposed: The only option.'
SINGLE_OUT=$(bash "$RENDER" card --variant=pending --file="$ROOT/.craft/decisions/2026-01-01-single-lettered.md")
echo "$SINGLE_OUT" | grep -q "YOUR OPTIONS" && pass "a single lettered option still draws as a question" || fail "a single lettered option still draws as a question" "YOUR OPTIONS" "$SINGLE_OUT"
rm -rf "$ROOT"

echo "-- Test: the decision state never prints a lettered option and the question state never prints a dashed one --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A card" --tag=guides \
  --context="Context." --options="- A.
- B." --decision="A." --consequences="Fine." --dry-run)
DEC=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --state=decision)
QUE=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --state=question --proposed=a)
echo "$DEC" | grep -qE '\(a\)|\(b\)' && fail "the decision state never prints a lettered option" "no (a)/(b)" "$DEC" || pass "the decision state never prints a lettered option"
echo "$QUE" | grep -q '^│    - ' && fail "the question state never prints a dashed option" "no dash lines" "$QUE" || pass "the question state never prints a dashed option"
rm -rf "$ROOT"

echo "-- Test: a body line wider than 57 columns wraps inside the frame and never breaks 63 columns --"
fresh_root
LONG_TEXT=$(printf 'word%.0s ' $(seq 1 120))
DRY_OUT=$(bash "$CAPTURE" "A wide card" --tag=guides \
  --context="$LONG_TEXT" --options="- A." --decision="A." --consequences="Fine." --dry-run)
WIDE_CARD=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh)
echo "$WIDE_CARD" | grep -q "word word word" && pass "a wide body line is present, wrapped" || fail "a wide body line is present, wrapped" "word word word" "$WIDE_CARD"
BAD=$(printf '%s\n' "$WIDE_CARD" | all_lines_63)
[ "$BAD" = "0" ] && pass "the wrapped card never breaks 63 columns" || fail "the wrapped card never breaks 63 columns" "0" "$BAD"
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

CLAIMED_RETIRE=$(bash "$RENDER" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" \
  --claimed-by="story-planning:planning" --claimed-by="story-ready:ready")
echo "$CLAIMED_RETIRE" | grep -qF '│  CLAIMED BY STORIES' && pass "the retire card prints a CLAIMED BY STORIES band at the gutter" || fail "the retire card prints a CLAIMED BY STORIES band at the gutter" "│  CLAIMED BY STORIES" "$CLAIMED_RETIRE"
PLANNING_LINE=$(echo "$CLAIMED_RETIRE" | grep "story-planning")
READY_LINE=$(echo "$CLAIMED_RETIRE" | grep "story-ready")
PLANNING_END=$(python3 -c "print('$PLANNING_LINE'.rstrip().rfind('planning') + len('planning'))")
READY_END=$(python3 -c "print('$READY_LINE'.rstrip().rfind('ready') + len('ready'))")
[ "$PLANNING_END" = "$READY_END" ] && pass "each story's status aligns in a fixed column" || fail "each story's status aligns in a fixed column" "$PLANNING_END" "$READY_END"

CLAIMED_REOPEN=$(bash "$RENDER" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" \
  --context="Context." --options="- A." --decision="A." --consequences="Fine." --claimed-by="story-planning:planning")
echo "$CLAIMED_REOPEN" | grep -qF '│  CLAIMED BY STORIES' && pass "the reopen card also prints a CLAIMED BY STORIES band" || fail "the reopen card also prints a CLAIMED BY STORIES band" "│  CLAIMED BY STORIES" "$CLAIMED_REOPEN"

SHIPPED=$(bash "$RENDER" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" --shipped-by="ship-story")
echo "$SHIPPED" | grep -qF '│  SHIPPED BY STORY' && pass "SHIPPED BY STORY prints at the gutter" || fail "SHIPPED BY STORY prints at the gutter" "│  SHIPPED BY STORY" "$SHIPPED"
echo "$SHIPPED" | grep -q '^│    ship-story' && pass "the shipping story is indented two beneath the label, with no status" || fail "the shipping story is indented two beneath the label, with no status" "│    ship-story" "$SHIPPED"

NEITHER=$(bash "$RENDER" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md")
echo "$NEITHER" | grep -q "CLAIMED BY STORIES\|SHIPPED BY STORY" && fail "the band is omitted with neither flag" "no band" "$NEITHER" || pass "the band is omitted with neither flag"

bash "$RENDER" card --variant=retire --file="$ROOT/.craft/decisions/approved/2026-01-01-claimed-law.md" \
  --claimed-by="a:planning" --shipped-by="b" > /dev/null 2>&1 && fail "the two flags together are refused" "exit 1" "exit 0" || pass "the two flags together are refused"
rm -rf "$ROOT"

echo "-- Test: --new-group=<tag> marks that tag NEW GROUP in the header --"
fresh_root
DRY_OUT=$(bash "$CAPTURE" "A new group card" --tag=gameroom \
  --context="Context." --options="- A." --decision="A." --consequences="Fine." --dry-run)
MARKED=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh --new-group=gameroom)
UNMARKED=$(printf '%s\n' "$DRY_OUT" | bash "$RENDER" card --variant=fresh)
echo "$MARKED" | grep -q "gameroom (NEW GROUP)" && pass "--new-group= marks the tag NEW GROUP" || fail "--new-group= marks the tag NEW GROUP" "gameroom (NEW GROUP)" "$MARKED"
echo "$UNMARKED" | grep -q "NEW GROUP" && fail "without the flag the tag renders plain" "no NEW GROUP" "$UNMARKED" || pass "without the flag the tag renders plain"
rm -rf "$ROOT"

echo "-- Test: a reopen card marks removed/added lines and leaves unchanged lines unmarked, with no escapes when not a TTY --"
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
DIFF_OUT=$(bash "$RENDER" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-diff-law.md" \
  --context="Unchanged context line." --options="- Keep it as is." --decision="Change it now." --consequences="Nothing changes.")
echo "$DIFF_OUT" | grep -q "^│  - Keep it as is\." && pass "the removed decision line carries a - marker at the gutter" || fail "the removed decision line carries a - marker at the gutter" "│  - Keep it as is." "$DIFF_OUT"
echo "$DIFF_OUT" | grep -q "^│  + Change it now\." && pass "the added decision line carries a + marker at the gutter" || fail "the added decision line carries a + marker at the gutter" "│  + Change it now." "$DIFF_OUT"
echo "$DIFF_OUT" | grep -q "^│    Unchanged context line\." && pass "the unchanged context line keeps the blank two-space indent" || fail "the unchanged context line keeps the blank two-space indent" "│    Unchanged context line." "$DIFF_OUT"
HAS_ESCAPE=$(printf '%s' "$DIFF_OUT" | python3 -c "import sys; print('yes' if chr(27) in sys.stdin.read() else 'no')")
[ "$HAS_ESCAPE" = "no" ] && pass "no escape sequences when stdout is not a TTY" || fail "no escape sequences when stdout is not a TTY" "no" "$HAS_ESCAPE"
rm -rf "$ROOT"

echo "-- Test: with colour forced on, the same reopen card colours - lines red and + lines green, one reset per line, 63 visible columns --"
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
COLOR_OUT=$(CRAFT_DECISIONS_FORCE_COLOR=1 bash "$RENDER" card --variant=reopen --file="$ROOT/.craft/decisions/approved/2026-01-01-diff-law.md" \
  --context="Unchanged context line." --options="- Keep it as is." --decision="Change it now." --consequences="Nothing changes.")
RESULT=$(python3 -c "
import re
esc = re.compile(r'\x1b\[[0-9;]*m')
red_ok = False
green_ok = False
reset_ok = True
width_ok = True
for line in '''$COLOR_OUT'''.split(chr(10)):
    if '\x1b[31m' in line:
        if line.startswith('\x1b[31m') and line.endswith('\x1b[0m') and line.count('\x1b[0m') == 1:
            red_ok = True
        else:
            reset_ok = False
    if '\x1b[32m' in line:
        if line.startswith('\x1b[32m') and line.endswith('\x1b[0m') and line.count('\x1b[0m') == 1:
            green_ok = True
        else:
            reset_ok = False
    stripped = esc.sub('', line)
    if stripped and len(stripped) != 63:
        width_ok = False
print('red_ok={} green_ok={} reset_ok={} width_ok={}'.format(red_ok, green_ok, reset_ok, width_ok))
")
echo "$RESULT" | grep -q "red_ok=True" && pass "the removed line is wrapped in red with one reset" || fail "the removed line is wrapped in red with one reset" "red_ok=True" "$RESULT"
echo "$RESULT" | grep -q "green_ok=True" && pass "the added line is wrapped in green with one reset" || fail "the added line is wrapped in green with one reset" "green_ok=True" "$RESULT"
echo "$RESULT" | grep -q "width_ok=True" && pass "every line measures exactly 63 visible characters once escapes are stripped" || fail "every line measures exactly 63 visible characters once escapes are stripped" "width_ok=True" "$RESULT"
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
  bash "$RENDER" card --variant=retire --file="$FAR_FILE_DIR/2026-01-01-far-card.md" > "$UNSET_CARD_DIR/card-out.txt"
)
CARD_UNSET_RESULT=$(cat "$UNSET_CARD_DIR/card-out.txt")
echo "$CARD_UNSET_RESULT" | grep -q "Far card" && pass "card renders with CRAFT_PROJECT_ROOT unset, reading only the --file= path handed to it" || fail "card renders with CRAFT_PROJECT_ROOT unset" "Far card" "$CARD_UNSET_RESULT"
rm -rf "$UNSET_CARD_DIR" "$FAR_FILE_DIR"

echo ""
echo "=== Summary: $PASS_COUNT/$TOTAL passed ==="
[ "$FAIL_COUNT" -eq 0 ]
