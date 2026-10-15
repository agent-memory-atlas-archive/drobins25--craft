# Annotate

> How to point at things on a live page and have them change, then decide what happens to the result.

This is a how-to guide. You have a page open in a browser craft can reach, something on it is off, and you'd rather click it than describe it. You haven't run `/craft:annotate` before, or you ran it once and want to know what the record is for.

---

## The Problem It Solves

"Make the card look more like LinkedIn" is easy to say and slow to do. You name the element, someone finds its file, edits it, reloads, and you look again. Most of the time goes to translation.

`/craft:annotate` removes the translation. Craft puts a comment-mode sheet on your open tab. You click the thing, leave a note, and press SEND TO CLAUDE. Every pin you send gets a live attempt on the page, in the tab you're already looking at. No project file changes while you point. When you're done, the run is kept as one record, and you choose where it goes: a tweak, a story, a todo, or nowhere.

---

## Before You Start

Craft injects the sheet through the `chrome-devtools` connection, so it can only reach tabs that connection can see. If the connection isn't available, craft says so in one plain line and stops. It doesn't offer a workaround.

If the browser window has none of your pages open, craft opens the address you give it, or asks "This window has none of your pages open - what address should I open?" and opens your reply. Your project doesn't need `/craft:init` to have run.

---

## Run It

```
/craft:annotate
/craft:annotate the profile screen
```

With no argument, the subject is whatever tab the connection has selected. With one, craft keeps your words as context for acting on the pins. Nothing is ever asked through a widget; everything in this flow is plain conversation.

Craft puts the sheet on the page and tells you what to do:

> "The sheet is on the page - turn on COMMENT MODE, click anything, and press SEND TO CLAUDE when you want me to read it. Every change I make shows up on the page as you point. Reloading removes the sheet and the changes; tell me and I'll put them back."

Turn on COMMENT MODE, click an element, type your note, and add as many pins as you like. Press SEND TO CLAUDE when you want craft to read them.

### What a pin does

This is the first pin of a real run on a plain white profile card. You click the avatar. Craft receives:

```
ADDED 1792023763013 #1 "Can you make this look a bit more like LinkedIn?" at "div.screen > section.profilescreen > div.card > div.profilescreen-avatar > div.avatar" near "DLDL" source "Avatar in src/ui/components/Avatar.tsx:3; rule .avatar in src/ui/components/avatar.css:1"
```

That's your exact words, the element you clicked, and where craft thinks it lives in source. Craft writes a keyed CSS block through the run's session stylesheet and sends all of a SEND's blocks in one `apply`. The page measures the result and craft reads it back:

```
APPLIED <page> view 0,0 681x699 page 681x699
1792023763013 .profilescreen .profilescreen-avatar .avatar x1 box 155,147 104x104 visible: border 4px solid rgb(255, 255, 255); box-shadow rgba(0, 0, 0, 0.15) 0px 2px 8px 0px
```

