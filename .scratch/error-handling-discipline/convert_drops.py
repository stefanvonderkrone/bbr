#!/usr/bin/env python3
"""Convert cause-dropping `catch` sites to the checked form that the compiler fills in.

A site `x catch H` becomes `x catch |err| switch (err) { error.A, error.B => H }`.
The prong names every error of the callee, and its body is the old handler
verbatim, so behavior does not change. The compiler supplies the names:

1. pending: the site is `catch |err| if (false) H else switch (err) {}`. The dead
   branch keeps every name in H referenced, so AstGen sees no new unused local.
   Zig rejects the empty switch with one `unhandled error value` note per error.
2. resolved: the names from the notes are written as one prong with body H.
3. reverted: the old text comes back, with a reason in the state file.

A site reverts when no analysis ever reaches it (an empty switch there would be
noreturn), when its set has more than --max-names names, when the callee set is
anyerror or unresolvable, when AstGen rejects the capture, when two generic
instantiations disagree, or when an out-of-memory handler meets a non-OOM error
(a mislabel finding). A chained catch or a handler that is not one expression
is never touched.

Zig reports only the first error in a function body per run, so the tool
rewrites, analyzes, and fills names until no site is pending. Analysis runs
`zig build analyze` through check_build.zig, which compiles every unfiltered
artifact of build.zig with -fno-emit-bin.

Run from the repository root:
    convert_drops.py --list              each drop, its group, and why it stays
    convert_drops.py --group oom-block   convert one group
    convert_drops.py --site PATH:LINE    convert one drop
    convert_drops.py --verify REV        fail unless each change since REV only wraps a handler

The state file records each outcome by a key of path, site text, and ordinal,
so a rerun skips a reverted site unless --retry is given.
"""

import argparse
import collections
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
STATE = HERE / "convert_drops.json"
BUILD_COPY = ROOT / ".convert_drops_build.zig"
sys.path.insert(0, str(ROOT / "tools"))

import check_diagnostics  # noqa: E402
from source_lines import zig_code_without_literals  # noqa: E402

GROUPS = ("oom-block", "return-error", "unreachable", "fallback", "empty")
OOM_WORDS = re.compile(r"\.out_of_memory\b|OutOfMemory|out of memory|\bOOM\b", re.IGNORECASE)
DIAGNOSTIC = re.compile(r"^(\S+?):(\d+):(\d+): (error|note): (.*)$")
UNHANDLED = re.compile(r"unhandled error value: 'error\.(\w+)'")
IDENT = re.compile(r"[A-Za-z_]\w*")
STOP_WORD = re.compile(r"(?:else|return)\b")
TIGHTER = re.compile(r"\s*(?:<<\|?|>>|\+\+|[-+*]%|[-+*]\||\*\*|\|\||[-+*/%])(?!=)")


def mask(text):
    """`text` with comments and literal contents replaced by spaces, so offsets stay the same."""
    out = list(text)
    index = 0
    while index < len(text):
        if text.startswith("//", index) or text.startswith("\\\\", index):
            while index < len(text) and text[index] != "\n":
                out[index] = " "
                index += 1
        elif text[index] in "\"'":
            quote = text[index]
            index += 1
            while index < len(text) and text[index] not in (quote, "\n"):
                if text[index] == "\\":
                    out[index] = " "
                    index += 1
                out[index] = " "
                index += 1
            index += 1
        else:
            index += 1
    return "".join(out)


def matching(masked, index):
    """The index of the bracket that closes the one at `index`."""
    depth = 0
    while index < len(masked):
        if masked[index] in "([{":
            depth += 1
        elif masked[index] in ")]}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise ValueError("unbalanced bracket")


def skip_space(masked, index):
    while index < len(masked) and masked[index].isspace():
        index += 1
    return index


def statement_end(masked, index):
    """The index of the first `;`, `,`, unmatched closer, or unmatched `else` after `index`.

    An `else` closes the operand of `return` or `break` unless an `if` inside
    the operand opened it.
    """
    depth = 0
    open_ifs = 0
    while index < len(masked):
        char = masked[index]
        word = IDENT.match(masked, index) if not IDENT.match(masked[index - 1 : index]) else None
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return index
            depth -= 1
        elif char in ";," and depth == 0:
            return index
        elif word and depth == 0 and word[0] in ("if", "while", "for"):
            open_ifs += 1
        elif word and depth == 0 and word[0] == "else":
            if open_ifs == 0:
                return index
            open_ifs -= 1
        index += word.end() - index if word else 1
    return index


