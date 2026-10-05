//! Pure Unicode matching for Buffer Search and Review Search.

const std = @import("std");
const bbr = @import("bbr");
const unicode_data = @import("search_unicode_data.zig");
const review_body = @import("review_body.zig");
const fold = @import("unicode_case.zig").fold;

pub const max_query_scalars = 256;

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Mapping = struct {
    semantic: Range,
    authored: Range,
    authored_column: ?usize = null,
    authored_line: ?u32 = null,
    definition_source: ?Range = null,
    /// Static catalog bytes. Either branch consumes this authored location once.
    alternative: []const u8 = "",
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
    definition_ranges: []const Range = &.{},
    column: usize,
    score: f64 = 0,
    calculation: Calculation = .exact,
    candidate_scalars: usize,
    corpus_order: usize,
    session_epoch: u64,

    fn deinit(self: *Occurrence, allocator: std.mem.Allocator) void {
        self.location.deinit(allocator);
        allocator.free(self.ranges);
        allocator.free(self.definition_ranges);
        self.* = undefined;
    }
};

pub const Batch = struct {
    occurrences: []Occurrence,
    references: ?*std.atomic.Value(usize) = null,
    // Worker-owned batches keep their allocator when Presentation takes ownership.
    owner: ?std.mem.Allocator = null,
    // Literal scans allocate many Occurrences. Release the worker arena once
    // instead of freeing each Occurrence on the terminal thread.
    owner_arena: ?*std.heap.ArenaAllocator = null,

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
            target.definition_ranges = allocator.dupe(Range, source.definition_ranges) catch |err| {
                target.deinit(allocator);
                return err;
            };
            initialized += 1;
        }
        return .{ .occurrences = occurrences };
    }

    /// Give a worker an immutable view while Presentation can replace its Batch.
    pub fn retain(self: *Batch, allocator: std.mem.Allocator) !Batch {
        if (self.references == null) {
            const references = try std.heap.page_allocator.create(std.atomic.Value(usize));
            references.* = .init(1);
            self.references = references;
            if (self.owner == null and self.owner_arena == null) self.owner = allocator;
        }
        _ = self.references.?.fetchAdd(1, .acq_rel);
        return self.*;
    }

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        if (self.references) |references| {
            const last = references.fetchSub(1, .acq_rel) == 1;
            if (!last) {
                self.* = undefined;
                return;
            }
            std.heap.page_allocator.destroy(references);
        }
        if (self.owner_arena) |arena| {
            const backing = arena.child_allocator;
            arena.deinit();
            backing.destroy(arena);
            self.* = undefined;
            return;
        }
        const backing = self.owner orelse allocator;
        for (self.occurrences) |*occurrence| occurrence.deinit(backing);
        backing.free(self.occurrences);
        self.* = undefined;
    }
};

