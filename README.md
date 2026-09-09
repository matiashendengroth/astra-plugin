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
Update later with `/plugin update astra`.

## Automatic use (recommended)
In a project run `/astra-auto` once. It adds a rule to `CLAUDE.md` so Claude calls ASTRA on its own (risk pass before medium changes, design/risk/alternative before large ones, adversarial review after), adds the permission rule so there are no prompts, and gitignores the logs. `/astra-auto off` reverses it. `/astra <task>` still forces the full pipeline.

## Reasoning effort
| what | default | override |
|---|---|---|
| exec passes | low | `-e`, `ASTRA_EFFORT`, `effort=` in `.claude/astra.conf` |
| review | medium | `-e`, `ASTRA_REVIEW_EFFORT`, `review_effort=` in `.claude/astra.conf` |

`/astra-effort <level>` sets `effort=`; `/astra-effort review <level>` sets `review_effort=`.

## Wrapper
`scripts/astra` — see the header for all options. Highlights: `-t SECS` timeout (default 480), `--json` structured review, `--ro`/`-w` sandbox override. Review defaults to workspace-write so Codex can run the test suite; set `review_sandbox=read-only` in `.claude/astra.conf` or `ASTRA_REVIEW_SANDBOX=read-only` to forbid that.

## Test
`scripts/test.sh` runs a smoke suite against a temp repo (needs a logged-in codex; ~3–5 min).
