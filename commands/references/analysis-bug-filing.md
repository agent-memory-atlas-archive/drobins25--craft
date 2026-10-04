# Filing analysis findings as bugs

How the orchestrator turns a returned QA or walkthrough report into bug records. Read this inline and follow it. Read `${CLAUDE_PLUGIN_ROOT}/commands/references/bugs-record.md` first and follow it. This file adds only what is specific to a QA or walkthrough report.

## Who files

The orchestrator files, from the report the analyzer returned. An analyzer never runs a script and never writes a file: it finds, describes, and hands the report back. Nothing in this procedure summons the user. Filing never pauses the run.

## What files

- **QA:** findings file by the bug reference's rules.
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

Pass `--requirement` only when Expected quotes a story acceptance criterion that the orchestrator itself put in the brief or the scope. Otherwise leave it out: an assumed requirement that reads as cited is worse than a blank one.

The script prints the record's absolute path as its last line. It exits 2 and writes nothing when a required field is missing. Fix the named field and run it again.

## The body

The body follows the template in `${CLAUDE_PLUGIN_ROOT}/commands/references/bugs-record.md`. Expected, Actual, and Reproduce come from the finding's expected, actual, and steps. Consequences is the impact in the reader's terms; the analyzer's priority, confidence, and walkthrough grade stay in its report. `## Blocks my next step` starts `no - found by <qa | walkthrough> analysis; nobody was mid-task on it.` Console errors, network failures, and screenshot paths go in `## References`. The analyzer's suggested cause goes in `## Notes`, labelled a hypothesis.

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

**Actual.** The button highlights on click and nothing else happens. No request leaves the page and the cart stays on screen.

## Consequences

A shopper with a one-item cart cannot buy it, and one item is the most common cart.

## Blocks my next step

no - found by qa analysis; nobody was mid-task on it.

## Reproduce

Starting state: dev server running on http://localhost:3000 with an empty cart.

1. Open /products and add any one product to the cart.
2. Open /checkout.
3. Click Place Order.

## Evidence

Console after step 3: Uncaught TypeError: Cannot read properties of undefined (reading 'map') at CheckoutForm.tsx:58. Network panel: no request to /api/orders.

## Done when

Steps 1-3 with one item in the cart send a POST to /api/orders and open the confirmation page, and the console shows no TypeError.

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
