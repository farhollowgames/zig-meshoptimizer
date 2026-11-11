//! The overdraw optimizer against the original: every test mesh and fuzzed
//! ones, as generated and vertex cache optimized, at several thresholds,
//! into a new buffer and in place, with positions at every stride.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;

const thresholds = [_]f32{ 1.0, 1.05, 1.5, 3.0, 0.5, 0, 1e9 };

test "optimizeOverdraw matches the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkMesh(mesh);
}

test "optimizeOverdraw matches the original on a large mesh" {
    var mesh = try meshes.sphere(gpa, 200, 400);
    defer mesh.deinit(gpa);
    try checkMesh(mesh);
}

fn checkMesh(mesh: common.Mesh) !void {
    const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
    defer gpa.free(optimized);

    // The positions alone, 3 floats each.
    const positions = try common.packedPositions(mesh.vertices);
    defer gpa.free(positions);

    const data = common.floatsOf(mesh.vertices);
    for ([_][]const u32{ optimized, mesh.indices }) |indices| {
        for (thresholds) |threshold| {
            try checkOverdraw(indices, data, common.vertex_floats, threshold);
        }
        try checkOverdraw(indices, positions, 3, 1.05);
    }
}

test "optimizeOverdraw matches the original on fuzzed meshes" {
    try common.fuzz("optimizeOverdraw", 0, fuzzOverdraw);
}

fn fuzzOverdraw(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var mesh = try common.fuzzMesh(rng.int(u64), 400, 500);
    defer mesh.deinit(gpa);

    // The positions alone, at a random stride up to the largest.
    const packed_positions = try common.packedPositions(mesh.vertices);
    defer gpa.free(packed_positions);
    const stride = if (rng.boolean()) 3 else rng.intRangeAtMost(usize, 3, 64);
    const data = try common.strided(packed_positions, stride);
    defer gpa.free(data);

    const threshold = if (rng.boolean())
        thresholds[rng.uintLessThan(usize, thresholds.len)]
    else
        rng.float(f32) * 3;
    const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
    defer gpa.free(optimized);
    try checkOverdraw(optimized, data, stride, threshold);
    try checkOverdraw(mesh.indices, data, stride, threshold);
}

test "optimizeOverdraw matches the original on edge cases" {
    try checkOverdraw(&.{}, &.{}, 3, 1.05);
    try checkOverdraw(&.{ 0, 0, 0 }, &.{ 1, 2, 3 }, 3, 1.05);
    try checkOverdraw(&.{ 0, 1, 2 }, &common.special_points, 3, 1.05);
    try checkOverdraw(&.{ 0, 1, 2, 2, 1, 0 }, common.special_points[0..9], 3, 1.05);
}

fn checkOverdraw(indices: []const u32, data: []const f32, stride: usize, threshold: f32) !void {
    const vertex_count = data.len / stride;
    const positions: mo.VertexFloats = .init(data, stride);

    const want = try gpa.alloc(u32, indices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, indices.len);
    defer gpa.free(got);
    c.meshopt_optimizeOverdraw(
        want.ptr,
        indices.ptr,
        indices.len,
        data.ptr,
        vertex_count,
        stride * @sizeOf(f32),
        threshold,
    );
    try mo.optimizeOverdraw(u32, gpa, got, indices, positions, threshold);
    try common.expectSame(u32, "indices", want, got);

    // In place.
    @memcpy(got, indices);
    try mo.optimizeOverdraw(u32, gpa, got, got, positions, threshold);
    try common.expectSame(u32, "indices in place", want, got);

    // Again, into a buffer holding other values.
    @memset(got, 0x55555555);
    try mo.optimizeOverdraw(u32, gpa, got, indices, positions, threshold);
    try common.expectSame(u32, "indices again", want, got);
}
