const std = @import("std");
const presentation = @import("tui/presentation.zig");
const render = @import("tui/render.zig");
const vaxis = @import("vaxis");

var screen: vaxis.Screen = undefined;

fn paint(allocator: std.mem.Allocator, review: presentation.ReviewProjection) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    render.drawReview(arena.allocator(), window, review, @import("tui/theme.zig").dark, 0);
}

pub fn main(init: std.process.Init) !void {
    screen = try vaxis.Screen.init(init.gpa, .{ .rows = 30, .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(init.gpa);
    try presentation.benchmarkBufferSearch(init.gpa, init.io, paint);
}
