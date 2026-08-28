# 21 — Execute BuiltInGrammar Match Predicates

**What to build:** Validate and execute the `#match?` and `#eq?` predicates used by BuiltInGrammars so conditional Captures appear only for accepted query matches.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] The pinned RE2 and Abseil sources build through a length-bearing C ABI wrapper with the specified UTF-8, Perl-mode, unanchored, case-sensitive, non-multiline profile.
- [x] Regex validation enforces the 4096-byte pattern limit and 1 MiB memory limit and reports source-positioned diagnostics for unsupported or invalid syntax.
- [x] Grammar validation accepts valid `#match?` and `#eq?` predicates and atomically rejects unknown operators, directives, malformed arguments, ranges, regexes, and properties.
- [x] A false predicate removes only its query match, while fallback Captures and later-pattern precedence remain intact.
- [x] Length-bearing matching supports UTF-8 and embedded NUL, and cursor match loss fails Highlighting instead of returning partial Spans.
