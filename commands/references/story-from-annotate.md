# Story From Annotate (reference - read inline by story-from-craft-designs.md and by the annotate "story" exit)

Transforms an annotate record into a story. The annotate run IS the extraction - no Explore agent, no gap-fill interview. The user pointed at a live page, watched changes land on it, and approved what they saw. Scope and data shape still go through the normal story machinery (content-spark and alignment run on the created story like any other).

**The record's `session.css` holds every change shown live, one keyed block per pin, and it is exactly what the user saw on the page.** Rule: session.css values port verbatim for how things look - implementers never reinterpret a look from appearance. A block that stands in for content (text swapped through `content:`, a new piece drawn in CSS) is not a look: it graduates as a Scope requirement quoting the pin, with what was shown live, never as a binding row or ported CSS. Read the CSS to tell which blocks those are; there is no list of kinds. Pin selectors are anchors for finding the element, never ported as structural selectors: a selector like `div.toolbar > button.save` breaks the moment the markup shifts, while the rule's values stay true.

This flow asks no questions through a widget - there is no AskUserQuestion anywhere in it, because the annotate story exit reads it inline from a flow that forbids widgets. Where a choice is needed, ask in plain conversation.

## Phase 1: Select the record

If the caller handed a specific record path (the usual case - this flow was entered from the annotate story exit), use it. Otherwise list open records that were not cut short (the same list `story-from-craft-designs.md` searches). The project is `$CRAFT_PROJECT_ROOT` when set, else the folder the before-init lookup prints:

```bash
ROOT="${CRAFT_PROJECT_ROOT:-}"
[ -n "$ROOT" ] || ROOT=$(bash -c 'source "$1" >/dev/null 2>&1; craft_before_init_root' _ "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/find-workshop.sh")
ROOT="${ROOT%/}"
for r in "$ROOT"/.craft/annotations/*/record.md; do
  [ -f "$r" ] || continue
  if grep -q '^status: open' "$r" && ! grep -q '^outcome: error' "$r"; then echo "$r"; fi
done
```

One record: use it, confirm conversationally ("Building the story from [name]"). Several: ask conversationally which one - no AskUserQuestion; the fork already spent the flow's question budget.

Read the full record: frontmatter, `## Pins` (the reading list), `## Pin Data` (the json fence, the source of truth for selector, component, box, page and `resolved`, the location the run found for the pin or null), and `session.css` beside it.

## Phase 2: Surface re-check (older records)

If the record's `created` is more than a few days old, re-verify the surface still exists as annotated BEFORE any pre-fill: for each pin's component name, confirm the component still exists in source; for each selector's classes, confirm they still appear; for each pin with a `resolved` key, confirm each resolved file still exists and the rule text still appears in it. Drift is surfaced to the user first ("the pin names `SaveButton`, which no longer exists - it looks like `PrimaryButton` now") - they decide whether the record still stands or the story should absorb the drift. Never silently pre-fill a story against a surface that no longer matches.

A record filed in this session skips this phase.

## Phase 3: Write the story

Target: `.craft/backlog/[story-name].md`, standard frontmatter (see craft-story-new Step 10) plus the backlink:

```markdown
annotate: [record name, e.g. <date>-hero-polish]
```

When you were entered from the annotate story exit rather than from story-new, Read the Step 10 frontmatter block from `${CLAUDE_PLUGIN_ROOT}/commands/craft-story-new.md` first - this reference does not carry it.

Type is almost always `ui`: `type: ui`. Set `alignment: pending` - the alignment check fires at implement time as usual.

**Pre-filled sections:**

- **`## Spark`** - from the record's `subject` plus the pins' text quoted verbatim. The user's own words on the page are the best spark material there is; quote them, never paraphrase.

- **Element Binding Table** - one row per `annotate-key` block that carries the look. A content stand-in gets no row (see Scope). The Value/Source cell names the block and its rule, and the anchors ride the same cell:
  ```markdown
  | Part | Role/State | Token | Value/Source |
  |------|------------|-------|--------------|
  | Save button | default | - | session.css `annotate-key 1728000000000` - `.toolbar .save { padding: 12px 20px }`; anchors: selector `div.toolbar > button.save`, component `SaveButton` |
  ```
  The Value/Source cell still names the session.css rule; the resolved location goes in Reference Materials, never in this cell. The source is the rule, never the selector. Selector and component are anchors that help the implementer find the element in source; a null component is simply omitted. Planning validation requires every non-TBD row bound by a `[visual-source:]` contract, so partial adoption of the sheet becomes a blocked plan, not a silent omission.

- **`## Scope`** - pins with no block in `session.css` (a direction ask, new scope, a question, a copy or behavior change, or a change the user undid) become scope lines, quoted verbatim, each with one clause on why it is not in the sheet. A content stand-in joins them: one requirement quoting the pin, with what was shown live (for example `"Show the full name here"` - shown live as the name "Ada Lovelace" in place of the original), so the story carries the words and the implementer builds them the project's way instead of copying the CSS trick. A pin the user withdrew is not in the record, so it appears nowhere. These are requirements the page could not truly show, so the story must still carry them.

- **`## Reference Materials`** - an "Annotation files:" category (anchor conventions per story-from-planning):
  ```markdown
  **Annotation files:**
  - [absolute path]/record.md (`## Pins`, `## Pin Data`)
  - [absolute path]/session.css (`annotate-key` blocks, one per pin)
  ```
  Then a "**Pin source (resolved during the run):**" category with one entry per `annotate-key` block (a content stand-in's block included, so its requirement says where the element lives), matched to the pin whose `str(ts)` equals the key and read from that pin's `resolved` in `## Pin Data`. Paths are the project root plus the stored relative path, absolute:
  ```markdown
  **Pin source (resolved during the run):**
  - `annotate-key 1728000000000`: [absolute path]/src/SaveButton.tsx (`SaveButton`, line 12); [absolute path]/src/styles/toolbar.css (`line 3`, `.toolbar .save`)
  - `annotate-key 1728000000001`: no source found - no component name, no rule
  ```
  The component file is anchored by its symbol and `component_line`; the rule file is anchored by `line N` and the rule selector. A location whose `rule_via` is `class-search` says it was found by class name. A block whose pin resolved nothing (`resolved` null or no file) gets one line naming the block and its `notes`, with no path.

- **`## Likely Files`** - scan as usual; the pins' component names and page names the surface.

**No token payload.** The sheet's values are page-local; where a value matches an existing token the binding table's Token column says so, and where it does not, the plan-chunks token check surfaces it as known drift the user chose by approving the page.

## Phase 4: Backlinks and close

Write both directions: the story frontmatter carries `annotate:` (done above); the record gets `graduated_to` and `status: graduated` by running:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-record.sh" graduate --record "[record name]" --to "[story name]"
```

The script rewrites only `status: graduated`, `graduated_to` and `outcome`. Verify the record now reads `status: graduated` - don't write those keys by hand.

Report the created story path and its pre-filled sections. The parent flow is DONE - the story takes the normal path from here (cycle-assign, plan-chunks, implement).
