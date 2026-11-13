# 13: Find why a switch to SideBySide costs three times more

Type: research
Status: open
Blocked by: none

## Question

Why does a rebuild after a switch to SideBySide cost about three times more worker CPU than a rebuild after a switch to Unified, and which changes would close most of the gap?

## Context

[Ticket 11](11-build-the-buffer-rows-without-copies.md) measured these medians at commit `f900968` on the workload of [ticket 05](05-make-a-buffer-rebuild-faster.md):

| Rebuild | Worker CPU, median |
| --- | --- |
| Switch to Unified | 109 ms |
| Switch to SideBySide | 322 ms |

Tickets 05 and 11 cut the Unified rebuild by about 68 %, but the SideBySide rebuild by only about 44 %.
The SideBySide rebuild now costs about 213 ms more than the Unified rebuild.

The known parts of the gap:

- The SideBySide change block matching is about 55 % of a SideBySide switch, according to the triage of [ticket 08](08-make-the-side-by-side-change-block-matching-cheaper.md).
- A SideBySide rebuild runs the matching twice: once for the Buffer and once for the search candidate Buffer of [ticket 07](07-build-the-search-candidates-without-a-second-buffer.md).

Nobody measured the rest of the gap at the current commit.
The other phases, such as the visual rows for line pairs, the search projection, and the corpus, have no SideBySide measurement of their own.

## What to find

1. A phase breakdown of the worker CPU for a switch to SideBySide and a switch to Unified at the current commit, with a CPU profile of the rebuild worker. Report the medians, the spread, and the machine load.
2. The share of the gap for each phase, and the share that tickets 07 and 08 remove according to their prototypes or a new measurement.
3. Whether a Layout switch must rebuild everything it rebuilds today. For example, the matching result does not depend on the Layout geometry, so a later switch or a resize could reuse it.
4. A ranked list of changes with an estimated saving for each. Each estimate is labeled as measured with a prototype, or as a guess.

## Deliverable

A dated `## Comments` entry in this ticket with the evidence, the ranked list, and a proposed target for a switch to SideBySide.
Proposed child tickets go in the text of the comment. Tickets 07 and 08 get a note when the findings change their scope or target.

## Comments
