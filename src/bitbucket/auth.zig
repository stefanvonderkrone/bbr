//! Bitbucket credential file (`auth.toml`) with named profiles.
//!
//! Opencode keeps provider credentials in `$XDG_DATA_HOME/opencode/auth.json`
//! with `0600` permissions; `bbr` does the same under `$XDG_DATA_HOME/bbr/`
//! but in TOML, matching the rest of our configuration surface:
//!
//! ```toml
//! active_profile = "default"
//!
//! [profiles.default]
//! username = "ada@example.com"
//! token = "ATBB-..."
//! workspace = "check24"
//! ```
//!
//! Profile selection is `--profile` > `BBR_PROFILE` > `active_profile` >
//! `"default"`. The `BITBUCKET_USERNAME` / `BITBUCKET_TOKEN` /
//! `BITBUCKET_WORKSPACE` environment variables override the selected
//! profile per field, so scripts keep working without a file.
//!
//! The token is a secret: it is never logged. File writes are atomic with
//! `0600` permissions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const Credential = @import("credential.zig").Credential;

/// The profile used when nothing selects another one.
pub const default_profile: []const u8 = "default";

/// Maximum profile name length (keeps headers and diagnostics bounded).
pub const max_profile_name_len: usize = 64;

/// Both loading and saving accept at most 64 KiB.
const max_auth_file_size: usize = 64 * 1024;

pub const Error = error{
    NoDataHome,
    InvalidAuthFile,
    InvalidProfileName,
    MissingUsername,
    MissingToken,
    MissingWorkspace,
    NoCredential,
};

/// One named credential set. All slices are owned by the allocator passed to
/// `parse` / `resolve`; free with `deinit` / `deinitOwned`.
pub const NamedProfile = struct {
    name: []const u8,
    username: []const u8,
    token: []const u8,
    workspace: []const u8,
};

/// Borrowed view used for saving (no ownership taken).
pub const ProfileView = struct {
    name: []const u8,
    username: []const u8,
    token: []const u8,
    workspace: []const u8,
};

/// A parsed `auth.toml`. Owns all its strings.
pub const AuthFile = struct {
    active_profile: []const u8,
    profiles: []NamedProfile,

    pub fn deinit(self: *AuthFile, allocator: Allocator) void {
        allocator.free(self.active_profile);
        for (self.profiles) |p| {
            allocator.free(p.name);
            allocator.free(p.username);
            allocator.free(p.token);
            allocator.free(p.workspace);
        }
        allocator.free(self.profiles);
        self.* = undefined;
    }

    pub fn find(self: *const AuthFile, name: []const u8) ?*const NamedProfile {
        for (self.profiles) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

/// A resolved credential with owned strings. Lives as long as the Bitbucket
/// client using it; free with `deinit`.
pub const OwnedCredential = struct {
    username: []u8,
    token: []u8,
    workspace: []u8,
    profile: []u8,

    pub fn deinit(self: *OwnedCredential, allocator: Allocator) void {
        allocator.free(self.username);
        allocator.free(self.token);
        allocator.free(self.workspace);
        allocator.free(self.profile);
        self.* = undefined;
    }

    /// Borrowed view for `Client.init` (valid while `self` is alive).
    pub fn credential(self: *const OwnedCredential) Credential {
        return .{ .username = self.username, .token = self.token, .workspace = self.workspace };
    }
};

/// Profile names start alphanumerically and allow `-`/`_` after that.
pub fn isValidProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_profile_name_len) return false;
    for (name, 0..) |c, i| {
        const ok = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9' => true,
            '-', '_' => i > 0,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

fn dataHome(allocator: Allocator, env: *const EnvMap) !?[]u8 {
    if (env.get("XDG_DATA_HOME")) |base| return try allocator.dupe(u8, base);
    if (env.get("HOME")) |home| return try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
    return null;
}

/// Full path of `auth.toml`, or `null` when neither `XDG_DATA_HOME` nor
/// `HOME` is set. Caller owns the result.
pub fn authFilePath(allocator: Allocator, env: *const EnvMap) !?[]u8 {
    const base = (try dataHome(allocator, env)) orelse return null;
    defer allocator.free(base);
    return try std.fmt.allocPrint(allocator, "{s}/bbr/auth.toml", .{base});
}

/// Directory holding `auth.toml` (`.../bbr`). Caller owns the result.
fn authDirPath(allocator: Allocator, env: *const EnvMap) !?[]u8 {
    const base = (try dataHome(allocator, env)) orelse return null;
    defer allocator.free(base);
    return try std.fmt.allocPrint(allocator, "{s}/bbr", .{base});
}

/// Parse one double-quoted TOML basic string (handles `\"` and `\\`).
/// Returns the unescaped value owned by `allocator`.
fn parseBasicString(allocator: Allocator, raw: []const u8, location: *ParseLocation) ![]u8 {
    if (raw.len == 0 or raw[0] != '"') return error.InvalidAuthFile;
    const start_column = location.column;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        location.column = start_column + i;
        const c = raw[i];
        if (c == '"') {
            if (i != raw.len - 1) return error.InvalidAuthFile;
            return out.toOwnedSlice(allocator);
        }
        if (c == '\\') {
            i += 1;
            location.column = start_column + i;
            if (i >= raw.len) return error.InvalidAuthFile;
            switch (raw[i]) {
                '"', '\\' => try out.append(allocator, raw[i]),
                else => return error.InvalidAuthFile,
            }
        } else if (isForbiddenStringByte(c)) {
            return error.InvalidAuthFile;
        } else {
            try out.append(allocator, c);
        }
    }
    location.column = start_column + raw.len;
    return error.InvalidAuthFile;
}

fn isForbiddenStringByte(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7f;
}

fn escapeInto(buf: *std.ArrayList(u8), allocator: Allocator, raw: []const u8) !void {
    for (raw) |c| {
        if (isForbiddenStringByte(c)) return error.InvalidAuthFile;
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            else => try buf.append(allocator, c),
        }
    }
}

