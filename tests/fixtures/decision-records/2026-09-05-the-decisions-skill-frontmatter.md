---
type: decision
status: accepted
created: 2026-09-05
source: session
tags: [decisions]
disposition: crafted
stories: [decisions-skill]
---
# The decisions skill routes on the noun, and only the noun

## Context
/craft:decisions has no command file yet (Story 3 builds
it). Its frontmatter is the routing surface: the one place
that decides whether a sentence about a decision lands
here or in the notebook. Notebook already claims "save/
capture a note, idea, or todo" plus deferral markers and a
proactive offer. Lock-decision claims "lock it", "go with
that", "approved", "that's the standard" for code patterns.
Gate words ("approve", "decline") are answers everywhere
in craft and can never be routing triggers.

## Options considered
(a) Mirror notebook: long when_to_use, deferral markers,
    proactive offers. Maximum reach, maximum overlap, a
    third surface that interrupts to offer itself.
(b) Description only, like status. Explicit invocation
    works; a decision named in prose falls to notebook.
(c) Proposed - the dial shape. One-sentence description,
    a when_to_use of two short paragraphs, argument-hint.
    Recognition is the noun "decision" used about a
    product ruling. Card responses are the flow's
    business, not routing's.

## Decision
commands/craft-decisions.md opens with exactly:

  name: decisions
  description: "The Shelf - what waits on you, what's
    ruled, what's claimed, what became real. Rule on a
    card, reopen or retire one, or move one to another
    topic."
  when_to_use: |
    The user says "decision" about a product ruling:
    "save this as a decision", "what decisions are
    pending", "list decisions tagged X", "move the
    guides ones to wright". Renders live from
    .craft/decisions/, never from memory.

    Not for: facts, ideas, todos (notebook); code
    patterns the validator enforces (lock-decision);
    gate words on their own - "approve", "decline",
    "lock it" belong to whatever is on screen. Reactive
    only - never offers itself.
  argument-hint: "[tag or topic] or empty for the Shelf"

Four keys. No aliases, no version, no allowed-tools, no
proactive surface, no invocation string.

## Consequences
The noun routes here; "note", "idea", "todo" stay with
notebook; "lock it" stays with lock-decision; a bare
"approve" answers whatever gate is open. Notebook's Not
for gains one clause: "product rulings (decisions)".
Not (a): a third proactive surface makes every settled
sentence an offer. Not (b): a store nobody can address in
prose is a store nobody uses. Story 3 carries this record
and builds the file byte for byte from it.

## Approval
> "approve." - Darin, 2026-09-05, session
> Reworded: "Yes" - Darin, 2026-10-03, session (dropped graduation, which was cut from the desk 2026-10-02)
