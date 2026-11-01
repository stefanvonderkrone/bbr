"""The code text of each source line, without its comment.

Every line checker in tools/ reads source through this module, so a comment
that quotes a forbidden pattern never fails a check, and a comment marker
inside a string literal never hides code.
"""


def zig_code(text):
    """Each line of Zig source without its `//`, `///`, or `//!` comment.

    A `//` inside a "..." string, a '...' character, or a `\\\\` multiline
    string line is literal text.
    """
    return [_zig_line(line) for line in text.splitlines()]


def yaml_code(text):
    """Each line of YAML without its `#` comment.

    A `#` starts a comment at the start of a line or after whitespace, outside
    '...' and "..." quotes. The rule also holds for shell lines in a `run`
    block, so a commented-out command is not code.
    """
    return [_yaml_line(line) for line in text.splitlines()]


def _zig_line(line):
    index = 0
    while index < len(line):
        char = line[index]
        if line.startswith("//", index):
            return line[:index].rstrip()
        if line.startswith("\\\\", index):
            return line
        if char in "\"'":
            index = _literal_end(line, index, char, escape="\\")
        else:
            index += 1
    return line


def _yaml_line(line):
    index = 0
    while index < len(line):
        char = line[index]
        if char == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index].rstrip()
        if char == '"':
            index = _literal_end(line, index, char, escape="\\")
        elif char == "'":
            index = _literal_end(line, index, char, escape=None)
        else:
            index += 1
    return line


def _literal_end(line, start, quote, escape):
    """The index after the literal that opens at `start`, or the line end when it never closes."""
    index = start + 1
    while index < len(line):
        if line[index] == escape:
            index += 2
        elif line[index] == quote:
            return index + 1
        else:
            index += 1
    return len(line)
