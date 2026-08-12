//! Theme — the palette the renderer consults for every cell. Presentation owns
//! it (it speaks in vaxis styles). One `dark` default ships now; selectable
//! themes (catppuccin / gruvbox / solarized / light) are M12.
//!
//! Diff lines get the classic neutral / green / red *backgrounds* (design §2),
//! so the emphasis reads as bands across the pane, not just colored text.

const std = @import("std");
const vaxis = @import("vaxis");
const bbr = @import("bbr");

const LineKind = bbr.diff.LineKind;
const Style = vaxis.Style;
const Color = vaxis.Cell.Color;
const review_card = @import("review_card.zig");

pub const Theme = struct {
    /// Frame-owned Pane and Overlay chrome.
    pane_border: Style = .{ .dim = true },
    pane_border_focused: Style = .{ .bold = true },
    overlay_border: Style = .{ .bold = true },
    overlay_title: Style = .{ .bold = true },
    section_rule: Style = .{ .dim = true },
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
    /// A pending Draft (the reviewer's own unsent comment) — a distinct band so
    /// it never reads as already-published.
    draft: Style,
    /// A reply Draft, indented under whatever it replies to.
    draft_reply: Style,
    /// A Draft whose POST outcome remains unresolved after Duplicate guards.
    outcome_unknown: Style,
    outcome_unknown_reply: Style,
    /// A section divider (PR comments / Pending / Outdated).
    section: Style,
    /// The PR picker overlay's background rows.
    picker: Style,
    /// The picker's highlighted (selected) row.
    picker_selected: Style,
    /// The picker's query/prompt line.
    picker_query: Style,
    /// Syntax foregrounds. Diff and emphasis continue to own backgrounds.
    syntax_comment: Color,
    syntax_string: Color,
    syntax_keyword: Color,
    syntax_function: Color,
    syntax_type: Color,
    syntax_constant: Color,
    syntax_variable: Color,
    syntax_property: Color,
    syntax_punctuation: Color,
    syntax_tag: Color,

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

    /// Compose a ReviewCard surface, semantic part, and inline Markdown marks.
    /// Cursor focus is applied by the renderer last through `cursorBg`.
    pub fn reviewCardStyle(self: Theme, role: review_card.CardRole, part: review_card.Part, marks: review_card.Marks) Style {
        var style = switch (role) {
            .comment => self.comment,
            .comment_reply => self.comment_reply,
            .deleted_comment, .deleted_reply => blk: {
                var deleted = self.section;
                deleted.dim = true;
                break :blk deleted;
            },
            .draft => self.draft,
            .draft_reply => self.draft_reply,
            .outcome_unknown => self.outcome_unknown,
            .outcome_unknown_reply => self.outcome_unknown_reply,
        };
        switch (part) {
            .suggestion_label, .suggestion_body => style = self.suggestion,
            .disclosure_footer => {
                style.fg = self.section.fg;
                style.dim = true;
            },
            .header => style.bold = true,
            .body => {},
        }
        style.italic = style.italic or marks.emphasis;
        style.bold = style.bold or marks.strong;
        if (marks.link_label or marks.link_destination) style.ul_style = .single;
        return style;
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
            .index => |index| switch (index) {
                1 => .{ .index = 9 },
                2 => .{ .index = 10 },
                else => self.cursor_line,
            },
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

    /// Resolve a hierarchical Capture by its general root. Unknown Captures
    /// preserve the line style's existing foreground.
    pub fn captureColor(self: Theme, capture: bbr.highlight.Capture) ?Color {
        const dot = std.mem.indexOfScalar(u8, capture.name, '.') orelse capture.name.len;
        const root = capture.name[0..dot];
        if (std.mem.eql(u8, root, "comment")) return self.syntax_comment;
        if (std.mem.eql(u8, root, "string")) return self.syntax_string;
        if (std.mem.eql(u8, root, "keyword") or std.mem.eql(u8, root, "operator")) return self.syntax_keyword;
        if (std.mem.eql(u8, root, "function") or std.mem.eql(u8, root, "method") or std.mem.eql(u8, root, "constructor")) return self.syntax_function;
        if (std.mem.eql(u8, root, "type")) return self.syntax_type;
        if (std.mem.eql(u8, root, "constant") or std.mem.eql(u8, root, "number") or std.mem.eql(u8, root, "boolean")) return self.syntax_constant;
        if (std.mem.eql(u8, root, "variable") or std.mem.eql(u8, root, "label")) return self.syntax_variable;
        if (std.mem.eql(u8, root, "property") or std.mem.eql(u8, root, "attribute")) return self.syntax_property;
        if (std.mem.eql(u8, root, "punctuation")) return self.syntax_punctuation;
        if (std.mem.eql(u8, root, "tag")) return self.syntax_tag;
        return null;
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
    .pane_border = .{ .fg = rgb(0x70_70_80), .dim = true },
    .pane_border_focused = .{ .fg = rgb(0xd0_d0_d0), .bold = true },
    .overlay_border = .{ .fg = rgb(0xd0_d0_d0), .bold = true },
    .overlay_title = .{ .fg = rgb(0xff_ff_ff), .bold = true },
    .section_rule = .{ .fg = rgb(0x70_70_80), .dim = true },
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
    .draft = .{ .bg = rgb(0x2c_24_10), .fg = rgb(0xe0_c8_88), .bold = true },
    .draft_reply = .{ .bg = rgb(0x24_1e_0c), .fg = rgb(0xc8_b0_78) },
    .outcome_unknown = .{ .bg = rgb(0x5a_30_00), .fg = rgb(0xff_d0_70), .bold = true },
    .outcome_unknown_reply = .{ .bg = rgb(0x46_25_00), .fg = rgb(0xf0_b8_58) },
    .section = .{ .fg = rgb(0x88_88_a0), .bold = true },
    .picker = .{ .bg = rgb(0x20_20_2c), .fg = rgb(0xc8_c8_d8) },
    .picker_selected = .{ .bg = rgb(0x3a_3a_52), .fg = rgb(0xff_ff_ff), .bold = true },
    .picker_query = .{ .bg = rgb(0x28_28_36), .fg = rgb(0xff_ff_ff) },
    .syntax_comment = rgb(0x78_78_78),
    .syntax_string = rgb(0x98_c3_79),
    .syntax_keyword = rgb(0xc5_86_c0),
    .syntax_function = rgb(0x61_af_ef),
    .syntax_type = rgb(0xe5_c0_7b),
    .syntax_constant = rgb(0xd1_9a_66),
    .syntax_variable = rgb(0xd4_d4_d4),
    .syntax_property = rgb(0x9c_dc_fe),
    .syntax_punctuation = rgb(0xab_ab_ab),
    .syntax_tag = rgb(0x56_b6_c2),
};

fn fixedTheme(comptime p: struct { bg: u24, fg: u24, surface: u24, surface2: u24, muted: u24, green: u24, red: u24, yellow: u24, blue: u24, violet: u24, teal: u24, light: bool }) Theme {
    return .{
        .pane_border = .{ .fg = rgb(p.muted), .bg = rgb(p.bg), .dim = true },
        .pane_border_focused = .{ .fg = rgb(p.fg), .bg = rgb(p.bg), .bold = true },
        .overlay_border = .{ .fg = rgb(p.fg), .bg = rgb(p.surface), .bold = true },
        .overlay_title = .{ .fg = rgb(p.fg), .bg = rgb(p.surface2), .bold = true },
        .section_rule = .{ .fg = rgb(p.muted), .bg = rgb(p.bg), .dim = true },
        .context = .{ .fg = rgb(p.fg), .bg = rgb(p.bg) },
        .added = .{ .fg = rgb(p.fg), .bg = rgb(if (p.light) 0xd8_ef_d0 else 0x1f_3a_28) },
        .removed = .{ .fg = rgb(p.fg), .bg = rgb(if (p.light) 0xf4_d4_d4 else 0x45_20_28) },
        .added_emphasis = .{ .fg = rgb(p.fg), .bg = rgb(if (p.light) 0xb8_df_aa else 0x32_5a_3c) },
        .removed_emphasis = .{ .fg = rgb(p.fg), .bg = rgb(if (p.light) 0xe9_b0_b0 else 0x6a_30_3a) },
        .gutter = .{ .fg = rgb(p.muted), .bg = rgb(p.bg) },
        .cursor_line = rgb(p.surface2),
        .cursor_line_shift = if (p.light) -18 else 18,
        .file_header = .{ .fg = rgb(p.fg), .bg = rgb(p.bg), .bold = true },
        .hunk_header = .{ .fg = rgb(p.blue), .bg = rgb(p.bg) },
        .fold = .{ .fg = rgb(p.muted), .bg = rgb(p.surface) },
        .sidebar_item = .{ .fg = rgb(p.fg), .bg = rgb(p.bg) },
        .sidebar_selected = .{ .fg = rgb(p.fg), .bg = rgb(p.surface2), .bold = true },
        .status_added = rgb(p.green),
        .status_modified = rgb(p.yellow),
        .status_removed = rgb(p.red),
        .status_renamed = rgb(p.violet),
        .comment = .{ .fg = rgb(p.fg), .bg = rgb(p.surface) },
        .comment_reply = .{ .fg = rgb(p.muted), .bg = rgb(p.surface) },
        .suggestion = .{ .fg = rgb(p.teal), .bg = rgb(p.surface) },
        .draft = .{ .fg = rgb(p.yellow), .bg = rgb(p.surface), .bold = true },
        .draft_reply = .{ .fg = rgb(p.yellow), .bg = rgb(p.surface) },
        .outcome_unknown = .{ .fg = rgb(p.fg), .bg = rgb(if (p.light) 0xff_e0_a3 else 0x5a_30_00), .bold = true },
        .outcome_unknown_reply = .{ .fg = rgb(p.fg), .bg = rgb(if (p.light) 0xff_e9_bd else 0x46_25_00) },
        .section = .{ .fg = rgb(p.muted), .bg = rgb(p.bg), .bold = true },
        .picker = .{ .fg = rgb(p.fg), .bg = rgb(p.surface) },
        .picker_selected = .{ .fg = rgb(p.fg), .bg = rgb(p.surface2), .bold = true },
        .picker_query = .{ .fg = rgb(p.fg), .bg = rgb(p.surface2) },
        .syntax_comment = rgb(p.muted),
        .syntax_string = rgb(p.green),
        .syntax_keyword = rgb(p.violet),
        .syntax_function = rgb(p.blue),
        .syntax_type = rgb(p.yellow),
        .syntax_constant = rgb(p.yellow),
        .syntax_variable = rgb(p.fg),
        .syntax_property = rgb(p.teal),
        .syntax_punctuation = rgb(p.muted),
        .syntax_tag = rgb(p.red),
    };
}

pub const system: Theme = .{
    .pane_border = .{ .fg = .{ .index = 8 }, .dim = true },
    .pane_border_focused = .{ .bold = true },
    .overlay_border = .{ .bold = true },
    .overlay_title = .{ .reverse = true, .bold = true },
    .section_rule = .{ .fg = .{ .index = 8 }, .dim = true },
    .context = .{},
    .added = .{ .bg = .{ .index = 2 } },
    .removed = .{ .bg = .{ .index = 1 } },
    .added_emphasis = .{ .bg = .{ .index = 10 } },
    .removed_emphasis = .{ .bg = .{ .index = 9 } },
    .gutter = .{ .fg = .{ .index = 8 } },
    .cursor_line = .{ .index = 8 },
    .cursor_line_shift = 0,
    .file_header = .{ .bold = true },
    .hunk_header = .{ .fg = .{ .index = 4 } },
    .fold = .{ .fg = .{ .index = 8 } },
    .sidebar_item = .{},
    .sidebar_selected = .{ .reverse = true, .bold = true },
    .status_added = .{ .index = 2 },
    .status_modified = .{ .index = 3 },
    .status_removed = .{ .index = 1 },
    .status_renamed = .{ .index = 5 },
    .comment = .{ .fg = .{ .index = 6 } },
    .comment_reply = .{ .fg = .{ .index = 8 } },
    .suggestion = .{ .fg = .{ .index = 6 } },
    .draft = .{ .fg = .{ .index = 3 }, .bold = true },
    .draft_reply = .{ .fg = .{ .index = 3 } },
    .outcome_unknown = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 3 }, .bold = true },
    .outcome_unknown_reply = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 3 } },
    .section = .{ .fg = .{ .index = 8 }, .bold = true },
    .picker = .{},
    .picker_selected = .{ .reverse = true, .bold = true },
    .picker_query = .{ .reverse = true },
    .syntax_comment = .{ .index = 8 },
    .syntax_string = .{ .index = 2 },
    .syntax_keyword = .{ .index = 5 },
    .syntax_function = .{ .index = 4 },
    .syntax_type = .{ .index = 3 },
    .syntax_constant = .{ .index = 3 },
    .syntax_variable = .default,
    .syntax_property = .{ .index = 6 },
    .syntax_punctuation = .{ .index = 8 },
    .syntax_tag = .{ .index = 1 },
};

