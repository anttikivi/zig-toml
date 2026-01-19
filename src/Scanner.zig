const Scanner = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

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

const Error = Allocator.Error || error{ InvalidControlCharacter, Reported };

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
            else => return .end_of_file, // TODO: Handle.
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

    return self.input[self.cursor];
}

/// Fail the parsing in the Scanner. This either fills the Diagnostics with
/// the appropriate information and returns `error.Reported` or returns
/// the given error.
fn fail(self: *const Scanner, opts: struct { err: Error, msg: ?[]const u8 = null }) Error {
    if (self.diagnostics) |d| {
        const msg = if (opts.msg) |m| m else switch (opts.err) {
            error.InvalidControlCharacter => "invalid control character",
            error.Reported => @panic("fail with error.Reported"),
            // OOM should not go through this function.
            error.OutOfMemory => @panic("fail with error.OutOfMemory"),
        };
        try d.initLineKnown(self.gpa, msg, self.input, self.cursor, self.line);

        return error.Reported;
    }

    return opts.err;
}

test nextKey {
    const cases = [_]struct { input: []const u8, seq: []const Token }{
        .{
            .input =
            \\
            \\
            ,
            .seq = &[_]Token{
                .line_feed,
                .end_of_file,
            },
        },
        .{
            .input =
            \\# This is comment
            \\
            ,
            .seq = &[_]Token{
                .end_of_file,
            },
        },
        .{
            .input =
            \\# This is comment
            \\
            \\
            ,
            .seq = &[_]Token{
                .line_feed,
                .end_of_file,
            },
        },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = init(allocator, std.testing.allocator, case.input, .{});

        for (case.seq) |expected| {
            const actual = try scanner.nextKey();
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test nextValue {}
