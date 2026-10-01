# Choose nested Reply presentation

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: needs-info

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
