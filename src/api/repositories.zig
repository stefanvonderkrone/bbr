//! `bbr api list-repositories | get-repository`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");

pub const list_help =
    \\usage: bbr api list-repositories [--workspace SLUG] [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
    \\
    \\List repositories in a workspace (GET /repositories/{workspace}).
    \\Workspace defaults to BITBUCKET_WORKSPACE.
    \\
;

pub const get_help =
    \\usage: bbr api get-repository --repository SLUG [--workspace SLUG] [--json]
    \\
    \\Get one repository (GET /repositories/{workspace}/{repository}).
    \\
;

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var workspace: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "workspace")) {
            _ = cur.next();
            workspace = try arg.takeValue(&cur, f);
        } else break;
    }
    // Remaining page flags follow workspace (order: --workspace first).
    const rest = args[cur.pos..];
    var cur2: arg.Cursor = .{ .args = rest };
    const opts = try ws.pageOpts(rest, &cur2);
    if (!cur2.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const items = try bb.listRepositories(arena.allocator(), workspace, opts);
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |r| try out.printLine(init, "{s} ({s})", .{ r.slug, r.full_name });
        try out.printLine(init, "ok: {d} repositor(ies)", .{items.len});
    }
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var workspace: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "workspace")) {
            _ = cur.next();
            workspace = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const r = try bb.getRepository(arena.allocator(), repo, workspace);
    if (json) {
        try out.printJson(init, r);
    } else {
        try out.printLine(init, "{s} ({s}) private={}", .{ r.slug, r.full_name, r.is_private });
    }
}