test "a retained Batch survives replacement until its worker releases it" {
    const allocator = std.testing.allocator;
    var batch: Batch = .{ .occurrences = try allocator.alloc(Occurrence, 0) };
    var worker = try batch.retain(allocator);
    batch.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), worker.occurrences.len);
    worker.deinit(allocator);
}

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
        var has_emoji = false;
        for (candidate.mapping) |entry| has_emoji = has_emoji or entry.alternative.len > 0;
        if (has_emoji) {
            if (mode == .literal) {
                for (regions) |region| try scanEmojiLiteral(allocator, query, candidate, scalars, region, &occurrences);
            } else try scanEmojiFuzzy(allocator, query, candidate, scalars, regions, &occurrences);
            continue;
        }
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
    var old_count: usize = 0;
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
        if (version.relation == .old) old_count = candidates.items.len;
    }
    var batch = try scan(allocator, query, candidates.items, .fuzzy);
    if (old == null or new == null) return batch;
    errdefer batch.deinit(allocator);
    const old_lines = candidates.items[0..old_count];
    const new_lines = candidates.items[old_count..];
    const old_matches = try allocator.alloc(?usize, old_lines.len);
    defer allocator.free(old_matches);
    @memset(old_matches, null);
    const new_matches = try allocator.alloc(?usize, new_lines.len);
    defer allocator.free(new_matches);
    @memset(new_matches, null);
    for (batch.occurrences, 0..) |occurrence, index| {
        const source = occurrence.location.source;
        switch (source.relation) {
            .old => if (source.old_line) |number| {
                const offset = @as(usize, number) - 1;
                if (offset < old_matches.len) old_matches[offset] = index;
            },
            .new => if (source.new_line) |number| {
                const offset = @as(usize, number) - 1;
                if (offset < new_matches.len) new_matches[offset] = index;
            },
            .neutral => {},
        }
    }
    for (file.hunks) |hunk| for (hunk.lines) |line| {
        if (line.kind != .context or line.old_no == 0 or line.new_no == 0) continue;
        const old_offset = @as(usize, line.old_no) - 1;
        const new_offset = @as(usize, line.new_no) - 1;
        if (old_offset >= old_lines.len or new_offset >= new_lines.len) continue;
        const old_text = old_lines[old_offset].text;
        const new_text = new_lines[new_offset].text;
        if (!std.mem.eql(u8, old_text, new_text) or !std.mem.eql(u8, old_text, line.text)) continue;
        if (old_matches[old_offset]) |oi| if (new_matches[new_offset]) |ni| {
            const before = &batch.occurrences[oi];
            const after = &batch.occurrences[ni];
            if (before.location.source.relation != .old or after.location.source.relation != .new) continue;
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
        if (occurrence.corpus_order != std.math.maxInt(usize)) kept += 1;
    }
    if (kept == batch.occurrences.len) return batch;
    const compact = try allocator.alloc(Occurrence, kept);
    kept = 0;
    for (batch.occurrences) |occurrence| {
        if (occurrence.corpus_order == std.math.maxInt(usize)) {
            var duplicate = occurrence;
            duplicate.deinit(allocator);
        } else {
            compact[kept] = occurrence;
            kept += 1;
        }
    }
    allocator.free(batch.occurrences);
    batch.occurrences = compact;
    return batch;
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

const no_node: usize = std.math.maxInt(usize);
const BranchNode = struct { scalar: Scalar, previous: [2]usize, authored_form: bool = false };

fn appendBranch(allocator: std.mem.Allocator, nodes: *std.ArrayList(BranchNode), text: []const u8, semantic: Range, previous: [2]usize, atomic: bool) !usize {
    var before = previous;
    const scalars = try decode(allocator, text);
    defer allocator.free(scalars);
    for (scalars) |scalar| {
        try nodes.append(allocator, .{ .scalar = .{ .value = scalar.value, .bytes = if (atomic) semantic else .{ .start = semantic.start + scalar.bytes.start, .end = semantic.start + scalar.bytes.end } }, .previous = before, .authored_form = atomic and scalar.bytes.start == 0 });
        before = .{ nodes.items.len - 1, no_node };
    }
    return before[0];
}

// The two branches rejoin only after the complete emoji. A match can never
// walk from its displayed sequence into its own shortcode sequence.
fn emojiGraph(allocator: std.mem.Allocator, query: Query, candidate: Candidate, start_byte: usize, end_byte: usize, nodes: *std.ArrayList(BranchNode)) ![2]usize {
    var previous = [_]usize{ no_node, no_node };
    var offset = start_byte;
    for (candidate.mapping) |entry| {
        if (entry.alternative.len == 0 or entry.semantic.start < start_byte or entry.semantic.end > end_byte) continue;
        if (offset < entry.semantic.start) previous = .{ try appendBranch(allocator, nodes, candidate.text[offset..entry.semantic.start], .{ .start = offset, .end = entry.semantic.start }, previous, false), no_node };
        const displayed = try appendBranch(allocator, nodes, candidate.text[entry.semantic.start..entry.semantic.end], entry.semantic, previous, false);
        var supplies_query = false;
        for (entry.alternative) |byte| for (query.scalars) |needle| {
            supplies_query = supplies_query or equalScalar(query, needle, byte);
        };
        // Unmatched shortcode branches have the same following boundary bonus
        // as emoji, but add gaps and authored forms. Displayed text dominates.
        const authored = if (supplies_query) try appendBranch(allocator, nodes, entry.alternative, entry.semantic, previous, true) else no_node;
        previous = .{ displayed, authored };
        offset = entry.semantic.end;
    }
    if (offset < end_byte) previous = .{ try appendBranch(allocator, nodes, candidate.text[offset..end_byte], .{ .start = offset, .end = end_byte }, previous, false), no_node };
    return previous;
}

fn scanEmojiLiteral(allocator: std.mem.Allocator, query: Query, candidate: Candidate, scalars: []const Scalar, region: Range, occurrences: *std.ArrayList(Occurrence)) !void {
    if (region.start == region.end) return;
    var nodes: std.ArrayList(BranchNode) = .empty;
    defer nodes.deinit(allocator);
    _ = try emojiGraph(allocator, query, candidate, scalars[region.start].bytes.start, scalars[region.end - 1].bytes.end, &nodes);
    if (query.scalars.len > nodes.items.len) return;
    var before = try allocator.alloc(usize, nodes.items.len);
    defer allocator.free(before);
    var current = try allocator.alloc(usize, nodes.items.len);
    defer allocator.free(current);
    @memset(before, no_node);
    for (query.scalars, 0..) |needle, qi| {
        @memset(current, no_node);
        var live = false;
        for (nodes.items, 0..) |node, ni| {
            if (!equalScalar(query, needle, node.scalar.value)) continue;
            if (qi == 0) {
                current[ni] = node.scalar.bytes.start;
            } else {
                for (node.previous) |predecessor| {
                    if (predecessor != no_node) current[ni] = @min(current[ni], before[predecessor]);
                }
            }
            live = live or current[ni] != no_node;
        }
        if (!live) return;
        const swap = before;
        before = current;
        current = swap;
    }
    var matches: std.ArrayList(Range) = .empty;
    defer matches.deinit(allocator);
    for (nodes.items, before) |node, first| if (first != no_node) {
        try matches.append(allocator, .{ .start = first, .end = node.scalar.bytes.end });
    };
    std.mem.sort(Range, matches.items, {}, struct {
        fn less(_: void, left: Range, right: Range) bool {
            return if (left.start != right.start) left.start < right.start else left.end < right.end;
        }
    }.less);
    var authored_end: usize = 0;
    var scalar_cursor = region.start;
    for (matches.items) |match| {
        var positions: std.ArrayList(usize) = .empty;
        defer positions.deinit(allocator);
        while (scalar_cursor < region.end and scalars[scalar_cursor].bytes.end <= match.start) scalar_cursor += 1;
        var index = scalar_cursor;
        while (index < region.end and scalars[index].bytes.start < match.end) : (index += 1) try positions.append(allocator, index);
        var occurrence = try makeOccurrence(allocator, candidate, scalars, positions.items, 0, .exact);
        errdefer occurrence.deinit(allocator);
        if (occurrence.ranges[0].start < authored_end) {
            occurrence.deinit(allocator);
            continue;
        }
        authored_end = occurrence.ranges[occurrence.ranges.len - 1].end;
        try occurrences.append(allocator, occurrence);
    }
}

const BranchPath = struct {
    // All M21 weights are multiples of 1/200. Integer accumulation preserves
    // mathematical ties before representation and authored-alignment ordering.
    score: i64 = std.math.minInt(i64),
    authored_forms: usize = 0,
    length: usize = 0,
    first: usize = no_node,
    last: usize = no_node,
    previous: usize = no_node,
    matched: bool = false,

    fn better(left: BranchPath, right: BranchPath) bool {
        if (left.score != right.score) return left.score > right.score;
        if (left.authored_forms != right.authored_forms) return left.authored_forms < right.authored_forms;
        return left.first < right.first;
    }

    fn step(self: BranchPath, node: BranchNode, score: f64, previous: usize, matched: bool) BranchPath {
        if (self.score == std.math.minInt(i64)) return .{};
        return .{
            .score = self.score + @as(i64, @intFromFloat(@round(score * 200))),
            .authored_forms = self.authored_forms + @intFromBool(node.authored_form),
            .length = self.length + 1,
            .first = if (matched and self.first == no_node) node.scalar.bytes.start else self.first,
            .last = if (matched) node.scalar.bytes.start else self.last,
            .previous = previous,
            .matched = matched,
        };
    }

    fn resultScore(self: BranchPath) f64 {
        return if (self.score == std.math.maxInt(i64)) score_max else @as(f64, @floatFromInt(self.score)) / 200;
    }
};

const BranchTrace = struct { path: BranchPath, node: usize, next: usize = no_node };
const BranchFrontiers = struct { exact: usize = no_node, best: usize = no_node };
const EmojiAlignment = struct {
    positions: []usize,
    path: BranchPath,
};

fn alignmentOrder(left: BranchPath, right: BranchPath, traces: []const BranchTrace) i8 {
    var left_positions: [max_query_scalars]usize = undefined;
    var right_positions: [max_query_scalars]usize = undefined;
    var starts = [_]usize{ max_query_scalars, max_query_scalars };
    for ([_]BranchPath{ left, right }, 0..) |initial, side| {
        var path = initial;
        while (true) {
            if (path.matched) {
                starts[side] -= 1;
                if (side == 0) left_positions[starts[side]] = path.last else right_positions[starts[side]] = path.last;
            }
            if (path.previous == no_node) break;
            path = traces[path.previous].path;
        }
    }
    for (left_positions[starts[0]..], right_positions[starts[1]..]) |a, b| {
        if (a != b) return if (a < b) -1 else 1;
    }
    return 0;
}

fn traceBetter(left: BranchPath, right: BranchPath, traces: []const BranchTrace) bool {
    if (left.score != right.score or left.authored_forms != right.authored_forms or left.first != right.first) return left.better(right);
    return alignmentOrder(left, right, traces) < 0;
}

// Keep the score/length frontier. A longer, higher-scoring prefix must not
// discard a shorter prefix that alone can finish within M21's work limit.
fn appendFrontier(allocator: std.mem.Allocator, traces: *std.ArrayList(BranchTrace), head: *usize, path: BranchPath, node: usize, remaining: usize, limit: usize) !void {
    if (path.score == std.math.minInt(i64) or remaining > limit or path.length > limit - remaining) return;
    var link = head;
    while (link.* != no_node) {
        const index = link.*;
        const current = traces.items[index].path;
        const tied = current.score == path.score and current.authored_forms == path.authored_forms and current.first == path.first;
        const order = if (tied) alignmentOrder(current, path, traces.items) else @as(i8, 0);
        if (current.length <= path.length and (current.better(path) or (tied and order <= 0))) return;
        if (path.length <= current.length and (path.better(current) or (tied and order > 0))) {
            link.* = traces.items[index].next;
        } else link = &traces.items[index].next;
    }
    // ArrayList growth can invalidate link, so publish through head only.
    const next = head.*;
    try traces.append(allocator, .{ .path = path, .node = node, .next = next });
    head.* = traces.items.len - 1;
}

fn exactEmojiAlignment(allocator: std.mem.Allocator, query: Query, nodes: []const BranchNode, ends: [2]usize, whole: bool) !?EmojiAlignment {
    const limit = exact_fuzzy_cell_limit / query.scalars.len;
    const remaining = try allocator.alloc(usize, nodes.len);
    defer allocator.free(remaining);
    @memset(remaining, no_node);
    for (ends) |end| if (end != no_node) {
        remaining[end] = 0;
    };
    var cursor = nodes.len;
    while (cursor > 0) {
        cursor -= 1;
        for (nodes[cursor].previous) |previous| if (previous != no_node) {
            remaining[previous] = @min(remaining[previous], remaining[cursor] + 1);
        };
    }
    const leading = try allocator.alloc(BranchPath, nodes.len);
    defer allocator.free(leading);
    for (nodes, 0..) |node, index| {
        var before: BranchPath = .{};
        if (node.previous[0] == no_node) before = .{ .score = 0 };
        for (node.previous) |previous| if (previous != no_node and leading[previous].better(before)) {
            before = leading[previous];
        };
        leading[index] = before.step(node, score_gap_leading, no_node, false);
    }
    var shortest = no_node;
    for (ends) |end| if (end != no_node) {
        shortest = @min(shortest, leading[end].length);
    };
    if (shortest > limit) return null;
    // Only the current and previous query rows remain live. Traceback records
    // retain accepted paths, rather than a table for every mutually exclusive branch.
    const table = try allocator.alloc(BranchFrontiers, 2 * nodes.len);
    defer allocator.free(table);
    for (table) |*cell| cell.* = .{};
    var traces: std.ArrayList(BranchTrace) = .empty;
    defer traces.deinit(allocator);
    for (query.scalars, 0..) |needle, query_index| {
        const current_row = table[(query_index % 2) * nodes.len ..][0..nodes.len];
        const previous_row = table[((query_index + 1) % 2) * nodes.len ..][0..nodes.len];
        for (current_row) |*cell| cell.* = .{};
        const gap = if (query_index + 1 == query.scalars.len) score_gap_trailing else score_gap_inner;
        for (nodes, 0..) |node, index| {
            const cell = &current_row[index];
            if (equalScalar(query, needle, node.scalar.value)) {
                if (query_index == 0 and node.previous[0] == no_node) try appendFrontier(allocator, &traces, &cell.exact, (BranchPath{ .score = 0 }).step(node, score_match_word, no_node, true), index, remaining[index], limit);
                for (node.previous) |previous| {
                    if (previous == no_node) continue;
                    if (query_index == 0) {
                        try appendFrontier(allocator, &traces, &cell.exact, leading[previous].step(node, branchBonus(nodes[previous].scalar.value, node.scalar.value), no_node, true), index, remaining[index], limit);
                    } else {
                        const before = previous_row[previous];
                        for ([_]struct { head: usize, bonus: f64 }{ .{ .head = before.exact, .bonus = score_match_consecutive }, .{ .head = before.best, .bonus = branchBonus(nodes[previous].scalar.value, node.scalar.value) } }) |track| {
                            var trace = track.head;
                            while (trace != no_node) {
                                const value = traces.items[trace];
                                try appendFrontier(allocator, &traces, &cell.exact, value.path.step(node, track.bonus, trace, true), index, remaining[index], limit);
                                trace = value.next;
                            }
                        }
                    }
                }
            }
            var exact = cell.exact;
            while (exact != no_node) {
                const value = traces.items[exact];
                try appendFrontier(allocator, &traces, &cell.best, value.path, index, remaining[index], limit);
                exact = value.next;
            }
            for (node.previous) |previous| {
                if (previous == no_node) continue;
                var trace = current_row[previous].best;
                while (trace != no_node) {
                    const value = traces.items[trace];
                    try appendFrontier(allocator, &traces, &cell.best, value.path.step(node, gap, trace, false), index, remaining[index], limit);
                    trace = value.next;
                }
            }
        }
    }
    var winner: BranchPath = .{};
    var winner_index = no_node;
    for (ends) |end| {
        if (end == no_node) continue;
        var trace = table[((query.scalars.len - 1) % 2) * nodes.len + end].best;
        while (trace != no_node) {
            const value = traces.items[trace];
            var path = value.path;
            if (whole and path.length == query.scalars.len) path.score = std.math.maxInt(i64);
            if (traceBetter(path, winner, traces.items)) {
                winner = path;
                winner_index = trace;
            }
            trace = value.next;
        }
    }
    if (winner_index == no_node) return null;
    const positions = try allocator.alloc(usize, query.scalars.len);
    var left = positions.len;
    cursor = winner_index;
    while (cursor != no_node) {
        const value = traces.items[cursor];
        if (value.path.matched) {
            left -= 1;
            positions[left] = value.node;
        }
        cursor = value.path.previous;
    }
    std.debug.assert(left == 0);
    return .{ .positions = positions, .path = winner };
}

const GreedyState = struct {
    path: BranchPath = .{},
    previous_value: ?u21 = null,
    positions: [max_query_scalars]Range = undefined,
};

fn greedyBetter(left: GreedyState, right: GreedyState, consumed: usize) bool {
    if (left.path.score == std.math.minInt(i64)) return false;
    if (left.path.score != right.path.score or left.path.authored_forms != right.path.authored_forms or left.path.first != right.path.first) return left.path.better(right.path);
    for (left.positions[0..consumed], right.positions[0..consumed]) |a, b| {
        if (a.start != b.start) return a.start < b.start;
    }
    return false;
}

fn advanceGreedy(query: Query, text: []const u8, semantic: Range, atomic: bool, current: *[]GreedyState, scratch: *[]GreedyState) void {
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    var offset: usize = 0;
    while (iterator.nextCodepointSlice()) |bytes| {
        const scalar: Scalar = .{ .value = std.unicode.utf8Decode(bytes) catch unreachable, .bytes = if (atomic) semantic else .{ .start = semantic.start + offset, .end = semantic.start + offset + bytes.len } };
        const node: BranchNode = .{ .scalar = scalar, .previous = .{ no_node, no_node }, .authored_form = atomic and offset == 0 };
        for (scratch.*) |*state| state.path = .{};
        for (current.*, 0..) |*state, index| {
            if (state.path.score == std.math.minInt(i64)) continue;
            const consumed = index / 2;
            const matched = consumed < query.scalars.len and equalScalar(query, query.scalars[consumed], scalar.value);
            const next = consumed + @intFromBool(matched);
            const bonus = if (matched) if (consumed > 0 and state.path.matched) score_match_consecutive else branchBonus(state.previous_value, scalar.value) else if (consumed == 0) score_gap_leading else if (consumed == query.scalars.len) score_gap_trailing else score_gap_inner;
            const path = state.path.step(node, bonus, no_node, matched);
            const target = &scratch.*[next * 2 + @intFromBool(matched)];
            var advanced = state.*;
            advanced.path = path;
            advanced.previous_value = scalar.value;
            if (matched) advanced.positions[consumed] = scalar.bytes;
            if (greedyBetter(advanced, target.*, next)) target.* = advanced;
        }
        const swap = current.*;
        current.* = scratch.*;
        scratch.* = swap;
        offset += bytes.len;
    }
}

fn greedyEmojiOccurrence(allocator: std.mem.Allocator, query: Query, candidate: Candidate, region: Range) !?struct { occurrence: Occurrence, forms: usize } {
    const state_count = (query.scalars.len + 1) * 2;
    var current = try allocator.alloc(GreedyState, state_count);
    defer allocator.free(current);
    var scratch = try allocator.alloc(GreedyState, state_count);
    defer allocator.free(scratch);
    const before = try allocator.alloc(GreedyState, state_count);
    defer allocator.free(before);
    const displayed = try allocator.alloc(GreedyState, state_count);
    defer allocator.free(displayed);
    for (current) |*state| state.path = .{};
    current[0] = .{ .path = .{ .score = 0 } };
    for (candidate.mapping) |entry| {
        const start = @max(region.start, entry.semantic.start);
        const end = @min(region.end, entry.semantic.end);
        if (start >= end) continue;
        if (entry.alternative.len == 0) {
            advanceGreedy(query, candidate.text[start..end], .{ .start = start, .end = end }, false, &current, &scratch);
        } else {
            @memcpy(before, current);
            advanceGreedy(query, candidate.text[start..end], .{ .start = start, .end = end }, false, &current, &scratch);
            @memcpy(displayed, current);
            @memcpy(current, before);
            advanceGreedy(query, entry.alternative, entry.semantic, true, &current, &scratch);
            for (current, displayed, 0..) |*authored, visible, index| if (greedyBetter(visible, authored.*, index / 2)) {
                authored.* = visible;
            };
        }
    }
    const final = current[query.scalars.len * 2 ..];
    const winner = if (greedyBetter(final[0], final[1], query.scalars.len)) final[0] else final[1];
    if (winner.path.score == std.math.minInt(i64)) return null;
    const scalars = try allocator.alloc(Scalar, query.scalars.len);
    defer allocator.free(scalars);
    const positions = try allocator.alloc(usize, query.scalars.len);
    defer allocator.free(positions);
    for (scalars, positions, 0..) |*scalar, *position, index| {
        scalar.* = .{ .value = query.scalars[index], .bytes = winner.positions[index] };
        position.* = index;
    }
    var found = try makeOccurrence(allocator, candidate, scalars, positions, winner.path.resultScore(), .fallback);
    found.candidate_scalars = winner.path.length;
    return .{ .occurrence = found, .forms = winner.path.authored_forms };
}

fn branchBonus(previous: ?u21, current: u21) f64 {
    const before = previous orelse return score_match_word;
    if (before == '/' or before == '\\') return score_match_slash;
    if (before == ' ' or before == '_' or before == '-') return score_match_word;
    if (before == '.') return score_match_dot;
    if (isLowercase(before) and isUppercase(current)) return score_match_capital;
    return 0;
}

fn minimumMatchingLength(query: Query, candidate: Candidate, region: Range) usize {
    var current = [_]usize{no_node} ** (max_query_scalars + 1);
    var next = current;
    current[0] = 0;
    for (candidate.mapping) |entry| {
        const start = @max(region.start, entry.semantic.start);
        const end = @min(region.end, entry.semantic.end);
        if (start >= end) continue;
        @memset(&next, no_node);
        for ([_][]const u8{ candidate.text[start..end], entry.alternative }) |text| {
            if (text.len == 0) continue;
            const length = std.unicode.utf8CountCodepoints(text) catch unreachable;
            for (current[0 .. query.scalars.len + 1], 0..) |prefix, consumed| {
                if (prefix == no_node) continue;
                var progress = consumed;
                var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
                while (iterator.nextCodepoint()) |scalar| {
                    if (progress < query.scalars.len and equalScalar(query, query.scalars[progress], scalar)) progress += 1;
                }
                next[progress] = @min(next[progress], prefix +| length);
            }
        }
        current = next;
    }
    return current[query.scalars.len];
}

fn scanEmojiFuzzy(allocator: std.mem.Allocator, query: Query, candidate: Candidate, displayed: []const Scalar, regions: []const Range, occurrences: *std.ArrayList(Occurrence)) !void {
    var best: ?Occurrence = null;
    errdefer if (best) |*value| value.deinit(allocator);
    var best_forms: usize = no_node;
    for (regions) |region| {
        if (region.start == region.end) continue;
        var nodes: std.ArrayList(BranchNode) = .empty;
        defer nodes.deinit(allocator);
        const bytes = Range{ .start = displayed[region.start].bytes.start, .end = displayed[region.end - 1].bytes.end };
        // Check legal matching lengths before allocating exact search storage.
        const minimum = minimumMatchingLength(query, candidate, bytes);
        if (minimum == no_node) continue;
        const alignment = if (minimum <= exact_fuzzy_cell_limit / query.scalars.len) blk: {
            const ends = try emojiGraph(allocator, query, candidate, bytes.start, bytes.end, &nodes);
            break :blk try exactEmojiAlignment(allocator, query, nodes.items, ends, candidate.boundaries.len == 0);
        } else null;
        var found: Occurrence = undefined;
        var forms: usize = undefined;
        if (alignment) |matched| {
            defer allocator.free(matched.positions);
            const graph_scalars = try allocator.alloc(Scalar, nodes.items.len);
            defer allocator.free(graph_scalars);
            for (nodes.items, graph_scalars) |node, *scalar| scalar.* = node.scalar;
            found = try makeOccurrence(allocator, candidate, graph_scalars, matched.positions, matched.path.resultScore(), .exact);
            found.candidate_scalars = matched.path.length;
            forms = matched.path.authored_forms;
        } else {
            const fallback = (try greedyEmojiOccurrence(allocator, query, candidate, .{ .start = displayed[region.start].bytes.start, .end = displayed[region.end - 1].bytes.end })) orelse continue;
            found = fallback.occurrence;
            forms = fallback.forms;
        }
        errdefer found.deinit(allocator);
        found.candidate_scalars += displayed.len - (region.end - region.start);
        const better = if (best) |value| if (found.calculation != value.calculation) found.calculation == .exact else if (found.score != value.score) found.score > value.score else if (forms != best_forms) forms < best_forms else found.ranges[0].start < value.ranges[0].start else true;
        if (better) {
            if (best) |*value| value.deinit(allocator);
            best = found;
            best_forms = forms;
        } else found.deinit(allocator);
    }
    if (best) |value| {
        try occurrences.append(allocator, value);
        best = null;
    }
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
    return branchBonus(if (index == 0) null else scalars[index - 1].value, scalars[index].value);
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
    const ranges = try mapRanges(allocator, semantic_ranges, candidate.mapping, false);
    errdefer allocator.free(ranges);
    const definition_ranges = try mapRanges(allocator, semantic_ranges, candidate.mapping, true);
    errdefer allocator.free(definition_ranges);
    var column = positions[0] + 1;
    var location = candidate.location;
    const first = scalars[positions[0]].bytes.start;
    for (candidate.mapping) |mapping| {
        if (first < mapping.semantic.start or first >= mapping.semantic.end) continue;
        if (mapping.authored_column) |authored_column| {
            column = authored_column + if (mapping.definition_source == null and mapping.alternative.len == 0) (std.unicode.utf8CountCodepoints(candidate.text[mapping.semantic.start..first]) catch 0) else @as(usize, 0);
        }
        if (mapping.authored_line) |line| if (location == .review_body) {
            location.review_body.logical_line = line;
        };
        break;
    }
    return .{
        .location = try location.clone(allocator),
        .ranges = ranges,
        .definition_ranges = definition_ranges,
        .column = column,
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
        if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].end >= scalar.start) {
            ranges.items[ranges.items.len - 1].end = @max(ranges.items[ranges.items.len - 1].end, scalar.end);
        } else try ranges.append(allocator, scalar);
    }
    return ranges.toOwnedSlice(allocator);
}