def operand_end(masked, index):
    """The end of the expression that a catch handler starts at `index`, or None.

    The handler takes every operator that binds tighter than `catch`: the
    additive, multiplicative, and shift operators. It stops before `orelse`, a
    bitwise or comparison operator, `and`, `or`, and a terminator.
    """
    end = postfix_end(masked, index)
    while end is not None:
        operator = TIGHTER.match(masked, end)
        if not operator:
            return end
        end = postfix_end(masked, skip_space(masked, operator.end()))
    return None


def postfix_end(masked, index):
    """The end of a primary expression with its prefix and postfix operators, or None."""
    while masked.startswith(("&", "-", "!", "~"), index):
        index += 1
    if masked.startswith(".{", index):
        index = matching(masked, index + 1) + 1
    elif masked[index] in "\"'":
        index = masked.index(masked[index], index + 1) + 1
    elif masked[index] == "(":
        index = matching(masked, index) + 1
    elif masked[index] == "@":
        name = IDENT.match(masked, index + 1)
        if not name or masked[name.end()] != "(":
            return None
        index = matching(masked, name.end()) + 1
    elif masked[index] == ".":
        name = IDENT.match(masked, index + 1)
        if not name:
            return None
        index = name.end()
    else:
        name = re.compile(r"[A-Za-z_0-9]\w*").match(masked, index)
        if not name or name[0] in ("if", "switch", "while", "for", "try", "orelse", "catch"):
            return None
        index = name.end()
    while index < len(masked):
        if masked.startswith((".*", ".?"), index):
            index += 2
        elif masked[index] == "." and IDENT.match(masked, index + 1):
            index = IDENT.match(masked, index + 1).end()
        elif masked[index] in "([{":
            index = matching(masked, index) + 1
        else:
            return index
    return index


def handler_span(masked, start):
    """`(begin, end, problem)` of the handler after the `catch` keyword that ends at `start`."""
    begin = skip_space(masked, start)
    label = re.compile(r"[A-Za-z_]\w*:\s*\{").match(masked, begin)
    if masked.startswith("{", begin) or label:
        end = matching(masked, masked.index("{", begin)) + 1
    elif re.compile(r"(return|break|continue|if)\b").match(masked, begin):
        return begin, statement_end(masked, begin), None
    elif re.compile(r"unreachable\b").match(masked, begin):
        end = begin + len("unreachable")
    else:
        end = operand_end(masked, begin)
        if end is None:
            return begin, statement_end(masked, begin), "handler is not a simple expression"
    after = skip_space(masked, end)
    if after < len(masked) and masked[after] not in ";,)]}" and not re.compile(r"else\b").match(masked, after):
        return begin, end, "handler continues into another operator"
    return begin, end, None


def chained(masked, catch_at):
    """Whether the left operand of the catch at `catch_at` holds another catch at depth 0."""
    depth = 0
    index = catch_at - 1
    while index >= 0:
        char = masked[index]
        if char in ")]}":
            depth += 1
        elif char in "([{":
            if depth == 0:
                return False
            depth -= 1
        elif depth == 0 and (char in ";,=" or (STOP_WORD.match(masked, index) and not IDENT.match(masked[index - 1 : index]))):
            return False
        elif depth == 0 and masked.startswith("catch", index) and not IDENT.match(masked[index - 1 : index] or " "):
            if not re.match(r"\w", masked[index + 5 : index + 6]):
                return True
        index -= 1
    return False


def group_of(handler):
    body = " ".join(handler.split())
    if re.fullmatch(r"\{\s*\}", body):
        return "empty"
    if body == "unreachable":
        return "unreachable"
    if re.fullmatch(r"return error\.\w+", body):
        return "return-error"
    if body.startswith("{") and ".out_of_memory" in body:
        return "oom-block"
    return "fallback"


