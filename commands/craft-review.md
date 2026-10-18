---
name: review
description: "PR review skill - invokes pr-reviewer-expert agent against branch diff, story commits, or full project audit. Every run leaves a record in .craft/reviews/, clean or not, and findings graduate one at a time."
---

# Review

Run a PR-style code review using the crystallized pr-reviewer-expert agent. Three approaches based on what you want reviewed.

## Modes

| Mode | Trigger | What gets reviewed |
|------|---------|-------------------|
| **Branch** (default) | `/craft:review` | Everything on current branch not on origin/main |
| **Story** | `/craft:review story [name]` | Commits from a specific story |
| **Project** | `/craft:review project [path]` | Full codebase or subsystem audit (no diffs) |

Optional focus flag: `--focus security|consistency|performance|correctness` (default: correctness + security)

Optional review strategy: `--maze` enables perpendicular maze review (architect generates questions, runner answers them). Without `--maze`, uses the existing single-agent generalist review.

## Flow

### Step 1: Determine Mode and Scope

**Parse args to determine review scope:**

- No args or `branch` → **Branch mode**
- `story` or `story <name>` → **Story mode**
- `project` or `project <path>` → **Project mode**

Extract `--focus` flag if present. Default focus is `correctness,security`.

### Step 2: Gather Context

**Always pre-load these files (read them, include relevant content in agent prompt):**

1. `.craft/design/locked.md` - locked decisions the reviewer must respect
2. `.craft/project.md` - stack, patterns, conventions
3. `.craft/quality.yaml` - quality gates

### Step 3: Gather Diff / Scope

**Branch mode:**

```bash
# Detect the default remote branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

# Get the diff
git diff origin/${DEFAULT_BRANCH}...HEAD

# Get changed file list
git diff --name-only origin/${DEFAULT_BRANCH}...HEAD

# Get commit log for the branch
git log --oneline origin/${DEFAULT_BRANCH}..HEAD
```

If there are no commits ahead of origin, tell the user:

> "No commits ahead of origin/${DEFAULT_BRANCH}. Nothing to review."

Stop there. No reviewer ran, so this exit writes no record.

**If diff exceeds ~500 lines**, split by directory or subsystem. Run the agent multiple times with scoped diffs rather than one massive prompt. Tell the user:

> "Large diff ([N] lines across [M] files). I'll review in batches by directory to keep findings sharp."

**Story mode:**

If no story name provided, check `.craft/.global-state` for CURRENT_STORY. If none active, use AskUserQuestion to pick from completed/active stories in the current cycle.

```bash
# Read story file to find associated commits
# Look for commits that reference the story name
git log --oneline --all --grep="[story-name]"

# If no story-tagged commits found, ask user for commit range
```

Get cumulative diff across those commits. Also read the story file itself so the agent knows intent.

**Project mode:**

No diff. Instead gather:
- Directory tree of relevant source files
- If a path was specified, scope to that subtree
- The agent will do full file reads during its review

### Step 4: Route - Standard or Maze

Check if `--maze` flag is present. If not, go to **Step 4a (Standard)**. If yes, go to **Step 4b (Maze)**.

---

### Step 4a: Standard Review (no --maze)

**INVOKE the pr-reviewer-expert agent using the Agent tool.**

Build the prompt with:

1. **Mode** - what kind of review this is
2. **Context** - locked.md content, project.md content, quality.yaml content
3. **Diff** - the actual diff (branch/story modes) or file list (project mode)
4. **Changed files** - list of files that changed (branch/story modes)
5. **Commit messages** - so the agent understands intent
6. **Focus** - which lens to prioritize
7. **Story intent** - the story file content (story mode only)

**Prompt structure for the agent:**

