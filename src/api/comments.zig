//! `bbr api list-comments | get-comment | create-comment | update-comment |
//! delete-comment | resolve-comment | reopen-comment`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const pages = @import("workspaces.zig");

pub const list_help =
    \\usage: bbr api list-comments --repository SLUG --pull-request-id N [--source-commit H] [--destination-commit H] [--no-head]
    \\      [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
    \\
    \\List comments (GET .../comments, follows pages). PR head is fetched
    \\automatically for outdated detection unless --no-head or explicit commits.
    \\--no-follow returns one page. --limit caps the number of comments fetched.
    \\Page size defaults to 100. Flags can appear in any order.
    \\
;

pub const get_help =
    \\usage: bbr api get-comment --repository SLUG --pull-request-id N --comment-id N [--json]
    \\
;

pub const create_help =
    \\usage: bbr api create-comment --repository SLUG --pull-request-id N (--body TEXT | --body-file PATH)
    \\      [--parent-id N | --path P (--to N | --from N) [--start-to N] [--start-from N] | --file-path P [--source-commit H]] [--json]
    \\
    \\Scope is inferred: --parent-id = reply; --path + lines = inline;
    \\--file-path = file; otherwise review-level.
    \\Flags can appear in any order.
    \\
;

pub const update_help =
    \\usage: bbr api update-comment --repository SLUG --pull-request-id N --comment-id N (--body TEXT | --body-file PATH) [--json]
    \\
;

pub const delete_help =
    \\usage: bbr api delete-comment --repository SLUG --pull-request-id N --comment-id N [--json]
    \\
;

pub const resolve_help =
    \\usage: bbr api resolve-comment --repository SLUG --pull-request-id N --comment-id N [--json]
    \\
;

pub const reopen_help =
    \\usage: bbr api reopen-comment --repository SLUG --pull-request-id N --comment-id N [--json]
    \\
;

const Ids = struct {
    repository: []const u8,
    pr_id: u64,
};

const IdFlags = struct {
    repository: ?[]const u8 = null,
    pr_id: ?u64 = null,
    comment_id: ?u64 = null,

    fn take(self: *IdFlags, cur: *arg.Cursor, f: arg.Flag, want_comment: bool) !bool {
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            self.repository = try arg.takeValue(cur, f);
        } else if (std.mem.eql(u8, f.name, "pull-request-id")) {
            _ = cur.next();
            self.pr_id = try arg.parseU64(try arg.takeValue(cur, f));
        } else if (want_comment and std.mem.eql(u8, f.name, "comment-id")) {
            _ = cur.next();
            self.comment_id = try arg.parseU64(try arg.takeValue(cur, f));
        } else return false;
        return true;
    }

    fn ids(self: IdFlags) !Ids {
        return .{
            .repository = self.repository orelse return error.MissingRequired,
            .pr_id = self.pr_id orelse return error.MissingRequired,
        };
    }
};

const CommentArgs = struct {
    ids: Ids,
    comment_id: ?u64 = null,
    body: ?[]const u8 = null,
    body_file: ?[]const u8 = null,
    parent_id: ?u64 = null,
    path: ?[]const u8 = null,
    to: ?u32 = null,
    from: ?u32 = null,
    start_to: ?u32 = null,
    start_from: ?u32 = null,
    file_path: ?[]const u8 = null,
    source_commit: ?[]const u8 = null,
};

