# Bitbucket Cloud Comment Markdown compatibility

Research date: 2026-10-01.
Ticket: [Research Bitbucket Cloud Markdown compatibility](../issues/01-research-bitbucket-cloud-markdown-compatibility.md).
Parent: [M23 Comment thread and Markdown presentation fixes](../map.md).

## Findings

Cloud is not proven equivalent to the whole user-selected Data Center guide.
The Data Center guide claims CommonMark with extensions. Cloud Comment docs name Python-Markdown with extensions. [S1][S2]
Python-Markdown explicitly states that it is not a CommonMark implementation. [S6]
The shared syntax examples establish overlap, not parser equivalence.

The strongest confirmed Cloud facts are:

- The Comment wire contract has `content.raw`, `content.markup`, and `content.html`. [S4]
- Cloud Comment docs name `sane_lists`, `fenced_code`, `codehilite`, `tables`, and `del`, among other extensions. [S2]
- Cloud documents `pull request #1541` for a same-Repository PullRequest reference. [S2]
- Cloud does not document the Data Center cross-Project PullRequest shorthand as equivalent. [S1][S2]
- Cloud rejects arbitrary HTML as supported Markdown. Its docs do not specify one exact escape result for every tag. [S2][S5]
- List start numbers, mixed list types, nested fences, and image dimensions need further Cloud Comment evidence.

This asset records external facts and fixture inputs. It selects no ReviewBody presentation policy.
Review retains authored bytes. Presentation derives ReviewBody and ReviewCard rows, as the repository context docs specify.

## Evidence limits

The evidence labels in this asset have these meanings:

| Label | Meaning |
| --- | --- |
| Cloud documentation | An Atlassian Cloud document or API definition states the fact. |
| Cloud demo | Atlassian Cloud docs link to a public syntax demo. The demo is a README, not a Comment capture. |
| Upstream documentation | The named parser project's docs state the fact. Cloud deployment behavior remains unconfirmed. |
| Upstream source | The parser project's public source supports the fact. Cloud deployment behavior remains unconfirmed. |
| Data Center only | The selected Data Center guide states the fact. No matching Cloud guarantee was found. |
| Unknown | The reviewed sources do not settle the behavior for Cloud PullRequest Comments. |

Context7 supplied current Cloud documentation leads after library resolution.
Direct reads then checked Atlassian support docs, the Cloud OpenAPI definition, and the documented demo source.
The demo source read used commit `5b6c39df3196eeeb8a36684beb9a3df854a0b5f3`. [S3]
No live Comment, editor preview, or rendered README response was captured.
No remote write or local parser experiment was run.
Documented examples below are not live observations.

The Cloud docs do not pin a deployed Python-Markdown version, extension versions, or extension settings. [S2][S5]
Names such as `headerid` and the demo's legacy `safe mode` text do not prove a current runtime configuration.
The reviewed sources expose no first-party Cloud production renderer source.
Upstream docs and source therefore identify compatibility questions, not a complete Cloud conformance oracle.

## Comment wire contract

The OpenAPI `pullrequest_comment` schema inherits `comment` through `allOf`. [S4]
The inherited `content` properties have these definitions:

| Field | Wire type | Exact schema description |
| --- | --- | --- |
| `content.raw` | string | "The text as it was typed by a user." |
| `content.markup` | string | "The type of markup language the raw content is to be interpreted in." |
| `content.html` | string | "The user's content rendered as HTML." |

The abstract Comment schema permits `markdown`, `creole`, and `plaintext` for `markup`.
That enum alone does not prove that PullRequest Comments accept all three authoring modes.
Cloud Comment docs describe Markdown. [S2][S4]

`links.html.href` is a URL for the Comment. It is not `content.html`.
The list endpoint includes root Comments, inline Comments, and Replies. [S4][S12]
The list and single-Comment endpoints reference the inherited Comment schema.
The schema does not mark the three content properties as required.
Partial responses and deleted Comments need separate evidence about omitted or empty content.

