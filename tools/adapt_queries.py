#!/usr/bin/env python3
"""Adapt a raw nvim-treesitter query for the bbr tree-sitter runtime.

The adaptation reads S-expression forms, never lines. Each edit replaces the span of one form or
one token, so formatting outside the edits stays byte for byte.
"""

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys

HIGHLIGHTS = "highlights"
INJECTIONS = "injections"
KINDS = (HIGHLIGHTS, INJECTIONS)

KEPT_PREDICATES = frozenset(
    {
        "#eq?",
        "#match?",
        "#not-eq?",
        "#not-match?",
        "#any-of?",
        "#not-any-of?",
        "#has-ancestor?",
        "#not-has-ancestor?",
        "#has-parent?",
        "#not-has-parent?",
    }
)
LUA_PREDICATES = {"#lua-match?": "#match?", "#not-lua-match?": "#not-match?"}
REMOVED_CAPTURES = frozenset({"@spell", "@nospell", "@conceal", "@conceal_lines"})
REMOVED_SET_KEYS = frozenset({"conceal", "conceal_lines", "url"})
INJECTION_FLAGS = frozenset({"injection.combined", "injection.include-children"})
INHERITS = re.compile(r";+\s*inherits\s*:?\s*(\S.*?)\s*")
BASE_NAME = re.compile(r"(\()?([a-z0-9_]+)(\))?")
INTEGER = re.compile(r"-?\d+")


class AdaptError(Exception):
    """An adaptation failure. The message names the file, the line, and the form."""


@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    start: int
    end: int
    line: int


@dataclass(frozen=True)
class Form:
    open: Token
    items: tuple
    close: Token

    @property
    def start(self):
        return self.open.start

    @property
    def end(self):
        return self.close.end

    @property
    def line(self):
        return self.open.line

    def words(self):
        return [item for item in self.items if not (isinstance(item, Token) and item.kind == "comment")]

    def predicate(self):
        words = self.words()
        if self.open.text == "(" and words and isinstance(words[0], Token) and words[0].text.startswith("#"):
            return words[0]
        return None


def tokenize(text, label):
    tokens = []
    i, line, n = 0, 1, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            line += c == "\n"
            i += 1
            continue
        if c == ";":
            j = text.find("\n", i)
            j, kind = (n if j < 0 else j), "comment"
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            if j >= n:
                raise AdaptError(f"{label}:{line}: unterminated string")
            j, kind = j + 1, "string"
        elif c in "([":
            j, kind = i + 1, "open"
        elif c in ")]":
            j, kind = i + 1, "close"
        else:
            j = i + 1
            while j < n and not text[j].isspace() and text[j] not in '()[]";@':
                j += 1
            kind = "capture" if c == "@" else "atom"
        tokens.append(Token(kind, text[i:j], i, j, line))
        line += text.count("\n", i, j)
        i = j
    return tokens


def parse(text, label):
    stack, opens = [[]], []
    for token in tokenize(text, label):
        if token.kind == "open":
            opens.append(token)
            stack.append([])
        elif token.kind == "close":
            if not opens:
                raise AdaptError(f"{label}:{token.line}: unmatched {token.text}")
            opening = opens.pop()
            if (opening.text, token.text) not in (("(", ")"), ("[", "]")):
                raise AdaptError(f"{label}:{token.line}: {token.text} closes {opening.text} from line {opening.line}")
            items = stack.pop()
            stack[-1].append(Form(opening, tuple(items), token))
        else:
            stack[-1].append(token)
    if opens:
        raise AdaptError(f"{label}:{opens[-1].line}: unclosed {opens[-1].text}")
    return stack[0]


def form_text(item):
    if isinstance(item, Token):
        return item.text
    return item.open.text + " ".join(form_text(word) for word in item.words()) + item.close.text


