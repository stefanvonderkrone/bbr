//! Parsing a git remote URL into a Bitbucket `(workspace, repo_slug)`. Pure and
//! allocation-free: every field borrows the input URL. Handles both remote
//! forms Bitbucket serves and this machine's `url.insteadof` rewrites.
//!
//! See `src/git/CONTEXT.md` (Remote) for the ubiquitous language.

const std = @import("std");

/// A tracking remote resolved to the two path segments the Bitbucket API needs.
/// Both slices borrow the URL passed to `parse`.
pub const Remote = struct {
    workspace: []const u8,
    repo_slug: []const u8,
};

pub const ParseError = error{
    /// The URL's host is not Bitbucket Cloud (after applying rewrites).
    NotBitbucket,
    /// The URL has no recognizable `workspace/repo` tail.
    MalformedUrl,
};

/// One `git config url.<base>.insteadOf <alias>` rewrite. Git replaces a leading
/// `alias` with `base` before using the URL; we apply the same so an aliased
/// remote (e.g. `bb:ws/repo`) still resolves to its real Bitbucket host.
pub const Rewrite = struct {
    /// The configured shorthand that appears at the start of a raw remote URL.
    alias: []const u8,
    /// What the alias expands to — carries the real scheme/host.
    base: []const u8,
};

/// Normalize a generic Git remote to credential-free `host/path` identity.
/// Transport spelling and a matching `url.*.insteadOf` prefix do not affect
/// the result. The returned bytes are owned by `allocator`.
pub fn normalize(allocator: std.mem.Allocator, url: []const u8, rewrites: []const Rewrite) ![]u8 {
    var effective = url;
    var expanded: ?[]u8 = null;
    defer if (expanded) |bytes| allocator.free(bytes);
    var best: ?Rewrite = null;
    for (rewrites) |rewrite| {
        if (!std.mem.startsWith(u8, url, rewrite.alias)) continue;
        if (best == null or rewrite.alias.len > best.?.alias.len) best = rewrite;
    }
    if (best) |rewrite| {
        expanded = try std.mem.concat(allocator, u8, &.{ rewrite.base, url[rewrite.alias.len..] });
        effective = expanded.?;
    }

    if (std.mem.startsWith(u8, effective, "file://")) {
        return normalizeFileRemote(allocator, effective["file://".len..]);
    }
    if (std.mem.startsWith(u8, effective, "/")) return normalizeFileRemote(allocator, effective);

    var host_part: []const u8 = "";
    var path_part: []const u8 = "";
    if (std.mem.indexOf(u8, effective, "://")) |scheme| {
        const authority_path = effective[scheme + 3 ..];
        const slash = std.mem.indexOfScalar(u8, authority_path, '/') orelse return error.MalformedUrl;
        var authority = authority_path[0..slash];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        host_part = authority;
        path_part = authority_path[slash + 1 ..];
    } else if (std.mem.indexOfScalar(u8, effective, ':')) |colon| {
        var authority = effective[0..colon];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        host_part = authority;
        path_part = effective[colon + 1 ..];
    } else return error.MalformedUrl;
    if (host_part.len == 0 or path_part.len == 0) return error.MalformedUrl;
    if (std.mem.indexOfAny(u8, path_part, "?#")) |end| path_part = path_part[0..end];
    while (std.mem.endsWith(u8, path_part, "/")) path_part = path_part[0 .. path_part.len - 1];
    if (std.mem.endsWith(u8, path_part, ".git")) path_part = path_part[0 .. path_part.len - 4];
    while (std.mem.startsWith(u8, path_part, "/")) path_part = path_part[1..];
    if (path_part.len == 0) return error.MalformedUrl;

    const normalized = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ host_part, path_part });
    for (normalized[0..host_part.len]) |*byte| byte.* = std.ascii.toLower(byte.*);
    return normalized;
}

fn normalizeFileRemote(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, input, "/")) return error.MalformedUrl;
    var path = input;
    while (path.len > 1 and std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    if (path.len == 0) return error.MalformedUrl;
    return std.fmt.allocPrint(allocator, "file:{s}", .{path});
}

