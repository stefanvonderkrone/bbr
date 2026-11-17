# 12: Reject a digest that stands in for an equality check

Status: needs-triage
Blocked by: 10

## Summary

Two places in the TUI accepted earlier work when a 64-bit digest of its inputs was equal, and not when the inputs were equal:

- The Buffer Search candidate key of [ticket 23 of the cascade](../../enrichment-rebuild-cascade/issues/23-compare-the-search-candidate-inputs-without-a-digest-collision.md), introduced in `1009d8f4` and replaced by an exact key in `d4e2d284`. Its test shows a constructed Draft pair with the same Wyhash digest that reused a stale corpus.
- The code highlighting identity of [ticket 10](10-accept-a-code-highlighting-result-only-for-the-same-source.md): `body_hash` and `context_hash` in `scheduleCodeBody` and `acceptCodeHighlight` in `src/tui/presentation.zig`.

So the mistake class "a 64-bit digest stands in for an equality check" happened twice. No check rejects a third case.

## Level

The triage of tickets 23 and 24 looked at each level of the `correct` skill:

- Architecture. Ticket 10 removes the remaining case. It does not stop the next one.
- Types. Not enough on their own. Zig rejects `==` on a struct, so a digest type such as `struct { value: u64 }` cannot be compared by mistake. But `std.hash.Wyhash.hash` returns a plain `u64`, and nothing makes code use the wrapper.
- A lint. Possible. In production Zig, every legitimate use of `std.hash` in `src/tui`, `src/review`, and `src/diff` today is the `hash` function of a `HashMap` context, which has an `eql` beside it: `NameContext.hash` in `src/tui/review_body.zig`, `OwnerContext.hash` in `src/tui/frame.zig`, and `AnchorKeyContext.hash` in `src/tui/buffer.zig`. The benchmarks use Wyhash as an output checksum, which is not an equality check of inputs. The grammar trust check uses SHA-256 with `timing_safe.eql`, which is a deliberate cryptographic digest.

## What the triage decides

- A check in `tools/`, read through `zig_files` in `tools/source_lines.py`, that rejects `std.hash.` in production code under `src/` outside a function named `hash`, with `src/benchmark/` and `test` blocks excluded. Its message names the fix: compare the inputs, or put the digest in a `HashMap` context that has an `eql`.
- How the check treats a file-scope helper that only tests call, such as `hashBaselineRows` in `src/tui/presentation.zig`.
- Prove the check on the real mistakes: it fails on `src/tui/buffer.zig` at `aba58b55`, and on the highlight sites until ticket 10 removes them.
- Add a rule section that names the check to the area doc that [the rule areas guide](../../../docs/agents/rule-areas.md) picks.

## Comments

### 2026-11-16 filed

The runner of tickets 23 and 24 filed this ticket for the `correct` step, so as not to widen the change of ticket 23. It is blocked by ticket 10, because the check would fail on the highlight sites until that ticket removes them. A baseline of the two sites is the other option.
