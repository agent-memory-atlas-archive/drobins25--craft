---
name: annotate
description: "Point at anything in a live browser tab - comment-mode pins go back to the session when you press SEND, or are read directly from the page when its policy blocks localhost."
when_to_use: |
  Use when the user wants to point at something on a page they are looking
  at: "let me point at something", "annotate this page", "mark up what I'm
  looking at". The page is already open in a browser craft can reach through
  chrome-devtools. Not for visual-value questions ("is this gap too loose") -
  those are dial's - and not for pages that do not exist yet (mockup).
  SEND needs a page that can reach localhost; on a site whose policy
  blocks that, craft says so up front and will read the pins directly
  from the page instead. Invoked by the user only; craft never offers it.
argument-hint: "[what you are pointing at]"
---

# Annotate

Put a comment-mode sheet on a live tab, let the user click anything and leave notes, and read those notes the moment they press SEND TO CLAUDE. The page is left pristine when it ends. This is the one flow that waits: standing by the page is the whole job.

This shell owns only routing. The flow lives in one reference file.

## Flow

### Step 1: Parse the subject

**If args provided:** the args name what the user is pointing at - a page, a tab, a screen. Keep it as context for acting on the pins later.

**If no args:** the subject is whatever tab the browser connection currently has selected. Nothing needs asking - and nothing is ever asked through a widget.

### Step 2: Connection preflight

The overlay is injected through the chrome-devtools connection, so it can only reach tabs that connection can see. If the connection is not available, say so in one plain line and stop - no offer, no error, no workaround.

### Step 3: Run the flow

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/annotate-inline.md` and execute it inline, from Step 1, with the subject in hand.

**Never invoke the flow via the Skill tool** - a Skill-tool call ends the turn and control never comes back for the wait, the read, and the teardown; inline execution is the contract (see .claude/rules/skill-invocation-chain-breaks.md).
