//! `bbr api list-comments | get-comment | create-comment | update-comment |
//! delete-comment | resolve-comment | reopen-comment`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");

pub const list_help =
    \\usage: bbr api list-comments --repository SLUG --pull-request-id N [--source-commit H] [--destination-commit H] [--no-head] [--limit N] [--json]
    \\
    \\List comments (GET .../comments, follows pages). PR head is fetched
    \\automatically for outdated detection unless --no-head or explicit commits.
    \\
;

pub const get_help =
    \\usage: bbr api get-comment --repository SLUG --pull-request-id N --comment-id N [--json]
    \\
;

pub const create_help =
    \\usage: bbr api create-comment --repository SLUG --pull-request-id N (--body TEXT | --body-file PATH)
    \\      [--parent-id N | --path P (--to N | --from N) [--start-to N] [--start-from N] | --file-path P [--source-commit H]]
    \\
    \\Scope is inferred: --parent-id = reply; --path + lines = inline;
    \\--file-path = file; otherwise review-level.
    \\
;

pub const update_help =
    \\usage: bbr api update-comment --repository SLUG --pull-request-id N --comment-id N (--body TEXT | --body-file PATH) [--json]
    \\
;

pub const delete_help =
    \\usage: bbr api delete-comment --repository SLUG --pull-request-id N --comment-id N
    \\
;

pub const resolve_help =
    \\usage: bbr api resolve-comment --repository SLUG --pull-request-id N --comment-id N
    \\
;

pub const reopen_help =
    \\usage: bbr api reopen-comment --repository SLUG --pull-request-id N --comment-id N
    \\
;

const Ids = struct {
    repository: []const u8,
    pr_id: u64,
};

fn parseIds(args: []const []const u8, want_comment: bool) !struct { ids: Ids, comment_id: ?u64, rest: []const []const u8 } {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var comment_id: ?u64 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (want_comment and std.mem.eql(u8, f.name, "comment-id")) {
            _ = cur.next();
            comment_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else break;
    }
    return .{
        .ids = .{
            .repository = repository orelse return error.MissingRequired,
            .pr_id = pr_id orelse return error.MissingRequired,
        },
        .comment_id = comment_id,
        .rest = args[cur.pos..],
    };
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseIds(args, false);
    var cur: arg.Cursor = .{ .args = p.rest };
    var source: ?[]const u8 = null;
    var dest: ?[]const u8 = null;
    var no_head = false;
    var limit: ?usize = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "source-commit")) {
            _ = cur.next();
            source = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "destination-commit")) {
            _ = cur.next();
            dest = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "no-head")) {
            _ = cur.next();
            no_head = true;
        } else if (std.mem.eql(u8, f.name, "limit")) {
            _ = cur.next();
            limit = try arg.parseUsize(try arg.takeValue(&cur, f));
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var head: bbr.bitbucket.types.HeadCommits = .{};
    if (!no_head) {
        if (source != null and dest != null) {
            head = .{ .source = source.?, .destination = dest.? };
        } else {
            const pr = try bb.getPullRequest(a, p.ids.repository, p.ids.pr_id);
            head = .{ .source = pr.source_commit, .destination = pr.destination_commit };
        }
    }
    const all = try bb.getComments(a, p.ids.repository, p.ids.pr_id, head);
    const items = if (limit) |n| all[0..@min(n, all.len)] else all;
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |c| {
            const where: []const u8 = if (c.anchor) |anc| anc.path else "(review)";
            const state: []const u8 = @tagName(c.state);
            try out.printLine(init, "#{d} {s} [{s}{s}] {s}", .{
                c.id, c.author, where, state,
                if (c.resolved) " resolved" else "",
            });
        }
        try out.printLine(init, "ok: {d} comment(s)", .{items.len});
    }
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseIds(args, true);
    if (p.rest.len != 0) return error.UnknownFlag;
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const comments = try bb.getComments(
        arena.allocator(),
        p.ids.repository,
        p.ids.pr_id,
        .{},
    );
    for (comments) |c| {
        if (c.id != cid) continue;
        if (json) {
            try out.printJson(init, c);
        } else {
            try out.printLine(init, "#{d} {s}: {s}", .{ c.id, c.author, c.body });
        }
        return;
    }
    // Fall back to the single-comment endpoint (covers non-listed shapes).
    const single = try bb.getComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid);
    if (json) {
        try out.printJson(init, single);
    } else {
        try out.printLine(init, "#{d} {s}: {s}", .{ single.id, single.author, single.body });
    }
}

