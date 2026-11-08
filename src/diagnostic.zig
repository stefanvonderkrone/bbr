const std = @import("std");

pub const Operation = enum {
    startup,
    arguments,
    configuration,
    auth,
    api,
    http,
    bitbucket,
    git,
    persistence,
    submission_lock,
    session_load,
    picker_list,
    recovery_check,
    duplicate_check,
    submission,
    mutation,
    verdict,
    file_enrichment,
    highlighting,
    buffer_build,
    buffer_search,
    review_search,
    composer,
    help,
    clipboard,
    external_edit,
    terminal,
    grammar,
    completion,
    diagnostics,
};

pub const Phase = enum {
    execute,
    launch,
    decode,
    validate,
    read,
    write,
    prepare,
    cleanup,
    post,
    admission,
    proxy,
    uri,
    connect,
    send_body,
    receive_head,
    receive_body,
    rejection,
    open,
    exec,
    bind,
    step,
    reset,
    finalize,
    close,
    query,
    fallback,
};

pub const Context = struct {
    command_id: ?u64 = null,
    work_id: ?u64 = null,
    session_epoch: ?u64 = null,
    operation_id: ?u64 = null,
    draft_id: ?u64 = null,
    file_index: ?usize = null,
    side: ?enum { old, new } = null,
    attempt: ?u32 = null,
    page: ?u32 = null,
};

pub const HttpClass = enum { authentication, authorization, rate_limit, server, validation, not_found, conflict, other };
pub const Cause = union(enum) {
    zig: anyerror,
    http: struct { status: u16, classification: HttpClass },
    git: struct { kind: enum { exited, signal, stopped, unknown }, code: u32 },
    sqlite: struct { result: i32, extended: i32 },
    grammar: struct { rule: GrammarRule, code: u32 = 0, offset: u32 },
};

/// `query` carries a Tree-sitter query error code and `regex` a regex engine code.
/// The other rules have no code.
pub const GrammarRule = enum { query, regex, unknown_operator, unsupported_directive, malformed_arguments, unsupported_property };

pub const Failure = struct {
    operation: Operation,
    phase: Phase,
    context: Context,
    cause: Cause,
    source: struct { file: []const u8, line: u32, column: u32 },

    pub fn capture(operation: Operation, phase: Phase, context: Context, cause: Cause, comptime source: std.builtin.SourceLocation) Failure {
        return .{
            .operation = operation,
            .phase = phase,
            .context = context,
            .cause = cause,
            .source = .{ .file = source.file, .line = source.line, .column = source.column },
        };
    }

    /// Whether the cause is `error.Reported`, the marker of a failure that a layer below
    /// recorded. `diagnostics.Handle.record` drops such a Failure, so the failure keeps
    /// exactly one record.
    pub fn reported(self: Failure) bool {
        return switch (self.cause) {
            .zig => |err| switch (err) {
                error.Reported => true,
                else => false,
            },
            .http, .git, .sqlite, .grammar => false,
        };
    }
};

pub const State = union(enum) {
    off,
    on,
    unavailable: Failure,
};

fn assertSafe(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| assertSafe(field.type),
        .@"union" => |info| inline for (info.fields) |field| assertSafe(field.type),
        .optional => |info| assertSafe(info.child),
        .int, .@"enum", .error_set, .void => {},
        else => @compileError("diagnostic evidence must contain only closed causes and numeric identities"),
    }
}

comptime {
    assertSafe(Context);
    assertSafe(Cause);
}
