const Scanner = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Datetime = @import("value.zig").Datetime;
const Date = @import("value.zig").Date;
const Time = @import("value.zig").Time;

arena: Allocator,
input: []const u8,
cursor: usize = 0,

const Error = error{};

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

pub fn init(arena: Allocator, input: []const u8) Scanner {
    return .{
        .arena = arena,
        .input = input,
    };
}

pub fn nextKey(self: *Scanner) Error!Token {
    return self.next(true);
}

pub fn nextValue(self: *Scanner) Error!Token {
    return self.next(false);
}

fn next(self: *Scanner, comptime key_mode: bool) Error!Token {
    _ = self;
    _ = key_mode;

    return .end_of_file;
}
