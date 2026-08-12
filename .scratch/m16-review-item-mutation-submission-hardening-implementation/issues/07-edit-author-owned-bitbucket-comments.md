# 07 — Edit author-owned Bitbucket Comments

**What to build:** Let the Authenticated Account press `e` on one of its published root Comments or Replies and edit the same Bitbucket Comment through the prefilled Composer. The remote effect is serialized, never retried automatically, and becomes visible only through authoritative Reconciliation.

**Blocked by:** 02 — Resume frozen SubmissionRuns safely; 03 — Edit Draft bodies atomically.

**Status:** done

- [x] Remote Review loading independently acquires and caches the Authenticated Account UUID without making read-only loading depend on success; `401` invalidates the cached capability.
- [x] Ownership compares only Authenticated Account UUID with Comment author UUID; missing evidence and other authors fail closed with precise ActionAvailability reasons.
- [x] Edit is available for non-deleted author-owned roots and Replies, including resolved, Outdated, and Suggestion-bearing Comments; published re-anchor remains unavailable.
- [x] The typed-target Composer is labelled `Edit Bitbucket Comment`, prefills exact authored bytes, and preserves CommentId, parentage, and CommentScope.
- [x] The Bitbucket update sends only accepted bytes as `content.raw`; raw HTTP, JSON, status, and Atlassian field names do not cross the adapter boundary.
- [x] Submission and published Comment mutation share one global remote-write lane; an accepted edit continues across Session replacement and reports a PullRequest-qualified result when another Review is current.
- [x] Confirmed success and outcome-unknown transport results start Reconciliation without optimistic graph mutation or automatic retry; definitive failure restores the initiating Composer when its Session remains current.
- [x] Failed Reconciliation reports that the Comment was updated but authoritative reload is required and gates later remote writes from that stale Session only.
- [x] Fake-adapter and Presentation tests cover UUID acquisition and invalidation, Suggestion round-trip, body-only request shape, every failure class, unknown delivery, lane contention, Session replacement, Reconciliation, and reload-required gating.
