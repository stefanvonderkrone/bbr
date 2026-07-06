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
//! Pure and zero-copy: `Segment.text` borrows the line text passed in; only the
//! `Segment` arrays are allocated, so pass an arena. Lines here are short (one
//! source line), so the O(n·m) LCS table is cheap.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

fn tokenize(allocator: Allocator, text: []const u8) ![]Tok {
    var toks: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        const c = classOf(text[i]);
        if (c == .other) {
            i += 1;
        } else {
            while (i < text.len and classOf(text[i]) == c) i += 1;
        }
        try toks.append(allocator, .{ .start = start, .end = i });
    }
    return toks.toOwnedSlice(allocator);
}

fn tokEql(a_text: []const u8, a: Tok, b_text: []const u8, b: Tok) bool {
    return std.mem.eql(u8, a_text[a.start..a.end], b_text[b.start..b.end]);
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
    const ot = try tokenize(allocator, old_text);
    const nt = try tokenize(allocator, new_text);
    const n = ot.len;
    const m = nt.len;

    const old_matched = try allocator.alloc(bool, n);
    @memset(old_matched, false);
    const new_matched = try allocator.alloc(bool, m);
    @memset(new_matched, false);

    if (n != 0 and m != 0) {
        // dp[i*stride + j] = LCS length of old[i..] vs new[j..]. Fill backward.
        const stride = m + 1;
        const dp = try allocator.alloc(usize, (n + 1) * stride);
        @memset(dp, 0);
        var i = n;
        while (i > 0) : (i -= 1) {
            var j = m;
            while (j > 0) : (j -= 1) {
                const ii = i - 1;
                const jj = j - 1;
                dp[ii * stride + jj] = if (tokEql(old_text, ot[ii], new_text, nt[jj]))
                    dp[i * stride + j] + 1
                else
                    @max(dp[i * stride + jj], dp[ii * stride + j]);
            }
        }

        // Walk forward along an LCS, marking the tokens it visits as common.
        var oi: usize = 0;
        var ni: usize = 0;
        while (oi < n and ni < m) {
            if (tokEql(old_text, ot[oi], new_text, nt[ni])) {
                old_matched[oi] = true;
                new_matched[ni] = true;
                oi += 1;
                ni += 1;
            } else if (dp[(oi + 1) * stride + ni] >= dp[oi * stride + (ni + 1)]) {
                oi += 1;
            } else {
                ni += 1;
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

fn pairEmpty(segs: []const Segment) bool {
    for (segs) |s| {
        if (s.text.len != 0) return false;
    }
    return true;
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
