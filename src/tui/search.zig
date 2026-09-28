//! Pure Unicode matching for Buffer Search and Review Search.

const std = @import("std");
const bbr = @import("bbr");
const unicode_data = @import("search_unicode_data.zig");
const review_body = @import("review_body.zig");

pub const max_query_scalars = 256;

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Mapping = struct {
    semantic: Range,
    authored: Range,
};

pub const VersionRelation = enum { neutral, old, new };

pub const SourceLocation = struct {
    file_index: usize,
    relation: VersionRelation,
    old_path: []const u8 = "",
    new_path: []const u8 = "",
    old_line: ?u32 = null,
    new_line: ?u32 = null,
};

pub const ReviewBodyOwner = union(enum) {
    comment: bbr.review.CommentId,
    draft: bbr.review.TempId,
};

pub const ReviewBodyLocation = struct {
    owner: ReviewBodyOwner,
    logical_line: u32,
};

pub const Location = union(enum) {
    source: SourceLocation,
    review_body: ReviewBodyLocation,

    fn clone(self: Location, allocator: std.mem.Allocator) !Location {
        return switch (self) {
            .source => |source| blk: {
                const old_path = try allocator.dupe(u8, source.old_path);
                errdefer allocator.free(old_path);
                break :blk .{ .source = .{
                    .file_index = source.file_index,
                    .relation = source.relation,
                    .old_path = old_path,
                    .new_path = try allocator.dupe(u8, source.new_path),
                    .old_line = source.old_line,
                    .new_line = source.new_line,
                } };
            },
            .review_body => |body| .{ .review_body = body },
        };
    }

    fn deinit(self: Location, allocator: std.mem.Allocator) void {
        switch (self) {
            .source => |source| {
                allocator.free(source.old_path);
                allocator.free(source.new_path);
            },
            .review_body => {},
        }
    }
};

pub const Candidate = struct {
    text: []const u8,
    mapping: []const Mapping = &.{},
    boundaries: []const usize = &.{},
    location: Location,
    corpus_order: usize = 0,
    session_epoch: u64 = 0,
};

pub const Calculation = enum { exact, fallback };

pub const Occurrence = struct {
    location: Location,
    ranges: []Range,
    column: usize,
    score: f64 = 0,
    calculation: Calculation = .exact,
    candidate_scalars: usize,
    corpus_order: usize,
    session_epoch: u64,

    fn deinit(self: *Occurrence, allocator: std.mem.Allocator) void {
        self.location.deinit(allocator);
        allocator.free(self.ranges);
        self.* = undefined;
    }
};

pub const Batch = struct {
    occurrences: []Occurrence,
    // Worker-owned batches keep their allocator when Presentation takes ownership.
    owner: ?std.mem.Allocator = null,

    pub fn clone(self: Batch, allocator: std.mem.Allocator) !Batch {
        const occurrences = try allocator.alloc(Occurrence, self.occurrences.len);
        errdefer allocator.free(occurrences);
        var initialized: usize = 0;
        errdefer for (occurrences[0..initialized]) |*occurrence| occurrence.deinit(allocator);
        for (self.occurrences, occurrences) |source, *target| {
            target.* = .{
                .location = try source.location.clone(allocator),
                .ranges = &.{},
                .column = source.column,
                .score = source.score,
                .calculation = source.calculation,
                .candidate_scalars = source.candidate_scalars,
                .corpus_order = source.corpus_order,
                .session_epoch = source.session_epoch,
            };
            target.ranges = allocator.dupe(Range, source.ranges) catch |err| {
                target.location.deinit(allocator);
                return err;
            };
            initialized += 1;
        }
        return .{ .occurrences = occurrences };
    }

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        const backing = self.owner orelse allocator;
        for (self.occurrences) |*occurrence| occurrence.deinit(backing);
        backing.free(self.occurrences);
        self.* = undefined;
    }
};

pub const Mode = enum { literal, fuzzy };

const Scalar = struct {
    value: u21,
    bytes: Range,
};

// Apple M5 Pro `search_fuzzy_*` p95: ASCII 0.44 ms, Unicode 3.88 ms, fallback
// 0.011 ms. The 256 Ki-cell bound keeps the worst exact table at 256 x 1024.
// Larger scans use deterministic greedy matching and rank after exact results.
pub const exact_fuzzy_cell_limit: usize = 256 * 1024;

pub const Query = struct {
    text: []u8,
    scalars: []u21,
    case_sensitive: bool,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !Query {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.Nul;
        if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.LineEnding;

        var decoded: std.ArrayList(u21) = .empty;
        defer decoded.deinit(allocator);
        var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
        var case_sensitive = false;
        while (iterator.nextCodepoint()) |scalar| {
            if (decoded.items.len == max_query_scalars) return error.TooLong;
            try decoded.append(allocator, scalar);
            case_sensitive = case_sensitive or isUppercase(scalar);
        }
        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);
        const owned_scalars = try decoded.toOwnedSlice(allocator);
        return .{
            .text = owned_text,
            .scalars = owned_scalars,
            .case_sensitive = case_sensitive,
        };
    }

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.scalars);
        self.* = undefined;
    }
};

