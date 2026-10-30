//! The help Overlay owns its query, filtered lines, scroll, and input rollback.

const std = @import("std");
const vaxis = @import("vaxis");
const keymap = @import("keymap.zig");
const search = @import("search.zig");
const layouts = @import("layouts.zig");

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
    no_matches,
};

const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    query: search.Query,
    lines: []const Line,
    scroll: usize = 0,

    fn init(allocator: std.mem.Allocator, km: keymap.Keymap, text: []const u8) !Snapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const query = try search.Query.init(a, text);
        const lines = filter(try build(a, km), query);
        return .{ .arena = arena, .query = query, .lines = lines };
    }

    fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const View = struct {
    lines: []const Line,
    query: union(enum) { none, kept: []const u8, input: []const u8 },
    scroll: usize,

    pub fn layout(self: View) layouts.Help {
        return .{ .rows = self.lines.len, .query = self.query != .none, .scroll = .{ .total = self.lines.len, .offset = self.scroll } };
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    mode: union(enum) {
        browse: Snapshot,
        input: struct { before: Snapshot, current: Snapshot },
    },

    pub fn init(allocator: std.mem.Allocator, km: keymap.Keymap) !State {
        return .{ .allocator = allocator, .mode = .{ .browse = try Snapshot.init(allocator, km, "") } };
    }

    pub fn deinit(self: *State) void {
        switch (self.mode) {
            .browse => |*snapshot| snapshot.deinit(),
            .input => |*input| {
                input.before.deinit();
                input.current.deinit();
            },
        }
        self.* = undefined;
    }

    pub fn view(self: *const State) View {
        const snapshot = switch (self.mode) {
            .browse => |*snapshot| snapshot,
            .input => |*input| &input.current,
        };
        return .{
            .lines = snapshot.lines,
            .query = if (self.mode == .input) .{ .input = snapshot.query.text } else if (snapshot.query.text.len > 0) .{ .kept = snapshot.query.text } else .none,
            .scroll = snapshot.scroll,
        };
    }

    pub fn applyKey(self: *State, km: keymap.Keymap, key: keymap.KeyStroke, page: u16) !enum { stay, close } {
        switch (self.mode) {
            .input => |*input| {
                if (key.matches(keymap.special.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                    const before = input.before;
                    input.current.deinit();
                    self.mode = .{ .browse = before };
                } else if (key.matches(keymap.special.enter, .{})) {
                    const current = input.current;
                    input.before.deinit();
                    self.mode = .{ .browse = current };
                } else {
                    const text = input.current.query.text;
                    var joined: ?[]u8 = null;
                    defer if (joined) |bytes| self.allocator.free(bytes);
                    const next_text = blk: {
                        if (key.matches(keymap.special.backspace, .{})) break :blk text[0..search.lastScalarStart(text)];
                        if (key.matches('w', .{ .ctrl = true })) break :blk text[0..search.wordStart(text)];
                        if (key.matches('u', .{ .ctrl = true })) break :blk "";
                        if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.meta or key.mods.hyper) return .stay;
                        const added = key.text orelse return .stay;
                        joined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ text, added });
                        break :blk joined.?;
                    };
                    const next = try Snapshot.init(self.allocator, km, next_text);
                    input.current.deinit();
                    input.current = next;
                }
            },
            .browse => |*snapshot| {
                if (key.matches('/', .{})) {
                    const current = try Snapshot.init(self.allocator, km, "");
                    self.mode = .{ .input = .{ .before = snapshot.*, .current = current } };
                    return .stay;
                }
                if (key.matches(keymap.special.escape, .{})) {
                    if (snapshot.query.text.len == 0) return .close;
                    const next = try Snapshot.init(self.allocator, km, "");
                    snapshot.deinit();
                    snapshot.* = next;
                    return .stay;
                }
                const last = snapshot.lines.len -| page;
                snapshot.scroll = @min(snapshot.scroll, last);
                const half = @max(page / 2, 1);
                if (key.matches('j', .{}) or key.matches(keymap.special.down, .{})) {
                    snapshot.scroll = @min(snapshot.scroll +| 1, last);
                } else if (key.matches('k', .{}) or key.matches(keymap.special.up, .{})) {
                    snapshot.scroll -|= 1;
                } else if (key.matches('d', .{ .ctrl = true }) or key.matches(keymap.special.page_down, .{})) {
                    snapshot.scroll = @min(snapshot.scroll +| half, last);
                } else if (key.matches('u', .{ .ctrl = true }) or key.matches(keymap.special.page_up, .{})) {
                    snapshot.scroll -|= half;
                } else if (key.matches('g', .{})) {
                    snapshot.scroll = 0;
                } else if (key.matches('G', .{})) {
                    snapshot.scroll = last;
                } else return .close;
            },
        }
        return .stay;
    }
};

