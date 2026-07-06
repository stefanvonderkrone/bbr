//! Bitbucket Cloud REST adapter (api.bitbucket.org/2.0). Turns HTTP responses
//! into typed domain values behind the `HttpClient` seam, so it is fully
//! testable with `FakeHttpClient` — no network in tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const httpc = @import("../http/client.zig");
const HttpClient = httpc.HttpClient;
const Credential = @import("credential.zig").Credential;
const types = @import("types.zig");
const PullRequest = types.PullRequest;
const ApiError = types.ApiError;
const review = @import("../review/comment.zig");
const Comment = review.Comment;
const Anchor = review.Anchor;

pub const base_url = "https://api.bitbucket.org/2.0";

pub const Client = struct {
    http: HttpClient,
    cred: Credential,

    pub fn init(http: HttpClient, cred: Credential) Client {
        return .{ .http = http, .cred = cred };
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests/{id}.
    /// The returned `PullRequest` (and its strings) is owned by `allocator`.
    pub fn getPullRequest(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
    ) !PullRequest {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer allocator.free(res.body);

        try classify(res.status);
        return parsePullRequest(allocator, res.body);
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests/{id}/diff.
    /// Returns the raw unified diff text (owned by `allocator`) exactly as
    /// Bitbucket serves it — the authoritative line model (ADR-0001). Feed it to
    /// `diff.parse`; this adapter deliberately does not parse, so the same text
    /// path serves both remote and (later) local review.
    pub fn getDiff(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/diff",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );
        defer allocator.free(url);

        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        const res = try self.http.send(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "accept", .value = "text/plain" },
            },
        });
        errdefer allocator.free(res.body);

        try classify(res.status);
        return res.body;
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests/{id}/comments, following
    /// Bitbucket's `next` links until the last page. Returns every non-deleted
    /// comment flat (thread nesting is the review context's job, `buildThreads`).
    /// Each `Comment` and its strings are owned by `allocator`; free the batch
    /// with `deinitComments`. Callers should pass a PR-scoped arena.
    pub fn getComments(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
    ) ![]Comment {
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        var out: std.ArrayList(Comment) = .empty;
        errdefer out.deinit(allocator);

        // First page URL is ours; each subsequent one is Bitbucket's `next` link
        // (an absolute URL). `url` is always heap-owned by `allocator` here.
        var url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments?pagelen=100",
            .{ base_url, self.cred.workspace, repo_slug, id },
        );

        while (true) {
            const res = try self.http.send(allocator, .{
                .method = .GET,
                .url = url,
                .headers = &.{
                    .{ .name = "authorization", .value = auth },
                    .{ .name = "accept", .value = "application/json" },
                },
            });
            allocator.free(url); // request is sent; the slice is free to reuse.
            defer allocator.free(res.body);

            try classify(res.status);

            const parsed = std.json.parseFromSlice(CommentsPage, allocator, res.body, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedResponse;
            defer parsed.deinit();

            for (parsed.value.values) |cj| {
                if (cj.deleted) continue;
                try out.append(allocator, try dupeComment(allocator, cj));
            }

            const next = parsed.value.next orelse break;
            url = try allocator.dupe(u8, next);
        }

        return out.toOwnedSlice(allocator);
    }
};

/// Map HTTP status to an `ApiError`; return normally on 2xx.
fn classify(status: u16) ApiError!void {
    return switch (status) {
        200...299 => {},
        401 => error.Unauthorized,
        403 => error.Forbidden,
        404 => error.NotFound,
        429 => error.RateLimited,
        500...599 => error.ServerError,
        else => error.UnexpectedStatus,
    };
}

/// JSON shape we read from Bitbucket. `ignore_unknown_fields` skips the rest.
const PrJson = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author: struct { display_name: []const u8 },
    source: struct { branch: struct { name: []const u8 } },
    destination: struct { branch: struct { name: []const u8 } },
};

