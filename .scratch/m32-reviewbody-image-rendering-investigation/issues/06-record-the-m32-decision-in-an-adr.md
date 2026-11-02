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
  State the fix: `redirect_behavior = .unhandled`, and a loop in bbr that checks the scheme and the host at each hop.
  State that moving the Credential into `privileged_headers` is not a fix, because Zig 0.16 `sendHead` never writes that field (`std/http/Client.zig:990-1073`).
  State that the enforcement is a loopback server test in `src/http/std_client.zig`, not a `FakeHttpClient` test.
  Link the [Credential transport ticket](../../credential-transport-hardening/issues/01-port-the-http-credential-fixes-to-main.md), which owns the fix for the existing API requests.
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
- [ ] The ADR records the redirect finding, the `.unhandled` fix, the `privileged_headers` trap, and the link to the Credential transport ticket.
- [ ] `TODO.md` has the new milestone with `needs M32`, or the ADR states why no milestone follows.
- [ ] Every M32 line in `TODO.md` is checked or has a note.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Required checks

- `python3 tools/check_agent_docs.py`

## Comments

The M32 runner planned the ADR number on 2026-10-31.
`docs/adr/` ends at ADR-0013 on this branch.
The unmerged branches of M27 and M28 both plan ADR-0014.
So the M32 ADR uses ADR-0015.
Check the number again when this ticket runs, and use the next free number if 0015 is taken.

Ticket 03 found a decoder panic in the Zig 0.16 flate decoder on the `zigimg` path.
The ADR must record it in the "Decoding" section, with the decision of ticket 05.

On 2026-11-02, the M32 review fix run corrected the redirect fix in the scope (M32I-2 and M32I-14).
The earlier text let a later run move the Credential into `privileged_headers`, which removes it from every request.
