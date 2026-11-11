//! The original's C interface over the port, for its own test suite only
//! (test/suite.zig): each `meshopt_` function turns its pointers and counts
//! into the slices and views the port takes, and calls it. Scratch memory
//! goes through the original's allocator hooks from its allocator.cpp, or
//! through the port's `AllocatorCache` over them once the suite sets one up
//! with `meshopt_setAllocatorCache`, so the suite's allocation counts see
//! every allocation the port makes.

const std = @import("std");
const assert = std.debug.assert;
const mo = @import("meshoptimizer");
const c = @import("upstream");

extern fn suite_allocate(size: usize) ?[*]u8;
extern fn suite_deallocate(ptr: ?*anyopaque) void;

/// The original's allocator hooks: the callbacks `meshopt_setAllocator` set.
const callbacks: std.mem.Allocator = .{
    .ptr = @constCast(&{}),
    .vtable = &.{
        .alloc = callbackAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = callbackFree,
    },
};

fn callbackAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    // The callbacks align to 16 bytes, as operator new does.
    assert(alignment.toByteUnits() <= 16);
    return suite_allocate(len);
}

fn callbackFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    suite_deallocate(memory.ptr);
}

/// What the port's scratch memory goes through: the cache the suite set up,
/// else the callbacks.
const hooks: std.mem.Allocator = .{
    .ptr = @constCast(&{}),
    .vtable = &.{
        .alloc = hookAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = hookFree,
    },
};

fn hookAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return scratchAllocator().rawAlloc(len, alignment, ret_addr);
}

fn hookFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    scratchAllocator().rawFree(memory, alignment, ret_addr);
}

fn scratchAllocator() std.mem.Allocator {
    return if (allocator_cache != null) allocator_cache_local.allocator() else callbacks;
}

/// The cache `meshopt_setAllocatorCache` set up over the callbacks, if any,
/// and the handle of it the suite allocates through, from its one thread.
var allocator_cache: ?mo.AllocatorCache = null;
var allocator_cache_local: mo.AllocatorCache.Local = undefined;

export fn meshopt_setAllocatorCache(block_count: usize, block_size: usize) void {
    // Every block must be back: the suite calls this while no other
    // meshopt_ function runs.
    if (allocator_cache) |*cache| cache.deinit();
    allocator_cache = null;
    // Without memory for the blocks, the original keeps no cache.
    allocator_cache = mo.AllocatorCache.init(callbacks, block_count, block_size) catch return;
    allocator_cache_local = .init(&allocator_cache.?);
}

fn oom() noreturn {
    @panic("out of memory");
}

fn pending(comptime name: []const u8) noreturn {
    @panic(name ++ " is not ported yet");
}

fn items(comptime T: type, ptr: ?[*]const T, len: usize) []const T {
    if (ptr) |p| return p[0..len];
    assert(len == 0);
    return &.{};
}

fn itemsMut(comptime T: type, ptr: ?[*]T, len: usize) []T {
    if (ptr) |p| return p[0..len];
    assert(len == 0);
    return @constCast(&[_]T{});
}

fn bytes(ptr: ?*const anyopaque, len: usize) []const u8 {
    return items(u8, @ptrCast(ptr), len);
}

fn bytesMut(ptr: ?*anyopaque, len: usize) []u8 {
    return itemsMut(u8, @ptrCast(ptr), len);
}

/// `count` vertices of `width` floats each, `stride_bytes` apart.
fn floats(ptr: ?[*]const f32, count: usize, stride_bytes: usize, width: usize) mo.VertexFloats {
    assert(stride_bytes % @sizeOf(f32) == 0);
    const stride = stride_bytes / @sizeOf(f32);
    if (count == 0) return .{ .data = &.{}, .stride = stride };
    return .{ .data = ptr.?[0 .. (count - 1) * stride + width], .stride = stride };
}

fn optionalIndices(ptr: ?[*]const u32, len: usize) ?[]const u32 {
    return if (ptr) |p| p[0..len] else null;
}

/// One more than the largest of `values` other than the unused marker.
fn countOf(values: []const u32) usize {
    var count: usize = 0;
    for (values) |v| {
        if (v != std.math.maxInt(u32)) count = @max(count, @as(usize, v) + 1);
    }
    return count;
}

fn streamsOf(
    ptr: ?[*]const c.Stream,
    count: usize,
    vertex_count: usize,
    buffer: *[16]mo.Stream,
) []const mo.Stream {
    const list = items(c.Stream, ptr, count);
    for (list, buffer[0..list.len]) |s, *out| {
        const len = if (vertex_count == 0) 0 else (vertex_count - 1) * s.stride + s.size;
        out.* = .{ .data = bytes(s.data, len), .size = s.size, .stride = s.stride };
    }
    return buffer[0..list.len];
}

