# 15 — Eliminate Remaining Buffer Search Input Stalls

**What to build:** Buffer Search input remains responsive on large Pull Requests while opening search, typing rapidly, admitting scan completions, revealing hidden matches, and projecting highlights.

**Blocked by:** 11 — Add Buffer Search.

**Status:** ready-for-agent

- [ ] Add deterministic large-Buffer benchmarks that separately measure opening `/`, query-edit dispatch, worker scanning, completion admission, disclosure rebuilding, range projection, and painting.
- [ ] Record median and p95 latency plus fixture size before changing the implementation, and identify which synchronous stages cause the observed stalls.
- [ ] Query-edit dispatch performs bounded work and never builds the corpus, scans Candidates, clones a complete Batch, rebuilds disclosures, or projects all ranges.
- [ ] Corpus construction is cached, incrementally maintained, or performed as correlated worker work so opening `/` does not stall the terminal loop.
- [ ] Presentation allows at most one Buffer Search scan to consume worker capacity at a time and retains only the newest queued Query generation.
- [ ] Completion admission avoids an unbounded full-Batch clone on the terminal thread. Expensive disclosure and range projection work is staged without publishing a partial Frame.
- [ ] Command id, Session Epoch, and Query generation reject stale work. Cancellation, refresh, Review switching, shutdown, launch failure, and allocation failure release every Query, corpus reference, Batch, and staged projection.
- [ ] `Enter` while work is pending accepts only the newest completed generation. `Esc`, `n`, `N`, Count, active-occurrence retention, hidden-match reveal, and status reset keep their existing behavior.
- [ ] Presentation and runtime tests cover rapid edits before and after worker launch, stale completion ordering, cancellation, failure, and Session replacement.
- [ ] The benchmark demonstrates materially lower p95 input latency on the large fixture, and `zig build test --summary all` passes.

## Baseline

`zig build bench-buffer-search` on `4b967b3`, ReleaseFast, 16 Files, 4,096 changed Lines, 63,240 Diff bytes, nine samples. Values are nanoseconds. The disclosure measurement includes Buffer rebuilding and range projection. Painting is not yet measured.

| Stage | Median | p95 |
| --- | ---: | ---: |
| Open `/` | 7,635,584 | 8,654,375 |
| Query edit | 5,291 | 22,875 |
| Worker scan | 44,682,917 | 47,385,334 |
| Completion admission | 92,566,416 | 94,588,583 |
| Disclosure rebuild | 98,758,708 | 101,908,584 |
| Range projection | 90,738,625 | 142,183,125 |

Opening builds the corpus on the terminal thread. Completion admission and disclosure rebuilding both project the entire Batch. Range projection scans every visual row for each Search Occurrence.

The baseline preceded the painting stage in the benchmark. The current benchmark measures headless painting on a 100 × 30 screen.

## Current measurement

Same fixture and nine samples, after caching the corpus with the staged Buffer and indexing source rows during projection:

| Stage | Median | p95 |
| --- | ---: | ---: |
| Open `/` | 13,667 | 66,541 |
| Query edit | 16,792 | 27,042 |
| Worker scan | 45,697,292 | 47,291,833 |
| Completion admission | 1,419,167 | 1,524,083 |
| Disclosure rebuild | 9,340,666 | 9,966,084 |
| Range projection | 463,417 | 490,208 |
| Headless painting | 55,125 | 81,958 |

The corpus cache moves its build cost to Session publication and Buffer rebuilding. Disclosure rebuilding still runs on the terminal thread. The benchmark uses a 4,096-Line fixture, so it does not set a bound for larger Sessions. The baseline has no painting sample.
