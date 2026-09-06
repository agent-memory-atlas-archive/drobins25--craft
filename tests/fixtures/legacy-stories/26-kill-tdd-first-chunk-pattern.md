---
name: kill-tdd-first-chunk-pattern
title: "Remove 'tests first' chunk pattern from plan-chunks"
status: complete
cycle: orchestration-intelligence
story_number: 26
created: 2026-02-20
updated: 2026-02-21
priority: urgent
chunks_total: 1
chunks_complete: 1
current_chunk: 1
---

# Story: Remove "tests first" chunk pattern from plan-chunks

## Spark
The plan-chunks skill and plan-chunks-agent both enforce a TDD chunk pattern: "Chunk 1: Write tests, Middle chunks: Implementation, Final chunk: Verify." This is structurally incompatible with validation — chunk 1 writes intentionally failing tests, validation fails, test-fix triages, user intervenes, tests get .skip()'d, re-validation runs. That's 10+ minutes of wasted overhead per story for a pattern that adds no value. Tests should be written alongside the implementation they verify, in the same chunk. Each chunk is self-contained: implement + test + validate.

## Technical Concerns
- The pattern lives in two places: plan-chunks skill ("Chunk Size Guidelines" section) and plan-chunks-agent instructions
- Existing planned stories may already have "tests first" chunks — those won't be affected (already planned)
- The plan-chunks-agent may still independently decide to put tests first even without the guideline — need explicit "do NOT" instruction
- This changes planning behavior for all future stories

## Acceptance
- "Chunk 1: Write tests" pattern removed from plan-chunks skill guidelines
- plan-chunks-agent instructions updated: each chunk includes tests for what it implements
- Explicit instruction: "Do NOT create a separate 'write tests' chunk — tests belong in the same chunk as the code they verify"
- No other files changed — this is a planning instruction fix, not a validator change
