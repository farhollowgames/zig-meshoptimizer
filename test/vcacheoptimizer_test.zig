//! The vertex cache optimizers against the original, on every test mesh and
//! on large ones, into a new buffer and in place.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");
const fuzzed = @import("fuzzed_meshes.zig");

const gpa = common.gpa;

const Optimizer = union(enum) {
    default,
    strip,
    fifo: u32,
    table: *const mo.VertexScoreTable,
};

/// Positive everywhere a vertex is live, as the optimizer requires.
const custom_table: mo.VertexScoreTable = .{
    .cache = .{ 0, 2, 1.5, 1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.05, 0.02, 0.01, 0 },
    .live = .{ 0, 3, 1, 0.5, 0.25, 0.125, 0.0625, 0.03125, 1e-6 },
};

const optimizers = [_]Optimizer{
    .default,
    .strip,
    .{ .fifo = 3 },
    .{ .fifo = 4 },
    .{ .fifo = 8 },
    .{ .fifo = 16 },
    .{ .fifo = 32 },
    .{ .fifo = 1000 },
    .{ .table = &.default },
    .{ .table = &.strip },
    .{ .table = &custom_table },
};

fn runOriginal(
    optimizer: Optimizer,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
) void {
    const d = destination.ptr;
    const i = indices.ptr;
    const n = indices.len;
    switch (optimizer) {
        .default => c.meshopt_optimizeVertexCache(d, i, n, vertex_count),
        .strip => c.meshopt_optimizeVertexCacheStrip(d, i, n, vertex_count),
        .fifo => |size| c.meshopt_optimizeVertexCacheFifo(d, i, n, vertex_count, size),
        .table => |table| {
            const original: c.VertexScoreTable = .{ .cache = table.cache, .live = table.live };
            c.meshopt_optimizeVertexCacheTable(d, i, n, vertex_count, &original);
        },
    }
}

fn runPort(
    optimizer: Optimizer,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
) !void {
    const d = destination;
    const n = vertex_count;
    switch (optimizer) {
        .default => try mo.optimizeVertexCache(gpa, d, indices, n),
        .strip => try mo.optimizeVertexCacheStrip(gpa, d, indices, n),
        .fifo => |size| try mo.optimizeVertexCacheFifo(gpa, d, indices, n, size),
        .table => |table| try mo.optimizeVertexCacheTable(gpa, d, indices, n, table),
    }
}

/// Each optimizer into a new buffer and in place, against the original;
/// then the port again, which must write the same.
fn checkMeshWith(list: []const Optimizer, indices: []const u32, vertex_count: usize) !void {
    const want = try gpa.alloc(u32, indices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, indices.len);
    defer gpa.free(got);
    const again = try gpa.alloc(u32, indices.len);
    defer gpa.free(again);

    for (list) |optimizer| {
        const name = @tagName(optimizer);

        // Into a new buffer, every entry set first so unwritten ones match.
        @memset(std.mem.sliceAsBytes(want), fuzzed.first_fill);
        @memset(std.mem.sliceAsBytes(got), fuzzed.first_fill);
        @memset(std.mem.sliceAsBytes(again), fuzzed.second_fill);
        runOriginal(optimizer, want, indices, vertex_count);
        try runPort(optimizer, got, indices, vertex_count);
        try common.expectSame(u32, name, want, got);
        try runPort(optimizer, again, indices, vertex_count);
        try fuzzed.expectRerunSame(name, std.mem.sliceAsBytes(got), std.mem.sliceAsBytes(again));

        // In place.
        @memcpy(want, indices);
        @memcpy(got, indices);
        @memcpy(again, indices);
        runOriginal(optimizer, want, want, vertex_count);
        try runPort(optimizer, got, got, vertex_count);
        try common.expectSame(u32, name, want, got);
        try runPort(optimizer, again, again, vertex_count);
        try common.expectSame(u32, name, got, again);
    }
}

fn checkMesh(indices: []const u32, vertex_count: usize) !void {
    return checkMeshWith(&optimizers, indices, vertex_count);
}

test "optimizeVertexCache and its variants match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkMesh(mesh.indices, mesh.vertices.len);
}

test "optimizeVertexCache and its variants match the original on large meshes" {
    var sphere = try meshes.sphere(gpa, 200, 400);
    defer sphere.deinit(gpa);
    try checkMesh(sphere.indices, sphere.vertices.len);

    var grid = try meshes.grid(gpa, 250);
    defer grid.deinit(gpa);
    try checkMesh(grid.indices, grid.vertices.len);

    var random = try meshes.random(gpa, 77, 20000, 120000);
    defer random.deinit(gpa);
    try checkMesh(random.indices, random.vertices.len);
}

test "optimizeVertexCache matches the original on degenerate inputs" {
    // No indices, no vertices, one triangle, and triangles that repeat a
    // corner or all three.
    try checkMesh(&.{}, 0);
    try checkMesh(&.{}, 10);
    try checkMesh(&.{ 0, 1, 2 }, 3);
    try checkMesh(&.{ 0, 0, 0, 1, 1, 1, 0, 0, 1, 2, 2, 2, 1, 2, 1 }, 3);

    // Vertices no index uses.
    try checkMesh(&.{ 5, 9, 7, 7, 9, 2 }, 100);

    // A fan of many triangles around one vertex, past the valence table.
    var fan: [3 * 40]u32 = undefined;
    for (0..40) |i| {
        const k: u32 = @intCast(i);
        fan[i * 3 ..][0..3].* = .{ 0, k + 1, k + 2 };
    }
    try checkMesh(&fan, 42);
}

/// One fuzzed mesh, each optimizer with a fuzzed cache size or score table.
fn checkFuzzed(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var fuzz_mesh = try fuzzed.mesh(rng);
    defer fuzz_mesh.deinit();

    // Any scores that keep every live triangle's above zero, as the
    // optimizer requires: none below zero in the cache, and above zero for
    // every vertex with triangles left.
    var table: mo.VertexScoreTable = undefined;
    for (&table.cache) |*score| score.* = if (rng.boolean()) 0 else rng.float(f32) * 3;
    for (&table.live, 0..) |*score, live| {
        score.* = if (live == 0) 0 else 1e-3 + rng.float(f32) * 3;
    }
    const cache_size: u32 = if (rng.uintLessThan(u32, 16) == 0)
        rng.intRangeAtMost(u32, 65, 100_000)
    else
        @intCast(fuzzed.size(rng, 3, 64));

    const list = [_]Optimizer{ .default, .strip, .{ .fifo = cache_size }, .{ .table = &table } };
    const mesh = fuzz_mesh.mesh;
    try checkMeshWith(&list, mesh.indices, mesh.vertices.len);
}

test "optimizeVertexCache and its variants match the original on fuzzed meshes" {
    try common.fuzz("optimizeVertexCache", 0, checkFuzzed);
}
