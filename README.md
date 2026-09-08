# astra — Claude ⇄ Codex pipeline plugin

`/astra <task>` runs: Claude architect → 3 parallel ASTRA (Codex) passes → Claude reconcile + implement → ASTRA adversarial review → Claude verify.

## Prerequisites (each teammate)
1. `npm i -g @openai/codex` and run `codex` once to log in.
2. Optional: set the model in `~/.codex/config.toml`, e.g. `model = "gpt-6-astra"`, `model_reasoning_effort = "xhigh"`.

## Install
In Claude Code:
```
/plugin marketplace add Smart-Lifestyle-AS/astra-plugin
/plugin install astra@smarteating
```
Then `/astra <task>` in any project. Approve the `scripts/astra` command once when prompted, or add
`"Bash(*/astra-plugin/scripts/astra:*)"` style allow rule to your settings.

## Logs
Full Codex transcripts go to `.claude/astra-logs/` in the project (add to `.gitignore`).
