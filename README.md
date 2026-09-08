# astra — Claude ⇄ Codex pipeline plugin

`/astra <task>` runs: Claude architect → 3 parallel ASTRA (Codex) passes → Claude reconcile + implement → ASTRA adversarial review → Claude verify.

## Prerequisites (each teammate)
1. `npm i -g @openai/codex` and run `codex` once to log in.
2. Optional: set the model in `~/.codex/config.toml`, e.g. `model = "gpt-6-astra"`, `model_reasoning_effort = "xhigh"`.

## Install
In Claude Code:
```
/plugin marketplace add matiashendengroth/astra-plugin
/plugin install astra@smarteating
```
Then `/astra <task>` in any project. Approve the `scripts/astra` command once when prompted, or add
`"Bash(*/astra-plugin/scripts/astra:*)"` style allow rule to your settings.

## Automatic use (no manual `/astra`)
Run `/astra-auto` once in a project. It adds a rule to `CLAUDE.md` so Claude spawns `astra` subagents on its own:
design/risk/alternative passes before non-trivial changes, and an adversarial review after. `/astra-auto off` removes it.
The subagent description also marks it "use proactively", so Claude may reach for it even without the rule.

## Reasoning effort
Default is `low`. Change it per project with `/astra-effort <minimal|low|medium|high|xhigh>` (stored in `.claude/astra.conf`),
per shell with `ASTRA_EFFORT=high`, or per call with `astra -e high "..."`.

## Logs
Full Codex transcripts go to `.claude/astra-logs/` in the project (add to `.gitignore`).
