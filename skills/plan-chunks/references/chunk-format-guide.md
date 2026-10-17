# Chunk Format Guide

This is the required format for planned stories: the Investigation, the Pitch, and the chunk specs produced during Phase 3 (Chunk Planning).

**The standard:** A plan locks the **seams** - contracts between chunks, between layers, and with existing code - and leaves the **interiors** to the implementer. Every binding claim carries evidence. The plan is done when a skeptical reviewer probes it and walks away with "...that's all."

**The litmus test:** Could two competent implementers build from this plan independently and not conflict at the seams? Seams are what plans must lock. Interiors are what implementers own.

---

## Story-Level Sections

A planned story adds two sections beyond the chunks. Both are required.

### `## The Pitch` (replaces `## Delivery`)

Placed directly after `## Spark`. Two parts:

1. **The sell** (2-4 sentences): why this plan works - mechanically, not aspirationally. A pitch you wouldn't buy is a plan that shouldn't be approved, before anyone reads a single chunk.
2. **The conditions table**: every load-bearing assumption the guarantee stands on, each tagged with how it's secured.

```markdown
## The Pitch

Ship this and the countdown can't lie and the button can't betray - not because
we were careful, but because we made other systems responsible: the date is
ILS-owned so drift is impossible by construction, "once" is ILS-enforced so we
can't fork its truth, and auth is the existing middleware so there is no new
surface.

**This plan stands on:**

| Condition | Secured by |
|-----------|-----------|
| `holdDeadline` is ILS-owned; local writes would be overwritten | verified - traced all writes, only `jobs/ils-sync.ts` touches it |
| ILS API accepts `PATCH /holds/{id}/pickup-by` | unverifiable by reading - becomes Chunk 1's FIRST test |
| Auth middleware covers account mutations | verified - `requirePatron` guards all 3 existing PUTs in `routes/account.ts` |
```

**Rules for the conditions table:**
- Every condition is tagged `verified - <evidence>`, `system-owned - <who>`, or `unverifiable by reading - becomes Chunk N's FIRST test`.
- A condition that can't carry one of those tags is not a condition - it's a hole. Go back.
- An unverifiable single-thing condition MUST become the named chunk's first test, before anything is built on it. The plan's weakest point gets attacked first, by construction.
- A class claim never takes the first-test escape: a capture of chosen instances cannot secure a claim about a class. It is secured by research (`verified - research: <slug> -> "<anchor>"`) or, in batch, tagged `unverifiable class claim - research request raised, never a first test` with a matching Critical Blocker.
- **The conditions table is the implementer's tripwire watchlist.** The implementer doesn't watch everything; it watches these.

### `## Investigation` (the planner's narrative)

Placed directly before `## Chunks`. The causal record of how the plan was found - the planner's headspace, so the implementer (and any future re-planner) inherits the reasoning, not just the conclusions. First person is fine. Write it as it happened:

```markdown
## Investigation

Read the ticket as possibly-a-bug - "show a countdown" sounds like it might
already exist. Searched the repo for "Pick up by" - nothing. Searched for
hold-related UI - found AccountPage.tsx, renders hold rows, no deadline. So:
new feature, existing surface.

AccountPage gets data from UserAccountService.getHolds(). Read it - already
returns holdDeadline. But the service is GET-only. Asked WHY before planning a
PUT: traced writes to holdDeadline - nothing in this repo writes it - found
jobs/ils-sync.ts, a nightly mirror from the library's ILS. This repo does not
own this date. A local PUT would be silently overwritten by tomorrow's sync.
Ruled out: writing holdDeadline locally.

Asked the user: hardcode the 2 days? -> Yes, hardcoded. Button placement? ->
In the hold row, site-standard secondary button.

Dead ends kept: searched for an existing countdown component - none, but
RelativeDate at components/shared/RelativeDate.tsx is 80% of it. No test
patterns in jobs/ - out of scope, the ILS client tests are the pattern to mirror.
```

**Rules for the Investigation:**
- **Causal, not inventory.** Each step motivates the next ("found X, which raised Y, so read Z"). A list of files read is not an investigation.
- **Dead ends stay in.** "Searched for it, found nothing" is load-bearing - it records what was ruled out. A suspiciously clean narrative with no wrong turns is itself a fabrication signal.
- **Absence is evidence.** Every missing thing the plan builds (endpoint, column, config) needs a stated theory of why it's missing. "Nobody needed it yet" is acceptable; "it's a fence" changes the plan.
- **Ownership is the floor.** "The field exists" is never the bottom of an investigation. "I know who writes it, and what happens to my write tomorrow" is.
- User questions asked during planning and their answers are recorded here.
- **Size: typically 10-30 lines.** A narrative that outgrows ~40 lines is usually a story that should split - the sprawl is the signal, not a writing problem.
- **The Do-Nothing Walk is recorded here.** The resting state's claims and whether the write path agrees with each (display vs held vs would-be-sent). Every divergence found lands as a chunk or a Pitch condition - never as a note that goes nowhere.

