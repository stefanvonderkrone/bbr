# 16: Keep a Buffer Search move into hidden text after a rebuild

Status: resolved
Blocked by: none

## Summary

A Buffer Search `n` or `N` to a match that is hidden, for example in a collapsed fold or a collapsed disclosure, queues an `.accepted` or `.restore` build.
When another Buffer rebuild is admitted before that build ends, the build is not dropped.
The Presentation retries it.
But the retry keeps the occurrence index of the old accepted batch and uses it in the rebuilt batch.
When the rebuild added or removed occurrences before the target, the move lands on another match.

A reproducing test shows the effect.
The user presses `n` to go forward to a hidden reply, and the cursor goes back to an earlier source line.
The status shows that earlier match as current.

## Evidence

All paths are in `src/tui/presentation.zig`. The evidence is from commit `62d0ac3`.

### The drop that the first reading suspected does not occur

The first reading suspected this check in `acceptAcceptedDisclosure`, which returns with no retry and no message:

```zig
if (current == null or snapshot.occurrences.ptr != current.?.occurrences.ptr) return;
```

An earlier check in the same function catches every admitted Buffer rebuild first:

```zig
if (!published.disclosure_inputs_current or job.inputs != published.disclosure_inputs or job.frame_revision != published.visual_rows_revision or ...) {
    self.retryAcceptedDisclosure(published, job);
    return;
}
```

`acceptViewBuild` sets `visual_rows_revision` on each admission.
`DisclosureBuild.create` copies `visual_rows_revision` into `frame_revision`.
So each admission that replaces `accepted_batch` also makes the `frame_revision` check fail, and the build is retried.

The order of the builds limits when the case can occur.
`takeCommand` issues one `build_buffer_disclosure` at a time, in queue order.
A hidden `n` increments `search_generation`, so an `.enrichment` build that already runs is rejected by its `request_id` check and is retried behind the `.accepted` build.
But an `.enrichment` build that waits in the queue ahead of the `.accepted` build gets a new `request_id` from `refreshEnrichmentBuild` when it is issued.
That build is admitted first, and then the `.accepted` build is retried.

### The retry keeps the old index

`retryAcceptedDisclosure` passes `job.destination_active` and `job.target` unchanged to `queueAcceptedDisclosure`.
The new build copies the current accepted batch into `accepted_snapshot`.
So the index of the old batch now selects an occurrence of the new batch.
`job.target` still holds the disclosures of the old occurrence.
`acceptViewBuild` maps the published current occurrence with `retainedSearchIndex`, but nothing maps the destination of a waiting build.

At admission, `acceptAcceptedDisclosure` reads `rows[index]` and `current.?.occurrences[index]` without a bounds check.
A rebuilt batch that is shorter than the old index can therefore read out of bounds.
This is inferred from the code. No test made a batch shorter.

### Throwaway test

A throwaway test in a detached worktree drove `Presentation` through these steps:

1. Make a Session with two Files.
   File `0.txt` has two hunks with a gap of unchanged lines that contain `zz`.
   File `a.txt` has a resolved Thread with the reply `fixed zz` and an open comment `open zz`.
2. Change the scope to Whole File with `cycle_scope`.
   Before File Enrichment, File `0.txt` has no source occurrences.
3. Accept the Buffer Search `zz`. The batch has 2 occurrences, both review bodies.
4. Deliver the File Enrichment of File `0.txt`. Its `.enrichment` build waits in the queue.
5. Press `n`. A `.restore` build to occurrence 1 waits behind the `.enrichment` build.
6. Run the builds in queue order.

Results at `62d0ac3`:

| Step | Admitted | Current occurrence | Occurrences |
| --- | --- | --- | --- |
| `.enrichment` build | yes | 4 | 6 |
| `.restore` build | no, retried | 4 | 6 |
| retried `.restore` build | yes | 1 | 6 |

The target was the reply on visual row 15.
After the builds, the current occurrence is the source line `zz1` on visual row 3, and the cursor is on row 3.
No message appears.

The same steps in the Changes scope, with the hidden fold matches of `testDisclosureSession` (`c`, then `4n` for `.accepted` and `2N` for `.restore`), land on the correct match.
There, File Enrichment does not change the occurrences, so the old index is still correct.

### Live run

A ReleaseFast build of `62d0ac3` with temporary `[DEBUG-t16]` logs ran `bbr local` on the two commits of ticket 04 at 160 × 80 with an empty state directory.
Each run pressed `n` 200 times at 0.1 second intervals.

