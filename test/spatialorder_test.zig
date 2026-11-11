//! Spatial sorting and clustering against the original: every test mesh,
//! fuzzed clouds of many sizes and extents, clouds with every point equal,
//! on a plane, repeated or at the float range's edges, positions at every
//! stride, and many cluster sizes.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;

const cluster_sizes = [_]usize{ 1, 2, 3, 5, 8, 31, 64, 100, 127, 1000, 1 << 20 };

test "spatialSortRemap and spatialClusterPoints match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        try checkPoints(common.floatsOf(mesh.vertices), common.vertex_floats, &cluster_sizes);
    }
}

test "spatialSortRemap and spatialClusterPoints match the original on large clouds" {
    for ([_]usize{ 4096, 100_000 }, 0..) |count, seed| {
        const points = try common.randomPoints(seed, count, 100);
        defer gpa.free(points);
        try checkPoints(points, 3, &cluster_sizes);
    }
}

test "spatialSortRemap and spatialClusterPoints match the original on edge cases" {
    try checkPoints(&.{}, 3, &cluster_sizes);
    try checkPoints(&.{ 1, 2, 3 }, 3, &cluster_sizes);
    try checkPoints(&common.special_points, 3, &cluster_sizes);
    try checkPoints(common.special_points[0..9], 3, &cluster_sizes);
}

test "spatialSortRemap and spatialClusterPoints match the original on fuzzed clouds" {
    try common.fuzz("spatialSortRemap and spatialClusterPoints", 0, fuzzPoints);
}

fn fuzzPoints(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const count = rng.uintAtMost(usize, if (rng.uintLessThan(u32, 8) == 0) 4 else 1500);
    const extent = std.math.pow(f32, 10, @floatFromInt(rng.intRangeAtMost(i32, -4, 20)));
    const points = try common.randomPoints(rng.int(u64), count, extent);
    defer gpa.free(points);
    switch (rng.uintLessThan(u32, 5)) {
        // A cloud as made.
        0 => {},
        // Every point on a plane.
        1 => {
            const axis = rng.uintLessThan(usize, 3);
            for (0..count) |i| points[i * 3 + axis] = 1.5;
        },
        // Every point equal.
        2 => for (0..count) |i| {
            points[i * 3 ..][0..3].* = .{ 1, 2, 3 };
        },
        // Some coordinates special values.
        3 => for (points) |*p| {
            if (rng.uintLessThan(u32, 8) != 0) continue;
            p.* = common.special_points[rng.uintLessThan(usize, common.special_points.len)];
        },
        // Many points repeated.
        else => for (1..@max(count, 1)) |i| {
            if (rng.boolean()) continue;
            const j = rng.uintLessThan(usize, i);
            points[i * 3 ..][0..3].* = points[j * 3 ..][0..3].*;
        },
    }
    const stride = if (rng.boolean()) 3 else rng.intRangeAtMost(usize, 3, 64);
    const data = try common.strided(points, stride);
    defer gpa.free(data);
    const sizes = [_]usize{
        cluster_sizes[rng.uintLessThan(usize, cluster_sizes.len)],
        rng.intRangeAtMost(usize, 1, 300),
    };
    try checkPoints(data, stride, &sizes);
}

fn checkPoints(data: []const f32, stride: usize, sizes: []const usize) !void {
    const vertex_count = data.len / stride;
    const positions: mo.VertexFloats = .init(data, stride);

    const want = try gpa.alloc(u32, vertex_count);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, vertex_count);
    defer gpa.free(got);

    c.meshopt_spatialSortRemap(want.ptr, data.ptr, vertex_count, stride * @sizeOf(f32));
    try mo.spatialSortRemap(gpa, got, positions);
    try common.expectSame(u32, "remap", want, got);
    @memset(got, 0x55555555);
    try mo.spatialSortRemap(gpa, got, positions);
    try common.expectSame(u32, "remap again", want, got);

    for (sizes) |cluster_size| {
        c.meshopt_spatialClusterPoints(
            want.ptr,
            data.ptr,
            vertex_count,
            stride * @sizeOf(f32),
            cluster_size,
        );
        try mo.spatialClusterPoints(gpa, got, positions, cluster_size);
        try common.expectSame(u32, "clusters", want, got);
        @memset(got, 0x55555555);
        try mo.spatialClusterPoints(gpa, got, positions, cluster_size);
        try common.expectSame(u32, "clusters again", want, got);
    }
}

test "spatialSortTriangles matches the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        try checkTriangles(mesh.indices, common.floatsOf(mesh.vertices), common.vertex_floats);
    }

    var sphere = try meshes.sphere(gpa, 200, 400);
    defer sphere.deinit(gpa);
    try checkTriangles(sphere.indices, common.floatsOf(sphere.vertices), common.vertex_floats);
}

test "spatialSortTriangles matches the original on edge cases" {
    try checkTriangles(&.{}, &.{}, 3);
    try checkTriangles(&.{ 0, 0, 0 }, &.{ 1, 2, 3 }, 3);
    try checkTriangles(&.{ 0, 1, 2, 2, 1, 0, 3, 4, 5 }, &common.special_points, 3);
}

test "spatialSortTriangles matches the original on fuzzed meshes" {
    try common.fuzz("spatialSortTriangles", 0, fuzzTriangles);
}

fn fuzzTriangles(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var mesh = try common.fuzzMesh(rng.int(u64), 1000, 1500);
    defer mesh.deinit(gpa);
    const packed_positions = try common.packedPositions(mesh.vertices);
    defer gpa.free(packed_positions);
    const stride = if (rng.boolean()) 3 else rng.intRangeAtMost(usize, 3, 64);
    const data = try common.strided(packed_positions, stride);
    defer gpa.free(data);
    try checkTriangles(mesh.indices, data, stride);
}

fn checkTriangles(indices: []const u32, data: []const f32, stride: usize) !void {
    const vertex_count = data.len / stride;
    const positions: mo.VertexFloats = .init(data, stride);

    const want = try gpa.alloc(u32, indices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, indices.len);
    defer gpa.free(got);
    c.meshopt_spatialSortTriangles(
        want.ptr,
        indices.ptr,
        indices.len,
        data.ptr,
        vertex_count,
        stride * @sizeOf(f32),
    );
    try mo.spatialSortTriangles(gpa, got, indices, positions);
    try common.expectSame(u32, "indices", want, got);

    // In place.
    @memcpy(got, indices);
    try mo.spatialSortTriangles(gpa, got, got, positions);
    try common.expectSame(u32, "indices in place", want, got);

    // Again, into a buffer holding other values.
    @memset(got, 0x55555555);
    try mo.spatialSortTriangles(gpa, got, indices, positions);
    try common.expectSame(u32, "indices again", want, got);
}