---

## Required Chunk Template

```markdown
### Chunk [N]: [Descriptive Name]

**Goal:** [Specific outcome - not vague]

**Files:**
- `src/routes/account.ts` - modify (new PUT route)
- `src/services/UserAccountService.ts` - modify
- `src/services/__tests__/UserAccountService.test.ts` - create

**Contracts:** (binding - these are the seams; match exactly)
- `IlsClient.extendHoldPickup(holdId: string, newDate: IsoDate)` [owner: Chunk 1 - cite its real signature at implement time, not this line]
- New route `PUT /api/account/holds/:holdId/extension` [verified: read routes/account.ts - all four existing routes use plural/:id shape]
- Auth via existing `requirePatron` middleware [verified: it guards the 3 existing account mutations; no new auth surface]
- Response is the refreshed hold from the ILS payload - never locally computed [investigation: ILS owns this data; local math is the silent-failure trap this plan routes around]
- 409 when ILS reports `extensionCount >= 1` [investigation: "once" is ILS-enforced; we translate, never track]

**Approach:** (advisory - the interior is yours)
- Service method beside getHolds(), same DI pattern
- +2 days via addDays from lib/dates.ts, library-local timezone

**Test cases:** (write these, assert this - bodies are yours)
- "returns refreshed hold on success" - deadline comes from the ILS response, not local math
- "surfaces 409 when already extended"
- "rejects unauthenticated with 401"
- "ILS failure -> 502, no local state change"

**What Could Break:**
- [resolved] Route collision with /holds/:id - checked, no existing extension route
- [escalated to conditions] ILS PATCH availability - Chunk 1's first test

**Done When:**
- [ ] Endpoint live behind auth
- [ ] Build passes and all tests pass
```

### Section rules

**Contracts** - the binding section. Each line is a seam: a signature, a shape, a route, a name, an integration point, an invariant. Each line carries exactly one receipt:

| Receipt | Meaning |
|---------|---------|
| `[verified: <what was checked and what would have falsified it>]` | Attacked against existing code during investigation. The receipt is attack residue, not attestation - "I tried to kill this and here's what would have killed it."  For a fact outside the repo the form is `[verified: web - <source url or doc name> - <what was checked>]`. |
| `[owner: Chunk N]` | The contract's truth is produced by an earlier chunk. By implement time it's real, compiled code - cite IT, not this line, if they differ. |
| `[investigation: <one-line reason>]` | Backref to the narrative - the reasoning this contract protects. The implementer uses this to judge mismatches: does a deviation break the *reason*, or just the coordinates? Never for a fact outside the repo - that is `[verified: web - ...]`. |
| `[defines]` | A new seam this chunk creates - a name, route, or shape with no prior reality to verify. Authoritative from this chunk on; later chunks cite it via `[owner: Chunk N]`. Greenfield stories are mostly `[defines]` - that's correct, not a gap. |
| `[visual-source: <mockup anchor \| tokens.yaml token \| Visual Direction Part/Role>]` | A UI element's visual binding: this Part/Role uses this token or value, sourced from a mockup, the design system, or the Visual Direction table. The visual-domain twin of `[verified:]` - it points at where the look was decided, not at code. |

A contract about *pre-existing reality* that can earn no receipt goes in the Pitch's conditions table as unverifiable - it does not ship as a bare assertion.

**Mutation contracts carry their unit and their readers.** A contract for any state-changing write declares the key it writes under ("completion is per schedule-occurrence `(workout_id, scheduled_date)`, not per workout") and receipts its read sites ("[verified: read by CalendarView.tsx:31 and AccountPage.tsx:84 - both rebuild from the refreshed payload]"). An undeclared unit is an invisible assumption - and invisible assumptions are the one thing receipts can't attack.

**Approach** - advisory prose. Pattern pointers by `file:line`, ordering, gotchas. **No code blocks** - with two narrow exceptions. (1) When the code IS the decision (an exact regex, a migration statement, a non-obvious one-liner where ambiguity is dangerous). (2) Irreducible visual logic (an SVG node/path array, a CSS keyframe sequence, a GSAP timeline) that cannot be expressed as a binding-table row and where approximating the geometry or motion sequence would change the result. Either way the code carries a receipt that names what makes it non-substitutable - not a bare `[decision:]` - like any contract.

