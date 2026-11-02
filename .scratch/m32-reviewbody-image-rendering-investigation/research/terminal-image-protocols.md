# Terminal image protocols and multiplexer detection

Research date: 2026-10-31.
Ticket: [Research terminal image protocols and multiplexer detection](../issues/02-research-terminal-image-protocols-and-multiplexer-detection.md).
Spec: [M32 spec](../SPEC.md), sections "Protocol matrix" and "Multiplexer detection rule".

This note comes from specifications, documentation, source code, and public issue reports.
Nobody ran a terminal for this note.
Ticket 04 confirms or corrects each cell in a hands-on run.

## Result

- The kitty graphics protocol is the one protocol that every target terminal with images supports.
  Ghostty, kitty, WezTerm, iTerm2, and herdr accept it. [S1] [S6] [S17] [S20] [S33]
- iTerm2 supports the kitty graphics protocol since 3.5.5beta1, except animation. [S19] [S20]
  So the brief statement "iTerm2 supports only its own protocol" is out of date.
  The iTerm2 inline image protocol (OSC 1337) adds value only for an older iTerm2.
- WezTerm accepts the kitty graphics protocol, but it does not parse Unicode placeholders (`U=1`). [S16]
- tmux forwards an image sequence only in DCS passthrough, and only with `allow-passthrough on`. [S25] [S26]
  tmux sends no terminal reply back to the application through passthrough. [S28] [S30]
  So bbr cannot detect image support inside tmux with a capability query.
- herdr parses the kitty graphics protocol in each pane and draws the images itself in the outer terminal. [S33]
  herdr answers the capability query itself, also when the outer terminal has no image protocol. [S35]
- vaxis 0.6.0 sends only direct kitty placements.
  It has no tmux passthrough, no Unicode placeholders, no `q=2`, and no iTerm2 protocol. [V1] [V6] [V9]
- bbr can add tmux passthrough and Unicode placeholders without a vaxis change.
  bbr writes its own transmit commands and paints placeholder cells as normal vaxis cells.
- The recommended transmission medium is direct data (`t=d`) in every column.

## Sources

Each source is a URL that this research read on 2026-10-31.
A V source is a file and line in the vaxis 0.6.0 package.

