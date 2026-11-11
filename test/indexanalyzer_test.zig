//! The vertex cache and vertex fetch analyzers against the original: every
//! test mesh and fuzzed ones, as generated and optimized, under many cache
//! models and vertex sizes.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;

/// Cache size, warp size and primitive group size: no warps or groups,
/// each alone, both, and the smallest of everything.
const cache_models = [_][3]u32{
    .{ 16, 0, 0 },   .{ 3, 0, 0 },     .{ 32, 0, 0 },   .{ 16, 64, 0 },
    .{ 16, 0, 128 }, .{ 14, 64, 128 }, .{ 32, 32, 96 }, .{ 3, 3, 1 },
    .{ 8, 5, 3 },    .{ 128, 3, 0 },   .{ 3, 0, 1 },    .{ 1000, 4, 7 },
};

const vertex_sizes = [_]usize{ 1, 4, 12, 16, 32, 48, 63, 64, 65, 100, 128, 255, 256 };

test "analyzeVertexCache and analyzeVertexFetch match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkMesh(mesh);
}

test "analyzeVertexCache and analyzeVertexFetch match the original on a large mesh" {
    var mesh = try meshes.sphere(gpa, 200, 400);
    defer mesh.deinit(gpa);
    try checkMesh(mesh);
}

fn checkMesh(mesh: common.Mesh) !void {
    const vertex_count = mesh.vertices.len;
    const optimized = try common.vertexCacheOptimized(mesh.indices, vertex_count);
    defer gpa.free(optimized);

    // Vertex cache and fetch optimized: the fetch order is then sequential.
    const fetched = try gpa.dupe(u32, optimized);
    defer gpa.free(fetched);
    const remap = try gpa.alloc(u32, vertex_count);
    defer gpa.free(remap);
    _ = c.meshopt_optimizeVertexFetchRemap(remap.ptr, optimized.ptr, optimized.len, vertex_count);
    c.meshopt_remapIndexBuffer(fetched.ptr, optimized.ptr, optimized.len, remap.ptr);

    for ([_][]const u32{ mesh.indices, optimized, fetched }) |indices| {
        for (cache_models) |model| try checkCache(indices, vertex_count, model);
        for (vertex_sizes) |size| try checkFetch(indices, vertex_count, size);
    }
}

test "analyzeVertexCache and analyzeVertexFetch match the original on fuzzed meshes" {
    try common.fuzz("analyzeVertexCache and analyzeVertexFetch", 0, fuzzAnalyzers);
}

fn fuzzAnalyzers(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var mesh = try common.fuzzMesh(rng.int(u64), 300, 600);
    defer mesh.deinit(gpa);
    const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
    defer gpa.free(optimized);

    // Cache sizes up to where the timestamps wrap.
    const cache_size = switch (rng.uintLessThan(u32, 8)) {
        0 => std.math.maxInt(u32) - rng.uintLessThan(u32, 3),
        1 => 1 << 31,
        else => rng.intRangeAtMost(u32, 3, 64),
    };
    const warp_size = if (rng.boolean()) 0 else rng.intRangeAtMost(u32, 3, 96);
    const primgroup_size = if (rng.boolean()) 0 else rng.intRangeAtMost(u32, 1, 200);
    const model = [3]u32{ cache_size, warp_size, primgroup_size };
    const vertex_size = rng.intRangeAtMost(usize, 1, 256);
    for ([_][]const u32{ mesh.indices, optimized }) |indices| {
        try checkCache(indices, mesh.vertices.len, model);
        try checkFetch(indices, mesh.vertices.len, vertex_size);
    }
}

/// The statistics both sides give, the port's twice.
fn checkCache(indices: []const u32, vertex_count: usize, model: [3]u32) !void {
    const want = c.meshopt_analyzeVertexCache(
        indices.ptr,
        indices.len,
        vertex_count,
        model[0],
        model[1],
        model[2],
    );
    for (0..2) |_| {
        const got = try mo.analyzeVertexCache(
            gpa,
            indices,
            vertex_count,
            model[0],
            model[1],
            model[2],
        );
        try common.expectSameFields(want, got);
    }
}

fn checkFetch(indices: []const u32, vertex_count: usize, vertex_size: usize) !void {
    const want = c.meshopt_analyzeVertexFetch(indices.ptr, indices.len, vertex_count, vertex_size);
    for (0..2) |_| {
        const got = try mo.analyzeVertexFetch(gpa, indices, vertex_count, vertex_size);
        try common.expectSameFields(want, got);
    }
}

test "the analyzers match the original on empty and unused input" {
    for ([_]usize{ 0, 1, 5 }) |vertex_count| {
        const want = c.meshopt_analyzeVertexCache(null, 0, vertex_count, 16, 0, 0);
        const got = try mo.analyzeVertexCache(gpa, &.{}, vertex_count, 16, 0, 0);
        try common.expectSameFields(want, got);
        const want_fetch = c.meshopt_analyzeVertexFetch(null, 0, vertex_count, 16);
        const got_fetch = try mo.analyzeVertexFetch(gpa, &.{}, vertex_count, 16);
        try common.expectSameFields(want_fetch, got_fetch);
    }
}
