//! `bbr api list-prs | get-pr | whoami | get-verdict | set-verdict`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");

pub const list_help =
    \\usage: bbr api list-prs --repository SLUG [--state OPEN|MERGED|DECLINED|SUPERSEDED] [--source-branch NAME] [--limit N] [--json]
    \\
    \\List pull requests (GET .../pullrequests, follows pages).
    \\
;

pub const get_help =
    \\usage: bbr api get-pr --repository SLUG --pull-request-id N [--json]
    \\
;

pub const whoami_help =
    \\usage: bbr api whoami [--json]
    \\
    \\Print the authenticated account UUID (GET /user).
    \\
;

pub const get_verdict_help =
    \\usage: bbr api get-verdict --repository SLUG --pull-request-id N [--uuid UUID] [--json]
    \\
    \\Show the review verdict for one account (defaults to the authenticated account).
    \\
;

pub const set_verdict_help =
    \\usage: bbr api set-verdict --repository SLUG --pull-request-id N --verdict approved|changes_requested|none --expected-source-commit HASH [--uuid UUID] [--json]
    \\
;

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var state: []const u8 = "OPEN";
    var source_branch: ?[]const u8 = null;
    var limit: ?usize = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "state")) {
            _ = cur.next();
            state = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "source-branch")) {
            _ = cur.next();
            source_branch = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "limit")) {
            _ = cur.next();
            limit = try arg.parseUsize(try arg.takeValue(&cur, f));
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const all = try bb.listPullRequests(arena.allocator(), repo, .{
        .state = state,
        .source_branch = source_branch,
    });
    const items = if (limit) |n| all[0..@min(n, all.len)] else all;
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |pr| try out.printLine(init, "#{d} [{s}] {s} ({s} -> {s})", .{
            pr.id, pr.state, pr.title, pr.source_branch, pr.destination_branch,
        });
        try out.printLine(init, "ok: {d} pull request(s)", .{items.len});
    }
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;
    const id = pr_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const pr = try bb.getPullRequest(arena.allocator(), repo, id);
    if (json) {
        try out.printJson(init, pr);
    } else {
        try out.printLine(init, "#{d} [{s}] {s}", .{ pr.id, pr.state, pr.title });
        try out.printLine(init, "author: {s}", .{pr.author_display_name});
        try out.printLine(init, "{s} -> {s}", .{ pr.source_branch, pr.destination_branch });
        try out.printLine(init, "source: {s} destination: {s}", .{ pr.source_commit, pr.destination_commit });
    }
}

pub fn runWhoami(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    if (args.len != 0) return error.UnknownFlag;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const uuid = try bb.getAuthenticatedAccountUuid(arena.allocator());
    if (json) {
        try out.printJson(init, .{ .uuid = uuid });
    } else {
        try out.printLine(init, "{s}", .{uuid});
    }
}

pub fn runGetVerdict(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var uuid: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "uuid")) {
            _ = cur.next();
            uuid = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;
    const id = pr_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const account = if (uuid) |u| u else try bb.getAuthenticatedAccountUuid(a);
    const pr = try bb.getPullRequest(a, repo, id);
    const verdict = pr.reviewerVerdict(account);
    if (json) {
        try out.printJson(init, .{ .uuid = account, .verdict = @tagName(verdict) });
    } else {
        try out.printLine(init, "{s}: {s}", .{ account, @tagName(verdict) });
    }
}

pub fn runSetVerdict(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var verdict_s: ?[]const u8 = null;
    var expected: ?[]const u8 = null;
    var uuid: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "verdict")) {
            _ = cur.next();
            verdict_s = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "expected-source-commit")) {
            _ = cur.next();
            expected = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "uuid")) {
            _ = cur.next();
            uuid = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;
    const id = pr_id orelse return error.MissingRequired;
    const vs = verdict_s orelse return error.MissingRequired;
    const exp = expected orelse return error.MissingRequired;
    const target: bbr.bitbucket.ReviewerVerdict = if (std.mem.eql(u8, vs, "approved"))
        .approved
    else if (std.mem.eql(u8, vs, "changes_requested"))
        .changes_requested
    else if (std.mem.eql(u8, vs, "none") or std.mem.eql(u8, vs, "no_verdict"))
        .no_verdict
    else
        return error.BadRequest;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const account = if (uuid) |u| u else try bb.getAuthenticatedAccountUuid(a);
    const result = try bb.changeReviewerVerdict(a, repo, id, exp, account, target);
    const name: []const u8 = switch (result) {
        .success => "success",
        .reconciled_success => "reconciled_success",
        .api_error => "api_error",
        .stale_source_commit => "stale_source_commit",
        .unresolved => "unresolved",
    };
    if (json) {
        try out.printJson(init, .{ .result = name, .verdict = vs });
    } else {
        try out.printLine(init, "ok: {s} (verdict {s})", .{ name, vs });
    }
    const ok = switch (result) {
        .success, .reconciled_success => true,
        else => false,
    };
    if (!ok) return error.ReviewerVerdictChangeFailed;
}
