# Choose Selection source ownership after Markdown projection

Parent: [M23 Comment thread and Markdown presentation fixes](../map.md)
Label: wayfinder:grilling
Type: grilling
Status: ready-for-agent
Blocked by: 04, 06, 07

## Question

Which authored logical lines does a selected ReviewBody row represent when Markdown projection joins, repeats, or hides authored text?

Apply the mixed Selection contract from [Choose raw ReviewBody yank behavior](./07-choose-raw-reviewbody-yank-behavior.md).
Keep complete-body copying, Selected Version filtering, selected ReviewCard labels, and exact authored bytes unchanged.

Combine that contract with [Choose ReviewBody Markdown presentation](./04-choose-reviewbody-markdown-presentation.md).
Use [Choose search through Markdown projection](./06-choose-search-through-markdown-projection.md) for related source and navigation distinctions.
Search ranges do not define clipboard extraction by themselves.

Choose observable copying behavior for these cases:

- Two authored prose lines join into one displayed paragraph.
  A selected row can contain text from both lines or only one line after wrapping.
- One authored table row becomes several header-labelled cells at a narrow width.
  A selected cell row can repeat a header from another authored line.
  Decide whether that repeated header contributes its authored line or remains generated decoration.
- A reference link displays a destination from a hidden body-local definition.
  A Selection touches the displayed destination but not a row for the definition.
  Decide whether copying includes the reference use, the hidden definition, or both.
- A displayed spacer represents several authored blank lines.
  Decide which blank lines a selected spacer copies.
- A body row contains only a generated heading, list, quote, or table marker.
  Distinguish these markers from the already permitted selected ReviewCard labels.
- Valid fence delimiters and Setext underlines have no displayed row.
  Decide whether Selection of their adjacent content implies those authored lines.
  The existing contract already forbids synthesizing fences around partial code.

Keep deduplication per authored owner and logical line.
Define contribution order when displayed order and authored order differ.
Do not infer the answer from equal-length source and display slices.

The answer must include exact clipboard-byte examples for narrow and wide projections.
Include a joined-paragraph search reveal followed by Selection copying.
Include resize and ReviewCard disclosure without adding hidden logical lines merely because the body owns them.

This ticket resolves a presentation and clipboard decision.
It does not implement M23.