@dataclass
class Site:
    path: str
    key: str
    line: int
    catch_at: int
    end: int
    handler: str
    group: str
    problem: str | None
    state: str = "original"
    names: list = field(default_factory=list)
    reason: str | None = None

    def text(self, original):
        if self.state == "pending":
            return f"catch |err| if (false) {self.handler} else switch (err) {{}}"
        if self.state == "resolved":
            names = ", ".join(f"error.{name}" for name in self.names)
            if "\n" in self.handler:
                return f"catch |err| switch (err) {{\n{names} => {self.handler},\n}}"
            return f"catch |err| switch (err) {{ {names} => {self.handler} }}"
        return original[self.catch_at : self.end]


def find_sites(path, text):
    masked = mask(text)
    production = {number for number, _ in check_diagnostics.production(zig_code_without_literals(text))}
    sites = []
    ordinals = collections.Counter()
    for match in check_diagnostics.CAUSE_DROP.finditer(masked):
        line = masked.count("\n", 0, match.start()) + 1
        if line not in production:
            continue
        begin, end, problem = handler_span(masked, match.end())
        if problem is None and chained(masked, match.start()):
            problem = "chained catch"
        handler = text[begin:end]
        first = text.rfind("\n", 0, match.start()) + 1
        last = text.find("\n", end)
        context = " ".join(text[first : last if last >= 0 else len(text)].split())
        digest = hashlib.sha1(context.encode()).hexdigest()[:12]
        ordinals[digest] += 1
        sites.append(
            Site(path, f"{path}:{digest}:{ordinals[digest]}", line, match.start(), end, handler, group_of(handler), problem)
        )
    return sites


class Files:
    """The original text of each touched file, rendered with each site's current state."""

    def __init__(self, sites):
        self.original = {}
        self.sites = collections.defaultdict(list)
        for site in sites:
            self.sites[site.path].append(site)
            self.original.setdefault(site.path, (ROOT / site.path).read_text(encoding="utf-8"))
        self.spans = {}

    def render(self):
        for path, sites in self.sites.items():
            original = self.original[path]
            pieces = []
            cursor = 0
            spans = []
            length = 0
            for site in sorted(sites, key=lambda s: s.catch_at):
                pieces.append(original[cursor : site.catch_at])
                length += site.catch_at - cursor
                text = site.text(original)
                spans.append((length, length + len(text), site))
                pieces.append(text)
                length += len(text)
                cursor = site.end
            pieces.append(original[cursor:])
            rendered = "".join(pieces)
            self.spans[path] = (rendered, spans)
            (ROOT / path).write_text(rendered, encoding="utf-8")

    def restore(self):
        for path, text in self.original.items():
            (ROOT / path).write_text(text, encoding="utf-8")

    def locate(self, path, line, column):
        """The site whose rendered text holds the 1-based byte position, or None."""
        if path not in self.spans:
            return None
        rendered, spans = self.spans[path]
        lines = rendered.split("\n")
        if line > len(lines):
            return None
        offset = sum(len(item) + 1 for item in lines[: line - 1])
        offset += len(lines[line - 1].encode()[: column - 1].decode(errors="ignore"))
        for start, end, site in spans:
            if start <= offset < end:
                return site
        return None


def diagnostics(output):
    """Each error with its notes, as `(path, line, column, message, notes)`, without repeats."""
    found = []
    for line in output.splitlines():
        match = DIAGNOSTIC.match(line)
        if not match:
            continue
        path = Path(match[1])
        if path.is_absolute() and path.resolve().is_relative_to(ROOT):
            path = path.resolve().relative_to(ROOT)
        path = str(path)
        if match[4] == "error":
            found.append([path, int(match[2]), int(match[3]), match[5], []])
        elif found:
            found[-1][4].append(match[5])
    unique = []
    for item in found:
        item = (item[0], item[1], item[2], item[3], tuple(item[4]))
        if item not in unique:
            unique.append(item)
    return unique