The generated POST example includes `content.raw`, `content.markup`, and `content.html` with placeholder strings. [S12]
That example demonstrates the JSON shape. It does not prove that clients control the HTML output.
The generic request and response schema does not define precedence between conflicting raw and HTML fields.
No create or update request was sent during this research.

The API activity documentation contains a concrete Comment content pair. [S12]
This excerpt omits all account and Repository data:

```json
{
	"raw": "inline with to a dn from lines",
	"markup": "markdown",
	"html": "<p>inline with to a dn from lines</p>",
	"type": "rendered"
}
```

This is documented Cloud output for a plain paragraph.
The activity example includes `content.type`. The OpenAPI `content` object does not list that property.
The discrepancy limits exact schema assertions. It does not remove the documented raw and HTML fields.

## Whole-guide comparison

| Selected guide construct | Cloud evidence | Compatibility boundary |
| --- | --- | --- |
| ATX headings, H1 through H6 | The demo gives six heading levels. [S3] | Shared basic syntax. Heading whitespace and IDs are not a Cloud Comment conformance contract. |
| Setext H1 and H2 | The demo gives `=` and `-` underlines. [S3] | Shared basic syntax. Multiline Setext interpretation remains unconfirmed. |
| Paragraphs | The demo separates paragraphs with blank lines. The API gives a paragraph HTML pair. [S3][S12] | Shared basic syntax. The demo also documents two trailing spaces for a hard line break. |
| Emphasis and strong emphasis | The demo gives `*text*`, `_text_`, `**text**`, and `__text__`. [S3] | Shared basic syntax. Intraword and delimiter edge cases need Cloud evidence. |
| Strikethrough | The demo gives `~~text~~`. Comment docs name `del`. [S2][S3] | Documented Cloud support. Tables and strikethrough are extensions, not base CommonMark claims. |
| Unordered lists | The demo gives `*`, `+`, and `-` markers. [S3] | Nested indentation and changes between marker types need separate fixtures. |
| Ordered lists | The demo gives digit-plus-period markers and repeated `1.` inputs. Comment docs name `sane_lists`. [S2][S3] | The first number and later authored numbers are different questions. See the list section. |
| Lists inside lists | The demo includes ordered, unordered, and mixed nesting. [S3] | Shared intent. Two-space CommonMark nesting is not a documented Cloud guarantee. |
| Quotes | The demo gives `>` quotes, nested quotes, and quotes with lists or indented code. [S3] | Shared basic syntax. Fenced code inside a quote remains unconfirmed for Comments. |
| Inline code | The demo gives backtick spans and doubled backticks around a literal backtick. [S3] | Shared basic syntax. Exact whitespace normalization needs Cloud evidence. |
| Indented code | The demo states four spaces or one tab at the root. It gives code inside lists. [S3] | Shared basic syntax. Code content stays literal in the documented example. |
| Fenced code | Comment docs name `fenced_code`. The demo gives backticks and tilde fences. [S2][S3] | Shared intent. Nested fences and unequal closing fence lengths are unresolved Cloud questions. |
| Code language and colors | The demo names Pygments. README docs give `javascript`, `java`, and `python` fences. [S3][S5] | Data Center names CodeMirror. Its language coverage promise cannot transfer to Cloud. |
| Inline links and link titles | The demo gives an inline link and a reference definition with an optional title. [S3] | Shared basic syntax. Relative URL resolution depends on the document context. |
| Reference links | The demo gives `[an example][id]` and a later definition. [S3] | Documented Cloud syntax. Missing or duplicate definitions need separate fixtures. |
| Bare URL auto-detection | The Data Center guide gives a bare `http://example.com/`. [S1] | No exact Cloud Comment bare-URL input and HTML pair was found. Angle-bracket autolinks are a separate syntax. |
| Jira references | Cloud docs describe configured linkers for PullRequest Comments. [S2][S13] | The destination depends on Repository or integration context. A key alone does not supply the URL. |
| PullRequest references | Cloud gives `pull request #number` in the current Repository. [S2] | Data Center gives `#123`, `example-repo#123`, and `PROJ/example-repo#123`. Those are not established Cloud equivalents. |
| Inline and reference images | The demo describes both styles and gives inline images with an optional title. [S3] | Shared basic syntax. Relative image paths need Comment-specific evidence. |
| Image width and height | Data Center gives `![text](/url.png){width=640 height=480}`. [S1] | No Cloud Comment guarantee was found. The listed Cloud extensions omit `attr_list`. |
| Tables | Comment docs name `tables`. The demo gives pipe tables, alignment, and inline styles in cells. [S2][S3] | Documented Cloud support. This does not permit authored HTML tables. |
| Backslash escapes | The demo gives escaped asterisks. The base Markdown source lists punctuation escapes. [S3][S11] | Shared intent. CommonMark permits more punctuation escapes than the original list. Exact Cloud handling remains unconfirmed. |
| Authored HTML | Cloud docs reject arbitrary HTML, including `<table>`. [S2][S5] | Data Center promises escaped tags. Cloud does not give the same universal output promise. |
| README discovery | Cloud uses filename extensions and supports several markup languages. [S5] | README discovery and rendering are not Comment wire behavior. |

