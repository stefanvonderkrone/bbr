//! Compose syntax foreground meaning with diff emphasis for one Line.
//!
//! This module is presentation-neutral: it produces borrowed text runs tagged
//! with an optional Capture and an emphasis bit, never terminal colors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const highlighter = @import("highlighter.zig");
const intraline = @import("../diff/intraline.zig");

pub const Capture = highlighter.Capture;
pub const Span = highlighter.Span;

pub const Run = struct {
    text: []const u8,
    capture: ?Capture = null,
    emphasis: bool = false,
};

pub const LineDecoration = struct {
    runs: []const Run,
};

pub const Error = error{
    InvalidSpan,
    InvalidEmphasis,
} || Allocator.Error;

/// Partition `text` wherever either its Capture or emphasis changes. `spans`
/// must all belong to this Line and be ordered/non-overlapping.
pub fn decorate(allocator: Allocator, text: []const u8, spans: []const Span, emphasis: []const intraline.Segment) Error!LineDecoration {
    try validateSpans(text, spans);
    try validateEmphasis(text, emphasis);
    if (text.len == 0) return .{ .runs = &.{} };

    const capacity = 2 + spans.len * 2 + emphasis.len;
    const boundaries = try allocator.alloc(usize, capacity);
    defer allocator.free(boundaries);
    var count: usize = 0;
    boundaries[count] = 0;
    count += 1;
    boundaries[count] = text.len;
    count += 1;
    for (spans) |span| {
        boundaries[count] = span.start;
        boundaries[count + 1] = span.end;
        count += 2;
    }
    var offset: usize = 0;
    for (emphasis) |segment| {
        offset += segment.text.len;
        boundaries[count] = offset;
        count += 1;
    }
    std.mem.sort(usize, boundaries[0..count], {}, std.sort.asc(usize));

    var unique: usize = 0;
    for (boundaries[0..count]) |boundary| {
        if (unique == 0 or boundaries[unique - 1] != boundary) {
            boundaries[unique] = boundary;
            unique += 1;
        }
    }

    const runs = try allocator.alloc(Run, unique - 1);
    var span_index: usize = 0;
    var emphasis_index: usize = 0;
    var emphasis_end: usize = if (emphasis.len > 0) emphasis[0].text.len else 0;
    for (boundaries[0 .. unique - 1], 0..) |start, i| {
        const end = boundaries[i + 1];
        while (span_index < spans.len and spans[span_index].end <= start) span_index += 1;
        while (emphasis_index < emphasis.len and emphasis_end <= start) {
            emphasis_index += 1;
            if (emphasis_index < emphasis.len) emphasis_end += emphasis[emphasis_index].text.len;
        }
        const capture: ?Capture = if (span_index < spans.len and spans[span_index].start <= start and end <= spans[span_index].end)
            spans[span_index].capture
        else
            null;
        runs[i] = .{
            .text = text[start..end],
            .capture = capture,
            .emphasis = emphasis_index < emphasis.len and emphasis[emphasis_index].emphasis,
        };
    }
    return .{ .runs = runs };
}

fn validateSpans(text: []const u8, spans: []const Span) error{InvalidSpan}!void {
    var previous_end: usize = 0;
    var line: ?u32 = null;
    for (spans) |span| {
        if (line) |expected| {
            if (span.line != expected) return error.InvalidSpan;
        } else line = span.line;
        if (span.start >= span.end or span.start < previous_end or span.end > text.len) return error.InvalidSpan;
        if (!utf8Boundary(text, span.start) or !utf8Boundary(text, span.end)) return error.InvalidSpan;
        previous_end = span.end;
    }
}

fn validateEmphasis(text: []const u8, emphasis: []const intraline.Segment) error{InvalidEmphasis}!void {
    if (emphasis.len == 0) return;
    var offset: usize = 0;
    for (emphasis) |segment| {
        if (segment.text.len == 0 or offset + segment.text.len > text.len) return error.InvalidEmphasis;
        if (!std.mem.eql(u8, text[offset .. offset + segment.text.len], segment.text)) return error.InvalidEmphasis;
        offset += segment.text.len;
    }
    if (offset != text.len) return error.InvalidEmphasis;
}

fn utf8Boundary(text: []const u8, index: usize) bool {
    return index == 0 or index == text.len or text[index] & 0xc0 != 0x80;
}

const testing = std.testing;

test "LineDecoration intersects Captures and emphasis without copying text" {
    const text = "const answer = 42";
    const spans = [_]Span{
        .{ .line = 1, .start = 0, .end = 5, .capture = Capture.init(0, "keyword") },
        .{ .line = 1, .start = 15, .end = 17, .capture = Capture.init(1, "number") },
    };
    const emphasis = [_]intraline.Segment{
        .{ .text = text[0..6], .emphasis = false },
        .{ .text = text[6..12], .emphasis = true },
        .{ .text = text[12..], .emphasis = false },
    };
    const result = try decorate(testing.allocator, text, &spans, &emphasis);
    defer testing.allocator.free(result.runs);

    try testing.expectEqual(@as(usize, 5), result.runs.len);
    try testing.expectEqualStrings("const", result.runs[0].text);
    try testing.expectEqual(highlighter.CaptureRole.keyword, result.runs[0].capture.?.role);
    try testing.expect(!result.runs[0].emphasis);
    try testing.expectEqualStrings("answer", result.runs[2].text);
    try testing.expect(result.runs[2].capture == null);
    try testing.expect(result.runs[2].emphasis);
    try testing.expectEqualStrings("42", result.runs[4].text);
    try testing.expectEqual(highlighter.CaptureRole.constant, result.runs[4].capture.?.role);
}

test "LineDecoration reconstructs plain and syntax-only Lines" {
    const text = "hello";
    const plain = try decorate(testing.allocator, text, &.{}, &.{});
    defer testing.allocator.free(plain.runs);
    try testing.expectEqual(@as(usize, 1), plain.runs.len);
    try testing.expectEqualStrings(text, plain.runs[0].text);

    const syntax = try decorate(testing.allocator, text, &.{.{ .line = 8, .start = 1, .end = 4, .capture = Capture.init(0, "string") }}, &.{});
    defer testing.allocator.free(syntax.runs);
    try testing.expectEqual(@as(usize, 3), syntax.runs.len);
    try testing.expectEqualStrings("ell", syntax.runs[1].text);
    try testing.expectEqual(highlighter.CaptureRole.string, syntax.runs[1].capture.?.role);
}

test "LineDecoration rejects overlap and UTF-8 splits" {
    const overlap = [_]Span{
        .{ .line = 1, .start = 0, .end = 2, .capture = Capture.init(0, "a") },
        .{ .line = 1, .start = 1, .end = 3, .capture = Capture.init(1, "b") },
    };
    try testing.expectError(error.InvalidSpan, decorate(testing.allocator, "abc", &overlap, &.{}));
    try testing.expectError(error.InvalidSpan, decorate(testing.allocator, "é", &.{.{ .line = 1, .start = 1, .end = 2, .capture = Capture.init(0, "string") }}, &.{}));
}

test "LineDecoration rejects emphasis that does not reconstruct the Line" {
    try testing.expectError(error.InvalidEmphasis, decorate(testing.allocator, "abc", &.{}, &.{.{ .text = "ab", .emphasis = true }}));
}
