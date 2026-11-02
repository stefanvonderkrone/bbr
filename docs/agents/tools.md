# Agent tools

The project configuration in `opencode.json` disables the inherited Atlassian, Chrome DevTools, and Confluence MCP servers at startup.
Context7 remains available for library documentation.
The `bash` rules in `opencode.jsonc` deny the commands that start bbr, such as `bbr`, `zig build run`, and `zig-out/bin/bbr`.
They also deny `zig run` and each `zig build` step that reads the Credential, such as `zig build check`.
Run `python3 tools/check_live_run_denial.py` after a change to those rules.
A new rule needs a command in its `DENIED` or `ALLOWED` list, or the check fails.
The local Markdown tracker needs no external issue service.

For a task that needs a disabled server, enable that server in OpenCode's MCP controls for the session.
Keep the project defaults unchanged for ordinary local development.

After a project configuration or skill change, quit and restart OpenCode.
The running session retains the configuration and skills that it loaded at startup.
