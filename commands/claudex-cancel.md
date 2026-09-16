---
description: Stop all running CLAUDEX processes in this project and remove build worktrees — /claudex-cancel [--keep-worktrees]
argument-hint: "[--keep-worktrees]"
---
Run exactly: `"${CLAUDE_PLUGIN_ROOT}/scripts/claudex" cancel -C "$PWD" $ARGUMENTS` and show its output verbatim. With `--keep-worktrees` the partial builds are left in `.claudex-wt/` for inspection; otherwise they are deleted with their branches. Add nothing else.
