# Choose ReviewBody code-block Highlighting

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 01, 04

## Question

When can ReviewBody code blocks use the existing Highlighter, and what happens when Highlighting is unavailable?

The user requests syntax colors where possible.
Inspect the existing Highlighter and GrammarMatch interfaces before asking the human to choose a policy.
Decide how a fence language identifier selects a BuiltInGrammar or UserGrammar without a File path.
Decide how indented blocks, unlabelled fences, unsupported identifiers, and Suggestions appear.

Choose when Highlighting runs, which limits apply, and how failures preserve readable literal text.
Keep terminal input responsive and keep published Presentation Frames internally consistent.
Decide whether source foreground roles and the existing Theme are sufficient.
Do not add a new Grammar merely to claim parity with every language named in the guide.

The answer records the supported mapping, fallback, lifetime, and acceptance examples.

## Comments

### Existing interfaces

The session claimed this ticket after both dependencies reached `resolved`.

- [Highlighter](../../../src/highlight/highlighter.zig) accepts a path and content, not a fence identifier.
  Its result contains line-local Spans with Capture roles.
  PlainHighlighter returns no Spans.
- [BuiltInGrammar selection](../../../src/highlight/grammar_match.zig) supports TSX, TypeScript, JavaScript, CSS, Go, Bash, JSON, and YAML.
  Selection uses path suffixes and a Bash shebang fallback.
- [UserGrammar selection](../../../src/highlight/user_grammar.zig) uses configured filenames, compound suffixes, extensions, and shebangs.
  The Registry has no public selector for a fence identifier or installed Grammar name.
- [TreeSitterHighlighter](../../../src/highlight/tree_sitter_highlighter.zig) tries an active matching UserGrammar before a BuiltInGrammar.
  A failed UserGrammar can fall back to the matching BuiltInGrammar.
  The public call exposes no timeout or query-work budget.
- [File Enrichment](../../../src/tui/file_enrichment.zig) runs Highlighting with separate result and scratch storage.
  The [configuration](../../../src/tui/config.zig) defaults its Highlighting size limit to 2 MiB.
  A zero limit means unlimited.
- [ADR-0012](../../../docs/adr/0012-presentation-is-a-typed-command-producing-state-machine.md) requires correlated commands and owned completions for worker work.
  Session-bound results cannot change a later Session.
  A failed reprojection preserves the previous complete Presentation Frame.

### First decision round

These recommendations await the user's answers.
They define proposed bbr behavior, not observed Cloud behavior.

1. Map supported fence names and common aliases to representative suffixes, then reuse existing GrammarMatch rules.
   Active UserGrammars can supply missing languages through those suffixes.
   Do not select an installed Grammar by its package name.
   The next round must settle the exact alias table and unsupported identifiers.
2. Keep unlabelled fences and indented blocks plain.
   Do not guess from the surrounding File or code text.
   A recognized Suggestion can use its inherited inline File path.
   An unavailable path leaves its replacement code plain.
3. Publish readable plain code first, then run Highlighting in background work when its ReviewCard enters the viewport.
   Analyze the complete block, including rows hidden by body disclosure.
   Reuse results across wrapping, resizing, disclosure, and Theme changes.
   Reject results after Session replacement, body edits, or deletion.
4. Reuse the existing Highlighting size setting for each complete block.
   Do not truncate a block to color only its prefix.
   Unsupported, oversized, or failed blocks retain complete literal text and their agreed background.
   The next round must settle aggregate work, scheduling, retained-result limits, and failure retry behavior.
5. Reuse existing Capture roles and Theme foregrounds for code.
   Keep the agreed code-block background and the distinct Suggestion background and label.
   Cursor, Selection, and search backgrounds preserve syntax foregrounds.
   Plain fallback uses the Theme's ordinary foreground rather than inline-code green.

The ticket remains claimed until the user confirms the full decision.

### User answers to the first round

The user accepted all five recommendations.
Fence selection reuses GrammarMatch through a small alias-to-suffix table.
Unlabelled fences and indented blocks stay plain, except recognized Suggestions with an inherited inline File path.
Background Highlighting starts when the ReviewCard enters the viewport.
The complete block uses the existing Highlighting size setting.
Code uses existing Capture roles and Theme foregrounds.

