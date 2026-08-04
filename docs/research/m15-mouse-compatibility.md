# M15 mouse compatibility envelope

## Question and conclusion

M15 asks whether mouse input can safely add convenience for focusing Files,
scrolling Panes, opening disclosures, and placing or extending a Selection while
keyboard operation remains complete.

The pinned libvaxis 0.6.0 has enough primitives for all four interactions, but
they do not have the same compatibility or implementation risk:

| Interaction | Available input | Compatibility judgment |
| --- | --- | --- |
| Focus a File or Pane | Cell coordinates plus left press/release | Good baseline. A click can identify a rendered row or Pane, provided bbr owns the hit map. |
| Scroll a Pane | Vertical wheel up/down plus coordinates | Good baseline on POSIX terminals, SSH PTYs, tmux, and Windows. Treat each report as a semantic scroll step; do not assume a physical distance or gesture phase. |
| Toggle a disclosure | Cell coordinates plus left press/release | Good baseline. Use a single click on a whole rendered disclosure row or an explicit marker; double-click is not a portable libvaxis event. |
| Place/extend a Selection | Left press, drag, release, cell coordinates, modifiers | Technically available but conditional. It conflicts with terminal-native text selection, is cell-granular, needs bbr-specific row/side mapping, and has no portable guarantee of drag autoscroll beyond the viewport. |

The recommended envelope is therefore:

1. Mouse remains optional and additive. Every mouse operation invokes the same
   Presentation Action/state transition as a keyboard operation; there is no
   mouse-only state or workflow.
2. Focus, vertical wheel scrolling, and single-click disclosure are suitable
   M15 candidates.
3. Click-to-place a Selection is feasible. Drag-to-extend should enter M15 only
   with an intentionally narrow contract: visible diff rows, cell-level input,
   the same anchor-validity checks as keyboard Selection, and no promised edge
   autoscroll. Otherwise retain `v` and shift+arrow as the complete interface
   and defer drag.
4. Horizontal wheel, hover-only behavior, double/triple-click, smooth scrolling,
   gesture phases, pressure, and pointer capture are outside the verified common
   baseline.

## What pinned libvaxis actually exposes

