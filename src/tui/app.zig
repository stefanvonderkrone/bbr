//! M0 TUI: boot vaxis on the alt-screen, render one PR's header, quit on `q`
//! or ctrl-c. vaxis 0.16 threads the runtime's `Io` and `Environ.Map` through
//! `init`, matching what `std.process.Init` hands `main`.
//!
//! Lifetime note: vaxis cells hold a *borrowed* grapheme slice, so any text
//! passed to `printSegment` must stay valid until `render`. We keep each line's
//! buffer in scope for the whole draw+render.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const PullRequest = bbr.bitbucket.PullRequest;

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    pr: PullRequest,
) !void {
    var write_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &write_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, env_map, .{});
    defer vx.deinit(gpa, writer);

    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try loop.installResizeHandler();
    try vx.enterAltScreen(writer);

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;
            },
            .winsize => |ws| try vx.resize(gpa, writer, ws),
            else => {},
        }

        // One buffer per line — all must outlive render() (cells borrow the text).
        var l0: [512]u8 = undefined;
        var l1: [256]u8 = undefined;
        var l2: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&l0, "#{d} [{s}] {s}", .{ pr.id, pr.state, pr.title }) catch pr.title;
        const author = std.fmt.bufPrint(&l1, "author: {s}", .{pr.author_display_name}) catch "";
        const branches = std.fmt.bufPrint(&l2, "{s} -> {s}", .{ pr.source_branch, pr.destination_branch }) catch "";

        const win = vx.window();
        win.clear();
        _ = win.printSegment(.{ .text = title, .style = .{ .bold = true } }, .{ .row_offset = 0 });
        _ = win.printSegment(.{ .text = author }, .{ .row_offset = 2 });
        _ = win.printSegment(.{ .text = branches }, .{ .row_offset = 3 });
        _ = win.printSegment(.{ .text = "press q to quit" }, .{ .row_offset = 5 });
        try vx.render(writer);
    }
}
