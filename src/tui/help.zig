//! The lines of the keybinding help Overlay. Presentation reads the line count
//! to clamp the help scroll, and render.zig paints the lines. The Keymap
//! supplies the Pane bindings, grouped by `keymap.HelpSection`. The fixed keys
//! of the Overlays that keep their own input follow as fixed sections.

const std = @import("std");
const vaxis = @import("vaxis");
const keymap = @import("keymap.zig");

pub const Entry = struct {
    keys: []const u8,
    description: []const u8,
    /// The Keymap Action, or null for a fixed Overlay key.
    action: ?keymap.Action = null,
};

pub const Line = union(enum) {
    heading: []const u8,
    blank,
    entry: Entry,
};

const FixedSection = struct { title: []const u8, entries: []const Entry };

/// The keys of the Overlays that capture input outside the Keymap. Keep each
/// section in step with the key handler in presentation.zig that it names.
pub const fixed_sections = [_]FixedSection{
    // `applySubmissionTreeKey`
    .{ .title = "Submission Overlay", .entries = &.{
        .{ .keys = "j k ↑ ↓", .description = "select Draft" },
        .{ .keys = "⏎", .description = "jump to Draft (X shows the Overlay again)" },
        .{ .keys = "e", .description = "edit Draft" },
        .{ .keys = "a", .description = "re-anchor Draft" },
        .{ .keys = "D", .description = "delete Draft and its Replies" },
        .{ .keys = "X", .description = "retry selected subtree" },
        .{ .keys = "R", .description = "reload PullRequest after a SourceCommit change" },
        .{ .keys = "U", .description = "outcome unknown: confirm not published" },
        .{ .keys = "L", .description = "outcome unknown: link existing Comment" },
        .{ .keys = "A", .description = "abandon recovery, or decide later" },
        .{ .keys = "p", .description = "open PullRequest Picker" },
        .{ .keys = "q esc", .description = "close Submission" },
    } },
    // `applyDeleteConfirmationInput` callers in `applyKey`
    .{ .title = "Delete Confirmation", .entries = &.{
        .{ .keys = "y ⏎", .description = "delete" },
        .{ .keys = "n esc ctrl-c", .description = "cancel" },
    } },
    // `applyUnknownResolutionInput` callers in `applyKey`
    .{ .title = "Link Existing Comment", .entries = &.{
        .{ .keys = "0-9", .description = "type Comment ID" },
        .{ .keys = "⌫", .description = "erase digit" },
        .{ .keys = "⏎", .description = "link Draft to Comment" },
        .{ .keys = "esc ctrl-c", .description = "cancel" },
    } },
    // `applyHelpKey`
    .{ .title = "Help", .entries = &.{
        .{ .keys = "j k ↑ ↓", .description = "scroll" },
        .{ .keys = "ctrl-d ctrl-u", .description = "scroll half page" },
        .{ .keys = "g G", .description = "go to top / bottom" },
        .{ .keys = "other key", .description = "close help" },
    } },
    .{ .title = "Mouse", .entries = &.{
        .{ .keys = "click", .description = "focus, select, toggle" },
        .{ .keys = "wheel", .description = "scroll" },
        .{ .keys = "shift option", .description = "native terminal selection" },
        .{ .keys = "config", .description = "[input.mouse] enabled = false" },
    } },
};

/// The number of lines that `build` returns for `km`.
pub fn lineCount(km: keymap.Keymap) usize {
    var count: usize = 0;
    var sections: usize = 0;
    for (std.enums.values(keymap.HelpSection)) |section| {
        const entries = actionCount(km, section);
        if (entries == 0) continue;
        count += 1 + entries;
        sections += 1;
    }
    for (fixed_sections) |section| count += 1 + section.entries.len;
    sections += fixed_sections.len;
    return count + sections - 1;
}

/// Build the help lines: one heading per section, one entry per Action with
/// all of its chords, and a blank line between sections.
pub fn build(scratch: std.mem.Allocator, km: keymap.Keymap) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    for (std.enums.values(keymap.HelpSection)) |section| {
        if (actionCount(km, section) == 0) continue;
        if (lines.items.len > 0) try lines.append(scratch, .blank);
        try lines.append(scratch, .{ .heading = section.title() });
        for (km.bindings, 0..) |binding, index| {
            if (keymap.helpSection(binding.action) != section or !firstBinding(km, index)) continue;
            var keys: std.ArrayList(u8) = .empty;
            for (km.bindings) |other| {
                if (other.action != binding.action) continue;
                if (keys.items.len > 0) try keys.append(scratch, ' ');
                try keys.appendSlice(scratch, try chordLabel(scratch, other.chord));
            }
            try lines.append(scratch, .{ .entry = .{ .keys = keys.items, .description = binding.help, .action = binding.action } });
        }
    }
    for (fixed_sections) |section| {
        if (lines.items.len > 0) try lines.append(scratch, .blank);
        try lines.append(scratch, .{ .heading = section.title });
        for (section.entries) |entry| try lines.append(scratch, .{ .entry = entry });
    }
    return lines.items;
}

