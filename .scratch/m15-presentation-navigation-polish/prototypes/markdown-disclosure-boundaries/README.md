# PROTOTYPE — Markdown disclosure boundaries

Three disclosure policies for six-row review-card bodies, switchable via
`?variant=A`, `B`, or `C`. Every policy is shown against the same four projected
Markdown cases.

Run from the repository root:

```sh
python3 -m http.server 4175 --directory .scratch/m15-presentation-navigation-polish/prototypes/markdown-disclosure-boundaries
```

Then open `http://localhost:4175/?variant=B`. Use the floating bar or left/right
arrow keys to compare policies. Click any card to expand or collapse it.

This is disposable UI-prototype code, not an implementation.