## Lists need distinct fixtures

### Numbering and list-type changes

The Cloud demo says that actual number values do not matter. Its example repeats `1.` for three items. [S3]
That example does not establish the behavior of a list whose first marker is `4.`.
Cloud Comment docs separately list `sane_lists`. [S2]
Current upstream `sane_lists` preserves the first marker through `<ol start="4">`. [S7]
Its source sets `LAZY_OL = False` and separates ordered and unordered sibling lists. [S15]
The base list processor records the first number, not a separate value for each later list item. [S16]

The demo's broad numbering statement and the upstream extension behavior do not form one exact Cloud rule.
Cloud first-number handling remains unobserved.
Skipped later numbers, repeated numbers, and list restarts also need Cloud Comment output evidence.

These are exact documented upstream examples, not Cloud captures. [S7]

Input:

```markdown
4. Apples
5. Oranges
6. Pears
```

Output:

```html
<ol start="4">
<li>Apples</li>
<li>Oranges</li>
<li>Pears</li>
</ol>
```

Input:

```markdown
A Paragraph.
* Not a list item.

1. Ordered list item.
* Not a separate list item.
```

Output:

```html
<p>A Paragraph.
* Not a list item.</p>
<ol>
<li>Ordered list item.
* Not a separate list item.</li>
</ol>
```

The upstream extension also documents separate `<ol>` and `<ul>` blocks when a blank line separates their inputs. [S7]
This rule concerns sibling list types. It does not forbid an unordered child list inside an ordered item.

### Indentation, continuation paragraphs, and code

The Cloud demo documents four spaces or one tab for a later paragraph inside a list item. [S3]
The upstream parser requires that indentation for nested blocks, including child lists and quotes. [S6]
CommonMark calculates continuation indentation from marker width and padding instead. [S10]
The Data Center guide's four-space examples fit both styles in common cases. They do not establish identical edge cases. [S1]

The Cloud demo has mixed nesting with tabs and continuation paragraphs. [S3]
It also documents this code block inside a list. The spaces below are significant:

```markdown
* Green

    Try this code:

        This is an embedded code block.

    Then this:

        More code!

* Blue
* Red
```

The documented result places two literal code blocks inside the Green item.
The source includes both the displayed example and an indented source copy. [S3]
This is Cloud demo evidence. No Cloud Comment HTML capture confirms the same hierarchy in this session.

For fixture design, the unresolved list inputs include:

- First markers `0.`, `4.`, and `10.`, with later repeated or skipped numbers.
- A period marker compared with a closing-parenthesis marker such as `1)`.
- Two-space, four-space, and tab child-list indentation.
- Ordered parents with unordered children, and the reverse.
- A list-type change with a blank line, and the same change without a blank line.
- Continuation text, a later paragraph, a quote, and code inside one item.
- Tight lists, loose lists, and list restarts after a paragraph.