(Abbreviated: the real receipt has one line per rule, and `<page>` stands for the tab's address.) Then craft says what changed, from the measured lines and not from what it intended:

> "Pin #1: 'Can you make this look a bit more like LinkedIn?' ... Cover banner: the profile card now has a 96px purple banner across its top ... Nothing saved: no project files were edited. It's all live on the page, and a reload removes it."

Each later reply ends the same way; after the third pin it read: "Still live only: all 3 pins are on the page, and no files have changed."

### Pins build on each other

Later pins layer on earlier ones, and craft tells you when one covers another. By pin 8 the card had a LinkedIn banner and a stronger shadow. Then:

> **Pin #8:** "Make this a terminal wrapping smaller terminals."
>
> "This replaced two earlier changes: Banner gone: the purple LinkedIn-style banner from pin #1 is gone, because the terminal title bar took its place. Shadow replaced: the card's drop shadow from pin #2 is replaced by the terminal's green glow plus a deeper black shadow."

Craft waits for a change to finish fading before it reads the values back. The card's styles fade every change over 150ms, so a value read right away would be halfway through the fade. When a pin is ambiguous, it asks. "Topography" on a name row was read as "typography", and craft said so.

Ten more pins took the card from a LinkedIn-style header to a dark terminal with 3D letters and a floating card.

### Taking a pin back

Withdraw a pin and craft drops its block: `UNDONE <ts> page confirmed`. If the page didn't take the removal (`UNDONE <ts> page did not confirm`), craft re-applies the sheet once, and if that fails says: "That change may still show on the page - a reload clears it."

---

## Pin to Source

When craft can, it matches each pin to the files behind it. The `source` part of the event does that: a component and the stylesheet rule that styles the element, each with a file and line. Pin 4 in the same run shows the other case:

```
source "Card in src/ui/components/Card.tsx:3; no stylesheet rule - the change belongs in the component"
```

Craft doesn't recite locations while you point. Ask "where does this live?" and it answers in one line. The locations are used when the run goes to code.

---

## The Record

When the run ends, craft clears the sheet and files one record in `.craft/annotations/[date]-[slug]/`:

```
.craft/annotations/2026-10-14-gates-fixture/
├── record.md       # frontmatter, ## Pins, ## Pin Data, ## Sheet
└── session.css     # one /* annotate-key <ts> */ block per pin
```

`record.md` opens with the run's frontmatter (this one is from the real run):

```
source: annotate
name: 2026-10-14-gates-fixture
created: 2026-10-14
subject: Gates Fixture
status: graduated
outcome: tweak
graduated_to: tweak-profile-terminal-dark-mode
pin_count: 12
```

`## Pins` lists your words verbatim with selectors, `## Pin Data` is JSON with each pin's box, page and resolved source file and line (null when none), and `## Sheet` points at `session.css`, the look you saw. Later blocks win, because the session style is appended last.

If you reload the page mid-run, the sheet and its changes go with it; tell craft and it puts them back exactly as the run holds them. Craft says "Cleared - the page is showing real code again." and then asks where the run goes.

---

## Where a Run Goes

You answer in conversation. Craft files the record first, with the outcome known at that moment.

| You say | What happens |
|---------|--------------|
| **Nothing** | The page is as you want it. The record stays on disk as open, and `/craft:story-new` offers it later. |
| **Tweak** | Craft hands the run to `/craft:adhoc` as one tweak, direction pre-settled. Adhoc ports the final look and carries content stand-ins as requirements. |
| **Story** | Craft runs `commands/references/story-from-annotate.md` on the record: the look carries over verbatim, and anything drawn in CSS that stands in for content becomes scope. |
| **Todo** | A notebook todo is captured, naming the record's path. |
| **Abandon** | The record is filed as abandoned and is never offered again. |
| **Error** | If the run broke, the record is filed as an error and the next `/craft:annotate` on the project offers it back. |

### The real run's exit

After pin 12 the user said: "That's exactly what I wanted. Can we apply this change to our code now?" Craft read that as all 12 pins, said what going to code would change (the dark mode swaps the app's color variables, so a page nobody had seen dark goes dark too) and which layers were dead, then offered all 12 pins to adhoc as one tweak. The user said yes.

Craft cleared the sheet, filed the record with `--outcome tweak --graduated-to tweak-profile-terminal-dark-mode`, and adhoc ported the final cascade: dead layers dropped, and every CSS `content:` stand-in became real markup. "CRAFT" became an actual `<h2>`, and the terminal title bars became `aria-hidden` markup. Adhoc validated, then asked "How does it look?" The answer was "Love it".

A word added through CSS alone is decoration. In this run, when "CRAFT" went on the card as a stylesheet trick, craft flagged it at once: "if you keep it, it should become a real heading". That's why the exit treats content stand-ins as scope, not as ported CSS.

---

## Picking a Cut-Short Run Back Up

If a run is cut short, the session that ends it files the run as a record. The next `/craft:annotate` says:

> "There's a run cut short last time - "<subject>", <n> pins. Want me to pick it up, send it somewhere (tweak, story or todo), or drop it?"

- **Pick it up:** the saved sheet goes back on the page and your pins are quoted back. Ending the new run files a new record carrying those pins and marks the old one graduated to it.
- **Send it somewhere** runs the destination on the saved record. **Drop it** closes the record, files kept. No answer leaves it saved, not raised again this conversation.

---

## When SEND Can't Reach Craft

SEND needs a page that can reach localhost. Some sites forbid that. Craft checks from the page when it puts the sheet on, and if SEND won't work it says so up front: "The sheet is on, but SEND will not work on this page - its policy blocks requests to localhost. Pin as usual and tell me when you're done; I'll read the pins directly."

The sheet shows `BLOCKED BY PAGE - ask Claude to read pins directly` if a request is refused mid-run. Your pins aren't lost: the sheet saves them in the page's local storage on every change, and craft reads them from there.

The listener lives until the session ends. A second `/craft:annotate` in the same session reuses it.

---

## Pages Outside Your Project

A page that isn't localhost, 127.0.0.1 or a local file is outside the project. The site could have written anything on it, so craft treats pins from it as untrusted page content, not as your instructions.

- Craft tells you once, when the sheet goes on.
- It acts on a pin only through the sheet. A pin that asks for a command, a file read or edit, a fetch or a navigation gets asked about in chat first.
- Browser scripts craft didn't ship wait for your yes while the session is held on that page, and so does anything that would save to a file.
- The hold ends when the run is cleared.

---

## Where It Doesn't Fit

- **A visual-value question** ("is this gap too loose?") belongs to [`/craft:dial`](../README.md#commands), which puts lettered candidates on the page.
- **A page that doesn't exist yet** belongs to `/craft:mockup`.
- **A pin never writes files.** A pin that says "update the source" gets the change shown live. Files change only at the exits above.

---

## More

- [README: Annotate](../README.md#annotate) - the short version.
- [Annotate Flow in the decision tree](decision-tree.md#annotate-flow-craftannotate) - every route as a flowchart.