**Test cases** - names plus what they assert. No bodies. The implementer writes bodies during TDD, where they get verified by running - not authored as fiction in a markdown file.

**What Could Break** - every entry is `[resolved]` (checked dead during planning, say how) or `[escalated to conditions]` (now in the Pitch table). A bare risk bullet that is neither resolved nor escalated is an unfinished thought.

**Amendments** - when implement-time reality contradicts a contract and the fix is approved, the delta is recorded in the chunk under an `**Amendments:**` heading (date, what changed, what the original receipt missed) - the contract line is never silently edited. The plan stays honest about what it got wrong; the amendment trail is how future planning learns which receipts fail.

### Visual Contracts (type=ui stories)

A UI story's per-element visual intent is carried as an **Element Binding Table** in `## Visual Direction` (the story-level source of truth); each chunk binds the subset of rows it builds as Contract lines, each carrying a `[visual-source:]` receipt. The table:

| Part | Role/State | Token | Value/Source |
|------|------------|-------|--------------|
| cta | surface | `primary` | tokens.yaml |
| cta | surface (hover) | `primary/90` | tokens.yaml |
| label | on-surface | `card-foreground` | mockup hero/h2 |

- **Part** = element/anatomy name. **Role/State** = the styling role plus interaction state - a hover row is its own row, owned by the chunk that builds that state. **Token** = the semantic token bound. **Value/Source** = origin (`tokens.yaml`, a mockup anchor, a design ref), and the literal value only where no token exists.
- **Raw values are the narrow exception.** A literal (not a token) is allowed only when it is structural rather than thematic (a `1px` hairline, an `aspect-ratio`, a `z-index`) AND no token of that type exists - flagged inline with a one-line reason. Color, spacing, type, radius, shadow, and motion are theme-owned: those must be tokens, never literals.

---

## Risk Tag Translation

When the story carries a `## Risk Tags` section, the tags are consumed at plan time: translate EACH tag into at least one acceptance criterion that names the implementation mechanism. A tag that produces no criterion is a tag the plan ignored - say why, or translate it.

### Risk Tag Authoring Rule

This is the canonical statement; `skills/content-spark/SKILL.md` and `commands/references/content-spark-inline.md` carry the short form and point here.

Each risk tag's `#` comment must specify the **implementation mechanism** or cite a **project locked rule**. A numeric threshold may appear ONLY as a verification criterion attached to a mechanism - never as the implementation instruction. A threshold as a CHECK is legitimate (a quality gate's 44px touch-target floor verifies an outcome); a threshold as the INSTRUCTION is the antipattern - the implementer satisfies the number in the cheapest literal way (`min-height: 44px` on the visual element) instead of building the mechanism (an extended hit area).

- Wrong: `- has-touch-targets    # must stay >=44px`
- Right: `- has-touch-targets    # hit area extended via padding/pseudo-element, not min-height on the visual element; verify computed target >=44px`

**Per-tag translation requirement.** For each tag, the criteria you write must name the mechanism the tag carries (or the locked rule it cites). The threshold, if any, appears only as the verification clause of that mechanism-naming criterion:

- From the RIGHT tag above: "Interactive elements extend their hit area via padding or pseudo-element (not min-height on the visual element); verify every computed target is >=44px."
- A tag citing a locked rule translates to a criterion that names the rule and asserts conformance with it.