pub const light = fixedTheme(.{ .bg = 0xfa_fa_f8, .fg = 0x24_24_24, .surface = 0xee_ee_ea, .surface2 = 0xdd_dd_d8, .muted = 0x72_72_72, .green = 0x2f_7d_32, .red = 0xb3_26_1e, .yellow = 0x8a_62_00, .blue = 0x1d_5f_a7, .violet = 0x73_3f_9b, .teal = 0x0c_72_72, .light = true });
pub const catppuccin_latte = fixedTheme(.{ .bg = 0xef_f1_f5, .fg = 0x4c_4f_69, .surface = 0xe6_e9_ef, .surface2 = 0xcc_d0_da, .muted = 0x8c_8f_a1, .green = 0x40_a0_2b, .red = 0xd2_0f_39, .yellow = 0xdf_8e_1d, .blue = 0x1e_66_f5, .violet = 0x88_39_ef, .teal = 0x17_92_99, .light = true });
pub const catppuccin_frappe = fixedTheme(.{ .bg = 0x30_34_46, .fg = 0xc6_d0_f5, .surface = 0x41_45_59, .surface2 = 0x51_57_6d, .muted = 0x83_8b_a7, .green = 0xa6_d1_89, .red = 0xe7_82_84, .yellow = 0xe5_c8_90, .blue = 0x8c_aa_ee, .violet = 0xca_9e_e6, .teal = 0x81_c8_be, .light = false });
pub const catppuccin_macchiato = fixedTheme(.{ .bg = 0x24_27_3a, .fg = 0xca_d3_f5, .surface = 0x36_3a_4f, .surface2 = 0x49_4d_64, .muted = 0x80_88_a6, .green = 0xa6_da_95, .red = 0xed_87_96, .yellow = 0xee_d4_9f, .blue = 0x8a_ad_f4, .violet = 0xc6_a0_f6, .teal = 0x8b_d5_ca, .light = false });
pub const catppuccin_mocha = fixedTheme(.{ .bg = 0x1e_1e_2e, .fg = 0xcd_d6_f4, .surface = 0x31_32_44, .surface2 = 0x45_47_5a, .muted = 0x7f_84_a2, .green = 0xa6_e3_a1, .red = 0xf3_8b_a8, .yellow = 0xf9_e2_af, .blue = 0x89_b4_fa, .violet = 0xcb_a6_f7, .teal = 0x94_e2_d5, .light = false });
pub const gruvbox_light = fixedTheme(.{ .bg = 0xfb_f1_c7, .fg = 0x3c_38_36, .surface = 0xeb_db_b2, .surface2 = 0xd5_c4_a1, .muted = 0x7c_6f_64, .green = 0x79_74_0e, .red = 0x9d_00_06, .yellow = 0xb5_76_14, .blue = 0x07_66_78, .violet = 0x8f_3f_71, .teal = 0x42_7b_58, .light = true });
pub const gruvbox_dark = fixedTheme(.{ .bg = 0x28_28_28, .fg = 0xeb_db_b2, .surface = 0x3c_38_36, .surface2 = 0x50_49_45, .muted = 0x92_83_74, .green = 0xb8_bb_26, .red = 0xfb_49_34, .yellow = 0xfa_bd_2f, .blue = 0x83_a5_98, .violet = 0xd3_86_9b, .teal = 0x8e_c0_7c, .light = false });
pub const solarized_light = fixedTheme(.{ .bg = 0xfd_f6_e3, .fg = 0x65_7b_83, .surface = 0xee_e8_d5, .surface2 = 0xd8_d2_c0, .muted = 0x93_a1_a1, .green = 0x85_99_00, .red = 0xdc_32_2f, .yellow = 0xb5_89_00, .blue = 0x26_8b_d2, .violet = 0x6c_71_c4, .teal = 0x2a_a1_98, .light = true });
pub const solarized_dark = fixedTheme(.{ .bg = 0x00_2b_36, .fg = 0x83_94_96, .surface = 0x07_36_42, .surface2 = 0x0d_47_54, .muted = 0x58_6e_75, .green = 0x85_99_00, .red = 0xdc_32_2f, .yellow = 0xb5_89_00, .blue = 0x26_8b_d2, .violet = 0x6c_71_c4, .teal = 0x2a_a1_98, .light = false });

