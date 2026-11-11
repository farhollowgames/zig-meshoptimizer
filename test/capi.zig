//! The original's C interface over the port, for its own test suite only
//! (test/suite.zig): each `meshopt_` function turns its pointers and counts
//! into the slices and views the port takes, and calls it. Scratch memory
//! goes through the original's allocator hooks from its allocator.cpp, so
//! the suite's allocation counts see every allocation the port makes.

const std = @import("std");
const assert = std.debug.assert;
const mo = @import("meshoptimizer");
const c = @import("upstream");

extern fn suite_allocate(size: usize) ?[*]u8;
extern fn suite_deallocate(ptr: ?*anyopaque) void;

const hooks: std.mem.Allocator = .{
    .ptr = @constCast(&{}),
    .vtable = &.{
        .alloc = hookAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = hookFree,
    },
};

fn hookAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    // The hooks align to 16 bytes, as operator new and the cache do.
    assert(alignment.toByteUnits() <= 16);
    return suite_allocate(len);
}

fn hookFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    suite_deallocate(memory.ptr);
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
// Not ported yet
// --------------------------------------------------------
export fn meshopt_optimizeVertexCache(_: ?[*]u32, _: ?[*]const u32, _: usize, _: usize) void {
    pending("meshopt_optimizeVertexCache");
}

export fn meshopt_optimizeVertexCacheStrip(_: ?[*]u32, _: ?[*]const u32, _: usize, _: usize) void {
    pending("meshopt_optimizeVertexCacheStrip");
}

export fn meshopt_optimizeVertexCacheFifo(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: usize,
    _: u32,
) void {
    pending("meshopt_optimizeVertexCacheFifo");
}

export fn meshopt_optimizeOverdraw(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: f32,
) void {
    pending("meshopt_optimizeOverdraw");
}

export fn meshopt_optimizeVertexFetch(
    _: ?*anyopaque,
    _: ?[*]u32,
    _: usize,
    _: ?*const anyopaque,
    _: usize,
    _: usize,
) usize {
    pending("meshopt_optimizeVertexFetch");
}

export fn meshopt_optimizeVertexFetchRemap(_: ?[*]u32, _: ?[*]const u32, _: usize, _: usize) usize {
    pending("meshopt_optimizeVertexFetchRemap");
}

export fn meshopt_encodeVertexBuffer(
    _: ?[*]u8,
    _: usize,
    _: ?*const anyopaque,
    _: usize,
    _: usize,
) usize {
    pending("meshopt_encodeVertexBuffer");
}

export fn meshopt_encodeVertexBufferBound(_: usize, _: usize) usize {
    pending("meshopt_encodeVertexBufferBound");
}

export fn meshopt_encodeVertexBufferLevel(
    _: ?[*]u8,
    _: usize,
    _: ?*const anyopaque,
    _: usize,
    _: usize,
    _: c_int,
    _: c_int,
) usize {
    pending("meshopt_encodeVertexBufferLevel");
}

export fn meshopt_encodeVertexVersion(_: c_int) void {
    pending("meshopt_encodeVertexVersion");
}

export fn meshopt_decodeVertexBuffer(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: ?[*]const u8,
    _: usize,
) c_int {
    pending("meshopt_decodeVertexBuffer");
}

