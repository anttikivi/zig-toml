const Scanner = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const DecodeOptions = @import("decoder.zig").DecodeOptions;
const Diagnostics = @import("decoder.zig").Diagnostics;
const Datetime = @import("value.zig").Datetime;
const Date = @import("value.zig").Date;
const Time = @import("value.zig").Time;

arena: Allocator,

/// The general-purpose allocator used to create the parsing arena. Here it is
/// used for allocating the diagnostics message if the decoding fails.
gpa: Allocator,
input: []const u8,
cursor: usize = 0,
diagnostics: ?*Diagnostics = null,

/// Sentinel character that marks the end of input.
const end_of_input: u8 = 0;

const Error = error{ InvalidControlCharacter, Reported };

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
        .arena = arena,
        .gpa = gpa,
        .input = input,
        .diagnostics = opts.diagnostics,
    };
}

pub fn nextKey(self: *Scanner) Error!Token {
    return self.next(true);
}

pub fn nextValue(self: *Scanner) Error!Token {
    return self.next(false);
}

fn next(self: *Scanner, comptime key_mode: bool) Error!Token {
    _ = key_mode;

    while (self.cursor < self.input.len) {
        const c = self.advance();
        switch (c) {
            '\n' => return .line_feed,
            ' ', '\t' => continue,
            '#' => {
                while (self.cursor < self.input.len) {
                    switch (self.advance()) {
                        '\n' => break,
                        0...8, 0x0a...0x1f, 0x7f => {
                            return self.fail(.{ .err = error.InvalidControlCharacter });
                        },
                        else => {},
                    }
                }
                continue;
            },
        }
    }

    return .end_of_file;
}

/// Moves the Scanner to the next position and returns the valid, read
/// character.
fn advance(self: *Scanner) u8 {
    if (self.cursor >= self.input.len) {
        return end_of_input;
    }

    const c = self.input[self.cursor];
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

/// Fail the parsing in the Scanner. This either fills the Diagnostics with
/// the appropriate information and returns `error.Reported` or returns
/// the given error.
fn fail(self: *const Scanner, opts: struct { err: Error, msg: ?[]const u8 = null }) Error {
    if (self.diagnostics) |*d| {
        const msg = if (opts.msg) |m| m else switch (opts.err) {
            error.InvalidControlCharacter => "invalid control character",
            error.Reported => @panic("fail with error.Reported"),
        };
        d.initLineKnown(self.gpa, msg, self.input, self.cursor, self.line);

        return error.Reported;
    }

    return opts.err;
}
