# Select P2 actions from the post-P1 profile

Type: grilling
Status: resolved
Blocked by: 14, 15, 16, 17, 18, 19, 20, 21

## Question

Which P2 experiments have enough profile evidence after P0 and accepted P1 work, and which actions should close without implementation?

## Comments

The post-P1 ReleaseFast benchmarks measured 12,578,375 ns for 100 KiB JavaScript Highlighting, 913,664,208 ns for 2 MiB JavaScript Highlighting, 4,171,000 ns for a wrapped 50,000-row Presentation Frame, and 2,327,583 ns for painting 1,000 rows. Checksums stayed stable. Paint made no allocations and remained instruction-throughput-bound.

The read-only live acquisition profile used the existing bounded two-request pool. PullRequest 1856 fell from 2,546 ms sequential to 1,758 ms bounded, a 30% reduction. PullRequest 1726 fell from 2,315 ms to 1,389 ms, a 40% reduction. Both runs used at most two connections and reported no failures or rate limits.

## Answer

Actions 20, 21, 22, and 23 pass the P2 evidence gate.

- Action 20 targets material Highlighting latency, where query cursor work remains hot.
- Action 21 targets material Presentation Frame and paint work while preserving complete Frame publication.
- Action 22 targets material instruction-bound paint work after the VisualRow compaction.
- Action 23 has live Bitbucket evidence that bounded concurrent requests cut read latency by 30% to 40% without failures or rate limits.

Actions 19 and 24 fail the gate.

- Action 19 has no profile evidence that parser or query cursor setup is a material share of warm Highlighting time. Parsing and query execution are the measured costs.
- Action 24 has no current hot stack with a material scalar `memset` cost. The only earlier `_platform_memset` sample sat below Buffer work that P1 later removed.
