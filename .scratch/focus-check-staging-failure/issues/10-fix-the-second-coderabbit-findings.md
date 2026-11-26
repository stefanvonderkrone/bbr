# Fix the second CodeRabbit findings of PR #45

Status: resolved
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

- [x] The rule in `docs/rules/tui-state.md` claims only what holds on this branch, and it names the known gaps once.
- [x] A test fails the first acquisition queue with no File Enrichment in flight, lets memory recover, and runs the focus check. It expects eight File Enrichment commands. The test fails before the fix.
- [x] `zig build test` exits 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` pass.

## Comments

### 2026-11-26 verdicts

1. Valid. The rule in `docs/rules/tui-state.md` claimed the clear order for every user input. `setReviewSearchQuery` clears at the end of its success paths, after its lease releases. The pump comment and the `retryReviewSearchQuery` comment also said that a pump success keeps the message of the event, but the pump clears the `.review_search` message of a failed retry.
2. Valid. Ticket 03 assumed that a later pump always follows a failed queue. Only a completion, an open, a Preview hold, a hit in an evicted File, a cache update commit, or a source scan restart pumps. With no File Enrichment in flight, none of them follows, and the focus check returned early while Review Search was open.

The focus check now runs the query retry and then the pump in one event, as `openReviewSearch` does. So the second gap of `.scratch/query-edit-clear-order/` also applies at the focus check. That ticket names only `openReviewSearch`.

## Completion

2026-11-26, branch `focus-check-staging-failure`.

- `ensureFocusedEnrichment` pumps the Review Search acquisition while Review Search is open. The pump keeps its limit of eight requests, and a failed queue still goes through `failMaintenance`.
- `docs/rules/tui-state.md` states the clear order of `openReviewSearch` only and names the two gaps once, with the text pointer `.scratch/query-edit-clear-order/`. The comments of `retryReviewSearchQuery` and `pumpReviewSearchAcquisition` no longer say that a pump success keeps the message of a failed retry. `CODING_STANDARDS.md` says that the focus check pumps while Review Search is open.
- Red proof: "M21 kernel the focus check queues a Review Search acquisition that failed with no work in flight" failed with `expected 8, found 0`. It passes now.
- Commits: `ec213ae7` (ticket), `820975b5` (red test), `bfe093bb` (fix), `11789770` (docs), `11b20a41` (review fix), and the resolve commit.
- Checks: `zig build test` exit 0, `zig fmt --check src build.zig tests` exit 0, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` exit 0.
- Review: a readonly review found two claims that went too far. `11b20a41` fixes both. It found no other issue with the eight-request limit, `failMaintenance`, the cache order, or the other pump callers.
- Open: the owner of `.scratch/query-edit-clear-order/` must add the focus check to its second gap, because the focus check now runs the retry right before the pump.
