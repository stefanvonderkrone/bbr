//! A map from each key to its list of entries. All lists share one entry
//! array, so a build makes the same few allocations whatever its key count,
//! and no list grows.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `source.each(sink)` calls `sink.add(key, value)` for every entry, in the
/// same order on each call. `build` calls it twice. The first pass finds the
/// keys and counts their entries, and the second pass places each value.
/// A list keeps its entries in the order of the calls.
pub fn KeyLists(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        /// While `build` runs, `start` is the key's number in first-call order.
        const Range = struct { start: u32, len: u32 };
        const Map = std.HashMapUnmanaged(K, Range, Context, std.hash_map.default_max_load_percentage);

        map: Map = .empty,
        entries: []V = &.{},

        /// `entry_hint` is the number of `add` calls in one pass, or more.
        pub fn build(a: Allocator, entry_hint: usize, key_hint: u32, source: anytype) Allocator.Error!Self {
            var result: Self = .{};
            errdefer result.deinit(a);
            try result.map.ensureTotalCapacity(a, key_hint);
            var intern: Intern = .{ .map = &result.map, .allocator = a };
            defer intern.ids.deinit(a);
            try intern.ids.ensureTotalCapacity(a, entry_hint);
            try source.each(&intern);
            result.entries = try a.alloc(V, intern.ids.items.len);
            const cursors = try a.alloc(u32, result.map.count());
            defer a.free(cursors);
            var start: u32 = 0;
            var ranges = result.map.valueIterator();
            while (ranges.next()) |range| {
                cursors[range.start] = start;
                range.start = start;
                start += range.len;
            }
            var place: Place = .{ .ids = intern.ids.items, .cursors = cursors, .entries = result.entries };
            try source.each(&place);
            if (place.next != place.ids.len) @panic("a KeyLists source changed its calls between the passes");
            return result;
        }

        pub fn deinit(self: *Self, a: Allocator) void {
            a.free(self.entries);
            self.map.deinit(a);
            self.* = undefined;
        }

        pub fn get(self: *const Self, key: K) []const V {
            const range = self.map.get(key) orelse return &.{};
            return self.entries[range.start..][0..range.len];
        }

        pub fn count(self: *const Self) u32 {
            return self.map.count();
        }

        pub fn lists(self: *const Self) ListIterator {
            return .{ .ranges = self.map.valueIterator(), .entries = self.entries };
        }

        pub const ListIterator = struct {
            ranges: Map.ValueIterator,
            entries: []V,

            pub fn next(self: *ListIterator) ?[]V {
                const range = self.ranges.next() orelse return null;
                return self.entries[range.start..][0..range.len];
            }
        };

        const Intern = struct {
            map: *Map,
            allocator: Allocator,
            /// The key number of each call.
            ids: std.ArrayList(u32) = .empty,

            pub fn add(self: *Intern, key: K, _: V) Allocator.Error!void {
                const entry = try self.map.getOrPut(self.allocator, key);
                if (!entry.found_existing) entry.value_ptr.* = .{ .start = self.map.count() - 1, .len = 0 };
                entry.value_ptr.len += 1;
                try self.ids.append(self.allocator, entry.value_ptr.start);
            }
        };

        const Place = struct {
            ids: []const u32,
            cursors: []u32,
            entries: []V,
            next: usize = 0,

            pub fn add(self: *Place, _: K, value: V) Allocator.Error!void {
                if (self.next == self.ids.len) @panic("a KeyLists source changed its calls between the passes");
                const id = self.ids[self.next];
                self.next += 1;
                self.entries[self.cursors[id]] = value;
                self.cursors[id] += 1;
            }
        };
    };
}

const testing = std.testing;
const TestLists = KeyLists(u32, usize, std.hash_map.AutoContext(u32));

const Interleaved = struct {
    count: usize,

    /// Key `i % 3` gets the values `i` in call order, so the keys interleave.
    pub fn each(self: Interleaved, sink: anytype) !void {
        for (0..self.count) |index| try sink.add(@intCast(index % 3), index);
    }
};

test "each key lists its values in call order when keys interleave" {
    var lists = try TestLists.build(testing.allocator, 7, 1, Interleaved{ .count = 7 });
    defer lists.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), lists.count());
    try testing.expectEqualSlices(usize, &.{ 0, 3, 6 }, lists.get(0));
    try testing.expectEqualSlices(usize, &.{ 1, 4 }, lists.get(1));
    try testing.expectEqualSlices(usize, &.{ 2, 5 }, lists.get(2));
    try testing.expectEqual(@as(usize, 0), lists.get(3).len);
    var total: usize = 0;
    var iterator = lists.lists();
    while (iterator.next()) |list| total += list.len;
    try testing.expectEqual(@as(usize, 7), total);
}

test "an empty source builds empty lists" {
    var lists = try TestLists.build(testing.allocator, 0, 0, Interleaved{ .count = 0 });
    defer lists.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), lists.count());
    try testing.expectEqual(@as(usize, 0), lists.get(0).len);
}

fn buildInterleaved(allocator: Allocator) !void {
    var lists = try TestLists.build(allocator, 50, 1, Interleaved{ .count = 50 });
    lists.deinit(allocator);
}

test "a failed build releases every allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, buildInterleaved, .{});
}
