# 05: Vendor the JVM and .NET Grammars: Java, Kotlin, Groovy, and C#

Status: ready-for-agent
Blocked by: 03
Spec: [M27 spec](../SPEC.md)

## What to build

A reviewer sees highlighting for Java, Kotlin, Groovy, and C# Files.
Gradle scripts and `Jenkinsfile` use the Groovy BuiltInGrammar.

## Scope

- Vendor `java`, `kotlin`, `groovy`, and `c_sharp` with `tools/vendor_grammar.py` at the revisions that the pinned nvim-treesitter commit names.
- Resolve the C# tag `v0.23.5` to its commit, and record both.
- Add their manifest entries, enum tags, names, `extern` symbols, `grammarSource` arms, and GrammarMatch rows from the spec.

## Acceptance criteria

- [ ] `tools/check_vendored_grammars.py` passes for all four Grammars.
- [ ] Every query loads, and every ABI is in the runtime range.
- [ ] `.java`, `.kt`, `.kts`, `.groovy`, `.gradle`, `Jenkinsfile`, and `.cs` select the right Grammar.
- [ ] `build.gradle.kts` selects Kotlin.
- [ ] Each Grammar has a Capture fixture with comment, string, keyword, function, and type roles.
- [ ] A C# fixture with a namespace proves the `module` to `type` classification.
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
