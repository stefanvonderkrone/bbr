//! Intra-line word-diff — the character-level emphasis overlaid on a modified
//! line pair (design §2). Given the *old* and *new* text of a removed/added
//! pair, it computes which runs of each side changed, so the renderer can paint
//! only those runs with a brighter band instead of flooding the whole line.
//!
//! The algorithm is a token-level Longest Common Subsequence: both lines are
//! split into tokens (word runs / whitespace runs / single punctuation), the LCS
//! marks the tokens common to both, and everything else is emphasized. Adjacent
//! tokens with the same verdict are coalesced into one `Segment`, so a line is
//! partitioned into a handful of runs — concatenating a side's `Segment.text`
//! reconstructs that side's line exactly.
//!
//! `Segment.text` borrows the line text passed in. Work is bounded by the product
//! of both lexical-part counts; larger pairs use whole-line emphasis.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Largest measured lexical-part product below the 332,137 ns p95 budget.
const work_limit: usize = 500 * 500;

/// A run of bytes within one side of the pair. `emphasis` is true when the run
/// differs from the other side, false when it is common to both. Segments are
/// in order and together cover the whole line.
pub const Segment = struct {
    text: []const u8,
    emphasis: bool,
};

/// The word-diff of a line pair: emphasized/common runs for each side.
pub const Pair = struct {
    old: []const Segment,
    new: []const Segment,
    whole_line: bool = false,
};

const Class = enum { word, space, other };

fn classOf(b: u8) Class {
    if (std.ascii.isAlphanumeric(b) or b == '_') return .word;
    if (b == ' ' or b == '\t') return .space;
    return .other;
}

/// A token as a byte range into its line. Word and whitespace runs are maximal;
/// every other byte is its own token (punctuation shouldn't glue together).
const Tok = struct { start: usize, end: usize };

const Direction = enum(u8) { match, skip_old, skip_new };

fn tokenize(allocator: Allocator, text: []const u8, count: usize) ![]Tok {
    const toks = try allocator.alloc(Tok, count);
    var i: usize = 0;
    var index: usize = 0;
    while (i < text.len) {
        const start = i;
        const c = classOf(text[i]);
        if (c == .other) {
            i += 1;
        } else {
            while (i < text.len and classOf(text[i]) == c) i += 1;
        }
        toks[index] = .{ .start = start, .end = i };
        index += 1;
    }
    return toks;
}

pub fn lexicalPartCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (count += 1) {
        const c = classOf(text[i]);
        if (c == .other) {
            i += 1;
        } else {
            while (i < text.len and classOf(text[i]) == c) i += 1;
        }
    }
    return count;
}

fn tokEql(a_text: []const u8, a: Tok, b_text: []const u8, b: Tok) bool {
    return std.mem.eql(u8, a_text[a.start..a.end], b_text[b.start..b.end]);
}

fn commonTable(allocator: Allocator, old_text: []const u8, old_parts: []const Tok, new_text: []const u8, new_parts: []const Tok, byte_weight: bool) ![]usize {
    const stride = new_parts.len + 1;
    const table = try allocator.alloc(usize, (old_parts.len + 1) * stride);
    @memset(table, 0);
    var oi = old_parts.len;
    while (oi > 0) : (oi -= 1) {
        var ni = new_parts.len;
        while (ni > 0) : (ni -= 1) {
            const old_index = oi - 1;
            const new_index = ni - 1;
            table[old_index * stride + new_index] = if (tokEql(old_text, old_parts[old_index], new_text, new_parts[new_index]))
                table[oi * stride + ni] + if (byte_weight) old_parts[old_index].end - old_parts[old_index].start else 1
            else
                @max(table[oi * stride + new_index], table[old_index * stride + ni]);
        }
    }
    return table;
}

/// Coalesce a side's tokens into `Segment`s: consecutive tokens with the same
/// emphasis verdict become one run (a contiguous slice of `text`).
fn segmentsFor(allocator: Allocator, text: []const u8, toks: []const Tok, matched: []const bool) ![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    var k: usize = 0;
    while (k < toks.len) {
        const emph = !matched[k];
        const start = toks[k].start;
        var end = toks[k].end;
        var j = k + 1;
        while (j < toks.len and !matched[j] == emph) : (j += 1) end = toks[j].end;
        try segs.append(allocator, .{ .text = text[start..end], .emphasis = emph });
        k = j;
    }
    return segs.toOwnedSlice(allocator);
}

