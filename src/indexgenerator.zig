//! Index buffer generation: merging equal vertices into a remap table,
//! applying it, filtering redundant triangles, shadow and position-only
//! index buffers, and index buffers for adjacency, tessellation and
//! visibility-buffer topologies.
//!
//! Translated from meshoptimizer's indexgenerator.cpp, which builds on
//! Teschner et al., "Optimized Spatial Hashing for Collision Detection of
//! Deformable Objects" (2003); McDonald and Kilgard, "Crack-Free
//! Point-Normal Triangles using Adjacent Edge Normals" (2010); and Hable,
//! "Variable Rate Shading with Visibility Buffer Rendering" (2024).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const VertexFloats = @import("strided.zig").VertexFloats;

/// A vertex attribute stream: each vertex's `size` bytes begin `stride`
/// bytes after the last one's, from the start of `data` (`size <= stride`).
pub const Stream = struct {
    data: []const u8,
    size: usize,
    stride: usize,

    fn vertex(self: Stream, index: u32) []const u8 {
        return self.data[index * self.stride ..][0..self.size];
    }
};

const none = std.math.maxInt(u32);

fn hashUpdate(seed: u32, key: []const u8) u32 {
    // MurmurHash2
    const m: u32 = 0x5bd1e995;
    const r = 24;

    var h = seed;
    var rest = key;

    while (rest.len >= 4) {
        var k: u32 = @bitCast(rest[0..4].*);

        k *%= m;
        k ^= k >> r;
        k *%= m;

        h *%= m;
        h ^= k;

        rest = rest[4..];
    }

    if (rest.len > 0) {
        h ^= @as(
            u32,
            rest[0],
        ) | @as(u32, rest[rest.len / 2]) << 8 | @as(u32, rest[rest.len - 1]) << 16;
        h *%= m;
        h ^= h >> r;
    }

    return h;
}

const VertexHasher = struct {
    stream: Stream,

    fn hash(self: VertexHasher, index: u32) u32 {
        return hashUpdate(0, self.stream.vertex(index));
    }

    fn equal(self: VertexHasher, lhs: u32, rhs: u32) bool {
        return std.mem.eql(u8, self.stream.vertex(lhs), self.stream.vertex(rhs));
    }
};

const VertexStreamHasher = struct {
    streams: []const Stream,

    fn hash(self: VertexStreamHasher, index: u32) u32 {
        var h: u32 = 0;
        for (self.streams) |stream| h = hashUpdate(h, stream.vertex(index));
        return h;
    }

    fn equal(self: VertexStreamHasher, lhs: u32, rhs: u32) bool {
        for (self.streams) |stream| {
            if (!std.mem.eql(u8, stream.vertex(lhs), stream.vertex(rhs))) return false;
        }
        return true;
    }
};

/// Hashes the position, as a spatial hash, and compares it as floats (so
/// -0 matches 0 and NaN matches nothing), then asks `equal`, if any.
fn VertexCustomHasher(comptime Context: type, comptime equalFn: ?fn (Context, u32, u32) bool) type {
    return struct {
        positions: VertexFloats,
        context: Context,

        const Self = @This();

        fn hash(self: Self, index: u32) u32 {
            const key: [3]u32 = @bitCast(self.positions.vec3(index));
            var x, var y, var z = key;

            // Negative zero hashes as zero.
            x = if (x == 0x80000000) 0 else x;
            y = if (y == 0x80000000) 0 else y;
            z = if (z == 0x80000000) 0 else z;

            // Scramble the bits so integer coordinates have entropy in the
            // lower bits.
            x ^= x >> 17;
            y ^= y >> 17;
            z ^= z >> 17;

            return (x *% 73856093) ^ (y *% 19349663) ^ (z *% 83492791);
        }

        fn equal(self: Self, lhs: u32, rhs: u32) bool {
            const lp = self.positions.vec3(lhs);
            const rp = self.positions.vec3(rhs);

            if (lp[0] != rp[0] or lp[1] != rp[1] or lp[2] != rp[2]) return false;

            const f = equalFn orelse return true;
            return f(self.context, lhs, rhs);
        }
    };
}