def decode_string(literal):
    out, i, body = [], 0, literal[1:-1]
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            out.append({"n": "\n", "r": "\r", "t": "\t", "0": "\0"}.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def encode_string(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'


def value_text(token):
    if token.kind == "string":
        return decode_string(token.text)
    if token.kind == "atom":
        return token.text
    return None


# Lua classes in the C locale, as inclusive code point ranges.
LUA_CLASSES = {
    "a": ((0x41, 0x5A), (0x61, 0x7A)),
    "c": ((0x00, 0x1F), (0x7F, 0x7F)),
    "d": ((0x30, 0x39),),
    "l": ((0x61, 0x7A),),
    "p": ((0x21, 0x2F), (0x3A, 0x40), (0x5B, 0x60), (0x7B, 0x7E)),
    "s": ((0x09, 0x0D), (0x20, 0x20)),
    "u": ((0x41, 0x5A),),
    "w": ((0x30, 0x39), (0x41, 0x5A), (0x61, 0x7A)),
    "x": ((0x30, 0x39), (0x41, 0x46), (0x61, 0x66)),
}
MAX_CODE_POINT = 0x10FFFF
REGEX_META = frozenset("\\.+*?()|[]{}^$-")


class LuaPatternError(Exception):
    pass


def regex_char(c):
    ch = chr(c)
    if 0x20 <= c < 0x7F:
        return "\\" + ch if ch in REGEX_META else ch
    if c < 0x100:
        return f"\\x{c:02x}"
    return f"\\x{{{c:x}}}"


def regex_literal(ch):
    return ch if not ch.isascii() else regex_char(ord(ch))


def merge(ranges):
    merged = []
    for low, high in sorted(ranges):
        if merged and low <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], high))
        else:
            merged.append((low, high))
    return merged


def complement(ranges):
    out, low = [], 0
    for start, end in merge(ranges):
        if start > low:
            out.append((low, start - 1))
        low = end + 1
    if low <= MAX_CODE_POINT:
        out.append((low, MAX_CODE_POINT))
    return out


def lua_class(letter):
    ranges = LUA_CLASSES.get(letter.lower())
    if ranges is None:
        raise LuaPatternError(f"unsupported Lua class %{letter}")
    return ranges


def class_ranges(letter):
    ranges = lua_class(letter)
    return list(ranges) if letter.islower() else complement(ranges)


def regex_set(ranges, negated):
    parts = []
    for low, high in merge(ranges):
        if low == high:
            parts.append(regex_char(low))
        elif high == low + 1:
            parts.append(regex_char(low) + regex_char(high))
        else:
            parts.append(regex_char(low) + "-" + regex_char(high))
    return "[" + ("^" if negated else "") + "".join(parts) + "]"


def lua_set(pattern, i):
    j, n = i + 1, len(pattern)
    negated = j < n and pattern[j] == "^"
    j += negated
    ranges, first = [], True
    while True:
        if j >= n:
            raise LuaPatternError("unclosed set")
        c = pattern[j]
        if c == "]" and not first:
            return regex_set(ranges, negated), j + 1
        first = False
        if not c.isascii():
            raise LuaPatternError(f"non-ASCII {c} in a set matches bytes in Lua")
        if c == "%":
            if j + 1 >= n:
                raise LuaPatternError("set ends with %")
            escaped = pattern[j + 1]
            ranges.extend(class_ranges(escaped) if escaped.isalpha() else [(ord(escaped), ord(escaped))])
            j += 2
        elif j + 2 < n and pattern[j + 1] == "-" and pattern[j + 2] != "]":
            if not pattern[j + 2].isascii():
                raise LuaPatternError(f"non-ASCII {pattern[j + 2]} in a set matches bytes in Lua")
            ranges.append((ord(c), ord(pattern[j + 2])))
            j += 3
        else:
            ranges.append((ord(c), ord(c)))
            j += 1


def lua_to_re2(pattern):
    """Translate a Lua pattern to an RE2 pattern with the same matches."""
    out, i, n = [], 0, len(pattern)
    if pattern.startswith("^"):
        out.append("^")
        i = 1
    while i < n:
        c = pattern[i]
        if c == "$" and i == n - 1:
            out.append("$")
            i += 1
            continue
        if c == "(":
            if pattern[i + 1 : i + 2] == ")":
                raise LuaPatternError("position capture ()")
            out.append("(")
            i += 1
            continue
        if c == ")":
            out.append(")")
            i += 1
            continue
        if c == "%":
            if i + 1 >= n:
                raise LuaPatternError("pattern ends with %")
            escaped = pattern[i + 1]
            if escaped in "bf":
                raise LuaPatternError(f"%{escaped} has no RE2 form")
            if escaped.isdigit():
                raise LuaPatternError(f"back reference %{escaped} has no RE2 form")
            if escaped.isalpha():
                item = regex_set(lua_class(escaped), escaped.isupper())
            else:
                item = regex_literal(escaped)
            i += 2
        elif c == "[":
            item, i = lua_set(pattern, i)
        elif c == ".":
            item = "(?s:.)"
            i += 1
        else:
            item = regex_literal(c)
            i += 1
            if not c.isascii() and i < n and pattern[i] in "*+?-":
                raise LuaPatternError(f"quantifier after non-ASCII {c} repeats one byte in Lua")
        if i < n and pattern[i] in "*+?-":
            out.append(item + ("*?" if pattern[i] == "-" else pattern[i]))
            i += 1
        else:
            out.append(item)
    return "".join(out)


