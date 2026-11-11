//! How the library allocates: every function that needs memory takes a
//! `std.mem.Allocator` and uses it only for scratch memory it frees before
//! returning, in stack order, as the original's allocator hooks are used.
//! The exception is `clusterlod.build`, which grows lists as the original's
//! demo grows vectors, and needs a general-purpose allocator.
//! `AllocatorCache` keeps blocks of that memory for threads to reuse.
//!
//! Translated from meshoptimizer's allocator.cpp and the meshopt_Allocator
//! class of meshoptimizer.h.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The scratch memory of one call. Each allocation lives until `deinit`,
/// which frees them newest first, unless `free` releases the newest one
/// sooner. Stack-ordered allocators, such as `std.heap.FixedBufferAllocator`,
/// a `std.heap.BufferFirstAllocator` or an `AllocatorCache` handle, can rely
/// on that order.
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

/// A fixed set of memory blocks that threads reuse for scratch memory, in
/// place of asking `backing` on every call: the original's allocation cache
/// (`meshopt_setAllocatorCache`), as an allocator the caller makes and
/// passes.
///
/// Each thread allocates through a `Local` handle of its own. A handle takes
/// a free block on its first allocation that fits in one, hands out the
/// block's memory in order, and gives the block back once all of it is
/// freed, so a thread holds one block at a time: give a cache as many blocks
/// as threads that call the library at once. Requests that do not fit in
/// the block, need an alignment above 16 bytes, or find every block taken go
/// to `backing`, which must be thread-safe when several threads use the
/// cache.
///
/// The cache must not move while it has handles, and must outlive them.
pub const AllocatorCache = struct {
    /// A bit for each block no handle holds.
    free_blocks: FreeBlocks = .{ .mask = .init(0) },
    /// The blocks, `block_size` bytes each, one after another; empty in a
    /// cache that sends everything to `backing`.
    memory: []align(block_alignment.toByteUnits()) u8 = &.{},
    /// A multiple of 16, or 0 without blocks.
    block_size: usize = 0,
    /// A bit for each block.
    all_blocks: u64 = 0,
    backing: Allocator,

    /// The most blocks a cache has: one bit each in a `u64`.
    pub const block_count_max = 64;

    /// The alignment of every block and of every allocation in one.
    const block_alignment: std.mem.Alignment = .@"16";

    /// Handles write the mask when they take and return blocks, while every
    /// allocation reads the fields beside it: the alignment gives the mask a
    /// cache line of its own, so those reads do not wait on the writes.
    const FreeBlocks = struct {
        mask: std.atomic.Value(u64) align(std.atomic.cache_line),
    };

    /// `block_count` blocks of `block_size` bytes, rounded down to a
    /// multiple of 16, taken from `backing` in one allocation. A cache of no
    /// blocks takes no memory and sends every request to `backing`.
    pub fn init(
        backing: Allocator,
        block_count: usize,
        block_size: usize,
    ) Allocator.Error!AllocatorCache {
        assert(block_count <= block_count_max);
        assert(block_count == 0 or block_size >= 16);

        // Allocations in a block are aligned to 16 bytes, so the blocks use
        // only a 16-byte-aligned subset.
        const size = block_alignment.backward(block_size);
        if (block_count == 0 or size == 0) return .{ .backing = backing };

        const memory_size = if (block_count > std.math.maxInt(usize) / size)
            std.math.maxInt(usize)
        else
            block_count * size;
        const memory = try backing.alignedAlloc(u8, block_alignment, memory_size);
        const all_blocks = if (block_count >= 64)
            std.math.maxInt(u64)
        else
            (@as(u64, 1) << @intCast(block_count)) - 1;
        return .{
            .free_blocks = .{ .mask = .init(all_blocks) },
            .memory = memory,
            .block_size = size,
            .all_blocks = all_blocks,
            .backing = backing,
        };
    }

    /// Gives the blocks' memory back to `backing`. Every block must be back:
    /// no handle holds memory from them, and no thread uses a handle.
    pub fn deinit(self: *AllocatorCache) void {
        assert(self.free_blocks.mask.load(.seq_cst) == self.all_blocks);
        self.backing.free(self.memory);
        self.* = undefined;
    }

    /// Whether `ptr` points into the blocks.
    fn holds(self: *const AllocatorCache, ptr: [*]const u8) bool {
        return @intFromPtr(ptr) -% @intFromPtr(self.memory.ptr) < self.memory.len;
    }

    /// Whether `len` bytes fit in a block at `offset`: the original's test,
    /// which leaves at least a byte of the block after them.
    fn fits(block_size: usize, offset: usize, len: usize) bool {
        return len < block_size and offset < block_size - len;
    }

    /// Where the allocation after `len` bytes at `start` goes: on the next
    /// 16 bytes, and past at least one byte, even after an empty request.
    fn nextOffset(start: usize, len: usize) usize {
        return block_alignment.forward(start + @max(len, 1));
    }

    /// A thread's handle on a cache: the block it holds, if any, and where
    /// its next allocation in that block starts. `allocator` gives the
    /// `std.mem.Allocator` to pass to the library's functions.
    ///
    /// A handle must not outlive its cache, and one thread at a time uses
    /// it. Memory it hands out is invalid after its free. Memory from a
    /// block is freed newest first, as the library's functions free their
    /// scratch memory, and only the newest allocation in a block can change
    /// its size in place.
    pub const Local = struct {
        /// Handles side by side, as in an array, do not share a cache line.
        _: void align(std.atomic.cache_line) = {},
        cache: *AllocatorCache,
        /// The block this handle holds, from the allocation that takes it to
        /// the free that empties it.
        block: ?[*]u8 = null,
        /// Where the next allocation in `block` starts.
        offset: usize = 0,
        /// The bit of the block this handle held last, kept after the block
        /// goes back as the one to ask for first.
        block_mask: u64 = 0,

        pub fn init(cache: *AllocatorCache) Local {
            return .{ .cache = cache };
        }

        /// This handle's allocator, which points at the handle: the handle
        /// must stay in place while the allocator is in use.
        pub fn allocator(self: *Local) Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        fn alloc(
            context: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Local = @ptrCast(@alignCast(context));
            const cache = self.cache;
            if (alignment.compare(.gt, block_alignment)) {
                return cache.backing.rawAlloc(len, alignment, ret_addr);
            }

            // Take a free block on the first request that fits in one.
            if (self.block == null and len < cache.block_size and
                cache.free_blocks.mask.load(.monotonic) != 0)
            {
                self.takeBlock();
            }

            if (self.block) |block| {
                if (fits(cache.block_size, self.offset, len)) {
                    const start = self.offset;
                    self.offset = nextOffset(start, len);
                    return block + start;
                }
            }
            return cache.backing.rawAlloc(len, alignment, ret_addr);
        }

        /// Takes the block this handle held last if it is free, else the
        /// lowest free one; takes none when every block is taken.
        fn takeBlock(self: *Local) void {
            const cache = self.cache;
            var blocks = cache.free_blocks.mask.load(.monotonic);
            var mask: u64 = 0;
            while (true) {
                // The block held last may still be in this core's caches.
                mask = if (blocks & self.block_mask != 0)
                    self.block_mask
                else
                    blocks & (0 -% blocks);
                // No free block, and one is unlikely to come back soon.
                if (blocks == 0) break;
                // A failed exchange reloads the mask.
                blocks = cache.free_blocks.mask.cmpxchgWeak(
                    blocks,
                    blocks & ~mask,
                    .acquire,
                    .monotonic,
                ) orelse break;
            }
            if (mask == 0) return;

            const index: usize = @ctz(mask);
            self.block = cache.memory.ptr + index * cache.block_size;
            self.block_mask = mask;
        }

        fn free(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            const self: *Local = @ptrCast(@alignCast(context));
            const cache = self.cache;
            if (!cache.holds(memory.ptr)) return cache.backing.rawFree(memory, alignment, ret_addr);

            // The library frees scratch memory newest first, on the thread
            // that allocated it.
            assert(self.isNewest(memory));
            self.offset = @intFromPtr(memory.ptr) - @intFromPtr(self.block.?);

            // An empty block goes back; its mask stays, as the block to ask
            // for first next time.
            if (self.offset == 0) {
                _ = cache.free_blocks.mask.fetchOr(self.block_mask, .release);
                self.block = null;
            }
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *Local = @ptrCast(@alignCast(context));
            const cache = self.cache;
            if (!cache.holds(memory.ptr)) {
                return cache.backing.rawResize(memory, alignment, new_len, ret_addr);
            }
            return self.resizeInBlock(memory, new_len);
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Local = @ptrCast(@alignCast(context));
            const cache = self.cache;
            if (!cache.holds(memory.ptr)) {
                return cache.backing.rawRemap(memory, alignment, new_len, ret_addr);
            }
            return if (self.resizeInBlock(memory, new_len)) memory.ptr else null;
        }

        /// Moves the end of `memory` if it is the newest allocation in this
        /// handle's block and `new_len` bytes fit there; refuses otherwise.
        fn resizeInBlock(self: *Local, memory: []u8, new_len: usize) bool {
            if (!self.isNewest(memory)) return false;
            const start = @intFromPtr(memory.ptr) - @intFromPtr(self.block.?);
            if (!fits(self.cache.block_size, start, new_len)) return false;
            self.offset = nextOffset(start, new_len);
            return true;
        }

        /// Whether `memory`, inside the cache's blocks, is the newest
        /// allocation in this handle's block.
        fn isNewest(self: *const Local, memory: []const u8) bool {
            const block = self.block orelse return false;
            const start = @intFromPtr(memory.ptr) -% @intFromPtr(block);
            return start < self.offset and nextOffset(start, memory.len) == self.offset;
        }
    };
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

/// Fails unless `bytes` lies in block `index` of `cache`.
fn expectInBlock(cache: *const AllocatorCache, bytes: []const u8, index: usize) !void {
    const block_start = @intFromPtr(cache.memory.ptr) + index * cache.block_size;
    const start = @intFromPtr(bytes.ptr);
    try testing.expect(start >= block_start);
    try testing.expect(start + bytes.len <= block_start + cache.block_size);
}

fn freeMask(cache: *const AllocatorCache) u64 {
    return cache.free_blocks.mask.load(.monotonic);
}

test "a handle takes the lowest free block and gives it back once empty" {
    var cache: AllocatorCache = try .init(testing.allocator, 2, 64);
    defer cache.deinit();
    var local: AllocatorCache.Local = .init(&cache);
    const gpa = local.allocator();

    const a = try gpa.alloc(u8, 10);
    try testing.expectEqual(@intFromPtr(cache.memory.ptr), @intFromPtr(a.ptr));
    try testing.expectEqual(0b10, freeMask(&cache));
    // The next allocation starts on the next 16 bytes.
    const b = try gpa.alloc(u32, 3);
    try testing.expectEqual(@intFromPtr(cache.memory.ptr) + 16, @intFromPtr(b.ptr));
    gpa.free(b);
    try testing.expectEqual(0b10, freeMask(&cache));
    gpa.free(a);
    try testing.expectEqual(0b11, freeMask(&cache));
    try testing.expectEqual(null, local.block);
    try testing.expectEqual(0, local.offset);

    // The freed space is handed out again.
    const c = try gpa.alloc(u8, 40);
    try testing.expectEqual(@intFromPtr(cache.memory.ptr), @intFromPtr(c.ptr));
    gpa.free(c);
}

test "a handle asks first for the block it held last" {
    var cache: AllocatorCache = try .init(testing.allocator, 3, 64);
    defer cache.deinit();
    var first: AllocatorCache.Local = .init(&cache);
    var second: AllocatorCache.Local = .init(&cache);
    var third: AllocatorCache.Local = .init(&cache);

    // Without a block held before, a handle takes the lowest free one.
    const a = try first.allocator().alloc(u8, 1);
    const b = try second.allocator().alloc(u8, 1);
    try expectInBlock(&cache, a, 0);
    try expectInBlock(&cache, b, 1);
    first.allocator().free(a);
    second.allocator().free(b);
    try testing.expectEqual(0b111, freeMask(&cache));

    // Block 0 is free and lower, but `second` takes block 1 again.
    const c = try second.allocator().alloc(u8, 1);
    try expectInBlock(&cache, c, 1);
    const d = try third.allocator().alloc(u8, 1);
    try expectInBlock(&cache, d, 0);
    // With its last block taken, `first` takes the lowest free one.
    const e = try first.allocator().alloc(u8, 1);
    try expectInBlock(&cache, e, 2);
    try testing.expectEqual(0, freeMask(&cache));

    first.allocator().free(e);
    third.allocator().free(d);
    second.allocator().free(c);
    try testing.expectEqual(0b111, freeMask(&cache));
}

test "requests that do not fit, or need more alignment, go to the backing allocator" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var cache: AllocatorCache = try .init(counting.allocator(), 1, 48);
    defer cache.deinit();
    var local: AllocatorCache.Local = .init(&cache);
    const gpa = local.allocator();
    // The cache's own memory.
    try testing.expectEqual(1, counting.allocations);

    // A request of a whole block never fits, and takes no block.
    const whole = try gpa.alloc(u8, 48);
    try testing.expectEqual(2, counting.allocations);
    try testing.expectEqual(null, local.block);
    // Nor does one that needs more than 16-byte alignment.
    const aligned = try gpa.alignedAlloc(u8, .@"32", 8);
    try testing.expectEqual(3, counting.allocations);
    try testing.expectEqual(null, local.block);
    gpa.free(aligned);
    gpa.free(whole);
    try testing.expectEqual(2, counting.deallocations);

    // The original's suite: 36 bytes fit, 12 more do not fit after them.
    const copy = try gpa.alloc(u8, 36);
    try expectInBlock(&cache, copy, 0);
    const remap = try gpa.alloc(u32, 3);
    try testing.expectEqual(4, counting.allocations);
    try testing.expect(!cache.holds(@ptrCast(remap.ptr)));
    gpa.free(remap);
    gpa.free(copy);
    try testing.expectEqual(3, counting.deallocations);
    try testing.expectEqual(cache.all_blocks, freeMask(&cache));
}

