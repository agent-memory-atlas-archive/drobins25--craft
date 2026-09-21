#!/bin/bash
# test-decisions-wiring.sh — Doc-grep coverage for /craft:decisions wiring
#
# Mirrors tests/test-dial-wiring.sh's shape: the command file is a doc, not
# code, so its load-bearing rules are frozen by grepping for the literal
# sentences the story's Contracts require, plus a byte-for-byte diff of the
# routing digraph against a copy embedded here (never read from the story
# file at test time, since story files move when a cycle completes).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/.."
CMD="$REPO/commands/craft-decisions.md"

PASS_COUNT=0; FAIL_COUNT=0; TOTAL=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    Expected: $2"; [ -n "${3:-}" ] && echo "    Got:      $3"; }

echo "=== test-decisions-wiring.sh ==="
echo ""

if [ ! -e "$CMD" ]; then
  fail "commands/craft-decisions.md exists" "file present" "absent"
  echo ""
  echo "-- Summary --"
  echo "Total:  $TOTAL"
  echo "Passed: $PASS_COUNT"
  echo "Failed: $FAIL_COUNT"
  exit 1
fi

# ---------------------------------------------------------------------
# Frontmatter: exactly four keys, in order, values match the ruled record
# ---------------------------------------------------------------------
echo "-- Test: frontmatter is exactly the four ruled keys, in order --"
FRONTMATTER="$(awk '/^---$/{n++; next} n==1{print} n==2{exit}' "$CMD")"
TOP_KEYS="$(printf '%s\n' "$FRONTMATTER" | grep -oE '^[a-zA-Z_-]+:' | sed 's/:$//')"
EXPECTED_KEYS=$'name\ndescription\nwhen_to_use\nargument-hint'
if [ "$TOP_KEYS" = "$EXPECTED_KEYS" ]; then
  pass "frontmatter keys are name, description, when_to_use, argument-hint, in order, and no others"
else
  fail "frontmatter keys are name, description, when_to_use, argument-hint, in order, and no others" "$EXPECTED_KEYS" "$TOP_KEYS"
fi

echo "-- Test: description and when_to_use match the frontmatter record, whitespace-normalized --"
RECORD="$REPO/.craft/decisions/approved/2026-09-05-the-decisions-skill-frontmatter.md"
norm() { tr '\n' ' ' <<<"$1" | tr -s ' ' | sed 's/^ *//; s/ *$//'; }

RECORD_DESC="$(sed -n '/^  description: "The Shelf/,/into a cycle\."/p' "$RECORD")"
CMD_DESC="$(sed -n '/^description: "The Shelf/,/into a cycle\."/p' "$CMD")"
if [ "$(norm "$RECORD_DESC")" = "$(norm "$CMD_DESC")" ]; then
  pass "description matches the frontmatter record (whitespace-normalized)"
else
  fail "description matches the frontmatter record (whitespace-normalized)" "$(norm "$RECORD_DESC")" "$(norm "$CMD_DESC")"
fi

RECORD_WTU="$(sed -n '/^  when_to_use: |/,/^  argument-hint:/p' "$RECORD" | sed '1d;$d')"
CMD_WTU="$(sed -n '/^when_to_use: |/,/^argument-hint:/p' "$CMD" | sed '1d;$d')"
if [ "$(norm "$RECORD_WTU")" = "$(norm "$CMD_WTU")" ]; then
  pass "when_to_use matches the frontmatter record (whitespace-normalized)"
else
  fail "when_to_use matches the frontmatter record (whitespace-normalized)" "$(norm "$RECORD_WTU")" "$(norm "$CMD_WTU")"
fi

