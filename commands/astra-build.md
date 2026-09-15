---
description: Claude orchestrates, ASTRA builds — split into chunks, parallel ASTRA builders in git worktrees, merge, ASTRA review, Claude verify
argument-hint: <task>
---

Build this with ASTRA as the builder and you as the orchestrator: **$ARGUMENTS**

Wrapper: `${CLAUDE_PLUGIN_ROOT}/scripts/astra`. Call it directly with Bash, run_in_background: true, timeout 600000 per call (builds are long). You never write product code yourself in this flow; you write briefs, split work, merge, test, and verify.

## 1 · Architect
Read the code. Write `brief.md` in the scratchpad: goal, constraints, files in play, acceptance criteria, test command.

## 2 · Split
Decide whether the task splits into **independent chunks** (disjoint files, no shared interfaces that both sides must invent). If yes, write one `chunk-N.md` spec per chunk (max 4), each self-contained: the brief plus exactly what this chunk owns and what it must not touch. Where chunks share an interface, define it in the brief so both sides build to it. If the task does not split cleanly, use one chunk.

## 3 · Build in parallel
Require a clean tree (`git status --porcelain` empty; otherwise stop and tell the user). Then for each chunk, in ONE message:
```
git worktree add -b astra/<slug>-N .astra-wt/N HEAD
cat chunk-N.md | ${CLAUDE_PLUGIN_ROOT}/scripts/astra build -C "$PWD/.astra-wt/N"
```
One chunk: build directly in the project dir instead, no worktree. Wait for all builders. Read each report.

## 4 · Merge
For each worktree: `git -C .astra-wt/N add -A -- . ':!.claude/astra-logs' && git -C .astra-wt/N commit -qm "astra: chunk N"`, then `git merge --no-ff astra/<slug>-N` into the current branch. Resolve conflicts yourself. Remove worktrees and branches when merged. Run the test command. Fix build/test failures yourself if small; otherwise send the failure back to one ASTRA build call with the error and the affected files.

## 5 · ASTRA review
`${CLAUDE_PLUGIN_ROOT}/scripts/astra review -C "<dir>" --uncommitted --json "Acceptance criteria: <from brief>"`

## 6 · Verify and report
Open each finding, confirm or refute against the code, fix the confirmed ones, re-run tests. Report: chunks and what each built, merge conflicts resolved, findings confirmed/rejected, test results, assumptions ASTRA stated. Leave the result uncommitted for the user.
