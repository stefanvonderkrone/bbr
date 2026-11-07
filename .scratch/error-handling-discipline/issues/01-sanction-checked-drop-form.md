# Sanction the checked drop form in the lint

Status: resolved
Type: implementation
Blocked by: none
Parent: ../PRD.md

## Goal

The form `catch |err| switch (err) { error.X => fallback }` is the one sanctioned way to drop an error.
The prong names each dropped error, and the switch has no `else` prong.
The compiler then rejects the site when the callee gains a new error or loses a named one.
The standard library (`std/debug.zig:887-892`) and TigerBeetle (`src/stdx/stdx.zig:1021-1022`) use this form.

## Work

1. In `tools/check_diagnostics.py`, count two more forms as drops:
   - A capture that the handler discards with `_ = err;`.
   - A capture switch with an `else =>` prong that neither records the cause nor returns it.
2. Remove the `catch |_|` alternative from the `CAUSE_DROP` comment and regex. Zig 0.16 rejects `catch |_|` with "discard of error capture; omit it instead".
3. Regenerate `tools/diagnostic_catch_baseline.txt` after the lint change. Explain each count change in the commit.
4. Add regression tests to `tests/check_diagnostics_test.py`:
   - The sanctioned form passes.
   - `_ = err;` and a non-recording `else` prong fail.
5. Add a row to the `AGENTS.md` rule table and a section to `ZIG.md`.

## Decide before resolution

- Open question 3 of the PRD: does the ratchet need a per-site allow marker?
- The lint must find a multi-line handler. Ten sites put the handler on the next line. Decide whether the regex reads the enclosing expression, as the SQLite check does.

## Acceptance

- `zig build test` passes.
- A test shows that each new drop form fails the check.
- The rule table names the check and its tests.

## Resolution

The lint has no per-site allow marker. The sanctioned switch is the marker. The compiler checks that marker. A comment marker is not checked. The baseline already admits an expected drop when the commit says why.

The lint reads each file's production code as one text, as `unwrapped_sqlite_results` does. The scan finds a handler or a capture on the next line. The check maps match offsets back to line numbers the same way.

An `else` drop is one where the handler neither records nor returns the cause.
The `switch (err)` subject is not a use.
A `reportFailure` call or a `return err` means the cause flows.
Any other reference to the capture also means the cause flows.
The site is then not a drop.

## Completion

The check counts an uncaptured catch, a `_ = err;` discard, and an else drop whose handler neither records nor returns the cause. `python3 tests/check_diagnostics_test.py` passed, 17 tests. `zig build test` passed with exit 0. `python3 tools/check_agent_docs.py` passed.

A temporary `_ = err;` handler in `src/tui/emoji.zig` made `python3 tools/check_diagnostics.py` fail. The file was then reverted.

A comment review cut four restating comments. The scan logic did not change.

The lint, tests, and baseline are in `c017ba9`. The rule text is in this change.
