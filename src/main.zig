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

    const cred = bbr.bitbucket.Credential.fromEnv(init.environ_map) catch |err| {
        std.debug.print("bbr: missing credential: {s}\n{s}\n", .{
            @errorName(err),
            "set BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE",
        });
        return;
    };

    var it = init.minimal.args.iterate();
    _ = it.next(); // executable name
    var first = it.next() orelse return usage();

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
        return;
    }

    // Fetch and parse the diff into a session-lived arena. The parsed `Diff`
    // borrows this raw text, so the arena must outlive the TUI.
    var diff_arena = std.heap.ArenaAllocator.init(gpa);
    defer diff_arena.deinit();
    const raw_diff = try bb.getDiff(diff_arena.allocator(), repo, id);
    const diff = try bbr.diff.parse(diff_arena.allocator(), raw_diff);

    try app.run(init.io, gpa, init.environ_map, pr, diff);
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  bbr <repo-slug> <pr-id>          open the PR in the TUI
        \\  bbr check <repo-slug> <pr-id>    live smoke check (fetch + print, no TUI)
        \\
        \\requires BITBUCKET_USERNAME, BITBUCKET_TOKEN, BITBUCKET_WORKSPACE in the environment.
        \\
    , .{});
}

// Test discovery only follows `_ = @import(...)` chains rooted in the *test
// root* file's test blocks — merely calling `app.run` above pulls app's code
// but NOT its tests. This block roots the exe module's TUI test tree (app →
// render → theme → nav); the core `bbr` module's tests run via src/root.zig.
test {
    _ = @import("tui/app.zig");
}
