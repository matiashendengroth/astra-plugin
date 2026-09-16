---
description: Claude ⇄ CLAUDEX pipeline — architect, parallel CLAUDEX passes, reconcile + implement, CLAUDEX adversarial review, final verify
argument-hint: <task>
---

Run the full CLAUDEX pipeline on: **$ARGUMENTS**

Analysis passes: call the wrapper directly (`~/.local/bin/claudex -C "<abs dir>" "<question>"`, background Bash, timeout 600000; pipe long prompts from a file). The review goes through the `claudex` subagent (Agent tool, subagent_type `claudex:claudex`, run_in_background: true) so it shows as a named agent.

## 1 · Claude — architect
Read the relevant code. Write a brief (goal, constraints, files in play, open questions) to the scratchpad as `brief.md`. Decide the size: **small** (1 file, local change), **medium** (2–4 files, contained), **large** (new feature, refactor, cross-cutting, unclear bug).

## 2 · CLAUDEX — parallel passes, scaled to size
Start the runs in ONE message as background Bash jobs, each fed the brief plus one angle, then wait for all:
- small → skip this stage.
- medium → **Risk** only: everything that could break; edge cases, regressions, hidden coupling, tests needed.
- large → **Design** (approach file by file, trade-offs), **Risk**, and **Alternative** (a materially different approach, argued for and against).

## 3 · Claude — reconcile + implement
Where do the passes agree, where do they conflict, what do you decide and why. Implement it yourself. Run tests/build.

## 4 · CLAUDEX — adversarial review (all sizes)
Spawn one `claudex` agent: "review: <absolute dir>. Violations of this brief count as findings: <brief>". Read the RESULT file it names.
Review runs at its own effort (default medium) with a workspace-write sandbox so it can run the tests.

Judge review coverage by `measured.tests_detected` OR `measured.executed`; an empty review with neither is low-confidence. Also treat an empty findings list as low-confidence when `coverage.confidence` is low or `measured.exec_count` < 3; in that case either rerun the review at `-e high`, or read the diff yourself before reporting. State the coverage in your report.

## 5 · Claude — final verify
For each JSON finding: open the file/line, confirm or refute against the code. Never accept on faith. Fix confirmed ones, re-run tests. Report: what was built, where CLAUDEX agreed/disagreed, each finding as confirmed/rejected with a reason, test results.