fn filter(lines: []Line, query: search.Query) []Line {
    if (query.text.len == 0) return lines;
    var title: []const u8 = "";
    var emitted = false;
    var written: usize = 0;
    for (lines) |line| switch (line) {
        .heading => |heading| {
            title = heading;
            emitted = false;
        },
        .entry => |entry| {
            if (!search.containsLiteral(query, entry.keys) and !search.containsLiteral(query, entry.description)) continue;
            if (!emitted) {
                if (written > 0) {
                    lines[written] = .blank;
                    written += 1;
                }
                lines[written] = .{ .heading = title };
                written += 1;
                emitted = true;
            }
            lines[written] = line;
            written += 1;
        },
        .blank, .no_matches => {},
    };
    if (written == 0) {
        lines[0] = .no_matches;
        written = 1;
    }
    return lines[0..written];
}

const FixedSection = struct { title: []const u8, entries: []const Entry };

/// The keys of the Overlays that capture input outside the Keymap.
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
    // The Composer branch of `applyKey`
    .{ .title = "Composer", .entries = &.{
        .{ .keys = "⏎", .description = "insert newline" },
        .{ .keys = "⌫ ctrl-w ctrl-u", .description = "erase scalar, word, or to line start" },
        .{ .keys = "ctrl-d ctrl-s", .description = "save" },
        .{ .keys = "esc ctrl-c", .description = "cancel" },
    } },
    // The List Overlay branch of `applyKey`
    .{ .title = "Pickers and Command Palette", .entries = &.{
        .{ .keys = "↑ ↓ ctrl-p ctrl-n", .description = "select entry" },
        .{ .keys = "⌫", .description = "erase scalar" },
        .{ .keys = "⏎", .description = "confirm entry" },
        .{ .keys = "esc ctrl-c", .description = "close" },
    } },
    // The Buffer Search input branch of `applyKey`
    .{ .title = "Buffer Search Input", .entries = &.{
        .{ .keys = "⌫ ctrl-w ctrl-u", .description = "erase scalar, word, or query" },
        .{ .keys = "⏎", .description = "accept search" },
        .{ .keys = "esc ctrl-c", .description = "cancel search" },
    } },
    // The Review Search branch of `applyKey`
    .{ .title = "Review Search Input", .entries = &.{
        .{ .keys = "⌫ ctrl-w ctrl-k", .description = "erase scalar, word, or query" },
        .{ .keys = "esc ctrl-c", .description = "close Review Search" },
    } },
    .{ .title = "Help", .entries = &.{
        .{ .keys = "/", .description = "search help with an empty query" },
        .{ .keys = "⌫ ctrl-w ctrl-u", .description = "erase scalar, word, or query during search" },
        .{ .keys = "⏎", .description = "keep help filter and scroll" },
        .{ .keys = "esc", .description = "cancel input, clear kept filter, or close help" },
        .{ .keys = "ctrl-c", .description = "cancel help search input or close help" },
        .{ .keys = "j k ↑ ↓", .description = "scroll" },
        .{ .keys = "ctrl-d ctrl-u", .description = "scroll half page" },
        .{ .keys = "g G", .description = "go to top / bottom" },
        .{ .keys = "other key", .description = "close help outside search input" },
    } },
    .{ .title = "Mouse", .entries = &.{
        .{ .keys = "click", .description = "focus, select, toggle" },
        .{ .keys = "wheel", .description = "scroll" },
        .{ .keys = "shift option", .description = "native terminal selection" },
        .{ .keys = "config", .description = "[input.mouse] enabled = false" },
    } },
};