/// Word-diff `old_text` against `new_text`. When the lines share no tokens every
/// segment is emphasized on both sides; when identical, none are.
pub fn diff(allocator: Allocator, old_text: []const u8, new_text: []const u8) !Pair {
    const old_count = lexicalPartCount(old_text);
    const new_count = lexicalPartCount(new_text);
    if (old_count *| new_count > work_limit) return .{
        .old = try wholeLine(allocator, old_text),
        .new = try wholeLine(allocator, new_text),
        .whole_line = true,
    };

    const ot = try tokenize(allocator, old_text, old_count);
    const nt = try tokenize(allocator, new_text, new_count);
    const n = ot.len;
    const m = nt.len;

    const old_matched = try allocator.alloc(bool, n);
    @memset(old_matched, false);
    const new_matched = try allocator.alloc(bool, m);
    @memset(new_matched, false);

    if (n != 0 and m != 0) {
        const directions = try allocator.alloc(Direction, n * m);
        var next = try allocator.alloc(u32, m + 1);
        @memset(next, 0);
        var current = try allocator.alloc(u32, m + 1);

        var row = n;
        while (row > 0) {
            row -= 1;
            current[m] = 0;
            var column = m;
            while (column > 0) {
                column -= 1;
                if (tokEql(old_text, ot[row], new_text, nt[column])) {
                    current[column] = next[column + 1] + 1;
                    directions[row * m + column] = .match;
                } else if (next[column] >= current[column + 1]) {
                    current[column] = next[column];
                    directions[row * m + column] = .skip_old;
                } else {
                    current[column] = current[column + 1];
                    directions[row * m + column] = .skip_new;
                }
            }
            const swap = next;
            next = current;
            current = swap;
        }

        var oi: usize = 0;
        var ni: usize = 0;
        while (oi < n and ni < m) {
            switch (directions[oi * m + ni]) {
                .match => {
                    old_matched[oi] = true;
                    new_matched[ni] = true;
                    oi += 1;
                    ni += 1;
                },
                .skip_old => oi += 1,
                .skip_new => ni += 1,
            }
        }
    }

    return .{
        .old = try segmentsFor(allocator, old_text, ot, old_matched),
        .new = try segmentsFor(allocator, new_text, nt, new_matched),
    };
}

/// Fraction of `new_text` bytes that are common to `old_text`, in [0,1]. Used to
/// decide whether a removed/added pair is a *modification* worth word-diffing
/// (high ratio) or two unrelated lines that merely sit adjacent (low ratio).
pub fn similarity(pair: Pair) f64 {
    var common: usize = 0;
    var total: usize = 0;
    for (pair.new) |s| {
        total += s.text.len;
        if (!s.emphasis) common += s.text.len;
    }
    if (total == 0) return if (pairEmpty(pair.old)) 1.0 else 0.0;
    return @as(f64, @floatFromInt(common)) / @as(f64, @floatFromInt(total));
}

/// Symmetric similarity for matching changed Lines. The common byte count is
/// the maximum-weight lexical subsequence shared by both Lines.
pub fn matchingSimilarity(allocator: Allocator, old_text: []const u8, new_text: []const u8) !f64 {
    if (std.mem.eql(u8, old_text, new_text)) return 1.0;

    const old_parts = try tokenize(allocator, old_text, lexicalPartCount(old_text));
    defer allocator.free(old_parts);
    const new_parts = try tokenize(allocator, new_text, lexicalPartCount(new_text));
    defer allocator.free(new_parts);
    if (old_parts.len == 0 or new_parts.len == 0) return 0.0;

    const table = try commonTable(allocator, old_text, old_parts, new_text, new_parts, true);
    defer allocator.free(table);

    const common: f64 = @floatFromInt(table[0]);
    const total: f64 = @floatFromInt(old_text.len + new_text.len);
    return 2.0 * common / total;
}

fn pairEmpty(segs: []const Segment) bool {
    for (segs) |s| {
        if (s.text.len != 0) return false;
    }
    return true;
}

fn wholeLine(allocator: Allocator, text: []const u8) ![]const Segment {
    if (text.len == 0) return &.{};
    const segments = try allocator.alloc(Segment, 1);
    segments[0] = .{ .text = text, .emphasis = true };
    return segments;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

/// Reassemble a side's text from its segments — the partition invariant.
fn joined(allocator: Allocator, segs: []const Segment) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segs) |s| try out.appendSlice(allocator, s.text);
    return out.toOwnedSlice(allocator);
}

