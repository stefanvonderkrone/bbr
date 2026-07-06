//! Parsing a Bitbucket pull-request URL into `(workspace, repo_slug, id)`. Pure
//! and allocation-free — the string fields borrow the input. Accepts both the
//! web UI form and the REST API form, with or without trailing path/query/frag:
//!
//!   https://bitbucket.org/{ws}/{repo}/pull-requests/{id}[/…]
//!   https://api.bitbucket.org/2.0/repositories/{ws}/{repo}/pullrequests/{id}
//!
//! so a reviewer can paste whatever they copied.

const std = @import("std");

pub const PrRef = struct {
    workspace: []const u8,
    repo_slug: []const u8,
    id: u64,
};

pub const ParseError = error{
    /// Host is not a Bitbucket one, or the path has no PR marker.
    NotABitbucketPrUrl,
    /// The `pull-requests/<id>` segment is missing or not a number.
    MalformedUrl,
};

/// Parse a pasted PR URL. `id` must be a positive integer; the workspace/repo
/// are the two path segments preceding the `pull-requests`/`pullrequests`
/// marker. Any trailing segments (`/diff`, `/commits`), `?query`, or `#frag`
/// are ignored.
pub fn parse(url: []const u8) ParseError!PrRef {
    // Strip scheme + host so we work on the path only, and validate the host.
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |s| {
        rest = rest[s + 3 ..];
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NotABitbucketPrUrl;
    const hostname = rest[0..slash];
    if (!isBitbucketHost(hostname)) return error.NotABitbucketPrUrl;
    var path = rest[slash + 1 ..];

    // Drop query/fragment.
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];

    // Split into non-empty segments (up to a small fixed number — a PR URL is
    // shallow). Find the marker; workspace/repo precede it, id follows.
    var segs: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n == segs.len) return error.MalformedUrl;
        segs[n] = seg;
        n += 1;
    }

    const marker = for (segs[0..n], 0..) |seg, i| {
        if (std.mem.eql(u8, seg, "pull-requests") or std.mem.eql(u8, seg, "pullrequests")) break i;
    } else return error.NotABitbucketPrUrl;

    if (marker < 2 or marker + 1 >= n) return error.MalformedUrl;
    const id = std.fmt.parseInt(u64, segs[marker + 1], 10) catch return error.MalformedUrl;
    return .{
        .workspace = segs[marker - 2],
        .repo_slug = segs[marker - 1],
        .id = id,
    };
}

fn isBitbucketHost(h: []const u8) bool {
    return std.mem.eql(u8, h, "bitbucket.org") or std.mem.eql(u8, h, "api.bitbucket.org");
}

const testing = std.testing;

test "web UI url" {
    const r = try parse("https://bitbucket.org/check24/pr-webapp/pull-requests/1726");
    try testing.expectEqualStrings("check24", r.workspace);
    try testing.expectEqualStrings("pr-webapp", r.repo_slug);
    try testing.expectEqual(@as(u64, 1726), r.id);
}

test "web UI url with trailing segment and query" {
    const r = try parse("https://bitbucket.org/check24/pr-webapp/pull-requests/1726/diff?w=1#comment-42");
    try testing.expectEqualStrings("check24", r.workspace);
    try testing.expectEqualStrings("pr-webapp", r.repo_slug);
    try testing.expectEqual(@as(u64, 1726), r.id);
}

test "rest api url" {
    const r = try parse("https://api.bitbucket.org/2.0/repositories/check24/pr-webapp/pullrequests/1726");
    try testing.expectEqualStrings("check24", r.workspace);
    try testing.expectEqualStrings("pr-webapp", r.repo_slug);
    try testing.expectEqual(@as(u64, 1726), r.id);
}

test "non-bitbucket host is rejected" {
    try testing.expectError(error.NotABitbucketPrUrl, parse("https://github.com/foo/bar/pull/7"));
}

test "missing or malformed id" {
    try testing.expectError(error.MalformedUrl, parse("https://bitbucket.org/check24/pr-webapp/pull-requests/"));
    try testing.expectError(error.MalformedUrl, parse("https://bitbucket.org/check24/pr-webapp/pull-requests/abc"));
}

test "url without a PR marker is rejected" {
    try testing.expectError(error.NotABitbucketPrUrl, parse("https://bitbucket.org/check24/pr-webapp"));
}
