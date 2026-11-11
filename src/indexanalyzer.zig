//! Vertex cache and vertex fetch analysis: how an index buffer would use a
//! GPU's post-transform cache and its vertex memory, in simple models of
//! both.
//!
//! Translated from meshoptimizer's indexanalyzer.cpp.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;

pub const VertexCacheStatistics = struct {
    vertices_transformed: u32 = 0,
    warps_executed: u32 = 0,
    /// Transformed vertices per triangle: 0.5 at best, 3 at worst; the
    /// best reachable depends on the topology.
    acmr: f32 = 0,
    /// Transformed vertices per vertex: 1 at best, each vertex transformed
    /// once, and 6 at worst.
    atvr: f32 = 0,
};

/// Counts the vertex shader runs `indices` costs on a GPU with a FIFO
/// post-transform cache of `cache_size` vertices (at least 3), warps of
/// `warp_size` vertices (0 for no warps, else at least 3), and primitive
/// groups of `primgroup_size` triangles (0 for none). The model is simple,
/// and real GPUs may differ.
pub fn analyzeVertexCache(
    gpa: Allocator,
    indices: []const u32,
    vertex_count: usize,
    cache_size: u32,
    warp_size: u32,
    primgroup_size: u32,
) Allocator.Error!VertexCacheStatistics {
    assert(indices.len % 3 == 0);
    assert(cache_size >= 3);
    assert(warp_size == 0 or warp_size >= 3);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    var result: VertexCacheStatistics = .{};

    var warp_offset: u32 = 0;
    var primgroup_offset: u32 = 0;

    const cache_timestamps = try scratch.alloc(u32, vertex_count);
    @memset(cache_timestamps, 0);

    // The original's unsigned arithmetic wraps, and so does the port's.
    var timestamp: u32 = cache_size +% 1;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const a = indices[i + 0];
        const b = indices[i + 1];
        const c = indices[i + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        const ac: u32 = @intFromBool(timestamp -% cache_timestamps[a] > cache_size);
        const bc: u32 = @intFromBool(timestamp -% cache_timestamps[b] > cache_size);
        const cc: u32 = @intFromBool(timestamp -% cache_timestamps[c] > cache_size);

        // Flush the cache when the triangle fits neither the warp nor the
        // primitive buffer.
        if ((primgroup_size != 0 and primgroup_offset == primgroup_size) or
            (warp_size != 0 and warp_offset +% ac +% bc +% cc > warp_size))
        {
            result.warps_executed +%= @intFromBool(warp_offset > 0);

            warp_offset = 0;
            primgroup_offset = 0;

            // Every vertex in the cache now counts as out of it.
            timestamp +%= cache_size +% 1;
        }

        // Update the cache and add the vertices to the warp.
        for (indices[i..][0..3]) |index| {
            if (timestamp -% cache_timestamps[index] > cache_size) {
                cache_timestamps[index] = timestamp;
                timestamp +%= 1;
                result.vertices_transformed +%= 1;
                warp_offset +%= 1;
            }
        }

        primgroup_offset +%= 1;
    }

    var unique_vertex_count: usize = 0;

    for (cache_timestamps) |t| unique_vertex_count += @intFromBool(t > 0);

    result.warps_executed +%= @intFromBool(warp_offset > 0);

    const transformed: f32 = @floatFromInt(result.vertices_transformed);
    result.acmr = if (indices.len == 0)
        0
    else
        transformed / @as(f32, @floatFromInt(indices.len / 3));
    result.atvr = if (unique_vertex_count == 0)
        0
    else
        transformed / @as(f32, @floatFromInt(unique_vertex_count));

    return result;
}

pub const VertexFetchStatistics = struct {
    bytes_fetched: u32 = 0,
    /// Fetched bytes per byte of the vertices used: 1 at best, each byte
    /// fetched once.
    overfetch: f32 = 0,
};

/// Counts the bytes of vertex memory `indices` costs to fetch, in
/// 64-byte lines through a 128 KiB direct-mapped cache, for vertices of
/// `vertex_size` bytes. The model is simple, and real GPUs may differ.
pub fn analyzeVertexFetch(
    gpa: Allocator,
    indices: []const u32,
    vertex_count: usize,
    vertex_size: usize,
) Allocator.Error!VertexFetchStatistics {
    assert(vertex_size > 0 and vertex_size <= 256);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    var result: VertexFetchStatistics = .{};

    const vertex_visited = try scratch.alloc(u8, vertex_count);
    @memset(vertex_visited, 0);

    const cache_line = 64;
    const cache_size = 128 * 1024;

    // On typical meshes a direct-mapped cache comes close to a 4-way one,
    // and the model is a rough approximation anyway.
    var cache: [cache_size / cache_line]usize = @splat(0);

    for (indices) |index| {
        assert(index < vertex_count);

        vertex_visited[index] = 1;

        const start_address = index * vertex_size;
        const end_address = start_address + vertex_size;

        const start_tag = start_address / cache_line;
        const end_tag = (end_address + cache_line - 1) / cache_line;

        for (start_tag..end_tag) |tag| {
            const line = tag % cache.len;

            // Lines hold their tag plus one, as the cache starts zeroed.
            if (cache[line] != tag + 1) result.bytes_fetched +%= cache_line;
            cache[line] = tag + 1;
        }
    }

    var unique_vertex_count: usize = 0;

    for (vertex_visited) |visited| unique_vertex_count += visited;

    result.overfetch = if (unique_vertex_count == 0)
        0
    else
        @as(f32, @floatFromInt(result.bytes_fetched)) /
            @as(f32, @floatFromInt(unique_vertex_count * vertex_size));

    return result;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a cached vertex costs nothing again" {
    // Two triangles sharing an edge: 4 vertices for 2 triangles.
    const indices = [_]u32{ 0, 1, 2, 2, 1, 3 };
    const stats = try analyzeVertexCache(testing.allocator, &indices, 4, 16, 0, 0);
    try testing.expectEqual(4, stats.vertices_transformed);
    try testing.expectEqual(2.0, stats.acmr);
    try testing.expectEqual(1.0, stats.atvr);
}
