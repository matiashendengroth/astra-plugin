---
description: Set the default ASTRA reasoning effort for this project — /astra-effort [review|build] <minimal|low|medium|high|xhigh>
argument-hint: "[review|build] <minimal|low|medium|high|xhigh>"
---
Arguments: **$ARGUMENTS**

Config file: `./.claude/astra.conf` (key=value lines). Keys: `effort` (exec passes, default low), `review_effort` (default medium), `build_effort` (default high).

- No arguments: print all three current values (or their defaults) and stop.
- `review <level>` / `build <level>`: set `review_effort` / `build_effort`. `<level>` alone: set `effort`.
- Validate level ∈ minimal|low|medium|high|xhigh. Then rewrite the file keeping other keys: `mkdir -p .claude && { grep -v '^KEY=' .claude/astra.conf 2>/dev/null; echo "KEY=LEVEL"; } > .claude/astra.conf.tmp && mv .claude/astra.conf.tmp .claude/astra.conf`

Confirm in one line. Per-call `-e` and the env vars `ASTRA_EFFORT` / `ASTRA_REVIEW_EFFORT` still override.
