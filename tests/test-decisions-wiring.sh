#!/bin/bash
# test-decisions-wiring.sh - Structural coverage for /craft:decisions wiring
#
# The command file's routing rule now lives ONLY in its dot graph: a
# question is a diamond, an answer is a one-word arrow label, a
# destination is a node. This test never holds a byte-pinned copy of that
# graph - it parses it and asserts structure (labels defined, fan-out
# bounded, every node reachable, no script call hiding in prose) the same
# way evals/check-edges.sh does, and reuses that script's own edge and
# node grammar deliberately, so the two parsers never drift apart by
# reading the fence two different ways.
#
# The prose below the graph is technique only (the drawing rule,
# card-authoring rules, receipts) - what survives it is a capped, named
# list of literal phrases, not a growing pile of ad hoc greps.

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
# The routing graph, parsed structurally (never held as a literal copy)
# ---------------------------------------------------------------------
echo "-- Test: the routing graph's structure (labels, definitions, fan-out, reachability, no hidden routing) --"
# The parser is written to a scratch file first, rather than piped in via a
# heredoc directly inside a $(...) substitution - bash 3.2 (macOS's system
# bash) mishandles an apostrophe in a quoted heredoc's body when that
# heredoc sits inside a command substitution, and several sentences below
# have one.
GRAPH_SCRIPT="$(mktemp)"
trap 'rm -f "$GRAPH_SCRIPT"' EXIT
cat > "$GRAPH_SCRIPT" <<'PYEOF'
import re
import sys

command_file = sys.argv[1]
text = open(command_file).read()

SCRIPTS = ["decisions-list.sh", "decisions-view.sh", "decisions-capture.sh", "decisions-transition.sh"]


def out(status, desc, expected="", got=""):
    line = f"{status}: {desc}"
    if expected:
        line += f"\n    Expected: {expected}"
    if got:
        line += f"\n    Got:      {got}"
    print(line)


# --- locate the routing fence (same selection rule as evals/check-edges.sh:
# the fence whose own first line is "digraph decisions {", not the first
# fence in the file - the hard-gate block above it is a plain, non-dot
# fence, so this only matters if that ever changes) -----------------------
BACKTICKS = chr(96) * 3
fence_match = None
for m in re.finditer(BACKTICKS + r"dot\n(.*?)\n" + BACKTICKS, text, re.DOTALL):
    if m.group(1).lstrip().startswith("digraph decisions {"):
        fence_match = m
        break
if fence_match is None:
    out("FAIL", "a fenced dot block starting with 'digraph decisions {' exists")
    sys.exit(0)
fence_body = fence_match.group(1)
above_fence = text[: fence_match.start()]
below_fence = text[fence_match.end():]

# --- parse edges and nodes (same grammar as evals/check-edges.sh) --------
def parse_edges(body):
    edges = []
    for raw in body.splitlines():
        line = raw.strip()
        if '" -> "' not in line:
            continue
        left, _, right = line.partition('" -> "')
        if not left.startswith('"'):
            continue
        src = left[1:]
        m = re.match(r'^(?P<dst>.*?)"\s*(\[label="(?P<label>.*)"\])?;\s*$', right)
        if not m:
            continue
        edges.append((src, m.group("dst"), m.group("label") or ""))
    return edges


def parse_nodes(body):
    nodes = {}
    for raw in body.splitlines():
        line = raw.strip()
        if '" -> "' in line:
            continue
        m = re.match(r'^"(?P<name>(?:[^"\\]|\\.)*)"\s*\[(?P<attrs>[^\]]*)\]\s*;\s*$', line)
        if not m:
            continue
        nodes[m.group("name")] = m.group("attrs")
    return nodes


edges = parse_edges(fence_body)
node_attrs = parse_nodes(fence_body)


def shape_of(attrs):
    m = re.search(r"shape\s*=\s*(\w+)", attrs or "")
    return m.group(1) if m else None


shapes = {name: shape_of(attrs) for name, attrs in node_attrs.items()}
diamonds = [n for n, s in shapes.items() if s == "diamond"]
doublecircles = [n for n, s in shapes.items() if s == "doublecircle"]

