//! `bbr api list-commits`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");

pub const help =
    \\usage: bbr api list-commits --repository SLUG (--pull-request-id N | --revision REV | --from HASH --to HASH) [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
    \\
    \\List commits on a pull request or reachable from a revision.
    \\A range includes commits reachable from --to but not from --from.
    \\
;

const Parsed = struct {
    repository: ?[]const u8 = null,
    pr_id: ?u64 = null,
    revision: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    page: bbr.bitbucket.PageOptions = .{},
    mode: CommitMode = .pr,
};

fn setOption(comptime T: type, slot: *?T, value: T) !void {
    if (slot.*) |old| {
        const same = if (T == []const u8) std.mem.eql(u8, old, value) else old == value;
        if (!same) return error.BadRequest;
    }
    slot.* = value;
}

fn parse(args: []const []const u8) !Parsed {
    var cur: arg.Cursor = .{ .args = args };
    var p: Parsed = .{};
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (try ws.takePageFlag(&cur, f, &p.page)) continue;
        _ = cur.next();
        if (std.mem.eql(u8, f.name, "repository")) {
            try setOption([]const u8, &p.repository, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            try setOption(u64, &p.pr_id, try arg.parseU64(try arg.takeValue(&cur, f)));
        } else if (std.mem.eql(u8, f.name, "revision")) {
            try setOption([]const u8, &p.revision, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "from")) {
            try setOption([]const u8, &p.from, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "to")) {
            try setOption([]const u8, &p.to, try arg.takeValue(&cur, f));
        } else return error.UnknownFlag;
    }
    if (p.repository == null) return error.MissingRequired;
    p.mode = try commitMode(p.pr_id, p.revision, p.from, p.to);
    return p;
}

pub fn run(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parse(args);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const items: []bbr.bitbucket.Commit = switch (p.mode) {
        .pr => try bb.listPrCommits(a, p.repository.?, p.pr_id.?, p.page),
        .revision => try bb.listRepoCommits(a, p.repository.?, p.revision.?, p.page),
        .range => try bb.listRepoCommitRange(a, p.repository.?, p.from.?, p.to.?, p.page),
    };
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |c| try out.printLine(init, "{s} {s} {s}", .{ c.hash, out.firstLine(c.author), out.firstLine(c.message) });
        try out.printLine(init, "ok: {d} commit(s)", .{items.len});
    }
}

const CommitMode = enum { pr, revision, range };

fn commitMode(pr_id: ?u64, revision: ?[]const u8, from: ?[]const u8, to: ?[]const u8) !CommitMode {
    const has_range = from != null or to != null;
    if ((pr_id != null and (revision != null or has_range)) or (revision != null and has_range)) return error.BadRequest;
    if (pr_id != null) return .pr;
    if (revision) |rev| {
        if (rev.len == 0) return error.BadRequest;
        return .revision;
    }
    if (from == null or to == null) return error.MissingRequired;
    if (from.?.len == 0 or to.?.len == 0) return error.BadRequest;
    return .range;
}

test "commit modes reject conflicts and incomplete ranges" {
    const t = std.testing;
    try t.expectEqual(CommitMode.pr, try commitMode(7, null, null, null));
    try t.expectEqual(CommitMode.revision, try commitMode(null, "main", null, null));
    try t.expectEqual(CommitMode.range, try commitMode(null, null, "base", "tip"));
    try t.expectError(error.BadRequest, commitMode(7, null, null, "tip"));
    try t.expectError(error.BadRequest, commitMode(null, "main", null, "tip"));
    try t.expectError(error.BadRequest, commitMode(7, "main", null, null));
    try t.expectError(error.BadRequest, commitMode(null, "main", "base", "tip"));
    try t.expectError(error.MissingRequired, commitMode(null, null, "base", null));
    try t.expectError(error.MissingRequired, commitMode(null, null, null, "tip"));
    try t.expectError(error.MissingRequired, commitMode(null, null, null, null));
    try t.expectError(error.BadRequest, commitMode(null, null, "", "tip"));
}

test "review followups Commit flags accept interleaved paging and range controls" {
    const p = try parse(&.{ "--limit", "1", "--to=tip", "--page", "3", "--repository", "repo", "--query", "message ~ \"fix\"", "--from", "base", "--sort=-date", "--pagelen", "2", "--no-follow" });
    try std.testing.expectEqual(CommitMode.range, p.mode);
    try std.testing.expectEqualStrings("repo", p.repository.?);
    try std.testing.expectEqualStrings("base", p.from.?);
    try std.testing.expectEqualStrings("tip", p.to.?);
    try std.testing.expectEqual(@as(?usize, 1), p.page.limit);
    try std.testing.expectEqual(@as(?u32, 3), p.page.page);
    try std.testing.expectEqual(@as(?u32, 2), p.page.pagelen);
    try std.testing.expectEqualStrings("message ~ \"fix\"", p.page.query.?);
    try std.testing.expectEqualStrings("-date", p.page.sort.?);
    try std.testing.expect(!p.page.follow);
    try std.testing.expectEqual(CommitMode.pr, (try parse(&.{ "--sort", "-date", "--pull-request-id", "7", "--limit", "1", "--repository", "repo" })).mode);
    try std.testing.expectEqual(CommitMode.revision, (try parse(&.{ "--revision", "main", "--no-follow", "--repository", "repo" })).mode);
}

test "review followups Commit parser rejects conflicting values and modes in any order" {
    try std.testing.expectError(error.BadRequest, parse(&.{ "--to", "tip", "--repository", "repo", "--revision", "main" }));
    try std.testing.expectError(error.BadRequest, parse(&.{ "--pull-request-id", "7", "--limit", "1", "--repository", "repo", "--from", "base", "--to", "tip" }));
    try std.testing.expectError(error.BadRequest, parse(&.{ "--from", "base", "--repository", "repo", "--to", "tip", "--from", "other" }));
    try std.testing.expectError(error.BadRequest, parse(&.{ "--revision", "main", "--repository", "repo", "--repository", "other" }));
    try std.testing.expectError(error.MissingRequired, parse(&.{ "--to", "tip", "--limit", "1", "--repository", "repo" }));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "--repository", "repo", "--revision", "main", "extra" }));
}
