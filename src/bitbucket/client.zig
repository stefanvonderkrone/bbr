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
const PullRequestSummary = types.PullRequestSummary;
const HeadCommits = types.HeadCommits;
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

    /// GET /repositories/{workspace}/{repo}/pullrequests, following `next`
    /// links, optionally filtered to one source branch. Returns a flat slice of
    /// `PullRequestSummary` owned by `allocator` (free with `deinitSummaries`,
    /// or pass an arena). `opts.state` defaults to OPEN; pass an explicit branch
    /// via `opts.source_branch` to find the AdjacentPullRequest(s).
    pub fn listPullRequests(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        opts: ListOptions,
    ) ![]PullRequestSummary {
        const auth = try self.cred.basicAuthHeader(allocator);
        defer allocator.free(auth);

        var out: std.ArrayList(PullRequestSummary) = .empty;
        errdefer {
            for (out.items) |s| deinitSummary(allocator, s);
            out.deinit(allocator);
        }

        var url = try self.firstPageUrl(allocator, repo_slug, opts);
        while (true) {
            const res = try self.http.send(allocator, .{
                .method = .GET,
                .url = url,
                .headers = &.{
                    .{ .name = "authorization", .value = auth },
                    .{ .name = "accept", .value = "application/json" },
                },
            });
            allocator.free(url); // request sent; slice free to reuse.
            defer allocator.free(res.body);

            try classify(res.status);

            const parsed = std.json.parseFromSlice(PrListPage, allocator, res.body, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedResponse;
            defer parsed.deinit();

            for (parsed.value.values) |pj| {
                try out.append(allocator, try dupeSummary(allocator, pj));
            }

            const next = parsed.value.next orelse break;
            url = try allocator.dupe(u8, next);
        }

        return out.toOwnedSlice(allocator);
    }

    /// Build the first-page listing URL. The optional source-branch filter goes
    /// through Bitbucket's `q` query language (`source.branch.name="<branch>"`),
    /// percent-encoded; `state` is a plain query param.
    fn firstPageUrl(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        opts: ListOptions,
    ) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.print(allocator,
            "{s}/repositories/{s}/{s}/pullrequests?pagelen=50&state={s}",
            .{ base_url, self.cred.workspace, repo_slug, opts.state },
        );
        if (opts.source_branch) |branch| {
            try buf.appendSlice(allocator, "&q=");
            try percentEncodeInto(allocator, &buf, "source.branch.name=\"");
            try percentEncodeInto(allocator, &buf, branch);
            try percentEncodeInto(allocator, &buf, "\"");
        }
        return buf.toOwnedSlice(allocator);
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

    /// GET /repositories/{workspace}/{repo}/src/{commit}/{path}: a file's full
    /// text at a given commit. Used by the true-whole-file view (M9) to fill the
    /// unchanged regions the diff omits. Returns the raw bytes owned by
    /// `allocator`, exactly as served (same contract as `getDiff`). `path` is the
    /// repo-relative file path; `commit` is a full or abbreviated hash.
    pub fn getFileBlob(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        commit: []const u8,
        path: []const u8,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/src/{s}/{s}",
            .{ base_url, self.cred.workspace, repo_slug, commit, path },
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

    /// GET the first page of the comments *list* raw (debug aid), so we can see
    /// how the list endpoint shapes a comment vs. the single-comment endpoint.
    pub fn getCommentsRaw(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments?pagelen=100",
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
        errdefer allocator.free(res.body);
        try classify(res.status);
        return res.body;
    }

    /// GET a single comment's raw JSON (debug aid): /pullrequests/{id}/comments/{comment_id}.
    /// Returns the body verbatim, owned by `allocator`, so we can inspect the real
    /// wire shape (e.g. how Bitbucket flags an outdated comment).
    pub fn getCommentRaw(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        comment_id: u64,
    ) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/repositories/{s}/{s}/pullrequests/{d}/comments/{d}",
            .{ base_url, self.cred.workspace, repo_slug, id, comment_id },
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
        errdefer allocator.free(res.body);
        try classify(res.status);
        return res.body;
    }

    /// GET /repositories/{workspace}/{repo}/pullrequests/{id}/comments, following
    /// Bitbucket's `next` links until the last page. Returns every non-deleted
    /// comment flat (thread nesting is the review context's job, `buildThreads`).
    /// Each `Comment` and its strings are owned by `allocator`; free the batch
    /// with `deinitComments`. Callers should pass a PR-scoped arena.
    /// `head` is the PR's current source/destination commits: a comment whose
    /// anchored `links.code` revision differs is flagged outdated (the list
    /// endpoint does not expose the verdict directly). Pass `.{}` to skip this
    /// (then only an explicit `inline.outdated` marks a comment outdated).
    pub fn getComments(
        self: Client,
        allocator: Allocator,
        repo_slug: []const u8,
        id: u64,
        head: HeadCommits,
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
                try out.append(allocator, try dupeComment(allocator, cj, head));
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

/// Filter for `listPullRequests`. `state` is a Bitbucket PR state string
/// (OPEN, MERGED, DECLINED, SUPERSEDED); `source_branch` restricts to PRs
/// opened from that branch (the AdjacentPullRequest lookup).
pub const ListOptions = struct {
    state: []const u8 = "OPEN",
    source_branch: ?[]const u8 = null,
};

/// Percent-encode `raw` into `buf`, escaping everything outside the RFC 3986
/// unreserved set. Keeps the `q` filter (with its `=`, quotes, spaces) safe as
/// a single query-parameter value.
fn percentEncodeInto(allocator: Allocator, buf: *std.ArrayList(u8), raw: []const u8) !void {
    for (raw) |c| {
        if (isUnreserved(c)) {
            try buf.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0f]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// The subset of a PR list entry we surface. Commit hashes are absent from the
/// list endpoint, so they are not modeled here (see `PullRequestSummary`).
const PrSummaryJson = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author: ?struct { display_name: ?[]const u8 = null } = null,
    source: struct { branch: struct { name: []const u8 } },
    destination: struct { branch: struct { name: []const u8 } },
};

const PrListPage = struct {
    values: []PrSummaryJson,
    next: ?[]const u8 = null,
};

fn dupeSummary(allocator: Allocator, pj: PrSummaryJson) !PullRequestSummary {
    const author = if (pj.author) |a| (a.display_name orelse "") else "";
    return .{
        .id = pj.id,
        .title = try allocator.dupe(u8, pj.title),
        .state = try allocator.dupe(u8, pj.state),
        .author_display_name = try allocator.dupe(u8, author),
        .source_branch = try allocator.dupe(u8, pj.source.branch.name),
        .destination_branch = try allocator.dupe(u8, pj.destination.branch.name),
    };
}

fn deinitSummary(allocator: Allocator, s: PullRequestSummary) void {
    allocator.free(s.title);
    allocator.free(s.state);
    allocator.free(s.author_display_name);
    allocator.free(s.source_branch);
    allocator.free(s.destination_branch);
}

/// Free a batch returned by `listPullRequests`.
pub fn deinitSummaries(allocator: Allocator, summaries: []PullRequestSummary) void {
    for (summaries) |s| deinitSummary(allocator, s);
    allocator.free(summaries);
}

/// JSON shape we read from Bitbucket. `ignore_unknown_fields` skips the rest.
const PrJson = struct {
    id: u64,
    title: []const u8,
    state: []const u8,
    author: struct { display_name: []const u8 },
    source: struct { branch: struct { name: []const u8 }, commit: struct { hash: []const u8 } },
    destination: struct { branch: struct { name: []const u8 }, commit: struct { hash: []const u8 } },
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
        .source_commit = try allocator.dupe(u8, v.source.commit.hash),
        .destination_commit = try allocator.dupe(u8, v.destination.commit.hash),
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
    /// `links.code.href` embeds the diff revision the comment is anchored to,
    /// e.g. ".../diff/ws/repo:<src>..<dst>?path=…". Comparing that revision to
    /// the PR's current one is how we detect outdated (the list omits the flag).
    links: ?struct { code: ?struct { href: ?[]const u8 = null } = null } = null,
};

const CommentsPage = struct {
    values: []CommentJson,
    /// Absolute URL of the next page, or absent on the last page.
    next: ?[]const u8 = null,
};

/// Copy one wire comment into a domain `Comment` owned by `allocator`. `head`
/// is the PR's current revision, used to detect outdated inline comments.
fn dupeComment(allocator: Allocator, cj: CommentJson, head: HeadCommits) !Comment {
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
        .state = commentState(cj, head),
    };
}

/// Resolve a comment's `AnchorState`. Trust an explicit `inline.outdated` if
/// present (the single-comment endpoint sets it); otherwise — for list results,
/// which omit it — compare the comment's anchored revision (from `links.code`)
/// to the PR's current one. A mismatch means the diff moved under it: outdated.
fn commentState(cj: CommentJson, head: HeadCommits) review.AnchorState {
    const inl = cj.@"inline" orelse return .current; // PR-level: never outdated
    if (inl.outdated) |o| return if (o) .outdated else .current;

    // No explicit verdict: fall back to the revision comparison, but only when
    // we know both the PR head and the comment's anchored range.
    if (head.source.len == 0 or head.destination.len == 0) return .current;
    const href = (if (cj.links) |l| (if (l.code) |c| c.href else null) else null) orelse return .current;
    const rev = parseCodeRevision(href) orelse return .current;
    const matches = hashMatches(rev.src, head.source) and hashMatches(rev.dst, head.destination);
    return if (matches) .current else .outdated;
}

/// The `<src>..<dst>` commit pair from a `links.code` href of the form
/// ".../diff/{ws}/{repo}:{src}..{dst}?path=…". Null if it doesn't parse.
fn parseCodeRevision(href: []const u8) ?struct { src: []const u8, dst: []const u8 } {
    // The revision range sits between the last ':' and the '?' (or end).
    const colon = std.mem.lastIndexOfScalar(u8, href, ':') orelse return null;
    var rest = href[colon + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
    const sep = std.mem.indexOf(u8, rest, "..") orelse return null;
    const src = rest[0..sep];
    const dst = rest[sep + 2 ..];
    if (src.len == 0 or dst.len == 0) return null;
    return .{ .src = src, .dst = dst };
}

/// Compare two commit hashes tolerant of abbreviation (Bitbucket may hand back
/// 12-char hashes in one place and full 40-char in another): equal if the
/// shorter is a prefix of the longer.
fn hashMatches(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const shorter = if (a.len <= b.len) a else b;
    const longer = if (a.len <= b.len) b else a;
    return std.mem.startsWith(u8, longer, shorter);
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
    allocator.free(pr.source_commit);
    allocator.free(pr.destination_commit);
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
    try testing.expectEqualStrings("abc123def456", pr.source_commit);
    try testing.expectEqualStrings("0011223344ff", pr.destination_commit);
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

// A two-entry PR list page (no `next`: single page). Only fields our summary
// reads are asserted; the rest exercise `ignore_unknown_fields`.
const fixture_pr_list =
    \\{ "values": [
    \\  { "id": 42, "title": "Add diff parser", "state": "OPEN",
    \\    "author": { "display_name": "Ada Lovelace" },
    \\    "source": { "branch": { "name": "feature/diff" } },
    \\    "destination": { "branch": { "name": "main" } } },
    \\  { "id": 43, "title": "Fix nav", "state": "OPEN",
    \\    "author": { "display_name": "Grace Hopper" },
    \\    "source": { "branch": { "name": "feature/nav" } },
    \\    "destination": { "branch": { "name": "main" } } }
    \\] }
;

test "listPullRequests parses summaries" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr_list };
    const bb = Client.init(fake.httpClient(), testCredential());

    const prs = try bb.listPullRequests(a, "myrepo", .{});
    defer deinitSummaries(a, prs);

    try testing.expectEqual(@as(usize, 2), prs.len);
    try testing.expectEqual(@as(u64, 42), prs[0].id);
    try testing.expectEqualStrings("Add diff parser", prs[0].title);
    try testing.expectEqualStrings("Ada Lovelace", prs[0].author_display_name);
    try testing.expectEqualStrings("feature/diff", prs[0].source_branch);
    try testing.expectEqualStrings("main", prs[0].destination_branch);
    try testing.expectEqualStrings("feature/nav", prs[1].source_branch);
}

test "listPullRequests builds a filtered, percent-encoded URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_pr_list };
    const bb = Client.init(fake.httpClient(), testCredential());

    const prs = try bb.listPullRequests(a, "myrepo", .{ .source_branch = "feature/x y" });
    defer deinitSummaries(a, prs);

    // state is a plain param; the branch filter is `source.branch.name="..."`
    // percent-encoded as a single q value (space→%20, quote→%22, slash→%2F).
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests" ++
            "?pagelen=50&state=OPEN&q=source.branch.name%3D%22feature%2Fx%20y%22",
        fake.lastUrl().?,
    );
}