# --- definitions section: "## Words the graph uses" up to the next "## " -
def_section_match = re.search(
    r"## Words the graph uses\n(.*?)\n## ", text, re.DOTALL
)
def_section = def_section_match.group(1) if def_section_match else ""

TERM_RE = re.compile(r"^- \*\*(.+?)\*\* - ", re.MULTILINE)
defined_terms = set()
for term_group in TERM_RE.findall(def_section):
    for term in term_group.split("/"):
        defined_terms.add(term.strip().lower())

def_text_lower = def_section.lower()

# --- 1: every arrow leaving a diamond is labelled and its label defined -
undefined_labels = []
unlabelled_diamond_exits = []
fanout_violations = []
for d in diamonds:
    exits = [e for e in edges if e[0] == d]
    if len(exits) > 3:
        fanout_violations.append((d, len(exits)))
    for src, dst, label in exits:
        if not label:
            unlabelled_diamond_exits.append((src, dst))
        elif label.lower() not in defined_terms:
            undefined_labels.append((src, label))

if unlabelled_diamond_exits:
    out("FAIL", "every arrow leaving a diamond carries a label", "labelled", str(unlabelled_diamond_exits))
else:
    out("PASS", "every arrow leaving a diamond carries a label")

if undefined_labels:
    out("FAIL", "every label leaving a diamond has a definitions bullet", "defined", str(undefined_labels))
else:
    out("PASS", "every label leaving a diamond has a definitions bullet")

if fanout_violations:
    out("FAIL", "no diamond asks more than three ways", "<= 3 exits", str(fanout_violations))
else:
    out("PASS", "no diamond asks more than three ways")

# --- 2: every word of every diamond's own name has a definitions bullet -
# Fuzzy on purpose: a diamond name uses ordinary English around its
# technical words ("Which face does the record call for?"), and a
# definition is written in its own sentence, not as a repeated token - so
# a word is "covered" when a same-rooted word (its first 4 letters, or the
# whole word if shorter) appears anywhere in the definitions section
# (heading terms or body prose alike). This still catches the conductor's
# original catch (a word like "changed" with no definition anywhere would
# not match any 4-letter root in the section) without demanding the exact
# grammatical form of every connector.
STOPWORDS = {
    "the", "a", "an", "with", "on", "or", "for", "is", "are", "do", "does",
    "how", "many", "which", "named", "ask", "call", "as", "at", "of", "to",
    "in", "card", "cards", "decision", "question", "reopen",
}

diamond_word_gaps = []
for d in diamonds:
    words = re.findall(r"[a-zA-Z']+", d.lower())
    for w in words:
        if len(w) <= 2 or w in STOPWORDS:
            continue
        root = w[:4] if len(w) >= 4 else w
        if root not in def_text_lower:
            diamond_word_gaps.append((d, w))

if diamond_word_gaps:
    out("FAIL", "every word of every diamond's own name has a definitions bullet", "covered", str(diamond_word_gaps))
else:
    out("PASS", "every word of every diamond's own name has a definitions bullet")

# --- 3: reachability from the entry double circles -----------------------
adjacency = {}
for src, dst, _ in edges:
    adjacency.setdefault(src, []).append(dst)

reachable = set()
frontier = list(doublecircles[:2]) if len(doublecircles) >= 2 else list(doublecircles)
# Entry points are "Command invoked" and "Ruling in conversation" by name,
# not merely "the first two doublecircles" - falls back to all doublecircles
# only if those two aren't present, so a reordering of the node block never
# silently changes which nodes count as entries.
entries = [n for n in ("Command invoked", "Ruling in conversation") if n in shapes]
frontier = entries if entries else frontier
seen = set(frontier)
queue = list(frontier)
while queue:
    node = queue.pop()
    reachable.add(node)
    for nxt in adjacency.get(node, []):
        if nxt not in seen:
            seen.add(nxt)
            queue.append(nxt)

declared = set(shapes.keys())
unreachable = sorted(declared - reachable)
if unreachable:
    out("FAIL", "every declared node is reachable from an entry double circle", "none", str(unreachable))
