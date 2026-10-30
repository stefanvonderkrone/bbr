# 02: Keep binary Files honest with blob ids

Status: resolved
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

- [x] The parser reads short and full `index` ids, with and without a trailing mode.
- [x] A File without an `index` line has `blob_ids = null`.
- [x] A binary File with ids has a fingerprint, and a changed old or new id changes it.
- [x] A binary File without ids has no fingerprint.
- [x] A text File fingerprint does not change when only its `index` ids change.
- [x] A refined `File.content` byte size does not change any fingerprint.
- [x] `ShellGitClient.diff` gives full 40-character ids for a binary File in a real repository.
- [x] `m` on a binary File with ids marks it read, and a later blob change makes it unread after a refresh.
- [x] `m` on a binary File without ids reports `file_read_unverifiable` and writes nothing.

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

## Completion

The parser stores borrowed old and new blob ids in `File.blob_ids`.
It ignores the optional mode and resets the ids at each File boundary.
The fingerprint hashes both length-prefixed ids after the side tags for a File with a binary side.
A binary File without ids remains unverifiable.
Text fingerprints still ignore blob ids.
`ShellGitClient.diff` uses `--full-index`.

The changes are uncommitted in the `m22-durable-file-read-state` Worktree.
The runner reviews and commits these paths.

- `src/diff/model.zig`
- `src/diff/parser.zig`
- `src/review/file_read.zig`
- `src/git/client.zig`
- `src/tui/presentation.zig`
- `.scratch/m22-durable-file-read-state/issues/02-keep-binary-files-honest-with-blob-ids.md`

### Tests and checks

The parser test covers short and full ids with and without a mode.
It also covers successive Files without index lines.
Fingerprint tests cover both changed ids, id boundaries, missing ids, unchanged text fingerprints, and refined text and binary byte sizes.
The Git test uses a real repository with `core.abbrev=4`.
It compares both 40-character ids with `git hash-object` output.
Presentation tests cover the binary mark, an unchanged refresh, a changed blob, and refusal without writes.

The native target is Apple Silicon macOS with the project's macOS 15 deployment minimum.
The compiler is Zig 0.16.0.

- `zig fmt --check build.zig src tests` passed with exit code 0.
- `zig build` passed with exit code 0.
- `zig build test-file-read --summary all` passed all 38 tests across 9 steps.
  The library ran 11 tests, and the executable ran 27 tests.
- `zig build test --summary all` passed all 1411 tests across 24 steps.
  The test counts were 334, 1067, and 10.
  Ticket 01 had 1405 tests, so this ticket adds six tests.
- `python3 tools/check_agent_docs.py` passed with exit code 0.
- `git diff --check` passed with exit code 0.

### Failure proofs and review

I temporarily skipped the blob id hashing.
The fingerprint test and the Presentation refresh test failed.
The focused suite passed 36 of 38 tests during that check.
I restored the hashing.

I temporarily removed `--full-index`.
The real Git test failed because it received four-character ids instead of 40-character ids.
The focused suite passed 37 of 38 tests during that check.
I restored `--full-index` before the final checks.

The self-review found no remaining correctness issue or change beyond the SPEC.
I removed trailing whitespace from the parser fixture before the final checks.
The new behavioral tests enforce the blob hashing and full-id requirements.
I found no repeated repository mistake class in this task.
