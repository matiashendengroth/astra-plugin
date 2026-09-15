---
description: Toggle automatic ASTRA delegation in this project (CLAUDE.md rule + permission + gitignore) — /astra-auto [on|off]
argument-hint: "[on|off]"
---
Toggle automatic ASTRA delegation for the current project: **${ARGUMENTS:-on}**.

WRAPPER is the stable launcher path `$HOME/.local/bin/astra` — write it out literally (expanded, e.g. `/Users/name/.local/bin/astra`) in everything below. Never write the versioned plugin cache path; it changes on every plugin update.

## 0 · Launcher (both on and off)
Run: `mkdir -p "$HOME/.local/bin" && cp "${CLAUDE_PLUGIN_ROOT}/scripts/astra-launcher" "$HOME/.local/bin/astra" && chmod +x "$HOME/.local/bin/astra"`. It finds the newest installed plugin version at call time. Then run `"$HOME/.local/bin/astra" --help 2>&1 | head -1` once to confirm it resolves; if it prints "no installed astra plugin", stop and tell the user.

The CLAUDE.md rule block is delimited by `<!-- astra-auto:start -->` and `<!-- astra-auto:end -->`.

## on
1. If the block is absent, append this to `./CLAUDE.md` (create if needed), substituting the real path for WRAPPER:

```
<!-- astra-auto:start -->
## ASTRA delegation (automatic)
ASTRA is an independent second model (OpenAI Codex). Wrapper: `WRAPPER`. Call it with Bash as a background job (timeout 600000), always with `-C "<absolute project dir>"`. Use it proactively; do not wait to be asked.
You are the orchestrator; ASTRA is the builder. Classify every task first:
- **Trivial** (typo, one-liner, config tweak): do it yourself, no ASTRA.
- **Medium** (2–4 files, contained): write a spec, then `cat spec.md | WRAPPER build -C "<dir>"`. ASTRA implements; you do not write the code.
- **Large** (new feature, refactor, cross-cutting): first one ASTRA risk pass on your plan (`WRAPPER -C "<dir>" "<plan + ask for risks>"`), then split into independent chunks and run one `WRAPPER build` per chunk in parallel, each in its own git worktree (`git worktree add -b astra/<slug>-N .astra-wt/N HEAD`), then commit each worktree (`git add -A -- . ':!.claude/astra-logs'`), merge, remove worktrees, run tests. If it does not split cleanly, one build.
- **Unclear bug**: one ASTRA analysis pass first, then a build with the diagnosis.
- After every ASTRA build: run the tests, then `WRAPPER review -C "<dir>" --uncommitted --json`. Open each finding, confirm or refute against the code, fix confirmed ones yourself if small, otherwise send them back to `WRAPPER build` with the error. Never report done with unverified findings.
- Builds need a clean git tree; if it is dirty, ask before starting. Leave results uncommitted.
- Long prompts: write to a scratch file and pipe them in. Builds can take 10–20 minutes; use Bash timeout 600000 and background them.
<!-- astra-auto:end -->
```

2. Permission: add `"Bash(WRAPPER:*)"` to `permissions.allow` in `./.claude/settings.local.json` (create the file / arrays if missing, keep everything else, valid JSON). If an older entry pointing at a `plugins/cache/.../scripts/astra` path exists, remove it.
3. Add `.claude/astra-logs/` and `.astra-wt/` to `./.gitignore` if not present.

## off
Remove the CLAUDE.md block (nothing else), remove the astra allow entries from `./.claude/settings.local.json`, leave `.gitignore` and the launcher alone.

## on, when the block already exists
Replace the block in place (it may reference an old versioned path) and fix the permission entry as in step 2. Say that it was refreshed.

Confirm in one line what changed. Takes effect in new sessions.
