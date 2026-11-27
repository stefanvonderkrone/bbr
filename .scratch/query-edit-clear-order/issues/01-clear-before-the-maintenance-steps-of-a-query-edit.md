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

## OCR round 6

Open Code Review found three low items in `8e6cf144`. Each verdict comes from a red test, a revert of one site, or a mutation of the code.

1. Valid. An Enter key during pending work of the input sets `accept_when_ready`. A result or a restore build that lands runs the accept. But each failure that ended the pending work only set `pending` to false, so the flag stayed set, the input stayed open, and the Enter key did nothing. The same fault was at every failure site, not only in `failBufferSearchScan`: a failed scan without a restore, a failed restore, a failed or unadmitted input build, a failed queue of a disclosure or of a stale scan, and a failed query clear or a failed queue of its retry. A scan without matches has no such gap, because its landing runs the accept. The coverage test "M21 kernel a Buffer Search input that fails after a query edit opens no occurrence of the previous query" now presses the Enter key before each failure, and the tests "M21 kernel an Enter key during a failed Buffer Search scan closes the input" and "M21 kernel an Enter key during a failed Buffer Search query clear closes the input" are new. They failed at `buffer_search.input == null` for all five failure sites, for the scan without a restore, for the failed restore, and for the failed query clear (`e766ca43`, `6bcd5854`). The case with a failed queue of the retry came later (`cfadb2e4`), and a revert of its site makes it fail. The scan with a restore passed before the fix, because its landing already accepts. The fix (`d1526ccc`) adds `failPendingInput`. Each site that ends pending work of the input without its result calls it. It drops the batch of the previous query, marks the frame, and runs the waiting accept before the caller shows its message, so the accept does not clear that message. A revert of each call to the old drop made a test fail at every reachable site. The five sites that stay green on a revert are the three `search.Query.init` prongs of `retryStaleBufferDisclosure` that no input reaches, the admission of a query clear, whose disclosure list is empty and allocates nothing, and the failed queue of an opening, where the helper does not accept.
   A failed opening keeps the Enter key. An accept queues the opening again, so an accept at a failed opening build would repeat a failing build. So the user presses the Enter key again after a failed opening.
2. Valid. `docs/rules/tui-state.md` said that a failed scan keeps no preview of the previous query. When the restore build cannot queue or fails, the view keeps the disclosures of the previous preview and `saved_disclosures`, and the message of that failure replaces `buffer_search_scan_failed`. The rule now states that limit once, and it states how an Enter key during the failed work is accepted (`4454410b`).
3. Valid. `completeTestDisclosureBuilds` discarded a queued scan, so a restore that landed stale and queued a rescan passed without the rescan. The helper now fails on a queued scan. No existing test relied on the discard. The test "M21 kernel a query edit drops the restore of a failed Buffer Search scan" edits the query while the restore is queued and while it runs. It failed when `discardQueuedBufferSearchScans` kept the queued restore, and when `acceptBufferDisclosure` did not check the request of the running restore. The test "M21 kernel a failed restore of a failed Buffer Search scan shows the build failure" checks `buffer_build_failed` and the documented limit. When every restore landed as stale, the strict helper failed four tests with `UnexpectedBufferSearchScan` (`a33f901e`).

Review: a readonly review of `8e6cf144..HEAD` found no blocking finding. No caller reads the input after `failPendingInput`, the accept writes no record, and each remaining `pending = false` is on a success path that runs the accept. The review asked for one doc fix, which is done. Four findings stay open by choice:

- After an Enter key, a failed restore closes the input, but the view keeps the expanded Thread of the previous preview and `saved_disclosures` stays set until the next search. Without the Enter key the input shows the same view. The accept could queue a `.restore` build as `cancelBufferSearch` does. That changes the accept, so it needs a decision.
- A failed query clear with an Enter key runs `traverseBufferSearchBy`. When an accepted batch exists, a queued `.accepted` build of the same origin can clear `buffer_build_failed` when it lands, but the view is then right.
- The query clear test has no accepted batch, so only the scan tests guard the order of the accept and the message in `failPendingInput`. The helper is shared, so that order has one owner.
- A failed opening keeps the Enter key, as item 1 says.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_action_errors_test.py` pass.

Decision on the open question of OCR round 6: when Enter comes before a failed restore, the view keeps the old preview. This PR does not fix that. A follow-up ticket owns it, together with the deferred out-of-memory message of an accepted Buffer Search.

## OCR round 7

Open Code Review found two low items in `1a8fbac2`. Each verdict comes from a probe, a red mutation, or a full test run.

1. Not reachable. The finding said that a `clear_input` or `open_input` build whose `accepted_snapshot` no longer matches `accepted_batch` returns from `acceptAcceptedDisclosure` without a result, so the Enter key is lost. `DisclosureBuild.create` takes the snapshot for every kind, these two included. But `acceptAcceptedDisclosure` compares the inputs, `visual_rows_revision`, and the geometry before the snapshot, and a mismatch there retries the build. Each write of `accepted_batch` either changes `visual_rows_revision` in the same function or closes the input. `StagedBuffer.publish` and the landing of a general build, the enrichment rebuild included, increment the revision after they replace the batch. `acceptBufferSearch` and the reset of `buffer_search` close the input, and both kinds return earlier when the input is closed. The command queue also issues one build at a time, so a build that replaces the batch lands before the next build is issued. A probe test that landed a view rebuild between the queue and the landing of each kind saw the retry, and the Enter key closed the input. A full `zig build test` with a panic at both returns for the two kinds passed. No code changed.
2. Valid. Two paths had no test. The test "M21 kernel a failed Buffer Search opening keeps the input open" fails the opening build and the queue of its retry with an Enter key waiting. It checks that the input stays open, that `pending` is false, that the message is `buffer_build_failed` or `out_of_memory`, and that no opening is queued again. A second Enter key then retries the opening. The test "M21 kernel an Enter key during a failed Buffer Search query clear opens the next accepted occurrence" fails the query clear and the queue of its retry with an accepted search. It checks that the input closes and that the failure shows. After a failed build, the build of the next accepted occurrence restores the view of the accepted search and shows `buffer_search_hit_bottom`. After a failed queue, the view keeps the preview, as the rule says (`6d11d9cb`). Five temporary mutations each made a test fail: an accept at a failed opening, no accept at a failure, no traversal in the accept of a cleared query, and no `failPendingInput` at a failed opening build or at a failed queue of its retry. The first and the third failed only the new tests.
   The rule in `docs/rules/tui-state.md` said that the accept keeps the message of the failure. After a failed query clear with an accepted search, the accept can queue the build of the next occurrence. That build also restores the disclosures that the failed clear kept, and its result replaces the message when it lands. When that build cannot queue, the view keeps the preview, and `out_of_memory` shows. The rule now says so, and it says that a failed opening keeps the input open (`6b691c0b`).

This round closes the second open finding of the OCR round 6 review: the queued build of the next occurrence replaces `buffer_build_failed`, and the view is right.

Review: a readonly review of `1a8fbac2..HEAD` confirmed that item 1 is not reachable. It also found the `review_snapshot` return unreachable, because the Buffer Search input takes every key, so Review Search cannot open and change its batch. It found no blocking finding. Its low findings are fixed: a rule sentence that was too long and named the wrong cause, a missing rule for a clear whose occurrence build cannot queue, a test that did not check that the accepted search has one occurrence and that the cursor moves, a null unwrap in a test, and an Enforcement sentence without the second Enter key. The wording of two commit messages stays as committed. The docs commit says that the accept queues the occurrence build, but it only can queue it, when the disclosures differ.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_action_errors_test.py` pass.

## OCR round 8

Open Code Review found one item in `c2ae8321`.

1. Valid. The test "M21 kernel a failed Buffer Search opening keeps the input open" pressed the second Enter key only after a failed opening build. After a failed queue of the retry, the test stopped, but the Enforcement text in `docs/rules/tui-state.md` says that the test fails when a second Enter key does not retry the opening. The test now presses the second Enter key in both cases. After the failed queue, it lets memory recover first. It expects an `open_input` build, runs it, and checks that the input closes. A temporary mutation that cleared `restoring_review_disclosures` after the failed queue of the retry made the test fail at the retry command, and `zig build test` exited with 1. No production code changed.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, and `python3 tools/check_doc_symbols.py .` pass.

## OCR round 9

Open Code Review found one item in `91f625b1`.

1. Valid. Two sentences in `docs/rules/tui-state.md` about the Buffer Search accept had more than 20 words and several clauses. A one-time script listed each added sentence of more than 20 words in the changed sections of `docs/rules/tui-state.md`, `CODING_STANDARDS.md`, and `docs/rules/diagnostics.md`. The script counted a quoted test name or a code span as one word. The fix splits each listed sentence into sentences of 20 words or fewer, with the same meaning. The script then listed no sentence, no semicolon, and no em dash. No code changed.

