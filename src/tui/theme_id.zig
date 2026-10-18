//! The vaxis-free identity of a built-in Theme. Presentation, config, and the
//! Theme Overlay name Themes only by ThemeId. `theme.zig` maps each one to its
//! vaxis styles.

const std = @import("std");

pub const ThemeId = enum(u8) {
    // Declaration order is display order in the Theme Overlay.
    system,
    dark,
    light,
    catppuccin_latte,
    catppuccin_frappe,
    catppuccin_macchiato,
    catppuccin_mocha,
    gruvbox_light,
    gruvbox_dark,
    solarized_light,
    solarized_dark,

    pub const count = std.meta.fields(ThemeId).len;

    const names = blk: {
        var result: [count][]const u8 = undefined;
        for (std.meta.fields(ThemeId), &result) |field, *slot| {
            var spelled: [field.name.len]u8 = field.name[0..field.name.len].*;
            std.mem.replaceScalar(u8, &spelled, '_', '-');
            const final = spelled;
            slot.* = &final;
        }
        break :blk result;
    };

    /// The config.toml spelling: the tag name with `_` replaced by `-`.
    pub fn name(self: ThemeId) []const u8 {
        return names[@intFromEnum(self)];
    }

    /// Exact, case-sensitive match against `name`.
    pub fn fromName(text: []const u8) ?ThemeId {
        for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, text)) return @enumFromInt(index);
        return null;
    }

    /// Item `index` of the Theme Overlay list.
    pub fn at(index: usize) ThemeId {
        return @enumFromInt(index);
    }
};

test "every ThemeId name round-trips and keeps the config.toml spelling" {
    for (std.meta.tags(ThemeId)) |id| try std.testing.expectEqual(id, ThemeId.fromName(id.name()).?);
    try std.testing.expectEqualStrings("system", ThemeId.system.name());
    try std.testing.expectEqualStrings("catppuccin-latte", ThemeId.catppuccin_latte.name());
    try std.testing.expect(ThemeId.fromName("catppuccin_latte") == null);
    try std.testing.expect(ThemeId.fromName("Dark") == null);
}