| Id | Source |
| --- | --- |
| S1 | kitty graphics protocol specification, <https://sw.kovidgoyal.net/kitty/graphics-protocol/>. Sections "The transmission medium", "Querying support and available transmission mediums", "Unicode placeholders", "Deleting images", "Interaction with other terminal actions". The page lists kitty 0.49.2 as the latest release. |
| S2 | kitty glossary, environment variables, <https://sw.kovidgoyal.net/kitty/glossary/>. `TERM` is `xterm-kitty`. kitty sets `KITTY_WINDOW_ID` and `KITTY_PID`. |
| S3 | kitty FAQ, "I am using tmux/zellij and have a problem", <https://sw.kovidgoyal.net/kitty/faq/>. |
| S4 | kitty keyboard protocol, <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>. "Terminals must maintain separate stacks for the main and alternate screens." |
| S5 | kitty `kitty/vt-parser.c`, <https://raw.githubusercontent.com/kovidgoyal/kitty/master/kitty/vt-parser.c>, lines 591 to 597. OSC 1337 goes to `desktop_notify`, not to an image path. |
| S6 | Ghostty `src/terminal/kitty/graphics_image.zig`, <https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/terminal/kitty/graphics_image.zig>, lines 79 to 105 (medium limits), 160 to 190 (PNG decoder and medium dispatch), 502 to 520 (temporary file directory check). |
| S7 | Ghostty `src/termio/Termio.zig`, <https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/termio/Termio.zig>, lines 294 to 295 and 512. The terminal enables every medium with `allWithTempDir`. |
| S8 | Ghostty `src/terminal/kitty/graphics_unicode.zig`, <https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/terminal/kitty/graphics_unicode.zig>, lines 1 to 30. Placeholder `0x10EEEE` and virtual placements. |
| S9 | Ghostty `graphics_command.zig` line 1103 (`d=i` and `d=I`), and `graphics_exec.zig` lines 70 to 72, 156, and 982 (query and delete), in <https://github.com/ghostty-org/ghostty/tree/main/src/terminal/kitty>. |
| S10 | Ghostty `src/termio/Exec.zig`, <https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/termio/Exec.zig>, lines 639 to 666 (`TERM`, `GHOSTTY_RESOURCES_DIR`), 755 to 756 (`TERM_PROGRAM=ghostty`), 913 (`ws_xpixel`). The latest tag is v1.4.0. |
| S11 | Ghostty `src/terminal/osc/parsers/iterm2.zig`, <https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/terminal/osc/parsers/iterm2.zig>, lines 169 to 195. `File`, `FilePart`, and `MultipartFile` are "unimplemented OSC 1337". |
| S12 | Ghostty configuration reference, `image-storage-limit`, <https://ghostty.org/docs/config/reference>. The limit is separate for the primary and the alternate screen. |
| S13 | Ghostty `src/terminal/dcs.zig`, <https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/terminal/dcs.zig>, lines 53 to 73. Ghostty knows only tmux control mode (`ESC P 1000 p`), not `ESC P tmux;` passthrough. |
| S14 | WezTerm "iTerm Image Protocol", <https://wezterm.org/imgcat.html>. |
| S15 | WezTerm `config/src/config.rs`, <https://raw.githubusercontent.com/wezterm/wezterm/main/config/src/config.rs>, lines 256 to 257 (`enable_kitty_graphics` defaults to true) and 1619 to 1622 (`TERM_PROGRAM=WezTerm`). |
| S16 | WezTerm `wezterm-escape-parser/src/apc.rs`, <https://raw.githubusercontent.com/wezterm/wezterm/main/wezterm-escape-parser/src/apc.rs>, lines 107 to 125 (media `d`, `f`, `t`, `s`), 488 to 494 (formats 24, 32, 100), 626 to 645 (placement keys, no `U`). |
| S17 | WezTerm `term/src/terminalstate/kitty.rs`, <https://raw.githubusercontent.com/wezterm/wezterm/main/term/src/terminalstate/kitty.rs>, lines 174 to 272. Query, delete by id, and delete all are handled. Other delete forms log "unhandled". |
| S18 | WezTerm `pty/src/unix.rs`, <https://raw.githubusercontent.com/wezterm/wezterm/main/pty/src/unix.rs>, lines 29 and 184 (`ws_xpixel`). |
| S19 | iTerm2 "Inline Images Protocol", <https://iterm2.com/documentation-images.html>. "iTerm2 also supports the Kitty graphics protocol." The page also gives the tmux size limits for `MultipartFile`. |
| S20 | iTerm2 3.5.5beta1 change log, <https://iterm2.com/downloads/beta/iTerm2-3_5_5beta1.changelog>. "Add support for the Kitty graphics protocol (except animation)." The file header reads "3.5.4beta2, built on September 9, 2024". |
| S21 | iTerm2 `sources/InlineImages/KittyImageCommand.swift`, <https://raw.githubusercontent.com/gnachman/iTerm2/master/sources/InlineImages/KittyImageCommand.swift>, lines 24 to 46 (actions, `f=100`, media), 134 to 178 (`U` key), 304 to 322 (delete keys). |
| S22 | iTerm2 `sources/InlineImages/KittyImageController.swift`, <https://raw.githubusercontent.com/gnachman/iTerm2/master/sources/InlineImages/KittyImageController.swift>, lines 526 to 534 (media dispatch) and 1302 (`d=i`, `d=I`). |
| S23 | iTerm2 `sources/PTYSession/PTYSession.m`, <https://raw.githubusercontent.com/gnachman/iTerm2/master/sources/PTYSession/PTYSession.m>, lines 3606 and 3628 to 3631. |
| S24 | iTerm2 full change log, <https://iterm2.com/appcasts/full_changes.txt>. The latest build is 3.7.6, October 15, 2026. |
| S25 | tmux manual page, `allow-passthrough`, <https://man7.org/linux/man-pages/man1/tmux.1.html>. |
| S26 | tmux FAQ, "What is the passthrough escape sequence and how do I use it?", <https://github.com/tmux/tmux/wiki/FAQ>. "Any `\033` characters in the wrapped sequence must be doubled." |
| S27 | tmux CHANGES, <https://raw.githubusercontent.com/tmux/tmux/master/CHANGES>. Line 1432 (3.2 exports `TERM_PROGRAM`), 1076 (3.3 adds the passthrough option), 1027 (`all`), 1687 (3.1 sets `xpixel` and `ypixel`), 831 (3.6 queries the outer pixel size), 946 (3.4 SIXEL). The top section is "3.7c to 3.8". |
| S28 | tmux issue 5530, <https://github.com/tmux/tmux/issues/5530>. The maintainer writes "there is no passthrough for query responses, passthrough is pretty much one way". |
| S29 | crush issue 3500, <https://github.com/charmbracelet/crush/issues/3500>. A kitty reply that comes back through tmux arrives as single key presses, such as `Gi=31;OK`. |
| S30 | twitch-tui issue 685, <https://github.com/Xithrius/twitch-tui/issues/685>. The kitty author writes "You cannot check for graphics protocol support inside tmux" and "you have to use unicode placeholders". |
| S31 | pi-mono issue 2374, <https://github.com/badlogic/pi-mono/issues/2374>. Direct placements in tmux leak into adjacent panes. Unicode placeholders fix it. |
| S32 | opentui pull request 415, <https://github.com/anomalyco/opentui/pull/415>. A bare kitty APC sequence in tmux leaks into the pane title. |
| S33 | herdr source at commit `ee5bfb5` (version 0.9.5), <https://github.com/herdrdev/herdr>. Files: `src/pane.rs` lines 72 to 76 and 99 to 134 (pane environment), `src/pty/backend/unix.rs` line 77 (`HERDR_ENV`), `crates/ghostty-vt/src/lib.rs` lines 34 (`TERM`) and 1074 to 1108 (pane media), `src/kitty_graphics.rs` line 22 (3072-byte chunks), `src/client/image_files.rs` lines 73 to 100 (`t=t` only for a local Ghostty client), `src/pty/fd.rs` lines 222 to 236 (`ws_xpixel`), `src/config/model.rs` lines 2044 to 2066 (graphics on by default), `src/platform/macos.rs` line 872 (`Apple_Terminal`), `CHANGELOG.md` lines 46, 94, 159, 199, 853. |
| S34 | herdr issue 1843, <https://github.com/herdrdev/herdr/issues/1843>. Before 0.9.0, kitty graphics was an opt-in experiment. |
| S35 | herdr open and closed issues, read through <https://api.github.com/repos/herdrdev/herdr/issues>: 5295 (Terminal.app shows raw kitty text), 5116 (no images when the herdr client runs inside tmux), 5512 (slow images in iTerm2 and WezTerm), 5614 (placeholder images missing after a pane switch), 3877 (stop-motion scroll), 5705 (placement survives app exit), 4858 (placeholder images stretched), 3941 (no images in iTerm2), 5468 (query says OK, no image, closed), 3697 (`t=d` accepted but not painted on 0.8.2). |
| S36 | terminfo.dev, <https://terminfo.dev/extensions/kitty-graphics-protocol>. Low trust. It reports Terminal.app as a kitty graphics terminal and kitty as a terminal without Unicode placeholders. S1 and S35 contradict both claims. |
| S37 | In-band resize specification (mode 2048), <https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83>. "When first enabled, the terminal MUST send a report of the current size." |
| S38 | kitty row and column diacritics, <https://sw.kovidgoyal.net/kitty/_downloads/f0a0de9ec8d9ff4456206db8e0814937/rowcolumn-diacritics.txt>. The file lists 297 code points. |

