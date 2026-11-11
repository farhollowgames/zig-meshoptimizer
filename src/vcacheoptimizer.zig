//! Vertex cache optimization: reordering triangles so that a GPU's post
//! transform cache reuses more vertices, either by vertex scores tuned to
//! modern GPUs or by simulating a FIFO cache.
//!
//! Translated from meshoptimizer's vcacheoptimizer.cpp, which builds on
//! Forsyth, "Linear-Speed Vertex Cache Optimisation" (2006), and Sander,
//! Nehab and Barczak, "Fast Triangle Reordering for Vertex Locality and
//! Reduced Overdraw" (2007).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;

const none = std.math.maxInt(u32);

const cache_size_max = 16;
const valence_max = 8;

/// The scores `optimizeVertexCacheTable` gives a vertex: `cache[1 + p]` for
/// its position `p` in the simulated cache (-1 when outside it), plus
/// `live[n]` for the `n` triangles still to emit that use it, at most 8.
/// Scores must be positive for every vertex a triangle still uses.
pub const VertexScoreTable = struct {
    cache: [1 + cache_size_max]f32,
    live: [1 + valence_max]f32,

    /// Tuned to minimize the ACMR of a GPU with a cache profile like
    /// NVIDIA's and AMD's; `optimizeVertexCache` uses it.
    pub const default: VertexScoreTable = .{
        .cache = .{
            0,     0.779, 0.791, 0.789, 0.981, 0.843, 0.726, 0.847, 0.882,
            0.867, 0.799, 0.642, 0.613, 0.600, 0.568, 0.372, 0.234,
        },
        .live = .{ 0, 0.995, 0.713, 0.450, 0.404, 0.059, 0.005, 0.147, 0.006 },
    };

    /// Tuned to minimize the encoded index buffer size;
    /// `optimizeVertexCacheStrip` uses it.
    pub const strip: VertexScoreTable = .{
        .cache = .{
            0,     1.000, 1.000, 1.000, 0.453, 0.561, 0.490, 0.459, 0.179,
            0.526, 0.000, 0.227, 0.184, 0.490, 0.112, 0.050, 0.131,
        },
        .live = .{ 0, 0.956, 0.786, 0.577, 0.558, 0.618, 0.549, 0.499, 0.489 },
    };

    fn score(self: *const VertexScoreTable, cache_position: i32, live_triangles: u32) f32 {
        assert(cache_position >= -1 and cache_position < cache_size_max);

        const live_triangles_clamped = @min(live_triangles, valence_max);

        return self.cache[@intCast(1 + cache_position)] + self.live[live_triangles_clamped];
    }
};

/// For each vertex, the triangles that use it: `data[offsets[v]..][0..counts[v]]`.
/// Its slices are scratch memory, invalid once that is freed.
pub const TriangleAdjacency = struct {
    counts: []u32,
    offsets: []u32,
    data: []u32,

    pub fn init(
        scratch: *Scratch,
        indices: []const u32,
        vertex_count: usize,
    ) Allocator.Error!TriangleAdjacency {
        const face_count = indices.len / 3;

        const adjacency: TriangleAdjacency = .{
            .counts = try scratch.alloc(u32, vertex_count),
            .offsets = try scratch.alloc(u32, vertex_count),
            .data = try scratch.alloc(u32, indices.len),
        };

        @memset(adjacency.counts, 0);

        for (indices) |index| {
            assert(index < vertex_count);

            adjacency.counts[index] += 1;
        }

        var offset: u32 = 0;

        for (adjacency.offsets, adjacency.counts) |*o, count| {
            o.* = offset;
            offset += count;
        }

        for (0..face_count) |i| {
            const triangle: u32 = @intCast(i);
            for (indices[i * 3 ..][0..3]) |index| {
                adjacency.data[adjacency.offsets[index]] = triangle;
                adjacency.offsets[index] += 1;
            }
        }

        // Filling moved each offset to its list's end; move it back.
        for (adjacency.offsets, adjacency.counts) |*o, count| o.* -= count;

        return adjacency;
    }

    pub fn neighbors(self: TriangleAdjacency, vertex: u32) []u32 {
        return self.data[self.offsets[vertex]..][0..self.counts[vertex]];
    }

    /// Removes the emitted `triangle` from its `corners`' lists, so later
    /// walks over them are shorter; this lowers their counts too.
    pub fn remove(self: TriangleAdjacency, triangle: u32, corners: [3]u32) void {
        for (corners) |index| {
            const list = self.neighbors(index);

            for (list, 0..) |tri, i| {
                if (tri == triangle) {
                    list[i] = list[list.len - 1];
                    self.counts[index] -= 1;
                    break;
                }
            }
        }
    }
};

fn nextVertexDeadEnd(
    dead_end: []const u32,
    dead_end_top: *u32,
    input_cursor: *u32,
    live_triangles: []const u32,
) u32 {
    // The dead-end stack first.
    while (dead_end_top.* > 0) {
        dead_end_top.* -= 1;
        const vertex = dead_end[dead_end_top.*];

        if (live_triangles[vertex] > 0) return vertex;
    }

    // Then input order.
    while (input_cursor.* < live_triangles.len) {
        if (live_triangles[input_cursor.*] > 0) return input_cursor.*;

        input_cursor.* += 1;
    }

    return none;
}

