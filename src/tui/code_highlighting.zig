//! Complete-block analysis and Session-owned fenced-code results.
const std = @import("std");
const bbr = @import("bbr");
const card = @import("review_card.zig");
const body_mod = @import("review_body.zig");
const Allocator = std.mem.Allocator;

pub const budget_bytes = 8 * 1024 * 1024;

pub fn fencePath(a: Allocator, identifier: []const u8) !?[]const u8 {
    if (identifier.len == 0) return null;
    const normalized = try a.dupe(u8, identifier);
    defer a.free(normalized);
    for (normalized) |*byte| if (byte.* >= 'A' and byte.* <= 'Z') {
        byte.* += 'a' - 'A';
    };
    const aliases = .{
        .{ "tsx", "tsx" },       .{ "typescript", "ts" }, .{ "ts", "ts" },     .{ "mts", "ts" },    .{ "cts", "ts" },
        .{ "javascript", "js" }, .{ "js", "js" },         .{ "jsx", "js" },    .{ "mjs", "js" },    .{ "cjs", "js" },
        .{ "css", "css" },       .{ "go", "go" },         .{ "golang", "go" }, .{ "bash", "sh" },   .{ "sh", "sh" },
        .{ "shell", "sh" },      .{ "json", "json" },     .{ "yaml", "yaml" }, .{ "yml", "yaml" },  .{ "python", "py" },
        .{ "py", "py" },         .{ "ruby", "rb" },       .{ "rb", "rb" },     .{ "rust", "rs" },   .{ "rs", "rs" },
        .{ "c", "c" },           .{ "cpp", "cpp" },       .{ "c++", "cpp" },   .{ "cxx", "cpp" },   .{ "csharp", "cs" },
        .{ "c#", "cs" },         .{ "cs", "cs" },         .{ "java", "java" }, .{ "html", "html" }, .{ "xml", "xml" },
        .{ "sql", "sql" },       .{ "zig", "zig" },
    };
    inline for (aliases) |alias| if (std.mem.eql(u8, normalized, alias[0])) return try std.fmt.allocPrint(a, "review.{s}", .{alias[1]});
    for (normalized, 0..) |byte, index| {
        const alphanumeric = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
        if (!alphanumeric and (index == 0 or (byte != '_' and byte != '+' and byte != '-'))) return null;
    }
    return try std.fmt.allocPrint(a, "review.{s}", .{normalized});
}

pub const SourceSpan = struct { source: card.SourceRange, capture: bbr.highlight.Capture };
pub const Result = struct {
    allocator: Allocator,
    spans: []const SourceSpan,

    pub fn retainedBytes(self: *const Result) usize {
        return @sizeOf(Result) + self.spans.len * @sizeOf(SourceSpan);
    }

    pub fn destroy(self: *Result) void {
        const a = self.allocator;
        a.free(self.spans);
        a.destroy(self);
    }
};

pub const Identity = struct {
    session_epoch: u64,
    owner: card.Owner,
    block: usize,
    body_hash: u64,
    context_hash: u64,
};

pub const Completed = struct {
    command_id: u64,
    identity: Identity,
    result: ?*Result = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Completed) void {
        if (self.result) |result| result.destroy();
        self.result = null;
    }
};

