# Comment anchor lifecycle: current / moved / outdated

Every comment Anchor binds to a **commit + path + line** (plus a few captured context lines),
not just a line. When the diff being viewed differs from the commit a comment was authored on,
the comment resolves to an **AnchorState**: `current`, `moved`, or `outdated`. Outdated
comments are **never hidden** — they are shown in a per-file section using their captured
context, so a comment whose line no longer exists is still readable.

AnchorResolution is the attempt around that verdict. A local resolution may be `unavailable`
when the clone lacks the Anchor commit, Git fails, or the diff cannot be mapped. Unavailable is
not an AnchorState and never becomes `outdated` by assumption; the Draft remains visible with
captured context and an explicit warning while the rest of the Session remains usable. Outdated
and unavailable sections remain expanded in M14; collapsing them is a separate Presentation feature.

Each root local Draft persists an immutable AnchorSnapshot containing its complete selected
range plus three surrounding lines on each side. Current and moved Anchors render against the
current Diff and do not display the snapshot; outdated and unavailable Anchors display it as
evidence of the original subject. Mapping never uses the snapshot for fuzzy matching, and Replies
inherit the root Draft's snapshot rather than duplicating it.

## Who computes the state

- **Remote (Bitbucket) comments** — we display **Bitbucket's** outdated verdict and original
  hunk context. Bitbucket is authoritative for its own comments (consistent with ADR-0001);
  we do not re-derive it and risk divergence.
- **Local comments and pending Drafts** — there is no server, so we compute the state
  ourselves by **diff-walking**: `git diff <anchor_commit> <current_ref> -- <path>` and mapping
  the old line forward.

For a LocalReview, a new-side Anchor binds to the resolved SourceRef commit and maps toward the
current SourceRef; an old-side Anchor binds to the resolved BaseRef commit and maps toward the
current BaseRef. New-side context follows the SourceRef. The stored authored Anchor is preserved;
resolution produces projected coordinates rather than rewriting its history.

Local resolution follows a File rename only when Git's explicitly configured rename detection
reports it. A proven path change yields `moved` and projected path/line coordinates while the
authored Anchor remains unchanged. A deletion yields `outdated`; copies remain attached to the
original File and are never guessed as moves.

A ranged Anchor resolves atomically. It is `current` or `moved` only when every originally
anchored line survives contiguously on the same side; removal, replacement, separation, or
partial survival makes the whole Anchor `outdated`. Resolution never shrinks a range or maps
only its surviving endpoints.

File placement is side-aware: old-side Anchors match a File's old path and new-side Anchors match
its new path. An outdated item stays beneath the matching File, including a removed File rendered
under its old path. Only an item with no matching current File, or an unavailable resolution,
falls back to the trailing review-level section; no outdated or unavailable item is dropped.

Resolution of persisted local root Drafts is a required candidate-Session loading phase. The
loader caches one parsed repository transition Diff per authored/current commit pair, so every
compatible path and side shares the same Git work, and produces one terminal AnchorResolution
for every root before Presentation publishes the candidate.
`unavailable` is a successful resolution result for loading purposes: it preserves the captured
evidence and warning without making the rest of the Session unusable. Replies inherit their
root's result.

These results form a Session-scoped AnchorProjection keyed by root TempId. The projection belongs
to the published review aggregate rather than the source Session or durable PendingReview: the
Session remains acquired source material, while the PendingReview preserves authored truth.
Session replacement rebuilds the projection. Saving a new root Draft adds a `current` entry because
the Draft was authored against the already published Session; its Replies reuse that entry.

## Consequences

- Comments and Drafts store the commit hash they were authored against, plus captured context
  lines, in SQLite.
- This is why local review needs the GitClient (ADR-0004): the diff-walk is how local
  outdatedness is even knowable.