fn mapRanges(allocator: std.mem.Allocator, semantic_ranges: []const Range, mapping: []const Mapping, definitions: bool) ![]Range {
    if (mapping.len == 0) return allocator.dupe(Range, if (definitions) &.{} else semantic_ranges);
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(allocator);
    for (semantic_ranges) |semantic| for (mapping) |entry| {
        const start = @max(semantic.start, entry.semantic.start);
        const end = @min(semantic.end, entry.semantic.end);
        if (start >= end) continue;
        const source = if (definitions) entry.definition_source orelse continue else entry.authored;
        const equal_length = entry.alternative.len == 0 and (definitions or entry.definition_source == null) and source.end - source.start == entry.semantic.end - entry.semantic.start;
        const authored = if (equal_length) Range{
            .start = source.start + start - entry.semantic.start,
            .end = source.start + end - entry.semantic.start,
        } else source;
        if (ranges.items.len > 0 and std.meta.eql(ranges.items[ranges.items.len - 1], authored)) continue;
        if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].end >= authored.start) {
            ranges.items[ranges.items.len - 1].end = @max(ranges.items[ranges.items.len - 1].end, authored.end);
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
    if (mode == .literal and left.ranges.len > 0 and right.ranges.len > 0) return left.ranges[0].start < right.ranges[0].start;
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
    var authored_offset: usize = 0;
    var authored_line: u32 = 1;
    var authored_line_start: usize = 0;
    for (body.blocks) |block| {
        var region: BodyRegion = .{};
        const text = &region.text;
        defer text.deinit(allocator);
        const mappings = &region.mappings;
        defer mappings.deinit(allocator);
        const boundaries = &region.boundaries;
        defer boundaries.deinit(allocator);
        for (block.spans) |span| {
            if (span.boundary and text.items.len > 0) try boundaries.append(allocator, text.items.len);
            if (span.hard_break) {
                try appendBodyRegion(allocator, owner, session_epoch, corpus_order, candidates, &region);
                continue;
            }
            if (span.hidden or span.generated) continue;
            var pos: usize = 0;
            while (pos < span.text.len) {
                const newline = std.mem.indexOfScalarPos(u8, span.text, pos, '\n') orelse span.text.len;
                const end = if (newline > pos and span.text[newline - 1] == '\r') newline - 1 else newline;
                const start = span.source.start + if (span.definition_source == null) pos else @as(usize, 0);
                if (end > pos) {
                    while (authored_offset < start) : (authored_offset += 1) {
                        if (body.source[authored_offset] == '\n') {
                            authored_line += 1;
                            authored_line_start = authored_offset + 1;
                        }
                    }
                    const semantic_start = text.items.len;
                    try text.appendSlice(allocator, span.text[pos..end]);
                    try mappings.append(allocator, .{
                        .semantic = .{ .start = semantic_start, .end = text.items.len },
                        .authored = .{ .start = start, .end = if (span.join or span.emoji.len > 0) span.source.end else start + end - pos },
                        .alternative = span.emoji,
                        .definition_source = if (span.definition_source) |definition| .{ .start = definition.start + pos, .end = definition.start + end } else null,
                        .authored_column = 1 + (std.unicode.utf8CountCodepoints(body.source[authored_line_start..start]) catch start - authored_line_start),
                        .authored_line = authored_line,
                    });
                    if (span.definition_source != null) mappings.items[mappings.items.len - 1].authored = .{ .start = span.source.start, .end = span.source.end };
                }
                if (newline < span.text.len) try appendBodyRegion(allocator, owner, session_epoch, corpus_order, candidates, &region);
                pos = if (newline < span.text.len) newline + 1 else span.text.len;
            }
        }
        try appendBodyRegion(allocator, owner, session_epoch, corpus_order, candidates, &region);
    }
}

