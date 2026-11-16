# 23: Compare the search candidate inputs without a digest collision

Status: ready-for-agent
Blocked by: 24

## Summary

Ticket 07 reuses the published `BufferSearchCorpus` when `SearchCandidateInputs.key()` in `src/tui/buffer.zig` gives the same value as the key of that corpus.
The key is a 64-bit Wyhash digest of the inputs, and `BufferSearchCorpus.reuseOrBuild` in `src/tui/presentation.zig` compares only the digests.
When two different inputs give the same digest, the build publishes a stale corpus, and Buffer Search shows wrong matches with no error.
The chance of one collision is very small, but nothing detects one when it happens.

The triage decides between these options:

- Keep the digest and record the decision with its reason.
- Store a copy of the compared inputs with the corpus and compare them field by field after an equal digest.
- Compare the inputs field by field and drop the digest.

The triage measures the cost of each option on the workload of ticket 05 before it chooses.

## What to build

Replace the 64-bit digest with an exact key, so that `BufferSearchCorpus.reuseOrBuild` reuses a corpus only when the inputs are equal.

- `SearchCandidateKey` in `src/tui/buffer.zig` becomes a struct that holds the compared inputs, not a digest:
  - The Session Epoch, the Layout, the isolated File, the scope tag, and the Selected Version, by value.
  - The identity words of the Diff `files`, the Threads, and the mention names pointer, by value. Ticket 24 keeps these inputs read-only, and the identity sees a field reassignment.
  - One identity (presence, pointer, length) for each File blob side in the whole-file scope, copied into a slice.
  - A deep copy of the Drafts and the scope projections.
- `SearchCandidateInputs.key` takes an allocator and returns the key. `BufferSearchCorpus` makes the key in its own arena, so the key lives as long as the corpus. `SearchCandidateKey.eql` compares two keys field by field, with the presence of each optional, the length of each slice, and the content of each slice.
- Keep the exhaustive switch over `std.meta.FieldEnum(SearchCandidateInputs)`, so a new input does not compile until it says how the key covers it. The `emphasis_cache` and `side_by_side_plans` arms stay empty.
- Delete `hashIdentity`, `hashContent`, and the Wyhash state of the key. Do not keep the digest as a first check. The comparison reads the same bytes that the hash reads today, so a digest saves nothing on a hit.
- Remove "unless two different inputs give the same 64-bit digest" from the doc comment of `SearchCandidateInputs`. Update `src/tui/IMPLEMENTATION.md` and the Buffer Search entry of `src/tui/GLOSSARY.md` if they describe the key.

## Acceptance criteria

- [ ] `reuseOrBuild` reuses the previous corpus only when `SearchCandidateKey.eql` holds. No Wyhash is left in the key code.
- [ ] A test fails at `aba58b5` and passes after the change. It builds a corpus from inputs A, then calls `reuseOrBuild` with that corpus as the previous one and inputs B. A and B differ only in the bytes before a crafted block in one Draft, and give the same old digest. The test checks that the corpus of B holds the text of B. Construct the pair from the zero-state block of the comment of 2026-11-16. Try each of the 48 offsets of the block, so the test does not depend on the byte layout of the old key. Record in the Completion which offset collides at `aba58b5`.
- [ ] If the candidate build rejects the bytes of the block in a Draft body, put the block in a Draft or scope projection field that the build does not parse, and record the field in the Completion.
- [ ] The key tests of ticket 07 pass, with "changes the key" read as "the keys are not equal".
- [ ] On the workload of ticket 05, with the method of ticket 07 and temporary `[DEBUG-23]` marks, the median of the candidates and corpus phases of a Unified resize stays at most 1 ms. The phases of a Layout switch, which builds new candidates, stay within the run-to-run spread of a baseline at `aba58b5` of the same run. Report the machine load. No `[DEBUG-23]` line stays in the repository.
- [ ] `zig build test` passes.
- [ ] `python3 tools/check_agent_docs.py` passes.

## Comments

### 2026-11-16 triage

The runner asked for a triage of tickets 23 and 24 together, and set this ticket to `ready-for-agent`, blocked by [ticket 24](24-check-that-a-published-session-never-changes-its-diff-or-threads.md).

**Premise.** The premise is true at `aba58b5`, and a collision does not need chance.

- `reuseOrBuild` in `src/tui/presentation.zig:2048-2057` compares only the two digests. Only `DisclosureBuild` passes a previous corpus (3142). `Published.bufferSearchCorpus` passes none (5165).
- `SearchCandidateInputs.key` in `src/tui/buffer.zig:1278-1308` is one `std.hash.Wyhash` stream over every input.
- In Zig 0.16.0, `Wyhash.round` sets `state[i] = mix(a ^ secret[i + 1], b ^ state[i])` (`lib/std/hash/wyhash.zig:123-128`). When the words 0, 2, and 4 of a 48-byte block equal the secrets 1, 2, and 3, each product is zero, and the block erases all earlier state, the pointer words of the key included.
- A scratch program measured this: two different 48-byte prefixes, then the same block and the same tail, gave the same digest. So two Drafts that differ before such a block in a Draft body give the same key, and the build publishes the stale corpus.
- A user who types such bytes by accident is very unlikely, but the collision is constructible, and a test can show it.

**Non-collision cases.** The key also stays the same in these cases. An exact key does not fix them, and other code owns them.

- An in-place change of the Diff, the Threads, or the mention names of a published Session. Ticket 24 owns this.
- A File blob side that is evicted and loaded again at the same address with the same length. This is correct only because a side holds the same text whenever it is loaded. The leases of `DisclosureInputs` keep a side alive while a build reads it, but no check enforces the same-text rule.

**Decision.** The triage chose the exact key and rejected the two other options.

- The triage rejected keeping the digest, because the collision is constructible, and the exact key costs about the same as the digest.
- The triage rejected a field comparison after an equal digest, because the comparison reads the same bytes as the hash, so the digest only adds code.

**Cost.** The triage did not measure the options, because a measurement needs the change. The estimate is an inference from the code, and the acceptance criteria measure it.

- A hit compares the bytes that the hash reads today, so its cost does not change.
- A miss also copies the Drafts, the scope projections, and one identity for each File blob side into the corpus arena. On the workload, that is one Draft of 14 paragraphs. A miss also builds the candidates, which cost 45.1 ms on a Unified resize in the baseline of ticket 07.
- The saving of ticket 07 on a Unified resize, 34.1 ms of candidates and corpus phases, stays.

**Order.** Ticket 24 changes the `.mention_names` arm of the key, and this ticket replaces the key. Do ticket 24 first, in its own commit. Ticket 24 does not make this change smaller, because a field reassignment stays possible, so the identity words stay in the key.

**Same pattern elsewhere.** The code highlighting identity in `src/tui/presentation.zig:12283` and `12315` accepts a result when the 64-bit Wyhash of the ReviewBody source is equal. This ticket does not change it. A human decides whether it gets its own ticket.
