# Clear before the maintenance steps of a Review Search query edit

Status: resolved
Blocked by: none

Source: the Standards and Spec reviews of ticket 09 in `.scratch/focus-check-staging-failure/` (PR #45).

## Problem

1. `setReviewSearchQuery` calls `clearError` at the end of its success paths.
   Before that, `discardQueuedReviewSourceScans` and, for an empty query, `releaseReviewSearchHolds` can reach `finishSearchLease`, then `stageCacheBuild`, then `failMaintenance`.
   A user query edit runs with the origin `.user`, so its clear removes the `out_of_memory` message of that failed staging.
   The failure has its record, but the user sees no message.
   The rule "A user input clears before its own steps that can show a failure" in `docs/rules/tui-state.md` does not hold here.
   The search destination completion near `discardQueuedReviewSourceScans` and `releaseReviewSearchHolds` in `acceptBufferDisclosure` can have the same order. Nobody traced its origin.
2. `openReviewSearch` runs the reopened query retry and then the acquisition pump.
   Both run as `.review_search`.
   When the retry fails with `out_of_memory` and the next allocation succeeds, the pump's successful `queueFileEnrichment` clears the message of the retry.
   `std.testing.FailingAllocator` keeps failing after its first failure, so no current test can make this case.
   With a lasting allocation failure, the pump fails too, and `failMaintenance` keeps the message.
   The focus check of PR #45 (ticket 10) runs the same reopened query retry right before the same pump while Review Search is open, so the case also applies there. The fix must cover both `openReviewSearch` and the focus check.

## Proposal

1. Move the `clearError` of `setReviewSearchQuery` before its first step that can show a failure. Write a red test that fails the staging of a released source scan lease during a query edit.
2. Decide whether a short allocation failure between two adjacent allocations needs a fix. If it does, write a test allocator that fails one allocation only, and decide whether the pump waits for the results of a retried query.

## Acceptance criteria

- [x] A test fails before the fix when a query edit removes the message of its own failed staging.
- [x] Item 2 has a decision in the ticket.

## Comments

### Triage

All three cases are real. Each one has a red test through `Presentation.dispatch`.

1. Valid. `setReviewSearchQuery` called `clearError` at the end of both success paths. `discardQueuedReviewSourceScans` and, for an empty query, `releaseReviewSearchHolds` ran before it. With a cache update in flight, each release stages a cache build. When the staging cannot allocate, `failMaintenance` shows `out_of_memory` with the origin `.user`, and the clear of the same key removes it. The test "M21 kernel a Review Search query edit shows the failure of its cache staging" failed with `expected .out_of_memory, found null`.
2. Valid. The `.review_destination` branch of `acceptViewBuild` closes Review Search. It discards the queued source scan and releases the holds, and then it calls `clearError`. The completion has the origin `.buffer` from `DisclosureBuild.Kind.errorOrigin`, and `failMaintenance` shows its message with the same origin, so the clear removes it. The test "M21 kernel a Review Search destination shows the failure of its cache staging" failed with `expected .out_of_memory, found null`.
3. Valid for `openReviewSearch` and for the focus check. A test allocator that fails one allocation only, `FailOnceAllocator`, fails the queue slot of the reopened query retry. The pump then queues the Files, and its `queueFileEnrichment` clears the `.review_search` message of the retry. The test "M21 kernel a successful acquisition pump keeps the failure of the Review Search query retry before it" failed with `expected .out_of_memory, found null`, also with the loop order reversed so that the focus check case runs first.

The ticket was fully specified after this triage, so it went to `ready-for-agent` and then to `claimed`.

### Decision on item 2

A short allocation failure between two adjacent allocations needs a fix, because the experiment shows that the message is lost while the failure has its record.

The pump does not wait for the results of the retried query. The fault is not the order of the retry and the pump. The fault is that a clear removed a message that a step of the same event showed. A reorder cannot fix it, because the retry and the pump share the origin `.review_search` and both must run in the event.

The fix is in `clearError`. `Presentation.event_serial` counts the events, and each `ShownError` holds the serial of the event that showed it. A clear never removes a message of the event that runs. A failed maintenance step that keeps an older message records itself in `kept_failure` through `showMaintenanceError`. A later clear of the same event shows that failure instead of null. So the order of a clear and the steps of its event no longer matters, and the same change fixes items 1 and 2. The clear order rule in `CODING_STANDARDS.md` is gone, because its mistake can no longer happen.

## Completion

The fix changes the clear rule, so the order of a clear and the steps of its event no longer matters. It does not move the clears.

- `d89271b5`, `12c83975`, and `ba0ab9f4` add the red tests for the query edit, the Review Search destination, and the pump after a failed query retry. Each test failed with `expected .out_of_memory, found null`.
- `a3b96cea` adds `event_serial`, `ShownError.event`, `kept_failure`, and `showMaintenanceError`. It removes the clear order rule and the two gaps from the docs.
- `96d6ca80` makes `tools/check_action_errors.py` reject a test of `action_error == null` in `Presentation` outside `showMaintenanceError`. On the code before the fix, the check names the three old keep sites.
- The last fix commit applies the review findings. A kept failure keeps the origin of its step, the query edit test checks that the next key clears, and the docs state the rule once.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, and `python3 tools/check_doc_symbols.py .` pass.

Review: a readonly review found no correctness bug. It found the origin of a kept failure, a missing staleness test, and a duplicate rule, and the last fix commit fixes them. Two findings are open and documented. The check reads only `action_error == null`, and the rule doc says so. The span arithmetic of the check is correct, and it stays as it is.


## OCR round 1

Open Code Review found five items in the first fix. Each verdict comes from a test through `Presentation` or from a run of the check.

1. Valid. `acceptPreparedSession` ran the discards of the queued searches while the old Session was still published. The discard of the source scan finished its lease and staged a cache build for the old Session. A failed staging then showed `out_of_memory` for a Session that the same event destroys. The test "M21 kernel a Session replacement shows no cache staging failure of the replaced Session" failed with `expected null, found .out_of_memory`. The code before this branch passed it, so the first fix caused it. The discards now run after the new Session publishes (`2a375685`), so no lease of the old Session stages a build.
2. Valid. The check read one line at a time and matched only `.action_error == null`. Each rule now reads the code joined across lines. In the `Presentation` body, any access of `action_error` outside `showErrorFor`, `clearError`, `finishEvent`, and `projection` fails (`090f845b`). The new tests in `4ed241c4` failed against the old check. On the code before this branch, `7f872409`, the check names the three old keep sites, lines 9129, 10228, and 10704. On the first fix, `f1c8bf54`, it names the read in `showMaintenanceError`.
3. Valid. The docstring and the success line now name every owner of each field. `event_serial` and `kept_failure` are gone. Their replacement, `maintenance_failures`, has an access rule with the owners `settleMaintenance`, `showMaintenanceError`, and `finishEvent`.
4. Kept as decided. The test "M21 kernel an accepted Buffer Search without matches keeps its message" showed that the first fix kept the message only when the accept came before the scan result. An accept after the result cleared it (`cbc39d1d`). `acceptBufferSearch` now shows `buffer_search_no_matches` when the accepted batch has no occurrence, in both orders (`7df5a3db`). The review found that a null active occurrence is not enough. A Buffer rebuild can leave matches without an active occurrence, and a failed scan leaves no batch. The test "M21 kernel an accepted Buffer Search shows no-match only for an empty batch" (`b1f0cb5e`) failed on both cases. Without a batch, the accept keeps the message of the failed scan.
5. Valid, and it refuted the premise of the first fix. The premise was that a message must show at the time of the failure, so every clear of the same event must keep it. With that premise, a recovered step could not withdraw its message, and one `kept_failure` slot lost a second failure. The test "M21 kernel a Review Search query edit shows no failure of a cache staging that a later staging recovers" failed with `expected null, found .out_of_memory`.

The new design is smaller (`59a1fe64`), and it replaces the fix in "Decision on item 2". A failed maintenance step records its failure in `Presentation.maintenance_failures`, one entry for each `MaintenanceStep`, and shows nothing yet. `settleMaintenance` removes the entry when a later run of the same step in the event succeeds. When the outermost event ends, `finishEvent` shows the first recorded failure with the origin of its step, but only when no message shows. `event_serial`, `ShownError.event`, and `kept_failure` are gone, and `clearError` is the plain origin rule again. The one-slot case has a test: "M21 kernel a recovered cache staging keeps the failure of another maintenance step". It passes on the first fix and on the new design, and it fails when a recovery removes the failure of another step.

The new design also showed that `openReviewSearch` retried a reopened query through `replaceReviewSearchQuery`, which shows the failure of a dropped input at once. The query keeps `needs_scan`, and the focus check retries it, so the retry is maintenance work. `openReviewSearch` now runs `retryReviewSearchQuery`.

Review: a readonly review of `f1c8bf54..HEAD` found two medium findings in `acceptBufferSearch`, now fixed as above. It also found three gaps of the check: a one-line helper body, a read beside a write on one line, and a helper name in another struct. The tests in `9d312e76` failed against the check, and `cba6f02b` closes the gaps. The doc now says that `finishEvent` shows the failure of the first step in `MaintenanceStep` order, and two test names no longer say "same event". The review found no problem in the defer order of `dispatch`, the discards after publish, the reopened query retry, or the recovery of `settleMaintenance`. One finding stays open by choice: the test "M21 kernel a recovered cache staging keeps the failure of another maintenance step" runs private steps inside `withErrorOrigin`, because no single input makes two different steps fail and one of them recover.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_action_errors_test.py` pass.

## OCR round 2

Open Code Review found five items in `c35cf920`. Each verdict comes from a red test or from a run of the check.

1. Valid. `queueMaintenanceFileEnrichment` recorded a failure, but a later successful queue of the same File removed nothing. So when the acquisition pump of `openReviewSearch` or of the focus check failed to queue a File, and the pump of `holdReviewSearchPreview` queued that File in the same event, `finishEvent` still showed `out_of_memory`. The test "M21 kernel a File Enrichment queue recovers only the failure of its own File" (`139a4317`) failed with `expected null, found .out_of_memory`. The fix (`e715ea31`) makes `MaintenanceStep` a tagged union, and its `file_enrichment` field names the File. `queueMaintenanceFileEnrichment` passes its outcome to `settleMaintenance`, and a success removes only an entry of the same step and File. After a failure of a second File in the event, the step names no File, so no single queue hides the failure of the other File. Without that merge, the same test fails with `expected .out_of_memory, found null`. The test runs private steps inside `withErrorOrigin`, because the pump sequence needs a pending source occurrence for the Preview hold, and no test helper builds one.
2. Valid. The read rules of `tools/check_action_errors.py` read only the `Presentation` struct body, so a free function that takes a `*Presentation` passed. The test "a free function outside a test block is checked" (`4a0fa369`) failed against the check. Both rules now read the whole file outside the top-level `test` blocks (`230f59e6`). A read through `projection().action_error` passes, and eight reads in benchmarks and test helpers now use it. Each of those reads runs after its timed section.
3. Valid. `docs/rules/tui-state.md` now says that a successful retry clears only an error of its own origin, and that a failed retry shows `out_of_memory` when its event ends without a message (`193470a9`).
4. Valid. `CODING_STANDARDS.md`, `src/tui/GLOSSARY.md`, `docs/rules/diagnostics.md`, and the doc comments of `failMaintenance` and `showMaintenanceError` now say that a maintenance failure shows when its event ends without a message (`193470a9`).
5. Decided by the coordinator. An accept without a batch kept every shown message. The test "M21 kernel an accepted Buffer Search without a batch keeps only a message of the search" (`47e663df`) failed with `expected null, found .file_enrichment_launch_failed`. The accept now keeps only `buffer_search_scan_failed` or `buffer_search_no_matches` through `clearErrorExcept`, and it clears any other message by the rule of `clearError` (`234568a7`). The check allows `clearErrorExcept` to read `action_error`.

Review: a readonly review of `c35cf920..HEAD` found that the `projection().action_error` exemption also passed a hand-kept message inside a method of `Presentation`. The test in `89529b9e` failed against the check, and `6689c97e` exempts that read only outside the `Presentation` body. The review also found four doc gaps, fixed in `06241db8`: the `MaintenanceStep` comment, the tag key of `maintenance_failures`, the scope of the read rules, and the end-of-event rule, which the glossary and `docs/rules/diagnostics.md` stated a second time. Three findings stay open by choice:

- A maintenance queue of a File with a too-long path or commit shows `action_refused` at once, and the queue then counts as a success. The code before this branch does the same, and the message is not `out_of_memory`, so it is out of scope.
- A `MaintenanceFailure` has no Session epoch. No event runs a step on the old Session before `acceptPreparedSession` swaps it, so no message of a gone Session shows today.
- After two Files fail in one event, the step names no File. So when both Files recover later in the event, the user still sees `out_of_memory`. A bitset of Files would fix it, but no event recovers two failed Files.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_action_errors_test.py` pass.

## OCR round 3

Open Code Review found one item in `e0f03ced`.

1. Valid. `docs/rules/tui-state.md` said that an accepted Buffer Search without a batch clears any other message. But `clearErrorExcept` clears by the rule of `clearError`. Only an accept by the Enter key has the origin `.user` and clears any message. An accept that a Buffer Search completion runs through `accept_when_ready` clears only a message of the origin of that completion. The rule doc and the comment in `acceptBufferSearch` now say so. The code does not change.

## CodeRabbit round 1

CodeRabbit found one item in `c3168e16`.

1. Valid. A query edit keeps the batch of the previous query in `BufferSearchInput.batch` while the scan of the edited query is pending. Each failure that ended that scan only set `input.pending = false`, so the input kept the batch of the previous query as if it belonged to the edited query. An accept then installed it as `accepted_batch`. After a scan of `qqqq` with no match and a failed scan of `qqqqq`, the Enter key replaced `buffer_search_scan_failed` with `buffer_search_no_matches`. After a scan of `eigh` with matches and a failed scan of `eighx`, the accept cleared the message and opened the matches of `eigh`. The code before this branch has the same fault: its accept installs the batch of the previous query and clears every message, so the user sees no message at all. The test "M21 kernel an accepted Buffer Search keeps the scan failure of its query edit" (`d81ccf68`) failed with `expected .buffer_search_scan_failed, found .buffer_search_no_matches`, and its case with matches failed with `expected .buffer_search_scan_failed, found null`. The fix (`d17e4ec4`) adds `BufferSearchInput.failPendingScan`. It ends the scan and drops the batch, its ranges, its navigation rows, and the active occurrence. Each failure of a pending input scan calls it: a failed scan, a failed allocation after the scan, a failed or unadmitted disclosure build of the input, and a failed retry of a stale scan. So the batch of an accept always belongs to the accepted query, and `acceptBufferSearch` needs no new guard.

Review: a readonly review of `c3168e16..HEAD` found no blocking finding. It found every path that ends a pending input scan without its own batch covered, no batch of the current query dropped except by a real failure, and no double free. Two low findings stay open by choice:

- Some failure sites drop the highlights without a change of `frame_revision`. Each of them calls `showError`, which changes `status_revision`, and the App paints again on any change of `Projection.revision`. So the user sees no stale highlight.
- The test covers only the failed scan outcome. The other failure sites call the same `failPendingScan`, and each needs a disclosure build or an allocation failure at one point that no test helper reaches cheaply.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_action_errors_test.py` pass.

## OCR round 5

Open Code Review found two low items in `82169b10`. Each verdict comes from a red test or from a revert of one site.

1. Valid, and the coordinator decided to fix it. A failed scan dropped the batch of the previous query, but it kept the disclosures that the preview of that query expanded. After a scan of `eigh`, whose match is in a collapsed Resolved Thread, and a failed scan of `eighx`, the thread stayed open in the input and after the accept. A scan without matches restores the disclosures through its input build. A failed scan queued no build, and `clearBufferSearchActive` returns early without an active occurrence, so nothing restored them later. The test "M21 kernel a failed Buffer Search scan collapses the preview of the previous query" (`a7759ada`) failed with `expected 15, found 34` rows. The fix (`979afee3`) adds `failBufferSearchScan` for a failed scan and for a completed scan without ranges. It calls `failPendingScan`, shows `buffer_search_scan_failed`, and queues the same input build as a scan without matches, without a batch. That build shows `buffer_search_scan_failed` again when it lands. An input build now projects only its own batch, so a build without a batch installs no ranges. The test "M21 kernel an accepted Buffer Search keeps the scan failure of its query edit" now completes the build after the Enter key, because the accept waits for it as it waits for the build of a scan without matches.
2. Valid. Only the failed scan outcome had a test. The test "M21 kernel a Buffer Search input that fails after a query edit opens no occurrence of the previous query" (`93fe8af6`) fails a disclosure queue, an input build, the admission of an input build, and the queue of a stale scan once each. It checks the message and that the Enter key opens no occurrence of the previous query. A revert of each site to `input.pending = false` made a test fail: the failed scan and the scan without ranges fail the test of item 1, the shared call in `failBufferSearchScan` fails the test "M21 kernel an accepted Buffer Search keeps the scan failure of its query edit", and the four other reachable sites fail the new test. Three sites in `retryStaleBufferDisclosure` stay without a test, because no input reaches them. They handle a failure of `search.Query.init` for the text of a query that already passed `search.Query.init`, so `TooLong`, `InvalidUtf8`, `LineEnding`, and `Nul` cannot occur, and the `OutOfMemory` comes from `std.heap.page_allocator`, which a test cannot fail.

The coverage test reaches two sites through state that no key sets. It sets `disclosure_inputs_current` to false, the state after a failed cache staging, so that `DisclosureBuild.create` fails. It empties the capacity of the command queue, so that the queue of the stale scan allocates.

Review: a readonly review of `82169b10..HEAD` found no high finding. It found the restore build safe on Escape, Enter, another query edit, a Session replacement, and a stale build, which rescans the query as after a scan without matches. Two medium findings are fixed:

- The disclosure queue in `acceptBufferSearchScanned`, the new restore queue in `failBufferSearchScan`, and the admission in `acceptBufferDisclosure` dropped the input build of a query edit and showed `out_of_memory` without a record. [A dropped user input shows its failure](../../../CODING_STANDARDS.md#a-dropped-user-input-shows-its-failure) needs one record. The test case in `26f8d1cd` failed with `expected 1, found 0` records, and `edb4ac9d` calls `failDroppedInput` at the three sites. A revert of each site makes the test fail again.
- No test reached the restore queue of `failBufferSearchScan`. The coverage test now has a case for it.

The test also checks that the command queue is empty before it frees the capacity. Two low findings stay open by choice:

- After an `out_of_memory` of these sites, the Enter key clears the message through `clearErrorExcept`, so the accept does not say why nothing opened. The input could keep the message of its failure, and the accept could show it. That changes the accept rule of OCR round 2, so it needs a decision.
  Decision: this PR does not fix it. The case is rare, and the failure keeps its record. A follow-up ticket owns it, because the fix changes the accept rule of OCR round 2.
- The CodeRabbit round 1 section says that only the failed scan outcome has a test. This section supersedes it.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_action_errors_test.py` pass.
