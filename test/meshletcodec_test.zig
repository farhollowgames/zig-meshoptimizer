//! The meshlet codec against the original: the encoder byte for byte on
//! the original clusterizer's meshlets of every test mesh, at every
//! optimization level, and on random meshlets of every size; the decoder,
//! for each vertex and triangle size and raw, on those streams and on
//! truncated, corrupted and random buffers, with the same return codes and
//! the same output, padding included. The SIMD path is checked against the
//! original's SIMD build and the scalar path against its scalar build.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const common = @import("common.zig");

const gpa = common.gpa;
const meshletcodec = mo.meshletcodec;

// The original's meshletcodec.cpp built without SIMD.
extern fn scalar_meshopt_decodeMeshlet(
    vertices: ?*anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    triangles: ?*anyopaque,
    triangle_count: usize,
    triangle_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;
extern fn scalar_meshopt_decodeMeshletRaw(
    vertices: ?[*]u32,
    vertex_count: usize,
    triangles: ?[*]u32,
    triangle_count: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;

test "encodeMeshlet and decodeMeshlet match the original on clustered meshes" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    const limits = [_][2]usize{ .{ 64, 96 }, .{ 128, 256 }, .{ 256, 256 }, .{ 3, 1 }, .{ 32, 32 } };
    for (set.meshes[0..8], 0..) |mesh, m| {
        for (limits, 0..) |limit, l| {
            const levels: []const c_int = if (l == 0) &.{ 0, 1, 2, 3 } else &.{3};
            for (levels) |level| {
                try checkClusters(mesh, limit[0], limit[1], level, m < 4 and l == 0 and level == 3);
            }
        }
    }
}

test "encodeMeshlet and decodeMeshlet match the original on random meshlets" {
    for (0..400) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rng = prng.random();

        const sizes = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 63, 64, 65, 255, 256 };
        const vertex_count = if (seed < sizes.len * 2)
            sizes[seed % sizes.len]
        else
            rng.uintAtMost(usize, 256);
        const triangle_count = if (seed < sizes.len * 2)
            sizes[(seed / 2) % sizes.len]
        else
            rng.uintAtMost(usize, 256);

        var vertices: [256]u32 = undefined;
        randomVertices(rng, vertices[0..vertex_count], seed % 6);
        var triangles: [256 * 3]u8 = undefined;
        randomTriangles(rng, triangles[0 .. triangle_count * 3], vertex_count, seed % 5);

        try checkMeshlet(vertices[0..vertex_count], triangles[0 .. triangle_count * 3], seed < 60);
    }
}

test "encodeMeshletBound matches the original" {
    for (0..258) |vertices_max| for (0..258) |triangles_max| {
        try common.expectSameValue(
            usize,
            "encodeMeshletBound",
            c.meshopt_encodeMeshletBound(vertices_max, triangles_max),
            mo.encodeMeshletBound(vertices_max, triangles_max),
        );
    };
}

test "decodeMeshlet matches the original on random buffers" {
    var prng: std.Random.DefaultPrng = .init(0x3e5d1e7);
    const rng = prng.random();
    var buffer: [1600]u8 = undefined;
    for (0..6000) |i| {
        const vertex_count = if (i % 4 == 0) 0 else rng.uintAtMost(usize, 256);
        const triangle_count = rng.uintAtMost(usize, 256);
        const len = rng.uintLessThan(usize, buffer.len);
        rng.bytes(buffer[0..len]);
        // Sparse bytes too, which decode further before running out.
        if (rng.boolean()) {
            for (buffer[0..len]) |*b| b.* &= rng.int(u8) & rng.int(u8);
        }
        try checkDecode(buffer[0..len], vertex_count, triangle_count);
    }
}

// --------------------------------------------------------
// Helpers
// --------------------------------------------------------