### Second decision round

The following proposals await the user's answers.

#### Fence identifiers and aliases

Use the first whitespace-separated fence identifier and compare it without ASCII case sensitivity.
Ignore later information tokens for Grammar selection.
Use these aliases:

| Identifiers | Representative suffix |
| --- | --- |
| `tsx` | `.tsx` |
| `typescript`, `ts`, `mts`, `cts` | `.ts` |
| `javascript`, `js`, `jsx`, `mjs`, `cjs` | `.js` |
| `css` | `.css` |
| `go`, `golang` | `.go` |
| `bash`, `sh`, `shell` | `.sh` |
| `json` | `.json` |
| `yaml`, `yml` | `.yaml` |
| `python`, `py` | `.py` |
| `ruby`, `rb` | `.rb` |
| `rust`, `rs` | `.rs` |
| `c` | `.c` |
| `cpp`, `c++`, `cxx` | `.cpp` |
| `csharp`, `c#`, `cs` | `.cs` |
| `java` | `.java` |
| `html` | `.html` |
| `xml` | `.xml` |
| `sql` | `.sql` |
| `zig` | `.zig` |

Only the existing BuiltInGrammars ship.
Other rows require an active UserGrammar matching the representative suffix.
An unlisted identifier containing only ASCII letters, digits, underscores, plus signs, or hyphens supplies its own extension.
Require an ASCII letter or digit first.
For example, `kotlin` can match an active `.kotlin` rule, but not an installed package name alone.
Reject path separators, MIME types, attribute syntax, and other identifier forms for Grammar selection.
Their recognized code blocks still show complete literal code.

Explicit fence identifiers select only extension rules.
Do not use shebangs or synthetic exact filenames to override the fence identifier.
UserGrammars retain precedence for the representative extension.
An explicit unsupported identifier stays plain even if its code begins with a Bash shebang.
This needs a restricted selection mode because the current public Highlighter call permits shebang fallback.

#### Suggestion context

Use the root's authored inline File path for Suggestion replacement code, including outdated Threads.
Use normal File GrammarMatch rules with the replacement code as content.
Do not fetch File content or infer a path from the current cursor.
Do not require complete File Enrichment.
Missing inherited inline context leaves the Suggestion plain with its distinct background and label.

#### Work and retained results

Use at most one code-block Highlighting worker at a time.
Recompute pending eligibility from visible ReviewCards rather than retain copied bodies in an unbounded queue.
Order eligible blocks by displayed ReviewCard order, then authored block order.
Skip work that loses eligibility before launch.
Let started work finish, then reject a stale completion through normal ownership cleanup.

Keep a fixed 8 MiB Session budget for retained successful result storage.
Evict the least recently used results that do not belong to visible ReviewCards first.
If necessary, evict other results to stay within the budget.
If one result exceeds the budget, keep that block plain.
An evicted successful result can be recomputed when its ReviewCard leaves and then re-enters the viewport.
Do not retry a failed or oversized result merely because the terminal redraws or the reviewer scrolls.
Keep failure and size-skip state with the existing body-block identity rather than in a separate result cache.
The next implementation must account for storage capacity rather than count only logical Spans.

The existing size setting applies to code content after structural indentation removal, before tabs expand or lines wrap.
The size limit does not promise a parse-time deadline.
Do not add a timeout or a new setting in M23.

#### Failure and publication

If an active UserGrammar fails, try the matching BuiltInGrammar once, then retain plain code.
Ordinary unsupported or skipped code needs no warning label.
Technical failures use existing diagnostics without repeated status messages.
Retry a failed block only after body replacement or Session replacement.
Keep the complete plain Presentation Frame if result admission or reprojection fails.
Color completion does not change text, row geometry, authored source ownership, cursor, Selection, or Search Occurrence identity.

These choices remain open until the user answers and confirms shared understanding.

### User answers to the second round

