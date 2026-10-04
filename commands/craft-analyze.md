---
name: analyze
description: "Post-cycle analysis — QA, UX, Creative, and Style audits using MCP browser tools."
---

# Analyze

Run comprehensive analysis on what you've built. Findings persist between sessions — nothing gets lost.

## Analysis Types

| Type | Agent | Finds |
|------|-------|-------|
| **QA** | qa-analyzer | Bugs, errors, edge cases |
| **UX** | ux-analyzer | Friction, accessibility, heuristic violations |
| **Creative** | creative-analyzer | Delight opportunities, feature ideas |
| **Style** | style-analyzer | Token violations, pattern drift |
| **Walkthrough** | walkthrough-analyzer | "Does it actually work for a human?" - clicks everything, checks every state |

QA and Walkthrough file the defects they find as bugs in `.craft/bugs/`. UX, Creative, and Style queue their findings for review.

## Flow

### Step 1: Check Pending Findings

Before any new analysis, check for existing pending findings of the requested type. Only UX, Creative, and Style keep a pending queue (`.craft/analysis/pending/ux.yaml`, `creative.yaml`, `style.yaml`). A QA or Walkthrough request skips this step and goes to Step 2, since their defects are filed as bugs and nothing queues.

**If pending findings exist:**

> "You have [N] pending [type] findings from [date]:
>
> **Critical/High:** [count]
> **Medium:** [count]
> **Low:** [count]
>
> What would you like to do?"

Use **AskUserQuestion**:
```
question: "What would you like to do with pending findings?"
header: "Pending"
options:
  - label: "Review pending findings now"
    description: "Go through existing findings before new analysis"
  - label: "Continue analysis (keep pending)"
    description: "Run new analysis, existing findings stay queued"
  - label: "Clear pending and start fresh"
    description: "Dismiss old findings, start new analysis"
```

**If user provides custom text:** Ask a clarifying AskUserQuestion before proceeding.

**If user chooses "Review pending"** → Go to Step 5 (Review Findings)

**If user chooses "Continue" or "Clear"** → Proceed to Step 2

### Step 2: Select Analysis Type

> "What kind of analysis?"

Use **AskUserQuestion**:
```
question: "What kind of analysis?"
header: "Type"
options:
  - label: "QA Pass"
    description: "Find bugs and errors"
  - label: "UX Insights"
    description: "Usability and accessibility review"
  - label: "Creative Exploration"
    description: "Find delight opportunities"
  - label: "Style Audit"
    description: "Design consistency check"
  - label: "Walkthrough"
    description: "Click everything in the live app, report what doesn't feel right"
```

**Note:** "Full Analysis" runs all types sequentially. If user selects "Other" and mentions "full" or "all", run all types.

**If user provides custom text:** Ask a clarifying AskUserQuestion to confirm which analysis type(s) they want.

### Step 3: Select Scope

**Resolve the cycle first.** Read `ACTIVE_CYCLE` from `$PROJECT/.craft/.global-state` and take the title from that cycle's `cycle.yaml`. When `ACTIVE_CYCLE` is empty (a cycle just closed), look up the last completed cycle:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/get-latest-cycle.sh" "$PROJECT" --status=complete
```

Its `CYCLE_TITLE` is the title. When that comes back empty too, there is no cycle.

> "What should I analyze?"

Use **AskUserQuestion**:
```
question: "What should I analyze?"
header: "Scope"
options:
  - label: "Current cycle"
    description: "All stories in <title>"
  - label: "Specific story"
    description: "Pick one story from the cycle"
  - label: "Specific pages"
    description: "I'll specify which pages/URLs"
  - label: "Whole application"
    description: "Full app analysis"
