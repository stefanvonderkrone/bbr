# 23: Compare the search candidate inputs without a digest collision

Status: resolved
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

- [x] `reuseOrBuild` reuses the previous corpus only when `SearchCandidateKey.eql` holds. No Wyhash is left in the key code.
- [x] A test fails at `aba58b5` and passes after the change. It builds a corpus from inputs A, then calls `reuseOrBuild` with that corpus as the previous one and inputs B. A and B differ only in the bytes before a crafted block in one Draft, and give the same old digest. The test checks that the corpus of B holds the text of B. Construct the pair from the zero-state block of the comment of 2026-11-16. Try each of the 48 offsets of the block, so the test does not depend on the byte layout of the old key. Record in the Completion which offset collides at `aba58b5`.
- [x] If the candidate build rejects the bytes of the block in a Draft body, put the block in a Draft or scope projection field that the build does not parse, and record the field in the Completion.
- [x] The key tests of ticket 07 pass, with "changes the key" read as "the keys are not equal".
- [x] On the workload of ticket 05, with the method of ticket 07 and temporary `[DEBUG-23]` marks, the median of the candidates and corpus phases of a Unified resize stays at most 1 ms. The phases of a Layout switch, which builds new candidates, stay within the run-to-run spread of a baseline at `aba58b5` of the same run. Report the machine load. No `[DEBUG-23]` line stays in the repository.
- [x] `zig build test` passes.
- [x] `python3 tools/check_agent_docs.py` passes.

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

## Completion

Commits:

- `008cad2d` adds the failing test.
- `d4e2d284` replaces the digest with an exact key.

**Change.**

- `SearchCandidateKey` in `src/tui/buffer.zig` is a struct with one field for each input of the same name. It holds the Session Epoch, the Layout, the isolated File, the scope tag, and the Selected Version by value. It holds the Diff `files`, the Threads, and the mention names pointer as identity words. It holds one identity (presence, address, length) for each File blob side in the whole-file scope, in a slice. It holds a deep copy of the Drafts and the scope projections.
- `SearchCandidateInputs.key` takes an allocator. It keeps the exhaustive switch over `std.meta.FieldEnum(SearchCandidateInputs)`. The `emphasis_cache` and `side_by_side_plans` arms assert at compile time that the key has no field of that name. A `comptime` block in `SearchCandidateKey` asserts that each key field names an input, so no key field stays undefined.
- `copyContent` replaces each slice with a copy. `eqlContent` compares the presence of each optional, the length and content of each slice, and the tag and payload of each union. Both reject a single-item pointer, a float, or another type they do not know with a compile error.
- `BufferSearchCorpus.reuseOrBuild` in `src/tui/presentation.zig` makes the key in the build arena and reuses the previous corpus only when `SearchCandidateKey.eql` holds. On a miss it builds the corpus and makes the key again in the corpus arena, so the key lives as long as the corpus.
- `hashIdentity`, `hashContent`, and the Wyhash state of the key are gone. The doc comment of `SearchCandidateInputs` no longer names a digest. `src/tui/IMPLEMENTATION.md` says that the key holds the inputs and compares them exactly. The Buffer Search entry of `src/tui/GLOSSARY.md` does not describe the key, so it did not change.
- A design check before the code compared this shape with a borrowed key and a clone on a miss, and with a second walk that compares stored keys with the inputs. Both alternatives keep two sets of rules in step, so the runner kept the ticket's shape. The check asked for the compile-time field checks above.

**Failing test.** "M21 kernel a Buffer Search corpus is reused only for equal inputs, also when a 64-bit digest of them collides" in `src/tui/presentation.zig`. It builds a 48-byte block whose words 0, 2, and 4 are the Wyhash secrets 1, 2, and 3. For each of the 48 offsets, it builds a corpus from a Review-level Draft `stale` + padding + block + ` tail`, checks that an equal copy of the inputs reuses that corpus, and then checks that the Draft `fresh` + the same padding, block, and tail gets a corpus with `fresh` and without `stale`.

- At `008cad2d`, where the source of the key is the same as at `aba58b5`: `zig build test-search-kernel` fails with "offset 9 reused the corpus of other inputs".
- At `d4e2d284`: it passes for all 48 offsets.
- The candidate build accepts the bytes of the block in a Draft body, so the block stays in the body.

