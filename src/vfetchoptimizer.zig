//! Vertex fetch optimization: numbering vertices in the order the index
//! buffer first uses them, so the GPU reads vertex memory in sequence.
//!
//! Translated from meshoptimizer's vfetchoptimizer.cpp.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const checkIndex = @import("index.zig").check;

const none = std.math.maxInt(u32);

/// Fills `destination[0..vertex_count]` with a remap table that numbers the
/// vertices in the order `indices` first uses them, and returns how many
/// are used; unused vertices map to `maxInt(u32)`. Apply the table with
/// `remapVertexBuffer` to each vertex stream and with `remapIndexBuffer`.
pub fn optimizeVertexFetchRemap(
    comptime Index: type,
    destination: []u32,
    indices: []const Index,
    vertex_count: usize,
) usize {
    comptime checkIndex(Index);
    const remap = destination[0..vertex_count];
    @memset(remap, none);

    var next_vertex: u32 = 0;

    for (indices) |index| {
        assert(index < vertex_count);

        if (remap[index] == none) {
            remap[index] = next_vertex;
            next_vertex += 1;
        }
    }

    return next_vertex;
}

/// Copies the `vertex_size`-byte vertices of `vertices` to `destination` in
/// the order `indices` first uses them, rewrites `indices` to match, and
/// returns how many vertices are used, which is the vertex count unless some
/// are unused; `destination` needs room for that many. `destination` may be
/// `vertices` itself. For several vertex streams, use
/// `optimizeVertexFetchRemap` and remap each stream.
pub fn optimizeVertexFetch(
    comptime Index: type,
    gpa: Allocator,
    destination: []u8,
    indices: []Index,
    vertices: []const u8,
    vertex_size: usize,
) Allocator.Error!usize {
    comptime checkIndex(Index);
    assert(vertex_size > 0 and vertex_size <= 256);
    assert(vertices.len % vertex_size == 0);
    const vertex_count = vertices.len / vertex_size;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    var source = vertices;
    if (destination.ptr == vertices.ptr) {
        const copy = try scratch.alloc(u8, vertices.len);
        @memcpy(copy, vertices);
        source = copy;
    }

    const vertex_remap = try scratch.alloc(u32, vertex_count);
    @memset(vertex_remap, none);

    // Common sizes get their own loop, so each copy is a few moves.
    return switch (vertex_size) {
        inline 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 64 => |size| fetchVertices(
            Index,
            size,
            destination,
            indices,
            source,
            vertex_size,
            vertex_remap,
        ),
        else => fetchVertices(Index, 0, destination, indices, source, vertex_size, vertex_remap),
    };
}

/// Copies each vertex to `destination` at its first use and rewrites
/// `indices` to the new places; `block_size` is `vertex_size`, or 0 when
/// it is known only at run time.
fn fetchVertices(
    comptime Index: type,
    comptime block_size: usize,
    destination: []u8,
    indices: []Index,
    source: []const u8,
    vertex_size: usize,
    vertex_remap: []u32,
) usize {
    const size = if (block_size == 0) vertex_size else block_size;
    assert(size == vertex_size);

    var next_vertex: u32 = 0;

    for (indices) |*index| {
        assert(index.* < vertex_remap.len);

        const remap = &vertex_remap[index.*];

        if (remap.* == none) {
            const vertex = source[@as(usize, index.*) * size ..][0..size];
            @memcpy(destination[@as(usize, next_vertex) * size ..][0..size], vertex);

            remap.* = next_vertex;
            next_vertex += 1;
        }

        index.* = @intCast(remap.*);
    }

    return next_vertex;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "vertices move to the order of first use" {
    const vertices = [_]u32{ 10, 11, 12, 13 };
    var indices = [_]u32{ 2, 0, 2, 3 };
    var destination: [4]u32 = undefined;
    const unique = try optimizeVertexFetch(
        u32,
        testing.allocator,
        std.mem.asBytes(&destination),
        &indices,
        std.mem.asBytes(&vertices),
        @sizeOf(u32),
    );
    try testing.expectEqual(3, unique);
    try testing.expectEqualSlices(u32, &.{ 12, 10, 13 }, destination[0..3]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 2 }, &indices);
}
