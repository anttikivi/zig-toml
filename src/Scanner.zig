const Scanner = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const DecodeOptions = @import("decoder.zig").DecodeOptions;
const Diagnostics = @import("decoder.zig").Diagnostics;
const TomlVersion = @import("root.zig").TomlVersion;
const Datetime = @import("value.zig").Datetime;
const Date = @import("value.zig").Date;
const Time = @import("value.zig").Time;

features: Features,
arena: Allocator,

/// The general-purpose allocator used to create the parsing arena. Here it is
/// used for allocating the diagnostics message if the decoding fails.
gpa: Allocator,
input: []const u8,
cursor: usize = 0,
line: usize = 1,
diagnostics: ?*Diagnostics = null,

/// Sentinel character that marks the end of input.
const end_of_input: u8 = 0;

const Error = Allocator.Error || error{
    InvalidControlCharacter,
    InvalidEscapeSequence,
    UnexpectedToken,
    UnterminatedString,
    Reported,
};

/// Feature flags that determine which TOML features that have changed since
/// 1.0.0 are supported.
const Features = packed struct {
    escape_e: bool = false,
    escape_xhh: bool = false,

    fn init(toml_version: TomlVersion) @This() {
        return switch (toml_version) {
            .@"1.0.0" => .{},
            .@"1.1.0" => .{
                .escape_e = true,
                .escape_xhh = true,
            },
        };
    }
};

const Token = union(enum) {
    dot,
    equal,
    comma,
    left_bracket, // [
    double_left_bracket, // [[
    right_bracket, // ]
    double_right_bracket, // ]]
    left_brace, // {
    right_brace, // }

    literal: []const u8,
    string: []const u8,
    multiline_string: []const u8,
    literal_string: []const u8,
    multiline_literal_string: []const u8,

    int: i64,
    float: f64,
    bool: bool,

    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,

    line_feed,
    end_of_file,
};

pub fn init(arena: Allocator, gpa: Allocator, input: []const u8, opts: DecodeOptions) Scanner {
    return .{
        .features = Features.init(opts.toml_version),
        .arena = arena,
        .gpa = gpa,
        .input = input,
        .diagnostics = opts.diagnostics,
    };
}

/// Returns the next valid token from the stored TOML input when the parsing is
/// at a key.
pub fn nextKey(self: *Scanner) Error!Token {
    return self.next(true);
}

/// Returns the next valid token from the stored TOML input when the parsing is
/// at a value.
pub fn nextValue(self: *Scanner) Error!Token {
    return self.next(false);
}

/// Returns the next valid token from the stored TOML input.
fn next(self: *Scanner, comptime key_mode: bool) Error!Token {
    while (self.cursor < self.input.len) {
        const c = self.nextChar();
        switch (c) {
            '\n' => return .line_feed,
            ' ', '\t' => continue,
            '#' => {
                while (self.cursor < self.input.len) {
                    switch (self.nextChar()) {
                        // \n, marked as hex to make it clearer that it's one of
                        // the characters that are not permitted.
                        0x0a => break,
                        0...8, 0x0b...0x1f, 0x7f => {
                            return self.fail(.{ .err = error.InvalidControlCharacter });
                        },
                        else => {},
                    }
                }
                continue;
            },
            '.' => return .dot,
            '=' => return .equal,
            ',' => return .comma,
            '[' => {
                if (key_mode and self.peek() == '[') {
                    _ = self.nextChar();
                    return .double_left_bracket;
                }

                return .left_bracket;
            },
            ']' => {
                if (key_mode and self.peek() == ']') {
                    _ = self.nextChar();
                    return .double_right_bracket;
                }

                return .right_bracket;
            },
            '{' => return .left_brace,
            '}' => return .right_brace,
            '"' => {
                // Move back so that `scanString` finds the first quote.
                self.cursor -= 1;
                return self.scanString();
            },
            '\'' => {
                self.cursor -= 1;
                return self.scanLiteralString();
            },
            else => return .end_of_file, // TODO: Handle literals.
        }
    }

    return .end_of_file;
}

