//! Unified-diff parser — pure, no UI, no I/O. Turns the raw unified diff text
//! from a `DiffSource` (Bitbucket `RawDiff` or `git diff`) into the `Diff`
//! model. Bitbucket's diff is the authoritative line model (ADR-0001), so the
//! numbering this computes is what comment anchors point at.
//!
//! Zero-copy: every path, header, and line `text` borrows the `raw` slice, so
//! `raw` must outlive the returned `Diff`. The parser allocates only the arrays
//! that hold the model; callers pass an arena and free it wholesale.

const std = @import("std");
const model = @import("model.zig");

const Diff = model.Diff;
const File = model.File;
const FileStatus = model.FileStatus;
const Hunk = model.Hunk;
const Line = model.Line;
const LineKind = model.LineKind;

pub const ParseError = error{
    /// A hunk body or content line appeared before any `@@` header.
    UnexpectedLine,
    /// An `@@ … @@` header did not match the expected shape.
    MalformedHunkHeader,
} || std.mem.Allocator.Error;

/// Parse unified diff text into a `Diff`. `allocator` should be an arena: the
/// returned `Diff` and all nested arrays live in it, and the diff's strings
/// borrow `raw`.
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) ParseError!Diff {
    var files: std.ArrayList(File) = .empty;

    // Accumulators for the file currently being built.
    var have_file = false;
    var old_path: []const u8 = "";
    var new_path: []const u8 = "";
    var status: FileStatus = .modified;
    var hunks: std.ArrayList(Hunk) = .empty;

    // Accumulators for the hunk currently being built.
    var have_hunk = false;
    var hunk_header: []const u8 = "";
    var old_start: u32 = 0;
    var old_count: u32 = 0;
    var new_start: u32 = 0;
    var new_count: u32 = 0;
    var old_no: u32 = 0;
    var new_no: u32 = 0;
    var lines: std.ArrayList(Line) = .empty;

    const flushHunk = struct {
        fn call(a: std.mem.Allocator, hs: *std.ArrayList(Hunk), h: Hunk, ls: *std.ArrayList(Line)) !void {
            var hunk = h;
            hunk.lines = try ls.toOwnedSlice(a);
            try hs.append(a, hunk);
            ls.* = .empty;
        }
    }.call;

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            // Boundary: close the open hunk and file, then start a new file.
            if (have_hunk) {
                try flushHunk(allocator, &hunks, .{
                    .old_start = old_start,
                    .old_count = old_count,
                    .new_start = new_start,
                    .new_count = new_count,
                    .header = hunk_header,
                    .lines = &.{},
                }, &lines);
                have_hunk = false;
            }
            if (have_file) {
                try files.append(allocator, .{
                    .old_path = old_path,
                    .new_path = new_path,
                    .status = status,
                    .hunks = try hunks.toOwnedSlice(allocator),
                });
                hunks = .empty;
            }
            have_file = true;
            status = .modified;
            // Best-effort path guess from the `a/… b/…` operands; the `---`/`+++`
            // lines below refine it (and handle spaces/quoting more reliably).
            const paths = parseGitPaths(line["diff --git ".len..]);
            old_path = paths.old;
            new_path = paths.new;
            continue;
        }

        if (!have_file) {
            // Leading noise before the first file (e.g. commit headers) is skipped.
            continue;
        }

        if (!have_hunk) {
            // Still in the file preamble (mode/index/---/+++ lines).
            if (std.mem.startsWith(u8, line, "new file mode")) {
                status = .added;
                continue;
            }
            if (std.mem.startsWith(u8, line, "deleted file mode")) {
                status = .removed;
                continue;
            }
            if (std.mem.startsWith(u8, line, "rename ")) {
                status = .renamed;
                continue;
            }
            if (std.mem.startsWith(u8, line, "--- ")) {
                old_path = stripDiffPath(line["--- ".len..]);
                if (std.mem.eql(u8, old_path, "/dev/null")) status = .added;
                continue;
            }
            if (std.mem.startsWith(u8, line, "+++ ")) {
                new_path = stripDiffPath(line["+++ ".len..]);
                if (std.mem.eql(u8, new_path, "/dev/null")) status = .removed;
                continue;
            }
        }

        if (std.mem.startsWith(u8, line, "@@")) {
            if (have_hunk) {
                try flushHunk(allocator, &hunks, .{
                    .old_start = old_start,
                    .old_count = old_count,
                    .new_start = new_start,
                    .new_count = new_count,
                    .header = hunk_header,
                    .lines = &.{},
                }, &lines);
            }
            const h = try parseHunkHeader(line);
            have_hunk = true;
            hunk_header = line;
            old_start = h.old_start;
            old_count = h.old_count;
            new_start = h.new_start;
            new_count = h.new_count;
            old_no = h.old_start;
            new_no = h.new_start;
            continue;
        }

        if (!have_hunk) continue; // ignore anything else in the preamble

        // Hunk body. Every real body line carries a prefix char (` `/`+`/`-`);
        // a genuinely blank context line is `" "`, not `""`. An empty string
        // only comes from the trailing newline (split artifact), so skip it.
        if (line.len == 0) continue;
        switch (line[0]) {
            ' ' => {
                try lines.append(allocator, .{ .old_no = old_no, .new_no = new_no, .kind = .context, .text = line[1..] });
                old_no += 1;
                new_no += 1;
            },
            '+' => {
                try lines.append(allocator, .{ .old_no = null, .new_no = new_no, .kind = .added, .text = line[1..] });
                new_no += 1;
            },
            '-' => {
                try lines.append(allocator, .{ .old_no = old_no, .new_no = null, .kind = .removed, .text = line[1..] });
                old_no += 1;
            },
            '\\' => {
                // "\ No newline at end of file" — a marker, not a real line.
            },
            else => return ParseError.UnexpectedLine,
        }
    }

    // Flush the trailing hunk and file.
    if (have_hunk) {
        try flushHunk(allocator, &hunks, .{
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
            .header = hunk_header,
            .lines = &.{},
        }, &lines);
    }
    if (have_file) {
        try files.append(allocator, .{
            .old_path = old_path,
            .new_path = new_path,
            .status = status,
            .hunks = try hunks.toOwnedSlice(allocator),
        });
    }

    return .{ .files = try files.toOwnedSlice(allocator) };
}

