//! `bbr api list-commits`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");

pub const help =
    \\usage: bbr api list-commits --repository SLUG (--pull-request-id N | --revision REV | --from HASH --to HASH) [--pagelen N] [--no-follow] [--limit N] [--json]
    \\
    \\List commits on a pull request, at a revision, or in a from..to range
    \\(range resolves via the revision endpoint on --to).
    \\
;

pub fn run(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var revision: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "revision")) {
            _ = cur.next();
            revision = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "from")) {
            _ = cur.next();
            from = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "to")) {
            _ = cur.next();
            to = try arg.takeValue(&cur, f);
        } else break;
    }
    const rest = args[cur.pos..];
    var cur2: arg.Cursor = .{ .args = rest };
    const opts = try ws.pageOpts(rest, &cur2);
    if (!cur2.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;

    const mode: enum { pr, revision, range } = if (pr_id != null)
        .pr
    else if (revision != null)
        .revision
    else if (from != null and to != null)
        .range
    else
        return error.MissingRequired;
    if ((mode == .pr and (revision != null or from != null)) or
        (mode == .revision and (pr_id != null or from != null)) or
        (mode == .range and (pr_id != null or revision != null)))
        return error.BadRequest;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const items: []bbr.bitbucket.Commit = switch (mode) {
        .pr => try bb.listPrCommits(a, repo, pr_id.?, opts),
        .revision => try bb.listRepoCommits(a, repo, revision.?, opts),
        .range => blk: {
            // Range: list commits reachable from --to, then cut at --from.
            const all = try bb.listRepoCommits(a, repo, to.?, opts);
            var end: usize = all.len;
            for (all, 0..) |c, i| {
                if (std.mem.startsWith(u8, c.hash, from.?) or std.mem.startsWith(u8, from.?, c.hash)) {
                    end = @min(i + 1, all.len);
                    break;
                }
            }
            break :blk all[0..end];
        },
    };
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |c| try out.printLine(init, "{s} {s} {s}", .{ c.hash, c.author, c.message });
        try out.printLine(init, "ok: {d} commit(s)", .{items.len});
    }
}
