# 23: Compare the search candidate inputs without a digest collision

Status: needs-triage
Blocked by: none

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
