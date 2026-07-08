//! Keymap — the single source of truth for viewer-mode key bindings (M11).
//!
//! Vim-aligned model: motions and commands are *both* bindings in one table, so
//! the dispatch (`app.zig`) and the help overlay (`render.zig`) read the same
//! data. The two pieces of input *grammar* that don't fit a flat table live in
//! the engine, not the bindings — exactly as vim keeps the Count and multi-key
//! prefix resolution above its mapping table:
//!   * the numeric **Count** prefix (`5j`) is accumulated by `Nav`, and
//!   * a **leader** (the `g` in `gg`, the `z` in `zz`) is a one-key prefix the
//!     `Resolver` tracks; a leader has no standalone binding.
//!
//! Bindings are matched against a live event with the smart `vaxis.Key.matches`,
//! so `S` = shift+`s`, text-vs-codepoint, and caps-lock all resolve the vaxis
//! way rather than by raw equality.
//!
//! Only viewer (normal) mode is tabled here; the Composer and Picker overlays
//! keep their own fixed editing keys (their surface is mostly text entry). User
//! overrides from a config file arrive with M12 — this ships the defaults and
//! the seam. Composer/picker mode bindings can join later if that earns its keep.

const std = @import("std");
const vaxis = @import("vaxis");

/// A discrete viewer action or motion a key resolves to. Everything the viewer
/// does from a keypress is one of these.
pub const Action = enum {
    // motions
    down,
    up,
    half_page_down,
    half_page_up,
    page_down,
    page_up,
    to_top,
    to_bottom,
    center,
    scroll_cursor_top,
    scroll_cursor_bottom,
    cursor_view_top,
    cursor_view_middle,
    cursor_view_bottom,
    select_down,
    select_up,
    // commands
    quit,
    open_picker,
    toggle_resolved,
    toggle_layout,
    cycle_scope,
    comment,
    toggle_select,
    clear_selection,
    inline_comment,
    suggest,
    isolate,
    next_file,
    prev_file,
    reply,
    expand_fold,
    submit,
};

/// A key chord: a codepoint + modifiers, optionally preceded by a `leader` key.
/// `leader == null` is a single keypress; otherwise the binding fires only when
/// `leader` was pressed immediately before (`gg`, `zz`, `zt`, `zb`).
pub const Chord = struct {
    cp: u21,
    mods: vaxis.Key.Modifiers = .{},
    leader: ?u21 = null,
};

pub const Binding = struct {
    chord: Chord,
    action: Action,
    /// A short human label for the help overlay.
    help: []const u8,
};

