---
description: Claude ⇄ ASTRA pipeline — architect, parallel ASTRA passes, reconcile + implement, ASTRA adversarial review, final verify
argument-hint: <task>
---

Run the full ASTRA pipeline on: **$ARGUMENTS**

ASTRA wrapper: `${CLAUDE_PLUGIN_ROOT}/scripts/astra`. Call it directly with Bash (run_in_background: true, timeout 600000) — do not go through a relay subagent. Always pass `-C "<absolute project dir>"`. For long prompts write them to a scratchpad file and pipe: `cat brief.md | ${CLAUDE_PLUGIN_ROOT}/scripts/astra -C "<dir>"`.

## 1 · Claude — architect
Read the relevant code. Write a brief (goal, constraints, files in play, open questions) to the scratchpad as `brief.md`. Decide the size: **small** (1 file, local change), **medium** (2–4 files, contained), **large** (new feature, refactor, cross-cutting, unclear bug).

## 2 · ASTRA — parallel passes, scaled to size
Start the runs in ONE message as background Bash jobs, each fed the brief plus one angle, then wait for all:
- small → skip this stage.
- medium → **Risk** only: everything that could break; edge cases, regressions, hidden coupling, tests needed.
- large → **Design** (approach file by file, trade-offs), **Risk**, and **Alternative** (a materially different approach, argued for and against).

## 3 · Claude — reconcile + implement
Where do the passes agree, where do they conflict, what do you decide and why. Implement it yourself. Run tests/build.

## 4 · ASTRA — adversarial review (all sizes)
`${CLAUDE_PLUGIN_ROOT}/scripts/astra review -C "<dir>" --uncommitted --json "Violations of this brief count as findings: <brief>"`
Review runs at its own effort (default medium) with a workspace-write sandbox so it can run the tests.

## 5 · Claude — final verify
For each JSON finding: open the file/line, confirm or refute against the code. Never accept on faith. Fix confirmed ones, re-run tests. Report: what was built, where ASTRA agreed/disagreed, each finding as confirmed/rejected with a reason, test results.
