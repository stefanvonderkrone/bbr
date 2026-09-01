const std = @import("std");

pub const Explicit = struct {
    epoch: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    sequence: ?[]const u8 = null,
    dirty: ?[]const u8 = null,

    pub fn active(self: Explicit) bool {
        return self.epoch != null or self.commit != null or self.sequence != null or self.dirty != null;
    }
};

pub const Git = struct {
    epoch: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub fn resolve(allocator: std.mem.Allocator, explicit: Explicit, git: Git) ![]u8 {
    const metadata = if (explicit.active())
        try explicitMetadata(explicit)
    else
        try gitMetadata(git);
    return format(allocator, metadata);
}

const Metadata = struct {
    epoch_seconds: u64,
    commit: []const u8,
    sequence: u64,
    dirty: bool,
};

fn explicitMetadata(explicit: Explicit) !Metadata {
    const epoch_text = explicit.epoch orelse return error.IncompleteExplicitMetadata;
    const commit = explicit.commit orelse return error.IncompleteExplicitMetadata;
    const sequence_text = explicit.sequence orelse return error.IncompleteExplicitMetadata;
    const dirty_text = explicit.dirty orelse return error.IncompleteExplicitMetadata;
    const epoch_seconds = try parseEpoch(epoch_text);
    const sequence = parseCanonicalUnsigned(sequence_text) catch return error.InvalidSequence;
    try validateCommit(commit);
    const dirty = if (std.mem.eql(u8, dirty_text, "0"))
        false
    else if (std.mem.eql(u8, dirty_text, "1"))
        true
    else
        return error.InvalidDirty;
    return .{ .epoch_seconds = epoch_seconds, .commit = commit, .sequence = sequence, .dirty = dirty };
}

fn gitMetadata(git: Git) !Metadata {
    const epoch_text = git.epoch orelse return error.MissingGitMetadata;
    const commit = git.commit orelse return error.MissingGitMetadata;
    const tags = git.tags orelse return error.MissingGitMetadata;
    const status = git.status orelse return error.MissingGitMetadata;
    const epoch_seconds = try parseEpoch(std.mem.trim(u8, epoch_text, " \t\r\n"));
    const trimmed_commit = std.mem.trim(u8, commit, " \t\r\n");
    try validateCommit(trimmed_commit);

    const date = dateFromEpoch(epoch_seconds);
    var sequence: u64 = 0;
    var found_release = false;
    var lines = std.mem.splitScalar(u8, tags, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidGitTagData;
        const name = line[0..separator];
        if (!std.mem.startsWith(u8, name, "v")) continue;
        if (found_release) return error.ConflictingReleaseTags;
        if (!std.mem.eql(u8, line[separator + 1 ..], "tag")) return error.ReleaseTagMustBeAnnotated;
        sequence = try parseReleaseTag(name, date);
        found_release = true;
    }
    return .{
        .epoch_seconds = epoch_seconds,
        .commit = trimmed_commit,
        .sequence = sequence,
        .dirty = std.mem.trim(u8, status, " \t\r\n").len != 0,
    };
}

const Date = struct { year: u16, month: u4, day: u5 };

fn dateFromEpoch(epoch_seconds: u64) Date {
    const epoch_day = (std.time.epoch.EpochSeconds{ .secs = epoch_seconds }).getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{ .year = year_day.year, .month = month_day.month.numeric(), .day = month_day.day_index + 1 };
}

fn format(allocator: std.mem.Allocator, metadata: Metadata) ![]u8 {
    const date = dateFromEpoch(metadata.epoch_seconds);
    const dirty_suffix: []const u8 = if (metadata.dirty) ".dirty" else "";
    const version = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{d}+g{s}{s}", .{
        date.year,
        date.month,
        date.day,
        metadata.sequence,
        metadata.commit[0..12],
        dirty_suffix,
    });
    errdefer allocator.free(version);
    _ = std.SemanticVersion.parse(version) catch return error.InvalidFormattedVersion;
    return version;
}

fn validateCommit(commit: []const u8) !void {
    if (commit.len != 40) return error.InvalidCommit;
    for (commit) |character| {
        if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) return error.InvalidCommit;
    }
}

fn parseEpoch(text: []const u8) !u64 {
    const epoch_seconds = std.fmt.parseInt(u64, text, 10) catch return error.InvalidEpoch;
    if (epoch_seconds > 253402300799) return error.InvalidEpoch;
    return epoch_seconds;
}

fn parseCanonicalUnsigned(text: []const u8) !u64 {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidUnsigned;
    for (text) |character| if (!std.ascii.isDigit(character)) return error.InvalidUnsigned;
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidUnsigned;
}

