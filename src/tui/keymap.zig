//! Keymap — the single source of truth for viewer-mode key bindings (M11).
//!
//! Vim-aligned model: motions and commands are *both* bindings in one table, so
//! the dispatch (`app.zig`) and the help overlay (`render.zig`) read the same
//! data. The two pieces of input *grammar* that don't fit a flat table live in
//! the engine, not the bindings — exactly as vim keeps the Count and multi-key
//! prefix resolution above its mapping table:
//!   * the numeric **Count** prefix (`5j`) is accumulated by `Nav`, and
//!   * a **Leader** begins a configured multi-chord sequence the `Resolver`
//!     tracks; a Leader has no standalone binding.
//!
//! Bindings are matched against a portable `KeyStroke`, so the state-machine
//! boundary does not expose terminal-library event types.
//!
//! Only viewer (normal) mode is tabled here; the Composer and Picker overlays
//! keep their own fixed editing keys (their surface is mostly text entry). User
//! overrides from a config file arrive with M12 — this ships the defaults and
//! the seam. Composer/picker mode bindings can join later if that earns its keep.

const std = @import("std");
const vaxis = @import("vaxis");

/// Portable Presentation Action. This module owns only terminal-key resolution;
/// the resulting vocabulary is independent of vaxis and belongs to the state
/// machine that consumes it.
pub const Action = @import("action.zig").Action;
pub const InteractionContext = @import("action.zig").InteractionContext;

pub const Modifiers = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,

    pub fn eql(a: Modifiers, b: Modifiers) bool {
        return std.meta.eql(a, b);
    }
};

pub const KeyStroke = struct {
    codepoint: u21,
    text: ?[]const u8 = null,
    mods: Modifiers = .{},

    pub fn matches(self: KeyStroke, codepoint: u21, modifiers: Modifiers) bool {
        return self.codepoint == codepoint and self.mods.eql(modifiers);
    }
};

pub const special = struct {
    pub const escape = vaxis.Key.escape;
    pub const enter = vaxis.Key.enter;
    pub const backspace = vaxis.Key.backspace;
    pub const up = vaxis.Key.up;
    pub const down = vaxis.Key.down;
};

/// Is this Action a Motion (movement within a Pane) rather than a command? The
/// help overlay groups the two; `select_down`/`select_up` count as motions since
/// they move the cursor (while extending the selection).
pub fn isMotion(a: Action) bool {
    return switch (a) {
        .down,
        .up,
        .left,
        .right,
        .half_page_down,
        .half_page_up,
        .page_down,
        .page_up,
        .to_top,
        .to_bottom,
        .center,
        .scroll_cursor_top,
        .scroll_cursor_bottom,
        .cursor_view_top,
        .cursor_view_middle,
        .cursor_view_bottom,
        .select_down,
        .select_up,
        => true,
        else => false,
    };
}

/// One bounded sequence of key strokes. Single-key and multi-chord Actions use
/// the same representation.
pub const Chord = struct {
    strokes: [8]Stroke,
    count: u4,

    pub fn one(cp: u21) Chord {
        var strokes: [8]Stroke = undefined;
        strokes[0] = .{ .cp = cp };
        return .{ .strokes = strokes, .count = 1 };
    }

    pub fn modified(cp: u21, mods: Modifiers) Chord {
        var chord = one(cp);
        chord.strokes[0].mods = mods;
        return chord;
    }

    pub fn two(first: u21, second: u21) Chord {
        var strokes: [8]Stroke = undefined;
        strokes[0] = .{ .cp = first };
        strokes[1] = .{ .cp = second };
        return .{ .strokes = strokes, .count = 2 };
    }

    pub fn len(self: Chord) usize {
        return self.count;
    }

    pub fn at(self: Chord, index: usize) Stroke {
        return self.strokes[index];
    }
};

pub const Stroke = struct {
    cp: u21,
    mods: Modifiers = .{},
};

pub const Binding = struct {
    chord: Chord,
    action: Action,
    /// A short human label for the help overlay.
    help: []const u8,
};