/// Strip a trailing `#` comment that sits outside a double-quoted string.
fn stripTrailingComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
        } else if (c == '"') {
            in_string = true;
        } else if (c == '#') {
            return std.mem.trimEnd(u8, line[0..i], " \t");
        }
    }
    return line;
}

/// Parse `auth.toml` source into an owned `AuthFile`. Unknown tables and keys
/// are ignored for forward compatibility; malformed structure or empty values
/// for known keys are `error.InvalidAuthFile`.
pub fn parse(allocator: Allocator, source: []const u8) !AuthFile {
    var location: ParseLocation = .{};
    return parseWithLocation(allocator, source, &location);
}

const ParseLocation = struct {
    line: usize = 1,
    column: usize = 1,
};

/// Skip an unknown value through its closing brackets or multiline quotes.
/// This scans delimiters only. Known values still use parseBasicString.
fn skipUnknownValue(
    first: []const u8,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_number: *usize,
    location: *ParseLocation,
) !void {
    var raw = first;
    var depth: usize = 0;
    var quote: u8 = 0;
    var multiline = false;
    while (true) {
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (quote != 0) {
                if (quote == '"' and c == '\\') {
                    i += 1;
                    continue;
                }
                if (c == quote) {
                    if (!multiline) {
                        quote = 0;
                    } else if (raw.len - i >= 3 and raw[i + 1] == quote and raw[i + 2] == quote) {
                        // TOML permits one or two extra quotes at the end.
                        i += 2;
                        while (i + 1 < raw.len and raw[i + 1] == quote) i += 1;
                        quote = 0;
                        multiline = false;
                    }
                }
                continue;
            }
            switch (c) {
                '#' => break,
                '"', '\'' => {
                    quote = c;
                    multiline = raw.len - i >= 3 and raw[i + 1] == c and raw[i + 2] == c;
                    if (multiline) i += 2;
                },
                '[', '{' => depth += 1,
                ']', '}' => {
                    if (depth == 0) return error.InvalidAuthFile;
                    depth -= 1;
                },
                else => {},
            }
        }
        if (quote != 0 and !multiline) return error.InvalidAuthFile;
        if (depth == 0 and quote == 0) return;
        raw = lines.next() orelse return error.InvalidAuthFile;
        line_number.* += 1;
        location.* = .{ .line = line_number.*, .column = 1 };
    }
}

fn appendProfile(allocator: Allocator, profiles: *std.ArrayList(NamedProfile), name: []const u8) !usize {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const username = try allocator.dupe(u8, "");
    errdefer allocator.free(username);
    const token = try allocator.dupe(u8, "");
    errdefer allocator.free(token);
    const workspace = try allocator.dupe(u8, "");
    errdefer allocator.free(workspace);
    try profiles.append(allocator, .{
        .name = owned_name,
        .username = username,
        .token = token,
        .workspace = workspace,
    });
    return profiles.items.len - 1;
}

