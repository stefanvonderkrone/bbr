# 06: Document M29 and verify the integrated suite

Status: ready-for-agent
Blocked by: 05
Spec: [M29 spec](../SPEC.md)

## What to build

The glossaries, the agent documents, and the README describe the shipped M29 behavior.
The integrated hermetic suite passes with every M29 test.

## Scope

- Apply the glossary changes from the "Glossary changes" section of the spec.
  Edit the Presentation glossary and `GLOSSARY-MAP.md`.
- Add `comment_overview.zig` to the code entry points in `src/tui/IMPLEMENTATION.md`.
- Add the five M29 rules from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
  Change the text of the File Jump rule and the File Tree cursor rule as the spec describes.
  Make sure that each named test exists with that exact name.
- Describe `g o`, `g d`, the Comment Overview keys, the File Tree Filter, and the Action names in `README.md`.
- In the M29 section of `TODO.md`, check each line that the evidence proves.
  Mark "Show nearby source Lines for an inline item" as deferred by decision 8 of the brief.
- Run the integrated checks and record the results under `## Completion` in this ticket.

## Acceptance criteria

- [ ] The glossary entries match the spec and use the glossary terms exactly.
- [ ] `src/tui/IMPLEMENTATION.md` names `comment_overview.zig` and its two builds.
- [ ] `AGENTS.md` has the five M29 rules and the two changed rule texts, and each named test exists.
- [ ] `README.md` documents every new default key and Action name.
- [ ] `TODO.md` matches the brief and the shipped behavior.
- [ ] `python3 tools/check_agent_docs.py` passes.
- [ ] `zig fmt --check build.zig src`, `zig build`, and `zig build test-comment-overview` pass.
- [ ] `zig build test --summary all` passes, and the reported test count is higher than before M29.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`