else:
    out("PASS", "every declared node is reachable from an entry double circle")

# --- 4: no routing hides in an arrow label --------------------------------
bad_labels = [
    (s, d, l) for s, d, l in edges
    if l and (".sh" in l or re.search(r"(^|\s)-{1,2}[A-Za-z]", l))
]
if bad_labels:
    out("FAIL", "no arrow label contains a .sh name or a - flag", "none", str(bad_labels))
else:
    out("PASS", "no arrow label contains a .sh name or a - flag")

# --- 5: script calls are plaintext nodes, and only script calls are ------
mismatched_shape = [
    n for n in shapes
    if any(s in n for s in SCRIPTS) and shapes[n] != "plaintext"
]
mismatched_prefix = [
    n for n, s in shapes.items()
    if s == "plaintext" and not any(n.startswith(s2) for s2 in SCRIPTS)
]
if mismatched_shape or mismatched_prefix:
    out(
        "FAIL",
        "every node naming a decisions script is shape=plaintext and every plaintext node's name begins with one",
        "consistent",
        str(mismatched_shape + mismatched_prefix),
    )
else:
    out("PASS", "every node naming a decisions script is shape=plaintext and every plaintext node's name begins with one")

# --- 6: the never-bend rules are a hard gate, and the one octagon is red -
hard_gate_blocks = re.findall(r"<HARD-GATE>\n(.*?)\n</HARD-GATE>", text, re.DOTALL)
if len(hard_gate_blocks) != 1:
    out("FAIL", "exactly one <HARD-GATE> block", "1", str(len(hard_gate_blocks)))
else:
    lines = [l for l in hard_gate_blocks[0].splitlines() if l.strip()]
    non_never = [l for l in lines if not l.strip().startswith("NEVER")]
    if len(lines) != 8:
        out("FAIL", "the hard gate holds exactly eight rules", "8", str(len(lines)))
    elif non_never:
        out("FAIL", "every hard gate rule begins with NEVER", "all begin NEVER", str(non_never))
    else:
        out("PASS", "the hard gate holds exactly eight rules, each beginning NEVER")

octagons = [n for n, s in shapes.items() if s == "octagon"]
if len(octagons) != 1:
    out("FAIL", "exactly one octagon sits inside the routing graph", "1", str(len(octagons)))
else:
    attrs = node_attrs[octagons[0]]
    if "style=filled" in attrs.replace(" ", "") and "fillcolor=red" in attrs.replace(" ", ""):
        out("PASS", "the one octagon carries style=filled and fillcolor=red")
    else:
        out("FAIL", "the one octagon carries style=filled and fillcolor=red", "style=filled, fillcolor=red", attrs)

# --- 7: one draw node serves all five file-backed card faces -------------
face_nodes = [n for n in shapes if "--variant=<face>" in n]
if len(face_nodes) != 1:
    out("FAIL", "exactly one plaintext node carries --variant=<face>", "1", str(len(face_nodes)))
else:
    face_node = face_nodes[0]
    incoming_ellipses = [
        s for s, d, _ in edges
        if d == face_node and shapes.get(s) == "ellipse"
    ]
    if len(incoming_ellipses) == 5:
        out("PASS", "one shared draw node serves all five file-backed card faces")
    else:
        out("FAIL", "one shared draw node serves all five file-backed card faces", "5 ellipse states", str(incoming_ellipses))

# --- 8: no decisions script name outside the fence and the flag table ----
def strip_table_rows(s):
    return "\n".join(l for l in s.splitlines() if not l.strip().startswith("|"))

below_hits = [name for name in SCRIPTS if name in below_fence]
above_hits = [name for name in SCRIPTS if name in strip_table_rows(above_fence)]
if below_hits:
    out("FAIL", "no decisions script name appears below the routing fence", "none", str(below_hits))
else:
    out("PASS", "no decisions script name appears below the routing fence")
if above_hits:
    out("FAIL", "above the fence, a decisions script name appears only in the flag table", "none outside the flag table", str(above_hits))
else:
    out("PASS", "above the fence, a decisions script name appears only in the flag table")