fn parsePullRequest(allocator: Allocator, body: []const u8) !PullRequest {
    const parsed = std.json.parseFromSlice(PrJson, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedResponse;
    defer parsed.deinit();
    const v = parsed.value;

    // Duplicate the strings out of the parse arena into the caller's allocator.
    return .{
        .id = v.id,
        .title = try allocator.dupe(u8, v.title),
        .state = try allocator.dupe(u8, v.state),
        .author_display_name = try allocator.dupe(u8, v.author.display_name),
        .source_branch = try allocator.dupe(u8, v.source.branch.name),
        .destination_branch = try allocator.dupe(u8, v.destination.branch.name),
    };
}

/// The comment JSON we read from a page of the comments endpoint. Fields we
/// don't model are ignored; anything optional defaults so deleted/system
/// comments (which may omit `content`/`user`) still parse.
const CommentJson = struct {
    id: u64,
    content: ?struct { raw: ?[]const u8 = null } = null,
    user: ?struct { display_name: ?[]const u8 = null } = null,
    deleted: bool = false,
    parent: ?struct { id: u64 } = null,
    // `inline` is a Zig keyword; @"inline" maps to the JSON key "inline".
    @"inline": ?struct {
        path: []const u8,
        from: ?u32 = null,
        to: ?u32 = null,
        /// Bitbucket's own outdated verdict for this anchor (ADR-0001). Absent on
        /// current comments; treat missing as `current`.
        outdated: ?bool = null,
    } = null,
    /// Present (an object) when the thread is resolved; null/absent otherwise.
    resolution: ?struct {} = null,
};

const CommentsPage = struct {
    values: []CommentJson,
    /// Absolute URL of the next page, or absent on the last page.
    next: ?[]const u8 = null,
};

/// Copy one wire comment into a domain `Comment` owned by `allocator`.
fn dupeComment(allocator: Allocator, cj: CommentJson) !Comment {
    const author = if (cj.user) |u| (u.display_name orelse "") else "";
    const raw = if (cj.content) |c| (c.raw orelse "") else "";

    const author_owned = try allocator.dupe(u8, author);
    errdefer allocator.free(author_owned);
    const body_owned = try allocator.dupe(u8, raw);
    errdefer allocator.free(body_owned);

    var anchor: ?Anchor = null;
    if (cj.@"inline") |inl| {
        anchor = .{
            .path = try allocator.dupe(u8, inl.path),
            .from = inl.from,
            .to = inl.to,
        };
    }

    return .{
        .id = cj.id,
        .parent_id = if (cj.parent) |p| p.id else null,
        .author = author_owned,
        .body = body_owned,
        .anchor = anchor,
        .resolved = cj.resolution != null,
        .state = if (cj.@"inline") |inl|
            (if (inl.outdated orelse false) .outdated else .current)
        else
            .current,
    };
}

/// Free a batch returned by `getComments` (each comment's strings, then the
/// slice). No-op-safe on an arena, but correct under any allocator.
pub fn deinitComments(allocator: Allocator, comments: []Comment) void {
    for (comments) |c| {
        allocator.free(c.author);
        allocator.free(c.body);
        if (c.anchor) |a| allocator.free(a.path);
    }
    allocator.free(comments);
}

pub fn deinitPullRequest(allocator: Allocator, pr: PullRequest) void {
    allocator.free(pr.title);
    allocator.free(pr.state);
    allocator.free(pr.author_display_name);
    allocator.free(pr.source_branch);
    allocator.free(pr.destination_branch);
}

// ---------------------------------------------------------------------------
// Tests — no network; FakeHttpClient supplies fixtures.
// ---------------------------------------------------------------------------
const testing = std.testing;
const FakeHttpClient = @import("../http/fake_client.zig").FakeHttpClient;

// A schema-representative Bitbucket PR response (many fields our model ignores).
// Replace with a real captured response via `zig build check` when convenient.
const fixture_pr = @embedFile("testdata/pullrequest.json");

fn testCredential() Credential {
    return .{ .username = "u", .token = "t", .workspace = "check24" };
}

test "getPullRequest parses a well-formed fixture" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr };
    const bb = Client.init(fake.httpClient(), testCredential());

    const pr = try bb.getPullRequest(a, "myrepo", 42);
    defer deinitPullRequest(a, pr);

    try testing.expectEqual(@as(u64, 42), pr.id);
    try testing.expectEqualStrings("Add diff parser", pr.title);
    try testing.expectEqualStrings("OPEN", pr.state);
    try testing.expectEqualStrings("Ada Lovelace", pr.author_display_name);
    try testing.expectEqualStrings("feature/diff", pr.source_branch);
    try testing.expectEqualStrings("main", pr.destination_branch);
}

test "getPullRequest builds the correct URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr };
    const bb = Client.init(fake.httpClient(), testCredential());

    const pr = try bb.getPullRequest(a, "myrepo", 42);
    defer deinitPullRequest(a, pr);

    try testing.expectEqual(httpc.Method.GET, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/42",
        fake.lastUrl().?,
    );
}

test "status codes map to the right ApiError" {
    const a = testing.allocator;
    const cases = [_]struct { status: u16, want: anyerror }{
        .{ .status = 401, .want = error.Unauthorized },
        .{ .status = 403, .want = error.Forbidden },
        .{ .status = 404, .want = error.NotFound },
        .{ .status = 429, .want = error.RateLimited },
        .{ .status = 503, .want = error.ServerError },
        .{ .status = 302, .want = error.UnexpectedStatus },
    };
    for (cases) |c| {
        var fake: FakeHttpClient = .{ .status = c.status, .body = "" };
        const bb = Client.init(fake.httpClient(), testCredential());
        try testing.expectError(c.want, bb.getPullRequest(a, "myrepo", 1));
    }
}

test "malformed 2xx body is a MalformedResponse" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = "{ not json" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.MalformedResponse, bb.getPullRequest(a, "myrepo", 1));
}

const sample_diff =
    \\diff --git a/a.txt b/a.txt
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,2 +1,2 @@
    \\ keep
    \\-old
    \\+new
    \\
;

