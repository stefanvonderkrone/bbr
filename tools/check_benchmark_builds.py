#!/usr/bin/env python3
from pathlib import Path
import re
import sys

from source_lines import zig_files


EXECUTABLE = re.compile(
    r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\\\\[^\n]*|(?P<call>\baddExecutable\s*\()'''
)
FIELD = re.compile(
    r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\\\\[^\n]*|(?P<brace>[{}])|'''
    r'''(?P<name>\.name\s*=\s*(?P<value>"(?:\\.|[^"\\])*"|\w+)(?=\s*[,}]))'''
)
HELPER = re.compile(r"^fn\s+addBenchmark\b.*?(?=^\}|\Z)", re.MULTILINE | re.DOTALL)
COMPILE_DEPENDENCY = re.compile(r"\btest_step\s*\.\s*dependOn\s*\(")
RUN = re.compile(r"\baddRunArtifact\s*\(")


def executable_name(text, start):
    if not re.compile(r"\s*\.\s*\{").match(text, start):
        return None
    depth = 0
    for field in FIELD.finditer(text, start):
        if field["brace"]:
            depth += 1 if field["brace"] == "{" else -1
            if depth == 0:
                break
        elif depth == 1 and field["name"]:
            return field["value"]
    return None


def violations(root):
    _, lines = next(zig_files(root, ("build.zig",), literals=True))
    _, masked_lines = next(zig_files(root, ("build.zig",), literals=False))
    text = "\n".join(lines)
    masked = "\n".join(masked_lines)
    helper = HELPER.search(masked)
    if not helper or not COMPILE_DEPENDENCY.search(helper[0]) or RUN.search(helper[0]):
        yield (
            "build.zig: addBenchmark must call test_step.dependOn and must not call addRunArtifact. "
            "Depend on compilation only, not a benchmark run."
        )
    helper = HELPER.search(text)
    for call in EXECUTABLE.finditer(text):
        if not call["call"]:
            continue
        number = text.count("\n", 0, call.start()) + 1
        name = executable_name(text, call.end())
        if name in ('"bbr"', '"grammar-cli-integration"') or (
            name == "name" and helper and helper.start() <= call.start() < helper.end()
        ):
            continue
        yield (
            f"build.zig:{number}: executable bypasses benchmark compilation in the test step. "
            "Use addBenchmark(b, test_step, name, root_module). "
            "Only bbr and grammar-cli-integration use addExecutable directly."
        )


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    found = list(violations(root))
    for message in found:
        print(message, file=sys.stderr)
    if found:
        return 1
    print("Benchmark executables use addBenchmark.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
