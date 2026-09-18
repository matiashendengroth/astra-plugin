# Changelog

## 0.5.12
- Windows: the Python resolver now runs the candidate instead of trusting PATH, so the Microsoft Store `python3` alias is skipped (falls back to `python`, then the `py` launcher); hooks are invoked through `bash` explicitly.
- Codex usage limits are handled: a limit refusal exits 5 with a plain message, pauses CLAUDEX until the reset (no further Codex calls, no retries), the review hook stops blocking and tells the user the change was not reviewed, `claudex status` shows the pause, `claudex limit [--clear]` inspects or lifts it.

## 0.5.11
- Context engineering: reviews get a pre-assembled packet (conventions, test command, changed files, diff, file contents) with a stable prompt prefix and a no-discovery rule; `--resume` continues the previous review/build session for cheap follow-ups; session ids and a `discovery` metric in the registry; test suite offline by default (`--live` for Codex checks).

## 0.5.10
- Executed coverage signal; uniform review path with tokens; JSON build reports.
- Hook deadline, direct-edit tracking, and merge subcommand.
- Build dry-run, spec guide, budget/merge commands, and changelog.

## 0.5.9
- Stop hook, build budget, and setup preflight.

## 0.5.8
- Review calibration with reported coverage and measured activity.

## 0.5.7
- Run registry and status/cancel commands.

## 0.5.6
- Windows portability.

## 0.5.5
- Renamed to CLAUDEX.