# ---------------------------------------------------------------------
# The digraph, embedded here rather than read from the story file
# ---------------------------------------------------------------------
EXPECTED_DIGRAPH='```dot
digraph decisions {
    "Draw the Shelf (list | view shelf)" [shape=box];
    "Selection in words -> list filters" [shape=box];
    "Draw the archive under the Shelf" [shape=box];
    "Draw the question card" [shape=box];
    "Draw the decision card" [shape=box];
    "Draw the reopen card (diff against the file)" [shape=box];
    "Draw the retire card (claimed by / shipped by)" [shape=box];
    "Draw the match drawer (decisions-view.sh match)" [shape=box];
    "No match: answer in words" [shape=box];
    "User'"'"'s move?" [shape=diamond];
    "Card came from the root and changed?" [shape=diamond];
    "Filed pending in the root" [shape=doublecircle];
    "Filed as law in approved/" [shape=doublecircle];
    "Filed declined in archive/" [shape=doublecircle];
    "Rewritten in place" [shape=doublecircle];
    "Retagged in place" [shape=doublecircle];
    "Retired to archive/" [shape=doublecircle];
    "Refused: crafted law is frozen" [shape=box];

    "Draw the Shelf (list | view shelf)" -> "Selection in words -> list filters";
    "Selection in words -> list filters" -> "Draw the archive under the Shelf" [label="'"'"'declined'"'"', '"'"'retired'"'"'"];
    "Selection in words -> list filters" -> "Draw the question card" [label="pending, lettered options"];
    "Selection in words -> list filters" -> "Draw the decision card" [label="pending, dashed options"];
    "Selection in words -> list filters" -> "Draw the reopen card (diff against the file)" [label="law + words that change its text"];
    "Selection in words -> list filters" -> "Draw the retire card (claimed by / shipped by)" [label="'"'"'retire ...'"'"'"];
    "Selection in words -> list filters" -> "Retagged in place" [label="words naming record(s) and a tag: transition retag --tag="];
    "Selection in words -> list filters" -> "Draw the match drawer (decisions-view.sh match)" [label="several blocks matched"];
    "Draw the match drawer (decisions-view.sh match)" -> "Selection in words -> list filters" [label="user names one: resolves as a single match"];
    "Selection in words -> list filters" -> "No match: answer in words" [label="zero blocks matched"];
    "No match: answer in words" -> "Draw the decision card" [label="offer a fresh card, new group"];

    "A ruling in conversation" -> "Draw the question card" [label="live fork"];
    "A ruling in conversation" -> "Draw the decision card" [label="no fork"];

    "Draw the question card" -> "User'"'"'s move?";
    "Draw the decision card" -> "User'"'"'s move?";
    "Draw the reopen card (diff against the file)" -> "User'"'"'s move?";
    "Draw the retire card (claimed by / shipped by)" -> "User'"'"'s move?";

    "User'"'"'s move?" -> "Draw the question card" [label="words on a question card: redraw"];
    "User'"'"'s move?" -> "Draw the decision card" [label="a letter picks an option: redraw as decision"];
    "User'"'"'s move?" -> "Draw the decision card" [label="words on a decision card: redraw"];
    "User'"'"'s move?" -> "Draw the reopen card (diff against the file)" [label="words on a reopen card: redraw the diff"];
    "User'"'"'s move?" -> "Card came from the root and changed?" [label="approve / keep pending / decline (letter or plain words)"];
    "User'"'"'s move?" -> "Rewritten in place" [label="a) on a reopen card: capture --reopen --quote"];
    "User'"'"'s move?" -> "Refused: crafted law is frozen" [label="a) on a reopen card, record is crafted"];
    "User'"'"'s move?" -> "Draw the retire card (claimed by / shipped by)" [label="words say retire"];
    "User'"'"'s move?" -> "Draw the retire card (claimed by / shipped by)" [label="words on a retire card: redraw (nothing to reshape)"];
    "User'"'"'s move?" -> "Draw the reopen card (diff against the file)" [label="words on a retire card that change the text: draw the reopen card"];
    "User'"'"'s move?" -> "Retired to archive/" [label="a) on a retire card: transition deprecate --quote, then offer slug removal to planning/ready claimants"];
    "Selection in words -> list filters" -> "Refused: crafted law is frozen" [label="'"'"'retire ...'"'"' on crafted law: no card, the ruled words"];
    "Refused: crafted law is frozen" -> "Draw the decision card" [label="offer a fresh card"];

    "Card came from the root and changed?" -> "Filed as law in approved/" [label="fresh, approve: capture --quote"];
    "Card came from the root and changed?" -> "Filed pending in the root" [label="fresh, keep pending: capture"];
    "Card came from the root and changed?" -> "Filed declined in archive/" [label="fresh, decline: capture, transition decline --quote"];
    "Card came from the root and changed?" -> "Filed as law in approved/" [label="parked, changed, approve: capture --reopen (root), transition accept --quote"];
    "Card came from the root and changed?" -> "Filed as law in approved/" [label="parked, unchanged, approve: transition accept --quote"];
    "Card came from the root and changed?" -> "Filed pending in the root" [label="parked, changed, keep pending: capture --reopen (root)"];
    "Card came from the root and changed?" -> "Filed pending in the root" [label="parked, unchanged, keep pending: nothing, say so"];
    "Card came from the root and changed?" -> "Filed declined in archive/" [label="parked, decline: transition decline --quote"];
}
```'

echo "-- Test: the digraph is embedded verbatim as a fenced dot block --"
# Extraction: the first ```dot ... ``` block in the file.
ACTUAL_DIGRAPH="$(awk '
  /^```dot$/ { inblock=1; print; next }
  inblock && /^```$/ { print; exit }
  inblock { print }
' "$CMD")"
if [ "$ACTUAL_DIGRAPH" = "$EXPECTED_DIGRAPH" ]; then
  pass "digraph block is byte-identical to the story's Flow section"
else
  fail "digraph block is byte-identical to the story's Flow section" "(embedded copy)" "(diff — see below)"
  diff <(printf '%s\n' "$EXPECTED_DIGRAPH") <(printf '%s\n' "$ACTUAL_DIGRAPH") | head -20
fi

echo "-- Test: every doublecircle's incoming edges name capture or transition --"
DOUBLECIRCLES=(
  "Filed pending in the root"
  "Filed as law in approved/"
  "Filed declined in archive/"
  "Rewritten in place"
  "Retagged in place"
  "Retired to archive/"
)
for node in "${DOUBLECIRCLES[@]}"; do
  EDGES="$(printf '%s\n' "$ACTUAL_DIGRAPH" | grep -F -- "-> \"$node\"" || true)"
  if [ -z "$EDGES" ]; then
    fail "doublecircle '$node' has incoming edges naming a script" "at least one edge" "none found"
  elif printf '%s\n' "$EDGES" | grep -qiE 'capture|transition'; then
    pass "doublecircle '$node' incoming edges name a script"
  else
    fail "doublecircle '$node' incoming edges name a script" "capture or transition mentioned" "$EDGES"
  fi
done

# ---------------------------------------------------------------------
# Straightforward doc-grep contracts
# ---------------------------------------------------------------------
grep_pass() { # $1=description $2=pattern (extended regex, -i off by default)
  if grep -qE -- "$2" "$CMD"; then pass "$1"; else fail "$1" "$2" "not found"; fi
}
grep_pass_below_fence() { # asserts pattern appears in the body below the closing frontmatter fence
  # The body is joined onto one line first, since prose in the command file
  # hand-wraps at arbitrary widths and a phrase can legitimately straddle
  # two source lines.
  local desc="$1" pattern="$2"
  local body
  body="$(awk '/^---$/{n++; next} n>=2{print}' "$CMD" | tr '\n' ' ' | tr -s ' ')"
  if printf '%s' "$body" | grep -qE -- "$pattern"; then pass "$desc"; else fail "$desc" "$pattern" "not found below fence"; fi
}
grep_fail_below_fence() { # asserts pattern does NOT appear below the closing frontmatter fence
  local desc="$1" pattern="$2"
  local body
  body="$(awk '/^---$/{n++; next} n>=2{print}' "$CMD")"
  if printf '%s\n' "$body" | grep -qE -- "$pattern"; then
    fail "$desc" "absent" "found: $(printf '%s\n' "$body" | grep -E -- "$pattern" | head -1)"
  else
    pass "$desc"
  fi
}

echo "-- Test: the card's own relay phrases are gone, and the rail characters are present --"
grep_fail_below_fence "file no longer instructs a verbatim relay of the card's stdout" "relay its stdout untouched"
grep_fail_below_fence "file no longer says relays its stdout untouched" "relays its stdout untouched"
grep_fail_below_fence "file no longer says relayed exactly as printed" "relayed exactly as printed"
grep_fail_below_fence "file no longer says never re-typed of the card" "never re-typed"
grep_fail_below_fence "file no longer says re-flowed" "re-flowed"
grep_fail_below_fence "file no longer says hand-padded" "hand-padded"
grep_pass_below_fence "the question, decision, reopen and retire card boxes draw from the view's data" "decision, reopen and retire card boxes all draw the same way"
grep_fail_below_fence "the reopen card box is no longer named as a still-framed holdout" "reopen card box still draws its own framed diff"

echo "-- Test: the reopen diff's MARK= key colours red for removed, green for added --"
grep_pass_below_fence "removed rows draw red" "removed row draws red"
grep_pass_below_fence "added rows draw green" "added row draws green"
grep_pass_below_fence "decisions-view.sh emits the marker only, colour is drawn by the command file" "emits the marker only.*colour is drawn here|MARK=.*colour"

echo "-- Test: the command file carries the rail characters in its drawing rule, and requires them absent from script stdout (inverted: the old test forbade them here) --"
grep_pass_below_fence "### The drawing rule section is present" "### The drawing rule"
if grep -qP '[\x{250C}\x{2502}\x{2514}\x{251C}]' "$CMD" 2>/dev/null || grep -q '[┌│└├]' "$CMD"; then
  pass "the command file carries the rail characters ┌ │ ├ └ - it is where Claude reads the shape from"
else
  fail "the command file carries the rail characters ┌ │ ├ └ - it is where Claude reads the shape from" "present" "absent"
fi
grep_pass_below_fence "the drawing rule says no right edge" "no right edge"
grep_pass_below_fence "the drawing rule says no fixed width" "no fixed width"
grep_pass_below_fence "the drawing rule says quote lines print exactly as the file holds them, never re-wrapped" "print exactly as the file holds them"
grep_pass_below_fence "the drawing rule says no box-drawing character in any script's stdout" "No box-drawing character in any script's stdout"
grep_pass_below_fence "the drawing rule carries the ruled 'Done records never get a row' (2026-09-03-craft-decisions-renders-the-shelf)" "Done records never get a row"

echo "-- Test: AskUserQuestion is forbidden; answers are typed into the prompt --"
AUQ_LINES="$(grep -h "AskUserQuestion" "$CMD" || true)"
if [ -z "$AUQ_LINES" ]; then
  fail "AskUserQuestion mentioned only under a prohibition" "at least one prohibition line" "zero mentions"
else
  BAD="$(printf '%s\n' "$AUQ_LINES" | grep -iv "never" || true)"
  if [ -z "$BAD" ]; then pass "every AskUserQuestion mention sits on a 'never' line"; else fail "every AskUserQuestion mention sits on a 'never' line" "all lines contain never" "$BAD"; fi
fi
grep_pass_below_fence "file says answers are typed into the prompt" "typed into the prompt"

echo "-- Test: words that name exactly one move perform it; two or ambiguous redraws --"
grep_pass_below_fence "one writing move performs it after any pick or reshape" "exactly one writing move.*perform|perform.*exactly one writing move|plainly names exactly one writing move"
grep_pass_below_fence "two moves or an ambiguous one redraws and asks" "two.*moves.*redraw|redraw.*two.*moves|ambiguous.*redraw"

echo "-- Test: Consequences follow the chosen option, never named by letter once dashed --"
grep_pass_below_fence "Consequences are the chosen option's" "Consequences.*chosen option|chosen option.*Consequences"
grep_pass_below_fence "once options are dashes, other options named by what they are, never by letter" "never.*by letter|by letter.*never"

echo "-- Test: Decision authored as the ruling, then the fixed Ideas label, non-binding --"
grep_pass_below_fence "Decision authored as the ruling in the human's terms" "ruling in the (human|user)'s terms|the terms the human agreed to"
grep_pass_below_fence "fixed label 'Ideas to consider, not ruled:' present" "Ideas to consider, not ruled:"
grep_pass_below_fence "two to four lines taken from the first draft, never invented" "two to four lines"
grep_pass_below_fence "the ideas block is non-binding" "not (law|ruled|binding)"

echo "-- Test: one ruling per card, Context verified against disk, whole-card reshape with reopen exception --"
grep_pass_below_fence "one ruling per card" "[Oo]ne ruling per card"
grep_pass_below_fence "Context verified against disk at presentation" "[Cc]ontext.*verified against disk"
grep_pass_below_fence "words redraw the whole card" "redraw the whole card|whole card"
grep_pass_below_fence "reopen redraws the diff instead" "reopen.*redraw.*diff|redraw.*diff.*reopen"
grep_pass_below_fence "a redraw on words is a script draw, never a retype" "script draw, never a retype"
grep_pass_below_fence "a changed pending card redraws via the pending face with section flags" "variant=pending --file=<path>.*--consequences="

echo "-- Test: the four card-caliber rules --"
grep_pass_below_fence "card stands alone for a reader who was not in the room" "not in the room"
grep_pass_below_fence "Context states the situation as it stands on disk today" "as it stands on disk today"
grep_pass_below_fence "options are complete alternatives in plain words" "complete alternative in plain words"
grep_pass_below_fence "consequences name each option by what it cost, not its label" "why not the other options"

echo "-- Test: both write scripts named, no direct record-writing instruction --"
grep_pass_below_fence "decisions-capture.sh named" "decisions-capture\.sh"
grep_pass_below_fence "decisions-transition.sh named" "decisions-transition\.sh"
grep_fail_below_fence "no direct record-writing instruction (a ## Context/## Decision heredoc)" '^## (Context|Decision|Consequences|Approval)$'
grep_fail_below_fence "no direct .craft/decisions/ write path" '> *"?\.craft/decisions/'

echo "-- Test: no graduation flow below the frontmatter fence --"
grep_fail_below_fence "no 'graduate' verb below the frontmatter fence" '[Gg]raduate'

echo "-- Test: the move's routing, source-by-tag, and receipt wording --"
grep_pass_below_fence "the move's routing line names decisions-transition.sh retag --tag=" "decisions-transition\.sh.*retag|retag --tag="
grep_pass_below_fence "source-by-tag is resolved through decisions-list.sh --tag=<source> --no-scan, not a script flag" "decisions-list\.sh --tag=<source>"
grep_pass_below_fence "the receipt names what moved and where: 'Okay - moved <slug> to <tag>'" "Okay - moved <slug> to <tag>"
grep_pass_below_fence "a multi-record receipt reads 'Okay - moved N to <tag>'" "Okay - moved N to <tag>"
grep_pass_below_fence "the target group's rows follow the receipt, typed from decisions-list.sh --tag= output" "group's rows.*decisions-list\.sh --tag=<target>"
grep_pass_below_fence "the retag receipt is drawn as one Shelf drawer via decisions-view.sh group" "decisions-view\.sh group"
grep_pass_below_fence "', new group' is earned by the check run before the write" "before the (move|write)"
grep_pass_below_fence "an all-already-there move prints its own no-op line" "nothing to move"
grep_fail_below_fence "no --from-tag= flag is named anywhere in the file" "--from-tag"

echo "-- Test: no story template is touched by this story --"
for f in commands/craft-story-new.md commands/references/cycle-design/default-mode.md commands/references/cycle-design/roadmap-mode.md; do
  if git -C "$REPO" diff --quiet HEAD -- "$f" 2>/dev/null; then
    pass "$f unchanged vs HEAD"
  else
    fail "$f unchanged vs HEAD" "no diff" "diff present"
  fi
done

echo "-- Test: the fresh-decline path is documented as two script calls, per the digraph's own edge label --"
if printf '%s\n' "$ACTUAL_DIGRAPH" | grep -qF 'label="fresh, decline: capture, transition decline --quote"'; then
  pass "digraph edge names fresh decline as capture then transition decline"
else
  fail "digraph edge names fresh decline as capture then transition decline" 'label="fresh, decline: capture, transition decline --quote"' "not found"
fi

echo "-- Test: the retire path — scanned list, crafted refusal, claimed/shipped, deprecate, slug offer --"
grep_pass_below_fence "retire calls decisions-list.sh --slug= with the story scan on, before the card" "decisions-list\.sh --slug=.*scan|scan.*decisions-list\.sh --slug="
grep_pass_below_fence "crafted retire refuses with the ruled words and draws no card" "already built.*shipped it|That one's already built"
grep_pass_below_fence "crafted retire offers a fresh decision card" "fresh decision card"
grep_pass_below_fence "claimed by / shipped by follows disposition" "claimed by|shipped by"
grep_pass_below_fence "retire on a) calls decisions-transition.sh deprecate" "decisions-transition\.sh.*deprecate|transition.*deprecate"
grep_pass_below_fence "planning or ready claimants get a slug-removal offer" "planning.*ready|planning or ready"
grep_pass_below_fence "an active claimant is told to read it again and keeps its slug" "read it again"

echo "-- Test: the reopen path — scanned list + claimed-by BEFORE the card, Claimed: relay after write --"
grep_pass_below_fence "reopen or retire card calls decisions-list.sh --slug= with the scan on before drawing the card" "[Bb]efore a reopen or a retire card.*decisions-list\.sh --slug=|decisions-list\.sh --slug=.*[Bb]efore a reopen"
grep_pass_below_fence "capture's Claimed: lines are relayed after the write" "Claimed:.*relay.*after the write|Claimed:.*this command relays after the write"

echo "-- Test: every write path ends in a receipt line; no-op keep-pending says so --"
grep_pass_below_fence "receipt verbs Approved/Kept pending/Declined/Retired" "Approved:.*Kept pending:.*Declined:.*Retired:|Kept pending:"
grep_pass_below_fence "a no-op keep-pending prints its own line" "Nothing to save - still on the Shelf\."

echo "-- Test: a parked card is documented with three letters and the reshape-then-accept path, per the digraph --"
grep_pass_below_fence "parked card offers a) approve, b) keep pending, c) decline" "keep pending"
if printf '%s\n' "$ACTUAL_DIGRAPH" | grep -qF 'label="parked, changed, approve: capture --reopen (root), transition accept --quote"'; then
  pass "digraph edge names a changed a) as reshape (capture --reopen) then transition accept"
else
  fail "digraph edge names a changed a) as reshape (capture --reopen) then transition accept" 'label="parked, changed, approve: capture --reopen (root), transition accept --quote"' "not found"
fi
grep_pass_below_fence "an unchanged b) writes nothing and says so" "[Nn]othing.*[Uu]nchanged|unchanged.*nothing"
grep_pass_below_fence "a parked fork returns question-first" "question state|draws.*question"

echo "-- Test: a fresh card with a live fork is question-then-decision; no alternatives is decision only --"
grep_pass_below_fence "live fork drawn first in the question state, redrawn decision after the letter" "question state.*decision state|live fork.*question"
grep_pass_below_fence "no real alternatives drawn straight in the decision state" "no real alternative|straight.*decision state"
grep_pass_below_fence "the question card's keep-pending letter is capture with no quote" "capture.*no quote|keep pending.*capture"

echo "-- Test: lettered options only while a fork is live, dashed once chosen --"
grep_pass_below_fence "options lettered (a)(b)(c) with one Proposed: while a fork is live" '\(a\), \(b\), \(c\)|lettered.*Proposed'
grep_pass_below_fence "options re-authored as dashes once a letter is picked" 'dashe[sd]'

echo "-- Test: a crafted reopen and a crafted retire are both refused and routed to a fresh decision card --"
if printf '%s\n' "$ACTUAL_DIGRAPH" | grep -qF 'label="a) on a reopen card, record is crafted"' \
  && printf '%s\n' "$ACTUAL_DIGRAPH" | grep -qF 'label="offer a fresh card"'; then
  pass "digraph routes a crafted reopen to Refused: crafted law is frozen, then offers a fresh card"
else
  fail "digraph routes a crafted reopen to Refused: crafted law is frozen, then offers a fresh card" "both edge labels present" "missing"
fi
grep_pass_below_fence "crafted retire offers a fresh decision card too, the same offer" "fresh decision card, the same as a crafted reopen"
grep_pass_below_fence "crafted reopen refuses at a) with the ruled words, the diff carried forward" "happy to draw it up with these changes"
grep_pass_below_fence "crafted reopen seeds the fresh card from its own diff and never relays the script's error line" "seeded from the reopen's own diff.*never relayed as the answer"

echo "-- Test: the archive is reached in words and printed under the Shelf, never unasked --"
grep_pass_below_fence "archive reached in words (e.g. 'what did we decline')" "what did we decline|what did we retire"
grep_pass_below_fence "archive prints under the Shelf" "under the Shelf"
grep_pass_below_fence "nothing prints below the Shelf unless asked" "unless.*asked|nothing.*unasked|never.*unasked"

echo "-- Test: craft-notebook.md's when_to_use ends with the ruled Not-for line --"
NOTEBOOK="$REPO/commands/craft-notebook.md"
LAST_LINE_OF_WTU="$(awk '/^when_to_use: \|/{p=1; next} p && /^argument-hint:/{exit} p{last=$0} END{print last}' "$NOTEBOOK")"
if [ "$LAST_LINE_OF_WTU" = "  Not for: product rulings (decisions) - those belong to /craft:decisions." ]; then
  pass "notebook when_to_use ends with the ruled Not-for line, verbatim"
else
  fail "notebook when_to_use ends with the ruled Not-for line, verbatim" "  Not for: product rulings (decisions) - those belong to /craft:decisions." "$LAST_LINE_OF_WTU"
fi

echo "-- Test: /craft:decisions is present in decision-tree, DESIGN.md and README.md; DESIGN.md says 34 commands --"
grep -q '/craft:decisions' "$REPO/docs/decision-tree.md" && pass "/craft:decisions in docs/decision-tree.md" || fail "/craft:decisions in docs/decision-tree.md"
grep -q '/craft:decisions' "$REPO/DESIGN.md" && pass "/craft:decisions in DESIGN.md" || fail "/craft:decisions in DESIGN.md"
grep -q '/craft:decisions' "$REPO/README.md" && pass "/craft:decisions in README.md" || fail "/craft:decisions in README.md"
grep -q '34 commands' "$REPO/DESIGN.md" && pass "DESIGN.md says 34 commands" || fail "DESIGN.md says 34 commands"

echo "-- Test: a selection headed for a card resolves to exactly one record before anything draws --"
grep_pass_below_fence "the desk routes on the block count before drawing anything" "routes on that count before drawing anything"
grep_pass_below_fence "a zero-block filtered list is never piped into decisions-view.sh shelf" "never piped into .decisions-view\.sh shelf."
grep_pass_below_fence "several matches route to decisions-view.sh match" "decisions-view\.sh match --words="
grep_pass_below_fence "the drawer's answer maps back to the block's own SLUG=" "maps back to the .SLUG=. of the block that row came from"
grep_pass_below_fence "the rule governs a selection headed for a card only" "selection headed for a card only"

echo "-- Test: the no-match answer names the filter, the nearest group and a count of the rest, offers a fresh card, draws no frame --"
grep_pass_below_fence "the no-match answer names the filter back" "names the filter back"
grep_pass_below_fence "the no-match answer names the nearest group by spelling" "nearest group by spelling"
grep_pass_below_fence "the no-match answer counts the remaining groups, never a full dump" "count of the remaining groups.*never a full dump|never a full dump.*count of the remaining groups"
grep_pass_below_fence "the no-match answer offers a fresh card announced as a new group" "fresh card tagged with it, announced as a NEW GROUP"
grep_pass_below_fence "the no-match answer draws no frame" "no frame.*drawn|answered in words, no frame"

echo "-- Test: the drawing rule carries a match-drawer entry with the extended key band and the two-space record line --"
grep_pass_below_fence "the drawing rule names the header band's count-and-words form" "MATCH .<words>."
grep_pass_below_fence "the drawing rule extends the key band with the archived glyph" "× archived"
grep_pass_below_fence "the drawing rule puts record lines at two spaces, HEAD= not ROW=" "HEAD=.*two spaces after the rail|two spaces after the rail.*not a .ROW=. line"
grep_pass_below_fence "the drawing rule says the drawer has no group divider, strip or count" "no group divider, no strip and no count"

echo "-- Test: the alignment check's agent prompt cites no decision record by slug --"
# A slug names a record in THIS repo's store. A user's project has none, and the
# same prompt tells the agent where records live and to report one it cannot find,
# so a citation there can read as a rule with no authority behind it.
ALIGNMENT_REF="$REPO/commands/references/alignment-check.md"
ALIGNMENT_SLUGS="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z][a-z0-9-]+' "$ALIGNMENT_REF" || true)"
if [ -z "$ALIGNMENT_SLUGS" ]; then
  pass "alignment-check.md names no decision record by slug"
else
  fail "alignment-check.md names no decision record by slug" "none" "$ALIGNMENT_SLUGS"
fi
grep -q "the older is cited as superseded" "$ALIGNMENT_REF" && pass "the superseding rule itself survives, stated on its own authority" || fail "the superseding rule itself survives, stated on its own authority" "present" "absent"

echo "-- Test: the command file names no decision record by slug --"
CMD_SLUGS="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z][a-z0-9-]+' "$CMD" || true)"
if [ -z "$CMD_SLUGS" ]; then
  pass "commands/craft-decisions.md names no decision record by slug"
else
  fail "commands/craft-decisions.md names no decision record by slug" "none" "$CMD_SLUGS"
fi

echo ""
echo "-- Summary --"
echo "Total:  $TOTAL"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
