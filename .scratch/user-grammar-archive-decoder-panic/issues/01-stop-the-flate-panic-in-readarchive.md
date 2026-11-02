# 01: Stop the flate panic in UserGrammar readArchive

Status: needs-triage
Blocked by: none

## Problem

`readArchive` in `src/highlight/user_grammar.zig` decompresses a UserGrammar archive with `std.compress.flate.Decompress` in `.gzip` mode.
It expects a bad archive to give `error.InvalidArchive`.
On Zig 0.16, a truncated gzip stream can panic in the decoder instead.
A panic is not an error, so a bad archive can crash bbr, also in a `ReleaseSafe` build.

Review findings: M32I-8 and X-3 in `/Volumes/Work/t3-code/review-all-branches.md`.

## Evidence

- M32 ticket 03 found the panic on the image path: a PNG with valid chunks and a short deflate stream panics in `Decompress.peekBitsEnding`.
- M32 review A decompressed that IDAT stream with `std.compress.flate.Decompress` in a `ReleaseSafe` test. The output was `panic: integer overflow`.
- On 2026-11-02, the M32 review fix run repeated the test for gzip, with the same calls that `readArchive` makes.
  The input was a gzip stream of 1.2 MB of synthetic screenshot rows, written by Python `gzip.compress(raw, 6)`.
  The test removed 1 to 400 bytes from the end and decompressed each prefix.
  The run used `zig test -OReleaseSafe` on Zig 0.16.0.
  With 11 bytes removed, the decoder panicked:

```text
thread 91134639 panic: integer overflow
/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/compress/flate/Decompress.zig:548:30: 0x10086b12f in takeBits (test)
    d.input.toss((@as(u8, n) + d.consumed_bits) / 8);
/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/compress/flate/Decompress.zig:189:56: 0x10086d86f in decodeLength (test)
```

- The test did not call `readArchive` itself. The crash through `readArchive` is inferred from the same calls.

## Production flate callers

On 2026-11-02, `rg "std\.compress" src` finds one production decompression caller: `readArchive` at `src/highlight/user_grammar.zig:469-477`.
`src/highlight/user_grammar.zig:934-935` compresses in a test.
`StdHttpClient` accepts only the `identity` encoding, so std HTTP does not decompress a response.
No production code calls zigimg or the vaxis image API.

## Acceptance criteria

- [ ] A test in `src/highlight/user_grammar.zig` loads a truncated gzip archive and expects `error.InvalidArchive` with no panic, in Debug and in `ReleaseSafe`.
- [ ] The test fails on the current code.
- [ ] The fix removes the panic at its root, for example with a decoder that cannot panic on hostile input, or a check that rejects the stream before the std decoder reads it.
- [ ] The ticket records a report of the std bug upstream, with its link, or states why no report was made.
- [ ] `zig build test` passes.

## Comments

### 2026-11-02

The M32 review fix run filed this ticket.
The probe files were temporary and are not in the repository.
