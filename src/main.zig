//! bbr entry point. Zig 0.16 hands `main` an `Init` carrying `gpa`, `arena`,
//! `io` (a `std.Io.Threaded`-backed runtime), `environ_map`, and args — so we do
//! not construct any of that ourselves.
//!
//! M0 walking skeleton: fetch one PR and print its header. The TUI (vaxis) lands
//! next; this proves the credential → HttpClient → Bitbucket path end to end.

const std = @import("std");
const bbr = @import("bbr");
const app = @import("tui/app.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var it = init.minimal.args.iterate();
    _ = it.next(); // executable name
    var first = it.next() orelse return usage();

    // `demo` needs no credentials: it feeds synthetic data through the real
    // buffer/renderer so the comment UI can be exercised entirely offline.
    if (std.mem.eql(u8, first, "demo")) return demoRun(init.io, gpa, init.environ_map);

    const cred = bbr.bitbucket.Credential.fromEnv(init.environ_map) catch |err| {
        std.debug.print("bbr: missing credential: {s}\n{s}\n", .{
            @errorName(err),
            "set BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE",
        });
        return;
    };

    // `check` is a live smoke test: fetch and print, no TUI. Exits non-zero on
    // any failure (missing creds, network, HTTP status), so it is scriptable.
    const check_mode = std.mem.eql(u8, first, "check");
    if (check_mode) first = it.next() orelse return usage();

    const repo = first;
    const id_str = it.next() orelse return usage();
    const id = std.fmt.parseInt(u64, id_str, 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);
    const pr = try bb.getPullRequest(gpa, repo, id);
    defer bbr.bitbucket.deinitPullRequest(gpa, pr);

    if (check_mode) {
        std.debug.print(
            "ok: fetched PR from Bitbucket\n#{d} [{s}] {s}\n  author: {s}\n  {s} -> {s}\n",
            .{ pr.id, pr.state, pr.title, pr.author_display_name, pr.source_branch, pr.destination_branch },
        );

        // Also fetch comments and summarize, so a real run confirms the live
        // JSON shape parses (esp. the inline/outdated fields we couldn't verify
        // against the API offline).
        var carena = std.heap.ArenaAllocator.init(gpa);
        defer carena.deinit();
        const comments = try bb.getComments(carena.allocator(), repo, id);
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
        return;
    }

    // Fetch and parse the diff into a session-lived arena. The parsed `Diff`
    // borrows this raw text, so the arena must outlive the TUI.
    var diff_arena = std.heap.ArenaAllocator.init(gpa);
    defer diff_arena.deinit();
    const raw_diff = try bb.getDiff(diff_arena.allocator(), repo, id);
    const diff = try bbr.diff.parse(diff_arena.allocator(), raw_diff);

    // Comments and their threads live in the same PR-scoped arena (the rows woven
    // into the buffer borrow both the comments and the diff).
    const comments = try bb.getComments(diff_arena.allocator(), repo, id);
    const threads = try bbr.review.buildThreads(diff_arena.allocator(), comments);

    try app.run(init.io, gpa, init.environ_map, pr, diff, threads);
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  bbr <repo-slug> <pr-id>          open the PR in the TUI
        \\  bbr check <repo-slug> <pr-id>    live smoke check (fetch + print, no TUI)
        \\  bbr demo                         open the TUI with synthetic data (no network)
        \\
        \\<repo-slug>/<pr-id> require BITBUCKET_USERNAME, BITBUCKET_TOKEN,
        \\BITBUCKET_WORKSPACE in the environment; `demo` requires nothing.
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
/// (hidden until `R`), and an outdated thread (in the per-file section).
fn demoRun(io: std.Io, gpa: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const diff = try bbr.diff.parse(a, demo_diff);

    const path = "src/server.zig";
    const comments = [_]bbr.review.Comment{
        .{ .id = 1, .author = "Reviewer", .body = "Thanks — one question and a nit below." },
        .{ .id = 2, .author = "Reviewer", .body = "Why 60 specifically? A named const would read better.", .anchor = .{ .path = path, .to = 11 } },
        .{ .id = 3, .parent_id = 2, .author = "Author", .body = "Fair — see suggestion." },
        .{ .id = 4, .parent_id = 2, .author = "Author", .body = "```suggestion\n    const timeout_s = 60;\n```" },
        .{ .id = 5, .author = "Reviewer", .body = "spacing here is off", .resolved = true, .anchor = .{ .path = path, .to = 13 } },
        .{ .id = 6, .parent_id = 5, .author = "Author", .body = "fixed, thanks" },
        .{ .id = 7, .author = "Reviewer", .body = "this note pointed at code that no longer exists", .state = .outdated, .anchor = .{ .path = path, .from = 99 } },
    };
    const threads = try bbr.review.buildThreads(a, &comments);

    const pr: bbr.bitbucket.PullRequest = .{
        .id = 1799,
        .title = "Demo: raise handler timeout",
        .state = "OPEN",
        .author_display_name = "Author",
        .source_branch = "feature/timeout",
        .destination_branch = "main",
    };

    try app.run(io, gpa, env_map, pr, diff, threads);
}

// Test discovery only follows `_ = @import(...)` chains rooted in the *test
// root* file's test blocks — merely calling `app.run` above pulls app's code
// but NOT its tests. This block roots the exe module's TUI test tree (app →
// render → theme → nav); the core `bbr` module's tests run via src/root.zig.
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