/// Build the help lines: one heading per section, one entry per Action with
/// all of its chords, and a blank line between sections. An Action without a
/// chord follows the bound Actions of its section as `unbound`.
fn build(scratch: std.mem.Allocator, km: keymap.Keymap) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    for (std.enums.values(keymap.HelpSection)) |section| {
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
        for (std.enums.values(keymap.Action)) |action| {
            if (keymap.helpSection(action) != section or bound(km, action)) continue;
            try lines.append(scratch, .{ .entry = .{ .keys = "unbound", .description = try actionHelp(scratch, action), .action = action } });
        }
    }
    for (fixed_sections) |section| {
        if (lines.items.len > 0) try lines.append(scratch, .blank);
        try lines.append(scratch, .{ .heading = section.title });
        for (section.entries) |entry| try lines.append(scratch, .{ .entry = entry });
    }
    return lines.items;
}

fn bound(km: keymap.Keymap, action: keymap.Action) bool {
    for (km.bindings) |binding| if (binding.action == action) return true;
    return false;
}

/// The help label of the Action's default binding, or its name in words when
/// no default binding exists.
fn actionHelp(scratch: std.mem.Allocator, action: keymap.Action) ![]const u8 {
    for (keymap.default_bindings) |binding| if (binding.action == action) return binding.help;
    const name = try scratch.dupe(u8, @tagName(action));
    std.mem.replaceScalar(u8, name, '_', ' ');
    return name;
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

test "help starts with all lines and no query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try build(arena.allocator(), .default);
    var state = try State.init(testing.allocator, .default);
    defer state.deinit();
    try testing.expectEqual(lines.len, state.view().lines.len);
    try testing.expect(state.view().query == .none);
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
        .blank, .no_matches => {},
        .entry => |entry| if (entry.action == .down) {
            try testing.expect(!down_found);
            down_found = true;
            try testing.expectEqualStrings("Motions", section);
            try testing.expectEqualStrings("j ↓", entry.keys);
        },
    };
    try testing.expect(down_found);
    for (std.enums.values(keymap.Action)) |action| {
        var count: usize = 0;
        for (lines) |line| {
            if (line == .entry and line.entry.action == action) count += 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "help lists an Action without a chord as unbound in its section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var bindings: std.ArrayList(keymap.Binding) = .empty;
    for (keymap.default_bindings) |binding| if (binding.action != .quit) try bindings.append(arena.allocator(), binding);
    const lines = try build(arena.allocator(), .{ .bindings = bindings.items });
    var section: []const u8 = "";
    var found = false;
    for (lines) |line| switch (line) {
        .heading => |title| section = title,
        .blank, .no_matches => {},
        .entry => |entry| if (entry.action == .quit) {
            found = true;
            try testing.expectEqualStrings("General", section);
            try testing.expectEqualStrings("unbound", entry.keys);
            try testing.expectEqualStrings(actionHelp(arena.allocator(), .quit) catch unreachable, entry.description);
        },
    };
    try testing.expect(found);
    try testing.expectEqualStrings("open theme overlay", try actionHelp(arena.allocator(), .open_theme_overlay));
}

test "help names the keys of the Submission Overlay and the confirmations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try build(arena.allocator(), .default);
    var section: []const u8 = "";
    var found: usize = 0;
    for (lines) |line| switch (line) {
        .heading => |title| section = title,
        .blank, .no_matches => {},
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

fn typeQuery(state: *State, km: keymap.Keymap, text: []const u8) !void {
    _ = try state.applyKey(km, .{ .codepoint = '/', .text = "/" }, 3);
    _ = try state.applyKey(km, .{ .codepoint = 0, .text = text }, 3);
}

test "help filters configured keys and original descriptions with Unicode smart case" {
    const km: keymap.Keymap = .{ .bindings = &.{
        .{ .chord = keymap.Chord.two('g', 'Ω'), .action = .down, .help = "Ärger [x]" },
        .{ .chord = keymap.Chord.one('z'), .action = .up, .help = "ärger plain" },
        .{ .chord = keymap.Chord.one('!'), .action = .help, .help = "custom help" },
    } };
    for ([_]struct { query: []const u8, count: usize }{
        .{ .query = "ärger", .count = 2 },
        .{ .query = "Ärger", .count = 1 },
        .{ .query = "g ω", .count = 1 },
        .{ .query = "[x]", .count = 1 },
    }) |case| {
        var state = try State.init(testing.allocator, km);
        defer state.deinit();
        try typeQuery(&state, km, case.query);
        const lines = state.view().lines;
        try testing.expectEqual(case.count + 1, lines.len);
        try testing.expectEqualStrings("Motions", lines[0].heading);
        try testing.expectEqualStrings("g Ω", lines[1].entry.keys);
        try testing.expectEqualStrings("Ärger [x]", lines[1].entry.description);
    }
    var state = try State.init(testing.allocator, km);
    defer state.deinit();
    try typeQuery(&state, km, "Ω Ärger");
    try testing.expect(state.view().lines[0] == .no_matches);
}

test "help keeps only nonempty headings and separators and includes fixed keys" {
    const km: keymap.Keymap = .{ .bindings = &.{
        .{ .chord = keymap.Chord.one('z'), .action = .down, .help = "needle motion" },
        .{ .chord = keymap.Chord.one('!'), .action = .help, .help = "needle general" },
    } };
    var state = try State.init(testing.allocator, km);
    defer state.deinit();
    try typeQuery(&state, km, "needle");
    const lines = state.view().lines;
    try testing.expectEqual(@as(usize, 5), lines.len);
    try testing.expectEqualStrings("Motions", lines[0].heading);
    try testing.expectEqualStrings("needle motion", lines[1].entry.description);
    try testing.expect(lines[2] == .blank);
    try testing.expectEqualStrings("General", lines[3].heading);
    try testing.expectEqualStrings("needle general", lines[4].entry.description);
    _ = try state.applyKey(km, .{ .codepoint = keymap.special.escape }, 3);
    try typeQuery(&state, km, "ctrl-w");
    const fixed = state.view().lines;
    try testing.expectEqual(@as(usize, 11), fixed.len);
    for ([_][]const u8{ "Composer", "Buffer Search Input", "Review Search Input", "Help" }, 0..) |title, index| {
        try testing.expectEqualStrings(title, fixed[index * 3].heading);
        try testing.expect(std.mem.indexOf(u8, fixed[index * 3 + 1].entry.keys, "ctrl-w") != null);
    }
    _ = try state.applyKey(km, .{ .codepoint = keymap.special.escape }, 3);
    try typeQuery(&state, km, "Motions");
    try testing.expectEqual(@as(usize, 1), state.view().lines.len);
    try testing.expect(state.view().lines[0] == .no_matches);
    try testing.expectEqualStrings("Motions", state.view().query.input);
}

test "help accepts filters cancels to prior query and scroll and clears before closing" {
    var state = try State.init(testing.allocator, .default);
    defer state.deinit();
    try typeQuery(&state, .default, "o");
    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.enter }, 3);
    try testing.expectEqualStrings("o", state.view().query.kept);
    _ = try state.applyKey(.default, .{ .codepoint = 'G' }, 3);
    const before = state.view();
    try testing.expect(before.scroll > 0);
    _ = try state.applyKey(.default, .{ .codepoint = '/' }, 3);
    try testing.expectEqualStrings("", state.view().query.input);
    _ = try state.applyKey(.default, .{ .codepoint = 0, .text = "absent-query" }, 3);
    try testing.expect(state.view().lines[0] == .no_matches);
    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.escape }, 3);
    try testing.expectEqualDeep(before, state.view());
    _ = try state.applyKey(.default, .{ .codepoint = 'k' }, @intCast(before.lines.len - 1));
    try testing.expectEqual(@as(usize, 0), state.view().scroll);
    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.escape }, 3);
    try testing.expect(state.view().query == .none);
    try testing.expectEqual(@as(usize, 0), state.view().scroll);
    try testing.expectEqual(.close, try state.applyKey(.default, .{ .codepoint = keymap.special.escape }, 3));
    try testing.expectEqual(.close, try state.applyKey(.default, .{ .codepoint = 'x' }, 3));
}