const TriangleKey = struct {
    a: u32,
    b: u32,
    c: u32,
};

const TriangleKeyHasher = struct {
    fn hash(_: TriangleKeyHasher, k: TriangleKey) u32 {
        return (k.a *% 73856093) ^ (k.b *% 19349663) ^ (k.c *% 83492791);
    }

    fn equal(_: TriangleKeyHasher, lhs: TriangleKey, rhs: TriangleKey) bool {
        return std.meta.eql(lhs, rhs);
    }
};

/// Edges as `from << 32 | to`, equal when their ends share positions.
const EdgeHasher = struct {
    remap: []const u32,

    fn hash(self: EdgeHasher, edge: u64) u32 {
        var h1 = self.remap[@intCast(edge >> 32)];
        var h2 = self.remap[@as(u32, @truncate(edge))];

        const m: u32 = 0x5bd1e995;

        // MurmurHash64B finalizer
        h1 ^= h2 >> 18;
        h1 *%= m;
        h2 ^= h1 >> 22;
        h2 *%= m;
        h1 ^= h2 >> 17;
        h1 *%= m;
        h2 ^= h1 >> 19;
        h2 *%= m;

        return h2;
    }

    fn equal(self: EdgeHasher, lhs: u64, rhs: u64) bool {
        const lhs_from = self.remap[@intCast(lhs >> 32)];
        const rhs_from = self.remap[@intCast(rhs >> 32)];
        const lhs_to = self.remap[@as(u32, @truncate(lhs))];
        const rhs_to = self.remap[@as(u32, @truncate(rhs))];
        return lhs_from == rhs_from and lhs_to == rhs_to;
    }
};

/// The power of two hash table size for `count` keys.
pub fn hashBuckets(count: usize) usize {
    var buckets: usize = 1;
    while (buckets < count + count / 4) buckets *= 2;
    return buckets;
}

/// The position in `table` that holds `key` or, if no entry matches it,
/// the empty entry where it goes. `hasher` has `hash(T) u32` and
/// `equal(T, T) bool`; the table is never full. Inlined, as C++ inlines the
/// original's template, so each caller's probe loop holds its hasher.
pub inline fn hashLookup(
    comptime T: type,
    table: []const T,
    hasher: anytype,
    key: T,
    empty: T,
) usize {
    assert(std.math.isPowerOfTwo(table.len));

    const hashmod = table.len - 1;
    var bucket = hasher.hash(key) & hashmod;

    for (0..table.len) |probe| {
        const item = table[bucket];

        if (std.meta.eql(item, empty)) return bucket;
        if (hasher.equal(item, key)) return bucket;

        // A collision: probe quadratically.
        bucket = (bucket + probe + 1) & hashmod;
    }

    unreachable;
}

fn buildPositionRemap(scratch: *Scratch, remap: []u32, positions: VertexFloats) !void {
    const vertex_hasher: VertexHasher = .{ .stream = .{
        .data = std.mem.sliceAsBytes(positions.data),
        .size = 3 * @sizeOf(f32),
        .stride = positions.stride * @sizeOf(f32),
    } };

    const vertex_table = try scratch.alloc(u32, hashBuckets(remap.len));
    @memset(vertex_table, none);

    for (remap, 0..) |*r, i| {
        const index: u32 = @intCast(i);
        const entry = hashLookup(u32, vertex_table, vertex_hasher, index, none);

        if (vertex_table[entry] == none) vertex_table[entry] = index;

        r.* = vertex_table[entry];
    }

    scratch.free(vertex_table);
}

