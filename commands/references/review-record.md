# Review Record and Close-Out

Every `/craft:review` run that reached a reviewer leaves one record in `.craft/reviews/`, clean or not. A clean record is the denominator: without it, "reviewed and fine" and "never reviewed" look the same on disk. The close-out then graduates each finding to the craft artifact that fits it, and the record points at what each finding became.

Read this file at Step 5b (to write the record) and Step 6 (to close out).

## Who writes what

- The reviewer cannot write files. The orchestrator writes the record, from the reviewer's report, in one call to `review-capture.sh`.
- `review-capture.sh` owns the grammar. It derives the file name, craft version, counts and outcome itself, stamps a `graduated_to:` line under every finding (`docs` for a doc-drift finding, blank for the rest), and refuses a body with no Verified list.
- `review-graduate.sh` is the only thing that edits a record afterward.
- The record is immutable after capture. Every finding stays in full, exactly as the reviewer wrote it, forever. The only lines that ever change are a finding's `graduated_to:` line and, on a dismissal, the one `dismissed:` line under it. The record carries `outcome:` (`clean` or `findings`) and no status.

## The record

The frontmatter, in order, as capture writes it:

```
type: review
created, captured_at
mode (branch | story | project), strategy (standard | maze)
reviewed (branch name, story name, or audited path)
ref (<base>..<head> short SHAs, or the head SHA alone in project mode)
focus, files, lines (omitted in project mode)
craft_version, reviewer, gates
issues, suggestions, patterns
outcome (clean | findings)
```

The body is `## Verified`, one line per check the reviewer made and found clean, then `## Findings`: `None.` when clean, otherwise each finding under `### N. <Issue|Suggestion|Pattern> (<category>): <title>`, numbered 1..N in the order Step 5 presented them. The category is one of security, logic, performance, consistency, doc-drift. A finding keeps the reviewer's seven fields (Symptom, Expected, Actual, Consequences, Reproduce, Evidence, Fix) verbatim, plus `**Withdrawn.** <why>` when the reviewer raised it and then disproved it.

The record name is the file name without `.md`. It is the value every `review:` back-link and every graduate call uses.

## The capture call

One call per `/craft:review` invocation, with the body on stdin:

```
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/review-capture.sh" --mode=<branch|story|project> --strategy=<standard|maze> \
  --reviewed="<branch name | story name | audited path>" --ref="<base7>..<head7> | <head7>" \
  --focus="<csv>" --files=<N> [--lines=<N>] --reviewer="<agent name[, agent name]>" \
  --gates="<what ran - result | none | not reported>" --stdin <<'BODY'
<the body>
BODY
```

- `--lines` is required for branch and story runs and refused for project runs.
- `--gates` is `not reported` when the reviewer's report has no Gates run line. `none` means the reviewer said it ran nothing; an unknown is never written as `none`.
- When the report has no Verified list, the body carries the single line `- None reported - the reviewer's report listed no checks it found clean.` under `## Verified`. Never invent a check.
- A finding the reviewer withdrew stays in the body in full.
- The body must not already hold a `graduated_to:` line outside a fenced block: capture stamps its own.

The script prints the record's absolute path as its last line. It exits 2 and writes nothing when a flag is missing or the body breaks the grammar; fix the named problem and run it again.

A worked example body that capture accepts (finding 1 is one the reviewer withdrew, so the close-out would propose dismissing it; finding 2 is the issue that matters):

~~~review-body
## Verified
- Every caller of `parseToken` handles the new null return
- The migration is idempotent when run twice against the same database

## Findings

### 1. Suggestion (consistency): Error message wording differs from the sibling handler

**Symptom:** The new handler says "Invalid token" where its sibling says "Token rejected".
**Expected:** Handlers in `api/` share one wording - "No requirement found"; looked in `locked.md` and the sibling handlers.
**Actual:** Read in the code, not run: `api/refresh.ts:31` and `api/login.ts:27` differ.
**Consequences:** A client matching on the message text would handle one route and miss the other.
**Reproduce:**
1. Check out the branch at the head commit.
2. Compare the two lines.
**Evidence:**
```
api/refresh.ts:31: throw new HttpError(401, "Invalid token")
api/login.ts:27:   throw new HttpError(401, "Token rejected")
```
**Fix:** Align the wording.
**Withdrawn.** Clients branch on the status code, and the two routes already document different messages on purpose.