**Measurement.** Workload and method of ticket 07: `bbr local fb701b1 1836261` from a checkout of this repository, ReleaseFast, tmux at 160 × 80, a separate `XDG_STATE_HOME` with mode `700`, one Draft with 14 paragraphs, the cursor on a Diff Line (row 4 of 187,839). Temporary `[DEBUG-23]` marks in `DisclosureBuild.buildFallible` read the thread CPU clock around `reuseOrBuild` and the whole job, in detached worktrees at `aba58b5` (baseline) and `d4e2d284` (result). One warmup baseline run was discarded. Then four baseline runs and four result runs alternated, each with 8 resizes (150 and 160 columns) and 8 Layout switches, 1.5 s apart. The machine has 18 cores. The 1-minute load average was 3.5 to 8.4 from other work. The worktrees, the state directory, and the tmux sessions are removed.

Target, written before the runs: the `reuseOrBuild` phase of a Unified resize stays at most 1 ms, and the phase of a Layout switch stays within the spread of the baseline.

`reuseOrBuild` CPU per rebuild, median (range), in ms:

| Rebuild | n per side | Reused | Baseline | Result |
| --- | --- | --- | --- | --- |
| Resize, Unified | 32 | 32 of 32 on both sides | 0.003 (0.002 to 0.014) | 0.006 (0.003 to 0.009) |
| Switch to SideBySide | 16 | 0 on both sides | 33.4 (22.8 to 35.2) | 32.3 (22.8 to 36.8) |
| Switch to Unified | 16 | 0 on both sides | 33.6 (24.2 to 38.1) | 34.0 (24.8 to 38.8) |

- A hit costs about 3 µs more than the digest, for the copy of one Draft into the build arena and the comparison. Ticket 07 measured 34.1 ms for these phases before the reuse, so the saving of ticket 07 stays.
- A miss also makes the key twice. A hit makes the key once and compares it, at 6 µs, so the added cost of a miss is about 12 µs, which is far below the spread of 12 to 14 ms. The miss phase is bound by `buildSearchCandidates` over all Buffer rows, as in ticket 07.
- The whole job, median: resize 83.0 and 83.0 ms, switch to SideBySide 120.2 and 121.5 ms, switch to Unified 105.0 and 107.5 ms. Process CPU for the 16 actions: 1.99 to 2.06 s on both sides.
- Clock ramp: one more run of each side ran the fixed loop of ticket 21 (2 million xorshift steps) before `reuseOrBuild`. Its median was 4.5 and 4.3 ms before a resize, 3.9 and 4.9 ms before a switch to SideBySide, and 4.6 and 4.7 ms before a switch to Unified, with ranges of 2.7 to 5.3 ms on both sides. So the clock was the same on both sides. The loop range of about 2 times explains most of the spread of the miss phase.
- Only `view` builds ran for these actions on both sides.
- `git grep DEBUG- -- src` finds nothing.

**Checks.**

- `zig build test`: exit 0.
- `zig fmt --check src build.zig tests`: exit 0.
- `python3 tools/check_agent_docs.py`: pass.

**Follow-ups.** [Ticket 10](../../enrichment-rebuild-follow-up/issues/10-accept-a-code-highlighting-result-only-for-the-same-source.md) owns the code highlighting digest, [ticket 11](../../enrichment-rebuild-follow-up/issues/11-check-that-a-file-blob-side-always-holds-the-same-text.md) owns the blob text rule, and [ticket 12](../../enrichment-rebuild-follow-up/issues/12-reject-a-digest-that-stands-in-for-an-equality-check.md) owns a check for the mistake class.

**Review.** The two-axis code review of `6f2dcbbd..HEAD` found no hard violation and no missing requirement.

- Both axes named the hit-path copy: a hit copies the Drafts into the build arena before it compares. The runner kept it. The measured cost is 3 µs per hit, and a comparison of a stored key with the inputs needs a second walk over the input fields, which the design check rejected.
- The Standards axis named judgement calls that the runner did not change: `mention_names` is a raw address beside the `Identity` fields because it is one pointer, not a slice. `resolveMentions` creates an empty map when no comment has a mention, which costs one small arena allocation for each load. The rule of ticket 24 is in the `AGENTS.md` row and in the doc comments that the ticket asked for.