The repository pins libvaxis commit
[`ca781b3c`](https://github.com/rockorager/libvaxis/tree/ca781b3c01f44a92e5331652823b5a9ce445be96),
packaged as `vaxis-0.6.0` ([`build.zig.zon`](../../build.zig.zon#L7-L10)).
Its `Mouse` value carries signed cell coordinates,
optional pixel offsets, a button, Shift/Alt/Ctrl modifiers, and one of `press`,
`release`, `motion`, or `drag`. Its button enum includes left/middle/right,
vertical and horizontal wheel directions, and four extra buttons
([`Mouse.zig`](https://github.com/rockorager/libvaxis/blob/ca781b3c01f44a92e5331652823b5a9ce445be96/src/Mouse.zig#L16-L50)).

On POSIX-like terminals, `setMouseMode(true)` emits DEC private modes 1002,
1003, and 1004 together with SGR cell reporting (1006), or SGR pixel reporting
(1016) when libvaxis detected that capability. Pixel coordinates are translated
back to a cell plus within-cell offsets before delivery
([`ctlseqs.zig`](https://github.com/rockorager/libvaxis/blob/ca781b3c01f44a92e5331652823b5a9ce445be96/src/ctlseqs.zig#L19-L25),
[`Vaxis.zig`](https://github.com/rockorager/libvaxis/blob/ca781b3c01f44a92e5331652823b5a9ce445be96/src/Vaxis.zig#L886-L924)).
The paired 1002/1003 request is deliberate: 1003 is the last mode requested on
terminals that support it, while 1002 remains a fallback for intermediaries
such as older Zellij versions that do not support all-motion reporting.

The parser recognizes legacy X10 and SGR encodings. It turns motion with a
button down into `drag`, motion with no button into `motion`, and distinguishes
SGR press (`M`) from release (`m`)
([`Parser.zig`](https://github.com/rockorager/libvaxis/blob/ca781b3c01f44a92e5331652823b5a9ce445be96/src/Parser.zig#L688-L747)).
`Window.hasMouse` supplies rectangular hit testing only; it does not associate
events with rendered rows or domain objects
([`Window.zig`](https://github.com/rockorager/libvaxis/blob/ca781b3c01f44a92e5331652823b5a9ce445be96/src/Window.zig#L471-L479)).
That mapping must stay in bbr's Presentation adapter so rendering geometry does
not leak into Review state.

libvaxis's generic loop delivers a parsed mouse event only when the application's
event union has a `mouse` field, and translates pixel coordinates before posting
it ([`Loop.zig`](https://github.com/rockorager/libvaxis/blob/ca781b3c01f44a92e5331652823b5a9ce445be96/src/Loop.zig#L338-L356)).
Current bbr neither declares `AppEvent.mouse` nor calls `setMouseMode`, so it
currently receives no mouse input even though the dependency supports it
([`src/tui/app.zig`](../../src/tui/app.zig#L47-L51),
[`src/tui/app.zig`](../../src/tui/app.zig#L91-L104)). Enabling mouse mode and
adapting events are future implementation work, not an automatic library feature.

On native Windows consoles, libvaxis uses `MOUSE_EVENT_RECORD` rather than the
xterm parser. It maps left/middle/right press and release, vertical wheel, motion,
drag, and modifiers. It does **not** map `MOUSE_HWHEELED` in this pinned source,
so horizontal wheel is not a cross-platform promise
([`tty.zig`](https://github.com/rockorager/libvaxis/blob/ca781b3c01f44a92e5331652823b5a9ce445be96/src/tty.zig#L561-L647)). Microsoft's
console contract likewise says mouse records exist only while the console has
keyboard focus and the pointer is inside its bounds, and distinguishes movement,
vertical wheel, horizontal wheel, and double-click flags
([`MOUSE_EVENT_RECORD`](https://learn.microsoft.com/en-us/windows/console/mouse-event-record-str)).
libvaxis normalizes neither the Windows double-click flag nor gesture metadata
into its public `Mouse.Type`, reinforcing single-click as the portable contract.

## Terminal protocol limits

The requested modes are xterm extensions, not a universal terminal-input
standard. Xterm defines 1002 as button-event tracking (press/release and motion
while a button is down), 1003 as any-event tracking, 1004 as terminal-window
FocusIn/FocusOut, and 1006 as SGR extended coordinates. Under 1002, motion is
reported only after moving to a different character cell; 1003 adds motion with
no button down. SGR 1006 uses decimal coordinates and an explicit press/release
terminator, avoiding the old X10 coordinate ceiling and ambiguous release
([XTerm Control Sequences, Mouse Tracking](https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf#page=48)).

Consequences for M15:

- Coordinates identify terminal cells, not a File, rendered grapheme, source
  line, or side of a side-by-side diff. bbr must map the current Projection and
  layout to a semantic target and must reject non-selectable rows exactly as the
  keyboard Selection path does.
- `focus_in`/`focus_out` means the outer terminal window gained or lost OS
  focus. It is unrelated to clicking a bbr Pane or focusing a File and is not
  needed for the proposed interactions.
- A terminal that ignores an enabling mode simply produces no corresponding
  events; libvaxis has no general mouse-support handshake. Mouse therefore
  cannot be required for discovery, recovery, or completion of a workflow.
- Wheel events are discrete directions in libvaxis. There is no normalized
  distance, inertia, touchpad phase, or smooth-scroll delta. Fixed, documented
  line/page Actions are the stable semantic interpretation.
- Drag motion is cell-granular. Neither the xterm protocol nor libvaxis supplies
  application-level pointer capture or a portable request to keep scrolling
  when the pointer rests beyond the top or bottom edge. Edge autoscroll would
  require additional timing/state behavior and is not in the verified baseline.

## Native terminal selection conflict

When application mouse reporting is active, the terminal reserves mouse events
for escape sequences instead of its normal select-and-copy behavior. Xterm
normally lets Shift temporarily bypass application mouse reporting; its exact
behavior is configurable, so shifted mouse events may instead reach the
application ([xterm `shiftEscape`](https://invisible-island.net/xterm/manpage/xterm.pdf#page=57)).
The tmux project's FAQ generalizes the practical limitation: mouse reporting is
all-or-nothing at the terminal boundary, with Shift commonly used as the bypass
on Linux terminals and Option used by iTerm2
([tmux FAQ](https://github.com/tmux/tmux/wiki/FAQ#i-want-to-use-the-mouse-to-select-panes-but-the-terminal-to-copy-how)).

This creates two distinct meanings of “selection”:

- **bbr Selection** is a contiguous set of diff lines with Review anchor rules.
  It may be driven by app-level click/drag events.
- **terminal text selection** copies rendered cells, including decoration, and
  must use a terminal-specific bypass while bbr mouse reporting is enabled.

M15 documentation/help must keep those concepts distinct. Shift+drag cannot be
advertised as a universal bbr gesture because some terminals consume Shift as
the native-selection bypass and send bbr no event. The unmodified keyboard
Selection (`v`, motions, and any accepted shift+arrow support) remains canonical.

## SSH envelope

OpenSSH does not need a mouse-specific feature. With a requested pseudo-terminal,
it sends `TERM` and provides the interactive terminal channel over which the
terminal's escape-sequence bytes pass. `RequestTTY`/`-t` controls whether that
pseudo-terminal is allocated; the server may disallow it with `PermitTTY`
([OpenSSH `ssh_config`](https://man.openbsd.org/ssh_config#RequestTTY),
[`sshd_config`](https://man.openbsd.org/sshd_config#PermitTTY)).

Therefore the compatibility statement is: mouse reporting works over a normal
interactive SSH PTY when the **local terminal** supports the requested mode and
every intermediary preserves it. Running through `ssh -T`, a server with
`PermitTTY no`, or any non-interactive pipe is outside the TUI envelope, not a
mouse fallback case. SSH latency also makes all-motion/drag visibly more
sensitive than click or wheel input; this is another reason not to make drag a
required workflow. Keyboard input uses the same PTY path but generates far fewer
events.

## tmux and other multiplexers

tmux is an active terminal intermediary. It recognizes mouse events, maps many
of them to its own key bindings, and can pass an event to an application in a
Pane when that application has enabled mouse reporting. The official tmux guide
documents press, release, drag, and wheel event classes, and `send-keys -M` for
forwarding to mouse-aware programs
([tmux Advanced Use](https://github.com/tmux/tmux/wiki/Advanced-Use#mouse-key-bindings)).
Its user-level `mouse` option and custom bindings can also claim events for Pane
selection, copy mode, resizing, and menus
([tmux Getting Started](https://github.com/tmux/tmux/wiki/Getting-Started#using-the-mouse)).

Thus tmux supports the baseline interactions, but configuration and nesting can
intercept or transform them. bbr must not try to override tmux policy and cannot
promise that every mouse event reaches it. The same warning applies to other
multiplexers: libvaxis explicitly requests both 1002 and 1003 because support
differs. Keyboard parity is the recovery path whenever a multiplexer consumes a
gesture.

## Decision constraints for “Decide M15 mouse support”

Any accepted M15 mouse behavior should satisfy all of these:

- Mouse mode can disappear without making a visible control unreachable.
- A mouse gesture dispatches an existing or newly named semantic Presentation
  Action also exposed through the Keymap; rendering never mutates state directly.
- Hit testing is derived from the exact current Projection/layout and ignores
  borders, clipped rows, overlays, and stale geometry. An Overlay captures mouse
  input just as it captures keyboard input.
- Vertical wheel is targeted by event coordinates to the Pane under the pointer;
  its step is deterministic and shared with keyboard scroll/navigation Actions.
- Disclosure toggles use single left clicks and preserve independent expansion
  state through the same transition as Enter/the chosen keyboard binding.
- A click or drag over diff content goes through existing Selection-to-Anchor
  validation. Sidebar, border, Fold, Thread, and other non-line rows cannot
  silently become anchors.
- Help text calls mouse gestures optional and explains the native terminal text
  selection bypass as terminal-dependent.
- The test matrix covers pure coordinate-to-target mapping and Action parity;
  interactive smoke checks cover at least a direct terminal, SSH PTY, and tmux.
  A smoke failure never removes the keyboard route.

## Primary sources

- [Pinned libvaxis source at `ca781b3c`](https://github.com/rockorager/libvaxis/tree/ca781b3c01f44a92e5331652823b5a9ce445be96)
- [XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf)
- [xterm manual](https://invisible-island.net/xterm/manpage/xterm.pdf)
- [OpenSSH client configuration](https://man.openbsd.org/ssh_config) and [server configuration](https://man.openbsd.org/sshd_config)
- [Official tmux wiki](https://github.com/tmux/tmux/wiki)
- [Microsoft Windows Console mouse event contract](https://learn.microsoft.com/en-us/windows/console/mouse-event-record-str)
