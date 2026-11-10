"""A per-file count baseline for a ratchet check. It holds counts, not Zig source."""


def read(path):
    """The count for each file name in the baseline at `path`, or no counts when the file is missing."""
    counts = {}
    if not path.exists():
        return counts
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.startswith("#"):
            count, name = line.split(maxsplit=1)
            counts[name] = int(count)
    return counts


def write(path, header, counts):
    lines = [f"# {header}"] + [f"{count} {name}" for name, count in sorted(counts.items())]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
