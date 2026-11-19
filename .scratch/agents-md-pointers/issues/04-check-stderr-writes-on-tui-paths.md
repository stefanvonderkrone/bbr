# Check stderr writes on TUI paths

Status: needs-triage
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

- [ ] The check fails on the old `Diagnostic.report` of M27 (before `5eb344e4`).
- [ ] The check passes on the current tree, or each remaining site is fixed or named with its reason.
- [ ] `tests/` holds the regression tests of the check, and `zig build test` runs the check.
- [ ] The rule is a section in the matching doc under `docs/rules/`.

## Comments

### 2026-11-18 filed

The operator asked for this ticket after the M27 stderr fix.
