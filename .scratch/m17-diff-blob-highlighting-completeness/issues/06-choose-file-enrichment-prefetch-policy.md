# Choose the File Enrichment prefetch policy

Type: task
Status: resolved
Blocked by: 01, 02

## Question

What representative measurements compare focused-only demand loading with bounded prefetch during sequential and non-sequential review, and does the measured benefit justify a bounded prefetch policy under the existing inactive File cache budget, independent old/new ownership, and stale Session Epoch rules?

## Answer

Add remote-only, one-File-ahead prefetch after explicit forward sequential navigation. Keep focused-only demand loading as the baseline. Do not prefetch for LocalReviews, initial focus, backward movement, direct File Tree focus, File finding, or mouse focus.

Measurements on 2026-08-22 used 15-run `hyperfine` samples against a public Bitbucket Cloud Repository and 30-run local Git samples in this WorkingCopy:

- One 37 KiB Bitbucket file-content request took `299.3 ms +/- 16.8 ms` (`263.4-341.4 ms`). Two sequential requests for 2.8 KiB and 37 KiB content took `530.6 ms +/- 48.7 ms` (`495.2-655.8 ms`). This matches one modified File's sequential old/new acquisition shape and includes the fresh per-worker client setup used by the current adapter. It does not claim private-Repository, proxy, or authenticated latency because no Bitbucket Credential was available.
- Local `git show` reads took `5.8 ms +/- 0.8 ms` for 10 KiB and `6.5 ms +/- 2.1 ms` for 532 KiB content. A separate old/new sample of the 532 KiB File took `10.0 ms` and `10.6 ms` per side. Local prefetch cannot remove enough visible latency to justify speculative process and Highlighting work.
- A representative forward trace of 20 modified Files with at least `531 ms` reading time per File has about `10.6 s` cumulative remote enrichment lag under focused demand. The selected policy exposes only the initial File and first forward target, about `1.1 s`; the remaining 18 Files enrich during reading time. This is about a 90% reduction with the same 40 content requests when the full trace is reviewed.
- A representative non-sequential trace of 20 direct File jumps does not arm prefetch. It has the same demand latency and request count as today. If a forward trace is interrupted, at most one speculative File continues; there is no cancellable worker contract to pretend otherwise.

The policy contract is:

- An explicit move to the immediately next Diff File arms forward prefetch. After that focused File reaches a terminal File Enrichment state, request only its immediate successor. When an already-enriched prefetched successor becomes focused through the same Action, request its successor immediately.
- Keep at most one speculative File Enrichment in flight. A focus move onto it promotes the existing work to demand and never starts a duplicate. Demand work is never delayed behind speculation.
- Any focus change other than immediate forward navigation disarms further prefetch. An already-running request may complete.
- Disable prefetch when `[files.cache].enabled = false`. With caching enabled, admit a completion through the existing whole-File LRU. The focused File remains excluded from the inactive budget; a speculative inactive File that does not fit is evicted immediately. `max_bytes = 0` retains its existing unlimited meaning.
- Preserve independent old/new acquisition and ownership exactly as defined by ADR-0010. File status still determines which sides exist; M17 binary and unavailable-side rules suppress unsafe work before scheduling.
- Stamp speculative work with the same Session Epoch and WorkId rules as demand work. A replacement Session discards the result. A same-Session focus change may retain it only through the normal inactive File cache policy.
- Prefetch failure stays silent except when the File later becomes focused, when normal per-side status applies. It must not replace the focused File's status message.

The gate is therefore passed only for remote forward traversal. General bounded look-ahead, local prefetch, adaptive prediction, timers, new configuration, and parallel old/new side fetches are not justified by these measurements.