fn parseWithLocation(allocator: Allocator, source: []const u8, location: *ParseLocation) !AuthFile {
    var active: ?[]u8 = null;
    errdefer if (active) |a| allocator.free(a);
    var profiles: std.ArrayList(NamedProfile) = .empty;
    errdefer {
        for (profiles.items) |p| {
            allocator.free(p.name);
            allocator.free(p.username);
            allocator.free(p.token);
            allocator.free(p.workspace);
        }
        profiles.deinit(allocator);
    }

    var table: union(enum) { top_level, profile: usize, unknown } = .top_level;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        // Only the final CR belongs to a CRLF line ending.
        const without_cr = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        const content = std.mem.trim(u8, without_cr, " \t");
        const line = stripTrailingComment(content);
        location.* = .{ .line = line_number, .column = @intFromPtr(line.ptr) - @intFromPtr(raw.ptr) + 1 };
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            table = .unknown;
            if (!std.mem.endsWith(u8, line, "]")) return error.InvalidAuthFile;
            const header = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            const prefix = "profiles.";
            if (std.mem.startsWith(u8, header, prefix)) {
                const name = std.mem.trim(u8, header[prefix.len..], " \t");
                location.column = @intFromPtr(name.ptr) - @intFromPtr(raw.ptr) + 1;
                if (!isValidProfileName(name)) return error.InvalidAuthFile;
                // Headers declare profiles even when all fields are missing.
                table = .{ .profile = findIndex(profiles.items, name) orelse try appendProfile(allocator, &profiles, name) };
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            if (table == .unknown) continue;
            return error.InvalidAuthFile;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.InvalidAuthFile;
        const known = switch (table) {
            .top_level => std.mem.eql(u8, key, "active_profile"),
            .profile => std.mem.eql(u8, key, "username") or
                std.mem.eql(u8, key, "token") or std.mem.eql(u8, key, "workspace"),
            .unknown => false,
        };
        if (!known) {
            try skipUnknownValue(content[eq + 1 ..], &lines, &line_number, location);
            continue;
        }
        const value_source = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const value_column = @intFromPtr(value_source.ptr) - @intFromPtr(raw.ptr) + 1;
        location.column = value_column;
        const value = try parseBasicString(allocator, value_source, location);
        errdefer allocator.free(value);
        location.column = value_column;
        if (value.len == 0) return error.InvalidAuthFile;

        switch (table) {
            .top_level => {
                if (!isValidProfileName(value)) return error.InvalidAuthFile;
                if (active) |a| allocator.free(a);
                active = value;
            },
            .profile => |idx| {
                const slot: *[]const u8 = if (std.mem.eql(u8, key, "username"))
                    &profiles.items[idx].username
                else if (std.mem.eql(u8, key, "token"))
                    &profiles.items[idx].token
                else
                    &profiles.items[idx].workspace;
                allocator.free(slot.*);
                slot.* = value;
            },
            .unknown => unreachable,
        }
    }

    if (active == null) active = try allocator.dupe(u8, default_profile);
    return .{
        .active_profile = active.?,
        .profiles = try profiles.toOwnedSlice(allocator),
    };
}

fn findIndex(profiles: []const NamedProfile, name: []const u8) ?usize {
    for (profiles, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return null;
}

/// Serialize profiles to `auth.toml` source. Omit absent fields so the
/// environment can still fill them. Caller owns the result.
pub fn serialize(allocator: Allocator, active_profile: []const u8, profiles: []const ProfileView) ![]u8 {
    if (!isValidProfileName(active_profile)) return error.InvalidProfileName;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "active_profile = \"");
    try escapeInto(&buf, allocator, active_profile);
    try buf.appendSlice(allocator, "\"\n");
    for (profiles) |p| {
        if (!isValidProfileName(p.name)) return error.InvalidProfileName;
        try buf.appendSlice(allocator, "\n[profiles.");
        try buf.appendSlice(allocator, p.name);
        try buf.appendSlice(allocator, "]\n");
        for ([_][]const u8{ "username", "token", "workspace" }, [_][]const u8{ p.username, p.token, p.workspace }) |key, value| {
            if (value.len == 0) continue;
            try buf.appendSlice(allocator, key);
            try buf.appendSlice(allocator, " = \"");
            try escapeInto(&buf, allocator, value);
            try buf.appendSlice(allocator, "\"\n");
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// A loaded file with its path (both owned). `null` when no data home exists
/// or no file is present.
pub const Loaded = struct {
    path: []u8,
    file: AuthFile,

    pub fn deinit(self: *Loaded, allocator: Allocator) void {
        allocator.free(self.path);
        self.file.deinit(allocator);
        self.* = undefined;
    }
};

/// Load and parse `auth.toml`. Returns `null` when there is no data home or
/// no file yet (first login).
pub fn load(allocator: Allocator, io: std.Io, env: *const EnvMap) !?Loaded {
    const path = (try authFilePath(allocator, env)) orelse return null;
    errdefer allocator.free(path);
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_auth_file_size + 1)) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(path);
            return null;
        },
        error.StreamTooLong => {
            reportParseDiagnostic(io, path, .{});
            return error.InvalidAuthFile;
        },
        else => return err,
    };
    defer allocator.free(source);
    if (source.len > max_auth_file_size) {
        reportParseDiagnostic(io, path, .{});
        return error.InvalidAuthFile;
    }
    var location: ParseLocation = .{};
    const file = parseWithLocation(allocator, source, &location) catch |err| {
        if (err == error.InvalidAuthFile) reportParseDiagnostic(io, path, location);
        return err;
    };
    return .{ .path = path, .file = file };
}

fn writeParseDiagnostic(writer: *std.Io.Writer, path: []const u8, location: ParseLocation) !void {
    try writer.print("{s}:{d}:{d}: invalid auth file\n", .{ path, location.line, location.column });
}

fn reportParseDiagnostic(io: std.Io, path: []const u8, location: ParseLocation) void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    writeParseDiagnostic(&writer.interface, path, location) catch return;
    writer.interface.flush() catch {};
}

const file_permissions: std.Io.File.Permissions = @enumFromInt(0o600);

/// Atomically write profiles. Creates the `bbr` data directory. Returns the
/// file path (owned by `allocator`).
pub fn save(
    allocator: Allocator,
    io: std.Io,
    env: *const EnvMap,
    active_profile: []const u8,
    profiles: []const ProfileView,
) ![]u8 {
    const dir_path = (try authDirPath(allocator, env)) orelse return error.NoDataHome;
    defer allocator.free(dir_path);
    const path = try std.fmt.allocPrint(allocator, "{s}/auth.toml", .{dir_path});
    errdefer allocator.free(path);
    const source = try serialize(allocator, active_profile, profiles);
    defer allocator.free(source);
    if (source.len > max_auth_file_size) return error.InvalidAuthFile;

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, "auth.toml", .{ .replace = true, .permissions = file_permissions });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(source);
    try writer.interface.flush();
    try atomic.replace(io);
    // Enforce `0600` even when the atomic fallback preserved old modes.
    dir.setFilePermissions(io, "auth.toml", file_permissions, .{}) catch |err| switch (err) {
        error.OperationUnsupported => {},
        else => return err,
    };
    return path;
}