fn generateRemap(
    scratch: *Scratch,
    remap: []u32,
    indices: ?[]const u32,
    index_count: usize,
    hasher: anytype,
) !usize {
    @memset(remap, none);

    const table = try scratch.alloc(u32, hashBuckets(remap.len));
    @memset(table, none);

    var next_vertex: u32 = 0;

    for (0..index_count) |i| {
        const index: u32 = if (indices) |list| list[i] else @intCast(i);
        assert(index < remap.len);

        if (remap[index] != none) continue;

        const entry = hashLookup(u32, table, hasher, index, none);

        if (table[entry] == none) {
            table[entry] = index;
            remap[index] = next_vertex;
            next_vertex += 1;
        } else {
            assert(remap[table[entry]] != none);
            remap[index] = remap[table[entry]];
        }
    }

    return next_vertex;
}

fn remapVertices(
    comptime block_size: usize,
    destination: []u8,
    vertices: []const u8,
    vertex_size: usize,
    remap: []const u32,
) void {
    const size = if (block_size == 0) vertex_size else block_size;
    assert(size == vertex_size);

    for (remap, 0..) |r, i| {
        if (r != none) {
            assert(r < remap.len);
            @memcpy(destination[r * size ..][0..size], vertices[i * size ..][0..size]);
        }
    }
}

fn generateShadowBuffer(
    scratch: *Scratch,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
    hasher: anytype,
) !void {
    const remap = try scratch.alloc(u32, vertex_count);
    @memset(remap, none);

    const table = try scratch.alloc(u32, hashBuckets(vertex_count));
    @memset(table, none);

    for (indices, destination[0..indices.len]) |index, *d| {
        assert(index < vertex_count);

        if (remap[index] == none) {
            const entry = hashLookup(u32, table, hasher, index, none);

            if (table[entry] == none) table[entry] = index;

            remap[index] = table[entry];
        }

        d.* = remap[index];
    }
}

fn filterTriangles(
    scratch: *Scratch,
    destination: []u32,
    indices: []const u32,
    remap: []const u32,
) !usize {
    const empty: TriangleKey = .{ .a = none, .b = none, .c = none };

    const face_count = indices.len / 3;
    const table = try scratch.alloc(TriangleKey, hashBuckets(face_count));
    @memset(table, empty);

    var write: usize = 0;

    for (0..face_count) |i| {
        const a = indices[i * 3 + 0];
        const b = indices[i * 3 + 1];
        const c = indices[i * 3 + 2];
        assert(a < remap.len and b < remap.len and c < remap.len);

        var ra = remap[a];
        var rb = remap[b];
        var rc = remap[c];

        // A degenerate triangle.
        if (ra == rb or ra == rc or rb == rc) continue;

        // Canonical rotation, which keeps the winding.
        if (rb < ra and rb < rc) {
            // abc -> bca
            const t = ra;
            ra = rb;
            rb = rc;
            rc = t;
        } else if (rc < ra and rc < rb) {
            // abc -> cab
            const t = rc;
            rc = rb;
            rb = ra;
            ra = t;
        }

        const key: TriangleKey = .{ .a = ra, .b = rb, .c = rc };
        const entry = hashLookup(TriangleKey, table, TriangleKeyHasher{}, key, empty);

        // A duplicate triangle.
        if (table[entry].a != none) continue;

        table[entry] = key;

        destination[write..][0..3].* = .{ a, b, c };
        write += 3;
    }

    return write;
}

fn checkStreams(streams: []const Stream) void {
    assert(streams.len > 0 and streams.len <= 16);
    for (streams) |stream| {
        assert(stream.size > 0 and stream.size <= 256);
        assert(stream.size <= stream.stride);
    }
}

/// Fills `destination[0..vertex_count]` with a remap table from the
/// `vertex_size`-byte vertices in `vertices` and returns the number of
/// unique vertices. Vertices that are equal in all their bytes, padding
/// included (so zero it), map to the same new place, and the new places run
/// without gaps in order of first use by `indices`, or of the vertices
/// themselves if `indices` is null. Use the table with `remapVertexBuffer`
/// and `remapIndexBuffer`.
pub fn generateVertexRemap(
    gpa: Allocator,
    destination: []u32,
    indices: ?[]const u32,
    vertices: []const u8,
    vertex_size: usize,
) Allocator.Error!usize {
    assert(vertex_size > 0 and vertex_size <= 256);
    assert(vertices.len % vertex_size == 0);
    const vertex_count = vertices.len / vertex_size;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexHasher = .{ .stream = .{
        .data = vertices,
        .size = vertex_size,
        .stride = vertex_size,
    } };

    const index_count = if (indices) |list| list.len else vertex_count;
    return generateRemap(&scratch, destination[0..vertex_count], indices, index_count, hasher);
}

