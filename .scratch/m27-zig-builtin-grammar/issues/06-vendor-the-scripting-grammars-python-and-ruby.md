# 06: Vendor the scripting Grammars: Python and Ruby

Status: resolved
Blocked by: 03
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for Python and Ruby Files.
A script without an extension gets highlighting from its shebang.
`Gemfile` and `Rakefile` use the Ruby BuiltInGrammar.
PHP follows in ticket 11, because it needs the HTML BuiltInGrammar.

## Scope

- Vendor `python` and `ruby` with `tools/vendor_grammar.py` at the revisions that the pinned nvim-treesitter commit names.
- Resolve the Python tag `v0.25.0` to its commit, and record both.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and GrammarMatch rows from the spec.

## Acceptance criteria

- [x] `tools/check_vendored_grammars.py` passes for both Grammars.
- [x] Every query loads, and every ABI is in the runtime range.
- [x] `.py`, `.pyi`, `.rb`, `.gemspec`, `Gemfile`, and `Rakefile` select the right Grammar.
- [x] `#!/usr/bin/env python3`, `#!/usr/bin/python3.12`, and `#!/usr/bin/ruby` select Python, Python, and Ruby.
- [x] `#!/usr/bin/env -S python3 -u` selects Python.
- [x] Each Grammar has a Capture fixture with comment, string, keyword, function, and constant roles.
- [x] A Python fixture with a shebang line proves the rewritten `#lua-match?` on a real query.
- [x] Each fixture joins the byte-plane oracle test.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- The existing load, ABI, and manifest tests from ticket 03.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`

## Completion

The Python and Ruby BuiltInGrammars are vendored.
A reviewer now sees highlighting for Python and Ruby Files, also when only a shebang names them.

### Change summary

- `tools/vendor_grammar.py` vendored `python` and `ruby` with `--update-manifest`.
- The Python tag `v0.25.0` resolves to commit `293fdc02038ee2bf0e2e206711b69c90ac0d413f`. The manifest records both.
- The Ruby revision is commit `ad907a69da0c8a4f7a943a7fe012712208da6dee`.
- `BuiltInGrammar` in `src/highlight/grammar_match.zig` has the new tags `python` and `ruby`.
- `src/highlight/grammar_name.zig` has the new alias `python3`. The aliases `python`, `py`, `ruby`, and `rb` existed before.
- `build.zig` computes the include directory of each Grammar source at build time, not at comptime.
  Before this change, the comptime `dirname` calls of all sources used one branch quota.
  With Python and Ruby added, `zig build` failed with "evaluation exceeded 1000 backwards branches".
  Now the quota does not depend on the Grammar count.

### Tests

- "M27 grammar GrammarMatch selects Python and Ruby by name, extension, and shebang"
- "M27 grammar Python and Ruby fence and Injection names select their BuiltInGrammars"
- "M27 grammar Python fixture has shebang, comment, string, keyword, function, and constant roles"
- "M27 grammar Ruby fixture has comment, string, keyword, function, and constant roles"
- Both fixtures join "interval merge matches byte planes for every BuiltInGrammar fixture".

The Python fixture starts with `#!/usr/bin/env python3`.
The shebang gets the keyword role through the rewritten `#lua-match?`, and the next comment line keeps the comment role.
A changed assertion on the shebang role makes the test fail.

### Commands and results

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-builtin-grammars --summary all`: 40/40 tests pass.
- `python3 tools/check_vendored_grammars.py .`: pass.
- `python3 tests/adapt_queries_test.py`: 24 tests pass.
- `zig build test --summary all`: 27/27 steps, 1415/1415 tests pass.
- `python3 tools/check_agent_docs.py`: pass.

### Defaults chosen

- The new alias `python3` selects Python for a ReviewBody fence and an Injection.
- The adapter needed no change.
