# Vendored tree-sitter sources

These are copied source snapshots, not git submodules. `zig build` performs no network access and compiles only the files in this directory.

`manifest.zig.zon` records each upstream repository, pinned commit, and the SHA-256 of the principal generated source and highlight query. To update a Grammar:

1. Check out the recorded upstream repository at the intended commit in a temporary directory.
2. Replace `src/parser.c`, `src/scanner.c`, `src/tree_sitter/`, `queries/highlights.scm`, and `LICENSE` for that Grammar.
3. Update the commit and checksums in `manifest.zig.zon`.
4. Run `zig build test`; every BuiltInGrammar must load its query and produce fixture Captures.

The tree-sitter runtime is copied from `tree-sitter/tree-sitter/lib` at tag `v0.26.9`.