/// `generateVertexRemap` over several vertex streams, each remapped with its
/// own `remapVertexBuffer` call after. Vertices are equal when all the bytes
/// of every stream are. Takes 1 to 16 streams.
pub fn generateVertexRemapMulti(
    gpa: Allocator,
    destination: []u32,
    indices: ?[]const u32,
    vertex_count: usize,
    streams: []const Stream,
) Allocator.Error!usize {
    checkStreams(streams);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexStreamHasher = .{ .streams = streams };

    const index_count = if (indices) |list| list.len else vertex_count;
    return generateRemap(&scratch, destination[0..vertex_count], indices, index_count, hasher);
}

/// `generateVertexRemap` with an equality of your own: vertices are equal
/// when their positions compare equal as floats (so -0 equals 0, and NaN
/// equals nothing) and then `equal(context, lhs, rhs)` holds, if `equal` is
/// given.
pub fn generateVertexRemapCustom(
    gpa: Allocator,
    destination: []u32,
    indices: ?[]const u32,
    positions: VertexFloats,
    context: anytype,
    comptime equal: ?fn (@TypeOf(context), u32, u32) bool,
) Allocator.Error!usize {
    assert(positions.stride >= 3 and positions.stride <= 64);
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexCustomHasher(@TypeOf(context), equal) = .{
        .positions = positions,
        .context = context,
    };

    const index_count = if (indices) |list| list.len else vertex_count;
    return generateRemap(&scratch, destination[0..vertex_count], indices, index_count, hasher);
}

/// Writes the vertex buffer a remap table from `generateVertexRemap` gives:
/// each of `vertices`, `vertex_size` bytes each, moves to its new place in
/// `destination`, which holds the unique vertex count `generateVertexRemap`
/// returned. `destination` may be `vertices` itself.
pub fn remapVertexBuffer(
    gpa: Allocator,
    destination: []u8,
    vertices: []const u8,
    vertex_size: usize,
    remap: []const u32,
) Allocator.Error!void {
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

    // Common sizes get their own loop, so each copy is a few moves.
    const table = remap[0..vertex_count];
    switch (vertex_size) {
        inline 4, 8, 12, 16 => |size| remapVertices(size, destination, source, vertex_size, table),
        else => remapVertices(0, destination, source, vertex_size, table),
    }
}

/// Writes the index buffer a remap table from `generateVertexRemap` gives:
/// `destination[i]` is `remap[indices[i]]`, or `remap[i]` for every vertex
/// when `indices` is null. `destination` may be `indices` itself.
pub fn remapIndexBuffer(destination: []u32, indices: ?[]const u32, remap: []const u32) void {
    const list = indices orelse {
        // Every vertex in order: a copy, which the loop below would make
        // one index at a time.
        for (remap) |index| assert(index != none);
        @memcpy(destination[0..remap.len], remap);
        return;
    };
    for (destination[0..list.len], list) |*d, index| {
        assert(remap[index] != none);

        d.* = remap[index];
    }
}

/// Copies `indices` to `destination` without redundant triangles and
/// returns the number of indices left. A triangle is redundant when two of
/// its corners' vertices are equal (degenerate), or when an earlier
/// triangle has the same vertices in the same winding (duplicate); vertices
/// are equal when the bytes of `vertices` are, which usually holds just the
/// position. Duplicates of opposite winding stay, for double-sided
/// rendering. `destination` may be `indices` itself.
pub fn filterIndexBuffer(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
    vertices: Stream,
) Allocator.Error!usize {
    assert(indices.len % 3 == 0);
    checkStreams(&.{vertices});

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexHasher = .{ .stream = vertices };

    const remap = try scratch.alloc(u32, vertex_count);
    _ = try generateRemap(&scratch, remap, indices, indices.len, hasher);

    return filterTriangles(&scratch, destination, indices, remap);
}

