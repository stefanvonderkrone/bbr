# Define removed-File enrichment and blob validation

Type: research
Status: resolved
Blocked by: 01

## Question

What does Bitbucket Cloud's old- and new-side blob endpoint behavior establish for removed, added, renamed, empty, binary, and path-special Files, and what explicit shape validation and typed failure results must bbr use to fetch the old-side blob and build a true WholeFile deletion view while keeping hermetic fixtures authoritative for tests?

## Answer

- Bitbucket serves both sides through `GET /repositories/{workspace}/{repository}/src/{commit}/{path}`. Old uses destination commit plus old path. New uses source commit plus new path. Renames use distinct paths. Added old and removed new are absent and are not requested.
- A successful File response is opaque bytes. `Content-Type` is extension-derived and has no encoding contract. Zero bytes are valid text content. LFS follows the existing bounded redirect policy. Production does not add a metadata request to every enrichment.
- RawDiff paths must be Git-unquoted, checked as repository-relative File paths, then percent-encoded by segment while preserving `/`. Malformed path syntax is `invalid_path`. An expected side returning `404` is `not_found`, not `absent`.
- UTF-8 validation occurs after fetch and before Highlighting or ownership transfer. Invalid UTF-8 makes that side unavailable with its byte size. Classified API, transport, and redirect failures stay per-side unavailable reasons. `OutOfMemory` remains fatal and transfers neither side.
- WholeFile selects old content for removed Files and new content otherwise. The old splice mirrors the current new splice with old line numbers, preserves Hunk Lines, and marks inserted context Lines non-anchorable. Empty text produces a complete zero-Line WholeFile projection instead of Changes fallback.
- Hermetic fixtures are authoritative. They cover status/path/commit selection, special paths, empty content, binary stubs, invalid UTF-8, failures, splice numbering, and Anchor safety. The opt-in live checker uses `?format=meta` plus raw reads to compare `commit_file` type, exact path and commit, size, attributes, and raw length. It reports skipped fixture classes and never runs in the default test command.
- Research and source links: [Bitbucket File content research](../research/02-bitbucket-file-content.md).
