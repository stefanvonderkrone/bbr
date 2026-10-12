//! `bbr api list-workspaces | get-workspace`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const member_search = @import("member_search.zig");

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

pub const members_help =
    \\usage: bbr api list-workspace-members [--pagelen N] [--page N] [--no-follow] [--limit N] [--json]
    \\
    \\List members in the selected Workspace, with UUIDs, display names, and nicknames.
    \\Follow pages by default. --no-follow returns one page. --limit caps fetched members.
    \\Requires the read:workspace:bitbucket API token scope.
    \\
;

pub const search_members_help =
    \\usage: bbr api search-workspace-members --name TEXT [--pagelen N] [--concurrency N] [--limit N] [--json]
    \\
    \\Search all members in the selected Workspace by display name or nickname.
    \\Rank exact, German spelling, partial, and typo matches in that order.
    \\Name parts can appear in any order. Middle names can be omitted.
    \\Small typos and common German spelling changes can be combined.
    \\Search always follows all pages. --limit caps results after ranking, not requests.
    \\Page size defaults to 100, the maximum. --pagelen overrides it.
    \\Concurrency defaults to 8. --concurrency accepts a positive integer, capped by logical CPUs.
    \\Fetch the next page as a request finishes. Unknown page counts can cause extra empty-page requests.
    \\A failed page fails the complete search. HTTP 429 is not retried.
    \\Counts include all matches before the result limit. No matches is a successful empty result.
    \\A name must be nonblank, with at most 256 Unicode code points and no control characters.
    \\Requires the read:workspace:bitbucket API token scope.
    \\
;

const SearchOptions = struct { name: []const u8, page: bbr.bitbucket.PageOptions, concurrency: usize };

fn searchOptions(args: []const []const u8) !SearchOptions {
    var cur: arg.Cursor = .{ .args = args };
    var name: ?[]const u8 = null;
    var concurrency: ?usize = null;
    var page: bbr.bitbucket.PageOptions = .{};
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "name")) {
            _ = cur.next();
            try arg.setOption([]const u8, &name, try arg.takeValue(&cur, f));
        } else if (std.mem.eql(u8, f.name, "concurrency")) {
            _ = cur.next();
            const value = try arg.parseUsize(try arg.takeValue(&cur, f));
            if (value == 0) return error.InvalidNumber;
            try arg.setOption(usize, &concurrency, value);
        } else if (std.mem.eql(u8, f.name, "pagelen") or std.mem.eql(u8, f.name, "limit")) {
            _ = try takePageFlag(&cur, f, &page);
        } else return error.UnknownFlag;
    }
    const query = name orelse return error.MissingRequired;
    try member_search.validateName(query);
    return .{ .name = query, .page = page, .concurrency = concurrency orelse 8 };
}

fn effectiveConcurrency(requested: usize, cpu_count: std.Thread.CpuCountError!usize) usize {
    return @min(requested, cpu_count catch 1);
}

test "member search concurrency accepts positive values and caps them by logical CPUs" {
    try std.testing.expectEqual(@as(usize, 8), (try searchOptions(&.{"--name=Ada"})).concurrency);
    try std.testing.expectEqual(@as(usize, 100), (try searchOptions(&.{ "--name=Ada", "--concurrency", "100" })).concurrency);
    try std.testing.expectEqual(@as(usize, 1), (try searchOptions(&.{ "--concurrency=1", "--name=Ada" })).concurrency);
    try std.testing.expectEqual(@as(usize, 18), effectiveConcurrency(100, 18));
    try std.testing.expectEqual(@as(usize, 2), effectiveConcurrency(8, 2));
    try std.testing.expectEqual(@as(usize, 1), effectiveConcurrency(8, error.Unsupported));
    try std.testing.expectEqual(@as(usize, 1), effectiveConcurrency(1, 18));
    for ([_][]const u8{ "0", "-1", "1.5", "text", "184467440737095516160" }) |value|
        try std.testing.expectError(error.InvalidNumber, searchOptions(&.{ "--name=Ada", "--concurrency", value }));
    try std.testing.expectError(error.MissingValue, searchOptions(&.{ "--name=Ada", "--concurrency" }));
    try std.testing.expectError(error.BadRequest, searchOptions(&.{ "--name=Ada", "--concurrency=1", "--concurrency=2" }));
}

