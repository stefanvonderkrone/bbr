# Choose nested Reply presentation

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: resolved

## Question

How does each ReviewCard show its actual parent depth without losing readable body width?

The user includes published Replies, Draft Replies, and mixed ancestry.
Choose the indentation unit, traversal order, sibling order, and narrow-width behavior.
The current Thread builder preserves published Reply input order in a flat list.
The current ReviewCard projection distinguishes root and Reply roles but does not carry arbitrary depth.

Discuss a root with two Replies, a Reply to the first Reply, and Draft Replies attached at each level.
Decide whether published descendants stay in creation order or form contiguous parent subtrees.
Include Deleted Comments, absent parents, hidden resolved Threads, Outdated groups, and posted Draft reconciliation.
Keep Draft visibility tied to its parent and retain typed CommentId and TempId ownership.

Use narrow and wide terminal examples if the human needs a concrete comparison.
The answer defines observable presentation behavior and acceptance examples, not an implementation.

## Comments

### First decision round

- The user chose a viewport-dependent indentation unit of one, two, three, or four terminal columns.
- The width measurement, thresholds, and behavior when depth consumes the available width remain open.
- The user accepted published-first sibling order. Published siblings retain input order, followed by Draft siblings in creation order.
- The user chose contiguous parent subtrees. Show each parent before its Replies, then complete each Reply's descendants before the next sibling.
- Published-first order applies among siblings, not across the complete Thread. A Draft Reply under one published Reply stays in that parent's subtree.

### Viewport and absent-parent round

- The user accepted the available DiffPane width as the width measurement.
- Use four terminal columns per level at widths of at least 100 columns, three at 80 through 99, two at 60 through 79, and one below 60.
- The user accepted an available subtree with a "parent unavailable" label when its parent is absent. Keep the authored parent link.
- The user observed that the Bitbucket web UI shows only one Reply indentation level.
- The web UI observation does not establish a Cloud API depth limit. No Cloud depth limit was verified in this session.

### Depth and body-width round

- The user retained actual parent depth for published Replies, Draft Replies, and mixed ancestry.
- Start with the viewport-dependent indentation unit. If a Reply body has fewer than 40 columns, reduce the unit by one.
- Repeat the reduction until the body fits or the unit reaches one column.
- A viewport can have fewer than 40 available body columns. The presentation must still use the available width.
- The user accepted one reduced unit for the complete Thread, based on its deepest Reply.
- The user accepted a visual indentation cap when one column per level still cannot retain the body-width target.
- Show actual depth in the header when the cap prevents indentation from expressing that depth.
- Below 40 available body columns, use all available body width and show depth in the header.

## Answer

### Parent grouping and sibling order

Show each parent before its Replies. Complete each Reply's subtree before the next sibling.
Apply published-first order among siblings. Published siblings retain their input order, followed by Draft siblings in creation order.
A Draft descendant stays with its parent even when another published sibling follows that parent's subtree.

A root has depth zero. Each known parent relationship adds one level.
Use the same depth rule for published Replies, Draft Replies, and mixed ancestry.
Keep CommentId and TempId ownership distinct. Indentation never changes the authored parent link, CommentScope, or body bytes.

### Width policy

Measure the available DiffPane width in terminal columns, not the complete terminal width or UTF-8 bytes.
The starting indentation unit depends on that width.

| DiffPane width | Starting columns per level |
| --- | --- |
| At least 100 | 4 |
| 80 through 99 | 3 |
| 60 through 79 | 2 |
| Below 60 | 1 |

Use one indentation unit for the complete Thread or root Draft subtree.
Choose the unit from its deepest known Reply, including published and Draft ancestry.
Collapsing a ReviewCard body does not remove that Reply from the depth calculation.

Let `B` be the available root body width after ordinary ReviewCard padding.
The target body width is `min(40, B)`. The indentation budget is `B - min(40, B)`.
Start with the viewport-dependent unit.
Reduce the unit by one while the deepest Reply would exceed the indentation budget and the unit exceeds one.

For each ReviewCard, visual indentation is the smaller of its depth times the chosen unit and the indentation budget.
Apply that offset to its header, body rows, and disclosure footer.
Use the remaining body width for ReviewBody projection.
Show actual depth in the header when the cap prevents indentation from expressing that depth.

Below 40 available body columns, the indentation budget is zero.
Use all available body width. Show Reply depth in the header instead of consuming that width with indentation.
The 40-column target never requires a wider viewport or negative available width.

### Structural cases

- Deleted Comments retain their place and depth. Their surviving Replies stay beneath them.
- A collapsed resolved Thread hides its complete subtree, including Draft Replies. Expanding it restores the grouped order and depths.
- An Outdated group's disclosure retains the same parent grouping and Draft visibility rules within that group.
- Collapsing one ReviewCard body hides body rows only. Its Replies remain in the parent's subtree.
- If a parent is absent, show the available subtree with a `parent unavailable` label. Keep its authored parent link.
- Preserve known placement information for an absent-parent subtree. Do not invent the missing parent's CommentScope or ancestors.
- Calculate relative depth from the highest available ancestor when the root is unknown. Label capped depth as known relative depth in that case.
- A known parent hidden by a disclosure is not an absent parent. Its Replies hide with that disclosure.
- During Reconciliation, a fetched Comment replaces its posted Draft representation once. Pending Replies retain the parent's effective ancestry through the posted CommentId.
- A posted Draft alias adds no extra ancestry level. Existing DraftState and mutation availability rules still apply.

### Acceptance examples

For sibling ordering, use this mixed ancestry.

```text
Root published
  A published, parent Root
    C published, parent A
      F Draft, parent C
    D Draft, parent A
  B published, parent Root
  E Draft, parent Root
    H Draft, parent E
```

The presentation order is Root, A, C, F, D, B, E, H.
B can precede C in published input order. C still appears in A's subtree before B.
The two-column unit in this example illustrates depth, not a fixed viewport rule.

The width examples use the current four-column root body inset.

| DiffPane width | Root body width | Deepest Reply | Starting unit | Chosen unit | Deepest visual indent | Deepest body width | Depth label |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 100 | 96 | 3 | 4 | 4 | 12 | 84 | Not required |
| 100 | 96 | 20 | 4 | 2 | 40 | 56 | Not required |
| 80 | 76 | 12 | 3 | 3 | 36 | 40 | Not required |
| 60 | 56 | 12 | 2 | 1 | 12 | 44 | Not required |
| 60 | 56 | 20 | 2 | 1 | 16 | 40 | Required |
| 40 | 36 | 3 | 1 | 1 | 0 | 36 | Required |

Check each breakpoint on both sides: 59 and 60, 79 and 80, 99 and 100.
Check a viewport with fewer than 40 root body columns and one with exactly 40.
Resize a mixed Thread across these widths. Its order, typed owners, and parent relationships must remain stable.
Check the complete Thread uses its deepest Reply's chosen unit, including shallower sibling subtrees.
Check Deleted Comments, absent parents, resolved disclosure, Outdated disclosure, and partial Reconciliation against the structural cases above.

### Evidence boundary

The user observed one visible Reply indentation level in the Bitbucket web UI.
This decision retains actual known ancestry in bbr. It does not claim that Cloud permits unlimited nesting.
The local model already represents nested published parent links and Draft parent links.
No Cloud API depth limit was verified in this session.

Relevant code is [the Thread builder](../../../src/review/thread.zig), [Draft parentage](../../../src/review/draft.zig), and [ReviewCard placement](../../../src/tui/buffer.zig).
This answer defines the presentation contract. Application implementation remains outside this map.
