//! `bbr api list-tasks | get-task | create-task | update-task |
//! delete-task | resolve-task | reopen-task`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");

pub const list_help =
    \\usage: bbr api list-tasks --repository SLUG --pull-request-id N [--state-filter RESOLVED|UNRESOLVED] [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
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

const Command = enum { list, get, create, update, delete, resolve, reopen };

const Parsed = struct {
    repository: ?[]const u8 = null,
    pr_id: ?u64 = null,
    task_id: ?u64 = null,
    content: ?[]const u8 = null,
    content_file: ?[]const u8 = null,
    comment_id: ?u64 = null,
    state: ?bbr.bitbucket.TaskState = null,
    page: bbr.bitbucket.PageOptions = .{},
};

fn setOption(comptime T: type, slot: *?T, value: T) !void {
    if (slot.*) |old| {
        const same = if (T == []const u8) std.mem.eql(u8, old, value) else old == value;
        if (!same) return error.BadRequest;
    }
    slot.* = value;
}

fn parse(args: []const []const u8, command: Command) !Parsed {
    var cur: arg.Cursor = .{ .args = args };
    var p: Parsed = .{};
    const want_task = command != .list and command != .create;
    const want_content = command == .create or command == .update;
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (command == .list and try ws.takePageFlag(&cur, f, &p.page)) continue;
        _ = cur.next();
        if (std.mem.eql(u8, f.name, "repository")) {
            try setOption([]const u8, &p.repository, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            try setOption(u64, &p.pr_id, try arg.parseU64(try arg.takeValue(&cur, f)));
        } else if (want_task and std.mem.eql(u8, f.name, "task-id")) {
            try setOption(u64, &p.task_id, try arg.parseU64(try arg.takeValue(&cur, f)));
        } else if (want_content and std.mem.eql(u8, f.name, "content")) {
            try setOption([]const u8, &p.content, try arg.takeValue(&cur, f));
        } else if (want_content and std.mem.eql(u8, f.name, "content-file")) {
            try setOption([]const u8, &p.content_file, try arg.takeValue(&cur, f));
        } else if (command == .create and std.mem.eql(u8, f.name, "comment-id")) {
            try setOption(u64, &p.comment_id, try arg.parseU64(try arg.takeValue(&cur, f)));
        } else if (command == .update and std.mem.eql(u8, f.name, "state")) {
            try setOption(bbr.bitbucket.TaskState, &p.state, try parseState(try arg.takeValue(&cur, f)));
        } else if (command == .list and std.mem.eql(u8, f.name, "state-filter")) {
            try setOption(bbr.bitbucket.TaskState, &p.state, try parseState(try arg.takeValue(&cur, f)));
        } else return error.UnknownFlag;
    }
    if (p.repository == null or p.pr_id == null or (want_task and p.task_id == null)) return error.MissingRequired;
    if (p.content != null and p.content_file != null) return error.BadRequest;
    if (command == .create and p.content == null and p.content_file == null) return error.MissingRequired;
    if (command == .update and p.content == null and p.content_file == null and p.state == null) return error.MissingRequired;
    p.page.task_state = p.state;
    return p;
}

fn readContent(init: std.process.Init, p: Parsed) !struct { text: ?[]const u8, owned: bool } {
    if (p.content) |t| return .{ .text = t, .owned = false };
    if (p.content_file) |path| return .{ .text = try out.readFile(init.io, init.gpa, path), .owned = true };
    return .{ .text = null, .owned = false };
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parse(args, .list);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const all = try bb.listTasks(arena.allocator(), p.repository.?, p.pr_id.?, p.page);
    if (json) {
        try out.printJson(init, all);
    } else {
        for (all) |t| {
            try out.printLine(init, "#{d} [{s}] {s}", .{ t.id, @tagName(t.state), out.firstLine(t.content) });
        }
        try out.printLine(init, "ok: {d} task(s)", .{all.len});
    }
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parse(args, .get);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const t = try bb.getTask(arena.allocator(), p.repository.?, p.pr_id.?, p.task_id.?);
    if (json) {
        try out.printJson(init, t);
    } else {
        try out.printLine(init, "#{d} [{s}] {s}", .{ t.id, @tagName(t.state), t.content });
    }
}

pub fn runCreate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parse(args, .create);
    const read = try readContent(init, p);
    defer if (read.owned) init.gpa.free(read.text.?);
    const content = read.text orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const id = try bb.createTask(arena.allocator(), p.repository.?, p.pr_id.?, content, p.comment_id);
    if (json) {
        try out.printJson(init, .{ .id = id });
    } else {
        try out.printLine(init, "ok: task #{d}", .{id});
    }
}

pub fn runUpdate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parse(args, .update);
    const read = try readContent(init, p);
    defer if (read.owned) init.gpa.free(read.text.?);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const t = try bb.updateTask(arena.allocator(), p.repository.?, p.pr_id.?, p.task_id.?, read.text, p.state);
    if (json) {
        try out.printJson(init, t);
    } else {
        try out.printLine(init, "#{d} [{s}] {s}", .{ t.id, @tagName(t.state), t.content });
    }
}

pub fn runDelete(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parse(args, .delete);
    const tid = p.task_id.?;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try bb.deleteTask(arena.allocator(), p.repository.?, p.pr_id.?, tid);
    if (json) {
        try out.printJson(init, .{ .id = tid, .deleted = true });
    } else {
        try out.printLine(init, "ok: deleted task #{d}", .{tid});
    }
}