fn isUppercase(scalar: u21) bool {
    if (scalar < 0x80) return scalar >= 'A' and scalar <= 'Z';
    return inRanges(scalar, &unicode_data.uppercase);
}

fn isLowercase(scalar: u21) bool {
    if (scalar < 0x80) return scalar >= 'a' and scalar <= 'z';
    return inRanges(scalar, &unicode_data.lowercase);
}

fn inRanges(scalar: u21, ranges: []const unicode_data.Range) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range = ranges[middle];
        if (scalar < range.first) high = middle else if (scalar > range.last) low = middle + 1 else return true;
    }
    return false;
}

fn fold(scalar: u21) u21 {
    if (scalar < 0x80) return if (scalar >= 'A' and scalar <= 'Z') scalar + ('a' - 'A') else scalar;
    var low: usize = 0;
    var high = unicode_data.folds.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const mapping = unicode_data.folds[middle];
        if (scalar < mapping.source) high = middle else if (scalar > mapping.source) low = middle + 1 else return mapping.target;
    }
    return scalar;
}

pub fn scan(
    allocator: std.mem.Allocator,
    query: Query,
    candidates: []const Candidate,
    mode: Mode,
) !Batch {
    var occurrences: std.ArrayList(Occurrence) = .empty;
    errdefer {
        for (occurrences.items) |*occurrence| occurrence.deinit(allocator);
        occurrences.deinit(allocator);
    }
    if (query.scalars.len == 0) return .{ .occurrences = try occurrences.toOwnedSlice(allocator) };

    for (candidates) |candidate| {
        const scalars = try decode(allocator, candidate.text);
        defer allocator.free(scalars);
        const regions = try scalarRegions(allocator, scalars, candidate.boundaries);
        defer allocator.free(regions);
        switch (mode) {
            .literal => for (regions) |region| try scanLiteral(allocator, query, candidate, scalars, region, &occurrences),
            .fuzzy => {
                var best: ?Alignment = null;
                defer if (best) |alignment| allocator.free(alignment.positions);
                for (regions) |region| {
                    const whole_line = candidate.boundaries.len == 0 and region.start == 0 and region.end == scalars.len;
                    const relative = (try fuzzyAlignment(allocator, query, scalars[region.start..region.end], whole_line)) orelse continue;
                    for (relative.positions) |*position| position.* += region.start;
                    if (best) |current| {
                        if (alignmentBetter(relative, current)) {
                            allocator.free(current.positions);
                            best = relative;
                        } else allocator.free(relative.positions);
                    } else best = relative;
                }
                if (best) |alignment| {
                    var occurrence = try makeOccurrence(allocator, candidate, scalars, alignment.positions, alignment.score, alignment.calculation);
                    errdefer occurrence.deinit(allocator);
                    try occurrences.append(allocator, occurrence);
                }
            },
        }
    }
    std.mem.sort(Occurrence, occurrences.items, mode, occurrenceLessThan);
    return .{ .occurrences = try occurrences.toOwnedSlice(allocator) };
}

