# 11: A fast quit drops the Summary Cache save

Status: needs-triage
Blocked by: none
Spec: [M24 spec](../SPEC.md)

## Summary

The live M24 outside check, ticket 07 step C, found this on 2026-11-04 at commit `151352c`.

- The operator deleted `browser-cache.json`, ran `bbr` outside Git, and pressed `q` when the first rows showed.
- After two such runs, no `browser-cache.json` existed. The second run had no cached rows.
- With a wait of about 15 seconds before `q`, the file existed with mode `-rw-------`, and the next start showed cached rows at once.

So a reviewer who quits soon after the first rows never gets a Summary Cache.

## Suspected cause

Not proved.
`saveSummaryCache` in `src/tui/presentation.zig` returns when `shutdown_requested` is set.
It also saves only after the Repository list is complete.
Shutdown drops queued commands, which include a queued `save_summary_cache`.
The first rows can show before the complete Repository list arrives, because the list has many pages.

## What to do

1. Reproduce offline: show the first page of the Repository list, then request shutdown before the last page.
2. Decide what to save at shutdown: the complete list only, or also a partial list that keeps the Repositories that the old cache holds.
3. Let a save that is queued or due run before exit, with a short time limit.
4. Add a test that fails when a `q` after a complete Repository list leaves no Summary Cache file.

## Comments
