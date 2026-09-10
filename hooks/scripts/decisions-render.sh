#!/bin/bash
# decisions-render.sh - Draws every frame the decisions desk shows the user
# (the DECISION SHELF, its empty state, and the archive) from
# decisions-list.sh's stdin blocks. Chunk 3 adds the `card` subcommand.
#
# Usage:
#   decisions-render.sh shelf
#     stdin: decisions-list.sh's nine-key blank-line-separated blocks (any
#     filters already applied by the caller). Prints the DECISION SHELF, or
#     the 21-line empty frame when stdin holds no non-archive records.
#
#   decisions-render.sh archive [--only=declined|retired]
#     stdin: decisions-list.sh --room=archive blocks. Prints one row pair
#     per archived record - an exit label and the date-stripped slug, then
#     its exit words wrapped beneath - newest exit first. --only= keeps one
#     kind and drops the label column.
#
#   decisions-render.sh card --variant=<fresh|pending|reopen|retire>
#       [--state=<question|decision>] [--proposed=<letter>] [--file=<path>]
#       [--context= --options= --decision= --consequences= --title=]
#       [--new-group=<tag>] [--claimed-by=<story>:<status> ...]
#       [--shipped-by=<story>]
#     `fresh` reads decisions-capture.sh --dry-run's stdout on stdin: line 1
#     is SLUG=, the rest is the record body. `pending` and `retire` take
#     --file=<path> (a FILE= path decisions-list.sh emits). `reopen` takes
#     --file= for the base plus the proposed sections as flags, and renders
#     a red/green diff against the file. State on a fresh card defaults to
#     decision; on a pending card it is read from the file's own Options
#     section (lettered "(x)" lines are a question, "- " lines or an empty
#     section are a decision). reopen and retire ignore --state. The card
#     frame reuses the Shelf's geometry; a body line wider than 57 columns
#     soft-wraps rather than breaking the 63-column invariant.
#     Colour on the reopen diff follows [ -t 1 ] with NO_COLOR unset, in
#     the real world; CRAFT_DECISIONS_FORCE_COLOR=1 is a test-only hook
#     that forces it on when stdout is not a real terminal (as it never is
#     under a test harness), so the always-on markers and the colour they
#     carry can both be pinned by a test.
#
# Resolves no project root, reads no environment variable for one, and
# globs nothing under .craft/ - the only files this script opens are the
# exact FILE= paths handed to it on stdin. Every emitted line is exactly
# 63 characters. Exit 0 always.

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
TABLE_HEADER_TEXT = 'decisions by tag               progress             total'
TABLE_UNDERLINE_TEXT = '────────────────               ────────             ─────'

# The empty frame is fixed example copy, never rendered from data - kept
# as one literal string per line (not one giant literal) so no single
# source line buries the multi-byte box-drawing glyphs.
EMPTY_FRAME_LINES = [
    '┌─────────────────────────────────────────────────────────────┐',
    '│  DECISION SHELF  ·  empty                                   │',
    '├─────────────────────────────────────────────────────────────┤',
    "│  A decision is the one thing you're already sure of about   │",
    '│  a feature that has no cycle, no story, not even a name.    │',
    '├─────────────────────────────────────────────────────────────┤',
    '│  today      "The gameroom has a slot machine."    gameroom  │',
    '│  tomorrow   "The slot machine has a bonus round." gameroom  │',
    '├─────────────────────────────────────────────────────────────┤',
    '│  ? pending   ○ unclaimed   ● claimed   ✓ done               │',
    '├─────────────────────────────────────────────────────────────┤',
    '│  decisions by tag               progress             total  │',
    '│  ────────────────               ────────             ─────  │',
    '│  gameroom (example)             ○○                       2  │',
    '│    ○ the-gameroom-has-a-slot-machine                        │',
    '│    ○ the-slot-machine-has-a-bonus-round                     │',
    '├─────────────────────────────────────────────────────────────┤',
    "│  The tag is the feature you haven't planned yet. When a     │",
    '│  story or a cycle picks the gameroom decisions up, it is    │',
    '│  born already knowing both. Nothing gets re-decided.        │',
    '└─────────────────────────────────────────────────────────────┘',
]
EMPTY_FRAME_TEXT = chr(10).join(EMPTY_FRAME_LINES)


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