export fn meshopt_decodeVertexVersion(_: ?[*]const u8, _: usize) c_int {
    pending("meshopt_decodeVertexVersion");
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

export fn meshopt_simplify(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: usize,
    _: f32,
    _: u32,
    _: ?*f32,
) usize {
    pending("meshopt_simplify");
}

export fn meshopt_simplifyWithAttributes(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: ?[*]const u8,
    _: usize,
    _: f32,
    _: u32,
    _: ?*f32,
) usize {
    pending("meshopt_simplifyWithAttributes");
}

export fn meshopt_simplifyWithUpdate(
    _: ?[*]u32,
    _: usize,
    _: ?[*]f32,
    _: usize,
    _: usize,
    _: ?[*]f32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: ?[*]const u8,
    _: usize,
    _: f32,
    _: u32,
    _: ?*f32,
) usize {
    pending("meshopt_simplifyWithUpdate");
}

export fn meshopt_simplifySloppy(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: ?[*]const u8,
    _: usize,
    _: f32,
    _: ?*f32,
) usize {
    pending("meshopt_simplifySloppy");
}

export fn meshopt_simplifyPrune(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: f32,
) usize {
    pending("meshopt_simplifyPrune");
}

export fn meshopt_simplifyPoints(
    _: ?[*]u32,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: f32,
    _: usize,
) usize {
    pending("meshopt_simplifyPoints");
}

export fn meshopt_simplifyScale(_: ?[*]const f32, _: usize, _: usize) f32 {
    pending("meshopt_simplifyScale");
}

export fn meshopt_stripify(_: ?[*]u32, _: ?[*]const u32, _: usize, _: usize, _: u32) usize {
    pending("meshopt_stripify");
}

export fn meshopt_stripifyBound(_: usize) usize {
    pending("meshopt_stripifyBound");
}

export fn meshopt_unstripify(_: ?[*]u32, _: ?[*]const u32, _: usize, _: u32) usize {
    pending("meshopt_unstripify");
}

export fn meshopt_unstripifyBound(_: usize) usize {
    pending("meshopt_unstripifyBound");
}

export fn meshopt_analyzeVertexCache(
    _: ?[*]const u32,
    _: usize,
    _: usize,
    _: u32,
    _: u32,
    _: u32,
) c.VertexCacheStatistics {
    pending("meshopt_analyzeVertexCache");
}

export fn meshopt_analyzeVertexFetch(
    _: ?[*]const u32,
    _: usize,
    _: usize,
    _: usize,
) c.VertexFetchStatistics {
    pending("meshopt_analyzeVertexFetch");
}

export fn meshopt_analyzeOverdraw(
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
) c.OverdrawStatistics {
    pending("meshopt_analyzeOverdraw");
}

export fn meshopt_analyzeCoverage(
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
) c.CoverageStatistics {
    pending("meshopt_analyzeCoverage");
}

export fn meshopt_buildMeshlets(
    _: ?[*]c.Meshlet,
    _: ?[*]u32,
    _: ?[*]u8,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
    _: f32,
) usize {
    pending("meshopt_buildMeshlets");
}

export fn meshopt_buildMeshletsScan(
    _: ?[*]c.Meshlet,
    _: ?[*]u32,
    _: ?[*]u8,
    _: ?[*]const u32,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
) usize {
    pending("meshopt_buildMeshletsScan");
}

export fn meshopt_buildMeshletsBound(_: usize, _: usize, _: usize) usize {
    pending("meshopt_buildMeshletsBound");
}

export fn meshopt_buildMeshletsFlex(
    _: ?[*]c.Meshlet,
    _: ?[*]u32,
    _: ?[*]u8,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
    _: f32,
    _: f32,
) usize {
    pending("meshopt_buildMeshletsFlex");
}

export fn meshopt_buildMeshletsSpatial(
    _: ?[*]c.Meshlet,
    _: ?[*]u32,
    _: ?[*]u8,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
    _: f32,
) usize {
    pending("meshopt_buildMeshletsSpatial");
}

export fn meshopt_optimizeMeshlet(_: ?[*]u32, _: ?[*]u8, _: usize, _: usize) void {
    pending("meshopt_optimizeMeshlet");
}

export fn meshopt_optimizeMeshletLevel(_: ?[*]u32, _: usize, _: ?[*]u8, _: usize, _: c_int) void {
    pending("meshopt_optimizeMeshletLevel");
}

export fn meshopt_computeClusterBounds(
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
) c.Bounds {
    pending("meshopt_computeClusterBounds");
}

export fn meshopt_computeMeshletBounds(
    _: ?[*]const u32,
    _: ?[*]const u8,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
) c.Bounds {
    pending("meshopt_computeMeshletBounds");
}

export fn meshopt_computeSphereBounds(
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: ?[*]const f32,
    _: usize,
) c.Bounds {
    pending("meshopt_computeSphereBounds");
}

export fn meshopt_extractMeshletIndices(_: ?[*]u32, _: ?[*]u8, _: ?[*]const u32, _: usize) usize {
    pending("meshopt_extractMeshletIndices");
}

export fn meshopt_partitionClusters(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: usize,
) usize {
    pending("meshopt_partitionClusters");
}

export fn meshopt_spatialSortRemap(_: ?[*]u32, _: ?[*]const f32, _: usize, _: usize) void {
    pending("meshopt_spatialSortRemap");
}

export fn meshopt_spatialSortTriangles(
    _: ?[*]u32,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const f32,
    _: usize,
    _: usize,
) void {
    pending("meshopt_spatialSortTriangles");
}

export fn meshopt_spatialClusterPoints(
    _: ?[*]u32,
    _: ?[*]const f32,
    _: usize,
    _: usize,
    _: usize,
) void {
    pending("meshopt_spatialClusterPoints");
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
