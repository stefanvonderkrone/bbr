# Agent guidance

## Work and tracker

- Issues and PRDs are local Markdown under `.scratch/`. External PRs are not a triage surface. Read [the issue tracker guide](docs/agents/issue-tracker.md) before you create, claim, or close a ticket.
- Ticket states are `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. Read [the triage labels](docs/agents/triage-labels.md) before you change a state.
- Read [the project tool defaults](docs/agents/tools.md) before a task that needs a disabled MCP server.

## Domain

- Read `GLOSSARY-MAP.md` before you name a thing, and use its terms. [The domain docs guide](docs/agents/domain.md) says how.
- Read [the code navigation map](docs/code-navigation.md) to find the owner of the code you change.
- System-wide decisions live in `docs/adr/`. Read the ADRs of the area before you change a decision.

## Verify

- `zig build test` runs the unit tests, the line checks in `tools/`, and the CLI tests. Check its exit code.
- `zig fmt --check src build.zig tests` checks the format.
- After a change to an agent doc or a ticket, run `python3 tools/check_agent_docs.py`.

## Rules

Each rule names the check that enforces it. Read the area doc before you change its code.

- [Diagnostics](docs/rules/diagnostics.md): before you write a `catch`, an `errdefer`, an error return, an error comparison, a failure record, diagnostic evidence, or a task spawn.
- [Persist and Bitbucket](docs/rules/persist-and-bitbucket.md): before you change `src/persist/` or `src/bitbucket/`, such as the SQLite store, a schema migration, or a Bitbucket URL path.
- [Build and checks](docs/rules/build-and-checks.md): before you change `build.zig`, `tools/`, `tests/`, a benchmark, a library or system call of the core module, or the release publication.
- [CLI](docs/rules/cli.md): before you change `bbr api`, stdout or stderr output, or a config path.
- [TUI paint](docs/rules/tui-paint.md): before you change what the TUI paints, such as a layout, a border, a Title, a Theme color, the status, or a ReviewCard.
- [TUI state](docs/rules/tui-state.md): before you change Presentation, a Session, a Buffer or Frame build, search, navigation, or an Overlay.
- [Coding standards](CODING_STANDARDS.md): the rules that no check enforces. Read them before you review a change, and before you change the code that a standard names.

Before you add a rule, read [the rule areas guide](docs/agents/rule-areas.md). It names the area doc for the rule and the section format.
