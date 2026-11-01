#!/usr/bin/env python3
"""Fail when a guard's tests still pass after the guard is removed.

Each mutation removes or weakens one guard in its own scratch copy of the tree.
The named `zig build` step must then fail with a test failure.
Usage: check_guard_mutations.py [--only ID]
"""

from collections import namedtuple
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

Mutation = namedtuple("Mutation", "id file original mutated step")

HIGHLIGHTER = "src/highlight/tree_sitter_highlighter.zig"
PREDICATES = "src/highlight/query_predicates.zig"
MUTATIONS = [
    Mutation("m27-parent-range-clip", HIGHLIGHTER,
             "if (parent.ranges.len == 0) return",
             "if (true or parent.ranges.len == 0) return",
             "test-builtin-grammars"),
    Mutation("m27-capture-clip", HIGHLIGHTER,
             "if (layer.ranges.len == 0) {",
             "if (true or layer.ranges.len == 0) {",
             "test-builtin-grammars"),
    Mutation("m27-offset-utf8-boundary", HIGHLIGHTER,
             "if (start >= end or !predicate_mod.utf8Boundary(content, start) or !predicate_mod.utf8Boundary(content, end)) return;",
             "if (start >= end) return;",
             "test-builtin-grammars"),
    Mutation("m27-injection-depth", HIGHLIGHTER,
             "if (layer.depth == max_injection_depth) continue;",
             "if (layer.depth == max_injection_depth + 1) continue;",
             "test-builtin-grammars"),
    Mutation("m27-include-children", HIGHLIGHTER,
             "if (settings.include_children) return",
             "if (false and settings.include_children) return",
             "test-builtin-grammars"),
    Mutation("m27-combined", HIGHLIGHTER,
             "if (settings.combined) {",
             "if (false and settings.combined) {",
             "test-builtin-grammars"),
    Mutation("m27-predicate-negation", PREDICATES,
             "== predicate.negated) return false;",
             "== false) return false;",
             "test-builtin-grammars"),
    Mutation("m27-parent-only", PREDICATES,
             "if (operands.parent_only) return false;",
             "if (false and operands.parent_only) return false;",
             "test-builtin-grammars"),
]

# A fixed version keeps the build independent of Git, which the scratch copy lacks.
VERSION = {"SOURCE_DATE_EPOCH": "0", "BBR_VERSION_COMMIT": "0" * 40, "BBR_VERSION_SEQUENCE": "0", "BBR_VERSION_DIRTY": "1"}
SKIP = {".git", ".zig-cache", "zig-out"}


def scratch_copy(root, scratch, mutation):
    """Copies the top-level entry that holds the mutated file and links the rest."""
    scratch.mkdir()
    copied = Path(mutation.file).parts[0] if mutation else None
    for entry in root.iterdir():
        if entry.name in SKIP:
            continue
        if entry.name == copied:
            shutil.copytree(entry, scratch / entry.name, symlinks=True)
        else:
            (scratch / entry.name).symlink_to(entry)
    if mutation:
        path = scratch / mutation.file
        path.write_text(path.read_text().replace(mutation.original, mutation.mutated))


def run_step(scratch, cache, step):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BITBUCKET_")} | VERSION
    started = time.monotonic()
    result = subprocess.run(["zig", "build", step, "--cache-dir", str(cache)], cwd=scratch, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.returncode, result.stdout, time.monotonic() - started


def verdict(mutation, code, output):
    if mutation is None:
        return "passes" if code == 0 else "BROKEN"
    if code == 0:
        return "SURVIVED"
    # A compile error is not a caught mutation, because no test ran.
    return "BROKEN" if "compilation error" in output else "caught"


def main():
    root = Path(__file__).resolve().parent.parent
    selected = MUTATIONS
    if sys.argv[1:2] == ["--only"]:
        selected = [m for m in MUTATIONS if m.id == sys.argv[2]]
        if not selected:
            sys.exit(f"no mutation with id {sys.argv[2]}. Known ids: {', '.join(m.id for m in MUTATIONS)}")
    problems = []
    for mutation in selected:
        count = (root / mutation.file).read_text().count(mutation.original)
        if count != 1:
            problems.append(f"{mutation.id}: the original snippet matches {count} times in {mutation.file}, not once. Update the entry in tools/check_guard_mutations.py.")
    if problems:
        sys.exit("\n".join(problems))

    # The baseline proves each step passes unmutated, so a failure under a mutation comes from the mutation.
    runs = [(None, step) for step in sorted({m.step for m in selected})] + [(m, m.step) for m in selected]
    cache = root / ".zig-cache"
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="bbr-guard-mutations-") as directory:
        def run(index):
            mutation, step = runs[index]
            scratch = Path(directory) / str(index)
            scratch_copy(root, scratch, mutation)
            return run_step(scratch, cache, step)

        with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
            for (mutation, step), (code, output, seconds) in zip(runs, pool.map(run, range(len(runs)))):
                name = mutation.id if mutation else f"baseline {step}"
                result = verdict(mutation, code, output)
                print(f"{result:<9} {name} ({seconds:.1f}s)")
                if result == "SURVIVED":
                    print(f"  `zig build {step}` passes without the guard in {mutation.file}. Add a test that fails without it.")
                elif result == "BROKEN":
                    print(f"  `zig build {step}` does not reach the tests. Fix the entry or the tree:\n{output[-3000:]}")
                if result in ("SURVIVED", "BROKEN"):
                    problems.append(name)
    print(f"total {time.monotonic() - started:.1f}s")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
