---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

If the user passes a ticket reference, fetch it from the issue tracker and state its title before starting. If the reference is ambiguous, ask.

Before editing, record `git rev-parse HEAD` as the starting commit and inspect `git status --short`.
Record existing changes so the review can distinguish user work from this task.
For a ticket, follow the tracker's claim operation before starting implementation.

Call the Skill tool with "tdd" where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, call the Skill tool with "code-review".
Pass the starting commit, the ticket or spec, and the existing-change inventory.
Review the final working tree, including staged changes, unstaged changes, and new files, before committing.
After review fixes, run the affected checks and review the changed scope again.
Resolve the ticket through the tracker only after its acceptance criteria and required checks pass.

Commit your work to the current branch.
