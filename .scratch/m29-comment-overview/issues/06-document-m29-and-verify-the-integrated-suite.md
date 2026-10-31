# 06: Document M29 and verify the integrated suite

Status: resolved
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

- [x] The glossary entries match the spec and use the glossary terms exactly.
- [x] `src/tui/IMPLEMENTATION.md` names `comment_overview.zig` and its two builds.
- [x] `AGENTS.md` has the five M29 rules and the two changed rule texts, and each named test exists.
- [x] `README.md` documents every new default key and Action name.
- [x] `TODO.md` matches the brief and the shipped behavior.
- [x] `python3 tools/check_agent_docs.py` passes.
- [x] `zig fmt --check build.zig src`, `zig build`, and `zig build test-comment-overview` pass.
- [x] `zig build test --summary all` passes, and the reported test count is higher than before M29.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-comment-overview`
- `zig build test --summary all`

## Comments

- The documents describe the shipped behavior where it differs from the spec. `g f` and the File Finder work in the Comment Overview. A File Finder choice shows the DiffPane before the File Jump. The Review Search route closes Review Search only after the Comment Overview shows.
- The test "M29 overview an allocation failure in the Review Search route keeps the previous Frame and Review Search" in `src/tui/presentation.zig` covers the ticket 05 route. It fails each allocation of the index, File Tree, and listing arenas in turn. Each failure keeps Review Search open, the DiffPane, the Buffer, the File Tree, the listing, and the stale index mark. Two mutations fail it: closing Review Search before the route, and setting `main_pane` before the index build.
- `AGENTS.md` has the five spec rules and three more rules for the mistake classes that tickets 02, 03, and 05 fixed at the type level. These rules name `comment_overview.Frame.state`, `DisclosureBuild.Kind.publishedPane` with `Kind.rebuildsContent`, and `comment_overview.passes`. The `Frame.state` rule states its limit: a change of the field to a value type compiles. No test catches the dangling cells deterministically.
- Every test name in the changed `AGENTS.md` rows exists in `src`. A script compared each quoted name with the `test "..."` declarations.
- The spec keeps `Status: ready-for-agent`. Ticket 07 is `ready-for-human`, so `python3 tools/check_agent_docs.py` does not require the spec to be `claimed` or `resolved`. The runner sets the spec status after ticket 07.
- `README.md` does not list M27 to M29 in its milestone line, because that line stops at M26. This ticket does not change it.
- The `TODO.md` M29 heading stays without "done", because ticket 07 is open.

## Completion

Changed paths: `src/tui/GLOSSARY.md`, `GLOSSARY-MAP.md`, `src/tui/IMPLEMENTATION.md`, `AGENTS.md`, `README.md`, `TODO.md`, `src/tui/presentation.zig` (one new test), and this ticket.

Summary: the Presentation glossary adds Main Pane, Comment Overview, Overview Entry, Overview State, and File Tree Filter. It changes Pane, File Tree, File Jump, Review Search, and Interaction Context. `GLOSSARY-MAP.md` adds the Overview Entry projection to "Review → Presentation". `src/tui/IMPLEMENTATION.md` names `comment_overview.zig`, `buildIndex`, and `buildListing`. `AGENTS.md` adds eight rules and changes the File Jump and File Tree cursor rules. `README.md` documents `g o`, `g d`, the Comment Overview keys, the File Tree Filter, the Review Search route, and the eight Action names. `TODO.md` checks five M29 lines and marks the source context line as deferred by decision 8 of the brief.

Checks:

- `python3 tools/check_agent_docs.py`: pass.
- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-comment-overview --summary all`: 79/79 pass.
- `zig build test --summary all`: 1453/1453 pass, 24/24 steps (baseline before M29: 1378, after ticket 05: 1451).

Review result: the runner reviewed the docs diff and reran every check. The runner made two changes:

- A `comptime` block in `comment_overview.Frame` now rejects any field that holds an array by value. Its error names the field and the fix. The runner proved it: a by-value `state: State` field fails with that error. The AGENTS.md rule now names this check.
- The File Tree in the Comment Overview no longer paints the hidden DiffPane's active File as selected.

Commit: see the `docs: document M29 Comment Overview` commit.
