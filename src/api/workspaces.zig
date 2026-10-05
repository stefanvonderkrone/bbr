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

pub fn pageOpts(args: []const []const u8, cur: *arg.Cursor) !bbr.bitbucket.PageOptions {
    var opts: bbr.bitbucket.PageOptions = .{};
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "pagelen")) {
            _ = cur.next();
            opts.pagelen = try arg.parseU32(try arg.takeValue(cur, f));
        } else if (std.mem.eql(u8, f.name, "page")) {
            _ = cur.next();
            opts.page = try arg.parseU32(try arg.takeValue(cur, f));
        } else if (std.mem.eql(u8, f.name, "query")) {
            _ = cur.next();
            opts.query = try arg.takeValue(cur, f);
        } else if (std.mem.eql(u8, f.name, "sort")) {
            _ = cur.next();
            opts.sort = try arg.takeValue(cur, f);
        } else if (std.mem.eql(u8, f.name, "no-follow")) {
            _ = cur.next();
            opts.follow = false;
        } else if (std.mem.eql(u8, f.name, "limit")) {
            _ = cur.next();
            opts.limit = try arg.parseUsize(try arg.takeValue(cur, f));
        } else break;
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
    }
}