| Scope | Query | Final match | Retried `.accepted` or `.restore` builds | Silent drops | `.accepted` or `.restore` admissions |
| --- | --- | --- | --- | --- | --- |
| Changes | `return` | 201/6522 | 0 | 0 | 0 |
| Fetched | `return` | 201/6522 | 0 | 0 | 0 |
| Whole | `return` | 1/1 | 0 | 0 | 0 |
| Whole | `e` | 201/1542 | 0 | 0 | 0 |

The runs did not reach a hidden match, so they neither show nor exclude the wrong landing.
This local Review has no comments, and its first 201 matches are visible.
The live workload is not a good reproduction of this ticket. The throwaway test is the evidence.

### Other silent returns in `acceptAcceptedDisclosure`

- `job.request_id != published.search_generation`: a later search move replaced the build. Dropping it is correct.
- `.clear_input` input checks and `published.buffer_search.input != null`: the user opened the Buffer Search input. Dropping it is correct.
- The accepted snapshot pointer check: as described above, only a batch replacement that does not change `visual_rows_revision` reaches it, for example `acceptBufferSearch` with a new query. Dropping it is correct, because the new query replaces the move.
- `const review = published.review_search.batch orelse return;`: when the Review Search query is cleared while the build runs, the `n` is dropped with no message. The branch for a changed Review Search batch retries instead. This is a minor inconsistency and is out of scope.

`acceptBufferDisclosure` and `acceptViewBuild` retry on every stale check.

## What to build

1. In `retryAcceptedDisclosure`, map a non-null `job.destination_active` into the current accepted batch before it queues the replacement:
   `retainedSearchIndex(job.accepted_snapshot, job.destination_active, current)`.
   This is the rule that `acceptViewBuild` already uses for the published current occurrence.
   An exact match keeps the same occurrence.
   When the occurrence is gone, `retainedSearchIndex` gives the nearest index that is in bounds.
   A null destination stays null.
2. A retried traversal move recomputes its disclosures for the mapped occurrence.
   Move the end of `traverseBufferSearchBy`, from the `saved_disclosures == null` check on, into `openBufferSearchOccurrence(published, index, status)`.
   `traverseBufferSearchBy` calls it with the wrap status.
   `retryAcceptedDisclosure` calls it for an `.accepted` or `.restore` build whose `restore_navigation` is null, with `job.result_error` as the status.
   Then a mapped occurrence that is now visible gets a direct jump with no build, and a hidden occurrence gets the disclosures that it needs.
   Other kinds, such as the `.restore` of `cancelBufferSearch` and `.clear_input`, keep their `target` and only map the index.

A sketch of steps 1 and 2 changed about 20 lines.
The throwaway test failed before the sketch and passed after it, and `zig build test` passed with the sketch.

### Overlap with ticket 15

[Ticket 15](15-carry-the-search-destination-in-the-build-kind.md) asks whether `DisclosureBuild.Kind` should carry its destination.
This fix does not need ticket 15.
But a Kind that carries the target occurrence, and that separates a traversal move from the `.restore` of a cancel, would replace the `restore_navigation == null` test of step 2.
If ticket 15 lands first, step 2 uses that Kind instead.

## Acceptance criteria

- [x] A test through `Presentation` reproduces the Whole File case above.
  A File Enrichment build waits ahead of a hidden `n`, and its admission adds occurrences before the target.
  After the builds, `buffer_search.active` is the target occurrence, compared with `searchOccurrenceEql` against the batch before the `n`, and the cursor is on the visual row of that occurrence.
  The test fails at `62d0ac3`, where the move lands on occurrence 1 and visual row 3.
- [x] The same test with the hidden fold matches of `testDisclosureSession` passes for an `.accepted` move (`4n`) and a `.restore` move (`2N`).
- [x] A test removes the target occurrence with a rebuild that is admitted before the retried build, for example a Draft deletion.
  The move ends on an occurrence that is in bounds, its disclosures are open, and the cursor is on its visual row.
- [x] A retried build with a null destination, such as the `.restore` of `cancelBufferSearch` with no current occurrence, still has a null destination.
- [x] `zig build test` passes.

## Completion

Commits:

- `3829400` tui: reproduce Buffer Search moves retried after a rebuild.
- `132d933` tui: map a retried Buffer Search move into the rebuilt batch.

### Change

