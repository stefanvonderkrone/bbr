# 01 — Show actual Reply ancestry

**What to build:** Show each Comment or Draft before its Replies, with complete parent subtrees and readable bodies at narrow widths. Preserve actual known ancestry through disclosure and Reconciliation.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Complete each parent's subtree before the next sibling. Published siblings retain input order and precede Draft siblings in creation order.
- [ ] Keep Draft descendants inside their parent's subtree. Each known parent relationship adds one depth level from a root at depth zero.
- [ ] Keep CommentId and TempId distinct. Presentation does not change authored parent links, CommentScope, or body bytes.
- [ ] Select the starting indentation unit from DiffPane width. Use four columns at 100 or more. Use three from 80 through 99, two from 60 through 79, and one below 60.
- [ ] Use one unit for each Thread or root Draft subtree, based on its deepest known Reply, including body-collapsed Replies.
- [ ] Calculate the indentation budget from root body width minus the smaller of 40 columns and root body width. Reduce the starting unit until the deepest Reply fits or the unit reaches one.
- [ ] Cap each card's depth-times-unit indentation at that budget. Apply the same offset to its header, body, and footer.
- [ ] Show actual depth when the cap hides it. At or below 40 root body columns, use the complete body width without Reply indentation.
- [ ] Retain Deleted Comments at their actual place and depth. Resolved and Outdated disclosures hide or restore complete subtrees. Body disclosure hides only that body's rows.
- [ ] Label an absent-parent subtree `parent unavailable`. Preserve known placement without inventing ancestors or CommentScope. Use known relative depth from its highest available ancestor.
- [ ] Replace a posted Draft representation once with its fetched Comment. Pending Replies follow its CommentId without an extra ancestry level.
- [ ] Verify the approved mixed order, all width breakpoints, narrow and capped depths, disclosure, and partial Reconciliation in both layouts.
- [ ] Check cursor ownership and search navigation after resize. A failed projection preserves the previous complete Presentation Frame.
- [ ] Cover RemoteReview and LocalReview where applicable. Run the complete hermetic suite with `zig build test --summary all`.

## Contract

Use the [M23 specification](../../m23-comment-thread-markdown-presentation-fixes/SPEC.md#reply-ancestry-and-width) and the [approved ancestry answer and examples](../../m23-comment-thread-markdown-presentation-fixes/issues/03-choose-nested-reply-presentation.md#answer).
ADR-0007 governs posted Draft Reconciliation. ADR-0012 governs atomic Presentation publication.
