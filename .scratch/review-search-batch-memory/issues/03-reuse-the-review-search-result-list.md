# 03: Reuse the Review Search result list

Status: needs-triage
Blocked by: none
Source: [ticket 01](01-find-why-review-search-holds-gigabytes.md)

## Problem

Each accepted Review Search scan allocates a new `results` array (`src/tui/presentation.zig` line 8898) and frees the old one (line 8918).
libmalloc keeps the freed arrays. After close, 65 empty regions of about 33 MiB hold 2.19 GB, and `malloc_zone_pressure_relief` releases nothing (measured, `mem8-notes.md`).

## Proposal

- Grow the `results` array in place, or build it only for the visible rows.

## Acceptance criteria

- [ ] A live run shows the footprint after close before and after.
- [ ] The Review Search tests pass unchanged.

## Comments

### 2026-11-19 filed

The operator filed this ticket from the diagnosis in ticket 01.
