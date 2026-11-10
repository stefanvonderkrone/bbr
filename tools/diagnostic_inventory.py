import pathlib
import re
import sys

from source_lines import zig_files


def sites(root):
    for path, lines in zig_files(root, ["src"], literals=False):
        owner = "file"
        depth = 0
        test_depth = None
        for number, line in enumerate(lines, 1):
            if re.match(r"\s*test\b", line):
                test_depth = depth
            match = re.search(r"\bfn\s+(\w+)\s*\(", line)
            if match:
                owner = match[1]
            if test_depth is None and re.search(r"\bcatch\b|\belse\s*\|[^|]*\||\bsqlite3_\w+\s*\(", line):
                yield str(path), owner, number, line.strip()
            depth += line.count("{") - line.count("}")
            if test_depth is not None and depth <= test_depth:
                test_depth = None


if __name__ == "__main__":
    print("file\towner\tline\tboundary")
    for row in sites(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")):
        print("\t".join(map(str, row)))