fn nextVertexNeighbor(
    candidates: []const u32,
    live_triangles: []const u32,
    cache_timestamps: []const u32,
    timestamp: u32,
    cache_size: u32,
) u32 {
    var best_candidate: u32 = none;
    var best_priority: i32 = -1;

    for (candidates) |vertex| {
        // A vertex with no triangles left needs no processing.
        if (live_triangles[vertex] > 0) {
            var priority: i32 = 0;

            // Whether it would still be in the cache after fanning.
            const age = timestamp -% cache_timestamps[vertex];
            if (2 *% live_triangles[vertex] +% age <= cache_size) {
                // Its position in the cache.
                priority = @bitCast(age);
            }

            if (priority > best_priority) {
                best_candidate = vertex;
                best_priority = priority;
            }
        }
    }

    return best_candidate;
}

fn nextTriangleDeadEnd(input_cursor: *u32, emitted_flags: []const bool) u32 {
    // Input order.
    while (input_cursor.* < emitted_flags.len) {
        if (!emitted_flags[input_cursor.*]) return input_cursor.*;

        input_cursor.* += 1;
    }

    return none;
}

/// Writes `indices` to `destination` with the triangles reordered so the
/// GPU's vertex cache transforms fewer vertices, by the vertex scores in
/// `table`. `indices` refer to `vertex_count` vertices; `destination`
/// holds `indices.len` entries, and may be `indices` itself. Optimize each
/// draw call's range of an index buffer on its own.
pub fn optimizeVertexCacheTable(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
    table: *const VertexScoreTable,
) Allocator.Error!void {
    assert(indices.len % 3 == 0);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    if (indices.len == 0 or vertex_count == 0) return;

    var source = indices;
    if (destination.ptr == indices.ptr) {
        const copy = try scratch.alloc(u32, indices.len);
        @memcpy(copy, indices);
        source = copy;
    }

    const cache_size = 16;
    comptime assert(cache_size <= cache_size_max);

    const face_count = source.len / 3;

    const adjacency: TriangleAdjacency = try .init(&scratch, source, vertex_count);

    // Live triangle counts are the adjacency counts: emitting a triangle
    // removes it from the adjacency lists, so they always match.
    const live_triangles = adjacency.counts;

    const emitted_flags = try scratch.alloc(bool, face_count);
    @memset(emitted_flags, false);

    const vertex_scores = try scratch.alloc(f32, vertex_count);

    for (vertex_scores, live_triangles) |*s, live| s.* = table.score(-1, live);

    const triangle_scores = try scratch.alloc(f32, face_count);

    for (triangle_scores, 0..) |*s, i| {
        const a = source[i * 3 + 0];
        const b = source[i * 3 + 1];
        const c = source[i * 3 + 2];

        s.* = vertex_scores[a] + vertex_scores[b] + vertex_scores[c];
    }

    var cache_holder: [2 * (cache_size_max + 4)]u32 = undefined;
    var cache: []u32 = cache_holder[0 .. cache_size_max + 4];
    var cache_new: []u32 = cache_holder[cache_size_max + 4 ..];
    var cache_count: usize = 0;

    var current_triangle: u32 = 0;
    var input_cursor: u32 = 1;

    var output_triangle: usize = 0;

    while (current_triangle != none) {
        assert(output_triangle < face_count);

        const a = source[current_triangle * 3 + 0];
        const b = source[current_triangle * 3 + 1];
        const c = source[current_triangle * 3 + 2];

        destination[output_triangle * 3 ..][0..3].* = .{ a, b, c };
        output_triangle += 1;

        emitted_flags[current_triangle] = true;
        triangle_scores[current_triangle] = 0;

        // The new triangle's vertices enter the cache first.
        var cache_write: usize = 0;
        cache_new[0..3].* = .{ a, b, c };
        cache_write += 3;

        // Then the vertices of older triangles.
        for (cache[0..cache_count]) |index| {
            cache_new[cache_write] = index;
            cache_write += @intFromBool(index != a and index != b and index != c);
        }

        std.mem.swap([]u32, &cache, &cache_new);
        cache_count = @min(cache_write, cache_size);

        // This updates the live triangle counts too.
        adjacency.remove(current_triangle, .{ a, b, c });

        var best_triangle: u32 = none;
        var best_score: f32 = 0;

        // Update cache positions, vertex scores and triangle scores, and find
        // the next best triangle.
        for (cache[0..cache_write], 0..) |index, i| {
            // A vertex no triangle uses any more needs no new score.
            if (adjacency.counts[index] == 0) continue;

            const cache_position: i32 = if (i >= cache_size) -1 else @intCast(i);

            const score = table.score(cache_position, live_triangles[index]);
            const score_diff = score - vertex_scores[index];

            vertex_scores[index] = score;

            for (adjacency.neighbors(index)) |tri| {
                assert(!emitted_flags[tri]);

                const tri_score = triangle_scores[tri] + score_diff;
                assert(tri_score > 0);

                best_triangle = if (best_score < tri_score) tri else best_triangle;
                best_score = if (best_score < tri_score) tri_score else best_score;

                triangle_scores[tri] = tri_score;
            }
        }

        // At a dead end, go on with the input order.
        current_triangle = best_triangle;

        if (current_triangle == none) {
            current_triangle = nextTriangleDeadEnd(&input_cursor, emitted_flags);
        }
    }

    assert(output_triangle == face_count);
}

