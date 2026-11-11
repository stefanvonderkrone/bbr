# Add a symbol outline command for large Zig files

Status: needs-triage
Blocked by: none

## Problem

Agents read large source files again and again to find one declaration. A 30-day retro of the OpenCode sessions (session `ses_e38baeb9cffe00nhxrCe6jCmIf`, ranked finding 3) found these reads:

- `src/tui/presentation.zig`: 784 reads in 90 sessions. The file has 32,959 lines.
- `src/bitbucket/client.zig`: 271 reads. The file has 6,636 lines.

`docs/code-navigation.md` names the owner file for each kind of work. It does not help an agent inside a file with 33,000 lines. The agent then reads the file in slices or greps it many times.

Repeated reads show the lookup cost. They do not prove that every read was unnecessary.

## Proposal

Add a small read-only command that prints a symbol outline of a Zig file from the current checkout. The command name and its location (`tools/`, a `zig build` step, or a `bbr` dev subcommand) are open for triage.

- Input: a file path, and optionally a name pattern.
- Output for each match: the declaration kind (`fn`, `const`, `var`, `struct`, `union`, `enum`, `test`), the name, the container path (for example `Published.jumpToFileHeader`), and the line range.
- Optional: the tests in the same file that name the symbol, and a short source excerpt with a line limit.
- The command computes the outline from the source each time. It writes no line-number document that can go stale.
- Reuse `zig_files` in `tools/source_lines.py` if the command is a Python tool, as the repo rule for line checkers requires. Zig's own parser (`std.zig.Ast`) is an alternative.

## Acceptance criteria

- [ ] The command prints the outline of `src/tui/presentation.zig` with the kind, name, container path, and line range of each declaration.
- [ ] A name pattern limits the output to the matching declarations.
- [ ] A declaration's line range starts at its doc comment and ends at its closing brace or semicolon.
- [ ] The full outline of `src/tui/presentation.zig` is much smaller than the file. Triage sets the size limit.
- [ ] `docs/code-navigation.md` points to the command for large files.
- [ ] `zig build test` passes, and a test covers the outline of a small fixture file.
