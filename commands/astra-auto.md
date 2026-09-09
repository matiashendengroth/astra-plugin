---
description: Toggle automatic ASTRA delegation in this project (CLAUDE.md rule + permission + gitignore) — /astra-auto [on|off]
argument-hint: "[on|off]"
---
Toggle automatic ASTRA delegation for the current project: **${ARGUMENTS:-on}**.

The absolute wrapper path is `${CLAUDE_PLUGIN_ROOT}/scripts/astra` — write it out literally in everything below (CLAUDE.md cannot expand variables).

The CLAUDE.md rule block is delimited by `<!-- astra-auto:start -->` and `<!-- astra-auto:end -->`.

## on
1. If the block is absent, append this to `./CLAUDE.md` (create if needed), substituting the real path for WRAPPER:

```
<!-- astra-auto:start -->
## ASTRA delegation (automatic)
ASTRA is an independent second model (OpenAI Codex). Wrapper: `WRAPPER`. Call it with Bash as a background job (timeout 600000), always with `-C "<absolute project dir>"`. Use it proactively; do not wait to be asked.
- Before a **medium** change (2–4 files): one ASTRA pass — risk analysis of the plan. Before a **large** change (new feature, refactor, cross-cutting, unclear bug): three parallel passes — design, risk, alternative. Reconcile, then implement. Trivial edits skip this.
- After finishing any non-trivial change: `WRAPPER review -C "<dir>" --uncommitted --json`. Confirm or refute each finding against the code before reporting; fix confirmed ones.
- Long prompts: write to a scratch file and pipe them in.
<!-- astra-auto:end -->
```

2. Permission: add `"Bash(WRAPPER:*)"` to `permissions.allow` in `./.claude/settings.local.json` (create the file / arrays if missing, keep everything else, valid JSON).
3. Add `.claude/astra-logs/` to `./.gitignore` if not present.

## off
Remove the CLAUDE.md block (nothing else), remove the allow entry from `./.claude/settings.local.json`, leave `.gitignore` alone.

Confirm in one line what changed. Takes effect in new sessions.
