# M24 Remote-first Repository and PullRequest Browser

Status: ready-for-agent
Milestone: M24

The [M24 brief](brief.md) records the approved decisions.
This spec turns the brief and the M24 section of [TODO.md](../../TODO.md) into buildable form.
The implementation tickets live in [issues](issues/).

## Problem Statement

Today, plain `bbr` works only inside a WorkingCopy of a Bitbucket Repository.
It finds the AdjacentPullRequest for the current branch, or it opens the first PullRequest of a list.
A reviewer who reviews other people's work across many Repositories has no entry point.
That reviewer must know the Repository slug and the PullRequestId, or paste a URL.

Startup also blocks before the TUI starts.
`openTui` in `src/main.zig` calls `startup.resolve`, which waits for the network.
The terminal shows nothing while the PullRequest list loads.

## Solution

Plain `bbr` enters the TUI at once.
When the current branch is known, it shows the Detecting Frame "Detecting PR for `<branch>`…".
When Startup Detection finds exactly one AdjacentPullRequest, bbr opens its review Session, as it does today.
In every other case, bbr opens the Browser for the configured Workspace.

The Browser is one tree, like a file manager.
Its top level lists the Repositories of the Workspace.
Under each expanded Repository, it lists the open PullRequests of that Repository.
Each row shows only the facts that belong to that row.

The Browser shows the Summary Cache at once and refreshes it in the background.
It loads the PullRequests of a Repository only when the reviewer expands that Repository.
Request identities reject stale completions.
A failed request changes only its own row.

From a review Session, the new `open_browser` Action on `b` opens the Browser.
Enter on a PullRequest row opens its review Session.
The Browser keeps its state when the reviewer goes back and forth.

## User Stories

1. As a reviewer, I want plain `bbr` to start the TUI at once, so that I never stare at an empty terminal.
2. As a reviewer, I want the Detecting Frame to name my branch, so that I know what bbr looks for.
3. As a reviewer, I want `q` to quit during detection, so that a slow network never traps me.
4. As a reviewer, I want one AdjacentPullRequest to open its review Session, so that my usual flow stays one command.
5. As a reviewer, I want two or more AdjacentPullRequests to open the Browser on the newest one, so that I can choose.
6. As a reviewer, I want no AdjacentPullRequest to open the Browser on my Repository, so that I see its open PullRequests.
7. As a reviewer, I want a detached HEAD to open the Browser on my Repository, so that detection never fails loudly.
8. As a reviewer, I want `bbr` outside Git to open the Browser, so that I can review from any directory.
9. As a reviewer, I want a failed detection to open the plain Browser with no note, so that startup never blocks on an error.
10. As a reviewer, I want `bbr <repo-slug>` to detect in that Repository, so that I can name the Repository myself.
11. As a reviewer, I want URL and `<repo> <id>` startup to stay unchanged, so that my scripts keep working.
12. As a script author, I want `bbr detect` to print the startup outcome, so that I can check detection without the TUI.
13. As a reviewer, I want every Repository I can access in the Browser, so that I find work outside my WorkingCopy.
14. As a reviewer, I want Repositories without open PullRequests in the list, so that the list is complete.
15. As a reviewer, I want a Repository row to show its name, slug, and update time, so that I recognize it.
16. As a reviewer, I want a Repository row to show its open-PullRequest count only after it is known, so that I never read a guess.
17. As a reviewer, I want a PullRequest row to show id, title, author, update time, and branches, so that I can choose without opening it.
18. As a reviewer, I want a PullRequest row to show its approval and changes-requested counts, so that I see its review state.
19. As a reviewer, I want PullRequests to load only when I expand a Repository, so that the Browser does not flood Bitbucket.
20. As a reviewer, I want one failed Repository to keep the other results, so that one error does not hide everything.
21. As a reviewer, I want loading, empty, and failure rows, so that I always know the state of a Repository.
22. As a reviewer, I want the cached Browser at once, so that I can orient without waiting for the network.
23. As a reviewer, I want a background refresh to remove closed PullRequests and lost Repositories, so that the cache never lies for long.
24. As a reviewer, I want updated-time sorts by default, so that recent work is on top.
25. As a reviewer, I want name and id sorts that keep my selection, so that a sort never loses my place.
26. As a reviewer, I want Enter on a PullRequest row to open its review Session, so that the Browser leads to review.
27. As a reviewer, I want `b` to open the Browser from a review Session, so that I can switch to other work.
28. As a reviewer, I want the first `b` to expand my Repository and focus my PullRequest, so that I start where I am.
29. As a reviewer, I want the Browser to keep its expansion, selection, scroll, and summaries, so that going back costs nothing.
30. As a reviewer, I want Escape or `b` in the Browser to return to my review Session, so that I can cancel a switch.
31. As a reviewer, I want mouse clicks to select and open rows, so that the mouse and the keyboard do the same work.
32. As a reviewer, I want the terminal to stay responsive while pages load, so that I can keep working.
33. As a maintainer, I want fakes to drive every Browser state, so that the suite needs no network.
34. As a maintainer, I want a live, Credential-gated shape check, so that the participant and permission fields are proven.