pub const Builtin = struct { name: []const u8, value: Theme };

pub const builtins = [_]Builtin{
    .{ .name = "system", .value = system },
    .{ .name = "dark", .value = dark },
    .{ .name = "light", .value = light },
    .{ .name = "catppuccin-latte", .value = catppuccin_latte },
    .{ .name = "catppuccin-frappe", .value = catppuccin_frappe },
    .{ .name = "catppuccin-macchiato", .value = catppuccin_macchiato },
    .{ .name = "catppuccin-mocha", .value = catppuccin_mocha },
    .{ .name = "gruvbox-light", .value = gruvbox_light },
    .{ .name = "gruvbox-dark", .value = gruvbox_dark },
    .{ .name = "solarized-light", .value = solarized_light },
    .{ .name = "solarized-dark", .value = solarized_dark },
};

pub fn byName(name: []const u8) ?Theme {
    inline for (builtins) |entry| if (std.mem.eql(u8, name, entry.name)) return entry.value;
    return null;
}

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

test "every built-in Theme resolves by its exact name and keeps diff bands distinct" {
    for (builtins) |builtin| {
        const selected = byName(builtin.name).?;
        try testing.expect(!std.meta.eql(selected.added.bg, selected.removed.bg));
        try testing.expect(!std.meta.eql(selected.status_added, selected.status_removed));
        try testing.expect(selected.pane_border.dim);
        try testing.expect(selected.pane_border_focused.bold);
        try testing.expect(selected.overlay_border.bold);
        try testing.expect(selected.overlay_title.bold);
        try testing.expect(selected.section_rule.dim);
    }
    try testing.expect(byName("catppuccin") == null);
}

test "every built-in Theme composes every ReviewCard role and Markdown refinement" {
    for (builtins) |builtin| {
        inline for (std.meta.tags(review_card.CardRole)) |role| {
            const prose = builtin.value.reviewCardStyle(role, .body, .{ .emphasis = true });
            try testing.expect(prose.italic);
            const strong_link = builtin.value.reviewCardStyle(role, .body, .{ .strong = true, .link_label = true });
            try testing.expect(strong_link.bold and strong_link.ul_style == .single);
            try testing.expect(std.meta.eql(builtin.value.suggestion, builtin.value.reviewCardStyle(role, .suggestion_body, .{})));
            try testing.expect(builtin.value.reviewCardStyle(role, .header, .{}).bold);
            try testing.expect(builtin.value.reviewCardStyle(role, .disclosure_footer, .{}).dim);
        }
    }
}

test "Capture colors resolve hierarchical names and preserve unknown foregrounds" {
    try testing.expectEqual(dark.syntax_function, dark.captureColor(.{ .name = "function.call.builtin" }).?);
    try testing.expectEqual(dark.syntax_keyword, dark.captureColor(.{ .name = "operator" }).?);
    try testing.expect(dark.captureColor(.{ .name = "unrecognized.future.capture" }) == null);
}
