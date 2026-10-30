# 06: Vendor the scripting Grammars: Python and Ruby

Status: ready-for-agent
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

- [ ] `tools/check_vendored_grammars.py` passes for both Grammars.
- [ ] Every query loads, and every ABI is in the runtime range.
- [ ] `.py`, `.pyi`, `.rb`, `.gemspec`, `Gemfile`, and `Rakefile` select the right Grammar.
- [ ] `#!/usr/bin/env python3`, `#!/usr/bin/python3.12`, and `#!/usr/bin/ruby` select Python, Python, and Ruby.
- [ ] `#!/usr/bin/env -S python3 -u` selects Python.
- [ ] Each Grammar has a Capture fixture with comment, string, keyword, function, and constant roles.
- [ ] A Python fixture with a shebang line proves the rewritten `#lua-match?` on a real query.
- [ ] Each fixture joins the byte-plane oracle test.

## Tests that prove it

- "M27 grammar" Capture fixtures and GrammarMatch cases in `src/highlight/tree_sitter_highlighter.zig`.
- The existing load, ABI, and manifest tests from ticket 03.

## Required checks

- `zig fmt --check build.zig src`
- `zig build`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `zig build test --summary all`
