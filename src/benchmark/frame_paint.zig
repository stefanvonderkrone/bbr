const std = @import("std");
const vaxis = @import("vaxis");

pub const name = "frame_paint_1000_rows";

pub const Context = struct {
    screen: vaxis.Screen,

    pub fn init(allocator: std.mem.Allocator) !Context {
        return .{ .screen = try vaxis.Screen.init(allocator, .{ .rows = 1_000, .cols = 160, .x_pixel = 0, .y_pixel = 0 }) };
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        self.screen.deinit(allocator);
    }
};

pub fn run(_: std.mem.Allocator, context: *Context) !u64 {
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = context.screen.width,
        .height = context.screen.height,
        .screen = &context.screen,
    };
    win.clear();
    for (0..win.height) |row_index| {
        const row: u16 = @intCast(row_index);
        fillRow(win, row, .{ .bg = .{ .index = 2 } });
        drawGutter(win, row, @intCast(row_index + 1));
    }
    return screenChecksum(win);
}

pub fn checksum(output: u64) u64 {
    return output;
}

fn fillRow(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    win.child(.{ .y_off = row, .height = 1 }).fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
}

fn drawGutter(win: vaxis.Window, row: u16, no: u32) void {
    var text: [32]u8 = undefined;
    const gutter = std.fmt.bufPrint(&text, "{d: >4} {d: >4} ", .{ no, no }) catch return;
    for (gutter, 0..) |byte, column| {
        win.writeCell(@intCast(column), row, .{
            .char = .{ .grapheme = digitGlyph(byte), .width = 1 },
            .style = .{ .bg = .{ .index = 2 } },
        });
    }
}

fn digitGlyph(byte: u8) []const u8 {
    return switch (byte) {
        '0' => "0",
        '1' => "1",
        '2' => "2",
        '3' => "3",
        '4' => "4",
        '5' => "5",
        '6' => "6",
        '7' => "7",
        '8' => "8",
        '9' => "9",
        else => " ",
    };
}

fn screenChecksum(win: vaxis.Window) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (0..win.height) |row| {
        for (0..win.width) |column| {
            const cell = win.readCell(@intCast(column), @intCast(row)) orelse continue;
            hash.update(cell.char.grapheme);
            hash.update(std.mem.asBytes(&cell.style));
        }
    }
    return hash.final();
}