/// Insert or replace one profile and select it as active. Returns the file
/// path (owned by `allocator`).
pub fn upsertProfile(
    allocator: Allocator,
    io: std.Io,
    env: *const EnvMap,
    name: []const u8,
    creds: Credential,
) ![]u8 {
    if (!isValidProfileName(name)) return error.InvalidProfileName;
    if (creds.username.len == 0) return error.MissingUsername;
    if (creds.token.len == 0) return error.MissingToken;
    if (creds.workspace.len == 0) return error.MissingWorkspace;
    var loaded = try load(allocator, io, env);
    defer if (loaded) |*l| l.deinit(allocator);
    var views: std.ArrayList(ProfileView) = .empty;
    defer views.deinit(allocator);
    if (loaded) |*l| {
        for (l.file.profiles) |p| {
            if (std.mem.eql(u8, p.name, name)) continue;
            try views.append(allocator, .{
                .name = p.name,
                .username = p.username,
                .token = p.token,
                .workspace = p.workspace,
            });
        }
    }
    try views.append(allocator, .{
        .name = name,
        .username = creds.username,
        .token = creds.token,
        .workspace = creds.workspace,
    });
    return save(allocator, io, env, name, views.items);
}

/// Remove one profile, keeping the rest. Returns `true` when something was
/// removed. When the last profile goes, the file is deleted.
pub fn removeProfile(allocator: Allocator, io: std.Io, env: *const EnvMap, name: []const u8) !bool {
    var loaded = (try load(allocator, io, env)) orelse return false;
    defer loaded.deinit(allocator);
    var views: std.ArrayList(ProfileView) = .empty;
    defer views.deinit(allocator);
    for (loaded.file.profiles) |p| {
        if (std.mem.eql(u8, p.name, name)) continue;
        try views.append(allocator, .{
            .name = p.name,
            .username = p.username,
            .token = p.token,
            .workspace = p.workspace,
        });
    }
    if (views.items.len == loaded.file.profiles.len) return false;
    if (views.items.len == 0) {
        const path = (try authFilePath(allocator, env)) orelse return true;
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return true;
    }
    const active = if (std.mem.eql(u8, loaded.file.active_profile, name))
        views.items[0].name
    else
        loaded.file.active_profile;
    const path = try save(allocator, io, env, active, views.items);
    allocator.free(path);
    return true;
}

