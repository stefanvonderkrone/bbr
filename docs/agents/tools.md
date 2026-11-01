# Agent tools

The project configuration in `opencode.json` disables the inherited Atlassian, Chrome DevTools, and Confluence MCP servers at startup.
Context7 remains available for library documentation.
The local Markdown tracker needs no external issue service.

For a task that needs a disabled server, enable that server in OpenCode's MCP controls for the session.
Keep the project defaults unchanged for ordinary local development.

After a project configuration or skill change, quit and restart OpenCode.
The running session retains the configuration and skills that it loaded at startup.

## Guard mutation check

`tools/check_guard_mutations.py` makes sure that the tests of a guard fail when the guard is removed.
A table in the tool lists each guard mutation.
An entry names a file, the exact guard snippet, a weaker replacement, and a `zig build` step.
The tool applies each mutation in its own scratch copy of the tree.
The tool never changes your checkout, but it uses the `.zig-cache` of your checkout.
Under a mutation, the named step must fail with a test failure.
The tool then reports `caught`.
The tool reports `SURVIVED` when the step passes.
The tool reports `BROKEN` when the mutation does not compile.
The tool also fails when a snippet does not match exactly once in its file.
CI runs the tool after `zig build test`.

Add an entry for every new guard that a ticket adds.
Run the full table with `python3 tools/check_guard_mutations.py`.
Run one entry with `python3 tools/check_guard_mutations.py --only <id>`.
The runs go in parallel, so a full run takes about four minutes on an 18-core machine.
