//! `bbr api list-pull-requests | get-pull-request | whoami | get-verdict | set-verdict`.

const std = @import("std");
const bbr = @import("bbr");
const arg = @import("args.zig");
const out = @import("output.zig");
const ws = @import("workspaces.zig");

pub const list_help =
    \\usage: bbr api list-pull-requests --repository SLUG [--state OPEN|MERGED|DECLINED|SUPERSEDED] [--source-branch NAME] [--pagelen N] [--page N] [--query Q] [--sort S] [--no-follow] [--limit N] [--json]
    \\
    \\List pull requests (GET .../pullrequests).
    \\Follow pages by default. --no-follow returns one page. --limit caps the total.
    \\
;

pub const get_help =
    \\usage: bbr api get-pull-request --repository SLUG --pull-request-id N [--json]
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
    \\usage: bbr api set-verdict --repository SLUG --pull-request-id N --verdict approved|changes_requested|none|no_verdict --expected-source-commit HASH [--json]
    \\
    \\Set the reviewer verdict for the authenticated account only.
    \\
;

const ListArgs = struct {
    repository: []const u8,
    filter: bbr.bitbucket.ListOptions,
    page: bbr.bitbucket.PageOptions,
};

fn parseList(args: []const []const u8) !ListArgs {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var filter: bbr.bitbucket.ListOptions = .{};
    var page: bbr.bitbucket.PageOptions = .{};
    while (cur.peek()) |a| {
        const f = arg.splitFlag(a) orelse break;
        if (try ws.takePageFlag(&cur, f, &page)) continue;
        if (std.mem.eql(u8, f.name, "repository")) {
            _ = cur.next();
            repository = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "state")) {
            _ = cur.next();
            filter.state = try arg.takeValue(&cur, f);
        } else if (std.mem.eql(u8, f.name, "source-branch")) {
            _ = cur.next();
            filter.source_branch = try arg.takeValue(&cur, f);
        } else break;
    }
    if (!cur.done()) return error.UnknownFlag;
    return .{
        .repository = repository orelse return error.MissingRequired,
        .filter = filter,
        .page = page,
    };
}

fn listPullRequests(allocator: std.mem.Allocator, bb: bbr.bitbucket.Client, args: []const []const u8) ![]bbr.bitbucket.PullRequestSummary {
    const parsed = try parseList(args);
    return bb.listPullRequestsPage(allocator, parsed.repository, parsed.filter, parsed.page);
}