These are research-derived candidate inputs. Their expected Cloud HTML is unknown unless a cited pair supplies it.

## Fences and language identifiers

Cloud Comment docs list `fenced_code` and `codehilite`. [S2]
The documented demo names Pygments and claims lexer short names or MIME types. [S3]
The README page gives opening fences with `javascript`, `java`, and `python`. [S5]
Those README examples do not establish a complete current Comment language list.
No source guarantees Cloud Highlighting for `zig`, every Pygments alias, or every MIME-type fence string.
Installed Pygments versions, unknown-language fallback, language guessing, and HTML token classes remain unknown for Cloud Comments.

Current upstream `fenced_code` permits backticks or tildes with at least three delimiters. [S8]
It requires matching delimiter type and count.
It supports fences only at the document root, not inside lists or quotes.
CommonMark supports fences inside container blocks and permits a longer closing fence. [S10]
Those are real parser differences. The Cloud deployment's exact behavior remains unconfirmed.

This upstream documented pair has syntax highlighting disabled. It is not a Cloud output capture. [S8]

Input:

````markdown
``` html
<p>HTML Document</p>
```
````

Output:

```html
<pre><code class="language-html">&lt;p&gt;HTML Document&lt;/p&gt;
</code></pre>
```

Upstream `codehilite` can remove a pathless `#!python` line or a `:::python` line from indented code. [S9]
The Cloud demo also uses `#!python` inside a fence. [S3]
The sources do not settle Cloud Comment handling of these two forms together.
This behavior matters because the M23 map requires literal code-block text.
Whether M23 follows or rejects such language-directive removal remains a scope decision for the parent.

Potential fence fixtures include an absent language, an unknown language, whitespace before the language, and a MIME-type identifier.
Nested fences, tilde fences, unequal closing lengths, unclosed fences, and directive lines need separate expected-output evidence.
Cloud's Pygments claims do not select terminal colors or a tree-sitter Grammar mapping.

## Links, images, tables, and HTML

### Links depend on context

Cloud documentation maps `pull request #1541` to a linked PullRequest reference in the current Repository. [S2]
The documented output keeps the visible text `pull request #1541`.
The text extraction supplies no concrete `href` for that example.
The same document maps `issue #88` to a linked issue reference.
It also describes automatic commit-hash references and account mentions.
These constructs extend Markdown and can require Repository or account context.

The Data Center guide's `#123` and cross-Project forms remain Data Center evidence. [S1]
The reviewed Cloud docs do not establish their meaning in Cloud PullRequest Comments.
An explicit Markdown URL is distinct from a product shorthand.

Cloud linkers support external pages in commit messages and PullRequest Comments. [S13]
Linkers use a configured server URL and a case-sensitive key.
The example key `BB` gives the reference `BB-5792`.
The document says that adding a linker can also link references in existing Comments.
Therefore Jira-key output is context-dependent, not a universal parser-only result.
Jira integration docs also name PullRequest Comments as a place that shows Jira work item details. [S14]
The reviewed sources do not specify a complete key regex or the exact Comment HTML for each integration.

The demo documents inline links, reference links, and optional titles. [S3]
Original Markdown documents `<http://example.com/>` as an autolink with this output: [S11]

```html
<a href="http://example.com/">http://example.com/</a>
```

This is base Markdown documentation, not proof about a bare URL in a Cloud Comment.
Bare URLs, trailing punctuation, balanced parentheses, and relative destinations need Cloud-specific output evidence.

### Images do not inherit Data Center dimensions

The Cloud demo describes inline and reference image syntax with alt text and an optional title. [S3]
The Data Center guide adds `{width=640 height=480}` after an image. [S1]
Cloud's published extension list omits `attr_list`. [S2]
Upstream `attr_list` provides attribute syntax, but its existence does not prove Cloud enables it. [S17]
The omission does not prove Cloud lacks all custom image handling either.