const BodyRegion = struct {
    text: std.ArrayList(u8) = .empty,
    mappings: std.ArrayList(Mapping) = .empty,
    boundaries: std.ArrayList(usize) = .empty,
};

fn appendBodyRegion(allocator: std.mem.Allocator, owner: ReviewBodyOwner, epoch: u64, order: *usize, candidates: *std.ArrayList(Candidate), region: *BodyRegion) !void {
    const text = &region.text;
    const mappings = &region.mappings;
    const boundaries = &region.boundaries;
    if (text.items.len == 0) return;
    const line = mappings.items[0].authored_line.?;
    const owned_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    const owned_mapping = try mappings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_mapping);
    const owned_boundaries = try boundaries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_boundaries);
    try candidates.append(allocator, .{ .text = owned_text, .mapping = owned_mapping, .boundaries = owned_boundaries, .location = .{ .review_body = .{ .owner = owner, .logical_line = line } }, .corpus_order = order.*, .session_epoch = epoch });
    order.* += 1;
}

const testing = std.testing;

test "M23 emoji both searches accept mixed forms and map partial matches to complete compounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "π :mask: :white_check_mark:\n\n:thumbsup::skin-tone-2:";
    const body = try review_body.ReviewBody.parse(a, raw);
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 9, &order, &candidates);
    for ([_]Mode{ .literal, .fuzzy }) |mode| {
        for ([_][]const u8{ "😷 :white_check_mark:", ":mask: ✅", "mask", "skin-tone-2", "👍", "🏻" }) |text| {
            const batch = try scan(a, try Query.init(a, text), candidates.items, mode);
            try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
            const occurrence = batch.occurrences[0];
            try testing.expectEqual(@as(u64, 7), occurrence.location.review_body.owner.comment);
            if (std.mem.eql(u8, text, "mask")) {
                try testing.expectEqual(@as(usize, 3), occurrence.column);
                try testing.expectEqualStrings(":mask:", raw[occurrence.ranges[0].start..occurrence.ranges[0].end]);
            }
            if (std.mem.eql(u8, text, "skin-tone-2") or std.mem.eql(u8, text, "👍") or std.mem.eql(u8, text, "🏻")) {
                try testing.expectEqual(@as(u32, 3), occurrence.location.review_body.logical_line);
                try testing.expectEqual(@as(usize, 1), occurrence.column);
                try testing.expectEqualStrings(":thumbsup::skin-tone-2:", raw[occurrence.ranges[0].start..occurrence.ranges[0].end]);
            }
        }
        for ([_][]const u8{ "😷:mask:", "👍skin-tone-2", "MASK" }) |text| {
            const batch = try scan(a, try Query.init(a, text), candidates.items, mode);
            try testing.expectEqual(@as(usize, 0), batch.occurrences.len);
        }
    }
}

