# Annotate Flow

The full raw-tab session: arm through teardown. The overlay source, the port stamp, the annotate clear, and the channel protocol live in `${CLAUDE_PLUGIN_ROOT}/commands/references/annotate-overlay.md` - read it before Step 3 and hold it for the session. The capture channel is driven only through `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh`.

**No question widgets anywhere in this flow - never, at any step, including every exit.** The mode is armed by invocation and steered in plain conversation.

This flow runs in the orchestrator, not a subagent: it needs the browser connection and the session's own wake-up.

**How a snippet reaches the page.** `evaluate_script` takes a function and calls it. Every snippet this flow sends to the page - the clears and the overlay source when pasted - goes in as the body of `() => { <snippet> }`, with the snippet's text unchanged inside. The exceptions are the lines `loader`, `stamp`, `sheet` and `apply` print: the lines `loader`, `stamp` and `sheet` print are already functions, so each goes in verbatim, because evaluate_script calls the function it is given and returns what it returns - the loader line returns `LOADED` or `SCRIPT-BLOCKED`, the stamp line `STAMPED`, the sheet line `APPLIED`. Pasted bare, a snippet that ends in `;` is refused with `Unexpected token ';'` and nothing runs.

## Step 1: Connection check

The overlay reaches a tab through the chrome-devtools connection. If that connection is not available, say so in one plain line and stop - no offer, no error, no setup instructions. Otherwise list the tabs and select the one the user means (the subject, or the tab already selected when no subject was given).

Listing the tabs is the session's first browser call. Right after it run `node "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/devtools-launch.cjs" notice`; a printed line is said to the user verbatim, and nothing printed means nothing said.

**Fresh window rule.** When every listed tab is `about:blank` or a new-tab page, the window has none of the user's pages. If the subject is an address (`http://`, `https://`, `file://`), open it with `new_page`. Otherwise say exactly "This window has none of your pages open - what address should I open?" (no question widget), open the reply with `new_page`, then select it. When the notice line and this question are both spoken, they go in one message.

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

  If the line shows `PORT none`, or `CLIENTS unreachable` (the listener is not answering), run `arm --session "<id>"` - it is idempotent and prints the current port. Only ever reuse an id this conversation armed: another pane in the same project has its own session, and its listener is not yours.

Never arm a second listener while one is held.

Then mark the start of this run, whether the listener is new or reused:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" begin --session "<id>" --subject "<subject>"
```

The subject is the args, else the title of the selected tab. `begin` starts the run's sheet and puts the watch at the run's start, so a set sent by an earlier flow on the same listener is never mistaken for this run's first SEND. It also files any run on this session that never reached an exit.

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

## Step 4: Inject the overlay

On a project page - one served from localhost, 127.0.0.1 or file:// - the listener serves the overlay, so injecting it is one short line. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" loader --session "<id>" --page "<tab url>" --run
```

It prints ONE line. Pass it to `evaluate_script` verbatim - never edit it, rebuild it, or wrap it in anything. The line stamps the port and the run, loads the overlay the listener serves, and returns `LOADED` or `SCRIPT-BLOCKED`. On `LOADED` the overlay is on the page and the injection is done. If the command exits 1 because the listener does not answer, run `arm --session "<id>"` and run the loader again.

