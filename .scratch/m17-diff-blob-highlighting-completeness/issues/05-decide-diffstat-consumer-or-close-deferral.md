# Decide whether Diffstat has a concrete consumer

Type: grilling
Status: resolved
Blocked by: none

## Question

Does paginated Bitbucket `getDiffStat` provide metadata that the parsed Diff cannot supply to an accepted M17 user workflow? Choose one concrete consumer and its ownership/refresh/error contract, or close the old M1 Diffstat deferral as obsolete with no implementation.

## Answer

Close the M1 Diffstat deferral as obsolete. M17 will not implement `getDiffStat`.

The endpoint adds per-path `lines_added`, `lines_removed`, `escaped_path`, old/new blob links, and a second paginated File inventory. No accepted M17 workflow consumes those values. The shared Diff already supplies Files, paths, change status, and Lines for both remote and local review. File Enrichment already owns blob acquisition, including path encoding and per-side failure policy.

Adding Diffstat now would create remote-only acquisition, pagination, refresh, error, and reconciliation policy without reviewer value. A future change-total workflow must first define a source-neutral Diff summary. It can reopen Diffstat only if observed Bitbucket behavior proves that the parsed Diff cannot supply correct totals.
