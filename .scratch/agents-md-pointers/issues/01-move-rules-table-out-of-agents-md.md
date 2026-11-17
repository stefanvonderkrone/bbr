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

## Layout

The rules move to five area docs in `docs/rules/`. `AGENTS.md` keeps one pointer line for each area doc, with its read condition.

| Area doc | Read condition in `AGENTS.md` | Old rows | Old rows bytes |
| --- | --- | --- | --- |
| `docs/rules/diagnostics.md` | Before you write a `catch`, an `errdefer`, an error return, a failure record, or a task spawn. | 15 | 19,967 |
| `docs/rules/build-and-checks.md` | Before you change `build.zig`, `tools/`, `tests/`, a benchmark, or the release publication. | 7 | 3,891 |
| `docs/rules/cli.md` | Before you change `bbr api`, stdout or stderr output, or a config path. | 6 | 4,735 |
| `docs/rules/tui-paint.md` | Before you change what the TUI paints: a layout, a border, a Title, a Theme color, the status, or a ReviewCard. | 16 | 9,470 |
| `docs/rules/tui-state.md` | Before you change Presentation, a Session, a Buffer or Frame build, search, navigation, or an Overlay. | 22 | 8,432 |
| `CODING_STANDARDS.md` | The rules that no check enforces. The `code-review` skill reads it. | (ticket 02) | |

The sections of `docs/agents/rule-details.md` join the area doc of their row and keep their heading, so each anchor stays the same in the new file.

### Sort a rule into an area

Take the first area that matches:

1. The rule is about a failure: a `catch`, an error return, an error comparison, a failure record, diagnostic evidence, or a task spawn. Use `diagnostics.md`.
2. The rule or its enforcement is in `build.zig`, `tools/`, `tests/`, `src/benchmark*`, the module setup of `src/root.zig`, or the release publication. Use `build-and-checks.md`.
3. The rule is in `src/main.zig`, `src/api/`, `src/completion.zig`, `src/stdout.zig`, or `src/xdg.zig`. Use `cli.md`.
4. The rule decides what a terminal cell shows: a border, a glyph, a color, a Title, the status, or where a Slot sits. Use `tui-paint.md`.
5. Every other rule in `src/tui/` uses `tui-state.md`.

A rule with a part that no check covers puts that part in `CODING_STANDARDS.md` (ticket 02). A new area doc needs a new pointer line in `AGENTS.md`, so add one only when no area above matches.

### Rule section format

Each rule is one `##` section in its area doc. The heading names the rule, and its anchor is stable. The body holds the rule, then one paragraph that starts with "Enforcement:" and names the check or the test file and the build step that runs it. A test name stays only when the test file holds many unrelated tests. Old commits that fail a check stay out: the check reports the failure.

## Acceptance criteria

- [ ] `AGENTS.md` is less than 5,000 bytes.
- [ ] Each rule from the old table exists exactly once in a disclosed doc, or it is deleted with a reason in the commit message.
- [ ] Each rule area has a pointer line in `AGENTS.md` that names the condition for reading it.
- [ ] No disclosed doc lists test names that only repeat what the check reports.
- [ ] `python3 tools/check_agent_docs.py` passes.