/// Scan a complete File without copying its Lines into Search Occurrences.
/// Only context Lines proven by the Diff can merge old and new identities.
pub fn scanFile(allocator: std.mem.Allocator, query: Query, file: bbr.diff.File, file_index: usize, epoch: u64, old: ?[]const u8, new: ?[]const u8) !Batch {
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    for ([_]struct { blob: ?[]const u8, relation: VersionRelation }{
        .{ .blob = old, .relation = .old },
        .{ .blob = new, .relation = .new },
    }) |version| {
        const blob = version.blob orelse continue;
        var start: usize = 0;
        var line_no: u32 = 1;
        while (start < blob.len) : (line_no += 1) {
            const end = std.mem.indexOfScalarPos(u8, blob, start, '\n') orelse blob.len;
            const line_end = if (end > start and blob[end - 1] == '\r') end - 1 else end;
            try candidates.append(allocator, .{
                .text = blob[start..line_end],
                .location = .{ .source = .{
                    .file_index = file_index,
                    .relation = version.relation,
                    .old_path = file.old_path,
                    .new_path = file.new_path,
                    .old_line = if (version.relation == .old) line_no else null,
                    .new_line = if (version.relation == .new) line_no else null,
                } },
                .corpus_order = @as(usize, line_no) * 2 + @intFromBool(version.relation == .new),
                .session_epoch = epoch,
            });
            start = end + @intFromBool(end < blob.len);
        }
    }
    var batch = try scan(allocator, query, candidates.items, .fuzzy);
    if (old == null or new == null) return batch;
    // ponytail: Context verification walks complete text per Hunk Line. Index offsets if large diffs make scans slow.
    for (file.hunks) |hunk| for (hunk.lines) |line| {
        if (line.kind != .context or line.old_no == 0 or line.new_no == 0) continue;
        const old_text = lineAt(old.?, line.old_no) orelse continue;
        const new_text = lineAt(new.?, line.new_no) orelse continue;
        if (!std.mem.eql(u8, old_text, new_text) or !std.mem.eql(u8, old_text, line.text)) continue;
        var old_index: ?usize = null;
        var new_index: ?usize = null;
        for (batch.occurrences, 0..) |occurrence, index| {
            const source = occurrence.location.source;
            if (source.relation == .old and source.old_line == line.old_no) old_index = index;
            if (source.relation == .new and source.new_line == line.new_no) new_index = index;
        }
        if (old_index) |oi| if (new_index) |ni| {
            const before = &batch.occurrences[oi];
            const after = &batch.occurrences[ni];
            if (before.ranges.len != after.ranges.len) continue;
            var same_ranges = true;
            for (before.ranges, after.ranges) |a, b| if (a.start != b.start or a.end != b.end) {
                same_ranges = false;
                break;
            };
            if (!same_ranges) continue;
            before.location.source.relation = .neutral;
            before.location.source.new_line = line.new_no;
            after.location.source.relation = .neutral;
            after.location.source.old_line = line.old_no;
            // Drop the duplicate after walking all context Lines below.
            after.corpus_order = std.math.maxInt(usize);
        };
    };
    var kept: usize = 0;
    for (batch.occurrences) |occurrence| {
        if (occurrence.corpus_order == std.math.maxInt(usize)) {
            var duplicate = occurrence;
            duplicate.deinit(allocator);
        } else {
            batch.occurrences[kept] = occurrence;
            kept += 1;
        }
    }
    // Return a right-sized owned slice; the original remains the allocator's allocation.
    if (kept == batch.occurrences.len) return batch;
    const compact = allocator.dupe(Occurrence, batch.occurrences[0..kept]) catch |err| {
        for (batch.occurrences[0..kept]) |*occurrence| occurrence.deinit(allocator);
        allocator.free(batch.occurrences);
        return err;
    };
    allocator.free(batch.occurrences);
    return .{ .occurrences = compact };
}

fn lineAt(blob: []const u8, target: u32) ?[]const u8 {
    var start: usize = 0;
    var number: u32 = 1;
    while (start < blob.len) : (number += 1) {
        const end = std.mem.indexOfScalarPos(u8, blob, start, '\n') orelse blob.len;
        if (number == target) return blob[start..(if (end > start and blob[end - 1] == '\r') end - 1 else end)];
        start = end + @intFromBool(end < blob.len);
    }
    return null;
}

fn scalarRegions(allocator: std.mem.Allocator, scalars: []const Scalar, boundaries: []const usize) ![]Range {
    var regions: std.ArrayList(Range) = .empty;
    errdefer regions.deinit(allocator);
    var region_start: usize = 0;
    var scalar_cursor: usize = 0;
    for (boundaries) |boundary| {
        while (scalar_cursor < scalars.len and scalars[scalar_cursor].bytes.start < boundary) scalar_cursor += 1;
        if (scalar_cursor > region_start) try regions.append(allocator, .{ .start = region_start, .end = scalar_cursor });
        region_start = scalar_cursor;
    }
    if (region_start < scalars.len) try regions.append(allocator, .{ .start = region_start, .end = scalars.len });
    if (regions.items.len == 0) try regions.append(allocator, .{ .start = 0, .end = scalars.len });
    return regions.toOwnedSlice(allocator);
}

fn decode(allocator: std.mem.Allocator, text: []const u8) ![]Scalar {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var scalars: std.ArrayList(Scalar) = .empty;
    errdefer scalars.deinit(allocator);
    var iterator = view.iterator();
    var start: usize = 0;
    while (iterator.nextCodepointSlice()) |bytes| {
        try scalars.append(allocator, .{
            .value = std.unicode.utf8Decode(bytes) catch unreachable,
            .bytes = .{ .start = start, .end = start + bytes.len },
        });
        start += bytes.len;
    }
    return scalars.toOwnedSlice(allocator);
}

fn equalScalar(query: Query, needle: u21, candidate: u21) bool {
    return if (query.case_sensitive) needle == candidate else fold(needle) == fold(candidate);
}

fn scanLiteral(
    allocator: std.mem.Allocator,
    query: Query,
    candidate: Candidate,
    scalars: []const Scalar,
    region: Range,
    occurrences: *std.ArrayList(Occurrence),
) !void {
    if (query.scalars.len > region.end - region.start) return;
    var start = region.start;
    while (start + query.scalars.len <= region.end) {
        var matched = true;
        for (query.scalars, 0..) |needle, offset| if (!equalScalar(query, needle, scalars[start + offset].value)) {
            matched = false;
            break;
        };
        if (!matched) {
            start += 1;
            continue;
        }
        const positions = try allocator.alloc(usize, query.scalars.len);
        defer allocator.free(positions);
        for (positions, 0..) |*position, offset| position.* = start + offset;
        var occurrence = try makeOccurrence(allocator, candidate, scalars, positions, 0, .exact);
        errdefer occurrence.deinit(allocator);
        try occurrences.append(allocator, occurrence);
        start += query.scalars.len;
    }
}

