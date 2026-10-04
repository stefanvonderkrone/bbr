# Choose Selection source ownership after Markdown projection

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 04, 06, 07

## Question

Which authored logical lines does a selected ReviewBody row represent when Markdown projection joins, repeats, or hides authored text?

Apply the mixed Selection contract from [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md).
Keep complete-body copying, Selected Version filtering, selected ReviewCard labels, and exact authored bytes unchanged.

Combine that contract with [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md).
Use [Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) for related source and navigation distinctions.
Search ranges do not define clipboard extraction by themselves.

Choose observable copying behavior for these cases:

- Two authored prose lines join into one displayed paragraph.
  A selected row can contain text from both lines or only one line after wrapping.
- One authored table row becomes several header-labelled cells at a narrow width.
  A selected cell row can repeat a header from another authored line.
  Decide whether that repeated header contributes its authored line or remains generated decoration.
- A reference link displays a destination from a hidden body-local definition.
  A Selection touches the displayed destination but not a row for the definition.
  Decide whether copying includes the reference use, the hidden definition, or both.
- A displayed spacer represents several authored blank lines.
  Decide which blank lines a selected spacer copies.
- A body row contains only a generated heading, list, quote, or table marker.
  Distinguish these markers from the already permitted selected ReviewCard labels.
- Valid fence delimiters and Setext underlines have no displayed row.
  Decide whether Selection of their adjacent content implies those authored lines.
  The existing contract already forbids synthesizing fences around partial code.

Keep deduplication per authored owner and logical line.
Define contribution order when displayed order and authored order differ.
Do not infer the answer from equal-length source and display slices.

The answer must include exact clipboard-byte examples for narrow and wide projections.
Include a joined-paragraph search reveal followed by Selection copying.
Include resize and ReviewCard disclosure without adding hidden logical lines merely because the body owns them.

This ticket resolves a presentation and clipboard decision.
It does not implement M23.

## Comments

### Visual decision examples

The user requested visual examples before answering the six Selection questions.
The [Selection copying questions prototype](../prototype/selection-copy-questions.html) shows selected rows and exact clipboard results for each choice.
Each question has a number and lettered answers.
The user can also give a longform answer.

The examples include wide and narrow rows, repeated table headers, reference destinations, blank lines, and hidden delimiters.
They also include mixed-owner order, wrapped-line deduplication, a search reveal followed by Selection, and ReviewCard disclosure.
The prototype uses hand-built rows rather than the application parser.
Its outputs remain proposals until the user confirms the copying rules.
Browser checks covered all 22 examples, exact-byte results, upward Selection, and combined lettered and longform answers.
This ticket remains claimed and unresolved.

### User answers to the visual questions

The user answered `1a, 2a, 3b, 4b, 5b, 6a`.

1. Copy complete authored lines touched by selected displayed text, not the complete joined paragraph.
2. Repeated table headers remain decoration. Copy only the selected cell's complete authored row.
3. A selected resolved reference destination contributes both the reference use and its hidden definition.
4. A selected spacer contributes only its first represented authored blank line.
5. Selected block content also contributes its existing hidden block delimiters.
   Generated marker-only rows contribute nothing.
6. Keep first-encounter display order across selected rows and owners.
   Order several lines first encountered in one row by authored position.

The implied-line choices expose one combined order question.
Immediate first-encounter extraction can put a closing fence before a later selected code line.
It can also put a shared definition between its selected reference uses.
The prototype adds a seventh question to compare immediate extraction with authored order within each ReviewCard.
The recommended refinement retains display order between source and ReviewCards.
The user must confirm that refinement before this ticket resolves.

### Final confirmation

The user answered `7a`.
Keep authored order within each ReviewCard after adding the required hidden lines.
Keep source and ReviewCards in display order.
This confirmation settles the remaining combined order question.

## Answer

### Confirmed choices

