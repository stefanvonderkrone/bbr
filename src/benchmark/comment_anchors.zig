const std = @import("std");
const bbr = @import("bbr");
const buffer_mod = @import("benchmark_buffer");

pub const DisclosureKey = buffer_mod.DisclosureKey;

pub const Context = struct {
    diff: bbr.diff.Diff,
    threads: []const bbr.review.Thread,
    drafts: []const bbr.review.Draft,
    expanded_disclosures: []const buffer_mod.DisclosureKey,
};

pub fn run(allocator: std.mem.Allocator, context: *const Context) !buffer_mod.Buffer {
    return buffer_mod.buildWithComments(allocator, context.diff, .unified, context.threads, .{
        .drafts = context.drafts,
        .expanded_disclosures = context.expanded_disclosures,
    });
}

pub fn checksum(buffer: buffer_mod.Buffer) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (buffer.rows) |row| {
        hash.update(&.{@intFromEnum(row)});
        switch (row) {
            .file_header => |file| hash.update(file.new_path),
            .hunk_header => |hunk| hash.update(hunk.header),
            .line => |line| hash.update(line.line.text),
            .comment, .draft => |card| {
                hash.update(card.text());
                const id = switch (card.owner) {
                    .comment => |value| value,
                    .draft => |value| value,
                };
                hash.update(std.mem.asBytes(&id));
            },
            else => {},
        }
    }
    for (buffer.file_tallies) |tally| {
        hash.update(std.mem.asBytes(&tally.comments));
        hash.update(std.mem.asBytes(&tally.drafts));
    }
    return hash.final();
}