// --------------------------------------------------------
// Index generator
// --------------------------------------------------------

export fn meshopt_generateVertexRemap(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
) usize {
    return mo.generateVertexRemap(
        hooks,
        itemsMut(u32, destination, vertex_count),
        optionalIndices(indices, index_count),
        bytes(vertices, vertex_count * vertex_size),
        vertex_size,
    ) catch oom();
}

export fn meshopt_generateVertexRemapMulti(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    streams: ?[*]const c.Stream,
    stream_count: usize,
) usize {
    var buffer: [16]mo.Stream = undefined;
    return mo.generateVertexRemapMulti(
        hooks,
        itemsMut(u32, destination, vertex_count),
        optionalIndices(indices, index_count),
        vertex_count,
        streamsOf(streams, stream_count, vertex_count, &buffer),
    ) catch oom();
}

const CustomEqual = struct {
    callback: c.RemapCallback,
    context: ?*anyopaque,

    fn equal(self: CustomEqual, lhs: u32, rhs: u32) bool {
        return self.callback(self.context, lhs, rhs) != 0;
    }
};

export fn meshopt_generateVertexRemapCustom(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    callback: ?c.RemapCallback,
    context: ?*anyopaque,
) usize {
    const remap = itemsMut(u32, destination, vertex_count);
    const list = optionalIndices(indices, index_count);
    const positions = floats(vertex_positions, vertex_count, vertex_positions_stride, 3);
    if (callback) |f| {
        const custom: CustomEqual = .{ .callback = f, .context = context };
        return mo.generateVertexRemapCustom(
            hooks,
            remap,
            list,
            positions,
            custom,
            CustomEqual.equal,
        ) catch
            oom();
    }
    return mo.generateVertexRemapCustom(hooks, remap, list, positions, {}, null) catch oom();
}

export fn meshopt_remapVertexBuffer(
    destination: ?*anyopaque,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    remap: ?[*]const u32,
) void {
    const table = items(u32, remap, vertex_count);
    mo.remapVertexBuffer(
        hooks,
        bytesMut(destination, countOf(table) * vertex_size),
        bytes(vertices, vertex_count * vertex_size),
        vertex_size,
        table,
    ) catch oom();
}

export fn meshopt_remapIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    remap: ?[*]const u32,
) void {
    const list = optionalIndices(indices, index_count);
    const vertex_count = if (list) |l| countOf(l) else index_count;
    mo.remapIndexBuffer(
        itemsMut(u32, destination, index_count),
        list,
        items(u32, remap, vertex_count),
    );
}

export fn meshopt_filterIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    vertex_stride: usize,
) usize {
    const len = if (vertex_count == 0) 0 else (vertex_count - 1) * vertex_stride + vertex_size;
    return mo.filterIndexBuffer(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        vertex_count,
        .{ .data = bytes(vertices, len), .size = vertex_size, .stride = vertex_stride },
    ) catch oom();
}

export fn meshopt_filterIndexBufferMulti(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    streams: ?[*]const c.Stream,
    stream_count: usize,
) usize {
    var buffer: [16]mo.Stream = undefined;
    return mo.filterIndexBufferMulti(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        vertex_count,
        streamsOf(streams, stream_count, vertex_count, &buffer),
    ) catch oom();
}

export fn meshopt_generateShadowIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    vertex_stride: usize,
) void {
    const len = if (vertex_count == 0) 0 else (vertex_count - 1) * vertex_stride + vertex_size;
    mo.generateShadowIndexBuffer(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        vertex_count,
        .{ .data = bytes(vertices, len), .size = vertex_size, .stride = vertex_stride },
    ) catch oom();
}

export fn meshopt_generateShadowIndexBufferMulti(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    streams: ?[*]const c.Stream,
    stream_count: usize,
) void {
    var buffer: [16]mo.Stream = undefined;
    mo.generateShadowIndexBufferMulti(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        vertex_count,
        streamsOf(streams, stream_count, vertex_count, &buffer),
    ) catch oom();
}