The unresolved Cloud README image-sizing suggestion is historical supporting evidence, not a Comment contract. [S18]
It concerns a different input form, `=250x`, rather than the Data Center attribute suffix.
The duplicate Wiki suggestion likewise does not establish Comment behavior. [S19]

Cloud Comment output for the exact Data Center suffix remains unknown.
Relative image bases, attached images, alt-text output, title output, and dimension preservation need Comment-specific reads or tests.
No image was loaded during this research.

### Tables have documented syntax, not HTML authoring permission

The Cloud demo requires a header row and a separator row. [S3]
It documents left, right, and center alignment through colons in the separator.
It allows span-level formatting in cells, including code and emphasis.
It states that table cells contain simple lines.
Cloud Comment docs list `tables` while rejecting authored `<table>` tags. [S2]

This documented upstream table input produces `<table>`, `<thead>`, and `<tbody>` elements. [S20]

```markdown
First Header  | Second Header
------------- | -------------
Content Cell  | Content Cell
Content Cell  | Content Cell
```

The documented HTML has two `<th>` cells and two rows with two `<td>` cells each.
That is upstream output structure, not a Cloud Comment byte-for-byte HTML fixture.
Cloud alignment attributes, escaped pipes, pipes inside code spans, empty cells, and uneven row widths remain unobserved.

### HTML rejection differs from an exact escape promise

Data Center states that it escapes all HTML tags. [S1]
Cloud states that it does not support arbitrary HTML, with `<table>` as its example. [S2][S5]
The demo's legacy safe-mode paragraph mentions replacement, removal, or escaping without selecting one result. [S3]
The Cloud docs therefore do not establish that every authored tag survives as escaped visible text.

The demo explicitly states that code-block ampersands and angle brackets become HTML entities. [S3]
The fenced-code pair above supplies an upstream input and output example for escaped HTML inside code.
That code escaping is separate from handling an authored HTML block outside code.
Generated HTML for a Markdown table is also separate from authored `<table>` input.

Fixture inputs need to distinguish raw `<tag>`, authored `&lt;tag&gt;`, backslash escapes, inline code, and fenced code.
Expected Cloud output remains unknown for tag removal, HTML comments, and entity handling outside code.

## README evidence is not Comment evidence

The Cloud README docs choose markup from the filename extension. [S5]
They support Markdown, reStructuredText, Textile, and plain text.
They list the same Python-Markdown extension names as the Comment page.
That shared list does not prove identical URL bases, linkers, sanitization, or rendered wrappers.

Atlassian links the demo from both the README and Comment pages. [S2][S5]
The demo is useful documented syntax evidence for Comments.
Its rendered README would still be a README observation, not a Comment observation.
The Cloud Source API's `format=rendered` is a file-rendering operation, not a documented Comment preview endpoint. [S21]
The reviewed Cloud OpenAPI definition has no path containing `markup`. [S4]
That search does not prove that no internal editor preview exists.

## Remaining evidence and scope questions

| Question | Evidence needed |
| --- | --- |
| Exact list hierarchy and numbering | A live read of suitable existing Cloud Comments, or an authorized test Comment. Preserve raw and HTML as a pair. |
| Nested fences and language fallback | A Cloud Comment pair for each fence case. A README result alone is insufficient. |
| Escaped HTML versus stripped HTML | Cloud Comment raw and HTML pairs for authored tags, entities, and code contexts. |
| Bare URLs and product references | Cloud Comment output with the relevant Repository and linker context recorded without private data. |
| Image attributes and relative URLs | Cloud Comment pairs for the exact Data Center suffix and representative relative paths. |
| HTML fields on deleted or partial Comments | A live read or documented example that covers omissions and empty strings. |
| Cloud renderer and browser equivalence | A read of both `content.html` and the displayed Comment for the same input. |
| Whole-guide target versus Cloud-specific behavior | A parent scope decision for each difference. Research does not select terminal approximations. |
| Cloud extensions outside the selected guide | A parent scope decision about definitions, footnotes, abbreviations, heading IDs, table of contents, and wiki links. [S2] |

