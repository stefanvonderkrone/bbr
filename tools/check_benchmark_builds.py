#!/usr/bin/env python3
from pathlib import Path
import re
import sys

from source_lines import zig_files


EXECUTABLE = re.compile(r"\b\w+\s*\.\s*addExecutable\s*\(")
HELPER = re.compile(r"\bfn\s+addBenchmark\s*\([^{}]*\)\s*[^{}]*\{")
HELPER_BODY = re.compile(
    r"\s*const\s+exe\s*=\s*b\.addExecutable\(\.\{\s*\.name\s*=\s*name\s*,"
    r"\s*\.root_module\s*=\s*root_module\s*\}\);\s*"
    r"test_step\.dependOn\(&exe\.step\);\s*return\s+exe;\s*"
)
BENCHMARK = re.compile(r"\baddBenchmark\s*\(")
TEST_ARGUMENT = re.compile(r"\s*b\s*,\s*test_step\s*,")
APP_OR_FIXTURE = re.compile(
    r'\s*const\s+\w+\s*=\s*b\.addExecutable\(\.\{\s*\.name\s*=\s*'
    r'"(?:bbr|grammar-cli-integration)"\s*,\s*\.root_module\s*=\s*\w+\s*\}\);\s*'
)


def closing(text, start, opening, closing_char):
    depth = 1
    for index in range(start + 1, len(text)):
        if text[index] == opening:
            depth += 1
        elif text[index] == closing_char:
            depth -= 1
            if depth == 0:
                return index
    return len(text)


def violations(root):
    _, lines = next(zig_files(root, ("build.zig",), literals=True))
    _, masked_lines = next(zig_files(root, ("build.zig",), literals=False))
    masked = "\n".join(masked_lines)
    helper = HELPER.search(masked)
    helper_start = helper.end() - 1 if helper else -1
    helper_end = closing(masked, helper_start, "{", "}") if helper else -1
    if not helper or not HELPER_BODY.fullmatch(masked[helper_start + 1:helper_end]):
        yield (
            "build.zig: addBenchmark must create exe with addExecutable, "
            "call test_step.dependOn(&exe.step), and return exe. Depend on compilation only, not a benchmark run."
        )
    for call in BENCHMARK.finditer(masked):
        if helper and helper.start() <= call.start() <= helper_start:
            continue
        if not TEST_ARGUMENT.match(masked, call.end()):
            number = masked.count("\n", 0, call.start()) + 1
            yield f"build.zig:{number}: use addBenchmark(b, test_step, name, root_module) so test compiles the benchmark."
    for call in EXECUTABLE.finditer(masked):
        if helper_start < call.start() < helper_end:
            continue
        number = masked.count("\n", 0, call.start()) + 1
        if APP_OR_FIXTURE.fullmatch(lines[number - 1]):
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