```

The first option reads `Current cycle` when a cycle is active, `Last completed cycle (<title>)` when only a completed one exists, and is omitted when neither exists. "Specific story" picks from that same resolved cycle.

The confirmed scope yields two values the later steps use:
- **SCOPE** - the user's words for pages or areas, a story title, `the whole application`, or `all stories in <Cycle N>` for the cycle option (`<Cycle N>` is the title's text before its first colon when it starts with "Cycle ", else the full title)
- **CYCLE_RELATION** - `active` when the scope is tied to the active cycle, `after` when it is tied to the last completed cycle, `none` otherwise

**If user provides custom text:** Ask a clarifying AskUserQuestion to confirm the scope.

**If user selects "Specific pages":**

Use **AskUserQuestion**:
```
question: "Which pages should I analyze?"
header: "Pages"
options:
  - label: "[Known page 1]"
    description: "Based on project structure"
  - label: "[Known page 2]"
  - label: "[Known page 3]"
```

**If scope is ambiguous or Claude is unsure:**

Use **AskUserQuestion**:
```
question: "I want to make sure I analyze the right things. Can you confirm?"
header: "Clarify"
options:
  - label: "[Option based on understanding]"
  - label: "[Alternative interpretation]"
  - label: "Let me explain differently"
```

**IMPORTANT:** Always confirm scope before running analysis. If uncertain about:
- Which URLs to visit
- Which components to inspect
- What user flows to test
- What the acceptance criteria mean

Ask first. Don't assume.

### Step 4: Run Analysis

**Check MCP availability first.** Chrome-devtools MCP should be available — the Craft plugin bundles it automatically.

If chrome-devtools MCP tools are not available:

> "Chrome DevTools MCP should be available through the Craft plugin, but I'm not seeing it.
>
> Try restarting Claude Code (`exit` then `claude`) to reload the plugin's MCP servers.
>
> Then run `/craft:analyze` again."

**If MCP is available**, **INVOKE the appropriate analyzer agent using the Task tool**:
- QA analysis: `craft:qa-analyzer`
- UX analysis: `craft:ux-analyzer`
- Creative analysis: `craft:creative-analyzer`
- Style analysis: `craft:style-analyzer`
- Walkthrough: `craft:walkthrough-analyzer`

Pass the confirmed scope and any relevant context to the agent.

**For walkthrough analysis**, assemble a structured brief before invoking the agent (the agent does NOT read story files - it only interacts with the browser):

1. Read `project.md` for dev server command and port
2. For each `type: ui` story in scope, extract: feature name, trigger, expected behavior
3. Pass the brief with dev server command, URL, test plan, and story context
4. The agent returns its report as text

**After the agent completes, YOU (the orchestrator) handle what it returned.** The analyzer agents have Write/Edit disabled - they return findings in their output text only.

**QA and Walkthrough: file the defects as bugs.** Build `found_during` from SCOPE and CYCLE_RELATION (`active` gives the mid-cycle form, `after` the after-close form, `none` the no-cycle form, and the cycle option the whole-cycle form), then follow `${CLAUDE_PLUGIN_ROOT}/commands/references/analysis-bug-filing.md` inline. It covers which findings file, the open-pile check, the capture call, and the report-back lines. Nothing is written to `.craft/analysis/pending/` for these two types, except the walkthrough's feels-off and nitpick findings, which the reference sends to the UX queue.

**UX, Creative, and Style: write findings to** `.craft/analysis/pending/[type].yaml`:
1. Create `.craft/analysis/pending/` directory if it doesn't exist: `mkdir -p .craft/analysis/pending`
2. Read the existing pending file (if any) to preserve prior findings
3. Parse the agent's output for findings (issues, opportunities)
4. Append new findings to the YAML file using the template format from `${CLAUDE_PLUGIN_ROOT}/templates/analysis/pending/[type].yaml`
5. Set `updated:` to current date and `scope:` to what was analyzed

**This is critical.** If you don't file or write findings to disk, they exist only in conversation context and will be lost on compaction.

User can **stop at any time** - file or write all findings discovered so far before stopping.

**During analysis, Claude should:**
- Narrate what it's checking
- Ask if something unexpected comes up
- Confirm before testing destructive/stateful actions

### Step 5: Review Findings (Two-Phase Triage)

Applies to UX, Creative, and Style findings only. QA and Walkthrough defects were filed in Step 4, so skip to Step 7 when no UX, Creative, or Style finding is pending.

Use a funnel approach: batch filter first, then detailed review only for selected items.

---

#### Phase 1: Batch Filter (Fast)

Show all findings, then use multiSelect in batches of 4 to quickly filter which ones deserve detailed review.

> "**[Type] Analysis Complete — 12 Findings**
>
> | # | Priority | Finding |
> |---|----------|---------|
> | 1 | High | Form accepts invalid email |
> | 2 | High | No loading state on checkout |
> | 3 | Medium | First task completion feels flat |
> | 4 | Low | Button hover state inconsistent |
> | 5 | Medium | Missing skip link for a11y |
> | ... | ... | ... |
>
> Let's quickly filter which ones to review in detail."

**Batch 1/3:**

Use **AskUserQuestion** with `multiSelect: true`:
```
question: "Which findings need detailed review? (1-4)"
multiSelect: true
options:
  - label: "1. Form accepts invalid email (High)"
  - label: "2. No loading state on checkout (High)"
  - label: "3. First task completion flat (Medium)"
  - label: "4. Button hover inconsistent (Low)"