/// `filterIndexBuffer` over several vertex streams, which should hold every
/// attribute that moves a vertex (skinning influences, say). Takes 1 to 16
/// streams.
pub fn filterIndexBufferMulti(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
    streams: []const Stream,
) Allocator.Error!usize {
    assert(indices.len % 3 == 0);
    checkStreams(streams);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexStreamHasher = .{ .streams = streams };

    const remap = try scratch.alloc(u32, vertex_count);
    _ = try generateRemap(&scratch, remap, indices, indices.len, hasher);

    return filterTriangles(&scratch, destination, indices, remap);
}

/// Writes an index buffer for passes that read only some attributes (a
/// depth pre-pass, shadow maps): each index moves to the first vertex whose
/// bytes in `vertices` are equal to its own, padding included. Keep the
/// original buffer for the other passes.
pub fn generateShadowIndexBuffer(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
    vertices: Stream,
) Allocator.Error!void {
    assert(indices.len % 3 == 0);
    checkStreams(&.{vertices});

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexHasher = .{ .stream = vertices };

    try generateShadowBuffer(&scratch, destination, indices, vertex_count, hasher);
}

/// `generateShadowIndexBuffer` over several vertex streams. Takes 1 to 16
/// streams.
pub fn generateShadowIndexBufferMulti(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    vertex_count: usize,
    streams: []const Stream,
) Allocator.Error!void {
    assert(indices.len % 3 == 0);
    checkStreams(streams);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexStreamHasher = .{ .streams = streams };

    try generateShadowBuffer(&scratch, destination, indices, vertex_count, hasher);
}

/// Fills `destination[0..vertex_count]` with a table that maps each vertex
/// to the first vertex with the same position (compared as floats), for
/// position-only rendering and for algorithms that need positional
/// connectivity, such as hierarchical simplification.
pub fn generatePositionRemap(
    gpa: Allocator,
    destination: []u32,
    positions: VertexFloats,
) Allocator.Error!void {
    assert(positions.stride >= 3 and positions.stride <= 64);
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();
    const hasher: VertexCustomHasher(void, null) = .{ .positions = positions, .context = {} };

    const table = try scratch.alloc(u32, hashBuckets(vertex_count));
    @memset(table, none);

    for (destination[0..vertex_count], 0..) |*d, i| {
        const index: u32 = @intCast(i);
        const entry = hashLookup(u32, table, hasher, index, none);

        if (table[entry] == none) table[entry] = index;

        d.* = table[entry];
    }
}

