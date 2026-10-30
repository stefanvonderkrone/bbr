# 03: Decide whether the current LRU delays the reviewer

Status: ready-for-human
Blocked by: 02
Spec: [M28 spec](../SPEC.md)

## What to build

A human applies the stop rule from the spec to the baseline results of ticket 02.
The human records one outcome: `No delay` or `Delay`.
This is a decision checkpoint, so an agent cannot close it.

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

- [ ] `## Answer` names the outcome and quotes the numbers that decide it.
- [ ] `## Answer` names each PullRequest and scenario that shows a delay, or states that none does.
- [ ] `## Answer` records how a failed merged PullRequest check affects the decision, if one failed.
- [ ] With `Delay`, `## Answer` names the remaining candidates and the reason for each dropped candidate.
- [ ] With `Delay`, the new tickets exist from 05, and ticket 04 lists them in `Blocked by:`.
- [ ] `python3 tools/check_agent_docs.py` passes.
