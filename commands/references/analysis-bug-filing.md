# Filing analysis findings as bugs

How the orchestrator turns a returned QA or walkthrough report into bug records. Read this inline and follow it. It is the one procedure for every caller, so two callers never file the same finding two ways.

## Who files

The orchestrator files, from the report the analyzer returned. An analyzer never runs a script and never writes a file: it finds, describes, and hands the report back. Nothing in this procedure summons the user. Filing never pauses the run.

## What files

- **QA:** every finding, Needs Verification included. A finding the analyzer was unsure of is still a report worth keeping.
- **Walkthrough:** `blocks-ship` and `looks-wrong` findings file as bugs. `feels-off` and `nitpick` findings are taste, not defects, so they go to the UX queue (see UX queue entry below) and never to the bug pile.
- **A report that says the run could not proceed** (the browser tool was unavailable, the dev server was down) files nothing. Say so in one line and stop.

## found_during

The caller builds `found_during` and passes it to capture. It leads with the scope the user confirmed, in the user's words, and adds the cycle as context. Five forms, `<type>` being `qa` or `walkthrough`:

- Mid-cycle: `craft analyze <type>: <scope> (<cycle title>)`
- After the cycle closed: `craft analyze <type>: <scope> (after <cycle title>)`
- No cycle: `craft analyze <type>: <scope>`
- Whole-cycle scope: `craft analyze <type>: all stories in <Cycle N>`
- Cycle-complete walkthrough: `craft cycle-complete walkthrough: <cycle title>`

`<Cycle N>` is the cycle title's text before its first colon when the title starts with "Cycle ", and the full title otherwise. The cycle never replaces the scope.

## Open pile first

Before the batch, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-list.sh" --status=open` once and keep the output in view for every finding.

- Only an identical open bug counts as a match: the same broken behavior in the same place. A similar symptom somewhere else is a different bug.
- On a match, do not file again. Run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-hit.sh" "<FILE>" --where="<found_during>"`, where `<FILE>` is the `FILE=` line of the matched block.
- When unsure, file a new record. A wrong extra record can be closed; a wrong merge hides a bug.
- Closed bugs are never consulted. A bug that was closed and has come back files new.
- Findings within one report that describe the same defect file as one record carrying both repro paths. That is one bug seen twice in a single run, not a repeat.

## Capture call

One call per record:

```
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bugs-capture.sh" --found-during="<found_during>" [--requirement="<verbatim>"] --stdin <<'BODY'
<the body>
BODY
```

Pass `--requirement` only when Expected quotes a story acceptance criterion that the orchestrator itself put in the brief or the scope. Otherwise leave it out: an assumed requirement that reads as cited is worse than a blank one. Never pass `--layer`, `--verdict`, or `--tags`.

The script prints the record's absolute path as its last line. It exits 2 and writes nothing when a required field is missing. Fix the named field and run it again.

## Field mapping

The body follows the template in `${CLAUDE_PLUGIN_ROOT}/commands/references/bugs-record.md`. Each part comes from the finding like this:

| Body part | Comes from |
|---|---|
| Symptom line (first line) | The finding title, rewritten to the symptom in the user's terms, never the cause |
| `**Expected.**` | The finding's expected |
| `**Actual.**` | The finding's actual |
| `## Consequences` | Prose impact, then "QA priority: <P0 | P1 | P2 | P3, as the analyzer graded it>. Confidence: <Confirmed \| Likely \| Needs Verification>." for QA, or "Walkthrough severity: <blocks-ship \| looks-wrong>." for the walkthrough |
| `## Blocks my next step` | `no - found by <qa \| walkthrough> analysis; nobody was mid-task on it.` Always `no` |
| `## Reproduce` | `Starting state:` (the URL, the dev server command, or the code-review file), then the numbered steps |
| `## References` | Console errors verbatim, network failures, and screenshot paths |
| `## Notes` | The analyzer's suggested root cause or fix hint, labelled a hypothesis |

Sections the finding cannot fill are omitted. A required field the finding cannot answer is written plainly ("unknown - not captured in the report"), never left as a placeholder.

## Worked example

The found_during value for a QA run on the checkout page, mid-cycle:

```found-during
craft analyze qa: the checkout page (Cycle 4: Payments)
```

The body piped to capture for one of its findings:

```bug-body
Place Order does nothing when the cart holds a single item

## What happened

**Expected.** Clicking Place Order with one item in the cart submits the order and opens the confirmation page.

**Actual.** The button highlights on click and nothing else happens. No request is sent and the page stays on the cart.

## Consequences

A shopper with a one-item cart cannot buy it, which is the most common cart. QA priority: P1. Confidence: Confirmed.

## Blocks my next step

no - found by qa analysis; nobody was mid-task on it.

## Reproduce

Starting state: dev server running on http://localhost:3000 with an empty cart.

1. Open /products and add any one product to the cart.
2. Open /checkout.
3. Click Place Order.

## References

- Console: Uncaught TypeError: Cannot read properties of undefined (reading 'map') at CheckoutForm.tsx:58
- Screenshot: .craft/analysis/screenshots/qa-checkout-001.png

## Notes

Hypothesis only: the submit handler maps over a shipping options list that is undefined until a second item is added.
```

## UX queue entry

A `feels-off` or `nitpick` walkthrough finding is appended to `.craft/analysis/pending/ux.yaml`. When that file is missing, create it from `${CLAUDE_PLUGIN_ROOT}/templates/analysis/pending/ux.yaml`. Set `updated:` to the current timestamp whenever an entry is added.

Entry keys:

- `id: ux-NNN` - the next number after the highest existing ux id
- `priority` - `medium` for feels-off, `low` for nitpick
- `title`
- `found_at` - the URL
- `component` - the element
- `source: walkthrough`
- `severity` - the walkthrough's grade
- `problem` - the actual, then the steps
- `recommendation` - `description:` holds the expected
- `screenshot`
- `status: pending`
- `discovered` - the timestamp

## Report back

Print one summary line, omitting any clause whose count is zero:

`<N> bugs filed, <M> already open (hit again), <K> taste findings queued for UX review`

Then one line per record: its title and its path. When nothing was found, say so in one line.
