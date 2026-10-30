# 08: Vendor the configuration Grammars: TOML, Dockerfile, and Make

Status: ready-for-agent
Blocked by: 03
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for TOML, Dockerfile, and Make Files.
Files without an extension, such as `Dockerfile`, `Containerfile`, and `Makefile`, match by exact filename.

## Scope

- Vendor `toml`, `dockerfile`, and `make` with `tools/vendor_grammar.py` at the revisions that the pinned nvim-treesitter commit names.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and GrammarMatch rows from the spec.

## Acceptance criteria

- [ ] `tools/check_vendored_grammars.py` passes for all three Grammars.
- [ ] Every query loads, and every ABI is in the runtime range.
- [ ] `.toml`, `Dockerfile`, `Containerfile`, `app.dockerfile`, `Makefile`, `makefile`, `GNUmakefile`, and `.mk` select the right Grammar.
- [ ] `docker/Dockerfile` selects Dockerfile, because the exact filename rule uses the basename.
- [ ] `Dockerfile.dev` selects no Grammar.
- [ ] Each Grammar has a Capture fixture with comment, string, and keyword roles.
- [ ] A Make or Dockerfile fixture proves `#set! priority` on a real query.
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
