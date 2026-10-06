//! `bbr completion` scripts: static bash/zsh/fish completions generated from
//! the `bbr api` verb table, plus a `--list-profiles` helper for dynamic
//! `--profile` values. Never starts the TUI and never touches the network:
//! scripts print to stdout for `eval` or file install; errors go to stderr.
//!
//! Keep the per-verb flag rows in `api/cli.zig` (`verb_flags`) as the single
//! source of truth — these scripts embed them at comptime.

const std = @import("std");
const bbr = @import("bbr");
const cli = @import("api/cli.zig");

/// User-facing top-level commands offered by the scripts. Mirrors the
/// dispatch in `main.zig` (debug aids like `raw-comments` stay out).
pub const top_commands = [_][]const u8{
    "api",         "completion",        "login",          "logout",
    "local",       "grammar",           "demo",           "check",
    "check-blobs", "check-acquisition", "check-mutation", "check-verdict",
    "detect",
};

pub const usage =
    \\usage: bbr completion (bash|zsh|fish) [--help]
    \\       bbr completion --list-profiles
    \\
    \\Print a shell completion script to stdout. Source it (`eval "$(bbr completion bash)"`)
    \\or save it to your shell's completions directory. `--list-profiles` prints one
    \\saved Profile name per line; the scripts call it for dynamic `--profile` values.
    \\
;

const completion_help =
    \\usage: bbr completion (bash|zsh|fish) [--help]
    \\
    \\Shells:
    \\  bash  eval "$(bbr completion bash)"
    \\  zsh   bbr completion zsh > "${fpath[1]}/_bbr"
    \\  fish  bbr completion fish > ~/.config/fish/completions/bbr.fish
    \\
    \\`bbr completion --list-profiles` prints saved Profile names for the scripts.
    \\
;

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
}

/// Entry from `main.zig`: `bbr completion [...]`. No credentials needed.
pub fn run(init: std.process.Init, gpa: std.mem.Allocator, it: anytype) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    while (it.next()) |a| try args.append(gpa, a);
    const argv = args.items;

    var help_only = false;
    var list_profiles = false;
    var shell: ?[]const u8 = null;
    for (argv) |a| {
        if (isHelp(a)) {
            help_only = true;
        } else if (std.mem.eql(u8, a, "--list-profiles")) {
            list_profiles = true;
        } else if (shell == null and !std.mem.startsWith(u8, a, "-")) {
            shell = a;
        } else {
            return fail(init, "bbr completion: bad options (UnknownFlag)\n");
        }
    }

    if (help_only and shell == null and !list_profiles) {
        var buf: [2048]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buf);
        try stdout.interface.writeAll(completion_help);
        return stdout.interface.flush();
    }
    if (list_profiles and shell == null) return listProfiles(init, gpa);
    if (list_profiles) return fail(init, "bbr completion: bad options (UnknownFlag)\n");

    const name = shell orelse return fail(init, "bbr completion: a shell name is required (bash|zsh|fish)\n");
    var buf: [131072]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    if (std.mem.eql(u8, name, "bash")) {
        try stdout.interface.writeAll(bash_script);
    } else if (std.mem.eql(u8, name, "zsh")) {
        try stdout.interface.writeAll(zsh_script);
    } else if (std.mem.eql(u8, name, "fish")) {
        try stdout.interface.writeAll(fish_script);
    } else {
        return fail(init, "bbr completion: unknown shell (bash|zsh|fish)\n");
    }
    return stdout.interface.flush();
}

fn fail(init: std.process.Init, comptime message: []const u8) error{UnknownFlag} {
    var buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buf);
    stderr.interface.writeAll(message) catch {};
    stderr.interface.flush() catch {};
    return error.UnknownFlag;
}

/// Print one saved Profile name per line. Missing file prints nothing;
/// a corrupt file keeps `auth.load`'s stderr diagnostic and fails.
fn listProfiles(init: std.process.Init, gpa: std.mem.Allocator) !void {
    const loaded = try bbr.bitbucket.auth.load(gpa, init.io, init.environ_map);
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    if (loaded) |l| {
        var owned = l;
        defer owned.deinit(gpa);
        for (owned.file.profiles) |p| try stdout.interface.print("{s}\n", .{p.name});
    }
    try stdout.interface.flush();
}

const verbs_space = blk: {
    var text: []const u8 = "";
    for (cli.verbs) |verb| text = text ++ verb.name ++ " ";
    break :blk text;
};

const top_space = blk: {
    var text: []const u8 = "";
    for (top_commands) |name| text = text ++ name ++ " ";
    break :blk text;
};

const value_flags_space = blk: {
    var text: []const u8 = "";
    for (cli.completion_value_flags) |name| text = text ++ name ++ " ";
    break :blk text;
};

