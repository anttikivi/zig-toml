const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn decode(gpa: Allocator) void {
    const arena: std.heap.ArenaAllocator = .init(gpa);
    _ = arena;
}
