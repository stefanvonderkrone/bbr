# 03: Decide whether the current LRU delays the reviewer

Status: resolved
Blocked by: 02
Spec: [M28 spec](../SPEC.md)

## What to build

A human applies the stop rule from the spec to the results of ticket 02.
The human records one outcome: `No delay` or `Delay`.
This is a decision checkpoint, so an agent cannot close it.

Since 2026-11-02, the stop rule is the footprint rule of the spec.
The LRU stays when `full_review_bytes` of the largest PullRequest is well below the budget.
The steps below name the delay rule of the full baseline.
They apply only if the footprint rule decides nothing.

## Steps

1. Read the output and the `summarize` outcome under `## Completion` in ticket 02.
2. Check the outcome against the "Stop rule" section of the spec.
   A refetch adds more than 300 ms p95 to a Visible Action, or a repeat Review Search refetches.
3. If a merged PullRequest failed the merged PullRequest check, decide whether its numbers count.
   Record the reason.
4. Record the outcome and the scenarios that show a delay under `## Answer` in this ticket.

If the outcome is `No delay`:

1. Record that M28 compares no candidate.
2. Ticket 04 records "no change" in an ADR.

If the outcome is `Delay`:

1. Drop each candidate in the "Candidate policies" section that cannot remove the measured delay.
   For example, a delay only in S8 leaves only C3.
2. Write the comparison and policy tickets from the "Conditional work" section of the spec.
   Number them from 05.
3. Add the new ticket numbers to the `Blocked by:` line of ticket 04.

## Acceptance criteria

- [x] `## Answer` names the outcome and quotes the numbers that decide it.
- [x] `## Answer` names each PullRequest and scenario that shows a delay, or states that none does.
- [x] `## Answer` records how a failed merged PullRequest check affects the decision, if one failed.
      No check failed.
- [x] With `Delay`, `## Answer` names the remaining candidates and the reason for each dropped candidate.
      Not needed, because the outcome is `No delay`.
- [x] With `Delay`, the new tickets exist from 05, and ticket 04 lists them in `Blocked by:`.
      Not needed, because the outcome is `No delay`.
      Ticket 05 is a research ticket about the peak RSS, not a comparison ticket.
- [x] `python3 tools/check_agent_docs.py` passes.

## Answer

The operator decided on 2026-11-02.
The outcome is `No delay`, and the decision is "no change".
The Session-only, byte-budgeted LRU with the default of 256 MiB stays.
M28 adds no full-Review memory cache and no disk cache, and it compares no candidate.

The footprint rule decides.
The footprint run in [ticket 02](02-run-the-baseline-on-the-five-pullrequests.md) gives these numbers for PullRequest A:

- `full_review_bytes=35373616`. The full Review needs 33.7 MiB, which is 13% of the 256 MiB budget.
- `peak_retained_bytes=35373616`, equal to `full_review_bytes`. So the LRU evicted no File.
- `refetches=0`, `enrichment_refetches=0`, and `added_delay_p95_ms=0.0`.
- `failures=0` and `rate_limited=0`. The 6 retries were `HttpConnectionClosing` errors, and each one succeeded on its first retry.
- `not_found_sides=0` and `hunk_mismatch_files=0`, so the merged PullRequest check passed.

The full Review fits in 13% of the budget, so the LRU never evicts a File of PullRequest A.
So S2, S3, S5, and S6 cannot refetch after an eviction, and no PullRequest or scenario shows a delay.
`low_samples=true` follows from this result, because S1 had no refetch sample.

The run did not measure S4, S7, and S8.
Session replacement and a process restart refetch every File at every budget.
A cold full fetch of PullRequest A costs 663 requests.
That number is below the Bitbucket limit of 1,000 requests for each user in a rolling hour.
The operator accepted that gap, so this ticket keeps the M17 no-go for a disk cache.
The ADR from [ticket 04](04-record-the-m28-decision-in-an-adr.md) names the conditions that reopen the decision.

## Completion

The operator made the decision, and an agent recorded it on 2026-11-02.
`python3 tools/check_agent_docs.py` passes.
Changed paths: this ticket.

## Comments

2026-11-01: Review finding M28-7. No baseline exists yet.
This ticket starts only after a human records the live runs of ticket 02.
Ticket 04 writes the ADR only after this ticket records its outcome.