test "with every block taken, a handle goes to the backing allocator" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var cache: AllocatorCache = try .init(counting.allocator(), 1, 64);
    defer cache.deinit();
    var first: AllocatorCache.Local = .init(&cache);
    var second: AllocatorCache.Local = .init(&cache);

    const a = try first.allocator().alloc(u8, 8);
    try expectInBlock(&cache, a, 0);
    const b = try second.allocator().alloc(u8, 8);
    try testing.expect(!cache.holds(b.ptr));
    try testing.expectEqual(null, second.block);
    try testing.expectEqual(2, counting.allocations);
    second.allocator().free(b);
    try testing.expectEqual(1, counting.deallocations);
    first.allocator().free(a);

    // Once the block is back, the other handle takes it.
    const c = try second.allocator().alloc(u8, 8);
    try expectInBlock(&cache, c, 0);
    second.allocator().free(c);
    try testing.expectEqual(2, counting.allocations);
}

test "allocations in a block start 16 bytes apart at least and leave a byte at its end" {
    var cache: AllocatorCache = try .init(testing.allocator, 1, 64);
    defer cache.deinit();
    var local: AllocatorCache.Local = .init(&cache);
    const gpa = local.allocator();
    const base = @intFromPtr(cache.memory.ptr);

    const a = try gpa.alloc(u8, 1);
    const b = try gpa.alloc(u8, 17);
    try testing.expectEqual(base + 16, @intFromPtr(b.ptr));
    // A request that reaches the allocator empty still moves on 16 bytes.
    const empty = gpa.rawAlloc(0, .@"1", @returnAddress()).?;
    try testing.expectEqual(base + 48, @intFromPtr(empty));
    try testing.expectEqual(64, local.offset);
    gpa.rawFree(empty[0..0], .@"1", @returnAddress());
    try testing.expectEqual(48, local.offset);

    // 15 bytes at 48 leave one byte of the block: they fit; 16 would not.
    const c = try gpa.alloc(u8, 16);
    try testing.expect(!cache.holds(c.ptr));
    const d = try gpa.alloc(u8, 15);
    try testing.expectEqual(base + 48, @intFromPtr(d.ptr));
    gpa.free(d);
    gpa.free(c);
    gpa.free(b);
    gpa.free(a);
    try testing.expectEqual(cache.all_blocks, freeMask(&cache));
}

