//! Local Workspace Member name matching. Result strings borrow the supplied members.

const std = @import("std");
const bbr = @import("bbr");
const unicode_data = @import("../tui/search_unicode_data.zig");
const Allocator = std.mem.Allocator;
const Member = bbr.bitbucket.WorkspaceMember;

pub const max_query_scalars = 256;
pub const Kind = enum { exact, spelling, partial, fuzzy };
pub const Field = enum { display_name, nickname };
pub const Match = struct {
    member: Member,
    match_kind: Kind,
    matched_field: Field,
    edit_distance: u8,
};
pub const Result = struct {
    matches: []Match,
    total_matches: usize,
    exact_matches: usize,

    pub fn deinit(self: Result, allocator: Allocator) void {
        allocator.free(self.matches);
    }
};

pub fn validateName(name: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(name)) return error.BadRequest;
    var it = std.unicode.Utf8View.initUnchecked(name).iterator();
    var count: usize = 0;
    var nonblank = false;
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.BadRequest;
        count += 1;
        if (count > max_query_scalars) return error.BadRequest;
        nonblank = nonblank or cp != ' ';
    }
    if (!nonblank) return error.BadRequest;
}

const Text = struct {
    forms: [3][]const u21,
    parts: [3][]const []const u21,
};

fn fold(cp: u21) u21 {
    var lo: usize = 0;
    var hi = unicode_data.folds.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = unicode_data.folds[mid];
        if (cp < entry.source) hi = mid else if (cp > entry.source) lo = mid + 1 else return entry.target;
    }
    return cp;
}

fn prepare(a: Allocator, text: []const u8) !Text {
    if (!std.unicode.utf8ValidateSlice(text)) return error.MalformedResponse;
    var normalized: std.ArrayList(u21) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ' and (normalized.items.len == 0 or normalized.items[normalized.items.len - 1] == ' ')) continue;
        try normalized.append(a, fold(cp));
    }
    if (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == ' ') normalized.items.len -= 1;
    var result: Text = undefined;
    result.forms[0] = try normalized.toOwnedSlice(a);
    for (1..3) |form| {
        var alias: std.ArrayList(u21) = .empty;
        for (result.forms[0]) |cp| {
            switch (cp) {
                'ä', 'ö', 'ü' => {
                    try alias.append(a, switch (cp) {
                        'ä' => 'a',
                        'ö' => 'o',
                        else => 'u',
                    });
                    if (form == 2) try alias.append(a, 'e');
                },
                'ß' => {
                    try alias.append(a, 's');
                    try alias.append(a, 's');
                },
                else => try alias.append(a, cp),
            }
        }
        result.forms[form] = try alias.toOwnedSlice(a);
    }
    for (result.forms, 0..) |form, index| {
        var parts: std.ArrayList([]const u21) = .empty;
        var tokens = std.mem.tokenizeAny(u21, form, &.{ ' ', ',', '.', '-' });
        while (tokens.next()) |part| try parts.append(a, part);
        result.parts[index] = try parts.toOwnedSlice(a);
    }
    return result;
}

const Quality = struct { kind: Kind, distance: u8 = 0 };

fn better(lhs: Quality, rhs: Quality) bool {
    if (lhs.kind != rhs.kind) return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    return lhs.distance < rhs.distance;
}

// Query aliases have at most twice the validated query's code-point count.
// Three rows bound storage even when a member field is very long.
fn distance(query: []const u21, candidate: []const u21, budget: u8) u8 {
    const rejected = budget + 1;
    if (@max(query.len, candidate.len) - @min(query.len, candidate.len) > budget) return rejected;
    var rows: [3][max_query_scalars * 2 + 3]u16 = undefined;
    for (0..candidate.len + 1) |col| rows[0][col] = @intCast(col);
    for (query, 1..) |cp, row| {
        const current = &rows[row % 3];
        const previous = &rows[(row - 1) % 3];
        current[0] = @intCast(row);
        for (candidate, 1..) |other, col| {
            current[col] = @min(previous[col] + 1, @min(current[col - 1] + 1, previous[col - 1] + @as(u16, @intFromBool(cp != other))));
            if (row >= 2 and col >= 2 and cp == candidate[col - 2] and query[row - 2] == other)
                current[col] = @min(current[col], rows[(row - 2) % 3][col - 2] + 1);
        }
    }
    return @intCast(@min(rows[query.len % 3][candidate.len], rejected));
}

