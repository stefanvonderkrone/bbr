# 03 — Yank mixed source and ReviewCard Selection

**What to build:** Copy eligible source Lines and ReviewCard content across the complete marked Selection. Preserve display order between owners and exact authored bytes within each ReviewCard.

**Blocked by:** 02 — Yank complete authored ReviewBody content.

**Status:** ready-for-agent

- [ ] Scan the inclusive Selection from top to bottom, regardless of its direction, starting owner, or cursor File.
- [ ] Keep source and ReviewCards in display order across Files. Do not collect source Lines across an intervening ReviewCard.
- [ ] Source rows contribute complete logical Lines from Selected Version. Body rows contribute complete authored lines whose content they display.
- [ ] Deduplicate source wraps by File and logical Line. Deduplicate body lines by typed CommentId or TempId and logical line.
- [ ] Keep distinct owners with identical text as distinct contributions.
- [ ] Within each ReviewCard, copy touched body lines in original authored order. Provide the source ownership needed for later syntax-specific required hidden lines.
- [ ] A selected spacer copies only its first represented authored blank line, with exact whitespace and line ending. Generated spacers contribute nothing.
- [ ] Selected ReviewCard headers, Suggestion labels, and disclosure text contribute plain text without terminal markers or indentation.
- [ ] Other structural rows and generated marker-only rows contribute nothing. A collapsed footer does not select hidden body content.
- [ ] Filter source and inline ReviewCards through Selected Version and inherited scope in both layouts. Exclude opposite-version bodies and labels.
- [ ] Keep eligible Review-level and File-level cards, available Deleted Comment content, and selected plain labels copyable.
- [ ] Read authored contributions from raw storage. Preserve exact whitespace and line endings. Add a separating newline only when the preceding contribution has no ending newline.
- [ ] Do not add an otherwise absent final newline. Do not copy unrelated hidden lines or synthesize Markdown.
- [ ] Consume Count without limiting or repeating Selection copying. Clear Selection only after owned clipboard text queues.
- [ ] Refusal, empty eligible content, and allocation failure preserve Selection and emit no command. A later clipboard failure does not restore cleared Selection.
- [ ] ActionAvailability uses the same Selection eligibility as dispatch. Eligible Selection takes precedence over the cursor target.
- [ ] Verify upward and downward Selection, multiple Files and owners, selected labels, blank spacers, wrapped duplicates, and allocation-failure cleanup through Presentation.
- [ ] Run the complete hermetic suite with `zig build test --summary all`.

## Contract

Use the [approved yank answer](../../m23-comment-thread-markdown-presentation-fixes/issues/07-choose-raw-reviewbody-yank-behavior.md#answer) and the [later Selection ownership answer](../../m23-comment-thread-markdown-presentation-fixes/issues/11-choose-selection-source-ownership-after-markdown-projection.md#answer).
The later answer takes precedence for required hidden lines and authored order within each ReviewCard.
Tickets 05, 06, 08, and 09 add their syntax-specific extraction cases.
