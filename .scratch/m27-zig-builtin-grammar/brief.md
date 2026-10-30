# M27 BuiltInGrammar expansion: brief

Status: ready-for-agent
Milestone: M27

This brief records the `in-your-own-words` restatement and the `sharpen` pass for M27.
The requirements live in the M27 section of [TODO.md](../../TODO.md).
The vocabulary lives in [the Highlighting glossary](../../src/highlight/GLOSSARY.md).
The delivery model is [ADR-0009](../../docs/adr/0009-built-in-grammars-now-user-grammars-later.md).

## Scope change

M27 was "UserGrammar sandbox research".
On 2026-10-30, the user deferred the sandbox research and replaced M27 with a Zig BuiltInGrammar.
Later on the same day, the user added 19 more Grammars, including C++, and M27 became "BuiltInGrammar expansion".
The branch, the Worktree, and this directory are named `m27-zig-builtin-grammar`.
The sandbox research has no milestone now.
M17's native-code warning for UserGrammars stays.

Before the change, the user made these sandbox decisions.
They apply if the research comes back:

- Evaluate only macOS and Linux.
- Compare a Wasm Grammar, a confined helper process, and more BuiltInGrammars.
- Every dependency builds from source. No prebuilt Wasm runtime library.
- Prototypes never merge.

The candidate Wasm runtimes were wasmtime, WAMR, wasm3, zwasm, zware, and wasm2c or w2c2.
The user did not pick one.

## In my own words

Reviewers review code in many languages.
bbr highlights only 8 languages today.
Every other File shows as plain text, unless the reviewer installs a UserGrammar.
A UserGrammar is native code with the user's permissions, and installing it takes effort.

The goal is highlighting for the languages that the reviewers really meet, with no install and no trust prompt.
BuiltInGrammars give that.
They are pinned, vendored, compiled into the executable, and tested like the M13 Grammars.
This also removes most reasons to install a UserGrammar, which makes the deferred sandbox less urgent.

Some of these languages contain other languages.
Markdown has fenced code, HTML has `<script>` and `<style>`, and PHP sits inside HTML.
Without language injection, these Files are only partly highlighted.

## BuiltInGrammars after M27

The tree-sitter runtime is v0.26.9.
`vendors/tree-sitter/manifest.zig.zon` records each pinned commit and checksum.

| BuiltInGrammar | Upstream repository | Files | Status |
| --- | --- | --- | --- |
| JavaScript | `tree-sitter/tree-sitter-javascript` | `.js`, `.jsx`, `.mjs`, `.cjs` | existing |
| TypeScript | `tree-sitter/tree-sitter-typescript` | `.ts`, `.mts`, `.cts` | existing |
| TSX | `tree-sitter/tree-sitter-typescript` | `.tsx` | existing |
| CSS | `tree-sitter/tree-sitter-css` | `.css` | existing |
| Go | `tree-sitter/tree-sitter-go` | `.go` | existing |
| Bash | `tree-sitter/tree-sitter-bash` | `.sh`, `.bash`, shebang | existing |
| JSON | `tree-sitter/tree-sitter-json` | `.json` | existing |
| YAML | `tree-sitter-grammars/tree-sitter-yaml` | `.yaml`, `.yml` | existing |
| Zig | `tree-sitter-grammars/tree-sitter-zig` | `.zig`, `.zon` | new |
| C | `tree-sitter/tree-sitter-c` | `.c` | new |
| C++ | `tree-sitter/tree-sitter-cpp` | `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx`, `.h` | new |
| C# | `tree-sitter/tree-sitter-c-sharp` | `.cs` | new |
| PHP | `tree-sitter/tree-sitter-php` (`php` and `php_only`) | `.php` | new |
| Python | `tree-sitter/tree-sitter-python` | `.py`, `.pyi`, shebang | new |
| Rust | `tree-sitter/tree-sitter-rust` | `.rs` | new |
| Odin | `tree-sitter-grammars/tree-sitter-odin` | `.odin` | new |
| Swift | `alex-pinkus/tree-sitter-swift` | `.swift` | new |
| Kotlin | `fwcd/tree-sitter-kotlin` | `.kt`, `.kts` | new |
| Java | `tree-sitter/tree-sitter-java` | `.java` | new |
| Groovy | `murtaza64/tree-sitter-groovy` | `.groovy`, `.gradle`, `Jenkinsfile` | new |
| TOML | `tree-sitter-grammars/tree-sitter-toml` | `.toml` | new |
| Dockerfile | `camdencheek/tree-sitter-dockerfile` | `Dockerfile`, `Containerfile`, `*.dockerfile` | new |
| Make | `tree-sitter-grammars/tree-sitter-make` | `Makefile`, `makefile`, `GNUmakefile`, `.mk` | new |
| Ruby | `tree-sitter/tree-sitter-ruby` | `.rb`, `Gemfile`, `Rakefile`, `.gemspec`, shebang | new |
| HTML | `tree-sitter/tree-sitter-html` | `.html`, `.htm` | new |
| XML | `tree-sitter-grammars/tree-sitter-xml` | `.xml`, `.svg` | new |
| Markdown | `tree-sitter-grammars/tree-sitter-markdown` (block and inline) | `.md`, `.markdown` | new |
| SQL | `derekstride/tree-sitter-sql` (`gh-pages` branch) | `.sql` | new |

