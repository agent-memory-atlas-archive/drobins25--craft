#!/bin/bash
# decisions-view.sh - Derives every view the decisions desk shows the user
# (the DECISION SHELF, one group drawer, the empty state, the archive, and
# the card's fresh/pending/reopen/retire faces) from decisions-list.sh's
# stdin blocks or a record's own text, and emits it as plain key=value
# data - no box-drawing character and no ANSI escape anywhere in this
# script's stdout. Claude draws the rail around that data, following
# commands/craft-decisions.md's ### The drawing rule, including the reopen
# face's colour.
#
# Usage:
#   decisions-view.sh shelf
#     stdin: decisions-list.sh's nine-key blank-line-separated blocks (any
#     filters already applied by the caller). Emits BAND=/HEAD=/BLANK=
#     then one GROUP=/STRIP=/TOTAL=/COUNT_*=/MORE= block per group with
#     its ROW= lines, then CLOSE= - or the empty view's data when stdin
#     holds no non-archive records.
#
#   decisions-view.sh group
#     stdin: decisions-list.sh --tag=<target> blocks (already filtered to
#     one tag). Emits ONE GROUP=/STRIP=/TOTAL=/COUNT_*=/MORE= block and its
#     ROW= lines - no BAND=, no HEAD=, no CLOSE=. This is the retag
#     receipt's one drawer.
#
#   decisions-view.sh archive [--only=declined|retired]
#     stdin: decisions-list.sh --room=archive blocks. Emits BAND=, then per
#     record a ROW= carrying the exit label (padded to 9 columns, dropped
#     under --only=) and the date-stripped slug, then its exit words as
#     further ROW= lines indented to the same column, newest exit first,
#     then CLOSE=.
#
#   decisions-view.sh card --variant=<fresh|pending|reopen|retire>
#       [--state=<question|decision>] [--proposed=<letter>] [--file=<path>]
#       [--context= --options= --decision= --consequences= --title=]
#       [--new-group=<tag>] [--claimed-by=<story>:<status> ...]
#       [--shipped-by=<story>]
#     `fresh` reads decisions-capture.sh --dry-run's stdout on stdin: line 1
#     is SLUG=, the rest is the record body. `pending` and `retire` take
#     --file=<path> (a FILE= path decisions-list.sh emits). `reopen` takes
#     --file= for the base plus the proposed sections as flags, and diffs
#     them against the file. State on a fresh card defaults to decision; on
#     a pending card it is read from the file's own Options section
#     (lettered "(x)" lines are a question, "- " lines or an empty section
#     are a decision). reopen and retire ignore --state.
#     Every variant emits BAND=/HEAD=/BLANK=/DIV=/ROW=/CLOSE= data, same
#     vocabulary as the Shelf: body text wraps at 65 columns with hyphens
#     never treated as a break point, and every `> ` line of the Approval
#     section is its own ROW=, byte-identical to the file. reopen's title
#     and body rows carry an extra MARK=-|+| key naming which way a row
#     changed - the drawing rule colours it; this script emits no ANSI
#     escape of its own.
#
# Resolves no project root, reads no environment variable for one, and
# globs nothing under .craft/ - the only files this script opens are the
# exact FILE= paths handed to it on stdin. Exit 0 always.

set -e

# The python heredoc below occupies stdin (fd 0) with the script itself, so
# the piped decisions-list.sh output is saved to fd 3 first and read back
# from there - the house heredoc idiom, extended to also relay real input.
exec 3<&0

python3 - "$@" <<'PYEOF'
import sys, os, re, textwrap, difflib

ARGS = sys.argv[1:]
SUBCOMMAND = ARGS[0] if ARGS else ''
ONLY = ''
for a in ARGS[1:]:
    if a.startswith('--only='):
        ONLY = a[len('--only='):]


def parse_card_args(args):
    opts = {
        'variant': '', 'state': '', 'proposed': '', 'file': '',
        'context': None, 'options': None, 'decision': None,
        'consequences': None, 'title': None, 'new_group': '',
        'claimed_by': [], 'shipped_by': '',
    }
    for a in args:
        if a.startswith('--variant='):
            opts['variant'] = a[len('--variant='):]
        elif a.startswith('--state='):
            opts['state'] = a[len('--state='):]
        elif a.startswith('--proposed='):
            opts['proposed'] = a[len('--proposed='):]
        elif a.startswith('--file='):
            opts['file'] = a[len('--file='):]
        elif a.startswith('--context='):
            opts['context'] = a[len('--context='):]
        elif a.startswith('--options='):
            opts['options'] = a[len('--options='):]
        elif a.startswith('--decision='):
            opts['decision'] = a[len('--decision='):]
        elif a.startswith('--consequences='):
            opts['consequences'] = a[len('--consequences='):]
        elif a.startswith('--title='):
            opts['title'] = a[len('--title='):]
        elif a.startswith('--new-group='):
            opts['new_group'] = a[len('--new-group='):]
        elif a.startswith('--claimed-by='):
            v = a[len('--claimed-by='):]
            story, _, status = v.partition(':')
            opts['claimed_by'].append((story, status))
        elif a.startswith('--shipped-by='):
            opts['shipped_by'] = a[len('--shipped-by='):]
    return opts


