//! Nav — cursor/scroll state and the Motions that move them. Pure: no vaxis, no
//! I/O, so the motion arithmetic is unit-tested directly. The renderer reads
//! `cursor`/`scroll`; the event loop feeds it keys.
//!
//! Model: `cursor` is the selected row in the Buffer; `scroll` is the index of
//! the top visible row. After any motion, `scroll` is nudged just enough to keep
//! the cursor inside the viewport (no centering — that's `zz`, a later motion).

const std = @import("std");

pub const Nav = struct {
    /// Selected row index, always in `[0, row_count)` (0 when empty).
    cursor: usize = 0,
    /// Index of the top visible row.
    scroll: usize = 0,
    /// Pending numeric prefix (Count) for the next Motion; 0 means "none".
    count: usize = 0,

    row_count: usize,
    /// Visible rows in the pane; at least 1 so paging always advances.
    viewport: usize,

    pub fn init(row_count: usize, viewport: usize) Nav {
        return .{ .row_count = row_count, .viewport = @max(viewport, 1) };
    }

    /// Feed a decimal digit into the pending Count (e.g. `5` then `j`).
    pub fn pushDigit(self: *Nav, d: u8) void {
        std.debug.assert(d <= 9);
        self.count = self.count *| 10 +| d;
    }

    /// Consume the pending Count, defaulting to 1, and clear it.
    fn takeCount(self: *Nav) usize {
        const c = if (self.count == 0) 1 else self.count;
        self.count = 0;
        return c;
    }

    /// Update `viewport` (on resize) and re-clamp scroll to keep the cursor visible.
    pub fn setViewport(self: *Nav, viewport: usize) void {
        self.viewport = @max(viewport, 1);
        self.clampScroll();
    }

    /// Re-clamp against a new row count (e.g. after loading a different file).
    pub fn setRowCount(self: *Nav, row_count: usize) void {
        self.row_count = row_count;
        if (self.cursor >= row_count) self.cursor = if (row_count == 0) 0 else row_count - 1;
        self.clampScroll();
    }

    pub fn down(self: *Nav) void {
        self.moveTo(self.cursor +| self.takeCount());
    }

    pub fn up(self: *Nav) void {
        const n = self.takeCount();
        self.moveTo(if (n >= self.cursor) 0 else self.cursor - n);
    }

    /// `ctrl-d` — down half a viewport (times Count).
    pub fn halfPageDown(self: *Nav) void {
        const step = (self.viewport / 2) *| self.takeCount();
        self.moveTo(self.cursor +| @max(step, 1));
    }

    /// `ctrl-u` — up half a viewport (times Count).
    pub fn halfPageUp(self: *Nav) void {
        const step = (self.viewport / 2) *| self.takeCount();
        self.moveTo(if (step >= self.cursor) 0 else self.cursor - @max(step, 1));
    }

    /// `gg` — first row (or line N with a Count, 1-based).
    pub fn toTop(self: *Nav) void {
        const c = self.count;
        self.count = 0;
        self.moveTo(if (c == 0) 0 else c - 1);
    }

    /// `G` — last row (or line N with a Count, 1-based).
    pub fn toBottom(self: *Nav) void {
        const c = self.count;
        self.count = 0;
        self.moveTo(if (c == 0) self.lastRow() else c - 1);
    }

    fn lastRow(self: Nav) usize {
        return if (self.row_count == 0) 0 else self.row_count - 1;
    }

    fn moveTo(self: *Nav, target: usize) void {
        self.cursor = @min(target, self.lastRow());
        self.clampScroll();
    }

    /// Keep the cursor within `[scroll, scroll + viewport)`.
    fn clampScroll(self: *Nav) void {
        if (self.cursor < self.scroll) {
            self.scroll = self.cursor;
        } else if (self.cursor >= self.scroll +| self.viewport) {
            self.scroll = self.cursor + 1 - self.viewport;
        }
        // Don't scroll past the point where the last row sits at pane bottom
        // unless the content is shorter than the viewport.
        const max_scroll = if (self.row_count > self.viewport) self.row_count - self.viewport else 0;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
    }
};

// ---------------------------------------------------------------------------
// Tests — pure arithmetic.
// ---------------------------------------------------------------------------
const testing = std.testing;

test "down/up move the cursor and clamp at the ends" {
    var nav = Nav.init(100, 10);
    nav.down();
    try testing.expectEqual(@as(usize, 1), nav.cursor);
    nav.up();
    try testing.expectEqual(@as(usize, 0), nav.cursor);
    nav.up(); // already at top
    try testing.expectEqual(@as(usize, 0), nav.cursor);
}

test "Count prefix multiplies a motion and then clears" {
    var nav = Nav.init(100, 10);
    nav.pushDigit(5);
    nav.down();
    try testing.expectEqual(@as(usize, 5), nav.cursor);
    // Count was cleared, so the next down moves by 1.
    nav.down();
    try testing.expectEqual(@as(usize, 6), nav.cursor);
}

test "multi-digit Count accumulates" {
    var nav = Nav.init(1000, 10);
    nav.pushDigit(1);
    nav.pushDigit(2);
    nav.down();
    try testing.expectEqual(@as(usize, 12), nav.cursor);
}

test "scroll follows the cursor down and up" {
    var nav = Nav.init(100, 10);
    nav.pushDigit(9);
    nav.down(); // cursor 9, still last visible row
    try testing.expectEqual(@as(usize, 0), nav.scroll);
    nav.down(); // cursor 10 → scroll to 1
    try testing.expectEqual(@as(usize, 10), nav.cursor);
    try testing.expectEqual(@as(usize, 1), nav.scroll);
}

test "half page down/up steps by viewport/2" {
    var nav = Nav.init(100, 10);
    nav.halfPageDown();
    try testing.expectEqual(@as(usize, 5), nav.cursor);
    nav.halfPageDown();
    try testing.expectEqual(@as(usize, 10), nav.cursor);
    nav.halfPageUp();
    try testing.expectEqual(@as(usize, 5), nav.cursor);
}

test "gg and G jump to ends; G scroll shows the bottom" {
    var nav = Nav.init(100, 10);
    nav.toBottom();
    try testing.expectEqual(@as(usize, 99), nav.cursor);
    try testing.expectEqual(@as(usize, 90), nav.scroll); // last page
    nav.toTop();
    try testing.expectEqual(@as(usize, 0), nav.cursor);
    try testing.expectEqual(@as(usize, 0), nav.scroll);
}

test "Count with gg/G goes to a 1-based line" {
    var nav = Nav.init(100, 10);
    nav.pushDigit(4);
    nav.pushDigit(2);
    nav.toTop(); // 42G-style via gg: line 42 → index 41
    try testing.expectEqual(@as(usize, 41), nav.cursor);
}

test "setViewport and setRowCount re-clamp" {
    var nav = Nav.init(100, 10);
    nav.toBottom(); // cursor 99, scroll 90
    nav.setRowCount(20); // shrink: cursor clamps to 19
    try testing.expectEqual(@as(usize, 19), nav.cursor);
    try testing.expectEqual(@as(usize, 10), nav.scroll);
    nav.setViewport(20); // viewport now covers everything → scroll 0
    try testing.expectEqual(@as(usize, 0), nav.scroll);
}

test "empty buffer keeps cursor at 0" {
    var nav = Nav.init(0, 10);
    nav.down();
    try testing.expectEqual(@as(usize, 0), nav.cursor);
    nav.toBottom();
    try testing.expectEqual(@as(usize, 0), nav.cursor);
}