fn parseReleaseTag(tag: []const u8, expected_date: Date) !u64 {
    var version_parts = std.mem.splitScalar(u8, tag[1..], '-');
    const date_text = version_parts.next() orelse return error.InvalidReleaseTag;
    const sequence_text = version_parts.next() orelse return error.InvalidReleaseTag;
    if (version_parts.next() != null) return error.InvalidReleaseTag;

    var date_parts = std.mem.splitScalar(u8, date_text, '.');
    const year = parseCanonicalUnsigned(date_parts.next() orelse return error.InvalidReleaseTag) catch return error.InvalidReleaseTag;
    const month = parseCanonicalUnsigned(date_parts.next() orelse return error.InvalidReleaseTag) catch return error.InvalidReleaseTag;
    const day = parseCanonicalUnsigned(date_parts.next() orelse return error.InvalidReleaseTag) catch return error.InvalidReleaseTag;
    if (date_parts.next() != null) return error.InvalidReleaseTag;
    const sequence = parseCanonicalUnsigned(sequence_text) catch return error.InvalidReleaseTag;
    if (sequence == 0) return error.InvalidReleaseTag;
    if (year != expected_date.year or month != expected_date.month or day != expected_date.day) return error.ReleaseTagDateMismatch;
    return sequence;
}

test "explicit development metadata produces a semantic CalVer" {
    const actual = try resolve(std.testing.allocator, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .sequence = "0",
        .dirty = "0",
    }, .{});
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("2024.3.24-0+g0123456789ab", actual);
    _ = try std.SemanticVersion.parse(actual);
}

test "explicit release and dirty metadata produce semantic CalVer values" {
    const release = try resolve(std.testing.allocator, .{
        .epoch = "1711283696",
        .commit = "abcdef0123456789abcdef0123456789abcdef01",
        .sequence = "2",
        .dirty = "0",
    }, .{});
    defer std.testing.allocator.free(release);
    try std.testing.expectEqualStrings("2024.3.24-2+gabcdef012345", release);
    _ = try std.SemanticVersion.parse(release);

    const dirty = try resolve(std.testing.allocator, .{
        .epoch = "1711283696",
        .commit = "abcdef0123456789abcdef0123456789abcdef01",
        .sequence = "2",
        .dirty = "1",
    }, .{});
    defer std.testing.allocator.free(dirty);
    try std.testing.expectEqualStrings("2024.3.24-2+gabcdef012345.dirty", dirty);
    _ = try std.SemanticVersion.parse(dirty);
}

test "any explicit field requires all explicit metadata" {
    const valid_git: Git = .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "",
        .status = "",
    };
    try std.testing.expectError(error.IncompleteExplicitMetadata, resolve(std.testing.allocator, .{ .epoch = "1711283696" }, valid_git));
    try std.testing.expectError(error.IncompleteExplicitMetadata, resolve(std.testing.allocator, .{ .commit = "0123456789abcdef0123456789abcdef01234567" }, valid_git));
    try std.testing.expectError(error.IncompleteExplicitMetadata, resolve(std.testing.allocator, .{ .sequence = "0" }, valid_git));
    try std.testing.expectError(error.IncompleteExplicitMetadata, resolve(std.testing.allocator, .{ .dirty = "0" }, valid_git));
}

test "explicit metadata rejects invalid values" {
    const valid: Explicit = .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .sequence = "0",
        .dirty = "0",
    };
    try std.testing.expectError(error.InvalidEpoch, resolve(std.testing.allocator, .{
        .epoch = "-1",
        .commit = valid.commit,
        .sequence = valid.sequence,
        .dirty = valid.dirty,
    }, .{}));
    try std.testing.expectError(error.InvalidEpoch, resolve(std.testing.allocator, .{
        .epoch = "253402300800",
        .commit = valid.commit,
        .sequence = valid.sequence,
        .dirty = valid.dirty,
    }, .{}));
    try std.testing.expectError(error.InvalidCommit, resolve(std.testing.allocator, .{
        .epoch = valid.epoch,
        .commit = "0123456789abcdef0123456789abcdef0123456",
        .sequence = valid.sequence,
        .dirty = valid.dirty,
    }, .{}));
    try std.testing.expectError(error.InvalidCommit, resolve(std.testing.allocator, .{
        .epoch = valid.epoch,
        .commit = "0123456789abcdef0123456789abcdef0123456G",
        .sequence = valid.sequence,
        .dirty = valid.dirty,
    }, .{}));
    try std.testing.expectError(error.InvalidSequence, resolve(std.testing.allocator, .{
        .epoch = valid.epoch,
        .commit = valid.commit,
        .sequence = "01",
        .dirty = valid.dirty,
    }, .{}));
    try std.testing.expectError(error.InvalidDirty, resolve(std.testing.allocator, .{
        .epoch = valid.epoch,
        .commit = valid.commit,
        .sequence = valid.sequence,
        .dirty = "2",
    }, .{}));
}

