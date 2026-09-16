---
description: Claude orchestrates, CLAUDEX builds — split into chunks, parallel CLAUDEX builders in git worktrees, merge, CLAUDEX review, Claude verify
argument-hint: "[--dry-run] <task>"
---

Build this with CLAUDEX as the builder and you as the orchestrator: **$ARGUMENTS**

If `$ARGUMENTS` starts with `--dry-run`, remove that flag from the task and do stages 1–2 only. Print each chunk spec verbatim, including the files it owns, then estimate the builder count and effort. Stop before stage 3: do not create worktrees or start builders or reviews.

Builds and the review go through the `claudex` subagent (Agent tool, subagent_type `claudex:claudex`, run_in_background: true) so each appears as a named agent. Give each agent the full spec text and the absolute directory. You never write product code yourself in this flow; you write briefs, split work, merge, test, and verify.

## 1 · Architect
Read the code. Write `brief.md` in the scratchpad: goal, constraints, files in play, acceptance criteria, test command.

## 2 · Split
Decide whether the task splits into **independent chunks** (disjoint files, no shared interfaces that both sides must invent). If yes, write one `chunk-N.md` spec per chunk (max 4), each self-contained: the brief plus exactly what this chunk owns and what it must not touch. Where chunks share an interface, define it in the brief so both sides build to it. If the task does not split cleanly, use one chunk.

Use the [spec guide](../docs/SPECS.md) for the checklist, template, and examples.

## 3 · Build in parallel
Require a clean tree (`git status --porcelain` empty; otherwise stop and tell the user). Then for each chunk, in ONE message:
`git worktree add -b claudex/<slug>-N .claudex-wt/N HEAD`, then spawn an `claudex` agent: "build: <contents of chunk-N.md>. Directory: <absolute path of .claudex-wt/N>".
One chunk: build in the project dir instead, no worktree. Wait for all builders. After each build, read the JSON build report in its RESULT file. Treat `needs_attention` and `left_undone` as findings to check. If `measured.tests_detected` is false and `tests_run` is true, note the discrepancy.

## 4 · Merge
For worktree builds, run `"${CLAUDE_PLUGIN_ROOT}/scripts/claudex" merge -C "<root>"`, where `<root>` is the absolute project root. It commits the build worktrees and merges the `claudex/` branches. On exit 4, resolve the listed conflicts yourself in the remaining worktree(s), then re-run the same merge command. One chunk built in the project dir needs no merge. Run the test command. Fix build/test failures yourself if small; otherwise send the failure back to one CLAUDEX build call with the error and the affected files.

## 5 · CLAUDEX review
Spawn one `claudex` agent: "review: <absolute project dir>. Acceptance criteria: <from brief>". Read the RESULT file it names for the JSON findings.

Judge review coverage by `measured.tests_detected` OR `measured.executed`; an empty review with neither is low-confidence. Also treat an empty findings list as low-confidence when `coverage.confidence` is low or `measured.exec_count` < 3; in that case either rerun the review at `-e high`, or read the diff yourself before reporting. State the coverage in your report.

## 6 · Verify and report
Open each finding, confirm or refute against the code, fix the confirmed ones, re-run tests. Report: chunks and what each built, merge conflicts resolved, findings confirmed/rejected, test results, assumptions CLAUDEX stated. Worktree builds are committed by merge; leave single-chunk results and subsequent verification fixes uncommitted for the user.
