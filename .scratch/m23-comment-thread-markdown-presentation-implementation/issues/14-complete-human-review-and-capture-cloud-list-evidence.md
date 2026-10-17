# 14 — Complete human review and capture Cloud list evidence

**What to build:** Complete the required human terminal review and capture the tested Cloud list cases. Record observed evidence separately from project behavior and documentation examples.

**Blocked by:** 13 — Verify combined M23 acceptance.

**Status:** resolved

- [x] A human agrees on the test PullRequest and authoring scope before anyone authors the example Comments.
- [x] Author and publish the list example Comments in the agreed scope. The human delegated authoring and publication to the agent on 2026-10-15. Record their agent authorship.
- [x] A human reviews the complete approved format-combination checklist in bbr after implementation.
- [x] Review both nesting orders of bold and italic, inline code within emphasis, styled links, strikethrough combinations, and styled headings.
- [x] Review converted emoji in prose and link labels, compound skin tones, unknown names, escaped names, and literal code shortcodes.
- [x] Review each applicable combination in Comments, Replies, Drafts, and Draft Replies under cursor, Selection, and search backgrounds.
- [x] Review nested lists and quotes with links, inline code, and fenced code. Include wrapped continuations and narrow Reply widths.
- [x] Review wide and narrow tables with inline styles, links, emoji, escaped pipes, code pipes, missing cells, and extra-cell literal fallback.
- [x] Review image text, complete destinations, optional titles, code backgrounds, syntax colors, and plain fallback.
- [x] Resize the examples and change disclosure. Review light, dark, and system Themes and terminal strikethrough fallback where available.
- [x] Inspect raw complete-body and mixed Selection clipboard output against the approved exact-byte contracts.
- [x] Capture raw authored Markdown, returned Cloud HTML, and observed bbr output for the same authorized list examples.
- [x] Record the observation date and relevant Comment context with each captured case. Keep browser presentation separate from wire and bbr evidence.
- [x] Do not relabel project or upstream fixtures as Cloud observations. Finite observations establish only their tested cases.
- [x] Apply the approved Cloud compatibility policy to observed syntax differences. Record and resolve acceptance failures before declaring M23 complete.
- [x] Record the human review result and link the captured evidence. Do not modify the resolved planning parent or its decisions.

## Contract

