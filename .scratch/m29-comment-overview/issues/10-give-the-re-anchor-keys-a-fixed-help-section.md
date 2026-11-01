# 10: Give the re-anchor keys a fixed help section

Status: needs-triage
Blocked by: none
Spec: [M29 spec](../SPEC.md)

## Problem

An armed re-anchor reads Enter and Escape in `applyKey` outside the Keymap.
Only the status hint names these keys.
`help.fixed_sections` has no section for them.

Commit `7b639dd` makes each raw key input one value of `help.FixedKeyInput`.
The re-anchor branch runs after the switch on `Presentation.fixedKeyInput`, so the check does not cover it.
A new section changes the help output, and this change predates M29.
So the M29 fix commits do not add it.

## What to build

1. Add a `FixedKeyInput` value for the re-anchor stage two keys.
2. Add its section to `help.fixed_sections`.
3. Move the re-anchor branch of `applyKey` into the switch.
4. Update the help tests that count sections.
