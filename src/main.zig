//! bbr entry point. Zig 0.16 hands `main` an `Init` carrying `gpa`, `arena`,
//! `io` (a `std.Io.Threaded`-backed runtime), `environ_map`, and args — so we do
//! not construct any of that ourselves.
//!
//! Startup resolves what to open (design §startup): a pasted PR URL, an explicit
//! `<repo> <id>`, or auto-detection from the current worktree (the tracking
//! remote + the branch's open PRs). The TUI then loads that PR and lets the
//! reviewer switch with the fuzzy Picker.

const std = @import("std");
const bbr = @import("bbr");
const app = @import("tui/app.zig");
const session = @import("tui/session.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var it = init.minimal.args.iterate();
    _ = it.next(); // executable name
    const first = it.next();

    // `demo` needs no credentials: it feeds synthetic data through the real
    // buffer/renderer so the comment UI can be exercised entirely offline.
    if (first) |f| {
        if (std.mem.eql(u8, f, "demo")) return demoRun(init.io, gpa, init.environ_map);
    }

    const cred = bbr.bitbucket.Credential.fromEnv(init.environ_map) catch |err| {
        std.debug.print("bbr: missing credential: {s}\n{s}\n", .{
            @errorName(err),
            "set BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE",
        });
        return;
    };

    if (first) |f| {
        // Debug aids: dump raw comment JSON (no parsing).
        if (std.mem.eql(u8, f, "raw-comments")) return rawComments(init, gpa, cred, &it);
        if (std.mem.eql(u8, f, "raw-comment")) return rawComment(init, gpa, cred, &it);
        // Live smoke test: fetch + print, no TUI (scriptable, exits non-zero on failure).
        if (std.mem.eql(u8, f, "check")) return checkRun(init, gpa, cred, &it);
        // Print startup resolution (branch/remote/PR list) without the TUI.
        if (std.mem.eql(u8, f, "detect")) return detectRun(init, gpa, cred, &it);
    }

    // Build the startup input from the remaining args: a URL, an explicit
    // `<repo> <id>`, a bare `<repo>` (detect within it), or nothing (detect all).
    var input: bbr.startup.Input = .{};
    if (first) |f| {
        if (looksLikeUrl(f)) {
            input = .{ .url = f };
        } else if (it.next()) |second| {
            input = .{ .repo_slug = f, .id = std.fmt.parseInt(u64, second, 10) catch return usage() };
        } else {
            input = .{ .repo_slug = f };
        }
    }

    try openTui(init, gpa, cred, input);
}

/// Resolve the startup entry and hand off to the TUI. Uses a real GitClient and
/// a StdHttpClient for resolution; the loaded PR (and any switch) get their own
/// clients inside `app.run`.
fn openTui(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, input: bbr.startup.Input) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var git = bbr.git.ShellGitClient.init(gpa, init.io);

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(a, init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const entry = bbr.startup.resolve(a, git.gitClient(), bb, input) catch |err| {
        std.debug.print("bbr: could not resolve a PR to open: {s}\n", .{@errorName(err)});
        return;
    };

    // The repo and the id to open. A picker/empty result has no single id, so we
    // fall back to the first listed PR (the reviewer switches with `p`).
    const target: struct { repo: []const u8, id: u64 } = switch (entry) {
        .open => |t| .{ .repo = t.repo_slug, .id = t.id },
        .pick => |p| blk: {
            if (p.prs.len == 0) break :blk .{ .repo = p.repo_slug, .id = 0 };
            std.debug.print("bbr: {d} open PRs; opening #{d}. Press 'p' to switch.\n", .{ p.prs.len, p.prs[0].id });
            break :blk .{ .repo = p.repo_slug, .id = p.prs[0].id };
        },
        .empty => |repo| {
            std.debug.print("bbr: no open pull requests in {s}.\n", .{repo});
            return;
        },
    };

    // Load the initial session (blocking, on the main thread). It — and any PR
    // switched to later — is backed by the page allocator so `app.run` can
    // destroy it uniformly and worker threads can allocate without racing.
    const initial = session.load(init.io, std.heap.page_allocator, init.environ_map, cred, target.repo, target.id) catch |err| {
        std.debug.print("bbr: failed to load PR #{d} in {s}: {s}\n", .{ target.id, target.repo, @errorName(err) });
        return;
    };

    // `repo` must outlive the TUI (worker loads copy it), so dupe it into a
    // buffer the run owns via the session-independent gpa arena above… but that
    // arena is freed on return. Copy into a stable stack buffer instead.
    var repo_buf: [256]u8 = undefined;
    const repo_len = @min(target.repo.len, repo_buf.len);
    @memcpy(repo_buf[0..repo_len], target.repo[0..repo_len]);

    try app.run(.{
        .io = init.io,
        .gpa = gpa,
        .env_map = init.environ_map,
        .cred = cred,
        .repo = repo_buf[0..repo_len],
    }, initial);
}