test "listPullRequests follows next links across pages" {
    const a = testing.allocator;
    const page1 =
        \\{ "values": [
        \\  { "id": 1, "title": "one", "state": "OPEN",
        \\    "source": { "branch": { "name": "b1" } },
        \\    "destination": { "branch": { "name": "main" } } } ],
        \\  "next": "https://api.bitbucket.org/2.0/repositories/check24/myrepo/pullrequests?page=2" }
    ;
    const page2 =
        \\{ "values": [
        \\  { "id": 2, "title": "two", "state": "OPEN",
        \\    "source": { "branch": { "name": "b2" } },
        \\    "destination": { "branch": { "name": "main" } } } ] }
    ;
    const Canned = @import("../http/fake_client.zig").Canned;
    const responses = [_]Canned{
        .{ .status = 200, .body = page1 },
        .{ .status = 200, .body = page2 },
    };
    var fake: FakeHttpClient = .{ .responses = &responses };
    const bb = Client.init(fake.httpClient(), testCredential());

    const prs = try bb.listPullRequests(a, "myrepo", .{});
    defer deinitSummaries(a, prs);

    try testing.expectEqual(@as(usize, 2), prs.len);
    try testing.expectEqual(@as(u64, 1), prs[0].id);
    try testing.expectEqual(@as(u64, 2), prs[1].id);
    try testing.expectEqual(@as(usize, 2), fake.call_count);
}