const host = "bitbucket.org";

/// Parse `url` into a `Remote`. `rewrites` are applied longest-alias-first (as
/// git does) purely to recover the real host for validation; the `workspace`
/// and `repo_slug` tail is a suffix untouched by any prefix rewrite, so it is
/// always extracted from `url` directly.
pub fn parse(url: []const u8, rewrites: []const Rewrite) ParseError!Remote {
    // The rule (if any) whose alias is the longest prefix of `url` supplies the
    // effective host. With no match, the URL carries its own host.
    var host_source = url;
    var best_len: usize = 0;
    for (rewrites) |r| {
        if (r.alias.len > best_len and std.mem.startsWith(u8, url, r.alias)) {
            best_len = r.alias.len;
            host_source = r.base;
        }
    }

    if (!hostIsBitbucket(host_source)) return error.NotBitbucket;
    return extractTail(url);
}

/// True if `s` names the Bitbucket Cloud host — either the scp-like `git@host:`
/// form or a `scheme://[user@]host/…` form.
fn hostIsBitbucket(s: []const u8) bool {
    // scp-like: `[user@]host:path`, no `://`. The host ends at the first ':'.
    if (std.mem.indexOf(u8, s, "://") == null) {
        const after_user = if (std.mem.indexOfScalar(u8, s, '@')) |at| s[at + 1 ..] else s;
        const h = if (std.mem.indexOfScalar(u8, after_user, ':')) |c| after_user[0..c] else after_user;
        return hostMatches(h);
    }
    // URL form: take between `://` (past any user@) and the next '/' or ':'.
    const after_scheme = s[std.mem.indexOf(u8, s, "://").? + 3 ..];
    const after_user = if (std.mem.indexOfScalar(u8, after_scheme, '@')) |at| after_scheme[at + 1 ..] else after_scheme;
    const end = std.mem.indexOfAny(u8, after_user, "/:") orelse after_user.len;
    return hostMatches(after_user[0..end]);
}

fn hostMatches(h: []const u8) bool {
    return std.mem.eql(u8, h, host);
}

/// Pull the trailing `workspace/repo` out of a remote URL. The tail is the same
/// whether or not a prefix rewrite applied, so we always read it from `url`.
fn extractTail(url: []const u8) ParseError!Remote {
    var s = url;

    // Drop a `?query` / `#frag` if present (defensive; remotes rarely carry one).
    if (std.mem.indexOfScalar(u8, s, '?')) |q| s = s[0..q];
    if (std.mem.indexOfScalar(u8, s, '#')) |h| s = s[0..h];

    // Trim a trailing slash, then a trailing `.git`.
    if (std.mem.endsWith(u8, s, "/")) s = s[0 .. s.len - 1];
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];

    // repo_slug is the final `/`-delimited segment.
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/') orelse return error.MalformedUrl;
    const repo_slug = s[last_slash + 1 ..];
    if (repo_slug.len == 0) return error.MalformedUrl;

    // workspace is the segment before it, bounded by the previous '/' or the ':'
    // of the scp-like form (whichever is closer to the end).
    const before = s[0..last_slash];
    const prev_slash = std.mem.lastIndexOfScalar(u8, before, '/');
    const colon = std.mem.lastIndexOfScalar(u8, before, ':');
    const start: usize = blk: {
        const a = prev_slash;
        const b = colon;
        if (a == null and b == null) break :blk 0;
        if (a == null) break :blk b.? + 1;
        if (b == null) break :blk a.? + 1;
        break :blk @max(a.?, b.?) + 1;
    };
    const workspace = before[start..];
    if (workspace.len == 0) return error.MalformedUrl;

    return .{ .workspace = workspace, .repo_slug = repo_slug };
}

const testing = std.testing;

fn expectRemote(url: []const u8, ws: []const u8, repo: []const u8) !void {
    const r = try parse(url, &.{});
    try testing.expectEqualStrings(ws, r.workspace);
    try testing.expectEqualStrings(repo, r.repo_slug);
}