test "getDiff returns the raw diff text at the right URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = sample_diff };
    const bb = Client.init(fake.httpClient(), testCredential());

    const raw = try bb.getDiff(a, "myrepo", 42);
    defer a.free(raw);

    try testing.expectEqualStrings(sample_diff, raw);
    try testing.expectEqual(httpc.Method.GET, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/42/diff",
        fake.lastUrl().?,
    );
}

test "getDiff surfaces ApiError on non-2xx and leaks nothing" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 404, .body = "not found" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.NotFound, bb.getDiff(a, "myrepo", 1));
}

const comments_page_1 =
    \\{
    \\  "values": [
    \\    { "id": 1, "content": { "raw": "Looks good overall" },
    \\      "user": { "display_name": "Ada" } },
    \\    { "id": 2, "parent": { "id": 1 }, "content": { "raw": "agreed" },
    \\      "user": { "display_name": "Bob" } },
    \\    { "id": 3, "content": { "raw": "gone" }, "deleted": true,
    \\      "user": { "display_name": "Sys" } },
    \\    { "id": 4, "content": { "raw": "fix here" }, "user": { "display_name": "Cy" },
    \\      "inline": { "path": "src/foo.zig", "to": 42 },
    \\      "resolution": { "type": "resolution" } }
    \\  ],
    \\  "next": "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments?page=2"
    \\}
;

const comments_page_2 =
    \\{
    \\  "values": [
    \\    { "id": 5, "content": { "raw": "this line moved on" },
    \\      "user": { "display_name": "Di" },
    \\      "inline": { "path": "src/bar.zig", "from": 10, "outdated": true } }
    \\  ]
    \\}
;

test "getComments follows next links and returns non-deleted comments" {
    const a = testing.allocator;
    const pages = [_]@import("../http/fake_client.zig").Canned{
        .{ .status = 200, .body = comments_page_1 },
        .{ .status = 200, .body = comments_page_2 },
    };
    var fake: FakeHttpClient = .{ .responses = &pages };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "myrepo", 7);
    defer @import("client.zig").deinitComments(a, comments);

    // 5 wire comments, one deleted → 4 kept, across two pages.
    try testing.expectEqual(@as(usize, 2), fake.call_count);
    try testing.expectEqual(@as(usize, 4), comments.len);

    try testing.expectEqualStrings("Ada", comments[0].author);
    try testing.expect(comments[0].parent_id == null);

    // The reply keeps its parent link.
    try testing.expectEqual(@as(?review.CommentId, 1), comments[1].parent_id);

    // The inline+resolved comment.
    try testing.expect(comments[2].isInline());
    try testing.expectEqual(@as(?u32, 42), comments[2].anchor.?.to);
    try testing.expect(comments[2].resolved);
    try testing.expectEqual(review.AnchorState.current, comments[2].state);

    // Bitbucket's outdated verdict is honored.
    try testing.expectEqual(review.AnchorState.outdated, comments[3].state);
    try testing.expectEqual(@as(?u32, 10), comments[3].anchor.?.from);
}

test "getComments builds the correct first-page URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "myrepo", 7);
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests/7/comments?pagelen=100",
        fake.lastUrl().?,
    );
}

test "getComments surfaces ApiError on non-2xx" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 403, .body = "nope" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.Forbidden, bb.getComments(a, "myrepo", 7));
}

// A single-page body (no `next`) so the pagination loop terminates after one GET.
const comments_single =
    \\{
    \\  "values": [
    \\    { "id": 1, "content": { "raw": "Looks good overall" },
    \\      "user": { "display_name": "Ada" } },
    \\    { "id": 2, "parent": { "id": 1 }, "content": { "raw": "agreed" },
    \\      "user": { "display_name": "Bob" } },
    \\    { "id": 4, "content": { "raw": "fix here" }, "user": { "display_name": "Cy" },
    \\      "inline": { "path": "src/foo.zig", "to": 42 },
    \\      "resolution": { "type": "resolution" } }
    \\  ]
    \\}
;

test "getComments end to end feeds the thread builder" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = comments_single };
    const bb = Client.init(fake.httpClient(), testCredential());

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comments = try bb.getComments(arena.allocator(), "myrepo", 7);
    const threads = try @import("../review/thread.zig").build(arena.allocator(), comments);

    // root #1 with reply #2, and inline root #4.
    try testing.expectEqual(@as(usize, 2), threads.len);
    try testing.expectEqual(@as(usize, 1), threads[0].replies.len);
    try testing.expect(threads[1].isInline());
    try testing.expect(threads[1].resolved);
}

test "getDiff output feeds the parser end to end" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = sample_diff };
    const bb = Client.init(fake.httpClient(), testCredential());

    const raw = try bb.getDiff(a, "myrepo", 42);
    defer a.free(raw);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try @import("../diff/parser.zig").parse(arena.allocator(), raw);

    try testing.expectEqual(@as(usize, 1), parsed.files.len);
    try testing.expectEqualStrings("a.txt", parsed.files[0].new_path);
    try testing.expectEqual(@as(usize, 3), parsed.files[0].hunks[0].lines.len);
}
