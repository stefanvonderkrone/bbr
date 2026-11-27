# Rule areas

Each checked rule of bbr is one section in one area doc under `docs/rules/`.
`AGENTS.md` has one pointer line for each area doc, with the condition for reading it.
A rule, or a part of a rule, that no check enforces is a section in [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md).

## Sort a rule into an area

Sort a rule by the code that it governs, not by the place of its check.
An agent reads the area doc of the code that it changes.
Thus a TUI rule with a check in `tools/` still goes in a TUI area doc.
Take the first area that matches:

1. The rule is about a failure: a `catch`, an error return, an error comparison, a failure record, diagnostic evidence, or a task spawn. Use [`diagnostics.md`](../rules/diagnostics.md).
2. The rule governs only `src/persist/` or `src/bitbucket/`, such as a schema migration step or a migration test in `src/persist/sqlite_store.zig`, a REST path in `src/bitbucket/client.zig`, or the pull-request URL parse in `src/bitbucket/url.zig`. Use [`persist-and-bitbucket.md`](../rules/persist-and-bitbucket.md).
3. The rule governs `build.zig`, `tools/`, `tests/`, `src/benchmark*`, the libraries and system calls of the core module of `src/root.zig`, or the release publication. Use [`build-and-checks.md`](../rules/build-and-checks.md).
4. The rule governs `src/main.zig`, `src/api/`, `src/completion.zig`, `src/stdout.zig`, or `src/xdg.zig`. Use [`cli.md`](../rules/cli.md).
5. The rule decides what a terminal cell shows: a border, a glyph, a color, a Title, the status, or where a Slot sits. Use [`tui-paint.md`](../rules/tui-paint.md).
6. Every other rule in `src/tui/` uses [`tui-state.md`](../rules/tui-state.md).

A new area doc needs a new pointer line in `AGENTS.md`.
Add one only when no area above matches.
`tools/check_agent_docs.py` fails when `AGENTS.md` is larger than 5,000 bytes.

## Write a rule section

Each rule is one `##` section.
The heading names the rule. Other docs link to its anchor, so a heading change needs a link update.
The body states the rule and the reason when the rule does not show it.
The last paragraph starts with "Enforcement:" and names the check, the compile error, or the test file, and the build step that runs it.
The Enforcement paragraph claims only the violations that its check fails on. Before you write it, break the rule once and read the failure.
A claim of a compile error names the mechanism that fails: a `comptime` assertion, such as `read_only.assert` in `src/tui/read_only.zig`, an exhaustive switch, a `@compileError`, or a test that compiles the violation and expects the error, such as `tests/read_only_test.py`. A type that only lacks a way to write, such as a `const` pointer, a missing field, or a return type without an error union, stops nothing that a cast, a new field, or a `catch` adds. Then name the behavior test that fails instead.
`tools/check_agent_docs.py` rejects a new Enforcement sentence that claims a compile error and names none of these mechanisms. It sees only the name of a mechanism, not what the mechanism fails on, so break the rule once all the same.

Keep the facts that an agent cannot find from the check output or from the code.
Leave out the test names of a test file that holds only the tests of this rule, because a failing test prints its name.
Leave out the old commits that fail a check.
Put the cases that no check sees in `CODING_STANDARDS.md`, with the reason that no check covers them.
