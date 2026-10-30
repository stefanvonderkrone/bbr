# 06: Record the M32 decision in an ADR

Status: ready-for-agent
Blocked by: 05
Spec: [M32 spec](../SPEC.md)

## What to build

An ADR records the M32 image decision and its evidence.
`TODO.md` gets the implementation milestone, or the ADR states why no milestone follows.

## Scope

- Add `docs/adr/<next free number>-<slug>.md`.
  Check the number when this ticket runs, because the M28 spec plans ADR-0014.
- Write every section from the "Decision document" section of the spec.
- Link the research notes of tickets 01 and 02.
  Link the evidence of ticket 04 and the answer of ticket 05.
- Record the redirect finding from the spec: `StdHttpClient` keeps the Credential on a redirect to another host.
  State that a later milestone must fix it for the existing API requests.
- Propose the glossary terms from the "Glossary changes" section of the spec that the decision keeps.
  Do not change a glossary in this ticket.
- Propose the new AGENTS.md rules from the spec that the decision keeps.
  Do not change `AGENTS.md` in this ticket.
- Follow the "Handoff to the implementation milestone" section of the spec.
  Add the new milestone to `TODO.md` with the next free number, or record the reopen conditions in the ADR.
  Add the new milestone to the "Sequencing at a glance" block.
- In the M32 section of `TODO.md`, check each line that the evidence proves.
- Record the changed paths under `## Completion` in this ticket.

## Acceptance criteria

- [ ] The ADR has every section that the spec names.
- [ ] The ADR names one decision and links the evidence of tickets 01, 02, 04, and 05.
- [ ] The ADR holds no real image URL, no Comment text, and no Credential value.
- [ ] The ADR records the redirect finding and the follow-up.
- [ ] `TODO.md` has the new milestone with `needs M32`, or the ADR states why no milestone follows.
- [ ] Every M32 line in `TODO.md` is checked or has a note.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Required checks

- `python3 tools/check_agent_docs.py`
