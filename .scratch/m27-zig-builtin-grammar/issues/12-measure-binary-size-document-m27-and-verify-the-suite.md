# 12: Measure the binary size, document M27, and verify the integrated suite

Status: ready-for-agent
Blocked by: 04, 05, 06, 07, 10, 11
Spec: [M27 spec](../SPEC.md)

## What to build

The binary size before and after M27 is recorded.
The glossary, the agent documents, the ADRs, and the README describe the shipped M27 behavior.
The integrated hermetic suite passes with every M27 test.

## Scope

- Measure the values from the "Binary size measurement" section of the spec.
  Write them to `.scratch/m27-zig-builtin-grammar/binary-size.md` and link that file under `## Completion`.
- Apply the glossary changes from the "Glossary changes" section of the spec to `src/highlight/GLOSSARY.md`.
- Add `docs/adr/0014-builtin-grammar-queries-come-from-nvim-treesitter.md` with the decisions from the "ADRs" section of the spec.
- Add the six M27 rules from the "AGENTS.md rules" section of the spec to the table in `AGENTS.md`.
  Make sure that each named test and check exists with that exact name.
- Name the vendoring tools and Injection in `docs/code-navigation.md`.
- Add a BuiltInGrammar list with the GrammarMatch rules to `README.md`, near "Manage UserGrammars".
  State that an active UserGrammar takes precedence and that Injection uses only BuiltInGrammars.
- Update `FEATURES.md` for the new BuiltInGrammars.
- Check each M27 line in `TODO.md` that the evidence proves.
- Run the integrated checks and record the results under `## Completion`.

## Acceptance criteria

- [ ] `binary-size.md` records the host, the toolchain, both commits, both build modes, the `size` output, the build time, the `TreeSitterHighlighter.init` time, and the bench results.
- [ ] No Grammar is dropped for size.
- [ ] The glossary entries match the spec and use the glossary terms exactly.
- [ ] ADR-0014 exists and states its relation to ADR-0009.
- [ ] `AGENTS.md` has the six M27 rules, and each named test and check exists.
- [ ] `README.md` lists every BuiltInGrammar with its GrammarMatch rules.
- [ ] `vendors/tree-sitter/README.md` describes the procedure, the generated Swift parser, and the licences.
- [ ] `python3 tools/check_agent_docs.py` passes.
- [ ] `zig fmt --check build.zig src`, `zig build`, and `zig build test-builtin-grammars` pass.
- [ ] `python3 tools/check_vendored_grammars.py .` and `python3 tests/adapt_queries_test.py` pass.
- [ ] `zig build test --summary all` passes, and the reported test count is higher than before M27.

## Required checks

- `python3 tools/check_agent_docs.py`
- `zig fmt --check build.zig src`
- `zig build`
- `zig build -Doptimize=ReleaseSafe`
- `zig build test-builtin-grammars`
- `python3 tools/check_vendored_grammars.py .`
- `python3 tests/adapt_queries_test.py`
- `zig build test --summary all`