fn parseComment(args: []const []const u8, kind: enum { create, update, existing }) !CommentArgs {
    var cur: arg.Cursor = .{ .args = args };
    var flags: IdFlags = .{};
    var parsed: CommentArgs = .{ .ids = undefined };
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (try flags.take(&cur, f, kind != .create)) continue;
        _ = cur.next();
        if (kind != .existing and std.mem.eql(u8, f.name, "body")) {
            parsed.body = try arg.takeValue(&cur, f);
        } else if (kind != .existing and std.mem.eql(u8, f.name, "body-file")) {
            parsed.body_file = try arg.takeValue(&cur, f);
        } else if (kind == .create and std.mem.eql(u8, f.name, "parent-id")) {
            parsed.parent_id = try arg.parseU64(try arg.takeValue(&cur, f));
        } else if (kind == .create and std.mem.eql(u8, f.name, "path")) {
            parsed.path = try arg.takeValue(&cur, f);
        } else if (kind == .create and std.mem.eql(u8, f.name, "to")) {
            parsed.to = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (kind == .create and std.mem.eql(u8, f.name, "from")) {
            parsed.from = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (kind == .create and std.mem.eql(u8, f.name, "start-to")) {
            parsed.start_to = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (kind == .create and std.mem.eql(u8, f.name, "start-from")) {
            parsed.start_from = try arg.parseU32(try arg.takeValue(&cur, f));
        } else if (kind == .create and std.mem.eql(u8, f.name, "file-path")) {
            parsed.file_path = try arg.takeValue(&cur, f);
        } else if (kind == .create and std.mem.eql(u8, f.name, "source-commit")) {
            parsed.source_commit = try arg.takeValue(&cur, f);
        } else return error.UnknownFlag;
    }
    parsed.ids = try flags.ids();
    parsed.comment_id = flags.comment_id;
    if (kind != .create and parsed.comment_id == null) return error.MissingRequired;
    if (kind != .existing) {
        if (parsed.body != null and parsed.body_file != null) return error.BadRequest;
        if (parsed.body == null and parsed.body_file == null) return error.MissingRequired;
    }
    return parsed;
}

const ListArgs = struct {
    ids: Ids,
    source: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    no_head: bool = false,
    opts: bbr.bitbucket.PageOptions = .{ .pagelen = 100 },
};

fn parseList(args: []const []const u8) !ListArgs {
    var cur: arg.Cursor = .{ .args = args };
    var flags: IdFlags = .{};
    var parsed: ListArgs = .{ .ids = undefined };
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (try flags.take(&cur, f, false)) continue;
        if (try pages.takePageFlag(&cur, f, &parsed.opts)) continue;
        _ = cur.next();
        if (std.mem.eql(u8, f.name, "source-commit")) {
            parsed.source = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "destination-commit")) {
            parsed.destination = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "no-head")) {
            if (f.value != null) return error.UnknownFlag;
            parsed.no_head = true;
        } else return error.UnknownFlag;
    }
    parsed.ids = try flags.ids();
    return parsed;
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseList(args);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var head: bbr.bitbucket.types.HeadCommits = .{};
    if (!p.no_head) {
        if (p.source != null and p.destination != null) {
            head = .{ .source = p.source.?, .destination = p.destination.? };
        } else {
            const pr = try bb.getPullRequest(a, p.ids.repository, p.ids.pr_id);
            head = .{
                .source = p.source orelse pr.source_commit,
                .destination = p.destination orelse pr.destination_commit,
            };
        }
    }
    const items = try bb.getCommentsPage(a, p.ids.repository, p.ids.pr_id, head, p.opts);
    if (json) {
        try out.printJson(init, items);
    } else {
        for (items) |c| {
            const where: []const u8 = if (c.anchor) |anc| anc.path else "(review)";
            const state: []const u8 = @tagName(c.state);
            try out.printLine(init, "#{d} {s} [{s} {s}] {s}", .{
                c.id,                                c.author, where, state,
                if (c.resolved) " resolved" else "",
            });
        }
        try out.printLine(init, "ok: {d} comment(s)", .{items.len});
    }
}

