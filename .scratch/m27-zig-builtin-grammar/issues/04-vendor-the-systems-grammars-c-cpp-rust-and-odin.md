# 04: Vendor the systems Grammars: C, C++, Rust, and Odin

Status: resolved
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

- [x] `tools/check_vendored_grammars.py` passes for all four Grammars.
- [x] Every query loads, and every ABI is in the runtime range.
- [x] `.c` selects C, and `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx`, and `.h` select C++.
- [x] `.rs` selects Rust, and `.odin` selects Odin.
- [x] Each Grammar has a Capture fixture with comment, string, keyword, function, and type roles.
- [x] A C++ fixture shows a Capture that only the inherited C query produces.
- [x] The C++ BuiltInGrammar gives a pure C header the same roles that C gives a `.c` File.
- [x] A C fixture with a field declaration proves `#has-ancestor?` and `#not-has-ancestor?` on a real query.
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

The tool vendors C, C++, Rust, and Odin with `--update-manifest` at the pinned revisions.
The manifest has four new entries after `zig`, in the order c, cpp, rust, odin.
`BuiltInGrammar` has the tags `c`, `cpp`, `rust`, and `odin` in the same order.
The raw C query is in `vendors/tree-sitter/nvim-treesitter/queries/c` once.
The adapted C++ query resolves `; inherits: c` and puts the C query first.
Before this change, these Files had no highlighting. Now each File gets Captures from its BuiltInGrammar.

`build.zig` changes in one line.
`addTreeSitter` called `std.fs.path.dirname` at comptime for each source.
With four more Grammars, that comptime work exceeded the default branch quota, so `zig build` failed.
`addTreeSitter` now joins the include path at build time with `b.pathJoin`.

New tests in `src/highlight/tree_sitter_highlighter.zig`, under `// M27 ticket 04 fixtures`:

- "M27 grammar GrammarMatch selects C for .c and C++ for headers"
- "M27 grammar C fixture has comment, string, keyword, function, and type roles"
- "M27 grammar C field declaration proves has-ancestor and not-has-ancestor"
- "M27 grammar C++ fixture has comment, string, keyword, function, and type roles"
- "M27 grammar C++ gets the include and comment Captures from the inherited C query"
- "M27 grammar C++ gives a pure C header the roles that C gives a .c File"
- "M27 grammar Rust fixture has comment, string, keyword, function, and type roles"
- "M27 grammar Odin fixture has comment, string, keyword, function, and type roles"

The five fixtures also join "interval merge matches byte planes for every BuiltInGrammar fixture".
The field fixture `int run(int);` has no Span on `run`.
Without `#not-has-ancestor?`, the C query gives `run` the property Capture.

Commands and results:

- `zig fmt --check build.zig src` passes.
- `zig build` passes.
- `zig build test-builtin-grammars` passes 44 of 44 tests.
- `python3 tools/check_vendored_grammars.py .` passes.
- `python3 tests/adapt_queries_test.py` passes 24 tests.
- `zig build test --summary all` passes 27 of 27 steps and 1419 of 1419 tests.
- `python3 tools/check_agent_docs.py` passes.

Defaults chosen:

- `grammar_name.zig` gets no new alias.
- `fencePath` and `selectInjection` use an unknown name as the extension, so `odin`, `h`, `hpp`, and `cc` already resolve.
- The existing aliases cover `c`, `cpp`, `c++`, `cxx`, `rust`, and `rs`.
