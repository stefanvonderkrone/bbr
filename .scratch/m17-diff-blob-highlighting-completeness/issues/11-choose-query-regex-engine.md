# Choose the query regex engine

Type: research
Status: resolved
Blocked by: none

## Question

Which pinned, byte-oriented regex engine and dialect should M17 use for tree-sitter `#match?` predicates under Zig 0.16, considering linear-time behavior, supported targets, dependency and build cost, licensing, UTF-8 byte semantics, and compatibility with BuiltInGrammar and credible UserGrammar queries; or, if no engine earns its cost, what restricted syntax and diagnostics form the durable contract?

## Answer

Use RE2 2025-11-05 at commit `927f5d53caf8111721e734cf24724686bb745f55`, with its pinned Abseil 20250512.1 dependency, through a small vendored C ABI wrapper. Pin both release archives by their published SHA-256 digests. The public contract is RE2 Perl mode, UTF-8 encoding, case-sensitive unanchored search, and no multiline mode. Pass captured node text through a length-bearing byte slice so embedded NUL is valid. RE2 scalar semantics apply by default; `\C` is the explicit byte atom, and `\d`, `\s`, and `\w` remain ASCII-only.

Compile each distinct expression during atomic Grammar validation. Limit a pattern to 4096 UTF-8 bytes and set RE2 `max_mem` to 1 MiB per compiled expression. Reject unsupported syntax such as backreferences, look-around, and Vim `\c`; do not rewrite it. A diagnostic names RE2-2025-11-05, the query source position, stable bbr reason, RE2 error code and fragment when present, and the pinned dialect URL. Retain the previous active Grammar after any validation failure.

This profile accepts all nine current BuiltInGrammar expressions and the documented tree-sitter examples. It accepts 25 of 48 regex predicates sampled from pinned nvim-treesitter highlight queries; the other 23 use Vim `\c`. RE2 provides linear matching and bounded compiled-program and DFA-cache memory for untrusted UserGrammar expressions. Rust `regex` has closer tree-sitter Rust-binding semantics but adds a second compiler toolchain. PCRE2 cannot provide the required linear-time contract with equivalent semantics. A private Thompson-NFA dialect avoids a dependency but gives bbr a parser, VM, fuzzing, and compatibility burden that costs more than RE2.

RE2 adds C++17, Abseil, libc++, threading, and 22 RE2 translation units. M17 must compile, link, and smoke-test the wrapper with Zig 0.16 on every declared bbr target before claiming that target. Current evidence covers upstream Linux and macOS CI plus documented Windows builds; the repository does not yet declare a release-target matrix.

Full pins, option values, diagnostics, conformance fixtures, candidate comparison, compatibility audit, and primary sources: [Query regex engine research](../research/11-query-regex-engine.md).
