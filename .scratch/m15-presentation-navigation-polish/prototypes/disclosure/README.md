# Disclosure prototype

Throwaway UI for the Wayfinder ticket [Choose the disclosure language for hidden review content](../../issues/03-choose-disclosure-language-for-hidden-review-content.md).

Run from the repository root:

```sh
python3 -m http.server 4173 --directory .scratch/m15-presentation-navigation-polish/prototypes/disclosure
```

Open `http://localhost:4173/?variant=A`. Use the bottom switcher or Left/Right to compare the three variants. Within the mock DiffPane, `j`/`k` moves, Enter toggles, `r` simulates a Buffer rebuild, and `n` simulates a new Session.
