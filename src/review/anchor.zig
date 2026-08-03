//! Local Anchor resolution. Git acquisition is behind `AnchorResolver`; the
//! coordinate mapping itself is pure over a parsed transition Diff.

const std = @import("std");
const diff_mod = @import("../diff/model.zig");
const parser = @import("../diff/parser.zig");
const git_mod = @import("../git/client.zig");
const comment = @import("comment.zig");

const Allocator = std.mem.Allocator;
const Anchor = comment.Anchor;

pub const ResolvedAnchor = struct {
    state: comment.AnchorState,
    anchor: Anchor,
};

pub const AnchorResolution = union(enum) {
    resolved: ResolvedAnchor,
    unavailable,
};

pub const ProjectionEntry = struct {
    temp_id: @import("draft.zig").TempId,
    resolution: AnchorResolution,
};

pub fn find(entries: []const ProjectionEntry, temp_id: @import("draft.zig").TempId) ?AnchorResolution {
    for (entries) |entry| if (entry.temp_id == temp_id) return entry.resolution;
    return null;
}

pub const AnchorResolver = struct {
    ptr: *anyopaque,
    resolve_fn: *const fn (*anyopaque, Allocator, Anchor, []const u8) anyerror!AnchorResolution,

    pub fn resolve(self: AnchorResolver, allocator: Allocator, anchor: Anchor, current_commit: []const u8) !AnchorResolution {
        return self.resolve_fn(self.ptr, allocator, anchor, current_commit);
    }
};

pub const GitAnchorResolver = struct {
    git: git_mod.GitClient,
    cache_arena: std.heap.ArenaAllocator,
    transitions: std.StringHashMapUnmanaged(diff_mod.Diff) = .empty,
    unavailable_transitions: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator, git: git_mod.GitClient) GitAnchorResolver {
        return .{ .git = git, .cache_arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *GitAnchorResolver) void {
        self.cache_arena.deinit();
        self.* = undefined;
    }

    pub fn resolver(self: *GitAnchorResolver) AnchorResolver {
        return .{ .ptr = self, .resolve_fn = resolve };
    }

    fn resolve(ptr: *anyopaque, allocator: Allocator, authored: Anchor, current_commit: []const u8) anyerror!AnchorResolution {
        const self: *GitAnchorResolver = @ptrCast(@alignCast(ptr));
        const authored_commit = authored.commit orelse return .unavailable;
        const cache = self.cache_arena.allocator();
        const key = try std.fmt.allocPrint(cache, "{s}\x00{s}", .{ authored_commit, current_commit });
        if (self.unavailable_transitions.contains(key)) return .unavailable;
        const transition = self.transitions.get(key) orelse blk: {
            const raw = self.git.diff(cache, authored_commit, current_commit) catch {
                try self.unavailable_transitions.put(cache, key, {});
                return .unavailable;
            };
            const parsed_transition = parser.parse(cache, raw) catch {
                try self.unavailable_transitions.put(cache, key, {});
                return .unavailable;
            };
            try self.transitions.put(cache, key, parsed_transition);
            break :blk parsed_transition;
        };
        return resolveAgainst(allocator, authored, transition);
    }
};

/// Map an authored line/range from the old side of `transition` to its new
/// side. The stored Anchor remains untouched; returned coordinates are owned by
/// `allocator`.
pub fn resolveAgainst(allocator: Allocator, authored: Anchor, transition: diff_mod.Diff) !AnchorResolution {
    var changed_file: ?diff_mod.File = null;
    for (transition.files) |file| {
        if (std.mem.eql(u8, file.old_path, authored.path)) {
            changed_file = file;
            break;
        }
    }
    const file = changed_file orelse return .{ .resolved = .{
        .state = .current,
        .anchor = try dupeAnchor(allocator, authored, authored.path),
    } };
    if (file.status == .removed) return .{ .resolved = .{
        .state = .outdated,
        .anchor = try dupeAnchor(allocator, authored, authored.path),
    } };
    const projected_path = if (file.status == .renamed) file.new_path else authored.path;

    const top = authored.start_to orelse authored.start_from orelse authored.line() orelse return .unavailable;
    const bottom = authored.line() orelse return .unavailable;
    var mapped_top: ?u32 = null;
    var mapped_bottom: ?u32 = null;
    var previous_mapped: ?u32 = null;
    var line_no = top;
    while (true) : (line_no += 1) {
        const mapped = mapOldLine(file, line_no) orelse return .{ .resolved = .{
            .state = .outdated,
            .anchor = try dupeAnchor(allocator, authored, projected_path),
        } };
        if (previous_mapped) |previous| {
            if (mapped != previous + 1) return .{ .resolved = .{
                .state = .outdated,
                .anchor = try dupeAnchor(allocator, authored, projected_path),
            } };
        }
        if (mapped_top == null) mapped_top = mapped;
        mapped_bottom = mapped;
        previous_mapped = mapped;
        if (line_no == bottom) break;
    }
    if (mapped_bottom.? - mapped_top.? != bottom - top) return .{ .resolved = .{
        .state = .outdated,
        .anchor = try dupeAnchor(allocator, authored, projected_path),
    } };

    var projected = try dupeAnchor(allocator, authored, projected_path);
    if (authored.to != null) {
        projected.to = mapped_bottom;
        projected.start_to = if (authored.start_to != null) mapped_top else null;
    } else {
        projected.from = mapped_bottom;
        projected.start_from = if (authored.start_from != null) mapped_top else null;
    }
    const moved = !std.mem.eql(u8, projected_path, authored.path) or mapped_top.? != top;
    return .{ .resolved = .{ .state = if (moved) .moved else .current, .anchor = projected } };
}