The File lists for the new Grammars are proposals.
The implementation tickets confirm them.

## Expert approach

- Raw sources: each upstream Grammar repository, the nvim-treesitter `parsers.lua` pins, the nvim-treesitter highlight and injection queries, and the M13 vendoring steps in `vendors/tree-sitter/README.md`.
- Method: follow the M13 delivery for each Grammar.
  Pin one commit, copy the sources, record checksums, and add fixture tests.
  Add injection inside `TreeSitterHighlighter`, so the `Highlighter` seam does not change.
- Outside check: open real PullRequests with these languages and compare the Captures with the same Files in Neovim.
  Neovim uses the same Grammars and queries.
  Also, check that a query predicate that bbr does not support fails a test and is not dropped without a report.

## Decisions

The user made these decisions on 2026-10-30.

1. **Grammar sources: the repository that nvim-treesitter pins.**
   Official `tree-sitter/*` repositories are used for C, C++, C#, PHP, Python, Rust, Java, Ruby, and HTML.
2. **GrammarMatch for Zig: `.zig` and `.zon`.**
   ZON is Zig syntax, for example in `build.zig.zon`.
3. **Queries: nvim-treesitter for every new Grammar.**
   bbr vendors the queries from one pinned nvim-treesitter commit.
   bbr resolves `; inherits:` lines, and rewrites or removes Neovim-only predicates.
   The 8 existing BuiltInGrammars keep their current queries.
4. **Add language injection for BuiltInGrammars.**
   Injection covers Markdown inline content and fenced code, HTML `<script>` and `<style>`, and PHP with embedded HTML.
   UserGrammars get no injection.
5. **Binary size: measure, no hard limit.**
   The M27 evidence records the size before and after.
   The current binary is about 13 MB.
6. **SVG uses the XML Grammar.**
   The XML Grammar handles `.svg` and `.xml`.
   The HTML Grammar handles `.html` and `.htm`.
7. **The sandbox research is deferred.**
8. **C++ is a BuiltInGrammar.**
   The user added C++ on 2026-10-30.
   `.h` Files use the C++ Grammar, because the C++ Grammar parses almost all C headers correctly, and the C Grammar does not parse C++ headers.
   The C++ queries inherit the C queries through `; inherits: c`.

## Specification changes

- Replaced: the M27 sandbox checklist in `TODO.md` is now the BuiltInGrammar expansion checklist.
- Changed: the M27 size is now L.
- Added: Swift and SQL need a generated `parser.c`.
  Generate it once during vendoring with a pinned tree-sitter CLI, and commit it.
  The build never generates sources.
- Added: an ABI check against the vendored v0.26.9 runtime for every Grammar.
- Added: map new Captures to existing Theme Captures first, before any new Theme color.
- Added: an active UserGrammar still takes precedence over every new BuiltInGrammar.

## Ticket split

The implementation tickets follow this order:

1. Injection support in `TreeSitterHighlighter`, tested first with an existing Grammar.
2. The query pipeline: pinned nvim-treesitter queries, `; inherits:` resolution, and the predicate test.
3. The Grammars in batches: systems (Zig, C, C++, Rust, Odin), JVM and .NET (Java, Kotlin, Groovy, C#), scripting (Python, Ruby, PHP), Apple (Swift), config and build (TOML, Dockerfile, Make), and markup and data (HTML, XML, Markdown, SQL).
4. The binary size evidence and the README Grammar list.

## Open questions

None.

## Next step

After approval, write `SPEC.md` and the implementation tickets in this directory.