The user accepted the alias table and first-token identifier rules.
The user selected normal GrammarMatch behavior, including shebang fallback, rather than extension-only selection.
This supersedes the proposed restriction on shebangs and synthetic exact filenames.
For example, a `python` fence can use Bash colors when no `.py` Grammar matches and its content has a matching Bash shebang.
An unsupported identifier stays plain only when normal GrammarMatch finds no Grammar.
The accepted aliases do not install additional Grammars.

The user accepted one worker, the 8 MiB retained-result budget, and the proposed scheduling and eviction rules.
The user accepted the existing complete-block size setting without a new timeout.
The user accepted fallback, diagnostics, retry triggers, and atomic color publication.

The user did not understand the Suggestion path question.
No Suggestion path decision was made.
The next question must explain that path through a concrete File rename example.

### Suggestion path clarification

The session explained the choice with a Suggestion authored for `main.js` before that File becomes `main.ts`.
The user selected the original File name.
Use the root's authored inline File path for existing Suggestion replacement code.
Replies inherit that root context.
New Suggestions use their own authored target context.
Missing inline context leaves a recognized Suggestion plain.

The remaining step is confirmation of shared understanding before resolution.

### Final confirmation

The user confirmed the complete decision and requested closure.
The answer below supersedes earlier proposals where the user's choices differ.

## Answer

### Responsibility and literal content

Presentation selects eligible ReviewBody code blocks and projects their syntax foregrounds.
Highlighting supplies Spans through the existing Highlighter and GrammarMatch rules.
Review retains the exact authored Comment and Draft bytes.

Highlighting does not interpret Markdown, convert emoji, or change code content.
Remove structural container and code-block indentation before analysis.
Keep the remaining code bytes, including tabs and language directives such as `#!python`.
Analyze the complete code block before terminal tab expansion or line wrapping.
Map syntax Spans back to authored source ownership.

Use [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md) for fence recognition, whitespace, wrapping, and backgrounds.
An unclosed or otherwise unrecognized code construct retains its agreed literal fallback.
It does not enter code-block Highlighting merely because it resembles a fence.

### Fence identifiers and GrammarMatch

Use the first whitespace-separated fence information token as the identifier.
Compare identifiers without ASCII case sensitivity.
Ignore later information tokens for Grammar selection.
Do not treat later tokens as code content or visible fence labels.

Map the following identifiers to representative suffixes:

| Identifiers | Representative suffix |
| --- | --- |
| `tsx` | `.tsx` |
| `typescript`, `ts`, `mts`, `cts` | `.ts` |
| `javascript`, `js`, `jsx`, `mjs`, `cjs` | `.js` |
| `css` | `.css` |
| `go`, `golang` | `.go` |
| `bash`, `sh`, `shell` | `.sh` |
| `json` | `.json` |
| `yaml`, `yml` | `.yaml` |
| `python`, `py` | `.py` |
| `ruby`, `rb` | `.rb` |
| `rust`, `rs` | `.rs` |
| `c` | `.c` |
| `cpp`, `c++`, `cxx` | `.cpp` |
| `csharp`, `c#`, `cs` | `.cs` |
| `java` | `.java` |
| `html` | `.html` |
| `xml` | `.xml` |
| `sql` | `.sql` |
| `zig` | `.zig` |

Only the existing TSX, TypeScript, JavaScript, CSS, Go, Bash, JSON, and YAML BuiltInGrammars ship.
Other suffixes need an active matching UserGrammar unless normal shebang selection finds another available Grammar.
The table does not promise the language coverage of Cloud, Pygments, or CodeMirror.
Do not install or add Grammars for this decision.

An unlisted simple identifier supplies its own extension after ASCII case normalization.
Require an ASCII letter or digit first.
Allow only ASCII letters, digits, underscores, plus signs, and hyphens in an unlisted identifier.
For example, `kotlin` supplies `.kotlin`.
An installed Grammar named `kotlin` does not match unless its active GrammarMatch rules match the supplied path or content.

Reject path separators, MIME types, attribute syntax, and other identifier forms for Grammar selection.
These blocks still retain their recognized code presentation and complete literal content.

