# 06: Document M30 and verify the integrated suite

Status: resolved
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

- [x] The glossary entries match the spec and use the glossary terms exactly.
- [x] `src/tui/IMPLEMENTATION.md` names `scroll_marks.zig` and its two functions.
- [x] `AGENTS.md` has the five M30 rules and the two changed rule texts, and each named test exists.
- [x] `README.md` documents the track press, the Scroll Drag, and the Scroll Marks.
- [x] `TODO.md` matches the brief and the shipped behavior.
- [x] `python3 tools/check_agent_docs.py` passes.
- [x] `zig fmt --check build.zig src`, `zig build`, and `zig build test-scrollbars` pass.
- [x] `zig build test --summary all` passes, and the reported test count is higher than before M30.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-scrollbars`
- `zig build test --summary all`

## Completion

### Summary

- `src/tui/GLOSSARY.md` has the Scroll Mark and Scroll Drag entries from the spec.
  The View entry says that its scroll bar shows a thumb over its track and takes a press and a Scroll Drag.
- `src/tui/IMPLEMENTATION.md` has a "Scroll bars and Scroll Marks" row.
  It names `scroll_marks.zig`, `rowMarks`, `project`, `view.trackCell`, `frame.scrollState`, and `frame.scrollTarget`.
- `AGENTS.md` has the five M30 rules.
  The rule "A layout tree always declares its scroll bars" now says "only the scroll numbers and the Scroll Marks vary".
  Its enforcement is the test "M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks" in `src/tui/layouts.zig`.
  Ticket 04 already named `┃`, `◆`, and `━` in the `view_paint.zig` rule.
- `README.md` describes the track press, the Scroll Drag, and the Scroll Mark glyphs after the mouse paragraph.
- `TODO.md` marks the M30 size as M and checks the five lines that tickets 01 to 05 prove.
  Two open lines point to tickets 07 and 08.
- Ticket 07 has a `## Agent notes for the human` section.
  Ticket 08 is unchanged.

### Deviations from the spec text

- The second M30 rule names `frame.scrollTarget`.
  Paint reads `frame.scrollState`, but hit testing and the Scroll Drag read `frame.scrollTarget`, as ticket 02 shipped.
  The rule also cites "M30 scrollbar a track without a thumb or under an Overlay has no scroll bar target" in `src/tui/frame.zig`.
- The Scroll Mark priority rule adds that Review Search highlights give no hit mark.
  It cites "M30 scrollbar Review Search highlights in the DiffPane give no mark" in `src/tui/render.zig`, from ticket 05.
- The Scroll Drag rule says that every mouse event other than a left drag ends the drag, as ticket 02 shipped.
  It also cites the release test and the thumb test of ticket 02.
- The README says that the wheel over a track does nothing, as ticket 02 recorded.

### Test name check

A script under `$TMPDIR` extracted every quoted test name from the scroll bar rows of `AGENTS.md`.
It searched the named file for `test "<name>"`:

```text
found line 40 src/tui/layouts.zig: M30 scrollbar the layout rects do not depend on the scroll numbers or the Scroll Marks
found line 41 src/tui/view.zig: M30 scrollbar the thumb covers the track cell of every visible row
found line 41 src/tui/view.zig: the scroll bar thumb covers the visible share of the content
found line 42 src/tui/render.zig: M30 scrollbar every scroll bar hit target matches the painted thumb
found line 42 src/tui/frame.zig: M30 scrollbar a track without a thumb or under an Overlay has no scroll bar target
found line 43 src/tui/scroll_marks.zig: M30 scrollbar a cell shows the highest priority Scroll Mark
found line 43 src/tui/view_paint.zig: M30 scrollbar a Scroll Mark under the thumb keeps its glyph in the thumb style
found line 43 src/tui/render.zig: M30 scrollbar Review Search highlights in the DiffPane give no mark
found line 45 src/tui/presentation.zig: M30 scrollbar a Scroll Drag follows the pointer outside the track and past its ends
found line 45 src/tui/presentation.zig: M30 scrollbar key input and a Session replacement end a Scroll Drag
found line 45 src/tui/presentation.zig: M30 scrollbar a release activates nothing and a motion, a wheel, or another press ends a Scroll Drag
found line 45 src/tui/presentation.zig: M30 scrollbar a Scroll Drag ends when its thumb goes away
found line 47 src/tui/presentation.zig: every File jump puts the File header on the top DiffPane row and the File Tree cursor on the File
```

`tools/check_agent_docs.py` now does the same check for every row of the `AGENTS.md` rule table.
A quoted name in an Enforcement cell must be a test in the next or the previous `in `<file>.zig`` of the cell.
Before the change, one row named no file for "every OwnedCommand launch failure keeps its correlation and frees the command".
That row now names `src/tui/presentation.zig`.
All 50 cited tests exist.
Two temporary changes prove the check, and both were reverted:

- Without the file of the OwnedCommand row: `AGENTS.md: line 30: test "every OwnedCommand launch failure keeps its correlation and frees the command" names no file`.
- With "highest-priority" in the Scroll Mark rule: `AGENTS.md: line 43: src/tui/scroll_marks.zig has no test "M30 scrollbar a cell shows the highest-priority Scroll Mark"; cite the exact test name`.

`tests/check_agent_docs_test.py` has two new cases, and CI runs it.
A new `AGENTS.md` row names this check.
`docs/agents/issue-tracker.md` describes it.

### Other fix

`tests/check_box_glyphs_test.py` failed since ticket 04.
Its "straight lines" fixture still allowed `━` and `┃`, which the lint now rejects.
The fixture no longer has those two glyphs, and the test passes.
CI does not run this test, so CI did not show the failure.

### Checks

- `python3 tools/check_agent_docs.py`: pass.
- `python3 tests/check_agent_docs_test.py`: 16 of 16 pass.
- `python3 tests/check_box_glyphs_test.py`: 3 of 3 pass.
- `zig fmt --check build.zig src tests`: pass.
- `zig build`: pass.
- `zig build test-scrollbars --summary all`: 7 of 7 steps and 70 of 70 tests pass.
- `zig build test --summary all`: 24 of 24 steps and 1444 of 1444 tests pass. The count before M30 was 1378.
- Native target: aarch64-macos.

### Spec status

The spec is now `claimed`, not `ready-for-agent` and not `resolved`.
Tickets 07 and 08 have no `Type:` field, so `docs/agents/issue-tracker.md` counts them as implementation tickets.
They are `ready-for-human`, so the spec cannot resolve.
That document says to use `claimed` while implementation is active, and M30 implementation is active until ticket 08 resolves.
The human who resolves ticket 08 checks the integrated criteria and sets the spec to `resolved`.

### Review

- Self-review of the diff against the spec sections "Glossary changes" and "AGENTS.md rules": no open finding.
- No command started bbr or sent a request to Bitbucket.

### Commit

This commit.
