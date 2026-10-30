# 04: Show the Summary Cache at Browser start

Status: resolved
Blocked by: 02
Spec: [M24 spec](../SPEC.md)

## What to build

The Browser shows the Repositories and PullRequests of the last run at once.
A background refresh then replaces them.
The Summary Cache lives in `$XDG_STATE_HOME/bbr/browser-cache.json`.
A broken or foreign file never shows, and the next save rebuilds it.

## Scope

- Add `src/bitbucket/summary_cache.zig` with `Snapshot`, `encode`, `decode`, and the `comptime` field allowlist.
- Build the path in `src/main.zig` from `bbr.xdg.stateHome`, and pass it in `RunCtx.summary_cache_path`.
- Add the commands `load_summary_cache` and `save_summary_cache` with their completions, `deinit` arms, and `launchFailed` arms.
- Add the file I/O workers to `src/tui/presentation_adapter.zig`, with an atomic write and mode `0600`.
- Fill `cached` loads from the Summary Cache, as the "Summary Cache model" section of the spec describes.
- Save after each Repository list success and each PullRequest list success, with one save in flight.
- Paint a cached count in a dim style.

## Acceptance criteria

- [x] `encode` then `decode` returns an equal Snapshot.
- [x] `decode` returns `null` for truncated JSON, a wrong `version`, and a file larger than 16 MiB.
- [x] A Summary Cache for another Workspace gives an empty result.
- [x] The Browser shows cached rows before any network completion.
- [x] A Repository list success after the Summary Cache replaces the cached rows and removes lost Repositories.
- [x] A Summary Cache completion after a Repository list success changes nothing.
- [x] A cached PullRequest list shows as a `cached` load, and its first expansion queues a refresh.
- [x] A cached count paints dim, and a loaded count paints normal.
- [x] A saved file has mode `0600` and holds no Credential, no description, and no URL.
- [x] A newer Snapshot replaces a waiting save, and only one save runs at a time.
- [x] A failed save leaves the Browser unchanged.
- [x] A null Summary Cache path issues no Summary Cache command.
- [x] `tools/check_xdg_reads.py` passes.

## Tests that prove it

- `M24 cache` tests in `src/bitbucket/summary_cache.zig`, including "M24 cache a saved Summary Cache holds no Credential or description".
- `M24 cache` adapter tests in `src/tui/presentation_adapter.zig` with a temporary directory.
- `M24 cache` Presentation tests in `src/tui/presentation.zig`.
- The extended launch-failure test in `src/tui/presentation.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test --summary all`

## Completion

This commit implements the ticket.

### Change summary

- `src/bitbucket/summary_cache.zig` is new and pure. It holds `Snapshot`, `Repository`, `encode`, `decode`, `version`, and `max_bytes`.
  Three record types match the JSON shape of the spec, and a `comptime` allowlist names every key that they can hold.
  `decode` returns `null` for a parse error, an unknown key, a wrong `version`, and input larger than 16 MiB.
- `src/root.zig` exports it as `bbr.bitbucket.summary_cache`.
- `src/main.zig` builds `<state home>/bbr/browser-cache.json` with `bbr.xdg.stateHome` in `summaryCachePath`.
  The remote run passes it in `RunCtx.summary_cache_path`. The local review and the demo pass no path.
- `Dependencies.summary_cache` tells Presentation that a path exists. The adapter alone holds the path.
- The commands `load_summary_cache` and `save_summary_cache` and the completions `summary_cache_loaded` and `summary_cache_saved` are new.
  Each command has arms in `OwnedCommand.deinit`, `launchFailed`, `setCommandId`, `takeCommand`, and `LaunchFailureFixture`.
- `Presentation.startBrowser` queues `load_summary_cache` before `list_browser_repositories` when a path exists.
- `Browser.fillFromCache` adds or updates the Repository nodes and fills the `cached` load of each node with no settled list.
  The Browser keeps the cache in `Browser.cached` until the first Repository list success replaces the node summaries.
- After a Repository list success, Presentation frees a Summary Cache completion and changes nothing.
- `Presentation.saveSummaryCache` encodes `Browser.snapshot` after each Repository list success and each PullRequest list success.
  A queued save takes the newer Snapshot. While a save runs, a new save waits, and its completion queues the latest Snapshot.
- `presentation_adapter.loadSummaryCache` and `presentation_adapter.saveSummaryCache` do the file I/O on workers that `drainPresentationCommands` launches.
  The save creates the directory, writes an atomic file with mode `0600`, renames it over the old file, and sets mode `0600` again.
- `render.drawBrowser` already paints a `cached` count dim. A new test proves it.

### Defaults chosen

- Presentation saves only after the first Repository list success.
  A PullRequest list success before it queues no save, because that save would drop the Repositories that the Summary Cache still holds.
  The Repository list success that follows saves that PullRequest list too.
- A save holds `settled.list()` of each node. That is a `loaded` list, a `cached` list, or the previous list of a failed load.
- `decode` rejects an unknown key, so a foreign file never shows.
- A decoded PullRequest Summary gets `state = "OPEN"` and `draft = false`, because the file holds neither field and the Browser lists only open PullRequests.
- Shutdown drops a queued save and starts no new save, like the Browser loads. A running save completes.
- The Summary Cache directory gets the default mode, like `pending.db`. Only the file gets `0600`.

### Checks

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-browser`: "9/9 steps succeeded; 64/64 tests passed". The baseline was 49.
- `zig build test --summary all`: "24/24 steps succeeded; 1437/1437 tests passed". The baseline was 1422.
  `tools/check_xdg_reads.py` runs inside it and passes.
- `python3 tools/check_agent_docs.py`: pass.
- A `description` field added to `PullRequestRecord` fails `zig build` with "bitbucket.summary_cache.PullRequestRecord.description is not in the Summary Cache allowlist".

### Tests

- `src/bitbucket/summary_cache.zig`: "M24 cache encode then decode returns an equal Snapshot", "M24 cache decode returns null for truncated JSON, a wrong version, and an oversized file", and "M24 cache a saved Summary Cache holds no Credential or description".
- `src/tui/presentation_adapter.zig`: "M24 cache the save worker creates the directory and writes mode 0600, and the load worker reads it back", "M24 cache a missing, broken, or foreign Summary Cache gives an empty result", and "M24 cache a failed save reports the failure and consumes the command".
- `src/tui/presentation.zig`: six "M24 cache" tests for cached rows, a late cache completion, a cached expansion, the save queue, a failed save, and a null path.
  The test "every OwnedCommand launch failure keeps its correlation and frees the command" covers both new commands.
- `src/tui/browser.zig`: "M24 cache the Summary Cache fills only nodes with no settled list and copies its PullRequests".
- `src/tui/render.zig`: "M24 cache a cached count paints dim and a loaded count paints normal".
- `src/main.zig`: "M24 cache the Summary Cache path lives under the XDG state home".

### Review

- I read the full diff.
- I found no leak in the test allocator runs, no double free, and no AGENTS.md rule violation.
- Ticket 06 adds the Summary Cache row to the AGENTS.md rule table. The `comptime` allowlist and the test that the row names exist now.