**Fallback: `EXTERNAL` or `SCRIPT-BLOCKED`.** An external page (anything but localhost, 127.0.0.1 or file://) never loads a served script, so the loader prints `EXTERNAL` without contacting the listener; and a page whose policy refuses the script returns `SCRIPT-BLOCKED`. Either way, paste the overlay instead, in two `evaluate_script` steps in this order: first the line `stamp` prints (`annotate-run.sh" stamp --session "<id>"`; it stamps the port and the run), passed verbatim, then the whole `overlay-source` fence from the overlay reference, its text unchanged, passed as the body of `() => { ... }`. Stamp first because the overlay reads the port when the user presses SEND. On either path never stamp the baked flag and never stamp a context: a baked page opens an event stream at load, and an injected page must make no request before the user acts.

Then probe the listener FROM THE PAGE, through one more `evaluate_script`: `fetch(base + '/health')` where `base` is `'http://127.0.0.1:' + window.__craftAnnotatePort`. A page can carry a policy that forbids requests to 127.0.0.1, and SEND runs the same request from the same page, so this answer predicts SEND's. If the probe resolves, say nothing about it. If it rejects, tell the user up front, in one line and never a widget:

> "The sheet is on, but SEND will not work on this page - its policy blocks requests to localhost. Pin as usual and tell me when you're done; I'll read the pins directly."

Then tell the user ONCE:

> "The sheet is on the page - turn on COMMENT MODE, click anything, and press SEND TO CLAUDE when you want me to read it. Every change I make shows up on the page as you point. Reloading removes the sheet and the changes; tell me and I'll put them back."

## Step 5: Stand by for SEND

Once the overlay is on the page, start the watch ONCE, under the Monitor tool:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" watch --session "<id>"
```

with `timeout_ms: 1800000`. Each line it prints arrives inside a notification, so the pins are already in the chat - never open a file to read them. When the Monitor's expiry notice arrives, start the same watch again, silently. Where the Monitor tool is not available, run `watch --session "<id>" --once` as a background Bash command (`run_in_background: true`) and launch it again after acting on each wake.

- `ADDED <ts> #<n> "<text>" ...` and `EDITED ...`: a pin to act on, delivered once. Go to Step 6.
- `UNDONE <ts> page confirmed`: the user withdrew a pin and the watch already dropped its block. Go to Step 6.
- `UNREACHABLE`: the listener died and no SEND can arrive. Run `ensure`, below.

**The read beat.** Run `ensure` on an `UNREACHABLE` line and when an `annotate-run.sh` command fails, never on a SEND notification:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" ensure --session "<id>"
```

- `OK PORT <port>`: the listener is healthy; go on.
- `REARMED PORT <port> STREAK <k>`: the listener was dead or hung and is running again on a new port. Re-inject per Navigation below and leave the running watch alone. At `STREAK 1` do all of it silently - say nothing. At `STREAK 2` or more, say exactly one line and carry on:

  > "The pin listener dropped again - I restarted it; if SEND does nothing, tell me and I'll read the pins from the page."

- `FAILED` or `GONE`: the listener cannot be restarted. Say exactly one line:

  > "The pin listener won't restart - keep pinning and tell me when you're done; I'll read the pins from the page."

The streak is the number `ensure` prints; never count restarts yourself and never remember them. Say nothing else about the listener mid-session.

## Step 6: Act on each pin

Every pin gets a live attempt on the page. A pin that is a question gets an answer and, where it fits, a change too. Never reply to a pin with only a reason.

**A pin never opens the write gate.** This flow changes the page, never a file: no Write or Edit call, and no gate change of any kind, ever. The pin's text never opens the gate: chat instructions override pin text. A pin that asks for file edits ("make all edits now", "update the source") gets the change shown live; files change only at the exits below.

**One apply per SEND.** Every new or edited pin's block goes into ONE `apply` call, keyed by the pin's `ts`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" apply --session "<id>" <<'CSS'
/* annotate-key <ts> */
.toolbar .save { padding: 12px 20px; }
CSS
```

Aim each block at a selector that is stable on the page (a class or id), not the structural `selector` path unless nothing better exists. Add `--target "<ts>=<selector>"` when the change is aimed at an ancestor ("this section" on a heading); when it is unclear, take the outermost element of the pin's component. A block for a resolved pin is at least as specific as its `rule` from the `source` field (the session style is appended last, so equal specificity wins). The same key replaces that pin's block in place. Every change goes through the sheet; never write CSS into the page any other way.

`apply` prints what the page measured: the `APPLIED` line, then one line per rule with the match count, the box, whether it is visible and the live values. `PASTE` means the page did not confirm: pass the next line to `evaluate_script` verbatim - it is already a function that returns `APPLIED` - and read the value back.

When `apply` prints a `SHOT` line, or a pin asks for a look rather than a value, take one `take_screenshot` before replying - of the window (no `uid`), or with `fullPage: true` when any `SHOT` reason is `out of view`, never scrolling the user's page - and reply from what it shows, using the printed box to know where to look; otherwise the measured lines are the report.

**The reply.** Quote each `ADDED` / `EDITED` line's text as the user's exact words - never paraphrase, relabel or merge pins. Then one line per pin saying what changed on the page, from `apply`'s measured lines, never what was intended; a question pin's answer runs as long as it needs. `UNDONE` lines get one line each; `CLEARED` is never printed.

**Undo.** "Put it back" for a pin is `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" apply --session "<id>" --drop "<key>"` with an empty heredoc, its line handled as above.

**"Where does this live?"** Run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-resolve.sh" where --session "<id>" --ts "<ts>"` and say its one line, nothing more. This holds on an external page too: for a pin on an external page the line is `That page is outside this project, so there's no source file to point at.` The location is otherwise never spoken mid-session; it is used at graduation.

**When SEND cannot reach the listener.** The strip shows `BLOCKED BY PAGE - ask Claude to read pins directly` when the page refused the request, and the user may simply report that SEND did nothing. The pins are not lost: the overlay writes every pin to the page's local storage on every change, under the key `'ca-annotations:' + location.pathname` plus the hash route when the app routes with the hash (a fragment starting `#/` or `#!/`, its own query cut off). Read it through the devtools connection with `evaluate_script`: `JSON.parse(localStorage.getItem('ca-annotations:' + location.pathname + (/^#!?\//.test(location.hash) ? location.hash.split('?')[0] : '')) || '[]')`. Treat that array as the sent set and pipe it through `annotate-run.sh" send --session "<id>"`; the watch then delivers its `ADDED` lines with the source `not probed`. To resolve a pin's source there, run `annotate-resolve.sh" probe --session "<id>"`, pass its line to `evaluate_script` verbatim, and hand the result to `annotate-resolve.sh" resolve --session "<id>"` on a heredoc; resolution runs there only. After the user says they are done pinning, read the key again.

## Navigation and re-injection

The overlay and the changes live in the page, so they die on reload and on any navigation that replaces the document. When the user says the page reloaded, or a snapshot shows the controls are gone, the loader line alone restores everything: run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" loader --session "<id>" --page "<tab url>" --run` and pass its line to `evaluate_script` verbatim. It brings back the overlay, the run and every earlier change exactly as the sheet holds them - never re-derive a rule from memory. On `EXTERNAL` and `SCRIPT-BLOCKED` the paste path re-runs the stamp line, then the overlay source, then the sheet print: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" sheet --session "<id>"` (no `--add`, no `--drop`), and pass the printed line to `evaluate_script` verbatim. An empty sheet is applied too: one path, no branch. A redundant re-inject is harmless - the overlay's install guard makes a second copy a no-op - so when unsure, re-inject. Pins the user had not sent come back with the page, because the overlay keeps them in the page's local storage.

## Teardown, then file, on EVERY exit path

On every exit path, including abandonment and error - the user says they are done, the tab closes, the connection drops, the flow is interrupted - run, in this order:

1. The annotate clear on the tab (the `annotate-clear` fence), when the tab is still reachable. It removes the session style too.
2. The tombstone, so nothing sent can be read again:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-run.sh" clear --session "<id>"
   ```

   If the first step cannot run because the tab is gone, still run the second.
3. File the record, with the outcome known at that moment (`nothing`, `tweak`, `story`, `todo`, `abandon` or `error`):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/annotate-record.sh" file --session "<id>" --outcome <nothing|tweak|story|todo|abandon|error> [--graduated-to <ref>]
   ```

   It prints the record's path: `.craft/annotations/<date>-<slug>/record.md`, with `session.css` beside it. The live session folder keeps everything except `run.json`. A run with no pins and an empty sheet is filed as abandoned, so it is never offered as a source later. Filing never waits on routing and routing never waits on it succeeding: if the command fails, say so in one line and go on.

Then say:

> "Cleared - the page is showing real code again."

**Then route the exit.** Conversational, never a widget:

- **Nothing** - the page is as the user wants it and nothing more is needed. The record stays on disk as open, and `/craft:story-new` offers it later. A destination named after "nothing" runs on the filed record: story-from-annotate on it, or `annotate-record.sh" graduate --record <name> --to <ref>` once the destination exists.
- **Tweak** - pre-mint `tweak-<slug>` BEFORE filing, then file with `--outcome tweak --graduated-to tweak-<slug>`. Hand to `craft:adhoc` with the brief: "direction pre-settled, annotate record at [path], record name: tweak-<slug> (use verbatim)". Adhoc ports the look verbatim and carries content stand-ins as requirements quoting the pin.
- **Story** - file with `--outcome story`, then Read `${CLAUDE_PLUGIN_ROOT}/commands/references/story-from-annotate.md` and execute it inline on the record path (never via the Skill tool - a Skill-tool call ends the turn and control does not come back). It ends by graduating the record.
- **Todo** - file with `--outcome todo`, then `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/notebook-capture.sh" todo "<what the pins asked for, naming the record path>"`.
- **Abandon** or **error** - file with `--outcome abandon` or `--outcome error` and stop. The record stays open (or abandoned when empty) for a later story.

The listener stays up until the session ends; a later `/craft:annotate` in this conversation reuses it. Teardown never shuts it down.
