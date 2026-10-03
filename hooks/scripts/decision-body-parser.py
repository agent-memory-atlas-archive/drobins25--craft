#!/usr/bin/env python3
"""The record-body grammar, in one place, for every script that reads a
record typed on stdin.

Usage: decision-body-parser.py "<body text>"

The body travels as argv[1] - never stdin - because the eval sandbox
refuses opening /dev/stdin by path and a caller's heredoc may own stdin.

Grammar: an optional first non-blank "# <title>" line, then sections each
opened by a line exactly "## Context", "## Options considered",
"## Decision", "## Consequences" or "## Approval". A section's text is its
lines joined by newlines with leading and trailing newlines stripped.

Output: one KEY=<base64 of the UTF-8 value> line per section found, KEY in
TITLE CONTEXT OPTIONS DECISION CONSEQUENCES APPROVAL, in the order found.
A section that is present but empty prints "KEY=" - the output is raw, and
each caller decides what an empty section means. An absent section prints
no line.

Errors exit 1 with a message on stderr: a repeated heading, an unknown
"## " heading, or text before the first heading.
"""
import base64
import sys

SECTIONS = {
    '## Context': 'CONTEXT',
    '## Options considered': 'OPTIONS',
    '## Decision': 'DECISION',
    '## Consequences': 'CONSEQUENCES',
    '## Approval': 'APPROVAL',
}


def parse(text):
    found = {}
    current = None
    buf = []
    title_seen = False

    def close():
        if current is not None:
            found[current] = '\n'.join(buf).strip('\n')

    for line in text.split('\n'):
        if line in SECTIONS:
            key = SECTIONS[line]
            if key == current or key in found:
                sys.stderr.write("Error: repeated heading '{}' on stdin\n".format(line))
                sys.exit(1)
            close()
            current, buf = key, []
        elif line.startswith('## '):
            sys.stderr.write("Error: unknown heading '{}' on stdin\n".format(line))
            sys.exit(1)
        elif current is not None:
            buf.append(line)
        elif line.strip() == '':
            continue
        elif not title_seen and line.startswith('# '):
            title_seen = True
            found['TITLE'] = line[2:]
        else:
            sys.stderr.write("Error: text before the first section heading on stdin: '{}'\n".format(line))
            sys.exit(1)
    close()
    return found


def main():
    if len(sys.argv) != 2:
        sys.stderr.write('Usage: decision-body-parser.py "<body text>"\n')
        sys.exit(2)
    for key, value in parse(sys.argv[1]).items():
        sys.stdout.write('{}={}\n'.format(key, base64.b64encode(value.encode('utf-8')).decode('ascii')))


if __name__ == '__main__':
    main()
