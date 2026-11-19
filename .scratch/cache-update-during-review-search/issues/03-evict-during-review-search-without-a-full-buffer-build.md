# 03: Evict during Review Search without a full Buffer build

Status: needs-triage
Blocked by: none
Source: [ticket 01](01-evict-the-files-that-review-search-releases.md)

## Problem

During Review Search, each cache update that evicts Files is a full Buffer build, because the m21 rule says that cache content, cache focus, and the published Frame change together.
The floor rule of ticket 01 (`min(4 MiB, Review bytes / 8)` above the budget) only decides how often that build runs. On the large local Review at a 1 MiB budget it runs 12 to 13 times during two scan passes (measured, `cuba-notes.md`).
Most of the cost of one build is the copy of the Review Search Batch. [Ticket 04 of the Review Search memory effort](../../review-search-batch-memory/issues/04-share-the-batch-while-a-build-holds-it.md) removes that copy, and [ticket 02 of that effort](../../review-search-batch-memory/issues/02-keep-the-occurrence-data-of-a-batch-in-one-allocation.md) makes each Batch about 3 times smaller.

## Proposal

- A cache update during Review Search changes only the cache state and the Frame inputs that read it, not the whole Buffer.
- The design must keep the m21 rule: a failed publication keeps the previous Frame and cache content.
- If it works, remove the floor rule of ticket 01.

## What to decide

- Decide after tickets 02 and 04 of the Review Search memory effort. If a cache update is cheap after them, this ticket can close as not needed.
- Which Frame inputs read the cache, and whether a partial Frame can publish without breaking the m21 rule.

## Comments

### 2026-11-19 filed

The operator chose to keep the floor rule now and to decide this design after the Batch fixes.