```

**Batch 2/3, 3/3:** Same pattern for remaining findings.

**After all batches, handle unselected:**

```
question: "What about the 7 unselected findings?"
options:
  - label: "Dismiss all"
    description: "Won't come back"
  - label: "Keep for later"
    description: "Stay in pending queue"
```

---

#### Phase 2: Detailed Review (Thorough)

Now go through only the selected findings one-by-one for actual decisions.

> "**5 findings selected for detailed review.**"

**For UX findings:**
> "[2/5] UX Finding: No loading state on checkout
>
> **Priority:** High
> **Heuristic:** Visibility of System Status
> **Problem:** Users click multiple times, causing duplicate orders
>
> **Recommendation:** Add spinner + disable button
> **Alternatives:**
> - A: Optimistic UI with rollback
> - B: Full-page loading overlay
>
> Which approach?"

Use **AskUserQuestion**:
```
question: "Which approach for this UX issue?"
header: "UX"
options:
  - label: "Use recommendation (Recommended)"
    description: "Add spinner + disable button"
  - label: "Alternative A"
    description: "Optimistic UI with rollback"
  - label: "Alternative B"
    description: "Full-page loading overlay"
  - label: "Skip (keep for later)"
    description: "Stay in pending queue"
```

**If user provides custom text:** Ask a clarifying AskUserQuestion to understand their preferred approach.

**A UX entry with `source: walkthrough`** (a feels-off or nitpick finding queued by a walkthrough) shows Problem and Recommendation only:

Use **AskUserQuestion**:
```
question: "What should happen with this walkthrough finding?"
header: "UX"
options:
  - label: "Use recommendation (Recommended)"
    description: "Apply the recommended change"
  - label: "Skip (keep for later)"
    description: "Stay in pending queue"
```

**For Creative findings:**
> "[3/5] Creative Opportunity: First task completion feels flat
>
> **Options:**
> 1. Confetti animation (small effort, high impact) — Recommended
> 2. Achievement badge popup (medium effort)
> 3. Toast message (small effort)
>
> Which approach?"

Use **AskUserQuestion**:
```
question: "Which approach for this delight opportunity?"
header: "Creative"
options:
  - label: "Confetti animation (Recommended)"
    description: "Small effort, high impact"
  - label: "Achievement badge popup"
    description: "Medium effort"
  - label: "Toast message"
    description: "Small effort"
  - label: "Skip (keep for later)"
    description: "Stay in pending queue"