### 2. Issue (logic): Refresh path drops the session when the token is null

**Symptom:** A user whose token expired is signed out instead of refreshed.
**Expected:** "An expired token is refreshed once before the session is dropped" (story acceptance line 4).
**Actual:** Observed - ran `npm test auth`, got `1 failed: refresh keeps session`.
**Consequences:** Every user hitting an expired token loses their session mid-work.
**Reproduce:**
1. Check out the branch at the head commit.
2. Run `npm test auth`.
**Evidence:**
```
FAIL auth/refresh.test.ts > refresh keeps session
  expected session to exist, got null
```
**Fix:**
```diff
- if (!token) return endSession()
+ if (!token) return refreshOnce()
```
~~~

## Immutability and the one allowed edit

Graduate through the script, never by editing the file:

```
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/review-graduate.sh" <record name> <N[,N...]> <value> [--by=user|reviewer] [--reason="<text>"]
```

- `value` is the name of the artifact the finding became (a fix, tweak, bug, story or notebook todo), or `docs`, or `dismissed`.
- A comma list fills several findings in one write, all or nothing.
- `dismissed` requires `--by` and `--reason`; the script inserts `dismissed: <by> - <reason>` under the finding's `graduated_to:` line. Any other value refuses both flags.
- The script refuses a finding that is already graduated, an unknown finding number and an artifact that does not exist yet. Graduate only after the destination is written.
- Blank means nobody acted on the finding, whether the table went unanswered or the user left it. `docs` means doc-drift was already handed to the docs file by Step 5a.

## The doors

A finding graduates through one of four doors. The doors are not re-explained here; each door's own boundary sentence is quoted from its source, and the source is the authority. Read the finding against these sentences and pick.

**Adhoc** - `skills/adhoc/SKILL.md`, description:

> Acts NOW - a defect to file and fix later belongs in /craft:bugs, other deferred work in the notebook. Do NOT use for new features, design exploration, or changes requiring creative spark.

**Bug** - `commands/craft-bugs.md`, description and its "Not for" line:

> File a bug without fixing it, from a person mid-conversation or an agent mid-run.

> Not for: fixing it now (/craft:adhoc), ideas and todos (/craft:notebook).

**Notebook todo** - `commands/craft-notebook.md`, "Not to be Confused With":

> Notebook todos are deferred intent items, not act-now work.

> A todo is intent; a bug record carries the reproduce and done-when a fixer needs.

**Story** - `commands/craft-notebook.md`, the story line, and `skills/adhoc/SKILL.md`, the "No new features" guard:

> For thoughts that are already story-shape with a clear acceptance shape.

> If the solution adds something that wasn't there before (a new component, a new API endpoint, a new element on the page), it's a story.

A review finding never files a decision card.

## The Proposed paths table

After the findings, show one row per finding with a default door and an "or". Nothing is created until the user answers.

Defaults:

- **Suggestion** - adhoc, grouped. Suggestions that adhoc can take as one brief share one run, and each one's `graduated_to:` names that run's record. Bug and notebook are never the default for a suggestion.
- **Issue with a confident surgical fix** - its own adhoc run. Confident means the reviewer's Fix is a surgical change to something that already exists, with the cause visible, the bar adhoc's own confidence check holds.
- **Issue without one** - a story. The "or" on an issue is bug (a defect to file and fix later, or one that belongs to an earlier story) or notebook todo.
- **Pattern finding** - a story.
- **Doc-drift** - already handed to the docs file by Step 5a. Shown as `docs`, no question.
- **A finding the reviewer withdrew** - dismissed, with the reviewer's `**Withdrawn.**` reason shown in the row.

The table, as the user sees it:

