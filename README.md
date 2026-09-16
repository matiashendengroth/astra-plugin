# ASTRA — Claude orchestrates, Codex builds

A [Claude Code](https://claude.com/claude-code) plugin that puts OpenAI Codex to work as a second, independent model inside your Claude Code sessions. Claude stays in charge: it classifies the task, writes the spec, runs Codex builders in parallel, merges the result, has Codex review the diff adversarially, and verifies every finding before reporting. You just give Claude the task.

```
you ─▶ Claude (orchestrator)
          ├─▶ ASTRA risk pass            (one-shot, on the plan)
          ├─▶ ASTRA builder ×N           (parallel, one git worktree each)
          ├─▶ merge · tests
          ├─▶ ASTRA adversarial review   (JSON findings: severity, file, line)
          └─▶ verify each finding · fix · report
```

Each ASTRA run appears as a named agent in Claude Code, and its full Codex transcript (commands, patches, test runs) is visible in that agent's view.

## Requirements

- Claude Code (desktop or terminal), macOS or Linux. Windows via Git Bash is untested.
- [OpenAI Codex CLI](https://github.com/openai/codex): `npm i -g @openai/codex`, then run `codex` once to sign in.
- `git`, `python3`.

## Install

```
/plugin marketplace add matiashendengroth/astra-plugin
/plugin install astra@gryd
```

Restart Claude Code so the plugin's commands load.

## Enable in a project

```
/astra-auto
```

One command, idempotent. It installs a stable launcher at `~/.local/bin/astra`, adds an orchestration rule to the project's `CLAUDE.md`, pre-approves the launcher in `.claude/settings.local.json`, and gitignores the logs and build worktrees. `/astra-auto off` removes the rule and permission.

From the next session on, Claude delegates on its own:

| task size | what happens |
|---|---|
| trivial (typo, one-liner) | Claude does it |
| medium (2–4 files) | Claude writes a spec → one ASTRA builder |
| large (feature, refactor) | ASTRA risk pass → split into chunks → parallel ASTRA builders in worktrees → merge |
| unclear bug | ASTRA analysis → build with the diagnosis |
| after any build | tests → ASTRA JSON review → Claude confirms/refutes each finding |

Results are left uncommitted for you.

## Commands

| command | purpose |
|---|---|
| `/astra-auto [on\|off]` | enable / disable automatic delegation in this project |
| `/astra-build <task>` | force the build flow on one task |
| `/astra <task>` | advisory flow: Claude writes the code, ASTRA advises and reviews |
| `/astra-effort [review\|build] <level>` | set Codex reasoning effort (minimal, low, medium, high, xhigh) |

## Reasoning effort and timeouts

| mode | default effort | default timeout | overrides |
|---|---|---|---|
| exec (questions, risk passes) | low | 480 s | `-e`, `ASTRA_EFFORT`, `effort=` |
| review | medium | 480 s | `ASTRA_REVIEW_EFFORT`, `review_effort=` |
| build | high | 1200 s | `ASTRA_BUILD_EFFORT`, `build_effort=`, `build_timeout=` |

`key=value` lines live in `.claude/astra.conf` in the project. Review runs with a workspace-write sandbox so Codex can run your tests; set `review_sandbox=read-only` to forbid that. The Codex model itself comes from `~/.codex/config.toml`.

## Wrapper

`scripts/astra` is a plain bash script around `codex exec`. Modes: default (question), `review`, `build`. Useful flags: `-C DIR`, `-e EFFORT`, `-t SECS`, `-v` (full transcript), `--json` (structured review), `-w` / `--ro` (sandbox). Transcripts persist in `.claude/astra-logs/` (last 40 runs).

## Update

```
/plugin marketplace update gryd
/plugin update astra
```

then restart. Projects need no re-setup; the launcher resolves the newest installed version. If a release changes the CLAUDE.md rule, run `/astra-auto` again to refresh it in place.

## Development

`scripts/test.sh` runs a 16-case smoke suite against a temp repo (needs a signed-in Codex, ~5 min).

## License

MIT
