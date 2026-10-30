# 04: Record the M28 decision in an ADR

Status: ready-for-agent
Blocked by: 03
Spec: [M28 spec](../SPEC.md)

## What to build

An ADR records the M28 File cache decision and its evidence.
The TODO, the README, and ADR-0010 match the decision.

When ticket 03 records `Delay`, ticket 03 adds the comparison and policy tickets to the `Blocked by:` line of this ticket.
This ticket then waits for them.

## Scope

- Add `docs/adr/0014-<slug>.md` with the decision.
  Name the decision: no change, a revised LRU, a full-Review memory cache, or an opt-in disk cache.
- State the evidence in the ADR: the five PullRequests, the run dates and network labels, and the numbers that decide.
  Link tickets 02 and 03.
  Include no source text, File path, query text, or Comment text.
- State in the ADR why the 300 ms threshold meets the reopen condition of M17 ticket 09.
- If the decision is "no change", state the conditions that reopen the decision.
- If the decision changes the policy, mark ADR-0010 as replaced in part by the new ADR.
  Otherwise, leave ADR-0010 unchanged.
- In the M28 section of `TODO.md`, check each line that the evidence proves.
  With "no change", mark the comparison lines as not needed by decision 1 of the brief.
- If the decision changes the policy, update the File cache paragraphs in `README.md` and the glossary entries from the spec.
- Record the changed paths under `## Completion` in this ticket.

## Acceptance criteria

- [ ] The ADR names one decision from the four valid decisions.
- [ ] The ADR states the evidence and links tickets 02 and 03.
- [ ] The ADR holds no source text, File path, query text, or Comment text.
- [ ] The ADR states the reopen conditions, or the replaced part of ADR-0010.
- [ ] `TODO.md` matches the decision.
- [ ] `README.md` and the glossaries match the decision.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig build test --summary all`, if a ticket after 03 changed code.
