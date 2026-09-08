---
description: Set the default ASTRA (Codex) reasoning effort for this project — /astra-effort <minimal|low|medium|high|xhigh>
argument-hint: <minimal|low|medium|high|xhigh>
---
Set the ASTRA reasoning effort for the current project to **$ARGUMENTS**.

If no argument was given, print the current value (the `effort=` line in `.claude/astra.conf`, or "low (default)" if absent) and stop.

Otherwise validate it is one of minimal, low, medium, high, xhigh, then run:
`mkdir -p .claude && { grep -v '^effort=' .claude/astra.conf 2>/dev/null; echo "effort=$ARGUMENTS"; } > .claude/astra.conf.tmp && mv .claude/astra.conf.tmp .claude/astra.conf`
Confirm in one line. A per-call `-e` flag or the `ASTRA_EFFORT` env var still overrides this.
