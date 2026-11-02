# 04: Record the M28 decision in an ADR

Status: resolved
Blocked by: 03
Spec: [M28 spec](../SPEC.md)

## What to build

An ADR records the M28 File cache decision and its evidence.
The TODO, the README, and ADR-0010 match the decision.

When ticket 03 records `Delay`, ticket 03 adds the comparison and policy tickets to the `Blocked by:` line of this ticket.
This ticket then waits for them.

## Scope

- Add `docs/adr/<next free number>-<slug>.md` with the decision.
  Use the next free ADR number when this ticket runs. M27 keeps ADR-0014.
  Name the decision: no change, a revised LRU, a full-Review memory cache, or an opt-in disk cache.
- State this evidence in the ADR:
  the PullRequest, the run date and network label, and the numbers that decide.
  Since 2026-11-02, the evidence is the footprint run on PullRequest A, not runs on five PullRequests.
  Link tickets 02 and 03.
  Include no source text, File path, query text, or Comment text.
- State in the ADR why the 300 ms threshold meets the reopen condition of M17 ticket 09.
  With the footprint rule, state how the M28 evidence relates to that reopen condition.
- If the decision is "no change", state the conditions that reopen the decision.
- If the decision changes the policy, mark ADR-0010 as replaced in part by the new ADR.
  Otherwise, leave ADR-0010 unchanged.
- In the M28 section of `TODO.md`, check each line that the evidence proves.
  With "no change", mark the comparison lines as not needed by decision 1 of the brief.
- If the decision changes the policy, update the File cache paragraphs in `README.md` and the glossary entries from the spec.
- Record the changed paths under `## Completion` in this ticket.

## Acceptance criteria

- [x] The ADR names one decision from the four valid decisions.
- [x] The ADR states the evidence and links tickets 02 and 03.
- [x] The ADR holds no source text, File path, query text, or Comment text.
- [x] The ADR states the reopen conditions, or the replaced part of ADR-0010.
- [x] `TODO.md` matches the decision.
- [x] `README.md` and the glossaries match the decision.
- [x] `python3 tools/check_agent_docs.py` passes.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig build test --summary all`, if a ticket after 03 changed code.

## Comments

2026-11-01: The ADR number is no longer fixed.
M27 keeps ADR-0014, so this ticket takes the next free number when it runs.
The merge plan for all branches records this choice.

2026-11-01: Review finding M28-7. No baseline and no ADR exist yet, and this ticket must not invent either.
The order is fixed. A human does the live runs of ticket 02. Ticket 03 then decides on the recorded results.
Only then does this ticket write the ADR, with the next free ADR number at that time.
The pull request of the M28 branch claims only ticket 01.

## Completion

[ADR-0016](../../../docs/adr/0016-file-cache-stays-a-session-only-lru.md) records the decision "no change".
The number is 0016, because M27 holds ADR-0014 and M32 holds ADR-0015 on unmerged branches.
On 2026-11-02, `docs/adr/` on this branch, on `origin/m27-zig-builtin-grammar`, and on `origin/m32-reviewbody-image-rendering-investigation` had no ADR-0016.

- The ADR states the decision and the evidence of the footprint run.
  It also states the reason for the method change and the reopen conditions.
- The ADR names PullRequest A only by its letter. It holds no PullRequest id and no File count.
- `tools/check_agent_docs.py` now scans `docs/adr/` for live PullRequest ids, like `.scratch/`.
- ADR-0010 stays unchanged, because the cache policy does not change.
- `README.md` and the glossaries stay unchanged for the same reason.
- `TODO.md` checks the M28 lines that the evidence proves and marks the two comparison lines as not needed.
- `docs/code-navigation.md` names the benchmark as a tool for a reopened decision.

Checks: `python3 tools/check_agent_docs.py` passes. `zig build test --summary all` and `zig fmt --check build.zig src tests` pass.
Changed paths: `docs/adr/0016-file-cache-stays-a-session-only-lru.md`, `TODO.md`, `docs/code-navigation.md`, the M28 spec, and this ticket.
