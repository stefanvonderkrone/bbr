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
- Merge with `origin/main` (`497c86f`, PR #16) on 2026-11-01. The merge commit resolves the textual conflicts in `frame.zig`, `layouts.zig`, `presentation.zig`, and `render.zig`. It follows the single-branch trial recipe `5fe9422`. Later commits fix the review findings below.
- X-1 and M29-1. The merged tree did not compile. Main made `keymap.helpSection` exhaustive and moved the query erase helpers to `search.zig`. The fix commit adds the help sections and calls `search.lastScalarStart` and `search.wordStart`.
- Help sections. `show_comment_overview`, `show_diff_pane`, and `open_overview_entry` go to Panes and Files, because they change the Main Pane. `edit_overview_query` and the four `toggle_overview_*` Actions go to Comments and Drafts, because they filter Comments. M29 adds no new help section.
- M29-5. `help.fixed_sections` has a "Comment Overview Filter Input" section with the keys of the query input. The Mouse section names the second click that opens an Overview Entry.
- M29-2. A destination build that shows the DiffPane now closes the query input and keeps the query.
- M29-3. An armed re-anchor claims Enter and Escape only while the DiffPane shows. Enter in the Comment Overview opens the entry again.
- M29-4. A Submission Overlay jump to a Draft card shows the DiffPane on the fast path too. A failed DiffPane change shows the Submission Overlay again.
- Ticket 08 records the Overview scroll bar defect that exists after the M30 merge. The operator chose a follow-up ticket.
- After the fixes: `zig build test --summary all` passes, 24/24 steps and 1499/1499 tests. `python3 tools/check_agent_docs.py` passes.
- Second fix round on 2026-11-02 for the remaining review findings. Each fix commit has a test that failed before the fix, or a mutation that the new test kills.
- M29-9, commit `8df6955`. Three tests prove that a deleted Draft, a submitting Draft, and a Draft linked to its fetched Comment leave the listing. Each test fails when its `overview_index_stale = true` line goes. A Draft delete cannot happen while the Overview shows, so the delete test goes through `g d` and `g o`.
- M29-6, commit `c20f84f`. The `.sidebar` context gains `to_top`, `to_bottom`, the row scroll Actions, `submit`, and `recover_submission`. The root entry now acts like a File entry. These Motions move the hidden DiffPane on every entry, so ticket 09 asks triage for the visible behavior.
- M29-8, commit `e2deedb`. A geometry change calls `followOverviewSelection`. It clamps the scroll and rebuilds nothing.
- M29-10, commit `7dc9093`. The SPEC contradicted itself. The runner chose the step list reading, because the code, user story 3, and the acceptance list follow it. In its own view, `g o` or `g d` changes nothing, focus included. Rule 11 now says so. Two tests prove both cases.
- M29-7, commit `77845a1`. Each Overview record has a `tree_path`, the display path of its File. The Directory filter compares it. The SPEC File Tree Filter section now says so.
- M29-11, commit `6ce35e2`. `review_body.excerpt` cuts on a grapheme boundary with the Presentation `CellMetrics`. A cut excerpt ends with `…`, and the painter adds no second one. The SPEC excerpt lines now say so.
- Fixed help sections, commit `7b639dd`. `help.FixedKeyInput` names each raw key input. `applyKey` switches on it, and `help.fixed_sections` is an `EnumArray` over it. A new raw input without a section is a compile error. Removing the Comment Overview entry gives `missing struct field: comment_overview_query`. Ticket 10 records the re-anchor keys, which the check does not cover.
- Main Pane owner, commit `cb75794`. `Published.showMainPane` is the one writer of `main_pane` after init. It closes the query input and cancels a pending Overview destination when the Comment Overview hides. M29-2 and M29-4 came from writers that skipped a side effect. Removing either side effect fails an existing test. A Draft destination that leaves the Overview now also cancels a pending Overview destination.
- X-5 and X-6, M29 part, commit `f588ca6`. 32 mutations ran against the M29 `AGENTS.md` rows. 27 failed a named check at once. New tests kill three more. Two survivors have no cheap test, so their `AGENTS.md` cells now say "convention (no check)". These are the single-Pane draw loop in `app.zig` and the `draft_destination` arm of `Kind.publishedPane`.
- Out of scope: X-2 (Credential transport on main) and X-3 (decoders that panic on untrusted bytes). Ticket 08 waits for M30 and triage.

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