The vaxis sources are files in the extracted package `vaxis-0.6.0-BWNV_Gz5CQBTx7g34RYMPTL-bJhsFCU3ECHQ-CZlBVsn/src`.

| Id | vaxis 0.6.0 location |
| --- | --- |
| V1 | `Vaxis.zig:257-275` `queryTerminal`, `Vaxis.zig:278-327` `queryTerminalSend`. The kitty query is `ESC _ G i=1,a=q ESC \` (`ctlseqs.zig:12`), followed by DA1 (`Vaxis.zig:320-321`). |
| V2 | `Vaxis.zig:329-370` `enableDetectedFeatures`. It reads `TERMUX_VERSION`, `VHS_RECORD`, `TERM_PROGRAM` (only `vscode`), and three `VAXIS_FORCE_*` variables. |
| V3 | `Vaxis.zig:32-42` `Capabilities`. Every capability starts false. |
| V4 | `Loop.zig:386-419`. A reply sets each capability. Any `ESC _ G` reply sets `kitty_graphics` (`Parser.zig:197-200`). DA1 wakes the query futex. |
| V5 | `Vaxis.zig:928-985` `transmitLocalImagePath`, `Vaxis.zig:987-1043` `transmitPreEncodedImage`, `Vaxis.zig:1045-1079` `transmitImage`, `Vaxis.zig:1081-1097` `loadImage`, `Vaxis.zig:1099-1106` `freeImage`. Each transmit returns `error.NoGraphicsCapability` while `caps.kitty_graphics` is false. |
| V6 | `Vaxis.zig:411-441` `startRender`. Each render that writes anything sends `ESC _ G a=d ESC \` first, when `caps.kitty_graphics` is true. |
| V7 | `Vaxis.zig:484-489`. A cell with an image never counts as unchanged. |
| V8 | `Vaxis.zig:550-581`. The placement is `ESC _ G a=p,i=<id>` with optional `X`, `Y`, `x`, `y`, `w`, `h`, `r`, `c`, `z`, and the end `,C=1 ESC \` (`ctlseqs.zig:141-143`). |
| V9 | `Image.zig:87-169` `Image.draw`. It writes one `Cell.image` placement at cell (0, 0) of the window. `Cell.zig:7` holds `image: ?Image.Placement`. |
| V10 | `InternalScreen.zig:27-36` and `InternalScreen.zig:80-110`. The last-frame screen does not store the image of a cell. |
| V11 | `Window.zig:177-187` `writeCell`. A cell outside the window is dropped. |
| V12 | `Vaxis.zig:194-224` `resize`. It makes a new last-frame screen, so the next render repaints every cell. |
| V13 | `Vaxis.zig:134-187` `resetState`. It pops the kitty keyboard flags and resets mouse, paste, color scheme, mode 2048, and colors. It does not reset mode 2027. |
| V14 | `Vaxis.zig:885-904` `setMouseMode` and `Vaxis.zig:906-925` `translateMouse`. With `caps.sgr_pixels`, mouse mode uses pixel reports (mode 1016). |
| V15 | `Key.zig:25-31` `KittyFlags`. The default is disambiguate, alternate keys, all keys as escape codes, and associated text. |

A search for `tmux`, `TMUX`, `passthrough`, and `Ptmux` in the vaxis `src` directory finds nothing.

## Protocol matrix

The value of each cell is `yes`, `no`, `partial`, or `unknown`.
A note and a source id follow the value.
**T04** marks each cell that ticket 04 must check by hand.

The columns are the SPEC columns.
"No protocol" also covers every terminal that bbr cannot identify.

| Row | Ghostty | kitty | WezTerm | iTerm2 | tmux in Ghostty | tmux in iTerm2 | herdr in Ghostty | herdr in kitty | No protocol (Apple Terminal) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Tested version | `unknown`. Not run. Source read on main. Latest tag v1.4.0. [S10] **T04** | `unknown`. Not run. Docs list 0.49.2. [S1] **T04** | `unknown`. Not run. Source read on main. [S15] **T04** | `unknown`. Not run. Latest build 3.7.6. [S24] **T04** | `unknown`. Not run. CHANGES top is 3.8. [S27] **T04** | `unknown`. Not run. Same tmux source. [S27] **T04** | `unknown`. Not run. herdr 0.9.5 source. [S33] **T04** | `unknown`. Not run. herdr 0.9.5 source. [S33] **T04** | `unknown`. Not run. No source code. **T04** |
| kitty graphics protocol | `yes`. Full implementation. [S6] [S7] | `yes`. Reference implementation. [S1] | `yes`. On by default with `enable_kitty_graphics`. [S15] [S17] | `yes`. Since 3.5.5beta1, without animation. [S19] [S20] [S21] **T04** | `partial`. Only in passthrough. tmux does not track the images. [S25] [S30] **T04** | `partial`. Only in passthrough. [S25] [S30] **T04** | `yes`. herdr parses and redraws the images. On by default. [S33] **T04** | `yes`. Same herdr path. [S33] **T04** | `no`. herdr issue 5295 reports no support. S36 says yes, with low trust. [S35] [S36] **T04** |
| kitty transmission by direct data (`t=d`) | `yes`. [S6] | `yes`. The default medium. [S1] | `yes`. [S16] | `yes`. [S21] | `partial`. Each chunk needs the passthrough wrapper and `q=2`. [S26] [S29] **T04** | `partial`. Same as tmux in Ghostty. [S26] [S29] **T04** | `yes`. herdr forwards the pixels to the outer terminal. Issue 3697 shows a failure on 0.8.2. [S33] [S35] **T04** | `yes`. Same herdr path. [S33] **T04** | `no`. No protocol. |
| kitty transmission by file or temp file (`t=f`, `t=t`) | `yes`. Every medium is on. The file must be on the terminal host. [S6] [S7] | `yes`. Only for a local client. [S1] | `yes`. The parser accepts `f`, `t`, `s`. [S16] **T04** | `yes`. [S21] [S22] **T04** | `partial`. Only when bbr and Ghostty share a host. Not checked through tmux. [S1] **T04** | `partial`. Same as tmux in Ghostty. [S1] **T04** | `yes`. The herdr pane accepts file, temp file, and shared memory. [S33] **T04** | `yes`. Same herdr path. [S33] **T04** | `no`. No protocol. |
| kitty PNG payload (`f=100`) | `yes`. libghostty needs a PNG decoder hook. [S6] **T04** | `yes`. [S1] | `yes`. [S16] | `yes`. [S21] | `partial`. The outer terminal decodes. [S1] **T04** | `partial`. The outer terminal decodes. [S21] **T04** | `yes`. herdr installs a PNG decoder. [S33] | `yes`. Same herdr path. [S33] | `no`. No protocol. |
| kitty Unicode placeholders (`U=1`) | `yes`. [S8] **T04** | `yes`. Since 0.28.0. [S1] | `no`. The placement parser reads no `U` key. [S16] **T04** | `yes`. The parser reads `U`. [S21] **T04** | `yes`. Placeholders are text, so tmux moves them. [S30] [S31] **T04** | `partial`. Depends on iTerm2 placeholder rendering. [S21] [S31] **T04** | `partial`. herdr renders them. Issues 4858 and 5614 are open. [S33] [S35] **T04** | `partial`. Same herdr path. [S35] **T04** | `no`. No protocol. |
| kitty delete by id (`a=d,d=I`) | `yes`. [S9] | `yes`. [S1] | `yes`. [S17] | `yes`. [S21] [S22] | `partial`. Needs the passthrough wrapper. [S26] **T04** | `partial`. Needs the passthrough wrapper. [S26] **T04** | `partial`. Issue 5705 loses a delete at app exit. [S35] **T04** | `partial`. Same herdr path. [S35] **T04** | `no`. No protocol. |
| kitty capability query reply | `yes`. [S9] | `yes`. [S1] | `yes`. [S17] | `yes`. Action `q`. [S21] **T04** | `no`. tmux sends no reply back. A leaked reply arrives as keys. [S28] [S29] [S30] | `no`. Same as tmux in Ghostty. [S28] [S29] | `yes`. herdr answers, not Ghostty. [S33] [S35] **T04** | `yes`. herdr answers, not kitty. [S33] [S35] **T04** | `no`. Expect only the DA1 reply. **T04** |
| iTerm2 inline image protocol (OSC 1337) | `no`. `File` is unimplemented. [S11] | `no`. OSC 1337 goes to notifications. [S5] | `yes`. [S14] | `yes`. [S19] | `no`. Ghostty does not implement it. [S11] | `partial`. Needs passthrough and `MultipartFile` chunks. [S19] [S26] **T04** | `no`. herdr uses libghostty. [S11] [S33] | `no`. herdr uses libghostty. [S11] [S33] | `unknown`. No source. **T04** |
| Cell pixel size from the window size | `yes`. Ghostty sets `ws_xpixel`. [S10] **T04** | `yes`. The spec names `TIOCGWINSZ`. [S1] **T04** | `yes`. [S18] **T04** | `unknown`. No source found. **T04** | `yes`. tmux sets pixel sizes since 3.1. [S27] **T04** | `unknown`. Depends on iTerm2. [S27] **T04** | `yes`. herdr sets `ws_xpixel` from the host cell size. [S33] **T04** | `yes`. Same herdr path. [S33] **T04** | `unknown`. No source. **T04** |
| Image stays correct after a scroll | `yes`. Guess. vaxis deletes and places every image again on each render. [V6] [V8] **T04** | `yes`. Guess. Same vaxis behavior. [V6] **T04** | `yes`. Guess. Same vaxis behavior. [V6] **T04** | `unknown`. **T04** | `partial`. Direct placements do not move with tmux. Placeholders do. [S31] **T04** | `partial`. Same as tmux in Ghostty. [S31] **T04** | `partial`. Issue 3877 reports stop-motion scroll. [S35] **T04** | `partial`. Same herdr path. [S35] **T04** | `no`. No image. bbr shows text. |
| Image stays correct after a resize | `yes`. Guess. `resize` forces a full repaint. [V12] **T04** | `yes`. Guess. [V12] **T04** | `yes`. Guess. [V12] **T04** | `unknown`. **T04** | `partial`. tmux redraws placeholders. Direct placements stay stale. [S31] **T04** | `partial`. Same as tmux in Ghostty. [S31] **T04** | `unknown`. **T04** | `unknown`. **T04** | `no`. No image. bbr shows text. |
| No stale image copy after an Overlay closes | `partial`. A direct image covers the Overlay unless bbr drops the image cell. Placeholders do not. [V8] [V9] [S1] **T04** | `partial`. Same as Ghostty. [V9] [S1] **T04** | `partial`. Same as Ghostty. [V9] **T04** | `unknown`. **T04** | `partial`. Placeholders only. [S31] **T04** | `partial`. Placeholders only. [S31] **T04** | `partial`. herdr hides only the overlapped part under its popups. Issue 5705 is open. [S33] [S35] **T04** | `partial`. Same herdr path. [S35] **T04** | `no`. No image. bbr shows text. |
| Passthrough setting needed | `no`. | `no`. | `no`. The default `enable_kitty_graphics` is true. [S15] | `no`. | `yes`. `set -g allow-passthrough on`, tmux 3.3 or later. [S25] [S26] [S27] | `yes`. Same tmux setting. [S25] [S26] | `no`. herdr has no passthrough. `terminal.kitty_graphics` must stay true. [S33] | `no`. Same as herdr in Ghostty. [S33] | `no`. |
| Environment values that identify it | `yes`. `TERM_PROGRAM=ghostty`, `TERM=xterm-ghostty`, `GHOSTTY_RESOURCES_DIR`. [S10] | `yes`. `TERM=xterm-kitty`, `KITTY_WINDOW_ID`, `KITTY_PID`. [S2] | `yes`. `TERM_PROGRAM=WezTerm`, `WEZTERM_PANE`. [S15] [S33] | `yes`. `TERM_PROGRAM=iTerm.app`, `LC_TERMINAL=iTerm2`, `ITERM_SESSION_ID`. [S23] | `partial`. `TMUX`, `TMUX_PANE`, `TERM_PROGRAM=tmux`. The outer terminal is hidden. [S25] [S27] | `partial`. Same as tmux in Ghostty. [S27] | `partial`. `HERDR_ENV=1`, `TERM_PROGRAM=herdr`, `TERM=xterm-256color`. herdr removes the outer identity. [S33] | `partial`. Same as herdr in Ghostty. [S33] | `yes`. `TERM_PROGRAM=Apple_Terminal`. [S33] **T04** |
| vaxis 0.6.0 path works without change | `yes`. bbr must turn on the capability. [V1] [V5] **T04** | `yes`. [V5] **T04** | `yes`. vaxis uses only `a=d`, `a=p`, and `d=I`. [S17] [V6] [V8] **T04** | `partial`. Kitty support without animation. No source shows the vaxis placement form in iTerm2. [S20] **T04** | `no`. vaxis writes no wrapper and no `q=2`. [V5] [V8] | `no`. Same as tmux in Ghostty. [V5] | `partial`. herdr parses vaxis placements. Several herdr issues are open. [S35] **T04** | `partial`. Same herdr path. [S35] **T04** | `no`. No protocol. |
| Selected path for the prototype | `yes`. kitty, `t=d`. Compare direct placement with placeholders. | `yes`. kitty, `t=d`. Compare direct placement with placeholders. | `yes`. kitty direct placement through vaxis, `t=d`. | `yes`. kitty direct placement, `t=d`. Try placeholders. **T04** | `yes`. kitty placeholders, bbr transmit with `q=2` in passthrough, `t=d`. Opt-in only. **T04** | `partial`. Same as tmux in Ghostty, if iTerm2 renders placeholders. **T04** | `yes`. kitty direct placement through vaxis, `t=d`. Compare placeholders. **T04** | `yes`. Same as herdr in Ghostty. **T04** | `no`. M23 text fallback. |

### Notes on the matrix

- The scroll, resize, and Overlay rows describe bbr with vaxis, not the terminal alone.
  vaxis re-places each image on each render, so the terminal never scrolls a placement itself. [V6] [V8]
- A kitty placement with no `z` key draws above the text. [S1]
  `Image.draw` writes only cell (0, 0), and the image covers the cells to its right and below. [V9]
  So an Overlay over a direct image shows the image on top, until bbr stops drawing that image cell.
- A placeholder image belongs to its text cells. [S1]
  An Overlay that paints over the cells hides the image, and no delete command is necessary.
- Entering the alternate screen clears all images in it. [S1]
- The prototype builds no Unicode placeholders (ticket 03).
  So the hands-on run cannot test the selected tmux path.
  In the tmux columns, these rows are `not tested` for kitty placement: `kitty Unicode placeholders (U=1)`, `Image stays correct after a scroll`, `Image stays correct after a resize`, `No stale image copy after an Overlay closes`, and `Selected path for the prototype`.
  A tmux run uses two panes, so the run shows the known pane leak of a direct placement. [S31]
  Ghostty keeps image storage separate for each screen. [S12]
  So External Edit leaves the alternate screen and enters it again, and bbr must transmit its images again.
- Sixel is not a target.
  tmux 3.4 and later supports SIXEL when tmux is built with `--enable-sixel`. [S27]
  iTerm2 has a Sixel decoder file in the commit that added kitty graphics. Source: the search result for iTerm2 commit `4fe5b21`.
  This research did not check Sixel in the other terminals.

## Multiplexer detection rule

The rule reads four environment variables and at most one terminal reply.
It reads no variable that `src/xdg.zig` owns.
It never reads `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, or `XDG_STATE_HOME`.

