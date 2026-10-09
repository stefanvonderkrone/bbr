//! `bbr api list-workspaces | get-workspace`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");

pub const list_help =
    \\usage: bbr api list-workspaces [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
    \\
    \\List workspaces visible to the authenticated account (GET /user/workspaces).
    \\Follows pages by default; --no-follow returns one page.
    \\
;

pub const get_help =
    \\usage: bbr api get-workspace [--workspace SLUG] [--json]
    \\
    \\Get one workspace (GET /workspaces/{workspace}). Defaults to the
    \\workspace from BITBUCKET_WORKSPACE.
    \\
;

/// The cursor points at the flag. Unknown flags leave the cursor and options unchanged.
pub fn takePageFlag(cur: *arg.Cursor, f: arg.Flag, opts: *bbr.bitbucket.PageOptions) !bool {
    if (std.mem.eql(u8, f.name, "pagelen")) {
        _ = cur.next();
        const n = try arg.parseU32(try arg.takeValue(cur, f));
        if (n == 0 or n > 100) return error.InvalidNumber;
        opts.pagelen = n;
    } else if (std.mem.eql(u8, f.name, "page")) {
        _ = cur.next();
        const n = try arg.parseU32(try arg.takeValue(cur, f));
        if (n == 0) return error.InvalidNumber;
        opts.page = n;
    } else if (std.mem.eql(u8, f.name, "query")) {
        _ = cur.next();
        opts.query = try arg.takeValue(cur, f);
    } else if (std.mem.eql(u8, f.name, "sort")) {
        _ = cur.next();
        opts.sort = try arg.takeValue(cur, f);
    } else if (std.mem.eql(u8, f.name, "no-follow")) {
        if (f.value != null) return error.UnknownFlag;
        _ = cur.next();
        opts.follow = false;
    } else if (std.mem.eql(u8, f.name, "limit")) {
        _ = cur.next();
        opts.limit = try arg.parseUsize(try arg.takeValue(cur, f));
    } else return false;
    return true;
}

pub fn pageOpts(args: []const []const u8, cur: *arg.Cursor) !bbr.bitbucket.PageOptions {
    var opts: bbr.bitbucket.PageOptions = .{};
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (!try takePageFlag(cur, f, &opts)) break;
    }
    _ = args;
    return opts;
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    const opts = try pageOpts(args, &cur);
    if (!cur.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const items = try bb.listWorkspaces(arena.allocator(), opts);
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |w| try out.printLine(init, "{s}", .{w.slug});
        try out.printLine(init, "ok: {d} workspace(s)", .{items.len});
    }
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var workspace: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "workspace")) {
            _ = cur.next();
            workspace = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const ws = workspace orelse bb.cred.workspace;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const w = try bb.getWorkspace(arena.allocator(), ws);
    if (json) {
        try out.printJson(init, w);
    } else {
        try out.printLine(init, "{s} ({s})", .{ w.slug, w.name });
        try out.printLine(init, "uuid: {s}", .{w.uuid});
    }
}

test "page flag parser consumes recognized flags and leaves unknown flags unchanged" {
    var cur: arg.Cursor = .{ .args = &.{ "--page", "2", "--query=id > 0", "--no-follow", "--repository=demo" } };
    var opts: bbr.bitbucket.PageOptions = .{};
    for (0..3) |_| {
        const f = arg.splitFlag(cur.peek().?).?;
        try std.testing.expect(try takePageFlag(&cur, f, &opts));
    }
    try std.testing.expectEqual(@as(usize, 4), cur.pos);
    try std.testing.expectEqual(@as(u32, 2), opts.page.?);
    try std.testing.expectEqualStrings("id > 0", opts.query.?);
    try std.testing.expect(!opts.follow);
    const before = opts;
    try std.testing.expect(!try takePageFlag(&cur, arg.splitFlag(cur.peek().?).?, &opts));
    try std.testing.expectEqual(@as(usize, 4), cur.pos);
    try std.testing.expectEqual(before, opts);
}

test "page options validate numbers and reject values on no-follow" {
    const invalid = [_][]const u8{ "--pagelen=0", "--pagelen=101", "--page=0", "--page=-1", "--page=4294967296", "--limit=bad" };
    for (invalid) |flag| {
        var cur: arg.Cursor = .{ .args = &.{flag} };
        try std.testing.expectError(error.InvalidNumber, pageOpts(cur.args, &cur));
    }
    for ([_][]const u8{ "--no-follow=false", "--no-follow=true", "--no-follow=" }) |flag| {
        var cur: arg.Cursor = .{ .args = &.{flag} };
        try std.testing.expectError(error.UnknownFlag, pageOpts(cur.args, &cur));
        try std.testing.expectEqual(@as(usize, 0), cur.pos);
    }
    var missing: arg.Cursor = .{ .args = &.{"--page"} };
    try std.testing.expectError(error.MissingValue, pageOpts(missing.args, &missing));
    var valid: arg.Cursor = .{ .args = &.{ "--pagelen", "100", "--limit=0", "--sort=-slug" } };
    const opts = try pageOpts(valid.args, &valid);
    try std.testing.expect(valid.done());
    try std.testing.expectEqual(@as(u32, 100), opts.pagelen.?);
    try std.testing.expectEqual(@as(usize, 0), opts.limit.?);
    try std.testing.expectEqualStrings("-slug", opts.sort.?);
}