## Glossary changes

The Bitbucket, Git, and Presentation glossaries already name Workspace, Repository, PullRequest, AdjacentPullRequest, and Picker.
M24 adds and changes these entries.
Ticket 06 writes them.

In the [Bitbucket glossary](../../src/bitbucket/GLOSSARY.md):

- Add Repository Summary:
  The Browser facts of one Repository: slug, name, and Repository update time.
  It holds no PullRequest data.
  _Avoid_: Repository (the Bitbucket entity), repo row.
- Add PullRequest Summary:
  The Browser facts of one open PullRequest: PullRequestId, title, PullRequest Author, update time, source and destination Branches, approval count, and changes-requested count.
  It holds no description and no Comment.
  _Avoid_: PullRequest (the aggregate root), PR row.
- Add Summary Cache:
  The local file of Repository Summaries and PullRequest Summaries for one Workspace.
  bbr shows it at Browser start and replaces it after each refresh.
  It holds no Credential and no PullRequest description.
  bbr rebuilds it after any parse error.
  _Avoid_: cache (alone), offline copy, database.

In the [Git glossary](../../src/git/GLOSSARY.md):

- Add Startup Detection:
  The lookup that plain `bbr`, `bbr <repo-slug>`, and `bbr detect` run.
  It reads the current branch and the Remote, and it lists the AdjacentPullRequests.
  Its outcome is one review Session or a Browser Start.
  _Avoid_: auto-detect, resolve.
- Change AdjacentPullRequest:
  Replace "Zero matches → the no-PR chooser; more than one → a pre-filtered Picker" with the new rule.
  Exactly one match opens its review Session.
  Zero or several matches open the Browser.
- Change GitClient:
  Its read-only inspection subset powers Startup Detection.

In the [Presentation glossary](../../src/tui/GLOSSARY.md):

- Add Browser:
  The Workspace-wide tree of Repositories and, under each expanded Repository, its open PullRequests.
  It fills the content region in place of the Sidebar and the DiffPane.
  Its state belongs to the process, not to the Session, so Session replacement never resets it.
  _Avoid_: dashboard, chooser, Picker (switches PullRequests in one Repository).
- Add Browser Entry:
  One row of the Browser: a Repository entry, a PullRequest entry, or a message entry.
  A message entry shows a loading, empty, or failure state and never takes the cursor.
  _Avoid_: node, item, line.
- Add Browser Start:
  The expanded Repository and the focused PullRequest that a new Browser begins with.
  Startup Detection or the first `open_browser` chooses it.
  _Avoid_: initial state, landing.
- Add Detecting Frame:
  The loading frame that names the current branch while Startup Detection lists AdjacentPullRequests.
  Only `quit` is available in it.
  _Avoid_: splash, spinner.
- Change Pane:
  Add the Browser as one Pane role.
- Change Interaction Context:
  Add the Detecting Frame and the Browser Entry under the cursor as input surfaces.

In [GLOSSARY-MAP.md](../../GLOSSARY-MAP.md):

- Change "Git → Bitbucket":
  Startup Detection finds the AdjacentPullRequests and opens one review Session or the Browser.
- Add "Bitbucket → Presentation":
  The Browser projects Repository Summaries and PullRequest Summaries.
  It never projects a Session.

## Behavior

### Startup paths

`src/main.zig` builds a `startup.Input` from argv, as today.
The URL path and the `<repo> <id>` path do not change.
They dispatch `choose_pull_request`, and the TUI shows the existing "Loading PR #N…" frame.

Plain `bbr` and `bbr <repo-slug>` run Startup Detection in two steps.

Step 1 is local and runs before the TUI starts.
`startup.inspect(allocator, git, workspace, input) Inspection` reads the GitClient only.
It never calls Bitbucket.

| Local state | `Inspection` |
| --- | --- |
| `<repo-slug>` given and a current branch exists | `.detect` with the argument Repository and the branch |
| `<repo-slug>` given, but a detached HEAD, no Git repository, or another Git error | `.browse` with the argument Repository expanded |
| No argument, a current branch, and a Bitbucket Remote in the configured Workspace | `.detect` with the Remote Repository and the branch |
| No argument, a detached HEAD, and a Bitbucket Remote in the configured Workspace | `.browse` with the Remote Repository expanded and focused |
| No argument and no Git repository, no Remote, or a Remote in another Workspace | `.browse` with no expanded Repository |

The Workspace comparison ignores ASCII case.
Today, `resolveRepo` drops the Remote Workspace, so it cannot see a foreign Remote.
M24 fixes this.

Step 2 is remote and runs in a worker after the TUI starts.
`startup.detect(allocator, bb, detection) Outcome` lists the open PullRequests whose source Branch is the current branch.

| AdjacentPullRequests | `Outcome` |
| --- | --- |
| Exactly one | `.open` with the Repository and its PullRequestId |
| Two or more | `.browse` with the Repository expanded and the highest PullRequestId focused |
| None | `.browse` with the Repository expanded and focused |
| The list request fails, without a `<repo-slug>` argument | `.browse` with no expanded Repository |
| The list request fails, with a `<repo-slug>` argument | `.browse` with the argument Repository expanded |

