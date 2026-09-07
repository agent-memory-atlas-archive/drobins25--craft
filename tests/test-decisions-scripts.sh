#!/bin/bash
# test-decisions-scripts.sh — Behavior tests for the decisions-*.sh trio
# Usage: bash tests/test-decisions-scripts.sh
#
# Chunk 1 covers decisions-list.sh only. Chunks 2-4 append sections here
# for decisions-capture.sh, decisions-transition.sh, and the complete-story.sh
# flip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/../hooks/scripts/decisions-list.sh"
CAPTURE="$SCRIPT_DIR/../hooks/scripts/decisions-capture.sh"
TRANSITION="$SCRIPT_DIR/../hooks/scripts/decisions-transition.sh"
COMPLETE_STORY="$SCRIPT_DIR/../hooks/scripts/complete-story.sh"

PASS_COUNT=0; FAIL_COUNT=0; TOTAL=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    Expected: $2"; [ -n "${3:-}" ] && echo "    Got:      $3"; }

fresh_root() {
  ROOT=$(mktemp -d)
  export CRAFT_PROJECT_ROOT="$ROOT"
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

echo "=== test-decisions-scripts.sh ==="
echo ""

echo "-- Test: list over 40 records and 205 story files completes in under 2 seconds --"
fresh_root
for i in $(seq -w 1 40); do
  write_record "root" "scale-record-$i" "2026-01-01" "Scale record $i" "pending" "scale"
done
for i in $(seq -w 1 205); do
  write_story "scale-story-$i" "planning" ""
done
START=$(date +%s)
set +e
OUT=$(bash "$LIST")
RC=$?
set -e
END=$(date +%s)
ELAPSED=$((END - START))
[ "$RC" -eq 0 ] && pass "exit 0 at scale" || fail "exit 0 at scale" "0" "$RC"
COUNT=$(echo "$OUT" | grep -c "^SLUG=" || true)
[ "$COUNT" -eq 40 ] && pass "all 40 records emitted at scale" || fail "all 40 records emitted at scale" "40" "$COUNT"
[ "$ELAPSED" -lt 2 ] && pass "completes in under 2 seconds ($ELAPSED s)" || fail "completes in under 2 seconds" "<2s" "${ELAPSED}s"
rm -rf "$ROOT"

echo "-- Test: no .craft/decisions directory is silent and exits 0 --"
fresh_root
set +e
OUT=$(bash "$LIST")
RC=$?
set -e
[ "$RC" -eq 0 ] && pass "exit 0 with no .craft/decisions" || fail "exit 0 with no .craft/decisions" "0" "$RC"
[ -z "$OUT" ] && pass "empty stdout with no .craft/decisions" || fail "empty stdout with no .craft/decisions" "(empty)" "$OUT"
rm -rf "$ROOT"

echo "-- Test: a record whose BODY contains a disposition: line still reads DISPOSITION=open --"
fresh_root
write_record "approved" "fence-trap" "2026-09-03" "Fence trap record" "accepted" "decisions" "" "" \
  "disposition: open | claimed | crafted - pure enum, nothing else."
OUT=$(bash "$LIST" --slug=2026-09-03-fence-trap)
echo "$OUT" | grep -q "^DISPOSITION=open$" && pass "fence-scoped parse ignores body prose" || fail "fence-scoped parse ignores body prose" "DISPOSITION=open" "$(echo "$OUT" | grep '^DISPOSITION=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: keys are emitted in the contracted order for every block --"
fresh_root
write_record "root" "order-check" "2026-01-01" "Order check" "pending" "tag-a"
OUT=$(bash "$LIST")
KEYS=$(echo "$OUT" | grep -v '^$' | sed -E 's/=.*$//' | tr '\n' ',')
EXPECTED="FILE,ROOM,SLUG,DATE,TITLE,STATUS,TAGS,DISPOSITION,STORIES,"
[ "$KEYS" = "$EXPECTED" ] && pass "keys emitted in contracted order" || fail "keys emitted in contracted order" "$EXPECTED" "$KEYS"
rm -rf "$ROOT"

echo "-- Test: SLUG is the full dated slug, not the date-stripped slug --"
fresh_root
write_record "root" "keep-my-date" "2026-05-01" "Keep my date" "pending" "tag-a"
OUT=$(bash "$LIST")
echo "$OUT" | grep -q "^SLUG=2026-05-01-keep-my-date$" && pass "SLUG carries the full dated slug" || fail "SLUG carries the full dated slug" "SLUG=2026-05-01-keep-my-date" "$(echo "$OUT" | grep '^SLUG=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: a record claimed by a non-complete story reads claimed with STORIES set --"
fresh_root
write_record "approved" "claimed-record" "2026-01-01" "Claimed record" "accepted" "tag-a"
write_story "claiming-story" "planning" "2026-01-01-claimed-record"
OUT=$(bash "$LIST" --slug=2026-01-01-claimed-record)
echo "$OUT" | grep -q "^DISPOSITION=claimed$" && pass "claimed by a non-complete story" || fail "claimed by a non-complete story" "DISPOSITION=claimed" "$(echo "$OUT" | grep '^DISPOSITION=' || echo missing)"
echo "$OUT" | grep -q "^STORIES=claiming-story$" && pass "STORIES set to the claiming story" || fail "STORIES set to the claiming story" "STORIES=claiming-story" "$(echo "$OUT" | grep '^STORIES=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: the same record reads open once the claiming story's status is complete --"
fresh_root
write_record "approved" "was-claimed" "2026-01-01" "Was claimed" "accepted" "tag-a"
write_story "shipped-story" "complete" "2026-01-01-was-claimed"
OUT=$(bash "$LIST" --slug=2026-01-01-was-claimed)
echo "$OUT" | grep -q "^DISPOSITION=open$" && pass "reads open once claiming story completes" || fail "reads open once claiming story completes" "DISPOSITION=open" "$(echo "$OUT" | grep '^DISPOSITION=' || echo missing)"
echo "$OUT" | grep -q "^STORIES=$" && pass "STORIES empty once open" || fail "STORIES empty once open" "STORIES=" "$(echo "$OUT" | grep '^STORIES=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: frontmatter disposition: crafted wins over an active claiming story --"
fresh_root
write_record "approved" "already-crafted" "2026-01-01" "Already crafted" "accepted" "tag-a" "crafted" "shipping-story"
write_story "another-claimant" "planning" "2026-01-01-already-crafted"
OUT=$(bash "$LIST" --slug=2026-01-01-already-crafted)
echo "$OUT" | grep -q "^DISPOSITION=crafted$" && pass "crafted wins over an active claiming story" || fail "crafted wins over an active claiming story" "DISPOSITION=crafted" "$(echo "$OUT" | grep '^DISPOSITION=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: frontmatter disposition: claimed is never emitted from disk --"
fresh_root
write_record "approved" "fake-claimed" "2026-01-01" "Fake claimed" "accepted" "tag-a" "claimed"
OUT=$(bash "$LIST" --slug=2026-01-01-fake-claimed)
echo "$OUT" | grep -q "^DISPOSITION=open$" && pass "a disk claimed value is never trusted, reads open with no claimant" || fail "a disk claimed value is never trusted" "DISPOSITION=open" "$(echo "$OUT" | grep '^DISPOSITION=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: STORIES for a crafted record comes from frontmatter, not from the scan --"
fresh_root
write_record "approved" "frontmatter-stories" "2026-01-01" "Frontmatter stories" "accepted" "tag-a" "crafted" "shipped-by-me"
write_story "not-the-shipper" "planning" "2026-01-01-frontmatter-stories"
OUT=$(bash "$LIST" --slug=2026-01-01-frontmatter-stories)
echo "$OUT" | grep -q "^STORIES=shipped-by-me$" && pass "STORIES comes from frontmatter for a crafted record" || fail "STORIES comes from frontmatter for a crafted record" "STORIES=shipped-by-me" "$(echo "$OUT" | grep '^STORIES=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: --room, --tag, --status, --disposition and --slug each filter, and two filters AND together --"
fresh_root
write_record "root" "pending-one" "2026-01-01" "Pending one" "pending" "alpha"
write_record "approved" "accepted-one" "2026-01-02" "Accepted one" "accepted" "beta" "crafted" "some-story"
OUT_ROOM=$(bash "$LIST" --room=approved)
echo "$OUT_ROOM" | grep -q "^SLUG=2026-01-02-accepted-one$" && pass "--room filters to matching room" || fail "--room filters to matching room"
echo "$OUT_ROOM" | grep -q "^SLUG=2026-01-01-pending-one$" && fail "--room excludes non-matching room" "absent" "present" || pass "--room excludes non-matching room"

OUT_TAG=$(bash "$LIST" --tag=alpha)
echo "$OUT_TAG" | grep -q "^SLUG=2026-01-01-pending-one$" && pass "--tag filters to matching tag" || fail "--tag filters to matching tag"

OUT_STATUS=$(bash "$LIST" --status=accepted)
echo "$OUT_STATUS" | grep -q "^SLUG=2026-01-02-accepted-one$" && pass "--status filters to matching status" || fail "--status filters to matching status"

OUT_DISP=$(bash "$LIST" --disposition=crafted)
echo "$OUT_DISP" | grep -q "^SLUG=2026-01-02-accepted-one$" && pass "--disposition filters to matching disposition" || fail "--disposition filters to matching disposition"

OUT_SLUG=$(bash "$LIST" --slug=2026-01-01-pending-one)
COUNT_SLUG=$(echo "$OUT_SLUG" | grep -c "^SLUG=" || true)
[ "$COUNT_SLUG" -eq 1 ] && pass "--slug filters to exactly one record" || fail "--slug filters to exactly one record" "1" "$COUNT_SLUG"

OUT_AND=$(bash "$LIST" --room=root --tag=alpha)
COUNT_AND=$(echo "$OUT_AND" | grep -c "^SLUG=" || true)
[ "$COUNT_AND" -eq 1 ] && pass "two filters AND together (match)" || fail "two filters AND together (match)" "1" "$COUNT_AND"

OUT_AND_NONE=$(bash "$LIST" --room=archive --tag=alpha)
[ -z "$OUT_AND_NONE" ] && pass "two filters AND together (no match)" || fail "two filters AND together (no match)" "(empty)" "$OUT_AND_NONE"
rm -rf "$ROOT"

echo "-- Test: --tag=<a tag no record carries> prints nothing and exits 0 --"
fresh_root
write_record "root" "only-record" "2026-01-01" "Only record" "pending" "known-tag"
set +e
OUT=$(bash "$LIST" --tag=neverseen)
RC=$?
set -e
[ "$RC" -eq 0 ] && pass "unmatched tag exits 0" || fail "unmatched tag exits 0" "0" "$RC"
[ -z "$OUT" ] && pass "unmatched tag prints nothing" || fail "unmatched tag prints nothing" "(empty)" "$OUT"
rm -rf "$ROOT"

echo "-- Test: README.md and assets/ never appear in output --"
fresh_root
write_record "root" "real-record" "2026-01-01" "Real record" "pending" "tag-a"
echo "# Decisions" > "$ROOT/.craft/decisions/README.md"
mkdir -p "$ROOT/.craft/decisions/assets"
echo "not-a-record" > "$ROOT/.craft/decisions/assets/2026-01-01-decoy.md"
OUT=$(bash "$LIST")
COUNT=$(echo "$OUT" | grep -c "^SLUG=" || true)
[ "$COUNT" -eq 1 ] && pass "README.md and assets/ excluded from output" || fail "README.md and assets/ excluded from output" "1" "$COUNT"
echo "$OUT" | grep -q "README" && fail "no README leakage" "absent" "present" || pass "no README leakage"
echo "$OUT" | grep -q "decoy" && fail "no assets/ leakage" "absent" "present" || pass "no assets/ leakage"
rm -rf "$ROOT"

echo "=== decisions-capture.sh (Chunk 2) ==="
echo ""

echo "-- Test: a record with no approval lands in the root as pending --"
fresh_root
OUT=$(bash "$CAPTURE" "New pending idea" --tag=alpha --context="ctx body" --options="opts body" --decision="dec body" --consequences="cons body")
FILE=$(echo "$OUT" | tail -1)
[ -f "$FILE" ] && pass "capture writes a file" || fail "capture writes a file" "a file" "none"
DIRNAME=$(dirname "$FILE")
[ "$DIRNAME" = "$ROOT/.craft/decisions" ] && pass "record lands in the root" || fail "record lands in the root" "$ROOT/.craft/decisions" "$DIRNAME"
grep -q "^status: pending$" "$FILE" && pass "status: pending written" || fail "status: pending written" "status: pending" "$(grep '^status:' "$FILE" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: a record with an approval lands in approved/ as accepted with the quote rendered --"
fresh_root
OUT=$(bash "$CAPTURE" "New accepted idea" --tag=alpha --context="ctx body" --options="opts body" --decision="dec body" --consequences="cons body" --quote="the words, verbatim")
FILE=$(echo "$OUT" | tail -1)
DIRNAME=$(dirname "$FILE")
[ "$DIRNAME" = "$ROOT/.craft/decisions/approved" ] && pass "record lands in approved/" || fail "record lands in approved/" "$ROOT/.craft/decisions/approved" "$DIRNAME"
grep -q "^status: accepted$" "$FILE" && pass "status: accepted written" || fail "status: accepted written" "status: accepted" "$(grep '^status:' "$FILE" || echo missing)"
TODAY=$(date +%Y-%m-%d)
grep -qF "> \"the words, verbatim\" - $TODAY, session" "$FILE" && pass "quote rendered as quote, date, source" || fail "quote rendered as quote, date, source" "> \"the words, verbatim\" - $TODAY, session" "$(grep '^>' "$FILE" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: the approval line carries no name: --by= is rejected as unknown, store unchanged --"
fresh_root
set +e
ERR=$(bash "$CAPTURE" "Named attempt" --tag=alpha --context=c --options=o --decision=d --consequences=k --quote="the words" --by="Darin" 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "--by= is rejected as unknown" || fail "--by= is rejected as unknown" "non-zero" "$RC"
if [ -d "$ROOT/.craft/decisions" ]; then
  COUNT=$(find "$ROOT/.craft/decisions" -name "*.md" | wc -l | tr -d ' ')
else
  COUNT=0
fi
[ "$COUNT" -eq 0 ] && pass "store unchanged after rejected call" || fail "store unchanged after rejected call" "0" "$COUNT"
rm -rf "$ROOT"

echo "-- Test: the five section headings are written in README order --"
fresh_root
OUT=$(bash "$CAPTURE" "Heading order check" --tag=alpha --context="ctx body" --options="opts body" --decision="dec body" --consequences="cons body")
FILE=$(echo "$OUT" | tail -1)
HEADINGS=$(grep -E "^## " "$FILE" | tr '\n' ',')
EXPECTED="## Context,## Options considered,## Decision,## Consequences,## Approval,"
[ "$HEADINGS" = "$EXPECTED" ] && pass "five section headings in README order" || fail "five section headings in README order" "$EXPECTED" "$HEADINGS"
rm -rf "$ROOT"

echo "-- Test: the path is the last stdout line --"
fresh_root
OUT=$(bash "$CAPTURE" "Last line check" --tag=alpha --context=c --options=o --decision=d --consequences=k)
LAST=$(echo "$OUT" | tail -1)
[ -f "$LAST" ] && pass "last stdout line is the written path" || fail "last stdout line is the written path" "a file path" "$LAST"
rm -rf "$ROOT"

echo "-- Test: a second tag that exists on another record is accepted --"
fresh_root
write_record "root" "seed" "2026-01-01" "Seed" "pending" "known-tag"
OUT=$(bash "$CAPTURE" "Two tags" --tag=new-group --tag=known-tag --context=c --options=o --decision=d --consequences=k)
FILE=$(echo "$OUT" | tail -1)
grep -q "^tags: \[new-group, known-tag\]$" "$FILE" && pass "second tag accepted, both written" || fail "second tag accepted, both written" "tags: [new-group, known-tag]" "$(grep '^tags:' "$FILE" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: a second tag that exists nowhere exits non-zero naming the tag, and writes nothing --"
fresh_root
write_record "root" "seed2" "2026-01-01" "Seed 2" "pending" "known-tag"
set +e
ERR=$(bash "$CAPTURE" "Bad tags" --tag=new-group --tag=neverseen --context=c --options=o --decision=d --consequences=k 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "second unseen tag exits non-zero" || fail "second unseen tag exits non-zero" "non-zero" "$RC"
echo "$ERR" | grep -q "neverseen" && pass "error names the tag" || fail "error names the tag" "neverseen" "$ERR"
COUNT=$(find "$ROOT/.craft/decisions" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT" -eq 1 ] && pass "no new file written" || fail "no new file written" "1" "$COUNT"
rm -rf "$ROOT"

echo "-- Test: reopen rewrites the body in place at the same filename, date and status --"
fresh_root
write_record "approved" "reopen-target" "2026-02-01" "Reopen target" "accepted" "reopen-tag"
BEFORE_FILE="$ROOT/.craft/decisions/approved/2026-02-01-reopen-target.md"
OUT=$(bash "$CAPTURE" --reopen=2026-02-01-reopen-target --context="new ctx" --options="new opts" --decision="new dec" --consequences="new cons" --quote="reopen words")
FILE=$(echo "$OUT" | tail -1)
[ "$FILE" = "$BEFORE_FILE" ] && pass "reopen keeps the same filename" || fail "reopen keeps the same filename" "$BEFORE_FILE" "$FILE"
grep -q "^created: 2026-02-01$" "$FILE" && pass "reopen leaves created: untouched" || fail "reopen leaves created: untouched" "created: 2026-02-01" "$(grep '^created:' "$FILE" || echo missing)"
grep -q "^status: accepted$" "$FILE" && pass "reopen leaves status: untouched" || fail "reopen leaves status: untouched" "status: accepted" "$(grep '^status:' "$FILE" || echo missing)"
grep -qF "new dec" "$FILE" && pass "reopen rewrites the body" || fail "reopen rewrites the body" "new dec" "$(cat "$FILE")"
rm -rf "$ROOT"

echo "-- Test: reopen appends a Reopen line and leaves the original approval line intact --"
fresh_root
write_record "approved" "reopen-approval" "2026-02-02" "Reopen approval" "accepted" "reopen-tag"
FILE_PRE="$ROOT/.craft/decisions/approved/2026-02-02-reopen-approval.md"
ORIGINAL_LINE=$(grep '^> "approved"' "$FILE_PRE")
OUT=$(bash "$CAPTURE" --reopen=2026-02-02-reopen-approval --context=c --options=o --decision=d --consequences=k --quote="new words")
FILE=$(echo "$OUT" | tail -1)
grep -qF "$ORIGINAL_LINE" "$FILE" && pass "original approval line intact" || fail "original approval line intact" "$ORIGINAL_LINE" "$(cat "$FILE")"
grep -q '^> Reopen: "new words"' "$FILE" && pass "Reopen line appended" || fail "Reopen line appended" "> Reopen: \"new words\" - ..." "$(grep '^> Reopen' "$FILE" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: reopen on a claimed record prints one Claimed: line per claiming story, before the path --"
fresh_root
write_record "approved" "claimed-reopen" "2026-02-03" "Claimed reopen" "accepted" "reopen-tag"
write_story "claiming-story-a" "planning" "2026-02-03-claimed-reopen"
OUT=$(bash "$CAPTURE" --reopen=2026-02-03-claimed-reopen --context=c --options=o --decision=d --consequences=k --quote="new words")
LAST=$(echo "$OUT" | tail -1)
FIRST_LINE=$(echo "$OUT" | head -1)
[ "$FIRST_LINE" = "Claimed: claiming-story-a" ] && pass "Claimed: line printed before the path" || fail "Claimed: line printed before the path" "Claimed: claiming-story-a" "$FIRST_LINE"
[ -f "$LAST" ] && pass "path is still the last line on a claimed reopen" || fail "path is still the last line on a claimed reopen" "a file path" "$LAST"
rm -rf "$ROOT"

echo "-- Test: reopen on a crafted record writes nothing, names the shipping story, exits non-zero --"
fresh_root
write_record "approved" "crafted-reopen" "2026-02-04" "Crafted reopen" "accepted" "reopen-tag" "crafted" "shipping-story"
FILE="$ROOT/.craft/decisions/approved/2026-02-04-crafted-reopen.md"
BEFORE=$(cat "$FILE")
set +e
ERR=$(bash "$CAPTURE" --reopen=2026-02-04-crafted-reopen --context=c --options=o --decision=d --consequences=k --quote="new words" 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "reopen on a crafted record exits non-zero" || fail "reopen on a crafted record exits non-zero" "non-zero" "$RC"
echo "$ERR" | grep -q "shipping-story" && pass "error names the shipping story" || fail "error names the shipping story" "shipping-story" "$ERR"
AFTER=$(cat "$FILE")
[ "$BEFORE" = "$AFTER" ] && pass "crafted record is byte-identical after the refused reopen" || fail "crafted record is byte-identical after the refused reopen" "unchanged" "changed"
rm -rf "$ROOT"

echo "-- Test: capture never touches a story file --"
fresh_root
write_record "approved" "story-touch-check" "2026-02-05" "Story touch check" "accepted" "reopen-tag"
write_story "bystander-story" "planning" "2026-02-05-story-touch-check"
STORY_FILE="$ROOT/.craft/cycles/1-test/stories/bystander-story.md"
BEFORE_CONTENT=$(cat "$STORY_FILE")
bash "$CAPTURE" --reopen=2026-02-05-story-touch-check --context=c --options=o --decision=d --consequences=k --quote="new words" >/dev/null
AFTER_CONTENT=$(cat "$STORY_FILE")
[ "$BEFORE_CONTENT" = "$AFTER_CONTENT" ] && pass "story file untouched by capture" || fail "story file untouched by capture" "unchanged" "changed"
rm -rf "$ROOT"

echo "=== decisions-transition.sh (Chunk 3) ==="
echo ""

echo "-- Test: accept moves a pending root record into approved/ with status accepted and the quote appended --"
fresh_root
write_record "root" "accept-me" "2026-03-01" "Accept me" "pending" "tag-a"
SRC="$ROOT/.craft/decisions/2026-03-01-accept-me.md"
OUT=$(bash "$TRANSITION" 2026-03-01-accept-me accept --quote="accept words")
DEST="$ROOT/.craft/decisions/approved/2026-03-01-accept-me.md"
LAST=$(echo "$OUT" | tail -1)
[ "$LAST" = "$DEST" ] && pass "accept: path is the destination file" || fail "accept: path is the destination file" "$DEST" "$LAST"
[ -f "$DEST" ] && pass "accept: record present in approved/" || fail "accept: record present in approved/" "exists" "missing"
[ ! -f "$SRC" ] && pass "accept: record no longer in root" || fail "accept: record no longer in root" "removed" "still present"
grep -q "^status: accepted$" "$DEST" && pass "accept: status accepted" || fail "accept: status accepted" "status: accepted" "$(grep '^status:' "$DEST" || echo missing)"
grep -qF '> "accept words"' "$DEST" && pass "accept: quote appended" || fail "accept: quote appended" "> \"accept words\" ..." "$(grep '^>' "$DEST" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: accept without --quote exits non-zero and leaves the record in the root --"
fresh_root
write_record "root" "no-quote" "2026-03-02" "No quote" "pending" "tag-a"
SRC="$ROOT/.craft/decisions/2026-03-02-no-quote.md"
BEFORE=$(cat "$SRC")
set +e
ERR=$(bash "$TRANSITION" 2026-03-02-no-quote accept 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "accept without --quote exits non-zero" || fail "accept without --quote exits non-zero" "non-zero" "$RC"
[ -f "$SRC" ] && pass "accept without --quote leaves the record in root" || fail "accept without --quote leaves the record in root" "present" "missing"
AFTER=$(cat "$SRC")
[ "$BEFORE" = "$AFTER" ] && pass "accept without --quote leaves the record byte-identical" || fail "accept without --quote leaves the record byte-identical" "unchanged" "changed"
rm -rf "$ROOT"

echo "-- Test: decline moves a pending root record into archive/ with status declined --"
fresh_root
write_record "root" "decline-me" "2026-03-03" "Decline me" "pending" "tag-a"
OUT=$(bash "$TRANSITION" 2026-03-03-decline-me decline --quote="decline words")
DEST="$ROOT/.craft/decisions/archive/2026-03-03-decline-me.md"
[ -f "$DEST" ] && pass "decline: record present in archive/" || fail "decline: record present in archive/" "exists" "missing"
grep -q "^status: declined$" "$DEST" && pass "decline: status declined" || fail "decline: status declined" "status: declined" "$(grep '^status:' "$DEST" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: deprecate moves an approved record into archive/ with status deprecated --"
fresh_root
write_record "approved" "deprecate-me" "2026-03-04" "Deprecate me" "accepted" "tag-a"
OUT=$(bash "$TRANSITION" 2026-03-04-deprecate-me deprecate --quote="deprecate words")
DEST="$ROOT/.craft/decisions/archive/2026-03-04-deprecate-me.md"
[ -f "$DEST" ] && pass "deprecate: record present in archive/" || fail "deprecate: record present in archive/" "exists" "missing"
grep -q "^status: deprecated$" "$DEST" && pass "deprecate: status deprecated" || fail "deprecate: status deprecated" "status: deprecated" "$(grep '^status:' "$DEST" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: deprecate on a pending record exits non-zero with a wrong-status message --"
fresh_root
write_record "root" "still-pending" "2026-03-05" "Still pending" "pending" "tag-a"
set +e
ERR=$(bash "$TRANSITION" 2026-03-05-still-pending deprecate --quote="x" 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "deprecate on a pending record exits non-zero" || fail "deprecate on a pending record exits non-zero" "non-zero" "$RC"
echo "$ERR" | grep -qi "pending" && pass "deprecate on a pending record names the wrong status" || fail "deprecate on a pending record names the wrong status" "mentions pending" "$ERR"
rm -rf "$ROOT"

echo "-- Test: craft writes disposition: crafted and appends the story to stories: in one act, without moving the file --"
fresh_root
write_record "approved" "craft-me" "2026-03-06" "Craft me" "accepted" "tag-a"
FILE="$ROOT/.craft/decisions/approved/2026-03-06-craft-me.md"
OUT=$(bash "$TRANSITION" 2026-03-06-craft-me craft --story=story-one)
LAST=$(echo "$OUT" | tail -1)
[ "$LAST" = "$FILE" ] && pass "craft: path unchanged (no move)" || fail "craft: path unchanged (no move)" "$FILE" "$LAST"
grep -q "^disposition: crafted$" "$FILE" && pass "craft: disposition: crafted written" || fail "craft: disposition: crafted written" "disposition: crafted" "$(grep '^disposition:' "$FILE" || echo missing)"
grep -q "^stories: \[story-one\]$" "$FILE" && pass "craft: stories: appended" || fail "craft: stories: appended" "stories: [story-one]" "$(grep '^stories:' "$FILE" || echo missing)"
echo "$OUT" | grep -q "^CHANGED=1$" && pass "craft: first flip emits CHANGED=1" || fail "craft: first flip emits CHANGED=1" "CHANGED=1" "$(echo "$OUT" | grep '^CHANGED=' || echo missing)"
rm -rf "$ROOT"

echo "-- Test: craft inserts disposition: and stories: directly after tags: when both are absent --"
fresh_root
write_record "approved" "insert-order" "2026-03-07" "Insert order" "accepted" "tag-a"
FILE="$ROOT/.craft/decisions/approved/2026-03-07-insert-order.md"
bash "$TRANSITION" 2026-03-07-insert-order craft --story=story-two >/dev/null
FIELDS=$(sed -n '/^---$/,/^---$/p' "$FILE" | sed -E 's/^([a-z]+):.*$/\1/' | grep -v '^---$')
EXPECTED=$(printf 'type\nstatus\ncreated\nsource\ntags\ndisposition\nstories')
[ "$FIELDS" = "$EXPECTED" ] && pass "craft inserts disposition/stories right after tags" || fail "craft inserts disposition/stories right after tags" "$EXPECTED" "$FIELDS"
rm -rf "$ROOT"

echo "-- Test: craft on an already-crafted record appends a second story, emits CHANGED=0, exits 0, and does not duplicate an existing story name --"
fresh_root
write_record "approved" "already-crafted-t" "2026-03-08" "Already crafted t" "accepted" "tag-a" "crafted" "story-one"
FILE="$ROOT/.craft/decisions/approved/2026-03-08-already-crafted-t.md"
OUT=$(bash "$TRANSITION" 2026-03-08-already-crafted-t craft --story=story-two)
echo "$OUT" | grep -q "^CHANGED=0$" && pass "already-crafted second story: CHANGED=0" || fail "already-crafted second story: CHANGED=0" "CHANGED=0" "$(echo "$OUT" | grep '^CHANGED=' || echo missing)"
grep -q "^stories: \[story-one, story-two\]$" "$FILE" && pass "already-crafted second story: both stories present" || fail "already-crafted second story: both stories present" "stories: [story-one, story-two]" "$(grep '^stories:' "$FILE" || echo missing)"
set +e
RC=0
bash "$TRANSITION" 2026-03-08-already-crafted-t craft --story=story-two >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] && pass "already-crafted repeat call still exits 0" || fail "already-crafted repeat call still exits 0" "0" "$RC"
DUP=$(grep '^stories:' "$FILE")
[ "$DUP" = "stories: [story-one, story-two]" ] && pass "already-crafted: repeating an existing story does not duplicate it" || fail "already-crafted: repeating an existing story does not duplicate it" "stories: [story-one, story-two]" "$DUP"
rm -rf "$ROOT"

echo "-- Test: craft on a pending record exits non-zero with a still-pending message distinct from the not-found message --"
fresh_root
write_record "root" "craft-pending" "2026-03-09" "Craft pending" "pending" "tag-a"
set +e
ERR_PENDING=$(bash "$TRANSITION" 2026-03-09-craft-pending craft --story=x 2>&1 1>/dev/null)
RC_PENDING=$?
ERR_NOTFOUND=$(bash "$TRANSITION" 2026-01-01-does-not-exist craft --story=x 2>&1 1>/dev/null)
RC_NOTFOUND=$?
set -e
[ "$RC_PENDING" -ne 0 ] && pass "craft on a pending record exits non-zero" || fail "craft on a pending record exits non-zero" "non-zero" "$RC_PENDING"
[ "$RC_NOTFOUND" -ne 0 ] && pass "craft on an unknown slug exits non-zero" || fail "craft on an unknown slug exits non-zero" "non-zero" "$RC_NOTFOUND"
[ "$ERR_PENDING" != "$ERR_NOTFOUND" ] && pass "still-pending message differs from not-found message" || fail "still-pending message differs from not-found message" "distinct" "identical: $ERR_PENDING"
rm -rf "$ROOT"

echo "-- Test: craft on an archived record exits non-zero with an archived message --"
fresh_root
write_record "archive" "craft-archived" "2026-03-10" "Craft archived" "declined" "tag-a"
set +e
ERR=$(bash "$TRANSITION" 2026-03-10-craft-archived craft --story=x 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "craft on an archived record exits non-zero" || fail "craft on an archived record exits non-zero" "non-zero" "$RC"
echo "$ERR" | grep -qi "archive" && pass "craft on an archived record names archive" || fail "craft on an archived record names archive" "mentions archive" "$ERR"
rm -rf "$ROOT"

echo "-- Test: an unknown slug exits non-zero naming the slug --"
fresh_root
set +e
ERR=$(bash "$TRANSITION" 2099-01-01-nonexistent-slug accept --quote="x" 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "unknown slug exits non-zero" || fail "unknown slug exits non-zero" "non-zero" "$RC"
echo "$ERR" | grep -q "2099-01-01-nonexistent-slug" && pass "unknown slug error names the slug" || fail "unknown slug error names the slug" "2099-01-01-nonexistent-slug" "$ERR"
rm -rf "$ROOT"

echo "-- Test: every success prints TITLE=, CHANGED=, and the path last --"
fresh_root
write_record "root" "stdout-shape" "2026-03-11" "Stdout shape" "pending" "tag-a"
OUT=$(bash "$TRANSITION" 2026-03-11-stdout-shape accept --quote="x")
LINES=$(echo "$OUT" | wc -l | tr -d ' ')
LINE1=$(echo "$OUT" | sed -n '1p')
LINE2=$(echo "$OUT" | sed -n '2p')
LINE3=$(echo "$OUT" | sed -n '3p')
echo "$LINE1" | grep -q "^TITLE=Stdout shape$" && pass "stdout: TITLE= first" || fail "stdout: TITLE= first" "TITLE=Stdout shape" "$LINE1"
echo "$LINE2" | grep -q "^CHANGED=" && pass "stdout: CHANGED= second" || fail "stdout: CHANGED= second" "CHANGED=..." "$LINE2"
[ -f "$LINE3" ] && pass "stdout: path is the last line" || fail "stdout: path is the last line" "a file path" "$LINE3"
[ "$LINES" -eq 3 ] && pass "stdout: exactly three lines" || fail "stdout: exactly three lines" "3" "$LINES"
rm -rf "$ROOT"

echo "-- Test: a record whose body quotes status: in prose is not corrupted by any transition --"
fresh_root
write_record "root" "fence-trap-t" "2026-03-12" "Fence trap t" "pending" "tag-a" "" "" \
  "status: pending | accepted | declined - the enum, quoted here on purpose."
FILE_SRC="$ROOT/.craft/decisions/2026-03-12-fence-trap-t.md"
OUT=$(bash "$TRANSITION" 2026-03-12-fence-trap-t accept --quote="x")
DEST="$ROOT/.craft/decisions/approved/2026-03-12-fence-trap-t.md"
grep -q "^status: accepted$" "$DEST" && pass "fence trap: frontmatter status flipped correctly" || fail "fence trap: frontmatter status flipped correctly" "status: accepted" "$(grep '^status:' "$DEST" || echo missing)"
grep -qF "status: pending | accepted | declined - the enum, quoted here on purpose." "$DEST" && pass "fence trap: body prose line survives untouched" || fail "fence trap: body prose line survives untouched" "prose line present" "$(cat "$DEST")"
rm -rf "$ROOT"

echo "-- Test: accept into an unwritable approved/ exits non-zero and leaves the root record byte-identical --"
fresh_root
write_record "root" "unwritable-dest" "2026-03-13" "Unwritable dest" "pending" "tag-a"
SRC="$ROOT/.craft/decisions/2026-03-13-unwritable-dest.md"
BEFORE=$(cat "$SRC")
mkdir -p "$ROOT/.craft/decisions/approved"
chmod 000 "$ROOT/.craft/decisions/approved"
set +e
ERR=$(bash "$TRANSITION" 2026-03-13-unwritable-dest accept --quote="x" 2>&1 1>/dev/null)
RC=$?
set -e
chmod 755 "$ROOT/.craft/decisions/approved"
[ "$RC" -ne 0 ] && pass "unwritable destination exits non-zero" || fail "unwritable destination exits non-zero" "non-zero" "$RC"
[ -f "$SRC" ] && pass "unwritable destination leaves the source in place" || fail "unwritable destination leaves the source in place" "present" "missing"
AFTER=$(cat "$SRC")
[ "$BEFORE" = "$AFTER" ] && pass "unwritable destination leaves the source byte-identical" || fail "unwritable destination leaves the source byte-identical" "unchanged" "changed"
rm -rf "$ROOT"

echo "-- Test: a slug found in two rooms exits non-zero naming both rooms --"
fresh_root
write_record "root" "double-room" "2026-03-14" "Double room" "pending" "tag-a"
write_record "approved" "double-room" "2026-03-14" "Double room" "accepted" "tag-a"
set +e
ERR=$(bash "$TRANSITION" 2026-03-14-double-room accept --quote="x" 2>&1 1>/dev/null)
RC=$?
set -e
[ "$RC" -ne 0 ] && pass "slug in two rooms exits non-zero" || fail "slug in two rooms exits non-zero" "non-zero" "$RC"
echo "$ERR" | grep -q "root" && echo "$ERR" | grep -q "approved" && pass "slug in two rooms names both rooms" || fail "slug in two rooms names both rooms" "mentions root and approved" "$ERR"
rm -rf "$ROOT"

# ── Chunk 4: the flip in complete-story.sh ──────────────────────────────

# write_flip_story CSV_OR_EMPTY HAS_FIELD(0|1) [NAME]
# Builds a full .craft/ tree (cycle dir, .state, .global-state) around one
# story so complete-story.sh can run against it end to end.
write_flip_story() {
  local csv="$1" has_field="${2:-1}" name="${3:-flip-story}"
  mkdir -p "$ROOT/.craft/cycles/1-flip-cycle/stories"
  STORY_FILE="$ROOT/.craft/cycles/1-flip-cycle/stories/1-${name}.md"
  {
    echo "---"
    echo "name: $name"
    echo "title: \"Flip Story\""
    echo "status: active"
    echo "priority: medium"
    echo "created: 2026-01-01"
    echo "updated: 2026-01-01"
    echo "cycle: flip-cycle"
    echo "story_number: 1"
    echo "chunks_total: 1"
    echo "chunks_complete: 0"
    echo "current_chunk: 1"
    if [ "$has_field" = "1" ]; then
      echo "decisions: [$csv]"
    fi
    echo "---"
    echo ""
    echo "# Story: Flip Story"
    echo ""
    echo "## Spark"
    echo "Test story for the flip."
    echo ""
    echo "## Chunks"
    echo "### Chunk 1: only chunk"
    echo "**Goal:** test."
  } > "$STORY_FILE"

  cat > "$ROOT/.craft/.global-state" <<EOF
ACTIVE_CYCLE="1-flip-cycle"
CURRENT_STORY="$name"
PLANNING_CYCLE=""
LAST_ACTIVITY=""
EOF

  mkdir -p "$ROOT/.craft/cycles/1-flip-cycle"
  cat > "$ROOT/.craft/cycles/1-flip-cycle/.state" <<EOF
CYCLE_NAME="flip-cycle"
CYCLE_STATUS="active"
CURRENT_STORY="$name"
CURRENT_CHUNK="1"
TOTAL_CHUNKS="1"
LAST_VALIDATION=""
LAST_CHECKPOINT=""
EOF
}

# run_flip — runs complete-story.sh against $STORY_FILE from $ROOT, leaving
# FLIP_STDOUT, FLIP_STDERR and FLIP_RC set.
run_flip() {
  local stderr_file="$ROOT/.flip-stderr"
  set +e
  FLIP_STDOUT=$(cd "$ROOT" && bash "$COMPLETE_STORY" "$STORY_FILE" 2>"$stderr_file")
  FLIP_RC=$?
  set -e
  FLIP_STDERR=$(cat "$stderr_file" 2>/dev/null || true)
}

echo "-- Test: in a repo that gitignores .craft/, the flip appends nothing and prints no warning --"
fresh_root
(cd "$ROOT" && git init -q && git config user.email "t@example.com" && git config user.name "t" \
  && echo ".craft/" > .gitignore && git add -A && git commit -q -m init --no-verify --allow-empty)
write_record "approved" "gitignore-record" "2026-01-01" "Gitignore record" "accepted" "tag-a"
write_flip_story "2026-01-01-gitignore-record" 1
run_flip
[ "$FLIP_RC" -eq 0 ] && pass "gitignored .craft/: exits 0" || fail "gitignored .craft/: exits 0" "0" "$FLIP_RC"
echo "$FLIP_STDOUT" | grep -q "^Crafted: Gitignore record$" && pass "gitignored .craft/: still flips and prints Crafted" || fail "gitignored .craft/: still flips and prints Crafted" "Crafted: Gitignore record" "$FLIP_STDOUT"
echo "$FLIP_STDERR" | grep -qi "gitignored" && fail "gitignored .craft/: no gitignore warning leaks in" "(no gitignore warning)" "$FLIP_STDERR" || pass "gitignored .craft/: no gitignore warning leaks in"
rm -rf "$ROOT"

echo "-- Test: a story with no decisions: field completes with output and exit code identical to today's --"
fresh_root
write_flip_story "" 0
run_flip
[ "$FLIP_RC" -eq 0 ] && pass "no decisions field: exits 0" || fail "no decisions field: exits 0" "0" "$FLIP_RC"
echo "$FLIP_STDOUT" | grep -q "^Crafted:" && fail "no decisions field: no Crafted line" "(none)" "$FLIP_STDOUT" || pass "no decisions field: no Crafted line"
echo "$FLIP_STDERR" | grep -q "decision record" && fail "no decisions field: no decision warning" "(none)" "$FLIP_STDERR" || pass "no decisions field: no decision warning"
echo "$FLIP_STDOUT" | grep -q "^Story completed: $STORY_FILE$" && pass "no decisions field: still reports story completed" || fail "no decisions field: still reports story completed" "Story completed: $STORY_FILE" "$FLIP_STDOUT"
rm -rf "$ROOT"

echo "-- Test: a story with decisions: [] completes with no warning and no record touched --"
fresh_root
write_record "approved" "untouched-record" "2026-01-01" "Untouched record" "accepted" "tag-a"
BEFORE=$(cat "$ROOT/.craft/decisions/approved/2026-01-01-untouched-record.md")
write_flip_story "" 1
run_flip
[ "$FLIP_RC" -eq 0 ] && pass "decisions: []: exits 0" || fail "decisions: []: exits 0" "0" "$FLIP_RC"
echo "$FLIP_STDOUT" | grep -q "^Crafted:" && fail "decisions: []: no Crafted line" "(none)" "$FLIP_STDOUT" || pass "decisions: []: no Crafted line"
AFTER=$(cat "$ROOT/.craft/decisions/approved/2026-01-01-untouched-record.md")
[ "$BEFORE" = "$AFTER" ] && pass "decisions: []: record untouched" || fail "decisions: []: record untouched" "unchanged" "changed"
rm -rf "$ROOT"

echo "-- Test: each listed record is flipped to disposition: crafted with the story's name appended to stories: --"
fresh_root
write_record "approved" "flip-a" "2026-01-01" "Flip A" "accepted" "tag-a"
write_record "approved" "flip-b" "2026-01-02" "Flip B" "accepted" "tag-a"
write_flip_story "2026-01-01-flip-a, 2026-01-02-flip-b" 1
run_flip
[ "$FLIP_RC" -eq 0 ] && pass "two records flip: exits 0" || fail "two records flip: exits 0" "0" "$FLIP_RC"
FILE_A="$ROOT/.craft/decisions/approved/2026-01-01-flip-a.md"
FILE_B="$ROOT/.craft/decisions/approved/2026-01-02-flip-b.md"
grep -q "^disposition: crafted$" "$FILE_A" && pass "record A flipped to crafted" || fail "record A flipped to crafted" "disposition: crafted" "$(grep '^disposition:' "$FILE_A" || echo missing)"
grep -q "^stories: \[flip-story\]$" "$FILE_A" && pass "record A gains the story's name" || fail "record A gains the story's name" "stories: [flip-story]" "$(grep '^stories:' "$FILE_A" || echo missing)"
grep -q "^disposition: crafted$" "$FILE_B" && pass "record B flipped to crafted" || fail "record B flipped to crafted" "disposition: crafted" "$(grep '^disposition:' "$FILE_B" || echo missing)"
grep -q "^stories: \[flip-story\]$" "$FILE_B" && pass "record B gains the story's name" || fail "record B gains the story's name" "stories: [flip-story]" "$(grep '^stories:' "$FILE_B" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: one Crafted: <title> line is printed per newly-flipped record --"
fresh_root
write_record "approved" "count-a" "2026-01-01" "Count A" "accepted" "tag-a"
write_record "approved" "count-b" "2026-01-02" "Count B" "accepted" "tag-a"
write_flip_story "2026-01-01-count-a, 2026-01-02-count-b" 1
run_flip
COUNT=$(echo "$FLIP_STDOUT" | grep -c "^Crafted: " || true)
[ "$COUNT" -eq 2 ] && pass "one Crafted line per flipped record" || fail "one Crafted line per flipped record" "2" "$COUNT"
echo "$FLIP_STDOUT" | grep -q "^Crafted: Count A$" && pass "Crafted line names Count A" || fail "Crafted line names Count A" "Crafted: Count A" "$FLIP_STDOUT"
echo "$FLIP_STDOUT" | grep -q "^Crafted: Count B$" && pass "Crafted line names Count B" || fail "Crafted line names Count B" "Crafted: Count B" "$FLIP_STDOUT"
rm -rf "$ROOT"

echo "-- Test: Crafted: lines are present when the commit is aborted, and precede the deferred abort message --"
fresh_root
write_record "approved" "abort-record" "2026-01-01" "Abort record" "accepted" "tag-a"
write_flip_story "2026-01-01-abort-record" 1
printf 'story: some-other-story\n' > "$ROOT/.craft/.commit-manifest"
set +e
COMBINED=$(cd "$ROOT" && bash "$COMPLETE_STORY" "$STORY_FILE" 2>&1)
RC=$?
set -e
[ "$RC" -eq 1 ] && pass "aborted commit + flip: exits 1" || fail "aborted commit + flip: exits 1" "1" "$RC"
echo "$COMBINED" | grep -q "^Crafted: Abort record$" && pass "aborted commit: Crafted line still printed" || fail "aborted commit: Crafted line still printed" "Crafted: Abort record" "$COMBINED"
CRAFTED_LINE_NUM=$(echo "$COMBINED" | grep -n "^Crafted: Abort record$" | head -1 | cut -d: -f1)
ABORT_LINE_NUM=$(echo "$COMBINED" | grep -n "commit was aborted" | head -1 | cut -d: -f1)
[ -n "$CRAFTED_LINE_NUM" ] && [ -n "$ABORT_LINE_NUM" ] && [ "$CRAFTED_LINE_NUM" -lt "$ABORT_LINE_NUM" ] && pass "Crafted line precedes the deferred abort message" || fail "Crafted line precedes the deferred abort message" "Crafted before Error" "Crafted@$CRAFTED_LINE_NUM Error@$ABORT_LINE_NUM"
rm -rf "$ROOT"

echo "-- Test: an already-crafted record prints no Crafted: line but still gains the story name --"
fresh_root
write_record "approved" "already-crafted" "2026-01-01" "Already crafted" "accepted" "tag-a" "crafted" "earlier-story"
write_flip_story "2026-01-01-already-crafted" 1
run_flip
[ "$FLIP_RC" -eq 0 ] && pass "already-crafted: exits 0" || fail "already-crafted: exits 0" "0" "$FLIP_RC"
echo "$FLIP_STDOUT" | grep -q "^Crafted:" && fail "already-crafted: no Crafted line" "(none)" "$FLIP_STDOUT" || pass "already-crafted: no Crafted line"
FILE="$ROOT/.craft/decisions/approved/2026-01-01-already-crafted.md"
grep -q "^stories: \[earlier-story, flip-story\]$" "$FILE" && pass "already-crafted: story name appended alongside the earlier one" || fail "already-crafted: story name appended alongside the earlier one" "stories: [earlier-story, flip-story]" "$(grep '^stories:' "$FILE" || echo missing)"
rm -rf "$ROOT"

echo "-- Test: an unresolvable slug warns to stderr, flips the resolvable records, and exits 1 --"
fresh_root
write_record "approved" "resolvable" "2026-01-01" "Resolvable" "accepted" "tag-a"
write_flip_story "2026-01-01-resolvable, 2026-01-01-does-not-exist" 1
run_flip
[ "$FLIP_RC" -eq 1 ] && pass "unresolvable slug: exits 1" || fail "unresolvable slug: exits 1" "1" "$FLIP_RC"
echo "$FLIP_STDERR" | grep -q "^Warning: decision record '2026-01-01-does-not-exist' could not be flipped to crafted" && pass "unresolvable slug: warns naming the slug" || fail "unresolvable slug: warns naming the slug" "Warning: decision record '2026-01-01-does-not-exist' ..." "$FLIP_STDERR"
echo "$FLIP_STDERR" | grep -q -- "- continuing$" && pass "unresolvable slug: warning ends with - continuing" || fail "unresolvable slug: warning ends with - continuing" "- continuing" "$FLIP_STDERR"
echo "$FLIP_STDOUT" | grep -q "^Crafted: Resolvable$" && pass "unresolvable slug: the resolvable record still flips" || fail "unresolvable slug: the resolvable record still flips" "Crafted: Resolvable" "$FLIP_STDOUT"
rm -rf "$ROOT"

echo "-- Test: after an unresolvable slug the cycle state, global state and event log are still written --"
fresh_root
write_flip_story "2026-01-01-does-not-exist" 1
run_flip
[ "$FLIP_RC" -eq 1 ] && pass "unresolvable slug (non-stranding): exits 1" || fail "unresolvable slug (non-stranding): exits 1" "1" "$FLIP_RC"
source "$ROOT/.craft/.global-state"
[ -z "$CURRENT_STORY" ] && pass "unresolvable slug: global CURRENT_STORY cleared" || fail "unresolvable slug: global CURRENT_STORY cleared" "" "$CURRENT_STORY"
unset CURRENT_STORY
source "$ROOT/.craft/cycles/1-flip-cycle/.state"
[ -z "$CURRENT_STORY" ] && pass "unresolvable slug: cycle CURRENT_STORY cleared" || fail "unresolvable slug: cycle CURRENT_STORY cleared" "" "$CURRENT_STORY"
[ -f "$ROOT/.craft/cycles/1-flip-cycle/.events/1-flip-story.jsonl" ] && pass "unresolvable slug: event log written" || fail "unresolvable slug: event log written" "present" "missing"
rm -rf "$ROOT"

echo "-- Test: the flip-failure error message is distinct from the commit-abort message --"
fresh_root
write_flip_story "2026-01-01-does-not-exist" 1
run_flip
FLIP_ONLY_MSG=$(echo "$FLIP_STDERR" | grep "decision record(s) could not be flipped" || true)
[ -n "$FLIP_ONLY_MSG" ] && ! echo "$FLIP_ONLY_MSG" | grep -q "commit was aborted" && pass "flip-only error message names decision records, not the commit" || fail "flip-only error message names decision records, not the commit" "distinct message" "$FLIP_ONLY_MSG"
rm -rf "$ROOT"

echo "-- Test: when the commit is aborted AND a slug fails, both error lines print and the exit is 1 --"
fresh_root
write_flip_story "2026-01-01-does-not-exist" 1
printf 'story: some-other-story\n' > "$ROOT/.craft/.commit-manifest"
run_flip
[ "$FLIP_RC" -eq 1 ] && pass "both failures: exits 1" || fail "both failures: exits 1" "1" "$FLIP_RC"
echo "$FLIP_STDERR" | grep -q "commit was aborted" && pass "both failures: commit-abort message prints" || fail "both failures: commit-abort message prints" "commit was aborted" "$FLIP_STDERR"
echo "$FLIP_STDERR" | grep -q "decision record(s) could not be flipped" && pass "both failures: flip-failure message prints" || fail "both failures: flip-failure message prints" "decision record(s) could not be flipped" "$FLIP_STDERR"
rm -rf "$ROOT"

echo "-- Test: when the run exits at the deferred abort with no decisions carried, no Crafted: lines are printed --"
fresh_root
write_flip_story "" 0
printf 'story: some-other-story\n' > "$ROOT/.craft/.commit-manifest"
run_flip
[ "$FLIP_RC" -eq 1 ] && pass "abort with no decisions: exits 1" || fail "abort with no decisions: exits 1" "1" "$FLIP_RC"
echo "$FLIP_STDOUT" | grep -q "^Crafted:" && fail "abort with no decisions: no Crafted line printed" "(none)" "$FLIP_STDOUT" || pass "abort with no decisions: no Crafted line printed"
rm -rf "$ROOT"

echo ""
echo "-- Summary --"
echo "Total:  $TOTAL"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
