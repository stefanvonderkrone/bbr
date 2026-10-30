"""Regression checks for the nvim-treesitter query adaptation."""

import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/adapt_queries.py"
spec = importlib.util.spec_from_file_location("adapt_queries", SCRIPT)
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)

COMMIT = "a2f694478be07f89c2d03cc17858a8745a400c4b"
BUILTIN = frozenset({"html", "css", "javascript", "markdown_inline", "yaml"})


def python_regex(re2):
    """Rewrite the RE2 escapes that Python re spells differently."""
    return re.sub(r"\\x\{([0-9a-f]+)\}", lambda match: f"\\U{int(match.group(1), 16):08x}", re2)


def zig_string(literal):
    """Decode a Zig string literal that uses only the escapes \\\\, \\", and \\xNN."""
    escaped = re.sub(r'\\(x[0-9a-f]{2}|["\\])', lambda m: chr(int(m.group(1)[1:], 16)) if m.group(1)[0] == "x" else m.group(1), literal[1:-1])
    return escaped.encode("latin-1").decode("utf-8")


def matcher(lua_pattern):
    return re.compile(python_regex(adapter.lua_to_re2(lua_pattern)))


class AdaptQueriesTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, name, text, kind="highlights"):
        path = self.root / name / f"{kind}.scm"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def adapt(self, name="lang", kind="highlights"):
        return adapter.adapt(name, kind, self.root, COMMIT, BUILTIN)

    def body(self, text, kind="highlights"):
        self.write("lang", text, kind)
        return self.adapt(kind=kind).split("\n", 4)[4]

    def assert_fails(self, text, *parts, kind="highlights"):
        self.write("lang", text, kind)
        with self.assertRaises(adapter.AdaptError) as raised:
            self.adapt(kind=kind)
        for part in parts:
            self.assertIn(part, str(raised.exception))

    def test_header_names_the_source_and_the_commit(self):
        self.write("lang", "(identifier) @variable\n")
        lines = self.adapt().splitlines()
        self.assertIn("runtime/queries/lang/highlights.scm", lines[0])
        self.assertIn(COMMIT, lines[0])
        self.assertIn("Apache-2.0", lines[1])
        self.assertIn("bbr changed this query", lines[2])
        self.assertEqual(lines[4], "(identifier) @variable")

    def test_inherits_resolve_nested_and_optional_bases_in_order(self):
        self.write("base", "(base) @base\n")
        self.write("middle", "; inherits: base\n(middle) @middle\n")
        self.write("other", "(other) @other\n")
        self.write("lang", "; inherits: middle,(absent),other,(base)\n(lang) @lang\n")
        result = self.adapt()
        order = [result.index(text) for text in (
            "; bbr: inherited from base\n(base) @base",
            "; bbr: inherited from middle\n; inherits: base\n(middle) @middle",
            "; bbr: inherited from other\n(other) @other",
            "(lang) @lang",
        )]
        self.assertEqual(order, sorted(order))
        self.assertEqual(result.count("; bbr: inherited from base"), 2)
        self.assertNotIn("absent", result.replace("(absent)", ""))

    def test_a_missing_required_base_stops_the_adaptation(self):
        self.assert_fails("; inherits: absent\n(lang) @lang\n", "lang/highlights.scm:1", "absent/highlights.scm")

    def test_an_inherits_cycle_stops_the_adaptation(self):
        self.write("other", "; inherits: lang\n")
        self.assert_fails("; inherits: other\n", "cycle")

    def test_lua_match_becomes_match_and_not_lua_match_becomes_not_match(self):
        result = self.body(
            '((identifier) @constant (#lua-match? @constant "^[A-Z][%w_]*$"))\n'
            '((identifier) @variable (#not-lua-match? @variable "^%u"))\n'
        )
        self.assertIn('(#match? @constant "^[A-Z][0-9A-Z_a-z]*$")', result)
        self.assertIn('(#not-match? @variable "^[A-Z]")', result)
        self.assertNotIn("lua-match", result)

    def test_contains_becomes_match_with_escaped_literal_alternatives(self):
        result = self.body('((identifier) @x (#contains? @x "a.b" "c(d" "plain"))\n')
        self.assertIn('(#match? @x "a\\\\.b|c\\\\(d|plain")', result)
        pattern = re.compile(adapter.decode_string('"a\\\\.b|c\\\\(d|plain"'))
        self.assertTrue(pattern.search("xa.by"))
        self.assertFalse(pattern.search("axb"))
        self.assertTrue(pattern.search("c(d"))

    def test_the_rewrite_escapes_backslashes_and_quotes_for_the_query_string(self):
        result = self.body('((string) @s (#lua-match? @s "^%\\"%.\\\\"))\n')
        self.assertIn('(#match? @s "^\\"\\\\.\\\\\\\\")', result)

    def test_each_lua_class_and_its_complement(self):
        samples = {
            "a": ("q", "Z", "1", "_"),
            "d": ("0", "9", "a", " "),
            "l": ("a", "z", "A", "1"),
            "s": (" ", "\t", "x", "_"),
            "u": ("A", "Z", "a", "1"),
            "w": ("a", "7", "_", "-"),
            "x": ("f", "C", "g", "z"),
            "p": ("!", "~", "a", " "),
            "c": ("\x01", "\x7f", "a", " "),
        }
        for letter, (in_a, in_b, out_a, out_b) in samples.items():
            for wrapped in (f"^%{letter}$", f"^[%{letter}]$"):
                with self.subTest(pattern=wrapped):
                    pattern = matcher(wrapped)
                    self.assertTrue(pattern.search(in_a) and pattern.search(in_b))
                    self.assertFalse(pattern.search(out_a) or pattern.search(out_b))
            upper = letter.upper()
            for wrapped in (f"^%{upper}$", f"^[%{upper}]$"):
                with self.subTest(pattern=wrapped):
                    pattern = matcher(wrapped)
                    self.assertTrue(pattern.search(out_a) and pattern.search(out_b))
                    self.assertFalse(pattern.search(in_a) or pattern.search(in_b))
                    self.assertTrue(pattern.search("\u00e9"))

    def test_escapes_sets_anchors_and_quantifiers(self):
        cases = {
            "^%.%-%%$": ([".-%"], ["a-%", ".-%x"]),
            "^[^%s,]+$": (["ab"], ["a b", "a,b", ""]),
            "^[a-c_%-]*$": (["ab_-c", ""], ["d"]),
            "^[]x]$": (["]", "x"], ["a"]),
            "a.-b": (["a\nb", "ab"], ["a"]),
            "x^$y": (["x^$y"], ["xy"]),
            "^*a+b?$": (["*aa", "*ab"], ["aa"]),
            "^(%d+)%.": (["12."], ["a."]),
            "^%${": (["${x"], ["{"]),
        }
        for lua, (accepted, rejected) in cases.items():
            pattern = matcher(lua)
            for text in accepted:
                with self.subTest(pattern=lua, text=text):
                    self.assertTrue(pattern.search(text))
            for text in rejected:
                with self.subTest(pattern=lua, text=text):
                    self.assertFalse(pattern.search(text))

    def test_lazy_quantifier_takes_the_shortest_match(self):
        self.assertEqual(adapter.lua_to_re2("<.->"), "<(?s:.)*?>")
        self.assertEqual(matcher("<.->").search("<a><b>").group(), "<a>")

    def test_balance_frontier_and_back_references_stop_the_adaptation(self):
        for lua, message in (("%b()", "%b"), ("%f[%w]x", "%f"), ("(a)%1", "back reference"), ("()", "position")):
            with self.subTest(pattern=lua):
                self.assert_fails(f'((x) @x (#lua-match? @x "{lua}"))\n', "lang/highlights.scm:1", message, "#lua-match?")

    def test_neovim_directives_are_removed_with_a_record(self):
        result = self.body(
            '((x) @x\n'
            '  (#set! conceal "")\n'
            '  (#set! conceal_lines ""))\n'
            '((link) @label (#set! @label url @label))\n'
            '((y) @y (#offset! @y 0 1 0 -1) (#eq? @y "z"))\n'
        )
        self.assertIn('  ; bbr: removed (#set! conceal "")\n  ; bbr: removed (#set! conceal_lines "")\n  )', result)
        self.assertIn("((link) @label ; bbr: removed (#set! @label url @label)\n)", result)
        self.assertIn('((y) @y ; bbr: removed (#offset! @y 0 1 0 -1)\n (#eq? @y "z"))', result)

    def test_neovim_captures_are_removed_with_a_record(self):
        result = self.body("(comment) @comment @spell\n(a) @nospell\n((b) @conceal @conceal_lines (#eq? @b \"b\"))\n")
        self.assertIn("(comment) @comment ; bbr: removed @spell\n", result)
        self.assertIn("(a) ; bbr: removed @nospell\n", result)
        self.assertIn("; bbr: removed @conceal\n", result)
        self.assertIn("; bbr: removed @conceal_lines\n", result)
        for capture in ("@spell", "@nospell", "@conceal", "@conceal_lines"):
            self.assertEqual(len(re.findall(rf"{capture}(?![\w.-])", result)), 1)

    def test_hidden_captures_strings_and_comments_stay(self):
        source = (
            '; (#set! conceal "") @spell in a comment\n'
            '((identifier) @_name "@spell ; (#offset!)" (#eq? @_name "x"))\n'
        )
        self.assertEqual(self.body(source), source)

    def test_supported_forms_stay_unchanged(self):
        source = (
            '((a) @a (#eq? @a "x") (#not-eq? @a "y") (#match? @a "^z") (#not-match? @a "w"))\n'
            '((b) @b (#any-of? @b "p" "q") (#not-any-of? @b "r"))\n'
            "((c) @c (#has-ancestor? @c d e) (#not-has-ancestor? @c f) (#has-parent? @c g) (#not-has-parent? @c h))\n"
            '((d) @d (#is-not? local) (#set! priority 105) (#set! "priority" 90))\n'
            "(e (f) @f (#set! priority 95))\n"
        )
        self.assertEqual(self.body(source), source)

    def test_an_unknown_predicate_stops_the_adaptation_with_file_line_and_form(self):
        self.assert_fails('(a) @a\n\n((b) @b\n  (#vim-match? @b "x"))\n', "lang/highlights.scm:4", '(#vim-match? @b "x")')

    def test_unsupported_forms_stop_the_adaptation(self):
        for form in (
            "(#is-not? global)",
            "(#set! injection.language \"css\")",
            "(#set! priority high)",
            '(#gsub! @a "x" "y")',
            "(#eq? @spell \"x\")",
        ):
            with self.subTest(form=form):
                self.assert_fails(f"((a) @a {form})\n", "lang/highlights.scm:1", form)

    def test_a_base_failure_names_the_base_file(self):
        self.write("base", '\n((a) @a (#unknown! @a))\n')
        self.assert_fails("; inherits: base\n", "base/highlights.scm:2", "(#unknown! @a)")

    def test_injection_patterns_keep_builtin_and_dynamic_languages(self):
        result = self.body(
            "(fenced (info (language) @injection.language) (content) @injection.content)\n"
            '((html_block) @injection.content\n  (#set! injection.language "html")\n  (#set! injection.combined)\n'
            "  (#set! injection.include-children))\n"
            '((front) @injection.content (#set! injection.language "yaml") (#offset! @injection.content 1 0 -1 0))\n'
            "; a comment before a removed pattern\n"
            '((latex_block) @injection.content\n  (#set! injection.language "latex"))\n'
            '(x (y (z) @injection.content (#set! injection.language "regex")))\n'
            '((tag) @injection.language (#gsub! @injection.language "(.+)/(.+)" "%2"))\n',
            kind="injections",
        )
        self.assertIn("(fenced (info (language) @injection.language) (content) @injection.content)\n", result)
        self.assertIn('(#set! injection.language "html")', result)
        self.assertIn("(#set! injection.include-children))", result)
        self.assertIn("(#offset! @injection.content 1 0 -1 0))", result)
        self.assertIn("; a comment before a removed pattern\n; bbr: removed pattern for latex\n", result)
        self.assertIn("\n; bbr: removed pattern for regex\n", result)
        self.assertNotIn("latex_block", result)
        self.assertIn('; bbr: removed (#gsub! @injection.language "(.+)/(.+)" "%2")\n)', result)

    def test_injection_forms_outside_the_supported_set_stop_the_adaptation(self):
        for form in ("(#offset! @other 0 0 0 0)", "(#set! injection.self)"):
            with self.subTest(form=form):
                self.assert_fails(
                    f'((a) @injection.content (#set! injection.language "css") {form})\n', form, kind="injections"
                )
        self.assert_fails("((a) @injection.content)\n", "names no language", kind="injections")

    def test_injections_need_builtin_names(self):
        self.write("lang", "", "injections")
        with self.assertRaises(ValueError):
            adapter.adapt("lang", "injections", self.root, COMMIT)

    def test_two_runs_give_the_same_bytes(self):
        self.write("base", '((a) @a @spell (#lua-match? @a "^%a+$") (#set! conceal ""))\n')
        self.write("lang", '; inherits: base\n((b) @b (#contains? @b "x" "y"))\n')
        self.assertEqual(self.adapt().encode(), self.adapt().encode())

    def test_the_lua_pattern_cases_hold_the_current_translation(self):
        cases = (SCRIPT.parents[1] / "src/highlight/lua_pattern_cases.zig").read_text(encoding="utf-8")
        pairs = re.findall(r'\.lua = ("(?:\\.|[^"\\])*"), \.re2 = ("(?:\\.|[^"\\])*")', cases)
        self.assertGreater(len(pairs), 40)
        for lua, re2 in pairs:
            with self.subTest(pattern=lua):
                self.assertEqual(adapter.lua_to_re2(zig_string(lua)), zig_string(re2))

    def test_the_cli_prints_the_adapted_query(self):
        self.write("lang", '(a) @a @spell\n', "injections")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.root), "lang", "highlights", COMMIT],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("lang/highlights.scm", result.stderr)
        self.write("lang", "(a) @a @spell\n")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.root), "lang", "highlights", COMMIT, "--builtin", "css"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, self.adapt())


if __name__ == "__main__":
    unittest.main()
