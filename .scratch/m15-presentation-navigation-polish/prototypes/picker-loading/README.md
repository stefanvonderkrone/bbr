# PROTOTYPE — Picker loading feedback

Three deliberately different loading treatments for the PullRequest Picker, shown against a representative bbr review screen and switchable with `?variant=A`, `B`, or `C`.

Run from the repository root:

```sh
python3 -m http.server 4174 --directory .scratch/m15-presentation-navigation-polish/prototypes/picker-loading
```

Then open `http://localhost:4174/?variant=A`. Use the floating bar or left/right arrow keys to compare variants; choose representative delays from 0.25 to 8 seconds.

This is disposable UI-prototype code, not an implementation.
