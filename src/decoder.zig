const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const TomlVersion = @import("root.zig").TomlVersion;

const DecodeOptions = struct {
    /// Whether to borrow the input string or to copy it to the result type.
    borrow_input: bool = false,

    /// The version of TOML to accept in the decoding.
    tomlVersion: TomlVersion = .@"1.1.0",
};

const Parsed = struct {
    arena: std.heap.ArenaAllocator,

    /// The input buffer of the parsed TOML document. It is either borrowed or
    /// owned by the arena depending on `DecodeOptions`.
    input: []const u8,
};

pub fn decode(gpa: Allocator, input: []const u8, options: DecodeOptions) !Parsed {
    const arena: std.heap.ArenaAllocator = .init(gpa);
    const allocator = arena.allocator();

    const owned_input = if (options.borrow_input) input else try allocator.dupe(u8, input);

    const parser: Parser = .init(allocator, owned_input);
    _ = parser;

    return .{
        .arena = arena,
        .input = owned_input,
    };
}
