# Choose raw ReviewBody yank behavior

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: resolved

## Question

How does the existing `y` Action copy complete authored Markdown from a ReviewCard without breaking source yank behavior?

The user accepts exploring complete-body copying from any ReviewCard row.
Choose behavior for the header, body, Suggestion label, Suggestion body, and disclosure footer.
Define precedence when a source Selection is active and the cursor moves onto a ReviewCard.
Define Count behavior and whether a body yank clears Selection.

The copied bytes come from the owning Comment or Draft, not projected ReviewBody segments.
Include whitespace, trailing newlines, Markdown fences, and emoji shortcodes in the examples.
Choose refusal behavior for a Deleted Comment, an empty body, and structural rows outside a ReviewCard.
Include source yank on adjacent Lines and explain ActionAvailability and help text.

Use the existing typed clipboard command and completion seam for acceptance examples.
The answer defines the user-visible contract, not clipboard implementation changes.

## Comments

### First decision round

The user accepts complete authored-body copying from every ReviewCard row.
The copy preserves whitespace, trailing newlines, Markdown fences, and emoji shortcodes.
The user accepts source Selection precedence when the Selection starts in source and ends on a ReviewCard.
The user accepts one complete body copy for a Count such as `3y` on a ReviewCard.
The Action consumes the Count without repetition or copies of other bodies.

The user makes two changes to the proposed contract:

- A Deleted Comment remains copyable when content exists.
- A Selection that starts in a Comment and ends in source copies the Comment.

The user says to ignore structural rows.
The next round must clarify structural-row invocation and which Selection endpoint determines the owner.

### Current behavior relevant to the next round

- `Nav.mark` records the row where Selection starts. `Nav.selection()` returns a sorted inclusive row range.
- Selection can start on a ReviewCard through `canStartSelection`.
- Source yank clears Selection after it queues a clipboard command.
- Source yank preserves Selection on refusal or allocation failure and consumes Count in both cases.
- The Bitbucket adapter currently replaces every Deleted Comment body with an empty string in `dupeComment`.
- The Review glossary currently defines a Deleted Comment as a tombstone without an authored body.
- Clipboard completion currently reports source-specific success and failure text.

Code references:

- [Selection origin and sorted range](../../../src/tui/nav.zig#L18-L22)
- [Selection eligibility](../../../src/tui/presentation.zig#L11615-L11623)
- [Source yank and Selection cleanup](../../../src/tui/presentation.zig#L10318-L10385)
- [Deleted Comment body normalization](../../../src/bitbucket/client.zig#L924-L932)
- [Clipboard status text](../../../src/tui/app.zig#L331-L334)

### Second decision round

The user replaces the Selection-start rule with mixed-content copying.
Copy everything in the Selection, whether it belongs to a Comment or source.
Ignore structural characters and indentation.
The next round must distinguish terminal-added decoration from authored Markdown and whitespace.
It must also define partial-body copying and hidden content.

The user confirms that `y` on a structural row does nothing when no Selection is active.
Deleted Comment behavior follows the same content rule as other selected content.
The user accepts clearing Selection when the clipboard command queues.
Refusal or allocation failure preserves Selection.
The Action always consumes Count.

### Third decision round

The user confirms that removal applies only to terminal-added decoration and Reply indentation.
The copy preserves authored Markdown markers, fences, and code indentation.
For a partial Comment Selection, copy only authored logical lines touched by selected rows.
Copy a wrapped logical line once.
The user permits selected headers and disclosure text in the copy.
The final confirmation must state how that permission affects collapsed content and body-only copying without Selection.

### Selected Version correction

The user requires Selection copying to respect Selected Version.
A new-version Selection excludes old-version Comments.
An old-version Selection excludes new-version Comments.
The next round must confirm side-independent CommentScopes and direct body copying without Selection.

The user confirms that Review-level and File-level Comments participate with either Selected Version.
The user asks whether a state without Selection exists.
The next exchange must distinguish the cursor from the explicit marked Selection before deciding direct body-copy availability.

The user accepts the distinction between a cursor and an explicit marked Selection.
The user confirms that Selected Version also filters complete-body copying without Selection.
This confirmation closes the remaining decision.

## Answer

### Two copy modes

The cursor names one row without creating a Selection.
`v` or Shift+arrow starts an explicit marked Selection.
The existing `y` Action uses the marked Selection when one exists.
The Selection start does not choose a single Comment owner or a source-only copy mode.

Without Selection, `y` on any eligible ReviewCard row copies the owning Comment or Draft's complete authored body.
This applies to the header, body, Suggestion label, Suggestion body, and disclosure footer.
The copy includes the body's hidden content without expanding the ReviewCard.
The copy contains no generated header or disclosure text in this mode.
`3y` still copies one complete body, not three bodies or three repetitions.

Without Selection, `y` on a source Line retains the existing source copy behavior.
Count selects logical source Lines from Selected Version, with wrapped-line duplicates removed.
Source Count copying stops at the File boundary and skips ReviewCards and structural rows inside that source scan.
Without Selection, invocation on a structural row emits no clipboard command.
It does not scan forward to find a source Line or ReviewCard.

### Mixed Selection

Copy eligible content throughout the inclusive selected row range in display order.
The range can contain source Lines, Comments, Replies, Suggestions, and Drafts, including more than one File.
The Selection's direction and starting owner do not change the result.
Neither a source cursor nor a Comment cursor restricts the range to that owner's content.

For each selected source row, copy the complete logical Line from Selected Version.
For each selected body row, copy the complete authored logical body line that row represents.
Do not copy the complete body merely because one of its rows participates.
Copy each logical line once per owner, even when several selected wrapped rows represent it.
Distinct Comments with identical text remain distinct contributions.

Include selected ReviewCard headers and disclosure text as plain text.
Include a selected generated Suggestion label as plain text, without implying selection of the complete Suggestion body.
These selected labels are the permitted exception to authored-only body extraction.
Strip their terminal-added markers and indentation.
File headers, Hunk headers, section rows, and structural disclosures outside ReviewCards contribute no text.

Do not expand disclosures or add hidden logical lines that no selected body row represents.
A touched logical line copies completely even when some of its wraps lie outside the selected range.
Selecting a collapsed ReviewCard's footer copies its plain disclosure text, not all the hidden body lines.
This differs from complete-body copying without Selection.

Count does not limit or repeat a Selection copy.
Join separate contributions with a newline when the preceding contribution has no ending newline.
Preserve authored line endings within a contiguous body contribution.
Do not add a final newline that no copied body contribution contains.

### Selected Version

Selected Version filters both complete-body copying and Selection copying.
Copy old-version source and inline ReviewCards only when old is selected.
Copy new-version source and inline ReviewCards only when new is selected.
An opposite-version inline ReviewCard contributes no body, header, Suggestion label, or disclosure text to a Selection.
Without Selection, invoking `y` directly on that ReviewCard refuses the copy.
Expanding an opposite-version disclosure does not make its ReviewCards eligible.

Published Replies and Draft Replies inherit the root CommentScope through their ancestry.
Their side comes from that root inline scope, not their indentation or position beside a source row.
Use the same scope projection that places the ReviewCard, including inherited placement for Draft Replies.
Review-level and File-level ReviewCards participate with either Selected Version because those CommentScopes have no line side.
These rules apply in Unified and SideBySide layouts.
The global Selected Version chooses the version, not the horizontal cursor position.

### Authored bytes and Deleted Comments

Read body text from the owning Comment or Draft, not styled ReviewBody segments.
Preserve authored indentation, tabs, blank lines, trailing spaces, Markdown markers, fences, and emoji shortcodes.
Remove only terminal-added borders, gutter markers, line numbers, Reply indentation, and other presentation decoration.
Do not convert a displayed emoji back into guessed authored text.
Use its original shortcode or Unicode bytes from the authored body.
Do not add Markdown fences around a selected partial code block.

A Deleted Comment remains eligible when it has available authored content and satisfies the Selected Version rule.
Deletion alone does not refuse the copy.
Preserve authored content when the Bitbucket response supplies it.
Do not invent content for a tombstone whose body is absent.
This requires changing the current adapter rule that unconditionally discards Deleted Comment bodies during implementation.
Deletion still forbids mutation.

Without Selection, an empty authored body produces no clipboard command.
Generated header text does not substitute for an empty body in complete-body mode.
With Selection, available selected plain labels can contribute even when a Deleted Comment has no authored body.
A Selection with no eligible text produces no clipboard command and preserves Selection.
A nonempty whitespace-only body remains authored content and is copyable.

### Count, Selection, and completion

Every `y` invocation consumes Count, including ignored structural-row invocation and refused copies.
Clear Selection only after the clipboard command queues.
A refusal or allocation failure preserves Selection.
A later clipboard failure reports failure without restoring the cleared Selection.
The cursor and ReviewCard disclosure state do not change during copying.

Use the existing `copy_clipboard` command with owned text and its correlated `clipboard_completed` input.
Successful completion reports `copied text`.
Failed completion reports `could not copy text`.
Both messages apply to source, body, and mixed copies.
No separate clipboard backend or remote request is needed.

### ActionAvailability and help

Help names the Action `yank text`.
ActionAvailability follows the same eligibility and Selected Version rules as dispatch.
An eligible Selection takes precedence over the row under the cursor.
Grey the Action when the Selection contains no copyable text or the direct cursor target is unavailable.
State the applicable reason, such as no authored body, opposite Selected Version, or no copyable text at the cursor.
Unavailable source content retains the existing Selected Version-specific explanation.
Refused or ignored copies emit no clipboard command and leave existing clipboard contents unchanged.

### Acceptance examples

Each successful example inspects `copy_clipboard.text` through the Presentation seam.
Then return the matching `clipboard_completed` input and check the success or failure text.
No system clipboard, live Bitbucket write, or terminal worker is required for these checks.

| Case | Required result |
| --- | --- |
| Any eligible ReviewCard part, no Selection | Copy the same complete raw body. Do not include generated labels. |
| Collapsed footer, no Selection | Copy the complete body, including hidden lines, without expanding it. |
| Authored body `  **keep** :smile:  \n\n` | Copy those exact bytes, including leading spaces, trailing spaces, the shortcode, and both final newlines. |
| Authored body with tabs and a fenced `suggestion` block | Complete-body copying retains all tabs and both authored fences. |
| Selected row displays an emoji authored as `:smile:` | Copy the authored logical line containing `:smile:`, not the displayed emoji. |
| Selection starts in source and ends in a Comment | Copy eligible source Lines and selected authored body lines in display order. |
| Selection starts in a Comment and ends in source | Copy the same eligible content rule. Do not choose only the starting Comment. |
| Upward Selection spans several Comments and Files | Copy eligible content in display order, with no cursor-File restriction. |
| Several selected wraps represent one logical line | Copy that logical line once and preserve its authored indentation. |
| Selection contains an eligible header and collapsed footer | Include their plain labels. Do not add hidden logical body lines. |
| Selection touches part of a fenced block | Copy the touched authored logical lines. Do not synthesize missing fences. |
| New Selected Version spans old and new inline ReviewCards | Copy only new-version inline ReviewCards and new-version source. Exclude all labels of old-version inline ReviewCards. |
| Old Selected Version spans old and new inline ReviewCards | Apply the inverse filter, including inherited Reply and Draft Reply scope. |
| Opposite-version ReviewCard under the cursor, no Selection | Refuse the complete-body copy. Emit no clipboard command. |
| Review-level or File-level ReviewCard | Apply the same content rule with either Selected Version. |
| Deleted Comment supplies nonempty authored bytes | Copy available eligible content without removing it because of deletion. |
| Deleted Comment has no authored body, no Selection | Refuse body copying. Do not copy `Deleted Comment` as a substitute. |
| Selection contains only an eligible Deleted Comment header | Copy the plain header text under the selected-label rule. |
| Empty body or Selection with no eligible text | Emit no clipboard command. Preserve Selection and consume Count. |
| Structural row under the cursor, no Selection | Emit no clipboard command and consume Count. Do not search adjacent rows. |
| `3y` on an eligible ReviewCard | Copy one complete body and consume Count. |
| `3y` with a mixed Selection | Copy the complete eligible Selection once, regardless of Count. |
| Source Count reaches an interleaved Comment | Skip the Comment and continue eligible source Lines within the same File. |
| Clipboard command queues | Clear Selection before completion arrives. |
| Allocation failure or refusal | Preserve Selection, consume Count, and emit no clipboard command. |
| Matching clipboard failure completion | Report `could not copy text`. Do not restore Selection. |

### Implementation handoff

This answer replaces the earlier proposed source-only Selection and Selection-start-owner rules.
The tracker history retains those proposals as conversation, not as the final contract.
The mixed Selection contract changes source yank's current cursor-File filter only for marked Selection.
Unmarked source Count copying keeps its File boundary.
The application remains unchanged in this planning session.
The integrated acceptance ticket must combine these rules with final Markdown projection, disclosure, search, and Reply presentation decisions.
