# 06: Find each card search owner without a scan of all candidates

Status: needs-triage
Blocked by: none

## Summary

`buildSearchCandidates` in `src/tui/buffer.zig` calls `hasBodyOwner` for each `.comment` and `.draft` row of the semantic Buffer.
`hasBodyOwner` scans every candidate built so far, so the cost is the card rows times the candidates.
A Review with many Comments and about 200,000 source candidates can pay this on each candidate build that ticket 07 cannot reuse, such as a Layout switch.
Nobody measured it. The local workload of ticket 05 has one Draft, so it does not show the cost.

A set of the owners that already have candidates, or a check of the owner of the previous card row, removes the scan.
The design check of ticket 07 found it. It is outside ticket 07.

## Comments

### 2026-11-16 moved for a later PullRequest

The operator moved this ticket out of the enrichment rebuild cascade, where it was ticket 22, so that a later PullRequest owns it.
Ticket numbers in the text above are the numbers of the enrichment rebuild cascade. [The map](../map.md) lists the new numbers.
Take a new baseline at the head of the branch that starts this work.

