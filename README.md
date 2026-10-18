# bbr — Bitbucket Reviewer

A Zig terminal UI for reviewing **Bitbucket Cloud** pull requests: browse the diff with proper
coloring and syntax highlighting, read comment threads, and compose comments, replies, and
suggestions that stay **pending locally** until you submit them as a batch.

> Status: **M19 (operational hardening and product gates) complete** — `bbr` reviews Bitbucket PullRequests or
> committed local Git refs through the same diff, authoring, highlighting, and rendering pipeline.
> Local drafts persist in SQLite, share across linked worktrees/clones with the same repository
> identity, and remain local-only. The implementation is exercised hermetically by `zig build test`.

## Documentation map

| Document | What it is |
|---|---|
| [`docs/design.html`](docs/design.html) | The design document — architecture, seams, diff/rendering, pending review, concurrency, memory, milestones. **Start here.** |
| [`GLOSSARY-MAP.md`](GLOSSARY-MAP.md) | Bounded contexts and how they relate. |
| `src/*/GLOSSARY.md` | Per-context domain vocabulary. |
| [`docs/code-navigation.md`](docs/code-navigation.md) | Code entry points, implementation seams, and links to context-specific implementation notes. |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records for the hard-to-reverse choices. |
| [`ZIG.md`](ZIG.md) | Zig 0.16.0 feature/API notes this project depends on. |
| [`docs/m16-operations.md`](docs/m16-operations.md) | Mutation, Submission repair, External Edit, and opt-in checks. |
| [`docs/m19-operations.md`](docs/m19-operations.md) | Required CI, source identity, Credential and HTTP policy, Candidate Session acquisition, and Reviewer Verdict Actions. |
| [`FEATURES.md`](FEATURES.md) | Feature set by area, tagged with delivering milestone. |
| [`TODO.md`](TODO.md) | Near-term actionable work, per milestone. |

## Key decisions at a glance

