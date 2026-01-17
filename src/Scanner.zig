const Scanner = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

arena: Allocator,
input: []const u8,

pub fn init(arena: Allocator, input: []const u8) Scanner {
    return .{
        .arena = arena,
        .input = input,
    };
}
