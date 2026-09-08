---
description: Toggle automatic ASTRA delegation in this project (adds/removes a rule in CLAUDE.md) — /astra-auto [on|off]
argument-hint: "[on|off]"
---
Toggle automatic ASTRA delegation for the current project: **${ARGUMENTS:-on}**.

The rule block is delimited by the lines `<!-- astra-auto:start -->` and `<!-- astra-auto:end -->` in `./CLAUDE.md`.

- **on**: if the block is absent, append this to `./CLAUDE.md` (create the file if needed):

```
<!-- astra-auto:start -->
## ASTRA delegation (automatic)
Use the `astra` subagent proactively; do not wait to be asked.
- Before any non-trivial change (2+ files, new feature, refactor, unclear bug): spawn 2–3 `astra` subagents in parallel (design / risk / alternative), reconcile, then implement.
- After finishing a change: spawn one `astra` subagent to run `review` on the uncommitted diff. Confirm or refute each finding against the code before reporting.
- Trivial edits (typos, one-liners, config tweaks) skip ASTRA.
<!-- astra-auto:end -->
```

- **off**: remove that block (and nothing else) from `./CLAUDE.md`.

Confirm in one line what you did. Mention that the change takes effect in new sessions.
