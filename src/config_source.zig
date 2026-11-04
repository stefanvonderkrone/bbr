const std = @import("std");
const xdg = @import("xdg.zig");
pub const max_bytes = 64 * 1024;

pub const Snapshot = struct {
    path: ?[]u8 = null,
    source: ?[]u8 = null,
    read_error: ?anyerror = null,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Snapshot {
        const path = xdg.configFile(allocator, env) catch |err| return .{ .read_error = err };
        const resolved = path orelse return .{};
        const source = std.Io.Dir.cwd().readFileAlloc(io, resolved, allocator, .limited(max_bytes + 1)) catch |err| {
            return .{ .path = resolved, .read_error = if (err == error.FileNotFound) null else err };
        };
        return .{ .path = resolved, .source = source };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        if (self.source) |source| allocator.free(source);
    }
};

pub const LineParser = struct {
    text: []const u8,
    pos: usize = 0,
    pub fn done(self: LineParser) bool {
        return self.pos >= self.text.len;
    }
    pub fn peek(self: LineParser) u8 {
        return self.text[self.pos];
    }
    pub fn column(self: LineParser) usize {
        return self.pos + 1;
    }
    pub fn take(self: *LineParser, expected: u8) bool {
        if (self.done() or self.peek() != expected) return false;
        self.pos += 1;
        return true;
    }
    pub fn space(self: *LineParser) void {
        while (!self.done() and (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\r')) self.pos += 1;
    }
    pub fn trailing(self: LineParser) bool {
        return self.done() or self.peek() == '#';
    }
    pub fn section(self: *LineParser) ![]const u8 {
        if (!self.take('[')) return error.ExpectedSection;
        const start = self.pos;
        while (!self.done() and self.peek() != ']') self.pos += 1;
        if (self.done() or self.pos == start) return error.ExpectedClose;
        const result = self.text[start..self.pos];
        self.pos += 1;
        return result;
    }
    pub fn key(self: *LineParser) ![]const u8 {
        if (!self.done() and self.peek() == '"') return self.quoted();
        const start = self.pos;
        while (!self.done()) {
            const ch = self.peek();
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) break;
            self.pos += 1;
        }
        if (self.pos == start) return error.ExpectedKey;
        return self.text[start..self.pos];
    }
    pub fn quoted(self: *LineParser) ![]const u8 {
        if (!self.take('"')) return error.ExpectedQuote;
        const start = self.pos;
        while (!self.done() and self.peek() != '"') {
            if (self.peek() == '\\') return error.UnsupportedEscape;
            self.pos += 1;
        }
        if (self.done()) return error.UnterminatedString;
        const result = self.text[start..self.pos];
        self.pos += 1;
        return result;
    }
    pub const StringArray = struct {
        items: [16][]const u8 = undefined,
        len: usize = 0,
        pub fn slice(self: *const StringArray) []const []const u8 {
            return self.items[0..self.len];
        }
    };
    pub fn stringArray(self: *LineParser) !StringArray {
        var result: StringArray = .{};
        if (!self.take('[')) return error.ExpectedArray;
        self.space();
        if (self.take(']')) return result;
        while (true) {
            if (result.len == result.items.len) return error.TooManyItems;
            result.items[result.len] = try self.quoted();
            result.len += 1;
            self.space();
            if (self.take(']')) return result;
            if (!self.take(',')) return error.ExpectedComma;
            self.space();
        }
    }
    pub fn unsigned(self: *LineParser) ![]const u8 {
        const start = self.pos;
        while (!self.done() and std.ascii.isDigit(self.peek())) self.pos += 1;
        if (self.pos == start) return error.ExpectedUnsigned;
        return self.text[start..self.pos];
    }
    pub fn boolean(self: *LineParser) ![]const u8 {
        for ([_][]const u8{ "true", "false" }) |text| {
            if (std.mem.startsWith(u8, self.text[self.pos..], text)) {
                self.pos += text.len;
                return text;
            }
        }
        return error.ExpectedBoolean;
    }
};
