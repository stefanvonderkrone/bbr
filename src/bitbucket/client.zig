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
