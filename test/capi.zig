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

export fn meshopt_encodeIndexBuffer(_: ?[*]u8, _: usize, _: ?[*]const u32, _: usize) usize {
    pending("meshopt_encodeIndexBuffer");
}

export fn meshopt_encodeIndexBufferBound(_: usize, _: usize) usize {
    pending("meshopt_encodeIndexBufferBound");
}

export fn meshopt_encodeIndexVersion(_: c_int) void {
    pending("meshopt_encodeIndexVersion");
}

export fn meshopt_decodeIndexBuffer(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: ?[*]const u8,
    _: usize,
) c_int {
    pending("meshopt_decodeIndexBuffer");
}

export fn meshopt_decodeIndexVersion(_: ?[*]const u8, _: usize) c_int {
    pending("meshopt_decodeIndexVersion");
}

export fn meshopt_encodeIndexSequence(_: ?[*]u8, _: usize, _: ?[*]const u32, _: usize) usize {
    pending("meshopt_encodeIndexSequence");
}

export fn meshopt_encodeIndexSequenceBound(_: usize, _: usize) usize {
    pending("meshopt_encodeIndexSequenceBound");
}

export fn meshopt_decodeIndexSequence(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: ?[*]const u8,
    _: usize,
) c_int {
    pending("meshopt_decodeIndexSequence");
}

export fn meshopt_encodeMeshlet(
    _: ?[*]u8,
    _: usize,
    _: ?[*]const u32,
    _: usize,
    _: ?[*]const u8,
    _: usize,
) usize {
    pending("meshopt_encodeMeshlet");
}

export fn meshopt_encodeMeshletBound(_: usize, _: usize) usize {
    pending("meshopt_encodeMeshletBound");
}

export fn meshopt_decodeMeshlet(
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: ?*anyopaque,
    _: usize,
    _: usize,
    _: ?[*]const u8,
    _: usize,
) c_int {
    pending("meshopt_decodeMeshlet");
}

export fn meshopt_decodeMeshletRaw(
    _: ?[*]u32,
    _: usize,
    _: ?[*]u32,
    _: usize,
    _: ?[*]const u8,
    _: usize,
) c_int {
    pending("meshopt_decodeMeshletRaw");
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