test "M23 emoji fuzzy work counts legal branch nodes rather than representation combinations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = ":mask:" ** 32;
    const text = "😷:mask:" ** 16;
    const body = try review_body.ReviewBody.parse(a, raw);
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 1, &order, &candidates);
    const batch = try scan(a, try Query.init(a, text), candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    try testing.expectEqual(Calculation.exact, batch.occurrences[0].calculation);
    try testing.expectEqual(std.math.inf(f64), batch.occurrences[0].score);
    try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = raw.len }}, batch.occurrences[0].ranges);
}

test "M23 emoji counts authored locations and keeps smart case literal exclusions and exact sequences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const examples = [_]struct { raw: []const u8, query: []const u8, literal: usize, fuzzy: usize }{
        .{ .raw = ":mask: :mask:", .query = "mask", .literal = 2, .fuzzy = 1 },
        .{ .raw = ":mask: :mask:", .query = ":", .literal = 2, .fuzzy = 1 },
        .{ .raw = ":one: :flag_gb: :woman_technologist::skin-tone-2:", .query = "️", .literal = 1, .fuzzy = 1 },
        .{ .raw = ":flag_gb:", .query = "🇬", .literal = 1, .fuzzy = 1 },
        .{ .raw = ":woman_technologist::skin-tone-2:", .query = "‍", .literal = 1, .fuzzy = 1 },
        .{ .raw = ":v:", .query = "v", .literal = 1, .fuzzy = 1 },
        .{ .raw = "😷", .query = ":mask:", .literal = 0, .fuzzy = 0 },
        .{ .raw = "`:mask:`\n\n```\n:mask:\n```\n\n\\:mask: [label](url/:mask:) :unknown: :MASK:", .query = "😷", .literal = 0, .fuzzy = 0 },
        .{ .raw = "`:mask:`\n\n```\n:mask:\n```\n\n\\:mask: [label](url/:mask:) :MASK:", .query = "mask", .literal = 5, .fuzzy = 3 },
        .{ .raw = ":mask: :MASK:", .query = "MASK", .literal = 1, .fuzzy = 1 },
        .{ .raw = ":heart:", .query = "❤️", .literal = 0, .fuzzy = 0 },
        .{ .raw = "[:mask:](url) :white_check_mark:", .query = "😷✅", .literal = 0, .fuzzy = 0 },
    };
    for (examples) |example| {
        var candidates: std.ArrayList(Candidate) = .empty;
        var order: usize = 0;
        try appendReviewBodyCandidates(a, try review_body.ReviewBody.parse(a, example.raw), .{ .comment = 7 }, 1, &order, &candidates);
        for ([_]Mode{ .literal, .fuzzy }) |mode| {
            const batch = try scan(a, try Query.init(a, example.query), candidates.items, mode);
            try testing.expectEqual(if (mode == .literal) example.literal else example.fuzzy, batch.occurrences.len);
            if (std.mem.eql(u8, example.raw, ":v:")) try testing.expectEqualSlices(Range, &.{.{ .start = 0, .end = 3 }}, batch.occurrences[0].ranges);
            if (std.mem.eql(u8, example.raw, ":mask: :mask:") and mode == .fuzzy) try testing.expectEqual(@as(usize, 0), batch.occurrences[0].ranges[0].start);
        }
    }
}

