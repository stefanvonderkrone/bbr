# 01: Acquire Repository and PullRequest Summaries

Status: resolved
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

- [x] `listRepositorySummaries` follows `next` over three pages and keeps the order.
- [x] The first Repository URL holds `pagelen=100`, `sort=-updated_on`, and the `fields` filter.
- [x] The first PullRequest URL holds `pagelen=50`, `state=OPEN`, and a `fields` filter that names `next` and the participant fields.
- [x] Mixed participants give the correct approval and changes-requested counts.
- [x] A missing or malformed `updated_on` gives `null`.
- [x] A failure on page two returns the classified `ApiError` and no partial list.
- [x] `401`, `403`, `404`, and `429` map to `unauthorized`, `forbidden`, `not_found`, and `rate_limited`.
- [x] The existing Picker and startup tests pass without change.
- [x] `bbr check-browser` exits non-zero when a required field is missing in a canned response.

## Tests that prove it

- New `M24 acquisition` tests in `src/bitbucket/client.zig` with `FakeHttpClient` canned pages.
- The existing tests in `src/startup.zig` and the Picker tests in `src/tui/presentation.zig`.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-browser`
- `zig build test --summary all`

## Completion

This commit implements the ticket.

### Change summary

- `src/bitbucket/types.zig` adds `RepositorySummary`.
  `PullRequestSummary` gains `updated_on`, `approval_count`, and `changes_requested_count` with defaults.
- `src/bitbucket/client.zig` adds `Client.listRepositorySummaries` and `Client.listOpenPullRequestSummaries`.
  Both follow `next` through the existing `listPages` loop, so a failed page fails the whole list.
  One field table builds each `fields` filter, and the shape check reads the same table.
- The adapter parses `updated_on` as `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`.
  A missing time, a null time, a time without a zone, or an invalid date gives `null`.
- `Client.checkBrowserShape` walks the raw pages of both lists and names the first missing required field.
  Then it decodes both lists and counts the approvals and changes-requested states.
- `bbr check-browser [<repo-slug>]` prints the report and exits `1` when a required field is missing.
  `printBrowserShape` in `src/main.zig` makes this decision, and a test proves it.
- `src/root.zig` exports `RepositorySummary`, `BrowserShape`, and `deinitRepositorySummaries`.
- `src/completion.zig` and the usage text name `check-browser`.
- `build.zig` adds `test-browser`. It runs the `M24` filter in the `bbr` module and in the executable module.

### Defaults chosen

- The required fields are the fields that the `fields` filters name.
  A JSON null counts as present, so a participant with `"state": null` passes.
  A null `author` fails the check as a missing `author.display_name`.
- When no participant is in the checked Repository, `bbr check-browser` exits `0`.
  It prints a note that the participant fields are unproven.
- When the Workspace has no Repository and no argument names one, `bbr check-browser` fails with `NoRepositories`.
- `bbr check-browser` needs no opt-in variable, because it only reads.
- The decoders require `slug` and `name` for a Repository Summary, as the existing decoders require `title`.

### Checks

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-browser`: pass, 14 tests in two test binaries.
- `zig build test --summary all`: "24/24 steps succeeded; 1387/1387 tests passed". The baseline was 1378.
- `zig build test-cli`: pass.
- `python3 tools/check_agent_docs.py`: pass.
- The existing Picker tests in `src/tui/presentation.zig` and the startup tests in `src/startup.zig` pass without change.

### Review

- The self-review read the full diff.
- Each new test asserts an exact URL, the decoded values, or the `ApiError` that callers branch on.
- The allocation-failure test proves that every page releases its memory on failure.
- No finding remains open.
