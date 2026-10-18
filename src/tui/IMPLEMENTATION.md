# Presentation implementation

The [Presentation glossary](./GLOSSARY.md) defines the domain terms used here.

## Code entry points

| Work | Owner |
|---|---|
| Authored Markdown meaning and source ranges | [`review_body.zig`](./review_body.zig) interprets a ReviewBody independently of terminal width. |
| ReviewCard wrapping and disclosure | [`review_card.zig`](./review_card.zig) projects a ReviewBody into width-dependent rows with authored source ranges. |
| DiffPane row order and Thread placement | [`buffer.zig`](./buffer.zig) combines source Lines, ReviewCards, Folds, and disclosures into a Buffer. |
| Search matching and authored locations | [`search.zig`](./search.zig) defines the search corpus, mappings, and Search Occurrences. [`presentation.zig`](./presentation.zig) owns search interaction and navigation. |
| Selection and clipboard commands | [`presentation.zig`](./presentation.zig) owns Selection and yank behavior. [`frame.zig`](./frame.zig) projects source targets for Selected Version. |
| Geometry and terminal cells | [`frame.zig`](./frame.zig) builds the Presentation Frame. [`render.zig`](./render.zig) draws its rows with styles from [`theme.zig`](./theme.zig). |
| Key input and Actions | [`keymap.zig`](./keymap.zig) resolves input. [`action.zig`](./action.zig) defines Actions. [`presentation.zig`](./presentation.zig) dispatches them. |
| List Overlays and the Command Palette | [`list_overlay.zig`](./list_overlay.zig) owns ranking, selection, per-Overlay policy, and the curated Command Palette table. [`presentation.zig`](./presentation.zig) acts on the confirmed choice. [`render.zig`](./render.zig) draws every List Overlay. |
| Theme selection and persistence | [`theme_id.zig`](./theme_id.zig) names the built-in Themes without vaxis. [`theme.zig`](./theme.zig) maps each one to styles. [`config.zig`](./config.zig) reads the Configured Theme and writes it back to config.toml. |
| Session lifetime and owned commands | [`presentation.zig`](./presentation.zig) owns state transitions, command production, and completion admission under [ADR-0012](../../docs/adr/0012-presentation-is-a-typed-command-producing-state-machine.md). |
| Command execution and terminal events | [`presentation_adapter.zig`](./presentation_adapter.zig) executes commands. [`presentation_runtime.zig`](./presentation_runtime.zig) transfers worker completions. [`app.zig`](./app.zig) connects Presentation to the terminal loop. |

Markdown changes can affect search mappings, Selection bytes, and terminal cells through this projection chain.
The relevant tests live beside their implementation and enter the build through the imports in [`../main.zig`](../main.zig).
[`../../build.zig`](../../build.zig) defines focused test targets as well as the full `test` gate.

## Acquisition concurrency

All remote TUI work uses one TUI-lifetime `StdHttpClient` connection pool.
Candidate Session acquisition uses at most two active requests.
PullRequest, RawDiff, and Comments are required.
Authenticated Account acquisition is independent.
Comments wait for PullRequest commit data and take priority over RawDiff when both can start.
Remote File Enrichment fetches its old and new sides concurrently, with at most two requests per File.
All started branches complete without branch cancellation.
LocalReview acquisition and LocalReview File Enrichment remain sequential.