const GitPaths = struct { old: []const u8, new: []const u8 };

/// Extract `old`/`new` from the `a/… b/…` operands of a `diff --git` line.
/// Best-effort: assumes no spaces in the (unquoted) common case, splitting on
/// the midpoint " b/". Refined by the `---`/`+++` lines when present.
fn parseGitPaths(operands: []const u8) GitPaths {
    // Find " b/" that separates the two operands.
    if (std.mem.indexOf(u8, operands, " b/")) |sep| {
        const a = operands[0..sep];
        const b = operands[sep + 1 ..];
        return .{ .old = stripPrefix(a, "a/"), .new = stripPrefix(b, "b/") };
    }
    return .{ .old = operands, .new = operands };
}

/// Strip the `a/` or `b/` prefix and drop a trailing tab-delimited timestamp
/// (`git`/`diff -u` append `\t<date>` to `---`/`+++` lines). `/dev/null` passes
/// through unchanged.
fn stripDiffPath(rest: []const u8) []const u8 {
    var path = rest;
    if (std.mem.indexOfScalar(u8, path, '\t')) |t| path = path[0..t];
    if (std.mem.eql(u8, path, "/dev/null")) return path;
    path = stripPrefix(path, "a/");
    path = stripPrefix(path, "b/");
    return path;
}

fn stripPrefix(s: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return s;
}

const HunkNumbers = struct { old_start: u32, old_count: u32, new_start: u32, new_count: u32 };

