# Choose search through Markdown projection

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: needs-info
Blocked by: 02, 04

## Question

How do Buffer Search and Review Search find and focus authored text after ReviewBody transforms its display?

The user accepts searches for both displayed emoji and authored shortcodes.
Choose whether this equivalence applies identically to Buffer Search and Review Search.
Define occurrence identity and counts when both forms name the same authored shortcode.
Define case behavior without changing the existing literal smart-case and fuzzy ranking contracts by accident.

Discuss hidden emphasis delimiters, escapes, inline code, list markers, links, images, and table presentation.
Define which generated text participates in search and how a hit focuses its exact authored owner and location.
Decide how shortcode hits highlight an entire displayed emoji, including multiple-code-point emoji.
Include wrapping, narrow terminals, collapsed ReviewCards, previews, and Session replacement.

Keep raw authored ranges available for editing and clipboard operations.
The answer defines matching and navigation semantics with observable acceptance examples.
