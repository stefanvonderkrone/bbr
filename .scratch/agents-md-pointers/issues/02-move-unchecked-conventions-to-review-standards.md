# Move the unchecked conventions to review standards

Status: ready-for-agent
Blocked by: none

## Problem

Most rules in the `AGENTS.md` table have a check that fails when an agent breaks them. Some rules are marked "Convention (no check)", in full or in part. No check catches them, so today every implementing agent must read and remember them.

The rows that are fully conventions:

- A `catch` whose error set contains `error.Canceled` names `error.Canceled`.
- A layout tree always declares its scroll bars, and only the scroll numbers vary.
- The help Overlay fixed sections change with their key handlers.
- `presentation.zig` does not import vaxis or `theme.zig`.

Other rows end with partial conventions. For example, the record-once rule names the cases that its checks cannot see.

The implementing agent carries the most context. The reviewer receives a diff and has room for judgement rules. The repo's `code-review` skill already reads `CODING_STANDARDS.md` when it exists.

## Proposal

- Create `CODING_STANDARDS.md` (or the name that triage picks) for the judgement rules that no check covers.
- Move each convention there from the disclosed docs of ticket 01, with the reason that no check can cover it.
- Make the cheap ones checks instead. For example, a line check can reject `@import("vaxis")` and `@import("theme.zig")` in `src/tui/presentation.zig`. A check is better than a rule.

## Acceptance criteria

- [x] Each "Convention (no check)" rule, full or partial, is either a new check or a rule in `CODING_STANDARDS.md`.
- [x] The `code-review` skill finds `CODING_STANDARDS.md` without changes, or its pointer is updated.
- [ ] `src/tui/presentation.zig` imports no vaxis and no `theme.zig` directly, and a check that `zig build test` runs rejects such an import.
- [ ] A check rejects the literal `.{ .hunk_line = ` in production code outside `LineOwner.of` in `src/tui/frame.zig`.
- [ ] A check rejects `@constCast(session.` and `@constCast(published.session.` outside `test` blocks.
- [ ] A test compares the keys that each fixed-key handler reads with its section in `help.fixed_sections` in `src/tui/help.zig`.
- [ ] Each new check has its regression tests in `tests/`. Each rule moves from `CODING_STANDARDS.md` to its area doc in `docs/rules/` with its enforcement.
- [ ] `python3 tools/check_agent_docs.py` and `zig build test` pass.

## Completion of the move

2026-11-17, branch `agents-md-pointers`. The move is done. The checks stay open.

- `CODING_STANDARDS.md` holds every "Convention (no check)" rule, full or partial, from the old table and from `docs/agents/rule-details.md`. Each standard names why no check covers it and links its checked rule. The `code-review` skill finds the file by name, so its pointer needs no change.
- Full conventions: `error.Canceled` prongs, fixed scroll bars, and the imports of `presentation.zig`. The other 16 standards are the unchecked parts of checked rules.

Candidates for a check, not done:

- `presentation.zig` imports no vaxis and no `theme.zig`. A line check in `tools/` can reject a direct `@import` of either in `src/tui/presentation.zig`. The import through `keymap.zig` stays, because the rule is about the direct import.
- A literal `.{ .hunk_line = ` outside `LineOwner.of`. A line check can reject it in production code.
- A `@constCast` of a Session field after publication. A line check can reject `@constCast` on Session fields outside test blocks.
- The `.bytes` default of `BuildOptions.cell_metrics`. Follow-up ticket 03 removes the default.
- The fixed help sections. A test can compare the keys that each fixed-key handler reads with its section in `help.fixed_sections`.

## Comments

### 2026-11-23 triage

- Ticket 01 is resolved, so this ticket has no blocker.
- The move is done. The remaining work is the four checks in the acceptance criteria.
- The `.bytes` default of `BuildOptions.cell_metrics` is out of scope. [Follow-up ticket 03](../../enrichment-rebuild-follow-up/issues/03-require-the-cell-metrics-of-every-buffer-build.md) owns it.
- On 2026-11-23 `main` has no direct import of vaxis or `theme.zig` in `presentation.zig`. The only `.{ .hunk_line = ` is in `LineOwner.of`. Each `@constCast(session.` is in a `test` block. The `@constCast` calls at `presentation.zig` lines 2138, 4959, and 11175 and `review_body.zig` line 259 are not Session fields, and the check must not reject them. Each check passes on the current tree.
- A line check reads source through `zig_files` in `tools/source_lines.py`.