/// Parse `@@ -old_start[,old_count] +new_start[,new_count] @@[ section]`.
/// Counts default to 1 when omitted, per unified-diff convention.
fn parseHunkHeader(line: []const u8) ParseError!HunkNumbers {
    // Content between the first "@@ " and the next " @@".
    if (!std.mem.startsWith(u8, line, "@@ ")) return ParseError.MalformedHunkHeader;
    const after = line["@@ ".len..];
    const close = std.mem.indexOf(u8, after, " @@") orelse return ParseError.MalformedHunkHeader;
    const ranges = after[0..close]; // e.g. "-1,3 +1,4"

    var parts = std.mem.splitScalar(u8, ranges, ' ');
    const old_part = parts.next() orelse return ParseError.MalformedHunkHeader;
    const new_part = parts.next() orelse return ParseError.MalformedHunkHeader;
    if (old_part.len == 0 or old_part[0] != '-') return ParseError.MalformedHunkHeader;
    if (new_part.len == 0 or new_part[0] != '+') return ParseError.MalformedHunkHeader;

    const old_r = try parseRange(old_part[1..]);
    const new_r = try parseRange(new_part[1..]);
    return .{
        .old_start = old_r.start,
        .old_count = old_r.count,
        .new_start = new_r.start,
        .new_count = new_r.count,
    };
}

const Range = struct { start: u32, count: u32 };

fn parseRange(s: []const u8) ParseError!Range {
    if (std.mem.indexOfScalar(u8, s, ',')) |c| {
        return .{
            .start = std.fmt.parseInt(u32, s[0..c], 10) catch return ParseError.MalformedHunkHeader,
            .count = std.fmt.parseInt(u32, s[c + 1 ..], 10) catch return ParseError.MalformedHunkHeader,
        };
    }
    return .{
        .start = std.fmt.parseInt(u32, s, 10) catch return ParseError.MalformedHunkHeader,
        .count = 1,
    };
}

// ---------------------------------------------------------------------------
// Tests — hermetic, parse into an arena over the testing allocator.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Parse into an arena so nested arrays need no per-node free; the caller
/// deinits the arena. Returns both so the test can read then tear down.
fn parseInArena(arena: *std.heap.ArenaAllocator, raw: []const u8) !Diff {
    return parse(arena.allocator(), raw);
}

test "single modified file, one hunk, numbers assigned per kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw =
        \\diff --git a/src/foo.zig b/src/foo.zig
        \\index 111..222 100644
        \\--- a/src/foo.zig
        \\+++ b/src/foo.zig
        \\@@ -1,3 +1,4 @@
        \\ const a = 1;
        \\-const b = 2;
        \\+const b = 3;
        \\+const c = 4;
        \\ const d = 5;
        \\
    ;

    const diff = try parseInArena(&arena, raw);
    try testing.expectEqual(@as(usize, 1), diff.files.len);

    const file = diff.files[0];
    try testing.expectEqual(FileStatus.modified, file.status);
    try testing.expectEqualStrings("src/foo.zig", file.old_path);
    try testing.expectEqualStrings("src/foo.zig", file.new_path);
    try testing.expectEqual(@as(usize, 1), file.hunks.len);

    const hunk = file.hunks[0];
    try testing.expectEqual(@as(u32, 1), hunk.old_start);
    try testing.expectEqual(@as(u32, 3), hunk.old_count);
    try testing.expectEqual(@as(u32, 1), hunk.new_start);
    try testing.expectEqual(@as(u32, 4), hunk.new_count);
    try testing.expectEqual(@as(usize, 5), hunk.lines.len);

    // context: both sides
    try testing.expectEqual(LineKind.context, hunk.lines[0].kind);
    try testing.expectEqual(@as(?u32, 1), hunk.lines[0].old_no);
    try testing.expectEqual(@as(?u32, 1), hunk.lines[0].new_no);
    try testing.expectEqualStrings("const a = 1;", hunk.lines[0].text);

    // removed: old only
    try testing.expectEqual(LineKind.removed, hunk.lines[1].kind);
    try testing.expectEqual(@as(?u32, 2), hunk.lines[1].old_no);
    try testing.expectEqual(@as(?u32, null), hunk.lines[1].new_no);

    // added: new only
    try testing.expectEqual(LineKind.added, hunk.lines[2].kind);
    try testing.expectEqual(@as(?u32, null), hunk.lines[2].old_no);
    try testing.expectEqual(@as(?u32, 2), hunk.lines[2].new_no);

    try testing.expectEqual(LineKind.added, hunk.lines[3].kind);
    try testing.expectEqual(@as(?u32, 3), hunk.lines[3].new_no);

    // trailing context: old resumes at 3 (1 context + 1 removed), new at 4
    try testing.expectEqual(LineKind.context, hunk.lines[4].kind);
    try testing.expectEqual(@as(?u32, 3), hunk.lines[4].old_no);
    try testing.expectEqual(@as(?u32, 4), hunk.lines[4].new_no);
}

