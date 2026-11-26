# Fix the second CodeRabbit findings of PR #45

Status: claimed
Claimed by: /Volumes/Work/t3-code/focus-check-staging-failure
Blocked by: none

Source: second CodeRabbit review of PR #45.

## Problem

1. `docs/rules/tui-state.md` says that a user input clears before its own steps that can show a failure.
   That holds for opening Review Search, but not for a query edit.
   A query edit clears after `releaseReviewSearchHolds` and `discardQueuedReviewSourceScans`, so a failed cache staging of those steps loses its message.
   The rule also says that a success of `pumpReviewSearchAcquisition` keeps an error of the event that pumps.
   But the pump and the reopened query retry share the origin `.review_search`, so a successful pump clears the failure of the retry.
   The follow-up PR #52 owns both gaps, in `.scratch/query-edit-clear-order/` on the branch `query-edit-clear-order`.
2. When the first queue of the Review Search acquisition fails and no File Enrichment is in flight, the pump stops and the File stays pending.
   Only a completion, an open, a Preview hold, or a source scan restart pumps again.
   The focus check returns early while Review Search is open, so no later check queues the File.
   This breaks the rule that maintenance work runs again at a later check.

## Proposal

1. Limit the rule to opening Review Search. Name the two gaps and point to `.scratch/query-edit-clear-order/` as text, because that path is not on this branch.
   Fix each code comment that states the opposite of the code.
2. Prove the stop with a test through Presentation first.
   Then let the focus check pump the acquisition while Review Search is open.
   Keep the limit of eight requests and the message rule of `failMaintenance`.

## Acceptance criteria

- [ ] The rule in `docs/rules/tui-state.md` claims only what holds on this branch, and it names the known gaps once.
- [ ] A test fails the first acquisition queue with no File Enrichment in flight, lets memory recover, and runs the focus check. It expects eight File Enrichment commands. The test fails before the fix.
- [ ] `zig build test` exits 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` pass.
