# 02 — Yank complete authored ReviewBody content

**What to build:** Let a reviewer use `y` on any eligible ReviewCard row to copy its complete authored body. Retain available Deleted Comment bodies from Bitbucket so deletion does not discard copyable content.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] Without Selection, every eligible header, body row, Suggestion label, Suggestion body row, and disclosure footer copies the same complete raw body.
- [x] Copy hidden body content without changing disclosure or cursor. Do not copy generated labels in complete-body mode.
- [x] Preserve exact authored Markdown, tabs, indentation, trailing spaces, line endings, emoji bytes, and absent final newlines.
- [x] Filter inline ReviewCards through Selected Version and the scope projection that places them. Published and Draft Replies inherit root inline scope.
- [x] Keep Review-level and File-level ReviewCards eligible with either Selected Version. Apply the rules in both layouts.
- [x] Retain available Deleted Comment authored content at the Bitbucket boundary. Preserve structural tombstone filtering and surviving-Reply behavior.
- [x] Keep Deleted Comments excluded from both searches and unavailable for mutation. Do not invent content when the response has no body.
- [x] Copy a nonempty whitespace-only body. Emit no complete-body clipboard command for an empty body or an opposite-version inline ReviewCard.
- [x] Consume Count on every invocation. A Count copies an eligible body once.
- [x] Preserve unmarked source logical-Line Count copying within one File. Skip interleaved ReviewCards and structural rows and remove wrapped duplicates.
- [x] Direct invocation on a structural row emits no command and does not scan ahead.
- [x] Help names the Action `yank text`. ActionAvailability and dispatch share direct-target eligibility rules.
- [x] Use owned `copy_clipboard` text and a correlated `clipboard_completed` input. Report `copied text` or `could not copy text`.
- [x] Refusal and allocation failure emit no command and preserve Selection. Existing explicit Selection retains precedence over direct body copying.
- [x] Verify exact command bytes through Presentation. Use scripted HttpClient responses for available and absent Deleted Comment content.
- [x] Run the complete hermetic suite with `zig build test --summary all`.

## Contract

Use the [M23 raw yank contract](../../m23-comment-thread-markdown-presentation-fixes/SPEC.md#raw-yank-and-selection-ownership) and the [approved yank answer](../../m23-comment-thread-markdown-presentation-fixes/issues/07-choose-raw-reviewbody-yank-behavior.md#answer).
Ticket 03 adds the mixed Selection contract. Later Markdown tickets add extraction rules for their syntax.

## Implementation

Commit: `d22a57f` (`tui: yank complete authored ReviewCard bodies`).

ReviewCard rows retain the root scope that places their subtree.
Presentation uses that scope to filter complete-body copies through Selected Version.
Published Replies, Draft Replies, and Replies under fetched posted-Draft aliases inherit the placed root scope.
Complete-body copies read the exact authored bytes from Review storage.

The Bitbucket adapter retains available Deleted Comment bodies.
Scripted HttpClient tests verify exact bytes, absent bodies, structural tombstone filtering, and surviving Reply ancestry.
Presentation tests verify that Deleted Comments remain excluded from both searches and unavailable for mutation.

Validation for this implementation on native Apple Silicon macOS, with the macOS 15 deployment target:

- `zig build test-yank --summary all`: 23 tests passed.
- `zig build test-selected-version-hardening test-yank --summary all`: 34 tests passed.
- `zig test src/root.zig --test-filter getComments`: 8 tests passed.
- `zig fmt --check build.zig src tests`: passed.
- `zig build`: passed.
- `zig build test --summary all`: 967 tests passed.
- `git diff --check`: passed.

The Standards and Spec reviews found no remaining issues.