CARD_OPTS = parse_card_args(ARGS[1:]) if SUBCOMMAND == 'card' else None

SHELF_TITLE = 'DECISION SHELF'
KEY_BAND_TEXT = '? pending   ○ unclaimed   ● claimed   ✓ done'


def read_piped_input():
    try:
        with os.fdopen(3, 'r') as f:
            return f.read()
    except OSError:
        return ''


def parse_blocks(text):
    blocks = []
    cur = {}
    for line in text.split('\n'):
        if line == '':
            if cur:
                blocks.append(cur)
                cur = {}
            continue
        if '=' in line:
            k, _, v = line.partition('=')
            cur[k] = v
    if cur:
        blocks.append(cur)
    return blocks


def strip_date(slug):
    return re.sub(r'^\d{4}-\d{2}-\d{2}-', '', slug)


GLYPH_ORDER = ["?", "○", "●", "✓"]


def kv(key, value=''):
    return "{}={}".format(key, value)


def glyph_counts(recs):
    counts = {"?": 0, "○": 0, "●": 0, "✓": 0}
    for r in recs:
        counts[r["_glyph"]] += 1
    return counts


def full_strip(counts):
    # The complete glyph strip in ? ○ ● ✓ order, never truncated - the
    # capacity arithmetic and ellipsis a fixed width once forced are gone.
    return "".join(g * counts.get(g, 0) for g in GLYPH_ORDER)


def group_block_lines(tag, recs):
    # One GROUP=/STRIP=/TOTAL=/COUNT_*=/MORE= block, then its ROW= lines -
    # the shape both `shelf` (many groups) and `group` (one, for the
    # retag receipt) draw from. Row order and membership are unchanged:
    # every ?, then every ○, then ONE ●, then the +N more row; ✓ records
    # get no row at all, but still count toward STRIP and TOTAL.
    counts = glyph_counts(recs)
    lines = [
        kv("GROUP", tag),
        kv("STRIP", full_strip(counts)),
        kv("TOTAL", len(recs)),
        kv("COUNT_Q", counts["?"]),
        kv("COUNT_O", counts["○"]),
        kv("COUNT_C", counts["●"]),
        kv("COUNT_D", counts["✓"]),
    ]
    pending_recs = [r for r in recs if r["_glyph"] == "?"]
    open_recs = [r for r in recs if r["_glyph"] == "○"]
    claimed_recs = [r for r in recs if r["_glyph"] == "●"]
    more_n = max(len(claimed_recs) - 1, 0)
    lines.append(kv("MORE", more_n))

    for r in pending_recs:
        lines.append(kv("ROW", "? " + strip_date(r.get("SLUG", ""))))
    for r in open_recs:
        lines.append(kv("ROW", "○ " + strip_date(r.get("SLUG", ""))))
    if claimed_recs:
        lines.append(kv("ROW", "● " + strip_date(claimed_recs[0].get("SLUG", ""))))
        if more_n > 0:
            # The drawing rule's "+N more" row gets six spaces after the
            # rail (four from ROW=, two more baked into the value here),
            # so its own indent falls out of the one 4-space ROW rule.
            lines.append(kv("ROW", "  +{} more".format(more_n)))
    return lines


def empty_view_lines():
    # Fixed example copy, never derived from data - every sentence kept
    # verbatim, unchanged since before this script emitted data instead
    # of frames. The "gameroom (example)" group draws through the same
    # GROUP mechanism a real Shelf group does, so drawing stays
    # mechanical everywhere.
    lines = [
        kv("BAND", "DECISION SHELF  ·  empty"),
        kv("BLANK"),
        kv("HEAD", "A decision is the one thing you're already sure of about a feature that has no cycle, no story, not even a name."),
        kv("BLANK"),
        kv("HEAD", 'today      "The gameroom has a slot machine."    gameroom'),
        kv("HEAD", 'tomorrow   "The slot machine has a bonus round." gameroom'),
        kv("BLANK"),
        kv("HEAD", KEY_BAND_TEXT),
        kv("BLANK"),
    ]
    lines.extend(group_block_lines("gameroom (example)", [
        {"_glyph": "○", "SLUG": "the-gameroom-has-a-slot-machine"},
        {"_glyph": "○", "SLUG": "the-slot-machine-has-a-bonus-round"},
    ]))
    lines.append(kv("BLANK"))
    lines.append(kv("HEAD", "The tag is the feature you haven't planned yet. When a story or a cycle picks the gameroom decisions up, it is born already knowing both. Nothing gets re-decided."))
    lines.append(kv("CLOSE"))
    return lines


def glyph_for(block):
    room = block.get("ROOM", "")
    status = block.get("STATUS", "")
    disposition = block.get("DISPOSITION", "")
    if room == "root" and status == "pending":
        return "?"
    if disposition == "crafted":
        return "✓"
    if disposition == "claimed":
        return "●"
    return "○"


