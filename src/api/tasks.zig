//! `bbr api list-tasks | get-task | create-task | update-task |
//! delete-task | resolve-task | reopen-task`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");

pub const list_help =
    \\usage: bbr api list-tasks --repository SLUG --pull-request-id N [--state-filter RESOLVED|UNRESOLVED] [--pagelen N] [--no-follow] [--limit N] [--json]
    \\
;

pub const get_help =
    \\usage: bbr api get-task --repository SLUG --pull-request-id N --task-id N [--json]
    \\
;

pub const create_help =
    \\usage: bbr api create-task --repository SLUG --pull-request-id N (--content TEXT | --content-file PATH) [--comment-id N] [--json]
    \\
;

pub const update_help =
    \\usage: bbr api update-task --repository SLUG --pull-request-id N --task-id N [--content TEXT | --content-file PATH] [--state RESOLVED|UNRESOLVED] [--json]
    \\
    \\At least one of --content/--content-file/--state is required.
    \\
;

pub const delete_help =
    \\usage: bbr api delete-task --repository SLUG --pull-request-id N --task-id N
    \\
;

pub const resolve_help =
    \\usage: bbr api resolve-task --repository SLUG --pull-request-id N --task-id N [--json]
    \\
;

pub const reopen_help =
    \\usage: bbr api reopen-task --repository SLUG --pull-request-id N --task-id N [--json]
    \\
;

const Ids = struct {
    repository: []const u8,
    pr_id: u64,
    task_id: ?u64,
};

fn parseBase(args: []const []const u8, want_task: bool) !struct { ids: Ids, rest: []const []const u8 } {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var task_id: ?u64 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            pr_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (want_task and std.mem.eql(u8, f.name, "task-id")) {
            _ = cur.next();
            task_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else break;
    }
    return .{
        .ids = .{
            .repository = repository orelse return error.MissingRequired,
            .pr_id = pr_id orelse return error.MissingRequired,
            .task_id = task_id,
        },
        .rest = args[cur.pos..],
    };
}

fn readContent(init: std.process.Init, cur: *arg.Cursor) !struct { text: ?[]const u8, owned: bool } {
    var text: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "content")) {
            _ = cur.next();
            text = try arg.takeValue(cur, f);
        } else if (std.mem.eql(u8, f.name, "content-file")) {
            _ = cur.next();
            file = try arg.takeValue(cur, f);
        } else break;
    }
    if (text != null and file != null) return error.BadRequest;
    if (text) |t| return .{ .text = t, .owned = false };
    if (file) |path| return .{ .text = try out.readFile(init.io, init.gpa, path), .owned = true };
    return .{ .text = null, .owned = false };
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBase(args, false);
    var cur: arg.Cursor = .{ .args = p.rest };
    var state_filter: ?[]const u8 = null;
    // Peek state-filter first, then delegate the rest to page flags.
    if (cur.peek()) |a| {
        if (arg.splitFlag(a)) |f| {
            if (std.mem.eql(u8, f.name, "state-filter") or std.mem.eql(u8, f.name, "state")) {
                _ = cur.next();
                state_filter = try arg.takeValue(&cur, f);
            }
        }
    }
    const rest = p.rest[cur.pos..];
    var cur2: arg.Cursor = .{ .args = rest };
    const opts = try ws.pageOpts(rest, &cur2);
    if (!cur2.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const all = try bb.listTasks(arena.allocator(), p.ids.repository, p.ids.pr_id, opts);
    // Client-side state filter (the API has no server-side state param here).
    var count: usize = 0;
    for (all) |t| {
        if (state_filter) |s| {
            if (!std.mem.eql(u8, t.state, s)) continue;
        }
        count += 1;
    }
    if (json) {
        if (state_filter) |s| {
            var filtered: std.ArrayList(bbr.bitbucket.Task) = .empty;
            defer filtered.deinit(init.gpa);
            for (all) |t| {
                if (std.mem.eql(u8, t.state, s)) try filtered.append(init.gpa, t);
            }
            try out.printJson(init, filtered.items);
        } else {
            try out.printJson(init, all);
        }
    } else {
        for (all) |t| {
            if (state_filter) |s| {
                if (!std.mem.eql(u8, t.state, s)) continue;
            }
            try out.printLine(init, "#{d} [{s}] {s}", .{ t.id, t.state, t.content });
        }
        try out.printLine(init, "ok: {d} task(s)", .{count});
    }
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBase(args, true);
    if (p.rest.len != 0) return error.UnknownFlag;
    const tid = p.ids.task_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const t = try bb.getTask(arena.allocator(), p.ids.repository, p.ids.pr_id, tid);
    if (json) {
        try out.printJson(init, t);
    } else {
        try out.printLine(init, "#{d} [{s}] {s}", .{ t.id, t.state, t.content });
    }
}

pub fn runCreate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBase(args, false);
    var cur: arg.Cursor = .{ .args = p.rest };
    const read = try readContent(init, &cur);
    defer if (read.owned) init.gpa.free(read.text.?);
    const content = read.text orelse return error.MissingRequired;
    var comment_id: ?u64 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "comment-id")) {
            _ = cur.next();
            comment_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const id = try bb.createTask(arena.allocator(), p.ids.repository, p.ids.pr_id, content, comment_id);
    if (json) {
        try out.printJson(init, .{ .id = id });
    } else {
        try out.printLine(init, "ok: task #{d}", .{id});
    }
}

pub fn runUpdate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBase(args, true);
    var cur: arg.Cursor = .{ .args = p.rest };
    const read = try readContent(init, &cur);
    defer if (read.owned) init.gpa.free(read.text.?);
    var state: ?[]const u8 = null;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (std.mem.eql(u8, f.name, "state")) {
            _ = cur.next();
            state = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    const tid = p.ids.task_id orelse return error.MissingRequired;
    if (read.text == null and state == null) return error.MissingRequired;
    if (state) |s| {
        if (!std.mem.eql(u8, s, "RESOLVED") and !std.mem.eql(u8, s, "UNRESOLVED")) return error.BadRequest;
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const t = try bb.updateTask(arena.allocator(), p.ids.repository, p.ids.pr_id, tid, read.text, state);
    if (json) {
        try out.printJson(init, t);
    } else {
        try out.printLine(init, "#{d} [{s}] {s}", .{ t.id, t.state, t.content });
    }
}

pub fn runDelete(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseBase(args, true);
    if (p.rest.len != 0) return error.UnknownFlag;
    const tid = p.ids.task_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try bb.deleteTask(arena.allocator(), p.ids.repository, p.ids.pr_id, tid);
    if (json) {
        try out.printJson(init, .{ .id = tid, .deleted = true });
    } else {
        try out.printLine(init, "ok: deleted task #{d}", .{tid});
    }
}

fn runState(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool, resolved: bool) !void {
    const p = try parseBase(args, true);
    if (p.rest.len != 0) return error.UnknownFlag;
    const tid = p.ids.task_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const t = try bb.setTaskState(arena.allocator(), p.ids.repository, p.ids.pr_id, tid, resolved);
    if (json) {
        try out.printJson(init, t);
    } else {
        try out.printLine(init, "ok: task #{d} [{s}]", .{ t.id, t.state });
    }
}

pub fn runResolve(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    try runState(init, bb, args, json, true);
}

pub fn runReopen(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    try runState(init, bb, args, json, false);
}
