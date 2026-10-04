# Bug record

A bug record is a report of something broken that is not being fixed right now, written so a session with none of today's context can reproduce it, fix it, and prove it fixed.

A bug found mid-run needs somewhere to go without stopping the run. During a long test pass nothing gets fixed as it is found, because the run's own state depends on the code staying still. So the record holds enough to reproduce the bug from scratch.

## Where records live

One file per bug in `.craft/bugs/`, named `<YYYY-MM-DD>-<slug>.md`. A closed bug moves to `.craft/bugs/closed/`. The folder is the truth for open versus closed: a bug is either open or done, and "what is still open" never costs a frontmatter read of every file that ever existed. Older records with other field values stay readable as they are.

The first line of the record, and therefore the slug, names the symptom in the user's terms, never the suspected cause. The cause is a hypothesis at filing time, and a wrong one renames the file into a lie. The filing script derives the slug and the filename; never write the file by hand.

## Required at filing

Seven fields. Capture refuses a record missing any of them, or holding only an angle-bracket pointer.

- **symptom line** - the first line of the body, in the user's terms. Never a heading.
- **found_during** - where this turned up. Examples: test automation against <sheet>, craft review of <story>, conversation.
- **Expected** - what should have happened, and where that comes from.
- **Actual** - only what was observed. No theory.
- **Consequences** - what this breaks or costs. This is what a reader ranks the pile by; there is no severity field and no certainty score.
- **Blocks my next step** - first line starts `yes` or `no`, then why.
- **Reproduce** - numbered steps from a named starting state.

Everything else is filled when the filer can. A required field the filer cannot know is written plainly ("unknown - <why>") and never asked about.

## Template

Frontmatter is written by the script from flags. The body goes on stdin, symptom line first:

```
<Symptom in one line, in the user's terms, not the suspected cause.>

## What happened

**Expected.** <What should have happened. Quote the requirement, or say plainly that none covers it.>

**Actual.** <Only what was observed. No theory.>

## Consequences

<What this breaks or costs, in the reader's terms.>

## Blocks my next step

<yes or no, then one line on why.>

## Reproduce

Starting state: <repo, commit, or fixture>

1. <step>
2. <step>

Single-command repro, when one exists:
<one command>

## Evidence

<The raw capture, unedited, with the expected output beside it. Never paraphrase.>

## Done when

<The deterministic check that proves it fixed, written NOW, before the cause is known.>

## Scope

Files a fix may touch:
- <path>

## Do not

- Do not edit tests to make the failure pass. The tests encode the requirement, so a failure means the code is wrong.
- Do not fix other bugs noticed along the way. Each needs its own record and its own proof.
- <bug-specific exclusion, with its reason>

## References

- <related record, story, or file>

## Notes

<Optional. Hypotheses only, never dressed as the cause.>
```

Omit `## Log`. Capture creates it with the filing entry.

## Frontmatter flags

```
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-capture.sh" --found-during="<where>" \
  [--requirement="<verbatim>"] [--layer=code|spec|judgment] [--worked-before="<last known good>"] \
  [--verdict=bug|unspecified|spec-gap|not-reproducible] [--tags=a,b] --stdin <<'BODY'
<the body>
BODY
```

The script prints the record's absolute path as its last line. It exits 2 and writes nothing when a required field is missing; fix the named field and run it again.

## Requirement

The requirement is the rule the behaviour was measured against. Quote it verbatim, or leave it blank when the filer's own word is the requirement. A requirement that reads as cited when it was assumed is worse than a blank one: a fixer who trusts the report more than the rule can "fix" it into a regression.

When two sources disagree, the higher one wins:

1. Approved decisions
2. The story's acceptance criteria
3. locked.md
4. Ground truth, meaning what the data or output actually is

When nothing covers the behaviour, file it anyway with verdict `unspecified` and write in Expected: "No requirement found. Searched: <where>." That is a different and often more valuable bug: it looked wrong to a careful reader and nothing rules on it. The answer is usually a new decision, not a code change.

## Layer

Layer is code | spec | judgment. It decides what "done" can mean, so name it when known:

- **code** - a script or program misbehaves on given input. Proven by a test.
- **spec** - a requirement, doc, or command text says the wrong thing, or says nothing where it must rule. Proven by a doc or ruling change.
- **judgment** - the code was right and the model drew, chose, or phrased the wrong thing from correct data. No test will ever catch it. Proven by a human eye on the redraw.

## Statuses and verdicts

Status is where the work is: open | fixed | wont-fix.

Verdict is whether it was ever a bug: bug | unspecified | spec-gap | not-reproducible. It stays blank until triaged. A report that turns out to describe behaviour the requirement actually specifies closes as wont-fix with verdict spec-gap, and that is a real outcome worth keeping, not a mistake to delete.

## Filing rules

- Nothing summons the user, ever. A `yes` on the blocks line is mentioned at the next natural pause, never as an interrupt.
- Look at the injected pile first. If an identical bug is already open, never file it twice: name the match and record the repeat on its `FILE=` path (the line `bugs-list.sh --status=open` prints for it) with `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-hit.sh" "<FILE>" --where="<where>"`, which raises `hits:` by one and appends `- <date> hit again: <where>` to the record's `## Log`. Say where it recurred in `<where>`. A bug seen once is a report; the same bug seen again and again is a pattern and usually outranks the queue.
- When neither the typed text nor the session identifies a defect, ask exactly one question and nothing more:

```yaml
question: "What's broken?"
header: "Bug"
options:
  - label: "(type response)"
    description: "Describe what you saw - I'll file it."
```

- Otherwise ask nothing. An agent filing never asks.
- Take what the session has: the symptom in the user's words, what was run, what came back. Reduce the repro to the smallest thing that still fails before filing; a bug nobody can trigger stalls no matter how real it is.
- After capture, say in one line what was filed and where, then go back to what was happening.

## Closing a bug

Closing is `bugs-close.sh` with a status and, when known, a verdict. It moves the record to `closed/`, stamps `closed_at`, and appends the close to the Log.

When a person says an open bug is fixed, won't be fixed, or should close:

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-list.sh" --status=open` and match the person's words against TITLE and FOUND_DURING.
2. Apply the three-way rule. One match: name it. Several: ask which. None: say so and write nothing.
3. Ask one confirmation naming the bug, the status, and the verdict that will be written:

```yaml
question: "Close this bug?"
header: "Close"
options:
  - label: "Yes"
    description: "Close <title> as <status>, verdict <verdict or unchanged>."
  - label: "No"
    description: "Leave it open. Nothing is written."
```

4. Yes runs `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-close.sh" "<FILE>" --status=<fixed|wont-fix> [--verdict=<v>]`, where `<FILE>` is the `FILE=` line of the matched block. Pass that path, never the slug: a bare slug also matches a same-day twin (`-2`) or a longer slug that contains it, and the script refuses those as ambiguous. No writes nothing and draws no pushback.

`--fixed-by=<ref>` is passed only when the person names a commit or story.

A bare "wont-fix" changes status only: the verdict is left exactly as it was, blank included. A reason the person gives is written as the verdict: "that's intended" is spec-gap, "can't make it happen again" is not-reproducible.

The agent never argues with a close, never invents a verdict, and never reopens. A wont-fix with a verdict is a kept outcome. An agent never closes a `layer: judgment` bug as fixed on its own word: that grades its own homework, and only a human eye on the redraw can close one.