pub fn runGet(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseComment(args, .existing);
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const single = try bb.getComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid);
    if (json) {
        try out.printJson(init, single);
    } else {
        try out.printLine(init, "#{d} {s}", .{ single.id, single.author });
        if (single.author_uuid) |uuid| try out.printLine(init, "author uuid: {s}", .{uuid});
        if (single.parent_id) |id| {
            try out.printLine(init, "parent: #{d}", .{id});
            try out.printLine(init, "scope: inherited", .{});
        } else switch (single.effectiveScope()) {
            .review => try out.printLine(init, "scope: review", .{}),
            .file => |file| {
                try out.printLine(init, "scope: file", .{});
                try out.printLine(init, "path: {s}", .{file.path});
                try out.printLine(init, "source commit: {s}", .{file.source_commit});
            },
            .@"inline" => |anchor| {
                try out.printLine(init, "scope: inline", .{});
                try out.printLine(init, "path: {s}", .{anchor.path});
                if (anchor.from) |line| try out.printLine(init, "from: {d}", .{line});
                if (anchor.to) |line| try out.printLine(init, "to: {d}", .{line});
                if (anchor.start_from) |line| try out.printLine(init, "start from: {d}", .{line});
                if (anchor.start_to) |line| try out.printLine(init, "start to: {d}", .{line});
                if (anchor.commit) |commit| try out.printLine(init, "commit: {s}", .{commit});
            },
        }
        try out.printLine(init, "state: {s}", .{@tagName(single.state)});
        try out.printLine(init, "resolved: {}", .{single.resolved});
        try out.printLine(init, "deleted: {}", .{single.deleted});
        try out.printLine(init, "body:\n{s}", .{single.body});
    }
}

fn readBody(init: std.process.Init, p: CommentArgs) !struct { body: []const u8, owned: bool } {
    if (p.body) |body| return .{ .body = body, .owned = false };
    if (p.body_file) |path| return .{ .body = try out.readFile(init.io, init.gpa, path), .owned = true };
    return error.MissingRequired;
}

pub fn runCreate(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseComment(args, .create);
    const read = try readBody(init, p);
    defer if (read.owned) init.gpa.free(read.body);

    var nc: bbr.bitbucket.NewComment = .{ .body = read.body };
    if (p.parent_id) |pid| {
        nc.parent = pid;
    } else if (p.path) |pa| {
        if (p.to == null and p.from == null) return error.MissingRequired;
        if (p.to != null and p.from != null) return error.BadRequest;
        nc.scope = .{ .@"inline" = .{
            .path = pa,
            .to = p.to,
            .from = p.from,
            .start_to = p.start_to,
            .start_from = p.start_from,
        } };
    } else if (p.file_path) |fp| {
        nc.scope = .{ .file = .{ .path = fp, .source_commit = p.source_commit orelse "" } };
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
    const p = try parseComment(args, .update);
    const read = try readBody(init, p);
    defer if (read.owned) init.gpa.free(read.body);
    const body = read.body;
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try requireCommentOwner(arena.allocator(), bb, p.ids, cid);
    try bb.updateComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid, body);
    if (json) {
        try out.printJson(init, .{ .id = cid, .updated = true });
    } else {
        try out.printLine(init, "ok: updated comment #{d}", .{cid});
    }
}

pub fn runDelete(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseComment(args, .existing);
    const cid = p.comment_id orelse return error.MissingRequired;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    try requireCommentOwner(arena.allocator(), bb, p.ids, cid);
    try bb.deleteComment(arena.allocator(), p.ids.repository, p.ids.pr_id, cid);
    if (json) {
        try out.printJson(init, .{ .id = cid, .deleted = true });
    } else {
        try out.printLine(init, "ok: deleted comment #{d}", .{cid});
    }
}

fn requireCommentOwner(allocator: std.mem.Allocator, bb: bbr.bitbucket.Client, ids: Ids, cid: u64) !void {
    const account_uuid = try bb.getAuthenticatedAccountUuid(allocator);
    if (account_uuid.len == 0) return error.CommentOwnershipUnavailable;
    const comment = try bb.getComment(allocator, ids.repository, ids.pr_id, cid);
    if (comment.deleted) return error.DeletedComment;
    const author_uuid = comment.author_uuid orelse return error.CommentOwnershipUnavailable;
    if (author_uuid.len == 0) return error.CommentOwnershipUnavailable;
    if (!std.mem.eql(u8, account_uuid, author_uuid)) return error.CommentOwnedByOther;
}

