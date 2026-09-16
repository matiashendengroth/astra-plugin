# astra — Claude ⇄ Codex pipeline plugin

ASTRA = OpenAI Codex used as an independent second model around Claude Code.
`/astra <task>` runs: Claude architect → parallel ASTRA passes (scaled to task size) → Claude reconcile + implement → ASTRA adversarial review (JSON findings, can run tests) → Claude verify.

## Prerequisites (each person)
1. `npm i -g @openai/codex` then run `codex` once to log in.
2. Optional, in `~/.codex/config.toml`: `model = "gpt-6-astra"`.

## Install
```
/plugin marketplace add matiashendengroth/astra-plugin
/plugin install astra@matias
```
## Update
```
/plugin marketplace update matias
/plugin update astra
```
then restart Claude Code. Projects keep working without any re-setup, because the launcher resolves the newest version. If a release note says the CLAUDE.md rule changed, run `/astra-auto` again in the project to refresh the block in place.

## Automatic use (recommended)
Restart Claude Code once after installing so the plugin's commands appear. Then, in a project, run `/astra-auto` once. It adds a rule to `CLAUDE.md` making Claude the orchestrator and ASTRA the builder: Claude classifies each task, writes specs, runs `astra build` (in parallel git worktrees for large tasks), merges, tests, has ASTRA review the diff, and verifies every finding. Trivial edits stay with Claude. It also installs a stable launcher at `~/.local/bin/astra` (which resolves the newest installed plugin version, so plugin updates need no re-run), adds the permission rule, and gitignores the logs. `/astra-auto off` reverses it.

Manual overrides: `/astra-build <task>` forces the build flow; `/astra <task>` forces the advisory flow (Claude writes the code, ASTRA advises and reviews).

## Reasoning effort
| what | default | override |
|---|---|---|
| exec passes | low | `-e`, `ASTRA_EFFORT`, `effort=` in `.claude/astra.conf` |
| review | medium | `-e`, `ASTRA_REVIEW_EFFORT`, `review_effort=` in `.claude/astra.conf` |
| build | high | `-e`, `ASTRA_BUILD_EFFORT`, `build_effort=` in `.claude/astra.conf` |

Build timeout defaults to 1200 s (`ASTRA_BUILD_TIMEOUT`, `build_timeout=`); everything else 480 s.

`/astra-effort <level>` sets `effort=`; `/astra-effort review|build <level>` sets the mode-specific key.

## Seeing what ASTRA did
Each ASTRA build or review runs as a named `astra` agent. Open it in the desktop tasks panel or `/tasks` in the terminal: its tool output holds ASTRA's full transcript (commands, patches, test runs, notes), because the relay calls the wrapper with `-v`. The orchestrator only receives the final answer plus the log path, so the main conversation stays small. Full logs also persist in `.claude/astra-logs/`.

## Wrapper
`scripts/astra` — see the header for all options. Highlights: `-t SECS` timeout (default 480), `--json` structured review, `--ro`/`-w` sandbox override. Review defaults to workspace-write so Codex can run the test suite; set `review_sandbox=read-only` in `.claude/astra.conf` or `ASTRA_REVIEW_SANDBOX=read-only` to forbid that.

## Test
`scripts/test.sh` runs a smoke suite against a temp repo (needs a logged-in codex; ~3–5 min).