fn mapOldLine(file: diff_mod.File, target: u32) ?u32 {
    var delta: i64 = 0;
    for (file.hunks) |hunk| {
        if (target < hunk.old_start) return applyDelta(target, delta);
        const old_end = hunk.old_start + hunk.old_count;
        if (target < old_end) {
            for (hunk.lines) |line| {
                if (line.old_no != target) continue;
                return line.new_no;
            }
            return null;
        }
        delta += @as(i64, hunk.new_count) - @as(i64, hunk.old_count);
    }
    return applyDelta(target, delta);
}

fn applyDelta(line: u32, delta: i64) ?u32 {
    const mapped = @as(i64, line) + delta;
    if (mapped < 1 or mapped > std.math.maxInt(u32)) return null;
    return @intCast(mapped);
}

fn dupeAnchor(allocator: Allocator, source: Anchor, path: []const u8) !Anchor {
    var result = source;
    result.path = try allocator.dupe(u8, path);
    if (source.commit) |commit| result.commit = try allocator.dupe(u8, commit);
    return result;
}

const testing = std.testing;

fn parsed(arena: Allocator, raw: []const u8) !diff_mod.Diff {
    return parser.parse(arena, raw);
}

test "an insertion before an Anchor moves it forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const transition = try parsed(arena.allocator(), "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n" ++
        "@@ -1,2 +1,3 @@\n first\n+inserted\n target\n");
    const result = try resolveAgainst(arena.allocator(), .{ .path = "f.zig", .to = 2, .commit = "old" }, transition);
    try testing.expect(result.resolved.state == .moved);
    try testing.expectEqual(@as(?u32, 3), result.resolved.anchor.to);
}

test "removal makes the whole ranged Anchor outdated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const transition = try parsed(arena.allocator(), "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n" ++
        "@@ -1,3 +1,2 @@\n one\n-two\n three\n");
    const result = try resolveAgainst(arena.allocator(), .{ .path = "f.zig", .start_to = 1, .to = 3, .commit = "old" }, transition);
    try testing.expect(result.resolved.state == .outdated);
}

test "proven rename moves the Anchor to the new path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const transition = try parsed(arena.allocator(), "diff --git a/old.zig b/new.zig\nsimilarity index 100%\nrename from old.zig\nrename to new.zig\n--- a/old.zig\n+++ b/new.zig\n");
    const result = try resolveAgainst(arena.allocator(), .{ .path = "old.zig", .to = 4, .commit = "old" }, transition);
    try testing.expect(result.resolved.state == .moved);
    try testing.expectEqualStrings("new.zig", result.resolved.anchor.path);
}

test "an outdated Anchor under a proven rename retains the projected path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const transition = try parsed(arena.allocator(), "diff --git a/old.zig b/new.zig\nsimilarity index 80%\nrename from old.zig\nrename to new.zig\n" ++
        "--- a/old.zig\n+++ b/new.zig\n@@ -1 +1 @@\n-old\n+new\n");
    const result = try resolveAgainst(arena.allocator(), .{ .path = "old.zig", .to = 1, .commit = "old" }, transition);
    try testing.expect(result.resolved.state == .outdated);
    try testing.expectEqualStrings("new.zig", result.resolved.anchor.path);
}

test "removed File makes its Anchor outdated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const transition = try parsed(arena.allocator(), "diff --git a/gone.zig b/gone.zig\ndeleted file mode 100644\n--- a/gone.zig\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n");
    const result = try resolveAgainst(arena.allocator(), .{ .path = "gone.zig", .from = 1, .commit = "old" }, transition);
    try testing.expect(result.resolved.state == .outdated);
}

test "Git resolver groups anchors that share an authored and current commit" {
    var fake: git_mod.FakeGitClient = .{ .diff_result = "diff --git a/f.zig b/f.zig\n--- a/f.zig\n+++ b/f.zig\n" ++
        "@@ -1,2 +1,3 @@\n first\n+inserted\n target\n" };
    var resolver = GitAnchorResolver.init(testing.allocator, fake.gitClient());
    defer resolver.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try resolver.resolver().resolve(arena.allocator(), .{ .path = "f.zig", .to = 1, .commit = "old" }, "new");
    _ = try resolver.resolver().resolve(arena.allocator(), .{ .path = "f.zig", .to = 2, .commit = "old" }, "new");

    try testing.expectEqual(@as(usize, 1), fake.diff_calls);
}

test "Git resolver also groups unavailable transition evidence" {
    var fake: git_mod.FakeGitClient = .{ .diff_result = error.UnknownRef };
    var resolver = GitAnchorResolver.init(testing.allocator, fake.gitClient());
    defer resolver.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try resolver.resolver().resolve(arena.allocator(), .{ .path = "f.zig", .to = 1, .commit = "missing" }, "new")) == .unavailable);
    try testing.expect((try resolver.resolver().resolve(arena.allocator(), .{ .path = "g.zig", .to = 2, .commit = "missing" }, "new")) == .unavailable);
    try testing.expectEqual(@as(usize, 1), fake.diff_calls);
}
