const std = @import("std");
const bbr = @import("bbr");
const buffer_mod = @import("benchmark_tui").buffer;

pub const name = "buffer_projection_300_files_50000_lines";

pub const Context = struct {
    diff: bbr.diff.Diff,
};

pub fn run(allocator: std.mem.Allocator, context: *const Context) !buffer_mod.Buffer {
    return buffer_mod.build(allocator, context.diff, .unified);
}

pub fn checksum(buffer: buffer_mod.Buffer) u64 {
    var hash = std.hash.Wyhash.init(0);
    hashScalar(&hash, @intFromEnum(buffer.layout));
    hashScalar(&hash, buffer.rows.len);
    for (buffer.rows) |row| {
        hashScalar(&hash, @intFromEnum(row));
        switch (row) {
            .file_header => |header| {
                hashFile(&hash, header.file);
                hashText(&hash, header.path);
            },
            .hunk_header => |hunk| {
                hashScalar(&hash, hunk.old_start);
                hashScalar(&hash, hunk.old_count);
                hashScalar(&hash, hunk.new_start);
                hashScalar(&hash, hunk.new_count);
                hashText(&hash, hunk.header);
            },
            .status_placeholder => |placeholder| {
                hashFile(&hash, placeholder.file);
                hashContentStatus(&hash, placeholder.old);
                hashContentStatus(&hash, placeholder.new);
            },
            .line => |line| hashLine(&hash, line),
            .line_pair => |pair| {
                hashOptionalLine(&hash, pair.left);
                hashOptionalLine(&hash, pair.right);
            },
            .disclosure => |disclosure| {
                hashDisclosureKey(&hash, disclosure.key);
                hashScalar(&hash, @intFromEnum(disclosure.kind));
                hashScalar(&hash, disclosure.expanded);
                hashScalar(&hash, disclosure.count);
                hashText(&hash, disclosure.path);
            },
            .comment, .draft => |card| hashCard(&hash, card),
            .snapshot => |snapshot| {
                hashScalar(&hash, snapshot.draft.local_id);
                hashText(&hash, snapshot.line);
                hashScalar(&hash, snapshot.selected);
            },
            .section => |section| {
                hashScalar(&hash, @intFromEnum(section.kind));
                hashScalar(&hash, section.count);
                hashText(&hash, section.path);
            },
        }
    }
    hashScalar(&hash, buffer.row_kinds.len);
    for (buffer.row_kinds) |kind| hashScalar(&hash, @intFromEnum(kind));
    hashScalar(&hash, buffer.file_tallies.len);
    for (buffer.file_tallies) |tally| {
        hashScalar(&hash, tally.comments);
        hashScalar(&hash, tally.drafts);
    }
    hashScalar(&hash, buffer.file_rows.len);
    for (buffer.file_rows) |file_row| {
        hashScalar(&hash, file_row.file_index);
        hashScalar(&hash, file_row.first_row);
    }
    return hash.final();
}

fn hashScalar(hash: *std.hash.Wyhash, value: anytype) void {
    hash.update(std.mem.asBytes(&value));
}

fn hashText(hash: *std.hash.Wyhash, text: []const u8) void {
    hashScalar(hash, text.len);
    hash.update(text);
}

fn hashFile(hash: *std.hash.Wyhash, file: *const bbr.diff.File) void {
    hashText(hash, file.old_path);
    hashText(hash, file.new_path);
    hashScalar(hash, @intFromEnum(file.status));
}

fn hashContentStatus(hash: *std.hash.Wyhash, status: ?buffer_mod.VersionContentState) void {
    const value = status orelse {
        hashScalar(hash, false);
        return;
    };
    hashScalar(hash, true);
    hashScalar(hash, @intFromEnum(value));
    switch (value) {
        .loading => |size| {
            hashOptionalScalar(hash, size);
        },
        .absent, .empty => {},
        .binary => |size| hashOptionalScalar(hash, size),
        .unavailable => |status_value| {
            const unavailable = status_value.unavailable;
            hashOptionalScalar(hash, unavailable.byte_size);
            hashScalar(hash, @intFromEnum(unavailable.reason));
            if (unavailable.reason == .acquisition_failed) hashText(hash, @errorName(unavailable.reason.acquisition_failed));
        },
    }
}

fn hashOptionalScalar(hash: *std.hash.Wyhash, value: anytype) void {
    if (value) |present| {
        hashScalar(hash, true);
        hashScalar(hash, present);
    } else {
        hashScalar(hash, false);
    }
}

fn hashLine(hash: *std.hash.Wyhash, line: buffer_mod.LineRow) void {
    hashScalar(hash, line.line.old_no);
    hashScalar(hash, line.line.new_no);
    hashScalar(hash, @intFromEnum(line.line.kind));
    hashText(hash, line.line.text);
    hashScalar(hash, line.line.in_hunk);
    hashScalar(hash, line.decoration.runs.len);
    for (line.decoration.runs) |decoration_run| {
        hashText(hash, decoration_run.text);
        if (decoration_run.capture) |capture| {
            hashScalar(hash, true);
            hashScalar(hash, capture.id);
            hashScalar(hash, @intFromEnum(capture.role));
        } else {
            hashScalar(hash, false);
        }
        hashScalar(hash, decoration_run.emphasis);
    }
}

fn hashOptionalLine(hash: *std.hash.Wyhash, line: ?buffer_mod.LineRow) void {
    if (line) |present| {
        hashScalar(hash, true);
        hashLine(hash, present);
    } else {
        hashScalar(hash, false);
    }
}

fn hashDisclosureKey(hash: *std.hash.Wyhash, key: buffer_mod.DisclosureKey) void {
    hashScalar(hash, @intFromEnum(key));
    switch (key) {
        .resolved_thread => |id| hashScalar(hash, id),
        .fold => |line| {
            hashScalar(hash, line.old_no);
            hashScalar(hash, line.new_no);
            hashText(hash, line.text);
        },
        .outdated_file, .opposite_version => |file| hashFile(hash, file),
        .outdated_review => {},
        .review_card => |owner| {
            hashScalar(hash, @intFromEnum(owner));
            switch (owner) {
                .comment => |id| hashScalar(hash, id),
                .draft => |id| hashScalar(hash, id),
            }
        },
    }
}

fn hashCard(hash: *std.hash.Wyhash, card: buffer_mod.ReviewCardRow) void {
    hashScalar(hash, @intFromEnum(card.owner));
    switch (card.owner) {
        .comment => |id| hashScalar(hash, id),
        .draft => |id| hashScalar(hash, id),
    }
    hashScalar(hash, @intFromEnum(card.source));
    hashText(hash, card.source.body());
    hashScalar(hash, @intFromEnum(card.role));
    hashScalar(hash, @intFromEnum(card.part));
    hashScalar(hash, card.block_ordinal);
    hashScalar(hash, @intFromEnum(card.block_kind));
    if (card.block_kind == .heading) hashScalar(hash, card.block_kind.heading);
    hashScalar(hash, card.source_range.start);
    hashScalar(hash, card.source_range.end);
    hashScalar(hash, card.segments.len);
    for (card.segments) |segment| {
        hashText(hash, segment.text);
        hashScalar(hash, segment.source.start);
        hashScalar(hash, segment.source.end);
        hashScalar(hash, segment.marks.emphasis);
        hashScalar(hash, segment.marks.strong);
        hashScalar(hash, segment.marks.link_label);
        hashScalar(hash, segment.marks.link_destination);
    }
    hashScalar(hash, card.hidden_rows);
    hashScalar(hash, card.total_rows);
}
