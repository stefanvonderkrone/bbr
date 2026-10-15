# Agree the M26 completion contract

Label: wayfinder:map

## Destination

An agreed M26 completion contract with each open decision resolved in its own ticket.
Implementation can then finish Credential login and logout without guessing at input, source, storage, status, or acceptance rules.

## Notes

- This map plans M26. Implementation remains follow-up work.
- The user confirmed the destination and the five decision areas in this conversation.
- Read the M26 section of [TODO.md](../../TODO.md) for requirements and verification evidence.
- Read [the context map](../../CONTEXT-MAP.md) and [the Bitbucket glossary](../../src/bitbucket/CONTEXT.md). Use Credential, Profile, Active Profile, Workspace, and Authenticated Account consistently.
- Consult `grilling` and `domain-modeling` for each decision. Use `technical-writing` and `unslop` for recorded answers. Consult `zig` when checking code facts.
- TOML storage is accepted. Preserve named Profiles unless a later user decision changes them.
- Account and Workspace validation already exist. Missing login integration tests do not mean validation is absent.
- Command grouping includes status. The status-output ticket refines that command rather than introducing a separate feature.
- Command, documentation, and test implementation remains in the [single M26 handoff](file:///var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/m26-auth-handoff.md). It is a session-local file. Decision answers override assumptions in that handoff.
- Relate work to the original ten-item review table through each ticket's coverage note.
- Use the [local tracker operations](../../docs/agents/issue-tracker.md#wayfinding-operations). Find open tickets in `issues/`, ordered by filename. Do not list them on this map.
- Each ticket has only a `wayfinder:` label. `Status: open` means unclaimed. Set `Status: claimed` before working a ticket.
- Resolve at most one decision per session. Append its answer under `## Answer`, set `Status: resolved`, and add a named link below.
- Keep Credential values and private account data out of tracker artifacts. Use synthetic examples only.

## Decisions so far

No tickets resolved in this map yet. Previously accepted facts remain in the referenced milestone and conversation.

## Not yet specified

The effect of the combined decisions on existing Profile-based automation is not yet clear.
Revisit that transition after the input, source, and storage policies are settled.
Create another decision ticket only if the combined contract leaves a concrete question unanswered.

## Out of scope

- Implementing auth commands, documentation, or tests while charting this map.
- Migrating accepted TOML storage to JSON.
- Adding a native credential-store adapter.
- Revoking Atlassian API tokens through logout.
- Browser work, LocalReview expansion, and other milestones.
