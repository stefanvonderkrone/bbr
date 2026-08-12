# 13 — Cap authored Anchor ranges at the same envelope as re-anchor

**What to build:** Hold initial inline authoring to the same Anchor envelope re-anchor already enforces, so a Selection that bbr would refuse to *repair* to is also refused when it is first *authored*.

**Blocked by:** 04 — Re-anchor inline root Drafts.

**Status:** ready-for-agent

## Why

Ticket 04 introduced `Anchor.validateShape` and `max_anchor_lines` (30) and applied them to re-anchor candidates and to both store adapters' `reanchorDraft` path. Initial authoring — `i` and `S` through `openInlineComposer`/`spanFromLines` in `src/tui/presentation.zig` — was deliberately left alone because changing it was outside 04's scope.

That leaves one inconsistency: a 40-line Selection can still *create* an inline Comment, but the identical Selection is refused when re-anchoring that same Comment, and Bitbucket's verified envelope is the same in both directions. The Selection entry in `src/review/CONTEXT.md` already states the 30-line rule unconditionally, so today the code is narrower than the documented language.

## Decisions to make while implementing

- Whether the cap belongs in `spanFromLines` (shared by both paths) or stays a caller-side check, given re-anchor's bounded `CandidateLines` collector already refuses past 30 before a span exists.
- Whether `put` — the creation write — should recheck the shape the way `reanchorDraft` does, or whether creation validation staying purely in Presentation is the honest boundary. A Draft loaded from an older database may carry a longer range; existing rows must keep loading.

## Acceptance

- [ ] An inline Comment or Suggestion authored over more than 30 inclusive lines is refused at creation with the same reason re-anchor reports, and the Composer does not open.
- [ ] Exactly 30 inclusive lines is still accepted on both the new and old side, at creation and at re-anchor.
- [ ] The refusal is discoverable the same way every other authoring refusal is: a precise ActionError, not a silent no-op or a truncated range.
- [ ] Persisted Drafts whose Anchor predates the cap still load, project, and submit; the cap governs new authored Anchors, not stored history.
- [ ] `src/review/CONTEXT.md`'s Selection entry matches the implemented rule in both directions.
- [ ] Deterministic tests cover the creation boundary on both sides, the refusal reason, and the legacy-row load path.