```

**If user provides custom text:** Ask a clarifying AskUserQuestion to understand their creative direction.

**For Style findings:**
> "[4/5] Style Violation: Hardcoded colors in Header
>
> **Files:** src/components/Header.tsx (lines 42, 58)
> **Found:** #6B7280, #1F2937
> **Should be:** text-secondary, text-primary
>
> **Fix options:**
> 1. Replace with Tailwind classes — Recommended
> 2. Extract to CSS variables
>
> Which fix?"

Use **AskUserQuestion**:
```
question: "Which fix for this style violation?"
header: "Style"
options:
  - label: "Replace with Tailwind classes (Recommended)"
    description: "Use design system tokens"
  - label: "Extract to CSS variables"
    description: "Create custom properties"
  - label: "Skip (keep for later)"
    description: "Stay in pending queue"
```

**If user provides custom text:** Ask a clarifying AskUserQuestion to understand their preferred fix approach.

---

**Result:** 12 findings → 5 detailed reviews → stories created for chosen ones.

### Step 6: Create Stories

**6a. Offer story drafting from findings:**

After detailed review, offer batch story creation from accepted findings:

Use **AskUserQuestion**:
```
question: "Draft backlog stories from accepted findings?"
header: "Stories"
options:
  - label: "Draft from high-severity (Recommended)"
    description: "Auto-create stories for high/critical findings"
  - label: "Let me pick"
    description: "Choose which findings become stories"
  - label: "Skip story creation"
    description: "Keep findings pending, no stories"
