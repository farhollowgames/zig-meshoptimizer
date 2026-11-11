//! The stripifier against the original: every test mesh and fuzzed ones, as
//! generated and vertex cache optimized, with degenerate joins and both
//! restart indices; a vertex used past its 8-bit valence; and fuzzed strips
//! back to lists.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;

const restart_indices = [_]u32{ 0, 0xffff, 0xffffffff };

test "stripify and unstripify match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkMesh(mesh);
}

test "stripify and unstripify match the original on a large mesh" {
    var mesh = try meshes.sphere(gpa, 200, 400);
    defer mesh.deinit(gpa);
    try checkMesh(mesh);
}

fn checkMesh(mesh: common.Mesh) !void {
    const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
    defer gpa.free(optimized);
    for ([_][]const u32{ mesh.indices, optimized }) |indices| {
        for (restart_indices) |restart_index| {
            try checkStrip(indices, mesh.vertices.len, restart_index);
        }
    }
}

test "stripify matches the original on fuzzed meshes" {
    try common.fuzz("stripify", 0, fuzzStrip);
}

fn fuzzStrip(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    // Few vertices in most cases, so triangles share many edges.
    const max_vertices: u32 = if (rng.uintLessThan(u32, 4) == 0) 2000 else 64;
    var mesh = try common.fuzzMesh(rng.int(u64), max_vertices, 800);
    defer mesh.deinit(gpa);
    const restart_index = restart_indices[rng.uintLessThan(usize, restart_indices.len)];
    try checkStrip(mesh.indices, mesh.vertices.len, restart_index);
    const optimized = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
    defer gpa.free(optimized);
    try checkStrip(optimized, mesh.vertices.len, restart_index);
}

test "stripify matches the original on edge cases" {
    for (restart_indices) |restart_index| {
        try checkStrip(&.{}, 0, restart_index);
        try checkStrip(&.{ 0, 1, 2 }, 3, restart_index);
        try checkStrip(&.{ 0, 0, 0 }, 1, restart_index);
        try checkStrip(&.{ 0, 1, 2, 2, 1, 0 }, 3, restart_index);
        try checkStrip(&.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 }, 3, restart_index);
    }
}

test "stripify matches the original past 255 uses of a vertex" {
    // A fan of 600 triangles around vertex 0, whose valence wraps, and a
    // strip of triangles after it.
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    for (0..600) |i| {
        const rim: u32 = @intCast(i + 1);
        try indices.appendSlice(gpa, &.{ 0, rim, rim + 1 });
    }
    for (0..100) |i| {
        const base: u32 = @intCast(602 + i);
        try indices.appendSlice(gpa, &.{ base, base + 1, base + 2 });
    }
    for (restart_indices) |restart_index| {
        try checkStrip(indices.items, 705, restart_index);
    }
}

fn checkStrip(indices: []const u32, vertex_count: usize, restart_index: u32) !void {
    const bound = c.meshopt_stripifyBound(indices.len);
    try common.expectSameValue(usize, "strip bound", bound, mo.stripifyBound(indices.len));

    const want = try gpa.alloc(u32, bound);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, bound);
    defer gpa.free(got);
    const want_size = c.meshopt_stripify(
        want.ptr,
        indices.ptr,
        indices.len,
        vertex_count,
        restart_index,
    );
    const got_size = try mo.stripify(gpa, got, indices, vertex_count, restart_index);
    try common.expectSameValue(usize, "strip size", want_size, got_size);
    try common.expectSame(u32, "strip", want[0..want_size], got[0..got_size]);

    // Again, into a buffer holding other values.
    @memset(got, 0x55555555);
    const again = try mo.stripify(gpa, got, indices, vertex_count, restart_index);
    try common.expectSame(u32, "strip again", want[0..want_size], got[0..again]);

    try checkUnstrip(want[0..want_size], restart_index);
}

test "unstripify matches the original on fuzzed strips" {
    try common.fuzz("unstripify", 0, fuzzUnstrip);
}

fn fuzzUnstrip(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const restart_index = restart_indices[rng.uintLessThan(usize, restart_indices.len)];
    const vertex_count = rng.uintLessThan(u32, 12) + 1;
    const strip = try gpa.alloc(u32, rng.uintLessThan(usize, 400) + 3);
    defer gpa.free(strip);
    for (strip) |*index| {
        // Few vertices, so many degenerate triangles, and some restarts.
        index.* = if (rng.uintLessThan(u32, 10) == 0)
            restart_index
        else
            rng.uintLessThan(u32, vertex_count);
    }
    try checkUnstrip(strip, restart_index);
}

test "unstripify matches the original on edge cases" {
    try checkUnstrip(&.{}, 0);
    try checkUnstrip(&.{ 0, 1, 2 }, 0);
    try checkUnstrip(&.{ 0, 1, 2, 3 }, 0xffff);
    try checkUnstrip(&.{ 0xffff, 0xffff, 0xffff }, 0xffff);
    try checkUnstrip(&.{ 0, 1, 0xffffffff, 2, 3, 4 }, 0xffffffff);
}

fn checkUnstrip(strip: []const u32, restart_index: u32) !void {
    const bound = c.meshopt_unstripifyBound(strip.len);
    try common.expectSameValue(usize, "list bound", bound, mo.unstripifyBound(strip.len));

    const want = try gpa.alloc(u32, bound);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, bound);
    defer gpa.free(got);
    const want_size = c.meshopt_unstripify(want.ptr, strip.ptr, strip.len, restart_index);
    const got_size = mo.unstripify(got, strip, restart_index);
    try common.expectSameValue(usize, "list size", want_size, got_size);
    try common.expectSame(u32, "list", want[0..want_size], got[0..got_size]);

    // Again, into a buffer holding other values.
    @memset(got, 0x55555555);
    const again = mo.unstripify(got, strip, restart_index);
    try common.expectSame(u32, "list again", want[0..want_size], got[0..again]);
}
