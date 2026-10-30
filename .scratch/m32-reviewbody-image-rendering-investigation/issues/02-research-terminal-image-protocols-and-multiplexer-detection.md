# 02: Research terminal image protocols and multiplexer detection

Status: ready-for-agent
Blocked by: none
Spec: [M32 spec](../SPEC.md)

## What to build

A research note that fills the protocol matrix of the spec from specifications and source code.
The note defines the multiplexer detection rule for tmux, herdr, and the nested cases.
It also states what vaxis 0.6.0 does and what the prototype must add.

This ticket runs no terminal by hand.
Ticket 04 confirms each cell in a hands-on run.

## Scope

- Write `research/terminal-image-protocols.md` in the M32 directory.
- Read the kitty graphics protocol specification, the iTerm2 inline image documentation, and the tmux passthrough documentation.
- Read the image documentation or source code of Ghostty, kitty, WezTerm, iTerm2, and herdr.
- Read the herdr documentation for `HERDR_ENV`, `terminal.kitty_graphics`, and the public reports about stale images and slow output.
- Read the vaxis 0.6.0 source that `build.zig.zon` pins.
  Use the extracted package directory, not the tarball.
  Cover `Vaxis.queryTerminal`, `enableDetectedFeatures`, the image functions, `Image.draw`, and `Cell.image`.
- Fill every cell of the protocol matrix with `yes`, `no`, `partial`, or `unknown`, a note, and a source.
- Define the multiplexer detection rule from the "Multiplexer detection rule" section of the spec.
  Give the rule as an ordered list of checks with the result of each check.
  Cover bbr in a plain terminal, in tmux, in herdr, in tmux inside herdr, and in herdr inside tmux.
- List each side effect of `queryTerminal` on the current bbr terminal setup in `src/tui/app.zig`.
- Estimate the cost of each path that vaxis 0.6.0 lacks: the iTerm2 protocol, tmux passthrough, and kitty Unicode placeholders.
  Name the files that each path changes and whether it needs a vaxis change.
- Recommend the kitty transmission medium for each column, with the reason.

## Acceptance criteria

- [ ] `research/terminal-image-protocols.md` fills every cell of the protocol matrix, each with a source.
- [ ] The note holds the detection rule as ordered checks for the five cases in the scope.
- [ ] The detection rule reads no XDG variable.
- [ ] The note lists the side effects of `queryTerminal` for bbr.
- [ ] The note estimates the cost of the iTerm2 path, tmux passthrough, and kitty Unicode placeholders.
- [ ] The note recommends a transmission medium for each column.
- [ ] The note marks each cell that ticket 04 must check by hand.
- [ ] `python3 tools/check_agent_docs.py` passes.
