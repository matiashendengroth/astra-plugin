<!-- claudex-auto:start -->
## CLAUDEX delegation (automatic)
CLAUDEX is an independent second model (OpenAI Codex). Wrapper: `WRAPPER`. Call it with Bash as a background job (timeout 600000), always with `-C "<absolute project dir>"`. Use it proactively; do not wait to be asked.
You are the orchestrator; CLAUDEX is the builder. Builds and reviews go through the `claudex` subagent (Agent tool, subagent_type `claudex:claudex`, run_in_background: true) so each shows up as a named agent; give it the full spec text and the absolute directory. Cheap one-shot questions (risk passes, analysis) call the wrapper directly instead: `WRAPPER -C "<dir>" "<question>"`, background Bash, timeout 600000. Classify every task first:
- **Trivial** (typo, one-liner, config tweak): do it yourself, no CLAUDEX.
- **Medium** (2–4 files, contained): write a spec, spawn ONE `claudex` agent with "build: <spec>" and the project dir. CLAUDEX implements; you do not write the code.
- **Large** (new feature, refactor, cross-cutting): first one direct risk pass on your plan via WRAPPER, then split into independent chunks, create one git worktree per chunk (`git worktree add -b claudex/<slug>-N .claudex-wt/N HEAD`), spawn one `claudex` agent per chunk in the SAME message with "build: <chunk spec>" and that worktree's absolute path. When all finish: commit each worktree (`git add -A -- . ':!.claude/claudex-logs'`), merge, remove worktrees, run tests. If it does not split cleanly, one build.
- **Unclear bug**: one direct analysis pass via WRAPPER, then a build with the diagnosis.
- After every build: run the tests, then spawn one `claudex` agent with "review: <dir>, acceptance criteria: <from spec>". It returns JSON findings; read the RESULT file it names. Open each finding, confirm or refute against the code, fix confirmed ones yourself if small, otherwise send them back as another build with the error. Never report done with unverified findings.
- Judge the review by its coverage. Treat an empty findings list as low-confidence when measured.tests_detected is false or coverage.confidence is low or exec_count < 3; in that case either rerun the review at -e high, or read the diff yourself before reporting. State the coverage in your report.
- Builds need a clean git tree; if it is dirty, ask before starting. Leave results uncommitted.
- Progress: `WRAPPER status -C "<dir>"` lists running builders and recent runs; tell the user to use `/claudex-status` and `/claudex-cancel` if they ask how to watch or stop it.
<!-- claudex-auto:end -->
