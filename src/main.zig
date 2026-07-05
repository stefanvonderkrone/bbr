//! bbr entry point. Zig 0.16 hands `main` an `Init` carrying `gpa`, `arena`,
//! `io` (a `std.Io.Threaded`-backed runtime), `environ_map`, and args — so we do
//! not construct any of that ourselves.
//!
//! M0 walking skeleton: fetch one PR and print its header. The TUI (vaxis) lands
//! next; this proves the credential → HttpClient → Bitbucket path end to end.

const std = @import("std");
const bbr = @import("bbr");

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
    const repo = it.next() orelse return usage();
    const id_str = it.next() orelse return usage();
    const id = std.fmt.parseInt(u64, id_str, 10) catch return usage();

    var client = bbr.http.StdHttpClient.init(gpa, init.io);
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    const bb = bbr.bitbucket.Client.init(client.httpClient(), cred);
    const pr = try bb.getPullRequest(gpa, repo, id);
    defer bbr.bitbucket.deinitPullRequest(gpa, pr);

    std.debug.print(
        "#{d} [{s}] {s}\n  {s}\n  {s} -> {s}\n",
        .{ pr.id, pr.state, pr.title, pr.author_display_name, pr.source_branch, pr.destination_branch },
    );
}

fn usage() void {
    std.debug.print("usage: bbr <repo-slug> <pr-id>\n", .{});
}
