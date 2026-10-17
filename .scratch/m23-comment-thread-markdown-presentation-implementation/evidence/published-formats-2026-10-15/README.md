# Published format review on 2026-10-15

## Context

The agent prepared a combined format example for the remaining published Comment and Reply checks in the agreed test PullRequest.
The agent published the same [authored body](./body.md) as both owners through `bbr api create-comment`.

- Root Comment: [883983200](https://bitbucket.org/check24/pr-webapp/pull-requests/2425/_/diff#comment-883983200).
- Reply: [883983254](https://bitbucket.org/check24/pr-webapp/pull-requests/2425/_/diff#comment-883983254).
- Reply parent: `883983200`.
- PullRequest: `check24/pr-webapp` 2425.
- Publication date: 2026-10-15.

These are agent-authored published examples for human terminal review.
They are separate from the paired raw Markdown and Cloud HTML observations in [the list evidence](../cloud-lists-2026-10-15/README.md).

## Cases

| Cases | Review focus |
| --- | --- |
| P01 through P06 | Ordinary prose weight, both emphasis nesting orders, inline code in emphasis, styled links, and combined strikethrough. |
| P07 through P09 | Styled heading, converted emoji, compound skin tone, unknown shortcode, escaped shortcode, and literal code shortcode. |
| P10 and P11 | Lists, quotes, wrapped continuations, and nested JavaScript code. |
| P12 | Styled table cells, emoji, links, escaped pipes, code pipes, missing cells, and extra-cell literal fallback. |
| P13 and P14 | Image text and reference links with complete destinations and optional titles. |
| P15 and P16 | JavaScript syntax colors and literal unknown-language fallback. |

Both published bodies are expanded in `m23-review` at 150 columns by 55 rows with Catppuccin Mocha.
The current Buffer Search query is `P01`.
The two Search Occurrences allow direct comparison of the published parent and Reply.
Human review remains pending.

The human approved P01 through P06 in both published owners in Catppuccin Mocha.
This result covers ordinary prose weight, both emphasis nesting orders, inline code within emphasis, styled links, and combined strikethrough.
The remaining cases still need review.

The human approved P07 through P09 in both published owners in Catppuccin Mocha.
This result covers the styled heading, converted emoji, compound skin tone, unknown shortcode, escaped shortcode, and literal code shortcode.

The human approved P10 and P11 in both published owners in the wide Catppuccin Mocha viewport.
This result covers mixed list nesting, quote bars, inline styles, and the quoted JavaScript block's literal text, syntax colors, and bounded background.

The human approved P12 in both published owners in the wide Catppuccin Mocha viewport.
This result covers table styles, emoji, links, code pipes, escaped pipes, the empty missing cell, and extra-cell literal fallback.

The human approved P13 and P14 in both published owners at the wide viewport.
The human requested a narrower viewport to check wrapping before accepting that part of the review.

The human approved P13 and P14 wrapping in both published owners at 75 columns by 55 rows.
This result includes complete image and reference destinations, optional titles, query parameters, and the fragment.

The human approved P15 and P16 in both published owners at 75 columns by 55 rows.
This result covers JavaScript syntax colors, bounded code backgrounds, and literal unknown-language fallback.

The human approved P10 through P12 in both published owners at 75 columns by 55 rows.
This result covers list continuation alignment, quote bars, quoted code, and wrapped table cells with retained styles, links, and column alignment.

The human approved P01 through P16 in both published owners in the built-in `light` Theme at 150 columns by 55 rows.
This result covers readable prose, headings, emoji, tables, links, code backgrounds, and retained styles.

The human approved P01 through P16 in both published owners in the updated `system` Theme at 150 columns by 55 rows.
The normal format review now covers Catppuccin Mocha, light, and system Themes.

## Interaction-background comparison

The agent selected both expanded published bodies with the query `a` in the system Theme.
The human correctly identified that converted emoji also match their authored shortcode names, including `:heart:`.
The human requested stronger highlight contrast and the same interaction check in other Themes.

The inactive system search background was almost identical to selected code, with a luminance contrast ratio of 1.01 to 1.
The trial changes the inactive search background from `#39324a` to `#534668` and the active background from `#5a4a18` to `#705018`.
The inactive background now contrasts with selected code at 1.43 to 1 and selected prose at 1.50 to 1.
The existing foreground checks still require at least 3 to 1 for the tested Catppuccin Mocha palette.

Both published bodies are selected again in the updated system Theme with query `a`.
The human approved the stronger system contrast with "looks better".
The agent restored the same query `a` and Selection across both published bodies in Catppuccin Mocha.
The human approved this interaction check with "looks good".
The agent restored the same query `a` and Selection across both published bodies in the light Theme.
The human approved this interaction check with "looks good".
This full-body Selection and search check now has human approval in system, Catppuccin Mocha, and light Themes.
