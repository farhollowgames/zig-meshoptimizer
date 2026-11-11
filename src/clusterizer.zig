//! Meshlet building: splitting a mesh into small clusters of at most 256
//! vertices and 512 triangles, each with an 8-bit index buffer into its own
//! vertex list, for mesh shaders and cluster-based renderers; by growing
//! clusters along the surface, by scanning the index buffer, or by a
//! surface area heuristic split for ray tracing.
//!
//! Translated from meshoptimizer's clusterizer.cpp, which builds on
//! Wihlidal, "Optimizing the Graphics Pipeline with Compute" (2016), and
//! Wald and Havran, "On building fast kd-Trees for Ray Tracing, and on doing
//! that in O(N log N)" (2006).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const VertexFloats = @import("strided.zig").VertexFloats;
const TriangleAdjacency = @import("vcacheoptimizer.zig").TriangleAdjacency;
const checkIndex = @import("index.zig").check;

const none = std.math.maxInt(u32);
const float_max = std.math.floatMax(f32);

// Seed triangles are kept to a limited number, a few added per finished
// meshlet.
const meshlet_max_seeds = 256;
const meshlet_add_seeds = 4;

// Bounds the recursion on malformed inputs.
const meshlet_max_tree_depth = 50;

/// One meshlet's place in the arrays its builder fills: its vertices are
/// `meshlet_vertices[vertex_offset..][0..vertex_count]`, indices into the
/// mesh's vertex buffer, and its triangles are
/// `meshlet_triangles[triangle_offset..][0 .. triangle_count * 3]`, indices
/// into its own vertices.
pub const Meshlet = extern struct {
    vertex_offset: u32,
    triangle_offset: u32,
    vertex_count: u32,
    triangle_count: u32,

    const empty: Meshlet = .{
        .vertex_offset = 0,
        .triangle_offset = 0,
        .vertex_count = 0,
        .triangle_count = 0,
    };
};

/// A triangle's centroid and unit normal, or a meshlet's sums of them.
const Cone = struct {
    position: [3]f32,
    normal: [3]f32,

    const zero: Cone = .{ .position = @splat(0), .normal = @splat(0) };
};

/// `TriangleAdjacency.init` for indices that use few of many vertices: it
/// touches only the vertices the indices use.
fn sparseAdjacency(
    comptime Index: type,
    scratch: *Scratch,
    indices: []const Index,
    vertex_count: usize,
) Allocator.Error!TriangleAdjacency {
    const face_count = indices.len / 3;

    // The top bit of a count marks a vertex seen.
    const sparse_seen: u32 = 1 << 31;
    assert(indices.len < sparse_seen);

    const adjacency: TriangleAdjacency = .{
        .counts = try scratch.alloc(u32, vertex_count),
        .offsets = try scratch.alloc(u32, vertex_count),
        .data = try scratch.alloc(u32, indices.len),
    };

    for (indices) |index| assert(index < vertex_count);

    for (indices) |index| adjacency.counts[index] = 0;

    for (indices) |index| adjacency.counts[index] += 1;

    var offset: u32 = 0;

    for (indices) |v| {
        if (adjacency.counts[v] & sparse_seen == 0) {
            adjacency.offsets[v] = offset;
            offset += adjacency.counts[v];
            adjacency.counts[v] |= sparse_seen;
        }
    }

    for (0..face_count) |i| {
        const triangle: u32 = @intCast(i);
        for (indices[i * 3 ..][0..3]) |index| {
            adjacency.data[adjacency.offsets[index]] = triangle;
            adjacency.offsets[index] += 1;
        }
    }

    // Filling moved each offset to its list's end; move it back, and clear
    // the marks.
    for (indices) |v| {
        if (adjacency.counts[v] & sparse_seen != 0) {
            adjacency.counts[v] &= ~sparse_seen;
            adjacency.offsets[v] -= adjacency.counts[v];
        }
    }

    return adjacency;
}

/// Marks every vertex `indices` use as in no meshlet.
fn clearUsed(comptime Index: type, used: []i16, indices: []const Index) void {
    // For sparse inputs, clearing only the vertices the indices use is
    // faster.
    if (used.len <= indices.len) {
        @memset(used, -1);
    } else {
        for (indices) |index| {
            assert(index < used.len);
            used[index] = -1;
        }
    }
}

/// How many of a triangle's corners are not in the meshlet yet.
fn newVertices(used: []const i16, a: u32, b: u32, c: u32) u32 {
    return @as(u32, @intFromBool(used[a] < 0)) +
        @intFromBool(used[b] < 0) +
        @intFromBool(used[c] < 0);
}

fn meshletScore(distance: f32, spread: f32, cone_weight: f32, expected_radius: f32) f32 {
    const cone = 1 - spread * cone_weight;
    const cone_clamped: f32 = if (cone < 1e-3) 1e-3 else cone;

    return (1 + distance / expected_radius * (1 - cone_weight)) * cone_clamped;
}

fn meshletCone(acc: Cone, triangle_count: u32) Cone {
    var result = acc;

    const center_scale: f32 = if (triangle_count == 0)
        0
    else
        1 / @as(f32, @floatFromInt(triangle_count));

    for (&result.position) |*p| p.* *= center_scale;

    const n = result.normal;
    const axis_length = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
    const axis_scale: f32 = if (axis_length == 0) 0 else 1 / @sqrt(axis_length);

    for (&result.normal) |*v| v.* *= axis_scale;

    return result;
}

