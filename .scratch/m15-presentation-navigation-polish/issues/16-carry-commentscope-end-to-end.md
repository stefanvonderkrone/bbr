# Carry CommentScope end to end

Status: ready-for-human

## What to build

Make `CommentScope` exhaustive for every root Comment and Draft across Review, persistence, Bitbucket, and Presentation. Review-level, File-level, and inline roots must retain their authored identity, while Replies inherit the root scope. Project each root exactly once into the current Frame, including File-header placement, review/file fallback sections, and File Tree tallies.

## Acceptance criteria

- [x] Root Comments and Drafts use exhaustive Review, File, or inline scope; Replies carry only parentage and inherit their root's scope.
- [x] Persistence is migrated without losing existing inline or Review-level Drafts, and round trips preserve FileScope path and authored source commit.
- [x] Bitbucket translation supports path-only File-level roots through the ordinary comment and Thread APIs without leaking wire vocabulary outside the Bitbucket context.
- [x] Scope resolution distinguishes current, moved, outdated, and unavailable outcomes without mutating authored scope or treating unavailable as outdated.
- [x] ScopeProjection renders every root and its Replies exactly once at the accepted Review, File-header, inline, or fallback location and produces correct per-File tallies.
- [x] Deterministic tests exhaust RemoteReview and LocalReview classifications, migrations, API mappings, fallback placement, Reply inheritance, and duplicate-free projection.

## Blocked by

- [15 — Establish the atomic Presentation Frame](15-establish-the-atomic-presentation-frame.md)
