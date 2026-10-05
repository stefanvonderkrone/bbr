//! `bbr api get-diff | get-compare-diff | get-blob | check-blob`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");

pub const diff_help =
    \\usage: bbr api get-diff --repository SLUG --pull-request-id N [--out PATH] [--json]
    \\
    \\Raw unified diff of a pull request (GET .../pullrequests/{id}/diff).
    \\
;

pub const compare_help =
    \\usage: bbr api get-compare-diff --repository SLUG --from HASH --to HASH [--patch] [--out PATH] [--json]
    \\
    \\Raw diff between two commits (GET .../diff/{from}..{to}).
    \\--patch returns the patch form instead.
    \\
;

pub const blob_help =
    \\usage: bbr api get-blob --repository SLUG --commit HASH --path PATH [--out FILE] [--json]
    \\
;

pub const check_help =
    \\usage: bbr api check-blob --repository SLUG --commit HASH --path PATH [--attributes a,b|-] [--json]
    \\
    \\Verify file metadata (type/path/commit/size/attributes) then report size.
    \\
;

fn parseRepoPr(args: []const []const u8) !struct { repository: []const u8, pr_id: ?u64, rest: []const []const u8 } {
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
    return .{
        .repository = repository orelse return error.MissingRequired,
        .pr_id = pr_id,
        .rest = args[cur.pos..],
    };
}

pub fn runDiff(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseRepoPr(args);
    const id = p.pr_id orelse return error.MissingRequired;
    var cur: arg.Cursor = .{ .args = p.rest };
    var out_path: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "out")) {
            _ = cur.next();
            out_path = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const raw = try bb.getDiff(arena.allocator(), p.repository, id);
    if (json) {
        try out.printJson(init, .{ .repository = p.repository, .pull_request_id = id, .diff = raw });
    } else {
        try out.printRaw(init, raw, out_path);
    }
}

pub fn runCompare(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var patch = false;
    var out_path: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "from")) {
            _ = cur.next();
            from = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "to")) {
            _ = cur.next();
            to = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "patch")) {
            _ = cur.next();
            patch = true;
        } else if (std.mem.eql(u8, f.name, "out")) {
            _ = cur.next();
            out_path = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const repo = repository orelse return error.MissingRequired;
    const f = from orelse return error.MissingRequired;
    const t = to orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const raw = try bb.getCompareDiff(arena.allocator(), repo, f, t, patch);
    if (json) {
        try out.printJson(init, .{ .repository = repo, .from = f, .to = t, .diff = raw });
    } else {
        try out.printRaw(init, raw, out_path);
    }
}

fn parseBlobArgs(args: []const []const u8) !struct {
    repository: []const u8,
    commit: []const u8,
    path: []const u8,
    rest: []const []const u8,
} {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "commit")) {
            _ = cur.next();
            commit = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "path")) {
            _ = cur.next();
            path = try arg.takeValue(&cur, f);
        } else break;
    }
    return .{
        .repository = repository orelse return error.MissingRequired,
        .commit = commit orelse return error.MissingRequired,
        .path = path orelse return error.MissingRequired,
        .rest = args[cur.pos..],
    };
}

pub fn runBlob(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBlobArgs(args);
    var cur: arg.Cursor = .{ .args = p.rest };
    var out_path: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "out")) {
            _ = cur.next();
            out_path = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const raw = try bb.getFileBlob(arena.allocator(), p.repository, p.commit, p.path);
    if (json) {
        // Bytes may not be UTF-8; report size rather than embedding content.
        try out.printJson(init, .{ .repository = p.repository, .commit = p.commit, .path = p.path, .size = raw.len });
        if (out_path) |path| try out.printRaw(init, raw, path);
    } else {
        try out.printRaw(init, raw, out_path);
    }
}

pub fn runCheck(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBlobArgs(args);
    var cur: arg.Cursor = .{ .args = p.rest };
    var attributes: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "attributes")) {
            _ = cur.next();
            attributes = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (attributes) |attrs_s| {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(a);
        if (!std.mem.eql(u8, attrs_s, "-")) {
            var it = std.mem.splitScalar(u8, attrs_s, ',');
            while (it.next()) |attr| {
                if (attr.len == 0) return error.BadRequest;
                try list.append(a, attr);
            }
        }
        const n = try bb.checkFileBlob(a, p.repository, p.commit, p.path, list.items);
        if (json) {
            const meta = try bb.getFileMeta(a, p.repository, p.commit, p.path);
            try out.printJson(init, .{ .path = meta.path, .commit = meta.commit, .size = meta.size, .attributes = meta.attributes, .raw = n });
        } else {
            try out.printLine(init, "ok: {s} size={d} attributes={s}", .{ p.path, n, attrs_s });
        }
    } else {
        const meta = try bb.getFileMeta(a, p.repository, p.commit, p.path);
        if (json) {
            try out.printJson(init, .{ .path = meta.path, .commit = meta.commit, .size = meta.size, .attributes = meta.attributes });
        } else {
            try out.printLine(init, "ok: {s} size={d}", .{ meta.path, meta.size });
        }
    }
}
