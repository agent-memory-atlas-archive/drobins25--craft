import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))
sys.path.insert(0, _HERE)

from src import registry, summary, vocabulary

OPEN = "bugs/2026-10-01-widget-crashes.md"
CLOSED = "bugs/closed/2026-10-01-widget-crashes.md"

OPEN_TEXT = """---
type: bug
created: 2026-10-01
captured_at: 2026-10-01T10:00:00Z
status: open
verdict:
found_during: test automation against the sheet
layer: code
hits: 1
tags: [ui, crash]
---

The widget crashes on empty input

## What happened

It threw on an empty string.

## Consequences

Users lose their draft.

More detail here.
"""

CLOSED_TEXT = OPEN_TEXT.replace("status: open", "status: fixed")

OLD_TEXT = """---
type: bug
created: 2026-09-01
status: open
found_by: a reviewer
---

Old shape symptom
"""


def _parse(rel, text):
    return registry.parse_file("bug", rel, text)


class TestClassify(unittest.TestCase):
    def test_dated_records_are_bugs_prototype_docs_are_not(self):
        self.assertEqual(registry.classify("bugs/2026-10-01-x.md"), "bug")
        self.assertEqual(registry.classify("bugs/closed/2026-10-01-x.md"), "bug")
        self.assertIsNone(registry.classify("bugs/README.md"))
        self.assertIsNone(registry.classify("bugs/_TEMPLATE.md"))


class TestParseBug(unittest.TestCase):
    def test_open_record_envelope(self):
        node, links, annotations = _parse(OPEN, OPEN_TEXT)
        self.assertEqual(node["type"], "bug")
        self.assertEqual(node["title"], "The widget crashes on empty input")
        self.assertEqual(node["date"], "2026-10-01")
        self.assertEqual(node["status"], "open")
        self.assertEqual(node["found_during"], "test automation against the sheet")
        self.assertEqual(node["tags"], ["ui", "crash"])
        self.assertEqual((links, annotations), ([], []))

    def test_closed_fixed_record_is_fixed(self):
        node, _, _ = _parse(CLOSED, CLOSED_TEXT)
        self.assertEqual(node["status"], "fixed")

    def test_closed_wont_fix_record(self):
        node, _, _ = _parse(CLOSED, OPEN_TEXT.replace("status: open", "status: wont-fix"))
        self.assertEqual(node["status"], "wont-fix")

    def test_closed_record_claiming_open_has_no_status(self):
        node, _, _ = _parse(CLOSED, OPEN_TEXT)
        self.assertIsNone(node["status"])

    def test_open_room_ignores_a_fixed_status_word(self):
        node, _, _ = _parse(OPEN, CLOSED_TEXT)
        self.assertEqual(node["status"], "open")

    def test_old_record_reads_found_by(self):
        node, _, _ = _parse(OPEN, OLD_TEXT)
        self.assertEqual(node["found_during"], "a reviewer")

    def test_missing_found_during_is_none(self):
        node, _, _ = _parse(OPEN, "---\ntype: bug\n---\n\nJust a symptom\n")
        self.assertIsNone(node["found_during"])


    def test_long_title_cuts_at_a_word_with_an_ellipsis(self):
        long_line = ("A monorepo opened at its top level files bugs and notebook entries "
                     "into the top-level folder, where no project session ever lists them")
        text = OPEN_TEXT.replace("The widget crashes on empty input", long_line)
        node, _, _ = _parse(OPEN, text)
        self.assertTrue(node["title"].endswith("\u2026"), node["title"])
        self.assertTrue(long_line.startswith(node["title"][:-1]), node["title"])
        self.assertTrue(long_line[len(node["title"]) - 1] == " ", node["title"])
        self.assertLessEqual(len(node["title"]), 121)

    def test_short_title_is_untouched(self):
        node, _, _ = _parse(OPEN, OPEN_TEXT)
        self.assertEqual(node["title"], "The widget crashes on empty input")


class TestBugVocabulary(unittest.TestCase):
    def test_statuses_have_display_words(self):
        self.assertEqual(vocabulary.STATUSES["fixed"], "Fixed")
        self.assertEqual(vocabulary.STATUSES["wont-fix"], "Won't fix")

    def test_summary_prefers_consequences_then_what_happened(self):
        _, body = None, OPEN_TEXT.split("---\n", 2)[2]
        self.assertEqual(summary.extract("bug", {}, body), "Users lose their draft.")
        no_cons = body.split("## Consequences")[0]
        self.assertEqual(summary.extract("bug", {}, no_cons), "It threw on an empty string.")


if __name__ == "__main__":
    unittest.main()
