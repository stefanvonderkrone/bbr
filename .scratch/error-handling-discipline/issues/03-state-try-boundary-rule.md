# State the try boundary rule

Status: ready-for-agent
Type: implementation
Blocked by: none
Parent: ../PRD.md

## Goal

One rule says where `try` stops.
Inside a module, code uses `try`.
Code catches only in a function that cannot return an error, or that owns a user-visible decision.
At that boundary, code records the failure once through a `diagnostics.Handle`, then restores state or shows the failure.

## Boundaries in bbr

- Worker task entry points.
- Presentation event and command handlers. Presentation is a typed command-producing state machine (`docs/adr/0012`).
- CLI `main`, through `exitFailure` in `src/main.zig`.
- The SQLite and HTTP seams that convert foreign codes into typed causes.

Ghostty uses the same split (`src/renderer/Thread.zig:193-197`, `threadMain` and `threadMain_`).

## Origin in release builds

A release build has no error return trace.
The `@src()` in a `diagnostic.Failure` is then the only origin.
Record at the deepest point that still has context, and propagate after that.
A higher layer must not record the same failure again.

## Work

1. Write the rule as an ADR under `docs/adr/`, with the boundary list and the reason.
2. Add a row to the `AGENTS.md` rule table. Name what enforces it. If nothing enforces a part of it, mark that part "Convention (no check)".
3. Add the rule to `.agents/skills/zig/runtime.md` or a new reference beside the zig skill.
4. Find a check for the rule. For example, a lint can reject a record through a `diagnostics.Handle` in a function that also returns the same error. Record the result in this issue, even when no check is possible.

## Acceptance

- The ADR and the rule table row exist.
- `python3 tools/check_agent_docs.py` passes.
- This issue states which part of the rule a check enforces.
