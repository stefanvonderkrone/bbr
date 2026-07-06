//! ArenaRing — a small fixed ring of arenas for the transient buffers the
//! viewer rebuilds every time the layout, scope, resolved toggle, or a fold
//! changes (and on a PR switch). One reset-and-reuse arena would work, but it
//! invalidates the *previous* buffer the instant a rebuild starts. A ring of N
//! decouples that by N generations: `next()` rotates to a different arena, so
//! the buffer built last generation stays valid while the new one is built.
//!
//! With `n = 2` you get classic double-buffering — enough for the viewer, which
//! only ever holds one live buffer plus the one being built. Each arena keeps
//! its backing pages across resets (`.retain_capacity`), so steady-state
//! rebuilds don't churn the OS allocator.
//!
//! The ring must live at a stable address once `next()` has handed out an
//! allocator (the returned `Allocator` points into the ring); take a `*Ring`
//! and don't move it. `init` before any `next()` is fine to move.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn ArenaRing(comptime n: usize) type {
    comptime std.debug.assert(n >= 1);
    return struct {
        const Self = @This();

        arenas: [n]std.heap.ArenaAllocator,
        idx: usize = 0,

        /// Build a ring of `n` arenas over `backing`. Safe to move the returned
        /// value into its final home before the first `next()`.
        pub fn init(backing: Allocator) Self {
            var self: Self = .{ .arenas = undefined, .idx = 0 };
            for (&self.arenas) |*a| a.* = std.heap.ArenaAllocator.init(backing);
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (&self.arenas) |*a| a.deinit();
            self.* = undefined;
        }

        /// Rotate to the next arena, reset it (keeping its capacity), and return
        /// its allocator. The allocation handed out last call (from a different
        /// arena, when `n > 1`) stays valid.
        pub fn next(self: *Self) Allocator {
            self.idx = (self.idx + 1) % n;
            _ = self.arenas[self.idx].reset(.retain_capacity);
            return self.arenas[self.idx].allocator();
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "a ring of 2 keeps the previous generation's allocation alive" {
    var ring = ArenaRing(2).init(testing.allocator);
    defer ring.deinit();

    const a0 = ring.next();
    const first = try a0.alloc(u8, 8);
    @memset(first, 0xAB);

    // Next generation uses a different arena — `first` must still be readable.
    const a1 = ring.next();
    const second = try a1.alloc(u8, 8);
    @memset(second, 0xCD);
    for (first) |b| try testing.expectEqual(@as(u8, 0xAB), b);

    // Two generations on, we rotate back to the first arena and reset it.
    _ = ring.next();
    for (second) |b| try testing.expectEqual(@as(u8, 0xCD), b);
}

test "rotation cycles through all arenas and retains capacity" {
    var ring = ArenaRing(3).init(testing.allocator);
    defer ring.deinit();

    // Grow each arena, then loop the ring several times; resets must not leak
    // (testing.allocator would flag a leak on deinit otherwise).
    var round: usize = 0;
    while (round < 9) : (round += 1) {
        const a = ring.next();
        _ = try a.alloc(u8, 4096);
    }
}

test "a ring of 1 degrades to a single reset-reuse arena" {
    var ring = ArenaRing(1).init(testing.allocator);
    defer ring.deinit();
    const a = ring.next();
    _ = try a.alloc(u8, 16);
    // Same arena next time; the prior allocation is gone after reset.
    const b = ring.next();
    _ = try b.alloc(u8, 16);
}
