# Move the rules table out of AGENTS.md

Status: needs-triage
Blocked by: none

## Problem

`AGENTS.md` is 44,531 bytes in 82 lines, about 11,000 tokens. Every agent session in this repo loads it, subagents included. In the 30 days before November 11, 353 OpenCode sessions ran in bbr checkouts. The retro in session `ses_e38baeb9cffe00nhxrCe6jCmIf` (ranked finding 5) flagged this file.

The table "Rules and enforcement" holds 43,496 of the 44,531 bytes in 56 rows:

| Area | Rows (approx.) | Bytes (approx.) |
| --- | --- | --- |
| Diagnostics and failure records | 22 | 24,400 |
| TUI layout, Overlays, ReviewCards, Presentation | 28 | 15,100 |
| `bbr api`, stdout, XDG | 4 | 2,800 |
| Tests, tools, release | 2 | 1,200 |

The Enforcement column is 24,700 bytes. It lists test names and check internals that the checks report themselves when they fail. A task in one area loads the rules of every area.

## Proposal

- `AGENTS.md` keeps only the pointers that every task needs: issue tracker, triage labels, domain docs, agent checks, and one line for each rule area.
- Each rule area moves to its own disclosed doc. The diagnostics rules can join `docs/diagnostic-logging.md` or get a sibling doc. Triage decides the file names.
- Each pointer line names the condition for reading its doc, for example "Before you change a `catch`, a failure record, or a task spawn, read the diagnostics rules."
- Each rule keeps one sentence for the check that enforces it, for example "`tools/check_diagnostics.py`". The test names stay in the tests.
- Each rule exists in one place only.

## Acceptance criteria

- [ ] `AGENTS.md` is less than 5,000 bytes.
- [ ] Each rule from the old table exists exactly once in a disclosed doc, or it is deleted with a reason in the commit message.
- [ ] Each rule area has a pointer line in `AGENTS.md` that names the condition for reading it.
- [ ] No disclosed doc lists test names that only repeat what the check reports.
- [ ] `python3 tools/check_agent_docs.py` passes.
