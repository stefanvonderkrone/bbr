//! Theme — the palette the renderer consults for every cell. Presentation owns
//! it (it speaks in vaxis styles). One `dark` default ships now; selectable
//! themes (catppuccin / gruvbox / solarized / light) are M9.
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
    /// The line-number gutter.
    gutter: Style,
    /// `diff --git` file separator rows.
    file_header: Style,
    /// `@@ … @@` hunk headers.
    hunk_header: Style,
    /// A file row in the sidebar.
    sidebar_item: Style,
    /// The currently selected sidebar file.
    sidebar_selected: Style,

    /// Style for a diff body line of the given kind.
    pub fn lineStyle(self: Theme, kind: LineKind) Style {
        return switch (kind) {
            .context => self.context,
            .added => self.added,
            .removed => self.removed,
        };
    }
};

fn rgb(hex: u24) Color {
    return Color.rgbFromUint(hex);
}

/// The default dark theme. Backgrounds are muted so foreground text stays
/// readable; foregrounds are left `default` except where contrast needs it.
pub const dark: Theme = .{
    .context = .{},
    .added = .{ .bg = rgb(0x18_32_18) },
    .removed = .{ .bg = rgb(0x3a_18_18) },
    .gutter = .{ .fg = rgb(0x80_80_80) },
    .file_header = .{ .fg = rgb(0xd0_d0_d0), .bold = true },
    .hunk_header = .{ .fg = rgb(0x6c_9c_d0) },
    .sidebar_item = .{},
    .sidebar_selected = .{ .bg = rgb(0x30_30_40), .bold = true },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "lineStyle maps each kind to its band" {
    try testing.expect(dark.lineStyle(.context).bg == .default);
    try testing.expectEqual(dark.added.bg, dark.lineStyle(.added).bg);
    try testing.expectEqual(dark.removed.bg, dark.lineStyle(.removed).bg);
    // added and removed are distinguishable bands.
    try testing.expect(!std.meta.eql(dark.added.bg, dark.removed.bg));
}