/// Moves the Scanner to the next position and returns the valid, read
/// character.
fn nextChar(self: *Scanner) u8 {
    if (self.cursor >= self.input.len) {
        return end_of_input;
    }

    var c = self.input[self.cursor];
    self.cursor += 1;

    // CRLF counts as a single newline character.
    if (c == '\r' and self.cursor < self.input.len and self.input[self.cursor] == '\n') {
        c = '\n';
        self.cursor += 1;
    }

    if (c == '\n') {
        self.line += 1;
    }

    return c;
}

/// Take a look at the next character without advancing.
fn peek(self: *const Scanner) u8 {
    if (self.cursor >= self.input.len) {
        return end_of_input;
    }

    assert(self.input[self.cursor] != end_of_input);

    return self.input[self.cursor];
}

fn matchN(self: *const Scanner, c: u8, n: comptime_int) bool {
    comptime if (n < 2) {
        @compileError("calling Scanner.matchN with n < 2");
    };

    assert(c != '\n');

    if (self.cursor + n > self.input.len) {
        return false;
    }

    inline for (0..n) |i| {
        if (self.input[self.cursor + i] != c) {
            return false;
        }
    }

    return true;
}

fn scanString(self: *Scanner) !Token {
    assert(self.peek() == '"');

    if (self.matchN('"', 3)) {
        return self.scanMultilineString();
    }

    _ = self.nextChar(); // skip opening quote
    const start = self.cursor;

    while (self.cursor < self.input.len and self.input[self.cursor] != '"') {
        var c = self.input[self.cursor];
        if (c == '\n' or c == '\r') {
            return self.fail(.{ .err = error.UnterminatedString });
        }

        if (c == '\\') {
            self.cursor += 1;

            if (self.cursor >= self.input.len) {
                return self.fail(.{ .err = error.UnterminatedString });
            }

            c = self.input[self.cursor];

            switch (c) {
                // Skip the "normal" escape sequences.
                '"', '\\', 'b', 'f', 'n', 'r', 't' => self.cursor += 1,

                // Escape character in TOML 1.1.0.
                'e' => if (self.features.escape_e) {
                    self.cursor += 1;
                } else {
                    return self.fail(.{ .err = error.InvalidEscapeSequence });
                },

                // \xHH for Unicode codepoints < 256.
                'x' => if (self.features.escape_xhh) {
                    self.cursor += 1;

                    if (self.cursor + 2 > self.input.len) {
                        return self.fail(.{ .err = error.InvalidEscapeSequence });
                    }

                    for (0..2) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .err = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                } else {
                    return self.fail(.{ .err = error.InvalidEscapeSequence });
                },

                'u' => {
                    self.cursor += 1;

                    if (self.cursor + 4 > self.input.len) {
                        return self.fail(.{ .err = error.InvalidEscapeSequence });
                    }

                    for (0..4) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .err = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                'U' => {
                    self.cursor += 1;

                    if (self.cursor + 8 > self.input.len) {
                        return self.fail(.{ .err = error.InvalidEscapeSequence });
                    }

                    for (0..8) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .err = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                else => return self.fail(.{ .err = error.InvalidEscapeSequence }),
            }
        } else if (isValidChar(c) or c == ' ' or c == '\t') {
            // TODO: See the uses for `isValidChar` and determine if
            // the whitespaces should be included in it.
            self.cursor += 1;
        } else {
            return self.fail(.{ .err = error.InvalidControlCharacter });
        }
    }

    // TODO: Do we compare self.input[self.cursor] != '"' here?
    if (self.cursor >= self.input.len) {
        return self.fail(.{ .err = error.UnterminatedString });
    }

    assert(self.input[self.cursor] == '"');

    const result = self.input[start..self.cursor];
    self.cursor += 1;

    return .{ .string = result };
}

fn scanMultilineString(self: *Scanner) !Token {
    assert(self.matchN('"', 3));

    self.cursor += 3; // skip opening """

    // Newline that immediately follows """ is trimmed.
    if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
        self.cursor += 1;
        self.line += 1;
    } else if (self.cursor + 1 < self.input.len and
        self.input[self.cursor] == '\r' and
        self.input[self.cursor + 1] == '\n')
    {
        self.cursor += 2;
        self.line += 1;
    }

    const start = self.cursor;

    while (self.cursor < self.input.len) {
        var c = self.input[self.cursor];

        if (c == '"') {
            var i: usize = 0;

            while (self.cursor + i < self.input.len and self.input[self.cursor + i] == '"') {
                i += 1;
            }

            if (i >= 3) {
                if (i > 5) {
                    return self.fail(.{
                        .err = error.UnexpectedToken,
                        .msg = "invalid closing quotes",
                    });
                }

                const extra = i - 3;
                const result = self.input[start .. self.cursor + extra];
                self.cursor += i;

                assert(!std.mem.startsWith(u8, result, "\"\"\""));
                assert(!std.mem.endsWith(u8, result, "\"\"\""));

                return .{ .multiline_string = result };
            } else {
                self.cursor += i; // eat the non-closing quotes
            }
        } else if (c == '\\') {
            self.cursor += 1;

            if (self.cursor >= self.input.len) {
                return self.fail(.{ .err = error.UnterminatedString });
            }

            c = self.input[self.cursor];

            switch (c) {
                '"', '\\', 'b', 'f', 'n', 'r', 't' => self.cursor += 1,

                'e' => if (self.features.escape_e) {
                    self.cursor += 1;
                } else {
                    return self.fail(.{ .err = error.InvalidEscapeSequence });
                },

                'x' => if (self.features.escape_xhh) {
                    self.cursor += 1;

                    if (self.cursor + 2 > self.input.len) {
                        return self.fail(.{ .err = error.InvalidEscapeSequence });
                    }

                    for (0..2) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .err = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                } else {
                    return self.fail(.{ .err = error.InvalidEscapeSequence });
                },

                'u' => {
                    self.cursor += 1;

                    if (self.cursor + 4 > self.input.len) {
                        return self.fail(.{ .err = error.InvalidEscapeSequence });
                    }

                    for (0..4) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .err = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                'U' => {
                    self.cursor += 1;

                    if (self.cursor + 8 > self.input.len) {
                        return self.fail(.{ .err = error.InvalidEscapeSequence });
                    }

                    for (0..8) |_| {
                        if (!std.ascii.isHex(self.input[self.cursor])) {
                            return self.fail(.{ .err = error.InvalidEscapeSequence });
                        }

                        self.cursor += 1;
                    }
                },

                // Line-ending backslash.
                '\n' => {
                    self.cursor += 1;
                    self.line += 1;
                    try self.skipLineEndingWhitespace();
                },

                '\r' => if (self.cursor + 1 < self.input.len and
                    self.input[self.cursor + 1] == '\n')
                {
                    self.cursor += 2;
                    self.line += 1;
                    try self.skipLineEndingWhitespace();
                } else {
                    return self.fail(.{ .err = error.InvalidEscapeSequence });
                },

                ' ', '\t' => {
                    while (self.cursor < self.input.len) {
                        c = self.input[self.cursor];
                        if (c == ' ' or c == '\t') {
                            self.cursor += 1;
                        } else if (c == '\n') {
                            self.cursor += 1;
                            self.line += 1;
                            break;
                        } else if (c == '\r' and self.cursor + 1 < self.input.len and
                            self.input[self.cursor + 1] == '\n')
                        {
                            self.cursor += 2;
                            self.line += 1;
                            break;
                        } else {
                            return self.fail(.{ .err = error.InvalidEscapeSequence });
                        }
                    }

                    // After finding newline, eat the rest of the whitespace chars.
                    try self.skipLineEndingWhitespace();
                },

                else => return self.fail(.{ .err = error.InvalidEscapeSequence }),
            }
        } else if (c == '\n') {
            self.cursor += 1;
            self.line += 1;
        } else if (c == '\r' and self.cursor + 1 < self.input.len and
            self.input[self.cursor + 1] == '\n')
        {
            self.cursor += 2;
            self.line += 1;
        } else if (isValidChar(c) or c == ' ' or c == '\t') {
            self.cursor += 1;
        } else {
            return self.fail(.{ .err = error.InvalidControlCharacter });
        }
    }

    return self.fail(.{ .err = error.UnterminatedString });
}

fn scanLiteralString(self: *Scanner) Error!Token {
    assert(self.peek() == '\'');

    if (self.matchN('\'', 3)) {
        return self.scanMultilineLiteralString();
    }

    _ = self.nextChar();
    const start = self.cursor;

    while (self.cursor < self.input.len and self.input[self.cursor] != '\'') : (self.cursor += 1) {
        const c = self.input[self.cursor];
        if (c == '\n' or c == '\r') {
            return self.fail(.{ .err = error.UnterminatedString });
        }

        if (!isValidChar(c) and c != '\t') {
            return self.fail(.{ .err = error.InvalidControlCharacter });
        }
    }

    // TODO: Do we compare self.input[self.cursor] != '\'' here?
    if (self.cursor >= self.input.len) {
        return self.fail(.{ .err = error.UnterminatedString });
    }

    assert(self.input[self.cursor] == '\'');

    const result = self.input[start..self.cursor];
    self.cursor += 1;

    return .{ .literal_string = result };
}

fn scanMultilineLiteralString(self: *Scanner) Error!Token {
    assert(self.matchN('\'', 3));

    self.cursor += 3;

    if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
        self.cursor += 1;
        self.line += 1;
    } else if (self.cursor + 1 < self.input.len and
        self.input[self.cursor] == '\r' and
        self.input[self.cursor + 1] == '\n')
    {
        self.cursor += 2;
        self.line += 1;
    }

    const start = self.cursor;

    while (self.cursor < self.input.len) {
        const c = self.input[self.cursor];

        if (c == '\'') {
            var i: usize = 0;
            while (self.cursor < self.input.len and self.input[self.cursor + i] == '\'') {
                i += 1;
            }

            if (i >= 3) {
                if (i > 5) {
                    return self.fail(.{
                        .err = error.UnexpectedToken,
                        .msg = "invalid closing quotes",
                    });
                }

                const extra = i - 3;
                const result = self.input[start .. self.cursor + extra];
                self.cursor += i;

                assert(!std.mem.startsWith(u8, result, "'''"));
                assert(!std.mem.endsWith(u8, result, "'''"));

                return .{ .multiline_literal_string = result };
            } else {
                self.cursor += i;
            }
        } else if (c == '\n') {
            self.cursor += 1;
            self.line += 1;
        } else if (c == '\r' and self.cursor + 1 < self.input.len and
            self.input[self.cursor + 1] == '\n')
        {
            self.cursor += 2;
            self.line += 1;
        } else if (isValidChar(c) or c == ' ' or c == '\t') {
            self.cursor += 1;
        } else {
            return self.fail(.{ .err = error.InvalidEscapeSequence });
        }
    }

    return self.fail(.{ .err = error.UnterminatedString });
}

/// Skips the whitespace after a line-ending backslash in a multiline string.
fn skipLineEndingWhitespace(self: *Scanner) !void {
    while (self.cursor < self.input.len) {
        const c = self.input[self.cursor];
        if (c == ' ' or c == '\t') {
            self.cursor += 1;
        } else if (c == '\n') {
            self.cursor += 1;
            self.line += 1;
        } else if (c == '\r' and self.cursor + 1 < self.input.len and
            self.input[self.cursor + 1] == '\n')
        {
            self.cursor += 2;
            self.line += 1;
        } else {
            return;
        }
    }

    return self.fail(.{ .err = error.UnterminatedString });
}

/// Fail the parsing in the Scanner. This either fills the Diagnostics with
/// the appropriate information and returns `error.Reported` or returns
/// the given error.
fn fail(self: *const Scanner, opts: struct { err: Error, msg: ?[]const u8 = null }) Error {
    if (self.diagnostics) |d| {
        const msg = if (opts.msg) |m| m else switch (opts.err) {
            error.InvalidControlCharacter => "invalid control character",
            error.InvalidEscapeSequence => "invalid escape sequence",
            error.UnexpectedToken => "unexpected token",
            error.UnterminatedString => "unterminated string",
            error.Reported => @panic("fail with error.Reported"),
            // OOM should not go through this function.
            error.OutOfMemory => @panic("fail with error.OutOfMemory"),
        };
        try d.initLineKnown(self.gpa, msg, self.input, self.cursor, self.line);

        return error.Reported;
    }

    return opts.err;
}

fn isValidChar(c: u8) bool {
    return std.ascii.isPrint(c) or (c & 0x80) != 0;
}

const TestToken = union(enum) {
    dot,
    equal,
    comma,
    left_bracket, // [
    double_left_bracket, // [[
    right_bracket, // ]
    double_right_bracket, // ]]
    left_brace, // {
    right_brace, // }

    literal: []const u8,
    string: []const u8,
    multiline_string: []const u8,
    literal_string: []const u8,
    multiline_literal_string: []const u8,

    int: i64,
    float: f64,
    bool: bool,

    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,

    line_feed,
    end_of_file,

    err: Error,
};

const next_test_cases = [_]struct { input: []const u8, seq: []const TestToken }{
    .{
        .input =
        \\
        \\
        ,
        .seq = &[_]TestToken{
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\# This is comment
        \\
        ,
        .seq = &[_]TestToken{
            .end_of_file,
        },
    },
    .{
        .input =
        \\# This is comment
        \\
        \\
        ,
        .seq = &[_]TestToken{
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is a string"
        ,
        .seq = &[_]TestToken{
            .{ .string = "This is a string" },
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is a string"
        \\
        ,
        .seq = &[_]TestToken{
            .{ .string = "This is a string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is a string
        \\
        ,
        .seq = &[_]TestToken{.{ .err = error.UnterminatedString }},
    },
    .{
        .input =
        \\"This is \uFFFF a string"
        \\
        ,
        .seq = &[_]TestToken{
            .{ .string = "This is \\uFFFF a string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"This is \uFFF a string"
        \\
        ,
        .seq = &[_]TestToken{.{ .err = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \uFFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a\n   multiline \\uFFFF string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \uFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .err = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \UFFFFFFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a\n   multiline \\UFFFFFFFF string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a
        \\   multiline \UFFFFFFF string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .err = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a \
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a \\\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a \word
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .err = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""This is a \ word
        \\   multiline string
        \\"""
        \\
        ,
        .seq = &[_]TestToken{.{ .err = error.InvalidEscapeSequence }},
    },
    .{
        .input =
        \\"""
        \\This is a multiline string"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a multiline string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""
        \\This is a multiline string""
        \\
        ,
        .seq = &[_]TestToken{.{ .err = error.UnterminatedString }},
    },
    .{
        .input =
        \\"""
        \\This is a multiline
        \\
        \\string"""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a multiline\n\nstring" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\"""This is a multiline string"""""
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_string = "This is a multiline string\"\"" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'This is a literal string'
        \\
        ,
        .seq = &[_]TestToken{
            .{ .literal_string = "This is a literal string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'This \\ is a literal string'
        \\
        ,
        .seq = &[_]TestToken{
            .{ .literal_string = "This \\\\ is a literal string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input = "'This is\ta literal string'",
        .seq = &[_]TestToken{
            .{ .literal_string = "This is\ta literal string" },
            .end_of_file,
        },
    },
    .{
        .input = "'This is\\ta literal string'",
        .seq = &[_]TestToken{
            .{ .literal_string = "This is\\ta literal string" },
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is a
        \\   multiline string
        \\'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is a ''multiline string'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a ''multiline string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is a ''multiline string'''''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a ''multiline string''" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''This is \\a multiline string'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is \\\\a multiline string" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''
        \\This is a
        \\   multiline string
        \\'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
    .{
        .input =
        \\'''
        \\  This is a
        \\   multiline string
        \\'''
        \\
        ,
        .seq = &[_]TestToken{
            .{ .multiline_literal_string = "  This is a\n   multiline string\n" },
            .line_feed,
            .end_of_file,
        },
    },
};

fn convertUnion(source: anytype, comptime Dest: type) Dest {
    if (!builtin.is_test) {
        @compileError("convertUnion may only be used in tests");
    }

    const Source = @TypeOf(source);
    const info = @typeInfo(Source);

    if (info != .@"union" or info.@"union".tag_type == null) {
        @compileError("convertUnion only works on tagged unions");
    }

    return switch (source) {
        inline else => |payload, tag| {
            const field_name = @tagName(tag);
            if (!@hasField(Dest, field_name)) {
                @compileError(
                    "destination " ++ @typeName(Dest) ++ " is missing field: " ++ field_name,
                );
            }
            return @unionInit(Dest, field_name, payload);
        },
    };
}

fn testNextKey(self: *Scanner) Error!TestToken {
    if (!builtin.is_test) {
        @compileError("testNextKey may only be used in tests");
    }

    const result = try self.nextKey();
    return convertUnion(result, TestToken);
}

fn testNextValue(self: *Scanner) Error!TestToken {
    if (!builtin.is_test) {
        @compileError("testNextValue may only be used in tests");
    }

    const result = try self.nextValue();
    return convertUnion(result, TestToken);
}

test nextKey {
    for (next_test_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = init(allocator, std.testing.allocator, case.input, .{});

        for (case.seq) |expected| {
            switch (expected) {
                .err => |e| {
                    try std.testing.expectError(e, scanner.testNextKey());
                },
                else => {
                    const actual = try scanner.testNextKey();
                    switch (actual) {
                        .string => |actual_str| {
                            try std.testing.expect(expected == .string);
                            try std.testing.expectEqualStrings(expected.string, actual_str);
                        },
                        .multiline_string => |actual_str| {
                            try std.testing.expect(expected == .multiline_string);
                            try std.testing.expectEqualStrings(expected.multiline_string, actual_str);
                        },
                        .literal_string => |actual_str| {
                            try std.testing.expect(expected == .literal_string);
                            try std.testing.expectEqualStrings(expected.literal_string, actual_str);
                        },
                        .multiline_literal_string => |actual_str| {
                            try std.testing.expect(expected == .multiline_literal_string);
                            try std.testing.expectEqualStrings(
                                expected.multiline_literal_string,
                                actual_str,
                            );
                        },
                        else => try std.testing.expectEqual(expected, actual),
                    }
                },
            }
        }
    }
}

test nextValue {
    for (next_test_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = init(allocator, std.testing.allocator, case.input, .{});

        for (case.seq) |expected| {
            switch (expected) {
                .err => |e| {
                    try std.testing.expectError(e, scanner.testNextValue());
                },
                else => {
                    const actual = try scanner.testNextValue();
                    switch (actual) {
                        .string => |actual_str| {
                            try std.testing.expect(expected == .string);
                            try std.testing.expectEqualStrings(expected.string, actual_str);
                        },
                        .multiline_string => |actual_str| {
                            try std.testing.expect(expected == .multiline_string);
                            try std.testing.expectEqualStrings(expected.multiline_string, actual_str);
                        },
                        .literal_string => |actual_str| {
                            try std.testing.expect(expected == .literal_string);
                            try std.testing.expectEqualStrings(expected.literal_string, actual_str);
                        },
                        .multiline_literal_string => |actual_str| {
                            try std.testing.expect(expected == .multiline_literal_string);
                            try std.testing.expectEqualStrings(
                                expected.multiline_literal_string,
                                actual_str,
                            );
                        },
                        else => try std.testing.expectEqual(expected, actual),
                    }
                },
            }
        }
    }
}