fn looksLikeUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or
        std.mem.startsWith(u8, s, "https://") or
        std.mem.indexOf(u8, s, "bitbucket.org") != null;
}

fn rawComments(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    const repo = it.next() orelse return usage();
    const pr_id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const raw = try bb.getCommentsRaw(gpa, repo, pr_id);
    defer gpa.free(raw);
    std.debug.print("{s}\n", .{raw});
}

fn rawComment(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    const repo = it.next() orelse return usage();
    const pr_id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();
    const cid = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const raw = try bb.getCommentRaw(gpa, repo, pr_id, cid);
    defer gpa.free(raw);
    std.debug.print("{s}\n", .{raw});
}

fn checkRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    const repo = it.next() orelse return usage();
    const id = std.fmt.parseInt(u64, it.next() orelse return usage(), 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const pr = try bb.getPullRequest(gpa, repo, id);
    defer bbr.bitbucket.deinitPullRequest(gpa, pr);

    std.debug.print(
        "ok: fetched PR from Bitbucket\n#{d} [{s}] {s}\n  author: {s}\n  {s} -> {s}\n",
        .{ pr.id, pr.state, pr.title, pr.author_display_name, pr.source_branch, pr.destination_branch },
    );

    // Also fetch comments and summarize, so a real run confirms the live JSON
    // shape parses (esp. the inline/outdated fields we couldn't verify offline).
    var carena = std.heap.ArenaAllocator.init(gpa);
    defer carena.deinit();
    const comments = try bb.getComments(carena.allocator(), repo, id, .{
        .source = pr.source_commit,
        .destination = pr.destination_commit,
    });
    const threads = try bbr.review.buildThreads(carena.allocator(), comments);

    var inline_n: usize = 0;
    var resolved_n: usize = 0;
    var outdated_n: usize = 0;
    for (threads) |t| {
        if (t.isInline()) inline_n += 1;
        if (t.resolved) resolved_n += 1;
        if (t.root.state == .outdated) outdated_n += 1;
    }
    std.debug.print(
        "  comments: {d} in {d} threads ({d} inline, {d} resolved, {d} outdated)\n",
        .{ comments.len, threads.len, inline_n, resolved_n, outdated_n },
    );
    if (threads.len > 0) {
        const t = threads[0];
        const anc: []const u8 = if (t.root.anchor) |x| x.path else "(PR-level)";
        std.debug.print("  first thread: {s} on {s} — \"{s}\" (+{d} replies)\n", .{
            t.root.author, anc, firstLine(t.root.body), t.replies.len,
        });
    }
}