# -- Frame geometry ------------------------------------------------------
# Every line is 63 characters: a 1-char border, a 2-space gutter, a
# 57-column content field (indices 3..59), a 2-space gutter, a 1-char
# border. See story 4-decisions-skill.md's Pitch conditions table for the
# measured geometry this mirrors.
INNER = 61
CONTENT_WIDTH = 57

TOP = "┌" + "─" * INNER + "┐"
BOT = "└" + "─" * INNER + "┘"
DIV = "├" + "─" * INNER + "┤"


def content_line(text):
    return "│  " + text.ljust(CONTENT_WIDTH)[:CONTENT_WIDTH] + "  │"


BLANK = content_line("")
KEY_BAND = content_line(KEY_BAND_TEXT)
TABLE_HEADER = content_line(TABLE_HEADER_TEXT)
TABLE_UNDERLINE = content_line(TABLE_UNDERLINE_TEXT)

GLYPH_ORDER = ["?", "○", "●", "✓"]


def tag_row(tagname, counts, total):
    # Capacity is derived from the 63-column invariant, not hardcoded: the
    # total is right-aligned to end at content index 56 (absolute 59), the
    # glyph strip starts at content index 31 (absolute 34), and at least
    # one blank column separates them.
    glyphs = "".join(g * counts.get(g, 0) for g in GLYPH_ORDER)
    total_str = str(total)
    region_width = 26 - len(total_str)
    capacity = region_width - 1
    if len(glyphs) > capacity:
        glyphs_display = glyphs[:max(capacity - 1, 0)] + "…"
    else:
        glyphs_display = glyphs
    content = tagname.ljust(31) + glyphs_display.ljust(region_width) + total_str
    return "│  " + content[:CONTENT_WIDTH] + "  │"


def sub_row(glyph, slug):
    return content_line("  " + glyph + " " + strip_date(slug))


def more_row(n):
    return content_line("    +" + str(n) + " more")


def empty_frame_lines():
    return list(EMPTY_FRAME_LINES)


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


def render_shelf(blocks):
    non_archive = [b for b in blocks if b.get("ROOM") != "archive"]
    if not non_archive:
        return empty_frame_lines()

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

    sorted_tags = sorted(order, key=lambda t: group_sort_key(t, groups))

    lines = [TOP, content_line(SHELF_TITLE), DIV, KEY_BAND, DIV, BLANK,
             TABLE_HEADER, TABLE_UNDERLINE]

    for tag in sorted_tags:
        recs = groups[tag]
        counts = {"?": 0, "○": 0, "●": 0, "✓": 0}
        for r in recs:
            counts[r["_glyph"]] += 1
        total = len(recs)
        lines.append(tag_row(tag, counts, total))

        # Rows are grouped by glyph class first (? then ○ then ●), and only
        # WITHIN a class is decisions-list.sh's own emission order kept -
        # a claimed record earlier in emission order than the open ones
        # still prints its row after every ○ row, never before.
        pending_recs = [r for r in recs if r["_glyph"] == "?"]
        open_recs = [r for r in recs if r["_glyph"] == "○"]
        claimed_recs = [r for r in recs if r["_glyph"] == "●"]

        for r in pending_recs:
            lines.append(sub_row("?", r.get("SLUG", "")))
        for r in open_recs:
            lines.append(sub_row("○", r.get("SLUG", "")))
        if claimed_recs:
            lines.append(sub_row("●", claimed_recs[0].get("SLUG", "")))
            remaining_claimed = len(claimed_recs) - 1
            if remaining_claimed > 0:
                lines.append(more_row(remaining_claimed))
        lines.append(BLANK)

    lines.append(BOT)
    return lines


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


def wrap_lines(text, width=CONTENT_WIDTH, indent=0):
    # Wrapped continuation lines carry the same left indent as the first
    # line they continue, so a multi-line row still reads as one column.
    available = width - indent
    if not text:
        wrapped = [""]
    else:
        wrapped = textwrap.wrap(text, width=available) or [""]
    return [(" " * indent) + w for w in wrapped]


def render_archive(blocks, only_filter):
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

    title = "ARCHIVE  ·  " + only_filter if only_filter else "ARCHIVE"
    lines = [TOP, content_line(title), DIV]

    # The slug's own column: 9 chars for the label field when one prints,
    # 0 when --only= has dropped it - the exit words wrap to that same
    # column, never to the gutter.
    slug_column = 0 if only_filter else 9

    for r in records:
        if only_filter:
            first_line_text = r["slug"]
        else:
            first_line_text = r["label"].ljust(9) + r["slug"]
        for fl in wrap_lines(first_line_text):
            lines.append(content_line(fl))
        for wl in wrap_lines(r["words"], indent=slug_column):
            lines.append(content_line(wl))
        lines.append(BLANK)

    lines.append(BOT)
    return lines