test "M23 emoji fuzzy scores match the existing scores on each legal representation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "a :mask: b :white_check_mark: c";
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, try review_body.ReviewBody.parse(a, raw), .{ .comment = 7 }, 1, &order, &candidates);
    for ([_][]const u8{ "abc", "a😷c", "amaskc", "mask", "a:white_check_mark:", "b✅", "😷:mask:" }) |text| {
        const query = try Query.init(a, text);
        const graph_match = try scan(a, query, candidates.items, .fuzzy);
        var best_score = -std.math.inf(f64);
        for ([_][]const u8{ "a 😷 b ✅ c", "a :mask: b ✅ c", "a 😷 b :white_check_mark: c", raw }) |legal| {
            const result = try scan(a, query, &.{.{ .text = legal, .location = .{ .review_body = .{ .owner = .{ .comment = 7 }, .logical_line = 1 } } }}, .fuzzy);
            if (result.occurrences.len > 0) best_score = @max(best_score, result.occurrences[0].score);
        }
        if (best_score == -std.math.inf(f64)) {
            try testing.expectEqual(@as(usize, 0), graph_match.occurrences.len);
        } else {
            try testing.expectEqual(@as(usize, 1), graph_match.occurrences.len);
            try testing.expectApproxEqAbs(best_score, graph_match.occurrences[0].score, 0.000001);
        }
    }
}

test "M23 emoji both search calculations release every partial allocation" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator, query: Query, candidates: []const Candidate, mode: Mode) !void {
            var batch = try scan(allocator, query, candidates, mode);
            defer batch.deinit(allocator);
            try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try review_body.ReviewBody.parse(a, "a :mask: :white_check_mark:\n\n:woman_technologist::skin-tone-2:");
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 1, &order, &candidates);
    const query = try Query.init(a, "😷 :white_check_mark:");
    for ([_]Mode{ .literal, .fuzzy }) |mode| try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{ query, candidates.items, mode });
    var large: std.ArrayList(Candidate) = .empty;
    try appendReviewBodyCandidates(a, try review_body.ReviewBody.parse(a, "x" ** 3000 ++ " :mask: :white_check_mark:"), .{ .comment = 7 }, 1, &order, &large);
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{ try Query.init(a, "x" ** 100 ++ " 😷 :white_check_mark:"), large.items, Mode.fuzzy });
}

test "M23 emoji large fuzzy regions use deterministic legal mixed form fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "x" ** 3000 ++ " :mask: :white_check_mark:";
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, try review_body.ReviewBody.parse(a, raw), .{ .comment = 7 }, 1, &order, &candidates);
    const text = "x" ** 100 ++ " 😷 :white_check_mark:";
    const batch = try scan(a, try Query.init(a, text), candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    try testing.expectEqual(Calculation.fallback, batch.occurrences[0].calculation);
    const last = batch.occurrences[0].ranges[batch.occurrences[0].ranges.len - 1];
    try testing.expectEqualStrings(" :mask: :white_check_mark:", raw[last.start..last.end]);
    const forbidden = try scan(a, try Query.init(a, "x" ** 100 ++ " 😷:mask:"), candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 0), forbidden.occurrences.len);
}

