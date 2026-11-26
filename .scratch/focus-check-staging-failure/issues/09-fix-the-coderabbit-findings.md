# Fix the CodeRabbit findings of PR #45

Status: resolved
Blocked by: none

Source: CodeRabbit review of PR #45.

## Problem

1. `ORIGIN_CALL` in `tools/check_action_errors.py` puts `\s*` before its negative lookahead.
   The regex backtracks `\s*` to zero characters, so the lookahead sees the space and passes.
   So the check rejects `withErrorOrigin( .user, …)` and a call whose enum literal origin starts on the next line.
2. `showErrorFor` and `clearError` change `action_error` and change no revision.
   The App paints only when `Projection.revision` changes.
   `dispatch` changes no revision for an `ensure_focused_enrichment` input, so a message that the focus check shows or clears can stay unpainted until a later event.
3. `openReviewSearch` pumps the Review Search acquisition and then calls `clearError`.
   The open is a user input, so the clear removes the `out_of_memory` message that a failed pump just showed.
   The failure has its record, but the user sees no message.
4. The `Error origin` entry in `src/tui/GLOSSARY.md` says how `dispatch` derives an origin and how `withErrorOrigin` assigns one.
   A glossary holds no implementation details.

## Proposal

1. Move the whitespace into the lookahead. Keep the exclusion of the declaration.
2. Prove the missing repaint through `Projection.revision` first. If it holds, change the status revision where `action_error` changes.
3. Clear the shown message before the pump and before every other step of the open that can show a message.
4. Keep the domain definition in the glossary. Move the mechanics to `docs/rules/tui-state.md` only if that file does not state them.

## Acceptance criteria

- [x] A checker test with a space and a line break before `.user` fails before the fix. Copied and qualified origins stay rejected.
- [x] A test through `Projection.revision` fails before the fix when a focus check shows or clears a message.
- [x] A test fails before the fix when the pump of an open Review Search cannot queue a File Enrichment and no message shows after the open.
- [x] The glossary entry has no implementation details, and each rule stays stated once.
- [x] `zig build test` exits 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` pass.

## Comments

### 2026-11-26 verdicts

1. Valid. The check reads the Presentation body as one joined text, so `\s` inside the lookahead also covers a line break.
2. Valid. `dispatch` changes no revision for `ensure_focused_enrichment`, a mouse input, a Selected Version action, a loaded or prepared Session, and a code highlight completion. On main the helpers are the same. The test "a failed Selected Version change preserves the complete published interaction" asserted an unchanged revision while it showed `out_of_memory`, so it encoded the same fault.
3. Valid. A reopened query retry runs as `.review_search` and clears a Review Search message on success, so it also removed the message of the pump. The open now clears first, then retries the query, then pumps.
4. Valid. `docs/rules/tui-state.md` already states how `dispatch` and `withErrorOrigin` set an origin.

The reviews found two more cases of item 3. [Ticket 10](10-clear-before-the-maintenance-steps-of-a-query-edit.md) holds them.

## Completion

- Item 1: `ORIGIN_CALL` reads the whitespace inside its lookahead. Red: `AssertionError: Lists differ: ['3', '4', '9'] != ['9']`.
- Item 2: `showErrorFor` changes `status_revision`, and `clearError` changes it when it clears. Red: "M21 kernel the paint revision changes when a focus check shows or clears a message" failed at the shown `out_of_memory` with the same revision. Without the bump in `clearError`, the test fails at the clear.
- Item 3: `openReviewSearch` clears before its reopened query retry and its pump. Red: "M21 kernel opening Review Search shows the failure of its acquisition queue" failed with `expected .out_of_memory, found null`. With the clear moved but the old order, the reopened query case still failed.
- Item 4: the Error Origin entry has no mechanics.
- Commits: `781a5006` (ticket), `69f25541` (red 1), `52cd22a2` (fix 1), `b28ec293` (red 2), `9874f2a7` (fix 2), `e6ff14f6` (red 3), `cd7a602c` (fix 3), `059ded93` (glossary), `a4e8d144` (review comments), and the resolve commit.
- Checks: `zig build test` exit 0 with 1773 of 1773 tests. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` pass.
- Review: the Standards review found no hard violation. The Spec review found that a failed retry with a short allocation failure loses its message when the pump succeeds. A lasting failure keeps it. Ticket 10 holds that case.