test "only the newest allocation in a block resizes in place" {
    var cache: AllocatorCache = try .init(testing.allocator, 1, 256);
    defer cache.deinit();
    var local: AllocatorCache.Local = .init(&cache);
    const gpa = local.allocator();

    const a = try gpa.alloc(u8, 16);
    var b = try gpa.alloc(u8, 16);
    try testing.expect(!gpa.resize(a, 8));
    try testing.expect(gpa.resize(b, 100));
    b = b.ptr[0..100];
    try testing.expectEqual(128, local.offset);
    // It may not reach the block's last byte.
    try testing.expect(!gpa.resize(b, 240));
    try testing.expect(gpa.resize(b, 239));
    b = b.ptr[0..239];
    try testing.expectEqual(256, local.offset);
    try testing.expectEqual(@intFromPtr(b.ptr), @intFromPtr(gpa.remap(b, 20).?.ptr));
    b = b.ptr[0..20];
    try testing.expectEqual(48, local.offset);

    // Grown past the block, the newest moves to the backing allocator.
    b = try gpa.realloc(b, 1000);
    try testing.expect(!cache.holds(b.ptr));
    try testing.expectEqual(16, local.offset);
    gpa.free(b);
    gpa.free(a);
    try testing.expectEqual(cache.all_blocks, freeMask(&cache));
}

