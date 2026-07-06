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
