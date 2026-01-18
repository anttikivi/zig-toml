const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const TomlVersion = @import("root.zig").TomlVersion;

pub const DecodeOptions = struct {
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
/// the `snippet` and `message` strings if the decoder has failed, and it is
/// allocated using the general-purpose allocator that was passed in to
/// `toml.decode`. This is done so that the diagnostics object can be safely
/// deallocated as the arena is not returned from `toml.decode` on errors.
pub const Diagnostics = struct {
    line: ?usize = null,
    column: ?usize = null,
    snippet: ?[]const u8 = null,
    message: ?[]const u8 = null,

    /// Initialize the given Diagnostics with the appropriate information when
    /// the current line is not known. The Diagnostics is modified in place and
    /// the line is calculated from the cursor position and the input.
    pub fn init(
        self: *@This(),
        gpa: Allocator,
        msg: []const u8,
        input: []const u8,
        cursor: usize,
    ) Allocator.Error!void {
        const line = 1 + std.mem.count(u8, input[0..cursor], "\n");
        try self.initLineKnown(gpa, msg, input, cursor, line);
    }

    /// Initialize the given Diagnostics with the appropriate information.
    pub fn initLineKnown(
        self: *@This(),
        gpa: Allocator,
        msg: []const u8,
        input: []const u8,
        cursor: usize,
        line: usize,
    ) Allocator.Error!void {
        const start = std.mem.lastIndexOfScalar(u8, input[0..cursor], '\n') orelse 0;
        const end = std.mem.indexOfScalarPos(u8, input, cursor, '\n') orelse input.len;
        const col = (cursor - start) + 1;
        self.line = line;
        self.column = col;
        self.snippet = try gpa.dupe(u8, input[(if (start > 0) start + 1 else start)..end]);
        self.message = try gpa.dupe(u8, msg);
    }

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        if (self.snippet) |s| {
            gpa.free(s);
        }

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
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const allocator = arena.allocator();

    const owned_input = if (options.borrow_input) input else try allocator.dupe(u8, input);

    const parser: Parser = .init(allocator, gpa, owned_input, options);
    _ = parser;

    return .{
        .arena = arena,
        .input = owned_input,
    };
}