The newest AdjacentPullRequest is the one with the highest PullRequestId.
Bitbucket assigns PullRequestIds in creation order within one Repository.

A failed detection shows no note in the TUI.
`startup.resolve`, `startup.Entry.pick`, and `startup.Entry.empty` go away.
`openTui` no longer prints "N open PRs; opening #M".

### The Detecting Frame

`app.run` takes a `startup.Start` instead of `repo` and the initial `OwnedReviewIdentity`.
It dispatches one of three inputs after `Presentation.init`:

- `choose_pull_request` for the URL and `<repo> <id>` paths.
- `detect_startup` with the Workspace, the Repository, and the branch, for an `Inspection.detect`.
- `start_browser` with a Browser Start, for an `Inspection.browse`.

`detect_startup` makes Presentation queue one `detect_adjacent_pull_requests` command.
While it runs, `Projection.detecting` holds the branch.
`app.zig` paints it with `render.drawDetecting`, which uses `layouts.loading`.
The text is "Detecting PR for `<branch>`…".

The Interaction Context is `detecting`.
It supports only `quit`.
`q` requests shutdown at once.
Shutdown waits for the detection worker, like it waits for a Picker list today.

The `adjacent_detected` completion carries the `Outcome`.
`.open` dispatches the same path as `choose_pull_request`.
`.browse` starts the Browser with that Browser Start.

### `bbr detect`

`detectRun` in `src/main.zig` runs `startup.inspect` and then `startup.detect` when needed.
It prints the `branch:` and `remote:` diagnostic lines, as today.
`startup.describe(outcome, writer)` prints the outcome line:

| Outcome | Line |
| --- | --- |
| Open | `resolved: open <repo> #<id>` |
| Browser with a focused PullRequest | `resolved: browser <repo> expanded, focus #<id>` |
| Browser with an expanded Repository | `resolved: browser <repo> expanded` |
| Plain Browser | `resolved: browser` |

A failed detection also prints `reason: <error name>` above the outcome line.
`bbr detect` exits `0` for every outcome.
A missing Credential still exits as it does today.
`bbr detect` never reads or writes the Summary Cache.

### Summary acquisition

`src/bitbucket/types.zig` adds `RepositorySummary`:

```zig
pub const RepositorySummary = struct {
    slug: []const u8,
    name: []const u8,
    /// Unix seconds, or null when Bitbucket omits the field.
    updated_on: ?i64,
};
```

`PullRequestSummary` gains three fields with defaults, so the Picker and Startup Detection keep working:

```zig
updated_on: ?i64 = null,
approval_count: u32 = 0,
changes_requested_count: u32 = 0,
```

`src/bitbucket/client.zig` adds two methods.
Both follow `next` links until the last page.

- `Client.listRepositorySummaries(allocator)` sends `GET /repositories/{workspace}?pagelen=100&sort=-updated_on&fields=next,values.slug,values.name,values.updated_on`.
- `Client.listOpenPullRequestSummaries(allocator, repo_slug)` sends `GET /repositories/{workspace}/{repo}/pullrequests?pagelen=50&state=OPEN` with a `fields` filter.
  The filter names `next`, `id`, `title`, `state`, `draft`, `updated_on`, `author.display_name`, the source and destination Branch names, and `participants.approved` and `participants.state`.

The approval count is the number of participants with `approved = true`.
The changes-requested count is the number of participants with `state = "changes_requested"`.
The adapter parses `updated_on` from ISO 8601 into Unix seconds.
A missing or malformed time gives `null`, not an error.

A non-success response returns the classified `ApiError`.
A page failure fails the whole list, so a partial list never replaces a complete one.

`bbr check-browser [<repo-slug>]` is a new live, Credential-gated shape check.
It lists the Repository Summaries and the PullRequest Summaries of one Repository.
It prints the counts and the participant fields that it saw.
It exits non-zero when a required field is missing.

### Browser model

`src/tui/browser.zig` is new.
It imports neither vaxis nor `theme.zig`.
It owns the Browser data and the Browser Entry projection.

```zig
pub const Sort = enum { updated, name };

pub const PullRequestLoad = union(enum) {
    unknown,
    cached: []const PullRequestSummary,
    loading: struct { work_id: WorkId, previous: ?[]const PullRequestSummary },
    loaded: []const PullRequestSummary,
    failed: struct { reason: ApiError, previous: ?[]const PullRequestSummary },
};

pub const RepositoryNode = struct {
    summary: RepositorySummary,
    expanded: bool,
    pull_requests: PullRequestLoad,
};

pub const Selection = union(enum) {
    repository: []const u8, // slug
    pull_request: struct { repository: []const u8, id: u64 },
};

pub const Entry = union(enum) {
    repository: usize,
    pull_request: struct { repository: usize, index: usize },
    message: Message,
};
```

`Message` names the message entries: `loading_repositories`, `repositories_failed`, `no_repositories`, `loading_pull_requests`, `pull_requests_failed`, and `no_pull_requests`.
A message entry never takes the cursor.
Motions skip it.