```
You are reviewing code for [project name].

PLUGIN_ROOT: ${CLAUDE_PLUGIN_ROOT}
(The agent cannot resolve this variable itself - this line passes the resolved path.)

## Mode: [Branch|Story|Project]

## Focus: [correctness, security, ...]

## Project Context
[locked.md content]
[project.md relevant sections]
[quality.yaml content]

## [Diff / File List]
[the actual diff or file list]

## Changed Files
[list of changed files - read each one fully for surrounding context]

## Commit Messages
[commit log]

## Instructions
- Read each changed file in full (not just the diff) to understand surrounding context
- Check imports/callers of changed functions for cross-file issues
- Respect locked decisions - do not flag patterns that are explicitly locked
- Use two severity levels: issue (must fix) and suggestion (consider)
- [For project mode: add "pattern" severity for consistency observations]
- Categorize each finding: security, logic, performance, consistency, or doc-drift
- doc-drift = stale references in docs/comments, terminology that doesn't match current code, outdated examples, references to renamed/removed symbols
- Lead with the finding. Every finding carries Symptom, Expected (requirement quoted), Actual (observed, or read in code and not run), Consequences, Reproduce from a named starting state, Evidence (raw), and the fix diff with file:line and category
- Focus on: [focus areas]
- Do NOT comment on formatting/style if linters exist
- If the diff is clean and you have no real findings, say so - do not manufacture issues
- Report in this shape: a `Gates run:` line (what you ran on your own initiative and the result, or `none`), a `## Verified` list (one line per check you made and found clean), then `## Findings` with each finding under `### N. <Issue|Suggestion|Pattern> (<category>): <title>`, and `**Withdrawn.** <why>` on any finding you raised and then disproved
```

Then skip to **Step 5: Present Findings**.

---

### Step 4b: Maze Review (--maze)

The maze review splits question-generation from question-answering. The architect decides WHAT to investigate. The runner investigates it. This prevents the infinite-regression problem where fixing 10 issues reveals 10 more.

#### Step 4b.1: Slice the Diff (if needed)

If the diff exceeds ~500 lines, slice it by subsystem/directory:

```bash
# Get changed files grouped by top-level directory
git diff --name-only origin/${DEFAULT_BRANCH}...HEAD | sed 's|/.*||' | sort -u
```

Create one slice per subsystem. Each slice gets its own architect pass. Tell the user:

> "Large diff ([N] lines). Slicing into [M] subsystems for maze review."

For diffs under 500 lines, use the entire diff as a single slice.

#### Step 4b.2: Run the Maze Architect (per slice)

**INVOKE the maze-architect agent using the Agent tool.**

**CRITICAL: The architect must NOT see intent.** Do not include commit messages, PR descriptions, story files, or any explanation of WHY the changes were made. This is the core principle - naive-about-intent question generation produces better review questions.

Build the architect prompt with ONLY:

```
Here is a code diff to analyze. Generate review routes.

## Diff
[raw unified diff for this slice - NO commit messages, NO PR description]

## Changed Files
[file paths only - no descriptions]

## Project Context (optional, if available)
[locked.md content - this is about the PROJECT, not the CHANGE]
[project.md stack/patterns section - this is about the PROJECT, not the CHANGE]
```

The architect returns structured YAML:

```yaml
routes:
  - question: "What happens when [scenario]?"
    lens: security|correctness|consistency|concurrency
    entry_point: "path/to/file.ts:NN"
    why: "The diff shows [observation]"
  - ...
maze_size: small|medium|large
summary: "Naive one-line description of what the diff does"
```

If running multiple slices, run architects in parallel (multiple Agent calls in one message).

#### Step 4b.3: Show the Architect's Routes to the User

Before running the runner, show what the architect found:

> **Maze Architect Report**
>
> *Naive reading:* "[summary from architect]"
>
> | # | Question | Lens | Entry Point |
> |---|----------|------|-------------|
> | 1 | Can a user with role=viewer call this delete endpoint? | security | api/reports/route.ts:12 |
> | 2 | Does the error path clean up the temp file? | correctness | lib/upload.ts:45 |
> | 3 | Do all consumers of UserProfile handle the new nullable field? | consistency | types/user.ts:8 |

This gives the user visibility into what the architect thinks the code does (without knowing what it's supposed to do). The naive reading itself is often revealing.

#### Step 4b.4: Run the Runner with Architect's Questions

**INVOKE the pr-reviewer-expert agent using the Agent tool.**

The runner gets FULL context (unlike the architect) - but its mission is answering the architect's questions, not free-roaming.

```
You are reviewing code for [project name].

