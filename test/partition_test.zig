//! The cluster partitioner against the original: on the meshlets the
//! original builds from every test mesh and a large one, on random
//! clusters, with and without positions, at several partition sizes.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");
const fuzzed = @import("fuzzed_meshes.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;

const targets = [_]usize{ 1, 2, 3, 4, 8, 16, 32, 100 };

/// One partition against the original; then the port again, into an
/// output set to another byte, which must get the same.
fn checkOne(
    cluster_indices: []const u32,
    cluster_index_counts: []const u32,
    vertices: []const Vertex,
    target: usize,
    with_positions: bool,
) !void {
    const positions = common.positionsOf(vertices);
    const cluster_count = cluster_index_counts.len;

    const want = try gpa.alloc(u32, cluster_count);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, cluster_count);
    defer gpa.free(got);
    const again = try gpa.alloc(u32, cluster_count);
    defer gpa.free(again);
    @memset(std.mem.sliceAsBytes(want), fuzzed.first_fill);
    @memset(std.mem.sliceAsBytes(got), fuzzed.first_fill);
    @memset(std.mem.sliceAsBytes(again), fuzzed.second_fill);

    const want_count = c.meshopt_partitionClusters(
        want.ptr,
        cluster_indices.ptr,
        cluster_indices.len,
        cluster_index_counts.ptr,
        cluster_count,
        if (with_positions) positions.data.ptr else null,
        vertices.len,
        if (with_positions) @sizeOf(Vertex) else 0,
        target,
    );
    const port_positions: ?mo.VertexFloats = if (with_positions) positions else null;
    const got_count = try mo.partitionClusters(
        u32,
        gpa,
        got,
        cluster_indices,
        cluster_index_counts,
        port_positions,
        vertices.len,
        target,
    );
    try common.expectSameValue(usize, "partitions", want_count, got_count);
    try common.expectSame(u32, "partition of each cluster", want, got);

    const again_count = try mo.partitionClusters(
        u32,
        gpa,
        again,
        cluster_indices,
        cluster_index_counts,
        port_positions,
        vertices.len,
        target,
    );
    try common.expectSameValue(usize, "a second run", got_count, again_count);
    try fuzzed.expectRerunSame(
        "partition of each cluster",
        std.mem.sliceAsBytes(got),
        std.mem.sliceAsBytes(again),
    );
}

fn checkPartition(
    cluster_indices: []const u32,
    cluster_index_counts: []const u32,
    vertices: []const Vertex,
) !void {
    for (targets) |target| {
        for ([_]bool{ false, true }) |with_positions| {
            try checkOne(cluster_indices, cluster_index_counts, vertices, target, with_positions);
        }
    }
}

/// Partitions the meshlets the original builds from `mesh`, given as their
/// triangles' indices and as their vertex lists.
fn checkMesh(mesh: meshes.Mesh, max_vertices: usize, max_triangles: usize) !void {
    const indices = mesh.indices;
    const bound = c.meshopt_buildMeshletsBound(indices.len, max_vertices, max_triangles);
    const meshlets = try gpa.alloc(c.Meshlet, bound);
    defer gpa.free(meshlets);
    const meshlet_vertices = try gpa.alloc(u32, indices.len);
    defer gpa.free(meshlet_vertices);
    const meshlet_triangles = try gpa.alloc(u8, indices.len);
    defer gpa.free(meshlet_triangles);
    const positions = common.positionsOf(mesh.vertices);
    const count = c.meshopt_buildMeshlets(
        meshlets.ptr,
        meshlet_vertices.ptr,
        meshlet_triangles.ptr,
        indices.ptr,
        indices.len,
        positions.data.ptr,
        mesh.vertices.len,
        @sizeOf(Vertex),
        max_vertices,
        max_triangles,
        0,
    );

    const cluster_indices = try gpa.alloc(u32, indices.len);
    defer gpa.free(cluster_indices);
    const counts = try gpa.alloc(u32, count);
    defer gpa.free(counts);
    const vertex_counts = try gpa.alloc(u32, count);
    defer gpa.free(vertex_counts);

    var written: usize = 0;
    for (meshlets[0..count], counts, vertex_counts) |m, *n, *v| {
        const local = meshlet_vertices[m.vertex_offset..];
        for (meshlet_triangles[m.triangle_offset..][0 .. m.triangle_count * 3]) |t| {
            cluster_indices[written] = local[t];
            written += 1;
        }
        n.* = m.triangle_count * 3;
        v.* = m.vertex_count;
    }
    try checkPartition(cluster_indices[0..written], counts, mesh.vertices);

    // The vertex lists, one after another.
    const last = meshlets[count - 1];
    const vertex_total = last.vertex_offset + last.vertex_count;
    try checkPartition(meshlet_vertices[0..vertex_total], vertex_counts, mesh.vertices);
}