const Alignment = struct {
    positions: []usize,
    score: f64,
    calculation: Calculation,
};

fn alignmentBetter(left: Alignment, right: Alignment) bool {
    if (left.calculation != right.calculation) return left.calculation == .exact;
    if (left.score != right.score) return left.score > right.score;
    return left.positions[0] < right.positions[0];
}

const score_min = -std.math.inf(f64);
const score_max = std.math.inf(f64);
const score_gap_leading: f64 = -0.005;
const score_gap_trailing: f64 = -0.005;
const score_gap_inner: f64 = -0.01;
const score_match_consecutive: f64 = 1.0;
const score_match_slash: f64 = 0.9;
const score_match_word: f64 = 0.8;
const score_match_capital: f64 = 0.7;
const score_match_dot: f64 = 0.6;

fn fuzzyAlignment(allocator: std.mem.Allocator, query: Query, scalars: []const Scalar, whole_line: bool) !?Alignment {
    if (query.scalars.len > scalars.len) return null;
    const cells = query.scalars.len *| scalars.len;
    if (cells > exact_fuzzy_cell_limit) return greedyAlignment(allocator, query, scalars);
    const positions = try allocator.alloc(usize, query.scalars.len);
    errdefer allocator.free(positions);
    if (whole_line and query.scalars.len == scalars.len) {
        for (positions, 0..) |*position, index| {
            if (!equalScalar(query, query.scalars[index], scalars[index].value)) {
                allocator.free(positions);
                return null;
            }
            position.* = index;
        }
        return .{ .positions = positions, .score = score_max, .calculation = .exact };
    }

    const exact_scores = try allocator.alloc(f64, cells);
    defer allocator.free(exact_scores);
    const best_scores = try allocator.alloc(f64, cells);
    defer allocator.free(best_scores);
    const width = scalars.len;
    for (query.scalars, 0..) |needle, query_index| {
        var previous_score = score_min;
        const gap_score = if (query_index + 1 == query.scalars.len) score_gap_trailing else score_gap_inner;
        for (scalars, 0..) |candidate, candidate_index| {
            const index = query_index * width + candidate_index;
            var score = score_min;
            if (equalScalar(query, needle, candidate.value)) {
                if (query_index == 0) {
                    score = @as(f64, @floatFromInt(candidate_index)) * score_gap_leading + boundaryBonus(scalars, candidate_index);
                } else if (candidate_index > 0) {
                    score = @max(
                        best_scores[(query_index - 1) * width + candidate_index - 1] + boundaryBonus(scalars, candidate_index),
                        exact_scores[(query_index - 1) * width + candidate_index - 1] + score_match_consecutive,
                    );
                }
            }
            exact_scores[index] = score;
            previous_score = @max(score, previous_score + gap_score);
            best_scores[index] = previous_score;
        }
    }
    const final_score = best_scores[cells - 1];
    if (final_score == score_min) {
        allocator.free(positions);
        return null;
    }

    var match_required = false;
    var candidate_cursor = scalars.len;
    var query_cursor = query.scalars.len;
    while (query_cursor > 0) {
        query_cursor -= 1;
        var found = false;
        while (candidate_cursor > 0) {
            candidate_cursor -= 1;
            const index = query_cursor * width + candidate_cursor;
            if (exact_scores[index] == score_min or (!match_required and exact_scores[index] != best_scores[index])) continue;
            match_required = query_cursor > 0 and candidate_cursor > 0 and
                best_scores[index] == exact_scores[(query_cursor - 1) * width + candidate_cursor - 1] + score_match_consecutive;
            positions[query_cursor] = candidate_cursor;
            found = true;
            break;
        }
        if (!found) {
            allocator.free(positions);
            return null;
        }
    }
    return .{ .positions = positions, .score = final_score, .calculation = .exact };
}

fn greedyAlignment(allocator: std.mem.Allocator, query: Query, scalars: []const Scalar) !?Alignment {
    const positions = try allocator.alloc(usize, query.scalars.len);
    errdefer allocator.free(positions);
    var cursor: usize = 0;
    for (query.scalars, 0..) |needle, query_index| {
        while (cursor < scalars.len and !equalScalar(query, needle, scalars[cursor].value)) cursor += 1;
        if (cursor == scalars.len) {
            allocator.free(positions);
            return null;
        }
        positions[query_index] = cursor;
        cursor += 1;
    }
    return .{ .positions = positions, .score = alignmentScore(scalars, positions), .calculation = .fallback };
}