- **Target:** Bitbucket Cloud (`api.bitbucket.org/2.0`), workspace `check24`; HTTP Basic with an
  Atlassian API token saved via `bbr auth login` (environment override available).
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
zig build run -- --version       # print the reproducible source identity
zig build test                   # unit tests — hermetic, no network/disk (seams are faked)
zig build check -- <repo> <id>   # live smoke check against real Bitbucket (needs creds)
BBR_ALLOW_PTY_SMOKE=1 zig build check-external-edit
BBR_ALLOW_LIVE_MUTATION=1 zig build check-mutation -- <repo> <id>
BBR_ALLOW_LIVE_MUTATION=1 zig build check-verdict -- <repo> <id>
zig build run -- local [base-ref] [source-ref]  # committed local review (no creds)
```

`zig build test` is hermetic and CI-safe. The four required native CI jobs receive no Bitbucket
Credential. The `check*` commands are explicit local opt-ins and are never part of `test`; see
[`docs/m19-operations.md`](docs/m19-operations.md) for their gates and scope.

Remote-review credentials are managed with `bbr auth login` / `bbr auth status` /
`bbr auth logout` and stored in `$XDG_DATA_HOME/bbr/auth.toml` (fallback
`$HOME/.local/share/bbr/auth.toml` when `XDG_DATA_HOME` is unset, empty, or relative). The `bbr` directory is created and repaired to mode
`0700` (parents untouched); `auth.toml` is replaced atomically with mode `0600`.
`bbr auth login [profile]` prompts for each missing field in Email, Token, Workspace order
(`--email` / `--workspace` skip their prompts; the token prompt hides input and restores echo
on every exit), verifies the credential live against Bitbucket (`GET /user` plus a workspace
probe), then saves the profile and selects it as active. `--stdin` reads only the token as one
silent line and requires `--email` and `--workspace`; piped input without `--stdin` is refused
before the first prompt. Unknown arguments are rejected: the token never rides as a CLI argument.
`bbr auth status [profile]` always validates live and reports the profile, configured email,
workspace, per-field file-versus-environment source, proven account UUID, and separate account
and workspace results without ever printing the token. `bbr auth logout [profile]` removes the
selected Profile and keeps the rest; `--all` deletes only `auth.toml`. Logout is idempotent,
does not revoke the Atlassian API token, and cannot remove environment overrides.
Named profiles hold one credential set each (`[profiles.<name>]`); selection is positional arg,
then `--profile <name>`, then `BBR_PROFILE`, then the Active Profile in `active_profile`, then
`default`. `BITBUCKET_USERNAME`, `BITBUCKET_TOKEN`, `BITBUCKET_WORKSPACE` override the selected
profile per field (empty counts as missing; a complete set resolves without the file). `bbr local`
does not read or require them. Its SourceRef defaults to the current branch; its BaseRef defaults
to the tracking remote's locally recorded default branch and must be supplied when Git has no
such default.

Create the token at your Atlassian account (Security → API tokens) with an expiry date and the
minimum scopes for your work: `read:account` (prove the account), `read:repository:bitbucket`
(repositories, diffs, blobs), `read:pullrequest:bitbucket` (read, comment, tasks),
`write:pullrequest:bitbucket` (approve, decline, mutate), `read:workspace:bitbucket` (workspace
and member search). Rotate by creating a replacement token and running `bbr auth login` again;
tokens cannot be viewed after creation, so replace rather than recover. See
[API tokens](https://support.atlassian.com/bitbucket-cloud/docs/api-tokens/) and
[API token permissions](https://support.atlassian.com/bitbucket-cloud/docs/api-token-permissions/).

### Bitbucket API commands

`bbr api` uses the same saved Profiles and per-field environment overrides as remote review.
`--workspace` overrides both `BITBUCKET_WORKSPACE` and the selected Profile's Workspace.
The API commands do not load the TUI configuration.
Help does not need credentials.

```sh
bbr api --help
bbr api whoami --profile work --json
bbr --profile work api list-pull-requests --workspace check24 --repository sample
```

Find a Workspace Member's UUID before assigning a reviewer:

```sh
bbr api list-workspace-members --json
bbr api search-workspace-members --name 'Ada Lovelace' --json
bbr api search-workspace-members --name 'Kronechek Stefan' --limit 5 --json
bbr api search-workspace-members --name 'Ada Lovelace' --concurrency 4 --json
bbr api search-workspace-members --name 'Ada Lovelace' --name='Grace Hopper' --limit 5 --json
```

Member search reads every page in the selected Workspace before it ranks the results.
Repeat `--name` to search several names from one member list acquisition.
It defaults to 100 members per page and eight concurrent page requests.
`--concurrency N` accepts a positive integer and caps active requests at the logical CPU count.
The search starts the next page when a request finishes.
Without a total page count, the search can send extra requests beyond the last page.
The extra request count is at most the effective concurrency minus one.
An empty successful page without a next link marks the end. A failed request fails the complete search.
HTTP 429 fails with `RateLimited` without automatic retries.
It supports reversed name parts, omitted middle names, common German spelling forms, and small typos.
Results rank as `exact`, `spelling`, `partial`, and `fuzzy`.
Each match contains only the member's `uuid`, `display_name`, and `nickname`.
JSON returns an array of groups, even for one name.
Each group contains `name` and `matches`.
Groups preserve input order and duplicate name values.
Search's `--limit` caps returned matches per name, while list's `--limit` caps fetched members.
Human output starts each group with `name: TEXT`.
Each member line contains the UUID, display name, and nickname. The group ends with the number shown.
A name with no matches returns an empty group with exit status zero.
All names must pass validation before any member request. A failed search produces no partial groups.
Both commands require the `read:workspace:bitbucket` API token scope.
Workspace membership does not prove Repository access.

The `bbr` skill uses a single result directly when the name or nickname has only minor differences.
It asks you to select a member for multiple results or to confirm a single result with larger differences.
Use the selected UUID in `--reviewer UUID` or `--uuid UUID`.

Create a Branch and a Draft PullRequest, then mark the PullRequest ready:

```sh
bbr api create-branch --repository sample --name feature/example --target main
bbr api list-branches --repository sample --sort name --limit 10
bbr api get-branch --repository sample --name feature/example
bbr api create-pull-request --repository sample --title 'Example change' --source-branch feature/example --draft true
bbr api update-pull-request --repository sample --pull-request-id 42 --draft false
```

PullRequest creation requires a title and a source branch. It defaults to ready and uses the Repository's main branch as the destination. Use `--destination-branch` to select another destination. For a fork source, add `--source-repository WORKSPACE/SLUG`.

Create and update support descriptions, reviewers, draft state, and source-branch closure. `--description-file PATH` reads up to 1 MiB. Repeated `--reviewer UUID` options replace the reviewer list. `--clear-reviewers` sends an empty list. Omitted fields stay unchanged on update, including reviewers. An empty description clears the description.

Approve or decline a PullRequest, or find PullRequests for a commit:

```sh
bbr api set-verdict --repository sample --pull-request-id 42 --verdict approved --expected-source-commit abc123
bbr api decline-pull-request --repository sample --pull-request-id 42
bbr api list-commit-pull-requests --repository sample --commit abc123 --json
```

Approval sets the Authenticated Account's Reviewer Verdict. Decline closes the PullRequest without merging. Commit lookup includes closed PullRequests and follows pages by default. Use `--page`, `--pagelen`, `--no-follow`, and `--limit` to control the results.

Commit lookup needs Bitbucket's Pull Request Commit Links app. Bitbucket installs it when someone selects `Go to pull request` on a commit's details page. Pending indexing produces an error and a hint instead of an empty result.

### Shell completions

`bbr completion` prints a completion script for `bbr` commands, `bbr api` verbs,
and per-verb flags. `--profile` values complete from saved Profiles. No
credentials are needed to print a script.

```sh
eval "$(bbr completion bash)"                                   # try it once
bbr completion bash > ~/.local/share/bash-completion/completions/bbr
bbr completion zsh > "${fpath[1]}/_bbr"                        # then `compinit`
bbr completion fish > ~/.config/fish/completions/bbr.fish
```

## Configuration

The TUI reads `$XDG_CONFIG_HOME/bbr/config.toml`, falling back to
`$HOME/.config/bbr/config.toml` when `XDG_CONFIG_HOME` is unset, empty, or relative. A missing file uses defaults; an existing invalid file reports
all detected diagnostics and stops before entering the alternate screen.

Pending reviews persist in `$XDG_STATE_HOME/bbr/pending.db`, and submission locks live in
`$XDG_STATE_HOME/bbr/submission-locks`. When `XDG_STATE_HOME` is unset, empty, or relative, the
state directory is `$HOME/.local/state/bbr`. If you change `XDG_STATE_HOME`, move the existing
`pending.db` to the new directory, because bbr does not look for it in the old one.

```toml
theme = "system"

