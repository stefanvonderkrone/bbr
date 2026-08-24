const std = @import("std");

const c = @cImport({
    @cInclude("bbr_re2.h");
});

pub const max_pattern_bytes = 4096;
pub const engine = "RE2-2025-11-05";
pub const dialect = "https://github.com/google/re2/blob/2025-11-05/doc/syntax.txt";

pub const CompileFailure = struct {
    reason: enum { pattern_too_long, compile_budget_exceeded, invalid_pattern, out_of_memory },
    engine_code: c_int = 0,
    engine_fragment: [256]u8 = undefined,
    engine_fragment_len: usize = 0,

    pub fn fragment(self: *const CompileFailure) []const u8 {
        return self.engine_fragment[0..self.engine_fragment_len];
    }
};

pub const CompileResult = union(enum) {
    regex: Regex,
    failure: CompileFailure,
};

pub const Regex = struct {
    ptr: *c.BbrRegex,

    pub fn compile(pattern: []const u8) CompileResult {
        if (pattern.len > max_pattern_bytes) {
            return .{ .failure = .{ .reason = .pattern_too_long } };
        }
        var failure: CompileFailure = .{ .reason = .invalid_pattern };
        const ptr = c.bbr_regex_compile(
            pattern.ptr,
            pattern.len,
            &failure.engine_code,
            &failure.engine_fragment,
            failure.engine_fragment.len,
            &failure.engine_fragment_len,
        ) orelse {
            if (failure.engine_code == c.BBR_REGEX_OUT_OF_MEMORY) {
                failure.reason = .out_of_memory;
            } else if (failure.engine_code == c.BBR_RE2_ERROR_PATTERN_TOO_LARGE) {
                failure.reason = .compile_budget_exceeded;
            }
            return .{ .failure = failure };
        };
        return .{ .regex = .{ .ptr = ptr } };
    }

    pub fn deinit(self: Regex) void {
        c.bbr_regex_delete(self.ptr);
    }

    pub fn matches(self: Regex, text: []const u8) bool {
        return c.bbr_regex_match(self.ptr, text.ptr, text.len);
    }
};

const testing = std.testing;

test "RE2 wrapper uses the fixed length-bearing predicate profile" {
    var regex = switch (Regex.compile("^héllo\\x00world$")) {
        .regex => |value| value,
        .failure => return error.UnexpectedCompileFailure,
    };
    defer regex.deinit();

    try testing.expect(regex.matches("héllo\x00world"));
    try testing.expect(!regex.matches("HÉLLO\x00world"));
    try testing.expect(!regex.matches("héllo\nworld"));
}

test "RE2 wrapper rejects unsupported syntax and oversized patterns" {
    const invalid = Regex.compile("(?=lookaround)");
    try testing.expect(invalid == .failure);
    try testing.expectEqual(.invalid_pattern, invalid.failure.reason);
    try testing.expect(invalid.failure.engine_code != 0);
    try testing.expect(invalid.failure.fragment().len != 0);

    const oversized = Regex.compile("a" ** (max_pattern_bytes + 1));
    try testing.expect(oversized == .failure);
    try testing.expectEqual(.pattern_too_long, oversized.failure.reason);
}
