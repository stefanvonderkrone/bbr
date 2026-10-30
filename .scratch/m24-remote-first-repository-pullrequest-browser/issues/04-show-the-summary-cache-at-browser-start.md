# 04: Show the Summary Cache at Browser start

Status: ready-for-agent
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

- [ ] `encode` then `decode` returns an equal Snapshot.
- [ ] `decode` returns `null` for truncated JSON, a wrong `version`, and a file larger than 16 MiB.
- [ ] A Summary Cache for another Workspace gives an empty result.
- [ ] The Browser shows cached rows before any network completion.
- [ ] A Repository list success after the Summary Cache replaces the cached rows and removes lost Repositories.
- [ ] A Summary Cache completion after a Repository list success changes nothing.
- [ ] A cached PullRequest list shows as a `cached` load, and its first expansion queues a refresh.
- [ ] A cached count paints dim, and a loaded count paints normal.
- [ ] A saved file has mode `0600` and holds no Credential, no description, and no URL.
- [ ] A newer Snapshot replaces a waiting save, and only one save runs at a time.
- [ ] A failed save leaves the Browser unchanged.
- [ ] A null Summary Cache path issues no Summary Cache command.
- [ ] `tools/check_xdg_reads.py` passes.

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
