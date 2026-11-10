# Code navigation

The [glossary map](../GLOSSARY-MAP.md) defines the contexts and their relationships.
These paths identify implementation entry points in the current checkout.

## Code entry points

| Work | Entry points |
|---|---|
| Top-level commands and review startup | [`src/main.zig`](../src/main.zig) dispatches commands. [`src/startup.zig`](../src/startup.zig) owns Startup Detection. `startup.start` keeps the URL and `<repo> <id>` paths and calls `startup.inspect` for the other paths. `startup.inspect` reads only the GitClient before the TUI starts. `startup.detect` lists the AdjacentPullRequests on a worker. `startup.describe` prints the `bbr detect` outcome line. |
| Profiles and Credential selection | [`src/bitbucket/auth.zig`](../src/bitbucket/auth.zig) stores Profiles and resolves Credentials. [`src/main.zig`](../src/main.zig) handles login and logout. |
| Config, data, and state directories | [`src/xdg.zig`](../src/xdg.zig) resolves the config home, the data home, the state home, and the `config.toml` path. [`src/main.zig`](../src/main.zig) puts `pending.db`, the submission locks, and the Summary Cache file `bbr/browser-cache.json` under the state home. |
| Diagnostic logging | [`src/diagnostics.zig`](../src/diagnostics.zig) owns private files and enablement. [`src/diagnostic.zig`](../src/diagnostic.zig) defines safe evidence. [`src/logging_config.zig`](../src/logging_config.zig) validates the startup setting. [Diagnostic logging](diagnostic-logging.md) lists records, owners, checks, and limits. |
| Standard output | [`src/stdout.zig`](../src/stdout.zig) owns the stdout writer and turns a closed pipe into `error.StdoutClosed`. `main` in [`src/main.zig`](../src/main.zig) ends quietly on that error. |
| `bbr api` verbs and flags | [`src/api/cli.zig`](../src/api/cli.zig) holds the verb table and global parser. [`src/api/args.zig`](../src/api/args.zig) holds argument helpers. Resource files in [`src/api/`](../src/api/) handle each verb. |
| API output and endpoint behavior | [`src/api/output.zig`](../src/api/output.zig) formats CLI output. [`src/bitbucket/client.zig`](../src/bitbucket/client.zig) implements the Bitbucket adapter. [Bitbucket implementation notes](../src/bitbucket/IMPLEMENTATION.md) record verified API quirks. |
| Repository and PullRequest Browser | [`src/tui/browser.zig`](../src/tui/browser.zig) owns the Browser model and its Browser Entries. [`src/bitbucket/summary_cache.zig`](../src/bitbucket/summary_cache.zig) encodes and decodes the Summary Cache. [Presentation entry points](../src/tui/IMPLEMENTATION.md#code-entry-points) name the other owners. |
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
