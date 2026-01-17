const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @import("Scanner.zig");

arena: Allocator,
scanner: Scanner,

const Error = Scanner.Error || error{UnexpectedToken};

const ParsingTable = struct {};

pub fn init(arena: Allocator, input: []const u8) Parser {
    return .{
        .arena = arena,
        .scanner = Scanner.init(arena, input),
    };
}

pub fn parse(self: *Parser) Error!ParsingTable {
    const root: ParsingTable = .{};
    const current: *ParsingTable = &root;
    _ = current;

    while (self.scanner.cursor < self.scanner.input.len) {
        const token = try self.scanner.nextKey();

        switch (token) {
            .end_of_file => break,
            else => error.UnexpectedToken,
        }
    }

    return root;
}
