#!/bin/bash
# decisions-view.sh - Derives every view the decisions desk shows the user
# (the DECISION SHELF, one group drawer, the empty state, the archive, and
# the reopen card) from decisions-list.sh's
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
#     under --only=) and the record's title, then its exit words as
#     further ROW= lines indented to the same column, newest exit first,
#     then CLOSE=.
#
#   decisions-view.sh match [--words=<searched words>]
#     stdin: decisions-list.sh blocks for a selection that matched more
#     than one record (any filters already applied by the caller). Emits
#     BAND=<count> MATCH "<words>" (the quoted words segment dropped when
#     --words= is absent or empty), the Shelf's key band extended with
#     "× archived", a BLANK=, one HEAD= per block in stdin order - the
#     glyph, two spaces, the block's TITLE= verbatim - a BLANK=, the
#     closing HEAD=, then CLOSE=. This is the drawer that asks the user to
#     name one record when their words resolved to several.
#
#   decisions-view.sh card --variant=reopen --file=<path>
#       [--context= --options= --decision= --consequences= --title=]
#       [--claimed-by=<story>:<status> ...] [--shipped-by=<story>] [--stdin]
#     --variant=reopen is the only variant; any other exits non-zero. The
#     card takes --file= for the base record plus the proposed sections,
#     and diffs them against the file. The proposed sections come as
#     flags, or on stdin with --stdin (never both): a record-format body -
#     an optional `# <title>` line, then `## Context`,
#     `## Options considered`, `## Decision`, `## Consequences`; a
#     `## Approval` section is ignored, any other `## ` heading is
#     refused.
#     The card emits BAND=/HEAD=/BLANK=/DIV=/ROW=/CLOSE= data, same
#     vocabulary as the Shelf: body text wraps at 65 columns with hyphens
#     never treated as a break point, and every `> ` line of the Approval
#     section is its own ROW=, byte-identical to the file. reopen's title
#     and body rows carry an extra MARK=-|+| key naming which way a row
#     changed - the drawing rule colours it; this script emits no ANSI
#     escape of its own.
#
# Resolves no project root, reads no environment variable for one, and
# globs nothing under .craft/ - the only files this script opens are the
# exact FILE= paths handed to it on stdin.
#
# Exit 0 is success. Exit 1 is any of: an unknown flag (stderr
# "Error: unknown flag '<argument>'", nothing on stdout - each mode accepts
# only its own flags, and a flag in the subcommand position is unknown), a
# --variant= other than reopen, a missing or unreadable --file=,
# --claimed-by= together with --shipped-by=, --stdin together with a
# section flag, or a --stdin body the shared stdin grammar refuses.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The python heredoc below occupies stdin (fd 0) with the script itself, so
# the piped decisions-list.sh output is saved to fd 3 first and read back
# from there - the house heredoc idiom, extended to also relay real input.
exec 3<&0

DECISION_BODY_PARSER="$SCRIPT_DIR/decision-body-parser.py" python3 - "$@" <<'PYEOF'
import sys, os, re, textwrap, difflib, subprocess, base64

ARGS = sys.argv[1:]
SUBCOMMAND = ARGS[0] if ARGS else ''
ONLY = ''
WORDS = ''
for a in ARGS[1:]:
    if a.startswith('--only='):
        ONLY = a[len('--only='):]
    elif a.startswith('--words='):
        WORDS = a[len('--words='):]


def parse_card_args(args):
    opts = {
        'variant': '', 'file': '',
        'context': None, 'options': None, 'decision': None,
        'consequences': None, 'title': None,
        'claimed_by': [], 'shipped_by': '', 'stdin': False,
    }
    for a in args:
        if a.startswith('--variant='):
            opts['variant'] = a[len('--variant='):]
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
        elif a.startswith('--claimed-by='):
            v = a[len('--claimed-by='):]
            story, _, status = v.partition(':')
            opts['claimed_by'].append((story, status))
        elif a.startswith('--shipped-by='):
            opts['shipped_by'] = a[len('--shipped-by='):]
        elif a == '--stdin':
            opts['stdin'] = True
    return opts


