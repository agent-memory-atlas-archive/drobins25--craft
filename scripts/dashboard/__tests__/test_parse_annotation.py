import os
import shutil
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))
sys.path.insert(0, _HERE)

from src import assemble, registry, resolve

RECORD_REL = "annotations/2026-10-04-hero/record.md"

RECORD = """---
source: annotate
name: 2026-10-04-hero
created: 2026-10-04
subject: Hero polish
status: graduated
outcome: story
graduated_to: hero-polish
session: 123-456
seq_from: 0
seq_to: 2
pin_count: 1
rule_count: 1
---

# Hero polish

## Pins

1. "Make the hero button larger" - `.hero .btn`

Second paragraph.

## Sheet

`session.css` beside this file is normative.
"""

STORY = """---
name: hero-polish
annotate: 2026-10-04-hero
status: backlog
---

# Hero polish

## Spark

Make the hero button larger.
"""


def _parse(text=RECORD, rel=RECORD_REL):
    return registry.parse_file("annotation", rel, text)


class TestParseAnnotation(unittest.TestCase):
    def test_a_record_parses_to_an_annotation_node_with_subject_title_date_and_status(self):
        node, _, _ = _parse()
        self.assertEqual(node["type"], "annotation")
        self.assertEqual(node["title"], "Hero polish")
        self.assertEqual(node["date"], "2026-10-04")
        self.assertEqual(node["status"], "graduated")
        self.assertEqual(node["_name"], "2026-10-04-hero")
        self.assertEqual(node["_warnings"], [])

    def test_title_falls_back_to_the_humanized_folder_stem(self):
        text = RECORD.replace("subject: Hero polish\n", "").replace("name: 2026-10-04-hero\n", "")
        node, _, _ = _parse(text)
        self.assertEqual(node["_name"], "2026-10-04-hero")
        self.assertTrue(node["title"])
        self.assertNotIn("-", node["title"])

    def test_graduated_to_links_to_a_story(self):
        _, links, _ = _parse()
        graduated = [l for l in links if l["kind"] == "graduated_to"]
        self.assertEqual(len(graduated), 1)
        self.assertEqual(graduated[0]["raw_value"], "hero-polish")

    def test_an_empty_graduated_to_emits_no_link(self):
        text = RECORD.replace("graduated_to: hero-polish", "graduated_to:")
        _, links, _ = _parse(text)
        self.assertEqual([l for l in links if l["kind"] == "graduated_to"], [])

    def test_a_record_without_source_annotate_carries_a_warning(self):
        node, _, _ = _parse(RECORD.replace("source: annotate\n", ""))
        self.assertEqual(len(node["_warnings"]), 1)

    def test_summary_is_the_first_paragraph_of_pins(self):
        from src import summary
        body = RECORD.split("---\n", 2)[2]
        text = summary.extract("annotation", {}, body)
        self.assertIn("Make the hero button larger", text)
        self.assertNotIn("Second paragraph", text)
        self.assertFalse(text.startswith("1."))


class TestAnnotationEndToEnd(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        craft = os.path.join(self.root, ".craft")
        files = {
            RECORD_REL: RECORD,
            "annotations/2026-10-04-hero/session.css": ".a{color:red}\n",
            "annotations/123-456/current.json": "[]",
            "annotations/123-456/history.jsonl": "",
            "annotations/123-456/run.json": "{}",
            "annotations/123-456/port": "1",
            "annotations/.gitignore": "*\n",
            "backlog/hero-polish.md": STORY,
        }
        for rel, text in files.items():
            full = os.path.join(craft, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as handle:
                handle.write(text)
        self.graph = assemble.build(self.root)["graph"]

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def _id(self, node_type):
        return [n["id"] for n in self.graph["nodes"] if n["type"] == node_type]

    def test_one_annotation_node_an_annotate_edge_a_graduated_to_edge_and_no_live_node(self):
        annotation = self._id("annotation")
        story = self._id("story")
        self.assertEqual(len(annotation), 1)
        self.assertEqual(len(story), 1)
        self.assertEqual(len(self.graph["nodes"]), 2)
        edges = {(e["source"], e["target"], e["kind"]) for e in self.graph["edges"]}
        self.assertIn((story[0], annotation[0], "annotate"), edges)
        self.assertIn((annotation[0], story[0], "graduated_to"), edges)

    def test_live_session_files_are_not_records_and_the_sheet_is_a_citation_target(self):
        self.assertIsNone(registry.classify("annotations/123-456/current.json"))
        self.assertIsNone(registry.classify("annotations/123-456/history.jsonl"))
        self.assertIsNone(registry.classify("annotations/.gitignore"))
        self.assertIsNone(registry.classify("annotations/123-456/run.json"))
        self.assertEqual(registry.classify(RECORD_REL), "annotation")

    def test_a_citation_to_a_records_session_css_resolves_to_the_record_node(self):
        craft = os.path.join(self.root, ".craft")
        with open(os.path.join(craft, "backlog", "citer.md"), "w") as handle:
            handle.write(
                "---\nname: citer\nstatus: backlog\n---\n\n# Citer\n\n"
                "## Spark\n\nSee `.craft/annotations/2026-10-04-hero/session.css`.\n"
            )
        graph = assemble.build(self.root)["graph"]
        citer = [n["id"] for n in graph["nodes"] if n["id"].endswith("citer")][0]
        record = [n["id"] for n in graph["nodes"] if n["type"] == "annotation"][0]
        self.assertIn(
            (citer, record),
            {(e["source"], e["target"]) for e in graph["edges"]},
        )


if __name__ == "__main__":
    unittest.main()