### Facts from the sources

- tmux sets `TMUX` in each pane. tmux 3.2 and later sets `TERM_PROGRAM=tmux`. [S25] [S27]
- herdr sets `HERDR_ENV=1` and `TERM_PROGRAM=herdr` in each pane. [S33]
- herdr removes `TMUX`, `TMUX_PANE`, `ITERM_SESSION_ID`, `LC_TERMINAL`, `WEZTERM_PANE`, `KITTY_WINDOW_ID`, and others from each pane. [S33]
  herdr 0.9.2 (issue 4104) added `TERM_PROGRAM=herdr` and the removal of outer session ids. [S33]
  This research did not find the first version that removes `TMUX`. **T04**
  With this removal, a `TMUX` value in a herdr pane always comes from a tmux inside herdr.
- tmux does not unset `HERDR_ENV` in its panes.
  A tmux server that starts in a herdr pane passes `HERDR_ENV=1` to its panes.
  Guess from the tmux `update-environment` behavior [S25]. **T04**
- tmux answers DA1 itself, and no reply comes back through passthrough. [S28] [S30]
  A bare kitty APC sequence in tmux can leak into the pane title. [S32]
- herdr answers the kitty query from its own pane terminal. [S33]
  It answers when `terminal.kitty_graphics` is on, also for an outer terminal without images. [S35]
  It sends no answer when the setting is off, since 0.9.4. [S33]

