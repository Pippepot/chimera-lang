const std = @import("std");
const structures = @import("structures.zig");

pub const Token = structures.Token;

pub const Tokenizer = struct {
    gpa: std.mem.Allocator,
    buffer: []const u8,
    index: u32,
    at_line_start: bool,
    indent: u16,
    indent_levels: std.ArrayList(u16),

    pub fn init(gpa: std.mem.Allocator, buffer: []const u8) !Tokenizer {
        var indent_levels = try std.ArrayList(u16).initCapacity(gpa, 8);
        errdefer indent_levels.deinit(gpa);
        // Start with indentation level 0, such that previous indentation can be checked against
        try indent_levels.append(gpa, 0);

        return .{
            .gpa = gpa,
            .buffer = buffer,
            // Skip the UTF-8 BOM if present.
            .index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
            .at_line_start = true,
            .indent = 0,
            .indent_levels = indent_levels,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.indent_levels.deinit(self.gpa);
    }

    const State = enum {
        start,
        expect_newline,
        identifier,
        string_literal,
        string_literal_backslash,
        char_literal,
        char_literal_backslash,
        equal,
        minus,
        line_comment,
        int,
        int_exponent,
        int_period,
        float,
        float_exponent,
        angle_bracket_left,
        angle_bracket_right,
        period,
        period_2,
        invalid,
    };

    fn current(self: *const Tokenizer) u8 {
        return if (self.index < self.buffer.len) self.buffer[self.index] else 0;
    }

    // EOF can be observed either between tokens or while scanning trailing
    // whitespace or a comment. Every path must emit all pending dedents first.
    fn eofOrDedent(self: *Tokenizer) Token {
        if (self.indent_levels.items.len > 1) {
            _ = self.indent_levels.pop();
            return .{ .tag = .dedent, .loc = .{ .start = self.index, .end = self.index } };
        }
        return .{ .tag = .eof, .loc = .{ .start = self.index, .end = self.index } };
    }

    fn binary_op(self: *Tokenizer, tag: Token.Tag, equal_tag: Token.Tag) Token.Tag {
        self.index += 1;
        if (self.current() == '=') {
            self.index += 1;
            return equal_tag;
        }
        return tag;
    }

    fn getNewLineTokens(self: *Tokenizer) ?u32 {
        if (self.current() == '\n') return 1;
        // A CR directly preceding NL is part of the newline sequence
        if (self.current() == '\r' and self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') return 2;
        return null;
    }

    fn checkIndentation(self: *Tokenizer) !?Token {
        line_start: while (true) {
            while (self.current() == ' ') {
                self.index += 1;
                self.indent += 1;
            }

            // Reset indentation counting on newline. This avoids bloating with dedent/indent that cancel out
            if (getNewLineTokens(self)) |token_count| {
                self.index += token_count;
                self.indent = 0;
                continue :line_start;
            }

            break :line_start;
        }

        // Comment-only lines and trailing spaces do not open or close blocks.
        // The token scanner still validates the comment's contents.
        if (self.current() == '#' or self.index == self.buffer.len) {
            self.at_line_start = false;
            return null;
        }

        const current_indent = self.indent_levels.items[self.indent_levels.items.len - 1];
        if (self.indent > current_indent) {
            self.at_line_start = false;
            try self.indent_levels.append(self.gpa, self.indent);
            return Token{ .tag = .indent, .loc = .{ .start = self.index - self.indent, .end = self.index } };
        }

        if (self.indent < current_indent) {
            _ = self.indent_levels.pop();
            return Token{ .tag = .dedent, .loc = .{ .start = self.index, .end = self.index } };
        }

        self.at_line_start = false;
        return null;
    }

    pub fn next(self: *Tokenizer) !Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{ .start = self.index, .end = undefined },
        };

        if (self.at_line_start) {
            if (try checkIndentation(self)) |tok| return tok;
            // checkIndentation may have skipped blank lines;
            // start the token scan at the first byte of the actual line.
            result.loc.start = self.index;
        }

        if (self.index == self.buffer.len) {
            return self.eofOrDedent();
        }

        state: switch (State.start) {
            .start => switch (self.current()) {
                0 => {
                    if (self.index == self.buffer.len) {
                        return self.eofOrDedent();
                    } else {
                        continue :state .invalid;
                    }
                },
                '\n', '\r' => {
                    if (getNewLineTokens(self)) |token_count| {
                        self.index += token_count;
                        self.indent = 0;
                        self.at_line_start = true;
                        if (try checkIndentation(self)) |tok| return tok;
                        result.loc.start = self.index;
                        continue :state .start;
                    } else continue :state .invalid;
                },
                ' ', '\t' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '"' => {
                    result.tag = .string_literal;
                    continue :state .string_literal;
                },
                '\'' => {
                    result.tag = .char_literal;
                    continue :state .char_literal;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '=' => {
                    result.tag = .equal;
                    continue :state .equal;
                },
                '|' => result.tag = self.binary_op(.pipe, .pipe_equal),
                '(' => {
                    result.tag = .l_paren;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .r_paren;
                    self.index += 1;
                },
                '[' => {
                    result.tag = .l_bracket;
                    self.index += 1;
                },
                ']' => {
                    result.tag = .r_bracket;
                    self.index += 1;
                },
                ';' => {
                    result.tag = .semicolon;
                    self.index += 1;
                },
                ',' => {
                    result.tag = .comma;
                    self.index += 1;
                },
                '?' => {
                    result.tag = .question_mark;
                    self.index += 1;
                },
                ':' => {
                    result.tag = .colon;
                    self.index += 1;
                },
                '%' => result.tag = self.binary_op(.percent, .percent_equal),
                '*' => result.tag = self.binary_op(.asterisk, .asterisk_equal),
                '+' => result.tag = self.binary_op(.plus, .plus_equal),
                '<' => continue :state .angle_bracket_left,
                '>' => continue :state .angle_bracket_right,
                '^' => result.tag = self.binary_op(.caret, .caret_equal),
                '{' => {
                    result.tag = .l_brace;
                    self.index += 1;
                },
                '}' => {
                    result.tag = .r_brace;
                    self.index += 1;
                },
                '~' => {
                    result.tag = .tilde;
                    self.index += 1;
                },
                '.' => continue :state .period,
                '-' => {
                    result.tag = .minus;
                    continue :state .minus;
                },
                '/' => result.tag = self.binary_op(.slash, .slash_equal),
                '&' => result.tag = self.binary_op(.ampersand, .ampersand_equal),
                '0'...'9' => {
                    result.tag = .number_literal;
                    self.index += 1;
                    continue :state .int;
                },
                '#' => continue :state .line_comment,
                else => continue :state .invalid,
            },

            .expect_newline => {
                self.index += 1;
                switch (self.current()) {
                    0 => {
                        if (self.index == self.buffer.len) {
                            result.tag = .invalid;
                        } else {
                            continue :state .invalid;
                        }
                    },
                    '\n' => {
                        self.index += 1;
                        self.indent = 0;
                        self.at_line_start = true;
                        if (try checkIndentation(self)) |tok| return tok;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    else => continue :state .invalid,
                }
            },

            .invalid => {
                self.index += 1;
                switch (self.current()) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },

            .identifier => {
                self.index += 1;
                switch (self.current()) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    else => {
                        const ident = self.buffer[result.loc.start..self.index];
                        if (Token.getKeyword(ident)) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },

            .string_literal => {
                self.index += 1;
                switch (self.current()) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '\n' => result.tag = .invalid,
                    '\\' => continue :state .string_literal_backslash,
                    '"' => self.index += 1,
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .string_literal,
                }
            },

            .string_literal_backslash => {
                self.index += 1;
                switch (self.current()) {
                    0, '\n' => result.tag = .invalid,
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .string_literal,
                }
            },

            .char_literal => {
                self.index += 1;
                switch (self.current()) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '\n' => result.tag = .invalid,
                    '\\' => continue :state .char_literal_backslash,
                    '\'' => self.index += 1,
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .char_literal,
                }
            },

            .char_literal_backslash => {
                self.index += 1;
                switch (self.current()) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '\n' => result.tag = .invalid,
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .char_literal,
                }
            },

            .equal => {
                self.index += 1;
                switch (self.current()) {
                    '=' => {
                        result.tag = .equal_equal;
                        self.index += 1;
                    },
                    '>' => {
                        result.tag = .equal_angle_bracket_right;
                        self.index += 1;
                    },
                    else => result.tag = .equal,
                }
            },

            .minus => {
                self.index += 1;
                switch (self.current()) {
                    '>' => {
                        result.tag = .arrow;
                        self.index += 1;
                    },
                    '=' => {
                        result.tag = .minus_equal;
                        self.index += 1;
                    },
                    else => result.tag = .minus,
                }
            },

            .angle_bracket_left => {
                self.index += 1;
                switch (self.current()) {
                    '<' => result.tag = self.binary_op(
                        .angle_bracket_angle_bracket_left,
                        .angle_bracket_angle_bracket_left_equal,
                    ),
                    '>' => {
                        result.tag = .angle_bracket_left_angle_bracket_right;
                        self.index += 1;
                    },
                    '=' => {
                        result.tag = .angle_bracket_left_equal;
                        self.index += 1;
                    },
                    else => result.tag = .angle_bracket_left,
                }
            },

            .angle_bracket_right => {
                self.index += 1;
                switch (self.current()) {
                    '>' => result.tag = self.binary_op(
                        .angle_bracket_angle_bracket_right,
                        .angle_bracket_angle_bracket_right_equal,
                    ),
                    '=' => {
                        result.tag = .angle_bracket_right_equal;
                        self.index += 1;
                    },
                    else => result.tag = .angle_bracket_right,
                }
            },

            .period => {
                self.index += 1;
                switch (self.current()) {
                    '.' => continue :state .period_2,
                    else => result.tag = .period,
                }
            },

            .period_2 => {
                self.index += 1;
                switch (self.current()) {
                    '.' => {
                        result.tag = .ellipsis3;
                        self.index += 1;
                    },
                    else => result.tag = .ellipsis2,
                }
            },

            .line_comment => {
                self.index += 1;
                switch (self.current()) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else return self.eofOrDedent();
                    },
                    '\n' => {
                        self.index += 1;
                        self.indent = 0;
                        self.at_line_start = true;
                        if (try checkIndentation(self)) |tok| return tok;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    '\r' => continue :state .expect_newline,
                    0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .line_comment,
                }
            },

            .int => switch (self.current()) {
                '.' => continue :state .int_period,
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.index += 1;
                    continue :state .int;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .int_exponent;
                },
                else => {},
            },
            .int_exponent => {
                self.index += 1;
                switch (self.current()) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .int,
                }
            },
            .int_period => {
                self.index += 1;
                switch (self.current()) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    'e', 'E', 'p', 'P' => {
                        continue :state .float_exponent;
                    },
                    else => self.index -= 1,
                }
            },
            .float => switch (self.current()) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.index += 1;
                    continue :state .float;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .float_exponent;
                },
                else => {},
            },
            .float_exponent => {
                self.index += 1;
                switch (self.current()) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .float,
                }
            },
        }

        result.loc.end = self.index;
        return result;
    }
};

