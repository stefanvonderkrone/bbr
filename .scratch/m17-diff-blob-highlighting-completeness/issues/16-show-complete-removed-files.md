# 16 — Show Complete Removed Files

**What to build:** Show a removed File's complete old content in WholeFile Scope while preserving the RawDiff Hunk Lines and their Anchor identity.

**Blocked by:** 14 — Acquire Remote File Sides Safely; 15 — Apply File Content Status to LocalReview.

**Status:** ready-for-agent

- [ ] WholeFile Scope selects old content for removed Files and new content for all other Files.
- [ ] Old-side splicing uses authoritative old line numbers and preserves every Hunk Line unchanged.
- [ ] Context Lines sourced from full content are non-anchorable and cannot receive inline Comments or Drafts.
- [ ] Empty text content produces a complete zero-Line WholeFile projection instead of falling back to Changes Scope.
- [ ] Remote and LocalReview fixtures prove equivalent removed, added, renamed, empty, unavailable, and path-special behavior.