Supply the representative suffix through a synthetic path without fetching or creating a File.
Reuse normal GrammarMatch behavior, including existing UserGrammar precedence and shebang fallback.
Do not add an extension-only selection mode.
The user explicitly permits a shebang to select a Grammar when the fence suffix has no matching Grammar.
For example, a `python` block with a Bash shebang can use Bash colors when no `.py` Grammar matches.
The shebang itself stays visible code text.

An unsupported identifier stays plain when normal GrammarMatch finds no available Grammar.
Unlabelled fences and ordinary indented code blocks stay plain even when their content contains a shebang.
Do not guess their Grammar from the containing File or their code text.

### Suggestions

A recognized Suggestion uses its root's authored inline File path to select a Grammar.
Replies inherit that root context.
Use the replacement code as Highlighter content with normal File GrammarMatch rules.
Do not use the cursor's File, fetch File content, or wait for File Enrichment.

Keep the original authored File path for existing Suggestions when a File moves or becomes outdated.
For example, a Suggestion for `main.js` retains that path after the File becomes `main.ts`.
New Suggestions use their own authored target context.
Missing inherited inline context leaves the Suggestion plain.
All Suggestions retain their distinct background and label, including plain fallback.

### Scheduling and lifetime

[Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) extends eligibility and priority to the selected Review Search Preview.

Publish readable plain code first.
Start background Highlighting when its ReviewCard enters the viewport.
Analyze the complete eligible block, including rows hidden by ReviewCard body disclosure.
Keep at most one code-block Highlighting worker active at a time.

Order eligible work by displayed ReviewCard order, then authored block order.
Recompute pending eligibility from the current visible ReviewCards.
Do not retain copied bodies in an unbounded pending queue.
Skip work that loses eligibility before launch.
Let started work finish even if the reviewer scrolls away.

Correlate each completion with its Session Epoch, authored owner, block, body content, and Grammar selection context.
Reject stale results after Session replacement, body replacement, deletion, or a change to the target context.
Dispose of every owned completion exactly once.
Use the command and completion boundary from [ADR-0012](../../../docs/adr/0012-presentation-is-a-typed-command-producing-state-machine.md).

Reuse accepted results across wrapping, resize, disclosure, and Theme changes.
None of those changes requires another syntax analysis.
A Theme change remaps existing Capture roles to foregrounds.

### Size and retained-result limits

Reuse `[highlight].max_file_bytes` for each complete code block.
Its default is 2 MiB, and zero means unlimited.
Measure code content after structural indentation removal and before tab expansion or wrapping.
Permit a block exactly at the limit.
Skip Highlighting when its content exceeds a nonzero limit.
Do not truncate code or color only a prefix.

Keep a fixed 8 MiB Session budget for retained successful Highlighting result storage.
Measure retained allocation capacity rather than only logical Span bytes.
This budget does not count authored Review storage, existing body metadata, or temporary worker scratch storage.
Release worker scratch storage after analysis.
The budget does not promise an 8 MiB peak for all process memory.

Evict least recently used results outside visible ReviewCards first.
Evict other results if necessary to keep retained storage within the budget.
Keep a block plain if its result alone exceeds the budget.
An evicted successful result can run again after its ReviewCard leaves and re-enters the viewport.
Do not immediately repeat evicted work while the same ReviewCards remain visible.

Keep failure and size-skip state with its existing body-block identity.
Do not add an unbounded negative-result cache.
Redraw, scrolling, wrapping, disclosure, and Theme changes do not retry failed or skipped blocks.
Body or Session replacement permits a fresh attempt.

Add no new limit setting or timeout setting in M23.
The existing Highlighter exposes no timeout.
The size limit does not establish a parse-time deadline.
Background execution keeps code-block analysis off the terminal input path.

### Theme, fallback, and publication

Use existing Capture roles and Theme syntax foregrounds.
Unknown Capture roles and plain fallback use the Theme's ordinary foreground.
Do not use inline-code green for complete plain code blocks.
Do not add separate syntax foreground roles for code blocks.

Preserve the agreed code background and the distinct Suggestion background and label.
Cursor, Selection, and search backgrounds preserve syntax foregrounds.
Code remains literal under every interaction background.

If an active UserGrammar fails, try the matching BuiltInGrammar once.
If no usable result remains, show complete plain code on its agreed background.
Unsupported, oversized, and skipped blocks need no warning label.
Technical failures use existing diagnostics without repeated status messages.

