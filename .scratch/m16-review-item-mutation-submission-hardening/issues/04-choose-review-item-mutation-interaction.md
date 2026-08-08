# Choose the review-item mutation interaction

Type: prototype
Status: resolved
Blocked by: none

## Question

How should a reviewer target a rendered Draft, Comment, or Reply and invoke edit, re-anchor, delete, recovery, and confirmation Actions without confusing local Draft identity with Bitbucket-owned Comment identity, while using one prefilled Composer and preserving complete keyboard operation?

## Answer

Use direct contextual Actions on the ReviewCard under the DiffPane cursor (prototype Variant A). Every row of a ReviewCard resolves to its stable, typed owner: either a local `TempId` or a Bitbucket `CommentId`. Presentation carries that typed target through the interaction; it never converts both identities into one generic numeric id. Human-facing headers and transient surfaces name the provenance explicitly as `local Draft` or `Bitbucket Comment`, with `draft`, `failed`, and `outcome unknown` remaining semantic labels rather than identities.

Bind `e` to edit, `a` to re-anchor, and `D` to delete in the ReviewCard Interaction Context. Keep these Actions visible through ActionAvailability even when unavailable. Invoking an unavailable Action produces a specific status reason: another author's Comment is not owned, a published Anchor is immutable, a Reply has no independent Anchor, an active SubmissionRun owns the Draft, or an ambiguous recovered Draft must be resolved first. There is no silent no-op and no hidden mutation binding.

`e` opens the existing Composer with the selected item's authored bytes prefilled. Its header says `Edit local Draft` or `Edit Bitbucket Comment`; the Composer request retains the typed mutation target, so save mutates the same identity and parent relationship rather than creating a new Draft. Composer editing, cancellation, `Ctrl-E` external-editor handoff, and save remain one interaction regardless of whether persistence is local or remote; only the command emitted by the accepted save differs.

Root-Draft re-anchor is a two-stage contextual interaction because the ReviewCard cursor first names the Draft and a later source cursor or Selection names the replacement Anchor. Pressing `a` on an eligible root Draft arms `Re-anchor local Draft`, retains its `TempId`, and returns navigation to the DiffPane with a persistent status/banner. The reviewer navigates or selects lines under the existing Selection rules, presses Enter to accept, or Escape to cancel. While armed, the UI shows the Draft identity and the candidate path/side/range together. Replies and every published Comment lack this Action.

`D` opens a confirmation Overlay that names the typed target and effect. A local parent Draft confirmation includes the count of Draft reply-descendants that will also be deleted. A Bitbucket confirmation explicitly says the mutation is remote and that Reconciliation follows success. Confirm and cancel are keyboard-complete; failure closes no identity gap and leaves the visible published state unchanged.

Recovered `outcome_unknown` or unresolved `submitting` Drafts keep their distinct card treatment and expose only their recovery Actions. The existing direct `U` (confirm unpublished) and `g C` (link an existing author-owned Comment) bindings remain contextual; choosing neither is `decide later`. Edit, re-anchor, and delete stay visible but unavailable with `outcome unknown — resolve before editing`. The exact evidence and confirmation flow for ambiguous recovery remains for the later recovery contract.

Prototype evidence: branch `prototype/m16-review-item-mutation-interaction`, commit `67db2fd39fd32ffc5e633973de9a09d2a2779d3d`. The human selected Variant A over the Action-menu and inspector alternatives.