# -- The card --------------------------------------------------------
# One shape, five faces: fresh (question or decision state), pending
# (state read from the file), reopen (a diff against the file) and
# retire (the file, relayed unchanged). See the module docstring above
# for the flag shape per variant.

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


# Labels ("CONTEXT", "OPTIONS CONSIDERED", ...) and the bare title sit
# at the gutter, unindented. Everything beneath a label is body text,
# indented two spaces, wrapped at 55 - so indent(2) + text(<=55) is the
# same 57-column content field every other frame uses. Ruled 2026-09-09
# at acceptance ("all caps. Don't indent them either").
BODY_TEXT_WIDTH = CONTENT_WIDTH - 2


def prefixed_wrap(prefix, text):
    # First physical line carries the marker (an option's letter or
    # dash, or a YOUR MOVE letter); continuation lines align under the
    # text, not the marker. The two-space body indent is baked into
    # every physical line here, so callers never add it twice.
    avail = max(BODY_TEXT_WIDTH - len(prefix), 1)
    chunks = textwrap.wrap(text, width=avail) or ['']
    out = ["  " + prefix + chunks[0]]
    for c in chunks[1:]:
        out.append("  " + (' ' * len(prefix)) + c)
    return out


# The store's records were authored with hard line breaks near 57
# columns; the card's body field is 55. Relaying those breaks verbatim
# left one-word orphans on nearly every line. The frame REFLOWS instead:
# consecutive non-blank source lines join into one paragraph on single
# spaces and re-wrap at 55; a blank source line ends a paragraph; a line
# beginning "- ", "(x) ", "(x) Proposed: " or "> " starts its own
# paragraph (a bullet, a lettered option, or a quote) and wraps with a
# hanging indent under its own text. No word or punctuation changes -
# only where the lines break. Ruled 2026-09-09 at acceptance, after a
# real record rendered with orphans on every other line.
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


def emit_flow(lines, text):
    for marker, ptext, blank_before in paragraphs_of(text):
        if blank_before:
            lines.append('')
        if marker:
            lines.extend(prefixed_wrap(marker, ptext))
        else:
            lines.extend(wrap_lines(ptext, width=CONTENT_WIDTH, indent=2))


def canonical_body(parsed, options, state, proposed_letter):
    # The record byte for byte in the decision state; a display
    # transform of the same section list in the question state. See
    # 2026-09-08-a-card-with-a-live-fork-reads-as-a-question-and.
    lines = [parsed['title'], "", "CONTEXT"]
    emit_flow(lines, parsed['context'])
    lines.append("")

    letters = None
    marker_letter = None
    if state == 'question':
        lines.append("YOUR OPTIONS")
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
            lines.extend(prefixed_wrap(prefix, o['text']))
        if proposed_idx is not None:
            marker_letter = letters[proposed_idx]
        else:
            marker_letter = proposed_letter or (letters[0] if letters else 'a')
    else:
        lines.append("OPTIONS CONSIDERED")
        for o in options:
            lines.extend(prefixed_wrap("- ", o['text']))

    lines.append("")
    lines.append("DECISION" + (" if ({})".format(marker_letter) if state == 'question' else ""))
    emit_flow(lines, parsed['decision'])
    lines.append("")
    lines.append("CONSEQUENCES" + (" if ({})".format(marker_letter) if state == 'question' else ""))
    emit_flow(lines, parsed['consequences'])
    lines.append("")
    lines.append("APPROVAL")
    if parsed['approval'].strip():
        emit_flow(lines, parsed['approval'])

    return lines, letters


def raw_body_lines(parsed):
    # A retire (or a reopen's base) presents the record exactly as it
    # sits on disk - never re-punctuated, never re-lettered - even a
    # legacy record whose Options are still lettered.
    lines = [parsed['title'], "", "CONTEXT"]
    emit_flow(lines, parsed['context'])
    lines.append("")
    lines.append("OPTIONS CONSIDERED")
    emit_flow(lines, parsed['options'])
    lines.append("")
    lines.append("DECISION")
    emit_flow(lines, parsed['decision'])
    lines.append("")
    lines.append("CONSEQUENCES")
    emit_flow(lines, parsed['consequences'])
    lines.append("")
    lines.append("APPROVAL")
    if parsed['approval'].strip():
        emit_flow(lines, parsed['approval'])
    return lines


