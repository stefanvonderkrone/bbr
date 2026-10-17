# Bitbucket Cloud Comment emoji shortcodes

Research date: 2026-10-01.
Ticket: [Research Bitbucket Cloud emoji shortcodes](../issues/02-research-bitbucket-cloud-emoji-shortcodes.md).
Map: [M23 Comment thread and Markdown presentation fixes](../map.md).

## Result

No authoritative public catalog of Bitbucket Cloud Comment shortcodes was found.
Atlassian's Cloud documentation explicitly states, "We don't have a definitive list of supported emoji."
The page documents `:emoji:` syntax and gives `:mask:` as its example. [S1]

Atlassian publishes a catalog-like test fixture with shortcode names, Unicode fallbacks, and skin-tone variations.
The fixture maps `:white_check_mark:` to `✅`, U+2705. [S3]
This establishes an Atlassian mapping, not current Bitbucket Cloud Comment support.

The Cloud API documents raw content separately from rendered HTML.
Its Comment schema defines `content.raw` as "The text as it was typed by a user." [S2]
Shortcode retention is therefore the documented expectation.
This research did not observe a live Comment round trip.

## Scope and evidence

This report concerns Bitbucket Cloud REST API 2.0 Comments on a PullRequest.
It does not treat Data Center, Jira, Confluence, or an editor component as proof of Cloud Comment behavior.
The repository's Bitbucket and Presentation contexts supply the terms Comment, Draft, ReviewBody, and authored Markdown.
Review retains authored bytes. Presentation projects a ReviewBody.

Context7 supplied current Cloud service and API documentation after library resolution.
Direct reads of official documentation, OpenAPI, and Atlassian source files supplied the cited evidence.
All remote requests were reads of public documentation or source files.
There were no live Comment observations, remote writes, or reads of private content.

The evidence levels differ:

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| Cloud support documentation | Shortcode syntax and the `:mask:` example. | A complete catalog, aliases, exact Unicode output, or conversion contexts. |
| Cloud OpenAPI schema | Raw content and rendered HTML are separate fields. | A shortcode-specific observed round trip or browser editor serialization. |
| Atlassian frontend source and fixtures | Concrete Atlassian names, fallbacks, and component behavior at one commit. | The catalog or renderer deployed for Cloud Comments. |
| Unicode data | Code-point sequences and emoji qualification. | Bitbucket shortcode names or alias acceptance. |

## Documented Cloud subset and catalog gap

The Cloud guide says the name goes between colons.
It does not define allowed name characters, case matching, unknown-name behavior, or a Unicode version. [S1]
The documented example subset found here contains `:mask:`.
The guide does not give the example's code points.
Atlassian's fixture supplies `:mask:` → `😷`, U+1F637. Unicode confirms that character's name. [S3, S7]

The guide links David Coffey's user-created emoji list.
That link returned HTTP 404 during this research. [S1, S12]
Atlassian's link does not turn a user-created list into an authoritative catalog.
The list's data, license, update history, and completeness could not be checked.

The inspected public Cloud OpenAPI contains no path with `emoji` or `render` in its name. [S2]
This is a limit of that public specification, not proof that internal endpoints do not exist.
No published Cloud catalog export, catalog version, or shortcode update contract was found.

## Atlassian's fixture is a usable candidate source

The source is `elements/util-data-test/src/json-data/service-data-standard.json` in Atlassian's frontend mirror. [S3]
All source links below pin commit `f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e`.
The mirror describes its packages as reusable parts for Atlassian products. [S11]
It does not describe this fixture as the Bitbucket Cloud Comment catalog.

Each standard entry supplies `shortName`, `id`, `name`, `fallback`, and an image representation.
Some entries also supply `skinVariations` or `ascii` forms. [S3]
The fixture references staging sprite URLs.
The test-data loader imports this JSON directly. [S4]
The example resource combines standard, Atlassian, and site test data. [S13]
Those facts identify a test source, not a live Cloud catalog.

The following table reproduces fixture mappings.
None of these rows is a live Cloud Comment observation. [S3]

| Fixture shortcode | Fixture fallback | Fallback code points | Detail |
| --- | --- | --- | --- |
| `:white_check_mark:` | ✅ | U+2705 | Fixture ID `2705`. Unicode calls this "check mark button". |
| `:mask:` | 😷 | U+1F637 | Also the Cloud guide's example. |
| `:thumbsup:` | 👍 | U+1F44D | The fixture also lists ASCII form `(y)`. |
| `:thumbsup::skin-tone-2:` | 👍🏻 | U+1F44D U+1F3FB | Nested skin variation with a compound shortcode. |
| `:heart:` | ❤ | U+2764 | The fallback has no U+FE0F. |
| `:one:` | 1️⃣ | U+0031 U+FE0F U+20E3 | Fixture ID `31-20e3` omits U+FE0F. |
| `:flag_gb:` | 🇬🇧 | U+1F1EC U+1F1E7 | Two regional indicators. |
| `:woman_technologist:` | 👩‍💻 | U+1F469 U+200D U+1F4BB | A zero-width joiner sequence. |
| `:woman_technologist::skin-tone-2:` | 👩🏻‍💻 | U+1F469 U+1F3FB U+200D U+1F4BB | A modifier inside a joiner sequence. |

