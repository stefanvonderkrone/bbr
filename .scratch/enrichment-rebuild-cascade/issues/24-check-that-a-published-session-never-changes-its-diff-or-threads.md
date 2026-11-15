# 24: Check that a published Session never changes its Diff or Threads

Status: needs-triage
Blocked by: none

## Summary

The search candidate key of ticket 07 covers the Diff, the Threads, and the mention names only by their identity and the Session epoch.
This is correct only while a published Session never changes these values in place.
Refresh and Reconciliation make a new Session with a new epoch today, so the rule holds.
No compile error, lint, or test enforces the rule.
A later change that edits a Thread or the Diff in place keeps the same key, and Buffer Search then shows stale matches with no error.

The triage decides how to enforce the rule at the highest level that works.
For example, the Session can expose these values only as `const` data, or a test can fail when an in-place edit keeps the key.
The triage also decides if the rule belongs in the `AGENTS.md` rules table.