The user confirmed `1a, 2a, 3b, 4b, 5b, 6a, 7a` through the [visual Selection examples](../prototype/selection-copy-questions.html).
The examples define project clipboard behavior, not observed Bitbucket Cloud behavior.

### Selected body rows

A selected body row contributes the complete authored logical lines whose content it displays.
One joined paragraph row can contribute several authored lines.
A wrapped row can contribute only one authored line from that paragraph.
Copy a touched line completely, even when some of its displayed wraps are outside Selection.
Do not add the rest of the paragraph.

A narrow table cell contributes its complete authored table row.
Repeated header labels beside cells are generated decoration and do not contribute the authored header line.
Selecting several cells from one authored row copies that row once.
The table's actual header content contributes its authored header line when selected.

A selected spacer contributes only its first represented authored blank line.
Preserve that line's exact whitespace and line ending.
Do not add later blank lines compressed into the same spacer.
A generated spacer with no authored blank line contributes nothing.

Generated heading, list, quote, and table markers contribute nothing by themselves.
A row containing only such a marker does not select the source line that produced it.
When selected content touches that source line, its complete authored markers remain in the copy.
Selected ReviewCard headers, disclosure text, and Suggestion labels retain the permitted plain-text exception from the yank decision.
They do not imply selection of hidden body content.

### Required hidden lines

A selected row displaying a resolved reference destination contributes the reference use's authored line and the resolved definition's authored line.
This rule also applies to reference images.
Use the same first matching body-local definition that supplies the displayed destination.
A label-only selected row does not add a definition whose destination appears only on an unselected row.
Do not add intervening blank lines merely because the definition depends on them in the complete body.

Selected block content also contributes its existing hidden block delimiters.
For valid fenced code and Suggestions, include both authored fence lines, including their original metadata and indentation.
For a Setext heading, include its authored underline.
For a table, include its authored separator line.
Selecting table content does not also imply the unselected authored header line.
An indented code block has no fence lines to add.
Malformed delimiters that remain literal follow the ordinary touched-line rule.

Do not synthesize missing fences or other Markdown.
Do not add unselected code lines, other table rows, unrelated definitions, or adjacent prose.
These required hidden lines are explicit exceptions to the earlier no-hidden-lines rule.
They do not make the complete body eligible merely because a selected row belongs to it.

### Contribution order and exact bytes

Scan the inclusive Selection from top to bottom, independent of the Selection's direction.
Keep source and ReviewCards in display order.
Within each ReviewCard, collect its touched authored body lines and the required hidden lines.
Copy that authored set in original line order, not immediate first-encounter order.
Selected plain labels retain their display order and their position around the body content they label.
Do not group a File's source Lines across an intervening ReviewCard.

Deduplicate by authored owner and logical line.
Use the stable CommentId or TempId owner, not displayed text, to distinguish body lines.
Several uses of one reference definition copy the definition once for that owner.
Several selected code rows copy each fence once, with the closing fence after the selected code lines.
Distinct owners with identical content remain distinct contributions.

Read every authored contribution from the owning raw body.
Preserve indentation, tabs, trailing spaces, line endings, Markdown markers, and authored emoji bytes.
Keep the existing contribution-join rule from [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md).
Do not replace authored text with displayed emoji or generated table labels.

### Search, resize, disclosure, and existing contracts

Search ranges do not decide clipboard extraction.
After opening a joined-paragraph Review Search result, Selection still copies the lines represented by selected rows.
The persistent search disclosure makes those rows available but does not select every line in the match or body.
Buffer Search's temporary reveal retains its existing lifecycle.

Resizing reprojects the rows and their source relationships.
Copying always uses the selected rows in the current Presentation Frame.
When the same logical content participates at both widths, its authored clipboard bytes remain the same.
If the selected row represents different authored lines after reprojection, apply the current touched-line rule.

Expanding a ReviewCard makes additional rows available, not automatically selected.
A selected collapsed footer copies its plain label, not hidden body lines or their delimiters.
Complete-body copying without Selection still copies the entire authored body from any eligible ReviewCard row.