test "added file: /dev/null old side, status added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\index 000..abc
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,2 @@
        \\+first
        \\+second
        \\
    ;

    const diff = try parseInArena(&arena, raw);
    try testing.expectEqual(@as(usize, 1), diff.files.len);
    const file = diff.files[0];
    try testing.expectEqual(FileStatus.added, file.status);
    try testing.expectEqualStrings("/dev/null", file.old_path);
    try testing.expectEqualStrings("new.txt", file.new_path);
    try testing.expectEqual(@as(usize, 2), file.hunks[0].lines.len);
    try testing.expectEqual(@as(?u32, 1), file.hunks[0].lines[0].new_no);
    try testing.expectEqual(@as(?u32, 2), file.hunks[0].lines[1].new_no);
}

test "deleted file: /dev/null new side, status removed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw =
        \\diff --git a/gone.txt b/gone.txt
        \\deleted file mode 100644
        \\--- a/gone.txt
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-line one
        \\-line two
        \\
    ;

    const diff = try parseInArena(&arena, raw);
    const file = diff.files[0];
    try testing.expectEqual(FileStatus.removed, file.status);
    try testing.expectEqual(LineKind.removed, file.hunks[0].lines[0].kind);
    try testing.expectEqual(@as(?u32, 1), file.hunks[0].lines[0].old_no);
    try testing.expectEqual(@as(?u32, null), file.hunks[0].lines[0].new_no);
}

test "multiple files, multiple hunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10,2 +10,2 @@
        \\ ctx
        \\-x
        \\+y
        \\diff --git a/b.txt b/b.txt
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -5,1 +5,2 @@
        \\ keep
        \\+extra
        \\
    ;

    const diff = try parseInArena(&arena, raw);
    try testing.expectEqual(@as(usize, 2), diff.files.len);
    try testing.expectEqual(@as(usize, 2), diff.files[0].hunks.len);
    try testing.expectEqual(@as(usize, 1), diff.files[1].hunks.len);

    // Second hunk of first file: count omitted-vs-present, numbering from 10.
    const h2 = diff.files[0].hunks[1];
    try testing.expectEqual(@as(u32, 10), h2.old_start);
    try testing.expectEqual(@as(?u32, 10), h2.lines[0].old_no);
    try testing.expectEqual(@as(?u32, 10), h2.lines[0].new_no);

    // First file's first hunk used the count-omitted form "@@ -1 +1 @@".
    const h1 = diff.files[0].hunks[0];
    try testing.expectEqual(@as(u32, 1), h1.old_count);
    try testing.expectEqual(@as(u32, 1), h1.new_count);
}

test "hunk header with section heading and count-omitted ranges" {
    const nums = try parseHunkHeader("@@ -1 +1,4 @@ fn main() void {");
    try testing.expectEqual(@as(u32, 1), nums.old_start);
    try testing.expectEqual(@as(u32, 1), nums.old_count);
    try testing.expectEqual(@as(u32, 1), nums.new_start);
    try testing.expectEqual(@as(u32, 4), nums.new_count);
}

test "malformed hunk header is rejected" {
    try testing.expectError(ParseError.MalformedHunkHeader, parseHunkHeader("@@ nonsense @@"));
    try testing.expectError(ParseError.MalformedHunkHeader, parseHunkHeader("not a hunk"));
}

test "\\ No newline marker does not create a line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw =
        \\diff --git a/n.txt b/n.txt
        \\--- a/n.txt
        \\+++ b/n.txt
        \\@@ -1 +1 @@
        \\-a
        \\\ No newline at end of file
        \\+b
        \\\ No newline at end of file
        \\
    ;

    const diff = try parseInArena(&arena, raw);
    const lines_ = diff.files[0].hunks[0].lines;
    try testing.expectEqual(@as(usize, 2), lines_.len);
    try testing.expectEqual(LineKind.removed, lines_[0].kind);
    try testing.expectEqual(LineKind.added, lines_[1].kind);
}

test "empty input yields no files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diff = try parseInArena(&arena, "");
    try testing.expectEqual(@as(usize, 0), diff.files.len);
}