pub fn runList(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const items = try listPullRequests(arena.allocator(), bb, args);
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
        try out.printLine(init, "author uuid: {s}", .{pr.author_uuid});
        try out.printLine(init, "{s} -> {s}", .{ pr.source_branch, pr.destination_branch });
        try out.printLine(init, "source: {s} destination: {s}", .{ pr.source_commit, pr.destination_commit });
        if (pr.reviewer_verdicts) |verdicts| {
            try out.printLine(init, "reviewer verdicts: {d}", .{verdicts.len});
            for (verdicts) |entry| {
                try out.printLine(init, "  {s}: {s}", .{ entry.account_uuid, @tagName(entry.verdict) });
            }
        }
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

const SetVerdictResult = struct {
    result: bbr.bitbucket.ReviewerVerdictChangeResult,
    verdict: []const u8,
};

fn setVerdict(allocator: std.mem.Allocator, bb: bbr.bitbucket.Client, args: []const []const u8) !SetVerdictResult {
    var cur: arg.Cursor = .{ .args = args };
    var repository: ?[]const u8 = null;
    var pr_id: ?u64 = null;
    var verdict_s: ?[]const u8 = null;
    var expected: ?[]const u8 = null;
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

    const account = try bb.getAuthenticatedAccountUuid(allocator);
    defer allocator.free(account);
    return .{
        .result = try bb.changeReviewerVerdict(allocator, repo, id, exp, account, target),
        .verdict = vs,
    };
}

pub fn runSetVerdict(init: std.process.Init, bb: bbr.bitbucket.Client, args: []const []const u8, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const changed = try setVerdict(arena.allocator(), bb, args);
    const result = changed.result;
    const vs = changed.verdict;
    switch (result) {
        .success, .reconciled_success => {},
        .api_error => |err| return err,
        .stale_source_commit, .unresolved => return error.ReviewerVerdictChangeFailed,
    }
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
}

test "list-pull-requests parses interleaved filters and page controls in both value forms" {
    const cases = [_][]const []const u8{
        &.{ "--page", "3", "--repository", "repository", "--query", "title=\"Review\"", "--state", "MERGED", "--pagelen", "10", "--source-branch", "feature", "--limit", "12", "--sort", "-id", "--no-follow" },
        &.{ "--no-follow", "--repository=repository", "--pagelen=10", "--state=MERGED", "--sort=-id", "--source-branch=feature", "--page=3", "--query=title=\"Review\"", "--limit=12" },
    };
    for (cases) |args| {
        const parsed = try parseList(args);
        try std.testing.expectEqualStrings("repository", parsed.repository);
        try std.testing.expectEqualStrings("MERGED", parsed.filter.state);
        try std.testing.expectEqualStrings("feature", parsed.filter.source_branch.?);
        try std.testing.expectEqual(@as(u32, 10), parsed.page.pagelen.?);
        try std.testing.expectEqual(@as(u32, 3), parsed.page.page.?);
        try std.testing.expectEqualStrings("title=\"Review\"", parsed.page.query.?);
        try std.testing.expectEqualStrings("-id", parsed.page.sort.?);
        try std.testing.expect(!parsed.page.follow);
        try std.testing.expectEqual(@as(usize, 12), parsed.page.limit.?);
    }
    const defaults = try parseList(&.{ "--repository", "repository" });
    try std.testing.expectEqualStrings("OPEN", defaults.filter.state);
    try std.testing.expect(defaults.filter.source_branch == null);
    try std.testing.expectEqual(bbr.bitbucket.PageOptions{}, defaults.page);
}

test "list-pull-requests rejects invalid page controls before HTTP" {
    var fake: bbr.http.FakeHttpClient = .{};
    const bb = testClient(&fake);
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingRequired, listPullRequests(a, bb, &.{"--no-follow"}));
    try std.testing.expectError(error.MissingValue, listPullRequests(a, bb, &.{ "--repository=repository", "--page" }));
    try std.testing.expectError(error.InvalidNumber, listPullRequests(a, bb, &.{ "--repository=repository", "--pagelen=-1" }));
    try std.testing.expectError(error.InvalidNumber, listPullRequests(a, bb, &.{ "--repository=repository", "--limit=bad" }));
    try std.testing.expectError(error.UnknownFlag, listPullRequests(a, bb, &.{ "--repository=repository", "--no-follow=false" }));
    try std.testing.expectError(error.UnknownFlag, listPullRequests(a, bb, &.{ "--repository=repository", "--unknown" }));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
}