fn boundaryBonus(scalars: []const Scalar, index: usize) f64 {
    if (index == 0) return score_match_word;
    const previous = scalars[index - 1].value;
    const current = scalars[index].value;
    if (previous == '/' or previous == '\\') return score_match_slash;
    if (previous == ' ' or previous == '_' or previous == '-') return score_match_word;
    if (previous == '.') return score_match_dot;
    if (isLowercase(previous) and isUppercase(current)) return score_match_capital;
    return 0;
}

fn alignmentScore(scalars: []const Scalar, positions: []const usize) f64 {
    var score = @as(f64, @floatFromInt(positions[0])) * score_gap_leading + boundaryBonus(scalars, positions[0]);
    for (positions[1..], 1..) |position, index| {
        const gap = position - positions[index - 1] - 1;
        score += if (gap == 0) score_match_consecutive else boundaryBonus(scalars, position) + @as(f64, @floatFromInt(gap)) * score_gap_inner;
    }
    score += @as(f64, @floatFromInt(scalars.len - positions[positions.len - 1] - 1)) * score_gap_trailing;
    return score;
}

fn makeOccurrence(
    allocator: std.mem.Allocator,
    candidate: Candidate,
    scalars: []const Scalar,
    positions: []const usize,
    score: f64,
    calculation: Calculation,
) !Occurrence {
    const semantic_ranges = try mergedScalarRanges(allocator, scalars, positions);
    defer allocator.free(semantic_ranges);
    const ranges = try mapRanges(allocator, semantic_ranges, candidate.mapping);
    errdefer allocator.free(ranges);
    return .{
        .location = try candidate.location.clone(allocator),
        .ranges = ranges,
        .column = positions[0] + 1,
        .score = score,
        .calculation = calculation,
        .candidate_scalars = scalars.len,
        .corpus_order = candidate.corpus_order,
        .session_epoch = candidate.session_epoch,
    };
}

fn mergedScalarRanges(allocator: std.mem.Allocator, scalars: []const Scalar, positions: []const usize) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(allocator);
    for (positions) |position| {
        const scalar = scalars[position].bytes;
        if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].end == scalar.start) {
            ranges.items[ranges.items.len - 1].end = scalar.end;
        } else try ranges.append(allocator, scalar);
    }
    return ranges.toOwnedSlice(allocator);
}

fn mapRanges(allocator: std.mem.Allocator, semantic_ranges: []const Range, mapping: []const Mapping) ![]Range {
    if (mapping.len == 0) return allocator.dupe(Range, semantic_ranges);
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(allocator);
    for (semantic_ranges) |semantic| for (mapping) |entry| {
        const start = @max(semantic.start, entry.semantic.start);
        const end = @min(semantic.end, entry.semantic.end);
        if (start >= end) continue;
        const authored = Range{
            .start = entry.authored.start + start - entry.semantic.start,
            .end = entry.authored.start + end - entry.semantic.start,
        };
        if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].end == authored.start) {
            ranges.items[ranges.items.len - 1].end = authored.end;
        } else try ranges.append(allocator, authored);
    };
    return ranges.toOwnedSlice(allocator);
}

fn occurrenceLessThan(mode: Mode, left: Occurrence, right: Occurrence) bool {
    if (mode == .fuzzy) {
        if (left.calculation != right.calculation) return left.calculation == .exact;
        if (left.score != right.score) return left.score > right.score;
        if (left.candidate_scalars != right.candidate_scalars) return left.candidate_scalars < right.candidate_scalars;
        if (left.location == .source and right.location == .review_body) return true;
        if (left.location == .review_body and right.location == .source) return false;
        if (left.location == .source and right.location == .source) {
            const a = left.location.source;
            const b = right.location.source;
            const a_path = if (a.relation == .old) a.old_path else a.new_path;
            const b_path = if (b.relation == .old) b.old_path else b.new_path;
            const order = std.mem.order(u8, a_path, b_path);
            if (order != .eq) return order == .lt;
            const a_line = a.new_line orelse a.old_line orelse 0;
            const b_line = b.new_line orelse b.old_line orelse 0;
            if (a_line != b_line) return a_line < b_line;
            if (a.relation != b.relation) return @intFromEnum(a.relation) < @intFromEnum(b.relation);
        }
    }
    if (left.corpus_order != right.corpus_order) return left.corpus_order < right.corpus_order;
    return left.column < right.column;
}

pub fn rank(batch: *Batch) void {
    std.mem.sort(Occurrence, batch.occurrences, Mode.fuzzy, occurrenceLessThan);
}