def parse_stdin_body(text):
    # The record-format body the reopen face accepts on --stdin. The grammar
    # lives in one parser shared with the capture script, so the card and
    # the write can never read the same typed text two ways. A present but
    # empty section stays '' and an absent one stays None. A malformed body
    # makes the parser exit non-zero after naming the problem on stderr
    # (inherited here), and the view exits 1 before printing anything.
    proc = subprocess.run([sys.executable, os.environ['DECISION_BODY_PARSER'], text],
                          stdout=subprocess.PIPE)
    if proc.returncode != 0:
        sys.exit(1)
    found = {}
    for line in proc.stdout.decode('ascii').split('\n'):
        key, sep, b64 = line.partition('=')
        if sep:
            found[key] = base64.b64decode(b64).decode('utf-8')
    sections = {k.lower(): v for k, v in found.items() if k != 'TITLE'}
    return found.get('TITLE'), sections


# Each mode owns its own flags: a prefix ends in '=', an exact flag does not.
# Unknown means unknown to the mode being run, so a flag another mode owns is
# refused here, and any subcommand that is not a named mode is the Shelf.
FLAGS_BY_MODE = {
    'archive': ('--only=',),
    'match': ('--words=',),
    'card': ('--variant=', '--file=', '--context=', '--options=', '--decision=',
             '--consequences=', '--title=', '--claimed-by=', '--shipped-by=',
             '--stdin'),
}


def refuse_unknown_flags(args):
    # Runs before anything is read or printed, so a refusal leaves no output
    # and touches no file. A first argument that is itself a flag is refused
    # too: it would otherwise fall through to the Shelf and be swallowed.
    allowed = FLAGS_BY_MODE.get(args[0], ()) if args else ()
    for i, a in enumerate(args):
        if not a.startswith('--'):
            continue
        if i > 0 and any(a == f or (f.endswith('=') and a.startswith(f)) for f in allowed):
            continue
        sys.stderr.write("Error: unknown flag '%s'\n" % a)
        sys.exit(1)


refuse_unknown_flags(ARGS)
CARD_OPTS = parse_card_args(ARGS[1:]) if SUBCOMMAND == 'card' else None

SHELF_TITLE = 'DECISION SHELF'
KEY_BAND_TEXT = '? pending   ○ unclaimed   ● claimed   ✓ done'
# The match drawer's own key band: the Shelf's band plus the one glyph a
# Shelf row never carries, since the drawer is the only view that ever
# shows an archived record alongside live ones.
MATCH_KEY_BAND_TEXT = KEY_BAND_TEXT + '   × archived'
ARCHIVE_GLYPH = '×'


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


def display_title(block):
    # The name a row gives a record: its title, never cut. decisions-list.sh
    # fills TITLE with the full dated slug when a record has no H1, and a
    # date on a Shelf row reads as noise, so that case draws the slug alone.
    slug = block.get("SLUG", "")
    title = block.get("TITLE", "")
    if title and title != slug:
        return title
    return strip_date(slug)


GLYPH_ORDER = ["?", "○", "●", "✓"]

# The card wraps body text at 65 columns with hyphens never treated as a break point: the width
# and setting that reproduce story 7's card exhibit line for line from a
# real record on disk (`textwrap.wrap(t, 65, break_on_hyphens=False)`;
# the default hyphen setting splits "(over-prescriptive)" across lines
# and the exhibit does not). The rail supplies the four-space gutter
# these rows draw under, so nothing here bakes in a leading indent of
# its own. The archive view wraps exit words at this width too.
CARD_DATA_WIDTH = 65


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
        lines.append(kv("ROW", "? " + display_title(r)))
    for r in open_recs:
        lines.append(kv("ROW", "○ " + display_title(r)))
    if claimed_recs:
        lines.append(kv("ROW", "● " + display_title(claimed_recs[0])))
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
        {"_glyph": "○", "SLUG": "the-gameroom-has-a-slot-machine", "TITLE": "The gameroom has a slot machine"},
        {"_glyph": "○", "SLUG": "the-slot-machine-has-a-bonus-round", "TITLE": "The slot machine has a bonus round"},
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


def match_glyph_for(block):
    # Archived blocks draw the cross regardless of status or disposition -
    # glyph_for() never sees ROOM=archive from any other view (the Shelf
    # and the retag receipt both drop archive blocks before it runs), so
    # the archive case is decided here rather than folded into it.
    if block.get("ROOM") == "archive":
        return ARCHIVE_GLYPH
    return glyph_for(block)


