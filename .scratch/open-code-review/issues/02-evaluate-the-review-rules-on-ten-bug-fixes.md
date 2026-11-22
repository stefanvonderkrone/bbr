# Evaluate the review rules on ten bug fixes

Status: resolved
Blocked by: 01

## Problem

Nothing shows yet that the project rules find real defects in bbr, or that they find more than the built-in rules.

## Method

Use the ten newest bug fixes: `81787495`, `2e8ab1e7`, `9f285acb`, `3127762c`, `3ae9b944`, `f1e76906`, `1825dd0a`, `8c5770a6`, `e60b43c0`, and `1e809a19`.

1. For each fix, write down the expected finding before any run.
2. Find the commit that brought in the bug with `git blame` on the lines that the fix changes. When no commit clearly brought in the bug, mark the case `no clean origin` and skip it.
3. Review the origin commit in commit mode twice with the same model: once with the project rules, and once with `--rule` set to an empty rule list, which leaves only the built-in rules.
4. Count hits, misses, and false positives for each run.
5. As false-positive controls, review each fix commit and the refactor commit `c63780fe`.

## Acceptance criteria

- [x] A results table lists each case with its expected finding, origin commit, and outcome for both rule sets.
- [x] The table names the model of each run.
- [x] Each rule that caused a false positive is changed or removed.

## Completion

Every run used the `ocr-review` agent on `anthropic/claude-sonnet-5-5`, `ocr` 1.14.0, and commit mode in a detached checkout of the reviewed commit. The project rules came from `--rule` with a copy of `.opencodereview/rule.json` at `625ba921`. The built-in rules came from `--rule` with the same filters and one entry, `**/*`, with an empty rule and `merge_system_rule`.

### Origin reviews

Two cases have no clean origin, so the evaluation skips them. For `3127762c`, `5e2093b2` holds the code, but `ae39a66d` exposed the defect. For `e60b43c0`, the error reset changed in four commits.

| Fix | Origin | Expected finding | Project rules | Built-in rules |
| --- | --- | --- | --- | --- |
| `81787495` | `bd0b9161` | The deferred lease release stages a cache build, and its `out_of_memory` replaces `buffer_search_scan_failed`. | miss | miss |
| `2e8ab1e7` | `bd0b9161` | Under a lasting failure, each File fails twice, which gives two scans and two records per File. | miss | miss |
| `9f285acb` | `7d9102cf` | `*const MentionNames` does not stop a write, because `getPtr` returns a mutable pointer. | partial: flags the Enforcement claim as unsupported, but not `getPtr` | miss |
| `3ae9b944` | `0f55293a` | `far_over_budget` needs an eighth of the Files, so a few large Files can hold any number of bytes. | miss | miss |
| `f1e76906` | `45ddc6ee` | A move of the Buffer Search current occurrence discards a running rebuild. | miss: no finding names `accepted_active` | miss: three unverified findings about lost queued jobs |
| `1825dd0a` | `45ddc6ee` | A Review Search selection move discards a running rebuild. | miss: no finding names `review_selected` | miss |
| `8c5770a6` | `ae39a66d` | One refused result refuses the whole batch, and joined results get no hold. | miss | miss |
| `1e809a19` | `aab419ef` | A failed stderr write returns `WriteFailed` instead of `error.Reported`, so the failure has two records. | hit, plus two stale doc claims | hit |

Project rules: 1 hit and 1 partial hit of 8. Built-in rules: 1 hit of 8.

These limits apply to the numbers:

- The sample is small, and each review ran once. Model output varies between runs.
- Several origin commits are older than `docs/rules/` and `CODING_STANDARDS.md`, so the project rules named files that the checkout did not have.
- Some rule text comes from the later fixes. For example, the queued cache update rule comes from `3127762c`. The review of `ae39a66d` with the project rules reported that the queued cache update is passed, but that finding repeats a rule that the later fix wrote.

### False-positive controls

The controls are the ten fix commits and the refactor `c63780fe`, with the project rules.

| Commit | Real | False | Debatable | Notes |
| --- | --- | --- | --- | --- |
| `81787495` | 1 | 0 | 0 | The new standard has no related checked rule link. |
| `2e8ab1e7` | 1 | 0 | 0 | The rule doc says "stays unscanned", but the code sets `given_up`. |
| `9f285acb` | 2 | 0 | 1 | The commit does not build (`read_only.zig:22`), and `3f0cf9f1` fixes it. A rule doc claim is stale. |
| `3127762c` | 0 | 1 | 0 | It reports a missing test, but the test is in the parent `1eaadeaa`. |
| `3ae9b944` | 2 | 0 | 0 | The rule doc names the removed `far_over_budget_bytes`. A test comment still names "an eighth of the Files". |
| `f1e76906` | 1 | 0 | 0 | `AGENTS.md` names the removed `DisclosureBuild.accepted_active`. |
| `1825dd0a` | 0 | 0 | 0 | |
| `8c5770a6` | 1 | 0 | 1 | No new test reaches `refuseEnrichments`. |
| `e60b43c0` | 0 | 0 | 1 | A `.cache_update` build still clears an unread `picker_load_failed`. This is unverified, and no test reproduces it. |
| `1e809a19` | 0 | 0 | 2 | It records a write failure with the cause `Canceled` before `io.recancel()`. |
| `c63780fe` | 0 | 0 | 0 | |

Totals: 8 real findings, 1 false positive, and 5 debatable or unverified findings. Six real findings are stale docs, and three of those docs were not in the diff.

### Rule changes

- A guard drops a missing-test finding only when an earlier commit adds a test that reaches the changed code. It fixes the `3127762c` false positive.
- The cancelation rule now covers only retry and give-up limits. It fixes the over-application in `1e809a19`.

### Conclusion

The project rules find stale docs well. Neither rule set finds the state-machine defects of Presentation, which were 6 of 8 cases. Those defects come from a policy under a lasting failure, or from a snapshot that admission compares. A rule for each class would fit only this set of cases, so this ticket adds none.

One finding is still on `main`. The `.cache_update` error reset at `src/tui/presentation.zig:10316` clears an unread `picker_load_failed`. Triage verified it with a test, and [ticket 02](../../open-code-review-findings/issues/02-keep-a-picker-error-through-a-cache-update.md) tracks it.

The test comment at `src/tui/presentation.zig:30870` was stale at `3ae9b944`, but `8cb4b75e` made it correct again. [Ticket 01](../../open-code-review-findings/issues/01-correct-the-cache-budget-test-comment.md) records why it is `wontfix`.

The `user_grammar.zig` finding is false. `Diagnostic.report` drops a failed stderr write, and `diagnostic_handle.fail` still records the failure.

## Comments
