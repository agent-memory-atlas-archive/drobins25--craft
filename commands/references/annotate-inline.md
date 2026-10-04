# Annotate Flow

The full raw-tab session: arm through teardown. The overlay source, the port stamp, the annotate clear, and the channel protocol live in `${CLAUDE_PLUGIN_ROOT}/commands/references/annotate-overlay.md` - read it before Step 3 and hold it for the session. The capture channel is driven only through `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh`.

**No question widgets anywhere in this flow - never, at any step, including every exit.** The mode is armed by invocation and steered in plain conversation.

This flow runs in the orchestrator, not a subagent: it needs the browser connection and the session's own wake-up.

## Step 1: Connection check

The overlay reaches a tab through the chrome-devtools connection. If that connection is not available, say so in one plain line and stop - no offer, no error, no setup instructions. Otherwise list the tabs and select the one the user means (the subject, or the tab already selected when no subject was given).

## Step 2: Arm or reuse the session listener

The listener is lazy and per-session. It starts the first time a flow needs it and lives until the session ends. Nothing in this flow ever shuts it down.

- **No session id held in this conversation:** arm one. Pass the project root when `CRAFT_PROJECT_ROOT` is not set.

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" arm --root "<project root>"
  ```

  It prints `SESSION <id> PORT <port>`. Hold the id and the port.
- **A session id is already held** (an earlier `/craft:annotate` or another flow in this conversation armed one): read it back, and reuse it.

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" status --session "<id>"
  ```

  If the line shows `PORT none`, or the listener is not answering, run `arm --session "<id>"` - it is idempotent and prints the current port. Only ever reuse an id this conversation armed: another pane in the same project has its own session, and its listener is not yours.

Never arm a second listener while one is held.

## Step 3: Clear any dial residue, then any earlier overlay

Run the canonical dial clear on the selected tab first, unconditionally. A dial panel from an earlier session may still be on the page, and pins taken on a page wearing a stale panel are pins about the wrong page. The clear is idempotent on a clean page:

```js
document.getElementById('craft-dial-style')?.remove();
document.getElementById('craft-dial-panel')?.remove();
document.querySelectorAll('[data-craft-dial-injected]').forEach(el => el.remove());
delete document.documentElement.dataset.craftDial;
```

Then run the annotate clear, so a redundant earlier install is gone before the new one lands. It is the `annotate-clear` fence of the overlay reference, verbatim:

```js
document.getElementById('ca-style')?.remove(); document.getElementById('ca-sheet')?.remove(); document.getElementById('ca-strip')?.remove(); document.querySelectorAll('[data-craft-annotate-injected],.ca-pin,.ca-popover,.ca-box').forEach(el => el.remove()); document.body.classList.remove('ca-mode'); delete window.__craftAnnotateInstalled;
```

## Step 4: Stamp the port, then inject

Injection is two `evaluate_script` steps, in this order:

1. The port stamp: `window.__craftAnnotatePort = <port>;` - the port printed in Step 2, as in the `annotate-stamp` fence of the overlay reference. Only the port line. Never stamp the baked flag and never stamp a context: a baked page opens an event stream at load, and an injected page must make no request before the user acts.
2. The overlay source: the whole `overlay-source` fence from the overlay reference, pasted unchanged as a single expression.

Stamp first because the overlay reads the port when the user presses SEND; without the stamp SEND reports that nothing is listening.

Then tell the user ONCE:

> "The sheet is on the page - turn on COMMENT MODE, click anything, and press SEND TO CLAUDE when you want me to read it. Reloading the page removes the sheet; tell me and I'll put it back."

## Step 5: Stand by for SEND

This is the one flow that waits. Start the wait ONCE as a background Bash command: run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" wait --session "<id>" --timeout 3600
```

with the Bash tool's `run_in_background: true`. No tool timeout is set. A background command is permission-checked once, when it launches, and has no time limit in a terminal, desktop, or VS Code session. Do not poll it and do not start it in the foreground.

- **SEND:** the command exits with the pins as JSON on its output, and that exit wakes the session. Read the output and go to Step 6.
- **WAITING:** the hour ran out with no SEND. Start one new background wait, silently - say nothing to the user, and do not stack a second wait beside a live one.

The wait notices only a SEND that lands while it is running. Each time a wait ends, read the channel file before starting the next one, and act if its `seq` is higher than the last one you acted on: a SEND in the gap between two waits is otherwise lost.

```bash
cat ".craft/annotations/<id>/current.json"
```

## Step 6: Read the pins and act

The payload is `{seq, cleared, pins, ...}`. A `cleared: true` payload means the user cleared the sheet: nothing to act on, say nothing about pins, and go back to Step 5.

Otherwise quote every pin back as the user's exact words - never paraphrase a comment, relabel it, or merge two into one. Show each pin's number, its comment text verbatim, and where it points (`selector`, with `nearText` to confirm). A pin the user reports as detached is a pin whose element changed on the page; its comment still stands.

Then act on what the pins ask, as the subject and conversation direct. Reading the set does not end the session: tell the user briefly what you took from the pins, and return to Step 5 for the next SEND.

## Navigation and re-injection

The overlay lives in the page, so it dies on reload and on any navigation that replaces the document. When the user says the page reloaded, or a snapshot shows the controls are gone, re-inject: run the port stamp first, then the overlay source, exactly as in Step 4. If the session's listener was restarted, take the port from `arm --session "<id>"` first. A redundant re-inject is harmless - the overlay's install guard makes a second copy a no-op - so when unsure, re-inject. Pins the user had not sent come back with the page, because the overlay keeps them in the page's local storage.

## Teardown, on EVERY exit path

On every exit path, including abandonment and error - the user says they are done, the tab closes, the connection drops, the flow is interrupted - run, in this order:

1. The annotate clear on the tab (the `annotate-clear` fence), when the tab is still reachable.
2. The tombstone, so nothing sent can be read again:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" clear --session "<id>"
   ```

If the first step cannot run because the tab is gone, still run the second. Then say:

> "Cleared - the page is showing real code again."

The listener stays up until the session ends; a later `/craft:annotate` in this conversation reuses it. Teardown never shuts it down.