const global_flags_space = blk: {
    var text: []const u8 = "";
    for (cli.global_flags) |name| text = text ++ "--" ++ name ++ " ";
    break :blk text;
};

/// Shell-variable assignments holding the word lists, emitted at the top of
/// the bash/zsh scripts so the function bodies need no per-line interpolation.
const bash_lists =
    "_bbr_top=\"" ++ top_space ++ "\"\n" ++
    "_bbr_verbs=\"" ++ verbs_space ++ "\"\n" ++
    "_bbr_value_flags=\"" ++ value_flags_space ++ "\"\n" ++
    "_bbr_globals=\"" ++ global_flags_space ++ "\"\n";

const zsh_lists =
    "_bbr_top=(" ++ top_space ++ ")\n" ++
    "_bbr_verbs=(" ++ verbs_space ++ ")\n" ++
    "_bbr_value_flags=(" ++ value_flags_space ++ ")\n" ++
    "_bbr_globals=(" ++ global_flags_space ++ ")\n";

fn verbHasFlag(name: []const u8, flag: []const u8) bool {
    if (cli.flagsForVerb(name)) |flags| {
        for (flags) |f| if (std.mem.eql(u8, f, flag)) return true;
    }
    return false;
}

fn verbFlagWords(name: []const u8) []const u8 {
    // Comptime-built `--flag` words for one verb (globals included).
    return blk: {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "";
        if (cli.flagsForVerb(name)) |flags| {
            for (flags) |flag| text = text ++ "--" ++ flag ++ " ";
        }
        for (cli.global_flags) |flag| {
            if (!verbHasFlag(name, flag)) text = text ++ "--" ++ flag ++ " ";
        }
        break :blk text;
    };
}

const bash_verb_cases = blk: {
    @setEvalBranchQuota(100_000);
    var text: []const u8 = "";
    for (cli.verbs) |verb| text = text ++ "            " ++ verb.name ++ ") _bbr_words=\"" ++ verbFlagWords(verb.name) ++ "\";;\n";
    break :blk text;
};

const zsh_verb_cases = blk: {
    @setEvalBranchQuota(100_000);
    var text: []const u8 = "";
    for (cli.verbs) |verb| text = text ++ "        " ++ verb.name ++ ") _bbr_words=(" ++ verbFlagWords(verb.name) ++ ");;\n";
    break :blk text;
};

pub const bash_script =
    \\# bbr shell completion for bash. Install with:
    \\#   eval "$(bbr completion bash)"
    \\