// Rectangular minimum-cost assignment keeps repeated query parts distinct.
// Hungarian augmenting paths avoid factorial enumeration of name permutations.
fn assignmentCost(a: Allocator, costs: []const u8, rows: usize, cols: usize, budget: u8) !?u8 {
    if (rows == 0 or rows > cols) return null;
    var lower_bound: usize = 0;
    for (0..rows) |row| {
        var minimum: u8 = budget + 1;
        for (costs[row * cols ..][0..cols]) |cost| minimum = @min(minimum, cost);
        lower_bound += minimum;
    }
    if (lower_bound > budget) return null;
    const u = try a.alloc(i32, rows + 1);
    const v = try a.alloc(i32, cols + 1);
    const owner = try a.alloc(usize, cols + 1);
    const previous = try a.alloc(usize, cols + 1);
    const minimum = try a.alloc(i32, cols + 1);
    const used = try a.alloc(bool, cols + 1);
    @memset(u, 0);
    @memset(v, 0);
    @memset(owner, 0);
    for (1..rows + 1) |row| {
        owner[0] = row;
        @memset(minimum, 1_000_000);
        @memset(used, false);
        var col: usize = 0;
        while (true) {
            used[col] = true;
            const current_row = owner[col];
            var delta: i32 = 1_000_000;
            var next: usize = 0;
            for (1..cols + 1) |candidate_col| {
                if (used[candidate_col]) continue;
                const cost = @as(i32, costs[(current_row - 1) * cols + candidate_col - 1]) - u[current_row] - v[candidate_col];
                if (cost < minimum[candidate_col]) {
                    minimum[candidate_col] = cost;
                    previous[candidate_col] = col;
                }
                if (minimum[candidate_col] < delta) {
                    delta = minimum[candidate_col];
                    next = candidate_col;
                }
            }
            for (0..cols + 1) |candidate_col| {
                if (used[candidate_col]) {
                    u[owner[candidate_col]] += delta;
                    v[candidate_col] -= delta;
                } else minimum[candidate_col] -= delta;
            }
            col = next;
            if (owner[col] == 0) break;
        }
        while (col != 0) {
            const next = previous[col];
            owner[col] = owner[next];
            col = next;
        }
        if (-v[0] > budget) return null;
    }
    return @intCast(-v[0]);
}

fn partMatch(a: Allocator, query: Text, candidate: Text, budget: u8, literal: bool) !?u8 {
    const rows = query.parts[0].len;
    const cols = candidate.parts[0].len;
    if (rows == 0 or rows > cols) return null;
    const costs = try a.alloc(u8, rows *| cols);
    for (query.parts[0], 0..) |part, row| {
        for (candidate.parts[0], 0..) |other, col| {
            var cost: u8 = budget + 1;
            if (literal) {
                if (std.mem.indexOf(u21, other, part) != null) cost = 0;
            } else {
                for (query.parts) |query_parts| for (candidate.parts) |candidate_parts| {
                    cost = @min(cost, distance(query_parts[row], candidate_parts[col], budget));
                };
            }
            costs[row * cols + col] = cost;
        }
    }
    return assignmentCost(a, costs, rows, cols, budget);
}

