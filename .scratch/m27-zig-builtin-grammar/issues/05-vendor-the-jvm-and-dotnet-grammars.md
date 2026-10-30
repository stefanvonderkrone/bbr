# 05: Vendor the JVM and .NET Grammars: Java, Kotlin, Groovy, and C#

Status: resolved
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

- [x] `tools/check_vendored_grammars.py` passes for all four Grammars.
- [x] Every query loads, and every ABI is in the runtime range.
- [x] `.java`, `.kt`, `.kts`, `.groovy`, `.gradle`, `Jenkinsfile`, and `.cs` select the right Grammar.
- [x] `build.gradle.kts` selects Kotlin.
- [x] Each Grammar has a Capture fixture with comment, string, keyword, function, and type roles.
- [x] A C# fixture with a namespace proves the `module` to `type` classification.
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

### Change summary

- `tools/vendor_grammar.py --update-manifest` vendored `java`, `kotlin`, `groovy`, and `c_sharp` in this order.
- The C# tag `v0.23.5` resolves to commit `cac6d5fb595f5811a076336682d5d595ac1c9e85`. The manifest records both.
- The ABI is 14 for Java and Kotlin, and 15 for Groovy and C#.
- `BuiltInGrammar` in `src/highlight/grammar_match.zig` has the four new tags at the end, in manifest order.
- `build.zig` now joins each Grammar include path at run time.
  The old `comptime std.fs.path.dirname` call used one shared branch quota for all sources.
  With 13 BuiltInGrammars, the quota of 1000 backward branches failed the build.
  The new call has no quota and gives the same include paths.
- `src/highlight/grammar_name.zig` did not change.
  `cs`, `csharp`, `c#`, `java`, and `kotlin` already have aliases.
  `kt`, `groovy`, and `gradle` resolve through the extension fallback, so they need no alias.

### Tests

The block `// M27 ticket 05 fixtures` at the end of `src/highlight/tree_sitter_highlighter.zig` adds these tests:

- "M27 grammar GrammarMatch selects Java, Kotlin, Groovy, and C#". It includes `build.gradle.kts` for Kotlin and `Jenkinsfile` for Groovy.
- "M27 grammar fence names resolve to Java, Kotlin, Groovy, and C#".
- "M27 grammar Java fixture has comment, string, keyword, function, and type roles".
- "M27 grammar Kotlin fixture has comment, string, keyword, function, and type roles".
- "M27 grammar Groovy fixture has comment, string, keyword, function, and type roles".
- "M27 grammar C# fixture has comment, string, keyword, function, and type roles".
- "M27 grammar C# namespace module Capture has the type role".

The four fixtures also join "interval merge matches byte planes for every BuiltInGrammar fixture".

### Commands and results

- `zig fmt --check build.zig src`: pass.
- `zig build`: pass.
- `zig build test-builtin-grammars`: 43 of 43 tests pass.
- `python3 tools/check_vendored_grammars.py .`: pass.
- `python3 tests/adapt_queries_test.py`: 24 tests pass.
- `zig build test --summary all`: 27 of 27 steps succeed, and 1418 of 1418 tests pass.
- `python3 tools/check_agent_docs.py`: pass.

### Defaults chosen

- No Grammar in this ticket is an Injection host, so the tool ran without `--injections`.
- The recipe says that no step edits `build.zig`. This ticket edits it because the build failed at the comptime branch quota. The fix keeps the recipe valid for later Grammars.
