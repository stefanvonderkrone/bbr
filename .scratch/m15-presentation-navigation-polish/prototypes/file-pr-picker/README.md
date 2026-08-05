# File finder / PullRequest Picker prototype

Throwaway UI prototype for three variants of the File finder and PullRequest Picker, switchable with `?variant=A`, `B`, or `C`.

Run from the repository root:

```sh
python3 -m http.server 4173 --directory .scratch/m15-presentation-navigation-polish/prototypes/file-pr-picker
```

Then open <http://127.0.0.1:4173/?variant=A>.

The result list is interactive: type to filter, use Up/Down or `ctrl-p`/`ctrl-n`, click to move the selection, and press Enter to confirm. The bottom prototype switcher changes variants with its buttons; Left/Right also switch variants while the query field is not focused.