test "M23 emoji applies exact work limits to each legal representation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = ":white_check_mark:" ** 1000;
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, try review_body.ReviewBody.parse(a, raw), .{ .comment = 7 }, 1, &order, &candidates);
    const exact = try scan(a, try Query.init(a, "✅" ** 100), candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 1), exact.occurrences.len);
    try testing.expectEqual(Calculation.exact, exact.occurrences[0].calculation);
    try testing.expectEqual(@as(usize, 1000), exact.occurrences[0].candidate_scalars);
    const fallback = try scan(a, try Query.init(a, "w" ** 100), candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 1), fallback.occurrences.len);
    try testing.expectEqual(Calculation.fallback, fallback.occurrences[0].calculation);
}

test "M23 emoji fallback keeps the best score across legal greedy representations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "x" ** 3000 ++ ":mask: m";
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, try review_body.ReviewBody.parse(a, raw), .{ .comment = 7 }, 1, &order, &candidates);
    const found = try scan(a, try Query.init(a, "x" ** 100 ++ "m"), candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 1), found.occurrences.len);
    try testing.expectEqual(Calculation.fallback, found.occurrences[0].calculation);
    try testing.expectApproxEqAbs(@as(f64, 71.58), found.occurrences[0].score, 0.000001);
    const last = found.occurrences[0].ranges[found.occurrences[0].ranges.len - 1];
    try testing.expectEqualStrings("m", raw[last.start..last.end]);
    try testing.expectEqual(@as(usize, raw.len - 1), last.start);
}

test "M23 emoji score ties prefer displayed forms and earliest authored alignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const examples = [_]struct { raw: []const u8, query: []const u8, offset: usize }{
        .{ .raw = "mzzzzzzzzz m:mask:", .query = "m", .offset = 0 },
        .{ .raw = "x" ** 3000 ++ ":a:zza", .query = "x" ** 100 ++ "a", .offset = 3005 },
        .{ .raw = "xzm" ++ "z" ** 158 ++ " m:mask:", .query = "xm", .offset = 2 },
    };
    for (examples) |example| {
        var candidates: std.ArrayList(Candidate) = .empty;
        var order: usize = 0;
        try appendReviewBodyCandidates(a, try review_body.ReviewBody.parse(a, example.raw), .{ .comment = 7 }, 1, &order, &candidates);
        const found = try scan(a, try Query.init(a, example.query), candidates.items, .fuzzy);
        const last = found.occurrences[0].ranges[found.occurrences[0].ranges.len - 1];
        try testing.expectEqual(example.offset, last.start);
    }
}

test "M23 tables both searches keep authored cells as separate matching regions as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "| Name | State |\r\n| :--- | ---: |\r\n| **Ada** | `a|b` \\| ready |\n| Bo |\n| extra | literal | cells |";
    const body = try review_body.ReviewBody.parse(a, raw);
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 1, &order, &candidates);
    for ([_]Mode{ .literal, .fuzzy }) |mode| {
        for ([_][]const u8{ "Name", "State", "Ada", "a|b", "| ready", "Bo", "extra | literal | cells" }) |text| {
            const batch = try scan(a, try Query.init(a, text), candidates.items, mode);
            try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
            try testing.expectEqual(@as(u64, 7), batch.occurrences[0].location.review_body.owner.comment);
            if (std.mem.eql(u8, text, "Ada")) {
                try testing.expectEqual(@as(u32, 3), batch.occurrences[0].location.review_body.logical_line);
                try testing.expectEqual(@as(usize, 5), batch.occurrences[0].column);
            }
        }
        for ([_][]const u8{ "NameState", "Ada a|b", "ready Bo", "---", "│", "State:" }) |text| {
            const batch = try scan(a, try Query.init(a, text), candidates.items, mode);
            try testing.expectEqual(@as(usize, 0), batch.occurrences.len);
        }
    }
}

test "M23 links both searches find each reference use and retain separate definition ranges as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[Docs][ID]\n![art][id]\n\n[id]: https://host/path \"Guide\"\n[unused]: /other";
    const body = try review_body.ReviewBody.parse(a, raw);
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 1, &order, &candidates);
    const batch = try scan(a, try Query.init(a, "host"), candidates.items, .literal);
    try testing.expectEqual(@as(usize, 2), batch.occurrences.len);
    for (batch.occurrences, 0..) |occurrence, index| {
        try testing.expectEqual(@as(u32, @intCast(index + 1)), occurrence.location.review_body.logical_line);
        try testing.expect(occurrence.ranges[0].start < 20);
        try testing.expectEqualStrings("host", raw[occurrence.definition_ranges[0].start..occurrence.definition_ranges[0].end]);
    }
    for ([_]Mode{ .literal, .fuzzy }) |mode| {
        for ([_][]const u8{ "Docs", "art", "path", "Guide", "unused" }) |query| {
            const found = try scan(a, try Query.init(a, query), candidates.items, mode);
            try testing.expect(found.occurrences.len > 0);
        }
        for ([_][]const u8{ "image:", "‹", "Docshttps", "pathGuide" }) |query| {
            const found = try scan(a, try Query.init(a, query), candidates.items, mode);
            try testing.expectEqual(@as(usize, 0), found.occurrences.len);
        }
    }
}

test "M23 containers both searches join item and quote prose but exclude markers as project behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "4. **first**\r\n    second\n1. other\n    - child\n        continuation\n\n> first\n> second\n>\n> separate\n> ~~~zig metadata\n> first\n> second\n> ~~~\n\n1) literal\n\nprose\n- unsupported\n\n- hard  \n    break\n\n> - parent\n>     > quoted\n>     > continuation\n>     > ~~~\n>     > code\n>     > ~~~";
    const body = try review_body.ReviewBody.parse(a, raw);
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 1, &order, &candidates);
    for ([_]Mode{ .literal, .fuzzy }) |mode| {
        const query = try Query.init(a, "first second");
        const batch = try scan(a, query, candidates.items, mode);
        try testing.expectEqual(@as(usize, 2), batch.occurrences.len);
        if (mode == .literal) {
            try testing.expectEqual(@as(usize, 6), batch.occurrences[0].column);
            try testing.expectEqual(@as(u32, 1), batch.occurrences[0].location.review_body.logical_line);
            try testing.expectEqualStrings("first", raw[batch.occurrences[0].ranges[0].start..batch.occurrences[0].ranges[0].end]);
            try testing.expectEqualStrings("\r\n", raw[batch.occurrences[0].ranges[1].start..batch.occurrences[0].ranges[1].end]);
            try testing.expectEqualStrings("second", raw[batch.occurrences[0].ranges[2].start..batch.occurrences[0].ranges[2].end]);
        }
        for ([_][]const u8{ "4.", "5.", "•", "│", ">", "metadata", "other child", "hard break", "second separate" }) |text| {
            const excluded = try Query.init(a, text);
            const matches = try scan(a, excluded, candidates.items, mode);
            try testing.expectEqual(@as(usize, 0), matches.occurrences.len);
        }
        for ([_][]const u8{ "1)", "- unsupported", "child continuation", "quoted continuation" }) |text| {
            const included = try Query.init(a, text);
            const matches = try scan(a, included, candidates.items, mode);
            try testing.expectEqual(@as(usize, 1), matches.occurrences.len);
        }
    }
}