/// Concatenate only the emphasized runs of a side.
fn emphasized(allocator: Allocator, segs: []const Segment) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segs) |s| {
        if (s.emphasis) try out.appendSlice(allocator, s.text);
    }
    return out.toOwnedSlice(allocator);
}

test "segments partition each side exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try diff(a, "the quick brown fox", "the slow brown fox");
    try testing.expectEqualStrings("the quick brown fox", try joined(a, p.old));
    try testing.expectEqualStrings("the slow brown fox", try joined(a, p.new));
}

test "only the changed word is emphasized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try diff(a, "the quick brown fox", "the slow brown fox");
    try testing.expectEqualStrings("quick", try emphasized(a, p.old));
    try testing.expectEqualStrings("slow", try emphasized(a, p.new));
}

test "a pure insertion emphasizes only the inserted run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try diff(a, "let x = 1;", "let x = 1 + y;");
    // Old side loses nothing → nothing emphasized.
    try testing.expectEqualStrings("", try emphasized(a, p.old));
    // New side gains " + y" (tokens: space,+,space,y — coalesced).
    try testing.expectEqualStrings(" + y", try emphasized(a, p.new));
}

test "identical lines emphasize nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try diff(a, "same line", "same line");
    try testing.expectEqualStrings("", try emphasized(a, p.old));
    try testing.expectEqualStrings("", try emphasized(a, p.new));
    try testing.expectEqual(@as(f64, 1.0), similarity(p));
}

test "completely different lines emphasize everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try diff(a, "aaa", "zzz");
    try testing.expectEqualStrings("aaa", try emphasized(a, p.old));
    try testing.expectEqualStrings("zzz", try emphasized(a, p.new));
    try testing.expectEqual(@as(f64, 0.0), similarity(p));
}

test "an empty side leaves the other fully emphasized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try diff(a, "", "hello");
    try testing.expectEqual(@as(usize, 0), p.old.len);
    try testing.expectEqualStrings("hello", try emphasized(a, p.new));
}

test "similarity distinguishes an edit from an unrelated pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const edit = try diff(a, "value = compute(x)", "value = compute(y)");
    try testing.expect(similarity(edit) > 0.7);

    const unrelated = try diff(a, "import std", "return 42;");
    try testing.expect(similarity(unrelated) < 0.3);
}

test "matching similarity is symmetric and treats blank Lines as exact" {
    try testing.expectEqual(@as(f64, 1.0), try matchingSimilarity(testing.allocator, "", ""));
    try testing.expectEqual(@as(f64, 0.0), try matchingSimilarity(testing.allocator, "", "text"));

    const forward = try matchingSimilarity(testing.allocator, "const value = old;", "const value = new;");
    const reverse = try matchingSimilarity(testing.allocator, "const value = new;", "const value = old;");
    try testing.expectEqual(forward, reverse);
}

test "lexical part count matches tokenization" {
    const text = "const value = source();";
    const parts = try tokenize(testing.allocator, text, lexicalPartCount(text));
    defer testing.allocator.free(parts);
    try testing.expectEqual(parts.len, lexicalPartCount(text));
}

test "work above the limit uses whole-line emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var old: std.ArrayList(u8) = .empty;
    var new: std.ArrayList(u8) = .empty;
    for (0..501) |i| {
        if (i % 2 == 0) {
            try old.print(a, "o{d}", .{i});
            try new.print(a, "n{d}", .{i});
        } else {
            try old.append(a, '+');
            try new.append(a, '+');
        }
    }

    const pair = try diff(a, old.items, new.items);
    try testing.expectEqual(@as(usize, 1), pair.old.len);
    try testing.expectEqual(@as(usize, 1), pair.new.len);
    try testing.expect(pair.old[0].emphasis);
    try testing.expect(pair.new[0].emphasis);
    try testing.expect(pair.whole_line);
    try testing.expectEqualStrings(old.items, pair.old[0].text);
    try testing.expectEqualStrings(new.items, pair.new[0].text);
}

test "leading indentation change is isolated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try diff(a, "  foo()", "    foo()");
    // The word `foo` and its parens are common; only whitespace differs.
    try testing.expectEqualStrings("foo()", try joinedCommon(a, p.new));
}

/// Concatenate only the common runs of a side (helper for the indentation test).
fn joinedCommon(allocator: Allocator, segs: []const Segment) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segs) |s| {
        if (!s.emphasis) try out.appendSlice(allocator, s.text);
    }
    return out.toOwnedSlice(allocator);
}