/// The default bindings. Contextual Actions deliberately share chords; the
/// resolver filters them through the active Interaction Context.
pub const default_bindings = [_]Binding{
    // --- motions ---
    .{ .chord = Chord.one('j'), .action = .down, .help = "down" },
    .{ .chord = Chord.one(vaxis.Key.down), .action = .down, .help = "down" },
    .{ .chord = Chord.one('k'), .action = .up, .help = "up" },
    .{ .chord = Chord.one(vaxis.Key.up), .action = .up, .help = "up" },
    .{ .chord = Chord.one('h'), .action = .left, .help = "collapse / parent" },
    .{ .chord = Chord.one(vaxis.Key.left), .action = .left, .help = "collapse / parent" },
    .{ .chord = Chord.one('l'), .action = .right, .help = "expand / child" },
    .{ .chord = Chord.one(vaxis.Key.right), .action = .right, .help = "expand / child" },
    .{ .chord = Chord.modified('d', .{ .ctrl = true }), .action = .half_page_down, .help = "half page down" },
    .{ .chord = Chord.one(vaxis.Key.page_down), .action = .half_page_down, .help = "half page down" },
    .{ .chord = Chord.modified('u', .{ .ctrl = true }), .action = .half_page_up, .help = "half page up" },
    .{ .chord = Chord.one(vaxis.Key.page_up), .action = .half_page_up, .help = "half page up" },
    .{ .chord = Chord.modified('f', .{ .ctrl = true }), .action = .page_down, .help = "page down" },
    .{ .chord = Chord.modified('b', .{ .ctrl = true }), .action = .page_up, .help = "page up" },
    .{ .chord = Chord.modified('y', .{ .ctrl = true }), .action = .scroll_row_up, .help = "scroll one row up" },
    .{ .chord = Chord.modified('e', .{ .ctrl = true }), .action = .scroll_row_down, .help = "scroll one row down" },
    .{ .chord = Chord.two('g', 'g'), .action = .to_top, .help = "go to top" },
    .{ .chord = Chord.one(vaxis.Key.home), .action = .to_top, .help = "go to top" },
    .{ .chord = Chord.one('G'), .action = .to_bottom, .help = "go to bottom" },
    .{ .chord = Chord.one(vaxis.Key.end), .action = .to_bottom, .help = "go to bottom" },
    .{ .chord = Chord.two('z', 'z'), .action = .center, .help = "center cursor" },
    .{ .chord = Chord.two('z', 't'), .action = .scroll_cursor_top, .help = "cursor to viewport top" },
    .{ .chord = Chord.two('z', 'b'), .action = .scroll_cursor_bottom, .help = "cursor to viewport bottom" },
    .{ .chord = Chord.one('H'), .action = .cursor_view_top, .help = "top of viewport" },
    .{ .chord = Chord.one('M'), .action = .cursor_view_middle, .help = "middle of viewport" },
    .{ .chord = Chord.one('L'), .action = .cursor_view_bottom, .help = "bottom of viewport" },
    .{ .chord = Chord.modified(vaxis.Key.down, .{ .shift = true }), .action = .select_down, .help = "extend selection down" },
    .{ .chord = Chord.modified(vaxis.Key.up, .{ .shift = true }), .action = .select_up, .help = "extend selection up" },
    // --- commands ---
    .{ .chord = Chord.one('q'), .action = .quit, .help = "quit" },
    .{ .chord = Chord.modified('c', .{ .ctrl = true }), .action = .quit, .help = "quit" },
    .{ .chord = Chord.one('F'), .action = .open_file_finder, .help = "open File finder" },
    .{ .chord = Chord.one('p'), .action = .open_pull_request_picker, .help = "open PullRequest Picker" },
    .{ .chord = Chord.one('R'), .action = .refresh, .help = "refresh review" },
    .{ .chord = Chord.one('s'), .action = .toggle_layout, .help = "toggle unified / side-by-side" },
    .{ .chord = Chord.one('f'), .action = .cycle_scope, .help = "cycle diff scope" },
    .{ .chord = Chord.one('v'), .action = .toggle_select, .help = "toggle visual selection" },
    .{ .chord = Chord.one(vaxis.Key.escape), .action = .clear_selection, .help = "clear selection" },
    .{ .chord = Chord.one('i'), .action = .inline_comment, .help = "inline comment" },
    .{ .chord = Chord.one('I'), .action = .file_comment, .help = "File-level comment" },
    .{ .chord = Chord.one('C'), .action = .review_comment, .help = "Review-level comment" },
    .{ .chord = Chord.one('S'), .action = .suggest, .help = "suggestion" },
    .{ .chord = Chord.one('o'), .action = .isolate, .help = "isolate / exit file" },
    .{ .chord = Chord.one(']'), .action = .next_file, .help = "next file" },
    .{ .chord = Chord.one('['), .action = .prev_file, .help = "previous file" },
    .{ .chord = Chord.one('r'), .action = .reply, .help = "reply" },
    .{ .chord = Chord.one('e'), .action = .edit_review_item, .help = "edit local Draft" },
    .{ .chord = Chord.one('a'), .action = .reanchor_review_item, .help = "re-anchor local root Draft" },
    .{ .chord = Chord.one('D'), .action = .delete_review_item, .help = "delete local Draft subtree" },
    .{ .chord = Chord.one(vaxis.Key.enter), .action = .toggle_disclosure, .help = "toggle disclosure" },
    .{ .chord = Chord.one(vaxis.Key.enter), .action = .toggle_review_card, .help = "toggle ReviewCard" },
    .{ .chord = Chord.one(vaxis.Key.enter), .action = .toggle_directory, .help = "toggle Directory" },
    .{ .chord = Chord.one(vaxis.Key.enter), .action = .focus_file, .help = "focus File" },
    .{ .chord = Chord.one(vaxis.Key.enter), .action = .confirm_picker, .help = "confirm selection" },
    .{ .chord = Chord.one('X'), .action = .submit, .help = "submit review" },
    .{ .chord = Chord.one('Y'), .action = .recover_submission, .help = "resume interrupted submission" },
    .{ .chord = Chord.one('U'), .action = .resolve_unpublished, .help = "mark unknown draft unpublished" },
    .{ .chord = Chord.two('g', 'C'), .action = .link_existing_comment, .help = "link unknown draft to comment" },
    .{ .chord = Chord.one('y'), .action = .yank, .help = "yank source text" },
    .{ .chord = Chord.one('?'), .action = .help, .help = "toggle this help" },
    .{ .chord = Chord.one(vaxis.Key.tab), .action = .focus_next_pane, .help = "switch Pane" },
};