/// A backing allocator that keeps the length of the request it refuses.
const Refusing = struct {
    len: usize = 0,

    fn allocator(self: *Refusing) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = Allocator.noFree,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Refusing = @ptrCast(@alignCast(context));
        self.len = len;
        return null;
    }
};

test "block sizes round down to 16 bytes, and a cache without blocks takes no memory" {
    {
        var cache: AllocatorCache = try .init(testing.allocator, 3, 100);
        defer cache.deinit();
        try testing.expectEqual(96, cache.block_size);
        try testing.expectEqual(3 * 96, cache.memory.len);
        try testing.expectEqual(0b111, cache.all_blocks);
        try testing.expectEqual(0b111, freeMask(&cache));
    }
    {
        var cache: AllocatorCache = try .init(testing.allocator, 64, 31);
        defer cache.deinit();
        try testing.expectEqual(16, cache.block_size);
        try testing.expectEqual(std.math.maxInt(u64), cache.all_blocks);
    }

    // Without blocks, any block size, everything goes to the backing.
    for ([_]usize{ 0, 15, 16, 1000 }) |block_size| {
        var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var cache: AllocatorCache = try .init(counting.allocator(), 0, block_size);
        defer cache.deinit();
        try testing.expectEqual(0, counting.allocations);
        var local: AllocatorCache.Local = .init(&cache);
        const a = try local.allocator().alloc(u8, 1);
        try testing.expectEqual(1, counting.allocations);
        try testing.expectEqual(null, local.block);
        local.allocator().free(a);
        try testing.expectEqual(1, counting.deallocations);
    }

    // A size that overflows asks for all of memory, which fails.
    var refusing: Refusing = .{};
    const max = std.math.maxInt(usize);
    try testing.expectError(error.OutOfMemory, AllocatorCache.init(refusing.allocator(), 64, max));
    try testing.expectEqual(max, refusing.len);
    try testing.expectError(error.OutOfMemory, AllocatorCache.init(refusing.allocator(), 3, 100));
    try testing.expectEqual(3 * 96, refusing.len);
}