test "help edits Unicode scalars and uses Buffer Search word whitespace rules" {
    var state = try State.init(testing.allocator, .default);
    defer state.deinit();
    try typeQuery(&state, .default, "α\u{2003}βγ\u{00a0}");
    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.backspace }, 3);
    try testing.expectEqualStrings("α\u{2003}βγ", state.view().query.input);
    _ = try state.applyKey(.default, .{ .codepoint = 'w', .mods = .{ .ctrl = true } }, 3);
    try testing.expectEqualStrings("α\u{2003}", state.view().query.input);
    _ = try state.applyKey(.default, .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, 3);
    try testing.expectEqualStrings("", state.view().query.input);
    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.up }, 3);
    try testing.expectEqualStrings("", state.view().query.input);
    const before = state.view();
    try testing.expectError(error.InvalidUtf8, state.applyKey(.default, .{ .codepoint = 0, .text = "\xff" }, 3));
    try testing.expectError(error.TooLong, state.applyKey(.default, .{ .codepoint = 0, .text = "x" ** (search.max_query_scalars + 1) }, 3));
    try testing.expectEqualDeep(before, state.view());
}

test "help opening releases every failed snapshot allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var state = try State.init(allocator, .default);
            defer state.deinit();
            try testing.expect(state.view().lines.len > 1);
        }
    }.run, .{});
}