PLUGIN_ROOT: ${CLAUDE_PLUGIN_ROOT}
(The agent cannot resolve this variable itself - this line passes the resolved path.)

## Mode: Maze Review - Targeted Investigation

## Your Mission
A naive code reviewer (who cannot see commit messages or PR intent) analyzed this diff
and generated the following questions. Your job is to ANSWER each question with evidence
from the codebase. You have full context - use it.

## Questions to Answer
1. [question 1] (lens: [lens], start at: [entry_point])
   Architect's reasoning: [why]
2. [question 2] ...
3. [question 3] ...

## Project Context
[locked.md content]
[project.md relevant sections]
[quality.yaml content]

## Diff
[the actual diff]

## Changed Files
[list of changed files - read each one fully for surrounding context]

## Instructions
- Answer each question with a clear YES (problem found) or NO (code is safe) + evidence
- For each YES: a finding with Symptom, Expected (requirement quoted), Actual (observed, or read in code and not run), Consequences, Reproduce from a named starting state, Evidence (raw), and the fix diff with file:line
- For each NO: briefly explain why the code handles this correctly
- You may also record BREADCRUMB findings - issues you notice along the way that aren't
  part of the architect's questions. List these separately at the end. These are lower
  priority - side-effects of your investigation, not your mission.
- Use two severity levels for findings: issue (must fix) and suggestion (consider)
- Categorize each finding: security, logic, performance, consistency, or doc-drift
- Breadcrumbs are always suggestions unless they're security/data-loss critical
- Do NOT free-roam beyond the questions + breadcrumbs. When you've answered all questions, stop.
- Do NOT comment on formatting/style if linters exist
- Report in this shape: a `Gates run:` line (what you ran on your own initiative and the result, or `none`), a `## Verified` list with one line per NO answer (the check you made, in your words), then `## Findings` with one finding per YES or breadcrumb under `### N. <Issue|Suggestion|Pattern> (<category>): <title>`, and `**Withdrawn.** <why>` on any finding you raised and then disproved
```

#### Step 4b.5: Cross-Slice Questions (large diffs only)

If there were multiple slices, after all per-slice runners complete, do one final pass.

Collect all architect summaries:

```
Slice A (api/): "Adds a reports endpoint with database query"
Slice B (components/): "New ReportCard component that fetches and displays data"
Slice C (hooks/): "Adds useReport hook with caching"
```

**INVOKE the maze-architect agent one more time** with:

```
Multiple subsystems changed in the same branch. Here are naive summaries of each:

- api/: "Adds a reports endpoint with database query"
- components/: "New ReportCard component that fetches and displays data"
- hooks/: "Adds useReport hook with caching"

Generate cross-cutting questions that span these subsystems.
Focus on contract mismatches, shape disagreements, and assumptions one
subsystem makes about another.

Do NOT repeat questions that would be caught within a single subsystem.
```

Run the runner against any cross-slice questions the same way as Step 4b.4.

### Step 5: Present Findings

When the agent returns, present findings to the user.

**If no findings:**

> "Clean review - no issues or suggestions found across [N] files."

**If findings exist, show a summary table:**

> "**Review complete - [N] findings across [M] files**
>
> | # | Severity | Category | File | Finding |
> |---|----------|----------|------|---------|
> | 1 | Issue | security | auth.ts:42 | Token refresh race condition |
> | 2 | Suggestion | logic | api/users.ts:18 | Missing null check on optional param |
> | 3 | Pattern | consistency | components/ | Inconsistent error boundary usage |
> | 4 | Suggestion | doc-drift | CLAUDE.md:85 | References removed "certainty gate" concept |

Then show each finding in detail with the agent's fix diffs.

**For each finding, show:**

```
### [#] [Severity] ([Category]): [Title]

**File:** `path/to/file.ts:line`