test "keywords" {
    try testTokenize("if else const var read mut deinit return true false comptime static func struct is as and or not none sizeof test", &.{
        .keyword_if,
        .keyword_else,
        .keyword_const,
        .keyword_var,
        .keyword_read,
        .keyword_mut,
        .keyword_deinit,
        .keyword_return,
        .keyword_true,
        .keyword_false,
        .keyword_comptime,
        .keyword_static,
        .keyword_func,
        .keyword_struct,
        .keyword_is,
        .keyword_as,
        .keyword_and,
        .keyword_or,
        .keyword_not,
        .keyword_none,
        .keyword_sizeof,
        .keyword_test,
    });
}

test "function indentation" {
    try testTokenize(
        \\static foo = func()
        \\  print(1)
        \\print(2)
    , &.{
        .keyword_static, .identifier, .equal,          .keyword_func,   .l_paren, .r_paren,
        .indent,         .identifier, .l_paren,        .number_literal, .r_paren, .dedent,
        .identifier,     .l_paren,    .number_literal, .r_paren,        .eof,
    });
}

test "nested indentation" {
    try testTokenize(
        \\static foo = struct
        \\  static bar = func()
        \\      print(1)
        \\print(1)
    , &.{
        .keyword_static, .identifier,     .equal,          .keyword_struct,
        .indent,         .keyword_static, .identifier,     .equal,
        .keyword_func,   .l_paren,        .r_paren,        .indent,
        .identifier,     .l_paren,        .number_literal, .r_paren,
        .dedent,         .dedent,         .identifier,     .l_paren,
        .number_literal, .r_paren,
    });
}

