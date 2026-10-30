# 02: Keep binary Files honest with blob ids

Status: ready-for-agent
Blocked by: 01
Spec: [M22 spec](../SPEC.md)

## What to build

A reviewer can mark a binary File read when its diff header names the old and new blob ids.
The binary File becomes bold again when either blob id changes.
A binary File without an `index` header stays bold.
`m` on that File shows "File cannot be verified, so it stays unread" and changes nothing.
A LocalReview gives the same blob ids on every load, whatever the `core.abbrev` setting is.

## Scope

- Add `BlobIds` and `File.blob_ids: ?BlobIds` to `src/diff/model.zig`.
- Read the `index <old>..<new>` preamble line in `bbr.diff.parser.parse` for every File.
  Ignore an optional mode after the ids.
- Add the blob id part to the fingerprint encoding for a File with a binary side.
  A binary side without `File.blob_ids` keeps the fingerprint null.
- Add `--full-index` to `ShellGitClient.diff` in `src/git/client.zig`.
- Text Files keep their fingerprint from ticket 01.
  The blob ids do not participate for them.

## Acceptance criteria

- [ ] The parser reads short and full `index` ids, with and without a trailing mode.
- [ ] A File without an `index` line has `blob_ids = null`.
- [ ] A binary File with ids has a fingerprint, and a changed old or new id changes it.
- [ ] A binary File without ids has no fingerprint.
- [ ] A text File fingerprint does not change when only its `index` ids change.
- [ ] A refined `File.content` byte size does not change any fingerprint.
- [ ] `ShellGitClient.diff` gives full 40-character ids for a binary File in a real repository.
- [ ] `m` on a binary File with ids marks it read, and a later blob change makes it unread after a refresh.
- [ ] `m` on a binary File without ids reports `file_read_unverifiable` and writes nothing.

## Tests that prove it

- Parser tests in `src/diff/parser.zig`.
- Fingerprint fixtures in `src/review/file_read.zig`.
- An extension of the shell Git client test in `src/git/client.zig` with a binary File.
- Presentation tests in `src/tui/presentation.zig` for the binary mark, the blob change, and the refusal.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-file-read`
- `zig build test --summary all`