/// Writes an index buffer for geometry shaders with triangle adjacency
/// (VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST_WITH_ADJACENCY), 2 indices per input
/// index: each triangle becomes 6, its corners at 0, 2 and 4, and at 1, 3
/// and 5 the vertices across its edges 02, 24 and 40. Edges match by
/// position, compared bit for bit, and a border edge's opposite vertex is
/// the edge's own start.
pub fn generateAdjacencyIndexBuffer(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    positions: VertexFloats,
) Allocator.Error!void {
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const next = [4]u32{ 1, 2, 0, 1 };

    // Which canonical vertex each vertex's position maps to.
    const remap = try scratch.alloc(u32, vertex_count);
    try buildPositionRemap(&scratch, remap, positions);

    // Every triangle edge, found again by any edge between the same
    // positions.
    const edge_hasher: EdgeHasher = .{ .remap = remap };

    const edge_table_size = hashBuckets(indices.len);
    const edge_table = try scratch.alloc(u64, edge_table_size);
    const edge_vertex_table = try scratch.alloc(u32, edge_table_size);

    @memset(edge_table, std.math.maxInt(u64));
    @memset(edge_vertex_table, none);

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        for (0..3) |e| {
            const from = indices[i + e];
            const to = indices[i + next[e]];
            const opposite = indices[i + next[e + 1]];
            assert(from < vertex_count and to < vertex_count and opposite < vertex_count);

            const edge = @as(u64, from) << 32 | to;
            const entry = hashLookup(u64, edge_table, edge_hasher, edge, std.math.maxInt(u64));

            if (edge_table[entry] == std.math.maxInt(u64)) {
                edge_table[entry] = edge;

                // The vertex opposite the edge.
                edge_vertex_table[entry] = opposite;
            }
        }
    }

    i = 0;
    while (i < indices.len) : (i += 3) {
        var patch: [6]u32 = undefined;

        for (0..3) |e| {
            const from = indices[i + e];
            const to = indices[i + next[e]];
            assert(from < vertex_count and to < vertex_count);

            // The edge the other way, as the neighbouring triangle has it.
            const edge = @as(u64, to) << 32 | from;
            const oppe = hashLookup(u64, edge_table, edge_hasher, edge, std.math.maxInt(u64));

            patch[e * 2 + 0] = from;
            patch[e * 2 + 1] = if (edge_table[oppe] == std.math.maxInt(u64))
                from
            else
                edge_vertex_table[oppe];
        }

        destination[i * 2 ..][0..6].* = patch;
    }
}

/// Writes an index buffer for PN-AEN tessellation with crack-free
/// displacement (McDonald, "Tessellation on Any Budget", GDC 2011), 4
/// indices per input index: each triangle becomes 12, its corners at 0, 1
/// and 2; the edges across its edges 0, 1 and 2 at 3 and 4, 5 and 6, 7 and 8;
/// and each corner's dominant vertex, the first with its position, at 9, 10
/// and 11. A border edge stands in for its own opposite.
pub fn generateTessellationIndexBuffer(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    positions: VertexFloats,
) Allocator.Error!void {
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const next = [3]u32{ 1, 2, 0 };

    // Which canonical vertex each vertex's position maps to.
    const remap = try scratch.alloc(u32, vertex_count);
    try buildPositionRemap(&scratch, remap, positions);

    // Every triangle edge, found again by any edge between the same
    // positions.
    const edge_hasher: EdgeHasher = .{ .remap = remap };

    const edge_table = try scratch.alloc(u64, hashBuckets(indices.len));
    @memset(edge_table, std.math.maxInt(u64));

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        for (0..3) |e| {
            const from = indices[i + e];
            const to = indices[i + next[e]];
            assert(from < vertex_count and to < vertex_count);

            const edge = @as(u64, from) << 32 | to;
            const entry = hashLookup(u64, edge_table, edge_hasher, edge, std.math.maxInt(u64));

            if (edge_table[entry] == std.math.maxInt(u64)) edge_table[entry] = edge;
        }
    }

    i = 0;
    while (i < indices.len) : (i += 3) {
        var patch: [12]u32 = undefined;

        for (0..3) |e| {
            const from = indices[i + e];
            const to = indices[i + next[e]];
            assert(from < vertex_count and to < vertex_count);

            // The edge the other way, as the neighbouring triangle has it.
            const edge = @as(u64, to) << 32 | from;
            var oppe = edge_table[
                hashLookup(u64, edge_table, edge_hasher, edge, std.math.maxInt(u64))
            ];

            // A border edge stands in for its missing opposite.
            oppe = if (oppe == std.math.maxInt(u64)) edge else oppe;

            patch[e] = from;

            patch[3 + e * 2 + 0] = @truncate(oppe);
            patch[3 + e * 2 + 1] = @intCast(oppe >> 32);

            patch[9 + e] = remap[from];
        }

        destination[i * 4 ..][0..12].* = patch;
    }
}

