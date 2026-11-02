# The File cache stays a Session-only, byte-budgeted LRU

M28 asked whether large Reviews need a full-Review File cache in memory or on disk. The decision is "no change". File Enrichment keeps inactive File content in the Session-only, byte-budgeted LRU from [ADR-0010](0010-file-enrichment-transfers-per-side-ownership.md), with the default budget of 256 MiB. bbr gets no full-Review memory cache and no disk cache. The operator made this decision on 2026-11-02.

## Evidence

On 2026-11-02, the operator's agent ran scenario S1 of the File cache benchmark on PullRequest A in `pr-webapp`. PullRequest A has the most Files and the most changed lines of the five benchmark PullRequests. The run used bbr `2026.11.2-0+ge5d60b6f8b3d`, the network label `home-office-vpn-wired`, the default budget, and a dwell time of 1,000 ms. S1 moves through every File once in File Tree order. [Ticket 02](../../.scratch/m28-full-review-file-cache-evaluation/issues/02-run-the-baseline-on-the-five-pullrequests.md) holds the full output.

| Value | Result |
| --- | --- |
| State | Merged |
| `full_review_bytes` | 35,373,616 bytes, which is 33.7 MiB and 13% of the budget |
| `peak_retained_bytes` | 35,373,616 bytes, equal to `full_review_bytes` |
| `refetches` and `enrichment_refetches` | 0 and 0 |
| `requests` | 663, with `failures=0` and `rate_limited=0` |
| `not_found_sides` and `hunk_mismatch_files` | 0 and 0 |

`full_review_bytes` is the memory that a full-Review memory cache needs. The complete Review of the largest benchmark PullRequest uses 13% of the budget. So the LRU never evicts a File of that Review. Inside one Session, a File Jump back to a File and a repeat Review Search can find the content in memory. A larger budget or a full-Review cache adds nothing inside one Session. A cold fetch of the complete Review costs 663 requests. That number is below the Bitbucket limit of 1,000 requests for each user in a rolling hour. [Ticket 03](../../.scratch/m28-full-review-file-cache-evaluation/issues/03-decide-whether-the-current-lru-delays-the-reviewer.md) records the decision.

## Why one S1 run replaced the full benchmark

The [M28 spec](../../.scratch/m28-full-review-file-cache-evaluation/SPEC.md) first planned two runs of scenarios S1 to S8 on five PullRequests, on different days and networks. Each run took 15 to 50 hours. The operator judged that cost too high for the answer. The revisit scenarios S2, S3, S5, and S6 can show a delay only after an eviction. S1 alone shows whether an eviction can happen, because it reports `full_review_bytes`. A Review far below the budget makes those four scenarios unable to show a delay. The benchmark and `tools/m28-baseline-run.sh` stay in the tree for a reopened decision.

The run does not measure S4, S7, and S8. Session replacement and a process restart discard all File content at every budget. Only a carry-over memory cache or a disk cache would remove those refetches. [M17 ticket 09](../../.scratch/m17-diff-blob-highlighting-completeness/issues/09-decide-persistent-file-cache.md) keeps a disk cache out until workflow measurements show a material delay. The footprint run did not test the 300 ms threshold of the M28 brief for a restart or a Session replacement. The operator accepted that gap, and the third reopen condition covers it. The footprint run also does not meet the M17 reopen condition, so a disk cache stays out.

The operator then ran S4 alone on the same PullRequest on 2026-11-02. The cold Review Search did not complete in 2 hours, and the operator stopped it. The process used one CPU core at 100%, and the request rate fell from about 50 to 0 per minute. CPU samples show repeated `SearchProjection.create` work. So the cold start is slow because of CPU work in Review Search, not because of refetches. A disk cache would only hide that work after the first search, so it stays out. [The Review Search bug](../../.scratch/review-search-cold-projection/issues/01-a-cold-review-search-on-a-large-review-never-completes.md) records the evidence. After its fix, run S4 again and apply the reopen conditions.

## Reopen conditions

Reopen this decision when one of these conditions is true:

- A Review has a `full_review_bytes` value that nears the budget. Run S1 of the benchmark on that Review to get the number.
- The default `[files.cache]` budget changes.
- Reviewers report a measured delay after a cold start, a Session replacement, or a process restart.

Then run the scenarios of the M28 spec that match the condition, and apply its delay rule.

## Consequences

The peak RSS of the run was 816 MiB, and the File cache held at most 33.7 MiB. The File cache does not explain the peak. [Ticket 05](../../.scratch/m28-full-review-file-cache-evaluation/issues/05-explain-the-peak-rss-of-the-footprint-run.md) asks for a measurement that splits the RSS by owner. ADR-0010 stays unchanged, because the cache policy does not change.
