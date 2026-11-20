# 11: Check that a File blob side always holds the same text

Status: needs-triage
Blocked by: none

## Summary

The search candidate key of [ticket 23 of the cascade](../../enrichment-rebuild-cascade/issues/23-compare-the-search-candidate-inputs-without-a-digest-collision.md) covers each File blob side in the whole-file scope by its presence, address, and length, not by its text.
This is correct only while a side holds the same text whenever it is loaded.
File Enrichment can evict a side (`clearText` in `src/tui/file_enrichment.zig`) and load it again later (`projectView`).
When the new text gets the address and length of the old text, the key stays the same.

The rule holds today because a side is the blob of one commit and one path, so a new load reads the same bytes.
No type, lint, or test enforces the rule.
A later change that loads a side from another source, for example a working tree file or a changed commit, with the same address and length, makes Buffer Search reuse a stale corpus with no error.

## What the triage decides

- Whether the rule can be a type or an architecture fact, for example a blob that is never freed while its Session lives, or a load generation that the key covers.
- Whether a test can show the rule, without a forbidden edit in the test itself.
- Whether the rule belongs in an area doc under `docs/rules/` (see [the rule areas guide](../../../docs/agents/rule-areas.md)).

## Comments

### 2026-11-16 filed

The runner of tickets 23 and 24 filed this ticket after the triage of ticket 23 listed the blob identity as a case that an exact key does not fix.