```
Proposed paths for review 2026-10-18-branch-feature-x

| # | Finding | Path | or |
|---|---------|------|----|
| 1 | Suggestion (consistency): error wording | dismissed - reviewer: clients branch on status | adhoc |
| 2 | Issue (logic): refresh drops session | adhoc (own run) | bug, todo |
| 3 | Suggestion (doc-drift): stale README line | docs (already handed off) | - |
```

Answer in a word:

- "yes" runs every row as shown.
- A change plus the rest settled ("2 bug, rest yes") edits that row and runs all of it.
- A change that leaves the rest unsettled ("2 bug") re-shows the edited table and waits.
- No answer leaves every finding blank. The record already says it was reviewed.
- A user dismissal states its reason in the user's words. With none given, record `--by=user --reason="no reason given"`; never supply a reason on the user's behalf and never ask a follow-up for one.

The table and the answers do not name a widget: show the table, read the reply.

## Running an answer

Run in this order, because the script-backed doors finish in one turn and adhoc runs carry their own questions:

1. Dismissals and "leave" rows. A dismissal graduates with `dismissed`, `--by` and `--reason`.
2. Bug, todo and story doors.
3. Adhoc runs, one at a time.

After each destination exists, graduate the finding to its name through `review-graduate.sh`. All graduation writes go through that script.

### Bug door

Follow `${CLAUDE_PLUGIN_ROOT}/commands/references/bugs-record.md` and the open-pile check in `${CLAUDE_PLUGIN_ROOT}/commands/references/analysis-bug-filing.md`.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-list.sh" --status=open` once. On an identical open bug (the same broken behavior in the same place), run `bugs-hit.sh` on its path instead of filing, and graduate to that bug's name.
2. Otherwise file it: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-capture.sh" --found-during="craft review of <reviewed> (<ref>)" --review=<record name> --stdin`.
3. The body: Symptom as the first line; Expected, Actual, Consequences, Reproduce and Evidence carried over from the finding; `## Blocks my next step` starting `no - found by craft review; nobody was mid-task on it.`; the record path, the finding number and any earlier source story in `## References`; the reviewer's Fix in `## Notes`, labelled a proposed fix.
4. A defect that belongs to an earlier story than the one under review names that story in `## References` as its source.
5. Severity does not travel: a bug record has no severity field.

### Todo door

`bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/notebook-capture.sh" todo "<imperative from the finding title>" --review=<record name> --body-paragraph2="<symptom; record path, finding N>"`, then graduate to the printed file's stem.

### Story door

1. `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/create-story.sh" "<kebab name>" "<title>"` creates it in the backlog and prints its path.
2. Append `review: <record name>` to the story's frontmatter, the Spark from the finding's Symptom and Consequences, and acceptance from Expected and the Fix.
3. Title check: read the title line of the frontmatter back. A title holding a colon must be wrapped in double quotes; wrap it if it is not.
4. Graduate to the story name.

### Adhoc door

Adhoc runs inline. Read `${CLAUDE_PLUGIN_ROOT}/skills/adhoc/SKILL.md` and follow it in this turn, never through the Skill tool: a Skill-tool call ends the turn and control does not come back to the close-out for the next finding.

Before the first run starts, create one task per pending adhoc run, so the close-out survives adhoc's own questions and its gate tasks between runs. Complete each task once its graduation is written (or once the run is known to leave the finding blank).

The brief for each run names:

- the review record's name and path;
- the finding numbers it covers, with their text verbatim;
- "set `review:` to <record name>";
- the earlier source story, when the defect predates the reviewed change.

The flow never opens or edits the review record. When a run hands back, read the record it wrote, in `.craft/fixes/` or `.craft/tweaks/`, and check its `status:`:

- A fix at `validated`, or a tweak at `accepted` or `revised-then-accepted`: graduate every covered finding to that record's `name:`.
- Any other status (escalated, failed, abandoned, not yet validated): leave the covered findings blank. A fix that fails adhoc's confidence check leaves its finding blank.

Then move on to the next pending run.