`browser.entries(...)` builds the visible Browser Entries from the nodes, the expansion, and the Sort.
It is a pure function, like `file_tree.build`.

`Presentation.browser: ?*Browser` holds the Browser.
It lives outside `Published`.
A Session replacement, a failed replacement, and `close_browser` keep it unchanged.
`Presentation.surface` is `.review` or `.browser`.
It decides which surface the Projection shows.

### Browser Start and lifetime

The Browser starts once per process.
`start_browser`, a `.browse` outcome, and the first `open_browser` start it.
A start does three things:

1. It creates the Browser with the Browser Start.
2. It queues `load_summary_cache` when a Summary Cache path exists.
3. It queues `list_browser_repositories`.

The Browser Start Repository becomes expanded, and its PullRequest load starts at once.
The Browser Start PullRequest becomes a pending focus.
Before the Repository list arrives, the expanded Repository shows as a Repository entry with only its slug.

The pending focus moves the cursor when its row appears.
A cursor Motion by the reviewer clears the pending focus.
A pending focus for a missing PullRequest falls back to its Repository row.

The first `open_browser` uses the published Session's Repository and PullRequest as its Browser Start.
A later `open_browser` shows the existing Browser unchanged.
It starts no request.

### Repository list loading

`list_browser_repositories` carries a `WorkId`.
`Browser.repositories_work` stores the current one.

- With no rows yet, the Browser shows the `loading_repositories` message entry.
- A success replaces the Repository nodes.
  A cached Repository that the result does not contain goes away with its PullRequests.
  A node in the result keeps its expansion and its PullRequest load.
- A failure keeps the current rows.
  With no rows, the Browser shows `repositories_failed` with the `ApiError` text.
  With rows, the status shows `browser_repositories_failed`.
- An empty success shows `no_repositories`.

### PullRequest loading and the concurrency bound

Expanding a Repository with an `unknown` or `cached` PullRequest load queues its load.
Expanding a `loaded`, `loading`, or `failed` Repository starts no request.
`refresh` starts a new load for every expanded Repository.

Presentation holds a FIFO of Repositories that wait to load.
At most two `list_browser_pull_requests` commands are outstanding at one time.
A completion starts the next waiting Repository.
Collapsing a Repository removes it from the FIFO.
A load in flight still completes and stores its result.

Each command carries a `WorkId` and the Repository slug.
The completion `browser_pull_requests_loaded` is current only when its `WorkId` equals the `loading.work_id` of that Repository.
Presentation frees the payload of any other completion and changes nothing.

- A success sets `loaded` and replaces the previous list.
  A closed PullRequest therefore goes away.
- A failure sets `failed` and keeps no previous list for `forbidden` and `not_found`.
  For other reasons, it keeps the previous list visible.
- A `rate_limited` failure also empties the FIFO.
  Each waiting Repository returns to its earlier load state.
  The status shows `browser_rate_limited`.
- An expanded Repository with an empty list shows `no_pull_requests`.

A failure in one Repository never changes another Repository.

### Rows

A Repository entry shows, in this order:

1. A disclosure marker, `▸` when collapsed and `▾` when expanded.
2. The name, and the slug when it differs from the name.
3. The Repository update time as `YYYY-MM-DD` in UTC.
4. The open-PullRequest count, or `?` while the load is `unknown` or `loading` with no previous list.

A PullRequest entry shows, in this order:

1. `#<id>` and the title.
2. The PullRequest Author.
3. The update time as `YYYY-MM-DD` in UTC.
4. `<source> → <destination>`.
5. `✓<approval count>` and `✗<changes-requested count>`.

A row that does not fit drops its title or name text first, with `…`.
A count from a `cached` load paints in a dim style.
Presentation formats dates from Unix seconds, so it needs no clock.

### Sort

`cycle_browser_sort` switches between `.updated` and `.name`.

- `.updated` orders Repositories by Repository update time, newest first, then by slug.
  It orders PullRequests by update time, newest first, then by PullRequestId, highest first.
- `.name` orders Repositories by name without ASCII case, then by slug.
  It orders PullRequests by PullRequestId, highest first.

A `null` time sorts last.
The cursor follows its `Selection`, not its row index.
After a sort, the scroll moves only when the selected row leaves the viewport.

### Selection and scroll

The cursor is a `Selection`, so it survives a refresh, a sort, and a Session replacement.
When the selected PullRequest goes away, the cursor moves to its Repository row.
When the selected Repository goes away, the cursor moves to the row at the same index, clamped to the list.
The scroll keeps its top row until the cursor leaves the viewport.

### Actions and Interaction Contexts

`src/tui/action.zig` adds four Actions and four Interaction Contexts.

| Action | Default key | Contexts |
| --- | --- | --- |
| `open_browser` | `b` | `sidebar`, `sidebar_directory`, `sidebar_file`, `diff` and the DiffPane contexts that inherit from it |
| `close_browser` | `b`, Escape | `browser`, `browser_repository`, `browser_pull_request` |
| `open_browser_entry` | Enter | `browser_repository`, `browser_pull_request` |
| `cycle_browser_sort` | `s` | `browser`, `browser_repository`, `browser_pull_request` |

