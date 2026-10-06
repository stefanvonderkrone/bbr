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
fn parseBasicString(allocator: Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return error.InvalidAuthFile;
    const inner = trimmed[1 .. trimmed.len - 1];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c == '\\') {
            i += 1;
            if (i >= inner.len) return error.InvalidAuthFile;
            switch (inner[i]) {
                '"', '\\' => try out.append(allocator, inner[i]),
                else => return error.InvalidAuthFile,
            }
            i += 1;
        } else if (c == '\n' or c == '\r') {
            return error.InvalidAuthFile;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn escapeInto(buf: *std.ArrayList(u8), allocator: Allocator, raw: []const u8) !void {
    for (raw) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n', '\r' => return error.InvalidAuthFile,
        else => try buf.append(allocator, c),
    };
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

    // Index into `profiles` of the table the current keys belong to, if any.
    var current: ?usize = null;
    // Scratch storage for a `[profiles.x]` header seen before its first key.
    var pending: ?[]u8 = null;
    defer if (pending) |p| allocator.free(p);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = stripTrailingComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            current = null;
            if (pending) |p| {
                allocator.free(p);
                pending = null;
            }
            if (!std.mem.endsWith(u8, line, "]")) return error.InvalidAuthFile;
            const header = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            const prefix = "profiles.";
            if (std.mem.startsWith(u8, header, prefix)) {
                const name = std.mem.trim(u8, header[prefix.len..], " \t");
                if (!isValidProfileName(name)) return error.InvalidAuthFile;
                if (findIndex(profiles.items, name)) |idx| {
                    current = idx;
                } else {
                    pending = try allocator.dupe(u8, name);
                }
            }
            // Unknown tables are ignored.
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidAuthFile;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.InvalidAuthFile;
        for (key) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
            else => return error.InvalidAuthFile,
        };
        const value = try parseBasicString(allocator, line[eq + 1 ..]);
        if (value.len == 0) {
            allocator.free(value);
            // Empty values are only rejected for known keys; unknown keys
            // with empty values are ignored like any other unknown key.
            const known = std.mem.eql(u8, key, "active_profile") or
                std.mem.eql(u8, key, "username") or
                std.mem.eql(u8, key, "token") or
                std.mem.eql(u8, key, "workspace");
            if (known) return error.InvalidAuthFile;
            continue;
        }

        if (current == null and pending == null) {
            // Top-level table.
            if (std.mem.eql(u8, key, "active_profile")) {
                if (!isValidProfileName(value)) {
                    allocator.free(value);
                    return error.InvalidAuthFile;
                }
                if (active) |a| allocator.free(a);
                active = value;
            } else {
                allocator.free(value);
            }
            continue;
        }
        if (std.mem.eql(u8, key, "username") or
            std.mem.eql(u8, key, "token") or
            std.mem.eql(u8, key, "workspace"))
        {
            const idx: usize = if (current) |i| i else blk: {
                const name = pending.?;
                try profiles.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .username = try allocator.dupe(u8, ""),
                    .token = try allocator.dupe(u8, ""),
                    .workspace = try allocator.dupe(u8, ""),
                });
                allocator.free(pending.?);
                pending = null;
                current = profiles.items.len - 1;
                break :blk current.?;
            };
            const slot: *[]const u8 = if (std.mem.eql(u8, key, "username"))
                &profiles.items[idx].username
            else if (std.mem.eql(u8, key, "token"))
                &profiles.items[idx].token
            else
                &profiles.items[idx].workspace;
            allocator.free(slot.*);
            slot.* = value;
        } else {
            allocator.free(value);
        }
    }

    // A header with no keys still declares the profile (with empty fields,
    // which `resolve` treats as missing, fillable from the environment).
    if (pending) |name| {
        try profiles.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .username = try allocator.dupe(u8, ""),
            .token = try allocator.dupe(u8, ""),
            .workspace = try allocator.dupe(u8, ""),
        });
        allocator.free(pending.?);
        pending = null;
    }

    return .{
        .active_profile = active orelse try allocator.dupe(u8, default_profile),
        .profiles = try profiles.toOwnedSlice(allocator),
    };
}

fn findIndex(profiles: []const NamedProfile, name: []const u8) ?usize {
    for (profiles, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return null;
}

/// Serialize profiles to `auth.toml` source. Caller owns the result.
pub fn serialize(allocator: Allocator, active_profile: []const u8, profiles: []const ProfileView) ![]u8 {
    if (!isValidProfileName(active_profile)) return error.InvalidProfileName;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "active_profile = \"");
    try escapeInto(&buf, allocator, active_profile);
    try buf.appendSlice(allocator, "\"\n");
    for (profiles) |p| {
        if (!isValidProfileName(p.name)) return error.InvalidProfileName;
        if (p.username.len == 0) return error.MissingUsername;
        if (p.token.len == 0) return error.MissingToken;
        if (p.workspace.len == 0) return error.MissingWorkspace;
        try buf.appendSlice(allocator, "\n[profiles.");
        try buf.appendSlice(allocator, p.name);
        try buf.appendSlice(allocator, "]\nusername = \"");
        try escapeInto(&buf, allocator, p.username);
        try buf.appendSlice(allocator, "\"\ntoken = \"");
        try escapeInto(&buf, allocator, p.token);
        try buf.appendSlice(allocator, "\"\nworkspace = \"");
        try escapeInto(&buf, allocator, p.workspace);
        try buf.appendSlice(allocator, "\"\n");
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
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 + 1)) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(path);
            return null;
        },
        else => return err,
    };
    defer allocator.free(source);
    if (source.len > 64 * 1024) return error.InvalidAuthFile;
    const file = try parse(allocator, source);
    return .{ .path = path, .file = file };
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
        \\top_level = "ignored"
        \\[other]
        \\x = "1"
        \\[profiles.mine]
        \\username = "a"
        \\custom = "keepable"
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
