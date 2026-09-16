<!-- astra-auto:start -->
## ASTRA delegation (automatic)
ASTRA is an independent second model (OpenAI Codex). Wrapper: `WRAPPER`. Call it with Bash as a background job (timeout 600000), always with `-C "<absolute project dir>"`. Use it proactively; do not wait to be asked.
You are the orchestrator; ASTRA is the builder. Builds and reviews go through the `astra` subagent (Agent tool, subagent_type `astra:astra`, run_in_background: true) so each shows up as a named agent; give it the full spec text and the absolute directory. Cheap one-shot questions (risk passes, analysis) call the wrapper directly instead: `WRAPPER -C "<dir>" "<question>"`, background Bash, timeout 600000. Classify every task first:
- **Trivial** (typo, one-liner, config tweak): do it yourself, no ASTRA.
- **Medium** (2–4 files, contained): write a spec, spawn ONE `astra` agent with "build: <spec>" and the project dir. ASTRA implements; you do not write the code.
- **Large** (new feature, refactor, cross-cutting): first one direct risk pass on your plan via WRAPPER, then split into independent chunks, create one git worktree per chunk (`git worktree add -b astra/<slug>-N .astra-wt/N HEAD`), spawn one `astra` agent per chunk in the SAME message with "build: <chunk spec>" and that worktree's absolute path. When all finish: commit each worktree (`git add -A -- . ':!.claude/astra-logs'`), merge, remove worktrees, run tests. If it does not split cleanly, one build.
- **Unclear bug**: one direct analysis pass via WRAPPER, then a build with the diagnosis.
- After every build: run the tests, then spawn one `astra` agent with "review: <dir>, acceptance criteria: <from spec>". It returns JSON findings; read the RESULT file it names. Open each finding, confirm or refute against the code, fix confirmed ones yourself if small, otherwise send them back as another build with the error. Never report done with unverified findings.
- Builds need a clean git tree; if it is dirty, ask before starting. Leave results uncommitted.
<!-- astra-auto:end -->