/// Builds meshlets of `mesh` with the original's clusterizer and optimizes
/// them at `level` with the original, then checks each.
fn checkClusters(
    mesh: common.Mesh,
    vertices_max: usize,
    triangles_max: usize,
    level: c_int,
    malformed: bool,
) !void {
    const index_count = mesh.indices.len;
    const meshlets_max = c.meshopt_buildMeshletsBound(index_count, vertices_max, triangles_max);
    const meshlets = try gpa.alloc(c.Meshlet, meshlets_max);
    defer gpa.free(meshlets);
    const meshlet_vertices = try gpa.alloc(u32, index_count);
    defer gpa.free(meshlet_vertices);
    const meshlet_triangles = try gpa.alloc(u8, index_count);
    defer gpa.free(meshlet_triangles);

    const positions = common.positionsOf(mesh.vertices);
    const count = c.meshopt_buildMeshlets(
        meshlets.ptr,
        meshlet_vertices.ptr,
        meshlet_triangles.ptr,
        mesh.indices.ptr,
        index_count,
        positions.data.ptr,
        mesh.vertices.len,
        @sizeOf(common.Vertex),
        vertices_max,
        triangles_max,
        0.25,
    );

    for (meshlets[0..count], 0..) |m, i| {
        const vertices = meshlet_vertices[m.vertex_offset..][0..m.vertex_count];
        const triangles = meshlet_triangles[m.triangle_offset..][0 .. m.triangle_count * 3];
        c.meshopt_optimizeMeshletLevel(
            vertices.ptr,
            vertices.len,
            triangles.ptr,
            m.triangle_count,
            level,
        );
        // Every other meshlet without its vertex references.
        try checkMeshlet(if (i % 2 == 0) vertices else &.{}, triangles, malformed and i < 8);
    }
}

/// Vertex references of one of several kinds: increasing by small steps,
/// as optimized meshlets have, in a small range, near the top of 32 bits,
/// with differences of 1 to 4 bytes mixed, or entirely random.
fn randomVertices(rng: std.Random, vertices: []u32, kind: usize) void {
    var base = rng.int(u32);
    for (vertices) |*v| {
        v.* = switch (kind) {
            0 => blk: {
                base +%= rng.uintAtMost(u32, 3);
                break :blk base;
            },
            1 => rng.uintLessThan(u32, 300),
            2 => std.math.maxInt(u32) - rng.uintLessThan(u32, 70000),
            3 => base +% (rng.int(u32) >> @intCast(rng.uintLessThan(u32, 32))),
            4 => blk: {
                // Runs of differences needing 3 bytes, which fall back to 4
                // bytes when a group has four.
                base +%= 0x10000 + rng.uintLessThan(u32, 0x7f0000);
                break :blk if (rng.uintLessThan(u32, 6) == 0) rng.int(u32) else base;
            },
            else => rng.int(u32),
        };
    }
}

/// Triangles of one of several kinds: strips and fans that reuse edges,
/// optimized-looking ones that walk the vertices in order, random corners
/// within the vertex count, any byte, and the same triangle again.
fn randomTriangles(rng: std.Random, triangles: []u8, vertex_count: usize, kind: usize) void {
    const top: u32 = @intCast(@max(vertex_count, 3));
    const triangle_count = triangles.len / 3;
    for (0..triangle_count) |t| {
        const tri = triangles[t * 3 ..][0..3];
        const k: u32 = @intCast(t);
        const corners: [3]u32 = switch (kind) {
            0 => if (k & 1 == 0) .{ k, k + 1, k + 2 } else .{ k + 1, k, k + 2 },
            1 => .{ 0, k + 1, k + 2 },
            2 => blk: {
                // Mostly the next vertex or one just used, rotated at
                // random.
                const n = k + 2;
                const v = [3]u32{
                    n -| rng.uintLessThan(u32, 4),
                    n -| rng.uintLessThan(u32, 3),
                    n + rng.uintLessThan(u32, 2),
                };
                const r = rng.uintLessThan(usize, 3);
                break :blk .{ v[r], v[(r + 1) % 3], v[(r + 2) % 3] };
            },
            3 => .{ rng.int(u8), rng.int(u8), rng.int(u8) },
            else => .{
                rng.uintLessThan(u32, top),
                rng.uintLessThan(u32, top),
                rng.uintLessThan(u32, top),
            },
        };
        for (tri, corners) |*out, corner| out.* = @truncate(corner % (if (kind == 3) 256 else top));
    }
}

