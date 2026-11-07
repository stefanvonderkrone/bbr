# Sanction the checked drop form in the lint

Status: ready-for-agent
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
