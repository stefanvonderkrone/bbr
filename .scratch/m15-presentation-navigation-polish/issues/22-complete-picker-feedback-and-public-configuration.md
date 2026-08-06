# Complete Picker feedback and public configuration

Status: ready-for-agent

## What to build

Finish M15's visible loading feedback and public configuration as one coherent product surface. Add a scoped, low-frequency Picker spinner through the blocking event path; implement the inactive in-memory File-cache policy; and complete configuration validation, help, documentation, Theme roles, and architectural records for all accepted M15 behavior.

## Acceptance criteria

- [ ] A visible loading Picker receives scoped tick events through the blocking event path and shows a single-glyph spinner; ticks stop when loading, the Overlay, or the application ends and never create idle polling.
- [ ] The inactive File cache honors `enabled = true` and `max_bytes = 268435456` defaults, treats `0` as unlimited, excludes the focused File from the budget, and evicts inactive content deterministically.
- [ ] Comment, File-cache, mouse, Theme, and Action settings implement their documented defaults, zero semantics, and opt-outs without compatibility aliases for renamed keys.
- [ ] Invalid values, duplicate keys, unknown tables or keys, ambiguous contextual bindings, and unusable mouse scroll values produce line-specific diagnostics.
- [ ] Help and user documentation describe the accepted keyboard and mouse workflows, ActionAvailability, Picker behavior, disclosure behavior, Comment scopes, cache semantics, and configuration.
- [ ] All new style roles exist in every built-in Theme, relevant ADRs reflect the final boundaries, and tests cover spinner lifetime, idle blocking, cache budgeting/eviction, defaults, opt-outs, and diagnostics.

## Blocked by

- [17 — Project Markdown ReviewCards](17-project-markdown-reviewcards.md)
- [20 — Introduce contextual Actions and purpose-shaped Overlays](20-introduce-contextual-actions-and-purpose-shaped-overlays.md)
- [21 — Add keyboard-parity mouse navigation](21-add-keyboard-parity-mouse-navigation.md)