test "help snapshot failures preserve query lines scroll and cancellation" {
    const operations = [_]keymap.KeyStroke{
        .{ .codepoint = '/' },
        .{ .codepoint = 'x', .text = "x" },
        .{ .codepoint = keymap.special.backspace },
        .{ .codepoint = 'w', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'u', .mods = .{ .ctrl = true } },
        .{ .codepoint = keymap.special.escape },
    };
    for (operations, 0..) |operation, operation_index| {
        var failures: usize = 0;
        for (0..256) |offset| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var state = try State.init(failing.allocator(), .default);
            defer state.deinit();
            try typeQuery(&state, .default, "o");
            _ = try state.applyKey(.default, .{ .codepoint = keymap.special.enter }, 3);
            _ = try state.applyKey(.default, .{ .codepoint = 'G' }, 3);
            const saved = state.view();
            if (operation_index > 0 and operation_index < operations.len - 1) try typeQuery(&state, .default, "old word");
            const before = state.view();
            failing.fail_index = failing.alloc_index + offset;
            failing.resize_fail_index = failing.resize_index;
            if (state.applyKey(.default, operation, 3)) |_| {
                try testing.expect(failures > 0);
                break;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                try testing.expectEqualDeep(before, state.view());
                failing.fail_index = std.math.maxInt(usize);
                failing.resize_fail_index = std.math.maxInt(usize);
                if (state.mode == .input) {
                    _ = try state.applyKey(.default, .{ .codepoint = 'z', .text = "z" }, 3);
                    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.escape }, 3);
                    try testing.expectEqualDeep(saved, state.view());
                } else {
                    try typeQuery(&state, .default, "z");
                    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.escape }, 3);
                    try testing.expectEqualDeep(saved, state.view());
                }
            }
            if (offset == 255) return error.FailureSweepDidNotFinish;
        }
    }
}

test "help acceptance and cancellation allocate nothing" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var state = try State.init(failing.allocator(), .default);
    defer state.deinit();
    try typeQuery(&state, .default, "old");
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.enter }, 3);
    try testing.expectEqualStrings("old", state.view().query.kept);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try typeQuery(&state, .default, "new");
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    _ = try state.applyKey(.default, .{ .codepoint = keymap.special.escape }, 3);
    try testing.expectEqualStrings("old", state.view().query.kept);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try typeQuery(&state, .default, "cancel with ctrl-c");
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    _ = try state.applyKey(.default, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }, 3);
    try testing.expectEqualStrings("old", state.view().query.kept);
    try testing.expect(!failing.has_induced_failure);
}
