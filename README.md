# bbr — Bitbucket Reviewer

A Zig terminal UI for reviewing **Bitbucket Cloud** pull requests: browse the diff with proper
coloring and syntax highlighting, read comment threads, and compose comments, replies, and
suggestions that stay **pending locally** until you submit them as a batch.

> Status: **M14 (local/offline review) complete** — `bbr` reviews Bitbucket PullRequests or
> committed local Git refs through the same diff, authoring, highlighting, and rendering pipeline.
> Local drafts persist in SQLite, share across linked worktrees/clones with the same repository
> identity, and remain local-only. The implementation is exercised hermetically by `zig build test`.

## Documentation map

| Document | What it is |
|---|---|
| [`docs/design.html`](docs/design.html) | The design document — architecture, seams, diff/rendering, pending review, concurrency, memory, milestones. **Start here.** |
| [`CONTEXT-MAP.md`](CONTEXT-MAP.md) | Bounded contexts and how they relate. |
| `src/*/CONTEXT.md` | Per-context glossary (ubiquitous language). Pure vocabulary, no implementation. |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records for the hard-to-reverse choices. |
| [`ZIG.md`](ZIG.md) | Zig 0.16.0 feature/API notes this project depends on. |
| [`FEATURES.md`](FEATURES.md) | Feature set by area, tagged with delivering milestone. |
| [`TODO.md`](TODO.md) | Near-term actionable work, per milestone. |

## Key decisions at a glance

- **Target:** Bitbucket Cloud (`api.bitbucket.org/2.0`), workspace `check24`; HTTP Basic with an
  Atlassian API token from the environment.
- **Stack:** Zig 0.16.0, libvaxis (TUI), zf (fuzzy find), SQLite/libSQL (pending reviews),
  tree-sitter (highlighting, post-MVP).
- **Pending review is client-side** — Bitbucket Cloud has no native draft concept
  ([ADR-0002](docs/adr/0002-client-side-pending-review-batch.md)).
- **Bitbucket's diff is the authoritative line model** so comment anchors are correct by
  construction ([ADR-0001](docs/adr/0001-bitbucket-diff-is-authoritative-line-model.md)).
- **External deps sit behind swappable seams** (`HttpClient`, `GitClient`, `PendingReviewStore`,
  `Highlighter`) — which is also what makes the domain testable
  ([ADR-0003](docs/adr/0003-swappable-seams-std-http-sqlite-treesitter.md)).
- **Two review modes over one pipeline** — remote (Bitbucket PR) and local (branch vs base ref,
  offline, comments in SQLite), unified by a `DiffSource`
  ([ADR-0004](docs/adr/0004-local-offline-review-via-diffsource-and-git-shell-out.md)).
- **Comments have an anchor lifecycle** — current / moved / outdated; outdated comments are
  always retained and resolved Threads can be revealed as a whole
  ([ADR-0005](docs/adr/0005-comment-anchor-lifecycle.md)).

## Milestones

Small vertical slices (sizes are relative effort, not dates):

`M0` walking skeleton → `M1` diff model & parser (pure, tested) → `M2` unified viewer →
`M3` comments (read) → `M4` PR discovery & switching → `M5` diff polish →
`M6` pending review: authoring → `M7` responsiveness (non-blocking loads) →
`M8` file view scope (single-file) → `M9` true whole-file view →
`M10` pending review submission → `M10b` multi-line anchors/reconciliation →
`M11` keymap & motions → `M12` themes & config →
`M13` syntax highlighting → `M14` local / offline review →
`M15` presentation/navigation polish → `M16` review-item mutation/submission hardening →
`M17` diff/blob/highlighting completeness → `M18` local-review expansion →
`M19` operational hardening/product gates.

**MVP line:** M0–M3 (usable read-only), M4 (ergonomic), M6+M10 (write-capable — the headline).
Full breakdown with dependencies in `docs/design.html` §14 and `TODO.md`.

## Building (once code lands)

```sh
zig build                        # build the bbr executable
zig build test                   # unit tests — hermetic, no network/disk (seams are faked)
zig build check -- <repo> <id>   # live smoke check against real Bitbucket (needs creds)
zig build run -- local [base-ref] [source-ref]  # committed local review (no creds)
```

`zig build test` is hermetic and CI-safe. `zig build check` is the opt-in live tier: it hits real
Bitbucket, so it needs credentials and is never part of `test`.

Remote-review credentials come from the environment only (never a config file, never persisted):
`BITBUCKET_USERNAME`, `BITBUCKET_TOKEN`, `BITBUCKET_WORKSPACE`. `bbr local` does not read or
require them. Its SourceRef defaults to the current branch; its BaseRef defaults to the tracking
remote's locally recorded default branch and must be supplied when Git has no such default.

## Configuration

The TUI reads `$XDG_CONFIG_HOME/bbr/config.toml`, falling back to
`$HOME/.config/bbr/config.toml`. A missing file uses defaults; an existing invalid file reports
all detected diagnostics and stops before entering the alternate screen.

```toml
theme = "system"

[keymap]
"ctrl-d" = "page-down"
"q" = "none"
"space r c" = "comment"

[highlight]
max_file_bytes = 2097152

[files.cache]
enabled = true
max_retained_bytes_per_review = 268435456
```

`system` is the default Theme and uses the terminal foreground, background, and ANSI palette.
Fixed Themes are `dark`, `light`, all four `catppuccin-*` flavors, `gruvbox-light`,
`gruvbox-dark`, `solarized-light`, and `solarized-dark`.

Keymap entries map one-to-eight space-separated chords to kebab-case Action names. Modifiers are
`shift`, `alt`, `ctrl`, `super`, `hyper`, and `meta`; `option`, `control`, `cmd`, and `command`
are accepted aliases. Assign `none` to remove a default binding. Count digits remain reserved at
the start of a sequence, and no complete binding may be a Leader for a longer binding.

Syntax highlighting is loaded lazily for the focused File. `max_file_bytes` limits each old/new
file side independently; the 2 MiB default avoids expensive parsing of generated or minified
files. Set it to `0` for no limit. Files above the limit remain readable as plain text.

Full file content has no size limit. The focused File is always retained while it is being
reviewed. Inactive file content uses a whole-File least-recently-used cache: it is enabled by
default with a 256 MiB budget across the current review, counting the complete owned allocation
capacity for blobs, Highlight Spans, Capture names, and retained scratch. Evicted Files are fetched again when revisited. Set `enabled = false` to retain
only the focused File; `max_retained_bytes_per_review` must be greater than zero while the cache
is enabled.

## Reference

High-quality Zig codebase used as a reference for structure and idioms:
[`ghostty`](https://github.com/ghostty-org/ghostty).
