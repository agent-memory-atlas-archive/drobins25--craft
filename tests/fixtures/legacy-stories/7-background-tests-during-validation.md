---
name: no-background-tests-during-validation
title: Prevent background test runs during validation
status: complete
cycle: learnings-pipeline
story_number: 7
created: 2026-02-09
updated: 2026-02-09
priority: high
chunks_total: 1
chunks_complete: 0
current_chunk: 0
---

# Story: Prevent background test runs during validation

## Spark

Agents are running test commands with `run_in_background: true` during chunk validation, causing background task completion notifications to pile up after stories/chunks are already marked complete. The agent incorrectly blamed hooks for this, but hooks don't run tests — the agent itself chose to background them. Add explicit guidance to validate-chunk and the implementer agent: all validation commands must run synchronously. Tests must complete before marking a chunk done.

## Chunks

### Chunk 1: Add synchronous execution guidance

**Goal:** Prevent agents from running validation/test commands in the background.

**Files:**
- `plugins/craft/skills/validate-chunk/SKILL.md` — Add to Validation Philosophy section
- `plugins/craft/agents/implementer.md` — Add to Common Mistakes section

**Done When:**
- [ ] validate-chunk has explicit synchronous execution guidance
- [ ] implementer lists background tests as a common mistake