fn fieldMatch(a: Allocator, query: Text, candidate: Text, field: Field) !?Quality {
    if (candidate.forms[0].len == 0) return null;
    if (std.mem.eql(u21, query.forms[0], candidate.forms[0])) return .{ .kind = .exact };
    for (query.forms) |q| for (candidate.forms) |c| {
        if (std.mem.eql(u21, q, c)) return .{ .kind = .spelling };
    };
    if (query.parts[0].len == 0 or candidate.parts[0].len == 0) return null;
    if (field == .nickname) {
        if (std.mem.indexOf(u21, candidate.forms[0], query.forms[0]) != null) return .{ .kind = .partial };
    } else if (try partMatch(a, query, candidate, 0, true) != null) return .{ .kind = .partial };

    const budget: u8 = if (query.forms[0].len < 3) 0 else if (query.forms[0].len < 8) 1 else 2;
    var best_distance: u8 = budget + 1;
    for (query.forms) |q| for (candidate.forms) |c| {
        best_distance = @min(best_distance, distance(q, c, budget));
    };
    if (field == .display_name) {
        if (try partMatch(a, query, candidate, budget, false)) |cost| best_distance = @min(best_distance, cost);
    }
    return if (best_distance <= budget) .{ .kind = .fuzzy, .distance = best_distance } else null;
}

const Ranked = struct { match: Match, name: []const u21, nickname: []const u21 };

fn rankedLessThan(_: void, lhs: Ranked, rhs: Ranked) bool {
    const left: Quality = .{ .kind = lhs.match.match_kind, .distance = lhs.match.edit_distance };
    const right: Quality = .{ .kind = rhs.match.match_kind, .distance = rhs.match.edit_distance };
    if (better(left, right)) return true;
    if (better(right, left)) return false;
    const name_order = std.mem.order(u21, lhs.name, rhs.name);
    if (name_order != .eq) return name_order == .lt;
    const nick_order = std.mem.order(u21, lhs.nickname, rhs.nickname);
    if (nick_order != .eq) return nick_order == .lt;
    const uuid_order = std.mem.order(u8, lhs.match.member.uuid, rhs.match.member.uuid);
    if (uuid_order != .eq) return uuid_order == .lt;
    return @intFromEnum(lhs.match.matched_field) < @intFromEnum(rhs.match.matched_field);
}

/// Owns only the returned Match array. The caller retains the member strings.
pub fn search(allocator: Allocator, members: []const Member, name: []const u8, limit: ?usize) !Result {
    try validateName(name);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const query = try prepare(a, name);
    var ranked: std.ArrayList(Ranked) = .empty;
    var seen = std.StringHashMap(usize).init(a);
    for (members) |member| {
        var item_arena = std.heap.ArenaAllocator.init(allocator);
        defer item_arena.deinit();
        const scratch = item_arena.allocator();
        const display = try prepare(scratch, member.display_name);
        const nickname = try prepare(scratch, member.nickname);
        var quality = try fieldMatch(scratch, query, display, .display_name);
        var field: Field = .display_name;
        if (try fieldMatch(scratch, query, nickname, .nickname)) |nick_match| {
            if (quality == null or better(nick_match, quality.?)) {
                quality = nick_match;
                field = .nickname;
            }
        }
        const matched = quality orelse continue;
        const entry: Ranked = .{
            .match = .{ .member = member, .match_kind = matched.kind, .matched_field = field, .edit_distance = matched.distance },
            .name = try a.dupe(u21, display.forms[0]),
            .nickname = try a.dupe(u21, nickname.forms[0]),
        };
        if (seen.get(member.uuid)) |index| {
            if (rankedLessThan({}, entry, ranked.items[index])) ranked.items[index] = entry;
        } else {
            try seen.put(member.uuid, ranked.items.len);
            try ranked.append(a, entry);
        }
    }
    std.mem.sort(Ranked, ranked.items, {}, rankedLessThan);
    var exact: usize = 0;
    for (ranked.items) |entry| exact += @intFromBool(entry.match.match_kind == .exact);
    const count = @min(limit orelse ranked.items.len, ranked.items.len);
    const matches = try allocator.alloc(Match, count);
    for (matches, ranked.items[0..count]) |*target, entry| target.* = entry.match;
    return .{ .matches = matches, .total_matches = ranked.items.len, .exact_matches = exact };
}