pub const Analyze = struct {
    command_id: u64 = 0,
    identity: Identity,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    content: []const u8,
    mapping: []const Mapping,
    const Mapping = struct { start: usize, end: usize, authored: usize };

    pub fn create(backing: Allocator, identity: Identity, block: body_mod.Block, path: []const u8) !*Analyze {
        const command = try backing.create(Analyze);
        command.* = .{ .identity = identity, .arena = std.heap.ArenaAllocator.init(backing), .path = "", .content = "", .mapping = &.{} };
        errdefer command.destroy();
        const a = command.arena.allocator();
        command.path = try a.dupe(u8, path);
        var content: std.ArrayList(u8) = .empty;
        var mapping: std.ArrayList(Mapping) = .empty;
        for (block.spans) |span| {
            if (span.hidden or span.generated) continue;
            try mapping.append(a, .{ .start = content.items.len, .end = content.items.len + span.text.len, .authored = span.source.start });
            try content.appendSlice(a, span.text);
        }
        command.content = content.items;
        command.mapping = mapping.items;
        return command;
    }

    pub fn destroy(self: *Analyze) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }

    pub fn launchFailed(self: *Analyze) Completed {
        const completed: Completed = .{ .command_id = self.command_id, .identity = self.identity, .failure = error.WorkerLaunchFailed };
        self.destroy();
        return completed;
    }

    /// Consumes the command. Only exact-sized source Spans leave worker scratch storage.
    pub fn execute(self: *Analyze, highlighter: bbr.highlight.Highlighter) Completed {
        defer self.destroy();
        var completed: Completed = .{ .command_id = self.command_id, .identity = self.identity };
        completed.result = self.analyze(highlighter) catch |err| {
            completed.failure = err;
            return completed;
        };
        return completed;
    }

    fn analyze(self: *Analyze, highlighter: bbr.highlight.Highlighter) !*Result {
        const backing = self.arena.child_allocator;
        var scratch = std.heap.ArenaAllocator.init(backing);
        defer scratch.deinit();
        const a = scratch.allocator();
        const highlighted = try highlighter.highlightWithScratch(a, a, self.path, self.content);
        var starts: std.ArrayList(usize) = .empty;
        try starts.append(a, 0);
        for (self.content, 0..) |byte, index| if (byte == '\n') {
            try starts.append(a, index + 1);
        };
        var mapped: std.ArrayList(SourceSpan) = .empty;
        for (highlighted.spans) |span| {
            if (span.line == 0 or span.line > starts.items.len or span.end < span.start) return error.InvalidHighlightSpan;
            const start = starts.items[span.line - 1] + span.start;
            const end = starts.items[span.line - 1] + span.end;
            if (end > self.content.len) return error.InvalidHighlightSpan;
            for (self.mapping) |range| {
                const lo = @max(start, range.start);
                const hi = @min(end, range.end);
                if (lo < hi) try mapped.append(a, .{ .source = .{ .start = range.authored + lo - range.start, .end = range.authored + hi - range.start }, .capture = span.capture });
            }
        }
        const result = try backing.create(Result);
        errdefer backing.destroy(result);
        result.* = .{ .allocator = backing, .spans = try backing.dupe(SourceSpan, mapped.items) };
        return result;
    }
};

pub const State = enum { pending, running, ready, failed, skipped, evicted };
pub const BlockState = struct {
    state: State = .pending,
    result: ?*Result = null,
    context_hash: u64 = 0,
    used: u64 = 0,
    left_viewport: bool = false,
};

pub const Body = struct {
    owner: card.Owner,
    arena: std.heap.ArenaAllocator,
    parsed: body_mod.ReviewBody,
    blocks: []BlockState,
    visible: bool = false,

    pub const Eligible = struct { ordinal: usize, block: body_mod.Block, path: []const u8 };

    pub fn nextEligible(self: *Body, a: Allocator, max_bytes: usize) !?Eligible {
        for (self.parsed.blocks, self.blocks, 0..) |block, *state, ordinal| {
            if (state.state != .pending) continue;
            if (block.kind != .code or block.fences == null or block.fence_identifier.len == 0) {
                state.state = .skipped;
                continue;
            }
            const path = fencePath(a, block.fence_identifier) catch |err| {
                state.state = .failed;
                return err;
            } orelse {
                state.state = .skipped;
                continue;
            };
            var bytes: usize = 0;
            for (block.spans) |span| if (!span.hidden and !span.generated) {
                bytes +|= span.text.len;
            };
            if (max_bytes != 0 and bytes > max_bytes) {
                a.free(path);
                state.state = .skipped;
                continue;
            }
            return .{ .ordinal = ordinal, .block = block, .path = path };
        }
        return null;
    }

    fn destroy(self: *Body) void {
        for (self.blocks) |block| if (block.result) |result| result.destroy();
        const a = self.arena.child_allocator;
        self.arena.deinit();
        a.destroy(self);
    }
};