++ bash_lists ++
    \\_bbr() {
    \\    local cur prev cword words
    \\    words=("${COMP_WORDS[@]}")
    \\    cword=$COMP_CWORD
    \\    cur="${words[cword]}"
    \\    prev=""
    \\    (( cword > 0 )) && prev="${words[cword - 1]}"
    \\
    \\    # `--profile=<TAB>` completes saved Profiles inside the `=` form.
    \\    case "$cur" in
    \\        --profile=*)
    \\            local names
    \\            names="$(bbr completion --list-profiles 2>/dev/null)"
    \\            COMPREPLY=($(compgen -P "--profile=" -W "$names" -- "${cur#--profile=}"))
    \\            return 0
    \\            ;;
    \\    esac
    \\
    \\    # A value flag in space form takes a path or word, not another flag.
    \\    case "$prev" in
    \\        --*)
    \\            local pname="${prev#--}"
    \\            case " $_bbr_value_flags " in
    \\                *" $pname "*)
    \\                    if [[ "$pname" == "profile" ]]; then
    \\                        local names
    \\                        names="$(bbr completion --list-profiles 2>/dev/null)"
    \\                        COMPREPLY=($(compgen -W "$names" -- "$cur"))
    \\                        return 0
    \\                    fi
    \\                    return 0
    \\                    ;;
    \\            esac
    \\            ;;
    \\    esac
    \\
    \\    # First two positionals after `bbr`: subcommand, then api verb.
    \\    local i word cmd="" verb="" skip=0
    \\    for (( i = 1; i < cword; i++ )); do
    \\        word="${words[i]}"
    \\        if (( skip )); then skip=0; continue; fi
    \\        case "$word" in
    \\            --*=*) continue ;;
    \\            --*)
    \\                case " $_bbr_value_flags " in
    \\                    *" ${word#--} "*) skip=1 ;;
    \\                esac
    \\                continue
    \\                ;;
    \\            -*) continue ;;
    \\        esac
    \\        if [[ -z "$cmd" ]]; then cmd="$word"; elif [[ "$cmd" == "api" && -z "$verb" ]]; then verb="$word"; fi
    \\    done
    \\
    \\    local _bbr_words=""
    \\    if [[ -z "$cmd" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            _bbr_words="--profile --help --version "
    \\        else
    \\            _bbr_words="$_bbr_top"
    \\        fi
    \\    elif [[ "$cmd" == "api" && -z "$verb" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            _bbr_words="$_bbr_globals"
    \\        else
    \\            _bbr_words="$_bbr_verbs"
    \\        fi
    \\    elif [[ "$cmd" == "api" ]]; then
    \\        case "$verb" in
    \\
++ bash_verb_cases ++
    \\            *) _bbr_words="$_bbr_globals";;
    \\        esac
    \\    elif [[ "$cmd" == "completion" ]]; then
    \\        _bbr_words=" bash zsh fish "
    \\    elif [[ "$cmd" == "login" || "$cmd" == "logout" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            _bbr_words="--profile --help "
    \\        else
    \\            _bbr_words=" $(bbr completion --list-profiles 2>/dev/null) "
    \\        fi
    \\    else
    \\        if [[ "$cur" == --* ]]; then
    \\            _bbr_words="--profile --help "
    \\        else
    \\            return 0
    \\        fi
    \\    fi
    \\    COMPREPLY=($(compgen -W "$_bbr_words" -- "$cur"))
    \\}
    \\complete -F _bbr -o default bbr
    \\
;

pub const zsh_script =
    \\#compdef bbr
    \\# bbr shell completion for zsh. Install with:
    \\#   bbr completion zsh > "${fpath[1]}/_bbr"
    \\
++ zsh_lists ++
    \\_bbr() {
    \\    local cur prev cmd verb
    \\    cur="${words[CURRENT]}"
    \\    prev=""
    \\    (( CURRENT > 1 )) && prev="${words[CURRENT - 1]}"
    \\
    \\    # `--profile=<TAB>` completes saved Profiles inside the `=` form.
    \\    case "$cur" in
    \\        --profile=*)
    \\            local -a names
    \\            names=(${(f)"$(bbr completion --list-profiles 2>/dev/null)"})
    \\            compadd -P "--profile=" -a names
    \\            return 0
    \\            ;;
    \\    esac
    \\
    \\    # A value flag in space form takes a path or word, not another flag.
    \\    case "$prev" in
    \\        --*)
    \\            local pname="${prev#--}"
    \\            case " $_bbr_value_flags " in
    \\                *" $pname "*)
    \\                    if [[ "$pname" == "profile" ]]; then
    \\                        local -a names
    \\                        names=(${(f)"$(bbr completion --list-profiles 2>/dev/null)"})
    \\                        compadd -a names
    \\                    fi
    \\                    return 0
    \\                    ;;
    \\            esac
    \\            ;;
    \\    esac
    \\
    \\    # First two positionals: subcommand, then api verb.
    \\    local -a pos
    \\    pos=()
    \\    local i w skip=0
    \\    for (( i = 2; i < CURRENT; i++ )); do
    \\        w="${words[i]}"
    \\        if (( skip )); then skip=0; continue; fi
    \\        case "$w" in
    \\            --*=*) continue ;;
    \\            --*)
    \\                case " $_bbr_value_flags " in
    \\                    *" ${w#--} "*) skip=1 ;;
    \\                esac
    \\                continue
    \\                ;;
    \\            -*) continue ;;
    \\        esac
    \\        pos+=("$w")
    \\    done
    \\    cmd="${pos[1]:-}"
    \\    verb="${pos[2]:-}"
    \\
    \\    local -a _bbr_words
    \\    if [[ -z "$cmd" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            _bbr_words=(--profile --help --version)
    \\        else
    \\            _bbr_words=($_bbr_top)
    \\        fi
    \\    elif [[ "$cmd" == "api" && -z "$verb" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            _bbr_words=($_bbr_globals)
    \\        else
    \\            _bbr_words=($_bbr_verbs)
    \\        fi
    \\    elif [[ "$cmd" == "api" ]]; then
    \\        case "$verb" in
    \\
++ zsh_verb_cases ++
    \\            *) _bbr_words=($_bbr_globals);;
    \\        esac
    \\    elif [[ "$cmd" == "completion" ]]; then
    \\        _bbr_words=(bash zsh fish)
    \\    elif [[ "$cmd" == "login" || "$cmd" == "logout" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            _bbr_words=(--profile --help)
    \\        else
    \\            _bbr_words=(${(f)"$(bbr completion --list-profiles 2>/dev/null)"})
    \\        fi
    \\    else
    \\        if [[ "$cur" == --* ]]; then
    \\            _bbr_words=(--profile --help)
    \\        else
    \\            return 0
    \\        fi
    \\    fi
    \\    compadd -a _bbr_words
    \\}
    \\_bbr "$@"
    \\
;

const fish_verb_lines = blk: {
    @setEvalBranchQuota(100_000);
    var text: []const u8 = "";
    for (cli.verbs) |verb| {
        text = text ++ "complete -c bbr -n '__fish_seen_subcommand_from api' -f -a '" ++ verb.name ++ "' -d '" ++ verb.summary ++ "'\n";
        if (cli.flagsForVerb(verb.name)) |flags| {
            for (flags) |flag| {
                const cond = "'__fish_seen_subcommand_from " ++ verb.name ++ "; and __fish_seen_subcommand_from api'";
                if (cli.completionTakesValue(flag)) {
                    if (std.mem.eql(u8, flag, "profile")) {
                        text = text ++ "complete -c bbr -n " ++ cond ++ " -l " ++ flag ++ " -r -f -a '(bbr completion --list-profiles)'\n";
                    } else {
                        text = text ++ "complete -c bbr -n " ++ cond ++ " -l " ++ flag ++ " -r\n";
                    }
                } else {
                    text = text ++ "complete -c bbr -n " ++ cond ++ " -l " ++ flag ++ " -f\n";
                }
            }
        }
    }
    break :blk text;
};

const fish_top_lines = blk: {
    var text: []const u8 = "";
    for (top_commands) |name| {
        if (std.mem.eql(u8, name, "api")) {
            text = text ++ "complete -c bbr -n '__fish_use_subcommand' -f -a 'api' -d 'Talk to the Bitbucket Cloud REST API'\n";
        } else if (std.mem.eql(u8, name, "completion")) {
            text = text ++ "complete -c bbr -n '__fish_use_subcommand' -f -a 'completion' -d 'Print a shell completion script'\n";
        } else {
            text = text ++ "complete -c bbr -n '__fish_use_subcommand' -f -a '" ++ name ++ "'\n";
        }
    }
    break :blk text;
};

pub const fish_script =
    \\# bbr shell completion for fish. Install with:
    \\#   bbr completion fish > ~/.config/fish/completions/bbr.fish
    \\complete -c bbr -s h -l help -f -d 'Show help'
    \\complete -c bbr -l version -f -d 'Show version'
    \\complete -c bbr -n '__fish_use_subcommand' -l profile -r -f -a '(bbr completion --list-profiles)'
    \\
++ fish_top_lines ++
    \\complete -c bbr -n '__fish_seen_subcommand_from completion' -f -a 'bash zsh fish'
    \\complete -c bbr -n '__fish_seen_subcommand_from login logout' -f -a '(bbr completion --list-profiles)'
    \\complete -c bbr -n '__fish_seen_subcommand_from api' -l profile -r -f -a '(bbr completion --list-profiles)'
    \\complete -c bbr -n '__fish_seen_subcommand_from api' -l workspace -r
    \\complete -c bbr -n '__fish_seen_subcommand_from api' -l json -f
    \\complete -c bbr -n '__fish_seen_subcommand_from api' -l help -f
    \\
++ fish_verb_lines;

test "completion metadata covers every verb" {
    try std.testing.expectEqual(cli.verbs.len, cli.verb_flags.len);
    for (cli.verbs) |verb| try std.testing.expect(cli.flagsForVerb(verb.name) != null);
}

test "bash script completes verbs, flags, and the profiles hook" {
    try std.testing.expect(std.mem.indexOf(u8, bash_script, "++") == null);
    for (cli.verbs) |verb| try std.testing.expect(std.mem.indexOf(u8, bash_script, verb.name) != null);
    for ([_][]const u8{ "--pull-request-id", "--profile", "--workspace", "--json" }) |flag| {
        try std.testing.expect(std.mem.indexOf(u8, bash_script, flag) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, bash_script, "bbr completion --list-profiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash_script, "complete -F _bbr bbr") != null);
}

test "zsh script completes verbs, flags, and the profiles hook" {
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "++") == null);
    for (cli.verbs) |verb| try std.testing.expect(std.mem.indexOf(u8, zsh_script, verb.name) != null);
    for ([_][]const u8{ "--pull-request-id", "--profile", "--workspace" }) |flag| {
        try std.testing.expect(std.mem.indexOf(u8, zsh_script, flag) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "bbr completion --list-profiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "#compdef bbr") != null);
}

test "fish script completes verbs, flags, and the profiles hook" {
    for (cli.verbs) |verb| try std.testing.expect(std.mem.indexOf(u8, fish_script, verb.name) != null);
    for ([_][]const u8{ "--pull-request-id", "--profile", "--workspace" }) |flag| {
        try std.testing.expect(std.mem.indexOf(u8, fish_script, flag) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, fish_script, "(bbr completion --list-profiles)") != null);
}