fn actionCount(km: keymap.Keymap, section: keymap.HelpSection) usize {
    var count: usize = 0;
    for (km.bindings, 0..) |binding, index| {
        if (keymap.helpSection(binding.action) == section and firstBinding(km, index)) count += 1;
    }
    return count;
}

fn firstBinding(km: keymap.Keymap, index: usize) bool {
    for (km.bindings[0..index]) |earlier| if (earlier.action == km.bindings[index].action) return false;
    return true;
}

/// A short display label for a key codepoint: named for the special keys,
/// otherwise the codepoint's own utf8.
fn keyName(scratch: std.mem.Allocator, cp: u21) ![]const u8 {
    return switch (cp) {
        vaxis.Key.enter => "⏎",
        vaxis.Key.escape => "esc",
        vaxis.Key.backspace => "⌫",
        vaxis.Key.tab => "tab",
        vaxis.Key.up => "↑",
        vaxis.Key.down => "↓",
        vaxis.Key.left => "←",
        vaxis.Key.right => "→",
        vaxis.Key.home => "home",
        vaxis.Key.end => "end",
        vaxis.Key.page_up => "pgup",
        vaxis.Key.page_down => "pgdn",
        else => blk: {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &b) catch break :blk "?";
            break :blk try scratch.dupe(u8, b[0..n]);
        },
    };
}

/// Format a Chord, including configured multi-chord Actions.
pub fn chordLabel(scratch: std.mem.Allocator, c: keymap.Chord) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..c.len()) |i| {
        const stroke = c.at(i);
        if (i > 0) try out.append(scratch, ' ');
        if (stroke.mods.meta) try out.appendSlice(scratch, "meta-");
        if (stroke.mods.hyper) try out.appendSlice(scratch, "hyper-");
        if (stroke.mods.super) try out.appendSlice(scratch, "super-");
        if (stroke.mods.ctrl) try out.appendSlice(scratch, "ctrl-");
        if (stroke.mods.alt) try out.appendSlice(scratch, "alt-");
        if (stroke.mods.shift) try out.appendSlice(scratch, "shift-");
        try out.appendSlice(scratch, try keyName(scratch, stroke.cp));
    }
    return out.items;
}

const testing = std.testing;

test "help lineCount matches the built lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try build(arena.allocator(), .default);
    try testing.expectEqual(lines.len, lineCount(.default));
    try testing.expect(lines[0] == .heading);
    try testing.expect(lines[lines.len - 1] == .entry);
}

test "help lists each Action once with all of its chords in its section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try build(arena.allocator(), .default);
    var section: []const u8 = "";
    var down_found = false;
    for (lines) |line| switch (line) {
        .heading => |title| section = title,
        .blank => {},
        .entry => |entry| if (entry.action == .down) {
            try testing.expect(!down_found);
            down_found = true;
            try testing.expectEqualStrings("Motions", section);
            try testing.expectEqualStrings("j ↓", entry.keys);
        },
    };
    try testing.expect(down_found);
}

test "help names the keys of the Submission Overlay and the confirmations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try build(arena.allocator(), .default);
    var section: []const u8 = "";
    var found: usize = 0;
    for (lines) |line| switch (line) {
        .heading => |title| section = title,
        .blank => {},
        .entry => |entry| {
            if (std.mem.eql(u8, section, "Submission Overlay") and std.mem.eql(u8, entry.keys, "⏎")) found += 1;
            if (std.mem.eql(u8, section, "Submission Overlay") and std.mem.eql(u8, entry.keys, "X")) found += 1;
            if (std.mem.eql(u8, section, "Delete Confirmation") and std.mem.eql(u8, entry.keys, "y ⏎")) found += 1;
            if (std.mem.eql(u8, section, "Review and Submission") and entry.action == .link_existing_comment) found += 1;
        },
    };
    try testing.expectEqual(@as(usize, 4), found);
}

test "a chord label names its modifiers and every stroke" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ctrl-d", try chordLabel(arena.allocator(), keymap.Chord.modified('d', .{ .ctrl = true })));
    try testing.expectEqualStrings("g C", try chordLabel(arena.allocator(), keymap.Chord.two('g', 'C')));
}