const test_pull_request =
    \\{"id":42,"title":"Review","state":"OPEN",
    \\ "author":{"display_name":"Ada","uuid":"{author}"},
    \\ "source":{"branch":{"name":"feature"},"commit":{"hash":"abc123"}},
    \\ "destination":{"branch":{"name":"main"},"commit":{"hash":"def456"}}
;

const test_first_page = "{\"values\":[" ++ test_pull_request ++ "}," ++ test_pull_request ++
    "}],\"next\":\"https://api.bitbucket.org/2.0/repositories/workspace/repository/pullrequests?page=4\"}";
const test_last_page = "{\"values\":[" ++ test_pull_request ++ "}]}";

fn testClient(fake: *bbr.http.FakeHttpClient) bbr.bitbucket.Client {
    return bbr.bitbucket.Client.init(fake.httpClient(), .{
        .username = "test-user",
        .token = "test-token",
        .workspace = "workspace",
    });
}

test "list-pull-requests sends filters and page controls and does not follow with no-follow" {
    const responses = [_]bbr.http.Canned{
        .{ .body = test_first_page },
        .{ .send_error = error.UnexpectedNextPage },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const a = std.testing.allocator;
    const items = try listPullRequests(a, testClient(&fake), &.{
        "--page=3",     "--repository=repository", "--query=title=\"Review\"", "--state=MERGED",
        "--pagelen=10", "--source-branch=feature", "--sort=-id",               "--no-follow",
    });
    defer bbr.bitbucket.deinitSummaries(a, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    const url = fake.lastUrl().?;
    try std.testing.expect(std.mem.startsWith(u8, url, bbr.bitbucket.base_url ++ "/repositories/workspace/repository/pullrequests?"));
    for ([_][]const u8{
        "pagelen=10",                                                              "page=3", "state=MERGED", "sort=-id",
        "q=source.branch.name%3D%22feature%22%20AND%20%28title%3D%22Review%22%29",
    }) |part| try std.testing.expect(std.mem.indexOf(u8, url, part) != null);
}

test "list-pull-requests limit stops HTTP paging and defaults still follow next" {
    const responses = [_]bbr.http.Canned{
        .{ .body = test_first_page },
        .{ .body = test_last_page },
    };
    const a = std.testing.allocator;
    var limited: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const capped = try listPullRequests(a, testClient(&limited), &.{ "--limit=1", "--repository=repository" });
    defer bbr.bitbucket.deinitSummaries(a, capped);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqual(@as(usize, 1), limited.call_count);

    var following: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const all = try listPullRequests(a, testClient(&following), &.{ "--repository=repository", "--page=3" });
    defer bbr.bitbucket.deinitSummaries(a, all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqual(@as(usize, 2), following.call_count);
    try std.testing.expectEqualStrings(
        bbr.bitbucket.base_url ++ "/repositories/workspace/repository/pullrequests?page=4",
        following.urlAt(1).?,
    );
}

test "set-verdict rejects a spoofed uuid before HTTP" {
    var fake: bbr.http.FakeHttpClient = .{};
    const bb = testClient(&fake);
    const cases = [_][]const []const u8{
        &.{ "--uuid", "{spoofed}", "--repository=repository", "--pull-request-id=42", "--verdict=none", "--expected-source-commit=abc123" },
        &.{ "--repository=repository", "--pull-request-id=42", "--verdict=none", "--expected-source-commit=abc123", "--uuid={spoofed}" },
    };
    for (cases) |args| try std.testing.expectError(error.UnknownFlag, setVerdict(std.testing.allocator, bb, args));
    try std.testing.expectEqual(@as(usize, 0), fake.call_count);
    try std.testing.expect(std.mem.indexOf(u8, set_verdict_help, "--uuid") == null);
    try std.testing.expect(std.mem.indexOf(u8, get_verdict_help, "--uuid UUID") != null);
}

test "set-verdict proves the authenticated account before removing its verdict" {
    const before = test_pull_request ++
        ",\"participants\":[{\"user\":{\"uuid\":\"{authenticated}\"},\"state\":\"changes_requested\"}," ++
        "{\"user\":{\"uuid\":\"{spoofed}\"},\"approved\":true}]}";
    const after = test_pull_request ++
        ",\"participants\":[{\"user\":{\"uuid\":\"{spoofed}\"},\"approved\":true}]}";
    const responses = [_]bbr.http.Canned{
        .{ .body = "{\"uuid\":\"{authenticated}\"}" },
        .{ .body = before },
        .{ .status = 204 },
        .{ .body = after },
    };
    var fake: bbr.http.FakeHttpClient = .{ .responses = &responses };
    const changed = try setVerdict(std.testing.allocator, testClient(&fake), &.{
        "--repository=repository", "--pull-request-id=42", "--verdict=none", "--expected-source-commit=abc123",
    });
    try std.testing.expectEqual(bbr.bitbucket.ReviewerVerdictChangeResult.success, changed.result);
    try std.testing.expectEqual(@as(usize, 4), fake.call_count);
    try std.testing.expectEqualStrings(bbr.bitbucket.base_url ++ "/user", fake.urlAt(0).?);
    try std.testing.expectEqual(bbr.http.client.Method.GET, fake.methodAt(0).?);
    try std.testing.expectEqual(bbr.http.client.Method.DELETE, fake.methodAt(2).?);
    try std.testing.expectEqualStrings(
        bbr.bitbucket.base_url ++ "/repositories/workspace/repository/pullrequests/42/request-changes",
        fake.urlAt(2).?,
    );
}

test "set-verdict does not mutate when account authentication fails" {
    var fake: bbr.http.FakeHttpClient = .{ .status = 401 };
    try std.testing.expectError(error.Unauthorized, setVerdict(std.testing.allocator, testClient(&fake), &.{
        "--repository=repository", "--pull-request-id=42", "--verdict=approved", "--expected-source-commit=abc123",
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.call_count);
    try std.testing.expectEqualStrings(bbr.bitbucket.base_url ++ "/user", fake.lastUrl().?);
    try std.testing.expectEqual(bbr.http.client.Method.GET, fake.last_method.?);
}