The Interaction Contexts are:

- `detecting`: the Detecting Frame. It supports only `quit`.
- `browser`: the Browser with no selectable row under the cursor. It supports `quit`, `help`, `refresh`, `close_browser`, and `cycle_browser_sort`.
- `browser_repository`: the cursor is on a Repository entry.
- `browser_pull_request`: the cursor is on a PullRequest entry.

`browser_repository` and `browser_pull_request` support everything that `browser` supports.
They also support `down`, `up`, `to_top`, `to_bottom`, `half_page_down`, `half_page_up`, `left`, `right`, and `open_browser_entry`.

- `right` expands a Repository.
- `left` collapses a Repository, or moves from a PullRequest entry to its Repository entry.
- `open_browser_entry` toggles a Repository, or opens the review Session of a PullRequest.
- `refresh` reloads the Repository list and the PullRequests of every expanded Repository.

A `[keymap]` override can rebind or unbind each new Action by its exact name.
The `p` Picker stays, with no change, until M25 replaces it.

ActionAvailability refuses `open_browser` in a LocalReview with `local_review_no_browser`.
It refuses `open_browser` in the demo with `action_refused`.
It refuses `close_browser` with no published Session with `no_review_open`.

The Command Palette lists `open_browser` with the title "Open Browser" and the description "Browse the Repositories and PullRequests of the Workspace".
The Command Palette does not open from the Browser in M24.

### Opening a PullRequest from the Browser

`open_browser_entry` on a PullRequest entry builds an `OwnedReviewIdentity` from the Workspace, the Repository, and the PullRequestId.
It dispatches the existing `choose_pull_request` path.
The Browser stays visible while the Candidate Session loads.
The status shows "Loading PR #`<id>`…".

When the replacement publishes, `Presentation.surface` becomes `.review`.
A failed replacement keeps the Browser visible and shows the existing replacement error.
A second choice during the load supersedes the first, as the existing intent rule does.

### Mouse parity

`frame.HitTarget` gains `browser_entry: usize`.
A click on a Repository entry or a PullRequest entry moves the cursor to it.
A click on the entry that already holds the cursor runs `open_browser_entry`.
A click on a message entry does nothing.
The wheel scrolls by `mouse_vertical_scroll_rows`, like the Panes.

### Layout and painting

`src/tui/layouts.zig` adds `layouts.browser` with one Slot, `.entries`.
It is one Pane with rounded corners and the Workspace slug as its Title.
Its scroll bar is always declared.
`view_paint.zig` paints its border, Title, and scroll bar.
`render.drawBrowser` paints only the Browser Entries into the content rect.

### Status messages

M24 adds `ActionError` values with their `actionErrorText` texts in `src/tui/app.zig`:

- `local_review_no_browser`: "Browser is unavailable for a local review".
- `no_review_open`: "No review is open".
- `browser_rate_limited`: "Bitbucket rate limit reached, press R to retry".
- `browser_repositories_failed`: "Repositories not refreshed".

The status paints them through the existing `Theme.statusStyle` parts.

## Summary Cache model

The Summary Cache is one file, `$XDG_STATE_HOME/bbr/browser-cache.json`.
`src/main.zig` builds the path from `bbr.xdg.stateHome` and passes it in `RunCtx.summary_cache_path`.
No other code reads an XDG variable.
A null path disables the Summary Cache.

The file is JSON with this shape:

```json
{
  "version": 1,
  "workspace": "check24",
  "repositories": [
    {
      "slug": "pr-webapp",
      "name": "PR Webapp",
      "updated_on": 1761730000,
      "pull_requests": [
        {
          "id": 1726,
          "title": "Fix the cart",
          "author": "Ada",
          "updated_on": 1761720000,
          "source": "feature/cart",
          "destination": "main",
          "approvals": 1,
          "changes_requested": 0
        }
      ]
    }
  ]
}
```

`pull_requests` is `null` when bbr never loaded that Repository.
The file holds no Credential, no PullRequest description, no Comment, and no URL.

`src/bitbucket/summary_cache.zig` is new and pure.
`encode` writes a `Snapshot`, and `decode` reads one.
`decode` returns `null` for every parse error, a wrong `version`, or a file larger than 16 MiB.
The record types have a `comptime` field allowlist.

The adapter reads and writes the file:

- `load_summary_cache` reads and decodes the file on a worker.
  A missing file, a parse error, or another Workspace gives an empty result.
  The Browser shows nothing from it, and the next save rebuilds the file.
- A `summary_cache_loaded` completion fills only nodes that the Repository list has not filled yet.
  After a Repository list success, Presentation ignores the Summary Cache completion.
  Cached PullRequest lists become `cached` loads.
- `save_summary_cache` writes the file after each Repository list success and each PullRequest list success.
  It writes a temporary file in the same directory with mode `0600` and renames it over the old file.
  At most one save runs at a time.
  A newer Snapshot replaces a waiting one.
  A failed save changes nothing visible, and the next save retries.

## State machine changes

