# 11: Scroll the help Overlay with the wheel

Status: needs-triage
Blocked by: none
Spec: [M30 spec](../SPEC.md)

## Problem

The Mouse section of the help Overlay lists `wheel` with the description `scroll`.
While the help Overlay is open, the wheel does not scroll the help lines.
This behavior comes from `origin/main` (PR #16), not from M30.
M30 gives the help scroll bar a press and a Scroll Drag, but M30 does not change the wheel.

## Possible change

A wheel event over the help body scrolls the help lines.
The help scroll keys clamp the scroll to the last page, and the wheel uses the same clamp.
A test opens the help, sends a wheel event over the body, and expects a changed help scroll.

## Acceptance criteria

- [ ] A maintainer decides whether the wheel scrolls the help or the help entry changes.
- [ ] The help Mouse section describes the shipped wheel behavior.
