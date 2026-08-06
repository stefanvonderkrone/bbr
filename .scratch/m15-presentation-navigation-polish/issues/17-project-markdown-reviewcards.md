# Project Markdown ReviewCards

Status: ready-for-human

## What to build

Project unchanged Comment and Draft bytes into bounded, terminal-native ReviewCards. Use a pure parsing and width-projection pipeline with stable source ownership, grapheme-aware geometry, visible link destinations, structural Suggestion fences, Theme-composed roles, and a configurable hard rendered-row disclosure limit.

## Acceptance criteria

- [x] ReviewBody parsing and ReviewCard row projection are pure, network-free stages shared by Comment, Reply, Draft, and Suggestion bodies.
- [x] Supported Markdown structure is legible in terminal cells, link destinations remain visible, and Suggestion fences retain their distinct review meaning.
- [x] Wrapping, clipping, and row counting use shared grapheme/cell metrics and remain correct at zero, narrow, ordinary, and wide content widths.
- [x] Bodies over `[comments].collapsed_rows` render exactly that many body rows plus a disclosure footer; `0` disables automatic collapse and the default is `6`.
- [x] Cursor restoration uses stable ReviewCard ownership and source offsets across width changes and disclosure transitions; Review-owned body bytes are never rewritten.
- [x] Malformed or adversarial Markdown degrades to readable text, and tests cover long tokens, Unicode, combining characters, nested syntax, Suggestions, links, and every built-in Theme role.

## Blocked by

- [15 — Establish the atomic Presentation Frame](15-establish-the-atomic-presentation-frame.md)