Unicode 17.0 confirms the corresponding sequences.
Its fully qualified red heart is U+2764 U+FE0F, rather than the fixture's bare U+2764. [S7]
These differences matter when specifying exact output bytes.
An emoji image also does not prove which Unicode sequence a terminal replacement must use.

Atlassian's `emojiIdToEmoji` helper shows why the ID alone is insufficient.
The helper adds presentation selectors and keycap selectors.
It declines flags so callers use Twemoji.
A feature flag controls whether the helper returns Unicode at all. [S6]
This is component behavior, not a Cloud Comment renderer contract.

### Aliases and unknown names

The inspected fixture includes `:thumbsup:` and `:flag_gb:`.
It lacks `:+1:`, `:thumbs_up:`, `:gb:`, `:uk:`, `:woman-technologist:`, and `:female_technologist:`. [S3]
Absence from a fixture does not prove rejection by Cloud.
The Cloud guide does not define those aliases. [S1]

The fixture's ASCII forms are a separate field.
An ASCII form such as `(y)` does not establish a colon-shortcode alias. [S3]
Atlassian's `EmojiRepository.findByShortName` uses an exact map lookup.
It returns no matching description for an absent name. [S5]
This establishes component lookup behavior only.
It does not establish Cloud case sensitivity or Cloud's rendered output for an unknown name.

## Raw Markdown retention

The OpenAPI `pullrequest_comment` schema inherits the base `comment` schema.
The base schema defines these fields. [S2]

| Field | Official description |
| --- | --- |
| `content.raw` | "The text as it was typed by a user." |
| `content.markup` | "The type of markup language the raw content is to be interpreted in." |
| `content.html` | "The user's content rendered as HTML." |

The PullRequest Comment GET documentation also shows `raw`, `markup`, and `html` in the response. [S14]
This supports retention of authored shortcodes in raw content while HTML shows the emoji.
It does not explicitly document an emoji-specific example or exact byte equality after submission.

Browser authoring and API retention are separate questions.
An editor can convert input before the request reaches the API.
The schema does not prove which Markdown a browser submits after emoji selection or rich-text editing.
The exact treatment of line endings, escaped colons, and shortcode aliases remains unobserved.

The map already requires search to accept displayed emoji and authored shortcodes.
That is an agreed requirement, not a claim about Cloud search behavior.
This report does not specify search matching or change authored content.

## Conversion contexts remain unproven

The Cloud guide documents Python-Markdown and lists `fenced_code` and `codehilite` among its extensions. [S1]
It does not describe the order of emoji conversion relative to Markdown parsing.
General Markdown code rules do not establish that extension order.

Every outcome in the following table remains unknown for current Cloud Comments.
The examples identify missing evidence, not expected output.

| Context | Evidence still needed |
| --- | --- |
| Plain prose | Current rendering of `:mask:` and `:white_check_mark:` with raw content alongside it. |
| Case | Results for `:mask:`, `:MASK:`, and `:Mask:`. Uppercase `:EMOJI:` in a syntax placeholder is not a case rule. |
| Unknown name | Output for `:bbr_unknown_emoji_20261001:`. Literal retention or replacement is not documented. |
| Escape | Results for `\:mask:`, `:mask\:`, escaped underscores, and two backslashes before a shortcode. |
| Inline code | Whether backticks protect `:mask:` and preserve its literal text. |
| Fenced code | Whether backtick and tilde fences protect `:mask:`. Language labels can require separate checks. |
| Indented code | Whether four-space indentation protects `:mask:`. |
| Link text | Whether `[:mask:](https://example.invalid/)` converts the visible label. |
| Link destination | Whether a shortcode in an explicit destination remains unchanged in `href`. |
| Bare URL or autolink | Treatment of `https://example.invalid/:mask:` and its angle-bracket form. |
| Link title or image text | Treatment of shortcodes in a title, image alternative text, or image destination. |
| Adjacent text | Treatment of `x:mask:y`, adjacent shortcodes, punctuation, and multiline names. |
| Alias or compound name | Acceptance of `:+1:`, `:uk:`, and nested skin-tone forms from the fixture. |

