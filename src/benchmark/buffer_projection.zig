const std = @import("std");
const bbr = @import("bbr");
const buffer_mod = @import("benchmark_buffer");

pub const name = "buffer_projection_300_files_50000_lines";

pub const Context = struct {
    diff: bbr.diff.Diff,
};

pub fn run(allocator: std.mem.Allocator, context: *const Context) !buffer_mod.Buffer {
    return buffer_mod.build(allocator, context.diff, .unified);
}

pub fn checksum(buffer: buffer_mod.Buffer) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (buffer.rows) |row| {
        hash.update(&.{@intFromEnum(row)});
        switch (row) {
            .file_header => |file| hash.update(file.new_path),
            .hunk_header => |hunk| hash.update(hunk.header),
            .line => |line| hash.update(line.line.text),
            else => {},
        }
    }
    return hash.final();
}
