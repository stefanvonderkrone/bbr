//! Theme — the palette the renderer consults for every cell. Presentation owns
//! it (it speaks in vaxis styles). One `dark` default ships now; selectable
//! themes (catppuccin / gruvbox / solarized / light) are M11.
//!
//! Diff lines get the classic neutral / green / red *backgrounds* (design §2),
//! so the emphasis reads as bands across the pane, not just colored text.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const LineKind = bbr.diff.LineKind;
const Style = vaxis.Style;
const Color = vaxis.Cell.Color;

pub const Theme = struct {
    /// Unchanged lines — terminal default background.
    context: Style,
    /// Added lines — green band.
    added: Style,
    /// Removed lines — red band.
    removed: Style,
    /// The changed run *within* an added line — a brighter green band.
    added_emphasis: Style,
    /// The changed run *within* a removed line — a brighter red band.
    removed_emphasis: Style,
    /// The line-number gutter.
    gutter: Style,
    /// Background for the line under the cursor when it has no diff band (a
    /// context/neutral row): the TUI "cursorline" tint.
    cursor_line: Color,
    /// Signed per-channel nudge applied to a row that *does* carry an rgb band
    /// (added/removed/comment/…) when it's under the cursor, so the band color is
    /// preserved but the row still reads as current. Positive lightens (a dark
    /// theme); a light theme would use a negative value.
    cursor_line_shift: i16,
    /// `diff --git` file separator rows.
    file_header: Style,
    /// `@@ … @@` hunk headers.
    hunk_header: Style,
    /// A collapsed-context fold row ("⋯ N unchanged lines ⋯").
    fold: Style,
    /// A file row in the sidebar.
    sidebar_item: Style,
    /// The currently selected sidebar file.
    sidebar_selected: Style,
    /// File-list name color for an added file (green).
    status_added: Color,
    /// File-list name color for a modified file (yellow).
    status_modified: Color,
    /// File-list name color for a removed file (red).
    status_removed: Color,
    /// File-list name color for a renamed file (violet).
    status_renamed: Color,
    /// A woven comment (root).
    comment: Style,
    /// A reply, indented under its root.
    comment_reply: Style,
    /// A ```suggestion block, called out distinctly.
    suggestion: Style,
    /// A section divider (PR comments / Outdated).
    section: Style,
    /// The PR picker overlay's background rows.
    picker: Style,
    /// The picker's highlighted (selected) row.
    picker_selected: Style,
    /// The picker's query/prompt line.
    picker_query: Style,

    /// Style for a diff body line of the given kind.
    pub fn lineStyle(self: Theme, kind: LineKind) Style {
        return switch (kind) {
            .context => self.context,
            .added => self.added,
            .removed => self.removed,
        };
    }

    /// Style for the emphasized (changed) run within an added/removed line.
    /// Context lines have no emphasis, so they fall back to their base band.
    pub fn emphasisStyle(self: Theme, kind: LineKind) Style {
        return switch (kind) {
            .context => self.context,
            .added => self.added_emphasis,
            .removed => self.removed_emphasis,
        };
    }

    /// Highlighted background for a cell on the cursor row. A cell with an rgb
    /// background (a diff band) keeps its hue, nudged by `cursor_line_shift`; a
    /// cell on the terminal-default (or palette) background takes `cursor_line`.
    pub fn cursorBg(self: Theme, base: Color) Color {
        return switch (base) {
            .rgb => |ch| .{ .rgb = .{
                shiftChannel(ch[0], self.cursor_line_shift),
                shiftChannel(ch[1], self.cursor_line_shift),
                shiftChannel(ch[2], self.cursor_line_shift),
            } },
            else => self.cursor_line,
        };
    }

    /// File-list name color for a change status: green add, yellow modify, red
    /// remove, violet rename.
    pub fn statusColor(self: Theme, status: bbr.diff.FileStatus) Color {
        return switch (status) {
            .added => self.status_added,
            .modified => self.status_modified,
            .removed => self.status_removed,
            .renamed => self.status_renamed,
        };
    }
};

fn rgb(hex: u24) Color {
    return Color.rgbFromUint(hex);
}

