# Check stderr writes on TUI paths

Status: ready-for-agent
Blocked by: none

## Problem

The TUI owns the terminal in raw mode. A direct stderr write on a TUI path puts text on top of the painted screen. ADR 0014 says that a site on a TUI path cannot print, and that its one diagnostic record is the evidence.

The same mistake happened twice. M27 commit `5eb344e4` removed `Diagnostic.report`, which wrote a failed lazy query to stderr through `std.debug.lockStderr`. The user grammar code had the write first (`src/highlight/user_grammar.zig`), and the built-in grammar code copied it (`src/highlight/tree_sitter_highlighter.zig`). No check failed on either write.

A plain line check is not enough. `src/main.zig` has about 100 valid `std.debug.print` and stderr calls on CLI paths, and `src/cli_failure.zig` writes CLI messages on purpose.

## Proposal

- Find the modules that only TUI paths reach, such as `src/tui/`, `src/highlight/`, and the File Enrichment code. Triage decides the list.
- Add a line check in `tools/` that fails on `std.debug.print`, `lockStderr`, and `stderr()` in production code of those modules. Read source through `zig_files` in `tools/source_lines.py`, and skip `test` blocks with the shared `production` filter.
- The message names the fix: return `Handle.fail`, and let the boundary record the failure.
- A shared module that the CLI also reaches, such as `src/highlight/user_grammar.zig`, writes its CLI message only through `bbr.cli_failure.fail`. Triage decides whether such a module is in the checked list.

## Acceptance criteria

- [ ] `Diagnostic.report` is gone from `src/highlight/query_predicates.zig`. `src/highlight/tree_sitter_highlighter.zig` and `src/highlight/user_grammar.zig` no longer call it. The failure is the one record of `Handle.fail`.
- [ ] A CLI path that showed the query message, such as `bbr grammar`, still shows it through `bbr.cli_failure.fail`.
- [ ] `Failure.report` moves out of `src/tui/config.zig` to the CLI code in `src/main.zig`, its only caller.
- [ ] The check covers the production code of `src/tui/` and `src/highlight/`. It fails on `std.debug.print`, `lockStderr`, and `stderr()`.
- [ ] The check fails on the `Diagnostic.report` of `main` before this ticket.
- [ ] The check passes on the tree after this ticket. Each exempt site is named with its reason.
- [ ] `tests/` holds the regression tests of the check, and `zig build test` runs the check.
- [ ] The rule is a section in the matching doc under `docs/rules/`.

## Comments

### 2026-11-18 filed

The operator asked for this ticket after the M27 stderr fix.

### 2026-11-23 triage

- The write is still on `main`. `Diagnostic.report` in `src/highlight/query_predicates.zig` writes through `std.debug.lockStderr`. `src/highlight/tree_sitter_highlighter.zig` line 56 and `src/highlight/user_grammar.zig` line 300 call it. The fix `5eb344e4` is only on the unmerged branch `m27-zig-builtin-grammar`.
- The operator decided: this ticket fixes the write on `main`. The check has no allowlist for it. The m27 merge then resolves a small conflict.
- Checked modules: `src/tui/` and `src/highlight/`. `src/highlight/user_grammar.zig` is in the list. It writes a CLI message only through `bbr.cli_failure.fail`.
- `Failure.report` in `src/tui/config.zig` is called only by `reportConfigFailure` in `src/main.zig`, on a CLI path. Move it to the CLI code instead of an exemption.
- The `pub fn benchmark*` functions in `src/tui/presentation.zig` print their results with `std.debug.print`. Only benchmark binaries call them. The check exempts them by name. This leaves a gap: a production function with a `benchmark` prefix passes the check. Write the gap into the rule section.
