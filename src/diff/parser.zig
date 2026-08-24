//! Unified-diff parser — pure, no UI, no I/O. Turns the raw unified diff text
//! from a `DiffSource` (Bitbucket `RawDiff` or `git diff`) into the `Diff`
//! model. Bitbucket's diff is the authoritative line model (ADR-0001), so the
//! numbering this computes is what comment anchors point at.
//!
//! Headers and line text borrow `raw`. Git-quoted paths are decoded into the
//! caller's allocator. Callers pass an arena and free the complete Diff there.

const std = @import("std");
const model = @import("model.zig");
const git_path = @import("path.zig");

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
    var old_path_valid = true;
    var new_path_valid = true;
    var status: FileStatus = .modified;
    var binary = false;
    var binary_new_size: ?usize = null;
    var binary_old_size: ?usize = null;
    var binary_block_count: usize = 0;
    var binary_expects_block = false;
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
                    .content = fileContent(status, binary, binary_old_size, binary_new_size, old_path_valid, new_path_valid),
                });
                hunks = .empty;
            }
            have_file = true;
            status = .modified;
            binary = false;
            binary_new_size = null;
            binary_old_size = null;
            binary_block_count = 0;
            binary_expects_block = false;
            old_path_valid = true;
            new_path_valid = true;
            // Best-effort path guess from the `a/… b/…` operands; the `---`/`+++`
            // lines below refine it (and handle spaces/quoting more reliably).
            const paths = try parseGitPaths(allocator, line["diff --git ".len..]);
            old_path = paths.old;
            new_path = paths.new;
            old_path_valid = paths.old_valid;
            new_path_valid = paths.new_valid;
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
                const parsed_path = try normalizeDiffPath(allocator, line["--- ".len..]);
                old_path = parsed_path.path;
                old_path_valid = parsed_path.valid;
                if (std.mem.eql(u8, old_path, "/dev/null")) status = .added;
                continue;
            }
            if (std.mem.startsWith(u8, line, "+++ ")) {
                const parsed_path = try normalizeDiffPath(allocator, line["+++ ".len..]);
                new_path = parsed_path.path;
                new_path_valid = parsed_path.valid;
                if (std.mem.eql(u8, new_path, "/dev/null")) status = .removed;
                continue;
            }
            if (std.mem.eql(u8, line, "GIT binary patch") or
                (std.mem.startsWith(u8, line, "Binary files ") and std.mem.endsWith(u8, line, " differ")))
            {
                binary = true;
                binary_expects_block = std.mem.eql(u8, line, "GIT binary patch");
                continue;
            }
            if (binary and line.len == 0) {
                binary_expects_block = true;
                continue;
            }
            if (binary_expects_block and
                (std.mem.startsWith(u8, line, "literal ") or std.mem.startsWith(u8, line, "delta ")))
            {
                if (std.mem.startsWith(u8, line, "literal ")) {
                    const size = std.fmt.parseInt(usize, line["literal ".len..], 10) catch null;
                    if (binary_block_count == 0) binary_new_size = size;
                    if (binary_block_count == 1) binary_old_size = size;
                }
                binary_block_count += 1;
                binary_expects_block = false;
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
            .content = fileContent(status, binary, binary_old_size, binary_new_size, old_path_valid, new_path_valid),
        });
    }

    return .{ .files = try files.toOwnedSlice(allocator) };
}

fn fileContent(status: FileStatus, binary: bool, old_size: ?usize, new_size: ?usize, old_path_valid: bool, new_path_valid: bool) model.FileContent {
    const old: ?model.FileContentStatus = if (status == .added)
        null
    else if (!old_path_valid)
        .{ .unavailable = .{ .reason = .invalid_path } }
    else if (binary)
        .{ .binary = old_size }
    else
        .{ .text = null };
    const new: ?model.FileContentStatus = if (status == .removed)
        null
    else if (!new_path_valid)
        .{ .unavailable = .{ .reason = .invalid_path } }
    else if (binary)
        .{ .binary = new_size }
    else
        .{ .text = null };
    return .{ .old = old, .new = new };
}

