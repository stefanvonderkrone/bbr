# Choose File cache configuration language

Type: grilling
Status: resolved
Blocked by: none

## Question

What user-facing `[files.cache]` setting names and documentation most clearly explain the enabled-by-default 256 MiB inactive-retention budget, focused File exception, eviction/refetch behavior, and distinction from `[highlight].max_file_bytes`, given that pre-user development permits clean renaming without aliases?

## Answer

Keep the `[files.cache]` table and expose this public schema:

```toml
[files.cache]
enabled = true
max_bytes = 268435456
```

- Rename `max_retained_bytes_per_review` cleanly to `max_bytes`; add no compatibility alias during pre-user development. The table supplies the cache scope, while the documentation explains that the budget applies to inactive in-memory File content.
- Default `enabled` to `true` and `max_bytes` to 256 MiB. With a positive limit, evict least-recently-used inactive whole Files until retained content fits the limit; refetch an evicted File when it is revisited. The focused File remains available outside this budget and may exceed it.
- Interpret `enabled = true` with `max_bytes = 0` as unlimited inactive caching, consistent with zero meaning unlimited for `[highlight].max_file_bytes`.
- With `enabled = false`, allocate and retain no inactive File cache and ignore `max_bytes`; revisiting a previously focused File refetches its content.
- Keep public documentation user-focused: explain the defaults, focused-File exception, whole-File eviction/refetch behavior, and zero semantics without enumerating internal blobs, Spans, Capture names, allocation capacity, or scratch accounting.
- Explicitly distinguish the settings by effect: `[files.cache].max_bytes` limits retained inactive full-File content, whereas `[highlight].max_file_bytes` limits Highlighting work for each old/new file side and leaves oversized content readable as plain text.
- Give any future persistent disk cache a distinct configuration namespace rather than broadening this in-memory setting. Implementation must also amend ADR-0010, whose current text records the superseded key and rejects a zero budget.
