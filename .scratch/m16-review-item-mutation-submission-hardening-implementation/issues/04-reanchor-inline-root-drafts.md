# 04 — Re-anchor inline root Drafts

**What to build:** Let a reviewer press `a` on an eligible inline root Draft, navigate to a replacement source cursor or Selection, and atomically publish the repaired Anchor while preserving the Draft and its Reply subtree. The interaction refuses ambiguous source shapes rather than guessing.

**Blocked by:** 03 — Edit Draft bodies atomically.

**Status:** done

- [x] Re-anchor is available only for mutable inline root Drafts; Replies, Review-level Drafts, File-level Drafts, and published Comments expose a precise unavailability reason.
- [x] The two-stage interaction retains the selected TempId, shows the Draft and candidate path/side/range, accepts with Enter, and cancels with Escape without mutation.
- [x] Accepted Anchors are one-side-only, matched, ascending, within one File, do not cross a hidden hunk gap, and contain at most 30 inclusive lines.
- [x] Ordinary old-side Comment Anchors are accepted; old-side Suggestions and mixed-side or otherwise ambiguous shapes are refused.
- [x] A real Anchor change preserves TempId, body, kind, and descendants, resets `failed` to `draft`, and replaces the root ScopeProjection with `current`; an identical Anchor is a no-op.
- [x] LocalReview re-anchor captures a replacement AnchorSnapshot, while RemoteReview records the side-appropriate authored commit without inventing local snapshot behavior.
- [x] The store atomically rechecks identity and eligibility; stage, persist, publish rollback preserves the old Draft, ScopeProjection, Frame, navigation, and active candidate on failure.
- [x] Success follows the TempId to its new ReviewCard and survives Session replacement and restart.
- [x] Deterministic tests cover new- and old-side ranges, the 30-line boundary, all refusal shapes, Suggestion behavior, LocalReview snapshot replacement, no-op handling, rollback, and identity-based navigation.