pub fn appendReviewBodyCandidates(
    allocator: std.mem.Allocator,
    body: review_body.ReviewBody,
    owner: ReviewBodyOwner,
    session_epoch: u64,
    corpus_order: *usize,
    candidates: *std.ArrayList(Candidate),
) !void {
    var line_start: usize = 0;
    var logical_line: u32 = 1;
    while (line_start <= body.source.len) : (logical_line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, body.source, line_start, '\n') orelse body.source.len;
        const line_end = if (newline > line_start and body.source[newline - 1] == '\r') newline - 1 else newline;
        var text: std.ArrayList(u8) = .empty;
        var mappings: std.ArrayList(Mapping) = .empty;
        var boundaries: std.ArrayList(usize) = .empty;
        var previous_destination = false;
        var have_span = false;

        for (body.blocks) |block| for (block.spans) |span| {
            const start = @max(line_start, span.source.start);
            const end = @min(line_end, span.source.end);
            if (start >= end) continue;
            const destination = span.marks.link_destination;
            if (have_span and destination != previous_destination and (destination or previous_destination)) {
                try boundaries.append(allocator, text.items.len);
            }
            const semantic_start = text.items.len;
            try text.appendSlice(allocator, body.source[start..end]);
            try mappings.append(allocator, .{
                .semantic = .{ .start = semantic_start, .end = text.items.len },
                .authored = .{ .start = start, .end = end },
            });
            previous_destination = destination;
            have_span = true;
        };
        if (have_span and previous_destination) try boundaries.append(allocator, text.items.len);

        if (text.items.len > 0) {
            try candidates.append(allocator, .{
                .text = try text.toOwnedSlice(allocator),
                .mapping = try mappings.toOwnedSlice(allocator),
                .boundaries = try boundaries.toOwnedSlice(allocator),
                .location = .{ .review_body = .{ .owner = owner, .logical_line = logical_line } },
                .corpus_order = corpus_order.*,
                .session_epoch = session_epoch,
            });
            corpus_order.* += 1;
        } else {
            text.deinit(allocator);
            mappings.deinit(allocator);
            boundaries.deinit(allocator);
        }
        if (newline == body.source.len) break;
        line_start = newline + 1;
    }
}

const testing = std.testing;

test "complete File scan merges only Diff-proven equal context and keeps opposite-side matches" {
    var query = try Query.init(testing.allocator, "match");
    defer query.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diff = try bbr.diff.parse(arena.allocator(), "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n match context\n-match old\n+match new\n");
    var batch = try scanFile(testing.allocator, query, diff.files[0], 0, 9, "match context\nmatch old\nmatch outside\n", "match context\nmatch new\nmatch outside\n");
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), batch.occurrences.len);
    var merged: usize = 0;
    for (batch.occurrences) |occurrence| if (occurrence.location.source.relation == .neutral) {
        merged += 1;
        try testing.expectEqual(@as(?u32, 1), occurrence.location.source.old_line);
        try testing.expectEqual(@as(?u32, 1), occurrence.location.source.new_line);
    };
    try testing.expectEqual(@as(usize, 1), merged);
}

test "complete File scan keeps the readable version when the other version failed" {
    var query = try Query.init(testing.allocator, "needle");
    defer query.deinit(testing.allocator);
    const file: bbr.diff.File = .{ .old_path = "a.txt", .new_path = "a.txt", .status = .modified, .hunks = &.{} };
    var batch = try scanFile(testing.allocator, query, file, 3, 8, null, "a needle outside the diff\n");
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    try testing.expectEqual(@as(?u32, 1), batch.occurrences[0].location.source.new_line);
    try testing.expectEqualStrings("a.txt", batch.occurrences[0].location.source.new_path);
}

fn exerciseScanAllocationFailures(allocator: std.mem.Allocator) !void {
    var query = try Query.init(allocator, "ab");
    defer query.deinit(allocator);
    const candidates = [_]Candidate{
        .{ .text = "a_b", .location = .{ .source = .{ .file_index = 0, .relation = .new, .new_path = "a.zig", .new_line = 1 } } },
        .{ .text = "a---b", .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } } },
    };
    var batch = try scan(allocator, query, &candidates, .fuzzy);
    defer batch.deinit(allocator);
}

test "M21 kernel Query validates UTF-8 controls scalar limit and smart case" {
    var lower = try Query.init(testing.allocator, "strasse σ");
    defer lower.deinit(testing.allocator);
    try testing.expect(!lower.case_sensitive);

    var upper = try Query.init(testing.allocator, "Straße Σ");
    defer upper.deinit(testing.allocator);
    try testing.expect(upper.case_sensitive);
    try testing.expectEqual(@as(u21, 'a'), fold('A'));
    try testing.expectEqual(@as(u21, 0x03c3), fold(0x03a3));
    try testing.expectEqual(@as(u21, 0x00df), fold(0x00df));

    try testing.expectError(error.InvalidUtf8, Query.init(testing.allocator, &.{0xff}));
    try testing.expectError(error.Nul, Query.init(testing.allocator, "a\x00b"));
    try testing.expectError(error.LineEnding, Query.init(testing.allocator, "a\nb"));

    var limit: [max_query_scalars]u8 = @splat('a');
    var accepted = try Query.init(testing.allocator, &limit);
    defer accepted.deinit(testing.allocator);
    var over: [max_query_scalars + 1]u8 = @splat('a');
    try testing.expectError(error.TooLong, Query.init(testing.allocator, &over));
}