def color_enabled():
    # Real usage: a TTY with NO_COLOR unset. CRAFT_DECISIONS_FORCE_COLOR
    # is a test-only override - see the module docstring.
    if os.environ.get('NO_COLOR'):
        return False
    if os.environ.get('CRAFT_DECISIONS_FORCE_COLOR'):
        return True
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


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


def colorize(row_line, marker, color):
    if marker == '-' and color:
        return "\033[31m" + row_line + "\033[0m"
    if marker == '+' and color:
        return "\033[32m" + row_line + "\033[0m"
    return row_line


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


def emit_diff_rows(lines, rows, color):
    # The diff marker lives IN the two-space body indent - "  "
    # unchanged, "- " removed, "+ " added - so a removed option bullet
    # reads "- - text" and an unchanged one reads "  - text": the
    # marker and the bullet's own dash never share a column. A marker
    # paragraph (a bullet, a lettered option, a quote) keeps its own
    # hanging indent past the diff marker. Ruled 2026-09-09.
    marker_prefix = {'': '  ', '-': '- ', '+': '+ '}
    for diff_marker, para_marker, text in rows:
        outer = marker_prefix[diff_marker]
        if para_marker:
            avail = max(BODY_TEXT_WIDTH - len(para_marker), 1)
            chunks = textwrap.wrap(text, width=avail) or ['']
            physical = [para_marker + chunks[0]]
            physical.extend((' ' * len(para_marker)) + c for c in chunks[1:])
        else:
            physical = textwrap.wrap(text, width=BODY_TEXT_WIDTH) or ['']
        for p in physical:
            lines.append(colorize(content_line(outer + p), diff_marker, color))


def reopen_diff_lines(parsed, opts):
    new_title = opts['title'] if opts['title'] is not None else parsed['title']
    new_context = opts['context'] if opts['context'] is not None else parsed['context']
    new_options = opts['options'] if opts['options'] is not None else parsed['options']
    new_decision = opts['decision'] if opts['decision'] is not None else parsed['decision']
    new_consequences = opts['consequences'] if opts['consequences'] is not None else parsed['consequences']

    color = color_enabled()
    out = []

    # The title is bare and unindented, like a label - a change marks
    # it at the gutter rather than in the body indent.
    title_marker_prefix = {'': '', '-': '- ', '+': '+ '}
    for marker, text in diff_rows(parsed['title'], new_title):
        prefix = title_marker_prefix[marker]
        for c in (textwrap.wrap(text, width=CONTENT_WIDTH - len(prefix)) or ['']):
            out.append(colorize(content_line(prefix + c), marker, color))
    out.append(content_line(''))

    out.append(content_line("CONTEXT"))
    emit_diff_rows(out, diff_paragraphs(parsed['context'], new_context), color)
    out.append(content_line(''))

    out.append(content_line("OPTIONS CONSIDERED"))
    emit_diff_rows(out, diff_paragraphs(parsed['options'], new_options), color)
    out.append(content_line(''))

    out.append(content_line("DECISION"))
    emit_diff_rows(out, diff_paragraphs(parsed['decision'], new_decision), color)
    out.append(content_line(''))

    out.append(content_line("CONSEQUENCES"))
    emit_diff_rows(out, diff_paragraphs(parsed['consequences'], new_consequences), color)
    out.append(content_line(''))

    out.append(content_line("APPROVAL"))
    if parsed['approval'].strip():
        approval_lines = []
        emit_flow(approval_lines, parsed['approval'])
        out.extend(content_line(al) for al in approval_lines)
    return out


def card_header_line1(status, tags, source, new_group_tag):
    # Status, tags and source share this line; the dated slug gets its
    # own line below so a long slug never wraps mid-word. Ruled
    # 2026-09-09 at acceptance, after a 45-character slug wrapped.
    tag_parts = []
    for t in tags:
        tag_parts.append(t + " (NEW GROUP)" if new_group_tag and t == new_group_tag else t)
    tags_text = ", ".join(tag_parts) if tag_parts else "(no tags)"
    return "{}  ·  tags: {}  ·  source: {}".format(status.upper() if status else "", tags_text, source)


def claim_row_text(story, status):
    left = "  " + story
    if not status:
        return left
    pad = max(CONTENT_WIDTH - len(left) - len(status), 1)
    return left + (" " * pad) + status


