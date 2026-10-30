# 04: Vendor the systems Grammars: C, C++, Rust, and Odin

Status: ready-for-agent
Blocked by: 03
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for C, C++, Rust, and Odin Files.
`.h` headers use the C++ BuiltInGrammar.
The C++ query inherits the C query through `; inherits: c`.

## Scope

- Vendor `c`, `cpp`, `rust`, and `odin` with `tools/vendor_grammar.py` at the revisions that the pinned nvim-treesitter commit names.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and GrammarMatch rows from the spec.
- Copy the raw `c` query once, and let the adaptation resolve it for `cpp`.

## Acceptance criteria

- [ ] `tools/check_vendored_grammars.py` passes for all four Grammars.
- [ ] Every query loads, and every ABI is in the runtime range.
- [ ] `.c` selects C, and `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx`, and `.h` select C++.
- [ ] `.rs` selects Rust, and `.odin` selects Odin.
- [ ] Each Grammar has a Capture fixture with comment, string, keyword, function, and type roles.
- [ ] A C++ fixture shows a Capture that only the inherited C query produces.
- [ ] The C++ BuiltInGrammar gives a pure C header the same roles that C gives a `.c` File.
- [ ] A C fixture with a field declaration proves `#has-ancestor?` and `#not-has-ancestor?` on a real query.
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