[keymap]
page_down = ["ctrl-f", "page-down"]
quit = []
review_comment = ["C", "space r c"]
select_old_version = ["h", "left"]
select_new_version = ["l", "right"]

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

DiffPane source Lines always wrap so every source location remains reachable.

In the DiffPane, `h` or Left Arrow selects the old File version.
`l` or Right Arrow selects the new File version.
Cursor and visual-selection highlights show only source Lines from Selected Version.
Copying a wrapped Line includes its complete source text once.
Changing Selected Version clears visual selection.

`j`, `k`, and vertical arrows skip source rows without a Line for Selected Version.
Real blank Lines remain navigation stops.
File headers, Hunk headers, Folds, and Comments also remain stops.
These keys skip an entire deleted File when new is selected.
They skip an entire added File when old is selected.
Opening a File directly selects old for a deleted File and new for an added File.
The absent version cannot be selected in these Files.
The Sidebar keeps `h` and `l` for collapse and expand.

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
`g a`/`g c`/`g n` for Approved/Changes Requested/No Verdict, `ctrl-y`/`ctrl-e` for one-row
scrolling, and `y` for OSC 52 source-text yank.
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

### Manage UserGrammars

> **Warning:** A UserGrammar contains native code. It runs in the `bbr` process with your
> permissions and can access the same memory and files. A SHA-256 digest proves the bundle's
> identity and integrity. It does not prove that the code is safe.

`bbr` installs only a local, prebuilt UserGrammar bundle. It does not download Grammar sources,
compile a Grammar, discover packages, or update a UserGrammar automatically.

Check a folder or `.tar.gz` archive before installation:

```sh
bbr grammar check ./tree-sitter-example-bundle
```

The output includes the UserGrammar identity, its GrammarMatch rules, affected BuiltInGrammars,
and the canonical SHA-256 digest. Install the exact bundle interactively, or pass the reported
digest in automation:

```sh
bbr grammar install ./tree-sitter-example-bundle
bbr grammar install ./tree-sitter-example-bundle --trust-sha256 <digest>
```

Installation enables the bundle's default GrammarMatch rules. These commands manage the rest of
the lifecycle:

```sh
bbr grammar list
bbr grammar check <name>
bbr grammar update <name> ./replacement-bundle --trust-sha256 <digest>
bbr grammar disable <name>
bbr grammar enable <name>
bbr grammar remove <name>
```

`disable` keeps the installed files. `enable` checks all active GrammarMatch rules again. `remove`
refuses a UserGrammar that still has a `[grammars.<name>]` table in `config.toml`. A failed install
or update keeps the prior installation and registry. A running `bbr` process does not reload CLI
changes.

To replace all default GrammarMatch rules for one UserGrammar, add at least one field:

```toml
[grammars.example]
filenames = ["Examplefile"]
compound_suffixes = [".example.test"]
extensions = [".example"]
shebangs = ["#!/usr/bin/env example"]
```

An active missing, changed, or invalid UserGrammar stops a new `bbr` process. An invalid disabled
UserGrammar appears as `invalid` in `bbr grammar list` and does not stop startup. If a UserGrammar
fails during Highlighting, `bbr` uses a matching BuiltInGrammar or plain text.

Full file content has no size limit. The focused File is always retained while it is being
reviewed. Inactive file content uses a whole-File least-recently-used cache: it is enabled by
default with a 256 MiB budget across the current review. Evicted Files are fetched again when
revisited. The focused File is outside the budget and may exceed it. Set `max_bytes = 0` for
unlimited inactive caching, or `enabled = false` to retain only the focused File. This cache limit
controls retained inactive content; `[highlight].max_file_bytes` separately limits Highlighting
work and never makes oversized content unreadable.

After an explicit move to the next File in a remote review, `bbr` prefetches only that File's
immediate successor. Other File focus changes and LocalReviews use demand loading. Disabling the
inactive File cache also disables prefetch. File content and Highlighting stay in memory and are
never written to SQLite, the state directory, or the data directory.

## Reference

High-quality Zig codebase used as a reference for structure and idioms:
[`ghostty`](https://github.com/ghostty-org/ghostty).
