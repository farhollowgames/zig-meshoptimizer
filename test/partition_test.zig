//! The cluster partitioner against the original: on the meshlets the
//! original builds from every test mesh and a large one, on random
//! clusters, with and without positions, at several partition sizes.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;

const targets = [_]usize{ 1, 2, 3, 4, 8, 16, 32, 100 };

fn checkPartition(
    cluster_indices: []const u32,
    cluster_index_counts: []const u32,
    vertices: []const Vertex,
) !void {
    const positions = common.positionsOf(vertices);
    const cluster_count = cluster_index_counts.len;

    const want = try gpa.alloc(u32, cluster_count);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, cluster_count);
    defer gpa.free(got);

    for (targets) |target| {
        for ([_]bool{ false, true }) |with_positions| {
            @memset(want, 0xcdcdcdcd);
            @memset(got, 0xcdcdcdcd);
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
            const got_count = try mo.partitionClusters(
                gpa,
                got,
                cluster_indices,
                cluster_index_counts,
                if (with_positions) positions else null,
                vertices.len,
                target,
            );
            try common.expectSameValue(usize, "partitions", want_count, got_count);
            try common.expectSame(u32, "partition of each cluster", want, got);
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