/// Nudge one 0–255 channel by a signed delta, clamped to the byte range.
fn shiftChannel(v: u8, delta: i16) u8 {
    return @intCast(std.math.clamp(@as(i16, v) + delta, 0, 255));
}

/// The default dark theme. Backgrounds are muted so foreground text stays
/// readable; foregrounds are left `default` except where contrast needs it.
pub const dark: Theme = .{
    .context = .{},
    .added = .{ .bg = rgb(0x18_32_18) },
    .removed = .{ .bg = rgb(0x3a_18_18) },
    .added_emphasis = .{ .bg = rgb(0x2c_5c_2c) },
    .removed_emphasis = .{ .bg = rgb(0x6c_28_28) },
    .gutter = .{ .fg = rgb(0x80_80_80) },
    .cursor_line = rgb(0x2c_2c_38),
    .cursor_line_shift = 0x1c,
    .file_header = .{ .fg = rgb(0xd0_d0_d0), .bold = true },
    .hunk_header = .{ .fg = rgb(0x6c_9c_d0) },
    .fold = .{ .fg = rgb(0x70_70_80), .bg = rgb(0x1a_1a_22) },
    .sidebar_item = .{},
    .sidebar_selected = .{ .bg = rgb(0x30_30_40), .bold = true },
    .status_added = rgb(0x8c_c8_5a),
    .status_modified = rgb(0xd7_af_5f),
    .status_removed = rgb(0xd0_6c_6c),
    .status_renamed = rgb(0xb0_88_e0),
    .comment = .{ .bg = rgb(0x1c_1c_28), .fg = rgb(0xc8_c8_d8) },
    .comment_reply = .{ .bg = rgb(0x18_18_22), .fg = rgb(0xb0_b0_c0) },
    .suggestion = .{ .bg = rgb(0x14_28_28), .fg = rgb(0x9c_d0_c0) },
    .section = .{ .fg = rgb(0x88_88_a0), .bold = true },
    .picker = .{ .bg = rgb(0x20_20_2c), .fg = rgb(0xc8_c8_d8) },
    .picker_selected = .{ .bg = rgb(0x3a_3a_52), .fg = rgb(0xff_ff_ff), .bold = true },
    .picker_query = .{ .bg = rgb(0x28_28_36), .fg = rgb(0xff_ff_ff) },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "statusColor maps each change kind to its own color" {
    try testing.expectEqual(dark.status_added, dark.statusColor(.added));
    try testing.expectEqual(dark.status_modified, dark.statusColor(.modified));
    try testing.expectEqual(dark.status_removed, dark.statusColor(.removed));
    try testing.expectEqual(dark.status_renamed, dark.statusColor(.renamed));
    // All four change kinds are visually distinct.
    const colors = [_]Color{ dark.status_added, dark.status_modified, dark.status_removed, dark.status_renamed };
    for (colors, 0..) |c1, i| {
        for (colors[i + 1 ..]) |c2| try testing.expect(!std.meta.eql(c1, c2));
    }
}

test "cursorBg tints a neutral row and nudges a banded one, keeping its hue" {
    // A context/neutral cell (default bg) takes the cursor_line tint outright.
    try testing.expectEqual(dark.cursor_line, dark.cursorBg(.default));

    // A banded (rgb) cell keeps its channels, shifted by cursor_line_shift.
    const added_bg = dark.added.bg; // rgb
    const lit = dark.cursorBg(added_bg);
    try testing.expect(lit == .rgb and added_bg == .rgb);
    // Each channel moved by the shift (all well within range here).
    inline for (0..3) |i| {
        try testing.expectEqual(added_bg.rgb[i] + @as(u8, 0x1c), lit.rgb[i]);
    }
    // Still distinct from the un-highlighted band.
    try testing.expect(!std.meta.eql(added_bg, lit));
}

test "lineStyle maps each kind to its band" {
    try testing.expect(dark.lineStyle(.context).bg == .default);
    try testing.expectEqual(dark.added.bg, dark.lineStyle(.added).bg);
    try testing.expectEqual(dark.removed.bg, dark.lineStyle(.removed).bg);
    // added and removed are distinguishable bands.
    try testing.expect(!std.meta.eql(dark.added.bg, dark.removed.bg));
}