def move_row(letter, move, effect):
    # Continuation lines align under the effect text, past the letter
    # and move columns, so a long effect still reads as one row.
    prefix = "{}) {}  ".format(letter, move.ljust(14))
    return prefixed_wrap(prefix, effect)


def moves_for(variant, state, letters):
    moves = []

    if variant == 'reopen':
        letter_list = ['a']
        moves.extend(move_row('a', 'approve', 'the law changes to this'))
    elif variant == 'retire':
        letter_list = ['a']
        moves.extend(move_row('a', 'retire', 'no longer applies, goes to the archive with your words'))
    elif state == 'question':
        n = len(letters) if letters else 0
        for letter in letters:
            moves.extend(move_row(letter, 'pick', 'picks this option and redraws'))
        keep_letter = chr(ord('a') + n)
        letter_list = list(letters) + [keep_letter]
        effect = ("saved on the Shelf as a question, decide later" if variant == 'fresh'
                  else "saves your changes, stays on the Shelf")
        moves.extend(move_row(keep_letter, 'keep pending', effect))
    else:
        letter_list = ['a', 'b', 'c']
        if variant == 'fresh':
            moves.extend(move_row('a', 'approve', 'what it becomes, and what gets built to it'))
            moves.extend(move_row('b', 'keep pending', 'saved on the Shelf, decide later'))
            moves.extend(move_row('c', 'decline', 'goes to the archive with your words, never re-proposed'))
        else:
            moves.extend(move_row('a', 'approve', 'moves to approved/ as shown'))
            moves.extend(move_row('b', 'keep pending', 'saves your changes, stays on the Shelf'))
            moves.extend(move_row('c', 'decline', 'moves to the archive with your words'))

    closing = ", ".join(letter_list) + ", or just tell me what to change."
    return moves, closing


def render_card(opts):
    variant = opts['variant']

    if opts['claimed_by'] and opts['shipped_by']:
        sys.stderr.write("Error: --claimed-by= and --shipped-by= are mutually exclusive\n")
        sys.exit(1)

    letters = None
    state = None
    framed_body = None
    plain_body = None

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
        plain_body, letters = canonical_body(parsed, options, state, opts['proposed'])

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
        plain_body, letters = canonical_body(parsed, options, state, proposed_letter)

    elif variant == 'retire':
        text = read_file_required(opts['file'])
        parsed = parse_record_text(text)
        dated_slug = dated_slug_from_path(opts['file'])
        plain_body = raw_body_lines(parsed)

    elif variant == 'reopen':
        text = read_file_required(opts['file'])
        parsed = parse_record_text(text)
        dated_slug = dated_slug_from_path(opts['file'])
        framed_body = reopen_diff_lines(parsed, opts)

    else:
        sys.stderr.write("Error: --variant= must be fresh, pending, reopen or retire\n")
        sys.exit(1)

    lines = [TOP]
    header1 = card_header_line1(parsed['status'], parsed['tags'], parsed['source'], opts['new_group'])
    for wl in wrap_lines(header1, width=CONTENT_WIDTH, indent=0):
        lines.append(content_line(wl))
    lines.append(content_line(dated_slug))
    lines.append(DIV)

    if framed_body is not None:
        lines.extend(framed_body)
    else:
        lines.extend(content_line(t) for t in plain_body)

    lines.append(DIV)

    if opts['claimed_by']:
        lines.append(content_line("CLAIMED BY STORIES"))
        for story, status in opts['claimed_by']:
            lines.append(content_line(claim_row_text(story, status)))
        lines.append(DIV)
    elif opts['shipped_by']:
        lines.append(content_line("SHIPPED BY STORY"))
        lines.append(content_line("  " + opts['shipped_by']))
        lines.append(DIV)

    lines.append(content_line("YOUR MOVE"))
    moves, closing = moves_for(variant, state, letters)
    lines.extend(content_line(mv) for mv in moves)
    lines.append(content_line(""))
    lines.append(content_line(closing))
    lines.append(BOT)
    return lines


def main():
    if SUBCOMMAND == "archive":
        data = read_piped_input()
        blocks = parse_blocks(data)
        lines = render_archive(blocks, ONLY)
    elif SUBCOMMAND == "card":
        lines = render_card(CARD_OPTS)
    else:
        data = read_piped_input()
        blocks = parse_blocks(data)
        lines = render_shelf(blocks)
    sys.stdout.write("\n".join(lines) + "\n")


main()
PYEOF