/// `detect [<repo>]`: run startup resolution and print the outcome, no TUI. A
/// scriptable way to verify the GitClient + list pipeline against live data.
fn detectRun(init: std.process.Init, gpa: std.mem.Allocator, cred: bbr.bitbucket.Credential, it: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var input: bbr.startup.Input = .{};
    if (it.next()) |repo| input = .{ .repo_slug = repo };

    var git = bbr.git.ShellGitClient.init(gpa, init.io);

    // Report what the GitClient sees, so a failed detect is diagnosable.
    if (git.gitClient().currentBranch(a)) |b| {
        std.debug.print("branch: {s}\n", .{b});
    } else |err| std.debug.print("branch: <{s}>\n", .{@errorName(err)});
    if (git.gitClient().remote(a)) |r| {
        std.debug.print("remote: {s}/{s}\n", .{ r.workspace, r.repo_slug });
    } else |err| std.debug.print("remote: <{s}>\n", .{@errorName(err)});

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(a, init.environ_map);
    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);

    const entry = try bbr.startup.resolve(a, git.gitClient(), bb, input);
    switch (entry) {
        .open => |t| std.debug.print("resolved: open {s} #{d}\n", .{ t.repo_slug, t.id }),
        .pick => |p| {
            std.debug.print("resolved: pick {s} ({s}, {d} PRs)\n", .{
                p.repo_slug, if (p.prefiltered) "branch-filtered" else "all open", p.prs.len,
            });
            for (p.prs, 0..) |pr, i| {
                if (i == 10) {
                    std.debug.print("  … and {d} more\n", .{p.prs.len - 10});
                    break;
                }
                std.debug.print("  #{d} {s} ({s} → {s})\n", .{ pr.id, pr.title, pr.source_branch, pr.destination_branch });
            }
        },
        .empty => |repo| std.debug.print("resolved: no open PRs in {s}\n", .{repo}),
    }
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  bbr                              auto-detect the PR for the current branch
        \\  bbr <pr-url>                     open a pasted Bitbucket PR URL
        \\  bbr <repo-slug>                  detect the current branch's PR in <repo>
        \\  bbr <repo-slug> <pr-id>          open a specific PR in the TUI
        \\  bbr check <repo-slug> <pr-id>    live smoke check (fetch + print, no TUI)
        \\  bbr demo                         open the TUI with synthetic data (no network)
        \\
        \\Everything but `demo` needs BITBUCKET_USERNAME, BITBUCKET_TOKEN,
        \\BITBUCKET_WORKSPACE in the environment.
        \\
    , .{});
}

/// First line of a string (up to the first newline). Borrows the input.
fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s[0..nl] else s;
}