# --- 9: a write arrow's label never doubles as a pre-card word ------------
# Pre-card = a node reachable from an entry before any card is on screen and
# NOT reachable from any card. A card is an ellipse that feeds a
# "decisions-view.sh card" draw node; the Shelf and the match drawer are
# ellipses too but draw no card, so they are walked through. A gate a card's
# path can also reach (the crafted? diamonds) is not a pre-card node - its
# answers come from data, not from what the user typed at the Shelf. The
# retag write is exempt: the hard gate rules that a retag draws no card.
cards = {n for n, s in shapes.items() if s == "ellipse"
         and any("decisions-view.sh card" in nxt for nxt in adjacency.get(n, []))}
def reach(starts, stop_at=frozenset()):
    seen = set(starts); q = list(starts)
    while q:
        node = q.pop()
        if node in stop_at and node not in starts: continue
        for nxt in adjacency.get(node, []):
            if nxt not in seen: seen.add(nxt); q.append(nxt)
    return seen
postcard = reach(cards)
precard = {n for n in reach(entries, stop_at=cards) if n not in postcard and n not in cards}
precard_labels = {l for s_, d_, l in edges if l and s_ in precard}
write_nodes = {n for n, s in shapes.items() if s == "plaintext" and ("decisions-transition.sh" in n or ("decisions-capture.sh" in n and "--dry-run" not in n))}
collisions = sorted({(l, d_) for s_, d_, l in edges if d_ in write_nodes and l and l in precard_labels and " retag " not in d_})
if collisions: out("FAIL", "no arrow into a write carries a label that also leaves a pre-card node (retag exempt)", "none", str(collisions))
else: out("PASS", "no arrow into a write carries a label that also leaves a pre-card node (retag exempt)")

# --- 10: the file says where the scripts live, once, above the fence -------
# Every other command that runs a script writes its plugin path; the desk
# named its scripts bare and a fresh session opened with `find` for them
# (bug 2026-09-27). One sentence in the flag-table section carries the
# directory, with the variable Claude Code substitutes at load, never a
# resolved path. Command nodes stay bare: a plaintext node is the literal
# command, so no plaintext node may carry a path of its own.
LOC = "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/"
loc_total = text.count(LOC); loc_above = above_fence.count(LOC)
pathed_nodes = sorted(n for n, s in shapes.items() if s == "plaintext" and "/" in n)
if loc_total == 1 and loc_above == 1 and not pathed_nodes:
    out("PASS", "the scripts' location is stated exactly once, above the fence, and no command node carries a path")
else:
    out("FAIL", "the scripts' location is stated exactly once, above the fence, and no command node carries a path", "1 above, 0 below, no pathed plaintext nodes", f"total={loc_total} above={loc_above} pathed_nodes={pathed_nodes}")

PYEOF
GRAPH_REPORT="$(python3 "$GRAPH_SCRIPT" "$CMD")"
rm -f "$GRAPH_SCRIPT"
trap - EXIT
echo "$GRAPH_REPORT" | sed 's/^/  /'
GRAPH_PASS="$(printf '%s\n' "$GRAPH_REPORT" | grep -c '^PASS:' || true)"
GRAPH_FAIL="$(printf '%s\n' "$GRAPH_REPORT" | grep -c '^FAIL:' || true)"
PASS_COUNT=$((PASS_COUNT + GRAPH_PASS)); FAIL_COUNT=$((FAIL_COUNT + GRAPH_FAIL)); TOTAL=$((TOTAL + GRAPH_PASS + GRAPH_FAIL))

# ---------------------------------------------------------------------
# The capped list of prose that survives below the graph
# ---------------------------------------------------------------------
echo "-- Test: the capped prose-grep list --"
# Every phrase here is a sentence the Sentence Inventory marks "kept" (or
# the drawing rule content it says is carried over unchanged); nothing
# else below the graph is grepped by this test. This IS the cap the
# story's Acceptance points at - a new routing rule has nowhere to land
# here, because this list is prose survivors, never rules.
PROSE_SURVIVORS=(
  "Done records never get a row"
  "No right edge"
  "fixed width"
  "print exactly as the file holds them"
  'MATCH "<words>"'
  "removed row draws red"
  "added row draws green"
  "colour is drawn here"
  "One ruling per card"
  "not in the room"
  "complete alternative in plain words"
  "why not the other options"
  "path not chosen"
  "no hand wrapping"
  "Ideas to consider, not ruled:"
  "rename it in words like anything else on the card"
  "an exhibit is never invented"
  "an unanswered second step is a trap"
  "read it again against the new meaning"
  "already built"
)
if [ "${#PROSE_SURVIVORS[@]}" -le 20 ]; then
  pass "the prose-grep array holds at most 20 entries (${#PROSE_SURVIVORS[@]})"
