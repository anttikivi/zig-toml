const std = @import("std");

pub const decode = @import("decoder.zig").decode;

/// TomlVersion represents the TOML versions that this parser supports that can
/// be passed in to the functions with the parsing options.
pub const TomlVersion = enum {
    @"1.1.0",
    @"1.0.0",
};

test {
    std.testing.refAllDecls(@This());
}
