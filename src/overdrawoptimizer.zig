//! Overdraw optimization: splitting a vertex cache optimized index buffer
//! into clusters of triangles and drawing the clusters that face out of the
//! mesh first, at a bounded cost in vertex cache efficiency.
//!
//! Translated from meshoptimizer's overdrawoptimizer.cpp, which builds on
//! Sander, Nehab and Barczak, "Fast Triangle Reordering for Vertex Locality
//! and Reduced Overdraw" (2007).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const checkIndex = @import("index.zig").check;
const VertexFloats = @import("strided.zig").VertexFloats;
const quantizeUnorm = @import("quantization.zig").quantizeUnorm;

/// Each cluster's sort key: how far its area-weighted centroid lies from
/// the mesh's centroid along its average normal. Clusters facing out of the
/// mesh score high.
fn calculateSortData(
    comptime Index: type,
    sort_data: []f32,
    indices: []const Index,
    positions: VertexFloats,
    clusters: []const u32,
) void {
    const vertex_count = positions.count();

    var mesh_centroid: [3]f32 = @splat(0);

    for (0..vertex_count) |i| {
        const p = positions.vec3(i);

        mesh_centroid[0] += p[0];
        mesh_centroid[1] += p[1];
        mesh_centroid[2] += p[2];
    }

    const count: f32 = @floatFromInt(vertex_count);
    mesh_centroid[0] /= count;
    mesh_centroid[1] /= count;
    mesh_centroid[2] /= count;

    for (clusters, 0..) |first, cluster| {
        const cluster_begin = @as(usize, first) * 3;
        const cluster_end = if (cluster + 1 < clusters.len)
            @as(usize, clusters[cluster + 1]) * 3
        else
            indices.len;
        assert(cluster_begin < cluster_end);

        var cluster_area: f32 = 0;
        var cluster_centroid: [3]f32 = @splat(0);
        var cluster_normal: [3]f32 = @splat(0);

        var i = cluster_begin;
        while (i < cluster_end) : (i += 3) {
            const p0 = positions.vec3(indices[i + 0]);
            const p1 = positions.vec3(indices[i + 1]);
            const p2 = positions.vec3(indices[i + 2]);

            const p10 = [3]f32{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
            const p20 = [3]f32{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };

            const normalx = p10[1] * p20[2] - p10[2] * p20[1];
            const normaly = p10[2] * p20[0] - p10[0] * p20[2];
            const normalz = p10[0] * p20[1] - p10[1] * p20[0];

            const area = @sqrt(normalx * normalx + normaly * normaly + normalz * normalz);

            cluster_centroid[0] += (p0[0] + p1[0] + p2[0]) * (area / 3);
            cluster_centroid[1] += (p0[1] + p1[1] + p2[1]) * (area / 3);
            cluster_centroid[2] += (p0[2] + p1[2] + p2[2]) * (area / 3);
            cluster_normal[0] += normalx;
            cluster_normal[1] += normaly;
            cluster_normal[2] += normalz;
            cluster_area += area;
        }

        const inv_cluster_area: f32 = if (cluster_area == 0) 0 else 1 / cluster_area;

        cluster_centroid[0] *= inv_cluster_area;
        cluster_centroid[1] *= inv_cluster_area;
        cluster_centroid[2] *= inv_cluster_area;

        const cluster_normal_length = @sqrt(cluster_normal[0] * cluster_normal[0] +
            cluster_normal[1] * cluster_normal[1] + cluster_normal[2] * cluster_normal[2]);
        const inv_cluster_normal_length: f32 =
            if (cluster_normal_length == 0) 0 else 1 / cluster_normal_length;

        cluster_normal[0] *= inv_cluster_normal_length;
        cluster_normal[1] *= inv_cluster_normal_length;
        cluster_normal[2] *= inv_cluster_normal_length;

        const centroid_vector = [3]f32{
            cluster_centroid[0] - mesh_centroid[0],
            cluster_centroid[1] - mesh_centroid[1],
            cluster_centroid[2] - mesh_centroid[2],
        };

        sort_data[cluster] = centroid_vector[0] * cluster_normal[0] +
            centroid_vector[1] * cluster_normal[1] + centroid_vector[2] * cluster_normal[2];
    }
}

/// Orders the clusters by `sort_data`, highest first, with a counting sort
/// of 11-bit keys; equal keys keep their order.
fn calculateSortOrderRadix(sort_order: []u32, sort_data: []const f32, sort_keys: []u16) void {
    // Scale the sort data to fixed-point snorm.
    var sort_data_max: f32 = 1e-3;

    for (sort_data) |data| {
        const dpa = @abs(data);

        sort_data_max = if (sort_data_max < dpa) dpa else sort_data_max;
    }

    const sort_bits = 11;

    for (sort_data, sort_keys) |data, *key| {
        // The distribution flips, so high dot products come first.
        const sort_key = 0.5 - 0.5 * (data / sort_data_max);

        key.* = @intCast(quantizeUnorm(sort_key, sort_bits) & ((1 << sort_bits) - 1));
    }

    var histogram: [1 << sort_bits]u32 = @splat(0);

    for (sort_keys) |key| histogram[key] += 1;

    // Each key's first place in the order.
    var histogram_sum: u32 = 0;

    for (&histogram) |*h| {
        const count = h.*;
        h.* = histogram_sum;
        histogram_sum += count;
    }

    for (sort_keys, 0..) |key, i| {
        sort_order[histogram[key]] = @intCast(i);
        histogram[key] += 1;
    }
}

/// Puts the vertices of triangle `triangle` in a FIFO cache of
/// `cache_size` vertices, as timestamps: a vertex is in the cache while
/// fewer than `cache_size` vertices went in after it. Returns how many
/// were missing.
fn updateCache(
    comptime Index: type,
    triangle: *const [3]Index,
    cache_size: u32,
    cache_timestamps: []u32,
    timestamp: *u32,
) u32 {
    var cache_misses: u32 = 0;

    for (triangle) |v| {
        if (timestamp.* -% cache_timestamps[v] > cache_size) {
            cache_timestamps[v] = timestamp.*;
            timestamp.* +%= 1;
            cache_misses += 1;
        }
    }

    return cache_misses;
}

/// Writes the first triangle of each cluster that starts with a triangle
/// missing the cache on all three vertices, and returns the cluster count.
fn generateHardBoundaries(
    comptime Index: type,
    destination: []u32,
    indices: []const Index,
    cache_size: u32,
    cache_timestamps: []u32,
) usize {
    @memset(cache_timestamps, 0);

    var timestamp: u32 = cache_size + 1;

    const face_count = indices.len / 3;

    var result: usize = 0;

    for (0..face_count) |i| {
        const triangle = indices[i * 3 ..][0..3];
        const m = updateCache(Index, triangle, cache_size, cache_timestamps, &timestamp);

        // A triangle missing all three vertices usually starts a new patch
        // of the mesh, disjoint from the vertices before; it sometimes comes
        // back to earlier vertices, which usually points at a weakness of
        // the vertex cache optimization. The first triangle misses three
        // times unless it is degenerate, so the first cluster starts at 0
        // either way.
        if (i == 0 or m == 3) {
            destination[result] = @intCast(i);
            result += 1;
        }
    }

    return result;
}

/// Splits each cluster of `clusters` where the triangles so far reach
/// `threshold` times the cluster's own cache misses per triangle, writes
/// the first triangle of each new cluster, and returns their count.
fn generateSoftBoundaries(
    comptime Index: type,
    destination: []u32,
    indices: []const Index,
    clusters: []const u32,
    cache_size: u32,
    threshold: f32,
    cache_timestamps: []u32,
) usize {
    @memset(cache_timestamps, 0);

    var timestamp: u32 = 0;

    var result: usize = 0;

    for (clusters, 0..) |first, it| {
        const start: usize = first;
        const end: usize = if (it + 1 < clusters.len) clusters[it + 1] else indices.len / 3;
        assert(start < end);

        // Empty the cache.
        timestamp +%= cache_size + 1;

        // The cluster's cache misses per triangle (ACMR).
        var cluster_misses: u32 = 0;

        for (start..end) |i| {
            const triangle = indices[i * 3 ..][0..3];
            cluster_misses += updateCache(
                Index,
                triangle,
                cache_size,
                cache_timestamps,
                &timestamp,
            );
        }

        const cluster_acmr = @as(f32, @floatFromInt(cluster_misses)) /
            @as(f32, @floatFromInt(end - start));
        const cluster_threshold = threshold * cluster_acmr;

        // The first new cluster starts at the hard boundary.
        destination[result] = @intCast(start);
        result += 1;

        // Empty the cache.
        timestamp +%= cache_size + 1;

        var running_misses: u32 = 0;
        var running_faces: u32 = 0;

        for (start..end) |i| {
            const triangle = indices[i * 3 ..][0..3];
            const m = updateCache(Index, triangle, cache_size, cache_timestamps, &timestamp);

            running_misses += m;
            running_faces += 1;

            const running_acmr = @as(f32, @floatFromInt(running_misses)) /
                @as(f32, @floatFromInt(running_faces));
            if (running_acmr <= cluster_threshold) {
                // This triangle reaches the target ACMR, so a new cluster
                // starts at the next one. After the last triangle that adds
                // `end`, an empty cluster, which the removal below takes
                // back.
                destination[result] = @intCast(i + 1);
                result += 1;

                // Empty the cache.
                timestamp +%= cache_size + 1;

                running_misses = 0;
                running_faces = 0;
            }
        }

        // A cluster ends whenever it reaches the target ACMR, so the last
        // one is the leftover: often a few triangles with a very bad ACMR,
        // which would weigh on the whole result. Removing the last boundary
        // merges it into the cluster before. When the leftover is empty,
        // the boundary is `end` and has to go anyway.
        if (destination[result - 1] != start) result -= 1;
    }

    return result;
}

/// Reorders the triangles of `indices` into `destination` to reduce
/// overdraw, while keeping most of their vertex cache efficiency.
/// `indices` must already be optimized for the vertex cache (by
/// `optimizeVertexCache`). `threshold` bounds how much worse the cache use
/// may get to reduce overdraw: 1.05 allows 5% more cache misses. An index
/// buffer of several draw calls needs a call per range. `destination` may
/// be `indices` itself.
pub fn optimizeOverdraw(
    comptime Index: type,
    gpa: Allocator,
    destination: []Index,
    indices: []const Index,
    positions: VertexFloats,
    threshold: f32,
) Allocator.Error!void {
    comptime checkIndex(Index);
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    // An empty mesh has nothing to reorder.
    if (indices.len == 0 or vertex_count == 0) return;

    var source = indices;
    if (destination.ptr == indices.ptr) {
        const copy = try scratch.alloc(Index, indices.len);
        @memcpy(copy, indices);
        source = copy;
    }

    const cache_size = 16;

    const cache_timestamps = try scratch.alloc(u32, vertex_count);

    // Hard boundaries where a triangle misses the cache on all its vertices.
    const hard_clusters = try scratch.alloc(u32, source.len / 3);
    const hard_cluster_count = generateHardBoundaries(
        Index,
        hard_clusters,
        source,
        cache_size,
        cache_timestamps,
    );

    // Soft boundaries within them.
    const soft_clusters = try scratch.alloc(u32, source.len / 3 + 1);
    const soft_cluster_count = generateSoftBoundaries(
        Index,
        soft_clusters,
        source,
        hard_clusters[0..hard_cluster_count],
        cache_size,
        threshold,
        cache_timestamps,
    );

    const clusters = soft_clusters[0..soft_cluster_count];

    const sort_data = try scratch.alloc(f32, clusters.len);
    calculateSortData(Index, sort_data, source, positions, clusters);

    const sort_keys = try scratch.alloc(u16, clusters.len);
    const sort_order = try scratch.alloc(u32, clusters.len);
    calculateSortOrderRadix(sort_order, sort_data, sort_keys);

    // Copy the clusters out in their sorted order.
    var offset: usize = 0;

    for (sort_order) |cluster| {
        const cluster_begin = @as(usize, clusters[cluster]) * 3;
        const cluster_end = if (cluster + 1 < clusters.len)
            @as(usize, clusters[cluster + 1]) * 3
        else
            source.len;

        const triangles = source[cluster_begin..cluster_end];
        @memcpy(destination[offset..][0..triangles.len], triangles);
        offset += triangles.len;
    }
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "an empty mesh is left alone" {
    var destination: [0]u32 = .{};
    try optimizeOverdraw(u32, testing.allocator, &destination, &.{}, .init(&.{}, 3), 1.05);
}