test "partitionClusters matches the original on every mesh's meshlets" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        try checkMesh(mesh, 64, 124);
        try checkMesh(mesh, 16, 8);
    }
}

test "partitionClusters matches the original on a large mesh's meshlets" {
    var sphere = try meshes.sphere(gpa, 200, 400);
    defer sphere.deinit(gpa);
    try checkMesh(sphere, 64, 124);
    try checkMesh(sphere, 128, 256);
}

test "partitionClusters matches the original on random clusters" {
    var prng: std.Random.DefaultPrng = .init(23);
    const rng = prng.random();
    var mesh = try meshes.random(gpa, 9, 400, 10);
    defer mesh.deinit(gpa);
    for (0..40) |round| {
        const cluster_count = 1 + rng.uintLessThan(usize, 120);
        const counts = try gpa.alloc(u32, cluster_count);
        defer gpa.free(counts);
        var total: usize = 0;
        for (counts) |*n| {
            n.* = 1 + rng.uintLessThan(u32, 40);
            total += n.*;
        }
        // Few vertices share a lot, many share little.
        const vertex_range: u32 = if (round % 2 == 0) 50 else 400;
        const cluster_indices = try gpa.alloc(u32, total);
        defer gpa.free(cluster_indices);
        for (cluster_indices) |*index| index.* = rng.uintLessThan(u32, vertex_range);
        try checkPartition(cluster_indices, counts, mesh.vertices);
    }

    // One cluster; clusters sharing one vertex; clusters sharing nothing.
    try checkPartition(&.{ 0, 1, 2 }, &.{3}, mesh.vertices);
    try checkPartition(&.{ 0, 1, 0, 2, 0, 3, 0, 4 }, &.{ 2, 2, 2, 2 }, mesh.vertices);
    try checkPartition(&.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &.{ 2, 2, 2, 2 }, mesh.vertices);
    try checkPartition(&.{}, &.{}, mesh.vertices);
}

/// Clusters from one seed: the meshlets the original builds from a fuzzed
/// mesh, as triangles' indices or vertex lists, or random clusters; at a
/// fuzzed target size, with or without positions.
fn checkFuzzed(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var fuzz_mesh = try fuzzed.mesh(rng);
    defer fuzz_mesh.deinit();
    const mesh = fuzz_mesh.mesh;
    const target = if (rng.uintLessThan(u32, 8) == 0)
        rng.intRangeAtMost(usize, 65, 1000)
    else
        fuzzed.size(rng, 1, 64);
    const with_positions = rng.boolean();

    var cluster_indices: std.ArrayList(u32) = .empty;
    defer cluster_indices.deinit(gpa);
    var counts: std.ArrayList(u32) = .empty;
    defer counts.deinit(gpa);

    if (rng.uintLessThan(u32, 3) == 0) {
        // Random clusters over a random share of the vertices.
        const vertex_range = fuzzed.size(rng, 1, mesh.vertices.len);
        for (0..fuzzed.size(rng, 1, 400)) |_| {
            const count = fuzzed.size(rng, 1, 80);
            try counts.append(gpa, @intCast(count));
            for (0..count) |_| {
                try cluster_indices.append(gpa, @intCast(rng.uintLessThan(usize, vertex_range)));
            }
        }
    } else {
        const indices = mesh.indices;
        const max_vertices = fuzzed.size(rng, 3, 256);
        const max_triangles = fuzzed.size(rng, 1, 512);
        const bound = c.meshopt_buildMeshletsBound(indices.len, max_vertices, max_triangles);
        const meshlets = try gpa.alloc(c.Meshlet, bound);
        defer gpa.free(meshlets);
        const meshlet_vertices = try gpa.alloc(u32, indices.len);
        defer gpa.free(meshlet_vertices);
        const meshlet_triangles = try gpa.alloc(u8, indices.len);
        defer gpa.free(meshlet_triangles);
        const count = c.meshopt_buildMeshletsScan(
            meshlets.ptr,
            meshlet_vertices.ptr,
            meshlet_triangles.ptr,
            indices.ptr,
            indices.len,
            mesh.vertices.len,
            max_vertices,
            max_triangles,
        );
        const as_triangles = rng.boolean();
        for (meshlets[0..count]) |m| {
            const local = meshlet_vertices[m.vertex_offset..];
            if (as_triangles) {
                const corners = meshlet_triangles[m.triangle_offset..][0 .. m.triangle_count * 3];
                for (corners) |corner| try cluster_indices.append(gpa, local[corner]);
                try counts.append(gpa, m.triangle_count * 3);
            } else {
                try cluster_indices.appendSlice(gpa, local[0..m.vertex_count]);
                try counts.append(gpa, m.vertex_count);
            }
        }
    }

    try checkOne(cluster_indices.items, counts.items, mesh.vertices, target, with_positions);
}

test "partitionClusters matches the original on fuzzed clusters" {
    try common.fuzz("partitionClusters", 0, checkFuzzed);
}