test "listPullRequests surfaces ApiError" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 401, .body = "" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.Unauthorized, bb.listPullRequests(a, "myrepo", .{}));
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

test "getFileBlob returns the raw file text at the right URL" {
    const a = testing.allocator;
    const contents = "line1\nline2\nline3\n";
    var fake: FakeHttpClient = .{ .status = 200, .body = contents };
    const bb = Client.init(fake.httpClient(), testCredential());

    const blob = try bb.getFileBlob(a, "myrepo", "abc123", "src/foo.zig");
    defer a.free(blob);

    try testing.expectEqualStrings(contents, blob);
    try testing.expectEqual(httpc.Method.GET, fake.last_method.?);
    try testing.expectEqualStrings(
        "https://api.bitbucket.org/2.0/repositories/check24/myrepo/src/abc123/src/foo.zig",
        fake.lastUrl().?,
    );
}

test "getFileBlob surfaces ApiError on non-2xx and leaks nothing" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 404, .body = "no such path" };
    const bb = Client.init(fake.httpClient(), testCredential());
    try testing.expectError(error.NotFound, bb.getFileBlob(a, "myrepo", "deadbeef", "gone.zig"));
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

    const comments = try bb.getComments(a, "myrepo", 7, .{});
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

// A real single-comment shape captured from PR 1726 (comment 811927613): an
// inline suggestion Bitbucket flags outdated. `from` is JSON null, `to` set.
const outdated_comment_page =
    \\{ "values": [
    \\  { "id": 811927613, "deleted": false, "pending": false,
    \\    "content": { "raw": "```suggestion\n        : phpOrigin;\n```\n\nyou already fall back" },
    \\    "user": { "display_name": "Stefan von der Krone" },
    \\    "inline": { "from": null, "to": 38, "path": "app/routes/rpc/$.ts",
    \\                "start_from": null, "start_to": null, "outdated": true, "base_rev": null } }
    \\] }
