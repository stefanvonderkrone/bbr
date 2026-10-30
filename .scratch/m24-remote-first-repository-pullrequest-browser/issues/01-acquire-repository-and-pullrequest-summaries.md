# 01: Acquire Repository and PullRequest Summaries

Status: ready-for-agent
Blocked by: none
Spec: [M24 spec](../SPEC.md)

## What to build

The Bitbucket adapter lists every Repository Summary of the configured Workspace.
It also lists the open PullRequest Summaries of one Repository, with approval and changes-requested counts.
Both lists follow every page.
A maintainer can run `bbr check-browser` to prove the live response shape.

This slice has no TUI change.
The Picker and Startup Detection keep their behavior.

## Scope

- Add `RepositorySummary` to `src/bitbucket/types.zig`.
- Add `updated_on`, `approval_count`, and `changes_requested_count` with defaults to `PullRequestSummary`.
- Add `Client.listRepositorySummaries` and `Client.listOpenPullRequestSummaries` to `src/bitbucket/client.zig`, as the "Summary acquisition" section of the spec describes.
- Parse `updated_on` from ISO 8601 into Unix seconds. A missing or malformed time gives `null`.
- Export the new names from `src/root.zig`.
- Add `bbr check-browser [<repo-slug>]` to `src/main.zig` and `src/completion.zig`.
  Without an argument, it uses the first Repository of the list.
- Add the `test-browser` build target with the filter `M24`.

## Acceptance criteria

- [ ] `listRepositorySummaries` follows `next` over three pages and keeps the order.
- [ ] The first Repository URL holds `pagelen=100`, `sort=-updated_on`, and the `fields` filter.
- [ ] The first PullRequest URL holds `pagelen=50`, `state=OPEN`, and a `fields` filter that names `next` and the participant fields.
- [ ] Mixed participants give the correct approval and changes-requested counts.
- [ ] A missing or malformed `updated_on` gives `null`.
- [ ] A failure on page two returns the classified `ApiError` and no partial list.
- [ ] `401`, `403`, `404`, and `429` map to `unauthorized`, `forbidden`, `not_found`, and `rate_limited`.
- [ ] The existing Picker and startup tests pass without change.
- [ ] `bbr check-browser` exits non-zero when a required field is missing in a canned response.

## Tests that prove it

- New `M24 acquisition` tests in `src/bitbucket/client.zig` with `FakeHttpClient` canned pages.
- The existing tests in `src/startup.zig` and the Picker tests in `src/tui/presentation.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test --summary all`
