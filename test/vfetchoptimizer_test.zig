//! The vertex fetch optimizer against the original: every test mesh, into
//! a new buffer and in place, and fuzzed vertices of every size.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;

test "optimizeVertexFetchRemap matches the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
        defer gpa.free(optimized);
        for ([_][]const u32{ mesh.indices, optimized }) |indices| {
            try checkVertexFetchRemap(indices, mesh.vertices.len);
        }
    }
}

fn checkVertexFetchRemap(indices: []const u32, vertex_count: usize) !void {
    const want = try gpa.alloc(u32, vertex_count);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, vertex_count);
    defer gpa.free(got);
    const want_unique = c.meshopt_optimizeVertexFetchRemap(
        want.ptr,
        indices.ptr,
        indices.len,
        vertex_count,
    );
    const got_unique = mo.optimizeVertexFetchRemap(got, indices, vertex_count);
    try common.expectSameValue(usize, "used vertices", want_unique, got_unique);
    try common.expectSame(u32, "remap", want, got);

    // Again, into a buffer holding other values.
    @memset(got, 0x55555555);
    _ = mo.optimizeVertexFetchRemap(got, indices, vertex_count);
    try common.expectSame(u32, "remap again", want, got);
}

test "optimizeVertexFetch matches the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
        defer gpa.free(optimized);
        for ([_][]const u32{ mesh.indices, optimized }) |indices| {
            try checkVertexFetch(std.mem.sliceAsBytes(mesh.vertices), @sizeOf(Vertex), indices);
        }
    }
}

test "optimizeVertexFetch matches the original on fuzzed vertices of every size" {
    try common.fuzz("optimizeVertexFetch", 0, fuzzVertexFetch);
}

fn fuzzVertexFetch(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const size = if (rng.uintLessThan(u32, 8) == 0) 256 else rng.intRangeAtMost(usize, 1, 256);
    const vertex_count = rng.uintAtMost(usize, 300);
    const vertices = try gpa.alloc(u8, vertex_count * size);
    defer gpa.free(vertices);
    rng.bytes(vertices);
    // Any number of indices, not only whole triangles, none past the vertices.
    const index_count = if (vertex_count == 0) 0 else rng.uintAtMost(usize, 900);
    const indices = try gpa.alloc(u32, index_count);
    defer gpa.free(indices);
    // Some cases use only a few of the vertices.
    const few = @min(vertex_count, rng.uintAtMost(usize, 8) + 1);
    const used = if (rng.boolean()) vertex_count else few;
    for (indices) |*index| index.* = rng.uintLessThan(u32, @intCast(@max(used, 1)));
    try checkVertexFetch(vertices, size, indices);
    try checkVertexFetchRemap(indices, vertex_count);
}

test "optimizeVertexFetch matches the original on edge cases" {
    try checkVertexFetch(&.{}, 16, &.{});
    try checkVertexFetchRemap(&.{}, 0);
    try checkVertexFetchRemap(&.{}, 5);
    const one = [_]u8{ 1, 2, 3, 4 };
    try checkVertexFetch(&one, 4, &.{ 0, 0, 0 });
    try checkVertexFetch(&one, 1, &.{ 3, 1, 2, 0 });
    try checkVertexFetchRemap(&.{ 0, 0, 0 }, 1);
}

/// Both sides into new buffers, then in place; the vertices, the rewritten
/// indices and the counts must match.
fn checkVertexFetch(vertices: []const u8, vertex_size: usize, indices: []const u32) !void {
    const vertex_count = vertices.len / vertex_size;
    const want_indices = try gpa.dupe(u32, indices);
    defer gpa.free(want_indices);
    const got_indices = try gpa.dupe(u32, indices);
    defer gpa.free(got_indices);

    // Into new buffers; past the used vertices, they keep what they held.
    const want = try gpa.alloc(u8, vertices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, vertices.len);
    defer gpa.free(got);
    @memset(want, 0xcd);
    @memset(got, 0xcd);
    const want_unique = c.meshopt_optimizeVertexFetch(
        want.ptr,
        want_indices.ptr,
        indices.len,
        vertices.ptr,
        vertex_count,
        vertex_size,
    );
    const got_unique = try mo.optimizeVertexFetch(gpa, got, got_indices, vertices, vertex_size);
    try common.expectSameValue(usize, "used vertices", want_unique, got_unique);
    try common.expectSame(u8, "vertices", want, got);
    try common.expectSame(u32, "indices", want_indices, got_indices);

    // In place.
    @memcpy(want, vertices);
    @memcpy(got, vertices);
    @memcpy(want_indices, indices);
    @memcpy(got_indices, indices);
    const want_in_place = c.meshopt_optimizeVertexFetch(
        want.ptr,
        want_indices.ptr,
        indices.len,
        want.ptr,
        vertex_count,
        vertex_size,
    );
    const got_in_place = try mo.optimizeVertexFetch(gpa, got, got_indices, got, vertex_size);
    try common.expectSameValue(usize, "used vertices in place", want_in_place, got_in_place);
    try common.expectSame(u8, "vertices in place", want, got);
    try common.expectSame(u32, "indices in place", want_indices, got_indices);

    // Again, into a buffer holding other values: the used vertices match.
    @memcpy(got_indices, indices);
    @memset(got, 0x55);
    const again = try mo.optimizeVertexFetch(gpa, got, got_indices, vertices, vertex_size);
    const used = again * vertex_size;
    try common.expectSame(u8, "vertices again", want[0..used], got[0..used]);
    try common.expectSame(u32, "indices again", want_indices, got_indices);
}
