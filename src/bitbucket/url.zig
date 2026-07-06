//! Parsing a Bitbucket pull-request URL into `(workspace, repo_slug, id)`. Pure
//! and allocation-free — the string fields borrow the input. Accepts both the
//! web UI form and the REST API form, with or without trailing path/query/frag:
//!
//!   https://bitbucket.org/{ws}/{repo}/pull-requests/{id}[/…]
//!   https://api.bitbucket.org/2.0/repositories/{ws}/{repo}/pullrequests/{id}
//!
//! so a reviewer can paste whatever they copied.
//!
//! `std.Uri` does the scheme/host/path/query/fragment decomposition (it requires
//! a scheme, which a pasted PR URL always has); the Bitbucket-specific bit — the
//! `pull-requests/<id>` marker and the two path segments before it — is ours.

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
    const uri = std.Uri.parse(url) catch return error.MalformedUrl;

    const host = uri.host orelse return error.NotABitbucketPrUrl;
    if (!isBitbucketHost(componentStr(host))) return error.NotABitbucketPrUrl;

    // std.Uri already split off query/fragment; the path is percent-encoded but
    // the segments we read (slugs, marker, id) are plain ASCII.
    const path = componentStr(uri.path);

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

/// The borrowed string behind a `std.Uri.Component` (either variant). We don't
/// decode percent-escapes: the host and the path segments we read are ASCII.
fn componentStr(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw, .percent_encoded => |s| s,
    };
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

test "userinfo and an explicit port are tolerated (std.Uri handles them)" {
    const r = try parse("https://user@bitbucket.org:443/check24/pr-webapp/pull-requests/9");
    try testing.expectEqualStrings("check24", r.workspace);
    try testing.expectEqual(@as(u64, 9), r.id);
}

test "a schemeless paste is rejected (std.Uri requires a scheme)" {
    // PR URLs people copy always carry https://; a bare host does not parse.
    try testing.expectError(error.MalformedUrl, parse("bitbucket.org/check24/pr-webapp/pull-requests/9"));
}
