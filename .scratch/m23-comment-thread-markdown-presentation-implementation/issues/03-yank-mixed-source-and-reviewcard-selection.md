# 03 — Yank mixed source and ReviewCard Selection

**What to build:** Copy eligible source Lines and ReviewCard content across the complete marked Selection. Preserve display order between owners and exact authored bytes within each ReviewCard.

**Blocked by:** 02 — Yank complete authored ReviewBody content.

**Status:** resolved

- [x] Scan the inclusive Selection from top to bottom, regardless of its direction, starting owner, or cursor File.
- [x] Keep source and ReviewCards in display order across Files. Do not collect source Lines across an intervening ReviewCard.
- [x] Source rows contribute complete logical Lines from Selected Version. Body rows contribute complete authored lines whose content they display.
- [x] Deduplicate source wraps by File and logical Line. Deduplicate body lines by typed CommentId or TempId and logical line.
- [x] Keep distinct owners with identical text as distinct contributions.
- [x] Within each ReviewCard, copy touched body lines in original authored order. Provide the source ownership needed for later syntax-specific required hidden lines.
- [x] A selected spacer copies only its first represented authored blank line, with exact whitespace and line ending. Generated spacers contribute nothing.
- [x] Selected ReviewCard headers, Suggestion labels, and disclosure text contribute plain text without terminal markers or indentation.
- [x] Other structural rows and generated marker-only rows contribute nothing. A collapsed footer does not select hidden body content.
- [x] Filter source and inline ReviewCards through Selected Version and inherited scope in both layouts. Exclude opposite-version bodies and labels.
- [x] Keep eligible Review-level and File-level cards, available Deleted Comment content, and selected plain labels copyable.
- [x] Read authored contributions from raw storage. Preserve exact whitespace and line endings. Add a separating newline only when the preceding contribution has no ending newline.
- [x] Do not add an otherwise absent final newline. Do not copy unrelated hidden lines or synthesize Markdown.
- [x] Consume Count without limiting or repeating Selection copying. Clear Selection only after owned clipboard text queues.
- [x] Refusal, empty eligible content, and allocation failure preserve Selection and emit no command. A later clipboard failure does not restore cleared Selection.
- [x] ActionAvailability uses the same Selection eligibility as dispatch. Eligible Selection takes precedence over the cursor target.
- [x] Verify upward and downward Selection, multiple Files and owners, selected labels, blank spacers, wrapped duplicates, and allocation-failure cleanup through Presentation.
- [x] Run the complete hermetic suite with `zig build test --summary all`.

## Contract

Use the [approved yank answer](../../m23-comment-thread-markdown-presentation-fixes/issues/07-choose-raw-reviewbody-yank-behavior.md#answer) and the [later Selection ownership answer](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#answer).
The later answer takes precedence for required hidden lines and authored order within each ReviewCard.
Tickets 05, 06, 08, and 09 add their syntax-specific extraction cases.

## Implementation

Commit: `fdde4e1` (`tui: yank mixed source and ReviewCard Selections`).

Presentation scans the complete Selection and retains display order across Files and ReviewCards.
Typed contribution keys distinguish source Lines, Comment bodies, Draft bodies, and plain labels.
ReviewCard segments distinguish authored content from generated markers and spacing.
Spacer rows identify their first authored blank line.
Body extraction reads complete touched lines from raw storage and preserves exact whitespace and line endings.
Presentation orders those lines within each ReviewCard without moving selected labels or source contributions.

Selection copying shares eligibility with ActionAvailability and respects inherited scope and Selected Version in both layouts.
Count does not limit or repeat the copy.
Selection clears only after the owned clipboard command queues.
Allocation-failure tests verify cleanup and preserve Selection when no command queues.
Boundary caching and hash-based deduplication avoid repeated scans across wrapped lines and large Selections.

Validation on native Apple Silicon macOS, with the macOS 15 deployment target:

- `zig build test-yank --summary all`: 30 tests passed.
- `zig fmt --check build.zig src tests`: passed.
- `zig build`: passed.
- `zig build test --summary all`: 974 tests passed.
- `git diff --check`: passed.

The first full-suite attempt reached the command timeout.
The run with a longer timeout passed all 18 build steps.
The Standards and Spec reviews found no remaining issues.