export fn meshopt_generatePositionRemap(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void {
    mo.generatePositionRemap(
        hooks,
        itemsMut(u32, destination, vertex_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ) catch oom();
}

export fn meshopt_generateAdjacencyIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void {
    mo.generateAdjacencyIndexBuffer(
        hooks,
        itemsMut(u32, destination, index_count * 2),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ) catch oom();
}

export fn meshopt_generateTessellationIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void {
    mo.generateTessellationIndexBuffer(
        hooks,
        itemsMut(u32, destination, index_count * 4),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ) catch oom();
}

export fn meshopt_generateProvokingIndexBuffer(
    destination: ?[*]u32,
    reorder: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) usize {
    return mo.generateProvokingIndexBuffer(
        hooks,
        itemsMut(u32, destination, index_count),
        itemsMut(u32, reorder, vertex_count + index_count / 3),
        items(u32, indices, index_count),
        vertex_count,
    ) catch oom();
}

// --------------------------------------------------------
// Quantization
// --------------------------------------------------------

export fn meshopt_quantizeHalf(v: f32) u16 {
    return mo.quantizeHalf(v);
}

export fn meshopt_quantizeFloat(v: f32, N: c_int) f32 {
    return mo.quantizeFloat(v, @intCast(N));
}

export fn meshopt_dequantizeHalf(h: u16) f32 {
    return mo.dequantizeHalf(h);
}

export fn meshopt_computePositionExponent(
    minv: *const [3]f32,
    maxv: *const [3]f32,
    min_exp: c_int,
    max_bits: c_int,
) c_int {
    return mo.computePositionExponent(minv.*, maxv.*, min_exp, @intCast(max_bits));
}

// --------------------------------------------------------
// Simplifier
// --------------------------------------------------------

/// `count` vertices of `width` floats each, `stride_bytes` apart, that the
/// callee may change.
fn floatsMut(ptr: ?[*]f32, count: usize, stride_bytes: usize, width: usize) mo.VertexFloatsMut {
    assert(stride_bytes % @sizeOf(f32) == 0);
    const stride = stride_bytes / @sizeOf(f32);
    if (count == 0) return .{ .data = &.{}, .stride = stride };
    return .{ .data = ptr.?[0 .. (count - 1) * stride + width], .stride = stride };
}

/// The attribute view of a simplifier call; with no attributes the pointer
/// may be null and the stride 0, and nothing is read.
fn attributesOf(
    ptr: ?[*]const f32,
    count: usize,
    stride_bytes: usize,
    attribute_count: usize,
) mo.VertexFloats {
    if (attribute_count == 0) return .{ .data = &.{}, .stride = 1 };
    return floats(ptr, count, stride_bytes, attribute_count);
}

fn attributesMutOf(
    ptr: ?[*]f32,
    count: usize,
    stride_bytes: usize,
    attribute_count: usize,
) mo.VertexFloatsMut {
    if (attribute_count == 0) return .{ .data = @constCast(&[_]f32{}), .stride = 1 };
    return floatsMut(ptr, count, stride_bytes, attribute_count);
}

fn locksOf(ptr: ?[*]const u8, count: usize) ?[]const mo.SimplifyVertexFlags {
    const p = ptr orelse return null;
    const flags: [*]const mo.SimplifyVertexFlags = @ptrCast(p);
    return flags[0..count];
}

/// A destination of `len` indices, which may be null when the call writes
/// none.
fn destinationOf(ptr: ?[*]u32, len: usize) []u32 {
    if (ptr) |p| return p[0..len];
    return @constCast(&[_]u32{});
}

export fn meshopt_simplify(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: ?*f32,
) usize {
    return mo.simplify(
        hooks,
        destinationOf(destination, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        target_index_count,
        target_error,
        @bitCast(options),
        result_error,
    ) catch oom();
}

export fn meshopt_simplifyWithAttributes(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_attributes: ?[*]const f32,
    vertex_attributes_stride: usize,
    attribute_weights: ?[*]const f32,
    attribute_count: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: ?*f32,
) usize {
    return mo.simplifyWithAttributes(
        hooks,
        destinationOf(destination, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        attributesOf(vertex_attributes, vertex_count, vertex_attributes_stride, attribute_count),
        items(f32, attribute_weights, attribute_count),
        locksOf(vertex_lock, vertex_count),
        target_index_count,
        target_error,
        @bitCast(options),
        result_error,
    ) catch oom();
}

export fn meshopt_simplifyWithUpdate(
    indices: ?[*]u32,
    index_count: usize,
    vertex_positions: ?[*]f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_attributes: ?[*]f32,
    vertex_attributes_stride: usize,
    attribute_weights: ?[*]const f32,
    attribute_count: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: ?*f32,
) usize {
    return mo.simplifyWithUpdate(
        hooks,
        itemsMut(u32, indices, index_count),
        floatsMut(vertex_positions, vertex_count, vertex_positions_stride, 3),
        attributesMutOf(vertex_attributes, vertex_count, vertex_attributes_stride, attribute_count),
        items(f32, attribute_weights, attribute_count),
        locksOf(vertex_lock, vertex_count),
        target_index_count,
        target_error,
        @bitCast(options),
        result_error,
    ) catch oom();
}

export fn meshopt_simplifySloppy(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    result_error: ?*f32,
) usize {
    return mo.simplifySloppy(
        hooks,
        destinationOf(destination, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        locksOf(vertex_lock, vertex_count),
        target_index_count,
        target_error,
        result_error,
    ) catch oom();
}

export fn meshopt_simplifyPrune(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    target_error: f32,
) usize {
    return mo.simplifyPrune(
        hooks,
        destinationOf(destination, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        target_error,
    ) catch oom();
}

export fn meshopt_simplifyPoints(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_colors: ?[*]const f32,
    vertex_colors_stride: usize,
    color_weight: f32,
    target_vertex_count: usize,
) usize {
    const colors: ?mo.VertexFloats = if (vertex_colors != null)
        floats(vertex_colors, vertex_count, vertex_colors_stride, 3)
    else
        null;
    return mo.simplifyPoints(
        hooks,
        destinationOf(destination, target_vertex_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        colors,
        color_weight,
        target_vertex_count,
    ) catch oom();
}

export fn meshopt_simplifyScale(
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) f32 {
    return mo.simplifyScale(floats(vertex_positions, vertex_count, vertex_positions_stride, 3));
}

// --------------------------------------------------------
// Vertex codec
// --------------------------------------------------------

/// The original's encoder version setting, which the port takes as a
/// parameter.
var encode_vertex_version: mo.VertexVersion = .default;

export fn meshopt_encodeVertexBuffer(
    buffer: ?[*]u8,
    buffer_size: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
) usize {
    return mo.encodeVertexBufferLevel(
        itemsMut(u8, buffer, buffer_size),
        bytes(vertices, vertex_count * vertex_size),
        vertex_size,
        2,
        encode_vertex_version,
    );
}

export fn meshopt_encodeVertexBufferBound(vertex_count: usize, vertex_size: usize) usize {
    return mo.encodeVertexBufferBound(vertex_count, vertex_size);
}

export fn meshopt_encodeVertexBufferLevel(
    buffer: ?[*]u8,
    buffer_size: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    level: c_int,
    version: c_int,
) usize {
    assert(version < 0 or version <= 1);
    return mo.encodeVertexBufferLevel(
        itemsMut(u8, buffer, buffer_size),
        bytes(vertices, vertex_count * vertex_size),
        vertex_size,
        @intCast(level),
        if (version < 0) encode_vertex_version else @fromBackingInt(@as(u4, @intCast(version))),
    );
}

export fn meshopt_encodeVertexVersion(version: c_int) void {
    assert(version >= 0 and version <= 1);
    encode_vertex_version = @fromBackingInt(@as(u4, @intCast(version)));
}

export fn meshopt_decodeVertexBuffer(
    destination: ?*anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int {
    mo.decodeVertexBuffer(
        bytesMut(destination, vertex_count * vertex_size),
        vertex_size,
        items(u8, buffer, buffer_size),
    ) catch |err| return switch (err) {
        error.InvalidHeader => -1,
        error.InvalidData => -2,
        error.LengthMismatch => -3,
    };
    return 0;
}

export fn meshopt_decodeVertexVersion(buffer: ?[*]const u8, buffer_size: usize) c_int {
    const version = mo.decodeVertexVersion(items(u8, buffer, buffer_size)) orelse return -1;
    return @backingInt(version);
}

// --------------------------------------------------------
// Index codec
// --------------------------------------------------------

/// The C interface's encoder version, which `meshopt_encodeIndexVersion`
/// sets; the port takes it as a parameter.
var index_version: mo.IndexVersion = .default;

fn indexResult(result: mo.IndexDecodeError!void) c_int {
    result catch |err| return switch (err) {
        error.InvalidHeader => -1,
        error.Truncated => -2,
        error.SizeMismatch => -3,
    };
    return 0;
}

export fn meshopt_encodeIndexBuffer(
    buffer: ?[*]u8,
    buffer_size: usize,
    indices: ?[*]const u32,
    index_count: usize,
) usize {
    return mo.encodeIndexBuffer(
        itemsMut(u8, buffer, buffer_size),
        items(u32, indices, index_count),
        index_version,
    ) catch 0;
}

export fn meshopt_encodeIndexBufferBound(index_count: usize, vertex_count: usize) usize {
    return mo.encodeIndexBufferBound(index_count, vertex_count);
}

export fn meshopt_encodeIndexVersion(version: c_int) void {
    assert(version >= 0 and version <= 1);
    index_version = @fromBackingInt(@as(u4, @intCast(version)));
}

export fn meshopt_decodeIndexBuffer(
    destination: ?*anyopaque,
    index_count: usize,
    index_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int {
    const encoded = items(u8, buffer, buffer_size);
    return indexResult(switch (index_size) {
        inline 2, 4 => |size| blk: {
            const T = if (size == 2) u16 else u32;
            const decoded = itemsMut(T, @ptrCast(@alignCast(destination)), index_count);
            break :blk mo.decodeIndexBuffer(T, decoded, encoded);
        },
        else => unreachable,
    });
}

export fn meshopt_decodeIndexVersion(buffer: ?[*]const u8, buffer_size: usize) c_int {
    const version = mo.decodeIndexVersion(items(u8, buffer, buffer_size)) orelse return -1;
    return @backingInt(version);
}

export fn meshopt_encodeIndexSequence(
    buffer: ?[*]u8,
    buffer_size: usize,
    indices: ?[*]const u32,
    index_count: usize,
) usize {
    return mo.encodeIndexSequence(
        itemsMut(u8, buffer, buffer_size),
        items(u32, indices, index_count),
        index_version,
    ) catch 0;
}

export fn meshopt_encodeIndexSequenceBound(index_count: usize, vertex_count: usize) usize {
    return mo.encodeIndexSequenceBound(index_count, vertex_count);
}

export fn meshopt_decodeIndexSequence(
    destination: ?*anyopaque,
    index_count: usize,
    index_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int {
    const encoded = items(u8, buffer, buffer_size);
    return indexResult(switch (index_size) {
        inline 2, 4 => |size| blk: {
            const T = if (size == 2) u16 else u32;
            const decoded = itemsMut(T, @ptrCast(@alignCast(destination)), index_count);
            break :blk mo.decodeIndexSequence(T, decoded, encoded);
        },
        else => unreachable,
    });
}

// --------------------------------------------------------
// Meshlet codec
// --------------------------------------------------------

fn meshletResult(result: mo.MeshletDecodeError!void) c_int {
    result catch |err| return switch (err) {
        error.Truncated => -2,
        error.SizeMismatch => -3,
    };
    return 0;
}

export fn meshopt_encodeMeshlet(
    buffer: ?[*]u8,
    buffer_size: usize,
    vertices: ?[*]const u32,
    vertex_count: usize,
    triangles: ?[*]const u8,
    triangle_count: usize,
) usize {
    return mo.encodeMeshlet(
        itemsMut(u8, buffer, buffer_size),
        items(u32, vertices, vertex_count),
        items(u8, triangles, triangle_count * 3),
    ) catch 0;
}

export fn meshopt_encodeMeshletBound(max_vertices: usize, max_triangles: usize) usize {
    return mo.encodeMeshletBound(max_vertices, max_triangles);
}

/// The `count` items of `size` bytes at `ptr`, rounded up to 4 bytes, as
/// `T`s.
fn padded(comptime T: type, ptr: ?*anyopaque, count: usize, size: usize) []T {
    const len = std.mem.alignForward(usize, count * size, 4) / @sizeOf(T);
    return itemsMut(T, @ptrCast(@alignCast(ptr)), len);
}

export fn meshopt_decodeMeshlet(
    vertices: ?*anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    triangles: ?*anyopaque,
    triangle_count: usize,
    triangle_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int {
    const encoded = items(u8, buffer, buffer_size);
    const vc = vertex_count;
    const tc = triangle_count;
    return meshletResult(switch (vertex_size) {
        inline 2, 4 => |vs| switch (triangle_size) {
            inline 3, 4 => |ts| blk: {
                const V = if (vs == 2) u16 else u32;
                const T = if (ts == 3) u8 else u32;
                break :blk mo.decodeMeshlet(
                    V,
                    T,
                    padded(V, vertices, vc, vs),
                    vc,
                    padded(T, triangles, tc, ts),
                    tc,
                    encoded,
                );
            },
            else => unreachable,
        },
        else => unreachable,
    });
}

export fn meshopt_decodeMeshletRaw(
    vertices: ?[*]u32,
    vertex_count: usize,
    triangles: ?[*]u32,
    triangle_count: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int {
    return meshletResult(mo.decodeMeshletRaw(
        itemsMut(u32, vertices, std.mem.alignForward(usize, vertex_count, 4)),
        vertex_count,
        itemsMut(u32, triangles, std.mem.alignForward(usize, triangle_count, 4)),
        triangle_count,
        items(u8, buffer, buffer_size),
    ));
}

// --------------------------------------------------------
// Vertex cache optimizer
// --------------------------------------------------------

export fn meshopt_optimizeVertexCache(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) void {
    mo.optimizeVertexCache(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        vertex_count,
    ) catch oom();
}

export fn meshopt_optimizeVertexCacheStrip(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) void {
    mo.optimizeVertexCacheStrip(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        vertex_count,
    ) catch oom();
}

export fn meshopt_optimizeVertexCacheFifo(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    cache_size: u32,
) void {
    mo.optimizeVertexCacheFifo(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        vertex_count,
        cache_size,
    ) catch oom();
}

// --------------------------------------------------------
// Clusterizer
// --------------------------------------------------------

fn meshletsMut(ptr: ?[*]c.Meshlet, len: usize) []mo.Meshlet {
    return itemsMut(mo.Meshlet, @ptrCast(ptr), len);
}

export fn meshopt_buildMeshlets(
    meshlets: ?[*]c.Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    max_vertices: usize,
    max_triangles: usize,
    cone_weight: f32,
) usize {
    // The builders write at most index_count vertices and triangle bytes.
    return mo.buildMeshlets(
        hooks,
        meshletsMut(meshlets, mo.buildMeshletsBound(index_count, max_vertices, max_triangles)),
        itemsMut(u32, meshlet_vertices, index_count),
        itemsMut(u8, meshlet_triangles, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        max_vertices,
        max_triangles,
        cone_weight,
    ) catch oom();
}

export fn meshopt_buildMeshletsScan(
    meshlets: ?[*]c.Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    max_vertices: usize,
    max_triangles: usize,
) usize {
    return mo.buildMeshletsScan(
        hooks,
        meshletsMut(meshlets, mo.buildMeshletsBound(index_count, max_vertices, max_triangles)),
        itemsMut(u32, meshlet_vertices, index_count),
        itemsMut(u8, meshlet_triangles, index_count),
        items(u32, indices, index_count),
        vertex_count,
        max_vertices,
        max_triangles,
    ) catch oom();
}

export fn meshopt_buildMeshletsBound(
    index_count: usize,
    max_vertices: usize,
    max_triangles: usize,
) usize {
    return mo.buildMeshletsBound(index_count, max_vertices, max_triangles);
}

export fn meshopt_buildMeshletsFlex(
    meshlets: ?[*]c.Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,
    cone_weight: f32,
    split_factor: f32,
) usize {
    return mo.buildMeshletsFlex(
        hooks,
        meshletsMut(meshlets, mo.buildMeshletsBound(index_count, max_vertices, min_triangles)),
        itemsMut(u32, meshlet_vertices, index_count),
        itemsMut(u8, meshlet_triangles, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        max_vertices,
        min_triangles,
        max_triangles,
        cone_weight,
        split_factor,
    ) catch oom();
}

export fn meshopt_buildMeshletsSpatial(
    meshlets: ?[*]c.Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,
    fill_weight: f32,
) usize {
    return mo.buildMeshletsSpatial(
        hooks,
        meshletsMut(meshlets, mo.buildMeshletsBound(index_count, max_vertices, min_triangles)),
        itemsMut(u32, meshlet_vertices, index_count),
        itemsMut(u8, meshlet_triangles, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        max_vertices,
        min_triangles,
        max_triangles,
        fill_weight,
    ) catch oom();
}

// --------------------------------------------------------
// Meshlet utilities
// --------------------------------------------------------

export fn meshopt_optimizeMeshlet(
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    triangle_count: usize,
    vertex_count: usize,
) void {
    mo.optimizeMeshlet(
        itemsMut(u32, meshlet_vertices, vertex_count),
        itemsMut(u8, meshlet_triangles, triangle_count * 3),
    );
}

export fn meshopt_optimizeMeshletLevel(
    meshlet_vertices: ?[*]u32,
    vertex_count: usize,
    meshlet_triangles: ?[*]u8,
    triangle_count: usize,
    level: c_int,
) void {
    mo.optimizeMeshletLevel(
        itemsMut(u32, meshlet_vertices, vertex_count),
        itemsMut(u8, meshlet_triangles, triangle_count * 3),
        @intCast(level),
    );
}

fn toBounds(b: mo.Bounds) c.Bounds {
    return .{
        .center = b.center,
        .radius = b.radius,
        .cone_apex = b.cone_apex,
        .cone_axis = b.cone_axis,
        .cone_cutoff = b.cone_cutoff,
        .cone_axis_s8 = b.cone_axis_s8,
        .cone_cutoff_s8 = b.cone_cutoff_s8,
    };
}

export fn meshopt_computeClusterBounds(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) c.Bounds {
    return toBounds(mo.computeClusterBounds(
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ));
}

export fn meshopt_computeMeshletBounds(
    meshlet_vertices: ?[*]const u32,
    meshlet_triangles: ?[*]const u8,
    triangle_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) c.Bounds {
    const triangles = items(u8, meshlet_triangles, triangle_count * 3);
    var used: usize = 0;
    for (triangles) |t| used = @max(used, @as(usize, t) + 1);
    return toBounds(mo.computeMeshletBounds(
        items(u32, meshlet_vertices, used),
        triangles,
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ));
}

export fn meshopt_computeSphereBounds(
    positions: ?[*]const f32,
    count: usize,
    positions_stride: usize,
    radii: ?[*]const f32,
    radii_stride: usize,
) c.Bounds {
    const radius_floats: ?mo.VertexFloats = if (radii) |r|
        floats(r, count, radii_stride, 1)
    else
        null;
    return toBounds(mo.computeSphereBounds(
        floats(positions, count, positions_stride, 3),
        radius_floats,
    ));
}

export fn meshopt_extractMeshletIndices(
    vertices: ?[*]u32,
    triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
) usize {
    // A meshlet has at most 256 vertices.
    return mo.extractMeshletIndices(
        itemsMut(u32, vertices, 256),
        itemsMut(u8, triangles, index_count),
        items(u32, indices, index_count),
    );
}

// --------------------------------------------------------
// Partition
// --------------------------------------------------------

export fn meshopt_partitionClusters(
    destination: ?[*]u32,
    cluster_indices: ?[*]const u32,
    total_index_count: usize,
    cluster_index_counts: ?[*]const u32,
    cluster_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    target_partition_size: usize,
) usize {
    const positions: ?mo.VertexFloats = if (vertex_positions) |p|
        floats(p, vertex_count, vertex_positions_stride, 3)
    else
        null;
    return mo.partitionClusters(
        hooks,
        itemsMut(u32, destination, cluster_count),
        items(u32, cluster_indices, total_index_count),
        items(u32, cluster_index_counts, cluster_count),
        positions,
        vertex_count,
        target_partition_size,
    ) catch oom();
}

// --------------------------------------------------------
// Overdraw and vertex fetch optimizers, analyzers, strips, spatial order
// --------------------------------------------------------

export fn meshopt_optimizeOverdraw(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    threshold: f32,
) void {
    mo.optimizeOverdraw(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        threshold,
    ) catch oom();
}

export fn meshopt_optimizeVertexFetch(
    destination: ?*anyopaque,
    indices: ?[*]u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
) usize {
    return mo.optimizeVertexFetch(
        hooks,
        bytesMut(destination, vertex_count * vertex_size),
        itemsMut(u32, indices, index_count),
        bytes(vertices, vertex_count * vertex_size),
        vertex_size,
    ) catch oom();
}

export fn meshopt_optimizeVertexFetchRemap(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) usize {
    return mo.optimizeVertexFetchRemap(
        itemsMut(u32, destination, vertex_count),
        items(u32, indices, index_count),
        vertex_count,
    );
}

export fn meshopt_analyzeVertexCache(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    cache_size: u32,
    warp_size: u32,
    primgroup_size: u32,
) c.VertexCacheStatistics {
    const stats = mo.analyzeVertexCache(
        hooks,
        items(u32, indices, index_count),
        vertex_count,
        cache_size,
        warp_size,
        primgroup_size,
    ) catch oom();
    return .{
        .vertices_transformed = stats.vertices_transformed,
        .warps_executed = stats.warps_executed,
        .acmr = stats.acmr,
        .atvr = stats.atvr,
    };
}

export fn meshopt_analyzeVertexFetch(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    vertex_size: usize,
) c.VertexFetchStatistics {
    const stats = mo.analyzeVertexFetch(
        hooks,
        items(u32, indices, index_count),
        vertex_count,
        vertex_size,
    ) catch oom();
    return .{ .bytes_fetched = stats.bytes_fetched, .overfetch = stats.overfetch };
}

export fn meshopt_analyzeOverdraw(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) c.OverdrawStatistics {
    const stats = mo.analyzeOverdraw(
        hooks,
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ) catch oom();
    return .{
        .pixels_covered = stats.pixels_covered,
        .pixels_shaded = stats.pixels_shaded,
        .overdraw = stats.overdraw,
    };
}

export fn meshopt_analyzeCoverage(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) c.CoverageStatistics {
    const stats = mo.analyzeCoverage(
        hooks,
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ) catch oom();
    return .{ .coverage = stats.coverage, .extent = stats.extent };
}

export fn meshopt_stripify(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    restart_index: u32,
) usize {
    return mo.stripify(
        hooks,
        itemsMut(u32, destination, mo.stripifyBound(index_count)),
        items(u32, indices, index_count),
        vertex_count,
        restart_index,
    ) catch oom();
}

export fn meshopt_stripifyBound(index_count: usize) usize {
    return mo.stripifyBound(index_count);
}

export fn meshopt_unstripify(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    restart_index: u32,
) usize {
    const bound = if (index_count < 3) 0 else (index_count - 2) * 3;
    return mo.unstripify(
        itemsMut(u32, destination, bound),
        items(u32, indices, index_count),
        restart_index,
    );
}

export fn meshopt_unstripifyBound(index_count: usize) usize {
    return mo.unstripifyBound(index_count);
}

export fn meshopt_spatialSortRemap(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void {
    mo.spatialSortRemap(
        hooks,
        itemsMut(u32, destination, vertex_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ) catch oom();
}

export fn meshopt_spatialSortTriangles(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void {
    mo.spatialSortTriangles(
        hooks,
        itemsMut(u32, destination, index_count),
        items(u32, indices, index_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
    ) catch oom();
}

export fn meshopt_spatialClusterPoints(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    cluster_size: usize,
) void {
    mo.spatialClusterPoints(
        hooks,
        itemsMut(u32, destination, vertex_count),
        floats(vertex_positions, vertex_count, vertex_positions_stride, 3),
        cluster_size,
    ) catch oom();
}

export fn meshopt_decodeFilterOct(_: ?*anyopaque, _: usize, _: usize) void {
    pending("meshopt_decodeFilterOct");
}

export fn meshopt_decodeFilterQuat(_: ?*anyopaque, _: usize, _: usize) void {
    pending("meshopt_decodeFilterQuat");
}

export fn meshopt_decodeFilterExp(_: ?*anyopaque, _: usize, _: usize) void {
    pending("meshopt_decodeFilterExp");
}

export fn meshopt_decodeFilterColor(_: ?*anyopaque, _: usize, _: usize) void {
    pending("meshopt_decodeFilterColor");
}

export fn meshopt_encodeFilterOct(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: c_int,
    _: ?[*]const f32,
) void {
    pending("meshopt_encodeFilterOct");
}

export fn meshopt_encodeFilterQuat(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: c_int,
    _: ?[*]const f32,
) void {
    pending("meshopt_encodeFilterQuat");
}

export fn meshopt_encodeFilterExp(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: c_int,
    _: ?[*]const f32,
    _: c.EncodeExpMode,
) void {
    pending("meshopt_encodeFilterExp");
}

export fn meshopt_encodeFilterColor(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: c_int,
    _: ?[*]const f32,
) void {
    pending("meshopt_encodeFilterColor");
}

export fn meshopt_opacityMapMeasure(
    _: ?[*]u8,
    _: ?[*]u32,
    _: ?[*]c_int,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: u32,
    _: u32,
    _: c_int,
    _: f32,
) usize {
    pending("meshopt_opacityMapMeasure");
}

export fn meshopt_opacityMapRasterize(
    _: ?[*]u8,
    _: c_int,
    _: c_int,
    _: ?[*]const f32,
    _: ?[*]const f32,
    _: ?[*]const f32,
    _: ?[*]const u8,
    _: usize,
    _: usize,
    _: u32,
    _: u32,
) void {
    pending("meshopt_opacityMapRasterize");
}

export fn meshopt_opacityMapEntrySize(_: c_int, _: c_int) usize {
    pending("meshopt_opacityMapEntrySize");
}

export fn meshopt_opacityMapCompact(
    _: ?[*]u8,
    _: usize,
    _: ?[*]u8,
    _: ?[*]u32,
    _: usize,
    _: ?[*]c_int,
    _: usize,
    _: c_int,
) usize {
    pending("meshopt_opacityMapCompact");
}

export fn meshopt_generateTangents(
    _: ?[*]f32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: u32,
) void {
    pending("meshopt_generateTangents");
}

export fn meshopt_generateNormals(
    _: ?[*]f32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: f32,
    _: f32,
) void {
    pending("meshopt_generateNormals");
}

export fn meshopt_remesh(
    _: ?[*]f32,
    _: usize,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: c_int,
    _: u32,
) usize {
    pending("meshopt_remesh");
}