def group_sort_key(tag, groups):
    recs = groups[tag]
    qcount = sum(1 for r in recs if r["_glyph"] == "?")
    ocount = sum(1 for r in recs if r["_glyph"] == "○")
    return (0 if qcount > 0 else 1, -qcount, -ocount, tag)


def grouped_by_tag(non_archive):
    # Every non-archive block's glyph, then its tags grouped in first-seen
    # order - the shared setup `shelf` and `group` both build on.
    for b in non_archive:
        b["_glyph"] = glyph_for(b)
    groups = {}
    order = []
    for b in non_archive:
        tags = [t.strip() for t in b.get("TAGS", "").split(";") if t.strip()]
        for t in tags:
            if t not in groups:
                groups[t] = []
                order.append(t)
            groups[t].append(b)
    return groups, order


def render_shelf_view(blocks):
    non_archive = [b for b in blocks if b.get("ROOM") != "archive"]
    if not non_archive:
        return empty_view_lines()

    groups, order = grouped_by_tag(non_archive)
    sorted_tags = sorted(order, key=lambda t: group_sort_key(t, groups))

    lines = [kv("BAND", SHELF_TITLE), kv("HEAD", KEY_BAND_TEXT), kv("BLANK")]
    for tag in sorted_tags:
        lines.extend(group_block_lines(tag, groups[tag]))
        lines.append(kv("BLANK"))
    lines.append(kv("CLOSE"))
    return lines


def render_group_view(blocks):
    # The retag receipt's one drawer: one GROUP block and its ROW lines,
    # nothing else. Stdin is already decisions-list.sh --tag=<target>
    # output, so every block shares the target tag - read it straight off
    # the blocks rather than taking a redundant flag.
    non_archive = [b for b in blocks if b.get("ROOM") != "archive"]
    if not non_archive:
        return []
    groups, order = grouped_by_tag(non_archive)
    tag_sets = [
        set(t.strip() for t in b.get("TAGS", "").split(";") if t.strip())
        for b in non_archive
    ]
    common = set.intersection(*tag_sets) if tag_sets else set()
    tag = sorted(common)[0] if common else order[0]
    return group_block_lines(tag, groups[tag])


ATTRIBUTION_RE = re.compile(r"-\s*(?:[^,]+,\s*)?(\d{4}-\d{2}-\d{2}),\s*\S+")


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def last_quote_block(content):
    """Returns (words, exit_date) for the LAST "> "-prefixed block in
    content. The attribution segment - "- <name>, YYYY-MM-DD, <source>"
    or "- YYYY-MM-DD, <source>", wherever it falls in a line - is cut out
    of the words entirely; whatever remains before and after it on that
    line is kept. A line that is nothing but the attribution disappears
    from the words; a line that carries the attribution mid-sentence, or
    a line that follows it with unrelated text, keeps its own words."""
    blocks = []
    cur = []
    for line in content.split("\n"):
        if line.startswith("> "):
            cur.append(line[2:])
        elif line == ">":
            cur.append("")
        else:
            if cur:
                blocks.append(cur)
                cur = []
    if cur:
        blocks.append(cur)
    if not blocks:
        return "", ""
    block = blocks[-1]
    exit_date = ""
    cleaned_lines = []
    for raw_line in block:
        m = ATTRIBUTION_RE.search(raw_line)
        if m:
            if not exit_date:
                exit_date = m.group(1)
            remainder = (raw_line[:m.start()] + raw_line[m.end():]).strip()
            if remainder:
                cleaned_lines.append(remainder)
        else:
            stripped = raw_line.strip()
            if stripped:
                cleaned_lines.append(stripped)
    return " ".join(cleaned_lines), exit_date


def render_archive_view(blocks, only_filter):
    records = []
    for b in blocks:
        if b.get("ROOM") != "archive":
            continue
        label = "declined" if b.get("STATUS") == "declined" else "retired"
        if only_filter and only_filter != label:
            continue
        path = b.get("FILE", "")
        words, exit_date = last_quote_block(read_file(path))
        records.append({
            "slug": strip_date(b.get("SLUG", "")),
            "label": label,
            "exit_date": exit_date,
            "words": words,
        })

    # Newest exit first, ties by slug ascending - a stable sort on slug
    # first, then a stable sort on date descending, yields that order.
    records.sort(key=lambda r: r["slug"])
    records.sort(key=lambda r: r["exit_date"], reverse=True)

    title = "ARCHIVE · " + only_filter if only_filter else "ARCHIVE"
    lines = [kv("BAND", title)]

    # The slug's own column: 9 chars for the label field when one prints,
    # 0 when --only= has dropped it - the exit words wrap to that same
    # column (left-anchored fixed columns survive), never to the gutter.
    # Wrap width is 65 minus that indent, the same width the card wraps
    # its body at.
    slug_column = 0 if only_filter else 9
    wrap_width = max(65 - slug_column, 1)

    for r in records:
        if only_filter:
            first_line_text = r["slug"]
        else:
            first_line_text = r["label"].ljust(9) + r["slug"]
        lines.append(kv("ROW", first_line_text))
        wrapped_words = textwrap.wrap(r["words"], width=wrap_width) if r["words"] else []
        for w in wrapped_words:
            lines.append(kv("ROW", (" " * slug_column) + w))
        lines.append(kv("BLANK"))

    lines.append(kv("CLOSE"))
    return lines


