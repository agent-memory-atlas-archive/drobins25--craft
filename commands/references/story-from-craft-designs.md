# Story From Craft Designs (reference - read inline by craft:story-new Step 2.5 and by craft:cycle-design default mode Step 2.7)

One source for every design waiting to be built: mockups that converged or were parked, and annotate runs still open. This file owns four things only: the search, the list, the pick and the hand-off. It writes no story and no record text. Each design is built by its existing graduation reference, which does all the pre-fill and graduation; this file hands it the record path.

This flow asks no questions through a widget - there is no AskUserQuestion anywhere in it, because the callers have already spent their question budget or run where batch-saving is in play. Where a choice is needed, ask in plain conversation.

## Search

Find the project root first: `$CRAFT_PROJECT_ROOT` when it is set, else the folder the before-init lookup prints, so a design saved before `/craft:init` is still found. Nothing here assigns or exports `CRAFT_PROJECT_ROOT`; it keeps meaning "a set-up project".

```bash
ROOT="${CRAFT_PROJECT_ROOT:-}"
[ -n "$ROOT" ] || ROOT=$(bash -c 'source "$1" >/dev/null 2>&1; craft_before_init_root' _ "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/find-workshop.sh")
ROOT="${ROOT%/}"
echo "ROOT $ROOT"
for r in "$ROOT"/.craft/mockups/*/record.md; do
  [ -f "$r" ] || continue
  if grep -qE '^status: (converged|parked)$' "$r"; then echo "MOCKUP $r"; fi
done
for r in "$ROOT"/.craft/annotations/*/record.md; do
  [ -f "$r" ] || continue
  if grep -q '^status: open' "$r" && ! grep -q '^outcome: error' "$r"; then echo "ANNOTATE $r"; fi
done
```

The output is a `ROOT <folder>` line, then one `MOCKUP <record.md path>` line per waiting mockup, then one `ANNOTATE <record.md path>` line per waiting run. Nothing waiting prints only the ROOT line.

What waits:

- **A mockup** waits when its status is exactly `converged` or `parked` - finished looking, no destination yet. Graduated, in-progress and abandoned mockups do not.
- **An annotate run** waits when its status is `open` and it was not cut short. A run saved by start-up cleanup after its window closed (`outcome: error`) is a frozen in-progress run nobody confirmed; finishing it belongs to `/craft:annotate`, so it is never offered here.
- Dials are not designs and are never listed.

**Counts phrase** (for a caller's question text): `<N> mockup` or `<N> mockups`, then `<M> annotate run` or `<M> annotate runs`, comma-joined, mockups first, a zero kind left out. For example "2 mockups, 1 annotate run". Count the MOCKUP and ANNOTATE lines, never the folders on disk.

## Pick

Read each waiting record's first lines so the list can say what it holds: a mockup's `## Brief`, an annotate run's `subject`.

- **The conversation named a design.** The caller says so. Resolve the name against the waiting records and go straight to the Hand-off with no confirm.
- **The name matches nothing waiting.** Say so in one plain line ("[name] is not waiting to be built"), then take the caller's normal path.
- **Exactly one waiting design.** Say `Building from [slug] - that one?` in conversation, not a list of one. A yes goes to the Hand-off.
- **Several.** List them in conversation: kind, record name and one line each (the Brief or the subject), then ask which to build from. Same wording rule as the graduation references - no AskUserQuestion; the caller already spent its question budget.
- **A no, or "none of these".** Return to the caller's freeform path.

## Hand-off

The chosen record's `record.md` path goes to its graduation reference, read inline with the Read tool, never via the Skill tool (a Skill call breaks control flow back to the caller):

```
Read "${CLAUDE_PLUGIN_ROOT}/commands/references/story-from-mockup.md"
```

for a mockup, or

```
Read "${CLAUDE_PLUGIN_ROOT}/commands/references/story-from-annotate.md"
```

for an annotate run. Hand it the record path so its Phase 1 uses that record and skips its own pick. Tell it to write the story at the absolute `<root>/.craft/backlog/<story-name>.md` (the ROOT line from the Search) instead of its relative target, so the story lands in the right folder even before `/craft:init`.

When the caller is not story-new, first Read the Step 10 frontmatter block from `${CLAUDE_PLUGIN_ROOT}/commands/craft-story-new.md`; the graduation references point at it for the standard story frontmatter.

When the graduation reference reaches "The parent flow is DONE", that design's story is written. What follows belongs to the caller.