[Agent's explanation of the issue]

**Fix:**
\`\`\`diff
- old code
+ new code
\`\`\`
```

### Step 5a: Drop Doc Findings

After presenting findings, check if any have category `doc-drift`. If none, skip to Step 5b.

If doc-drift findings exist:

1. Create the directory if needed: `mkdir -p "$PROJECT/.craft/docs"`
2. Append each doc-drift finding to `$PROJECT/.craft/docs/review-findings.md` in structured format
3. Tell the user: "Dropped N doc-related findings to `.craft/docs/review-findings.md` for the next docs run."

**File format** (append-only - don't overwrite existing content):

```markdown
## Review: [date] ([mode]: [branch/story/project])

```yaml
- finding: "[finding title]"
  file: "[file:line]"
  severity: "[issue/suggestion]"
  detail: "[agent's explanation, 1-2 sentences]"
  source:
    date: "[YYYY-MM-DD]"
    mode: "[branch/story/project]"
    branch: "[branch name]"
```
```

If the file already exists, append a new `## Review:` section. Each review run gets its own dated section so multiple reviews accumulate between docs runs.

**The docs command (craft:docs) handles consumption and clearing.** This step only writes.

### Step 5b: Write the Record

Every run that reached a reviewer leaves one record in `.craft/reviews/`, whether or not it found anything. This is a separate per-run file written by `review-capture.sh`; Step 5a's docs hand-off above is unchanged and keeps its own role.

Make one capture call per `/craft:review` invocation, after every batch, maze slice and the cross-slice pass has returned. Number the findings 1..N in the order Step 5 presented them across all of them, so the number in the table, the number in the record and the number in the user's answer ("3 bug") are the same number.

Pass the flags to `hooks/scripts/review-capture.sh` from these sources:

- `--ref` is `git rev-parse --short` of the diff's base and of HEAD joined as `<base>..<head>`; in project mode it is HEAD alone.
- `--lines` is insertions plus deletions from `git diff --shortstat` (omit it in project mode).
- `--gates` is the result of the reviewer's `Gates run:` line, and `not reported` when the report has none. Never write `none` for an unknown.
- The body is the reviewer's `## Verified` list and `## Findings`, verbatim. When the report has no Verified list, write the single line `- None reported - the reviewer's report listed no checks it found clean.` under `## Verified`, never an invented check.

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/review-record.md` for the full capture call and the body grammar, then write the record. Note the record's path (the script's last line) and its name (the file name without `.md`) for Step 6.

### Step 6: Close Out

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/review-record.md` and run its close-out: a Proposed paths table with one row per finding, answered in a word, with each answer running the door it names. Nothing is created until the user answers, and no path in this command edits project code outside the adhoc flow.

## Quick Commands

```bash
/craft:review                          # Branch review (default, standard mode)
/craft:review --maze                   # Branch review with maze architecture
/craft:review story auth-flow          # Review a specific story's changes
/craft:review story --maze             # Story review with maze architecture
/craft:review project                  # Full project audit (standard only)
/craft:review project src/api          # Audit a subsystem
/craft:review --focus security         # Branch review, security focus
/craft:review --maze --focus security  # Maze review, security focus
```

## Key Principles

1. **Context before opinions** - locked.md and project.md are read before any finding is formed
2. **Signal over noise** - fewer high-quality findings beat a wall of nitpicks
3. **Always include a fix** - every finding has an actionable diff, not just a complaint
4. **Respect the 500-line cap** - large diffs get split by subsystem
5. **Two severities for changes, three for audits** - issue/suggestion for diffs, add pattern for project-wide
6. **Every run leaves a record, clean or not** - a clean review that leaves nothing is indistinguishable from no review at all, so the record lists what the reviewer verified as well as what it found
7. **Findings graduate one at a time** - each finding goes to the door that fits it, answered in a word, and the review record points at what it became

## Maze Mode Principles

8. **Naive-about-intent** - the architect NEVER sees commit messages, PR descriptions, or story files. It asks "what does this code do?" not "did the developer do what they intended?"
9. **Questions over exploration** - the runner answers specific questions instead of free-roaming. This prevents infinite issue regression (the CodeRabbit problem).
10. **Breadcrumbs are secondary** - findings the runner discovers along the way are recorded but don't change the mission. They're suggestions, not blockers.
11. **Cross-slice awareness** - for large diffs, a meta-architect pass catches contract mismatches between subsystems that per-slice architects can't see.
12. **Convergence by design** - the review ends when all questions are answered. No open-ended "let me look around more."