pub const View = struct { owner: card.Owner, body: []const u8, block: usize, spans: []const SourceSpan };

pub const Storage = struct {
    bodies: std.ArrayList(*Body) = .empty,
    views: std.ArrayList(View) = .empty,
    clock: u64 = 0,
    retained_bytes: usize = 0,

    pub fn retainedBytes(self: *const Storage) usize {
        return self.retained_bytes + self.views.capacity * @sizeOf(View);
    }

    pub fn deinit(self: *Storage, a: Allocator) void {
        for (self.bodies.items) |body| body.destroy();
        self.bodies.deinit(a);
        self.views.deinit(a);
    }

    pub fn remove(self: *Storage, index: usize) void {
        const body = self.bodies.orderedRemove(index);
        for (body.blocks, 0..) |block, ordinal| if (block.result != null) self.removeResult(body, ordinal);
        body.destroy();
    }

    pub fn get(self: *Storage, a: Allocator, owner: card.Owner, source: []const u8) !*Body {
        for (self.bodies.items, 0..) |body, index| if (std.meta.eql(body.owner, owner)) {
            if (std.mem.eql(u8, body.parsed.source, source)) return body;
            self.remove(index);
            break;
        };
        const body = try a.create(Body);
        body.* = .{ .owner = owner, .arena = std.heap.ArenaAllocator.init(a), .parsed = undefined, .blocks = &.{} };
        errdefer body.destroy();
        body.parsed = try body_mod.ReviewBody.parse(body.arena.allocator(), source);
        body.blocks = try body.arena.allocator().alloc(BlockState, body.parsed.blocks.len);
        @memset(body.blocks, .{});
        try self.bodies.append(a, body);
        return body;
    }

    pub fn finishVisibility(self: *Storage) void {
        for (self.bodies.items) |body| for (body.blocks) |*block| {
            if (!body.visible) block.left_viewport = true;
            if (body.visible) {
                self.clock +%= 1;
                block.used = self.clock;
                if (block.state == .evicted and block.left_viewport) block.state = .pending;
                block.left_viewport = false;
            }
        };
    }

    fn removeResult(self: *Storage, body: *Body, ordinal: usize) void {
        const block = &body.blocks[ordinal];
        const result = block.result.?;
        self.retained_bytes -= result.retainedBytes();
        for (self.views.items, 0..) |view, index| if (std.meta.eql(view.owner, body.owner) and view.block == ordinal) {
            _ = self.views.orderedRemove(index);
            break;
        };
        result.destroy();
        block.result = null;
        block.state = .evicted;
        block.left_viewport = !body.visible;
    }

    /// Allocation precedes eviction and publication. A failed admission changes no colors.
    pub fn admit(self: *Storage, a: Allocator, body: *Body, ordinal: usize, result: *Result) !bool {
        if (result.retainedBytes() + @sizeOf(View) > budget_bytes) {
            body.blocks[ordinal].state = .skipped;
            return false;
        }
        var candidate: std.ArrayList(View) = .empty;
        defer candidate.deinit(a);
        try candidate.appendSlice(a, self.views.items);
        try candidate.append(a, .{ .owner = body.owner, .body = body.parsed.source, .block = ordinal, .spans = result.spans });
        var result_bytes = self.retained_bytes + result.retainedBytes();
        while (result_bytes + candidate.items.len * @sizeOf(View) > budget_bytes) {
            var victim: usize = 0;
            for (candidate.items[0 .. candidate.items.len - 1], 0..) |view, index| {
                const selected_body = self.bodyFor(view.owner);
                const prior = self.bodyFor(candidate.items[victim].owner);
                if ((!selected_body.visible and prior.visible) or
                    (selected_body.visible == prior.visible and selected_body.blocks[view.block].used < prior.blocks[candidate.items[victim].block].used)) victim = index;
            }
            const removed = candidate.orderedRemove(victim);
            result_bytes -= self.bodyFor(removed.owner).blocks[removed.block].result.?.retainedBytes();
        }
        // Exact-sized annotation storage also belongs to the retained-result budget.
        const views = try a.dupe(View, candidate.items);
        for (self.bodies.items) |existing| for (existing.blocks, 0..) |block, index| {
            if (block.result == null) continue;
            var keep = false;
            for (views) |view| if (std.meta.eql(view.owner, existing.owner) and view.block == index) {
                keep = true;
                break;
            };
            if (!keep) self.removeResult(existing, index);
        };
        self.views.deinit(a);
        self.views = .{ .items = views, .capacity = views.len };
        body.blocks[ordinal].result = result;
        body.blocks[ordinal].state = .ready;
        self.clock +%= 1;
        body.blocks[ordinal].used = self.clock;
        self.retained_bytes += result.retainedBytes();
        return true;
    }

    fn bodyFor(self: *const Storage, owner: card.Owner) *Body {
        for (self.bodies.items) |body| if (std.meta.eql(body.owner, owner)) return body;
        unreachable;
    }
};

