# Pane and Overlay framing prototype

Throwaway UI prototype for “Choose Pane and Overlay framing.” It compares three structural variants on the same review surface:

- A — Hairline split
- B — Framed Panes
- C — Navigation rail

Run from the repository root:

```sh
python3 -m http.server 4173 --directory .scratch/m15-presentation-navigation-polish/prototypes/pane-overlay-framing
```

Open <http://localhost:4173/?variant=A>. Use the bottom controls to change the Overlay and terminal width; left/right arrows cycle variants.