test "M21 kernel scan releases every owned allocation on failure" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseScanAllocationFailures, .{});
}

test "M21 kernel literal scan returns leftmost non-overlapping exact ranges and scalar columns" {
    var query = try Query.init(testing.allocator, "é.");
    defer query.deinit(testing.allocator);
    const candidates = [_]Candidate{
        .{ .text = "xÉ.é.é", .location = .{ .source = .{ .file_index = 2, .relation = .new, .new_path = "src/a.zig", .new_line = 8 } }, .corpus_order = 3 },
    };
    var batch = try scan(testing.allocator, query, &candidates, .literal);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), batch.occurrences.len);
    try testing.expectEqual(@as(usize, 2), batch.occurrences[0].column);
    try testing.expectEqual(Range{ .start = 1, .end = 4 }, batch.occurrences[0].ranges[0]);
    try testing.expectEqual(@as(usize, 4), batch.occurrences[1].column);
    try testing.expectEqual(Range{ .start = 4, .end = 7 }, batch.occurrences[1].ranges[0]);
}

test "M21 kernel literal scan maps a semantic ReviewBody match across Markdown delimiters" {
    var query = try Query.init(testing.allocator, "bold text");
    defer query.deinit(testing.allocator);
    const mappings = [_]Mapping{
        .{ .semantic = .{ .start = 0, .end = 4 }, .authored = .{ .start = 2, .end = 6 } },
        .{ .semantic = .{ .start = 4, .end = 9 }, .authored = .{ .start = 8, .end = 13 } },
    };
    const candidates = [_]Candidate{
        .{ .text = "bold text", .mapping = &mappings, .location = .{ .review_body = .{ .owner = .{ .comment = 4 }, .logical_line = 1 } } },
    };
    var batch = try scan(testing.allocator, query, &candidates, .literal);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    try testing.expectEqualSlices(Range, &.{ .{ .start = 2, .end = 6 }, .{ .start = 8, .end = 13 } }, batch.occurrences[0].ranges);
}

test "M21 kernel fuzzy scan keeps one best alignment and ranks exact before fallback" {
    var query = try Query.init(testing.allocator, "ab");
    defer query.deinit(testing.allocator);
    const candidates = [_]Candidate{
        .{ .text = "a---b", .location = .{ .review_body = .{ .owner = .{ .draft = 1 }, .logical_line = 1 } }, .corpus_order = 0 },
        .{ .text = "ab", .location = .{ .review_body = .{ .owner = .{ .draft = 2 }, .logical_line = 1 } }, .corpus_order = 1 },
        .{ .text = "xxaB", .location = .{ .review_body = .{ .owner = .{ .draft = 3 }, .logical_line = 1 } }, .corpus_order = 2 },
    };
    var batch = try scan(testing.allocator, query, &candidates, .fuzzy);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), batch.occurrences.len);
    try testing.expectEqual(@as(u64, 2), batch.occurrences[0].location.review_body.owner.draft);
    try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 2 }}, batch.occurrences[0].ranges);
    try testing.expect(batch.occurrences[0].calculation == .exact);
    try testing.expect(batch.occurrences[0].score > batch.occurrences[1].score);
}

test "M21 kernel fuzzy fallback stays deterministic and ranks after exact results" {
    var query_text: [max_query_scalars]u8 = @splat('a');
    var query = try Query.init(testing.allocator, &query_text);
    defer query.deinit(testing.allocator);
    var long_text: [1025]u8 = @splat('a');
    const candidates = [_]Candidate{
        .{ .text = &long_text, .location = .{ .review_body = .{ .owner = .{ .draft = 1 }, .logical_line = 1 } }, .corpus_order = 0 },
        .{ .text = &query_text, .location = .{ .review_body = .{ .owner = .{ .draft = 2 }, .logical_line = 1 } }, .corpus_order = 1 },
    };
    var batch = try scan(testing.allocator, query, &candidates, .fuzzy);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), batch.occurrences.len);
    try testing.expect(batch.occurrences[0].calculation == .exact);
    try testing.expect(batch.occurrences[1].calculation == .fallback);
}

test "M21 kernel ReviewBody candidates cross Markdown delimiters but stop at generated link boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body = try review_body.ReviewBody.parse(allocator, "**bold** text [docs](https://x) tail\nnext");
    var candidates: std.ArrayList(Candidate) = .empty;
    var corpus_order: usize = 0;
    try appendReviewBodyCandidates(allocator, body, .{ .comment = 7 }, 3, &corpus_order, &candidates);

    try testing.expectEqual(@as(usize, 2), candidates.items.len);
    try testing.expectEqualStrings("bold text docshttps://x tail", candidates.items[0].text);
    try testing.expectEqualSlices(usize, &.{ 14, 23 }, candidates.items[0].boundaries);
    try testing.expectEqual(@as(u32, 1), candidates.items[0].location.review_body.logical_line);

    const across_markdown = try Query.init(allocator, "bold text");
    const generated = try Query.init(allocator, "docshttps");
    const allowed = try scan(allocator, across_markdown, candidates.items, .literal);
    const refused = try scan(allocator, generated, candidates.items, .literal);
    try testing.expectEqual(@as(usize, 1), allowed.occurrences.len);
    try testing.expectEqual(@as(usize, 0), refused.occurrences.len);
}