/// A synthetic diff exercising every comment render path — no credentials, no
/// network. Line numbering matters: comments anchor to new lines that exist.
const demo_diff =
    \\diff --git a/src/server.zig b/src/server.zig
    \\--- a/src/server.zig
    \\+++ b/src/server.zig
    \\@@ -10,4 +10,4 @@ pub fn listen() !void {
    \\     const port = 8080;
    \\-    const timeout = 30;
    \\+    const timeout = 60;
    \\     try bind(port);
    \\     log("listening");
    \\diff --git a/README.md b/README.md
    \\--- a/README.md
    \\+++ b/README.md
    \\@@ -1,2 +1,2 @@
    \\-# webapp
    \\+# pr-webapp
    \\ A small demo service.
    \\
;

/// Run the TUI against `demo_diff` and a hand-built set of threads covering:
/// a PR-level comment, an inline root + reply, a suggestion, a resolved thread
/// (hidden until `R`), and an outdated thread (in the per-file section). The
/// Picker is disabled (`online = false`): there is no repo to list.
fn demoRun(io: std.Io, gpa: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    // Build the session on the page allocator so app.run can destroy it uniformly.
    const s = try session.create(std.heap.page_allocator);
    const a = s.arena.allocator();

    s.diff = try bbr.diff.parse(a, demo_diff);

    const path = "src/server.zig";
    const comments = try a.dupe(bbr.review.Comment, &.{
        .{ .id = 1, .author = "Reviewer", .body = "Thanks — one question and a nit below." },
        .{ .id = 2, .author = "Reviewer", .body = "Why 60 specifically? A named const would read better.", .anchor = .{ .path = path, .to = 11 } },
        .{ .id = 3, .parent_id = 2, .author = "Author", .body = "Fair — see suggestion." },
        .{ .id = 4, .parent_id = 2, .author = "Author", .body = "```suggestion\n    const timeout_s = 60;\n```" },
        .{ .id = 5, .author = "Reviewer", .body = "spacing here is off", .resolved = true, .anchor = .{ .path = path, .to = 13 } },
        .{ .id = 6, .parent_id = 5, .author = "Author", .body = "fixed, thanks" },
        .{ .id = 7, .author = "Reviewer", .body = "this note pointed at code that no longer exists", .state = .outdated, .anchor = .{ .path = path, .from = 99 } },
    });
    s.threads = try bbr.review.buildThreads(a, comments);

    s.pr = .{
        .id = 1799,
        .title = "Demo: raise handler timeout",
        .state = "OPEN",
        .author_display_name = "Author",
        .source_branch = "feature/timeout",
        .destination_branch = "main",
        .source_commit = "democ0ffee",
        .destination_commit = "demodeadbeef",
    };

    try app.run(.{
        .io = io,
        .gpa = gpa,
        .env_map = env_map,
        .cred = .{ .username = "", .token = "", .workspace = "" },
        .repo = "",
        .online = false,
    }, s);
}

// Test discovery only follows `_ = @import(...)` chains rooted in the *test
// root* file's test blocks. This block roots the exe module's TUI test tree
// (app → render → theme → nav → picker → session); the core `bbr` module's
// tests run via src/root.zig.
test {
    _ = @import("tui/app.zig");
}

// The demo is our offline validation surface, so guard that its synthetic data
// actually weaves as intended: anchors land on real lines, the suggestion is
// detected, resolved threads hide, and the outdated one groups per file.
test "demo data weaves through the real pipeline" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try bbr.diff.parse(a, demo_diff);
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Reviewer", .body = "PR-level note." },
        .{ .id = 2, .author = "Reviewer", .body = "Why 60?", .anchor = .{ .path = "src/server.zig", .to = 11 } },
        .{ .id = 4, .parent_id = 2, .author = "Author", .body = "```suggestion\n    const timeout_s = 60;\n```" },
        .{ .id = 5, .author = "Reviewer", .body = "nit", .resolved = true, .anchor = .{ .path = "src/server.zig", .to = 13 } },
        .{ .id = 7, .author = "Reviewer", .body = "stale", .state = .outdated, .anchor = .{ .path = "src/server.zig", .from = 99 } },
    };
    const threads = try bbr.review.buildThreads(a, &comments);

    // The inline suggestion is detected on comment #4.
    try testing.expect(comments[2].suggestion() != null);

    // Hidden: the resolved thread contributes no comment rows.
    const hidden = try bbr.diff.buffer.buildWithComments(a, diff, .unified, threads, .{});
    var hidden_comments: usize = 0;
    var outdated_sections: usize = 0;
    for (hidden.rows) |r| {
        if (r == .comment) hidden_comments += 1;
        if (r == .section and r.section.kind == .outdated) outdated_sections += 1;
    }
    // PR-level (#1) + inline root (#2) + suggestion reply (#4) + outdated (#7) = 4;
    // resolved #5 hidden.
    try testing.expectEqual(@as(usize, 4), hidden_comments);
    try testing.expectEqual(@as(usize, 1), outdated_sections);

    // Revealed: the resolved thread's root now appears too.
    const shown = try bbr.diff.buffer.buildWithComments(a, diff, .unified, threads, .{ .show_resolved = true });
    var shown_comments: usize = 0;
    for (shown.rows) |r| {
        if (r == .comment) shown_comments += 1;
    }
    try testing.expectEqual(@as(usize, 5), shown_comments);
}
