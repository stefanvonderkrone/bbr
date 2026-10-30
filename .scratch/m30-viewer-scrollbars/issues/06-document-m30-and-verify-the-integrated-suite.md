# 06: Document M30 and verify the integrated suite

Status: ready-for-agent
Blocked by: 03, 05
Spec: [M30 spec](../SPEC.md)

## What to build

The glossaries, the agent documents, and the README describe the shipped M30 behavior.
The integrated hermetic suite passes with every M30 test.

## Scope

- Apply the glossary changes from the "Glossary changes" section of the spec to the Presentation glossary.
- Add `scroll_marks.zig` to the code entry points in `src/tui/IMPLEMENTATION.md`.
- Add the five M30 rules from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
  Change the text and the enforcement of the rule "A layout tree always declares its scroll bars".
  Add the new glyphs to the enforcement text of the `view_paint.zig` rule.
  Make sure that each named test exists with that exact name.
- Describe the track press and the Scroll Drag in the mouse paragraph of `README.md`.
- In the M30 section of `TODO.md`, check each line that the evidence proves.
  Change the size from S/M to M, as the brief records.
- Run the integrated checks and record the results under `## Completion` in this ticket.

## Acceptance criteria

- [ ] The glossary entries match the spec and use the glossary terms exactly.
- [ ] `src/tui/IMPLEMENTATION.md` names `scroll_marks.zig` and its two functions.
- [ ] `AGENTS.md` has the five M30 rules and the two changed rule texts, and each named test exists.
- [ ] `README.md` documents the track press, the Scroll Drag, and the Scroll Marks.
- [ ] `TODO.md` matches the brief and the shipped behavior.
- [ ] `python3 tools/check_agent_docs.py` passes.
- [ ] `zig fmt --check build.zig src`, `zig build`, and `zig build test-scrollbars` pass.
- [ ] `zig build test --summary all` passes, and the reported test count is higher than before M30.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`