The selected Data Center guide cannot fill these Cloud gaps.
Atlassian component source cannot fill them either without evidence that Cloud uses the same path and data.

## Provenance, license, and updates

The test-data package and emoji package each declare Apache License 2.0. [S8, S15]
The monorepo README warns that packages can have different licenses. [S11]
The inspected fixture is inside the Apache-licensed test-data package.
No separate fixture-specific license or complete upstream data history was found in the inspected files.

Apache 2.0 permits reuse subject to its redistribution terms.
Those terms include a license copy, retained notices, change notices, and applicable NOTICE attribution. [S9]
The fixture's external sprite URLs do not establish permission to redistribute those image assets.
This report does not copy sprite images or choose a dependency.

Unicode supplies the sequence data under its data license.
Unicode License V3 requires its copyright and permission notice with copied data or associated documentation. [S10]
Unicode sequence data does not supply Bitbucket shortcode acceptance rules. [S7]

A source commit can identify a fixture snapshot.
It cannot identify the catalog deployed by Bitbucket Cloud.
The fixture does not declare a Cloud catalog version or update schedule. [S3]
The component's selector logic also uses an explicit Unicode 14.0 variation-base list. [S6]
Current source therefore does not imply one uniform, current Unicode version across all component data.

## Evidence-backed choices for the later human decision

This report selects no catalog size, conversion policy, Unicode normalization, or dependency.
The available choices have different evidence limits.

| Choice | Evidence available | Limit |
| --- | --- | --- |
| Documented Cloud subset | `:emoji:` syntax and the `:mask:` example. [S1] | Does not establish the required `:white_check_mark:` behavior or broad coverage. |
| Observation-backed subset | The Atlassian fixture supplies candidate names and Unicode fallbacks. [S3] | Requires later Cloud Comment observations for each supported name and context. |
| Pinned Atlassian fixture as a broader candidate catalog | First-party source, nested variations, and an identified package license. [S3, S8] | Requires an explicit best-effort compatibility claim. It is not a Cloud catalog. |
| Vendor-confirmed complete catalog | Atlassian would need to identify the deployed names, aliases, and conversion rules. | No such public contract was found. |

An npm emoji catalog, GitHub catalog, or Unicode version alone cannot prove complete Cloud compatibility.
The same shortcode syntax does not establish the same names or mappings.

Before bbr can claim complete Cloud shortcode compatibility, it needs evidence for these facts:

- The complete deployed Cloud Comment name set, aliases, and version.
- Exact Unicode mappings, including selectors, modifiers, flags, and joiner sequences.
- Parser boundaries, case rules, escapes, code, URLs, and unknown names.
- Raw shortcode retention through API authoring and browser authoring.
- The relation between server-rendered HTML and the current browser presentation.
- A source and update process that can track Cloud changes.

Later live evidence can compare synthetic authored Markdown, `content.raw`, `content.html`, and the browser display.
An existing synthetic fixture can supply read-only evidence.
This research did not create one.
Finite observations establish the tested subset at that date, not an undisclosed complete catalog.

## Sources

- [S1: Cloud Markup comments](https://support.atlassian.com/bitbucket-cloud/docs/markup-comments/). The Emoji section explicitly denies a definitive list.
- [S2: Official Cloud OpenAPI](https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json?_v=2.300.195). Inspect `components.schemas.comment`, `pullrequest_comment`, and `paths`.
- [S3: Atlassian standard emoji test fixture](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/util-data-test/src/json-data/service-data-standard.json).
- [S4: Test fixture loader](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/util-data-test/src/emoji/get-standard-emoji-data.ts).
- [S5: Atlassian EmojiRepository](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/emoji/src/api/EmojiRepository.ts). See `findByShortName` and the `shortNameMap` population.
- [S6: Atlassian emoji ID to Unicode helper](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/emoji/src/util/emojiIdToEmoji.ts).
- [S7: Unicode 17.0 emoji test data](https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt). This is Unicode sequence evidence, not Cloud compatibility evidence.
- [S8: Atlassian test-data package license](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/util-data-test/LICENSE).
- [S9: Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0.txt). Section 4 gives the redistribution terms.
- [S10: Unicode License V3](https://www.unicode.org/license.txt).
- [S11: Atlassian frontend mirror README](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/README.md).
- [S12: User-created list linked by Atlassian](https://bitbucket.org/DACOFFEY/wiki/wiki/BITBUCKET/EMOJI/Emoji). HTTP 404 on the research date.
- [S13: Combined example emoji data](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/util-data-test/src/emoji/get-emojis.ts).
- [S14: Cloud PullRequest Comment GET](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-comments-comment-id-get).
- [S15: Atlassian emoji package license](https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/emoji/LICENSE).
