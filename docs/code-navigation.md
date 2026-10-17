# Code navigation

The [glossary map](../GLOSSARY-MAP.md) defines the contexts and their relationships.
These paths identify implementation entry points in the current checkout.

## Code entry points

| Work | Entry points |
|---|---|
| Top-level commands and review startup | [`src/main.zig`](../src/main.zig) dispatches commands. [`src/startup.zig`](../src/startup.zig) selects the review source. |
| Profiles and Credential selection | [`src/bitbucket/auth.zig`](../src/bitbucket/auth.zig) stores Profiles and resolves Credentials. [`src/main.zig`](../src/main.zig) handles login and logout. |
| `bbr api` verbs and flags | [`src/api/cli.zig`](../src/api/cli.zig) holds the verb table and global parser. [`src/api/args.zig`](../src/api/args.zig) holds argument helpers. Resource files in [`src/api/`](../src/api/) handle each verb. |
| API output and endpoint behavior | [`src/api/output.zig`](../src/api/output.zig) formats CLI output. [`src/bitbucket/client.zig`](../src/bitbucket/client.zig) implements the Bitbucket adapter. [Bitbucket implementation notes](../src/bitbucket/IMPLEMENTATION.md) record verified API quirks. |
| Shell completions | [`src/completion.zig`](../src/completion.zig) generates completion scripts from the API registry. |
| Markdown, search, Selection, and terminal rendering | [Presentation entry points](../src/tui/IMPLEMENTATION.md#code-entry-points) map the semantic model, row projection, interaction owner, and terminal adapters. |
| Specifications and tickets | [Issue discovery](./agents/issue-tracker.md#when-a-skill-says-fetch-the-relevant-ticket) explains how to search `.scratch/` and follow feature maps. |
| Tests | [`build.zig`](../build.zig) defines the test gates. `zig build --help` lists the available targets. `zig build test-cli` runs the Python CLI checks. `zig build test` includes those checks and the full hermetic suite. |

## Seams

- `HttpClient` is the concurrent-send vtable seam under Bitbucket. Production uses `StdHttpClient`. Tests use `FakeHttpClient`. Another adapter requires a measured proxy need.
- `GitClient` is the seam under Git. It uses the `git` binary and supports test fixtures.
- `PendingReviewStore` is the repository seam under Review. Production uses SQLite or libSQL. Tests use an in-memory fake.
- `SubmissionLocks` is the live local ownership seam under Review. Production uses OS advisory locks. Deterministic tests use an in-memory lock table.
- `Highlighter` is the seam under Highlighting. It has plain and tree-sitter implementations and supports user-managed Grammars.