Presentation gains these commands and completions under ADR-0012.
Each command gets an arm in `OwnedCommand.deinit` and `OwnedCommand.launchFailed`.

| `OwnedCommand` | Completion `OwnedInput` | Launch failure |
| --- | --- | --- |
| `detect_adjacent_pull_requests` | `adjacent_detected` | A failed detection, so the plain Browser |
| `list_browser_repositories` | `browser_repositories_loaded` | A failed load with its `WorkId` |
| `list_browser_pull_requests` | `browser_pull_requests_loaded` | A failed load with its `WorkId` |
| `load_summary_cache` | `summary_cache_loaded` | An empty Summary Cache |
| `save_summary_cache` | `summary_cache_saved` | A failed save |

New inputs from `app.run` are `detect_startup` and `start_browser`.
`app.zig` runs the new commands on workers in `drainPresentationCommands`.
`presentation_adapter.zig` holds the worker functions.

The surface states are:

```text
detecting ── one AdjacentPullRequest ──► loading review ──► review
    │                                                         ▲   │
    └── zero, several, or failed ──► browser ◄── open_browser ┘   │
                                       │                          │
                                       └── open_browser_entry ────┘
                                          (publish switches to review)
```

`close_browser` moves from `browser` to `review` when a Session is published.
`quit` works in every state.

## Affected modules

| Module | Change |
| --- | --- |
| `src/bitbucket/types.zig` | Add `RepositorySummary`. Add `updated_on`, `approval_count`, and `changes_requested_count` to `PullRequestSummary`. |
| `src/bitbucket/client.zig` | Add `listRepositorySummaries` and `listOpenPullRequestSummaries` with their wire types and time parsing. |
| `src/bitbucket/summary_cache.zig` (new) | `Snapshot`, `encode`, `decode`, and the `comptime` field allowlist. |
| `src/startup.zig` | Replace `resolve` and `Entry` with `inspect`, `detect`, `Inspection`, `Outcome`, `Start`, and `describe`. Compare the Remote Workspace. |
| `src/main.zig` | Call `startup.inspect` before the TUI. Pass `startup.Start` and the Summary Cache path to `app.run`. Rewrite `detectRun`. Add `check-browser`. Update `usage`. |
| `src/root.zig` | Export the new `bbr.bitbucket` names. |
| `src/tui/browser.zig` (new) | The Browser model, `Selection`, `Entry`, `Sort`, and `entries`. |
| `src/tui/action.zig` | Four Actions and four Interaction Contexts. |
| `src/tui/keymap.zig` | Default bindings and `supportsContext` arms. |
| `src/tui/list_overlay.zig` | The Command Palette entry for `open_browser`. |
| `src/tui/presentation.zig` | `Presentation.browser`, `Presentation.surface`, the new inputs, commands, `ActionError` values, and `Projection.browser` and `Projection.detecting`. |
| `src/tui/presentation_adapter.zig` | The worker functions for detection, Browser lists, and Summary Cache I/O. |
| `src/tui/app.zig` | `RunCtx.start` and `RunCtx.summary_cache_path`, command launch, surface painting, and the status texts. |
| `src/tui/layouts.zig` | `layouts.browser`. |
| `src/tui/frame.zig` | `HitTarget.browser_entry` and Browser hit testing. |
| `src/tui/render.zig` | `drawBrowser` and `drawDetecting`. |
| `src/completion.zig` | Add `check-browser`. |
| `tests/detect_cli_test.py` (new) | Hermetic `bbr detect` outside Git. |
| `build.zig` | The `test-browser` target with the filter `M24`, and the new CLI script. |
| Glossaries, `GLOSSARY-MAP.md`, `docs/code-navigation.md`, `src/tui/IMPLEMENTATION.md`, `README.md`, `AGENTS.md`, `TODO.md` | Documentation changes in ticket 06. |

## AGENTS.md rules

M24 touches these existing rules:

- "Only `src/xdg.zig` reads `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME`."
  `src/main.zig` builds the Summary Cache path with `xdg.stateHome`.
  `tools/check_xdg_reads.py` proves it.
- "A terminal surface is a View tree in `src/tui/layouts.zig`."
  The Browser is `layouts.browser`, and `drawBrowser` paints only content.
  `tools/check_box_glyphs.py` proves that `render.zig` adds no border glyph.
- "A Pane has rounded corners and its Title in the top border."
  The Browser Pane follows it.
  The test "M24 browser the Browser Pane has rounded corners and the Workspace Title" in `src/tui/render.zig` proves it.
- "Every Title has one blank cell on each side."
  The Browser Title goes through `view_paint.titleText`.
- "A layout tree always declares its scroll bars."
  `layouts.browser` declares its scroll bar on every solve.
- "A layout tree places each of its Slots exactly once."
  The test "every layout places each of its Slots" covers `layouts.browser`.
- "`presentation.zig` does not import vaxis or `theme.zig`."
  `browser.zig` follows the same rule.
  The dim cached count is a flag in the Projection.
- "An `OwnedCommand` converts to its launch-failure `OwnedInput` only in `OwnedCommand.launchFailed`."
  The five new commands get arms there.
  The test "every OwnedCommand launch failure keeps its correlation and frees the command" covers them.