pub const Keymap = struct {
    bindings: []const Binding,

    pub const default = Keymap{ .bindings = &default_bindings };

    pub fn fromOverrides(allocator: std.mem.Allocator, overrides: []const Override) !OwnedKeymap {
        var bindings: std.ArrayList(Binding) = .empty;
        errdefer bindings.deinit(allocator);
        try bindings.appendSlice(allocator, &default_bindings);

        for (overrides) |override| {
            const action = actionFromName(override.action) orelse return error.UnknownAction;
            var index: usize = 0;
            while (index < bindings.items.len) {
                if (bindings.items[index].action == action) _ = bindings.orderedRemove(index) else index += 1;
            }
            for (override.sequences) |sequence| {
                const chord = try parseSequence(sequence);
                try bindings.append(allocator, .{ .chord = chord, .action = action, .help = helpFor(action) });
            }
        }
        try validateBindings(bindings.items);
        return .{ .bindings = try bindings.toOwnedSlice(allocator) };
    }
};

pub const Override = struct {
    action: []const u8,
    sequences: []const []const u8 = &.{},
};

pub fn validateOverride(override: Override) !void {
    if (actionFromName(override.action) == null) return error.UnknownAction;
    for (override.sequences) |sequence| _ = try parseSequence(sequence);
}

pub const SequenceConflict = enum { duplicate, prefix };

pub fn sequenceConflict(a_text: []const u8, b_text: []const u8) !?SequenceConflict {
    const a = try parseSequence(a_text);
    const b = try parseSequence(b_text);
    if (sameChord(a, b)) return .duplicate;
    const shorter, const longer = if (a.len() < b.len()) .{ a, b } else .{ b, a };
    if (shorter.len() == longer.len()) return null;
    for (0..shorter.len()) |i| if (!sameStroke(shorter.at(i), longer.at(i))) return null;
    return .prefix;
}

pub const OwnedKeymap = struct {
    bindings: []Binding,

    pub fn deinit(self: *OwnedKeymap, allocator: std.mem.Allocator) void {
        allocator.free(self.bindings);
        self.* = undefined;
    }

    pub fn keymap(self: *const OwnedKeymap) Keymap {
        return .{ .bindings = self.bindings };
    }
};

