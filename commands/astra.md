---
description: Claude ⇄ ASTRA pipeline — architect, 3 parallel ASTRA passes, reconcile + implement, ASTRA adversarial review, final verify
argument-hint: <task>
---

Run the full ASTRA pipeline on: **$ARGUMENTS**

Do every stage in order. Use the project's absolute directory for every ASTRA call.

## 1 · Claude — architect
Read the relevant code. Write a brief (goal, constraints, files in play, open questions) to the scratchpad as `brief.md`.

## 2 · ASTRA ×3 — parallel
Spawn three `astra` subagents in ONE message (run_in_background: true), each given the brief plus one angle:
- **Design** — implementation approach, file by file, with trade-offs.
- **Risk** — everything that could break: edge cases, regressions, hidden coupling, tests needed.
- **Alternative** — a materially different approach than the obvious one, argued for and against.
Wait for all three.

## 3 · Claude — reconcile + implement
Where do the three agree, where do they conflict, what do you decide and why. Then implement it yourself. Run tests/build.

## 4 · ASTRA — adversarial review
Spawn one `astra` subagent: `${CLAUDE_PLUGIN_ROOT}/scripts/astra review -C "<dir>" --uncommitted "Be adversarial. Find bugs, regressions, missed edge cases, and violations of this brief: <brief>. Rank by severity. Say explicitly if you found nothing."`

## 5 · Claude — final verify
Confirm or refute each finding against the code; never accept on faith. Fix confirmed ones, re-run tests. Report: what was built, where ASTRA agreed/disagreed, findings confirmed vs rejected, test results.