/// The default viewer bindings. Order matters only for the help overlay's
/// grouping; dispatch resolution is unambiguous (no key maps to two actions).
pub const default_bindings = [_]Binding{
    // --- motions ---
    .{ .chord = .{ .cp = 'j' }, .action = .down, .help = "down" },
    .{ .chord = .{ .cp = vaxis.Key.down }, .action = .down, .help = "down" },
    .{ .chord = .{ .cp = 'k' }, .action = .up, .help = "up" },
    .{ .chord = .{ .cp = vaxis.Key.up }, .action = .up, .help = "up" },
    .{ .chord = .{ .cp = 'd', .mods = .{ .ctrl = true } }, .action = .half_page_down, .help = "half page down" },
    .{ .chord = .{ .cp = vaxis.Key.page_down }, .action = .half_page_down, .help = "half page down" },
    .{ .chord = .{ .cp = 'u', .mods = .{ .ctrl = true } }, .action = .half_page_up, .help = "half page up" },
    .{ .chord = .{ .cp = vaxis.Key.page_up }, .action = .half_page_up, .help = "half page up" },
    .{ .chord = .{ .cp = 'f', .mods = .{ .ctrl = true } }, .action = .page_down, .help = "page down" },
    .{ .chord = .{ .cp = 'b', .mods = .{ .ctrl = true } }, .action = .page_up, .help = "page up" },
    .{ .chord = .{ .cp = 'g', .leader = 'g' }, .action = .to_top, .help = "go to top" },
    .{ .chord = .{ .cp = vaxis.Key.home }, .action = .to_top, .help = "go to top" },
    .{ .chord = .{ .cp = 'G' }, .action = .to_bottom, .help = "go to bottom" },
    .{ .chord = .{ .cp = vaxis.Key.end }, .action = .to_bottom, .help = "go to bottom" },
    .{ .chord = .{ .cp = 'z', .leader = 'z' }, .action = .center, .help = "center cursor" },
    .{ .chord = .{ .cp = 't', .leader = 'z' }, .action = .scroll_cursor_top, .help = "cursor to viewport top" },
    .{ .chord = .{ .cp = 'b', .leader = 'z' }, .action = .scroll_cursor_bottom, .help = "cursor to viewport bottom" },
    .{ .chord = .{ .cp = 'H' }, .action = .cursor_view_top, .help = "top of viewport" },
    .{ .chord = .{ .cp = 'M' }, .action = .cursor_view_middle, .help = "middle of viewport" },
    .{ .chord = .{ .cp = 'L' }, .action = .cursor_view_bottom, .help = "bottom of viewport" },
    .{ .chord = .{ .cp = vaxis.Key.down, .mods = .{ .shift = true } }, .action = .select_down, .help = "extend selection down" },
    .{ .chord = .{ .cp = vaxis.Key.up, .mods = .{ .shift = true } }, .action = .select_up, .help = "extend selection up" },
    // --- commands ---
    .{ .chord = .{ .cp = 'q' }, .action = .quit, .help = "quit" },
    .{ .chord = .{ .cp = 'c', .mods = .{ .ctrl = true } }, .action = .quit, .help = "quit" },
    .{ .chord = .{ .cp = 'p' }, .action = .open_picker, .help = "open PR picker" },
    .{ .chord = .{ .cp = 'R' }, .action = .toggle_resolved, .help = "toggle resolved threads" },
    .{ .chord = .{ .cp = 's' }, .action = .toggle_layout, .help = "toggle unified / side-by-side" },
    .{ .chord = .{ .cp = 'f' }, .action = .cycle_scope, .help = "cycle diff scope" },
    .{ .chord = .{ .cp = 'c' }, .action = .comment, .help = "new PR comment" },
    .{ .chord = .{ .cp = 'v' }, .action = .toggle_select, .help = "toggle visual selection" },
    .{ .chord = .{ .cp = vaxis.Key.escape }, .action = .clear_selection, .help = "clear selection" },
    .{ .chord = .{ .cp = 'i' }, .action = .inline_comment, .help = "inline comment" },
    .{ .chord = .{ .cp = 'S' }, .action = .suggest, .help = "suggestion" },
    .{ .chord = .{ .cp = 'o' }, .action = .isolate, .help = "isolate / exit file" },
    .{ .chord = .{ .cp = ']' }, .action = .next_file, .help = "next file" },
    .{ .chord = .{ .cp = '[' }, .action = .prev_file, .help = "previous file" },
    .{ .chord = .{ .cp = 'r' }, .action = .reply, .help = "reply" },
    .{ .chord = .{ .cp = vaxis.Key.enter }, .action = .expand_fold, .help = "expand fold" },
    .{ .chord = .{ .cp = 'X' }, .action = .submit, .help = "submit review" },
};

pub const Keymap = struct {
    bindings: []const Binding,

    pub const default = Keymap{ .bindings = &default_bindings };

    /// If `key` is a leader (the first key of a two-key motion), return its
    /// codepoint. A leader has no standalone binding, so this never shadows a
    /// real single-key action.
    pub fn leaderOf(self: Keymap, key: vaxis.Key) ?u21 {
        for (self.bindings) |b| {
            if (b.chord.leader) |ld| {
                if (key.matches(ld, .{})) return ld;
            }
        }
        return null;
    }

    /// Resolve a single (leaderless) chord to its action.
    pub fn lookup(self: Keymap, key: vaxis.Key) ?Action {
        for (self.bindings) |b| {
            if (b.chord.leader != null) continue;
            if (key.matches(b.chord.cp, b.chord.mods)) return b.action;
        }
        return null;
    }

    /// Resolve the key pressed after `leader`.
    pub fn lookupAfter(self: Keymap, leader: u21, key: vaxis.Key) ?Action {
        for (self.bindings) |b| {
            const ld = b.chord.leader orelse continue;
            if (ld == leader and key.matches(b.chord.cp, b.chord.mods)) return b.action;
        }
        return null;
    }
};

