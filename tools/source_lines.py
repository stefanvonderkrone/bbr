"""The code text of each Zig source line, without its comment.

Every line checker in tools/ reads Zig source only through `zig_files`, so a
comment that quotes a forbidden pattern never fails a check, and a comment
marker inside a string literal never hides code.
"""


def zig_files(root, sources, *, literals):
    """Yield `(relative_path, code_lines)` for each Zig file in `sources`.

    Each source is a path relative to `root`. A directory stands for each
    `*.zig` file below it, in sorted order. `code_lines` comes from `zig_code`
    when `literals` is true, and from `zig_code_without_literals` otherwise.
    """
    code = zig_code if literals else zig_code_without_literals
    for source in sources:
        path = root / source
        for file in sorted(path.rglob("*.zig")) if path.is_dir() else (path,):
            yield file.relative_to(root), code(file.read_text(encoding="utf-8"))


def zig_code(text):
    """Each line of Zig source without its `//`, `///`, or `//!` comment.

    A `//` inside a "..." string, a '...' character, or a `\\\\` multiline
    string line is literal text.
    """
    return [_zig_line(line, mask=False) for line in text.splitlines()]


def zig_code_without_literals(text):
    """Each line of Zig source without its comment and with every literal emptied.

    A string becomes `""`, a character becomes `''`, and a `\\\\` multiline
    string line keeps only the code before its `\\\\`. A checker that looks for
    a call uses this, so text that quotes the call is not a match.
    """
    return [_zig_line(line, mask=True) for line in text.splitlines()]


def _zig_line(line, mask):
    code = []
    index = 0
    while index < len(line):
        char = line[index]
        if line.startswith("//", index):
            return "".join(code).rstrip()
        if line.startswith("\\\\", index):
            return "".join(code) + "\\\\" if mask else line
        if char in "\"'":
            end = _literal_end(line, index, char)
            code.append(char * 2 if mask else line[index:end])
            index = end
        else:
            code.append(char)
            index += 1
    return "".join(code)


def _literal_end(line, start, quote):
    """The index after the literal that opens at `start`, or the line end when it never closes."""
    index = start + 1
    while index < len(line):
        if line[index] == "\\":
            index += 2
        elif line[index] == quote:
            return index + 1
        else:
            index += 1
    return len(line)
