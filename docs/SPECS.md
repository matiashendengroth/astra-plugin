# Writing specs for CLAUDEX builders

A builder should be able to implement its chunk without inventing requirements or editing another chunk's files. Put the shared decisions in the brief and include them in every chunk spec.

## What a good spec contains

- **Goal:** the user-visible behavior, with a concrete before/after example.
- **Ownership:** exact files the builder may edit or create, and files it must not touch. Include tests and documentation in the ownership list.
- **Shared interfaces:** names, signatures, inputs, outputs, error behavior, and which chunk supplies each interface.
- **Acceptance criteria:** observable outcomes, edge cases, and the exact test/build command, including its working directory. State any prerequisites.
- **Constraints:** supported runtime versions (for example, Bash 3.2), dependencies, compatibility requirements, and whether commits are forbidden.

## Splitting work

Split by file ownership: each file belongs to exactly one chunk, including shared test fixtures and configuration. Define shared interfaces in the brief before builders start. Give every chunk enough context to work independently; use one chunk when the work cannot be separated cleanly. Keep parallel builds to at most four chunks.

Builds commonly fail because ownership is vague, files have hidden coupling, or there is no test command. Name all affected files, spell out cross-chunk contracts, and define how success will be checked. Preview the specs with `/claudex-build --dry-run <task>` before starting builders.

## Template

```text
Goal: <behavior and concrete example>
Owns (edit/create): <exact file paths>
Must not touch: <exact paths or explicit excluded directories>
Shared interfaces: <contract, provider chunk, consumers; or none>
Acceptance criteria: <outcomes and edge cases>
Test/build command: <command, working directory, prerequisites>
Constraints: <runtime versions, dependencies, compatibility, no commits>
```

## Examples

**Medium, single chunk — add an output flag.** Goal: `tool --format json` emits JSON; the default stays text. Owns `src/cli.py`, `tests/test_cli.py`, and `docs/cli.md`; must not touch any other files. No shared interfaces. Accept when both formats work and unknown formats exit 2 with usage text. Run `python3 -m unittest tests.test_cli` from the project root (Python 3.10+). Use the standard library only; do not commit.

**Large, three chunks — add saved searches.** The brief defines `save_search(name: str, query: str) -> None` and `list_searches() -> list[dict]`, with each dict containing `name` and `query`. Names are unique, duplicate saves raise `ValueError`, and listing sorts by name. Chunk 1 supplies the functions; chunks 2 and 3 import them from `app.search_store`. All chunks use Python 3.10+, add no dependencies, must not touch files outside their ownership, and do not commit. Test commands run from the project root.

| Chunk | Exact files owned | Acceptance and test command |
|---|---|---|
| 1: storage | `app/search_store.py`, `tests/test_search_store.py` | Save/list persist across restarts; duplicate names fail. `python3 -m unittest tests.test_search_store` |
| 2: CLI | `app/search_cli.py`, `tests/test_search_cli.py` | Save/list commands use the contract; duplicate names exit 2. Mock storage for independent tests. `python3 -m unittest tests.test_search_cli` |
| 3: web | `app/search_routes.py`, `tests/test_search_routes.py`, `docs/searches.md` | GET returns the list; POST saves or returns 409 for duplicates. Mock storage for independent tests. `python3 -m unittest tests.test_search_routes` |

After merge, the orchestrator runs `python3 -m unittest discover -s tests` and verifies that the CLI and web routes use the real storage implementation.
