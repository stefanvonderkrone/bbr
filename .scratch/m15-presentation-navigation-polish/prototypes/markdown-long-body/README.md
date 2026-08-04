# PROTOTYPE — Markdown and long-body presentation

Three throwaway DiffPane variants for the Wayfinder ticket [Choose Markdown and long-body presentation](../../issues/04-choose-markdown-and-long-body-presentation.md), switchable with `?variant=A`, `?variant=B`, or `?variant=C`.

This answers how rendered Markdown, fenced Suggestions, and pathological body lengths should share Buffer rows. It is not an M15 implementation.

Run from the repository root:

```sh
python3 -m http.server 4173 --directory .scratch/m15-presentation-navigation-polish/prototypes/markdown-long-body
```

Open <http://127.0.0.1:4173/?variant=A>. Use the bottom switcher or Left/Right to compare variants. Within the mock DiffPane, `j`/`k` moves between review items, Enter expands/collapses the focused item, and `t` cycles the collapsed-row threshold.