# -- The card --------------------------------------------------------
# One shape, five faces: fresh (question or decision state), pending
# (state read from the file), reopen (a diff against the file) and
# retire (the file, presented unchanged). See the module docstring above
# for the flag shape per variant. Every face draws as data - fresh and
# pending from canonical_body, retire from raw_body_lines, reopen from
# reopen_body_data further down, which diffs the file against the
# proposed sections instead of relaying them straight.

FENCE_RE = re.compile(r'^---\n(.*?)\n---\n?(.*)$', re.DOTALL)

BODY_RE = re.compile(
    r'^# (?P<title>.*?)\n\n'
    r'## Context\n(?P<context>.*?)\n\n'
    r'## Options considered\n(?P<options>.*?)\n\n'
    r'## Decision\n(?P<decision>.*?)\n\n'
    r'## Consequences\n(?P<consequences>.*?)\n\n'
    r'## Approval\n?(?P<approval>.*)$',
    re.DOTALL,
)


def fm_get(fm_text, field):
    m = re.search(r'^' + re.escape(field) + r':\s*(.*)$', fm_text, re.MULTILINE)
    return m.group(1).strip() if m else ''


def fm_list(raw):
    m = re.match(r'\[(.*)\]', raw)
    if not m:
        return []
    return [p.strip() for p in m.group(1).split(',') if p.strip()]


def parse_record_text(full_text):
    m = FENCE_RE.match(full_text)
    fm_text, body = (m.group(1), m.group(2)) if m else ('', full_text)
    bm = BODY_RE.match(body)
    if bm:
        d = bm.groupdict()
    else:
        d = {'title': '', 'context': '', 'options': '', 'decision': '',
             'consequences': '', 'approval': ''}
    return {
        'status': fm_get(fm_text, 'status'),
        'tags': fm_list(fm_get(fm_text, 'tags')),
        'source': fm_get(fm_text, 'source'),
        'title': d['title'],
        'context': d['context'],
        'options': d['options'],
        'decision': d['decision'],
        'consequences': d['consequences'],
        'approval': d['approval'].rstrip('\n'),
    }