test "M21 kernel fuzzy scores exact boundaries gaps and ties in deterministic order" {
    var query = try Query.init(testing.allocator, "b");
    defer query.deinit(testing.allocator);
    const candidates = [_]Candidate{
        .{ .text = "ab", .location = .{ .review_body = .{ .owner = .{ .draft = 6 }, .logical_line = 1 } }, .corpus_order = 6 },
        .{ .text = ".b", .location = .{ .review_body = .{ .owner = .{ .draft = 5 }, .logical_line = 1 } }, .corpus_order = 5 },
        .{ .text = "aB", .location = .{ .review_body = .{ .owner = .{ .draft = 4 }, .logical_line = 1 } }, .corpus_order = 4 },
        .{ .text = "-b", .location = .{ .review_body = .{ .owner = .{ .draft = 3 }, .logical_line = 1 } }, .corpus_order = 3 },
        .{ .text = "_b", .location = .{ .review_body = .{ .owner = .{ .draft = 2 }, .logical_line = 1 } }, .corpus_order = 2 },
        .{ .text = "/b", .location = .{ .review_body = .{ .owner = .{ .draft = 1 }, .logical_line = 1 } }, .corpus_order = 1 },
        .{ .text = "b", .location = .{ .review_body = .{ .owner = .{ .draft = 0 }, .logical_line = 1 } }, .corpus_order = 0 },
    };
    var batch = try scan(testing.allocator, query, &candidates, .fuzzy);
    defer batch.deinit(testing.allocator);
    const expected = [_]bbr.review.TempId{ 0, 1, 2, 3, 4, 5, 6 };
    for (batch.occurrences, expected) |occurrence, id| try testing.expectEqual(id, occurrence.location.review_body.owner.draft);

    var gap_query = try Query.init(testing.allocator, "ab");
    defer gap_query.deinit(testing.allocator);
    const gaps = [_]Candidate{
        .{ .text = "a---b", .location = .{ .review_body = .{ .owner = .{ .draft = 8 }, .logical_line = 1 } } },
        .{ .text = "a_b", .location = .{ .review_body = .{ .owner = .{ .draft = 7 }, .logical_line = 1 } } },
    };
    var gap_batch = try scan(testing.allocator, gap_query, &gaps, .fuzzy);
    defer gap_batch.deinit(testing.allocator);
    try testing.expectEqual(@as(bbr.review.TempId, 7), gap_batch.occurrences[0].location.review_body.owner.draft);
}

test "M21 kernel smart case does not normalize or apply multi-scalar folds" {
    var lower = try Query.init(testing.allocator, "σ");
    defer lower.deinit(testing.allocator);
    const upper_candidate = [_]Candidate{.{ .text = "Σ", .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } } }};
    var folded = try scan(testing.allocator, lower, &upper_candidate, .literal);
    defer folded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), folded.occurrences.len);

    var upper = try Query.init(testing.allocator, "Σ");
    defer upper.deinit(testing.allocator);
    const lower_candidate = [_]Candidate{.{ .text = "σ", .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } } }};
    var sensitive = try scan(testing.allocator, upper, &lower_candidate, .literal);
    defer sensitive.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), sensitive.occurrences.len);

    var composed = try Query.init(testing.allocator, "é");
    defer composed.deinit(testing.allocator);
    const decomposed = [_]Candidate{.{ .text = "e\xcc\x81", .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } } }};
    var normalized = try scan(testing.allocator, composed, &decomposed, .literal);
    defer normalized.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), normalized.occurrences.len);

    var sharp_s = try Query.init(testing.allocator, "ß");
    defer sharp_s.deinit(testing.allocator);
    const expanded = [_]Candidate{.{ .text = "ss", .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } } }};
    var multi = try scan(testing.allocator, sharp_s, &expanded, .literal);
    defer multi.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), multi.occurrences.len);
}

test "M21 kernel generated-boundary region is not an exact whole logical Line" {
    var query = try Query.init(testing.allocator, "https://x");
    defer query.deinit(testing.allocator);
    const candidate = [_]Candidate{.{
        .text = "docshttps://x tail",
        .boundaries = &.{ 4, 13 },
        .location = .{ .review_body = .{ .owner = .{ .comment = 1 }, .logical_line = 1 } },
    }};
    var batch = try scan(testing.allocator, query, &candidate, .fuzzy);
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    try testing.expect(batch.occurrences[0].score != score_max);
}
