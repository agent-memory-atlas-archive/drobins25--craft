# Story From Annotate (reference - read inline by craft:story-new Step 2.5 and by the annotate "story" exit)

Transforms an annotate record into a story. The annotate run IS the extraction - no Explore agent, no gap-fill interview. The user pointed at a live page, watched changes land on it, and approved what they saw. Scope and data shape still go through the normal story machinery (content-spark and alignment run on the created story like any other).

**The record's `session.css` is NORMATIVE.** It holds every change that was injected live, one keyed block per pin, and it is exactly what the user saw on the page. Rule: session.css values port verbatim - implementers never reinterpret from the pin's wording or from appearance. Pin selectors are anchors for finding the element, never ported as structural selectors: a selector like `div.toolbar > button.save` breaks the moment the markup shifts, while the rule's values stay true.

This flow asks no questions through a widget - there is no AskUserQuestion anywhere in it, because the annotate story exit reads it inline from a flow that forbids widgets. Where a choice is needed, ask in plain conversation.

## Phase 1: Select the record

If the caller handed a specific record path (the usual case - this flow was entered from the annotate story exit), use it. Otherwise list open records:

```bash
grep -l "^status: open" "$CRAFT_PROJECT_ROOT"/.craft/annotations/*/record.md 2>/dev/null
```

One record: use it, confirm conversationally ("Building the story from [name]"). Several: ask conversationally which one - no AskUserQuestion; the fork already spent the flow's question budget.

Read the full record: frontmatter, `## Pins` (the reading list), `## Pin Data` (the json fence, the source of truth for selector, component, box and page), and `session.css` beside it.

## Phase 2: Surface re-check (older records)

If the record's `created` is more than a few days old, re-verify the surface still exists as annotated BEFORE any pre-fill: for each pin's component name, confirm the component still exists in source; for each selector's classes, confirm they still appear. Drift is surfaced to the user first ("the pin names `SaveButton`, which no longer exists - it looks like `PrimaryButton` now") - they decide whether the record still stands or the story should absorb the drift. Never silently pre-fill a story against a surface that no longer matches.

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

- **Element Binding Table** - one row per `annotate-key` block in `session.css`. The Value/Source cell names the block and its rule, and the anchors ride the same cell:
  ```markdown
  | Part | Role/State | Token | Value/Source |
  |------|------------|-------|--------------|
  | Save button | default | - | session.css `annotate-key 1728000000000` - `.toolbar .save { padding: 12px 20px }`; anchors: selector `div.toolbar > button.save`, component `SaveButton` |
  ```
  The source is the rule, never the selector. Selector and component are anchors that help the implementer find the element in source; a null component is simply omitted. Planning validation requires every non-TBD row bound by a `[visual-source:]` contract, so partial adoption of the sheet becomes a blocked plan, not a silent omission.

- **`## Scope`** - pins with no block in `session.css` (a direction ask, new scope, a question, a copy or behavior change, or a change the user undid) become scope lines, quoted verbatim, each with one clause on why it is not in the sheet. They are requirements the page could not show, so the story must still carry them.

- **`## Reference Materials`** - an "Annotation files:" category (anchor conventions per story-from-planning):
  ```markdown
  **Annotation files:**
  - [absolute path]/record.md (`## Pins`, `## Pin Data`)
  - [absolute path]/session.css (`annotate-key` blocks, one per pin)
  ```

- **`## Likely Files`** - scan as usual; the pins' component names and page names the surface.

**No token payload.** The sheet's values are page-local; where a value matches an existing token the binding table's Token column says so, and where it does not, the plan-chunks token check surfaces it as known drift the user chose by approving the page.

## Phase 4: Backlinks and close

Write both directions: the story frontmatter carries `annotate:` (done above); the record gets `graduated_to` and `status: graduated` by running:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-record.sh" graduate --record "[record name]" --to "[story name]"
```

The script rewrites only `status: graduated`, `graduated_to` and `outcome`. Verify the record now reads `status: graduated` - don't write those keys by hand.

Report the created story path and its pre-filled sections. The parent flow is DONE - the story takes the normal path from here (cycle-assign, plan-chunks, implement).