def read_file_required(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return f.read()
    except OSError:
        sys.stderr.write("Error: cannot read --file= path: {}\n".format(path))
        sys.exit(1)


def dated_slug_from_path(path):
    base = os.path.basename(path)
    return base[:-3] if base.endswith('.md') else base


# An option is a fork's alternative. Lettered while a fork is live
# ("(a) Proposed: ..." / "(b) ..."), dashed once chosen ("- ..."); a
# continuation line (no leading marker) folds into the option before it.
# See 2026-09-09-letters-to-choose-dashes-once-chosen.
DASH_OPTION_RE = re.compile(r'^-\s*(.*)$')
LETTER_OPTION_RE = re.compile(r'^\(([a-z])\)\s*(?:Proposed:\s*)?(.*)$')


def parse_options(text):
    options = []
    is_lettered = False
    cur = None
    for line in text.split('\n'):
        if line.strip() == '':
            continue
        lm = LETTER_OPTION_RE.match(line)
        dm = DASH_OPTION_RE.match(line)
        if lm:
            is_lettered = True
            cur = {'text': lm.group(2).strip(), 'proposed': 'Proposed:' in line}
            options.append(cur)
        elif dm:
            cur = {'text': dm.group(1).strip(), 'proposed': False}
            options.append(cur)
        elif cur is not None:
            cur['text'] = (cur['text'] + ' ' + line.strip()).strip()
        else:
            cur = {'text': line.strip(), 'proposed': False}
            options.append(cur)
    return options, is_lettered


# Every card face - fresh, pending, reopen and retire - wraps body text
# at 65 columns with hyphens never treated as a break point: the width
# and setting that reproduce story 7's card exhibit line for line from a
# real record on disk (`textwrap.wrap(t, 65, break_on_hyphens=False)`;
# the default hyphen setting splits "(over-prescriptive)" across lines
# and the exhibit does not). The rail supplies the four-space gutter
# these rows draw under, so nothing here bakes in a leading indent of
# its own.
CARD_DATA_WIDTH = 65


def wrap_lines_data(text):
    if not text:
        return []
    return textwrap.wrap(text, width=CARD_DATA_WIDTH, break_on_hyphens=False) or []


def prefixed_wrap_data(prefix, text):
    avail = max(CARD_DATA_WIDTH - len(prefix), 1)
    chunks = textwrap.wrap(text, width=avail, break_on_hyphens=False) or ['']
    out = [prefix + chunks[0]]
    for c in chunks[1:]:
        out.append((' ' * len(prefix)) + c)
    return out


# The store's records are authored with hard line breaks near 57
# columns; the card's data emits body text at CARD_DATA_WIDTH (65).
# Relaying those breaks verbatim leaves one-word orphans on nearly every
# line, so this reflows instead: consecutive non-blank source lines join
# into one paragraph on single spaces and re-wrap at CARD_DATA_WIDTH; a
# blank source line ends a paragraph; a line beginning "- ", "(x) ",
# "(x) Proposed: " or "> " starts its own paragraph (a bullet, a
# lettered option, or a quote) and wraps with a hanging indent under its
# own text. No word or punctuation changes - only where the lines break.
# Ruled 2026-09-09 at acceptance, after a real record rendered with
# orphans on every other line.
PARA_MARKER_RE = re.compile(r'^(-\s+|\([a-z]\)\s+(?:Proposed:\s+)?|>\s+)')


def paragraphs_of(text):
    # One (marker, joined_text, blank_before) tuple per paragraph.
    # marker is '' for plain prose; blank_before is True when a blank
    # source line preceded this paragraph (and it isn't the section's
    # first), so a deliberate paragraph break survives the reflow.
    paras = []
    raw_lines = text.split('\n')
    i, n = 0, len(raw_lines)
    pending_blank = False
    while i < n:
        line = raw_lines[i]
        if line.strip() == '':
            pending_blank = True
            i += 1
            continue
        blank_before = pending_blank and bool(paras)
        pending_blank = False
        m = PARA_MARKER_RE.match(line)
        marker = m.group(1) if m else ''
        first = line[len(marker):].strip() if m else line.strip()
        group = [first]
        i += 1
        while i < n and raw_lines[i].strip() != '' and not PARA_MARKER_RE.match(raw_lines[i]):
            group.append(raw_lines[i].strip())
            i += 1
        paras.append((marker, ' '.join(group), blank_before))
    return paras


def emit_flow_data(lines, text):
    # Appends ROW=/BLANK= kv lines straight onto the caller's list, at
    # CARD_DATA_WIDTH - the width every card face wraps body text at.
    for marker, ptext, blank_before in paragraphs_of(text):
        if blank_before:
            lines.append(kv("BLANK"))
        if marker:
            for l in prefixed_wrap_data(marker, ptext):
                lines.append(kv("ROW", l))
        else:
            for l in wrap_lines_data(ptext):
                lines.append(kv("ROW", l))


def approval_rows_data(approval_text):
    # Every `> ` line of the file's own Approval section is its own
    # ROW=, byte-identical, prefix included - never re-wrapped, never
    # joined with the line before or after it. Approval never goes
    # through paragraphs_of/emit_flow_data: reflowing quoted words is
    # the defect this ruling fixes, not a shape it repeats.
    rows = []
    if not approval_text.strip():
        return rows
    for line in approval_text.split('\n'):
        rows.append(kv("BLANK") if line == '' else kv("ROW", line))
    return rows


def canonical_body(parsed, options, state, proposed_letter):
    # The record's five sections as DIV=/ROW=/BLANK= data - byte-exact
    # in the decision state, a display transform of the same section
    # list in the question state. See
    # 2026-09-08-a-card-with-a-live-fork-reads-as-a-question-and.
    # The title and dated slug are the caller's job (render_card_data);
    # this starts at the first section divider.
    lines = [kv("DIV", "CONTEXT")]
    emit_flow_data(lines, parsed['context'])
    lines.append(kv("BLANK"))

    letters = None
    marker_letter = None
    if state == 'question':
        lines.append(kv("DIV", "YOUR OPTIONS"))
        letters = [chr(ord('a') + i) for i in range(len(options))]
        proposed_idx = None
        if proposed_letter:
            idx = ord(proposed_letter) - ord('a')
            if 0 <= idx < len(options):
                proposed_idx = idx
        if proposed_idx is None:
            for i, o in enumerate(options):
                if o['proposed']:
                    proposed_idx = i
                    break
        for i, o in enumerate(options):
            prefix = "({}) ".format(letters[i])
            if i == proposed_idx:
                prefix += "Proposed: "
            for l in prefixed_wrap_data(prefix, o['text']):
                lines.append(kv("ROW", l))
        if proposed_idx is not None:
            marker_letter = letters[proposed_idx]
        else:
            marker_letter = proposed_letter or (letters[0] if letters else 'a')
    else:
        lines.append(kv("DIV", "OPTIONS CONSIDERED"))
        for o in options:
            for l in prefixed_wrap_data("- ", o['text']):
                lines.append(kv("ROW", l))

    lines.append(kv("BLANK"))
    lines.append(kv("DIV", "DECISION" + (" if ({})".format(marker_letter) if state == 'question' else "")))
    emit_flow_data(lines, parsed['decision'])
    lines.append(kv("BLANK"))
    lines.append(kv("DIV", "CONSEQUENCES" + (" if ({})".format(marker_letter) if state == 'question' else "")))
    emit_flow_data(lines, parsed['consequences'])
    lines.append(kv("BLANK"))
    lines.append(kv("DIV", "APPROVAL"))
    lines.extend(approval_rows_data(parsed['approval']))
    lines.append(kv("BLANK"))

    return lines, letters


def raw_body_lines(parsed):
    # A retire face presents the record exactly as it sits on disk -
    # never re-punctuated, never re-lettered - even a legacy record
    # whose Options are still lettered. Same DIV=/ROW=/BLANK= shape as
    # canonical_body above; the title and dated slug are the caller's.
    lines = [kv("DIV", "CONTEXT")]
    emit_flow_data(lines, parsed['context'])
    lines.append(kv("BLANK"))
    lines.append(kv("DIV", "OPTIONS CONSIDERED"))
    emit_flow_data(lines, parsed['options'])
    lines.append(kv("BLANK"))
    lines.append(kv("DIV", "DECISION"))
    emit_flow_data(lines, parsed['decision'])
    lines.append(kv("BLANK"))
    lines.append(kv("DIV", "CONSEQUENCES"))
    emit_flow_data(lines, parsed['consequences'])
    lines.append(kv("BLANK"))
    lines.append(kv("DIV", "APPROVAL"))
    lines.extend(approval_rows_data(parsed['approval']))
    lines.append(kv("BLANK"))
    return lines


def diff_rows(old_text, new_text):
    # One (marker, text) tuple per logical line: '' unchanged, '-'
    # removed, '+' added. Used for the title only - a single line, never
    # reflowed.
    rows = []
    for dl in difflib.ndiff(old_text.split('\n'), new_text.split('\n')):
        if dl.startswith('? '):
            continue
        marker = dl[0] if dl[0] in '-+' else ''
        rows.append((marker, dl[2:]))
    return rows


def diff_paragraphs(old_text, new_text):
    # One (diff_marker, para_marker, text) tuple per PARAGRAPH, not per
    # source line - so a one-word edit marks the paragraph it lives in,
    # not every physical line the word-wrap happens to touch.
    old_paras = [(m, t) for m, t, _ in paragraphs_of(old_text)]
    new_paras = [(m, t) for m, t, _ in paragraphs_of(new_text)]
    old_keys = [m + '\x00' + t for m, t in old_paras]
    new_keys = [m + '\x00' + t for m, t in new_paras]
    rows = []
    sm = difflib.SequenceMatcher(a=old_keys, b=new_keys, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            for k in range(i1, i2):
                m, t = old_paras[k]
                rows.append(('', m, t))
        else:
            for k in range(i1, i2):
                m, t = old_paras[k]
                rows.append(('-', m, t))
            for k in range(j1, j2):
                m, t = new_paras[k]
                rows.append(('+', m, t))
    return rows


def emit_diff_rows_data(lines, rows):
    # The diff marker lives IN the two-space body indent - "  "
    # unchanged, "- " removed, "+ " added - so a removed option bullet's
    # ROW= reads "- - text" and an unchanged one reads "  - text": the
    # marker and the bullet's own dash never share a column. A marker
    # paragraph (a bullet, a lettered option, a quote) keeps its own
    # hanging indent past the diff marker. Ruled 2026-09-09, carried into
    # the data path unchanged. Each physical row also gets its own MARK=
    # key ('', '-' or '+') alongside its ROW=, so the drawing rule can
    # colour it - this script emits no ANSI escape of its own.
    marker_prefix = {'': '  ', '-': '- ', '+': '+ '}
    for diff_marker, para_marker, text in rows:
        outer = marker_prefix[diff_marker]
        # The outer diff marker is part of the emitted ROW, so it comes
        # off the wrap width first - the same subtraction prefixed_wrap_data
        # and the title diff make for their own prefixes. Without it a
        # reopen row ran up to two columns past every other face's 65.
        avail_width = max(CARD_DATA_WIDTH - len(outer), 1)
        if para_marker:
            avail = max(avail_width - len(para_marker), 1)
            chunks = textwrap.wrap(text, width=avail, break_on_hyphens=False) or ['']
            physical = [para_marker + chunks[0]]
            physical.extend((' ' * len(para_marker)) + c for c in chunks[1:])
        else:
            physical = textwrap.wrap(text, width=avail_width, break_on_hyphens=False) or ['']
        for p in physical:
            lines.append(kv("MARK", diff_marker))
            lines.append(kv("ROW", outer + p))


def reopen_body_data(parsed, opts):
    # The reopen face's diff, as DIV=/MARK=/ROW=/HEAD=/BLANK= data - the
    # same vocabulary render_card_data draws the other faces from. The
    # title is a label, not a section body, so its diff rides HEAD= at
    # the gutter rather than ROW= in the body indent. APPROVAL is never
    # diffed - it is relayed verbatim, same as every other face, so the
    # `> Reopen:` lines a prior write already appended stay visible
    # before this reopen's own letter is typed.
    new_title = opts['title'] if opts['title'] is not None else parsed['title']
    new_context = opts['context'] if opts['context'] is not None else parsed['context']
    new_options = opts['options'] if opts['options'] is not None else parsed['options']
    new_decision = opts['decision'] if opts['decision'] is not None else parsed['decision']
    new_consequences = opts['consequences'] if opts['consequences'] is not None else parsed['consequences']

    out = []

    title_marker_prefix = {'': '', '-': '- ', '+': '+ '}
    for marker, text in diff_rows(parsed['title'], new_title):
        prefix = title_marker_prefix[marker]
        avail = max(CARD_DATA_WIDTH - len(prefix), 1)
        for c in (textwrap.wrap(text, width=avail, break_on_hyphens=False) or ['']):
            out.append(kv("MARK", marker))
            out.append(kv("HEAD", prefix + c))
    out.append(kv("BLANK"))

    out.append(kv("DIV", "CONTEXT"))
    emit_diff_rows_data(out, diff_paragraphs(parsed['context'], new_context))
    out.append(kv("BLANK"))

    out.append(kv("DIV", "OPTIONS CONSIDERED"))
    emit_diff_rows_data(out, diff_paragraphs(parsed['options'], new_options))
    out.append(kv("BLANK"))

    out.append(kv("DIV", "DECISION"))
    emit_diff_rows_data(out, diff_paragraphs(parsed['decision'], new_decision))
    out.append(kv("BLANK"))

    out.append(kv("DIV", "CONSEQUENCES"))
    emit_diff_rows_data(out, diff_paragraphs(parsed['consequences'], new_consequences))
    out.append(kv("BLANK"))

    out.append(kv("DIV", "APPROVAL"))
    out.extend(approval_rows_data(parsed['approval']))

    return out


def card_band_text(status, tags, source, new_group_tag):
    # The BAND= text every card face draws from: single spaces around
    # each `·`, since there is no fixed width left to justify against. A
    # tag no record carries reads `<tag> (NEW GROUP)` in the same place.
    tag_parts = []
    for t in tags:
        tag_parts.append(t + " (NEW GROUP)" if new_group_tag and t == new_group_tag else t)
    tags_text = ", ".join(tag_parts) if tag_parts else "(no tags)"
    return "{} · tags: {} · source: {}".format(status.upper() if status else "", tags_text, source)


def claimed_by_rows_data(claimed_by):
    # Left-anchored fixed columns survive the rail: the story column is
    # padded to the longest claimant's name on THIS card, so every
    # status starts in the same column even though nothing right-aligns
    # to anything - there is no right edge to align to any more. See
    # 2026-09-09-the-reopen-card-shows-its-claimants-before-the.
    lines = [kv("DIV", "CLAIMED BY STORIES")]
    max_len = max(len(story) for story, _ in claimed_by)
    for story, status in claimed_by:
        if status:
            lines.append(kv("ROW", story.ljust(max_len + 2) + status))
        else:
            lines.append(kv("ROW", story))
    lines.append(kv("BLANK"))
    return lines


def shipped_by_row_data(shipped_by):
    return [kv("DIV", "SHIPPED BY STORY"), kv("ROW", shipped_by), kv("BLANK")]


def move_row_data(letter, move, effect):
    prefix = "{}) {}  ".format(letter, move.ljust(14))
    return prefixed_wrap_data(prefix, effect)


def moves_for_data(variant, state, letters):
    # Every face's letters and effects, as ROW= values.
    moves = []

    if variant == 'reopen':
        letter_list = ['a']
        moves.extend(move_row_data('a', 'approve', 'the law changes to this'))
    elif variant == 'retire':
        letter_list = ['a']
        moves.extend(move_row_data('a', 'retire', 'no longer applies, goes to the archive with your words'))
    elif state == 'question':
        n = len(letters) if letters else 0
        for letter in letters:
            moves.extend(move_row_data(letter, 'pick', 'picks this option and redraws'))
        keep_letter = chr(ord('a') + n)
        letter_list = list(letters) + [keep_letter]
        effect = ("saved on the Shelf as a question, decide later" if variant == 'fresh'
                  else "saves your changes, stays on the Shelf")
        moves.extend(move_row_data(keep_letter, 'keep pending', effect))
    else:
        letter_list = ['a', 'b', 'c']
        if variant == 'fresh':
            moves.extend(move_row_data('a', 'approve', 'what it becomes, and what gets built to it'))
            moves.extend(move_row_data('b', 'keep pending', 'saved on the Shelf, decide later'))
            moves.extend(move_row_data('c', 'decline', 'goes to the archive with your words, never re-proposed'))
        else:
            moves.extend(move_row_data('a', 'approve', 'moves to approved/ as shown'))
            moves.extend(move_row_data('b', 'keep pending', 'saves your changes, stays on the Shelf'))
            moves.extend(move_row_data('c', 'decline', 'moves to the archive with your words'))

    closing = ", ".join(letter_list) + ", or just tell me what to change."
    return moves, closing


def render_card_reopen_data(opts):
    # The reopen face's diff, as BAND=/HEAD=/BLANK=/DIV=/MARK=/ROW=/
    # CLOSE= data - the same vocabulary render_card_data draws the other
    # faces from. The title diff replaces the plain HEAD= title line the
    # other faces draw; everything else follows the same shape.
    if opts['claimed_by'] and opts['shipped_by']:
        sys.stderr.write("Error: --claimed-by= and --shipped-by= are mutually exclusive\n")
        sys.exit(1)

    text = read_file_required(opts['file'])
    parsed = parse_record_text(text)
    dated_slug = dated_slug_from_path(opts['file'])

    lines = [
        kv("BAND", card_band_text(parsed['status'], parsed['tags'], parsed['source'], opts['new_group'])),
        kv("HEAD", dated_slug),
        kv("BLANK"),
    ]
    lines.extend(reopen_body_data(parsed, opts))

    if opts['claimed_by']:
        lines.extend(claimed_by_rows_data(opts['claimed_by']))
    elif opts['shipped_by']:
        lines.extend(shipped_by_row_data(opts['shipped_by']))

    lines.append(kv("DIV", "YOUR MOVE"))
    moves, closing = moves_for_data('reopen', None, None)
    lines.extend(kv("ROW", mv) for mv in moves)
    lines.append(kv("BLANK"))
    lines.append(kv("HEAD", closing))
    lines.append(kv("CLOSE"))
    return lines


def render_card_data(opts):
    # fresh, pending and retire: the card as BAND=/HEAD=/DIV=/ROW=/
    # BLANK=/CLOSE= data, same vocabulary the Shelf draws from.
    variant = opts['variant']

    if opts['claimed_by'] and opts['shipped_by']:
        sys.stderr.write("Error: --claimed-by= and --shipped-by= are mutually exclusive\n")
        sys.exit(1)

    letters = None
    state = None

    if variant == 'fresh':
        raw = read_piped_input()
        first_nl = raw.find('\n')
        slug_line, rest = (raw, '') if first_nl == -1 else (raw[:first_nl], raw[first_nl + 1:])
        dated_slug = slug_line[len('SLUG='):] if slug_line.startswith('SLUG=') else ''
        parsed = parse_record_text(rest)
        state = opts['state'] or 'decision'
        if state == 'question' and not opts['proposed']:
            sys.stderr.write("Error: --proposed= is required with --state=question on a fresh card\n")
            sys.exit(1)
        if state == 'decision' and opts['proposed']:
            sys.stderr.write("Error: --proposed= is refused in the decision state\n")
            sys.exit(1)
        options, _ = parse_options(parsed['options'])
        body_lines, letters = canonical_body(parsed, options, state, opts['proposed'])

    elif variant == 'pending':
        text = read_file_required(opts['file'])
        parsed = parse_record_text(text)
        dated_slug = dated_slug_from_path(opts['file'])
        options, is_lettered = parse_options(parsed['options'])
        state = opts['state'] or ('question' if is_lettered else 'decision')
        proposed_letter = opts['proposed']
        if not proposed_letter and state == 'question':
            for i, o in enumerate(options):
                if o['proposed']:
                    proposed_letter = chr(ord('a') + i)
                    break
        body_lines, letters = canonical_body(parsed, options, state, proposed_letter)

    elif variant == 'retire':
        text = read_file_required(opts['file'])
        parsed = parse_record_text(text)
        dated_slug = dated_slug_from_path(opts['file'])
        body_lines = raw_body_lines(parsed)

    else:
        sys.stderr.write("Error: --variant= must be fresh, pending or retire\n")
        sys.exit(1)

    lines = [
        kv("BAND", card_band_text(parsed['status'], parsed['tags'], parsed['source'], opts['new_group'])),
        kv("HEAD", dated_slug),
        kv("BLANK"),
        kv("HEAD", parsed['title']),
        kv("BLANK"),
    ]
    lines.extend(body_lines)

    if opts['claimed_by']:
        lines.extend(claimed_by_rows_data(opts['claimed_by']))
    elif opts['shipped_by']:
        lines.extend(shipped_by_row_data(opts['shipped_by']))

    lines.append(kv("DIV", "YOUR MOVE"))
    moves, closing = moves_for_data(variant, state, letters)
    lines.extend(kv("ROW", mv) for mv in moves)
    lines.append(kv("BLANK"))
    lines.append(kv("HEAD", closing))
    lines.append(kv("CLOSE"))
    return lines


def main():
    if SUBCOMMAND == "archive":
        data = read_piped_input()
        blocks = parse_blocks(data)
        lines = render_archive_view(blocks, ONLY)
    elif SUBCOMMAND == "group":
        data = read_piped_input()
        blocks = parse_blocks(data)
        lines = render_group_view(blocks)
    elif SUBCOMMAND == "card":
        if CARD_OPTS['variant'] == 'reopen':
            lines = render_card_reopen_data(CARD_OPTS)
        else:
            lines = render_card_data(CARD_OPTS)
    else:
        data = read_piped_input()
        blocks = parse_blocks(data)
        lines = render_shelf_view(blocks)
    sys.stdout.write("\n".join(lines) + "\n")


main()
PYEOF
