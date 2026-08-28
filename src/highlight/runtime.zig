//! Runtime assembly for installed UserGrammars.

pub const grammar_cli = @import("grammar_cli.zig");
pub const user_grammar = @import("user_grammar.zig");
pub const TreeSitterHighlighter = @import("tree_sitter_highlighter.zig").TreeSitterHighlighter;
