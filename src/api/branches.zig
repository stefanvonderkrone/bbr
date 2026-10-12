//! `bbr api create-branch | list-branches | get-branch`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const pages = @import("workspaces.zig");

pub const create_help =
    \\usage: bbr api create-branch --repository SLUG --name NAME --target REV [--json]
    \\
    \\Create a branch from a commit hash or an existing branch name.
    \\Use a branch name without the refs/heads/ prefix.
    \\
;

pub const list_help =
    \\usage: bbr api list-branches --repository SLUG [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
    \\
    \\List branches. Follow pages by default. --limit caps the total.
    \\--query filters branches. --sort name uses Bitbucket's natural name order.
    \\
;

pub const get_help =
    \\usage: bbr api get-branch --repository SLUG --name NAME [--json]
    \\
    \\Read a branch, its target Commit, and its merge strategies.
    \\Use a branch name without the refs/heads/ prefix.
    \\
;

const Kind = enum { create, list, get };
const Parsed = struct {
    repository: ?[]const u8 = null,
    name: ?[]const u8 = null,
    target: ?[]const u8 = null,
    page: bbr.bitbucket.PageOptions = .{},
};

fn parse(args: []const []const u8, kind: Kind) !Parsed {
    var cur: arg.Cursor = .{ .args = args };
    var p: Parsed = .{};
    while (cur.peek()) |text| {
        const f = arg.splitFlag(text) orelse return error.UnknownFlag;
        if (kind == .list and try pages.takePageFlag(&cur, f, &p.page)) continue;
        _ = cur.next();
        if (std.mem.eql(u8, f.name, "repository")) {
            try arg.setOption([]const u8, &p.repository, try arg.takeValue(&cur, f));
        } else if (kind != .list and std.mem.eql(u8, f.name, "name")) {
            try arg.setOption([]const u8, &p.name, try arg.takeValue(&cur, f));
        } else if (kind == .create and std.mem.eql(u8, f.name, "target")) {
            try arg.setOption([]const u8, &p.target, try arg.takeValue(&cur, f));
        } else return error.UnknownFlag;
    }
    const repository = p.repository orelse return error.MissingRequired;
    if (repository.len == 0) return error.BadRequest;
    if (kind != .list) {
        const name = p.name orelse return error.MissingRequired;
        if (name.len == 0 or std.mem.startsWith(u8, name, "refs/heads/")) return error.BadRequest;
    }
    if (kind == .create) {
        const target = p.target orelse return error.MissingRequired;
        if (target.len == 0) return error.BadRequest;
    }
    return p;
}

fn branchRequest(a: std.mem.Allocator, bb: bbr.bitbucket.Client, args: []const []const u8, create: bool) !bbr.bitbucket.Branch {
    const p = try parse(args, if (create) .create else .get);
    return if (create)
        bb.createBranch(a, p.repository.?, p.name.?, p.target.?)
    else
        bb.getBranch(a, p.repository.?, p.name.?);
}

fn printBranch(init: std.process.Init, branch: bbr.bitbucket.Branch, json: bool) !void {
    if (json) return out.printJson(init, branch);
    try out.printLine(init, "{s} {s}", .{ branch.name, branch.target.hash });
    if (branch.url.len != 0) try out.printLine(init, "url: {s}", .{branch.url});
    try out.printLine(init, "author: {s}", .{branch.target.author});
    try out.printLine(init, "date: {s}", .{branch.target.date});
    try out.printLine(init, "message: {s}", .{branch.target.message});
    try out.printLine(init, "default merge strategy: {s}", .{branch.default_merge_strategy});
    for (branch.merge_strategies) |strategy| try out.printLine(init, "merge strategy: {s}", .{strategy});
}

pub fn runCreate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try printBranch(init, try branchRequest(arena.allocator(), bb, args, true), json);
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try printBranch(init, try branchRequest(arena.allocator(), bb, args, false), json);
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parse(args, .list);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const branches = try bb.listBranches(arena.allocator(), p.repository.?, p.page);
    if (json) return out.printJson(init, branches);
    for (branches) |branch| try out.printLine(init, "{s} {s}", .{ branch.name, branch.target.hash });
    try out.printLine(init, "ok: {d} branch(es)", .{branches.len});
}

test "API lifecycle branch flags support interleaved values and reject invalid writes before HTTP" {
    const a = std.testing.allocator;
    const p = try parse(&.{ "--target=main", "--name", "feature/test", "--repository=sample" }, .create);
    try std.testing.expectEqualStrings("feature/test", p.name.?);
    const listed = try parse(&.{ "--page=2", "--repository", "sample", "--query", "name ~ \"test\"", "--no-follow", "--limit=1" }, .list);
    try std.testing.expectEqual(@as(?u32, 2), listed.page.page);
    try std.testing.expect(!listed.page.follow);
    var fake: bbr.http.FakeHttpClient = .{};
    const bb = bbr.bitbucket.Client.init(fake.httpClient(), .{ .username = "u", .token = "t", .workspace = "w" });
    for ([_][]const []const u8{
        &.{ "--repository=sample", "--name=refs/heads/feature", "--target=main" },
        &.{ "--repository=sample", "--name=", "--target=main" },
        &.{ "--repository=sample", "--name=feature", "--target=" },
        &.{ "--repository=sample", "--name=feature", "--target=main", "--target=other" },
    }) |args| try std.testing.expectError(error.BadRequest, branchRequest(a, bb, args, true));
    try std.testing.expectError(error.MissingRequired, branchRequest(a, bb, &.{"--repository=sample"}, true));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "--repository=sample", "--name=main", "--target=other" }, .get));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
}