pub fn runSearchMembers(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const opts = try searchOptions(args);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const members = try bb.listWorkspaceMembersConcurrent(init.io, a, opts.page.pagelen orelse 100, effectiveConcurrency(opts.concurrency, std.Thread.getCpuCount()));
    const result = try member_search.search(a, members, opts.name, opts.page.limit);
    if (json) return out.printJson(init, result);
    for (result.matches) |match| {
        try out.printLine(init, "{s} {s} nickname: {s} match: {s} field: {s} edits: {d}", .{
            match.member.uuid,          match.member.display_name,     match.member.nickname,
            @tagName(match.match_kind), @tagName(match.matched_field), match.edit_distance,
        });
    }
    try out.printLine(init, "ok: {d} match(es), {d} exact, {d} shown", .{ result.total_matches, result.exact_matches, result.matches.len });
}

test "Workspace Member search parser requires valid names and a complete Workspace search" {
    const parsed = try searchOptions(&.{ "--limit=1", "--name", "Ada Lovelace", "--pagelen=100" });
    try std.testing.expectEqualStrings("Ada Lovelace", parsed.name);
    try std.testing.expectEqual(@as(?usize, 1), parsed.page.limit);
    try std.testing.expectEqual(@as(?u32, 100), parsed.page.pagelen);
    try std.testing.expect(parsed.page.follow);
    try std.testing.expectEqual(@as(?u32, null), parsed.page.page);
    for ([_][]const []const u8{
        &.{ "--name=Ada", "--page=2" },    &.{ "--name=Ada", "--no-follow" },
        &.{ "--name=Ada", "--query=Bob" }, &.{ "--name=Ada", "--sort=name" },
    }) |args| try std.testing.expectError(error.UnknownFlag, searchOptions(args));
    for ([_][]const []const u8{ &.{"--name="}, &.{"--name=   "}, &.{"--name=Ada\n"}, &.{ "--name=Ada", "--name=Bob" } }) |args|
        try std.testing.expectError(error.BadRequest, searchOptions(args));
    try std.testing.expectError(error.MissingRequired, searchOptions(&.{}));
    try std.testing.expectError(error.MissingValue, searchOptions(&.{"--name"}));
    try std.testing.expectError(error.InvalidNumber, searchOptions(&.{ "--name=Ada", "--pagelen=101" }));
    try std.testing.expectEqualStrings("--help", (try searchOptions(&.{ "--name", "--help" })).name);
}

fn memberPageOptions(args: []const []const u8) !bbr.bitbucket.PageOptions {
    var cur: arg.Cursor = .{ .args = args };
    var opts: bbr.bitbucket.PageOptions = .{};
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse return error.UnknownFlag;
        if (std.mem.eql(u8, f.name, "query") or std.mem.eql(u8, f.name, "sort")) return error.UnknownFlag;
        if (!try takePageFlag(&cur, f, &opts)) return error.UnknownFlag;
    }
    return opts;
}

pub fn runListMembers(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    const opts = try memberPageOptions(args);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const members = try bb.listWorkspaceMembers(arena.allocator(), opts);
    if (json) return out.printJson(init, members);
    for (members) |member| try out.printLine(init, "{s} {s} nickname: {s}", .{ member.uuid, member.display_name, member.nickname });
    try out.printLine(init, "ok: {d} Workspace Member(s)", .{members.len});
}

test "Workspace Member list parser accepts only documented pagination options" {
    const opts = try memberPageOptions(&.{ "--limit=2", "--pagelen", "100", "--page=3", "--no-follow" });
    try std.testing.expectEqual(@as(?usize, 2), opts.limit);
    try std.testing.expectEqual(@as(?u32, 3), opts.page);
    try std.testing.expect(!opts.follow);
    for ([_][]const []const u8{ &.{"--query=Bob"}, &.{"--sort=display_name"}, &.{"--repository=sample"}, &.{"--name=Bob"} }) |args|
        try std.testing.expectError(error.UnknownFlag, memberPageOptions(args));
    try std.testing.expectError(error.InvalidNumber, memberPageOptions(&.{"--page=0"}));
    try std.testing.expectError(error.MissingValue, memberPageOptions(&.{"--limit"}));
}

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
