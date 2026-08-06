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
    /// The other end of a visual selection, or null when nothing is selected.
    /// The selection is the inclusive row range between `mark` and `cursor`.
    /// Motions leave it untouched — the event loop starts/extends/clears it
    /// (via `v`, shift+arrow, Esc), so both input styles share one model.
    mark: ?usize = null,

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
    /// A selection doesn't survive a content change — the rows it named are gone.
    pub fn setRowCount(self: *Nav, row_count: usize) void {
        self.row_count = row_count;
        if (self.cursor >= row_count) self.cursor = if (row_count == 0) 0 else row_count - 1;
        self.mark = null;
        self.clampScroll();
    }

    // --- visual selection ---------------------------------------------------

    /// `v` — toggle a selection: start one at the cursor, or clear the current.
    pub fn toggleMark(self: *Nav) void {
        self.mark = if (self.mark == null) self.cursor else null;
    }

    /// Begin a selection at the cursor if none is active (the shift+arrow entry).
    pub fn ensureMark(self: *Nav) void {
        if (self.mark == null) self.mark = self.cursor;
    }

    /// Drop any active selection (Esc, or once an action consumes it).
    pub fn clearMark(self: *Nav) void {
        self.mark = null;
    }

    pub fn hasSelection(self: Nav) bool {
        return self.mark != null;
    }

    /// The selected inclusive row range `.{ lo, hi }`, ordered, or null when
    /// nothing is selected. A single-row selection has `lo == hi`.
    pub fn selection(self: Nav) ?[2]usize {
        const m = self.mark orelse return null;
        return .{ @min(m, self.cursor), @max(m, self.cursor) };
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

    /// `ctrl-f` — down a full viewport (times Count).
    pub fn pageDown(self: *Nav) void {
        self.moveTo(self.cursor +| self.viewport *| self.takeCount());
    }

    /// `ctrl-b` — up a full viewport (times Count).
    pub fn pageUp(self: *Nav) void {
        const step = self.viewport *| self.takeCount();
        self.moveTo(if (step >= self.cursor) 0 else self.cursor - step);
    }

    // --- scroll positioning (cursor stays; the viewport moves) ---------------
    // These set `scroll` directly; the cursor is left where it is and stays
    // visible by construction, so `clampScroll`'s keep-visible branches don't
    // fire — only its end-of-content cap applies (so `zz` near EOF can't center,
    // matching vim). Count is not meaningful, so it's cleared.

    /// `zz` — center the cursor line in the viewport.
    pub fn center(self: *Nav) void {
        self.count = 0;
        const half = self.viewport / 2;
        self.scroll = if (self.cursor > half) self.cursor - half else 0;
        self.clampScroll();
    }

    /// `zt` — scroll so the cursor line sits at the top of the viewport.
    pub fn scrollCursorTop(self: *Nav) void {
        self.count = 0;
        self.scroll = self.cursor;
        self.clampScroll();
    }

    /// `zb` — scroll so the cursor line sits at the bottom of the viewport.
    pub fn scrollCursorBottom(self: *Nav) void {
        self.count = 0;
        self.scroll = if (self.cursor + 1 > self.viewport) self.cursor + 1 - self.viewport else 0;
        self.clampScroll();
    }

    /// Scroll the viewport by signed rows while keeping the cursor visible.
    /// When an edge would pass the cursor, the cursor follows that edge.
    pub fn scrollRows(self: *Nav, delta: isize) void {
        self.count = 0;
        const max_scroll = if (self.row_count > self.viewport) self.row_count - self.viewport else 0;
        if (delta < 0) {
            const amount: usize = @intCast(-delta);
            self.scroll -|= amount;
        } else {
            const amount: usize = @intCast(delta);
            self.scroll = @min(self.scroll +| amount, max_scroll);
        }
        if (self.cursor < self.scroll) self.cursor = self.scroll;
        if (self.cursor >= self.scroll +| self.viewport) self.cursor = self.scroll +| self.viewport -| 1;
    }

    // --- viewport-relative cursor jumps (the viewport stays; the cursor moves) -
    // `H`/`M`/`L`: land the cursor on the row at the top / middle / bottom of the
    // current viewport. The target is already visible, so `moveTo`'s clampScroll
    // leaves `scroll` untouched. Count is cleared.

    /// `H` — cursor to the top visible row.
    pub fn cursorToViewTop(self: *Nav) void {
        self.count = 0;
        self.moveTo(self.scroll);
    }

    /// `M` — cursor to the middle visible row.
    pub fn cursorToViewMiddle(self: *Nav) void {
        self.count = 0;
        self.moveTo(self.scroll + self.viewport / 2);
    }

    /// `L` — cursor to the bottom visible row.
    pub fn cursorToViewBottom(self: *Nav) void {
        self.count = 0;
        self.moveTo(self.scroll +| self.viewport -| 1);
    }

    /// Jump straight to `target` (clamped), clearing any pending Count. Used for
    /// absolute moves that aren't `gg`/`G` — e.g. jump-to-file-header.
    pub fn jumpTo(self: *Nav, target: usize) void {
        self.count = 0;
        self.moveTo(target);
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

test "row scrolling moves the viewport and only carries the cursor at an edge" {
    var nav = Nav.init(20, 5);
    nav.jumpTo(2);
    nav.scrollRows(1);
    try testing.expectEqual(@as(usize, 1), nav.scroll);
    try testing.expectEqual(@as(usize, 2), nav.cursor);
    nav.scrollRows(4);
    try testing.expectEqual(@as(usize, 5), nav.scroll);
    try testing.expectEqual(@as(usize, 5), nav.cursor);
    nav.scrollRows(-2);
    try testing.expectEqual(@as(usize, 3), nav.scroll);
    try testing.expectEqual(@as(usize, 5), nav.cursor);
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

test "jumpTo moves to an absolute row, clears Count, and scrolls it into view" {
    var nav = Nav.init(100, 10);
    nav.pushDigit(5); // a pending Count must not affect an absolute jump
    nav.jumpTo(50);
    try testing.expectEqual(@as(usize, 50), nav.cursor);
    try testing.expectEqual(@as(usize, 0), nav.count);
    // Scroll clamped so row 50 is visible (bottom of the viewport).
    try testing.expectEqual(@as(usize, 41), nav.scroll);
    // Past the end clamps to the last row.
    nav.jumpTo(999);
    try testing.expectEqual(@as(usize, 99), nav.cursor);
}

test "visual selection: toggle, extend by motion, order, and clear" {
    var nav = Nav.init(100, 10);
    try testing.expect(!nav.hasSelection());
    try testing.expect(nav.selection() == null);

    nav.down(); // cursor 1
    nav.toggleMark(); // start selecting at 1
    try testing.expect(nav.hasSelection());
    nav.pushDigit(3);
    nav.down(); // cursor 4, mark still 1
    try testing.expectEqual([2]usize{ 1, 4 }, nav.selection().?);

    // Extending upward past the mark keeps the range ordered.
    nav.pushDigit(3);
    nav.up(); // cursor 1
    nav.up(); // cursor 0, mark 1
    try testing.expectEqual([2]usize{ 0, 1 }, nav.selection().?);

    nav.toggleMark(); // v again clears it
    try testing.expect(!nav.hasSelection());
}

test "ensureMark starts a selection only when none is active" {
    var nav = Nav.init(100, 10);
    nav.jumpTo(5);
    nav.ensureMark(); // shift+arrow entry: anchor at 5
    nav.down(); // cursor 6
    nav.ensureMark(); // no-op, mark stays at 5
    try testing.expectEqual([2]usize{ 5, 6 }, nav.selection().?);
    nav.clearMark();
    try testing.expect(nav.selection() == null);
}

test "setRowCount drops the selection" {
    var nav = Nav.init(100, 10);
    nav.toggleMark();
    nav.down();
    try testing.expect(nav.hasSelection());
    nav.setRowCount(50);
    try testing.expect(!nav.hasSelection());
}

test "full-page down/up steps by a whole viewport" {
    var nav = Nav.init(100, 10);
    nav.pageDown();
    try testing.expectEqual(@as(usize, 10), nav.cursor);
    nav.pageDown();
    try testing.expectEqual(@as(usize, 20), nav.cursor);
    nav.pageUp();
    try testing.expectEqual(@as(usize, 10), nav.cursor);
    nav.pushDigit(2);
    nav.pageUp(); // 2 pages up, clamps at 0
    try testing.expectEqual(@as(usize, 0), nav.cursor);
}

test "zz/zt/zb reposition the viewport, leaving the cursor line" {
    var nav = Nav.init(100, 10);
    nav.jumpTo(50); // cursor 50, scroll 41
    nav.center();
    try testing.expectEqual(@as(usize, 50), nav.cursor); // cursor unchanged
    try testing.expectEqual(@as(usize, 45), nav.scroll); // 50 - 10/2
    nav.scrollCursorTop();
    try testing.expectEqual(@as(usize, 50), nav.scroll);
    nav.scrollCursorBottom();
    try testing.expectEqual(@as(usize, 41), nav.scroll); // 50 + 1 - 10
    try testing.expectEqual(@as(usize, 50), nav.cursor);
}

test "zz near EOF cannot center past the last page" {
    var nav = Nav.init(100, 10);
    nav.toBottom(); // cursor 99, scroll 90
    nav.center();
    try testing.expectEqual(@as(usize, 99), nav.cursor);
    try testing.expectEqual(@as(usize, 90), nav.scroll); // capped at last page, not 94
}

test "H/M/L land the cursor within the current viewport" {
    var nav = Nav.init(100, 10);
    nav.jumpTo(50); // scroll 41 → visible rows 41..50
    nav.cursorToViewTop();
    try testing.expectEqual(@as(usize, 41), nav.cursor);
    try testing.expectEqual(@as(usize, 41), nav.scroll); // scroll unchanged
    nav.cursorToViewBottom();
    try testing.expectEqual(@as(usize, 50), nav.cursor);
    try testing.expectEqual(@as(usize, 41), nav.scroll);
    nav.cursorToViewMiddle();
    try testing.expectEqual(@as(usize, 46), nav.cursor); // 41 + 10/2
    try testing.expectEqual(@as(usize, 41), nav.scroll);
}

test "empty buffer keeps cursor at 0" {
    var nav = Nav.init(0, 10);
    nav.down();
    try testing.expectEqual(@as(usize, 0), nav.cursor);
    nav.toBottom();
    try testing.expectEqual(@as(usize, 0), nav.cursor);
}