fn parseSequence(text: []const u8) !Chord {
    var strokes: [8]Stroke = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |token| {
        if (count == strokes.len) return error.SequenceTooLong;
        strokes[count] = try parseStroke(token);
        count += 1;
    }
    if (count == 0) return error.EmptySequence;
    if (strokes[0].cp >= '0' and strokes[0].cp <= '9') return error.CountConflict;
    return .{ .strokes = strokes, .count = @intCast(count) };
}

fn parseStroke(text: []const u8) !Stroke {
    var rest = text;
    var mods: Modifiers = .{};
    while (true) {
        const dash = std.mem.indexOfScalar(u8, rest, '-') orelse break;
        const part = rest[0..dash];
        if (modifier(part, &mods)) {
            rest = rest[dash + 1 ..];
        } else break;
    }
    if (rest.len == 0) return error.MissingKey;
    const cp = keyCode(rest) orelse return error.UnknownKey;
    return .{ .cp = cp, .mods = mods };
}

fn modifier(name: []const u8, mods: *Modifiers) bool {
    if (std.mem.eql(u8, name, "shift")) mods.shift = true else if (std.mem.eql(u8, name, "alt") or std.mem.eql(u8, name, "option")) mods.alt = true else if (std.mem.eql(u8, name, "ctrl") or std.mem.eql(u8, name, "control")) mods.ctrl = true else if (std.mem.eql(u8, name, "super") or std.mem.eql(u8, name, "cmd") or std.mem.eql(u8, name, "command")) mods.super = true else if (std.mem.eql(u8, name, "hyper")) mods.hyper = true else if (std.mem.eql(u8, name, "meta")) mods.meta = true else return false;
    return true;
}

fn keyCode(name: []const u8) ?u21 {
    if (name.len == 1) {
        if (std.ascii.isUpper(name[0])) return null;
        return name[0];
    }
    const names = .{
        .{ "space", @as(u21, ' ') },           .{ "enter", vaxis.Key.enter },         .{ "escape", vaxis.Key.escape },
        .{ "up", vaxis.Key.up },               .{ "down", vaxis.Key.down },           .{ "left", vaxis.Key.left },
        .{ "right", vaxis.Key.right },         .{ "home", vaxis.Key.home },           .{ "end", vaxis.Key.end },
        .{ "page-up", vaxis.Key.page_up },     .{ "page-down", vaxis.Key.page_down }, .{ "tab", vaxis.Key.tab },
        .{ "backspace", vaxis.Key.backspace }, .{ "delete", vaxis.Key.delete },       .{ "insert", vaxis.Key.insert },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    if (name.len >= 2 and name[0] == 'f') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 35) return vaxis.Key.f1 + n - 1;
    }
    return null;
}

