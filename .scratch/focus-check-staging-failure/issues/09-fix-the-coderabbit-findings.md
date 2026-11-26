# Fix the CodeRabbit findings of PR #45

Status: claimed
Claimed by: /Volumes/Work/t3-code/focus-check-staging-failure
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

- [ ] A checker test with a space and a line break before `.user` fails before the fix. Copied and qualified origins stay rejected.
- [ ] A test through `Projection.revision` fails before the fix when a focus check shows or clears a message.
- [ ] A test fails before the fix when the pump of an open Review Search cannot queue a File Enrichment and no message shows after the open.
- [ ] The glossary entry has no implementation details, and each rule stays stated once.
- [ ] `zig build test` exits 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` pass.
