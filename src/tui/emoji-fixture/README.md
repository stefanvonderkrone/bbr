# Atlassian standard emoji fixture

`service-data-standard.json` is an unchanged copy of Atlassian's standard emoji test fixture.
The source commit is `f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e`.
The source path is `elements/util-data-test/src/json-data/service-data-standard.json`.

Source: https://api.bitbucket.org/2.0/repositories/atlassian/atlassian-frontend-mirror/src/f9f1d6a666d82ed28f06bfb74c07c4bb8e19f15e/elements/util-data-test/src/json-data/service-data-standard.json

Atlassian distributes the test-data package under Apache License 2.0.
`LICENSE` retains the package's license text and attribution.
bbr uses only the exact `shortName` and `fallback` fields, including nested `skinVariations`.
bbr does not copy the referenced sprite images.
The mapping is best-effort compatibility data, not a complete Bitbucket Cloud emoji catalog.

`emoji_data.zig` contains only the exact names and fallback bytes from the fixture.
Presentation adds U+FE0F to single-symbol fallbacks that default to text and have a Unicode 16.0 emoji-style variation.
For example, the catalog retains `❤`, while the converted `:heart:` shortcode displays `❤️`.
Existing selectors, skin tones, keycaps, flags, and joined sequences retain their fixture bytes.
Authored Unicode, code, escaped shortcodes, and link destinations retain their existing literal rules.
This display preference defines bbr behavior rather than observed Cloud behavior.

The display rule uses [Unicode 16.0 emoji properties](https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-data.txt) and [emoji variation sequences](https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-variation-sequences.txt).

`APACHE-2.0.txt` contains the full license.
`python3 src/tui/emoji-fixture/generate.py` regenerates the derived data.
The fixture and license remain part of the source distribution.
