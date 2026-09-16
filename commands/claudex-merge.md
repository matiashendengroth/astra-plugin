---
description: Commit build worktrees and merge their CLAUDEX branches — /claudex-merge
---
Run exactly: `"${CLAUDE_PLUGIN_ROOT}/scripts/claudex" merge -C "$PWD"` and show its output verbatim in a code block. Exit 4 means merge conflicts remain: explain that the listed conflicts must be resolved in the remaining worktree(s), then `/claudex-merge` must be run again.
