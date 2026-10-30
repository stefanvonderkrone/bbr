//! C-free Grammar name aliases shared by ReviewBody fences and Injection.

const std = @import("std");

const aliases = [_]struct { []const u8, []const u8 }{
    .{ "tsx", "tsx" },     .{ "typescript", "ts" },     .{ "ts", "ts" },                 .{ "mts", "ts" },
    .{ "cts", "ts" },      .{ "javascript", "js" },     .{ "js", "js" },                 .{ "jsx", "js" },
    .{ "mjs", "js" },      .{ "cjs", "js" },            .{ "css", "css" },               .{ "go", "go" },
    .{ "golang", "go" },   .{ "bash", "sh" },           .{ "sh", "sh" },                 .{ "shell", "sh" },
    .{ "json", "json" },   .{ "yaml", "yaml" },         .{ "yml", "yaml" },              .{ "python", "py" },
    .{ "py", "py" },       .{ "ruby", "rb" },           .{ "rb", "rb" },                 .{ "rust", "rs" },
    .{ "rs", "rs" },       .{ "c", "c" },               .{ "cpp", "cpp" },               .{ "c++", "cpp" },
    .{ "cxx", "cpp" },     .{ "csharp", "cs" },         .{ "c#", "cs" },                 .{ "cs", "cs" },
    .{ "c_sharp", "cs" },  .{ "java", "java" },         .{ "kotlin", "kt" },             .{ "html", "html" },
    .{ "xml", "xml" },     .{ "sql", "sql" },           .{ "zig", "zig" },               .{ "make", "mk" },
    .{ "makefile", "mk" }, .{ "docker", "dockerfile" }, .{ "dockerfile", "dockerfile" }, .{ "markdown", "md" },
    .{ "md", "md" },
};

/// The file extension, without its dot, for a lower-case Grammar name.
pub fn extension(lower_name: []const u8) ?[]const u8 {
    for (aliases) |alias| if (std.mem.eql(u8, lower_name, alias[0])) return alias[1];
    return null;
}