`retryAcceptedDisclosure` maps a non-null `destination_active` into the current accepted batch with `retainedSearchIndex`.
A null destination stays null, and a null accepted batch gives a null destination.
The end of `traverseBufferSearchBy` is now `openBufferSearchOccurrence(published, index, status)`.
A retried `.accepted` or `.restore` build with no `restore_navigation` and a mapped destination calls it with `job.result_error`.
So a mapped occurrence that is now visible gets a direct jump, and a hidden one gets its disclosures computed again.
Every other kind keeps its `target` and only maps the index.
The fields that the reopen does not copy, such as `clear_saved_disclosures` and `restore_search_disclosures`, are set only by `.open_input`, `.clear_input`, `.general`, and the `.restore` of `cancelBufferSearch`, so a traversal move never has them.
`job.keepPlans()` is still the first statement in `acceptBufferDisclosure`.

### Tests

- "M21 kernel Buffer Search retries a hidden reply move after Whole File enrichment adds earlier matches" covers criterion 1.
  It failed at `3829400` on the identity check: the batch had 6 occurrences, and the move landed on a source match.
- "M21 kernel Buffer Search retries a hidden move after an isolation removes its target" covers criterion 3.
  It failed at `3829400` with `panic: index out of bounds: index 1, len 1` in `acceptAcceptedDisclosure`, so the out-of-bounds read of the triage is now shown, not only inferred.
- "M21 kernel Buffer Search retries hidden fold moves after Changes enrichment" covers criterion 2 (`4n` for `.accepted`, `2N` for `.restore`). It passes before and after the fix.
- "M21 kernel Buffer Search retries null destinations after enrichment without selecting a match" covers criterion 4 for the `.restore` of `cancelBufferSearch` and of `clearBufferSearchActive`.

The criterion suggested a Draft deletion to remove the target.
A Draft deletion cannot do it: its build has a stale `request_id` after the `n`, so `acceptViewBuild` retries it behind the move.
An isolation can, because `acceptViewBuild` admits a `.view` build by `pending_view`, not by `search_generation`.
The Draft deletion run found a separate gap, filed as [ticket 17](17-keep-the-buffer-search-current-occurrence-visible-after-it-is-removed.md).

No live run: the local Review of the triage has no comments, and its live runs never reached a hidden match.

### Checks

- `zig build test --summary all`: exit 0, 52/52 steps, 1644/1644 tests.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.
- `python3 tools/check_benchmark_metrics.py`: pass.
- `python3 tools/check_diagnostics.py`: pass.

### Review

A two-axis code review found no hard violation and no scope creep.
The Standards review asked to rename the parameter `next` of `openBufferSearchOccurrence` to `index`, and the fix commit does that.
It flagged the kind test `(.accepted or .restore) and restore_navigation == null` as a second list beside `Kind.opensOccurrence`. Ticket 15 owns that shape, and a comment there records it.
It flagged the queue-order preconditions in the two guard tests as tied to the implementation. They stay, because they prove that the guard reaches the retry.
The Spec review confirmed the Draft deletion reasoning and found the empty-batch case, which ticket 17 records.

### Mistake class

Candidate: an occurrence index outlives the batch that it was computed for.
Six places map a stored index into a new batch correctly: `acceptViewBuild` for `buffer_search.active`, the input batch for `input.active`, Review Search for `selected` and for the range `occurrence_index` values, the identity check and reopen of `.review_destination`, and the rescan of an `.input` retry.
Only this retry did not, since commit `45ddc6e`.
One case does not make a class, so this ticket adds no check and no rules row.

## Comments

### 2026-11-14, triage

Decision: `ready-for-agent`.

The suspected silent drop does not occur.
The `frame_revision` check in `acceptAcceptedDisclosure` retries the build before the snapshot pointer check, because each admitted Buffer rebuild sets `visual_rows_revision`.
A throwaway test confirmed the retry in the Changes scope for `.accepted` and `.restore` moves into a collapsed fold, and both landed on the correct match.

The test found a different defect in the same retry.
The retry reuses the occurrence index of the old batch.
In the Whole File scope, File Enrichment adds occurrences, and an `n` toward a hidden reply ended on an earlier source line instead.
The status showed the wrong match and no message appeared.
A sketch that maps the index with `retainedSearchIndex` and reopens the occurrence through the traversal fixed the test, and `zig build test` passed with the sketch.

Four live runs with `n` held did not reach a hidden match.
They had no retried and no dropped `.accepted` or `.restore` build, so the live workload does not show the defect.

The runner rewrote the ticket around the stale index and listed the other silent returns.
Ticket 15 overlaps only in how a traversal move is told apart from a cancel.

The probe worktrees, the logs, and the state directory are deleted.
