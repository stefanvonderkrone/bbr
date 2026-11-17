# 10: Accept a code highlighting result only for the same source

Status: needs-triage
Blocked by: none

## Summary

`scheduleCodeBody` in `src/tui/presentation.zig` puts the 64-bit Wyhash of the ReviewBody source in `code_highlighting.Identity.body_hash`, and the Wyhash of the block path in `context_hash`.
`acceptCodeHighlight` admits the result when the Wyhash of the current source equals `body_hash` and the block state holds the same `context_hash`.
So a result of an older source is admitted for a different source that gives the same digest, and the ReviewBody shows colors for the wrong text with no error.

This is the same collision class as [ticket 23 of the cascade](../../enrichment-rebuild-cascade/issues/23-compare-the-search-candidate-inputs-without-a-digest-collision.md).
Its triage showed that a 48-byte block with the words 0, 2, and 4 equal to the Wyhash secrets erases all earlier state in Zig 0.16.0, so a collision does not need chance.
Here the source is text that a user types into a Draft, so the crafted block can come from a user.

## What the triage decides

- Whether the result must carry the source and the path it analyzed, so that `acceptCodeHighlight` compares the bytes, or whether a field that already identifies the source, such as a Draft revision, can replace the digest.
- Whether a mismatch can do harm beyond wrong colors, for example a highlight range past the end of a shorter source.
- Whether the test of ticket 23, which builds the colliding pair, can drive this path too.

## Comments

### 2026-11-16 filed

The runner of tickets 23 and 24 filed this ticket after the triage of ticket 23 found the same pattern at the `body_hash` and `context_hash` sites of `scheduleCodeBody` and `acceptCodeHighlight`.
