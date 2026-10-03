---
name: bugs
description: "File a bug without fixing it, from a person mid-conversation or an agent mid-run. One door, a complete record on disk, nobody pulled out of what they were doing. Also closes a bug by moving it to closed/ with a verdict."
when_to_use: |
  NAMING IT (check first): "file a bug", "log a bug", "bug ticket". That IS the invocation - run now with what the session has. No offer; ask only if nothing in the text or session identifies a defect.

  DEFERRAL + DEFECT: a deferral word ("later," "don't let me forget," "before I forget") attached to something broken. Offer once, inline and ignorable ("Worth filing in /craft:bugs? Otherwise I'll continue") - never AskUserQuestion. Nothing is filed until the user says yes.

  DEFECT MID-STORY OR MID-CHUNK: a bare defect named mid-story or mid-chunk gets the same offer, so a side sighting does not pull active work off course. A bare defect in an idle session stays /craft:adhoc. Nothing guesses from vocabulary beyond these signals.

  Example (person): "the save button does nothing on Safari, log a bug". Example (agent): mid test run, an agent meets a failing render it will not fix now and files what it saw.

  CLOSE: a bug said to be fixed, won't be fixed, or should be closed. Match it to one open bug, confirm once, then close it.

  Not for: fixing it now (/craft:adhoc), ideas and todos (/craft:notebook).
argument-hint: "[what's broken] or empty to see the open pile"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-list.sh *)
---

# Bugs

!`bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-list.sh --summary`

The block above is the live open pile, filled in before this prompt reached you: a count header, then one line per open bug, newest first. A trailing marker means that bug blocks someone's next step. Do not run anything to produce it.

## Project Root

Set `PROJECT` to `${CRAFT_PROJECT_ROOT:-.}`. All `.craft/` paths resolve under this root. The scripts resolve it themselves, so call them as written and never change directory first.

## Route

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/bugs-record.md` and follow it inline, in this session. Never run it through the Skill tool. It holds the record template, the filing rules, and the closing rules.

| What arrived | Action |
|--------------|--------|
| Bare `/craft:bugs` with no text and no defect in the session | Present the pile above and stop. No question, no filing. |
| A defect, in `$ARGUMENTS` or in the session | Follow the reference's filing rules. |
| An open bug said to be fixed, won't be fixed, or should close | Follow the reference's closing rules. |

Every script runs as `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/<name>.sh"`: `bugs-capture.sh` files a record, `bugs-close.sh` closes one, and `bugs-list.sh` lists the pile (`--status=open` for the full blocks). Nothing here summons the user. A filed bug is read when they choose to read it.