test "ssh scp-like form" {
    try expectRemote("git@bitbucket.org:check24/pr-webapp.git", "check24", "pr-webapp");
    try expectRemote("git@bitbucket.org:check24/pr-webapp", "check24", "pr-webapp");
}

test "ssh:// url form" {
    try expectRemote("ssh://git@bitbucket.org/check24/pr-webapp.git", "check24", "pr-webapp");
}

test "https url form, with and without user and .git" {
    try expectRemote("https://user@bitbucket.org/check24/pr-webapp.git", "check24", "pr-webapp");
    try expectRemote("https://bitbucket.org/check24/pr-webapp", "check24", "pr-webapp");
    try expectRemote("https://bitbucket.org/check24/pr-webapp/", "check24", "pr-webapp");
}

test "non-bitbucket host is rejected" {
    try testing.expectError(error.NotBitbucket, parse("git@github.com:foo/bar.git", &.{}));
    try testing.expectError(error.NotBitbucket, parse("https://gitlab.com/foo/bar.git", &.{}));
}

test "insteadof rewrite recovers the real host" {
    const rewrites = [_]Rewrite{
        .{ .alias = "bb:", .base = "git@bitbucket.org:" },
    };
    const r = try parse("bb:check24/pr-webapp.git", &rewrites);
    try testing.expectEqualStrings("check24", r.workspace);
    try testing.expectEqualStrings("pr-webapp", r.repo_slug);
}

test "insteadof picks the longest matching alias" {
    const rewrites = [_]Rewrite{
        .{ .alias = "bb:", .base = "git@example.com:" }, // shorter, wrong host
        .{ .alias = "bb:c24/", .base = "git@bitbucket.org:check24/" }, // longer, right host
    };
    const r = try parse("bb:c24/pr-webapp.git", &rewrites);
    // Host validated via the longer alias's base (bitbucket.org). Tail is the
    // literal suffix of the *original* url: segments `c24` and `pr-webapp`.
    try testing.expectEqualStrings("c24", r.workspace);
    try testing.expectEqualStrings("pr-webapp", r.repo_slug);
}

test "unmatched alias falls through to the url's own host" {
    const rewrites = [_]Rewrite{.{ .alias = "gh:", .base = "git@github.com:" }};
    try expectRemote2("https://bitbucket.org/check24/pr-webapp.git", &rewrites, "check24", "pr-webapp");
}

fn expectRemote2(url: []const u8, rewrites: []const Rewrite, ws: []const u8, repo: []const u8) !void {
    const r = try parse(url, rewrites);
    try testing.expectEqualStrings(ws, r.workspace);
    try testing.expectEqualStrings(repo, r.repo_slug);
}

test "malformed urls" {
    // Missing tail segment.
    try testing.expectError(error.MalformedUrl, parse("git@bitbucket.org:onlyone", &.{}));
    try testing.expectError(error.MalformedUrl, parse("https://bitbucket.org/", &.{}));
}

test "generic normalization collapses transport and strips credentials" {
    const https = try normalize(testing.allocator, "https://user:token@Example.COM/team/repo.git", &.{});
    defer testing.allocator.free(https);
    const ssh = try normalize(testing.allocator, "git@example.com:team/repo.git", &.{});
    defer testing.allocator.free(ssh);
    try testing.expectEqualStrings("example.com/team/repo", https);
    try testing.expectEqualStrings(https, ssh);
}

test "generic normalization applies insteadOf before identifying the host" {
    const normalized = try normalize(testing.allocator, "corp:team/repo.git", &.{.{
        .alias = "corp:",
        .base = "ssh://git@example.com/",
    }});
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings("example.com/team/repo", normalized);
}

test "filesystem normalization accepts stable absolute paths but rejects relative aliases" {
    const absolute = try normalize(testing.allocator, "file:///srv/git/repo.git", &.{});
    defer testing.allocator.free(absolute);
    try testing.expectEqualStrings("file:/srv/git/repo", absolute);
    try testing.expectError(error.MalformedUrl, normalize(testing.allocator, "../repo.git", &.{}));
}