def render_match_view(blocks, words):
    band = "{} MATCH".format(len(blocks))
    if words:
        band += ' "{}"'.format(words)
    lines = [
        kv("BAND", band),
        kv("HEAD", MATCH_KEY_BAND_TEXT),
        kv("BLANK"),
    ]
    for b in blocks:
        glyph = match_glyph_for(b)
        lines.append(kv("HEAD", glyph + "  " + b.get("TITLE", "")))
    lines.append(kv("BLANK"))
    lines.append(kv("HEAD", "Name one, or narrow it."))
    lines.append(kv("CLOSE"))
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
            "name": display_title(b),
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
    # Wrap width is CARD_DATA_WIDTH minus that indent - the same width
    # the card wraps its body at, expressed once.
    slug_column = 0 if only_filter else 9
    wrap_width = max(CARD_DATA_WIDTH - slug_column, 1)

    for r in records:
        if only_filter:
            first_line_text = r["name"]
        else:
            first_line_text = r["label"].ljust(9) + r["name"]
        lines.append(kv("ROW", first_line_text))
        wrapped_words = textwrap.wrap(r["words"], width=wrap_width) if r["words"] else []
        for w in wrapped_words:
            lines.append(kv("ROW", (" " * slug_column) + w))
        lines.append(kv("BLANK"))

    lines.append(kv("CLOSE"))
    return lines


# -- The card --------------------------------------------------------
# One face: reopen, a diff of the proposed sections against the file.
# See the module docstring above for its flags. It draws as data from
# reopen_body_data further down.

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


# CARD_DATA_WIDTH (65, defined with the module constants above) is the
# width the card wraps body text at; see its comment for why 65 and
# why hyphens never break.

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
        # reopen row ran up to two columns past the card's 65.
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
    # The reopen face's diff, as DIV=/MARK=/ROW=/HEAD=/BLANK= data in
    # the same vocabulary the Shelf draws from. The title is a label, not a section body, so its diff rides HEAD= at
    # the gutter rather than ROW= in the body indent. APPROVAL is never
    # diffed - it is relayed verbatim, so the
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


def card_band_text(status, tags, source):
    # The BAND= text the card draws from: single spaces around each `·`,
    # since there is no fixed width left to justify against.
    tags_text = ", ".join(tags) if tags else "(no tags)"
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


def moves_for_data():
    # The reopen face's one letter and effect, as ROW= values, and the
    # closing line that names it.
    moves = move_row_data('a', 'approve', 'the law changes to this')
    return moves, "a, or just tell me what to change."


def render_card_reopen_data(opts):
    # The reopen face's diff, as BAND=/HEAD=/BLANK=/DIV=/MARK=/ROW=/
    # CLOSE= data. The title diff rides HEAD= lines marked -/+ in place
    # of a plain title line.
    if opts['claimed_by'] and opts['shipped_by']:
        sys.stderr.write("Error: --claimed-by= and --shipped-by= are mutually exclusive\n")
        sys.exit(1)

    if opts['stdin']:
        if any(opts[k] is not None for k in ('title', 'context', 'options', 'decision', 'consequences')):
            sys.stderr.write("Error: --stdin cannot be combined with --title= or a section flag\n")
            sys.exit(1)
        # The draw happens before the answer exists, so a stdin Approval
        # section is parsed for the grammar and then ignored.
        title, sections = parse_stdin_body(read_piped_input())
        opts['title'] = title
        for k in ('context', 'options', 'decision', 'consequences'):
            opts[k] = sections.get(k)

    text = read_file_required(opts['file'])
    parsed = parse_record_text(text)
    dated_slug = dated_slug_from_path(opts['file'])

    lines = [
        kv("BAND", card_band_text(parsed['status'], parsed['tags'], parsed['source'])),
        kv("HEAD", dated_slug),
        kv("BLANK"),
    ]
    lines.extend(reopen_body_data(parsed, opts))

    if opts['claimed_by']:
        lines.extend(claimed_by_rows_data(opts['claimed_by']))
    elif opts['shipped_by']:
        lines.extend(shipped_by_row_data(opts['shipped_by']))

    lines.append(kv("DIV", "YOUR MOVE"))
    moves, closing = moves_for_data()
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
    elif SUBCOMMAND == "match":
        data = read_piped_input()
        blocks = parse_blocks(data)
        lines = render_match_view(blocks, WORDS)
    elif SUBCOMMAND == "card":
        if CARD_OPTS['variant'] == 'reopen':
            lines = render_card_reopen_data(CARD_OPTS)
        else:
            sys.stderr.write("Error: --variant= must be reopen\n")
            sys.exit(1)
    else:
        data = read_piped_input()
        blocks = parse_blocks(data)
        lines = render_shelf_view(blocks)
    sys.stdout.write("\n".join(lines) + "\n")


main()
PYEOF