- "The status paints each part through `Theme.statusStyle`."
  The new texts use the existing status parts.
- The Command Palette `comptime` block in `src/tui/list_overlay.zig` must accept `open_browser`.
  `open_browser` is not a Motion, and Pane contexts support it.
- "The File Finder and the Command Palette close before Session replacement."
  A replacement that starts from the Browser follows the same rule.

M24 adds these rules to the table in ticket 06:

| Rule | Enforcement |
| --- | --- |
| The Browser lives in `Presentation.browser`, outside `Published`. Session replacement, a failed replacement, and `close_browser` keep its expansion, Selection, scroll, Sort, and summaries. | The test "M24 browser Session replacement and return keep the Browser state" in `src/tui/presentation.zig`. |
| Every Browser command carries a `WorkId`. Presentation admits a completion only when its `WorkId` is current, and frees every other payload without a change. | The test "M24 browser a stale completion changes nothing and frees its payload" in `src/tui/presentation.zig`. |
| Presentation keeps at most two `list_browser_pull_requests` commands outstanding. Other loads wait in a FIFO. | The test "M24 browser keeps at most two PullRequest list requests outstanding" in `src/tui/presentation.zig`. |
| The Summary Cache holds only Repository Summary and PullRequest Summary fields. It holds no Credential and no description. | The `comptime` field allowlist in `src/bitbucket/summary_cache.zig` (compile error). The test "M24 cache a saved Summary Cache holds no Credential or description". |
| A new Browser Entry kind is one arm of `browser.Entry` in `src/tui/browser.zig`. | The exhaustive switches in `render.drawBrowser`, `frame.hitTest`, and the Browser context function (compile error). |
| Startup Detection has one implementation in `src/startup.zig`. Plain `bbr`, `bbr <repo-slug>`, and `bbr detect` call `startup.inspect` and `startup.detect`. | The tests "M24 startup every Inspection and Outcome" in `src/startup.zig` and `tests/detect_cli_test.py`. |

## Testing Decisions

A good test asserts behavior that the reviewer or a script can observe.
Tests assert outcomes, requests sent, published Browser Entries, the cursor, status texts, painted cells, and file contents.
Tests do not assert private helper calls, arena layout, or FIFO internals.

Every new Zig test name starts with `M24`, so `zig build test-browser` runs them.

### Seams

- `FakeGitClient` and `FakeHttpClient` drive `startup.inspect` and `startup.detect`.
- `FakeHttpClient` with canned pages drives the two new Client methods.
- The Presentation transition is the integration seam, as in ADR-0012.
  Tests dispatch inputs, take commands, and return completions in any order.
- `summary_cache.encode` and `summary_cache.decode` are pure.
  Adapter tests use a temporary directory for the file I/O.
- Headless rendering proves cells, and `frame.hitTest` proves mouse targets.
- `tests/detect_cli_test.py` runs `bbr detect` outside Git with an environment Credential.
  It needs no network, because inspection returns a plain Browser.

### Prior art

- The startup tests in `src/startup.zig`, such as "several adjacent PRs raise a pre-filtered picker".
- The paging tests in `src/bitbucket/client.zig` that use `pagedCount` and `sort=-updated_on`.
- The Picker load and tick tests in `src/tui/presentation.zig`, which use `list_pull_requests`.
- The File Tree render and hit-test tests in `src/tui/render.zig` and `src/tui/frame.zig`.
- The layout tests in `src/tui/layouts.zig`.
- `tests/auth_cli_test.py` for the CLI harness.

### Test plan

Startup:

- Each row of the `Inspection` table gives its result, and inspection sends no request.
- A Remote in another Workspace gives a plain Browser.
- A Remote Workspace that differs only in ASCII case counts as the configured Workspace.
- Each row of the `Outcome` table gives its result.
- Two AdjacentPullRequests focus the highest PullRequestId.
- `startup.describe` prints each line of the `bbr detect` table.
- `bbr detect` outside Git prints `resolved: browser` and exits `0`.

Acquisition:

- `listRepositorySummaries` follows `next` over three pages and keeps the order.
- The first URL holds `pagelen=100`, `sort=-updated_on`, and the `fields` filter.
- `listOpenPullRequestSummaries` counts approvals and changes-requested states over mixed participants.
- A missing or malformed `updated_on` gives `null`.
- A failure on page two returns the `ApiError` and no partial list.
- `401`, `403`, `404`, and `429` map to their `ApiError` values.

Presentation:

- `detect_startup` shows the Detecting Frame with the branch, and `q` requests shutdown.
- An `.open` outcome loads the Session, and a `.browse` outcome shows the Browser with its Browser Start.
- A plain Browser Start expands nothing.
- A Browser Start with a focused PullRequest moves the cursor when the row appears.
- A cursor Motion before the row appears clears the pending focus.
- The Repository list loading, empty, and failure states show their message entries.
- A Repository list failure with rows keeps the rows and shows the status text.
- Expanding a Repository queues one load, and expanding it again starts no request.
- Three expansions issue two commands, and the third starts after a completion.
- Collapsing a waiting Repository removes it from the FIFO.
- A stale Repository list completion and a stale PullRequest completion change nothing.
- A `refresh` supersedes the loads in flight.
- One failed Repository keeps the PullRequests of the others.
- A `forbidden` failure drops the previous list, and a `server` failure keeps it.
- A `rate_limited` failure empties the FIFO and shows its status text.
- A refreshed list removes a closed PullRequest, and a refreshed Repository list removes a lost Repository.
- The selected PullRequest that goes away moves the cursor to its Repository row.
- Each Sort orders Repositories and PullRequests as specified, and keeps the Selection.
- Enter on a PullRequest entry starts the Candidate Session, and publication switches to the review surface.
- A failed replacement keeps the Browser visible.
- `b` from the Session shows the Browser with the same expansion, Selection, scroll, and summaries.
- The first `b` from a Session expands its Repository and focuses its PullRequest.
- `b` in a LocalReview and in the demo is refused with its message.
- Escape with no published Session is refused with `no_review_open`.
- A click selects an entry, and a second click opens it.

Summary Cache:

- `encode` then `decode` returns an equal Snapshot.
- `decode` returns `null` for truncated JSON, a wrong `version`, and an oversized file.
- A Summary Cache for another Workspace gives an empty result.
- The Browser shows cached rows before the network completes.
- A Repository list success after the cache replaces the cached rows.
- A Summary Cache completion after a Repository list success changes nothing.
- A saved file has mode `0600` and holds no Credential or description.
- A failed save leaves the Browser unchanged.

Rendering and layout:

- A Repository entry shows its name, slug, date, and count, or `?` before a load.
- A PullRequest entry shows all its facts and truncates its title first.
- A cached count paints dim.
- The Browser Pane has rounded corners and the Workspace Title.
- The Detecting Frame names the branch.

Keymap and Command Palette:

- Each new Action resolves in its contexts and nowhere else.
- No new binding conflicts with another Action in a shared context.
- A `[keymap]` override can rebind and unbind each new Action.
- The Command Palette lists "Open Browser" from the Panes.

### Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test-cli`
- `zig build test --summary all`, and the reported test count increases.
- `python3 tools/check_agent_docs.py`

The live outside check in ticket 07 is a manual acceptance step.
It does not gate the hermetic suite.

## Implementation tickets

1. [Acquire Repository and PullRequest Summaries](issues/01-acquire-repository-and-pullrequest-summaries.md)
2. [Open the Browser from a review Session](issues/02-open-the-browser-from-a-review-session.md)
3. [Sort the Browser without moving the Selection](issues/03-sort-the-browser-without-moving-the-selection.md)
4. [Show the Summary Cache at Browser start](issues/04-show-the-summary-cache-at-browser-start.md)
5. [Detect the startup target inside the TUI](issues/05-detect-the-startup-target-inside-the-tui.md)
6. [Document M24 and verify the integrated suite](issues/06-document-m24-and-verify-the-integrated-suite.md)
7. [Run the live M24 outside check](issues/07-run-the-live-m24-outside-check.md)

## Out of Scope

- A filter that hides Repositories without open PullRequests. M25 owns finding.
- Search, recents, and settings in the Browser. M25 owns them.
- Removal of the `p` Picker. M25 replaces it.
- The Command Palette inside the Browser.
- An expand-all Action.
- A Browser for a Workspace other than the Credential Workspace.
- Persistence of the expansion or the Selection across a restart.
- A Draft PullRequest marker in a PullRequest entry.
- Changes to `bbr local` and LocalReview.
- The LocalReview ADR that the M24 TODO section mentions. It waits for real Browser usage.

## Further Notes

- Decision 7 of the brief keeps `bbr detect`. Ticket 06 checks the matching TODO line.
- The brief does not say how the Detecting Frame knows the branch at its first paint.
  This spec splits Startup Detection into a local `inspect` before the TUI and a remote `detect` after it.
  The local step reads Git only, so the TUI still starts without a network wait.
- The brief does not define "newest".
  This spec uses the highest PullRequestId, because Bitbucket assigns ids in creation order.
- The brief does not say what a failed list does with a `<repo-slug>` argument.
  This spec keeps that Repository expanded, because the reviewer named it.
- The brief does not say how to leave the Browser without a choice.
  This spec adds `close_browser` on Escape and `b`.
- The brief names one cache file.
  This spec stores one Workspace in it, so a change of Workspace rebuilds it.
- The participant fields in the PullRequest list response are not proven yet.
  [The Bitbucket implementation notes](../../src/bitbucket/IMPLEMENTATION.md) record that `fields` cannot add `inline.outdated` to the Comment list.
  Ticket 07 runs `bbr check-browser` to prove the participant fields.
  If they are absent, the human records the gap, and a follow-up ticket decides the fix.
- ADR-0012 holds: every Browser request is a typed command with a typed completion.
- ADR-0013 holds: the Browser is one View tree, and only `view_paint.zig` paints its decoration.
- ADR-0003 holds: every Bitbucket call goes through the `HttpClient` seam.