fn expectMatch(query: []const u8, display: []const u8, nickname: []const u8, kind: ?Kind, edits: u8) !void {
    const result = try search(std.testing.allocator, &.{.{ .uuid = "{member}", .display_name = display, .nickname = nickname }}, query, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, if (kind != null) 1 else 0), result.matches.len);
    if (kind) |expected| {
        try std.testing.expectEqual(expected, result.matches[0].match_kind);
        try std.testing.expectEqual(edits, result.matches[0].edit_distance);
    }
}

test "member search matches full names, nicknames, case, and spaces without changing identities" {
    try expectMatch("  ADA   lovelace ", "Ada Lovelace", "", .exact, 0);
    try expectMatch("ada", "Ada Lovelace", "Ada", .exact, 0);
    try expectMatch("JÖRG", "Jörg", "", .exact, 0);
    try expectMatch("κώστας", "ΚΏΣΤΑΣ", "", .exact, 0);
    try expectMatch("ada", "Ada Lovelace", "", .partial, 0);
    try expectMatch("love ada", "Ada Michael Lovelace", "", .partial, 0);
    try expectMatch("marie anne", "Anne-Marie Smith", "", .partial, 0);
    try expectMatch("admin", "Other Person", "ada_admin", .partial, 0);
    try expectMatch("Ada Smith", "Ada Jones", "smith", null, 0);
    try expectMatch("Ada Ada", "Ada Jones", "", null, 0);
    try expectMatch("Al Alf", "Alfred Al", "", .partial, 0);
    try expectMatch("Ada Aad", "Aad Adb", "", .fuzzy, 1);
    try expectMatch("...", "Ada Jones", "", null, 0);
}

test "member search supports German spelling and combined name-part typos" {
    try expectMatch("Jorg", "Jörg", "", .spelling, 0);
    try expectMatch("Mueller", "Müller", "", .spelling, 0);
    try expectMatch("Müller", "Mueller", "", .spelling, 0);
    try expectMatch("Strasse", "Straße", "", .spelling, 0);
    try expectMatch("Mueller Jorg", "Jörg Michael Müller", "", .fuzzy, 0);
    try expectMatch("Kronechek Stefan", "Stefan Michael Kronecheck", "", .fuzzy, 1);
    try expectMatch("Mueller Jrog", "Jörg Michael Müller", "", .fuzzy, 1);
    try expectMatch("Adaa", "Ada", "", .fuzzy, 1);
    try expectMatch("Ad", "Ada", "", .partial, 0);
    try expectMatch("Ada", "Alda", "", .fuzzy, 1);
    try expectMatch("Axa", "Ada", "", .fuzzy, 1);
    try expectMatch("Aad", "Ada", "", .fuzzy, 1);
    try expectMatch("Jose", "José", "", .fuzzy, 1);
}

test "member search enforces the total typo budget and returns no unrelated filler" {
    try expectMatch("Li", "Lu", "", null, 0);
    try expectMatch("Axaa", "Ada", "", null, 0);
    try expectMatch("Alphx Betx", "Alpha Beta", "", .fuzzy, 2);
    try expectMatch("Alphx Betxx", "Alpha Beta", "", null, 0);
    try expectMatch("Caroline", "Maxwell", "", null, 0);
    try expectMatch("Ada Ada", "Ada Ada", "", .exact, 0);
}

