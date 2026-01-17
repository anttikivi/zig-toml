const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @import("Scanner.zig");

arena: Allocator,
scanner: Scanner,

pub fn init(arena: Allocator, input: []const u8) Parser {
    return .{
        .arena = arena,
        .scanner = Scanner.init(arena, input),
    };
}