pub fn runResolve(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const p = try parseComment(args, .existing);
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
    const p = try parseComment(args, .existing);
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

const TestOutput = struct {
    buffer: [8192]u8 = undefined,
    len: usize = 0,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.fileWritePositional = writePositional;
        table.operate = operate;
        break :blk table;
    };

    fn init(self: *TestOutput) std.process.Init {
        return .{
            .minimal = undefined,
            .arena = undefined,
            .gpa = std.testing.allocator,
            .io = .{ .userdata = self, .vtable = &vtable },
            .environ_map = undefined,
            .preopens = undefined,
        };
    }

    fn bytes(self: *const TestOutput) []const u8 {
        return self.buffer[0..self.len];
    }

    fn append(self: *TestOutput, bytes_: []const u8) error{NoSpaceLeft}!void {
        if (bytes_.len > self.buffer.len - self.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.len..][0..bytes_.len], bytes_);
        self.len += bytes_.len;
    }

    fn writePositional(userdata: ?*anyopaque, _: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, _: u64) std.Io.File.WritePositionalError!usize {
        return capture(userdata, header, data, splat);
    }

    fn capture(userdata: ?*anyopaque, header: []const u8, data: []const []const u8, splat: usize) error{NoSpaceLeft}!usize {
        const self: *TestOutput = @ptrCast(@alignCast(userdata.?));
        const start = self.len;
        try self.append(header);
        for (data, 0..) |part, index| {
            const repetitions = if (index + 1 == data.len) splat else 1;
            for (0..repetitions) |_| try self.append(part);
        }
        return self.len - start;
    }

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const write = switch (operation) {
            .file_write_streaming => |write| write,
            else => unreachable,
        };
        return .{ .file_write_streaming = capture(userdata, write.header, write.data, write.splat) };
    }
};

fn testClient(fake: *bbr.http.FakeHttpClient) bbr.bitbucket.Client {
    return bbr.bitbucket.Client.init(fake.httpClient(), .{
        .username = "test@example.test",
        .token = "test-token",
        .workspace = "test-workspace",
    });
}

const test_ids = [_][]const u8{ "--repository", "repo", "--pull-request-id", "7", "--comment-id", "9" };
const test_account = "{\"uuid\":\"{account}\"}";
const test_owned_comment =
    \\{"id":9,"content":{"raw":"original"},"user":{"display_name":"Ada","uuid":"{account}"}}
;

test "human comment details distinguish scopes replies and deleted comments" {
    const cases = [_]struct { body: []const u8, expected: []const u8 }{
        .{
            .body = test_owned_comment,
            .expected = "#9 Ada\nauthor uuid: {account}\nscope: review\nstate: current\nresolved: false\ndeleted: false\nbody:\noriginal\n",
        },
        .{
            .body =
            \\{"id":9,"content":{"raw":"first\nsecond"},"user":{"display_name":"Ada"},"inline":{"path":"f.zig","to":4,"start_to":2,"outdated":true},"resolution":{}}
            ,
            .expected = "#9 Ada\nscope: inline\npath: f.zig\nto: 4\nstart to: 2\nstate: outdated\nresolved: true\ndeleted: false\nbody:\nfirst\nsecond\n",
        },
        .{
            .body =
            \\{"id":9,"content":{"raw":"original"},"user":{"display_name":"Ada"},"inline":{"path":"f.zig","from":8,"start_from":6}}
            ,
            .expected = "#9 Ada\nscope: inline\npath: f.zig\nfrom: 8\nstart from: 6\nstate: current\nresolved: false\ndeleted: false\nbody:\noriginal\n",
        },
        .{
            .body =
            \\{"id":9,"content":{"raw":"original"},"user":{"display_name":"Ada"},"inline":{"path":"f.zig"}}
            ,
            .expected = "#9 Ada\nscope: file\npath: f.zig\nsource commit: \nstate: current\nresolved: false\ndeleted: false\nbody:\noriginal\n",
        },
        .{
            .body =
            \\{"id":9,"parent":{"id":7},"content":{"raw":"reply"},"user":{"display_name":"Ada"}}
            ,
            .expected = "#9 Ada\nparent: #7\nscope: inherited\nstate: current\nresolved: false\ndeleted: false\nbody:\nreply\n",
        },
        .{
            .body =
            \\{"id":9,"deleted":true,"content":{"raw":"hidden"},"user":{"display_name":"Ada"},"inline":{"path":"f.zig","to":4}}
            ,
            .expected = "#9 Ada\nscope: inline\npath: f.zig\nto: 4\nstate: current\nresolved: false\ndeleted: true\nbody:\n\n",
        },
    };
    for (cases) |case| {
        var fake: bbr.http.FakeHttpClient = .{ .body = case.body };
        var output: TestOutput = .{};
        try runGet(output.init(), testClient(&fake), &test_ids, false);
        try std.testing.expectEqualStrings(case.expected, output.bytes());
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    }
}