## OCR round 10

Open Code Review found one item in `6c2c926b`.

1. Valid. The Enforcement paragraph of the Review Search source scan rule in `docs/rules/tui-state.md` named the test "M21 kernel Review Search retries a reopened query scan that cannot queue at the next event". Commit `e4d02628` on `main` renamed that test to "Review recovery a Review Search query retry clears its failed scan error". The renamed test still checks each claim of the paragraph. Four temporary mutations in `src/tui/presentation.zig` each made it fail under `zig build test-review-recovery`. The first mutation removed the pending mark at the reopen. The second removed the retry at the next event. The third removed the `needs_scan` mark at the close. The fourth retried a changed query. The doc now names the renamed test.

This was the second doc that named a missing thing, after the missing path of PR #44. Thus `tools/check_doc_symbols.py` now checks each quoted test name of an Enforcement paragraph in `docs/rules/*.md`. The test must exist with that exact name in the `.zig` file that the paragraph names. The error names the doc, the line, the file, and the test. It tells the agent to point at an existing test or to restore the test. The check failed on the stale name before the doc fix. It found no other stale name on this branch. Two paragraphs in `docs/rules/cli.md` quoted only a part of a test name. They now write that part as a code span. `tests/check_doc_symbols_test.py` has new cases for the check. The rule is in `docs/rules/build-and-checks.md`, and `docs/agents/rule-areas.md` points at it.

A readonly review found seven low items. Six are fixed. The check now decodes the `\\` and `\"` escapes of a Zig test name, and it binds a file only after the word `in`. New cases cover the file order, a quote across two lines, and the word `in`. The rule tells the agent to write other quoted text as a code span. Long sentences in the rule, the ticket, and the commit messages are split. The review also found that the check commit fails `zig build test` alone. That order stays, because each red check lands before its fix in this branch. Branch `m30-viewer-scrollbars` has a near copy of the check in `tools/check_agent_docs.py`. Its merge with `main` must keep only one copy.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_doc_symbols_test.py` pass.

## OCR round 11

Open Code Review found five items in the Enforcement test name check of `tools/check_doc_symbols.py`. All five are valid. Each fix has a unit test in `tests/check_doc_symbols_test.py` that failed before the fix.

1. Valid. The check skipped only the opening quote of a CI step name. The closing quote then paired with the next quote. Thus `step "Lint" runs "foo"` read ` runs ` as a test name and did not check `foo`. The check now reads a step quote as one token. After "steps", it also reads a list of step names joined by commas, "and", or "or".
2. Valid. A test name in single quotes or in curly quotes passed without a check. Now such a quote fails, and the error tells the agent to use double quotes. An apostrophe passes. "Step" and "Steps" now count as "step" and "steps".
3. Valid. Each error now ends with "If the quote is not a test name, write it as a code span."
4. Valid. A test name took the next file of the paragraph, also from a later sentence. Now it takes the next file only in its own sentence. Else it takes the last file before it in the paragraph. The rule docs use the earlier file in sentences such as "Other tests in that file", so no rule doc changes. The rule section states where a sentence ends.
5. Valid. `docs/agents/rule-areas.md` now only links to the rule section in `docs/rules/build-and-checks.md`.

A readonly review found two medium items and six low items. A list of quotes after a singular "step" hid the test name after "and". An apostrophe after a code span opened a single quote. Both are fixed with a failing test first. The rule now states the step list, the case of "Step", the apostrophe, and the sentence end. The review also asked for a stricter missing file test and for tests of "!", "?", and a test name with the word "step". Those are added. The review also proposed a sentence end that skips "e.g.". That proposal is not taken, because the rule tells the agent not to write such abbreviations.

Branch `m30-viewer-scrollbars` has a near copy of the check in `tools/check_agent_docs.py`. Its merge with `main` must keep only one copy, with the step token, the quote form error, the sentence limit, and the error text of this round.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_doc_symbols_test.py` pass.

## OCR round 12

