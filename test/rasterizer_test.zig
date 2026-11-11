//! The overdraw and coverage analyzers against the original: every test
//! mesh, fuzzed meshes in clouds from tiny to huge, flat and degenerate
//! meshes, positions at every stride, and coordinates at the float range's
//! edges.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;

test "analyzeOverdraw and analyzeCoverage match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
        defer gpa.free(optimized);
        const data = common.floatsOf(mesh.vertices);
        try checkRaster(mesh.indices, data, common.vertex_floats);
        try checkRaster(optimized, data, common.vertex_floats);
    }
}

test "analyzeOverdraw and analyzeCoverage match the original on a large mesh" {
    var mesh = try meshes.sphere(gpa, 200, 400);
    defer mesh.deinit(gpa);
    try checkRaster(mesh.indices, common.floatsOf(mesh.vertices), common.vertex_floats);
}

test "analyzeOverdraw and analyzeCoverage match the original on fuzzed meshes" {
    try common.fuzz("analyzeOverdraw and analyzeCoverage", 0, fuzzRaster);
}

fn fuzzRaster(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    // Few triangles: each one can cover most of the 256 by 256 viewport.
    var mesh = try common.fuzzMesh(rng.int(u64), 200, 40);
    defer mesh.deinit(gpa);
    const packed_positions = try common.packedPositions(mesh.vertices);
    defer gpa.free(packed_positions);
    // Clouds from tiny to huge.
    if (rng.uintLessThan(u32, 4) == 0) {
        const scale = std.math.pow(f32, 10, @floatFromInt(rng.intRangeAtMost(i32, -30, 30)));
        for (packed_positions) |*p| p.* *= scale;
    }
    const stride = if (rng.boolean()) 3 else rng.intRangeAtMost(usize, 3, 64);
    const data = try common.strided(packed_positions, stride);
    defer gpa.free(data);
    try checkRaster(mesh.indices, data, stride);
}

test "analyzeOverdraw and analyzeCoverage match the original on special values" {
    const points = &common.special_points;
    const vertex_count: u32 = points.len / 3;
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    for (0..vertex_count) |a| for (0..vertex_count) |b| {
        const third = (a + b + 1) % vertex_count;
        try indices.appendSlice(gpa, &.{ @intCast(a), @intCast(b), @intCast(third) });
    };
    try checkRaster(indices.items, points, 3);

    const max = std.math.floatMax(f32);
    // Finite points whose extent overflows to infinity.
    try checkRaster(&.{ 0, 1, 2 }, &.{ max, 0, 0, -max, 1, 0, 0, 0, 1 }, 3);
    // Finite points, denormals among them.
    const small = [_]f32{ 1e-40, -1e-40, std.math.floatMin(f32), 1e30, -1e30, 1e-30, 0.5, 0.25, 0 };
    try checkRaster(&.{ 0, 1, 2, 2, 1, 0 }, &small, 3);
    // All points equal: no extent at all.
    try checkRaster(&.{ 0, 1, 2 }, &.{ 1, 2, 3, 1, 2, 3, 1, 2, 3 }, 3);
    // No triangles.
    try checkRaster(&.{}, &small, 3);
}

fn checkRaster(indices: []const u32, data: []const f32, stride: usize) !void {
    const vertex_count = data.len / stride;
    const positions: mo.VertexFloats = .init(data, stride);

    const want = c.meshopt_analyzeOverdraw(
        indices.ptr,
        indices.len,
        data.ptr,
        vertex_count,
        stride * @sizeOf(f32),
    );
    for (0..2) |_| {
        const got = try mo.analyzeOverdraw(u32, gpa, indices, positions);
        try common.expectSameFields(want, got);
    }

    const want_coverage = c.meshopt_analyzeCoverage(
        indices.ptr,
        indices.len,
        data.ptr,
        vertex_count,
        stride * @sizeOf(f32),
    );
    for (0..2) |_| {
        const got_coverage = try mo.analyzeCoverage(u32, gpa, indices, positions);
        try common.expectSameFields(want_coverage, got_coverage);
    }
}
