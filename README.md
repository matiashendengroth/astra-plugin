# CLAUDEX — Claude orchestrates, Codex builds

A [Claude Code](https://claude.com/claude-code) plugin that puts OpenAI Codex to work as a second, independent model inside your Claude Code sessions. Claude stays in charge: it classifies the task, writes the spec, runs Codex builders in parallel, merges the result, has Codex review the diff adversarially, and verifies every finding before reporting. You just give Claude the task.

```
you ─▶ Claude (orchestrator)
          ├─▶ CLAUDEX risk pass            (one-shot, on the plan)
          ├─▶ CLAUDEX builder ×N           (parallel, one git worktree each)
          ├─▶ merge · tests
          ├─▶ CLAUDEX adversarial review   (JSON findings: severity, file, line)
          └─▶ verify each finding · fix · report
```

Each CLAUDEX run appears as a named agent in Claude Code, and its full Codex transcript (commands, patches, test runs) is visible in that agent's view.

## Requirements

- Claude Code (desktop or terminal) on macOS, Linux, or Windows.
- [OpenAI Codex CLI](https://github.com/openai/codex): `npm i -g @openai/codex`, then run `codex` once to sign in.
- `git`, Python 3 (`python3` on macOS/Linux; `python` on Windows is fine).

### Windows notes
Claude Code runs bash commands through Git Bash, which the scripts target. Make sure:
- Git for Windows is installed (it ships Git Bash and `awk`, `sed`, `sort`).
- Python 3 that actually runs. The `python3` that ships on Windows PATH is usually the Microsoft Store alias, which only prints an install hint; CLAUDEX skips it and uses `python` or the `py` launcher. If none works: `winget install Python.Python.3.12`, then reopen the terminal.
- Codex is installed the same way: `npm i -g @openai/codex`, then `codex` to sign in.
The launcher installs to `%USERPROFILE%\.local\bin\claudex` and is invoked by its Git Bash path (`/c/Users/<you>/.local/bin/claudex`). Line endings are pinned to LF via `.gitattributes`, so a checkout with `core.autocrlf=true` still works.

## Install

```
/plugin marketplace add matiashendengroth/claudex
/plugin install claudex@gryd
```

Restart Claude Code so the plugin's commands load.

## Enable in a project

```
/claudex-auto
```

One command, idempotent. It installs a stable launcher at `~/.local/bin/claudex`, adds an orchestration rule to the project's `CLAUDE.md`, pre-approves the launcher in `.claude/settings.local.json`, and gitignores the logs and build worktrees. `/claudex-auto off` removes the rule and permission.

Setup `on` also prints a nonfatal **Preflight** block: Codex CLI version/install hint, configured model (with a warning for mini/nano models), sign-in file presence, and Python version. Config and auth come from `$CODEX_HOME`, or `~/.codex` when unset.

From the next session on, Claude delegates on its own:

| task size | what happens |
|---|---|
| trivial (typo, one-liner) | Claude does it |
| medium (2–4 files) | Claude writes a spec → one CLAUDEX builder |
| large (feature, refactor) | CLAUDEX risk pass → split into chunks → parallel CLAUDEX builders in worktrees → merge |
| unclear bug | CLAUDEX analysis → build with the diagnosis |
| after any build | tests → CLAUDEX JSON review → Claude confirms/refutes each finding |

Single-chunk builds remain uncommitted. For parallel builds, the merge command commits the chunk worktrees and merges their branches; subsequent verification fixes remain uncommitted.

## Commands

| command | purpose |
|---|---|
| `/claudex-auto [on\|off]` | enable / disable automatic delegation in this project |
| `/claudex-build <task>` | force the build flow on one task |
| `/claudex-build --dry-run <task>` | print the brief's chunk specs verbatim with owned files, estimate builders and effort; stop before creating worktrees or builders |
| `/claudex <task>` | advisory flow: Claude writes the code, CLAUDEX advises and reviews |
| `/claudex-effort [review\|build] <level>` | set Codex reasoning effort (minimal, low, medium, high, xhigh) |
| `/claudex-status` | running builders/reviews, recent runs with duration and tokens, build worktrees |
| `/claudex-budget` | show this project's budget usage and limits |
| `/claudex-merge` | commit build worktrees and merge their `claudex/` branches; exit 4 means conflicts remain |
| `/claudex-cancel [--keep-worktrees]` | stop every running CLAUDEX process and clean up worktrees and branches |

See [Writing specs for CLAUDEX builders](docs/SPECS.md) for ownership, shared interfaces, acceptance criteria, and examples. If merge exits 4, the orchestrator resolves the listed conflicts in the remaining worktree(s) and re-runs merge.

## Context engineering (what keeps Codex usage down)
- **Packets, not exploration.** A review does not start by exploring the repo. The wrapper assembles a context packet with git first — project conventions, the test command, the changed-file list, the full diff, and the post-change contents of every changed file (size-capped) — and tells Codex not to run discovery commands or re-read what it already has. The static instructions come first in the prompt so provider prompt caching hits across calls.
- **Resume, don't restart.** `--resume` continues the last review or build session for the directory. A re-review after fixes sends only the current diff plus the previous findings and asks for fixed / still open / new; a build follow-up sends the failure to the builder that wrote the code. Measured on a small repo: re-review 2.7k tokens vs 21k cold; build follow-up 4.4k vs 20k.
- **Discovery is measured.** Coverage reports `discovery`: how many of Codex's commands were exploration (ls, find, git status/log, hunting for AGENTS.md). If it is not near zero, the packet is not doing its job.
- The offline test suite is the default; `scripts/test.sh --live` runs the Codex-backed checks.

## When Codex runs out of usage
If Codex refuses a run because of a usage or rate limit, the wrapper exits 5 with a plain message and pauses CLAUDEX for the project until the reset time Codex reported (15 minutes if it gave none). While paused: no Codex calls are made, the orchestrator is told not to retry and to finish the work itself, and the review hook stops blocking — it shows a notice that the change was **not** independently reviewed instead. `claudex status` shows the pause; `claudex limit` prints it; `claudex limit --clear` lifts it early (for example after upgrading your plan).

## Reasoning effort and timeouts

| mode | default effort | default timeout | overrides |
|---|---|---|---|
| exec (questions, risk passes) | low | 480 s | `-e`, `CLAUDEX_EFFORT`, `effort=` |
| review | medium | 480 s | `CLAUDEX_REVIEW_EFFORT`, `review_effort=` |
| build | high | 1200 s | `CLAUDEX_BUILD_EFFORT`, `build_effort=`, `build_timeout=` |

`key=value` lines live in `.claude/claudex.conf` in the project. Review runs with a workspace-write sandbox so Codex can run your tests; set `review_sandbox=read-only` to forbid that. The Codex model itself comes from `~/.codex/config.toml`.

## Wrapper

`scripts/claudex` is a plain bash script around `codex exec`. Modes: default (question), `review`, `build`. Useful flags: `-C DIR`, `-e EFFORT`, `-t SECS`, `-v` (full transcript), `--json` (structured review), `-w` / `--ro` (sandbox). Transcripts persist in `.claude/claudex-logs/` (last 40 runs).

JSON reviews report `coverage`: files actually opened, commands run, whether tests ran, whether code was executed (`executed`), test result, and confidence with a reason. The wrapper independently measures transcript `exec_count`, `tests_detected`, `executed`, and `patched` (distinct paths in apply-patch blocks) under `measured`. The log-path footer remains; remove it before parsing JSON (and omit `-v`). For JSON reviews the saved `.last.md` (the RESULT file the relay returns) is the merged document; the model's untouched answer is kept next to it as `.raw.md`. Review done/failed registry events include the measured fields, and detected patches trigger a warning. Test detection indicates a matching command, not a passing result.

Judge review coverage by `measured.tests_detected` OR `measured.executed`; empty findings with neither are low-confidence. Low reported confidence or fewer than three exec calls also warrant rerunning at `-e high` or reading the diff yourself. State the coverage in your report.

### Build reports

Builds return JSON with `summary`, `files_changed`, `commands_run`, `tests_run`, `test_result`, `assumptions`, `left_undone`, and `needs_attention`, plus the wrapper's `measured` object (`exec_count`, `tests_detected`, `executed`, `patched`). The relay returns the report verbatim. After each build, Claude checks `needs_attention` and `left_undone` as findings and notes any discrepancy when `tests_run` is true but `measured.tests_detected` is false.

The run registry lives in the main worktree, so `status` and `cancel` also work from linked worktrees and subdirectories. Cancellation checks process identity and marks mismatches as stale. Cleanup only removes worktrees inside the main worktree's `.claudex-wt/` whose branches start with `claudex/`.

### Budgets and review reminder

Configure `max_builders` (default 4) and `budget_minutes` (default 60) in the main worktree's `.claude/claudex.conf`. A build exits with code 3 when that root already has the maximum number of live builders. Other run modes remain available. The minutes budget sums durations of done/failed/timeout/cancelled runs whose final timestamp is in the last 24 hours; exceeding it warns at every run start and in `claudex status`, without blocking. `/claudex-budget` (or `claudex budget -C "<dir>"`) prints usage and limit. Before large builds, Claude checks the budget and asks before starting more builders when over budget. Limits accept nonnegative integers; invalid values are ignored.

The plugin's Stop hook reminds Claude to review uncommitted changes in projects enabled with `/claudex-auto`. A completed review newer than the changed tracked files satisfies the reminder. Otherwise it blocks stopping with instructions to run a review and verify its findings. If you explicitly want to skip, `claudex ack -C "<dir>"` acknowledges that change set. Reviews and acknowledgements save a fingerprint in `.claude/claudex-logs/.reviewed`; further changes trigger the reminder again. Fingerprints combine `git diff HEAD` and untracked file names, excluding `.claude/` and `.claudex-wt/` (untracked contents are not hashed). The hook skips clean trees, Git failures, disabled projects, and recursive Stop invocations.

### Edit tracking

The PostToolUse hook records Claude's direct file edits and shows them in `claudex status` (or `/claudex-status`). This is measurement only: it does not block edits or enforce delegation. Setup `on` confirms that the Stop and PostToolUse hooks are active in the project.

## Update

```
/plugin marketplace update gryd
/plugin update claudex
```

then restart. The launcher resolves the newest installed version. If a release changed the CLAUDE.md rule, run `/claudex-auto` again to refresh it in place. See the [changelog](CHANGELOG.md) for release notes.

## Development

`scripts/test.sh` runs offline registry checks and live smoke tests against a temporary repo (live tests need a signed-in Codex, ~5 min). Use `bash scripts/test.sh --offline` to run only the checks that need no network.

## License

MIT