test "eof unwinds indentation without trailing newline" {
    try testTokenize("comptime foo\n  bar", &.{
        .keyword_comptime,
        .identifier,
        .indent,
        .identifier,
        .dedent,
    });
}

test "eof unwinds indentation after trailing spaces" {
    try testTokenize("comptime foo\n  bar ", &.{
        .keyword_comptime,
        .identifier,
        .indent,
        .identifier,
        .dedent,
    });
}

test "equal tokens keep their distinct spellings" {
    try testTokenize("= == =>", &.{
        .equal,
        .equal_equal,
        .equal_angle_bracket_right,
    });
}

test "line comment followed by top-level comptime" {
    try testTokenize(
        \\# line comment
        \\comptime {}
        \\
    , &.{
        .keyword_comptime,
        .l_brace,
        .r_brace,
    });
}

test "code point literal with hex escape" {
    try testTokenize(
        \\'\x1b'
    , &.{.char_literal});
    try testTokenize(
        \\'\x1'
    , &.{.char_literal});
}

test "newline in char literal" {
    try testTokenize(
        \\'
        \\'
    , &.{ .invalid, .invalid });
}

test "newline in string literal" {
    try testTokenize(
        \\"
        \\"
    , &.{ .invalid, .invalid });
}

test "code point literal with unicode escapes" {
    // Valid unicode escapes
    try testTokenize(
        \\'\u{3}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{01}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{2a}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{3f9}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{6E09aBc1523}'
    , &.{.char_literal});
    try testTokenize(
        \\"\u{440}"
    , &.{.string_literal});

    // Invalid unicode escapes
    try testTokenize(
        \\'\u'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{{'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{s}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{2z}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{4a'
    , &.{.char_literal});

    // Test old-style unicode literals
    try testTokenize(
        \\'\u0333'
    , &.{.char_literal});
    try testTokenize(
        \\'\U0333'
    , &.{.char_literal});
}

test "code point literal with unicode code point" {
    try testTokenize(
        \\'💩'
    , &.{.char_literal});
}

test "float literal e exponent" {
    try testTokenize("a = 4.94065645841246544177e-324;\n", &.{
        .identifier,
        .equal,
        .number_literal,
        .semicolon,
    });
}

test "float literal p exponent" {
    try testTokenize("a = 0x1.a827999fcef32p+1022;\n", &.{
        .identifier,
        .equal,
        .number_literal,
        .semicolon,
    });
}

test "chars" {
    try testTokenize("'c'", &.{.char_literal});
}

test "invalid token characters" {
    try testTokenize("!", &.{.invalid});
    try testTokenize("`", &.{.invalid});
    try testTokenize("'c", &.{.invalid});
    try testTokenize("'", &.{.invalid});
    try testTokenize("''", &.{.char_literal});
    try testTokenize("'\n'", &.{ .invalid, .invalid });
}

test "invalid literal/comment characters" {
    try testTokenize("\"\x00\"", &.{.invalid});
    try testTokenize("`\x00`", &.{.invalid});
    try testTokenize("#\x00", &.{.invalid});
    try testTokenize("#\x1f", &.{.invalid});
    try testTokenize("#\x7f", &.{.invalid});
}

test "utf8" {
    try testTokenize("#\xc2\x80", &.{});
    try testTokenize("#\xf4\x8f\xbf\xbf", &.{});
}

test "invalid utf8" {
    try testTokenize("#\x80", &.{});
    try testTokenize("#\xbf", &.{});
    try testTokenize("#\xf8", &.{});
    try testTokenize("#\xff", &.{});
    try testTokenize("#\xc2\xc0", &.{});
    try testTokenize("#\xe0", &.{});
    try testTokenize("#\xf0", &.{});
    try testTokenize("#\xf0\x90\x80\xc0", &.{});
}

test "illegal unicode codepoints" {
    // unicode newline characters.U+0085, U+2028, U+2029
    try testTokenize("#\xc2\x84", &.{});
    try testTokenize("#\xc2\x85", &.{});
    try testTokenize("#\xc2\x86", &.{});
    try testTokenize("#\xe2\x80\xa7", &.{});
    try testTokenize("#\xe2\x80\xa8", &.{});
    try testTokenize("#\xe2\x80\xa9", &.{});
    try testTokenize("#\xe2\x80\xaa", &.{});
}

test "line comment" {
    try testTokenize("#", &.{});
    try testTokenize("# a # b", &.{});
    try testTokenize("# #", &.{});
}

test "line comment followed by identifier" {
    try testTokenize(
        \\Unexpected,
        \\# another
        \\Another,
    , &.{
        .identifier,
        .comma,
        .identifier,
        .comma,
    });
}

test "UTF-8 BOM is recognized and skipped" {
    try testTokenize("\xEF\xBB\xBFa;\n", &.{
        .identifier,
        .semicolon,
    });
}

test "range literals" {
    try testTokenize("0...9", &.{ .number_literal, .ellipsis3, .number_literal });
    try testTokenize("'0'...'9'", &.{ .char_literal, .ellipsis3, .char_literal });
    try testTokenize("0x00...0x09", &.{ .number_literal, .ellipsis3, .number_literal });
    try testTokenize("0b00...0b11", &.{ .number_literal, .ellipsis3, .number_literal });
    try testTokenize("0o00...0o11", &.{ .number_literal, .ellipsis3, .number_literal });
}

test "number literals decimal" {
    try testTokenize("0", &.{.number_literal});
    try testTokenize("1", &.{.number_literal});
    try testTokenize("2", &.{.number_literal});
    try testTokenize("3", &.{.number_literal});
    try testTokenize("4", &.{.number_literal});
    try testTokenize("5", &.{.number_literal});
    try testTokenize("6", &.{.number_literal});
    try testTokenize("7", &.{.number_literal});
    try testTokenize("8", &.{.number_literal});
    try testTokenize("9", &.{.number_literal});
    try testTokenize("1..", &.{ .number_literal, .ellipsis2 });
    try testTokenize("0a", &.{.number_literal});
    try testTokenize("9b", &.{.number_literal});
    try testTokenize("1z", &.{.number_literal});
    try testTokenize("1z_1", &.{.number_literal});
    try testTokenize("9z3", &.{.number_literal});

    try testTokenize("0_0", &.{.number_literal});
    try testTokenize("0001", &.{.number_literal});
    try testTokenize("01234567890", &.{.number_literal});
    try testTokenize("012_345_6789_0", &.{.number_literal});
    try testTokenize("0_1_2_3_4_5_6_7_8_9_0", &.{.number_literal});

    try testTokenize("00_", &.{.number_literal});
    try testTokenize("0_0_", &.{.number_literal});
    try testTokenize("0__0", &.{.number_literal});
    try testTokenize("0_0f", &.{.number_literal});
    try testTokenize("0_0_f", &.{.number_literal});
    try testTokenize("0_0_f_00", &.{.number_literal});
    try testTokenize("1_,", &.{ .number_literal, .comma });

    try testTokenize("0.0", &.{.number_literal});
    try testTokenize("1.0", &.{.number_literal});
    try testTokenize("10.0", &.{.number_literal});
    try testTokenize("0e0", &.{.number_literal});
    try testTokenize("1e0", &.{.number_literal});
    try testTokenize("1e100", &.{.number_literal});
    try testTokenize("1.0e100", &.{.number_literal});
    try testTokenize("1.0e+100", &.{.number_literal});
    try testTokenize("1.0e-100", &.{.number_literal});
    try testTokenize("1_0_0_0.0_0_0_0_0_1e1_0_0_0", &.{.number_literal});

    try testTokenize("1.", &.{ .number_literal, .period });
    try testTokenize("1e", &.{.number_literal});
    try testTokenize("1.e100", &.{.number_literal});
    try testTokenize("1.0e1f0", &.{.number_literal});
    try testTokenize("1.0p100", &.{.number_literal});
    try testTokenize("1.0p-100", &.{.number_literal});
    try testTokenize("1.0p1f0", &.{.number_literal});
    try testTokenize("1.0_,", &.{ .number_literal, .comma });
    try testTokenize("1_.0", &.{.number_literal});
    try testTokenize("1._", &.{.number_literal});
    try testTokenize("1.a", &.{.number_literal});
    try testTokenize("1.z", &.{.number_literal});
    try testTokenize("1._0", &.{.number_literal});
    try testTokenize("1.+", &.{ .number_literal, .period, .plus });
    try testTokenize("1._+", &.{ .number_literal, .plus });
    try testTokenize("1._e", &.{.number_literal});
    try testTokenize("1.0e", &.{.number_literal});
    try testTokenize("1.0e,", &.{ .number_literal, .comma });
    try testTokenize("1.0e_", &.{.number_literal});
    try testTokenize("1.0e+_", &.{.number_literal});
    try testTokenize("1.0e-_", &.{.number_literal});
    try testTokenize("1.0e0_+", &.{ .number_literal, .plus });
}

test "number literals binary" {
    try testTokenize("0b0", &.{.number_literal});
    try testTokenize("0b1", &.{.number_literal});
    try testTokenize("0b2", &.{.number_literal});
    try testTokenize("0b3", &.{.number_literal});
    try testTokenize("0b4", &.{.number_literal});
    try testTokenize("0b5", &.{.number_literal});
    try testTokenize("0b6", &.{.number_literal});
    try testTokenize("0b7", &.{.number_literal});
    try testTokenize("0b8", &.{.number_literal});
    try testTokenize("0b9", &.{.number_literal});
    try testTokenize("0ba", &.{.number_literal});
    try testTokenize("0bb", &.{.number_literal});
    try testTokenize("0bc", &.{.number_literal});
    try testTokenize("0bd", &.{.number_literal});
    try testTokenize("0be", &.{.number_literal});
    try testTokenize("0bf", &.{.number_literal});
    try testTokenize("0bz", &.{.number_literal});

    try testTokenize("0b0000_0000", &.{.number_literal});
    try testTokenize("0b1111_1111", &.{.number_literal});
    try testTokenize("0b10_10_10_10", &.{.number_literal});
    try testTokenize("0b0_1_0_1_0_1_0_1", &.{.number_literal});
    try testTokenize("0b1.", &.{ .number_literal, .period });
    try testTokenize("0b1.0", &.{.number_literal});

    try testTokenize("0B0", &.{.number_literal});
    try testTokenize("0b_", &.{.number_literal});
    try testTokenize("0b_0", &.{.number_literal});
    try testTokenize("0b1_", &.{.number_literal});
    try testTokenize("0b0__1", &.{.number_literal});
    try testTokenize("0b0_1_", &.{.number_literal});
    try testTokenize("0b1e", &.{.number_literal});
    try testTokenize("0b1p", &.{.number_literal});
    try testTokenize("0b1e0", &.{.number_literal});
    try testTokenize("0b1p0", &.{.number_literal});
    try testTokenize("0b1_,", &.{ .number_literal, .comma });
}

test "number literals octal" {
    try testTokenize("0o0", &.{.number_literal});
    try testTokenize("0o1", &.{.number_literal});
    try testTokenize("0o2", &.{.number_literal});
    try testTokenize("0o3", &.{.number_literal});
    try testTokenize("0o4", &.{.number_literal});
    try testTokenize("0o5", &.{.number_literal});
    try testTokenize("0o6", &.{.number_literal});
    try testTokenize("0o7", &.{.number_literal});
    try testTokenize("0o8", &.{.number_literal});
    try testTokenize("0o9", &.{.number_literal});
    try testTokenize("0oa", &.{.number_literal});
    try testTokenize("0ob", &.{.number_literal});
    try testTokenize("0oc", &.{.number_literal});
    try testTokenize("0od", &.{.number_literal});
    try testTokenize("0oe", &.{.number_literal});
    try testTokenize("0of", &.{.number_literal});
    try testTokenize("0oz", &.{.number_literal});

    try testTokenize("0o01234567", &.{.number_literal});
    try testTokenize("0o0123_4567", &.{.number_literal});
    try testTokenize("0o01_23_45_67", &.{.number_literal});
    try testTokenize("0o0_1_2_3_4_5_6_7", &.{.number_literal});
    try testTokenize("0o7.", &.{ .number_literal, .period });
    try testTokenize("0o7.0", &.{.number_literal});

    try testTokenize("0O0", &.{.number_literal});
    try testTokenize("0o_", &.{.number_literal});
    try testTokenize("0o_0", &.{.number_literal});
    try testTokenize("0o1_", &.{.number_literal});
    try testTokenize("0o0__1", &.{.number_literal});
    try testTokenize("0o0_1_", &.{.number_literal});
    try testTokenize("0o1e", &.{.number_literal});
    try testTokenize("0o1p", &.{.number_literal});
    try testTokenize("0o1e0", &.{.number_literal});
    try testTokenize("0o1p0", &.{.number_literal});
    try testTokenize("0o_,", &.{ .number_literal, .comma });
}

test "number literals hexadecimal" {
    try testTokenize("0x0", &.{.number_literal});
    try testTokenize("0x1", &.{.number_literal});
    try testTokenize("0x2", &.{.number_literal});
    try testTokenize("0x3", &.{.number_literal});
    try testTokenize("0x4", &.{.number_literal});
    try testTokenize("0x5", &.{.number_literal});
    try testTokenize("0x6", &.{.number_literal});
    try testTokenize("0x7", &.{.number_literal});
    try testTokenize("0x8", &.{.number_literal});
    try testTokenize("0x9", &.{.number_literal});
    try testTokenize("0xa", &.{.number_literal});
    try testTokenize("0xb", &.{.number_literal});
    try testTokenize("0xc", &.{.number_literal});
    try testTokenize("0xd", &.{.number_literal});
    try testTokenize("0xe", &.{.number_literal});
    try testTokenize("0xf", &.{.number_literal});
    try testTokenize("0xA", &.{.number_literal});
    try testTokenize("0xB", &.{.number_literal});
    try testTokenize("0xC", &.{.number_literal});
    try testTokenize("0xD", &.{.number_literal});
    try testTokenize("0xE", &.{.number_literal});
    try testTokenize("0xF", &.{.number_literal});
    try testTokenize("0x0z", &.{.number_literal});
    try testTokenize("0xz", &.{.number_literal});

    try testTokenize("0x0123456789ABCDEF", &.{.number_literal});
    try testTokenize("0x0123_4567_89AB_CDEF", &.{.number_literal});
    try testTokenize("0x01_23_45_67_89AB_CDE_F", &.{.number_literal});
    try testTokenize("0x0_1_2_3_4_5_6_7_8_9_A_B_C_D_E_F", &.{.number_literal});

    try testTokenize("0X0", &.{.number_literal});
    try testTokenize("0x_", &.{.number_literal});
    try testTokenize("0x_1", &.{.number_literal});
    try testTokenize("0x1_", &.{.number_literal});
    try testTokenize("0x0__1", &.{.number_literal});
    try testTokenize("0x0_1_", &.{.number_literal});
    try testTokenize("0x_,", &.{ .number_literal, .comma });

    try testTokenize("0x1.0", &.{.number_literal});
    try testTokenize("0xF.0", &.{.number_literal});
    try testTokenize("0xF.F", &.{.number_literal});
    try testTokenize("0xF.Fp0", &.{.number_literal});
    try testTokenize("0xF.FP0", &.{.number_literal});
    try testTokenize("0x1p0", &.{.number_literal});
    try testTokenize("0xfp0", &.{.number_literal});
    try testTokenize("0x1.0+0xF.0", &.{ .number_literal, .plus, .number_literal });

    try testTokenize("0x1.", &.{ .number_literal, .period });
    try testTokenize("0xF.", &.{ .number_literal, .period });
    try testTokenize("0x1.+0xF.", &.{ .number_literal, .period, .plus, .number_literal, .period });
    try testTokenize("0xff.p10", &.{.number_literal});

    try testTokenize("0x0123456.789ABCDEF", &.{.number_literal});
    try testTokenize("0x0_123_456.789_ABC_DEF", &.{.number_literal});
    try testTokenize("0x0_1_2_3_4_5_6.7_8_9_A_B_C_D_E_F", &.{.number_literal});
    try testTokenize("0x0p0", &.{.number_literal});
    try testTokenize("0x0.0p0", &.{.number_literal});
    try testTokenize("0xff.ffp10", &.{.number_literal});
    try testTokenize("0xff.ffP10", &.{.number_literal});
    try testTokenize("0xffp10", &.{.number_literal});
    try testTokenize("0xff_ff.ff_ffp1_0_0_0", &.{.number_literal});
    try testTokenize("0xf_f_f_f.f_f_f_fp+1_000", &.{.number_literal});
    try testTokenize("0xf_f_f_f.f_f_f_fp-1_00_0", &.{.number_literal});

    try testTokenize("0x1e", &.{.number_literal});
    try testTokenize("0x1e0", &.{.number_literal});
    try testTokenize("0x1p", &.{.number_literal});
    try testTokenize("0xfp0z1", &.{.number_literal});
    try testTokenize("0xff.ffpff", &.{.number_literal});
    try testTokenize("0x0.p", &.{.number_literal});
    try testTokenize("0x0.z", &.{.number_literal});
    try testTokenize("0x0._", &.{.number_literal});
    try testTokenize("0x0_.0", &.{.number_literal});
    try testTokenize("0x0_.0.0", &.{ .number_literal, .period, .number_literal });
    try testTokenize("0x0._0", &.{.number_literal});
    try testTokenize("0x0.0_", &.{.number_literal});
    try testTokenize("0x0_p0", &.{.number_literal});
    try testTokenize("0x0_.p0", &.{.number_literal});
    try testTokenize("0x0._p0", &.{.number_literal});
    try testTokenize("0x0.0_p0", &.{.number_literal});
    try testTokenize("0x0._0p0", &.{.number_literal});
    try testTokenize("0x0.0p_0", &.{.number_literal});
    try testTokenize("0x0.0p+_0", &.{.number_literal});
    try testTokenize("0x0.0p-_0", &.{.number_literal});
    try testTokenize("0x0.0p0_", &.{.number_literal});
}

test "invalid token with unfinished escape right before eof" {
    try testTokenize("\"\\", &.{.invalid});
    try testTokenize("'\\", &.{.invalid});
    try testTokenize("'\\u", &.{.invalid});
}

test "null byte before eof" {
    try testTokenize("123 \x00 456", &.{ .number_literal, .invalid });
    try testTokenize("#\x00", &.{.invalid});
    try testTokenize("\\\\\x00", &.{.invalid});
    try testTokenize("\x00", &.{.invalid});
    try testTokenize("# NUL\x00\n", &.{.invalid});
}

test "invalid tabs and carriage returns" {
    try testTokenize("#\t", &.{.invalid});
    try testTokenize("# \t", &.{.invalid});

    // "Inside Line Comments and Documentation Comments, CR directly preceding
    // NL is unambiguously part of the newline sequence. It is accepted by the
    // grammar and removed by zig fmt, leaving only NL. CR anywhere else is
    // rejected by the grammar."
    // https://github.com/ziglang/zig-spec/issues/38
    try testTokenize("#\r", &.{.invalid});
    try testTokenize("# \r", &.{.invalid});
    try testTokenize("#\r ", &.{.invalid});
    try testTokenize("# \r ", &.{.invalid});
    try testTokenize("#\r\n", &.{});
    try testTokenize("# \r\n", &.{});
}

test "carriage returns in code" {
    // CR directly preceding NL is part of the newline sequence.
    try testTokenize("exit()\r\n", &.{ .identifier, .l_paren, .r_paren });
    try testTokenize("\r\nexit()\n", &.{ .identifier, .l_paren, .r_paren });
    try testTokenize("exit()\n\r\nexit()\n", &.{ .identifier, .l_paren, .r_paren, .identifier, .l_paren, .r_paren });
    try testTokenize(
        "comptime\n  foo\r\n\r\n  bar\n",
        &.{ .keyword_comptime, .indent, .identifier, .identifier, .dedent },
    );
    try testTokenize(
        "static foo = func() int\r\n  print(1)\r\nprint(2)\r\n",
        &.{ .keyword_static, .identifier, .equal, .keyword_func, .l_paren, .r_paren, .identifier, .indent, .identifier, .l_paren, .number_literal, .r_paren, .dedent, .identifier, .l_paren, .number_literal, .r_paren },
    );

    // A CR not directly preceding NL is rejected.
    try testTokenize("\r", &.{.invalid});
    try testTokenize("\ra", &.{.invalid});
    try testTokenize("exit()\r", &.{ .identifier, .l_paren, .r_paren, .invalid });
    try testTokenize("exit()\r\r\n", &.{ .identifier, .l_paren, .r_paren, .invalid });
    try testTokenize("exit()\n\rbad\n", &.{ .identifier, .l_paren, .r_paren, .invalid });
    try testTokenize("a \r b", &.{ .identifier, .invalid });
    try testTokenize("comptime foo\n\r  bar\n", &.{ .keyword_comptime, .identifier, .invalid });
}

test "token loc skips leading blank lines" {
    const cases = [_]struct { source: [:0]const u8, start: u32, end: u32 }{
        .{ .source = "\nexit()\n", .start = 1, .end = 5 },
        .{ .source = "\n\nexit()\n", .start = 2, .end = 6 },
        .{ .source = "\r\nexit()\n", .start = 2, .end = 6 },
        .{ .source = "\r\n\r\nexit()\n", .start = 4, .end = 8 },
    };
    for (cases) |case| {
        var tokenizer = try Tokenizer.init(std.testing.allocator, case.source);
        defer tokenizer.deinit();
        const token = try tokenizer.next();
        try std.testing.expectEqual(Token.Tag.identifier, token.tag);
        try std.testing.expectEqual(case.start, token.loc.start);
        try std.testing.expectEqual(case.end, token.loc.end);
    }
}

fn testTokenize(source: [:0]const u8, expected_token_tags: []const Token.Tag) !void {
    var tokenizer = try Tokenizer.init(std.testing.allocator, source);
    defer tokenizer.deinit();
    for (expected_token_tags) |expected_token_tag| {
        const token = try tokenizer.next();
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
    // Last token should always be eof, even when the last token was invalid,
    // in which case the tokenizer is in an invalid state, which can only be
    // recovered by opinionated means outside the scope of this implementation.
    const last_token = try tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    try std.testing.expectEqual(source.len, last_token.loc.start);
    try std.testing.expectEqual(source.len, last_token.loc.end);
}

test "comment indentation and trailing blank lines do not change blocks" {
    try testTokenize("a\n  b\n# outside\n      # deeper\n  c\n    ", &.{
        .identifier, .indent, .identifier, .identifier, .dedent,
    });
    try testTokenize("a\n    ", &.{.identifier});
    try testTokenize("a\n  # comment at eof", &.{.identifier});
}
