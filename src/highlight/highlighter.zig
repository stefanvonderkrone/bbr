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

    /// nvim-treesitter names that the root rules classify wrongly. The longest matching prefix wins.
    const prefix_roles = [_]struct { []const u8, CaptureRole }{
        .{ "variable.member", .property },
        .{ "tag.attribute", .property },
        .{ "tag.delimiter", .punctuation },
        .{ "markup.heading", .keyword },
        .{ "markup.raw", .string },
        .{ "markup.link", .string },
        .{ "markup.list", .punctuation },
        .{ "markup.quote", .comment },
        .{ "markup.math", .string },
        .{ "module", .type },
        .{ "character", .string },
    };

    pub fn init(id: u16, name: []const u8) Capture {
        var prefix_len: usize = 0;
        var prefix_role: CaptureRole = .unknown;
        for (prefix_roles) |entry| {
            const prefix, const role = entry;
            const at_boundary = name.len == prefix.len or name.len > prefix.len and name[prefix.len] == '.';
            if (prefix.len > prefix_len and std.mem.startsWith(u8, name, prefix) and at_boundary) {
                prefix_len = prefix.len;
                prefix_role = role;
            }
        }
        if (prefix_len != 0) return .{ .id = id, .role = prefix_role };
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
    start: u32,
    end: u32,
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
        highlight: *const fn (ptr: *anyopaque, result_allocator: Allocator, scratch_allocator: Allocator, path: []const u8, content: []const u8) anyerror!Result,
    };

    pub fn highlight(self: Highlighter, allocator: Allocator, path: []const u8, content: []const u8) !Result {
        return self.highlightWithScratch(allocator, allocator, path, content);
    }

    pub fn highlightWithScratch(self: Highlighter, result_allocator: Allocator, scratch_allocator: Allocator, path: []const u8, content: []const u8) !Result {
        return self.vtable.highlight(self.ptr, result_allocator, scratch_allocator, path, content);
    }
};

/// The fallback adapter: every file remains on the Theme's default foreground.
pub const PlainHighlighter = struct {
    pub fn highlighter(self: *PlainHighlighter) Highlighter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Highlighter.VTable = .{ .highlight = highlightImpl };

    fn highlightImpl(_: *anyopaque, _: Allocator, _: Allocator, _: []const u8, _: []const u8) anyerror!Result {
        return .{ .spans = &.{} };
    }
};

const testing = std.testing;

test "Capture classifies hierarchical names once" {
    try testing.expectEqual(CaptureRole.function, Capture.init(7, "function.call.builtin").role);
    try testing.expectEqual(CaptureRole.keyword, Capture.init(8, "operator").role);
    try testing.expectEqual(CaptureRole.unknown, Capture.init(9, "future.capture").role);
}

test "M27 grammar dotted prefixes map nvim-treesitter Captures to their roles" {
    const cases = [_]struct { []const u8, CaptureRole }{
        .{ "variable.member", .property },
        .{ "variable.member.deep", .property },
        .{ "variable.membership", .variable },
        .{ "variable.parameter", .variable },
        .{ "tag.attribute", .property },
        .{ "tag.delimiter", .punctuation },
        .{ "tag.builtin", .tag },
        .{ "markup.heading", .keyword },
        .{ "markup.heading.1", .keyword },
        .{ "markup.raw.block", .string },
        .{ "markup.link.url", .string },
        .{ "markup.list.checked", .punctuation },
        .{ "markup.quote", .comment },
        .{ "markup.math", .string },
        .{ "module", .type },
        .{ "module.builtin", .type },
        .{ "character", .string },
        .{ "character.special", .string },
        .{ "markup.strong", .unknown },
        .{ "markup.italic", .unknown },
        .{ "markup.strikethrough", .unknown },
        .{ "markup.underline", .unknown },
        .{ "none", .unknown },
        .{ "diff.plus", .unknown },
    };
    for (cases) |case| {
        const name, const role = case;
        testing.expectEqual(role, Capture.init(0, name).role) catch |err| {
            std.debug.print("Capture {s}\n", .{name});
            return err;
        };
    }
}

test "Span uses compact offsets and Capture identity" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Span));
}

test "PlainHighlighter satisfies the seam with no Spans" {
    var plain: PlainHighlighter = .{};
    const result = try plain.highlighter().highlight(testing.allocator, "src/main.go", "package main\n");
    try testing.expectEqual(@as(usize, 0), result.spans.len);
}