Open Code Review found two items in the Enforcement test name check. The check read a test name from the text with blanked code spans, so a correct quote such as "a `b` c" failed. The check now reads the name from the original text. The check also failed a correct doc because an apostrophe opened a single quote. The check now does not read single quotes, and the rule states that only double quotes name a test. Each fix has a unit test that failed before the fix. Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_doc_symbols_test.py` pass.

## OCR round 13

Open Code Review found one item. The Enforcement paragraph of the test name rule in `docs/rules/build-and-checks.md` said that the check fails on a quote in single quotes. The check does not read single quotes since round 12. The paragraph now says that the check fails on a quote in curly quotes. No other doc, tool, test, or PR text says that single quotes fail. Checks: `zig build test` exits with 0. `python3 tools/check_agent_docs.py`, `python3 tools/check_doc_symbols.py .`, and `python3 tests/check_doc_symbols_test.py` pass.

## CodeRabbit round 2

CodeRabbit found seven items in `68fdba72`. The Enforcement test name check of `tools/check_doc_symbols.py` moved out of this ticket to its own PR. The revert commits `93a9bb5f` to `e38ef47e` remove the check, its tests, its rule in `docs/rules/build-and-checks.md`, and its link in `docs/agents/rule-areas.md`. The two code spans in `docs/rules/cli.md` and the renamed test name in `docs/rules/tui-state.md` (`b75c930f`) stay. They are true without the check. The sections of rounds 10 to 13 stay as records of the check.

1. `src/tui/presentation.zig:10094`. Valid. A height change before the restore of a failed scan landed made `acceptBufferDisclosure` reject the geometry of the restore. It then called `retryStaleBufferDisclosure`, which scanned the failed query again. A waiting Enter key could then open a match, and the scan failure disappeared. The test "M21 kernel a restore of a failed Buffer Search scan keeps the failure after a resize" (`b7d13877`) failed with `error.UnexpectedBufferSearchScan`. The fix (`d33e76bc`) sends each stale input build through `retryStaleInputBuild`. A build without a batch is the restore of a failed scan, so it runs `failBufferSearchScan` again. That queues the restore against the current geometry with the same request and the same failure. A query edit still drops the restore, and the test "M21 kernel a query edit drops the restore of a failed Buffer Search scan" still checks that.
2. `src/tui/presentation.zig:10931`. Valid, but not from this branch. `queueAcceptedDisclosure` removes a queued `.cache_update` build and keeps `pending_cache_update`. `main` has the same removal without a reset, so the fault does not come from this branch. It goes to the follow-up list.
3. `src/tui/presentation.zig:10960`. Valid. When the disclosure copy of an accepted disclosure build ran out of memory, `acceptAcceptedDisclosure` showed `out_of_memory` with no record. The test "M21 kernel an Enter key during a failed Buffer Search query clear closes the input" has a new admission case (`aa9682e0`). The user expands a fold first, so the copy allocates. The case failed with `expected 1, found 0` at the record count. The fix (`292ec149`) calls `failDroppedInput`, which writes the one record. The build case of the same test reads no record from Presentation, because the worker boundary writes the record of a failed build. The fix also covers the accepted and restore builds, which `main` left without a record.
4. `src/tui/presentation.zig:13052`. Valid, but not from this branch. A File Enrichment that the path length refuses shows `action_refused` at once, and `queueMaintenanceFileEnrichment` settles it as a success. `main` shows the same refusal at once in `queueFileEnrichment`. It goes to the follow-up list.
5. `tools/check_doc_symbols.py:27`. Not fixed here. The check moved to its own PR.
6. `tools/check_doc_symbols.py:57`. Not fixed here. The check moved to its own PR.
7. `tools/check_doc_symbols.py:94`. Not fixed here. The check moved to its own PR.

Follow-up list:

- Clear `pending_cache_update` when `queueAcceptedDisclosure` removes a queued `.cache_update` build. Until a focus change, the focus check stages no cache update and runs no focused enrichment.
- Do not settle a refused File Enrichment with a too-long path as a success. Defer its `action_refused` for maintenance work.
- The Enforcement test name check, with the three CodeRabbit items above: complete multi-backtick code spans, Zig escape decoding, and file references inside quoted test names.

Review: a readonly review of `68fdba72..HEAD` found no blocking finding. It confirmed that the reverts leave the check files as they were before `cfbe1047`, that only `failBufferSearchScan` queues an input build without a batch, and that the admission fix writes one record. Two low items are fixed: `retryStaleInputBuild` states its batch marker, and two long sentences are split.

Checks: `zig build test` exits with 0. `zig fmt --check src build.zig tests`, `python3 tools/check_agent_docs.py`, `python3 tools/check_action_errors.py`, `python3 tools/check_diagnostics.py`, `python3 tools/check_doc_symbols.py .`, `python3 tests/check_action_errors_test.py`, and `python3 tests/check_doc_symbols_test.py` pass.
