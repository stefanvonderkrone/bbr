# Choose raw ReviewBody yank behavior

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: needs-info

## Question

How does the existing `y` Action copy complete authored Markdown from a ReviewCard without breaking source yank behavior?

The user accepts exploring complete-body copying from any ReviewCard row.
Choose behavior for the header, body, Suggestion label, Suggestion body, and disclosure footer.
Define precedence when a source Selection is active and the cursor moves onto a ReviewCard.
Define Count behavior and whether a body yank clears Selection.

The copied bytes come from the owning Comment or Draft, not projected ReviewBody segments.
Include whitespace, trailing newlines, Markdown fences, and emoji shortcodes in the examples.
Choose refusal behavior for a Deleted Comment, an empty body, and structural rows outside a ReviewCard.
Include source yank on adjacent Lines and explain ActionAvailability and help text.

Use the existing typed clipboard command and completion seam for acceptance examples.
The answer defines the user-visible contract, not clipboard implementation changes.
