# Agent tools

The permissions in `opencode.jsonc` deny the tools of the inherited Atlassian, Chrome DevTools, and Confluence MCP servers.
The project does not disable the servers, because a V2 override must repeat the whole server entry of the global configuration.
Context7 remains available for library documentation.
The `shell` rules in `opencode.jsonc` deny the commands that start bbr, such as `bbr`, `zig build run`, and `zig-out/bin/bbr`.
They also deny `zig run` and each `zig build` step that reads the Credential, such as `zig build check`.
Run `python3 tools/check_live_run_denial.py` after a change to those rules.
A new rule needs a command in its `DENIED` or `ALLOWED` list, or the check fails.
The local Markdown tracker needs no external issue service.

For a task that needs one of these servers, ask the operator to allow its tools for the session.
Keep the project defaults unchanged for ordinary local development.

The `ocr-review` agent in `opencode.jsonc` runs a code review with Open Code Review. [Code review](../code-review.md) says how to install and use it.

## Configuration changes

OpenCode reloads a changed project configuration or skill without a restart.
Run `/reload` to force a full reload.
