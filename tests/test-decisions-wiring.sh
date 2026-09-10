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
    "Draw the Shelf (list | render shelf)" [shape=box];
    "Selection in words -> list filters" [shape=box];
    "Draw the archive under the Shelf" [shape=box];
    "Draw the question card" [shape=box];
    "Draw the decision card" [shape=box];
    "Draw the reopen card (diff against the file)" [shape=box];
    "Draw the retire card (claimed by / shipped by)" [shape=box];
    "User'"'"'s move?" [shape=diamond];
    "Card came from the root and changed?" [shape=diamond];
    "Filed pending in the root" [shape=doublecircle];
    "Filed as law in approved/" [shape=doublecircle];
    "Filed declined in archive/" [shape=doublecircle];
    "Rewritten in place" [shape=doublecircle];
    "Retired to archive/" [shape=doublecircle];
    "Refused: crafted law is frozen" [shape=box];

    "Draw the Shelf (list | render shelf)" -> "Selection in words -> list filters";
    "Selection in words -> list filters" -> "Draw the archive under the Shelf" [label="'"'"'declined'"'"', '"'"'retired'"'"'"];
    "Selection in words -> list filters" -> "Draw the question card" [label="pending, lettered options"];
    "Selection in words -> list filters" -> "Draw the decision card" [label="pending, dashed options"];
    "Selection in words -> list filters" -> "Draw the reopen card (diff against the file)" [label="law + words that change its text"];
    "Selection in words -> list filters" -> "Draw the retire card (claimed by / shipped by)" [label="'"'"'retire ...'"'"'"];

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

echo "-- Test: verbatim relay of the render script's stdout, and no box-drawing character --"
grep_pass_below_fence "file instructs verbatim relay of decisions-render.sh's stdout" "relay.*stdout|stdout.*relay"
grep_pass_below_fence "file says untouched/unmodified relay, never re-typed/re-flowed/summarised" "untouched|unmodified"
if grep -qP '[\x{250C}\x{2502}\x{2514}\x{251C}]' "$CMD" 2>/dev/null || grep -q '[┌│└├]' "$CMD"; then
  fail "no box-drawing character anywhere in the file" "absent" "found"
else
  pass "no box-drawing character anywhere in the file"
fi

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

echo "-- Test: both write scripts named, no direct record-writing instruction --"
grep_pass_below_fence "decisions-capture.sh named" "decisions-capture\.sh"
grep_pass_below_fence "decisions-transition.sh named" "decisions-transition\.sh"
grep_fail_below_fence "no direct record-writing instruction (a ## Context/## Decision heredoc)" '^## (Context|Decision|Consequences|Approval)$'
grep_fail_below_fence "no direct .craft/decisions/ write path" '> *"?\.craft/decisions/'

echo "-- Test: no graduation flow below the frontmatter fence --"
grep_fail_below_fence "no 'graduate' verb below the frontmatter fence" '[Gg]raduate'

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

echo "-- Test: the archive is reached in words and printed under the Shelf, never unasked --"
grep_pass_below_fence "archive reached in words (e.g. 'what did we decline')" "what did we decline|what did we retire"
grep_pass_below_fence "archive prints under the Shelf" "under the Shelf"
grep_pass_below_fence "nothing prints below the Shelf unless asked" "unless.*asked|nothing.*unasked|never.*unasked"

echo "-- Test: craft-notebook.md's when_to_use ends with the ruled Not-for line, and nothing else changed --"
NOTEBOOK="$REPO/commands/craft-notebook.md"
LAST_LINE_OF_WTU="$(awk '/^when_to_use: \|/{p=1; next} p && /^argument-hint:/{exit} p{last=$0} END{print last}' "$NOTEBOOK")"
if [ "$LAST_LINE_OF_WTU" = "  Not for: product rulings (decisions) - those belong to /craft:decisions." ]; then
  pass "notebook when_to_use ends with the ruled Not-for line, verbatim"
else
  fail "notebook when_to_use ends with the ruled Not-for line, verbatim" "  Not for: product rulings (decisions) - those belong to /craft:decisions." "$LAST_LINE_OF_WTU"
fi
NOTEBOOK_DIFF_LINES="$(git -C "$REPO" diff HEAD -- commands/craft-notebook.md | grep -cE '^[+-][^+-]' || true)"
# Exactly one added line (the Not-for clause) and no removed content lines.
ADDED="$(git -C "$REPO" diff HEAD -- commands/craft-notebook.md | grep -cE '^\+[^+]' || true)"
REMOVED="$(git -C "$REPO" diff HEAD -- commands/craft-notebook.md | grep -cE '^-[^-]' || true)"
if [ "$REMOVED" -eq 0 ] && [ "$ADDED" -eq 1 ]; then
  pass "notebook diff is exactly one added line, nothing removed"
else
  fail "notebook diff is exactly one added line, nothing removed" "1 added, 0 removed" "$ADDED added, $REMOVED removed"
fi

echo "-- Test: /craft:decisions is present in decision-tree, DESIGN.md and README.md; DESIGN.md says 34 commands --"
grep -q '/craft:decisions' "$REPO/docs/decision-tree.md" && pass "/craft:decisions in docs/decision-tree.md" || fail "/craft:decisions in docs/decision-tree.md"
grep -q '/craft:decisions' "$REPO/DESIGN.md" && pass "/craft:decisions in DESIGN.md" || fail "/craft:decisions in DESIGN.md"
grep -q '/craft:decisions' "$REPO/README.md" && pass "/craft:decisions in README.md" || fail "/craft:decisions in README.md"
grep -q '34 commands' "$REPO/DESIGN.md" && pass "DESIGN.md says 34 commands" || fail "DESIGN.md says 34 commands"

echo ""
echo "-- Summary --"
echo "Total:  $TOTAL"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
