---
type: decision
status: accepted
created: 2026-09-03
source: session
tags: [decisions]
disposition: crafted
stories: [decision-scripts, decisions-skill, move-decisions-between-tags]
---
# Every decision carries tags

## Context
Reopen 2026-09-05: the store held 96 distinct tags across 36
records, 67 on one record only, chosen freehand per card. Only the
first tag is read by anything.
Decisions need to be findable - by tag, by text search, by date, by
asking - and two competing label systems (tags AND a feature: field)
made every one of those harder.

## Options considered
Keep both tags and the feature: field (two taxonomies to maintain).
Tags as the only sanctioned search method (over-prescriptive).
Tags on every record as one way to find them, field retired.

## Decision
Every decision carries exactly one tag: its group. It is shown on
the card, approved with it, and is the Shelf's header. A second tag
is added only when the filer can name the existing record it would
join. A new group starts with one record, and its tag is the
group's name from that moment. Finding
records any other way - grep, a script, a question - stays open and
is not ruled here. The feature: field is retired; its value is the
tag: the 19 Wright records get requirement-to-cycle, the 4 TBD
records get guides.

## Consequences
Reopen 2026-09-05: the 36 records on disk are trimmed to their
first tag by hand, since capture is not built. Capture, when built,
takes one tag and refuses a second unless it exists on another
record. The Shelf row loses its tag column; the Shelf record's
"date, slug, tags" row is read as "date, slug".
One label system, governed by the user's approvals, usable by any
search method now or later. The field-to-tag conversion runs with the
restructure.

## Approval
> "approve. I do like having tags as being the motif for searching
> though. I wouldn't push back on that, I just didn't want it stated
> like it was the only way." - Darin, 2026-09-03, session (card 3 of
> 3, terminal ceremony)
> Reopen: "a" - Darin, 2026-09-05, session
> Reopen: "I'm okay with that, but if we're starting a new group, claude
> should propose a new tag so the user is aware of what's being
> created." - 2026-09-07, session