def analyze():
    BUILD_COPY.write_text((HERE / "check_build.zig").read_text(encoding="utf-8"), encoding="utf-8")
    try:
        result = subprocess.run(
            ["zig", "build", "--build-file", BUILD_COPY.name, "analyze", "--summary", "none", "--color", "off"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
    finally:
        BUILD_COPY.unlink(missing_ok=True)
    return result.returncode, result.stdout + result.stderr


def ast_check(paths):
    output = ""
    for path in paths:
        result = subprocess.run(["zig", "ast-check", "--color", "off", path], cwd=ROOT, capture_output=True, text=True)
        output += result.stdout + result.stderr
    return diagnostics(output)


def revert(site, reason):
    site.state = "reverted"
    site.reason = reason


def converge(files, sites, max_names, log):
    pending = [site for site in sites if site.state == "pending"]
    for iteration in range(1, 200):
        files.render()
        unattributed = []
        changed = False
        for path, line, column, message, notes in ast_check(sorted(files.sites)):
            site = files.locate(path, line, column)
            if site is None or site.state == "original":
                unattributed.append(f"{path}:{line}:{column}: {message}")
            elif site.state != "reverted":
                revert(site, f"ast-check: {message}")
                changed = True
        if unattributed:
            raise RuntimeError("ast-check errors outside the converted sites:\n" + "\n".join(unattributed))
        if changed:
            continue
        code, output = analyze()
        errors = diagnostics(output)
        log(f"iteration {iteration}: {sum(s.state == 'pending' for s in pending)} pending, {len(errors)} errors")
        if code != 0 and not errors:
            raise RuntimeError("analysis failed without a Zig error:\n" + output[-4000:])
        if not errors:
            unanalyzed = [site for site in pending if site.state == "pending"]
            for site in unanalyzed:
                revert(site, "never analyzed: comptime-known operand, empty error set, or unreferenced code")
            if not unanalyzed:
                return
            continue
        reports = collections.defaultdict(set)
        others = collections.defaultdict(list)
        for path, line, column, message, notes in errors:
            site = files.locate(path, line, column)
            if site is None or site.state not in ("pending", "resolved"):
                unattributed.append(f"{path}:{line}:{column}: {message}")
            elif site.state == "pending" and message == "switch must handle all possibilities":
                reports[id(site)].add(frozenset(UNHANDLED.search(note)[1] for note in notes if UNHANDLED.search(note)))
            else:
                others[id(site)].append(message)
        if unattributed:
            raise RuntimeError("Zig errors outside the converted sites:\n" + "\n".join(unattributed))
        for site in pending:
            if site.state == "resolved" and id(site) in others:
                revert(site, "instantiations disagree: " + others[id(site)][0])
            elif site.state != "pending":
                continue
            elif id(site) in others:
                message = others[id(site)][0]
                revert(site, "anyerror callee" if "anyerror" in message else message)
            elif len(reports[id(site)]) > 1:
                revert(site, "instantiations disagree: " + " | ".join(sorted(",".join(sorted(r)) for r in reports[id(site)])))
            elif reports[id(site)]:
                names = sorted(next(iter(reports[id(site)])))
                site.names = names
                if OOM_WORDS.search(site.handler) and names != ["OutOfMemory"]:
                    revert(site, "mislabel: OOM handler for " + ", ".join(names))
                elif len(names) > max_names:
                    revert(site, f"{len(names)} names")
                else:
                    site.state = "resolved"
    raise RuntimeError("no convergence after 200 iterations")


TOKEN = re.compile(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|\\\\[^\n]*|//[^\n]*|[A-Za-z_@]\w*|\d\w*|=>|\S')
OPENING = re.compile(r"\| err \| switch \( err \) \{ error \. \w+(?: , error \. \w+)* => ")


def verify(revision):
    """Fail unless each Zig change since `revision` only wraps an old handler in a checked switch.

    The token stream of each file may gain `|err| switch (err) { error.A, ... =>`
    right after a `catch`, and `}` or `, }` after the handler. Any other token
    change fails.
    """
    changed = subprocess.run(["git", "diff", "--name-only", revision, "--", "src"], cwd=ROOT, capture_output=True, text=True, check=True)
    failures = 0
    for path in changed.stdout.split():
        old = TOKEN.findall(subprocess.run(["git", "show", f"{revision}:{path}"], cwd=ROOT, capture_output=True, text=True, check=True).stdout)
        new = TOKEN.findall((ROOT / path).read_text(encoding="utf-8"))
        i = j = opened = closed = 0
        while i < len(old) or j < len(new):
            if i < len(old) and j < len(new) and old[i] == new[j]:
                i += 1
                j += 1
                continue
            ahead = " ".join(new[j : j + 64]) + " "
            opening = OPENING.match(ahead)
            if opening and old[i - 1] == "catch":
                j += opening[0].count(" ")
                opened += 1
            elif new[j : j + 2] == [",", "}"] or (new[j : j + 2] == ["}", ","] and old[i - 1] == ","):
                # After a matched `,`, an inserted `} ,` is the same change as `, }` before it.
                j += 2
                closed += 1
            elif new[j : j + 1] == ["}"]:
                j += 1
                closed += 1
            else:
                failures += 1
                print(f"{path}: token {i} {' '.join(old[i - 8 : i + 8])!r} became {' '.join(new[j - 8 : j + 8])!r}", file=sys.stderr)
                break
        if opened != closed:
            failures += 1
            print(f"{path}: {opened} switches opened, {closed} closed", file=sys.stderr)
        print(f"{path}: {opened} handlers wrapped")
    return 1 if failures else 0


def load_state():
    return json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--group", action="append", choices=GROUPS, default=[])
    parser.add_argument("--site", action="append", default=[], help="path:line of one drop")
    parser.add_argument("--max-names", type=int, default=3)
    parser.add_argument("--retry", action="store_true", help="also try sites that an earlier run reverted")
    parser.add_argument("--list", action="store_true", help="print each drop with its group and state")
    parser.add_argument("--verify", metavar="REV", help="check that each change since REV only wraps a handler")
    args = parser.parse_args()
    if args.verify:
        return verify(args.verify)

    state = load_state()
    sites = []
    for path, _ in check_diagnostics.cause_drop_counts(ROOT).items():
        sites += find_sites(path, (ROOT / path).read_text(encoding="utf-8"))
    if args.list:
        for site in sites:
            note = site.problem or (state.get(site.key) or {}).get("reason") or ""
            print(f"{site.path}:{site.line}\t{site.group}\t{note}\t{' '.join(site.handler.split())[:80]}")
        return 0

    wanted = {tuple(item.rsplit(":", 1)) for item in args.site}
    selected = []
    nested_in = []
    for site in sites:
        if (site.path, str(site.line)) not in wanted and site.group not in args.group:
            continue
        if site.problem:
            state[site.key] = {"path": site.path, "line": site.line, "group": site.group, "state": "skipped", "reason": site.problem}
            continue
        if not args.retry and (state.get(site.key) or {}).get("state") == "reverted":
            continue
        selected.append(site)
    # A handler that holds another selected site converts first. A rerun converts the inner one.
    for site in selected:
        if any(o is not site and o.path == site.path and o.catch_at < site.catch_at < o.end for o in selected):
            nested_in.append(site)
    selected = [site for site in selected if site not in nested_in]
    if not selected:
        print("no site selected")
        return 0
    for site in selected:
        site.state = "pending"

    files = Files(selected)
    try:
        converge(files, selected, args.max_names, lambda message: print(message, file=sys.stderr))
        files.render()
    except BaseException:
        files.restore()
        raise
    changed = [path for path, items in files.sites.items() if any(site.state == "resolved" for site in items)]
    if changed:
        subprocess.run(["zig", "fmt", *changed], cwd=ROOT, check=True)
    code, output = analyze()
    if code != 0:
        print(output[-4000:], file=sys.stderr)
        raise SystemExit("analysis fails after the conversion")

    for site in selected:
        state[site.key] = {
            "path": site.path,
            "line": site.line,
            "group": site.group,
            "state": site.state,
            "names": site.names,
            "reason": site.reason,
        }
    STATE.write_text(json.dumps(state, indent=1, sort_keys=True) + "\n", encoding="utf-8")

    resolved = [site for site in selected if site.state == "resolved"]
    reverted = [site for site in selected if site.state == "reverted"]
    print(f"resolved {len(resolved)}, reverted {len(reverted)}, nested and left for a rerun {len(nested_in)}")
    print("names per resolved site:", dict(sorted(collections.Counter(len(s.names) for s in resolved).items())))
    print("names per reverted site:", dict(sorted(collections.Counter(len(s.names) for s in reverted if s.names).items())))
    for reason, count in collections.Counter(re.sub(r":.*", "", s.reason) for s in reverted).most_common():
        print(f"reverted: {count} {reason}")
    for site in reverted:
        print(f"  {site.path}:{site.line}: {site.reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