Use the [human review checklist](../../m23-comment-thread-markdown-presentation-fixes/issues/04-choose-reviewbody-markdown-presentation.md#human-review-checklist), [approved evidence classes](../../m23-comment-thread-markdown-presentation-fixes/issues/08-define-the-integrated-m23-acceptance-contract.md#evidence-classes), and [Cloud compatibility policy](../../m23-comment-thread-markdown-presentation-fixes/issues/09-choose-cloud-compatibility-and-evidence-policy.md#answer).
The human agreed on the test PullRequest and authoring scope on 2026-10-12.

## Human review session

- Test PullRequest: https://bitbucket.org/check24/pr-webapp/pull-requests/2425.
- Approved authoring scope: Review-level Comments and nested Replies, including local Drafts before publication.
- The human authors and publishes the examples.
- The human requested thorough example coverage and step-by-step guidance.
- Terminal review and Cloud evidence capture remain pending.

### Build result reported by the human

The human reported these results on 2026-10-12:

- Executable version: `bbr 2026.10.12-0+ge906f9965b3a.dirty`.
- `zig build test-m23-acceptance --summary all`: all 7 build steps succeeded and all 13 tests passed.
- Terminal: Ghostty.
- Ghostty Theme: Catppuccin Mocha.
- bbr Theme: Catppuccin Mocha, confirmed by the human.

This result does not establish human terminal acceptance or observed Cloud behavior.

### Agent-authored emphasis examples

The human requested agent-created examples through tmux with `XDG_DATA_HOME="$HOME/.local/share"` on 2026-10-12.
The agent opened the agreed PullRequest in the `m23-review` tmux session with that environment override.
The agent saved one Review-level Draft and a two-level Draft Reply chain through the Composer.
Each body contains the same 20 labelled emphasis cases, `A01` through `A20`.
The examples remain unpublished.

The cases cover plain prose, both emphasis delimiter forms, both nesting orders, inline code, combined attributes, strikethrough, literal content, intraword underscores, and wrapping.
The agent inspected tmux text and ANSI captures at 150 columns by 55 rows.
The captures show hidden formatting delimiters, literal inline-code content, and both Draft Reply indentation levels.
The agent searched for `A13` and reached all three authored owners.
The third owner's selected row retained orange bold text, italic attributes, and green inline code under the interaction backgrounds.

The detached tmux resize attempt produced clipped output rather than a verified narrow projection.
The agent restored the original dimensions.
Human narrow-width review remains pending.

These examples are project fixtures authored by an agent.
They do not satisfy the required human-authored Comment examples or human terminal review.
No Cloud wire or browser presentation evidence was captured.

### Human emphasis review result

The human reported "emphasis passed" for cases `A01` through `A20` in Ghostty with Catppuccin Mocha in both Ghostty and bbr.
This result covers the current agent-authored emphasis examples.
The remaining format groups, Theme variants, human-authored Comments, and Cloud evidence remain pending.

### Agent-authored styled-link examples

The agent added a second Review-level Draft and a two-level Draft Reply chain in the same tmux session.
Each body contains 18 labelled styled-link cases, `B01` through `B18`.
The cases cover both emphasis delimiter forms, both nesting orders, emphasis inside and outside links, strikethrough, literal inline code, combined attributes, and a long destination with a title.
The agent confirmed three Buffer Search occurrences for `B17`.
Human styled-link review remains pending.
These unpublished examples remain agent-authored project fixtures.

### Heading marker trial

The human found the approved `§N` heading markers difficult to read.
The human requested a trial of visible Markdown heading markers.
The implementation now generates `#` through `######` followed by one space.
The markers use the Theme's gutter foreground and the terminal dim attribute.
The heading text retains its bold style and inline style composition.
Setext headings use the same generated markers.
Generated markers retain their existing search and clipboard exclusions.

The existing projection, Preview, and clipboard checks now use the trial markers.
Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build test-inline-markdown --summary all`: all 23 tests passed.
- `zig build test-yank --summary all`: all 40 tests passed.
- `zig build`.
- `zig build test --summary all`: all 1,251 tests passed across 18 build steps.
- `git diff --check`.

The agent restarted `m23-review` and expanded the heading Draft at `C01`.
The terminal text capture shows all six hash marker levels.
The human reviewed the hash marker trial and replied "looks better".
This review records the human's preference for the hash markers over `§N`.
The remaining heading and paragraph cases still need a human review result.
The resolved planning decision remains unchanged.

### B17 wrapped-link follow-up

The human reported that Ghostty highlighted only the first wrapped URL part during Cmd+Shift link interaction.
The agent reproduced missing hyperlink destinations through the terminal-cell rendering seam.
`zig build test-links --summary all` failed the new wrapped-link regression check before the fix.

The fix carries complete link destinations through ReviewBody spans and ReviewCard segments into libvaxis OSC 8 hyperlinks.
Each authored link use has one owner-qualified terminal hyperlink ID across its label and wrapped destination.
ReviewCards and Review Search Preview share the terminal hyperlink adapter.
Relative destinations remain visible without a guessed base URL.
Code text and link titles do not acquire hyperlink metadata.
The adapter excludes raw terminal control bytes from hyperlink destinations.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig build test-links --summary all`: all 20 tests passed.
- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,251 tests passed across 18 build steps.
- `git diff --check`.

The agent restarted bbr in `m23-review` with the agreed data directory.
The executable reports `bbr 2026.10.12-0+g12354fa58e6a.dirty`.
The tmux ANSI capture contains three B17 hyperlink runs with the same complete destination and `id=bbr-draft-4-1176`.
The complete destination includes `?first=one&second=two#complete-fragment`.
The human confirmed the B17 Cmd+Shift result with "looks good" after the restart.
The human also confirmed that the remaining styled-link cases look good so far.
This result covers `B01` through `B18` in the current Ghostty and bbr Themes.
This terminal observation does not establish Cloud behavior.

### Agent-authored heading and paragraph examples

The agent added a third Review-level Draft and a two-level Draft Reply chain in `m23-review`.
Each body contains 22 labelled cases, `C01` through `C22`.
The cases cover all six ATX heading levels, both Setext levels, styled headings, soft and hard paragraph breaks, compressed blank lines, escaped punctuation, literal HTML, malformed heading markers, and long wrapped headings.
The terminal text capture shows three searchable authored owners, generated heading markers, joined soft breaks, retained hard breaks, and local literal fallback.
Human review of this group remains pending.
These unpublished examples remain agent-authored project fixtures.

The human confirmed that `C17` hides escape backslashes and displays the escaped stars and underscores as literal text.
This confirms `C17`, not the complete heading and paragraph group.
The human also confirmed the Setext heading examples `C07` and `C08` after reviewing their raw Markdown syntax.
The human subsequently reported that the complete heading and paragraph group passed.
This result covers `C01` through `C22` with the hash marker trial in the current Ghostty and bbr Themes.

### Agent-authored emoji examples

The agent added a fourth Review-level Draft and a two-level Draft Reply chain in `m23-review`.
Each body contains 28 labelled cases, `D01` through `D28`.
The cases cover styled prose and links, all five listed thumb and technologist skin tones, joined emoji, flags, unknown names, case sensitivity, escapes, literal code, unchanged destinations, headings, lists, quotes, tables, ASCII emoticons, adjacent emoji, and wrapping.
The agent checked the chosen compound technologist, flag, and heart names against the pinned emoji fixture.
The terminal text capture shows three searchable authored owners, converted prose, and literal code and destination shortcodes.
The agent expanded the root Draft and positioned the review at `D01`.
Human emoji review remains pending.
These unpublished examples remain agent-authored project fixtures.

### D10 emoji-style preference

The human requested `❤️` instead of `❤` for `:heart:` and the same display preference for similar icons where possible.
The implementation now adds U+FE0F to a converted single-symbol fallback when Unicode 16.0 defines its emoji-style variation and the symbol defaults to text.
The pinned Atlassian catalog and its fallback bytes remain unchanged.
Existing selectors, skin tones, keycaps, flags, and joined sequences retain their fixture bytes.
Authored Unicode, code, escapes, and destinations retain their existing literal behavior.
This preference changes the earlier exact-display-byte expectation for the affected shortcodes.
The resolved planning decision remains unchanged.

The shared conversion check failed with the old heart display before the change.
Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build test-emoji --summary all`: all 21 tests passed.
- `zig build`.
- `zig build test --summary all`: all 1,252 tests passed across 18 build steps.
- `git diff --check`.

Search checks cover `❤`, `❤️`, and `:heart:` against the converted shortcode.
Rendering checks cover the complete emoji-style glyph, terminal width, and interaction backgrounds.
The full suite retains the raw authored storage and clipboard checks.

The agent restarted `m23-review` and added `D29` through `D34` in a Review-level Draft and two nested Draft Replies.
These cases compare preferred symbols, combined styles, authored Unicode, literal code, escapes, destinations, and wrapping.
The root Draft is expanded at `D29`.
The terminal capture shows `❤️ ☀️ ☁️ ⚠️ ✈️ 🖥️ ✂️` and preserves the literal comparisons.
The human confirmed that D10 now looks good and that the remaining emoji cases also look good.
This result covers `D01` through `D34` in the current Ghostty and bbr Themes.
These observations remain agent-authored project evidence rather than Cloud observations.

### Agent-authored list examples

The agent added `E01` through `E22` in a Review-level Draft and a two-level Draft Reply chain in `m23-review`.
The cases cover unordered marker forms, first-number continuation, zero starts, marker width growth, all four parent and child list-type combinations, nesting spaces, styled wrapping, authored continuations, blank-line boundaries, literal unsupported numbering, code, quotes, deep nesting, and empty items.
The terminal text capture shows normalized bullets, incremented ordered numbers, nested child lists, and continuation alignment.
The root Draft is expanded at `E01`.
The human confirmed that E04 looks good and that the remaining list cases also look good.
This result covers `E01` through `E22` in the current Ghostty and bbr Themes.
These examples remain unpublished agent-authored project fixtures.

### Agent-authored table examples

The agent added `G01` through `G15` in a Review-level Draft and two nested Draft Replies in `m23-review`.
The cases cover alignment, optional outer pipes, escaped pipes, code pipes, literal spaces, missing cells, extra cells, Unicode, emoji, styles, links, references, image text, wide tables, prose boundaries, malformed separators, one-column tables, and empty headers.
`G10` forces the narrow header-labelled presentation with long cell text.
The terminal capture shows aligned columns, literal code, empty missing cells, and the literal extra-cell row.
The root Draft is expanded at `G01`.
The human confirmed that `G01` through `G12` look good after the responsive-column and divider changes.
The human also confirmed that `G13` through `G15` pass.
This result completes the `G01` through `G15` table cases at the current review width and Themes.
These examples remain unpublished agent-authored project fixtures.

### Table divider and responsive-column preferences

The human requested a divider below table column headers.
The human clarified that this request does not apply to Markdown headings.
The human also requested wrapped table columns before the narrow header-labelled fallback.
The human clarified that this request applies to valid tables such as `G10`, rather than the separator-free `G12`.

The implementation measures all cells before it projects the table.
When the natural widths fit, it retains those widths.
Otherwise, it calculates a shared column-width cap that fits the body width and the column separators.
Short columns retain their natural widths.
Long columns wrap while the cap remains at least 16 terminal columns.
Below that cap, the implementation retains the header-labelled fallback.
The 16-column threshold is the agent's initial trial value.

Each column retains its alignment, styles, links, and authored source ranges across wrapped rows.
The generated header divider uses the dim gutter foreground.
The divider owns no authored bytes or hidden separator line.
Search Preview and ReviewCards use the same projection.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,254 tests passed across 18 build steps.
- `git diff --check`.

The regression checks cover the 16-column boundary, width redistribution, repeated reprojection, styles, links, source ownership, and divider styling in every Theme.
The agent restarted `m23-review` and positioned the root Draft at `G10`.
The terminal capture shows wrapped columns and a header divider.
The existing `G10` caption describes the earlier fallback expectation.
The new expected result is wrapped columns at the current width and header-labelled cells below the trial threshold.
The human approved these changes in `G01` through `G12` at the current review width.

The human also requested dim styling for all table dividers.
Vertical column separators now use the same dim gutter foreground as the horizontal header divider.
The shared renderer applies that style in ReviewCards and Search Preview.
The updated rendering check covers vertical separators in every Theme.
Formatting, build, all 1,254 tests, and `git diff --check` passed on the same native target.
The agent restarted `m23-review` at `G10` for human verification.

### Agent-authored link-edge examples

The agent added `H01` through `H20` in a Review-level Draft and two nested Draft Replies in `m23-review`.
The cases cover titles, image text, reference forms, case-insensitive names, duplicate definitions, missing references, unused definitions, definition order, code definitions, relative destinations, parentheses, spaces, bare-URL punctuation, shortcode boundaries, malformed links, HTML text, product shortcuts, and wrapped reference destinations.
The terminal capture shows resolved references, literal missing references, the first duplicate destination, and the literal duplicate definition.
The root Draft is expanded at `H01`.
The human confirmed that `H01` through `H20` look good.
The agent resized the tmux pane from 150 by 55 to 75 by 55 for the narrow-width review.
The human confirmed that the narrower viewport looks good.
The agent restored the pane to 150 by 55 at the human's request.
These examples remain unpublished agent-authored project fixtures.

### Agent-authored code examples

The agent added `I01` through `I16` in a Review-level Draft and two nested Draft Replies in `m23-review`.
The cases cover literal code, language identifiers, plain fallback, fence types and lengths, tabs, whitespace, indented code, wrapped code, nested containers, Suggestions, empty fences, inline delimiters, and unclosed fences.
The initial tmux paste did not retain the tab bytes.
The agent replaced all three fixture bodies through External Edit with Vim.
A read-only storage check confirmed the expected fixture content and eight authored tabs in each Draft body.
The fixture Draft TempIds are 29, 30, and 31.
The terminal capture shows four-column tab stops at the code content origin, including inside quotes and lists.
The agent restored the original process environment and positioned the expanded root Draft at `I01`.

The active XDG data directory contains no installed Grammars.
`I02`, `I03`, and `I05` currently exercise plain code fallback.
Human syntax-color review still requires an available Grammar.
The human confirmed that `I01` through `I16` look good in the current plain-fallback environment.
Syntax-color review remains pending until a Grammar is available.
These examples remain unpublished agent-authored project fixtures.

### Code-background rectangle preference

The human requested that code backgrounds fit the code block rather than fill the ReviewCard row.
The projection now records a code rectangle sized to the longest displayed line in each block.
The rectangle includes blank code rows and trailing authored spaces.
It excludes ReviewCard, Reply, quote, and list gutters.
The projection recalculates the rectangle when the body width changes.
It measures the full block before disclosure or Preview clipping.
Suggestions use the same bounded-background rule, including their generated label.
ReviewCards and Search Preview share the bounded paint operation.
Cursor and search styles still apply.

The new rendering regression covers Comments, Drafts, nested gutters, tabs, wide Unicode, blank code rows, Preview, and cursor focus in every Theme.
Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,255 tests passed across 18 build steps.
- `git diff --check`.

The agent restarted `m23-review` at the expanded root Draft's `I08` case.
The human confirmed that the bounded backgrounds look good in `I08`, `I09`, and `I12`.
The human also confirmed that the remaining code cases look good.

### I16 display-only fence closure preference

The human requested automatic closure for the unclosed fence in `I16`.
The implementation now treats an unclosed root fence as code through the end of the body.
An unclosed fence inside a quote or list ends at that container's boundary.
The projection hides the opening fence and applies the normal code background and literal-content rules.
Suggestions use the same closure rule.
The synthetic closing boundary owns no authored bytes.
Complete-body copying retains the missing closing fence exactly as authored.
Selection copying includes the existing opening fence and selected authored code lines, but never invents a closing fence.

Regression checks cover backticks, tildes, nested containers, literal shortcodes, local container exits, Highlighting acquisition, and exact Selection clipboard bytes.
Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,256 tests passed across 18 build steps.
- `git diff --check`.

The agent updated the `I16` caption in all three fixture Drafts through External Edit.
The code content still has no authored closing fence.
The agent restored the original process environment and positioned the expanded root Draft at `I16`.
The terminal capture shows literal code content without the opening fence.
The human confirmed that `I16` looks good with display-only fence closure.

### Complete-body clipboard review

The human reported that `y` on `I08` copies the entire Draft.
This result matches the complete-body behavior without Selection.
The agent clarified that selected code rows copy their selected authored lines and existing required fences.
Exact-byte clipboard review and the numbered Selection cases remain pending.

The agent positioned the cursor on the first code row in `I08` for the first Selection check.
Selecting that row with `v`, then invoking `y`, must copy `"```text\na\tb\n```\n"`.
The other three code rows and the rest of the Draft must not contribute.
The expected tab remains one authored tab byte rather than three displayed spaces.
The human verified the exact first-row Selection clipboard result after the tmux transport fix.

### tmux clipboard transport diagnosis

The human reported that `y` left the system clipboard at its previous value.
The agent reopened bbr after finding the tmux pane at a shell prompt.
The agent reproduced the failure by selecting an `I08` code row and checking the clipboard with `pbpaste`.
The clipboard remained unchanged across repeated attempts.

The tmux server used `set-clipboard external`.
That mode rejects application-originated OSC 52 clipboard writes from panes.
The agent changed the live server setting with `tmux set-option -s set-clipboard on`.
The same selection and `y` sequence then updated the system clipboard with the exact expected bytes.
Repeated checks alternated between the first and second `I08` code rows to detect stale clipboard content.
All those checks passed after the setting change.
The final system clipboard check returned `"```text\na\tb\n```\n"`.
This result verifies the real tab byte and both existing fence lines.

The cause was tmux's clipboard gate, rather than a wrong bbr register.
The earlier complete-body report did not establish a fresh system clipboard write.
Repeat the complete-body check after this transport fix.
The remaining numbered Selection cases still need human review.

The agent positioned the cursor on the first `I08` code row for the full-block Selection check.
Selecting all four code rows must copy `"```text\na\tb\nab\tc\nabc\td\nabcd\te\n```\n"`.
The opening and closing fence lines must each occur once.
The human confirmed the exact full-block Selection result, including four tab bytes and one copy of each fence.

### Joined-prose Selection check

The agent added Draft TempId 32 with the exact body `"first\nsecond"` and no ending newline.
The fixture has no authored caption so its bytes match numbered Selection example 1.
The current wide projection joins the two authored lines into one displayed row, `first second`.
The agent positioned the cursor on that row.
Selecting the row and invoking `y` must copy `"first\nsecond"` rather than the joined display text.
The human verified the exact wide-row result, including the authored newline and no ending newline.

The agent temporarily resized the pane from 150 by 55 to 40 by 55.
The projection now displays `first` and `second` as separate rows.
The cursor is on `first`.
Selecting only that row must copy `"first\n"`.
The human verified the narrow first-row result, `"first\n"`, without the second authored line.
Selecting both displayed rows must copy `"first\nsecond"`.
The human verified the narrow two-row result, `"first\nsecond"`, with each line present once and no ending newline.
The agent restored the pane to 150 by 55 after this check.

### Wrapped-prose Selection check

The agent added Draft TempId 33 with the exact body `"alpha bravo\ncharlie delta"` and no ending newline.
This fixture matches numbered Selection example 2.
The agent resized the pane to 40 by 55 and positioned the cursor on the displayed `alpha` wrap.
Selecting only `alpha` must copy the complete touched authored line, `"alpha bravo\n"`.
Selecting both `alpha` and `bravo` wraps must produce the same bytes once.
The unselected second authored line must not contribute.
The human verified the single-wrap result, `"alpha bravo\n"`, without the second authored line.
The human verified the two-wrap result, `"alpha bravo\n"`, with the authored line present once.

### Table-cell Selection check

The agent added Draft TempId 34 with the exact table from numbered Selection example 3.
The body is `"| Name | State |\n| --- | --- |\n| Ada | Ready |\n| Bo | Waiting |"`.
The agent positioned the cursor on the narrow displayed `Ready` value at 40 by 55.
Selecting that row must copy `"| --- | --- |\n| Ada | Ready |\n"`.
The separator is a required hidden delimiter.
The generated header labels, authored header row, and unselected Bo row must not contribute.
The human verified the exact narrow-cell result, including the required separator and the complete Ada row.
The human also verified the exact wide-row result, matching the narrow-cell result.

### Reference-link Selection check

The agent added Draft TempId 35 with the exact body `"[docs][id]\n\n[id]: https://example.invalid/"`.
This fixture matches numbered Selection example 4.
The agent positioned the cursor on the wide displayed link row at 150 by 55.
Selecting that row must copy `"[docs][id]\n[id]: https://example.invalid/"`.
The required definition must appear without the unselected blank line.
The human verified the exact wide-link result, including the definition and no blank line or ending newline.
The human also verified the exact narrow-destination result, matching the wide-link result.
The human verified the exact label-only result, `"[docs][id]\n"`, without the definition.

### Shared-reference definition check

The agent restored the pane to 150 by 55.
The agent added Draft TempId 36 with the exact body `"[docs][id]\n[more][id]\n\n[id]: https://example.invalid/"`.
This fixture matches numbered Selection example 5.
Both reference uses appear on one displayed row.
Selecting that row must copy `"[docs][id]\n[more][id]\n[id]: https://example.invalid/"`.
The shared definition must follow both authored uses and appear once.
The human verified the exact result, with both uses followed by one shared definition.

### Compressed-spacer Selection check

The agent added Draft TempId 37 with the exact body `"A\n\n\nB"`.
This fixture matches the first part of numbered Selection example 6.
The projection compresses the two authored blank lines into one displayed spacer.
The agent positioned the cursor on that spacer, with A above and B below it.
Selecting only the spacer must copy `"\n"` rather than both authored blank lines.
Selecting A, the spacer, and B must copy `"A\n\nB"`.
The human verified that selecting only the spacer copies exactly `"\n"`.
The human verified the three-row result, `"A\n\nB"`, without the second compressed blank line.

The agent added Draft TempId 38 for the whitespace variant of numbered Selection example 6.
The body is `"J06b Whitespace spacer\n\nA\n  \n\t\nB"`.
The caption provides a unique search target outside the tested Selection.
The agent used External Edit to retain the tab byte and verified the exact stored body.
The first blank line between A and B contains two spaces.
The next blank line contains a tab.
The cursor is on the displayed spacer between A and B.
Selecting only that spacer must copy `"  \n"`.
The unselected tab line must not contribute.
The human requested that the agent verify the clipboard directly.
The agent selected the spacer through bbr and read the system clipboard with `pbpaste`.
The exact bytes were `[32, 32, 10]`, which are two spaces followed by one newline.
The tab line did not contribute.
This result is agent-verified live clipboard evidence.

### Agent verification of the remaining clipboard checks

The human requested direct agent verification of the remaining clipboard bytes.
The agent drove the real `m23-review` UI and compared `pbpaste` bytes with the expected strings.
These checks used the live tmux clipboard setting established above.

| Contract | Fixture | Agent-verified result |
| --- | --- | --- |
| 7. Existing code fences | Draft TempId 39. Exact body: `"```zig\nconst x = 1;\nconst y = 2;\n```\nafter"`. | First-row Selection copied `"```zig\nconst x = 1;\n```\n"`. Both code rows copied `"```zig\nconst x = 1;\nconst y = 2;\n```\n"`. Checks passed at 150 and 40 columns. The upward Selection also passed. Unselected code and following prose did not contribute. |
| 8. Setext heading | Draft TempId 40. Exact body: `"Title\n=====\ntext"`. | Heading Selection copied `"Title\n=====\n"`. At 35 columns, selecting only the generated `#` row changed neither the system clipboard nor tmux's paste-buffer list. The heading check passed again after restoring the width. |
| 9. Review Search reveal | Draft TempId 41. Exact body: `"first\nsecond\n\nhidden tail"`. | The agent selected `local #41` for the Review Search query `first second`. After the narrow projection completed, selecting only `first` copied `"first\n"`. The second line and tail did not contribute. Complete-body copying also matched all authored bytes. |
| 10. Disclosure footer | Draft TempId 42. Exact body: `"J10 Footer check\n\none\n\ntwo\n\nthree  \nfour"`. | The collapsed footer copied `"2 hidden rows · 8 total · enter to expand"`. The expanded footer copied `"8 total rows · enter to collapse"`. Copying without Selection on the footer matched the complete authored body, including the trailing spaces and no ending newline. |

The footer checks also passed in both layouts and both Selected Versions.
The agent restored the unified layout, the new Selected Version, and the 150 by 55 viewport.
These results are live project evidence from unpublished agent-authored Drafts.

Numbered example 11 needs source lines around an inline Comment.
The approved live authoring scope remains Review-level Comments and Replies.
The agent verified example 11 through the existing exact-byte acceptance test instead.
That test covers both layouts, both Selection directions, and wide and narrow reprojection.
The yank suite also covers opposite Selected Version exclusion and inherited Reply scope.
These are automated-test results, rather than live inline-Comment observations.

`zig build test-yank test-m23-acceptance --summary all` passed all 54 tests across 10 build steps.

### Narrow Review Search resize crash

The live example 9 check exposed an integer overflow while resizing an open Review Search overlay from 150 to 40 columns.
The renderer received the previous wide geometry after the physical window became narrow.
Clipping the body window made its width smaller than the previous divider offset.
The subtraction in `drawReviewSearch` then overflowed.

The agent added a rendering regression with the same wide-projection and narrow-window combination.
`zig build test-m23-acceptance --summary all` reproduced the crash before the fix.
The renderer now waits when the published overlay rectangle does not fit the physical window.
It uses the shared geometry again when the replacement projection fits.
The regression also checks that the updated narrow geometry draws its result list and Preview.
The original live resize and search-reveal sequence passed after the fix.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,257 tests passed across 18 build steps.
- `zig build test-m23-acceptance --summary all`: all 14 tests passed.
- `git diff --check`.

The clipboard checks above complete the planned byte examples through a combination of human verification, live agent verification, and automated acceptance tests.
Human review across the remaining Themes and published Comment roles still remains open.
Syntax-color review still needs an available Grammar.
Human-authored Cloud list evidence remains pending.

### Human interaction-background review of B16

The human confirmed that B16 stays readable with cursor, Selection, and search backgrounds in the current Catppuccin Mocha Theme.
The check used the styled-link Draft with the query `combined code`.
The human also observed the faint search background after clearing Selection.
The agent explained that clearing Selection retains search highlighting.
The human accepted the explanation and requested the next review topic.
This result covers B16 in the current Theme, not the complete interaction-background checklist.

### Human code interaction-background review of Draft 39

The agent selected both code rows in Draft 39 and placed a Buffer Search match on the first row.
The human confirmed that the code stays readable under cursor, Selection, and search backgrounds.
The human also approved the code-background boundary before the following prose and outside the left gutter.
This result covers the plain code fixture in the current Catppuccin Mocha Theme.
Syntax-color review and other Theme variants remain pending.

The agent then restarted `m23-review` with the built-in `light` Theme through a temporary `XDG_CONFIG_HOME`.
The temporary configuration is `/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/m23-light/bbr/config.toml`.
The agent positioned Draft 39 at the top with the Buffer Search query `const x = 1`.
Human light-Theme review remains pending.

The human then confirmed that Draft 39 looks good in the built-in `light` Theme.
This result covers code readability, the darker code background, its boundary, and the requested Selection and search comparison.
Other format combinations in the light Theme remain pending.

The human also confirmed that B16 looks good in the built-in `light` Theme.
This result covers combined bold, italic, inline code, and link presentation with Selection and search backgrounds.
The agent requested a comparison after clearing Selection.
The human approved both states.

The agent then restarted `m23-review` with the built-in `system` Theme through a temporary `XDG_CONFIG_HOME`.
The temporary configuration is `/var/folders/dq/11fgn5lj5l539gh02ty2qjv40000gn/T/opencode/m23-system/bbr/config.toml`.
The agent positioned Draft 39 at the top with the Buffer Search query `const x = 1`.
Human system-Theme review remains pending.

### System-Theme contrast failure and trial fix

The human rejected the system-Theme Selection and added or removed Diff presentation on 2026-10-15.
The screenshot shows pale syntax text on a bright green added band and a bright yellow search match.
The existing system Theme used ANSI foreground colors as diff and search backgrounds.
Its cursor background and code background also used the same ANSI gray.

The agent added a contrast regression with the reported Catppuccin Mocha terminal palette.
`zig build test-inline-markdown --summary all` failed that regression before the fix.
The regression checks syntax and Markdown foregrounds against diff, changed-run, cursor, code, and search backgrounds.
It includes selected diff bands and selected changed runs.
The tested color pairs must have a contrast ratio of at least 3 to 1.
This finite palette check does not establish support for every terminal palette.

The trial uses muted RGB diff, cursor, code, and search backgrounds in the system Theme.
Cursor and Selection brighten RGB bands slightly and retain their hue.
Syntax colors still use the terminal palette.
Syntax comments and punctuation now use ANSI white instead of the low-contrast bright-black color.
The disclosure-footer foreground also uses ANSI white before its dim attribute.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,258 tests passed across 18 build steps.
- `git diff --check`.

The first full-suite run exceeded the 120-second tool timeout during the version integration checks.
The agent repeated the full suite with a 300-second timeout and received the passing result above.

The agent restarted `m23-review` with the temporary system-Theme configuration.
Draft 39 is at the top with both code rows selected and the query `const x = 1`.
Live ANSI captures confirm the muted added band, selected code background, and both search-match backgrounds.
Human review of the trial remains pending.

The human then confirmed that the updated system-Theme contrast is better.
This result covers the selected code and Diff bands presented for the comparison.
The system-Theme combined-style review remains pending.

The human then approved B16 in the updated system Theme.
This result covers combined bold, italic, inline code, and link presentation under Selection and search backgrounds.
The human also approved the requested comparison without Selection.

### Human Review Search Preview result

The agent opened Review Search with the query `B16` in the updated system Theme.
The result list contained the styled-link Draft and its two Draft Replies.
The human approved all three Previews.
The review covered B16 style composition and the complete wrapped B17 destination and optional title.
This result covers the current wide viewport and system Theme.

The agent then resized `m23-review` to 40 columns by 55 rows.
The agent sent SIGWINCH to bbr after tmux resized the terminal.
Review Search placed Results above Preview at that width.
The human approved all three narrow Previews, including the wrapped B17 destination, title, and combined styles.

### Human capped Draft Reply indentation result

The agent resized `m23-review` to 75 columns by 55 rows and positioned the two styled-link Draft Replies together.
At that width, the indentation budget is zero.
Both Draft Replies used the same body width and showed `depth 1` or `depth 2` in the header.
The human confirmed that the depth labels make the nesting clear and that the wrapping stays readable without extra indentation.
This result covers the current unpublished Draft Reply chain in the updated system Theme.
Published ancestry and deeper mixed ancestry remain separate review requirements.

The agent restored the 150-column by 55-row viewport and positioned the code examples at I02.
Live ANSI capture confirms that I03 and I05 already use the JavaScript BuiltInGrammar.
Keywords, numbers, strings, punctuation, and the function name have syntax foreground colors.
I02 remains plain because the Zig Grammar is unavailable.
The missing UserGrammar does not block the JavaScript syntax-color review.

The human approved the I03 syntax colors in the updated system Theme.
This result covers distinct and readable keyword, number, string, and function-name colors.
The requested check also covered literal Markdown inside strings.

The agent then selected I03's function and return rows in the first Draft Reply with the query `greet`.
The human approved the syntax colors under Selection and search backgrounds and the requested comparison without Selection.
The agent explicitly expanded the Draft Reply before selecting across the code rows.

### Subtle matched-line backgrounds in Review Search Preview

The human approved the Review-level syntax-colored Previews but rejected the source File Previews.
The source matched line had a stark light background that obscured the query highlight.
The human requested a subtle matched-line background for both source and ReviewBody results, including Comments and Drafts.

The source renderer reused `picker_selected`, which reverses foreground and background in the system Theme.
The query background inherited that reversal.
ReviewBody Preview did not apply a matched-line background.

The agent added a headless rendering regression across every built-in Theme.
`zig build test-m23-acceptance --summary all` reproduced the failure before the fix.
The regression covers source syntax foregrounds, Review-level Comments and Drafts, formatted prose, code, and the full matched-row width.
It checks that the query keeps its distinct background without reverse video.
Adjacent rows retain their existing backgrounds.

Both Preview renderers now apply the shared cursor-background tint to the matched row.
The tint changes only backgrounds outside the query match.
Syntax colors, Markdown attributes, links, and code-background boundaries retain their existing behavior.
The source renderer no longer uses the selected picker-row style for the matched line.
Existing reference-link, wrapped-destination, tab, quote, and Suggestion tests now expect the requested line tint around query matches.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test-m23-acceptance --summary all`: all 15 tests passed.
- `zig build test --summary all`: all 1,259 tests passed across 18 build steps.
- `git diff --check`.

The agent restarted `m23-review` in the updated system Theme and reopened Review Search with `greet`.
Live ANSI capture confirms the ReviewBody code-row tint and the separate query background.
The agent then selected a source File result for the next human comparison.
Human review of the new shared tint remains pending.

The human then approved the shared matched-line tint in the updated system Theme.
This result covers the requested comparison between source File results and Review-level results.
The human confirmed that the line tint and distinct query highlight look good.

The agent then restarted `m23-review` with the temporary built-in `light` Theme configuration and reopened `greet`.
The human approved the syntax colors, subtle matched-line tint, and distinct query highlight in both Review-level and source File Previews.
The requested Review-level check covered the first three results for the Draft and its two Draft Replies.

The agent restored the configured Catppuccin Mocha Theme and reopened `greet`.
The human approved syntax readability, the subtle matched-line tint, and the distinct query highlight for both Review-level and source File Previews in that dark Theme.
This completes the requested Preview comparison across the reviewed light, dark, and system Themes.

### Authorized live Cloud list observations

The human requested agent authoring and publication when asked to supply the next list examples.
This instruction replaces the earlier human-only authoring requirement for these list examples.
The agent published one Review-level Comment and one Reply in the agreed PullRequest on 2026-10-15.
The earlier unpublished Draft fixtures retain their original evidence class.

- Root Comment: [883824183](https://bitbucket.org/check24/pr-webapp/pull-requests/2425/_/diff#comment-883824183).
- Reply: [883824241](https://bitbucket.org/check24/pr-webapp/pull-requests/2425/_/diff#comment-883824241), parent `883824183`.
- Evidence: [Cloud list observations on 2026-10-15](../evidence/cloud-lists-2026-10-15/README.md).

The evidence retains exact authored Markdown, selected Cloud response fields including `content.raw` and `content.html`, and displayed bbr text.
The agent fetched both Comments again and verified that the saved fields match the live responses.
The returned raw Markdown also matches each authored file byte for byte.

The root's authored ordered markers are `3.` and `8.`.
Cloud returns `<ol start="3">` with consecutive list items and an unordered child list.
bbr displays `3.` and `4.` with the same nested list structure.
The Reply's unordered parent contains authored ordered markers `7.` and `2.`.
Cloud returns a nested `<ol start="7">` with consecutive items.
bbr displays the children as `7.` and `8.`.
Both Cloud responses retain the requested inline formatting as HTML elements.
These finite observations agree with the implemented first-number and mixed-nesting policy for the tested four-space cases.
No browser-presentation evidence was captured.

The first in-process bbr refresh remained in its loading state.
The agent closed bbr normally and reopened the PullRequest.
The new Session displays the complete published root and Reply above the Pending section.
The current viewport is 150 columns by 55 rows with the configured Catppuccin Mocha Theme.
Human review of the published Comment and Reply remains pending.

### Human browser and bbr list comparison

The human reported that the root displays `3.` and `4.` with nested unordered children.
The Reply displays unordered parents L03 and L04 with an ordered child list.
The human then clarified that bbr shows the child markers as `7.` and `8.`, while the browser shows `g.` and `h.`.
The live terminal capture independently confirms the decimal markers.
The captured Cloud HTML uses `<ol start="7">` with two consecutive items and no explicit marker type.
Both presentations retain the same start value, item order, and nesting.
The browser's alphabetic markers are a presentation difference from bbr's decimal markers for this tested case.
The browser observation is a human report, separate from the saved wire evidence and terminal capture.
The [evidence note](../evidence/cloud-lists-2026-10-15/README.md#human-browser-and-terminal-comparison) records that distinction.
Human review of the published inline styles remains pending.

The human then approved bold, italic, inline code, strikethrough, and links in the published Comment and Reply in the browser.
This approval is browser-presentation evidence.
Human review of the same published inline styles in bbr remains pending.

### Published Reply prose contrast

The human reported that the published formatting looks good so far in bbr but found the Reply prose too dim.
The screenshot shows normal parent prose and muted Reply prose in Catppuccin Mocha.
The human requested removal of the Reply dimming.

Published Replies now use the same prose foreground as parent Comments in every built-in Theme.
Reply indentation and the existing backgrounds retain their separate roles.
The shared Theme test checks equal parent and Reply prose foregrounds and no dim attribute across every built-in Theme.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,259 tests passed across 18 build steps.
- `git diff --check`.

The agent restarted `m23-review` with the configured Catppuccin Mocha Theme.
The published root and Reply are visible together at the top.
Live ANSI capture confirms that both prose captions use `#cdd6f4`.
Human review of the new Reply prose contrast remains pending.

The human then approved the updated published Reply prose contrast in Catppuccin Mocha.

### Mixed published and Draft Reply ancestry

The agent added Draft TempId 43 through the Composer as a Reply to published Comment `883824241`.
Read-only Draft inspection confirms that parent identity and the unpublished Draft state.
The Draft begins `K01 Mixed ancestry. Draft Reply to the published Reply.`
Its body includes bold, italic, inline code, strikethrough, a link, and a JavaScript fenced block.
The terminal places it below the published Reply at depth 2, beneath the depth-0 published root.
All three owners are visible together in the 150-column by 55-row viewport.
This Draft is an unpublished project fixture.
Human review of the mixed ancestry remains pending.

The human approved the mixed ancestry, inline styles, and JavaScript code in the wide Catppuccin Mocha viewport.

The agent then resized to 75 columns by 55 rows and expanded K01's body.
The published root and Reply bodies remained collapsed while the Draft Reply stayed visible.
The capped Replies showed `depth 1` and `depth 2` and retained the available body width.
The human approved the mixed nesting, wrapped JavaScript, and inline styles at that width.

The agent restored the wide viewport and selected the published Reply's L03 parent and both ordered children with the query `italic`.
The human approved bold, italic, inline code, strikethrough, and links under the interaction backgrounds and after clearing Selection.

The agent then applied the same Selection and search comparison to the published root's L01 item and its two unordered children.
The human approved all five styles in the published parent Comment under those interaction backgrounds.

The agent then selected K01's styled paragraph through its JavaScript code row with the query `italic`.
The human approved the Draft Reply's inline styles and syntax colors under Selection and search backgrounds and without Selection.

### Remaining published-format coverage

The agent checked the remaining human checklist after the mixed Draft Reply interaction review.
The earlier complete A through I groups primarily cover unpublished Drafts and Draft Replies.
The published list examples cover mixed lists and five inline styles, but not all published format combinations.

The agent prepared one combined format body with cases P01 through P16 in the agreed test PullRequest.
It is published as root Comment `883983200` and Reply `883983254` beneath that root.
The [published-format evidence note](../evidence/published-formats-2026-10-15/README.md) links both owners and the authored body.
The cases cover emphasis combinations, headings, emoji, lists, quotes, tables, image text, reference links, JavaScript syntax, and plain fallback.
These are agent-authored published examples for terminal review.
They do not replace the separately captured Cloud list response pairs.

The agent reopened bbr, expanded both published bodies, and positioned the parent at P01.
The viewport is 150 columns by 55 rows with Catppuccin Mocha.
The query `P01` has two Search Occurrences for comparison of the root and Reply.
Human review of these remaining published-format cases is pending.

The human approved P01 through P06 in both published owners.
This result covers ordinary prose weight, both emphasis nesting orders, inline code within emphasis, styled links, and combined strikethrough.

The human approved P07 through P09 in both published owners.
This result covers the styled heading, converted emoji, compound skin tone, unknown shortcode, escaped shortcode, and literal code shortcode.

The human approved P10 and P11 in both published owners in the wide Catppuccin Mocha viewport.
This result covers mixed list nesting, quote bars, inline styles, and the quoted JavaScript block's literal text, syntax colors, and bounded background.

The human approved P12 in both published owners in the wide Catppuccin Mocha viewport.
This result covers table styles, emoji, links, code pipes, escaped pipes, the empty missing cell, and extra-cell literal fallback.

The human approved the wide P13 and P14 image and reference-link presentation in both published owners.
The human requested a narrower viewport for the wrapping check.

The agent resized `m23-review` to 75 columns by 55 rows.
The human approved P13 and P14 wrapping in both published owners, including complete destinations, optional titles, query parameters, and the fragment.

The human approved P15 and P16 in both published owners at 75 columns by 55 rows.
This result covers JavaScript syntax colors, bounded code backgrounds, and literal unknown-language fallback.

The human approved P10 through P12 in both published owners at 75 columns by 55 rows.
This result covers list continuation alignment, quote bars, quoted code, and wrapped table cells with retained styles, links, and column alignment.

The agent restored the 150-column by 55-row viewport and opened both published format bodies in the built-in `light` Theme.
The human approved P01 through P16 in both owners, including readable prose, headings, emoji, tables, links, code backgrounds, and retained styles.

The agent then opened both published format bodies in the updated `system` Theme at the same wide viewport.
The human approved P01 through P16 in both owners there as well.
The normal published-format review now covers Catppuccin Mocha, light, and system Themes.

### Search-match contrast under full-body Selection

The agent selected both expanded published format bodies in the system Theme with the query `a`.
The human noted that emoji such as `:heart:` match because their authored shortcode names contain `a`.
This result follows the approved converted-shortcode search behavior.
The human requested stronger highlight contrast and the same interaction check in dark and light Themes.

The inactive system match background had only 1.01-to-1 luminance contrast against selected code and 1.06-to-1 against selected prose.
The agent extended the existing Theme regression to require at least 1.4-to-1 contrast against both selected backgrounds.
`zig build test-inline-markdown --summary all` failed that regression before the change.
The trial uses `#534668` for inactive matches and `#705018` for active matches.
Inactive-match contrast is now 1.43 to 1 against selected code and 1.50 to 1 against selected prose.
The tested syntax and Markdown foreground pairs still pass the existing 3-to-1 minimum.
These measurements use the reported Catppuccin Mocha terminal palette.

Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build test-inline-markdown --summary all`: all 24 tests passed.
- `zig build`.
- `zig build test --summary all`: all 1,259 tests passed across 18 build steps.
- `git diff --check`.

The agent restarted bbr with the updated system Theme and restored Selection across both published format bodies with query `a`.
Live ANSI capture confirms the new inactive search background.
The human approved the stronger system contrast with "looks better".
The agent restored the same query `a` and Selection across both published bodies in Catppuccin Mocha.
The human approved this interaction check with "looks good".
The agent restored the same query `a` and Selection across both published bodies in the light Theme.
The human approved this interaction check with "looks good".
This full-body Selection and search check now has human approval in system, Catppuccin Mocha, and light Themes.

### Checklist audit after the three-Theme interaction check

The approved A through I Draft groups and P01 through P16 published groups complete the individual format checks marked above.
The published full-body Selection and search review covers both Comments and Replies across the three reviewed Themes.
Earlier Draft interaction checks cover B16 and code, including syntax-colored code and Review Search Preview.
Full-format Selection and search review for Drafts and Draft Replies remains open.
The earlier clipboard section records the completed byte checks and the automated-only mixed source and inline-Comment case.
Final acceptance must retain that evidence distinction and the recorded browser list-marker difference.
The ticket remains `ready-for-human` until the remaining review and acceptance summary are complete.
The agent restored the configured Catppuccin Mocha Theme at 150 columns by 55 rows after the light check.

### Combined Draft format interaction fixtures

The agent created Review-level Draft TempId 44 and Draft Reply TempId 45 through the Composer on 2026-10-16.
Both remain unpublished, and TempId 45 names TempId 44 as its parent.
Their Q01 through Q16 bodies reuse the published format cases with Draft-specific labels and an unpublished-fixture introduction.
Read-only SQLite inspection confirmed both parent identities, unpublished states, and exact body equality with the Composer paste buffer.
The [Draft format evidence note](../evidence/draft-formats-2026-10-16/README.md) defines the body changes and review scope.

The agent expanded both bodies in Catppuccin Mocha at 150 columns by 55 rows.
Selection spans the root's Q01 through the Reply's final Q16 code row, with Buffer Search query `a`.
The human approved both Draft bodies in Catppuccin Mocha with "looks good".
The agent restored the same Selection and query `a` across both Draft bodies in the light Theme.
The human approved this check with "looks good".
The system Theme comparison remains pending.

The next system-Theme launch remained on `Loading PR #2425…`.
One normal close and restart produced the same result.
`bbr api get-pull-request --workspace check24 --repository pr-webapp --pull-request-id 2425 --json` returned `Forbidden`.
The public API endpoint remained reachable.
The remaining system-Theme Draft review is blocked on restored PullRequest access.
The agent did not record a system-Theme approval for these Draft fixtures.

The human requested another attempt, and the same direct PullRequest read succeeded.
The agent restarted bbr in the system Theme and restored both expanded Draft bodies with Selection and query `a`.
PullRequest access no longer blocks this check.
Human approval of the system-Theme Draft comparison remains pending.

The human approved the system-Theme Draft comparison with "looks good".
This completes the combined Draft and Draft Reply Selection and search comparison across Catppuccin Mocha, light, and system Themes.
They do not satisfy the required human-authored Cloud list evidence.

### E04 ordered-marker alignment preference

The human requested left padding on ordered numbers so their dots align across digit-count changes.
Each ordered list now uses its widest displayed number to set the marker width.
Nested lists retain independent marker widths.
Wrapped text and authored continuation blocks align with the padded item text.
Quotes inside ordered items retain that alignment.
The generated padding has no authored source bytes.

The agent added a regression check for digit growth, nested lists, quotes, independent lists, wrapped text, and generated source ownership.
Checks passed on native Apple Silicon macOS with the macOS 15 deployment target:

- `zig fmt --check build.zig src tests`.
- `zig build`.
- `zig build test --summary all`: all 1,253 tests passed across 18 build steps.
- `git diff --check`.

The agent restarted `m23-review` and positioned the expanded root Draft at `E04`.
The terminal capture shows aligned dots for `9.`, `10.`, and `11.`.
The human confirmed that the aligned E04 dots look good.

The human also requested the raw text for selected list cases and the basis for `E02` and `E15`.
Both cases follow the approved project list rules in presentation decision 04.
`E02` starts at the first authored number and increments for each later item.
`E15` keeps a sibling list-type switch literal when no blank line separates the types.

### Agent-authored quote examples

The agent added `F01` through `F12` in a Review-level Draft and two nested Draft Replies in `m23-review`.
The cases cover quote levels, paragraph joins, styles, links, emoji, wrapped text, code, paragraph gaps, hard breaks, quote exits, headings, empty quotes, and alternating quote and list levels.
The terminal capture shows the expected quote bars, paragraph joins, literal code, hard breaks, and the exit to unquoted prose.
The root Draft is expanded at `F01`.
The human confirmed that `F01` through `F12` pass in the current Ghostty and bbr Themes.
The human confirmed the literal `- Child bullet` in `F12` follows the blank-line rule.
The case label does not make that line a list item.
The agent clarified that the two trailing spaces in `F08` create a hard line break.
These examples remain unpublished agent-authored project fixtures.

## Final human review result

The human approved the reviewed format combinations in Comments, Replies, Drafts, and Draft Replies.
The review includes normal presentation and overlapping cursor, Selection, and search backgrounds in Catppuccin Mocha, light, and system Themes.
The recorded narrow-width checks cover wrapping, tables, bounded code backgrounds, Reply indentation, disclosure, and Review Search Preview.
The final combined Draft comparison closes the remaining interaction-review item.
Earlier pending statements record the session history rather than current acceptance status.

The accepted presentation changes include hash heading markers, emoji-style variation selectors, aligned ordered-list markers, and complete wrapped hyperlink destinations.
The human also accepted bounded code backgrounds, readable system-Theme bands, stronger system search matches, shared Preview line tint, and ordinary Reply prose contrast.
The regression checks and full test suite passed after the last source change.
That full run passed all 1,259 tests across 18 build steps.
Subsequent changes only add review evidence and checklist results.

### Evidence and compatibility limits

- [Cloud list evidence](../evidence/cloud-lists-2026-10-15/README.md) pairs exact authored Markdown with returned HTML and bbr output.
- [Published format evidence](../evidence/published-formats-2026-10-15/README.md) records human terminal approvals for the published owners.
- [Draft format evidence](../evidence/draft-formats-2026-10-16/README.md) records the final three-Theme Draft interaction review.
- The clipboard sections above distinguish human checks, live agent checks, and automated-only mixed source and inline-Comment checks.
- The reviewed terminal supports strikethrough. This session does not claim a live unsupported-terminal fallback result.
- System-Theme contrast measurements use the reported Catppuccin Mocha terminal palette.

The captured list syntax agrees with the implemented first-number and nesting rules for the tested cases.
The browser's alphabetic child markers and bbr's decimal child markers represent the same start value and item order.
The Cloud policy permits this terminal presentation difference because it separates syntax from terminal presentation.
No observed syntax conflict remains unresolved in these captured cases.
Support remains best-effort for the chosen scope rather than complete Cloud Markdown or emoji equivalence.

The temporary `Forbidden` response prevented one review attempt and succeeded on retry.
That observation does not establish a fixed loading defect or a Theme presentation failure.
The agent restored the configured Catppuccin Mocha Theme and the 150-column by 55-row viewport.
The PullRequest loaded successfully after restoration.
Ticket 14 is resolved.