Selected Version filtering, inherited Reply CommentScope, eligible Deleted Comment content, Count, and clipboard completion behavior retain the yank decision's rules.
The no-hidden-lines and display-order clauses in that decision now use the explicit refinements in this answer.
Neither search navigation nor generated text replaces those ownership rules.

### Exact clipboard-byte examples

The strings below use JSON escapes to show exact bytes.
The examples do not add an ending newline unless a copied authored line contains one.

1. Authored `"first\nsecond"`, wide selected row `first second`.
   Copy `"first\nsecond"`.
   At narrow width, selecting only `first` copies `"first\n"`.
   Selecting both narrow rows copies `"first\nsecond"`.
2. Authored `"alpha bravo\ncharlie delta"`, selected wrap `alpha`.
   Copy `"alpha bravo\n"`.
   Selecting both `alpha` and `bravo` wraps produces the same bytes once.
3. Authored `"| Name | State |\n| --- | --- |\n| Ada | Ready |\n| Bo | Waiting |"`.
   Selecting narrow `State: Ready` or the wide Ada row copies `"| --- | --- |\n| Ada | Ready |\n"`.
   The separator follows the required-hidden-delimiter rule.
   Neither the repeated header nor the unselected Bo row contributes.
4. Authored `"[docs][id]\n\n[id]: https://example.invalid/"`.
   Selecting only the narrow displayed destination copies `"[docs][id]\n[id]: https://example.invalid/"`.
   Selecting the wide label-and-destination row produces the same bytes.
   Selecting only the narrow label row copies `"[docs][id]\n"`.
5. Authored `"[docs][id]\n[more][id]\n\n[id]: https://example.invalid/"`.
   Selecting both visible reference uses copies `"[docs][id]\n[more][id]\n[id]: https://example.invalid/"`.
   The definition follows both uses and copies once.
6. Authored `"A\n\n\nB"`, selected compressed spacer.
   Copy `"\n"`, not `"\n\n"`.
   Selecting A, the spacer, and B copies `"A\n\nB"`.
   For `"A\n  \n\t\nB"`, selecting only the spacer copies `"  \n"`.
7. Authored `"```zig\nconst x = 1;\nconst y = 2;\n```\nafter"`.
   Selecting both code rows copies `"```zig\nconst x = 1;\nconst y = 2;\n```\n"`.
   Selecting only the first code row copies `"```zig\nconst x = 1;\n```\n"`.
   The unselected code line and following prose do not contribute.
8. Authored `"Title\n=====\ntext"`, selected Setext heading content.
   Copy `"Title\n=====\n"`.
   Selecting only a generated heading marker emits no clipboard command.
9. Open the Review Search match for `first second` in authored `"first\nsecond\n\nhidden tail"`.
   Select only the revealed narrow `first` row.
   Copy `"first\n"`, not all matched lines or the hidden tail.
10. Select a collapsed footer whose plain text is `Show 2 body rows`.
    Copy `"Show 2 body rows"` without expanding or adding hidden lines.
    Without Selection, invoking `y` on that footer instead copies the complete eligible authored body.
11. Select source `"before();\n"`, Comment `"first\nsecond\n"`, then source `"after();"`.
    Copy `"before();\nfirst\nsecond\nafter();"` at both wide and narrow projections.
    An upward Selection of the same rows produces the same bytes.

Inspect these results through the existing `copy_clipboard` command.
Include reprojection, disclosure, deduplication, and opposite Selected Version exclusion in implementation acceptance checks.
The prototype remains a planning asset, not evidence that the application implements these rules.

### Handoff

[Define the integrated M23 acceptance contract](./08-define-the-integrated-m23-acceptance-contract.md) can return to the frontier.
That review must include the explicit hidden-line exceptions and final authored order within each ReviewCard.
This answer resolves the Selection source-ownership decision.
