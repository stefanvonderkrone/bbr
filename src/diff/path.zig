const std = @import("std");

pub const NormalizeError = error{ InvalidPath, OutOfMemory };

/// Decode Git's C-style path quoting and require one repository-relative File path.
/// Quoted RawDiff operands may still carry their `a/` or `b/` side prefix.
pub fn normalize(allocator: std.mem.Allocator, input: []const u8) NormalizeError![]u8 {
    const normalized = if (input.len > 0 and input[0] == '"') quoted: {
        if (input.len < 2 or input[input.len - 1] != '"') return error.InvalidPath;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = if (std.mem.startsWith(u8, input, "\"a/") or std.mem.startsWith(u8, input, "\"b/")) 3 else 1;
        while (i < input.len - 1) {
            if (input[i] != '\\') {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= input.len - 1) return error.InvalidPath;
            const escaped: u8 = switch (input[i]) {
                'a' => 0x07,
                'b' => 0x08,
                't' => '\t',
                'n' => '\n',
                'v' => 0x0b,
                'f' => 0x0c,
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '0'...'7' => octal: {
                    if (input.len - 1 - i < 3 or input[i + 1] < '0' or input[i + 1] > '7' or input[i + 2] < '0' or input[i + 2] > '7') return error.InvalidPath;
                    const value = (@as(u16, input[i] - '0') << 6) | (@as(u16, input[i + 1] - '0') << 3) | @as(u16, input[i + 2] - '0');
                    if (value > 255) return error.InvalidPath;
                    i += 2;
                    break :octal @intCast(value);
                },
                else => return error.InvalidPath,
            };
            try out.append(allocator, escaped);
            i += 1;
        }
        break :quoted try out.toOwnedSlice(allocator);
    } else try allocator.dupe(u8, input);
    errdefer allocator.free(normalized);
    if (!isRepositoryRelative(normalized)) return error.InvalidPath;
    return normalized;
}

pub fn isRepositoryRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

test "normalizes quoted RawDiff paths" {
    const normalized = try normalize(std.testing.allocator, "\"a/src/quoted\\040name\\042.txt\"");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("src/quoted name\".txt", normalized);
}

test "rejects malformed and non-repository-relative paths" {
    for ([_][]const u8{ "", "/file", "../file", "src/../file", "src//file", "\"unterminated" }) |input|
        try std.testing.expectError(error.InvalidPath, normalize(std.testing.allocator, input));
}