A bare-threshold criterion ("touch targets >=44px") is rejected by plan validation (structural check #8 scans each tag line's `#` comment for a threshold with no mechanism wording).

---

## Cutting Chunks: the Ladder

Navigate top-down to find the seam; build bottom-up from the furthest-upstream fact the story touches.

- **Chunk boundaries sit at layer rungs** (data -> types -> service -> endpoint -> UI, or whatever ladder this story actually has). The rung interfaces ARE the contracts - they fall out of the cut instead of being invented.
- **Later chunks cite earlier chunks' output** via `[owner: Chunk N]`. By implement time the citation points at real, tested code - the ladder is the staleness-proofing.
- **Chunk 1 sits where speculation lives.** Pre-existing code contracts and any unverifiable condition land in the earliest chunk that can test them. The plan's weakest assumption is the first thing reality gets to vote on.
- A one-rung story is fine. Discover that honestly ("where does the data come from?" -> it's all right here) and cut one or two chunks. Do not manufacture rungs.

---

## Green-Tree Requirement

Every chunk's **Done When** must include at least one criterion asserting the project compiles and all tests pass at the end of the chunk ("Build passes and all tests pass"). Plan validation rejects any chunk whose Done When lacks one.

This is a planning constraint, not a checkbox to append. Cut chunk boundaries so the criterion can actually be true: a rename or symbol removal and every reference to it - including test files, mocks, and fixtures - belong in the same chunk. A plan that defers compilation across a chunk boundary ("do not build between Chunk 1 and Chunk 2") is invalid; merge or re-cut the chunks, or flag the story for splitting.

Exempt: chunks that modify no source files (all Files entries `read-only`, or a Goal that touches only docs).

---

## Quality Gates (run before presenting the plan)

1. **The seam test** - for each chunk: could two competent implementers build this independently and not conflict at its boundaries with other chunks and with existing code? If a conflict is possible, a contract is missing. If a contract dictates an interior (HOW a function's body works, what a test body contains), it's overreach - move it to Approach or delete it.

   *Visual token assignment is a seam, not an interior (UI stories).* Two implementers given the same UI spec can assign different valid tokens to one element (`surface` vs `surface-elevated`) - both pass style-analyzer, both render differently. That is exactly the conflict Contracts exist to prevent, so a per-element token/value binding belongs in Contracts with a `[visual-source:]` receipt, never left to Approach. (Also stated in `agents/plan-chunks-agent.md` Phase 3.1, which the agent runs from its own prompt.)

2. **The receipt audit** - every contract line carries a receipt; every receipt-less claim is in the conditions table; every unverifiable single-thing condition is some chunk's first test (a class claim goes to research). Run the narrative check: is the Investigation causal? Are the dead ends still in it? Too clean is a finding.

3. **The Miranda pass** - model the specific skeptic who receives this plan (the user at triage; the reviewer who gets sent in afterward). Write down the five questions they will ask. Each must already be answered *in the artifact* - in the Investigation, a contract receipt, or the conditions table. Not answerable: answered. The plan is done when that review walks out with "...that's all."

---

## Bad → Good Example

**BAD (old style - implementation written as fiction):**
```
**Implementation Details:**
- Import Card from src/components/ui/Card - <Card variant="outlined"> takes {title, children}
- Zod schema: z.object({ email: z.string().email(), password: z.string().min(8) })
- Submit: api.auth.register(data) - handle 409 with if (err.status === 409)
- [40 more lines of code the implementer will transcribe without verification]
```
Looks rigorous. Nothing in it was compiled, nothing was run, and the implementer is told to copy it even where it's wrong. Plausibility masquerading as verification.

**GOOD (contracts + receipts; interior left to the implementer):**
```
**Contracts:**
- `Card` from src/components/ui/Card, props {title: string, children: ReactNode, className?} [verified: read Card.tsx:8-15; no "outlined" variant exists - that was in the mockup but not the component]
- Registration via `api.auth.register(data)`, 409 = email taken [verified: read lib/api.ts:89; 409 is the only conflict the server emits]
- Reuse `PasswordStrength`, props {score: 0-4, showLabel?: boolean} [verified: read PasswordStrength.tsx:8; score is required, not optional]

**Approach:**
- Form layout follows LoginForm.tsx:45-62 (FormField -> Label -> Input -> ErrorMessage stack)

**Test cases:**
- "rejects mismatched password confirmation before submit"
- "surfaces email-taken error from 409"
- "disables submit while request is in flight"
```
Note the first receipt *caught a planning error* ("no outlined variant exists") - that's what receipts are for. The attack residue does the verifying that fake code only performed.

**The exception - code that IS the decision:**
```
**Approach:**
- Strip block comments before any parsing: `css.replace(/\/\*[\s\S]*?\*\//g, '')` [decision: comment syntax inside values would corrupt naive parsing; this exact pattern is the choice]
```
An exact regex, a migration statement, a tricky one-liner: when ambiguity is dangerous, the code is a contract and carries a receipt like one. This is rare. If most of a chunk is decision-code, the chunk is probably dictating interiors.

---

## Why This Matters

The implementer is autonomous, but it is not a transcriber - it reads the Investigation, holds the contracts as law, owns the interiors, and watches the conditions table. When reality contradicts a contract, finding that mismatch is a *deliverable*, not a failure: the plan gets amended with the delta, instead of code quietly improvised around a broken assumption.

**Planning is where the seams get locked and attacked. Implementation is where interiors get built and contracts meet reality.**

The plan failed only if the reviewer finds what the planner should have - or if two implementers could read the same chunk and ship conflicting seams.