test "Git metadata supports untagged and annotated release identities" {
    const development = try resolve(std.testing.allocator, .{}, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "docs-only\tcommit\n",
        .status = "",
    });
    defer std.testing.allocator.free(development);
    try std.testing.expectEqualStrings("2024.3.24-0+g0123456789ab", development);

    const release = try resolve(std.testing.allocator, .{}, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "v2024.3.24-3\ttag\n",
        .status = "",
    });
    defer std.testing.allocator.free(release);
    try std.testing.expectEqualStrings("2024.3.24-3+g0123456789ab", release);
    _ = try std.SemanticVersion.parse(release);
}

test "Git metadata rejects malformed conflicting and lightweight release tags" {
    const base: Git = .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .status = "",
    };
    try std.testing.expectError(error.InvalidReleaseTag, resolve(std.testing.allocator, .{}, .{
        .epoch = base.epoch,
        .commit = base.commit,
        .tags = "v2024.03.24-1\ttag\n",
        .status = base.status,
    }));
    try std.testing.expectError(error.ReleaseTagDateMismatch, resolve(std.testing.allocator, .{}, .{
        .epoch = base.epoch,
        .commit = base.commit,
        .tags = "v2024.3.25-1\ttag\n",
        .status = base.status,
    }));
    try std.testing.expectError(error.ReleaseTagMustBeAnnotated, resolve(std.testing.allocator, .{}, .{
        .epoch = base.epoch,
        .commit = base.commit,
        .tags = "v2024.3.24-1\tcommit\n",
        .status = base.status,
    }));
    try std.testing.expectError(error.ConflictingReleaseTags, resolve(std.testing.allocator, .{}, .{
        .epoch = base.epoch,
        .commit = base.commit,
        .tags = "v2024.3.24-1\ttag\nv2024.3.24-2\ttag\n",
        .status = base.status,
    }));
}

test "Git metadata requires every Git value" {
    try std.testing.expectError(error.MissingGitMetadata, resolve(std.testing.allocator, .{}, .{}));
    try std.testing.expectError(error.MissingGitMetadata, resolve(std.testing.allocator, .{}, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "",
    }));
}

test "Git status marks only supplied build-input changes dirty" {
    const clean = try resolve(std.testing.allocator, .{}, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "",
        .status = "",
    });
    defer std.testing.allocator.free(clean);
    const tracked = try resolve(std.testing.allocator, .{}, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "",
        .status = " M src/main.zig\n",
    });
    defer std.testing.allocator.free(tracked);
    const untracked = try resolve(std.testing.allocator, .{}, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "",
        .status = "?? tests/new.zig\n",
    });
    defer std.testing.allocator.free(untracked);

    try std.testing.expect(!std.mem.endsWith(u8, clean, ".dirty"));
    try std.testing.expect(std.mem.endsWith(u8, tracked, ".dirty"));
    try std.testing.expect(std.mem.endsWith(u8, untracked, ".dirty"));
}

test "every selected Git build-input class marks metadata dirty" {
    const statuses = [_][]const u8{
        " M build.zig\n",
        " M build.zig.zon\n",
        "?? build/generated.zig\n",
        " M src/main.zig\n",
        "?? tests/new.zig\n",
        " M vendors/sqlite/sqlite3.c\n",
        " M .github/workflows/ci.yml\n",
    };
    for (statuses) |status| {
        const version = try resolve(std.testing.allocator, .{}, .{
            .epoch = "1711283696",
            .commit = "0123456789abcdef0123456789abcdef01234567",
            .tags = "",
            .status = status,
        });
        defer std.testing.allocator.free(version);
        try std.testing.expect(std.mem.endsWith(u8, version, ".dirty"));
    }
}

test "epoch identity ignores wall clock and time zone and reproduces across sources" {
    const explicit = try resolve(std.testing.allocator, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .sequence = "0",
        .dirty = "0",
    }, .{});
    defer std.testing.allocator.free(explicit);
    const git = try resolve(std.testing.allocator, .{}, .{
        .epoch = "1711283696",
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .tags = "",
        .status = "",
    });
    defer std.testing.allocator.free(git);

    try std.testing.expectEqualStrings(explicit, git);
    try std.testing.expectEqualStrings("2024.3.24-0+g0123456789ab", git);
}