class _QueryFile:
    def __init__(self, label, text, kind, builtin_names):
        self.label = label
        self.text = text
        self.kind = kind
        self.builtin_names = builtin_names
        self.edits = []

    def fail(self, item, message):
        raise AdaptError(f"{self.label}:{item.line}: {message}: {form_text(item)}")

    def adapt(self):
        items = parse(self.text, self.label)
        if self.kind == HIGHLIGHTS:
            self.walk(items)
        else:
            for pattern in top_level_patterns(items):
                self.injection_pattern(pattern)
        return self.apply()

    def apply(self):
        out, position = [], 0
        for start, end, replacement in sorted(self.edits):
            assert start >= position, "adaptation edits overlap"
            out.append(self.text[position:start])
            out.append(replacement)
            position = end
        out.append(self.text[position:])
        result = "".join(out)
        return result if result.endswith("\n") else result + "\n"

    def replace(self, item, replacement):
        self.edits.append((item.start, item.end, replacement))

    def remove(self, item, what):
        line_end = self.text.find("\n", item.end)
        rest = self.text[item.end : len(self.text) if line_end < 0 else line_end].strip()
        line_start = self.text.rfind("\n", 0, item.start) + 1
        indent = re.match(r"[ \t]*", self.text[line_start:]).group()
        tail = "\n" + indent if rest and not rest.startswith(";") else ""
        self.replace(item, f"; bbr: removed {what}{tail}")

    def walk(self, items):
        for item in items:
            if isinstance(item, Form):
                if item.predicate():
                    self.predicate(item)
                else:
                    self.walk(item.items)
            elif item.kind == "capture" and item.text in REMOVED_CAPTURES:
                self.remove(item, item.text)

    def predicate(self, form):
        words = form.words()
        name, args = words[0].text, words[1:]
        if any(isinstance(arg, Form) for arg in args):
            self.fail(form, "nested form in a predicate")
        if name in KEPT_PREDICATES or (name == "#is-not?" and [arg.text for arg in args] == ["local"]):
            self.keep(form, args)
        elif name in LUA_PREDICATES:
            self.lua_predicate(form, words[0], args)
        elif name == "#contains?":
            self.contains(form, words[0], args)
        elif name == "#set!":
            self.set_directive(form, args)
        elif name == "#offset!" and self.kind == HIGHLIGHTS:
            self.remove(form, form_text(form))
        elif name == "#offset!" and self.is_content_offset(args):
            pass
        elif name == "#gsub!" and self.kind == INJECTIONS:
            self.remove(form, form_text(form))
        else:
            self.fail(form, f"unsupported {self.kind} form")

    def keep(self, form, args):
        for arg in args:
            if arg.kind == "capture" and arg.text in REMOVED_CAPTURES:
                self.fail(form, f"a kept predicate uses the removed capture {arg.text}")

    def lua_predicate(self, form, head, args):
        if len(args) != 2 or args[0].kind != "capture" or args[1].kind != "string":
            self.fail(form, "expected a capture and a pattern string")
        self.keep(form, args)
        try:
            translated = lua_to_re2(decode_string(args[1].text))
        except LuaPatternError as error:
            self.fail(form, str(error))
        self.replace(head, LUA_PREDICATES[head.text])
        self.replace(args[1], encode_string(translated))

    def contains(self, form, head, args):
        if len(args) < 2 or args[0].kind != "capture" or any(arg.kind != "string" for arg in args[1:]):
            self.fail(form, "expected a capture and literal strings")
        if len(form.words()) != len(form.items):
            self.fail(form, "comment inside #contains?")
        self.keep(form, args)
        alternatives = "|".join("".join(map(regex_literal, decode_string(arg.text))) for arg in args[1:])
        self.replace(head, "#match?")
        self.edits.append((args[1].start, args[-1].end, encode_string(alternatives)))

    def set_directive(self, form, args):
        key_index = 1 if args and args[0].kind == "capture" else 0
        key = value_text(args[key_index]) if len(args) > key_index else None
        values = args[key_index + 1 :]
        if key in REMOVED_SET_KEYS:
            self.remove(form, form_text(form))
        elif key_index == 0 and key == "priority" and len(values) == 1 and values[0].kind == "atom":
            if not INTEGER.fullmatch(values[0].text):
                self.fail(form, "priority is not an integer")
        elif self.kind == INJECTIONS and key_index == 0 and key == "injection.language":
            if len(values) != 1 or values[0].kind != "string":
                self.fail(form, "expected one injection.language string")
        elif self.kind == INJECTIONS and key_index == 0 and key in INJECTION_FLAGS and not values:
            pass
        else:
            self.fail(form, f"unsupported {self.kind} directive")

    @staticmethod
    def is_content_offset(args):
        return (
            len(args) == 5
            and args[0].text == "@injection.content"
            and all(arg.kind == "atom" and INTEGER.fullmatch(arg.text) for arg in args[1:])
        )

    def injection_pattern(self, pattern):
        language_capture = any(
            token.kind == "capture" and token.text == "@injection.language" for token in pattern_tokens(pattern)
        )
        language = static_language(pattern)
        if language_capture or language in self.builtin_names:
            self.walk(pattern)
            return
        if language is None:
            self.fail(pattern[0], "injection pattern names no language")
        self.edits.append((pattern[0].start, pattern[-1].end, f"; bbr: removed pattern for {language}"))