/// Threads the leader grammar across keypresses. Owned by the event loop; one
/// per viewer. `Nav` owns the Count, so the resolver only tracks the leader.
pub const Resolver = struct {
    leader: ?u21 = null,

    pub const Result = union(enum) {
        /// Consumed with nothing to do yet (leader armed) or an unbound key.
        none,
        /// A numeric Count digit (0–9) to feed `Nav.pushDigit`.
        digit: u8,
        /// A resolved viewer action.
        action: Action,
    };

    pub fn feed(self: *Resolver, km: Keymap, key: vaxis.Key) Result {
        // A leader is armed: this key completes (or aborts) the two-key motion.
        if (self.leader) |ld| {
            self.leader = null;
            if (km.lookupAfter(ld, key)) |a| return .{ .action = a };
            return .none; // an invalid leader combo is dropped, vim-style
        }
        // Arm a leader.
        if (km.leaderOf(key)) |ld| {
            self.leader = ld;
            return .none;
        }
        // A numeric Count prefix.
        if (key.text) |t| {
            if (t.len == 1 and t[0] >= '0' and t[0] <= '9') return .{ .digit = t[0] - '0' };
        }
        // A single-key action.
        if (km.lookup(key)) |a| return .{ .action = a };
        return .none;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn plain(cp: u21) vaxis.Key {
    return .{ .codepoint = cp };
}

test "single-key actions and motions resolve" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expectEqual(Action.quit, res.feed(km, plain('q')).action);
    try testing.expectEqual(Action.down, res.feed(km, plain('j')).action);
    try testing.expectEqual(Action.to_bottom, res.feed(km, plain('G')).action);
    try testing.expectEqual(Action.cursor_view_middle, res.feed(km, plain('M')).action);
    try testing.expectEqual(Action.reply, res.feed(km, plain('r')).action);
}

test "ctrl chords resolve and don't collide with their plain letters" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expectEqual(Action.half_page_down, res.feed(km, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }).action);
    try testing.expectEqual(Action.page_down, res.feed(km, .{ .codepoint = 'f', .mods = .{ .ctrl = true } }).action);
    // Plain 'f' is a different action (cycle scope), not page down.
    try testing.expectEqual(Action.cycle_scope, res.feed(km, plain('f')).action);
    // ctrl-c quits, like q.
    try testing.expectEqual(Action.quit, res.feed(km, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }).action);
    // Plain 'c' is a new comment.
    try testing.expectEqual(Action.comment, res.feed(km, plain('c')).action);
}

test "gg and the z-leader motions need two keys" {
    const km = Keymap.default;
    var res = Resolver{};
    // First g arms the leader (nothing yet), second g fires.
    try testing.expect(res.feed(km, plain('g')) == .none);
    try testing.expectEqual(@as(?u21, 'g'), res.leader);
    try testing.expectEqual(Action.to_top, res.feed(km, plain('g')).action);
    try testing.expect(res.leader == null);

    try testing.expect(res.feed(km, plain('z')) == .none);
    try testing.expectEqual(Action.center, res.feed(km, plain('z')).action);
    try testing.expect(res.feed(km, plain('z')) == .none);
    try testing.expectEqual(Action.scroll_cursor_top, res.feed(km, plain('t')).action);
    try testing.expect(res.feed(km, plain('z')) == .none);
    try testing.expectEqual(Action.scroll_cursor_bottom, res.feed(km, plain('b')).action);
}

test "an invalid leader combo is dropped, not misread" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expect(res.feed(km, plain('g')) == .none); // arm g
    try testing.expect(res.feed(km, plain('x')) == .none); // gx: dropped
    try testing.expect(res.leader == null);
    // A fresh 'j' after the aborted combo still moves.
    try testing.expectEqual(Action.down, res.feed(km, plain('j')).action);
}

test "numeric Count digits surface as digit results, not actions" {
    const km = Keymap.default;
    var res = Resolver{};
    const r = res.feed(km, .{ .codepoint = '5', .text = "5" });
    try testing.expectEqual(@as(u8, 5), r.digit);
}

test "shift+arrow resolves to a selection motion" {
    const km = Keymap.default;
    var res = Resolver{};
    const r = res.feed(km, .{ .codepoint = vaxis.Key.down, .mods = .{ .shift = true } });
    try testing.expectEqual(Action.select_down, r.action);
    // Plain arrow is a bare motion.
    try testing.expectEqual(Action.down, res.feed(km, plain(vaxis.Key.down)).action);
}

test "an unbound key resolves to none" {
    const km = Keymap.default;
    var res = Resolver{};
    try testing.expect(res.feed(km, plain('Z')) == .none);
}