;

test "an inline.outdated comment parses to AnchorState.outdated" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = outdated_comment_page };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "pr-webapp", 1726, .{});
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqual(@as(usize, 1), comments.len);
    try testing.expectEqual(review.AnchorState.outdated, comments[0].state);
    try testing.expectEqual(@as(?u32, 38), comments[0].anchor.?.to);
    try testing.expect(comments[0].anchor.?.from == null);
    try testing.expect(comments[0].suggestion() != null);
}

// A list page as the *list* endpoint actually shapes it (no inline.outdated),
// with two comments: one anchored to the PR's current revision, one to an older
// one. Mirrors PR 1726: outdated is derived from links.code, not a flag.
const list_with_revisions =
    \\{ "values": [
    \\  { "id": 1, "deleted": false,
    \\    "content": { "raw": "current one" }, "user": { "display_name": "Ada" },
    \\    "inline": { "from": null, "to": 30, "path": "app/utility/env.ts" },
    \\    "links": { "code": { "href":
    \\      "https://api.bitbucket.org/2.0/repositories/check24/pr-webapp/diff/check24/pr-webapp:f6180208c871..41739df6fc7f?path=app%2Futility%2Fenv.ts" } } },
    \\  { "id": 2, "deleted": false,
    \\    "content": { "raw": "stale one" }, "user": { "display_name": "Ada" },
    \\    "inline": { "from": null, "to": 38, "path": "app/routes/rpc/$.ts" },
    \\    "links": { "code": { "href":
    \\      "https://api.bitbucket.org/2.0/repositories/check24/pr-webapp/diff/check24/pr-webapp:c034a30e082c..826e08904076?path=app%2Froutes%2Frpc%2F%24.ts" } } }
    \\] }