/// Delete the whole file. Returns `true` when a file was removed.
pub fn deleteAuthFile(allocator: Allocator, io: std.Io, env: *const EnvMap) !bool {
    const path = (try authFilePath(allocator, env)) orelse return false;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Pick the profile name: explicit arg > `BBR_PROFILE` > file's active >
/// `"default"`. The result is owned by `allocator`.
pub fn selectedProfileName(
    allocator: Allocator,
    env: *const EnvMap,
    file_active: ?[]const u8,
    explicit: ?[]const u8,
) ![]u8 {
    if (explicit) |name| {
        if (!isValidProfileName(name)) return error.InvalidProfileName;
        return allocator.dupe(u8, name);
    }
    if (env.get("BBR_PROFILE")) |name| {
        if (!isValidProfileName(name)) return error.InvalidProfileName;
        return allocator.dupe(u8, name);
    }
    if (file_active) |name| return allocator.dupe(u8, name);
    return allocator.dupe(u8, default_profile);
}

/// Resolve the credential for one profile: per-field `BITBUCKET_*`
/// environment overrides over the file. Missing fields are
/// `MissingUsername` / `MissingToken` / `MissingWorkspace`.
pub fn resolve(
    allocator: Allocator,
    io: std.Io,
    env: *const EnvMap,
    explicit_profile: ?[]const u8,
) !OwnedCredential {
    var loaded = try load(allocator, io, env);
    defer if (loaded) |*l| l.deinit(allocator);
    const file_active: ?[]const u8 = if (loaded) |*l| l.file.active_profile else null;
    const selected = try selectedProfileName(allocator, env, file_active, explicit_profile);
    errdefer allocator.free(selected);

    const from_file: ?*const NamedProfile = if (loaded) |*l| l.file.find(selected) else null;
    const username_src = env.get("BITBUCKET_USERNAME") orelse if (from_file) |f| (if (f.username.len > 0) f.username else null) else null;
    const token_src = env.get("BITBUCKET_TOKEN") orelse if (from_file) |f| (if (f.token.len > 0) f.token else null) else null;
    const workspace_src = env.get("BITBUCKET_WORKSPACE") orelse if (from_file) |f| (if (f.workspace.len > 0) f.workspace else null) else null;

    const username = try allocator.dupe(u8, username_src orelse return error.MissingUsername);
    errdefer allocator.free(username);
    const token = try allocator.dupe(u8, token_src orelse return error.MissingToken);
    errdefer allocator.free(token);
    const workspace = try allocator.dupe(u8, workspace_src orelse return error.MissingWorkspace);
    errdefer allocator.free(workspace);

    return .{
        .username = username,
        .token = token,
        .workspace = workspace,
        .profile = selected,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn envWith(map: *EnvMap, pairs: []const [2][]const u8) !void {
    for (pairs) |p| try map.put(p[0], p[1]);
}

test "profile names accept alphanumerics, dash, underscore" {
    try testing.expect(isValidProfileName("default"));
    try testing.expect(isValidProfileName("work-2_x"));
    try testing.expect(!isValidProfileName(""));
    try testing.expect(!isValidProfileName("-lead"));
    try testing.expect(!isValidProfileName("has space"));
    try testing.expect(!isValidProfileName("has.dot"));
}

test "auth file path prefers XDG and falls back to HOME" {
    var map = EnvMap.init(testing.allocator);
    defer map.deinit();
    try envWith(&map, &.{
        .{ "XDG_DATA_HOME", "/data" },
        .{ "HOME", "/home/ada" },
    });
    const xdg = (try authFilePath(testing.allocator, &map)).?;
    defer testing.allocator.free(xdg);
    try testing.expectEqualStrings("/data/bbr/auth.toml", xdg);

    var home_map = EnvMap.init(testing.allocator);
    defer home_map.deinit();
    try envWith(&home_map, &.{.{ "HOME", "/home/ada" }});
    const home = (try authFilePath(testing.allocator, &home_map)).?;
    defer testing.allocator.free(home);
    try testing.expectEqualStrings("/home/ada/.local/share/bbr/auth.toml", home);

    var empty = EnvMap.init(testing.allocator);
    defer empty.deinit();
    try testing.expect(try authFilePath(testing.allocator, &empty) == null);
}

test "parse round-trips two profiles" {
    const source =
        \\active_profile = "work"
        \\
        \\[profiles.default]
        \\username = "ada@example.com"
        \\token = "t1"
        \\workspace = "ws1"
        \\
        \\[profiles.work]
        \\username = "bob@example.com"
        \\token = "t2"
        \\workspace = "ws2"
        \\
    ;
    var file = try parse(testing.allocator, source);
    defer file.deinit(testing.allocator);
    try testing.expectEqualStrings("work", file.active_profile);
    try testing.expectEqual(@as(usize, 2), file.profiles.len);
    try testing.expect(file.find("work") != null);
    try testing.expectEqualStrings("bob@example.com", file.find("work").?.username);

    const views = [_]ProfileView{
        .{ .name = file.profiles[0].name, .username = file.profiles[0].username, .token = file.profiles[0].token, .workspace = file.profiles[0].workspace },
        .{ .name = file.profiles[1].name, .username = file.profiles[1].username, .token = file.profiles[1].token, .workspace = file.profiles[1].workspace },
    };
    const out = try serialize(testing.allocator, file.active_profile, &views);
    defer testing.allocator.free(out);
    var reparsed = try parse(testing.allocator, out);
    defer reparsed.deinit(testing.allocator);
    try testing.expectEqualStrings("work", reparsed.active_profile);
    try testing.expectEqual(@as(usize, 2), reparsed.profiles.len);
}

test "parse rejects empty values and bad names" {
    try testing.expectError(
        error.InvalidAuthFile,
        parse(testing.allocator, "[profiles.default]\nusername = \"\"\ntoken = \"t\"\nworkspace = \"w\"\n"),
    );
    try testing.expectError(
        error.InvalidAuthFile,
        parse(testing.allocator, "[profiles.has space]\nusername = \"a\"\n"),
    );
    try testing.expectError(
        error.InvalidAuthFile,
        parse(testing.allocator, "active_profile = \"-bad\"\n"),
    );
}

test "parse ignores unknown tables and keys" {
    const source =
        \\top_level = 1
        \\[future]
        \\version = 2
        \\active_profile = "work"
        \\[profiles.mine]
        \\username = "a"
        \\custom = true
        \\values = [1, 2]
        \\active_profile = "work"
        \\token = "b"
        \\workspace = "c"
        \\
    ;
    var file = try parse(testing.allocator, source);
    defer file.deinit(testing.allocator);
    try testing.expectEqualStrings("default", file.active_profile);
    try testing.expectEqual(@as(usize, 1), file.profiles.len);
    try testing.expectEqualStrings("a", file.find("mine").?.username);
}

test "parse skips unknown multiline arrays and quoted values" {
    const source =
        \\future = [
        \\  1,
        \\  2, # ] is in a comment
        \\  ["] #", '[#]', { answer = 42 }],
        \\]
        \\description = """
        \\[profiles.fake]
        \\active_profile = "fake" # this is string content
        \\escaped = \"""
        \\end""""
        \\active_profile = "work"
        \\[profiles.work]
        \\future = [
        \\  1,
        \\  2,
        \\]
        \\description = '''
        \\[profiles.other]
        \\token = "fake"
        \\end'''''
        \\username = "fake-user"
        \\token = "fake-token"
        \\workspace = "ws"
        \\[future]
        \\description = """
        \\[profiles.hidden]
        \\"""
        \\[profiles.empty]
        \\
    ;
    var file = try parse(testing.allocator, source);
    defer file.deinit(testing.allocator);
    try testing.expectEqualStrings("work", file.active_profile);
    try testing.expectEqual(@as(usize, 2), file.profiles.len);
    const work = file.find("work").?;
    try testing.expectEqualStrings("fake-user", work.username);
    try testing.expectEqualStrings("fake-token", work.token);
    try testing.expectEqualStrings("ws", work.workspace);
    try testing.expect(file.find("empty") != null);
    try testing.checkAllAllocationFailures(testing.allocator, checkParseAllocations, .{ source, false });
}

test "unknown continuations keep known values strict and preserve diagnostic lines" {
    var location: ParseLocation = .{};
    try testing.expectError(error.InvalidAuthFile, parseWithLocation(
        testing.allocator,
        "future = [\n 1,\n 2,\n]\n[profiles.work]\n token = 2\n",
        &location,
    ));
    try testing.expectEqual(@as(usize, 6), location.line);
    try testing.expectEqual(@as(usize, 10), location.column);
    for ([_][]const u8{
        "active_profile = [\n 1,\n]\n",
        "[profiles.work]\ntoken = [\n 1,\n]\n",
        "[profiles.work]\ntoken = \"\"\"\nfake\n\"\"\"\n",
        "future = [\n 1,\n",
        "future = \"\"\"\nunterminated\n",
    }) |source| {
        try testing.expectError(error.InvalidAuthFile, parse(testing.allocator, source));
    }
}

fn checkParseAllocations(allocator: Allocator, source: []const u8, invalid: bool) !void {
    // Force toOwnedSlice to allocate rather than shrink in place.
    var no_remap = testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const checked = no_remap.allocator();
    var file = parse(checked, source) catch |err| {
        if (invalid and err == error.InvalidAuthFile) return;
        return err;
    };
    defer file.deinit(checked);
    try testing.expect(!invalid);
}

test "parse frees allocations at every failure point" {
    const sources = [_][]const u8{
        "",
        "[profiles.empty]\n",
        "[profiles.first]\n[future]\nversion = 2\n[profiles.last]\n",
        "active_profile = \"first\"\nactive_profile = \"last\"\n" ++
            "[profiles.first]\nusername = \"fake-user\"\ntoken = \"old\"\ntoken = \"new\"\nworkspace = \"ws\"\n" ++
            "[profiles.last]\nusername = \"other-user\"\ntoken = \"other-token\"\nworkspace = \"other-ws\"\n",
        "[profiles.p0]\n[profiles.p1]\n[profiles.p2]\n[profiles.p3]\n" ++
            "[profiles.p4]\n[profiles.p5]\n[profiles.p6]\n[profiles.p7]\n" ++
            "[profiles.p8]\n[profiles.p9]\n[profiles.p10]\n[profiles.p11]\n",
    };
    for (sources) |source| {
        try testing.checkAllAllocationFailures(testing.allocator, checkParseAllocations, .{ source, false });
    }
    for ([_][]const u8{
        "active_profile = \"work\"\n[profiles.work]\nusername = \"fake-user\"\ntoken = \"fake\"oops\"\n",
        "[profiles.work]\nusername = \"fake-user\"\ntoken = \"\"\n",
        "active_profile = \"work\"\nactive_profile = \"-bad\"\n",
    }) |source| {
        try testing.checkAllAllocationFailures(testing.allocator, checkParseAllocations, .{ source, true });
    }
}

test "parse retains empty profiles and rejects malformed known values" {
    var file = try parse(
        testing.allocator,
        "active_profile = \"mine\"\n[profiles.empty]\n[future]\nactive_profile = \"work\"\n" ++
            "[profiles.mine]\nusername = \"fake-user\"\n",
    );
    defer file.deinit(testing.allocator);
    try testing.expectEqualStrings("mine", file.active_profile);
    try testing.expectEqual(@as(usize, 2), file.profiles.len);
    try testing.expectEqualStrings("", file.find("empty").?.username);
    try testing.expectEqualStrings("", file.find("mine").?.token);
    for ([_][]const u8{
        "[profiles.]",
        "[profiles.bad.name]",
        "[profiles.work",
        "[profiles.work]\nusername = 2",
        "[profiles.work]\ntoken = true",
        "[profiles.work]\nworkspace = []",
        "[profiles.work]\ntoken = \"a\"b\"",
        "[profiles.work]\ntoken = \"unterminated",
        "[profiles.work]\ntoken = \"unsupported\\n\"",
    }) |source| {
        try testing.expectError(error.InvalidAuthFile, parse(testing.allocator, source));
    }
}

test "parser and serializer reject controls but allow a literal tab" {
    var source = "[profiles.default]\ntoken = \"a?b\"".*;
    var token = "a?b".*;
    for (0..0x80) |byte| {
        if (byte >= 0x20 and byte != 0x7f) continue;
        if (byte == '\t') continue;
        source[source.len - 3] = @intCast(byte);
        token[1] = @intCast(byte);
        try testing.expectError(error.InvalidAuthFile, parse(testing.allocator, &source));
        try testing.expectError(error.InvalidAuthFile, serialize(testing.allocator, "default", &.{.{
            .name = "default",
            .username = "fake-user",
            .token = &token,
            .workspace = "ws",
        }}));
    }
}

test "serialization round-trips quotes backslashes tabs and comment markers" {
    const profile: ProfileView = .{
        .name = "default",
        .username = "fake\t\"user\\name#",
        .token = "\\\"fake\t#token",
        .workspace = "ws",
    };
    const source = try serialize(testing.allocator, "default", &.{profile});
    defer testing.allocator.free(source);
    var file = try parse(testing.allocator, source);
    defer file.deinit(testing.allocator);
    const saved = file.find("default").?;
    try testing.expectEqualStrings(profile.username, saved.username);
    try testing.expectEqualStrings(profile.token, saved.token);
    try testing.expectEqualStrings(profile.workspace, saved.workspace);

    var crlf = try parse(testing.allocator, "[profiles.default]\r\ntoken = \"fake\tvalue\" # comment\r\n");
    defer crlf.deinit(testing.allocator);
    try testing.expectEqualStrings("fake\tvalue", crlf.find("default").?.token);
}

test "parse diagnostics give exact positions without source or Credential values" {
    const cases = [_]struct { source: []const u8, line: usize, column: usize }{
        .{ .source = "# comment\n  [profiles.bad name]\n", .line = 2, .column = 13 },
        .{ .source = "[profiles.default]\n    token = 2\n", .line = 2, .column = 13 },
        .{ .source = "  [profiles.default]\n  token = \"fake\"oops\"\n", .line = 2, .column = 16 },
        .{ .source = "[profiles.default]\ntoken = \"fake", .line = 2, .column = 14 },
        .{ .source = "[profiles.default]\ntoken = \"a\x00b\"", .line = 2, .column = 11 },
        .{ .source = "active_profile = \"-bad\"", .line = 1, .column = 18 },
    };
    for (cases) |case| {
        var location: ParseLocation = .{};
        try testing.expectError(error.InvalidAuthFile, parseWithLocation(testing.allocator, case.source, &location));
        try testing.expectEqual(case.line, location.line);
        try testing.expectEqual(case.column, location.column);
    }
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeParseDiagnostic(&writer, "/data/bbr/auth.toml", .{ .line = 2, .column = 16 });
    try testing.expectEqualStrings("/data/bbr/auth.toml:2:16: invalid auth file\n", writer.buffered());
}

test "save rejects oversized output before creating directories and retains prior data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/new", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    var profile: ProfileView = .{ .name = "default", .username = "fake-user", .token = "t", .workspace = "ws" };
    const small = try serialize(testing.allocator, "default", &.{profile});
    defer testing.allocator.free(small);
    const token = try testing.allocator.alloc(u8, max_auth_file_size - small.len + 2);
    defer testing.allocator.free(token);
    @memset(token, 'x');
    profile.token = token;
    try testing.expectError(error.InvalidAuthFile, save(testing.allocator, testing.io, &env, "default", &.{profile}));
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(testing.io, "new", .{}));

    profile.token = "t";
    const path = try save(testing.allocator, testing.io, &env, "default", &.{profile});
    defer testing.allocator.free(path);
    profile.token = token;
    try testing.expectError(error.InvalidAuthFile, save(testing.allocator, testing.io, &env, "default", &.{profile}));
    const retained = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(max_auth_file_size + 1));
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings(small, retained);

    // Exactly 64 KiB remains writable and loadable.
    profile.token = token[0 .. token.len - 1];
    const boundary_path = try save(testing.allocator, testing.io, &env, "default", &.{profile});
    defer testing.allocator.free(boundary_path);
    var loaded = (try load(testing.allocator, testing.io, &env)).?;
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings(profile.token, loaded.file.find("default").?.token);
}

