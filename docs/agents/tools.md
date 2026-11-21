# Agent tools

The project configuration in `opencode.jsonc` disables the inherited Atlassian, Chrome DevTools, and Confluence MCP servers at startup.
Context7 remains available for library documentation.
The local Markdown tracker needs no external issue service.

For a task that needs a disabled server, enable that server in OpenCode's MCP controls for the session.
Keep the project defaults unchanged for ordinary local development.

The `ocr-review` agent in `opencode.jsonc` runs a code review with Open Code Review. [Code review](../code-review.md) says how to install and use it.

## Configuration changes

After a project configuration or skill change, quit and restart OpenCode.
The running session retains the configuration and skills that it loaded at startup.
