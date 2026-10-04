# 02 — Yank complete authored ReviewBody content

**What to build:** Let a reviewer use `y` on any eligible ReviewCard row to copy its complete authored body. Retain available Deleted Comment bodies from Bitbucket so deletion does not discard copyable content.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Without Selection, every eligible header, body row, Suggestion label, Suggestion body row, and disclosure footer copies the same complete raw body.
- [ ] Copy hidden body content without changing disclosure or cursor. Do not copy generated labels in complete-body mode.
- [ ] Preserve exact authored Markdown, tabs, indentation, trailing spaces, line endings, emoji bytes, and absent final newlines.
- [ ] Filter inline ReviewCards through Selected Version and the scope projection that places them. Published and Draft Replies inherit root inline scope.
- [ ] Keep Review-level and File-level ReviewCards eligible with either Selected Version. Apply the rules in both layouts.
- [ ] Retain available Deleted Comment authored content at the Bitbucket boundary. Preserve structural tombstone filtering and surviving-Reply behavior.
- [ ] Keep Deleted Comments excluded from both searches and unavailable for mutation. Do not invent content when the response has no body.
- [ ] Copy a nonempty whitespace-only body. Emit no complete-body clipboard command for an empty body or an opposite-version inline ReviewCard.
- [ ] Consume Count on every invocation. A Count copies an eligible body once.
- [ ] Preserve unmarked source logical-Line Count copying within one File. Skip interleaved ReviewCards and structural rows and remove wrapped duplicates.
- [ ] Direct invocation on a structural row emits no command and does not scan ahead.
- [ ] Help names the Action `yank text`. ActionAvailability and dispatch share direct-target eligibility rules.
- [ ] Use owned `copy_clipboard` text and a correlated `clipboard_completed` input. Report `copied text` or `could not copy text`.
- [ ] Refusal and allocation failure emit no command and preserve Selection. Existing explicit Selection retains precedence over direct body copying.
- [ ] Verify exact command bytes through Presentation. Use scripted HttpClient responses for available and absent Deleted Comment content.
- [ ] Run the complete hermetic suite with `zig build test --summary all`.

## Contract

Use the [M23 raw yank contract](../../m23-comment-thread-markdown-presentation-fixes/SPEC.md#raw-yank-and-selection-ownership) and the [approved yank answer](../../m23-comment-thread-markdown-presentation-fixes/issues/07-choose-raw-reviewbody-yank-behavior.md#answer).
Ticket 03 adds the mixed Selection contract. Later Markdown tickets add extraction rules for their syntax.