/// Writes `indices` to `destination` with the triangles reordered so the
/// GPU's vertex cache transforms fewer vertices. `indices` refer to
/// `vertex_count` vertices; `destination` holds `indices.len` entries, and
/// may be `indices` itself. Optimize each draw call's range of an index
/// buffer on its own.
pub fn optimizeVertexCache(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
) Allocator.Error!void {
    return optimizeVertexCacheTable(gpa, destination, indices, vertex_count, &.default);
}

/// `optimizeVertexCache` for strip-like caches: worse for the GPU's vertex
/// cache, but the order makes shorter triangle strips and compresses
/// better.
pub fn optimizeVertexCacheStrip(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
) Allocator.Error!void {
    return optimizeVertexCacheTable(gpa, destination, indices, vertex_count, &.strip);
}

/// `optimizeVertexCache` by simulating a FIFO cache of `cache_size`
/// vertices, at least 3: about three times faster, with worse results.
/// Choose a `cache_size` below the GPU's real cache size, so the cache does
/// not thrash.
pub fn optimizeVertexCacheFifo(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
    cache_size: u32,
) Allocator.Error!void {
    assert(indices.len % 3 == 0);
    assert(cache_size >= 3);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    if (indices.len == 0 or vertex_count == 0) return;

    var source = indices;
    if (destination.ptr == indices.ptr) {
        const copy = try scratch.alloc(u32, indices.len);
        @memcpy(copy, indices);
        source = copy;
    }

    const face_count = source.len / 3;

    const adjacency: TriangleAdjacency = try .init(&scratch, source, vertex_count);

    const live_triangles = try scratch.alloc(u32, vertex_count);
    @memcpy(live_triangles, adjacency.counts);

    const cache_timestamps = try scratch.alloc(u32, vertex_count);
    @memset(cache_timestamps, 0);

    const dead_end = try scratch.alloc(u32, source.len);
    var dead_end_top: u32 = 0;

    const emitted_flags = try scratch.alloc(bool, face_count);
    @memset(emitted_flags, false);

    var current_vertex: u32 = 0;

    var timestamp: u32 = cache_size + 1;
    // The vertex to restart from at a dead end.
    var input_cursor: u32 = 1;

    var output_triangle: usize = 0;

    while (current_vertex != none) {
        const candidates_begin = dead_end_top;

        // Emit every triangle of the vertex not emitted yet.
        for (adjacency.neighbors(current_vertex)) |triangle| {
            if (emitted_flags[triangle]) continue;

            const corners = source[triangle * 3 ..][0..3].*;

            destination[output_triangle * 3 ..][0..3].* = corners;
            output_triangle += 1;

            dead_end[dead_end_top..][0..3].* = corners;
            dead_end_top += 3;

            for (corners) |corner| live_triangles[corner] -= 1;

            // A vertex outside the cache enters it.
            for (corners) |corner| {
                if (timestamp -% cache_timestamps[corner] > cache_size) {
                    cache_timestamps[corner] = timestamp;
                    timestamp +%= 1;
                }
            }

            emitted_flags[triangle] = true;
        }

        // The next candidates are the vertices just pushed on the dead-end
        // stack.
        current_vertex = nextVertexNeighbor(
            dead_end[candidates_begin..dead_end_top],
            live_triangles,
            cache_timestamps,
            timestamp,
            cache_size,
        );

        if (current_vertex == none) {
            current_vertex = nextVertexDeadEnd(
                dead_end,
                &dead_end_top,
                &input_cursor,
                live_triangles,
            );
        }
    }

    assert(output_triangle == face_count);
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "every triangle comes out once" {
    const indices = [_]u32{ 0, 1, 2, 2, 1, 3, 4, 5, 6, 3, 1, 4 };
    var destination: [indices.len]u32 = undefined;
    try optimizeVertexCache(testing.allocator, &destination, &indices, 7);
    var fifo: [indices.len]u32 = undefined;
    try optimizeVertexCacheFifo(testing.allocator, &fifo, &indices, 7, 16);
    for ([_][]const u32{ &destination, &fifo }) |result| {
        var seen: [4]bool = @splat(false);
        for (0..4) |t| {
            const triangle = result[t * 3 ..][0..3];
            for (0..4) |s| {
                if (std.mem.eql(u32, triangle, indices[s * 3 ..][0..3])) seen[s] = true;
            }
        }
        try testing.expectEqualSlices(bool, &.{ true, true, true, true }, &seen);
    }
}