/// Encodes the meshlet with both, into a buffer of the bound's size and
/// ones around the encoded size, then decodes the stream with both, and
/// if `malformed`, its truncations and corruptions too.
fn checkMeshlet(vertices: []const u32, triangles: []const u8, malformed: bool) !void {
    const triangle_count = triangles.len / 3;
    const bound = c.meshopt_encodeMeshletBound(vertices.len, triangle_count);
    try common.expectSameValue(
        usize,
        "encodeMeshletBound",
        bound,
        mo.encodeMeshletBound(vertices.len, triangle_count),
    );

    var want: [4096]u8 = undefined;
    var got: [4096]u8 = undefined;
    const want_size = c.meshopt_encodeMeshlet(
        &want,
        bound,
        vertices.ptr,
        vertices.len,
        triangles.ptr,
        triangle_count,
    );
    const got_size = mo.encodeMeshlet(got[0..bound], vertices, triangles) catch 0;
    try common.expectSameValue(usize, "encodeMeshlet size", want_size, got_size);
    try common.expectSame(u8, "encodeMeshlet", want[0..want_size], got[0..got_size]);

    // The original's own scalar build encodes the same.
    var scalar: [4096]u8 = undefined;
    const scalar_size = scalar_meshopt_encodeMeshlet(
        &scalar,
        bound,
        vertices.ptr,
        vertices.len,
        triangles.ptr,
        triangle_count,
    );
    try common.expectSame(u8, "encodeMeshlet (scalar)", scalar[0..scalar_size], got[0..got_size]);

    for ([_]usize{ 0, 1, 15, want_size / 2, want_size -| 1, want_size }) |size| {
        const want_fit = c.meshopt_encodeMeshlet(
            &want,
            size,
            vertices.ptr,
            vertices.len,
            triangles.ptr,
            triangle_count,
        );
        const got_fit = mo.encodeMeshlet(got[0..size], vertices, triangles) catch 0;
        try common.expectSameValue(usize, "encodeMeshlet size (small buffer)", want_fit, got_fit);
    }

    const stream = want[0..want_size];
    try checkDecode(stream, vertices.len, triangle_count);

    // The decoded meshlet is the input, its triangles possibly rotated.
    var rv: [256]u32 = undefined;
    var rt: [256 * 3]u8 = undefined;
    try mo.decodeMeshlet(u32, u8, &rv, vertices.len, &rt, triangle_count, stream);
    try common.expectSame(u32, "decodeMeshlet round trip", vertices, rv[0..vertices.len]);
    for (0..triangle_count) |t| {
        const in = canonical(triangles[t * 3 ..][0..3].*);
        const out = canonical(rt[t * 3 ..][0..3].*);
        try common.expectSameValue([3]u8, "decodeMeshlet round trip triangle", in, out);
    }

    if (malformed) {
        for (0..stream.len) |len| {
            try checkDecode(stream[0..len], vertices.len, triangle_count);
            try checkDecode(stream[stream.len - len ..], vertices.len, triangle_count);
        }
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..stream.len], stream);
        for (0..stream.len) |i| {
            for ([_]u8{ 0x01, 0x10, 0x80, 0xff }) |flip| {
                copy[i] ^= flip;
                try checkDecode(copy[0..stream.len], vertices.len, triangle_count);
                copy[i] ^= flip;
            }
        }
        // Other counts than the encoded ones.
        const vc = vertices.len;
        const tc = triangle_count;
        for ([_]usize{ 1, 2, 3, 4 }) |delta| {
            if (vc + delta <= 256) try checkDecode(stream, vc + delta, tc);
            if (tc + delta <= 256) try checkDecode(stream, vc, tc + delta);
            if (vc >= delta) try checkDecode(stream, vc - delta, tc);
            if (tc >= delta) try checkDecode(stream, vc, tc - delta);
        }
    }
}

extern fn scalar_meshopt_encodeMeshlet(
    buffer: ?[*]u8,
    buffer_size: usize,
    vertices: ?[*]const u32,
    vertex_count: usize,
    triangles: ?[*]const u8,
    triangle_count: usize,
) usize;

/// The rotation of the triangle that sorts first.
fn canonical(triangle: [3]u8) [3]u8 {
    return common.canonicalTriangle(u8, triangle);
}

const Decoder = enum { simd, scalar };

/// Decodes `buffer` with both, every vertex and triangle size and raw, on
/// the SIMD path against the original's SIMD build and on the scalar path
/// against its scalar build, into outputs filled alike, and compares the
/// results and all of the outputs, padding included.
fn checkDecode(buffer: []const u8, vertex_count: usize, triangle_count: usize) !void {
    const decoders = if (meshletcodec.has_simd)
        [_]Decoder{ .simd, .scalar }
    else
        [_]Decoder{.scalar};
    inline for (decoders) |decoder| {
        inline for (.{ u16, u32 }) |V| inline for (.{ u8, u32 }) |T| {
            try checkDecodeAs(decoder, V, T, buffer, vertex_count, triangle_count);
        };
        try checkDecodeRaw(decoder, buffer, vertex_count, triangle_count);
    }
}

