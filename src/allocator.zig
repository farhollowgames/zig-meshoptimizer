//! How the library allocates: every function that needs memory takes a
//! `std.mem.Allocator` and uses it only for scratch memory it frees before
//! returning, in stack order, as the original's allocator hooks are used.
//!
//! Translated from meshoptimizer's allocator.cpp and the meshopt_Allocator
//! class of meshoptimizer.h.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The scratch memory of one call. Each allocation lives until `deinit`,
/// which frees them newest first, unless `free` releases the newest one
/// sooner. Stack-ordered allocators, such as `std.heap.FixedBufferAllocator`
/// or a `std.heap.StackFallbackAllocator`, can rely on that order.
///
/// A slice it hands out is invalid after `deinit`, or after `free` of it.
pub const Scratch = struct {
    gpa: Allocator,
    blocks: [capacity]Block = undefined,
    count: usize = 0,

    /// The most allocations one call makes at once.
    pub const capacity = 24;

    const Block = struct {
        bytes: []u8,
        alignment: std.mem.Alignment,
    };

    pub fn init(gpa: Allocator) Scratch {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Scratch) void {
        while (self.count > 0) {
            self.count -= 1;
            const block = self.blocks[self.count];
            self.gpa.rawFree(block.bytes, block.alignment, @returnAddress());
        }
        self.* = undefined;
    }

    /// `n` uninitialized items of `T`.
    pub fn alloc(self: *Scratch, comptime T: type, n: usize) Allocator.Error![]T {
        assert(self.count < capacity);
        const items = try self.gpa.alloc(T, n);
        // Zero-length slices own no memory; there is nothing to free.
        if (items.len == 0) return items;
        self.blocks[self.count] = .{
            .bytes = std.mem.sliceAsBytes(items),
            .alignment = .of(T),
        };
        self.count += 1;
        return items;
    }

    /// Frees `items`, which must be the newest allocation still live.
    pub fn free(self: *Scratch, items: anytype) void {
        const bytes = std.mem.sliceAsBytes(items);
        if (bytes.len == 0) return;
        assert(self.count > 0);
        self.count -= 1;
        const block = self.blocks[self.count];
        assert(block.bytes.ptr == bytes.ptr);
        self.gpa.rawFree(block.bytes, block.alignment, @returnAddress());
    }
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "scratch frees newest first" {
    var buffer: [256]u8 align(16) = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var scratch: Scratch = .init(fixed.allocator());
    const a = try scratch.alloc(u32, 4);
    const b = try scratch.alloc(u64, 2);
    scratch.free(b);
    const c = try scratch.alloc(u8, 3);
    _ = a;
    _ = c;
    scratch.deinit();
    // A fixed buffer only reclaims stack-ordered frees: all of it is back.
    try testing.expectEqual(0, fixed.end_index);
}