test "threads allocate through their own handles at once" {
    const thread_count = 8;
    var cache: AllocatorCache = try .init(testing.allocator, Shared.block_count, 4096);
    defer cache.deinit();
    var shared: Shared = .{ .cache = &cache };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const mark: u8 = @intCast(i);
        thread.* = try std.Thread.spawn(.{}, allocateInRounds, .{ &shared, mark });
    }
    shared.start.store(true, .release);
    for (threads) |thread| thread.join();

    try testing.expectEqual(0, shared.failures.load(.monotonic));
    try testing.expectEqual(cache.all_blocks, freeMask(&cache));
}

/// What the threads of the threaded test share.
const Shared = struct {
    cache: *AllocatorCache,
    /// Set once every thread runs, so they allocate at once.
    start: std.atomic.Value(bool) = .init(false),
    /// The mark of the thread whose handle holds each block, or `nobody`.
    holders: [block_count]std.atomic.Value(u8) = @splat(.init(nobody)),
    failures: std.atomic.Value(u32) = .init(0),

    const block_count = 3;
    const nobody = 0xff;

    fn fail(self: *Shared) void {
        _ = self.failures.fetchAdd(1, .monotonic);
    }

    /// The holder entry of the block `local` holds.
    fn holderOf(self: *Shared, local: *const AllocatorCache.Local) *std.atomic.Value(u8) {
        const offset = @intFromPtr(local.block.?) - @intFromPtr(self.cache.memory.ptr);
        return &self.holders[offset / self.cache.block_size];
    }
};

