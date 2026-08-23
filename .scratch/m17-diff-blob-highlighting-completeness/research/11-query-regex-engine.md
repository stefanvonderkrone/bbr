# Query regex engine research

## Decision

Use **RE2 2025-11-05**, commit
[`927f5d53caf8111721e734cf24724686bb745f55`](https://github.com/google/re2/tree/927f5d53caf8111721e734cf24724686bb745f55),
through a small vendored C ABI wrapper. Pin `re2-2025-11-05.tar.gz` by its published SHA-256,
`87f6029d2f6de8aa023654240a03ada90e876ce9a4676e258dd01ea4c26ffd67`.
RE2 pins **Abseil 20250512.1**, commit
[`76bb24329e8bf5f39704eb10d21b9a80befa7c81`](https://github.com/abseil/abseil-cpp/tree/76bb24329e8bf5f39704eb10d21b9a80befa7c81);
pin `abseil-cpp-20250512.1.tar.gz` by its published SHA-256
`9b7a064305e9fd94d124ffa6cc358592eb42b5da588fb4e07d09254aa40086db`.

The public dialect is **RE2 Perl mode, UTF-8 encoding, unanchored search**, with these fixed
options:

- `encoding=UTF8`, `posix_syntax=false`, `case_sensitive=true`, `log_errors=false`,
  `never_capture=true`, `longest_match=false`, `dot_nl=false`, `never_nl=false`, and
  `literal=false`.
- Set `max_mem` to 1 MiB per compiled expression. This limits the compiled forward and reverse
  programs and their DFA caches. It is not a hard cap on all process memory. A full DFA cache is
  flushed, and repeated DFA exhaustion falls back to RE2's NFA.
- Maximum pattern length: 4096 UTF-8 bytes. Reject larger patterns before RE2 sees them.
- `^` and `$` mean start and end of the captured node text because RE2 is not put in multiline
  mode. An expression without anchors searches for a matching substring. This matches Tree-sitter
  and Neovim's documented `#match?` use.
- Input is the exact captured UTF-8 byte slice, including embedded NUL bytes. M17 validates File
  content as UTF-8 before Highlighting. The wrapper must use RE2's length-bearing
  `absl::string_view` API, not a C-string matching API.
- The atom is a Unicode code point in valid UTF-8. `\d`, `\s`, `\w`, and their complements are
  ASCII-only in RE2. `\C` is the explicit single-byte atom. No normalization occurs.
- Do not claim Rust-regex, PCRE, Vim-regex, or Lua-pattern compatibility. Reject unsupported
  syntax, including backreferences and look-around.

This dialect accepts all nine BuiltInGrammar expressions. It also accepts the syntax used by
Tree-sitter's documented examples. A check of nvim-treesitter commit
[`e82ef6ae2c3eeb96c6916b29917f96bf630b2cdb`](https://github.com/nvim-treesitter/nvim-treesitter/tree/e82ef6ae2c3eeb96c6916b29917f96bf630b2cdb)
found 48 `#match?` or `#not-match?` occurrences in highlight queries. RE2 accepts 25 as written.
The other 23 use Vim's `\c` case-folding prefix. This count assesses the regex strings only; M17's
predicate profile separately rejects `#not-match?` until that operator is added. Neovim implements
`#match?` with Vim regex, while Tree-sitter's Rust binding uses Rust byte regex. There is no shared
Tree-sitter regex dialect. Do not rewrite `\c` silently. Reject that UserGrammar and name the RE2
dialect in the diagnostic.

## Why RE2

RE2 is the only candidate that combines a current upstream release, a production security model
for untrusted expressions, linear matching time, a suitable UTF-8 and byte API, and a toolchain Zig
0.16 can drive without adding Rust. It rejects constructs that require backtracking, including
backreferences and look-around. Its configurable budget can reject a program during compilation.
During matching, DFA cache exhaustion causes cache flushes and then NFA fallback instead of a
reported failure.

RE2 is C++17 and BSD-3-Clause. Abseil is Apache-2.0. The cost is material: 22 RE2 C++ translation
units, the required Abseil components, the C++ runtime, and threading support. Zig 0.16 can compile
C++ sources and link libc++, but this repository has not proved the RE2 and Abseil build.

RE2's CI directly tests Linux and macOS. Its build documentation covers Windows with MSVC, Cygwin,
MinGW, and MSYS. The repository does not define a bbr release-target matrix, so this research cannot
claim exact Zig target triples. Accept RE2 only with Zig 0.16 compile, link, and wrapper smoke tests
for each declared bbr target. Do not claim freestanding or WASI support from upstream evidence.

The cost is justified by UserGrammar input. A nine-expression special case would solve only the
current BuiltInGrammars and would make M17's one-profile rule false in practice.

## Diagnostics contract

Compile every distinct expression once during atomic Grammar validation. On failure, reject the
complete Grammar and retain the previous active Grammar. Use this diagnostic shape:

```text
<grammar>:<query-source>:<line>:<column>: invalid #match? expression for RE2-2025-11-05: <reason>
  expression: <escaped expression>
  engine-code: <RE2 ErrorCode name>
  engine-fragment: <escaped error_arg, if non-empty>
  dialect: https://github.com/google/re2/blob/2025-11-05/doc/syntax.txt
```

`line` and `column` point to the first byte inside the Tree-sitter string argument. RE2 exposes an
error code and offending fragment, but no exact numeric error offset. Do not invent one. The query
source offset already required by ticket 07 points to the predicate/string, and the fragment gives
the engine's narrower evidence. Use stable reasons `pattern-too-long` for the pre-check and
`compile-budget-exceeded` for `ErrorPatternTooLarge`. A false match is not a diagnostic. RE2's
public match call returns only match or no match; it has no runtime-error result for the wrapper to
surface.

Conformance fixtures must pin behavior for every BuiltInGrammar expression and for embedded NUL,
multibyte UTF-8, `.` versus `\C`, ASCII `\d` and `\w`, `(?i)`, `^` and `$`, substring search,
invalid UTF-8 in the expression, backreferences, look-around, Vim `\c`, the 4096-byte limit, and
the 1 MiB compile budget.

## Candidate comparison

| Candidate | Time and memory | Text model and compatibility | Targets and build cost | License | Decision |
| --- | --- | --- | --- | --- | --- |
| RE2 2025-11-05 | Linear in input; compile and DFA-cache budget, with NFA fallback after DFA exhaustion | UTF-8 by default, `Latin1` option, `\C` byte atom; all BuiltInGrammar expressions; rejects Vim `\c` | C++17, 22 RE2 source files, Abseil 20250512.1, C++ runtime, threading; upstream Linux/macOS CI and documented Windows builds | RE2 BSD-3-Clause; Abseil Apache-2.0 | **Choose** |
| Rust `regex` 1.13.1 / `rure` 0.2.5 at commit `2b527599eb9eea0dcc288c704584f242f26a5c61` | Worst-case `O(m*n)`; bounded memory; safe parser limits | `regex::bytes::Regex`; exact engine family used by Tree-sitter's official Rust binding; best semantic compatibility | Requires Cargo/rustc plus a Rust/C static-library build for every target; adds a second compiler toolchain to the Zig build | MIT OR Apache-2.0; Unicode data has its own notice | Reject build/toolchain cost |
| PCRE2 10.47 | Default/JIT engine has worst-case exponential time; DFA is polynomial, not a linear guarantee, and changes semantics/features | Excellent byte, UTF, and PCRE compatibility; not Tree-sitter's defined dialect | Portable C99; upstream Zig build; continuously tested on many OS/CPU pairs | BSD-3-Clause WITH PCRE2 exception | Reject untrusted-pattern complexity behavior |
| Pure Zig restricted Thompson NFA | Can guarantee `O(pattern * text)` time and `O(pattern)` active-state memory | Contract below covers BuiltInGrammars but is a new dialect with lower UserGrammar compatibility | No dependency; follows Zig targets | No added third-party license | Reject bespoke engine maintenance for M17 |

## No-dependency fallback

If adding C++ and Abseil is not acceptable, use a named **bbr-regex-v1** dialect, not ad hoc matching.
Its exact grammar is:

```text
expr   := alt
alt    := concat ("|" concat)*
concat := repeat*
repeat := atom ("*" | "+" | "?" | "{" n "}" | "{" n "," n? "}")?
atom   := literal | "." | "^" | "$" | class | "(" expr ")"
class  := "[" "^"? class-item+ "]"
class-item := literal | literal "-" literal | "\\d" | "\\s" | "\\w"
```

Literals are ASCII bytes or valid UTF-8 scalar literals. Escapes are `\\`, escaped ASCII
punctuation, `\n`, `\r`, `\t`, `\xHH`, and ASCII `\dDsSwW`. `.` consumes one UTF-8 scalar except
LF. Classes and ranges are byte/ASCII-only. Groups do not capture. Matching is unanchored unless
`^` or `$` constrains it. Limits are 4096 pattern bytes, nesting 64, repeat count 1000, and 8192
compiled NFA states. All other syntax is a validation error with the expression byte offset and
expected token.

This can be implemented as a Thompson NFA without backtracking and it covers the BuiltInGrammar
inventory. It is not recommended because bbr would own a parser, compiler, VM, UTF-8 edge cases,
fuzzing burden, and a non-standard UserGrammar contract. It earns zero dependency cost by moving
the cost into long-term application code.

## Primary sources

- [RE2 2025-11-05 release and archive digest](https://github.com/google/re2/releases/tag/2025-11-05)
- [RE2 2025-11-05 release metadata, including asset SHA-256](https://api.github.com/repos/google/re2/releases/tags/2025-11-05)
- [RE2 safety, linear-time, syntax, build, and platform statements](https://github.com/google/re2/blob/2025-11-05/README.md)
- [RE2 exact syntax](https://github.com/google/re2/blob/2025-11-05/doc/syntax.txt)
- [RE2 options, encoding, memory budget, and error API](https://github.com/google/re2/blob/2025-11-05/re2/re2.h)
- [RE2 dependency pin and C++ requirements](https://github.com/google/re2/blob/2025-11-05/MODULE.bazel)
- [RE2 upstream CI matrix](https://github.com/google/re2/blob/2025-11-05/.github/workflows/ci.yml)
- [RE2 BSD-3-Clause license](https://github.com/google/re2/blob/2025-11-05/LICENSE)
- [Zig 0.16 Build module C++ source and libc++ controls](https://github.com/ziglang/zig/blob/0.16.0/lib/std/Build/Module.zig)
- [Abseil 20250512.1 release, digest, and C++17 requirement](https://github.com/abseil/abseil-cpp/releases/tag/20250512.1)
- [Abseil 20250512.1 release metadata, including asset SHA-256](https://api.github.com/repos/abseil/abseil-cpp/releases/tags/20250512.1)
- [Abseil Apache-2.0 license](https://github.com/abseil/abseil-cpp/blob/20250512.1/LICENSE)
- [Tree-sitter v0.26.9 predicate contract and statement that C does not evaluate predicates](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/docs/src/using-parsers/queries/3-predicates-and-directives.md)
- [Tree-sitter v0.26.9 Rust binding uses `regex::bytes::Regex`](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/lib/binding_rust/lib.rs)
- [Tree-sitter v0.26.9 Rust dependency declaration](https://github.com/tree-sitter/tree-sitter/blob/v0.26.9/lib/Cargo.toml)
- [Rust regex 1.13.1 linear-time, bytes, dependency, target, and license statements](https://github.com/rust-lang/regex/tree/1.13.1)
- [`rure` first-party C API and byte/UTF-8 behavior](https://github.com/rust-lang/regex/tree/1.13.1/regex-capi)
- [PCRE2 10.47 release](https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.47)
- [PCRE2 engine complexity, targets, byte modes, build, and license summary](https://github.com/PCRE2Project/pcre2/blob/pcre2-10.47/README.md)
- [PCRE2 standard and DFA algorithm semantics](https://github.com/PCRE2Project/pcre2/blob/pcre2-10.47/doc/pcre2matching.3)
- [PCRE2's upstream Zig build](https://github.com/PCRE2Project/pcre2/blob/pcre2-10.47/build.zig)
- [Neovim v0.11.4 `#match?` is Vim regex and anchors cover node text](https://github.com/neovim/neovim/blob/v0.11.4/runtime/doc/treesitter.txt)
- [Neovim v0.11.4 predicate implementation](https://github.com/neovim/neovim/blob/v0.11.4/runtime/lua/vim/treesitter/query.lua)
- [nvim-treesitter highlight-query corpus checked at `e82ef6ae`](https://github.com/nvim-treesitter/nvim-treesitter/tree/e82ef6ae2c3eeb96c6916b29917f96bf630b2cdb/runtime/queries)
- [Current repository predicate inventory](./07-tree-sitter-query-predicate-contract.md)
