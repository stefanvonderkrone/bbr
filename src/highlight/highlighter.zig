//! C-free Highlighting seam and its plain adapter.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CaptureRole = enum(u8) {
    unknown,
    comment,
    string,
    keyword,
    function,
    type,
    constant,
    variable,
    property,
    punctuation,
    tag,
};

/// A query-local Capture identity with its preclassified Theme role.
pub const Capture = struct {
    id: u16,
    role: CaptureRole,

    pub fn init(id: u16, name: []const u8) Capture {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
        const root = name[0..dot];
        const role: CaptureRole = if (std.mem.eql(u8, root, "comment"))
            .comment
        else if (std.mem.eql(u8, root, "string"))
            .string
        else if (std.mem.eql(u8, root, "keyword") or std.mem.eql(u8, root, "operator"))
            .keyword
        else if (std.mem.eql(u8, root, "function") or std.mem.eql(u8, root, "method") or std.mem.eql(u8, root, "constructor"))
            .function
        else if (std.mem.eql(u8, root, "type"))
            .type
        else if (std.mem.eql(u8, root, "constant") or std.mem.eql(u8, root, "number") or std.mem.eql(u8, root, "boolean"))
            .constant
        else if (std.mem.eql(u8, root, "variable") or std.mem.eql(u8, root, "label"))
            .variable
        else if (std.mem.eql(u8, root, "property") or std.mem.eql(u8, root, "attribute"))
            .property
        else if (std.mem.eql(u8, root, "punctuation"))
            .punctuation
        else if (std.mem.eql(u8, root, "tag"))
            .tag
        else
            .unknown;
        return .{ .id = id, .role = role };
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

test "Capture classifies hierarchical names once" {
    try testing.expectEqual(CaptureRole.function, Capture.init(7, "function.call.builtin").role);
    try testing.expectEqual(CaptureRole.keyword, Capture.init(8, "operator").role);
    try testing.expectEqual(CaptureRole.unknown, Capture.init(9, "future.capture").role);
}

test "PlainHighlighter satisfies the seam with no Spans" {
    var plain: PlainHighlighter = .{};
    const result = try plain.highlighter().highlight(testing.allocator, "src/main.go", "package main\n");
    try testing.expectEqual(@as(usize, 0), result.spans.len);
}