An existing Comment read cannot establish behavior for inputs that the Comment does not contain.
An authorized test must identify its input, context, response, and date before it becomes observed evidence.
No such authorization or test result is part of this asset.
Future fixtures can cite documented pairs now. The unknown cases need evidence or an explicit project behavior decision.

## Sources

All sources below were read on 2026-10-01.
The upstream source links track `master`. They identify reviewed code, not Cloud's deployed parser version.

- [S1] [Selected Data Center Markdown syntax guide](https://confluence.atlassian.com/bitbucketserver/markdown-syntax-guide-776639995.html). The page identifies Data Center and shows a 2023-01-10 modification date.
- [S2] [Cloud Markup comments](https://support.atlassian.com/bitbucket-cloud/docs/markup-comments/). Direct Comment documentation and product-reference examples.
- [S3] [Atlassian Markdown demo source at a fixed commit](https://api.bitbucket.org/2.0/repositories/tutorials/markdowndemo/src/5b6c39df3196eeeb8a36684beb9a3df854a0b5f3/README.md). [Public demo page](https://bitbucket.org/tutorials/markdowndemo).
- [S4] [Cloud OpenAPI definition linked from the API reference](https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json?_v=2.300.195). Schemas `comment` and `pullrequest_comment`, plus the Comment paths.
- [S5] [Cloud README content](https://support.atlassian.com/bitbucket-cloud/docs/readme-content/). README extensions, supported markup, and language-fence examples.
- [S6] [Python-Markdown goals and differences](https://python-markdown.github.io/#differences). Non-CommonMark claim and nested indentation rules.
- [S7] [Python-Markdown Sane Lists](https://python-markdown.github.io/extensions/sane_lists/). Documented list inputs and HTML outputs.
- [S8] [Python-Markdown Fenced Code Blocks](https://python-markdown.github.io/extensions/fenced_code_blocks/). Root-only fences, matching delimiters, and documented HTML output.
- [S9] [Python-Markdown CodeHilite](https://python-markdown.github.io/extensions/code_hilite/). Pygments settings and language-directive input and output examples.
- [S10] [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/). Sections 4.5, 5.2, and 5.3 define fences, list indentation, and lists.
- [S11] [Original Markdown syntax](https://daringfireball.net/projects/markdown/syntax). Base syntax examples, escapes, code output, and angle-bracket autolinks.
- [S12] [Cloud Pullrequests API reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/). Comment operations and the concrete paragraph pair under the activity examples.
- [S13] [Cloud Link to a web service](https://support.atlassian.com/bitbucket-cloud/docs/link-to-a-web-service/). Repository linkers and their effect on PullRequest Comments.
- [S14] [Integrate Bitbucket with Jira](https://support.atlassian.com/jira-cloud-administration/docs/integrate-bitbucket-with-jira/). Jira work item context in PullRequest Comments.
- [S15] [Upstream `sane_lists.py`](https://raw.githubusercontent.com/Python-Markdown/markdown/master/markdown/extensions/sane_lists.py). `SaneOListProcessor` and `SaneUListProcessor`.
- [S16] [Upstream `blockprocessors.py`](https://raw.githubusercontent.com/Python-Markdown/markdown/master/markdown/blockprocessors.py). `OListProcessor` and `ListIndentProcessor`.
- [S17] [Python-Markdown Attribute Lists](https://python-markdown.github.io/extensions/attr_list/). Attribute syntax is a separate extension.
- [S18] [BCLOUD-12877](https://jira.atlassian.com/browse/BCLOUD-12877). Public README image-sizing suggestion. Unresolved when read. Reporter text is not a current product guarantee.
- [S19] [BCLOUD-14409](https://jira.atlassian.com/browse/BCLOUD-14409). Public Wiki image-resize suggestion. Closed as Duplicate when read.
- [S20] [Python-Markdown Tables](https://python-markdown.github.io/extensions/tables/). Documented pipe-table input and HTML output.
- [S21] [Cloud Source API](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-source/). Raw file content and the `format=rendered` file-rendering option.