fn runState(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool, state: bbr.bitbucket.TaskState) !void {
    const p = try parse(args, if (state == .resolved) .resolve else .reopen);
    const tid = p.task_id.?;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const t = try bb.setTaskState(arena.allocator(), p.repository.?, p.pr_id.?, tid, state);
    if (json) {
        try out.printJson(init, t);
    } else {
        try out.printLine(init, "ok: task #{d} [{s}]", .{ t.id, @tagName(t.state) });
    }
}

pub fn runResolve(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    try runState(init, bb, args, json, .resolved);
}

pub fn runReopen(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    try runState(init, bb, args, json, .unresolved);
}

fn parseState(value: []const u8) !bbr.bitbucket.TaskState {
    if (std.mem.eql(u8, value, "RESOLVED") or std.mem.eql(u8, value, "resolved")) return .resolved;
    if (std.mem.eql(u8, value, "UNRESOLVED") or std.mem.eql(u8, value, "unresolved")) return .unresolved;
    return error.BadRequest;
}

test "Task state flags map to domain state" {
    try std.testing.expectEqual(bbr.bitbucket.TaskState.resolved, try parseState("RESOLVED"));
    try std.testing.expectEqual(bbr.bitbucket.TaskState.unresolved, try parseState("UNRESOLVED"));
    try std.testing.expectEqual(bbr.bitbucket.TaskState.resolved, try parseState("resolved"));
    try std.testing.expectError(error.BadRequest, parseState("OPEN"));
}

test "review followups Task list accepts interleaved state resource and page flags" {
    const p = try parse(&.{ "--limit", "1", "--state-filter", "RESOLVED", "--page", "3", "--repository=repo", "--query", "id > 0", "--pull-request-id", "7", "--sort=-id", "--pagelen", "2", "--no-follow" }, .list);
    try std.testing.expectEqualStrings("repo", p.repository.?);
    try std.testing.expectEqual(@as(?u64, 7), p.pr_id);
    try std.testing.expectEqual(@as(?bbr.bitbucket.TaskState, .resolved), p.page.task_state);
    try std.testing.expectEqual(@as(?usize, 1), p.page.limit);
    try std.testing.expectEqual(@as(?u32, 3), p.page.page);
    try std.testing.expectEqual(@as(?u32, 2), p.page.pagelen);
    try std.testing.expectEqualStrings("id > 0", p.page.query.?);
    try std.testing.expectEqualStrings("-id", p.page.sort.?);
    try std.testing.expect(!p.page.follow);
}

test "review followups all Task commands accept resource IDs in any order" {
    for ([_]Command{ .get, .delete, .resolve, .reopen }) |command| {
        const p = try parse(&.{ "--task-id=9", "--pull-request-id", "7", "--repository", "repo" }, command);
        try std.testing.expectEqualStrings("repo", p.repository.?);
        try std.testing.expectEqual(@as(?u64, 7), p.pr_id);
        try std.testing.expectEqual(@as(?u64, 9), p.task_id);
    }
    const created = try parse(&.{ "--comment-id", "9", "--content", "fix it", "--repository", "repo", "--pull-request-id", "7" }, .create);
    try std.testing.expectEqual(@as(?u64, 9), created.comment_id);
    try std.testing.expectEqualStrings("fix it", created.content.?);
    const created_file = try parse(&.{ "--comment-id", "9", "--pull-request-id", "7", "--content-file", "task.md", "--repository", "repo" }, .create);
    try std.testing.expectEqualStrings("task.md", created_file.content_file.?);
    const updated = try parse(&.{ "--state", "RESOLVED", "--task-id", "9", "--content", "done", "--pull-request-id", "7", "--repository", "repo" }, .update);
    try std.testing.expectEqual(@as(?bbr.bitbucket.TaskState, .resolved), updated.state);
    try std.testing.expectEqualStrings("done", updated.content.?);
    const updated_file = try parse(&.{ "--state", "UNRESOLVED", "--repository", "repo", "--content-file", "task.md", "--task-id", "9", "--pull-request-id", "7" }, .update);
    try std.testing.expectEqualStrings("task.md", updated_file.content_file.?);
}

test "review followups Task parser rejects conflicting values and content sources" {
    try std.testing.expectError(error.BadRequest, parse(&.{ "--content", "text", "--repository", "repo", "--pull-request-id", "7", "--content-file", "task.md" }, .create));
    try std.testing.expectError(error.BadRequest, parse(&.{ "--state", "RESOLVED", "--repository", "repo", "--task-id", "9", "--pull-request-id", "7", "--state", "UNRESOLVED" }, .update));
    try std.testing.expectError(error.BadRequest, parse(&.{ "--repository", "repo", "--limit", "1", "--state-filter", "RESOLVED", "--pull-request-id", "7", "--state-filter", "UNRESOLVED" }, .list));
    try std.testing.expectError(error.BadRequest, parse(&.{ "--task-id", "9", "--repository", "repo", "--pull-request-id", "7", "--task-id", "10" }, .get));
    try std.testing.expectError(error.BadRequest, parse(&.{ "--content", "one", "--repository", "repo", "--content", "two", "--pull-request-id", "7" }, .create));
    try std.testing.expectError(error.MissingRequired, parse(&.{ "--repository", "repo", "--task-id", "9", "--pull-request-id", "7" }, .update));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "--state", "RESOLVED", "--repository", "repo", "--task-id", "9", "--pull-request-id", "7" }, .get));
    const repeated = try parse(&.{ "--state-filter", "RESOLVED", "--repository", "repo", "--state-filter", "resolved", "--pull-request-id", "7", "--repository", "repo" }, .list);
    try std.testing.expectEqual(@as(?bbr.bitbucket.TaskState, .resolved), repeated.state);
}

test "list-tasks rejects the update-task state flag" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "--repository", "repo", "--pull-request-id", "7", "--state", "RESOLVED" }, .list));
}
