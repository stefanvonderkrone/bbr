# bbr — Bitbucket Reviewer

A Zig terminal UI for reviewing **Bitbucket Cloud** pull requests: browse the diff with proper
coloring and syntax highlighting, read comment threads, and compose comments, replies, and
suggestions that stay **pending locally** until you submit them as a batch.

> Status: **M16 (review mutation and Submission hardening) complete** — `bbr` reviews Bitbucket PullRequests or
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
| [`docs/m16-operations.md`](docs/m16-operations.md) | Mutation, Submission repair, External Edit, and opt-in checks. |
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
`M19` operational hardening/product gates → `M20` side-aware version inspection →
`M21` buffer & review search → `M22` durable File read state →
`M23` comment thread presentation fixes → `M24` remote-first Browser →
`M25` Browser navigation/settings → `M26` Credential login/logout.

**MVP line:** M0–M3 (usable read-only), M4 (ergonomic), M6+M10 (write-capable — the headline).
Full breakdown with dependencies in `docs/design.html` §14 and `TODO.md`.

## Building (once code lands)

```sh
zig build                        # build the bbr executable
zig build test                   # unit tests — hermetic, no network/disk (seams are faked)
zig build check -- <repo> <id>   # live smoke check against real Bitbucket (needs creds)
BBR_ALLOW_PTY_SMOKE=1 zig build check-external-edit
BBR_ALLOW_LIVE_MUTATION=1 zig build check-mutation -- <repo> <id>
zig build run -- local [base-ref] [source-ref]  # committed local review (no creds)
```

`zig build test` is hermetic and CI-safe. The `check*` commands are explicit opt-in tiers and are
never part of `test`; see [`docs/m16-operations.md`](docs/m16-operations.md) for their gates and scope.

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
page_down = ["ctrl-f", "page-down"]
quit = []
review_comment = ["C", "space r c"]

[highlight]
max_file_bytes = 2097152

[comments]
collapsed_rows = 6

[files.cache]
enabled = true
max_bytes = 268435456

[input.mouse]
enabled = true
vertical_scroll_rows = 3

[external_edit]
max_bytes = 1048576
```

`system` is the default Theme and uses the terminal foreground, background, and ANSI palette.
Fixed Themes are `dark`, `light`, all four `catppuccin-*` flavors, `gruvbox-light`,
`gruvbox-dark`, `solarized-light`, and `solarized-dark`.

Keymap entries map each Action name to one or more one-to-eight-chord sequences.
An empty list unbinds that Action. Contextual Actions may deliberately share a chord—Enter, for
example, confirms a Picker, focuses a File, toggles a Directory, or toggles the disclosure under
the DiffPane cursor. Bindings that can be available together are rejected as ambiguous. Modifiers are
`shift`, `alt`, `ctrl`, `super`, `hyper`, and `meta`; `option`, `control`, `cmd`, and `command`
are accepted aliases. Count digits remain reserved at
the start of a sequence, and no complete binding may be a Leader for a longer binding.
Unknown or duplicate settings, invalid values, renamed keys, and ambiguous contextual bindings are
rejected with the source line. Configuration names are exact; superseded Action and setting names
are not retained as compatibility aliases.

The default workflow keys are `F` for the Session-local File finder, `p` for the PullRequest
Picker, `i`/`I`/`C` for inline/File-level/Review-level Comments, `gC` for recovery linking,
`ctrl-y`/`ctrl-e` for one-row scrolling, and `y` for OSC 52 source-text yank.
The File finder focuses a changed File in the current Session. The PullRequest Picker opens all
open PullRequests, accepts input while loading, shows a small spinner, and replaces the Session
only after Enter confirms a result; Escape dismisses either Overlay. Unavailable Actions remain
visible but subdued in help and explain why they cannot run—for example, remote-only Actions in a
local review or source-only Actions away from a source row.

Inside any Composer, `Ctrl-E` hands the exact current body to the first non-empty `GIT_EDITOR`,
`VISUAL`, or `EDITOR`. External Edit returns to the same open Composer without saving or publishing.
`[external_edit].max_bytes` is the local limit for the file returned by that program; it defaults
to 1 MiB and must be greater than zero.

Enter also opens and closes the disclosure at the cursor: resolved Threads, context Folds,
Outdated sections, and over-limit ReviewCards retain independent disclosure state within the
current Session. Comments and Drafts show six rendered body rows when collapsed by default.
Set `[comments].collapsed_rows = 0` to disable automatic ReviewCard collapse. Root Comments can
target the Review (`C`), the focused File (`I`), or an inline source location (`i`); Replies keep
their root Comment's scope.

Mouse navigation is enabled by default as an optional keyboard-equivalent convenience. Left-click
focuses Panes, activates File Tree entries and disclosures, or selects a Picker row; Picker clicks
never confirm. The vertical wheel scrolls three rows by default. Set `[input.mouse].enabled = false`
to restore ordinary terminal mouse handling, or configure `vertical_scroll_rows` to another positive
count. Terminals commonly use Shift or Option as a terminal-dependent bypass for native selection
while mouse reporting is enabled.

Syntax highlighting is loaded lazily for the focused File. `max_file_bytes` limits each old/new
file side independently; the 2 MiB default avoids expensive parsing of generated or minified
files. Set it to `0` for no limit. Files above the limit remain readable as plain text.

Full file content has no size limit. The focused File is always retained while it is being
reviewed. Inactive file content uses a whole-File least-recently-used cache: it is enabled by
default with a 256 MiB budget across the current review. Evicted Files are fetched again when
revisited. The focused File is outside the budget and may exceed it. Set `max_bytes = 0` for
unlimited inactive caching, or `enabled = false` to retain only the focused File. This cache limit
controls retained inactive content; `[highlight].max_file_bytes` separately limits Highlighting
work and never makes oversized content unreadable.

## Reference

High-quality Zig codebase used as a reference for structure and idioms:
[`ghostty`](https://github.com/ghostty-org/ghostty).