test "api comments list parses interleaved identifiers head and all page options" {
    const p = try parseList(&.{
        "--pagelen=12",       "--source-commit", "abc", "--repository=repo",        "--query",           "content.raw ~ \"text\"",
        "--no-follow",        "--page",          "3",   "--destination-commit=def", "--pull-request-id", "7",
        "--sort=-created_on", "--limit",         "20",  "--no-head",
    });
    try std.testing.expectEqualStrings("repo", p.ids.repository);
    try std.testing.expectEqual(@as(u64, 7), p.ids.pr_id);
    try std.testing.expectEqualStrings("abc", p.source.?);
    try std.testing.expectEqualStrings("def", p.destination.?);
    try std.testing.expect(p.no_head);
    try std.testing.expectEqual(@as(?u32, 12), p.opts.pagelen);
    try std.testing.expectEqual(@as(?u32, 3), p.opts.page);
    try std.testing.expectEqualStrings("content.raw ~ \"text\"", p.opts.query.?);
    try std.testing.expectEqualStrings("-created_on", p.opts.sort.?);
    try std.testing.expect(!p.opts.follow);
    try std.testing.expectEqual(@as(?usize, 20), p.opts.limit);

    const defaults = try parseList(&.{ "--pull-request-id=7", "--repository", "repo" });
    try std.testing.expectEqual(@as(?u32, 100), defaults.opts.pagelen);
    try std.testing.expect(defaults.opts.follow);
    try std.testing.expect(defaults.opts.limit == null);
    try std.testing.expect(!defaults.no_head);
}

test "api comments list rejects missing invalid and unknown options" {
    try std.testing.expectError(error.MissingRequired, parseList(&.{ "--page=2", "--repository=repo" }));
    try std.testing.expectError(error.MissingValue, parseList(&.{ "--repository=repo", "--pull-request-id=7", "--sort" }));
    try std.testing.expectError(error.InvalidNumber, parseList(&.{ "--limit=-1", "--repository=repo", "--pull-request-id=7" }));
    try std.testing.expectError(error.InvalidNumber, parseList(&.{ "--page=text", "--repository=repo", "--pull-request-id=7" }));
    try std.testing.expectError(error.UnknownFlag, parseList(&.{ "--no-follow=false", "--repository=repo", "--pull-request-id=7" }));
    try std.testing.expectError(error.UnknownFlag, parseList(&.{ "--repository=repo", "--pull-request-id=7", "--unknown" }));
}

