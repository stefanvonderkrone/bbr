# Establish the mouse compatibility envelope

Type: research
Status: resolved
Blocked by: none

## Question

What mouse events and capabilities do bbr's pinned libvaxis version and common terminal, SSH, and multiplexer paths actually preserve for focus, scrolling, disclosure, and Selection, and what limitations must an M15 decision account for?

## Answer

Pinned libvaxis exposes cell coordinates, press/release, drag/motion, wheel directions, and modifiers. File/Pane focus, vertical scrolling, and single-click disclosure are sound candidates. Selection drag needs a narrow visible-row contract because terminal-native selection, cell granularity, latency, and lack of portable edge autoscroll make it less reliable. Hover-only behavior, double-click, smooth gestures, horizontal-wheel parity, and pointer capture are outside the common baseline. SSH adds no mouse semantics; multiplexers may intercept events. Every accepted interaction must dispatch a keyboard-equivalent Presentation Action.

Context: `docs/research/m15-mouse-compatibility.md` on branch `research/m15-mouse-compatibility`, commit `2321e509daf54f013076ed004798207530873e12`.
