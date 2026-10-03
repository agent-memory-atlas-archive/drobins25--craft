"""Bug parser: filed defects, open (bugs/) and closed (bugs/closed/).

Status derives from the folder first: anything outside closed/ is open,
whatever the frontmatter says. A closed record carries the verdict the
close script stamped (fixed or wont-fix); a closed record with any other
status word gets None rather than a guessed one. Bug records link to
nothing, so there are no edges and no annotations. The title is the first
non-blank body line (the symptom); found_during falls back to the older
found_by field.
"""

from . import identity

_TITLE_LIMIT = 120
_CLOSED_STATUSES = ("fixed", "wont-fix")


def parse(path, craft_rel, fields, body):
    node = {
        "id": identity.node_id("bug", craft_rel),
        "type": "bug",
        "title": _first_body_line(body),
        "date": fields.get("created") or None,
        "status": _status(craft_rel, fields),
        "found_during": fields.get("found_during") or fields.get("found_by") or None,
        "tags": _tags(fields),
        "surface": None,
        "_path": craft_rel,
        "_name": "",
        "_warnings": [],
    }
    return node, [], []


def _status(craft_rel, fields):
    if not craft_rel.startswith("bugs/closed/"):
        return "open"
    status = fields.get("status")
    return status if status in _CLOSED_STATUSES else None


def _first_body_line(body):
    for line in body.split("\n"):
        line = line.strip()
        if line:
            return line[:_TITLE_LIMIT]
    return "(empty bug)"


def _tags(fields):
    tags = fields.get("tags")
    if isinstance(tags, list):
        return tags
    if tags:
        return [tags]
    return []