;

test "outdated is derived from links.code revision vs PR head" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = list_with_revisions };
    const bb = Client.init(fake.httpClient(), testCredential());

    // PR head as captured for 1726.
    const comments = try bb.getComments(a, "pr-webapp", 1726, .{
        .source = "f6180208c871",
        .destination = "41739df6fc7f",
    });
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqual(@as(usize, 2), comments.len);
    // #1 anchored to source..dest == current head → current.
    try testing.expectEqual(review.AnchorState.current, comments[0].state);
    // #2 anchored to an older revision → outdated.
    try testing.expectEqual(review.AnchorState.outdated, comments[1].state);
}

test "without PR head, list comments default to current (no false outdated)" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = list_with_revisions };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "pr-webapp", 1726, .{}); // no head
    defer @import("client.zig").deinitComments(a, comments);

    try testing.expectEqual(review.AnchorState.current, comments[0].state);
    try testing.expectEqual(review.AnchorState.current, comments[1].state);
}

test "parseCodeRevision extracts the src..dst pair" {
    const rev = parseCodeRevision(
        "https://api.bitbucket.org/2.0/repositories/check24/pr-webapp/diff/check24/pr-webapp:aaaa..bbbb?path=x",
    ).?;
    try testing.expectEqualStrings("aaaa", rev.src);
    try testing.expectEqualStrings("bbbb", rev.dst);
    try testing.expect(parseCodeRevision("no colon or range here") == null);
}

// A full comments-list page captured live from PR 1726, then sanitized (author
// names, prose, suggestion code, file paths, and workspace scrubbed; comment
// ids and the links.code commit ranges kept, since outdated detection rides on
// them). Guards the real wire shape against schema drift.
const fixture_comments_1726 = @embedFile("testdata/comments_pr1726.json");

test "sanitized PR 1726 fixture: shape, deleted-skip, and outdated detection" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body = fixture_comments_1726 };
    const bb = Client.init(fake.httpClient(), testCredential());

    // PR 1726's real head (the "current" comment anchors exactly this range).
    const comments = try bb.getComments(a, "pr-webapp", 1726, .{
        .source = "f6180208c871",
        .destination = "41739df6fc7f",
    });
    defer @import("client.zig").deinitComments(a, comments);

    // 19 on the wire, 9 deleted → 10 kept.
    try testing.expectEqual(@as(usize, 10), comments.len);

    var outdated: usize = 0;
    var suggestions: usize = 0;
    for (comments) |c| {
        if (c.state == .outdated) outdated += 1;
        if (c.suggestion() != null) suggestions += 1;
    }
    // Every comment but the one anchored to the current head is outdated.
    try testing.expectEqual(@as(usize, 9), outdated);
    try testing.expectEqual(@as(usize, 2), suggestions);

    // Threaded: 9 roots + 1 reply, and 8 outdated thread roots (the reply's
    // outdated-ness doesn't count as a root) — matching the live `check`.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const threads = try @import("../review/thread.zig").build(arena.allocator(), comments);
    try testing.expectEqual(@as(usize, 9), threads.len);

    var outdated_roots: usize = 0;
    for (threads) |t| {
        if (t.root.state == .outdated) outdated_roots += 1;
    }
    try testing.expectEqual(@as(usize, 8), outdated_roots);
}

test "hashMatches tolerates abbreviation" {
    try testing.expect(hashMatches("f6180208c871", "f6180208c871abcd1234"));
    try testing.expect(hashMatches("f6180208c871abcd1234", "f6180208c871"));
    try testing.expect(!hashMatches("f6180208c871", "c034a30e082c"));
    try testing.expect(!hashMatches("", "abc"));
}

test "getComments builds the correct first-page URL" {
    const a = testing.allocator;
    var fake: FakeHttpClient = .{ .status = 200, .body =
        \\{ "values": [] }
    };
    const bb = Client.init(fake.httpClient(), testCredential());

    const comments = try bb.getComments(a, "myrepo", 7, .{});
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
    try testing.expectError(error.Forbidden, bb.getComments(a, "myrepo", 7, .{}));
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
    const comments = try bb.getComments(arena.allocator(), "myrepo", 7, .{});
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