/// Writes an index buffer for visibility-buffer rendering, in which each
/// triangle's provoking (first) vertex index equals its primitive id, so a
/// flat-interpolated attribute can pass the id to the fragment shader where
/// reading it there is slow. `reorder`, which must have room for
/// `vertex_count + indices.len / 3` entries, receives the original vertex of
/// each new vertex, for the vertex shader to load; the return value is how
/// many it holds. Rotate each triangle (abc to bca) where the provoking
/// vertex is the last (OpenGL). Optimize `indices` for the vertex cache
/// first.
pub fn generateProvokingIndexBuffer(
    gpa: Allocator,
    destination: []u32,
    reorder: []u32,
    indices: []const u32,
    vertex_count: usize,
) Allocator.Error!usize {
    assert(indices.len % 3 == 0);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const remap = try scratch.alloc(u32, vertex_count);
    @memset(remap, none);

    // Vertex valences, to prefer the least used corner. They are 8-bit
    // counters for speed: an outlier's count wraps, which only weakens the
    // heuristic.
    const valence = try scratch.alloc(u8, vertex_count);
    @memset(valence, 0);

    for (indices) |index| {
        assert(index < vertex_count);
        valence[index] +%= 1;
    }

    var reorder_offset: u32 = 0;

    // Provoking vertices first; the other corners wait for the next pass.
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        var a = indices[i + 0];
        var b = indices[i + 1];
        var c = indices[i + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        // Rotate the triangle so its provoking vertex is one not seen yet,
        // the least used if several are new, so a later triangle is less
        // likely to find all three seen.
        const va: u32 = if (remap[a] == none) valence[a] else none;
        const vb: u32 = if (remap[b] == none) valence[b] else none;
        const vc: u32 = if (remap[c] == none) valence[c] else none;

        if (vb != none and vb <= va and vb <= vc) {
            // abc -> bca
            const t = a;
            a = b;
            b = c;
            c = t;
        } else if (vc != none and vc <= va and vc <= vb) {
            // abc -> cab
            const t = c;
            c = b;
            b = a;
            a = t;
        }

        const newidx = reorder_offset;

        // Now a is new, or all three are seen. Recording a's new place lets
        // later references to it share the copy.
        if (remap[a] == none) remap[a] = newidx;

        // The provoking vertex is always a fresh copy, for a unique index;
        // if all three were seen, which one is copied makes no difference to
        // later triangles.
        reorder[reorder_offset] = a;
        reorder_offset += 1;

        // The first index is final; the second pass fixes the other two.
        destination[i + 0] = newidx;
        destination[i + 1] = b;
        destination[i + 2] = c;

        valence[a] -%= 1;
        valence[b] -%= 1;
        valence[c] -%= 1;
    }

    // Remap or copy the other corners, stepping over the provoking ones.
    var step: usize = 1;
    i = 1;
    while (i < indices.len) : ({
        i += step;
        step ^= 3;
    }) {
        const index = destination[i];

        if (remap[index] == none) {
            // Not seen as a provoking vertex: copy it, keeping the
            // reference to the original vertex.
            remap[index] = reorder_offset;
            reorder[reorder_offset] = index;
            reorder_offset += 1;
        }

        destination[i] = remap[index];
    }

    return reorder_offset;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "equal vertices share a place" {
    const vertices = [_]u32{ 7, 3, 7, 9, 3 };
    var remap: [5]u32 = undefined;
    const unique = try generateVertexRemap(
        testing.allocator,
        &remap,
        null,
        std.mem.sliceAsBytes(&vertices),
        @sizeOf(u32),
    );
    try testing.expectEqual(3, unique);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 2, 1 }, &remap);
}

test "remapping in place" {
    var vertices = [_]u32{ 7, 3, 7, 9, 3 };
    const remap = [_]u32{ 0, 1, 0, 2, 1 };
    const bytes = std.mem.sliceAsBytes(&vertices);
    try remapVertexBuffer(testing.allocator, bytes, bytes, @sizeOf(u32), &remap);
    try testing.expectEqualSlices(u32, &.{ 7, 3, 9 }, vertices[0..3]);
}
