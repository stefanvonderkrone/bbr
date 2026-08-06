Status: ready-for-human
Milestone: M20

# Choose explicit old/new side inspection and yank behavior

## Question

How should a reviewer explicitly select the old or new File version for isolated viewing and clipboard operations, across unified and side-by-side layouts, without making the currently selected side ambiguous?

The decision must cover the Action and default-key grammar, visible side/focus indication, whether side choice applies to one row or the whole File, Count and Selection behavior, unavailable sides such as additions and deletions, interaction with WholeFile scope and File Enrichment, reset/persistence rules, and keyboard/mouse parity. It must also decide whether an explicit side choice replaces M15's provisional yank rule—new-side text when present, otherwise old-side text—or only overrides it while active.

## Blocked by

M15's integrated Presentation contract. Implementation may additionally depend on M17's old-side blob and side-by-side alignment work.

## Comments

- 2026-08-06: Deferred from M15 at the human's request. M15 keeps the simple new-side-first yank rule and does not add explicit side switching.