/// Fills each triangle's centroid and normal, and returns the mesh's area,
/// twice over.
fn computeTriangleCones(
    comptime Index: type,
    triangles: []Cone,
    indices: []const Index,
    positions: VertexFloats,
) f32 {
    const vertex_count = positions.count();

    var mesh_area: f32 = 0;

    for (triangles, 0..) |*triangle, i| {
        const a = indices[i * 3 + 0];
        const b = indices[i * 3 + 1];
        const c = indices[i * 3 + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        const p0 = positions.vec3(a);
        const p1 = positions.vec3(b);
        const p2 = positions.vec3(c);

        const p10 = [3]f32{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
        const p20 = [3]f32{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };

        const normalx = p10[1] * p20[2] - p10[2] * p20[1];
        const normaly = p10[2] * p20[0] - p10[0] * p20[2];
        const normalz = p10[0] * p20[1] - p10[1] * p20[0];

        const area = @sqrt(normalx * normalx + normaly * normaly + normalz * normalz);
        const invarea: f32 = if (area == 0) 0 else 1 / area;

        triangle.* = .{
            .position = .{
                (p0[0] + p1[0] + p2[0]) / 3,
                (p0[1] + p1[1] + p2[1]) / 3,
                (p0[2] + p1[2] + p2[2]) / 3,
            },
            .normal = .{ normalx * invarea, normaly * invarea, normalz * invarea },
        };

        mesh_area += area;
    }

    return mesh_area;
}

/// The arrays the builders fill.
const Output = struct {
    meshlets: []Meshlet,
    vertices: []u32,
    triangles: []u8,
    max_vertices: usize,
    max_triangles: usize,
};

/// Adds triangle `a`, `b`, `c` to `meshlet`, first writing it out at
/// `meshlet_offset` and starting the next one if the triangle does not fit
/// or `split` asks for it; returns whether it did.
fn appendMeshlet(
    meshlet: *Meshlet,
    a: u32,
    b: u32,
    c: u32,
    used: []i16,
    out: Output,
    meshlet_offset: usize,
    split: bool,
) bool {
    // Pointers, as the corners of a degenerate triangle share an entry.
    const av = &used[a];
    const bv = &used[b];
    const cv = &used[c];

    var result = false;

    const used_extra = newVertices(used, a, b, c);

    if (meshlet.vertex_count + used_extra > out.max_vertices or
        meshlet.triangle_count >= out.max_triangles or split)
    {
        out.meshlets[meshlet_offset] = meshlet.*;

        for (out.vertices[meshlet.vertex_offset..][0..meshlet.vertex_count]) |v| used[v] = -1;

        meshlet.vertex_offset += meshlet.vertex_count;
        meshlet.triangle_offset += meshlet.triangle_count * 3;
        meshlet.vertex_count = 0;
        meshlet.triangle_count = 0;

        result = true;
    }

    inline for (.{ av, bv, cv }, .{ a, b, c }) |local, vertex| {
        if (local.* < 0) {
            local.* = @intCast(meshlet.vertex_count);
            out.vertices[meshlet.vertex_offset + meshlet.vertex_count] = vertex;
            meshlet.vertex_count += 1;
        }
    }

    const at = meshlet.triangle_offset + meshlet.triangle_count * 3;
    out.triangles[at..][0..3].* = .{ @intCast(av.*), @intCast(bv.*), @intCast(cv.*) };
    meshlet.triangle_count += 1;

    return result;
}

/// What the flow of `buildMeshletsFlex` reads.
fn Flow(comptime Index: type) type {
    return struct {
        indices: []const Index,
        adjacency: TriangleAdjacency,
        triangles: []const Cone,
        live_triangles: []const u32,
    };
}

fn neighborTriangle(
    comptime Index: type,
    flow: Flow(Index),
    meshlet: Meshlet,
    meshlet_cone: Cone,
    meshlet_vertices: []const u32,
    used: []const i16,
    meshlet_expected_radius: f32,
    cone_weight: f32,
) u32 {
    const indices = flow.indices;
    const live = flow.live_triangles;

    var best_triangle: u32 = none;
    var best_priority: i32 = 5;
    var best_score: f32 = float_max;

    for (meshlet_vertices[meshlet.vertex_offset..][0..meshlet.vertex_count]) |index| {
        for (flow.adjacency.neighbors(index)) |triangle| {
            const a = indices[triangle * 3 + 0];
            const b = indices[triangle * 3 + 1];
            const c = indices[triangle * 3 + 2];

            const extra: i32 = @intCast(newVertices(used, a, b, c));
            assert(extra <= 2);

            var priority: i32 = -1;

            if (extra == 0) {
                // Triangles that add no vertices come first.
                priority = 0;
            } else if (live[a] == 1 or live[b] == 1 or live[c] == 1) {
                // Dangling triangles are costly to add to a new meshlet.
                priority = 1;
            } else if (@as(u32, @intFromBool(live[a] == 2)) +
                @intFromBool(live[b] == 2) +
                @intFromBool(live[c] == 2) >= 2)
            {
                // Adding it leaves another triangle dangling, which is good
                // for the flow.
                priority = 1 + extra;
            } else {
                // The rest come after, 3 or 4 by the vertices they add.
                priority = 2 + extra;
            }

            // The topology's priority always wins over the score, so a
            // worse priority needs no score.
            if (priority > best_priority) continue;

            const tri_cone = flow.triangles[triangle];

            const dx = tri_cone.position[0] - meshlet_cone.position[0];
            const dy = tri_cone.position[1] - meshlet_cone.position[1];
            const dz = tri_cone.position[2] - meshlet_cone.position[2];
            const distance = @sqrt(dx * dx + dy * dy + dz * dz);
            const spread = tri_cone.normal[0] * meshlet_cone.normal[0] +
                tri_cone.normal[1] * meshlet_cone.normal[1] +
                tri_cone.normal[2] * meshlet_cone.normal[2];

            const score = meshletScore(distance, spread, cone_weight, meshlet_expected_radius);

            // The priority always wins over the score, which keeps meshlets
            // compact and saves scoring.
            if (priority < best_priority or score < best_score) {
                best_triangle = triangle;
                best_priority = priority;
                best_score = score;
            }
        }
    }

    return best_triangle;
}

fn distanceTo(triangles: []const Cone, triangle: u32, corner: [3]f32) f32 {
    const dx = triangles[triangle].position[0] - corner[0];
    const dy = triangles[triangle].position[1] - corner[1];
    const dz = triangles[triangle].position[2] - corner[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

fn liveCount(comptime Index: type, flow: Flow(Index), triangle: u32) u32 {
    const live = flow.live_triangles;
    const corners = flow.indices[triangle * 3 ..][0..3];
    return live[corners[0]] +% live[corners[1]] +% live[corners[2]];
}

/// Writes up to `meshlet_add_seeds` seeds near `meshlet` to `seeds` and
/// returns how many.
fn appendSeedTriangles(
    comptime Index: type,
    seeds: []u32,
    flow: Flow(Index),
    meshlet: Meshlet,
    meshlet_vertices: []const u32,
    corner: [3]f32,
) usize {
    var best_seeds: [meshlet_add_seeds]u32 = @splat(none);
    var best_live: [meshlet_add_seeds]u32 = @splat(none);
    var best_score: [meshlet_add_seeds]f32 = @splat(float_max);

    for (meshlet_vertices[meshlet.vertex_offset..][0..meshlet.vertex_count]) |index| {
        var best_neighbor: u32 = none;
        var best_neighbor_live: u32 = none;

        // The neighbor with the fewest live triangles.
        for (flow.adjacency.neighbors(index)) |triangle| {
            const live = liveCount(Index, flow, triangle);

            if (live < best_neighbor_live) {
                best_neighbor = triangle;
                best_neighbor_live = live;
            }
        }

        // Add it to the seeds; the list is unsorted, and replacement is
        // approximate.
        if (best_neighbor == none) continue;

        const best_neighbor_score = distanceTo(flow.triangles, best_neighbor, corner);

        for (0..meshlet_add_seeds) |j| {
            // A non-strict comparison gives fewer duplicate seeds
            // (triangles next to several of the vertices).
            if (best_neighbor_live < best_live[j] or
                (best_neighbor_live == best_live[j] and best_neighbor_score <= best_score[j]))
            {
                best_seeds[j] = best_neighbor;
                best_live[j] = best_neighbor_live;
                best_score[j] = best_neighbor_score;
                break;
            }
        }
    }

    var seed_count: usize = 0;

    for (best_seeds) |seed| {
        if (seed != none) {
            seeds[seed_count] = seed;
            seed_count += 1;
        }
    }

    return seed_count;
}

/// Drops the emitted triangles from `seeds`, keeping the order, and returns
/// how many are left.
fn pruneSeedTriangles(seeds: []u32, emitted_flags: []const bool) usize {
    var result: usize = 0;

    for (seeds) |index| {
        seeds[result] = index;
        result += @intFromBool(!emitted_flags[index]);
    }

    return result;
}

fn selectSeedTriangle(
    comptime Index: type,
    seeds: []const u32,
    flow: Flow(Index),
    corner: [3]f32,
) u32 {
    var best_seed: u32 = none;
    var best_live: u32 = none;
    var best_score: f32 = float_max;

    for (seeds) |index| {
        const live = liveCount(Index, flow, index);
        const score = distanceTo(flow.triangles, index, corner);

        if (live < best_live or (live == best_live and score < best_score)) {
            best_seed = index;
            best_live = live;
            best_score = score;
        }
    }

    return best_seed;
}

/// A k-d tree node, in an array where a branch's left subtree follows it
/// and its right subtree starts `1 + children` after it.
const KdNode = packed struct(u64) {
    /// A branch's split coordinate, as bits, or a leaf point's index.
    payload: u32,
    /// The split axis of a branch, or 3 for a leaf.
    axis: u2,
    /// A leaf's point count, itself included, the points being the nodes
    /// from it on; zero once all its points are emitted. For a branch, the
    /// size of its left subtree, or zero once both subtrees are empty.
    children: u30,
};

/// Moves the points of `indices` below `pivot` on `axis` to the front, and
/// returns how many there are.
fn kdtreePartition(indices: []u32, points: []const Cone, axis: u2, pivot: f32) usize {
    var m: usize = 0;

    // Points before m are below the pivot, points from m to i are not.
    for (0..indices.len) |i| {
        const v = points[indices[i]].position[axis];

        // Swapping unconditionally keeps both runs when v is not below.
        std.mem.swap(u32, &indices[m], &indices[i]);

        m += @intFromBool(v < pivot);
    }

    return m;
}

fn kdtreeBuildLeaf(offset: usize, nodes: []KdNode, indices: []const u32) usize {
    nodes[offset] = .{ .payload = indices[0], .axis = 3, .children = @truncate(indices.len) };

    // The other points follow the leaf.
    for (indices[1..], nodes[offset + 1 ..][0 .. indices.len - 1]) |index, *tail| {
        // A count no traversal can use.
        tail.* = .{ .payload = index, .axis = 3, .children = std.math.maxInt(u30) };
    }

    return offset + indices.len;
}

fn kdtreeBuild(
    offset: usize,
    nodes: []KdNode,
    points: []const Cone,
    indices: []u32,
    leaf_size: usize,
    depth: u32,
) usize {
    assert(indices.len > 0);
    assert(offset < nodes.len);

    const count = indices.len;

    if (count <= leaf_size) return kdtreeBuildLeaf(offset, nodes, indices);

    var mean: [3]f32 = @splat(0);
    var vars: [3]f32 = @splat(0);
    var runc: f32 = 1;
    var runs: f32 = 1;

    // The points' statistics, by Welford's algorithm.
    for (indices) |index| {
        const point = points[index].position;

        for (0..3) |k| {
            const delta = point[k] - mean[k];
            mean[k] += delta * runs;
            vars[k] += delta * (point[k] - mean[k]);
        }

        runc += 1;
        runs = 1 / runc;
    }

    // Split on the axis of largest variance.
    const axis: u2 = if (vars[0] >= vars[1] and vars[0] >= vars[2])
        0
    else if (vars[1] >= vars[2]) 1 else 2;

    const split = mean[axis];
    const middle = kdtreePartition(indices, points, axis, split);

    // A degenerate partition makes one leaf of the points; so does the
    // depth limit, which bounds the recursion on pathological inputs.
    if (middle == 0 or middle == count or depth >= meshlet_max_tree_depth) {
        return kdtreeBuildLeaf(offset, nodes, indices);
    }

    // An unbalanced partition of a few points makes one small leaf; larger
    // ones still split, so outliers cannot make huge leaves.
    if ((middle <= leaf_size / 2 or middle >= count - leaf_size / 2) and count <= leaf_size * 8) {
        return kdtreeBuildLeaf(offset, nodes, indices);
    }

    // The left subtree follows the node.
    const left = indices[0..middle];
    const next_offset = kdtreeBuild(offset + 1, nodes, points, left, leaf_size, depth + 1);

    // The distance to the right subtree is stored.
    nodes[offset] = .{
        .payload = @bitCast(split),
        .axis = axis,
        .children = @truncate(next_offset - offset - 1),
    };

    return kdtreeBuild(next_offset, nodes, points, indices[middle..], leaf_size, depth + 1);
}

/// Finds the point not yet emitted nearest to `position` and closer than
/// `limit`, setting `result` and `limit` to it; empties nodes it finds
/// with nothing left to emit.
fn kdtreeNearest(
    nodes: []KdNode,
    root: usize,
    points: []const Cone,
    emitted_flags: []const bool,
    position: [3]f32,
    result: *u32,
    limit: *f32,
) void {
    const node = nodes[root];

    if (node.children == 0) return;

    if (node.axis == 3) {
        var inactive = true;

        for (nodes[root..][0..node.children]) |leaf| {
            const index = leaf.payload;

            if (emitted_flags[index]) continue;

            inactive = false;

            const point = points[index].position;

            const dx = point[0] - position[0];
            const dy = point[1] - position[1];
            const dz = point[2] - position[2];
            const distance = @sqrt(dx * dx + dy * dy + dz * dz);

            if (distance < limit.*) {
                result.* = index;
                limit.* = distance;
            }
        }

        // A leaf with nothing left to emit is emptied.
        if (inactive) nodes[root].children = 0;
    } else {
        // A branch: the side the position is on first.
        const split: f32 = @bitCast(node.payload);
        const delta = position[node.axis] - split;
        const first: usize = if (delta <= 0) 0 else node.children;
        const second = first ^ node.children;

        // A branch with both sides empty is emptied, to speed up later
        // searches; doing it before the recursion delays it by one search
        // but keeps the second call a tail call.
        if ((nodes[root + 1 + first].children | nodes[root + 1 + second].children) == 0) {
            nodes[root].children = 0;
        }

        // The tree's depth, limited when it is built, bounds the recursion.
        kdtreeNearest(nodes, root + 1 + first, points, emitted_flags, position, result, limit);

        // The other side, only if it can hold a closer point.
        if (@abs(delta) <= limit.*) {
            kdtreeNearest(nodes, root + 1 + second, points, emitted_flags, position, result, limit);
        }
    }
}

/// Fills `out` with meshlets for the triangles of `indices`, each with at
/// most `max_vertices` vertices (3 to 256) and `min_triangles` to
/// `max_triangles` triangles (1 to 512), and returns how many there are; as
/// `buildMeshlets`, but a meshlet with at least `min_triangles` triangles
/// is cut short when the nearest triangle left is more than `split_factor`
/// times the expected meshlet radius away (a `split_factor` of 0 never
/// cuts).
///
/// `meshlets` holds at least `buildMeshletsBound(indices.len, max_vertices,
/// min_triangles)` entries (`min_triangles`, not `max_triangles`), and
/// `meshlet_vertices` and `meshlet_triangles` at least `indices.len` each;
/// `positions` holds every vertex the indices use. A `cone_weight` from 0
/// to 1 trades meshlet size for better cone culling; use 0 without cone
/// culling.
pub fn buildMeshletsFlex(
    comptime Index: type,
    gpa: Allocator,
    meshlets: []Meshlet,
    meshlet_vertices: []u32,
    meshlet_triangles: []u8,
    indices: []const Index,
    positions: VertexFloats,
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,
    cone_weight: f32,
    split_factor: f32,
) Allocator.Error!usize {
    comptime checkIndex(Index);
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);

    assert(max_vertices >= 3 and max_vertices <= 256);
    assert(min_triangles >= 1 and min_triangles <= max_triangles and max_triangles <= 512);

    assert(cone_weight >= 0 and cone_weight <= 1);
    assert(split_factor >= 0);

    if (indices.len == 0) return 0;

    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const adjacency = if (vertex_count > indices.len and indices.len < (1 << 31))
        try sparseAdjacency(Index, &scratch, indices, vertex_count)
    else
        try TriangleAdjacency.init(Index, &scratch, indices, vertex_count);

    // Live triangle counts are the adjacency counts: emitting a triangle
    // removes it from the adjacency lists, so they always match.
    const live_triangles = adjacency.counts;

    const face_count = indices.len / 3;

    const emitted_flags = try scratch.alloc(bool, face_count);
    @memset(emitted_flags, false);

    // Each triangle's centroid and normal, for scoring.
    const triangles = try scratch.alloc(Cone, face_count);
    const mesh_area = computeTriangleCones(Index, triangles, indices, positions);

    const flow: Flow(Index) = .{
        .indices = indices,
        .adjacency = adjacency,
        .triangles = triangles,
        .live_triangles = live_triangles,
    };

    // A meshlet as a square patch has a radius of the square root of its
    // expected area.
    const face_count_f: f32 = @floatFromInt(face_count);
    const triangle_area_avg: f32 = if (face_count == 0) 0 else mesh_area / face_count_f * 0.5;
    const max_triangles_f: f32 = @floatFromInt(max_triangles);
    const meshlet_expected_radius = @sqrt(triangle_area_avg * max_triangles_f) * 0.5;

    // A k-d tree of the centroids, for nearest neighbor searches.
    const kdindices = try scratch.alloc(u32, face_count);
    for (kdindices, 0..) |*k, i| k.* = @intCast(i);

    const nodes = try scratch.alloc(KdNode, face_count * 2);
    _ = kdtreeBuild(0, nodes, triangles, kdindices, 8, 0);

    // A corner of the mesh, where the meshlet flow starts.
    var corner: [3]f32 = @splat(float_max);

    for (triangles) |tri| {
        for (&corner, tri.position) |*k, p| k.* = if (k.* > p) p else k.*;
    }

    // Each vertex's index in the current meshlet, -1 if it is not in it.
    const used = try scratch.alloc(i16, vertex_count);
    clearUsed(Index, used, indices);

    // The first seed is the triangle closest to the corner.
    var initial_seed: u32 = none;
    var initial_score: f32 = float_max;

    for (0..face_count) |i| {
        const score = distanceTo(triangles, @intCast(i), corner);

        if (initial_seed == none or score < initial_score) {
            initial_seed = @intCast(i);
            initial_score = score;
        }
    }

    // Seed triangles that continue the meshlet flow.
    var seeds: [meshlet_max_seeds]u32 = @splat(0);
    var seed_count: usize = 0;

    const out: Output = .{
        .meshlets = meshlets,
        .vertices = meshlet_vertices,
        .triangles = meshlet_triangles,
        .max_vertices = max_vertices,
        .max_triangles = max_triangles,
    };

    var meshlet: Meshlet = .empty;
    var meshlet_offset: usize = 0;

    var meshlet_cone_acc: Cone = .zero;

    while (true) {
        const meshlet_cone = meshletCone(meshlet_cone_acc, meshlet.triangle_count);

        // The first triangle has no meshlet cone to score against, so it is
        // the first seed; later ones are neighbors, by connectivity and
        // distance.
        var best_triangle: u32 = if (meshlet_offset == 0 and meshlet.triangle_count == 0)
            initial_seed
        else
            neighborTriangle(
                Index,
                flow,
                meshlet,
                meshlet_cone,
                meshlet_vertices,
                used,
                meshlet_expected_radius,
                cone_weight,
            );

        var split = false;

        // Out of neighbors, search by distance alone: the closest triangle,
        // connected or not.
        if (best_triangle == none) {
            var index: u32 = none;
            var distance: f32 = float_max;

            kdtreeNearest(
                nodes,
                0,
                triangles,
                emitted_flags,
                meshlet_cone.position,
                &index,
                &distance,
            );

            best_triangle = index;
            split = meshlet.triangle_count >= min_triangles and split_factor > 0 and
                distance > meshlet_expected_radius * split_factor;
        }

        if (best_triangle == none) break;

        const corners = indices[best_triangle * 3 ..][0..3].*;
        const best_extra = newVertices(used, corners[0], corners[1], corners[2]);

        // A triangle that does not fit starts a new meshlet; re-select from
        // the seeds, to keep the global flow.
        if (split or meshlet.vertex_count + best_extra > max_vertices or
            meshlet.triangle_count >= max_triangles)
        {
            seed_count = pruneSeedTriangles(seeds[0..seed_count], emitted_flags);
            seed_count = if (seed_count + meshlet_add_seeds <= meshlet_max_seeds)
                seed_count
            else
                meshlet_max_seeds - meshlet_add_seeds;
            seed_count += appendSeedTriangles(
                Index,
                seeds[seed_count..],
                flow,
                meshlet,
                meshlet_vertices,
                corner,
            );

            const best_seed = selectSeedTriangle(Index, seeds[0..seed_count], flow, corner);

            // Seeds come from adjacency, so a disconnected mesh may have
            // none left.
            best_triangle = if (best_seed != none) best_seed else best_triangle;
        }

        const a = indices[best_triangle * 3 + 0];
        const b = indices[best_triangle * 3 + 1];
        const c = indices[best_triangle * 3 + 2];

        // A full meshlet is written out, and its cone starts over.
        if (appendMeshlet(&meshlet, a, b, c, used, out, meshlet_offset, split)) {
            meshlet_offset += 1;
            meshlet_cone_acc = .zero;
        }

        // This updates the live triangle counts too.
        adjacency.remove(best_triangle, .{ a, b, c });

        // The meshlet's cone, for scoring the next triangles.
        for (&meshlet_cone_acc.position, triangles[best_triangle].position) |*acc, p| acc.* += p;
        for (&meshlet_cone_acc.normal, triangles[best_triangle].normal) |*acc, n| acc.* += n;

        assert(!emitted_flags[best_triangle]);
        emitted_flags[best_triangle] = true;
    }

    if (meshlet.triangle_count != 0) {
        meshlets[meshlet_offset] = meshlet;
        meshlet_offset += 1;
    }

    assert(meshlet_offset <= buildMeshletsBound(indices.len, max_vertices, min_triangles));
    return meshlet_offset;
}

/// The most meshlets the builders make from `index_count` indices with
/// these limits: the length `meshlets` needs. Use `min_triangles` as
/// `max_triangles` for `buildMeshletsFlex` and `buildMeshletsSpatial`.
pub fn buildMeshletsBound(index_count: usize, max_vertices: usize, max_triangles: usize) usize {
    assert(index_count % 3 == 0);
    assert(max_vertices >= 3 and max_vertices <= 256);
    assert(max_triangles >= 1 and max_triangles <= 512);

    // The worst case is a mesh with no shared vertices, which strains both
    // limits alike; a meshlet may leave 2 vertex places unused, since one
    // with room for 3 takes any triangle.
    const max_vertices_conservative = max_vertices - 2;
    const meshlet_limit_vertices = @divFloor(
        index_count + max_vertices_conservative - 1,
        max_vertices_conservative,
    );
    const meshlet_limit_triangles = @divFloor(index_count / 3 + max_triangles - 1, max_triangles);

    return @max(meshlet_limit_vertices, meshlet_limit_triangles);
}

/// Splits the triangles of `indices` into meshlets of at most
/// `max_vertices` vertices (3 to 256) and `max_triangles` triangles (1 to
/// 512), grown along the surface so each stays small, writes them to
/// `meshlets`, `meshlet_vertices` and `meshlet_triangles`, and returns how
/// many there are. For mesh shaders, optimize each one after with
/// `optimizeMeshlet`.
///
/// `meshlets` holds at least `buildMeshletsBound(indices.len, max_vertices,
/// max_triangles)` entries, and `meshlet_vertices` and `meshlet_triangles`
/// at least `indices.len` each (not the vertex count); `positions` holds
/// every vertex the indices use. A `cone_weight` from 0 to 1 trades meshlet
/// size for better cone culling; use 0 without cone culling.
pub fn buildMeshlets(
    comptime Index: type,
    gpa: Allocator,
    meshlets: []Meshlet,
    meshlet_vertices: []u32,
    meshlet_triangles: []u8,
    indices: []const Index,
    positions: VertexFloats,
    max_vertices: usize,
    max_triangles: usize,
    cone_weight: f32,
) Allocator.Error!usize {
    return buildMeshletsFlex(
        Index,
        gpa,
        meshlets,
        meshlet_vertices,
        meshlet_triangles,
        indices,
        positions,
        max_vertices,
        max_triangles,
        max_triangles,
        cone_weight,
        0,
    );
}

/// `buildMeshlets` without positions: the triangles go into meshlets in
/// index buffer order, so optimize the buffer for the vertex cache first.
/// `indices` refer to `vertex_count` vertices.
pub fn buildMeshletsScan(
    comptime Index: type,
    gpa: Allocator,
    meshlets: []Meshlet,
    meshlet_vertices: []u32,
    meshlet_triangles: []u8,
    indices: []const Index,
    vertex_count: usize,
    max_vertices: usize,
    max_triangles: usize,
) Allocator.Error!usize {
    comptime checkIndex(Index);
    assert(indices.len % 3 == 0);

    assert(max_vertices >= 3 and max_vertices <= 256);
    assert(max_triangles >= 1 and max_triangles <= 512);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    // Each vertex's index in the current meshlet, -1 if it is not in it.
    const used = try scratch.alloc(i16, vertex_count);
    clearUsed(Index, used, indices);

    const out: Output = .{
        .meshlets = meshlets,
        .vertices = meshlet_vertices,
        .triangles = meshlet_triangles,
        .max_vertices = max_vertices,
        .max_triangles = max_triangles,
    };

    var meshlet: Meshlet = .empty;
    var meshlet_offset: usize = 0;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const a = indices[i + 0];
        const b = indices[i + 1];
        const c = indices[i + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        // A full meshlet is written out before the triangle starts the next.
        const full = appendMeshlet(&meshlet, a, b, c, used, out, meshlet_offset, false);
        meshlet_offset += @intFromBool(full);
    }

    if (meshlet.triangle_count != 0) {
        meshlets[meshlet_offset] = meshlet;
        meshlet_offset += 1;
    }

    assert(meshlet_offset <= buildMeshletsBound(indices.len, max_vertices, max_triangles));
    return meshlet_offset;
}

/// A triangle's bounding box, followed in memory by the next one's, and by a
/// zeroed box after the last, so a vector load may read 4 floats from
/// `max`.
const BvhBox = extern struct {
    min: [3]f32,
    max: [3]f32,
};

const Vec4 = @Vector(4, f32);

/// A running bounding box; only the first three lanes count.
const BvhAccumulator = struct {
    min: Vec4,
    max: Vec4,

    const empty: BvhAccumulator = .{
        .min = .{ float_max, float_max, float_max, 0 },
        .max = .{ -float_max, -float_max, -float_max, 0 },
    };
};

/// How the original takes minima and maxima of boxes, by its SIMD path:
/// the results differ for NaN coordinates only.
pub const BoxMerge = enum {
    /// x86's MINPS and MAXPS: the second operand unless the first one is
    /// smaller (larger).
    sse,
    /// AArch64's FMIN and FMAX: NaN if either is NaN.
    neon,
    /// The original without SIMD: the new box's coordinate if it is smaller
    /// (larger).
    scalar,
};

/// The box merge the original uses on this target.
pub const target_box_merge: BoxMerge = if (builtin.cpu.has(.x86, .sse2))
    .sse
else if (builtin.cpu.arch.family() == .aarch64) .neon else .scalar;

/// Grows `accumulator` by box `index` of `boxes`, its floats in order, and
/// returns the area of the result, half its surface area.
fn boxMerge(
    comptime merge: BoxMerge,
    accumulator: *BvhAccumulator,
    boxes: []const f32,
    index: u32,
) f32 {
    const floats = boxes[@as(usize, index) * 6 ..];
    // The fourth lane reads the next coordinate, or the padding box: it
    // takes no part in the area.
    const other_min: Vec4 = floats[0..4].*;
    const other_max: Vec4 = floats[3..7].*;

    var min = accumulator.min;
    var max = accumulator.max;

    switch (merge) {
        .sse => {
            min = @select(f32, min < other_min, min, other_min);
            max = @select(f32, max > other_max, max, other_max);
        },
        .neon => {
            const nan: Vec4 = @splat(std.math.nan(f32));
            const either_nan = (min != min) | (other_min != other_min);
            min = @select(f32, either_nan, nan, @select(f32, min < other_min, min, other_min));
            const either_nan_max = (max != max) | (other_max != other_max);
            max = @select(f32, either_nan_max, nan, @select(f32, max > other_max, max, other_max));
        },
        .scalar => {
            min = @select(f32, other_min < min, other_min, min);
            max = @select(f32, other_max > max, other_max, max);
        },
    }

    accumulator.min = min;
    accumulator.max = max;

    const size = max - min;
    const sx = size[0];
    const sy = size[1];
    const sz = size[2];
    return sx * sy + sy * sz + sz * sx;
}

/// Maps a float's bits to an integer of the same order.
fn radixFloat(v: u32) u32 {
    // A positive float flips its sign bit, a negative one every bit.
    const mask: u32 = @as(u32, @bitCast(@as(i32, @bitCast(v)) >> 31)) | 0x80000000;
    return v ^ mask;
}

const Histogram = [1024][3]u32;

/// Three 10-bit histograms of `keys` at once, dropping the 2 lowest bits,
/// turned into their prefix sums.
fn computeHistogram(hist: *Histogram, keys: []const f32) void {
    @memset(hist, @splat(0));

    for (keys) |key| {
        const id = radixFloat(@bitCast(key));

        hist[(id >> 2) & 1023][0] += 1;
        hist[(id >> 12) & 1023][1] += 1;
        hist[(id >> 22) & 1023][2] += 1;
    }

    var sum0: u32 = 0;
    var sum1: u32 = 0;
    var sum2: u32 = 0;

    for (hist) |*bucket| {
        const hx = bucket[0];
        const hy = bucket[1];
        const hz = bucket[2];

        bucket.* = .{ sum0, sum1, sum2 };

        sum0 += hx;
        sum1 += hy;
        sum2 += hz;
    }
}

fn radixPass(
    destination: []u32,
    source: []const u32,
    keys: []const f32,
    hist: *Histogram,
    comptime pass: usize,
) void {
    // The 2 lowest bits are dropped, so 3 passes of 10 bits cover the rest.
    const bitoff = pass * 10 + 2;

    for (source) |s| {
        const id = (radixFloat(@bitCast(keys[s])) >> bitoff) & 1023;

        destination[hist[id][pass]] = s;
        hist[id][pass] += 1;
    }
}

/// Fills each triangle's box and, for each axis `k`, the centroids
/// `centroids[k * face_count ..]` of the boxes.
fn bvhPrepare(
    comptime Index: type,
    boxes: []BvhBox,
    centroids: []f32,
    indices: []const Index,
    positions: VertexFloats,
) void {
    const vertex_count = positions.count();
    const face_count = boxes.len;

    for (boxes, 0..) |*box, i| {
        const a = indices[i * 3 + 0];
        const b = indices[i * 3 + 1];
        const c = indices[i * 3 + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        const va = positions.vec3(a);
        const vb = positions.vec3(b);
        const vc = positions.vec3(c);

        for (0..3) |k| {
            box.min[k] = if (va[k] < vb[k]) va[k] else vb[k];
            box.min[k] = if (vc[k] < box.min[k]) vc[k] else box.min[k];

            box.max[k] = if (va[k] > vb[k]) va[k] else vb[k];
            box.max[k] = if (vc[k] > box.max[k]) vc[k] else box.max[k];

            centroids[i + face_count * k] = (box.min[k] + box.max[k]) / 2;
        }
    }
}

/// The vertices the triangles of `order` use, and in `out`, if given, how
/// many the first 1, 2, ... of them use. Leaves `used` as it found it,
/// every entry -1.
fn bvhCountVertices(
    comptime Index: type,
    order: []const u32,
    used: []i16,
    indices: []const Index,
    out: ?[]u32,
) usize {
    var used_vertices: usize = 0;
    for (order, 0..) |index, i| {
        const a = indices[index * 3 + 0];
        const b = indices[index * 3 + 1];
        const c = indices[index * 3 + 2];

        used_vertices += newVertices(used, a, b, c);
        used[a] = 1;
        used[b] = 1;
        used[c] = 1;

        if (out) |list| list[i] = @intCast(used_vertices);
    }

    for (order) |index| {
        for (indices[index * 3 ..][0..3]) |v| used[v] = -1;
    }

    return used_vertices;
}

/// Marks `boundary` as one meshlet.
fn bvhPackLeaf(boundary: []u8) void {
    assert(boundary.len > 0);

    boundary[0] = 1;
    @memset(boundary[1..], 0);
}

/// Cuts `order` into meshlets in order, as many triangles as fit.
fn bvhPackTail(
    comptime Index: type,
    boundary: []u8,
    order: []const u32,
    used: []i16,
    indices: []const Index,
    max_vertices: usize,
    max_triangles: usize,
) void {
    const count = order.len;
    var i: usize = 0;
    while (i < count) {
        const chunk = if (i + max_triangles <= count) max_triangles else count - i;

        if (bvhCountVertices(Index, order[i..][0..chunk], used, indices, null) <= max_vertices) {
            bvhPackLeaf(boundary[i..][0..chunk]);
            i += chunk;
            continue;
        }

        // The chunk has too many vertices: cut a smaller meshlet.
        assert(chunk > max_vertices / 3);

        bvhPackLeaf(boundary[i..][0 .. max_vertices / 3]);
        i += max_vertices / 3;
    }
}

/// Whether `count` is a sum of numbers from `min` to `max`.
fn bvhDivisible(count: usize, min: usize, max: usize) bool {
    // It is when count is from k*min to k*max for some k, so when
    // ceil(count / max) <= floor(count / min); this form needs one division
    // (as nv_cluster_builder's), and none in the common case of min <=
    // max/2.
    return if (min * 2 <= max) count >= min else count % min <= (count / min) * (max - min);
}

/// Fills `areas[i]` with the area of the boxes of `order[0..i]`, and
/// `areas[count + i]` with that of the last `i + 1`.
fn bvhComputeArea(
    comptime merge: BoxMerge,
    areas: []f32,
    boxes: []const f32,
    order: []const u32,
) void {
    var accuml: BvhAccumulator = .empty;
    var accumr: BvhAccumulator = .empty;

    const count = order.len;

    for (0..count) |i| {
        if (merge == .sse and i + 16 < count) {
            // Fetch boxes ahead to stall less on cache misses; the loop is
            // not bound by loads, so this costs nothing on small inputs.
            @prefetch(boxes[@as(usize, order[i + 16]) * 6 ..].ptr, .{});
            @prefetch(boxes[@as(usize, order[count - 1 - i - 16]) * 6 ..].ptr, .{});
        }

        const larea = boxMerge(merge, &accuml, boxes, order[i]);
        const rarea = boxMerge(merge, &accumr, boxes, order[count - 1 - i]);

        areas[i] = larea;
        areas[i + count] = rarea;
    }
}

fn toFloat(n: usize) f32 {
    return @floatFromInt(@as(i32, @intCast(n)));
}

/// The split of `count` triangles, `step` apart, with the least surface
/// area cost, and in `out_cost` that cost.
fn bvhPivot(
    areas: []const f32,
    vertices: ?[]const u32,
    count: usize,
    step: usize,
    min: usize,
    max: usize,
    fill: f32,
    maxfill: usize,
    out_cost: *f32,
) usize {
    const aligned = count >= min * 2 and bvhDivisible(count, min, max);
    const end = if (aligned) count - min else count - 1;

    const rmaxfill = 1 / toFloat(maxfill);

    var bestsplit: usize = 0;
    var bestcost: f32 = float_max;

    var i = min - 1;
    while (i < end) : (i += step) {
        const lsplit = i + 1;
        const rsplit = count - (i + 1);

        if (!bvhDivisible(lsplit, min, max)) continue;
        if (aligned and !bvhDivisible(rsplit, min, max)) continue;

        // areas[x] covers boxes 0 to x; areas[count + count - 1 - x] boxes
        // x to the last.
        const larea = areas[i];
        const rarea = areas[(count - 1 - (i + 1)) + count];
        var cost = larea * toFloat(lsplit) + rarea * toFloat(rsplit);

        if (cost > bestcost) continue;

        // A vertex bound cluster's fill counts vertices, both sides by the
        // left-to-right count: counting both ways costs more and fills a
        // little worse in practice.
        const lfill = if (vertices) |list| list[i] else lsplit;
        const rfill = if (vertices) |list| list[i] else rsplit;

        // The places left in the last meshlet of each side; rounding up to
        // maxfill in floats saves an integer division.
        const maxfill_int: i32 = @intCast(maxfill);
        const lrounded: i32 = @intFromFloat(toFloat(lfill + maxfill - 1) * rmaxfill);
        const rrounded: i32 = @intFromFloat(toFloat(rfill + maxfill - 1) * rmaxfill);
        const lrest = lrounded * maxfill_int - @as(i32, @intCast(lfill));
        const rrest = rrounded * maxfill_int - @as(i32, @intCast(rfill));

        const lrest_f: f32 = @floatFromInt(lrest);
        const rrest_f: f32 = @floatFromInt(rrest);
        cost += fill * (lrest_f * larea + rrest_f * rarea);

        if (cost < bestcost) {
            bestcost = cost;
            bestsplit = i + 1;
        }
    }

    out_cost.* = bestcost;
    return bestsplit;
}

/// Writes `order` to `target`, the triangles `sides` marks 0 first and
/// those it marks 1 from `split` on, each in their order.
fn bvhPartition(target: []u32, order: []const u32, sides: []const u8, split: usize) void {
    var l: usize = 0;
    var r = split;

    for (order) |index| {
        const side = sides[index];
        target[if (side != 0) r else l] = index;
        l += 1;
        l -= side;
        r += side;
    }

    assert(l == split and r == order.len);
}

/// The scratch memory `bvhSplit` shares down its recursion, in three views.
const BvhWork = struct {
    floats: []f32,
    words: []u32,
    bytes: []u8,

    fn of(floats: []f32) BvhWork {
        const bytes = std.mem.sliceAsBytes(floats);
        return .{ .floats = floats, .words = std.mem.bytesAsSlice(u32, bytes), .bytes = bytes };
    }
};

/// What `bvhSplit` reads at every level.
fn BvhSplit(comptime Index: type) type {
    return struct {
        boxes: []const f32,
        work: BvhWork,
        used: []i16,
        indices: []const Index,
        max_vertices: usize,
        min_triangles: usize,
        max_triangles: usize,
        fill_weight: f32,
    };
}

/// Marks in `boundary` where each meshlet of the triangles in `orders`
/// starts: the triangles in the order of their centroids on each axis.
fn bvhSplit(
    comptime Index: type,
    comptime merge: BoxMerge,
    split: *const BvhSplit(Index),
    orders: [3][]u32,
    boundary: []u8,
    depth: u32,
) void {
    const count = boundary.len;
    const max_vertices = split.max_vertices;
    const min_triangles = split.min_triangles;
    const max_triangles = split.max_triangles;

    if (count <= max_triangles and
        bvhCountVertices(Index, orders[0], split.used, split.indices, null) <= max_vertices)
    {
        return bvhPackLeaf(boundary);
    }

    // Step 1 always works; step max is cheaper when min equals max.
    const step = if (min_triangles == max_triangles and count > max_triangles) max_triangles else 1;

    // A cluster that fits by triangles but could not be packed has too many
    // vertices.
    const mint = if (count <= max_triangles and max_vertices / 3 < min_triangles)
        max_vertices / 3
    else
        min_triangles;
    const maxfill = if (count <= max_triangles) max_vertices else max_triangles;

    var bestk: ?usize = null;
    var bestsplit: usize = 0;
    var bestcost: f32 = float_max;

    for (0..3) |k| {
        const areas = split.work.floats[0 .. 2 * count];
        var vertices: ?[]u32 = null;

        bvhComputeArea(merge, areas, split.boxes, orders[k]);

        if (count <= max_triangles) {
            // A vertex bound cluster counts the vertices of every split.
            const list = split.work.words[2 * count ..][0..count];
            _ = bvhCountVertices(Index, orders[k], split.used, split.indices, list);
            vertices = list;
        }

        var axiscost: f32 = float_max;
        const axissplit = bvhPivot(
            areas,
            vertices,
            count,
            step,
            mint,
            max_triangles,
            split.fill_weight,
            maxfill,
            &axiscost,
        );

        if (axissplit != 0 and axiscost < bestcost) {
            bestk = k;
            bestcost = axiscost;
            bestsplit = axissplit;
        }
    }

    // No split: the costs of the admissible splits are NaN, or the input is
    // pathologically unbalanced. The depth limit bounds the recursion.
    if (bestk == null or depth >= meshlet_max_tree_depth) {
        return bvhPackTail(
            Index,
            boundary,
            orders[0],
            split.used,
            split.indices,
            max_vertices,
            max_triangles,
        );
    }
    const best = bestk.?;

    // Each triangle's side of the split.
    const sides = split.work.bytes[count * @sizeOf(u32) ..];

    for (orders[best][0..bestsplit]) |index| sides[index] = 0;

    for (orders[best][bestsplit..]) |index| sides[index] = 1;

    // The other axes split the same way, keeping their order.
    const temp = split.work.words[0..count];

    for (orders, 0..) |axis, k| {
        if (k == best) continue;

        @memcpy(temp, axis);
        bvhPartition(axis, temp, sides, bestsplit);
    }

    bvhSplit(
        Index,
        merge,
        split,
        .{ orders[0][0..bestsplit], orders[1][0..bestsplit], orders[2][0..bestsplit] },
        boundary[0..bestsplit],
        depth + 1,
    );
    bvhSplit(
        Index,
        merge,
        split,
        .{ orders[0][bestsplit..], orders[1][bestsplit..], orders[2][bestsplit..] },
        boundary[bestsplit..],
        depth + 1,
    );
}

/// Splits the triangles of `indices` into meshlets for ray tracing, as
/// `buildMeshlets` does for rasterizing: each has at most `max_vertices`
/// vertices (3 to 256) and `min_triangles` to `max_triangles` triangles (1
/// to 512), split by the surface area heuristic. Writes them to `meshlets`,
/// `meshlet_vertices` and `meshlet_triangles`, and returns how many there
/// are.
///
/// `meshlets` holds at least `buildMeshletsBound(indices.len, max_vertices,
/// min_triangles)` entries (`min_triangles`, not `max_triangles`), and
/// `meshlet_vertices` and `meshlet_triangles` at least `indices.len` each;
/// `positions` holds every vertex the indices use. A positive
/// `fill_weight` favors fuller meshlets at some cost to the heuristic's
/// quality; 0.5 is a safe default.
pub fn buildMeshletsSpatial(
    comptime Index: type,
    gpa: Allocator,
    meshlets: []Meshlet,
    meshlet_vertices: []u32,
    meshlet_triangles: []u8,
    indices: []const Index,
    positions: VertexFloats,
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,
    fill_weight: f32,
) Allocator.Error!usize {
    return buildMeshletsSpatialMerge(
        Index,
        target_box_merge,
        gpa,
        meshlets,
        meshlet_vertices,
        meshlet_triangles,
        indices,
        positions,
        max_vertices,
        min_triangles,
        max_triangles,
        fill_weight,
    );
}

/// `buildMeshletsSpatial` with the box merge of the original's `merge`
/// path, which gives the same results as the others unless a position is
/// NaN.
pub fn buildMeshletsSpatialMerge(
    comptime Index: type,
    comptime merge: BoxMerge,
    gpa: Allocator,
    meshlets: []Meshlet,
    meshlet_vertices: []u32,
    meshlet_triangles: []u8,
    indices: []const Index,
    positions: VertexFloats,
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,
    fill_weight: f32,
) Allocator.Error!usize {
    comptime checkIndex(Index);
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);

    assert(max_vertices >= 3 and max_vertices <= 256);
    assert(min_triangles >= 1 and min_triangles <= max_triangles and max_triangles <= 512);

    assert(fill_weight >= 0);

    if (indices.len == 0) return 0;

    const face_count = indices.len / 3;
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    // Room for 3 floats and a word per triangle when sorting, 2 floats and
    // a word when pivoting, or a word and a byte when partitioning.
    const work: BvhWork = .of(try scratch.alloc(f32, face_count * 4));

    // Boxes and centroids, for sorting; the box after the last pads vector
    // loads.
    const boxes = try scratch.alloc(BvhBox, face_count + 1);
    bvhPrepare(Index, boxes[0..face_count], work.floats, indices, positions);
    boxes[face_count] = .{ .min = @splat(0), .max = @splat(0) };

    const axes = try scratch.alloc(u32, face_count * 3);
    const temp = work.words[face_count * 3 ..][0..face_count];

    for (0..3) |k| {
        const order = axes[k * face_count ..][0..face_count];
        const keys = work.floats[k * face_count ..][0..face_count];

        var hist: Histogram = undefined;
        computeHistogram(&hist, keys);

        // A 3-pass radix sort leaves the order in axes.
        for (temp, 0..) |*t, i| t.* = @intCast(i);

        radixPass(order, temp, keys, &hist, 0);
        radixPass(temp, order, keys, &hist, 1);
        radixPass(order, temp, keys, &hist, 2);
    }

    // Each vertex's index in the current meshlet, -1 if it is not in it.
    const used = try scratch.alloc(i16, vertex_count);
    clearUsed(Index, used, indices);

    const boundary = try scratch.alloc(u8, face_count);

    const split: BvhSplit(Index) = .{
        .boxes = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(boxes)),
        .work = work,
        .used = used,
        .indices = indices,
        .max_vertices = max_vertices,
        .min_triangles = min_triangles,
        .max_triangles = max_triangles,
        .fill_weight = fill_weight,
    };
    const orders = [3][]u32{
        axes[0..face_count],
        axes[face_count..][0..face_count],
        axes[face_count * 2 ..][0..face_count],
    };
    bvhSplit(Index, merge, &split, orders, boundary, 0);

    // The meshlets the split asks for; inputs with many vertex bound
    // clusters may ask for more than the bound.
    var meshlet_count: usize = 0;
    for (boundary) |b| {
        assert(b <= 1);
        meshlet_count += b;
    }

    const meshlet_bound = buildMeshletsBound(indices.len, max_vertices, min_triangles);

    const out: Output = .{
        .meshlets = meshlets,
        .vertices = meshlet_vertices,
        .triangles = meshlet_triangles,
        .max_vertices = max_vertices,
        .max_triangles = max_triangles,
    };

    // Pack the triangles into meshlets by the split's order and boundaries.
    var meshlet: Meshlet = .empty;
    var meshlet_offset: usize = 0;
    var meshlet_pending = meshlet_count;

    for (boundary, axes[0..face_count], 0..) |mark, index, i| {
        var cut = i > 0 and mark == 1;

        // Over the bound, boundaries are ignored until enough room is left.
        if (cut and meshlet_count > meshlet_bound and
            meshlet_offset + meshlet_pending >= meshlet_bound)
        {
            cut = false;
        }

        assert(index < face_count);

        const a = indices[index * 3 + 0];
        const b = indices[index * 3 + 1];
        const c = indices[index * 3 + 2];

        // A full meshlet is written out before the triangle starts the next.
        const full = appendMeshlet(&meshlet, a, b, c, used, out, meshlet_offset, cut);
        meshlet_offset += @intFromBool(full);
        meshlet_pending -= mark;
    }

    if (meshlet.triangle_count != 0) {
        meshlets[meshlet_offset] = meshlet;
        meshlet_offset += 1;
    }

    assert(meshlet_offset <= meshlet_bound);
    return meshlet_offset;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "the box merges agree on finite boxes" {
    const boxes = [_]f32{
        0,    1, 2, 3, 4, 5,
        -1,   2, 1, 0, 6, 2,
        -0.0, 0, 0, 0, 0, -0.0,
        0,    0, 0, 0, 0, 0,
    };
    var sse: BvhAccumulator = .empty;
    var neon: BvhAccumulator = .empty;
    var scalar: BvhAccumulator = .empty;
    for (0..3) |i| {
        const index: u32 = @intCast(i);
        const a = boxMerge(.sse, &sse, &boxes, index);
        const b = boxMerge(.neon, &neon, &boxes, index);
        const c = boxMerge(.scalar, &scalar, &boxes, index);
        try testing.expectEqual(a, b);
        try testing.expectEqual(a, c);
    }
}

test "a NaN coordinate merges as each original's path merges it" {
    const nan = std.math.nan(f32);
    const boxes = [_]f32{
        0,   0, 0, 1, 1, 1,
        nan, 0, 0, 1, 1, 1,
        0,   0, 0, 0, 0, 0,
    };
    var sse: BvhAccumulator = .empty;
    var neon: BvhAccumulator = .empty;
    var scalar: BvhAccumulator = .empty;
    for (0..2) |i| {
        _ = boxMerge(.sse, &sse, &boxes, @intCast(i));
        _ = boxMerge(.neon, &neon, &boxes, @intCast(i));
        _ = boxMerge(.scalar, &scalar, &boxes, @intCast(i));
    }
    // MINPS takes the second operand, the NaN; FMIN gives NaN; the scalar
    // comparison keeps the box's own coordinate.
    try testing.expect(std.math.isNan(sse.min[0]));
    try testing.expect(std.math.isNan(neon.min[0]));
    try testing.expectEqual(0, scalar.min[0]);
}