fn readBody(init: std.process.Init, cur: *arg.Cursor) !struct { body: []const u8, owned: bool } {
    var body: ?[]const u8 = null;
    var body_file: ?[]const u8 = null;
    // Caller positions cursor at body flags; parse them here.
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "body")) {
            _ = cur.next();
            body = try arg.takeValue(cur, f);
        } else if (std.mem.eql(u8, f.name, "body-file")) {
            _ = cur.next();
            body_file = try arg.takeValue(cur, f);
        } else break;
    }
    if (body != null and body_file != null) return error.BadRequest;
    if (body) |b| return .{ .body = b, .owned = false };
    if (body_file) |path| return .{ .body = try out.readFile(init.io, init.gpa, path), .owned = true };
    return error.MissingRequired;
}

pub fn runCreate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseIds(args, false);
    var cur: arg.Cursor = .{ .args = p.rest };
    const read = try readBody(init, &cur);
    defer if (read.owned) init.gpa.free(read.body);
    const body = read.body;
    var parent_id: ?u64 = null;
    var path: ?[]const u8 = null;
    var to: ?u32 = null;
    var from: ?u32 = null;
    var start_to: ?u32 = null;
    var start_from: ?u32 = null;
    var file_path: ?[]const u8 = null;
    var source_commit: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "parent-id")) {
            _ = cur.next();
            parent_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "path")) {
            _ = cur.next();
            path = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "to")) {
            _ = cur.next();
            to = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "from")) {
            _ = cur.next();
            from = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "start-to")) {
            _ = cur.next();
            start_to = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "start-from")) {
            _ = cur.next();
            start_from = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "file-path")) {
            _ = cur.next();
            file_path = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "source-commit")) {
            _ = cur.next();
            source_commit = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;

    var nc: bbr.bitbucket.NewComment = .{ .body = body };
    if (parent_id) |pid| {
        nc.parent = pid;
    } else if (path) |pa| {
        if (to == null and from == null) return error.MissingRequired;
        if (to != null and from != null) return error.BadRequest;
        nc.scope = .{ .@"inline" = .{
            .path = pa,
            .to = to,
            .from = from,
            .start_to = start_to,
            .start_from = start_from,
        } };
    } else if (file_path) |fp| {
        nc.scope = .{ .file = .{ .path = fp, .source_commit = source_commit orelse "" } };
    } else {
        nc.scope = .review;
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const id = try bb.createComment(arena.allocator(), p.ids.repository, p.ids.pr_id, nc);
    if (json) {
        try out.printJson(init, .{ .id = id });
    } else {
        try out.printLine(init, "ok: comment #{d}", .{id});
    }
}

pub fn runUpdate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseIds(args, true);
    var cur: arg.Cursor = .{ .args = p.rest };
    const read = try readBody(init, &cur);
    defer if (read.owned) init.gpa.free(read.body);
    const body = read.body;
    if (!cur.done()) return error.UnknownFlag;
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try bb.updateComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid, body);
    if (json) {
        try out.printJson(init, .{ .id = cid, .updated = true });
    } else {
        try out.printLine(init, "ok: updated comment #{d}", .{cid});
    }
}

pub fn runDelete(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseIds(args, true);
    if (p.rest.len != 0) return error.UnknownFlag;
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try bb.deleteComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid);
    if (json) {
        try out.printJson(init, .{ .id = cid, .deleted = true });
    } else {
        try out.printLine(init, "ok: deleted comment #{d}", .{cid});
    }
}

pub fn runResolve(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseIds(args, true);
    if (p.rest.len != 0) return error.UnknownFlag;
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try bb.resolveComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid);
    if (json) {
        try out.printJson(init, .{ .id = cid, .resolved = true });
    } else {
        try out.printLine(init, "ok: resolved comment #{d}", .{cid});
    }
}

pub fn runReopen(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseIds(args, true);
    if (p.rest.len != 0) return error.UnknownFlag;
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try bb.reopenComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid);
    if (json) {
        try out.printJson(init, .{ .id = cid, .resolved = false });
    } else {
        try out.printLine(init, "ok: reopened comment #{d}", .{cid});
    }
}