def top_level_patterns(items):
    """Group top-level items into patterns. A capture or a quantifier belongs to the item before it."""
    patterns = []
    for item in items:
        if isinstance(item, Token) and item.kind == "comment":
            continue
        attached = isinstance(item, Token) and (item.kind == "capture" or item.text in ("*", "+", "?"))
        if attached and patterns:
            patterns[-1].append(item)
        else:
            patterns.append([item])
    return patterns


def pattern_tokens(items):
    """Yield the tokens of a pattern outside its predicate forms."""
    for item in items:
        if isinstance(item, Form):
            if not item.predicate():
                yield from pattern_tokens(item.items)
        else:
            yield item


def static_language(items):
    for item in items:
        if not isinstance(item, Form):
            continue
        head = item.predicate()
        if head is None:
            found = static_language(item.items)
            if found is not None:
                return found
            continue
        words = item.words()
        if head.text == "#set!" and len(words) == 3 and value_text(words[1]) == "injection.language":
            return value_text(words[2])
    return None


def inherited(text, label):
    first_line = text.split("\n", 1)[0]
    match = INHERITS.fullmatch(first_line)
    if match is None:
        return []
    bases = []
    for entry in match.group(1).split(","):
        base = BASE_NAME.fullmatch(entry.strip())
        if base is None or bool(base.group(1)) != bool(base.group(3)):
            raise AdaptError(f"{label}:1: malformed inherits entry: {entry.strip()}")
        bases.append((base.group(2), bool(base.group(1))))
    return bases


def sources(name, kind, raw_root, chain=(), inheritor=None, optional=False):
    """Return (name, text) for each query in order: every base before the query that inherits it."""
    label = f"{name}/{kind}.scm"
    path = raw_root / name / f"{kind}.scm"
    if not path.is_file():
        if optional:
            return []
        if inheritor is None:
            raise AdaptError(f"{label}: missing query")
        raise AdaptError(f"{inheritor}/{kind}.scm:1: missing base query {label}")
    text = path.read_text(encoding="utf-8")
    order = []
    for base, base_optional in inherited(text, label):
        if base in chain or base == name:
            raise AdaptError(f"{label}:1: inherits cycle through {base}")
        order.extend(sources(base, kind, raw_root, chain + (name,), name, base_optional))
    order.append((name, text))
    return order


def adapt(name, kind, raw_root, commit, builtin_names=None):
    """Return the adapted query text for raw_root/<name>/<kind>.scm and its bases."""
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {KINDS}, not {kind!r}")
    if kind == INJECTIONS and builtin_names is None:
        raise ValueError("an injections adaptation needs builtin_names")
    names = frozenset(builtin_names or ())
    header = (
        f"; bbr: adapted from nvim-treesitter runtime/queries/{name}/{kind}.scm at commit {commit}.\n"
        "; bbr: The nvim-treesitter queries are Apache-2.0, see vendors/tree-sitter/nvim-treesitter/LICENSE.\n"
        '; bbr: bbr changed this query. Each "; bbr:" comment records one change.\n'
    )
    parts = [header]
    for source_name, text in sources(name, kind, Path(raw_root)):
        body = _QueryFile(f"{source_name}/{kind}.scm", text, kind, names).adapt()
        parts.append(body if source_name == name else f"; bbr: inherited from {source_name}\n{body}")
    return "\n".join(parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("raw_root", type=Path)
    parser.add_argument("name")
    parser.add_argument("kind", choices=KINDS)
    parser.add_argument("commit")
    parser.add_argument("--builtin", default=None, help="comma-separated BuiltInGrammar names")
    arguments = parser.parse_args()
    builtin = None if arguments.builtin is None else frozenset(filter(None, arguments.builtin.split(",")))
    try:
        result = adapt(arguments.name, arguments.kind, arguments.raw_root, arguments.commit, builtin)
    except AdaptError as error:
        print(error, file=sys.stderr)
        return 1
    sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