test "load classifies corrupt and oversized files as InvalidAuthFile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    try testing.expect(try load(testing.allocator, testing.io, &env) == null);
    var dir = try tmp.dir.createDirPathOpen(testing.io, "bbr", .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = "auth.toml", .data = "[profiles.default]\n token = \"fake\"oops\"\n" });
    try testing.expectError(error.InvalidAuthFile, load(testing.allocator, testing.io, &env));
    const oversized = try testing.allocator.alloc(u8, max_auth_file_size + 2);
    defer testing.allocator.free(oversized);
    @memset(oversized, ' ');
    for ([_][]const u8{ oversized[0 .. max_auth_file_size + 1], oversized }) |source| {
        try dir.writeFile(testing.io, .{ .sub_path = "auth.toml", .data = source });
        try testing.expectError(error.InvalidAuthFile, load(testing.allocator, testing.io, &env));
    }
}

test "resolve fills missing Profile fields from the environment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    try env.put("BITBUCKET_TOKEN", "fake-env-token");
    try env.put("BITBUCKET_WORKSPACE", "env-ws");
    var dir = try tmp.dir.createDirPathOpen(testing.io, "bbr", .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = "auth.toml", .data = "[profiles.default]\nusername = \"fake-file-user\"\n" });
    var credential = try resolve(testing.allocator, testing.io, &env, null);
    defer credential.deinit(testing.allocator);
    try testing.expectEqualStrings("fake-file-user", credential.username);
    try testing.expectEqualStrings("fake-env-token", credential.token);
    try testing.expectEqualStrings("env-ws", credential.workspace);
}