fn actionFromName(name: []const u8) ?Action {
    inline for (std.meta.fields(Action)) |field| {
        if (canonicalNameEqual(name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn canonicalNameEqual(configured: []const u8, tag: []const u8) bool {
    return std.mem.eql(u8, configured, tag);
}

fn helpFor(action: Action) []const u8 {
    for (default_bindings) |binding| if (binding.action == action) return binding.help;
    return @tagName(action);
}

fn sameStroke(a: Stroke, b: Stroke) bool {
    return a.cp == b.cp and a.mods.eql(b.mods);
}

fn sameChord(a: Chord, b: Chord) bool {
    if (a.len() != b.len()) return false;
    for (0..a.len()) |i| if (!sameStroke(a.at(i), b.at(i))) return false;
    return true;
}

fn findChord(bindings: []const Binding, chord: Chord) ?usize {
    for (bindings, 0..) |binding, i| if (sameChord(binding.chord, chord)) return i;
    return null;
}

fn validateBindings(bindings: []const Binding) !void {
    for (bindings, 0..) |a, i| for (bindings[i + 1 ..]) |b| {
        if (sameChord(a.chord, b.chord) and a.action != b.action and contextsOverlap(a.action, b.action)) return error.AmbiguousContext;
        const shorter, const longer = if (a.chord.len() < b.chord.len()) .{ a.chord, b.chord } else .{ b.chord, a.chord };
        if (shorter.len() == longer.len()) continue;
        var prefix = true;
        for (0..shorter.len()) |j| if (!sameStroke(shorter.at(j), longer.at(j))) {
            prefix = false;
            break;
        };
        if (prefix) return error.PrefixConflict;
    };
}

pub fn supportsContext(action: Action, context: InteractionContext) bool {
    return switch (context) {
        .composer, .help, .unknown_resolution, .delete_confirmation => false,
        .file_finder, .pull_request_picker => switch (action) {
            .up, .down, .confirm_picker, .quit => true,
            else => false,
        },
        .sidebar_directory => switch (action) {
            .down,
            .up,
            .left,
            .right,
            .to_top,
            .to_bottom,
            .scroll_row_up,
            .scroll_row_down,
            .quit,
            .open_file_finder,
            .open_pull_request_picker,
            .refresh,
            .review_comment,
            .submit,
            .recover_submission,
            .resolve_unpublished,
            .link_existing_comment,
            .help,
            .toggle_layout,
            .cycle_scope,
            .toggle_directory,
            .focus_next_pane,
            => true,
            else => false,
        },
        .sidebar_file => switch (action) {
            .down,
            .up,
            .left,
            .right,
            .to_top,
            .to_bottom,
            .scroll_row_up,
            .scroll_row_down,
            .quit,
            .open_file_finder,
            .open_pull_request_picker,
            .refresh,
            .file_comment,
            .review_comment,
            .submit,
            .recover_submission,
            .resolve_unpublished,
            .link_existing_comment,
            .help,
            .toggle_layout,
            .cycle_scope,
            .focus_file,
            .focus_next_pane,
            => true,
            else => false,
        },
        .sidebar => switch (action) {
            .down,
            .up,
            .left,
            .right,
            .quit,
            .open_file_finder,
            .open_pull_request_picker,
            .refresh,
            .review_comment,
            .help,
            .focus_next_pane,
            => true,
            else => false,
        },
        .diff_disclosure => switch (action) {
            .toggle_disclosure => true,
            else => supportsContext(action, .diff),
        },
        .diff_review_card => switch (action) {
            .toggle_review_card, .reply, .edit_review_item, .reanchor_review_item, .delete_review_item => true,
            else => supportsContext(action, .diff),
        },
        .diff_source => switch (action) {
            .inline_comment, .suggest, .yank => true,
            else => supportsContext(action, .diff),
        },
        .diff => switch (action) {
            .down,
            .up,
            .half_page_down,
            .half_page_up,
            .page_down,
            .page_up,
            .to_top,
            .to_bottom,
            .center,
            .scroll_cursor_top,
            .scroll_cursor_bottom,
            .cursor_view_top,
            .cursor_view_middle,
            .cursor_view_bottom,
            .scroll_row_up,
            .scroll_row_down,
            .select_down,
            .select_up,
            .quit,
            .open_file_finder,
            .open_pull_request_picker,
            .refresh,
            .inline_comment,
            .file_comment,
            .review_comment,
            .suggest,
            .yank,
            .submit,
            .recover_submission,
            .resolve_unpublished,
            .link_existing_comment,
            .help,
            .toggle_select,
            .clear_selection,
            .toggle_layout,
            .cycle_scope,
            .isolate,
            .next_file,
            .prev_file,
            .focus_next_pane,
            => true,
            else => false,
        },
    };
}

fn contextsOverlap(a: Action, b: Action) bool {
    inline for (std.meta.fields(InteractionContext)) |field| {
        const context: InteractionContext = @enumFromInt(field.value);
        if (supportsContext(a, context) and supportsContext(b, context)) return true;
    }
    return false;
}

/// Threads multi-chord Action grammar across keypresses. Presentation owns one
/// resolver and resets it when a replacement Session publishes. `Nav` owns the
/// Count, so the resolver only tracks the pending Keymap sequence.
pub const Resolver = struct {
    leader: ?u21 = null,
    pending: [8]Stroke = undefined,
    pending_len: u4 = 0,

    pub const Result = union(enum) {
        /// Consumed with nothing to do yet (leader armed) or an unbound key.
        none,
        /// A numeric Count digit (0–9) to feed `Nav.pushDigit`.
        digit: u8,
        /// A resolved viewer action.
        action: Action,
    };

    pub fn feed(self: *Resolver, km: Keymap, context: InteractionContext, key: KeyStroke) Result {
        if (self.pending_len > 0 and key.matches(vaxis.Key.escape, .{})) {
            self.pending_len = 0;
            self.leader = null;
            return .none;
        }
        // A numeric Count prefix.
        if (self.pending_len == 0) if (key.text) |t| {
            if (t.len == 1 and t[0] >= '0' and t[0] <= '9') return .{ .digit = t[0] - '0' };
        };
        var has_prefix = false;
        var matched_stroke: Stroke = undefined;
        for (km.bindings) |binding| {
            if (!supportsContext(binding.action, context)) continue;
            if (self.pending_len >= binding.chord.len()) continue;
            var matches = true;
            for (0..self.pending_len) |i| {
                const expected = binding.chord.at(i);
                if (!sameStroke(self.pending[i], expected)) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;
            const expected = binding.chord.at(self.pending_len);
            if (!key.matches(expected.cp, expected.mods)) continue;
            if (self.pending_len + 1 == binding.chord.len()) {
                self.pending_len = 0;
                self.leader = null;
                return .{ .action = binding.action };
            }
            has_prefix = true;
            matched_stroke = expected;
        }
        if (has_prefix) {
            self.pending[self.pending_len] = matched_stroke;
            self.pending_len += 1;
            self.leader = self.pending[0].cp;
            return .none;
        }
        self.pending_len = 0;
        self.leader = null;
        return .none;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn plain(cp: u21) KeyStroke {
    return .{ .codepoint = cp };
}

test "single-key actions and motions resolve" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expectEqual(Action.quit, res.feed(km, .diff, plain('q')).action);
    try testing.expectEqual(Action.down, res.feed(km, .diff, plain('j')).action);
    try testing.expectEqual(Action.to_bottom, res.feed(km, .diff, plain('G')).action);
    try testing.expectEqual(Action.cursor_view_middle, res.feed(km, .diff, plain('M')).action);
    try testing.expectEqual(Action.reply, res.feed(km, .diff_review_card, plain('r')).action);
    try testing.expectEqual(Action.help, res.feed(km, .diff, .{ .codepoint = '?', .text = "?" }).action);
}

test "isMotion separates movement from commands" {
    try testing.expect(isMotion(.down));
    try testing.expect(isMotion(.center));
    try testing.expect(isMotion(.select_up));
    try testing.expect(!isMotion(.reply));
    try testing.expect(!isMotion(.help));
}

test "ctrl chords resolve and don't collide with their plain letters" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expectEqual(Action.half_page_down, res.feed(km, .diff, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }).action);
    try testing.expectEqual(Action.page_down, res.feed(km, .diff, .{ .codepoint = 'f', .mods = .{ .ctrl = true } }).action);
    // Plain 'f' is a different action (cycle scope), not page down.
    try testing.expectEqual(Action.cycle_scope, res.feed(km, .diff, plain('f')).action);
    // ctrl-c quits, like q.
    try testing.expectEqual(Action.quit, res.feed(km, .diff, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }).action);
    try testing.expect(res.feed(km, .diff, plain('c')) == .none);
}

test "gg and the z-leader motions need two keys" {
    const km = Keymap.default;
    var res = Resolver{};
    // First g arms the leader (nothing yet), second g fires.
    try testing.expect(res.feed(km, .diff, plain('g')) == .none);
    try testing.expectEqual(@as(?u21, 'g'), res.leader);
    try testing.expectEqual(Action.to_top, res.feed(km, .diff, plain('g')).action);
    try testing.expect(res.leader == null);

    try testing.expect(res.feed(km, .diff, plain('z')) == .none);
    try testing.expectEqual(Action.center, res.feed(km, .diff, plain('z')).action);
    try testing.expect(res.feed(km, .diff, plain('z')) == .none);
    try testing.expectEqual(Action.scroll_cursor_top, res.feed(km, .diff, plain('t')).action);
    try testing.expect(res.feed(km, .diff, plain('z')) == .none);
    try testing.expectEqual(Action.scroll_cursor_bottom, res.feed(km, .diff, plain('b')).action);
}

test "an invalid leader combo is dropped, not misread" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expect(res.feed(km, .diff, plain('g')) == .none); // arm g
    try testing.expect(res.feed(km, .diff, plain('x')) == .none); // gx: dropped
    try testing.expect(res.leader == null);
    // A fresh 'j' after the aborted combo still moves.
    try testing.expectEqual(Action.down, res.feed(km, .diff, plain('j')).action);
}

test "numeric Count digits surface as digit results, not actions" {
    const km = Keymap.default;
    var res = Resolver{};
    const r = res.feed(km, .diff, .{ .codepoint = '5', .text = "5" });
    try testing.expectEqual(@as(u8, 5), r.digit);
}

test "shift+arrow resolves to a selection motion" {
    const km = Keymap.default;
    var res = Resolver{};
    const r = res.feed(km, .diff, .{ .codepoint = vaxis.Key.down, .mods = .{ .shift = true } });
    try testing.expectEqual(Action.select_down, r.action);
    // Plain arrow is a bare motion.
    try testing.expectEqual(Action.down, res.feed(km, .diff, plain(vaxis.Key.down)).action);
}

test "an unbound key resolves to none" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expect(res.feed(km, .diff, plain('Z')) == .none);
}

test "Action-oriented configuration replaces all chords and empty list unbinds" {
    const overrides = [_]Override{
        .{ .action = "page_down", .sequences = &.{"ctrl-x"} },
        .{ .action = "quit", .sequences = &.{} },
        .{ .action = "review_comment", .sequences = &.{"space x c"} },
    };
    var configured = try Keymap.fromOverrides(testing.allocator, &overrides);
    defer configured.deinit(testing.allocator);

    var resolver = Resolver{};
    try testing.expectEqual(Action.page_down, resolver.feed(configured.keymap(), .diff, .{ .codepoint = 'x', .mods = .{ .ctrl = true } }).action);
    try testing.expect(resolver.feed(configured.keymap(), .diff, plain('q')) == .none);
    try testing.expect(resolver.feed(configured.keymap(), .diff, plain(' ')) == .none);
    try testing.expect(resolver.feed(configured.keymap(), .diff, plain('x')) == .none);
    try testing.expectEqual(Action.review_comment, resolver.feed(configured.keymap(), .diff, plain('c')).action);
}

test "Escape cancels a pending sequence and aliases normalize before conflict checks" {
    const overrides = [_]Override{.{ .action = "review_comment", .sequences = &.{"space x c"} }};
    var configured = try Keymap.fromOverrides(testing.allocator, &overrides);
    defer configured.deinit(testing.allocator);
    var resolver = Resolver{};
    try testing.expect(resolver.feed(configured.keymap(), .diff, plain(' ')) == .none);
    try testing.expect(resolver.feed(configured.keymap(), .diff, plain(vaxis.Key.escape)) == .none);
    try testing.expectEqual(Action.reply, resolver.feed(configured.keymap(), .diff_review_card, plain('r')).action);

    try testing.expectEqual(SequenceConflict.duplicate, (try sequenceConflict("ctrl-d", "control-d")).?);
    try testing.expectEqual(SequenceConflict.prefix, (try sequenceConflict("space r", "space r c")).?);
}

test "Enter resolves to the precise Action for mutually exclusive targets" {
    var resolver = Resolver{};
    try testing.expectEqual(Action.toggle_disclosure, resolver.feed(.default, .diff_disclosure, plain(vaxis.Key.enter)).action);
    try testing.expectEqual(Action.toggle_review_card, resolver.feed(.default, .diff_review_card, plain(vaxis.Key.enter)).action);
    try testing.expectEqual(Action.toggle_directory, resolver.feed(.default, .sidebar_directory, plain(vaxis.Key.enter)).action);
    try testing.expectEqual(Action.focus_file, resolver.feed(.default, .sidebar_file, plain(vaxis.Key.enter)).action);
    try testing.expectEqual(Action.confirm_picker, resolver.feed(.default, .file_finder, plain(vaxis.Key.enter)).action);
    try testing.expect(resolver.feed(.default, .composer, plain(vaxis.Key.enter)) == .none);
}

test "the default bindings are themselves unambiguous and prefix-free" {
    try validateBindings(&default_bindings);
    var resolver = Resolver{};
    try testing.expectEqual(Action.reanchor_review_item, resolver.feed(.default, .diff_review_card, plain('a')).action);
    // Re-anchor belongs to a ReviewCard, not to bare source.
    try testing.expect(resolver.feed(.default, .diff_source, plain('a')) == .none);
}

test "same chord is rejected when Actions overlap in an Interaction Context" {
    const overrides = [_]Override{
        .{ .action = "down", .sequences = &.{"x"} },
        .{ .action = "up", .sequences = &.{"x"} },
    };
    try testing.expectError(error.AmbiguousContext, Keymap.fromOverrides(testing.allocator, &overrides));
}