### Ordered checks

The checks run once, at start, after `enterAltScreen`.
The environment checks run first. The terminal reply check runs last.

1. **`TMUX` is set and not empty.**
   Result: the innermost multiplexer is tmux. Go to check 5.
2. **`HERDR_ENV` is `1`.**
   Result: the innermost multiplexer is herdr. Go to check 6.
3. **`TERM_PROGRAM` is `tmux`, or `TERM` starts with `tmux` or `screen`.**
   This case means tmux or GNU screen without `TMUX`, for example after `ssh` or `sudo`.
   Result: an unknown multiplexer. bbr uses no image protocol. Stop.
4. **No check above matched.**
   Result: a plain terminal. Go to check 6.
5. **tmux: the operator opts in.**
   The prototype reads `BBR_M32_TMUX_IMAGES=1`.
   The value states that `allow-passthrough` is on and that the outer terminal supports kitty Unicode placeholders.
   bbr sends no capability query in tmux.
   Result with opt-in: kitty Unicode placeholders with the tmux passthrough wrapper. Stop.
   Result without opt-in: no image protocol. Stop.
6. **Plain terminal or herdr: send the capability query.**
   bbr writes `ESC _ G i=31,s=1,v=1,a=q,t=d,f=24;AAAA ESC \` and then DA1, `ESC [ c`.
   It waits for the DA1 reply, with a timeout of 1 second.
   Result when a kitty reply comes before the DA1 reply: kitty. Go to check 7.
   Result when only the DA1 reply comes: no image protocol. Stop.
   Result on a timeout: no image protocol. Stop.
7. **Placement form.**
   Result for `TERM_PROGRAM=WezTerm`: direct placement, because WezTerm has no `U=1`. [S16]
   Result for every other terminal: the prototype switch `BBR_M32_PLACEMENT` selects `direct` or `placeholder`.
   The default is `direct`, because it is the vaxis path.

### Result for each case

| Case | Check 1 | Check 2 | Check 3 | Check 5 or 6 | Result |
| --- | --- | --- | --- | --- | --- |
| Plain terminal, such as Ghostty | No `TMUX` | No `HERDR_ENV` | No match | The terminal answers the query | kitty, direct placement or placeholders |
| Plain terminal without images, such as Apple Terminal | No `TMUX` | No `HERDR_ENV` | No match | Only DA1 answers | No image protocol. M23 text fallback. **T04** |
| tmux | `TMUX` set | Not read | Not read | No query. Opt-in decides | Opt-in: placeholders in passthrough. Else no image protocol. **T04** |
| herdr | No `TMUX`, because herdr removes it | `HERDR_ENV=1` | Not read | herdr answers the query | kitty, direct placement. Placeholders for comparison. **T04** |
| tmux inside herdr | `TMUX` set | Not read, but `HERDR_ENV=1` is also present | Not read | No query. Opt-in decides | tmux unwraps the passthrough and writes the kitty sequence into the herdr pane. herdr then parses it. Guess. **T04** |
| herdr inside tmux | No `TMUX`, because herdr removes it | `HERDR_ENV=1` | Not read | herdr answers the query | bbr sends kitty. The herdr client writes kitty sequences into tmux without a wrapper, so tmux drops them. No image shows. herdr issue 5116. [S35] **T04** |

### Result when the checks disagree

| Disagreement | Result | Reason |
| --- | --- | --- |
| Plain terminal, and `TERM_PROGRAM` names a kitty terminal, but no kitty reply comes. | No image protocol. | The reply wins. For example, WezTerm can have `enable_kitty_graphics = false`. [S15] |
| Plain terminal, and `TERM_PROGRAM` names no kitty terminal, but a kitty reply comes. | kitty. | The reply wins. `TERM_PROGRAM` can come from a different outer terminal, for example over `ssh`. |
| `TMUX` is set, and `TERM_PROGRAM` names the outer terminal. | tmux. | The environment wins. bbr sends no query, because tmux returns no reply. [S28] |
| `TMUX` and `HERDR_ENV=1` are both set. | tmux. | herdr 0.9.5 removes `TMUX`, so tmux is the inner multiplexer. [S33] |
| `HERDR_ENV=1`, but `TERM_PROGRAM` is not `herdr`. | herdr. | herdr before 0.9.2 keeps the outer `TERM_PROGRAM`. [S33] |
| `HERDR_ENV=1`, but no kitty reply comes. | No image protocol. | `terminal.kitty_graphics` is off. [S33] |
| `HERDR_ENV=1`, a kitty reply comes, but the outer terminal has no image protocol. | kitty, as the default. | bbr cannot see the outer terminal, because herdr removes its identity. herdr then writes raw text into the outer terminal (issue 5295). [S35] Ticket 05 decides if herdr needs an opt-in. **T04** |
| `TMUX` is set, and an older herdr outside it does not remove `TMUX`. | tmux. | The rule cannot tell this case apart. The passthrough goes to herdr, and libghostty does not unwrap `ESC P tmux;`. [S13] No image shows. |

## Side effects of `queryTerminal` and `enableDetectedFeatures`

`src/tui/app.zig` calls neither function today.
It calls `vaxis.init`, `loop.start`, `installResizeHandler`, `enterAltScreen`, and `setMouseMode`.
So every capability in `vx.caps` stays false. [V3]

`queryTerminal` writes all queries in one block, and `enableDetectedFeatures` turns on what the replies report. [V1] [V2]
A call after `loop.start` and `enterAltScreen` has these effects on bbr:

| Effect | Cause | Consequence for bbr |
| --- | --- | --- |
| Startup waits for DA1 or the timeout. | `queryTerminal` waits on `query_futex`. [V1] | The first frame comes later. DA1 replies are usually fast. **T04** |
| Mode 2048 turns on, with no capability check. | `in_band_resize_set` is in the query block. [V1] | The terminal sends a size report at once. [S37] The Loop then removes the SIGWINCH handler. [V4] An External Edit leaves mode 2048 on, so the editor gets size reports as input. If the editor turns mode 2048 off, bbr gets no more resize events. Guess. **T04** |
| The cursor goes home, and bbr writes two OSC 66 queries and two cursor position requests. | Explicit width and scaled text detection. [V1] | A late cursor position reply arrives as Shift+F3 or Alt+F3 after the timeout. Guess. **T04** |
| The kitty keyboard protocol turns on when the terminal reports it. | `enableKittyKeyboard` with the default flags. [V2] [V15] | Every key comes as a CSI u sequence. The Keymap must still match each key. External Edit must pop the flags before it leaves the alternate screen and push them after it returns. [S4] **T04** |
| Mode 2027 turns on when the terminal reports it, and `explicit_width` is false. | `unicode_set`. [V2] | `resetState` does not reset mode 2027, so the mode stays on after bbr exits. [V13] **T04** |
| Pixel mouse reports turn on when the terminal reports mode 1016. | `caps.sgr_pixels` changes `setMouseMode`. [V14] | `translateMouse` converts pixels to cells. With a 0 pixel size, it returns pixel values as cells, so clicks land on wrong cells. **T04** |
| Wide characters use OSC 66 when the terminal supports explicit width. | `caps.explicit_width`. [V1] | The output of each wide grapheme grows. bbr already forces the `unicode` width method. |
| Secondary cursors are reset on each visible-cursor render. | `caps.multi_cursor`. | bbr hides the cursor in most states. Small cost. |
| Each render starts with `ESC _ G a=d ESC \`. | `caps.kitty_graphics`. [V6] | Seven more bytes on each render. In herdr, each render deletes and adds all placements again. Issue 3676 reports flicker from this pattern. [S35] **T04** |
| Each placement without `q=2` makes the terminal reply `OK`. | vaxis never writes `q`. [V5] [V8] | The Loop swallows the replies. [V4] In tmux, a reply would arrive as key presses. [S29] |
| In tmux, the bare kitty query can change the pane title. | The query has no passthrough wrapper. [S32] | Do not call `queryTerminal` in tmux. **T04** |
| Color scheme reports stay off. | bbr does not subscribe. | No effect. |

The prototype needs only the kitty capability, not the other features.
So the conservative choice is a kitty-only probe.
bbr writes the query from check 6 and DA1 itself, then waits on `vx.query_futex`. [V4]
The Loop sets `vx.caps.kitty_graphics` from the reply and wakes the futex on DA1. [V4]
bbr does not call `enableDetectedFeatures`.
This choice has no effect from the table except the rows for `a=d` and `OK` replies.
The probe needs no vaxis change, because `query_futex` and `caps` are public fields. [V3]

## Cost of the paths that vaxis 0.6.0 lacks

| Path | Files the prototype changes | vaxis change | Estimate |
| --- | --- | --- | --- |
| kitty direct placement (plain terminal and herdr) | `src/tui/app.zig` (probe, transmit, free, re-transmit after External Edit). `src/tui/render.zig` (call `Image.draw` in the ReviewCard content rect, drop the image cell under an Overlay, clip a partly visible image). `src/tui/presentation.zig` (image state as data). `src/tui/buffer.zig` or `src/tui/review_card.zig` (image rows). | No. | Small. The vaxis API covers transmit, place, and free. [V5] [V8] [V9] |
| tmux passthrough | A new `src/tui/passthrough.zig` with one function that wraps one complete sequence. `src/tui/app.zig` writes each bbr-owned kitty sequence through it. | No. bbr writes its own transmit and delete with `q=2`. vaxis writes no kitty bytes while `caps.kitty_graphics` stays false. | Small, about 40 lines and one test. It needs the placeholder path, because tmux cannot place a direct image in the pane. [S31] |
| kitty Unicode placeholders | A new `src/tui/kitty_placeholder.zig` with the row and column diacritics table and the cell encoder. `src/tui/render.zig` writes placeholder cells. `src/tui/app.zig` writes `a=t` and `a=p,U=1` with `q=2`. | No. A placeholder cell is a normal `Cell` with `char.width = 1`, so vaxis does not measure it. The image id goes in the foreground color. | Medium. The diacritics table has 297 entries. [S38] Ids above 255 need 24-bit color or the third diacritic. tmux can reduce 24-bit color to 256 colors, so ids 1 to 255 with `38;5;N` are safer. [S1] **T04** |
| iTerm2 inline images (OSC 1337) | A new emitter module. `src/tui/app.zig` writes the image after `vx.render` at an absolute cursor position. `src/tui/render.zig` reserves the cells. | No, but the path works against the vaxis diff renderer. | Large. The protocol has no image id, so each move sends the whole file again. bbr must force a repaint of the covered cells. iTerm2 3.5.5 and later supports kitty graphics, so the path helps only an older iTerm2. [S19] [S20] Recommendation: record the estimate and do not build it. |

### Gotchas in the vaxis image path

- `Image.draw` places the image only at cell (0, 0) of its window. [V9]
  `Window.writeCell` drops a cell outside the window. [V11]
  So an image whose top row scrolls above the DiffPane disappears completely.
  To show the lower part, bbr places the image at the first visible row and sets `clip_region.y` in pixels.
- A direct image can extend past the bottom of the DiffPane and cover the status.
  bbr prevents this with `size.rows` and `clip_region.height`.
- The last-frame screen does not store the image of a cell. [V10]
  If bbr removes an image cell and no other cell changes, no render starts, and the old placement stays.
  In practice the card cell under the image differs from the image cell. **T04**
- `loadImage` decodes the image with `zigimg` and encodes it again as PNG. [V5]
  For a PNG body, `transmitPreEncodedImage` with `.png` and the base64 of the original bytes skips the decode in bbr.
  bbr still reads the PNG header for the dimension limit.
- `Image.draw` with `fit` divides by the screen pixel size. [V9]
  With a 0 pixel size, `cellSize` returns 0 rows and 0 columns.
  The prototype uses the cell ratio from the SPEC, a cell twice as high as wide.
- Any `ESC _ G` reply sets `caps.kitty_graphics`, also after the probe. [V4]
  With the placeholder path, bbr sends `q=2` on every command, so no reply turns on the vaxis `a=d` per render.

## Recommended kitty transmission medium for each column

| Column | Medium | Reason |
| --- | --- | --- |
| Ghostty | `t=d` | It works over `ssh`. `t=t` saves bytes only on the same host, and bbr cannot prove the same host from the environment. Ticket 03 can measure `t=t` as an option. [S1] [S6] |
| kitty | `t=d` | Same reason as Ghostty. The spec requires direct data for a remote client. [S1] |
| WezTerm | `t=d` | It works over `ssh`. WezTerm parses `t=t`, but this research did not find its temp directory rule. [S16] |
| iTerm2 | `t=d` | It works over `ssh`. herdr issue 5512 reports slow image output in iTerm2, so ticket 04 measures the output bytes. [S35] |
| tmux in Ghostty | `t=d` | tmux can run on another host than the terminal. Each chunk is one passthrough sequence of about 4 KiB. |
| tmux in iTerm2 | `t=d` | Same reason as tmux in Ghostty. |
| herdr in Ghostty | `t=d` | The herdr pane accepts every medium. [S33] But herdr sends the pixels on as direct data or as its own temp file. So `t=t` from bbr saves only the pane copy. |
| herdr in kitty | `t=d` | Same reason as herdr in Ghostty. herdr uses its own temp file only for a local Ghostty client. [S33] |
| No protocol | None | bbr sends no image and no image request. |

## Consequences for the prototype

### Detection function

The prototype adds one pure function and one probe.

- Input of the pure function: the environment map.
  It reads `TMUX`, `HERDR_ENV`, `TERM_PROGRAM`, and `TERM`.
  It also reads the prototype switches `BBR_M32_TMUX_IMAGES`, `BBR_M32_PLACEMENT`, and `BBR_M32_IMAGE_PROTOCOL`.
- Output of the pure function: one value of a union.
  - `plain`: send the probe.
  - `herdr`: send the probe.
  - `tmux_opt_in`: no probe. Use placeholders and the passthrough wrapper.
  - `none`: tmux without opt-in, or an unknown multiplexer. No probe and no image.
- Input of the probe: the result `plain` or `herdr`, the tty writer, and the Loop.
  The probe writes `ESC _ G i=31,s=1,v=1,a=q,t=d,f=24;AAAA ESC \ ESC [ c` and waits up to 1 second on `vx.query_futex`.
- Output of the probe: `vx.caps.kitty_graphics`.
- `BBR_M32_IMAGE_PROTOCOL=none` forces the text fallback, and `kitty` skips the probe.
  This lets the human test a terminal that the rule rejects.
- `BBR_M32_PLACEMENT` takes `direct` or `placeholder`. The default is `direct`. WezTerm always gets `direct`.
- Each decision writes one probe log line, for example `event=detect mux=herdr reply=yes placement=direct`.

### Passthrough wrapper format

One kitty sequence becomes one passthrough sequence:

```text
ESC P t m u x ; <the kitty sequence with each ESC doubled> ESC \
```

For example, `\x1b_Ga=d,d=I,i=7,q=2\x1b\\` becomes `\x1bPtmux;\x1b\x1b_Ga=d,d=I,i=7,q=2\x1b\x1b\\\x1b\\`.
Each chunk of a chunked transmit gets its own wrapper.
Every wrapped command carries `q=2`, so the outer terminal sends no reply into tmux. [S1] [S29]
The placeholder text cells need no wrapper. tmux draws them as text. [S31]

### Custom writer

vaxis image calls need no custom writer in a plain terminal or in herdr.
They write to the tty writer directly. [V5] [V8]

In tmux, the prototype does not use the vaxis image calls.
vaxis writes no `q=2` and no wrapper, and a filter writer would have to parse and change every vaxis sequence.
So bbr writes its own kitty bytes through the wrapper, and `vx.caps.kitty_graphics` stays false.
This also stops the `a=d` at the start of each vaxis render. [V6]

### Checks for ticket 04

- Each cell marked **T04** in the matrix.
- The side effects marked **T04**, if the prototype calls `queryTerminal` for comparison.
- Image transmit again after an External Edit, in each column.
- herdr inside tmux and tmux inside herdr, as the two nested detection cases.

## Open questions for later tickets

- Ticket 05: should herdr need an opt-in, because herdr answers the query also for an outer terminal without images? [S35]
- Ticket 05: is placeholder support in iTerm2 good enough to select placeholders for every terminal except WezTerm?

No question needs an authenticated Bitbucket request.