test "upsert and logout preserve unrelated incomplete Profiles and environment filling" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    var dir = try tmp.dir.createDirPathOpen(testing.io, "bbr", .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{
        .sub_path = "auth.toml",
        .data = "active_profile = \"work\"\n[profiles.empty]\n" ++
            "[profiles.partial]\ntoken = \"partial-token\"\n" ++
            "[profiles.work]\nusername = \"fake-user\"\ntoken = \"fake-token\"\nworkspace = \"ws\"\n",
    });
    const path = try upsertProfile(testing.allocator, testing.io, &env, "new", .{
        .username = "new-user",
        .token = "new-token",
        .workspace = "new-ws",
    });
    defer testing.allocator.free(path);
    {
        var loaded = (try load(testing.allocator, testing.io, &env)).?;
        defer loaded.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 4), loaded.file.profiles.len);
        try testing.expectEqualStrings("new", loaded.file.active_profile);
        try testing.expectEqualStrings("", loaded.file.find("empty").?.username);
        try testing.expectEqualStrings("", loaded.file.find("partial").?.workspace);
        try testing.expectEqualStrings("partial-token", loaded.file.find("partial").?.token);
    }
    try testing.expect(try removeProfile(testing.allocator, testing.io, &env, "work"));
    try testing.expect(try removeProfile(testing.allocator, testing.io, &env, "new"));
    {
        var loaded = (try load(testing.allocator, testing.io, &env)).?;
        defer loaded.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), loaded.file.profiles.len);
        try testing.expectEqualStrings("empty", loaded.file.active_profile);
        try testing.expectEqualStrings("", loaded.file.find("empty").?.token);
        try testing.expectEqualStrings("partial-token", loaded.file.find("partial").?.token);
    }
    try env.put("BITBUCKET_USERNAME", "env-user");
    try env.put("BITBUCKET_WORKSPACE", "env-ws");
    var partial = try resolve(testing.allocator, testing.io, &env, "partial");
    defer partial.deinit(testing.allocator);
    try testing.expectEqualStrings("env-user", partial.username);
    try testing.expectEqualStrings("partial-token", partial.token);
    try testing.expectEqualStrings("env-ws", partial.workspace);
    try env.put("BITBUCKET_TOKEN", "env-token");
    var empty = try resolve(testing.allocator, testing.io, &env, null);
    defer empty.deinit(testing.allocator);
    try testing.expectEqualStrings("env-user", empty.username);
    try testing.expectEqualStrings("env-token", empty.token);
    try testing.expectEqualStrings("env-ws", empty.workspace);
}