/// Rounds of allocations through a handle of this thread's own. Each piece
/// is filled with `mark` and checked after a yield, so another thread's
/// writes to it would show; a piece from the cache must lie in the block
/// the handle holds, and no other handle may hold that block meanwhile.
fn allocateInRounds(shared: *Shared, mark: u8) void {
    while (!shared.start.load(.acquire)) std.atomic.spinLoopHint();
    var local: AllocatorCache.Local = .init(shared.cache);
    const gpa = local.allocator();
    var prng: std.Random.DefaultPrng = .init(mark);
    const rng = prng.random();
    var pieces: [8][]u8 = undefined;
    for (0..2000) |_| {
        const count = rng.intRangeAtMost(usize, 1, pieces.len);
        var made: usize = 0;
        while (made < count) : (made += 1) {
            // One piece in eight is larger than a block.
            const len = if (rng.uintLessThan(u32, 8) == 0)
                5000
            else
                rng.intRangeAtMost(usize, 1, 600);
            const had_block = local.block != null;
            const piece = gpa.alloc(u8, len) catch {
                shared.fail();
                break;
            };
            pieces[made] = piece;
            @memset(piece, mark);
            if (!had_block and local.block != null) {
                const holder = shared.holderOf(&local);
                if (holder.cmpxchgStrong(Shared.nobody, mark, .acquire, .monotonic) != null) {
                    shared.fail();
                }
            }
            if (shared.cache.holds(piece.ptr) and !inHeldBlock(&local, piece)) shared.fail();
        }
        std.Thread.yield() catch {};
        while (made > 0) {
            made -= 1;
            const piece = pieces[made];
            if (!std.mem.allEqual(u8, piece, mark)) shared.fail();
            // Freeing the block's first piece empties it, and another
            // handle may take it at once.
            if (local.block) |block| {
                if (block == piece.ptr) shared.holderOf(&local).store(Shared.nobody, .release);
            }
            gpa.free(piece);
        }
    }
}

/// Whether `bytes` lies in the block `local` holds.
fn inHeldBlock(local: *const AllocatorCache.Local, bytes: []const u8) bool {
    const block = @intFromPtr(local.block orelse return false);
    const start = @intFromPtr(bytes.ptr);
    return start >= block and start + bytes.len <= block + local.cache.block_size;
}