Publish accepted colors through one complete Presentation Frame.
If admission or reprojection fails, preserve the previous complete Frame.
Do not let color completion change text, row geometry, authored ownership, cursor, Selection, or Search Occurrence identity.
No failure can expose partial syntax state or discard authored content.

### Acceptance examples

These examples define bbr behavior, not observed Cloud renderer behavior.

| Input or condition | Expected behavior |
| --- | --- |
| A `TS` fence containing TypeScript | Select `.ts` without ASCII case sensitivity and use the TypeScript BuiltInGrammar unless a UserGrammar takes precedence. |
| `javascript extra-information` | Select `.js` from the first token. Later tokens do not affect Grammar selection. |
| A `jsx` fence | Use the JavaScript Grammar through `.js`. |
| A `python` fence with an active UserGrammar matching `.py` | Use that UserGrammar. No new BuiltInGrammar is required. |
| A `python` fence without a `.py` Grammar, beginning with a matching Bash shebang | Permit Bash selection through normal GrammarMatch. Keep the shebang visible. |
| A `python` fence without a matching suffix or shebang Grammar | Show complete plain code on the code background. |
| An unlisted `kotlin` fence with an active `.kotlin` rule | Select the matching UserGrammar. Package-name equality alone is insufficient. |
| `text/x-python`, a path, or attribute syntax as the first token | Do not select a Grammar. Keep the code presentation and literal code text. |
| An unlabelled fence or indented block beginning with a Bash shebang | Keep ordinary code plain. Do not infer a Grammar. |
| A recognized Suggestion in a Reply under a root for `main.js` | Analyze replacement code through the root's authored `main.js` path. |
| That File later becomes `main.ts` | The existing Suggestion still uses its authored `main.js` path. |
| A recognized Suggestion without inherited inline context | Keep replacement code plain with the Suggestion background and label. |
| A block containing `:mask:`, Markdown markers, tabs, and `#!python` | Retain literal code content. Apply only syntax foregrounds and agreed whitespace projection. |
| A code block whose ReviewCard first enters the viewport | Present readable plain code, then schedule eligible complete-block analysis. |
| Multiple visible ReviewCards with several code blocks | Run one worker in displayed card order, then authored block order. |
| A block hidden partly by body disclosure | Analyze its complete code once its ReviewCard becomes eligible. |
| Resize, disclosure, wrapping, or Theme change after a successful result | Reuse syntax results. Theme changes remap Capture roles. |
| Code exactly at the configured nonzero byte limit | Permit Highlighting. |
| Code above the configured nonzero byte limit | Keep the complete block plain. Do not truncate or color a prefix. |
| The configured byte limit is zero | Apply no input-size limit. The retained-result budget still applies. |
| A result alone exceeds 8 MiB | Keep the block plain without a repeated analysis loop. |
| Total retained results exceed 8 MiB | Evict results according to the agreed policy. Preserve readable code. |
| An evicted successful block's ReviewCard leaves and re-enters the viewport | Permit recomputation. |
| A failed or oversized block redraws or re-enters the viewport | Keep its fallback without retrying unchanged content. |
| An active UserGrammar fails and a matching BuiltInGrammar succeeds | Use the BuiltInGrammar result. |
| Both available Grammar attempts fail | Keep complete plain code and its agreed background. |
| A completion arrives after Session replacement, body replacement, deletion, or target-context change | Reject and dispose of it without changing the current Frame. |
| Color admission or reprojection fails | Preserve the previous complete Presentation Frame. |
| A color completion arrives under cursor, Selection, or search emphasis | Preserve text, geometry, source ownership, interaction locations, and syntax foregrounds. |

### Follow-up

The decision exposes no new independent planning question.
[Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) still decides transformed matching and navigation semantics.
[Validate combined Reply and Markdown presentation](./10-validate-combined-reply-and-markdown-presentation.md) must include syntax foregrounds and plain fallback.
[Define the integrated M23 acceptance contract](./08-define-the-integrated-m23-acceptance-contract.md) combines these examples with the other resolved decisions.