else
  fail "the prose-grep array holds at most 20 entries" "<= 20" "${#PROSE_SURVIVORS[@]}"
fi

BODY_JOINED="$(awk '/^---$/{n++; next} n>=2{print}' "$CMD" | tr '\n' ' ' | tr -s ' ')"
for phrase in "${PROSE_SURVIVORS[@]}"; do
  if printf '%s' "$BODY_JOINED" | grep -qiE -- "$phrase"; then
    pass "prose survives: $phrase"
  else
    fail "prose survives: $phrase" "found below the frontmatter fence" "not found"
  fi
done

# ---------------------------------------------------------------------
# Structural bans (not "prose that stays" - things that must NOT appear)
# ---------------------------------------------------------------------
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

echo "-- Test: no graduation flow below the frontmatter fence --"
grep_fail_below_fence "no 'graduate' verb below the frontmatter fence" '[Gg]raduate'

echo "-- Test: no direct record-writing instruction (a ## Context/## Decision heredoc or a .craft/decisions/ write path) --"
grep_fail_below_fence "no direct record-writing instruction" '^## (Context|Decision|Consequences|Approval)$'
grep_fail_below_fence "no direct .craft/decisions/ write path" '> *"?\.craft/decisions/'

echo "-- Test: AskUserQuestion is forbidden; answers are typed into the prompt --"
AUQ_LINES="$(grep -h "AskUserQuestion" "$CMD" || true)"
if [ -z "$AUQ_LINES" ]; then
  fail "AskUserQuestion mentioned only under a prohibition" "at least one prohibition line" "zero mentions"
else
  BAD="$(printf '%s\n' "$AUQ_LINES" | grep -iv "never" || true)"
  if [ -z "$BAD" ]; then pass "every AskUserQuestion mention sits on a NEVER line"; else fail "every AskUserQuestion mention sits on a NEVER line" "all lines contain NEVER" "$BAD"; fi
fi

echo "-- Test: the drawing rule survives, heading and rail characters --"
if grep -qE '^### The drawing rule$' "$CMD"; then
  pass "### The drawing rule heading is present, exact"
else
  fail "### The drawing rule heading is present, exact" "### The drawing rule" "not found"
fi
if grep -q '[┌│└├]' "$CMD"; then
  pass "the command file carries the rail characters ┌ │ ├ └ - it is where Claude reads the shape from"
else
  fail "the command file carries the rail characters ┌ │ ├ └ - it is where Claude reads the shape from" "present" "absent"
fi

echo "-- Test: no story template is touched by this story --"
for f in commands/craft-story-new.md commands/references/cycle-design/default-mode.md commands/references/cycle-design/roadmap-mode.md; do
  if git -C "$REPO" diff --quiet HEAD -- "$f" 2>/dev/null; then
    pass "$f unchanged vs HEAD"
  else
    fail "$f unchanged vs HEAD" "no diff" "diff present"
  fi
done

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
grep -q "holds the story's own records and no others" "$ALIGNMENT_REF" && pass "the investigator gets the story's own records and no others" || fail "the investigator gets the story's own records and no others" "present" "absent"
NOT_LAW_COUNT="$(grep -c "is NOT LAW for this story" "$ALIGNMENT_REF" || true)"
if [ "$NOT_LAW_COUNT" -eq 2 ]; then pass "the NOT LAW sentence is in the rule and in the prompt template"; else fail "the NOT LAW sentence is in the rule and in the prompt template" "2" "$NOT_LAW_COUNT"; fi

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
