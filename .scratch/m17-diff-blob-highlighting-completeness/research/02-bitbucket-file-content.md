# Bitbucket File content research

## Sources

- [Bitbucket Cloud Source API](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-source/#api-repositories-workspace-repo-slug-src-commit-path-get)
- [`src/bitbucket/client.zig`](../../../src/bitbucket/client.zig)
- [`src/tui/file_enrichment.zig`](../../../src/tui/file_enrichment.zig)
- [`src/tui/buffer.zig`](../../../src/tui/buffer.zig)
- [ADR-0001](../../../docs/adr/0001-bitbucket-diff-is-authoritative-line-model.md)
- [ADR-0010](../../../docs/adr/0010-file-enrichment-transfers-per-side-ownership.md)

## Findings

Bitbucket uses one Source endpoint for either side:

`GET /repositories/{workspace}/{repository}/src/{commit}/{path}`

The old side uses the destination commit and old path. The new side uses the source commit and new path. This also covers renames. Added Files have no old side. Removed Files have no new side.

For a File path, the endpoint returns raw, unmodified bytes. It does not declare a character encoding. It derives `Content-Type` from the filename extension, not the content. Empty Files are valid zero-byte success responses. A missing path returns `404`. LFS content returns a `301` redirect to Atlassian media storage. The current read-only HTTP path follows at most three redirects.

For a directory path, the same endpoint returns paginated JSON. Production cannot detect this shape from the body or `Content-Type`: a valid JSON File can have the same values. It must prevent this case with a canonical File path from RawDiff and correct path encoding. The opt-in live check can request `?format=meta` and assert `type = commit_file`, exact path, selected commit, byte size, and attributes before it compares the raw response length.

The metadata response can report `binary`, but M17's settled binary contract makes the RawDiff binary stub authoritative. Production does not need a metadata round trip for each side. It validates raw bytes as UTF-8 after fetch and makes only the invalid side unavailable.

The current implementation already selects destination commit plus old path and source commit plus new path. It also transfers old/new ownership independently. It has four gaps:

- `getFileBlob` inserts the path into the URL without percent-encoding path bytes.
- the Diff parser does not decode Git-quoted paths, so spaces and escaped bytes can select the wrong path before HTTP starts.
- `wholeFileBlob` rejects empty content and all removed Files.
- `spliceNewSide` only projects new-side line numbers.

## Required contract

- Normalize a RawDiff path to repository-relative bytes. Decode Git quoting before File Enrichment. Reject malformed quoting as a typed path-shape failure.
- Percent-encode each path segment for the Source URL while preserving `/` separators. Encode reserved bytes such as space, `%`, `?`, and `#`; do not double-encode decoded `%` bytes.
- Keep one source-neutral File Enrichment request. Fetch old with destination commit and old path, and new with source commit and new path. Do not request the absent side.
- Treat every final `2xx` body as opaque owned bytes. Zero bytes are `.text` with size zero, not missing content. Follow the existing bounded redirect policy for LFS.
- Validate UTF-8 after acquisition and before Highlighting or ownership transfer. Invalid UTF-8 is a per-side `unavailable` result with known byte size. It does not discard the other side.
- Preserve classified API and transport failures as per-side unavailable reasons. `404` on an expected side is `not_found`, not `absent`. Malformed RawDiff path syntax is `invalid_path`. Redirect exhaustion or a non-`2xx` final response remains a fetch failure. `OutOfMemory` remains fatal and transfers neither side.
- Select the WholeFile splice side from File status. Removed Files splice old content with old line numbers. All other Files splice new content with new line numbers. Both splices preserve Hunk Lines byte-for-byte and mark inserted context Lines `in_hunk = false`.
- Empty text content produces a complete WholeFile projection with no content Lines. It must not fall back to Changes.

## Hermetic and live checks

Hermetic fixtures are the required test tier. Cover modified, added, removed, renamed, empty, binary stub, invalid UTF-8, `404`, redirect exhaustion, malformed quoted path, and paths with spaces, `%`, `?`, `#`, quotes, tabs, and non-ASCII UTF-8. Assert exact commit/path selection, encoded URL, independent side results, old/new splice numbering, and Anchor refusal on inserted Lines.

The opt-in live check is diagnostic. Given a Repository, PullRequest, and fixture paths supplied by environment or arguments, it obtains the RawDiff and both commits, requests metadata and raw content for each present side, and compares type, path, commit, size, binary attribute, and raw byte length. It skips unavailable fixture classes explicitly and reports each case. It never replaces fixtures and never runs in the default test command.
