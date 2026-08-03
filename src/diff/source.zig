//! Narrow acquisition seam for unified diff text. Source adapters own how the
//! bytes are obtained; parsing and every downstream representation stay shared.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const parser = @import("parser.zig");
const git_mod = @import("../git/client.zig");

pub const DiffSource = struct {
    ptr: *anyopaque,
    read_fn: *const fn (*anyopaque, Allocator) anyerror![]u8,

    pub fn read(self: DiffSource, allocator: Allocator) ![]u8 {
        return self.read_fn(self.ptr, allocator);
    }
};

pub fn load(allocator: Allocator, source: DiffSource) !model.Diff {
    const raw = try source.read(allocator);
    // The parser is zero-copy: File paths, hunk headers, and line text borrow
    // this allocation. It therefore lives with the caller's Session/arena.
    return parser.parse(allocator, raw);
}

pub const TextSource = struct {
    text: []const u8,

    pub fn source(self: *TextSource) DiffSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(ptr: *anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *TextSource = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.text);
    }
};

pub const GitSource = struct {
    git: git_mod.GitClient,
    base_commit: []const u8,
    source_commit: []const u8,

    pub fn source(self: *GitSource) DiffSource {
        return .{ .ptr = self, .read_fn = read };
    }

    fn read(ptr: *anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *GitSource = @ptrCast(@alignCast(ptr));
        return self.git.diff(allocator, self.base_commit, self.source_commit);
    }
};

const testing = std.testing;

test "remote text and local Git sources produce the same Diff" {
    const raw =
        "diff --git a/f.zig b/f.zig\n" ++
        "--- a/f.zig\n" ++
        "+++ b/f.zig\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";

    var remote_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer remote_arena.deinit();
    var text_source: TextSource = .{ .text = raw };
    const remote_diff = try load(remote_arena.allocator(), text_source.source());

    var fake_git: git_mod.FakeGitClient = .{ .diff_result = raw };
    var git_source: GitSource = .{
        .git = fake_git.gitClient(),
        .base_commit = "base",
        .source_commit = "source",
    };
    var local_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer local_arena.deinit();
    const local_diff = try load(local_arena.allocator(), git_source.source());

    try testing.expectEqual(remote_diff.files.len, local_diff.files.len);
    try testing.expectEqualStrings(remote_diff.files[0].old_path, local_diff.files[0].old_path);
    try testing.expectEqualStrings(remote_diff.files[0].new_path, local_diff.files[0].new_path);
    try testing.expectEqual(remote_diff.files[0].hunks.len, local_diff.files[0].hunks.len);
    try testing.expectEqual(remote_diff.files[0].hunks[0].lines.len, local_diff.files[0].hunks[0].lines.len);
}
