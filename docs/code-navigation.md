# Code navigation

The [glossary map](../GLOSSARY-MAP.md) defines the contexts and their relationships.
These paths identify implementation entry points in the current checkout.

## Code entry points

| Work | Entry points |
|---|---|
| Top-level commands and review startup | [`src/main.zig`](../src/main.zig) dispatches commands. [`src/startup.zig`](../src/startup.zig) selects the review source. |
| Profiles and Credential selection | [`src/bitbucket/auth.zig`](../src/bitbucket/auth.zig) stores Profiles and resolves Credentials. [`src/main.zig`](../src/main.zig) handles login and logout. |
| Config, data, and state directories | [`src/xdg.zig`](../src/xdg.zig) resolves the config home, the data home, the state home, and the `config.toml` path. [`src/main.zig`](../src/main.zig) puts `pending.db` and the submission locks under the state home. |
| `bbr api` verbs and flags | [`src/api/cli.zig`](../src/api/cli.zig) holds the verb table and global parser. [`src/api/args.zig`](../src/api/args.zig) holds argument helpers. Resource files in [`src/api/`](../src/api/) handle each verb. |
| API output and endpoint behavior | [`src/api/output.zig`](../src/api/output.zig) formats CLI output. [`src/bitbucket/client.zig`](../src/bitbucket/client.zig) implements the Bitbucket adapter. [Bitbucket implementation notes](../src/bitbucket/IMPLEMENTATION.md) record verified API quirks. |
| Shell completions | [`src/completion.zig`](../src/completion.zig) generates completion scripts from the API registry. |
| Markdown, search, Selection, and terminal rendering | [Presentation entry points](../src/tui/IMPLEMENTATION.md#code-entry-points) map the semantic model, row projection, interaction owner, and terminal adapters. |
| BuiltInGrammars and GrammarMatch | [`vendors/tree-sitter/manifest.zig.zon`](../vendors/tree-sitter/manifest.zig.zon) is the one list of BuiltInGrammars. [`src/highlight/grammar_match.zig`](../src/highlight/grammar_match.zig) holds the `BuiltInGrammar` tags, the GrammarMatch table from the manifest, and `selectInjection`. [`src/highlight/grammar_name.zig`](../src/highlight/grammar_name.zig) holds the alias table that ReviewBody fences and Injection share. |
| Injection and Spans | [`src/highlight/tree_sitter_highlighter.zig`](../src/highlight/tree_sitter_highlighter.zig) owns Injection. `BuiltInPackages.get` prepares each BuiltInGrammar on its first use. `collectCaptureIntervals` parses the Injection layers, and `higherPrecedence` orders the intervals. [`src/highlight/runtime_package.zig`](../src/highlight/runtime_package.zig) prepares the highlight, locals, and injection queries. [`src/highlight/query_predicates.zig`](../src/highlight/query_predicates.zig) validates predicates, priorities, and injection directives. |
| Vendored Grammars | [`tools/vendor_grammar.py`](../tools/vendor_grammar.py) vendors one Grammar and writes its manifest entry. [`tools/adapt_queries.py`](../tools/adapt_queries.py) adapts the raw nvim-treesitter queries. [`tools/check_vendored_grammars.py`](../tools/check_vendored_grammars.py) checks the checksums and the adapted queries in `zig build test`. [`tools/third_party_notices.py`](../tools/third_party_notices.py) writes the `THIRD_PARTY_NOTICES` file of each release archive. [`vendors/tree-sitter/README.md`](../vendors/tree-sitter/README.md) describes the procedure. |
| Specifications and tickets | [Issue discovery](./agents/issue-tracker.md#when-a-skill-says-fetch-the-relevant-ticket) explains how to search `.scratch/` and follow feature maps. |
| Tests | [`build.zig`](../build.zig) defines the test gates. `zig build --help` lists the available targets. `zig build test-cli` runs the Python CLI checks. `zig build test` runs every other `tests/*_test.py` and `tests/*_test.sh` by the suffix of its name. `zig build test-builtin-grammars` runs the M27 Grammar and Injection tests. `zig build test` includes those checks and the full hermetic suite. |

## Seams

- `HttpClient` is the concurrent-send vtable seam under Bitbucket. Production uses `StdHttpClient`. Tests use `FakeHttpClient`. Another adapter requires a measured proxy need.
- `GitClient` is the seam under Git. It uses the `git` binary and supports test fixtures.
- `PendingReviewStore` is the repository seam under Review. Production uses SQLite or libSQL. Tests use an in-memory fake.
- `SubmissionLocks` is the live local ownership seam under Review. Production uses OS advisory locks. Deterministic tests use an in-memory lock table.
- `Highlighter` is the seam under Highlighting. It has plain and tree-sitter implementations and supports user-managed Grammars.