test "api comments get uses only the single endpoint and preserves authoritative outdated state" {
    var fake: bbr.http.FakeHttpClient = .{ .body =
        \\{"id":9,"content":{"raw":"original"},"user":{"display_name":"Ada"},"inline":{"path":"f.zig","to":4,"outdated":true}}
    };
    var output: TestOutput = .{};
    try runGet(output.init(), testClient(&fake), &.{ "--comment-id=9", "--repository", "repo", "--pull-request-id=7" }, true);
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    try std.testing.expectEqual(bbr.http.client.Method.GET, fake.methodAt(0).?);
    try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7/comments/9", fake.lastUrl().?);
    const parsed = try std.json.parseFromSlice(struct { state: bbr.review.ScopeState, body: []const u8 }, std.testing.allocator, output.bytes(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(bbr.review.ScopeState.outdated, parsed.value.state);
    try std.testing.expectEqualStrings("original", parsed.value.body);
}

test "api comments update and delete fail closed without ownership evidence" {
    const cases = [_]struct {
        account: bbr.http.Canned = .{ .body = test_account },
        comment: bbr.http.Canned = .{ .body = test_owned_comment },
        expected: anyerror,
        calls: usize = 2,
    }{
        .{ .comment = .{ .body = "{\"id\":9,\"user\":{\"display_name\":\"Ada\",\"uuid\":\"{foreign}\"}}" }, .expected = error.CommentOwnedByOther },
        .{ .comment = .{ .body = "{\"id\":9,\"user\":{\"uuid\":\"\"}}" }, .expected = error.CommentOwnershipUnavailable },
        .{ .comment = .{ .body = "{\"id\":9,\"user\":{\"display_name\":\"Ada\"}}" }, .expected = error.CommentOwnershipUnavailable },
        .{ .comment = .{ .body = "{\"id\":9}" }, .expected = error.CommentOwnershipUnavailable },
        .{ .account = .{ .body = "{\"uuid\":\"\"}" }, .expected = error.CommentOwnershipUnavailable, .calls = 1 },
        .{ .account = .{ .body = "{}" }, .expected = error.MalformedResponse, .calls = 1 },
        .{ .account = .{ .status = 401 }, .expected = error.Unauthorized, .calls = 1 },
        .{ .account = .{ .send_error = error.ConnectionResetByPeer }, .expected = error.ConnectionResetByPeer, .calls = 1 },
        .{ .comment = .{ .status = 404 }, .expected = error.NotFound },
        .{ .comment = .{ .body = "not JSON" }, .expected = error.MalformedResponse },
        .{ .comment = .{ .send_error = error.ConnectionResetByPeer }, .expected = error.ConnectionResetByPeer },
        .{ .comment = .{ .body = "{\"id\":9,\"deleted\":true,\"user\":{\"uuid\":\"{account}\"}}" }, .expected = error.DeletedComment },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |update| {
            const responses = [_]bbr.http.Canned{ case.account, case.comment, .{ .status = 204 } };
            var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
            var output: TestOutput = .{};
            const bb = testClient(&fake);
            if (update) {
                const args = test_ids ++ [_][]const u8{ "--body", "new body" };
                try std.testing.expectError(case.expected, runUpdate(output.init(), bb, &args, true));
            } else {
                try std.testing.expectError(case.expected, runDelete(output.init(), bb, &test_ids, true));
            }
            try std.testing.expectEqual(case.calls, fake.call_count);
            for (0..fake.call_count) |index| try std.testing.expectEqual(bbr.http.client.Method.GET, fake.methodAt(index).?);
            try std.testing.expectEqual(@as(usize, 0), output.len);
        }
    }
}

test "api comments owned update sends exact body once and owned delete mutates once" {
    const body = "  exact \"body\"\n```suggestion\nnew code\n```\n";
    for ([_]bool{ false, true }) |update| {
        const responses = [_]bbr.http.Canned{ .{ .body = test_account }, .{ .body = test_owned_comment }, .{ .status = 204 } };
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        var output: TestOutput = .{};
        if (update) {
            const args = [_][]const u8{ "--comment-id=9", "--body", body, "--pull-request-id=7", "--repository=repo" };
            try runUpdate(output.init(), testClient(&fake), &args, true);
            const parsed = try std.json.parseFromSlice(struct { content: struct { raw: []const u8 } }, std.testing.allocator, fake.lastBody().?, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings(body, parsed.value.content.raw);
        } else {
            try runDelete(output.init(), testClient(&fake), &.{ "--comment-id", "9", "--pull-request-id=7", "--repository", "repo" }, true);
            try std.testing.expectEqualStrings("", fake.lastBody().?);
        }
        try std.testing.expectEqual(@as(usize, 3), fake.call_count);
        try std.testing.expectEqual(bbr.http.client.Method.GET, fake.methodAt(0).?);
        try std.testing.expectEqual(bbr.http.client.Method.GET, fake.methodAt(1).?);
        try std.testing.expectEqual(if (update) bbr.http.client.Method.PUT else bbr.http.client.Method.DELETE, fake.methodAt(2).?);
        try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/user", fake.urlAt(0).?);
        try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7/comments/9", fake.urlAt(1).?);
        try std.testing.expectEqualStrings(fake.urlAt(1).?, fake.urlAt(2).?);
    }
}

test "api comments list head selection preserves automatic explicit and no-head behavior" {
    const page =
        \\{"values":[{"id":9,"content":{"raw":"original"},"inline":{"path":"f.zig","to":4},"links":{"code":{"href":"https://bitbucket.org/test-workspace/repo/diff/test-workspace/repo:abc..def?path=f.zig"}}}]}
    ;
    const pull_request =
        \\{"id":7,"title":"Title","state":"OPEN","author":{"display_name":"Ada","uuid":"{account}"},"source":{"branch":{"name":"source"},"commit":{"hash":"other"}},"destination":{"branch":{"name":"destination"},"commit":{"hash":"def"}},"participants":[]}
    ;
    const destination_pull_request =
        \\{"id":7,"title":"Title","state":"OPEN","author":{"display_name":"Ada","uuid":"{account}"},"source":{"branch":{"name":"source"},"commit":{"hash":"abc"}},"destination":{"branch":{"name":"destination"},"commit":{"hash":"other"}},"participants":[]}
    ;
    const cases = [_]struct {
        args: []const []const u8,
        state: bbr.review.ScopeState,
        calls: usize,
        pr_body: []const u8 = pull_request,
    }{
        .{ .args = &.{ "--repository=repo", "--pull-request-id=7" }, .state = .outdated, .calls = 2 },
        .{ .args = &.{ "--source-commit=abc", "--repository=repo", "--destination-commit=def", "--pull-request-id=7" }, .state = .current, .calls = 1 },
        .{ .args = &.{ "--no-head", "--repository=repo", "--pull-request-id=7" }, .state = .current, .calls = 1 },
        .{ .args = &.{ "--source-commit=abc", "--repository=repo", "--pull-request-id=7" }, .state = .current, .calls = 2 },
        .{ .args = &.{ "--source-commit=wrong", "--repository=repo", "--pull-request-id=7" }, .state = .outdated, .calls = 2 },
        .{ .args = &.{ "--destination-commit=def", "--repository=repo", "--pull-request-id=7" }, .state = .current, .calls = 2, .pr_body = destination_pull_request },
        .{ .args = &.{ "--destination-commit=wrong", "--repository=repo", "--pull-request-id=7" }, .state = .outdated, .calls = 2, .pr_body = destination_pull_request },
        .{ .args = &.{ "--source-commit=wrong", "--no-head", "--destination-commit=wrong", "--repository=repo", "--pull-request-id=7" }, .state = .current, .calls = 1 },
    };
    for (cases) |case| {
        const responses = [_]bbr.http.Canned{ .{ .body = case.pr_body }, .{ .body = page } };
        var fake: bbr.http.FakeHttpClient = .{ .responses = if (case.calls == 2) &responses else responses[1..] };
        var output: TestOutput = .{};
        try runList(output.init(), testClient(&fake), case.args, true);
        try std.testing.expectEqual(case.calls, fake.call_count);
        try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7/comments?pagelen=100", fake.lastUrl().?);
        const parsed = try std.json.parseFromSlice([]struct { state: bbr.review.ScopeState }, std.testing.allocator, output.bytes(), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
        try std.testing.expectEqual(case.state, parsed.value[0].state);
        if (case.calls == 2) try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7", fake.urlAt(0).?);
    }
}

test "api comments list passes page controls and stops before fetching beyond limit" {
    const page =
        \\{"values":[{"id":9},{"id":10}],"next":"https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7/comments?page=4"}
    ;
    const responses = [_]bbr.http.Canned{ .{ .body = page }, .{ .send_error = error.UnexpectedPageFetch } };
    for ([_][]const []const u8{
        &.{ "--page=3", "--repository=repo", "--pagelen=2", "--query=id>8", "--pull-request-id=7", "--sort=-created_on", "--limit=1", "--no-head" },
        &.{ "--no-follow", "--page=3", "--repository=repo", "--pagelen=2", "--query=id>8", "--pull-request-id=7", "--sort=-created_on", "--no-head" },
    }, 0..) |args, index| {
        var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
        var output: TestOutput = .{};
        try runList(output.init(), testClient(&fake), args, true);
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
        try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7/comments?pagelen=2&page=3&q=id%3E8&sort=-created_on", fake.lastUrl().?);
        const parsed = try std.json.parseFromSlice([]struct { id: u64 }, std.testing.allocator, output.bytes(), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(if (index == 0) @as(usize, 1) else @as(usize, 2), parsed.value.len);
        try std.testing.expectEqual(@as(u64, 9), parsed.value[0].id);
    }
}

test "api comments create accepts scope before body and keeps literal global flag values" {
    for ([_][]const u8{ "x", "--json", "--help" }) |body| {
        var fake: bbr.http.FakeHttpClient = .{ .status = 201, .body = "{\"id\":9}" };
        var output: TestOutput = .{};
        try runCreate(output.init(), testClient(&fake), &.{
            "--path", "f", "--to", "1", "--body", body, "--pull-request-id=7", "--repository=repo",
        }, true);
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
        try std.testing.expectEqual(bbr.http.client.Method.POST, fake.last_method.?);
        try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7/comments", fake.lastUrl().?);
        const parsed = try std.json.parseFromSlice(struct {
            content: struct { raw: []const u8 },
            @"inline": struct { path: []const u8, to: u32 },
        }, std.testing.allocator, fake.lastBody().?, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(body, parsed.value.content.raw);
        try std.testing.expectEqualStrings("f", parsed.value.@"inline".path);
        try std.testing.expectEqual(@as(u32, 1), parsed.value.@"inline".to);
    }
}

test "api comments parser accepts interleaved body files and scope flags but rejects unsupported flags" {
    const update = try parseComment(&.{ "--body-file", "--help", "--comment-id=9", "--repository=repo", "--pull-request-id=7" }, .update);
    try std.testing.expectEqualStrings("--help", update.body_file.?);
    const file = try parseComment(&.{ "--source-commit=abc", "--body", "--json", "--file-path=f", "--repository=repo", "--pull-request-id=7" }, .create);
    try std.testing.expectEqualStrings("--json", file.body.?);
    try std.testing.expectEqualStrings("f", file.file_path.?);
    try std.testing.expectEqualStrings("abc", file.source_commit.?);
    const reply = try parseComment(&.{ "--parent-id=9", "--repository=repo", "--body=x", "--pull-request-id=7" }, .create);
    try std.testing.expectEqual(@as(?u64, 9), reply.parent_id);
    const range = try parseComment(&.{ "--start-from=1", "--path=f", "--repository=repo", "--from=3", "--body=x", "--pull-request-id=7" }, .create);
    try std.testing.expectEqual(@as(?u32, 1), range.start_from);
    try std.testing.expectEqual(@as(?u32, 3), range.from);
    try std.testing.expectError(error.BadRequest, parseComment(&.{ "--body=x", "--comment-id=9", "--body-file=f", "--repository=repo", "--pull-request-id=7" }, .update));
    try std.testing.expectError(error.UnknownFlag, parseComment(&.{ "--path=f", "--body=x", "--comment-id=9", "--repository=repo", "--pull-request-id=7" }, .update));
    try std.testing.expectError(error.UnknownFlag, parseComment(&.{ "--body=x", "--comment-id=9", "--repository=repo", "--pull-request-id=7" }, .existing));
}

test "api comments resolve and reopen accept identifiers in any order" {
    for ([_]bool{ false, true }) |reopen| {
        var fake: bbr.http.FakeHttpClient = .{ .status = 204 };
        var output: TestOutput = .{};
        const args = [_][]const u8{ "--comment-id=9", "--pull-request-id", "7", "--repository=repo" };
        if (reopen) {
            try runReopen(output.init(), testClient(&fake), &args, true);
        } else {
            try runResolve(output.init(), testClient(&fake), &args, true);
        }
        try std.testing.expectEqual(@as(usize, 1), fake.call_count);
        try std.testing.expectEqual(if (reopen) bbr.http.client.Method.DELETE else bbr.http.client.Method.POST, fake.last_method.?);
        try std.testing.expectEqualStrings("https://api.bitbucket.org/2.0/repositories/test-workspace/repo/pullrequests/7/comments/9/resolve", fake.lastUrl().?);
    }
}