fn checkDecodeAs(
    comptime decoder: Decoder,
    comptime V: type,
    comptime T: type,
    buffer: []const u8,
    vertex_count: usize,
    triangle_count: usize,
) !void {
    const triangle_size: usize = if (T == u8) 3 else 4;
    const vertex_len = std.mem.alignForward(usize, vertex_count * @sizeOf(V), 4) / @sizeOf(V);
    const triangle_bytes = std.mem.alignForward(usize, triangle_count * triangle_size, 4);
    const triangle_len = triangle_bytes / @sizeOf(T);

    var want_vertices: [256]V = @splat(@truncate(0xa5a5_a5a5));
    var got_vertices: [256]V = @splat(@truncate(0xa5a5_a5a5));
    var want_triangles: [256 * 4]T = @splat(@truncate(0x5a5a_5a5a));
    var got_triangles: [256 * 4]T = @splat(@truncate(0x5a5a_5a5a));

    const original = switch (decoder) {
        .simd => &c.meshopt_decodeMeshlet,
        .scalar => &scalar_meshopt_decodeMeshlet,
    };
    const port = switch (decoder) {
        .simd => mo.decodeMeshlet,
        .scalar => meshletcodec.decodeMeshletScalar,
    };

    const want_rc = original(
        &want_vertices,
        vertex_count,
        @sizeOf(V),
        &want_triangles,
        triangle_count,
        triangle_size,
        buffer.ptr,
        buffer.len,
    );
    const got_rc = resultCode(port(
        V,
        T,
        got_vertices[0..vertex_len],
        vertex_count,
        got_triangles[0..triangle_len],
        triangle_count,
        buffer,
    ));
    const what = @tagName(decoder) ++ " " ++ @typeName(V) ++ " " ++ @typeName(T);
    try common.expectSameValue(c_int, "decodeMeshlet result (" ++ what ++ ")", want_rc, got_rc);
    try common.expectSame(
        V,
        "decodeMeshlet vertices (" ++ what ++ ")",
        &want_vertices,
        &got_vertices,
    );
    try common.expectSame(
        T,
        "decodeMeshlet triangles (" ++ what ++ ")",
        &want_triangles,
        &got_triangles,
    );
}

fn checkDecodeRaw(
    comptime decoder: Decoder,
    buffer: []const u8,
    vertex_count: usize,
    triangle_count: usize,
) !void {
    const vertex_len = std.mem.alignForward(usize, vertex_count, 4);
    const triangle_len = std.mem.alignForward(usize, triangle_count, 4);

    var want_vertices: [256]u32 = @splat(0xa5a5_a5a5);
    var got_vertices: [256]u32 = @splat(0xa5a5_a5a5);
    var want_triangles: [256]u32 = @splat(0x5a5a_5a5a);
    var got_triangles: [256]u32 = @splat(0x5a5a_5a5a);

    const original = switch (decoder) {
        .simd => &c.meshopt_decodeMeshletRaw,
        .scalar => &scalar_meshopt_decodeMeshletRaw,
    };
    const port = switch (decoder) {
        .simd => mo.decodeMeshletRaw,
        .scalar => meshletcodec.decodeMeshletRawScalar,
    };

    const want_rc = original(
        &want_vertices,
        vertex_count,
        &want_triangles,
        triangle_count,
        buffer.ptr,
        buffer.len,
    );
    const got_rc = resultCode(port(
        got_vertices[0..vertex_len],
        vertex_count,
        got_triangles[0..triangle_len],
        triangle_count,
        buffer,
    ));
    const what = @tagName(decoder);
    try common.expectSameValue(c_int, "decodeMeshletRaw result (" ++ what ++ ")", want_rc, got_rc);
    try common.expectSame(
        u32,
        "decodeMeshletRaw vertices (" ++ what ++ ")",
        &want_vertices,
        &got_vertices,
    );
    try common.expectSame(
        u32,
        "decodeMeshletRaw triangles (" ++ what ++ ")",
        &want_triangles,
        &got_triangles,
    );
}

/// The original's return code for a decoder's result.
fn resultCode(result: mo.MeshletDecodeError!void) c_int {
    result catch |err| return switch (err) {
        error.Truncated => -2,
        error.SizeMismatch => -3,
    };
    return 0;
}