```

**If "Let me pick":** Use AskUserQuestion with `multiSelect: true` listing accepted findings. Allow user to select subset.

**If user asks to merge findings:** Combine their details (spark, files, criteria) into a single story.

**6b. Generate stories with full context:**

**Duplicate check — before creating each story:**

1. **Exact match:** Scan `.craft/backlog/*.md` frontmatter for `finding_id: [same ID]`. If found → skip: "Story already exists for finding [ID]: [story title]"
2. **Fuzzy match:** Check if any backlog story title shares 3+ keywords with the finding title. If found → warn with AskUserQuestion:
   ```
   question: "Similar story exists: '[existing title]'. Create anyway?"
   header: "Duplicate?"
   options:
     - label: "Skip (it's the same)"
       description: "Don't create duplicate"
     - label: "Create anyway"
       description: "These are different issues"
     - label: "Merge with existing"
       description: "Add finding details to existing story"
   ```
3. **No match:** Create normally.

For each selected finding (that passes duplicate check), create a story:

```bash
${CLAUDE_PLUGIN_ROOT}/hooks/scripts/create-story.sh "[name]" "[title]"
```

**Naming convention:**
- UX findings: `improve-[kebab-slug]` / `Improve: [title]`
- Creative findings: `enhance-[kebab-slug]` / `Enhance: [title]`
- Style findings: `fix-[kebab-slug]` / `Fix: [title]`

**After creation, append to the story file:**
- Frontmatter additions: `source: analysis/[type]`, `finding_id: [ID]`, `priority: [mapped]`
- **Severity→priority mapping:** critical→high, high→high, medium→medium, low→low
- Spark section: finding description + steps to reproduce
- Files involved: from finding's file references
- Acceptance criteria: from finding's expected behavior + fix suggestion

**Title integrity check:** After appending fields, verify the title line is properly quoted. Read the `title:` line from the story file. If it contains a colon and is NOT wrapped in quotes (e.g., `title: Fix: broken thing` instead of `title: "Fix: broken thing"`), fix it by wrapping the value in double quotes. This is critical because all analyzer naming conventions use colons (`Fix:`, `Improve:`, `Enhance:`).

**6c. Update finding status:**

Update each finding's status in the pending YAML file:
- `status: story_created` — Story was made
- `status: dismissed` — User chose to dismiss
- `status: pending` — Kept for later

Remove completed/dismissed findings from pending file (or archive them).

### Step 7: Summary

When QA or Walkthrough ran, open with the report-back lines from the filing reference (the `<N> bugs filed ...` summary and one line per record).

> "Analysis session complete:
>
> **Stories created:** [N]
> - fix-email-validation (high)
> - ux-checkout-loading (high)
> - enhance-first-task-celebration (medium)
>
> **Kept for later:** [N] findings
> **Dismissed:** [N] findings
>
> **Backlog now has [X] total stories.**
>
> What's next?"

Use **AskUserQuestion**:
```
question: "What's next?"
header: "Next"
options:
  - label: "Run another analysis type"
    description: "Continue with different analysis"
  - label: "Review remaining pending"
    description: "Go through kept findings"
  - label: "Start a new cycle"
    description: "Begin implementation planning"
  - label: "Done for now"
    description: "End the analysis run"
```

Include "Review remaining pending" only when a UX, Creative, or Style finding is pending. Omit the stories-created lines when no story was made.

**If user provides custom text:** Ask a clarifying AskUserQuestion to understand their intent.

## Pending Findings Storage

Findings persist in `.craft/analysis/pending/`:

```
.craft/analysis/
├── pending/
│   ├── ux.yaml           ← Suggestions + recommendations
│   ├── creative.yaml     ← Ideas with options
│   └── style.yaml        ← Violations with fix options
├── screenshots/
│   └── walkthrough/      ← Before/after screenshots from walkthrough
└── reports/              ← Completed analysis reports (optional)
```

QA and Walkthrough defects are filed in `.craft/bugs/`, not queued here.

See templates in `${CLAUDE_PLUGIN_ROOT}/templates/analysis/` for file formats.

## Quick Commands

Fast analysis with defaults:

```bash
/craft:analyze qa           # QA on the current cycle, or the last completed one
/craft:analyze ux           # UX on the current cycle, or the last completed one
/craft:analyze creative     # Creative on the current cycle, or the last completed one
/craft:analyze style        # Style on the current cycle, or the last completed one
/craft:analyze walkthrough  # Interactive walkthrough of live app
/craft:analyze full         # All types on the current cycle, or the last completed one
/craft:analyze pending      # Review pending UX, Creative, and Style findings
```

## MCP Browser Access

Analyzer agents access the browser via `chrome-devtools` MCP, declared in their frontmatter (`mcpServers: - chrome-devtools`). This gives them access to the actual chrome-devtools MCP tools:

**Navigation & Pages:**
- `navigate_page` — Go to URLs, reload, back/forward
- `list_pages` / `select_page` — Manage browser tabs
- `new_page` / `close_page` — Open/close tabs

**Interaction:**
- `click` — Click elements by uid
- `fill` / `fill_form` — Type into inputs, select options
- `press_key` — Keyboard shortcuts
- `hover` / `drag` — Mouse interactions

**Inspection:**
- `take_screenshot` — Capture evidence (page or element)
- `take_snapshot` — A11y tree text snapshot (preferred over screenshots)
- `evaluate_script` — Run JS in page context
- `list_console_messages` / `get_console_message` — Console errors/warnings
- `list_network_requests` / `get_network_request` — Network inspection

**Performance:**
- `performance_start_trace` / `performance_stop_trace` — Performance profiling
- `performance_analyze_insight` — Analyze performance insights

**Typical usage by type:**

| Analysis | Primary Tools |
|----------|---------------|
| QA | navigate_page, click, fill, list_console_messages, take_screenshot |
| UX | take_snapshot, navigate_page, click, take_screenshot |
| Creative | take_screenshot, navigate_page, take_snapshot |
| Style | take_snapshot, evaluate_script, take_screenshot |
| Walkthrough | click, take_screenshot, evaluate_script, list_console_messages, resize_page |

All analyzers have the same MCP access — any can use any tool.

## Key Principles

1. **Nothing gets lost** — Findings save as discovered
2. **User controls the pace** — Stop anytime, review anytime
3. **Ask when unsure** — Clarify scope before running
4. **Actionable output** — Each finding has clear next steps
5. **Recommendations included** — Claude suggests, user decides