const GitPaths = struct { old: []const u8, new: []const u8, old_valid: bool, new_valid: bool };

/// Extract `old`/`new` from the `a/… b/…` operands of a `diff --git` line.
/// Best-effort: assumes no spaces in the (unquoted) common case, splitting on
/// the midpoint " b/". Refined by the `---`/`+++` lines when present.
fn parseGitPaths(allocator: std.mem.Allocator, operands: []const u8) std.mem.Allocator.Error!GitPaths {
    const first = parseGitOperand(operands, 0) orelse return invalidGitPaths(operands);
    const second = parseGitOperand(operands, first.next) orelse return invalidGitPaths(operands);
    if (std.mem.trim(u8, operands[second.next..], " ").len != 0) return invalidGitPaths(operands);
    const old = try normalizeGitOperand(allocator, first.value, "a/");
    const new = try normalizeGitOperand(allocator, second.value, "b/");
    return .{ .old = old.path, .new = new.path, .old_valid = old.valid, .new_valid = new.valid };
}

const GitOperand = struct { value: []const u8, next: usize };

fn parseGitOperand(input: []const u8, start: usize) ?GitOperand {
    var begin = start;
    while (begin < input.len and input[begin] == ' ') begin += 1;
    if (begin == input.len) return null;
    if (input[begin] != '"') {
        const end = std.mem.findScalarPos(u8, input, begin, ' ') orelse input.len;
        return .{ .value = input[begin..end], .next = end };
    }
    var escaped = false;
    for (input[begin + 1 ..], begin + 1..) |byte, index| {
        if (!escaped and byte == '"') return .{ .value = input[begin .. index + 1], .next = index + 1 };
        if (!escaped and byte == '\\') {
            escaped = true;
        } else {
            escaped = false;
        }
    }
    return null;
}

fn normalizeGitOperand(allocator: std.mem.Allocator, operand: []const u8, prefix: []const u8) std.mem.Allocator.Error!ParsedPath {
    if (operand.len > 0 and operand[0] == '"') return normalizePathOrOriginal(allocator, operand);
    const stripped = stripPrefix(operand, prefix);
    return .{ .path = stripped, .valid = git_path.isRepositoryRelative(stripped) };
}

fn invalidGitPaths(operands: []const u8) GitPaths {
    return .{ .old = operands, .new = operands, .old_valid = false, .new_valid = false };
}

const ParsedPath = struct { path: []const u8, valid: bool };

fn normalizePathOrOriginal(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!ParsedPath {
    return if (git_path.normalize(allocator, path)) |normalized|
        .{ .path = normalized, .valid = true }
    else |err| switch (err) {
        error.InvalidPath => .{ .path = path, .valid = false },
        error.OutOfMemory => error.OutOfMemory,
    };
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

fn normalizeDiffPath(allocator: std.mem.Allocator, rest: []const u8) std.mem.Allocator.Error!ParsedPath {
    const stripped = stripDiffPath(rest);
    if (std.mem.eql(u8, stripped, "/dev/null")) return .{ .path = stripped, .valid = true };
    return normalizePathOrOriginal(allocator, stripped);
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

test "Git-quoted paths are normalized in File identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diff = try parseInArena(&arena, "diff --git \"a/src/old\\040name.txt\" \"b/src/new\\040name.txt\"\n" ++
        "similarity index 90%\n" ++
        "rename from src/old name.txt\n" ++
        "rename to src/new name.txt\n" ++
        "--- \"a/src/old\\040name.txt\"\n" ++
        "+++ \"b/src/new\\040name.txt\"\n" ++
        "@@ -1 +1 @@\n-old\n+new\n");
    try testing.expectEqualStrings("src/old name.txt", diff.files[0].old_path);
    try testing.expectEqualStrings("src/new name.txt", diff.files[0].new_path);
}

test "malformed quoted paths make File content unavailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diff = try parseInArena(&arena, "diff --git a/file.txt b/file.txt\n" ++
        "--- \"a/unterminated\n" ++
        "+++ b/file.txt\n" ++
        "@@ -1 +1 @@\n-old\n+new\n");
    try testing.expect(diff.files[0].content.old.? == .unavailable);
    try testing.expect(diff.files[0].content.old.?.unavailable.reason == .invalid_path);
    try testing.expect(diff.files[0].content.new.? == .text);
}