test "M23 literal both searches use authored code lines and exclude fence metadata and tab decoration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "**before**\n\n  ~~~~zig metadata\r\n  a\tb **literal** :mask: <b>\r\n  second\n  ~~~~~\n\n    a\tb **literal** :mask: <b>\n    second\n\n```suggestion\na\tb **literal** :mask: <b>\nsecond\n```\n\n**after**\n```suggestion\n**fallback**";
    const body = try review_body.ReviewBody.parse(a, raw);
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 1, &order, &candidates);
    for ([_]Mode{ .literal, .fuzzy }) |mode| {
        var query = try Query.init(a, "**literal** :mask: <b>");
        var batch = try scan(a, query, candidates.items, mode);
        try testing.expectEqual(@as(usize, 3), batch.occurrences.len);
        for (batch.occurrences) |occurrence| {
            const column: usize = switch (occurrence.location.review_body.logical_line) {
                4 => 7,
                8 => 9,
                12 => 5,
                else => return error.WrongCodeLine,
            };
            try testing.expectEqual(column, occurrence.column);
            for (occurrence.ranges) |range| try testing.expect(std.mem.indexOfScalar(u8, raw[range.start..range.end], '\n') == null);
        }
        query = try Query.init(a, "a\tb");
        batch = try scan(a, query, candidates.items, mode);
        try testing.expectEqual(@as(usize, 3), batch.occurrences.len);
        for ([_][]const u8{ "metadata", "~~~~", "second after" }) |text| {
            query = try Query.init(a, text);
            batch = try scan(a, query, candidates.items, mode);
            try testing.expectEqual(@as(usize, 0), batch.occurrences.len);
        }
        if (mode == .literal) {
            query = try Query.init(a, "a   b");
            batch = try scan(a, query, candidates.items, mode);
            try testing.expectEqual(@as(usize, 0), batch.occurrences.len);
        }
        query = try Query.init(a, "**fallback**");
        batch = try scan(a, query, candidates.items, mode);
        try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    }
}

test "M23 inline joined paragraph search maps CRLF joins and first authored positions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try review_body.ReviewBody.parse(a, "π first\r\n**second**\n\nfirst  \nsecond\n\nTitle\n=====\n");
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .comment = 7 }, 9, &order, &candidates);
    var query = try Query.init(a, "first second");
    var batch = try scan(a, query, candidates.items, .literal);
    try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    try testing.expectEqualSlices(Range, &.{ .{ .start = 3, .end = 10 }, .{ .start = 12, .end = 18 } }, batch.occurrences[0].ranges);
    try testing.expectEqual(@as(usize, 3), batch.occurrences[0].column);
    query = try Query.init(a, "second");
    batch = try scan(a, query, candidates.items, .literal);
    try testing.expectEqual(@as(u32, 2), batch.occurrences[0].location.review_body.logical_line);
    try testing.expectEqual(@as(usize, 3), batch.occurrences[0].column);
    query = try Query.init(a, "=====");
    batch = try scan(a, query, candidates.items, .literal);
    try testing.expectEqual(@as(usize, 0), batch.occurrences.len);
}

test "M23 inline searches keep paragraph boundaries literal order and one best fuzzy match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try review_body.ReviewBody.parse(a, "prefix needle\nneedle\n\nfirst  \nsecond\n\nfirst\n\nsecond\n\n```suggestion\nfirst\nsecond\n```\n\n[docs](url) tail");
    var candidates: std.ArrayList(Candidate) = .empty;
    var order: usize = 0;
    try appendReviewBodyCandidates(a, body, .{ .draft = 1 }, 2, &order, &candidates);
    var query = try Query.init(a, "needle");
    var batch = try scan(a, query, candidates.items, .literal);
    try testing.expectEqual(@as(usize, 2), batch.occurrences.len);
    try testing.expectEqual(@as(u32, 1), batch.occurrences[0].location.review_body.logical_line);
    try testing.expectEqual(@as(u32, 2), batch.occurrences[1].location.review_body.logical_line);
    batch = try scan(a, query, candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 1), batch.occurrences.len);
    query = try Query.init(a, "first second");
    for ([_]Mode{ .literal, .fuzzy }) |mode| {
        batch = try scan(a, query, candidates.items, mode);
        try testing.expectEqual(@as(usize, 0), batch.occurrences.len);
    }
    query = try Query.init(a, "docsurl");
    batch = try scan(a, query, candidates.items, .fuzzy);
    try testing.expectEqual(@as(usize, 0), batch.occurrences.len);
}

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

fn exerciseFileScanAllocationFailures(allocator: std.mem.Allocator) !void {
    var query = try Query.init(allocator, "match");
    defer query.deinit(allocator);
    const lines: []const bbr.diff.Line = &.{
        .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "match" },
        .{ .old_no = 3, .new_no = 3, .kind = .context, .text = "match" },
    };
    const hunks: []const bbr.diff.Hunk = &.{.{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .header = "", .lines = lines }};
    const file: bbr.diff.File = .{ .old_path = "a.txt", .new_path = "a.txt", .status = .modified, .hunks = hunks };
    var batch = try scanFile(allocator, query, file, 0, 1, "match\r\nmatch\nmatch\n", "match\r\nmatch\nmatch\n");
    defer batch.deinit(allocator);
}

test "complete File scan indexes context, ignores duplicate and missing Lines, and releases allocations on failure" {
    var query = try Query.init(testing.allocator, "match");
    defer query.deinit(testing.allocator);
    const lines: []const bbr.diff.Line = &.{
        .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "match" },
        .{ .old_no = 1, .new_no = 1, .kind = .context, .text = "match" },
        .{ .old_no = 9, .new_no = 9, .kind = .context, .text = "match" },
        .{ .old_no = 2, .new_no = 2, .kind = .context, .text = "wrong" },
        .{ .old_no = 3, .new_no = 3, .kind = .context, .text = "match" },
    };
    const hunks: []const bbr.diff.Hunk = &.{.{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .header = "", .lines = lines }};
    const file: bbr.diff.File = .{ .old_path = "a.txt", .new_path = "a.txt", .status = .modified, .hunks = hunks };
    var batch = try scanFile(testing.allocator, query, file, 0, 1, "match\r\nmatch\nmatch\n", "match\r\nmatch\nmatch\n");
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), batch.occurrences.len);
    var neutral: usize = 0;
    for (batch.occurrences) |occurrence| {
        const source = occurrence.location.source;
        if (source.relation == .neutral) {
            neutral += 1;
            try testing.expect(source.old_line == 1 or source.old_line == 3);
            try testing.expectEqual(source.old_line, source.new_line);
        } else try testing.expectEqual(@as(?u32, 2), source.old_line orelse source.new_line);
    }
    try testing.expectEqual(@as(usize, 2), neutral);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseFileScanAllocationFailures, .{});
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

    try testing.expectEqual(@as(usize, 1), candidates.items.len);
    try testing.expectEqualStrings("bold text docshttps://x tail next", candidates.items[0].text);
    try testing.expectEqualSlices(usize, &.{ 10, 14, 23 }, candidates.items[0].boundaries);
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
