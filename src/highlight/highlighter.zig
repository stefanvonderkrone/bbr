//! C-free Highlighting seam and its plain adapter.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A hierarchical syntax role. Names use dot-separated specificity, for
/// example `function.call`; Theme resolution may fall back to `function`.
pub const Capture = struct {
    name: []const u8,

    pub fn parent(self: Capture) ?Capture {
        const at = std.mem.lastIndexOfScalar(u8, self.name, '.') orelse return null;
        return .{ .name = self.name[0..at] };
    }
};

/// A half-open UTF-8 byte range within one numbered file line.
pub const Span = struct {
    line: u32,
    start: usize,
    end: usize,
    capture: Capture,
};

pub const Result = struct {
    spans: []const Span,
};

/// Side-specific syntax analysis retained by a Session. `null` means that side
/// has not produced a usable result; a ready plain result has an empty slice.
pub const FileHighlights = struct {
    old: ?Result = null,
    new: ?Result = null,
};

pub const SideState = enum { pending, absent, loading, ready, skipped_too_large, fetch_failed, highlight_failed };

pub const FileHighlightStatus = struct {
    old: SideState = .pending,
    new: SideState = .pending,
};

pub const Highlighter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        highlight: *const fn (ptr: *anyopaque, allocator: Allocator, path: []const u8, content: []const u8) anyerror!Result,
    };

    pub fn highlight(self: Highlighter, allocator: Allocator, path: []const u8, content: []const u8) !Result {
        return self.vtable.highlight(self.ptr, allocator, path, content);
    }
};

/// The fallback adapter: every file remains on the Theme's default foreground.
pub const PlainHighlighter = struct {
    pub fn highlighter(self: *PlainHighlighter) Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Highlighter.VTable = .{ .highlight = highlightImpl };

    fn highlightImpl(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror!Result {
        return .{ .spans = &.{} };
    }
};

const testing = std.testing;

test "Capture walks hierarchical parents" {
    const specific: Capture = .{ .name = "function.call.builtin" };
    const parent = specific.parent().?;
    try testing.expectEqualStrings("function.call", parent.name);
    try testing.expectEqualStrings("function", parent.parent().?.name);
    try testing.expect(parent.parent().?.parent() == null);
}

test "PlainHighlighter satisfies the seam with no Spans" {
    var plain: PlainHighlighter = .{};
    const result = try plain.highlighter().highlight(testing.allocator, "src/main.go", "package main\n");
    try testing.expectEqual(@as(usize, 0), result.spans.len);
}
