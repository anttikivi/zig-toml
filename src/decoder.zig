const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const TomlVersion = @import("root.zig").TomlVersion;

const DecodeOptions = struct {
    /// Whether to borrow the input string or to copy it to the result type.
    borrow_input: bool = false,

    /// Optional diagnostics object that contains additional information if
    /// the decoder fails.
    diagnostics: ?*Diagnostics = null,

    /// The version of TOML to accept in the decoding.
    tomlVersion: TomlVersion = .@"1.1.0",
};

/// Diagnostics can contain additional information about errors in decoding. To
/// enable diagnostics, initialize the diagnostics object by
/// `var diagnostics = Diagnostics{};` and pass it with the decoding options:
/// `const opts = DecodeOptions{ .diagnostics = &diagnostics };`.
///
/// The caller must call `deinit` on the diagnostics object. It owns
/// the `message` string if the decoder has failed, and it is allocated using
/// the general-purpose allocator that was passed in to `toml.decode`.
/// The `snippet` points to the same string that the parsed result would point
/// to.
const Diagnostics = struct {
    line: ?usize = null,
    column: ?usize = null,
    snippet: ?[]const u8 = null,
    message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        if (self.message) |m| {
            gpa.free(m);
        }
    }
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