test "M23 highlighting approved fence aliases and invalid identifiers" {
    const a = std.testing.allocator;
    const cases = [_]struct { identifier: []const u8, path: ?[]const u8 }{
        .{ .identifier = "TS", .path = "review.ts" },
        .{ .identifier = "tsx", .path = "review.tsx" },
        .{ .identifier = "typescript", .path = "review.ts" },
        .{ .identifier = "mts", .path = "review.ts" },
        .{ .identifier = "cts", .path = "review.ts" },
        .{ .identifier = "javascript", .path = "review.js" },
        .{ .identifier = "js", .path = "review.js" },
        .{ .identifier = "jsx", .path = "review.js" },
        .{ .identifier = "mjs", .path = "review.js" },
        .{ .identifier = "cjs", .path = "review.js" },
        .{ .identifier = "css", .path = "review.css" },
        .{ .identifier = "go", .path = "review.go" },
        .{ .identifier = "bash", .path = "review.sh" },
        .{ .identifier = "sh", .path = "review.sh" },
        .{ .identifier = "shell", .path = "review.sh" },
        .{ .identifier = "json", .path = "review.json" },
        .{ .identifier = "yaml", .path = "review.yaml" },
        .{ .identifier = "yml", .path = "review.yaml" },
        .{ .identifier = "python", .path = "review.py" },
        .{ .identifier = "py", .path = "review.py" },
        .{ .identifier = "ruby", .path = "review.rb" },
        .{ .identifier = "rb", .path = "review.rb" },
        .{ .identifier = "rust", .path = "review.rs" },
        .{ .identifier = "rs", .path = "review.rs" },
        .{ .identifier = "c", .path = "review.c" },
        .{ .identifier = "cpp", .path = "review.cpp" },
        .{ .identifier = "C++", .path = "review.cpp" },
        .{ .identifier = "cxx", .path = "review.cpp" },
        .{ .identifier = "csharp", .path = "review.cs" },
        .{ .identifier = "c#", .path = "review.cs" },
        .{ .identifier = "cs", .path = "review.cs" },
        .{ .identifier = "java", .path = "review.java" },
        .{ .identifier = "html", .path = "review.html" },
        .{ .identifier = "xml", .path = "review.xml" },
        .{ .identifier = "sql", .path = "review.sql" },
        .{ .identifier = "zig", .path = "review.zig" },
        .{ .identifier = "golang", .path = "review.go" },
        .{ .identifier = "kOtLiN", .path = "review.kotlin" },
        .{ .identifier = "A9_+-", .path = "review.a9_+-" },
        .{ .identifier = "text/x-python", .path = null },
        .{ .identifier = "src/main.go", .path = null },
        .{ .identifier = "{.go}", .path = null },
        .{ .identifier = "_go", .path = null },
        .{ .identifier = "", .path = null },
    };
    for (cases) |case| {
        const path = try fencePath(a, case.identifier);
        defer if (path) |value| a.free(value);
        if (case.path) |expected| try std.testing.expectEqualStrings(expected, path.?) else try std.testing.expect(path == null);
    }
}