test "member search keeps duplicate names, deduplicates UUIDs, and counts exact matches before limits" {
    const members = [_]Member{
        .{ .uuid = "{z}", .display_name = "Ada", .nickname = "ada" },
        .{ .uuid = "{a}", .display_name = "Other", .nickname = "ada" },
        .{ .uuid = "{z}", .display_name = "Ada", .nickname = "ada" },
        .{ .uuid = "{partial}", .display_name = "Ada Lovelace" },
    };
    for ([_]?usize{ null, 1, 0 }, [_]usize{ 3, 1, 0 }) |limit, count| {
        const result = try search(std.testing.allocator, &members, "ada", limit);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(count, result.matches.len);
        try std.testing.expectEqual(@as(usize, 3), result.total_matches);
        try std.testing.expectEqual(@as(usize, 2), result.exact_matches);
        if (count > 0) {
            try std.testing.expectEqualStrings("{z}", result.matches[0].member.uuid);
            try std.testing.expectEqual(Field.display_name, result.matches[0].matched_field);
            try std.testing.expectEqualStrings("Ada", result.matches[0].member.display_name);
        }
    }
}

test "member search ranks spelling above partial matches with stable Unicode name and UUID ties" {
    const members = [_]Member{
        .{ .uuid = "{partial}", .display_name = "Muellerfeld" },
        .{ .uuid = "{b}", .display_name = "Müller" },
        .{ .uuid = "{exact}", .display_name = "Mueller" },
        .{ .uuid = "{a}", .display_name = "MÜLLER" },
    };
    const result = try search(std.testing.allocator, &members, "Mueller", null);
    defer result.deinit(std.testing.allocator);
    for (result.matches, [_][]const u8{ "{exact}", "{a}", "{b}", "{partial}" }) |match, uuid|
        try std.testing.expectEqualStrings(uuid, match.member.uuid);
}

test "member search retains a stronger identity match from a repeated member and sorts nickname ties" {
    const members = [_]Member{
        .{ .uuid = "{repeat}", .display_name = "Ada Lovelace" },
        .{ .uuid = "{repeat}", .display_name = "Other", .nickname = "Ada" },
        .{ .uuid = "{z}", .display_name = "Ada", .nickname = "z" },
        .{ .uuid = "{a}", .display_name = "Ada", .nickname = "a" },
    };
    const result = try search(std.testing.allocator, &members, "Ada", null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.total_matches);
    try std.testing.expectEqual(@as(usize, 3), result.exact_matches);
    try std.testing.expectEqualStrings("a", result.matches[0].member.nickname);
    try std.testing.expectEqualStrings("z", result.matches[1].member.nickname);
    try std.testing.expectEqual(Field.nickname, result.matches[2].matched_field);
    try std.testing.expectEqualStrings("Other", result.matches[2].member.display_name);
}

test "member search validates UTF-8, controls, blank names, and the Unicode scalar boundary" {
    for ([_][]const u8{ "", "   ", "Ada\n", "A\x00da", "Ada\t", "\xff", "Ada\xc2\x85" }) |query|
        try std.testing.expectError(error.BadRequest, validateName(query));
    const accepted = [_]u8{'a'} ** max_query_scalars;
    const rejected = [_]u8{'a'} ** (max_query_scalars + 1);
    try validateName(&accepted);
    try std.testing.expectError(error.BadRequest, validateName(&rejected));
    try validateName("ä" ** max_query_scalars);
    try std.testing.expectError(error.BadRequest, validateName("ä" ** (max_query_scalars + 1)));
    try expectMatch("ß" ** max_query_scalars, "ss" ** max_query_scalars, "", .spelling, 0);
    try expectMatch(&accepted, "a" ** (max_query_scalars + 10), "", .partial, 0);
}

fn searchAllocationCheck(a: Allocator) !void {
    const result = try search(a, &.{
        .{ .uuid = "{first}", .display_name = "Stefan Michael Kronecheck" },
        .{ .uuid = "{second}", .display_name = "Stefan Kronecheck", .nickname = "stefan" },
    }, "Kronechek Stefan", 1);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), result.total_matches);
}

test "member search releases scratch and result allocations on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, searchAllocationCheck, .{});
}