test "upsert rejects incomplete new and replacement Credentials without changing the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    const invalid = [_]struct { credential: Credential, err: anyerror }{
        .{ .credential = .{ .username = "", .token = "fake-token", .workspace = "ws" }, .err = error.MissingUsername },
        .{ .credential = .{ .username = "fake-user", .token = "", .workspace = "ws" }, .err = error.MissingToken },
        .{ .credential = .{ .username = "fake-user", .token = "fake-token", .workspace = "" }, .err = error.MissingWorkspace },
    };
    for (invalid) |case| {
        try testing.expectError(case.err, upsertProfile(testing.allocator, testing.io, &env, "work", case.credential));
    }
    try testing.expect(try load(testing.allocator, testing.io, &env) == null);
    const path = try upsertProfile(testing.allocator, testing.io, &env, "work", .{
        .username = "fake-user",
        .token = "fake-token",
        .workspace = "ws",
    });
    defer testing.allocator.free(path);
    for (invalid) |case| {
        try testing.expectError(case.err, upsertProfile(testing.allocator, testing.io, &env, "work", case.credential));
    }
    var loaded = (try load(testing.allocator, testing.io, &env)).?;
    defer loaded.deinit(testing.allocator);
    const work = loaded.file.find("work").?;
    try testing.expectEqualStrings("fake-user", work.username);
    try testing.expectEqualStrings("fake-token", work.token);
    try testing.expectEqualStrings("ws", work.workspace);
}

test "resolve merges env over file per field" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const base = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(base);
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    try env.put("BITBUCKET_TOKEN", "env-token");

    const path = try upsertProfile(testing.allocator, io, &env, "default", .{
        .username = "file-user",
        .token = "file-token",
        .workspace = "file-ws",
    });
    defer testing.allocator.free(path);

    var cred = try resolve(testing.allocator, io, &env, null);
    defer cred.deinit(testing.allocator);
    try testing.expectEqualStrings("file-user", cred.username);
    try testing.expectEqualStrings("env-token", cred.token);
    try testing.expectEqualStrings("file-ws", cred.workspace);
    try testing.expectEqualStrings("default", cred.profile);
}

test "resolve reports the missing field" {
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    // No data home, no env: the file cannot exist and every field is missing.
    try testing.expectError(error.MissingUsername, resolve(testing.allocator, testing.io, &env, null));
    try env.put("BITBUCKET_USERNAME", "u");
    try testing.expectError(error.MissingToken, resolve(testing.allocator, testing.io, &env, null));
}
