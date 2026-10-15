"""Annotation parser: annotations/<date-slug>/record.md.

The record is what one /craft:annotate run filed: its pins, its session.css
and where it graduated to. Live session folders beside it hold no record.md,
so they never reach this parser.
"""

import os

from . import body as body_mod
from . import identity
from .parse_fix import field_link


def parse(path, craft_rel, fields, body):
    stem = os.path.basename(os.path.dirname(craft_rel))
    nid = identity.node_id("annotation", craft_rel)
    node = {
        "id": nid,
        "type": "annotation",
        "title": body_mod.humanize(fields.get("subject") or stem),
        "date": fields.get("created") or None,
        "status": fields.get("status") or None,
        "tags": [],
        "surface": None,
        "_path": craft_rel,
        "_name": fields.get("name") or stem,
        "_warnings": [],
    }
    if fields.get("source") != "annotate":
        node["_warnings"].append(
            "annotation record has no `source: annotate` in its frontmatter"
        )
    links = []
    annotations = []
    field_link(nid, fields, "annotation", "graduated_to", links, annotations)
    return node, links, annotations