test "mixed Git quoting preserves pure-rename File identity" {
    const cases = [_]struct { operands: []const u8, old: []const u8, new: []const u8 }{
        .{ .operands = "\"a/old\\040name.txt\" b/new.txt", .old = "old name.txt", .new = "new.txt" },
        .{ .operands = "a/old.txt \"b/new\\040name.txt\"", .old = "old.txt", .new = "new name.txt" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const raw = try std.fmt.allocPrint(arena.allocator(), "diff --git {s}\nsimilarity index 100%\nrename from {s}\nrename to {s}\n", .{ case.operands, case.old, case.new });
        const diff = try parseInArena(&arena, raw);
        try testing.expectEqualStrings(case.old, diff.files[0].old_path);
        try testing.expectEqualStrings(case.new, diff.files[0].new_path);
    }
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

test "Git binary stubs classify present File sides without Lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const raw =
        \\diff --git a/modified.bin b/modified.bin
        \\index 111..222 100644
        \\GIT binary patch
        \\literal 4
        \\payload
        \\
        \\literal 3
        \\payload
        \\diff --git a/added.bin b/added.bin
        \\new file mode 100644
        \\index 000..333
        \\Binary files /dev/null and b/added.bin differ
        \\diff --git a/removed.bin b/removed.bin
        \\deleted file mode 100644
        \\index 444..000
        \\GIT binary patch
        \\literal 0
        \\payload
        \\
        \\literal 8
        \\payload
        \\diff --git a/old.bin b/new.bin
        \\similarity index 90%
        \\rename from old.bin
        \\rename to new.bin
        \\Binary files a/old.bin and b/new.bin differ
        \\diff --git a/delta.bin b/delta.bin
        \\GIT binary patch
        \\delta 12
        \\payload
        \\
        \\literal 6
        \\payload
        \\diff --git a/malformed.bin b/malformed.bin
        \\GIT binary patch
        \\literal invalid
        \\payload
        \\
        \\literal 9
        \\payload
    ;

    const diff = try parseInArena(&arena, raw);
    try testing.expectEqual(@as(usize, 6), diff.files.len);
    for (diff.files) |file| try testing.expectEqual(@as(usize, 0), file.hunks.len);

    try testing.expectEqual(@as(?usize, 3), diff.files[0].content.old.?.binary);
    try testing.expectEqual(@as(?usize, 4), diff.files[0].content.new.?.binary);
    try testing.expect(diff.files[1].content.old == null);
    try testing.expectEqual(@as(?usize, null), diff.files[1].content.new.?.binary);
    try testing.expectEqual(@as(?usize, 8), diff.files[2].content.old.?.binary);
    try testing.expect(diff.files[2].content.new == null);
    try testing.expectEqual(@as(?usize, null), diff.files[3].content.old.?.binary);
    try testing.expectEqual(@as(?usize, null), diff.files[3].content.new.?.binary);
    try testing.expectEqual(@as(?usize, 6), diff.files[4].content.old.?.binary);
    try testing.expectEqual(@as(?usize, null), diff.files[4].content.new.?.binary);
    try testing.expectEqual(@as(?usize, 9), diff.files[5].content.old.?.binary);
    try testing.expectEqual(@as(?usize, null), diff.files[5].content.new.?.binary);
}
