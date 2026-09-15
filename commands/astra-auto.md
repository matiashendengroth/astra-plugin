---
description: Toggle automatic ASTRA delegation in this project (one command; idempotent) — /astra-auto [on|off]
argument-hint: "[on|off]"
---
Run exactly this one command and report its output verbatim, nothing else:

`"${CLAUDE_PLUGIN_ROOT}/scripts/astra-setup" "$PWD" ${ARGUMENTS:-on}`

(It installs the stable launcher at ~/.local/bin/astra, writes or refreshes the ASTRA rule in ./CLAUDE.md, adds the permission rule to ./.claude/settings.local.json, and gitignores logs and worktrees. `off` removes the rule and permission.) If it fails, show the error and stop.
