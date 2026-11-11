//! Opacity micromaps for ray tracing: a subdivision level for each
//! triangle, the opacity state of every micro triangle sampled from an
//! alpha texture, and compaction of the results, with whole-triangle
//! states turned into special indices.
//!
//! Translated from meshoptimizer's opacitymap.cpp. Micromaps follow the
//! "bird" order of the Vulkan and DirectX specifications, which subdivides
//! each triangle recursively: micro triangles 0 and 2 keep the source
//! triangle's winding, and 1 (upside down) and 3 (upright) flip it, as
//! level 2 of the specification's diagram shows.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const VertexFloats = @import("strided.zig").VertexFloats;
const indexgenerator = @import("indexgenerator.zig");
const hashBuckets = indexgenerator.hashBuckets;
const hashLookup = indexgenerator.hashLookup;
const truncate = @import("convert.zig").truncate;
const log2f = @import("log2f.zig").log2f;

/// The states of a micro triangle; the value is the count.
pub const OpacityMapFormat = enum(u8) {
    /// One bit: transparent (0) or opaque (1).
    two_state = 2,
    /// Two bits: transparent (0), opaque (1), unknown and mostly
    /// transparent (2), or unknown and mostly opaque (3).
    four_state = 4,
};

/// An alpha channel of 8-bit unorm values, `width` by `height` (1 to 16384
/// each): texel (x, y) is `data[y * pitch + x * stride]`, so `data` starts at
/// the first pixel's alpha. `stride` is 1 to 4 (4 for RGBA), and `pitch`
/// at least `stride * width`.
pub const AlphaTexture = struct {
    data: []const u8,
    stride: usize,
    pitch: usize,
    width: u32,
    height: u32,
};

const none = std.math.maxInt(u32);

/// The bytes of a micromap: 1 or 2 bits for each micro triangle, rounded
/// up to whole bytes.
inline fn levelSize(level: u32, states: u32) usize {
    return ((@as(usize, 1) << @intCast(level * 2)) * (states >> 1) + 7) >> 3;
}

const Texture = struct {
    data: []const u8,
    stride: usize,
    pitch: usize,
    width: u32,
    height: u32,
    /// width * 256, height * 256.
    widthf: f32,
    heightf: f32,
};

/// Alpha at (u, v), wrapped, filtered bilinearly in fixed point. Inlined:
/// the recursion and the edge loops call it for nearly every sample.
inline fn sampleTexture(texture: *const Texture, u_in: f32, v_in: f32) f32 {
    // Coordinates wrap; floor is expensive, so it runs only outside [0, 1]
    // (and a little).
    const u = if (@abs(u_in - 0.5) > 0.5) u_in - @floor(u_in) else u_in;
    const v = if (@abs(v_in - 0.5) > 0.5) v_in - @floor(v_in) else v_in;

    // [0, 1] to 16.8 fixed point, rounded to the nearest subpixel, with
    // texel centers on the integer grid.
    var uf = truncate(u * texture.widthf - 127.5);
    var vf = truncate(v * texture.heightf - 127.5);

    // Clamped, so nothing extrapolates past the left or top edge, which
    // does not wrap.
    uf = if (uf < 0) 0 else uf;
    vf = if (vf < 0) 0 else vf;

    // Texel coordinates, and subpixel offsets.
    const x = uf >> 8;
    const y = vf >> 8;
    const rx = uf & 255;
    const ry = vf & 255;

    // A safeguard: this does not happen, but if it did, reads stay in
    // bounds.
    if (@as(u32, @bitCast(x)) >= texture.width or @as(u32, @bitCast(y)) >= texture.height) return 0;

    // Offsets clamp at the edges instead of wrapping, which is simpler and
    // faster.
    const xu: usize = @intCast(x);
    const yu: usize = @intCast(y);
    const offset = yu * texture.pitch + xu * texture.stride;
    const offsetx = if (x + 1 < @as(i32, @intCast(texture.width))) texture.stride else 0;
    const offsety = if (y + 1 < @as(i32, @intCast(texture.height))) texture.pitch else 0;

    const a00: i32 = texture.data[offset];
    const a10: i32 = texture.data[offset + offsetx];
    const a01: i32 = texture.data[offset + offsety];
    const a11: i32 = texture.data[offset + offsetx + offsety];

    // Bilinear interpolation in integers: the result is 8.16 fixed point.
    const ax0 = a00 * 256 + (a10 - a00) * rx;
    const ax1 = a01 * 256 + (a11 - a01) * rx;
    const axy = ax0 * 256 + (ax1 - ax0) * ry;

    const unit: f32 = 1.0 / (255.0 * 65536.0);
    return @as(f32, @floatFromInt(axy)) * unit;
}

/// MurmurHash2 over the whole 4-byte words of `key`.
fn hashUpdate4u(seed: u32, key: []const u8) u32 {
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

    return h;
}

/// A rasterization request: the corners in subpixels and the level.
const TriangleOmm = struct {
    uvs: [6]i32,
    level: i32,
};

const TriangleOmmHasher = struct {
    data: []const TriangleOmm,

    pub fn hash(self: TriangleOmmHasher, index: u32) u32 {
        const tri = &self.data[index];

        return hashUpdate4u(@bitCast(tri.level), std.mem.asBytes(&tri.uvs));
    }

    pub fn equal(self: TriangleOmmHasher, lhs: u32, rhs: u32) bool {
        const lt = &self.data[lhs];
        const rt = &self.data[rhs];

        return lt.level == rt.level and std.mem.eql(i32, &lt.uvs, &rt.uvs);
    }
};

const OmmHasher = struct {
    data: []const u8,
    offsets: []const u32,
    levels: []const u8,
    states: u32,

    pub fn hash(self: OmmHasher, index: u32) u32 {
        const size = levelSize(self.levels[index], self.states);
        const key = self.data[self.offsets[index]..][0..size];

        var h: u32 = self.levels[index];

        // MurmurHash2 for large keys, a simple fold for small ones; sizes
        // are powers of two.
        if (size < 4) {
            h ^= key[0] | @as(u32, key[size - 1]) << 8;
        } else {
            h = hashUpdate4u(h, key);
        }

        // MurmurHash2's finalizer.
        h ^= h >> 13;
        h *%= 0x5bd1e995;
        h ^= h >> 15;
        return h;
    }

    pub fn equal(self: OmmHasher, lhs: u32, rhs: u32) bool {
        const size = levelSize(self.levels[lhs], self.states);

        return self.levels[lhs] == self.levels[rhs] and std.mem.eql(
            u8,
            self.data[self.offsets[lhs]..][0..size],
            self.data[self.offsets[rhs]..][0..size],
        );
    }
};

inline fn quantizeSubpixel(v: f32, size: u32) i32 {
    const scale: f32 = @floatFromInt(@as(i32, @intCast(size)) * 4);
    return truncate(v * scale + @as(f32, if (v >= 0) 0.5 else -0.5));
}

/// `edgeres` samples evenly between two points, not counting them: the
/// mask of opaque samples, and their count shifted left by 16.
fn rasterizeEdge(
    start_u: f32,
    start_v: f32,
    end_u: f32,
    end_v: f32,
    edgeres: i32,
    texture: *const Texture,
) i32 {
    const edgestep = 1 / @as(f32, @floatFromInt(edgeres + 1));

    const ud = (end_u - start_u) * edgestep;
    const vd = (end_v - start_v) * edgestep;
    var u = start_u;
    var v = start_v;

    var mask: i32 = 0;
    var count: i32 = 0;

    var i: u5 = 0;
    while (i < edgeres) : (i += 1) {
        u += ud;
        v += vd;

        const a = sampleTexture(texture, u, v);
        mask |= @as(i32, @intFromBool(a >= 0.5)) << i;
        count += @intFromBool(a >= 0.5);
    }

    return mask | (count << 16);
}

/// Writes the state of micro triangle `index` from the alpha at its corners
/// and center, and the edge samples if `edgeres` is not 0.
fn rasterizeOpacity0(
    comptime states: u32,
    result: []u8,
    index: usize,
    a0: f32,
    a1: f32,
    a2: f32,
    ac: f32,
    e0: i32,
    e1: i32,
    e2: i32,
    edgeres: i32,
) void {
    // A basic coverage estimate from the center and corners, trained to
    // minimize error.
    var coverage = (a0 + a1 + a2) * 0.12 + ac * 0.64;

    if (edgeres != 0) {
        const edgescale = 1 / @as(f32, @floatFromInt(edgeres));

        // Edge samples give a better estimate; also trained.
        const edges: f32 = @floatFromInt((e0 >> 16) + (e1 >> 16) + (e2 >> 16));
        coverage = ac * 0.22 + edges * edgescale * 0.23 + (a0 + a1 + a2) * 0.03;
    }

    if (states == 2) {
        result[index / 8] |= @as(u8, @intFromBool(coverage >= 0.5)) << @intCast(index % 8);
        return;
    }

    const transp = a0 < 0.5 and a1 < 0.5 and a2 < 0.5 and ac < 0.5;
    const opaque_ = a0 > 0.5 and a1 > 0.5 and a2 > 0.5 and ac > 0.5;

    // The state is known when the corners and center agree against the
    // wider bounds; unknown states follow the 2-state estimate, for
    // consistency with a forced 2-state map.
    const unknown: u8 = 2 + @as(u8, @intFromBool(coverage >= 0.5));
    var state: u8 = if (transp or opaque_) @intFromBool(opaque_) else unknown;

    if (edgeres != 0 and (transp or opaque_)) {
        // The edge samples must agree too, or the state is unknown.
        const exp: i32 = if (opaque_) (@as(i32, 1) << @intCast(edgeres)) - 1 else 0;
        const eok = (e0 & 0xffff) == exp and (e1 & 0xffff) == exp and (e2 & 0xffff) == exp;

        state = if (eok) state else unknown;
    }

    result[index / 4] |= state << @intCast((index % 4) * 2);
}

/// Level 1 with edge samples: the four micro triangles, reusing the edge
/// samples they share.
fn rasterizeOpacity1(
    comptime states: u32,
    result: []u8,
    index: usize,
    edgeres: i32,
    c0: *const [3]f32,
    c1: *const [3]f32,
    c2: *const [3]f32,
    texture: *const Texture,
) void {
    // Each edge's midpoint, sampled.
    var c01 = [3]f32{ (c0[0] + c1[0]) / 2, (c0[1] + c1[1]) / 2, 0 };
    var c12 = [3]f32{ (c1[0] + c2[0]) / 2, (c1[1] + c2[1]) / 2, 0 };
    var c20 = [3]f32{ (c2[0] + c0[0]) / 2, (c2[1] + c0[1]) / 2, 0 };

    c01[2] = sampleTexture(texture, c01[0], c01[1]);
    c12[2] = sampleTexture(texture, c12[0], c12[1]);
    c20[2] = sampleTexture(texture, c20[0], c20[1]);

    // The corners of each edge, and the corners and edges of each triangle.
    // Edges run counterclockwise, the 6 outer first and the 3 inner last;
    // a triangle lists its corners and edges in its winding order.
    const edges = [9][2]u8{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 },
        .{ 3, 4 }, .{ 4, 5 }, .{ 5, 0 },
        .{ 5, 1 }, .{ 1, 3 }, .{ 3, 5 },
    };
    const triangles = [4][6]u8{
        .{ 0, 1, 5, 0, 6, 5 },
        .{ 5, 3, 1, 8, 7, 6 },
        .{ 1, 2, 3, 1, 2, 7 },
        .{ 3, 5, 4, 8, 4, 3 },
    };

    const points = [6]*const [3]f32{ c0, &c01, c1, &c12, c2, &c20 };

    var em: [9]i32 = @splat(0);

    // More samples along the edges, for better states.
    if (edgeres > 0) {
        for (&em, edges) |*e, edge| {
            const p = points[edge[0]];
            const q = points[edge[1]];
            e.* = rasterizeEdge(p[0], p[1], q[0], q[1], edgeres, texture);
        }
    }

    for (triangles, 0..) |tri, i| {
        const p0 = points[tri[0]];
        const p1 = points[tri[1]];
        const p2 = points[tri[2]];

        // The triangle's center, sampled.
        const uc = (p0[0] + p1[0] + p2[0]) * @as(f32, 1.0 / 3.0);
        const vc = (p0[1] + p1[1] + p2[1]) * @as(f32, 1.0 / 3.0);
        const ac = sampleTexture(texture, uc, vc);

        rasterizeOpacity0(
            states,
            result,
            index * 4 + i,
            p0[2],
            p1[2],
            p2[2],
            ac,
            em[tri[3]],
            em[tri[4]],
            em[tri[5]],
            edgeres,
        );
    }
}

/// The micro triangles of triangle `index` at `level`, from its corners
/// with their alpha in the third float.
fn rasterizeOpacityRec(
    comptime states: u32,
    result: []u8,
    index: usize,
    level: u32,
    edgeres: i32,
    c0: *const [3]f32,
    c1: *const [3]f32,
    c2: *const [3]f32,
    texture: *const Texture,
) void {
    if (level == 0) {
        // The triangle's center, sampled.
        const uc = (c0[0] + c1[0] + c2[0]) * @as(f32, 1.0 / 3.0);
        const vc = (c0[1] + c1[1] + c2[1]) * @as(f32, 1.0 / 3.0);
        const ac = sampleTexture(texture, uc, vc);

        var e0: i32 = 0;
        var e1: i32 = 0;
        var e2: i32 = 0;

        if (edgeres > 0) {
            // More samples along the edges, for better states.
            e0 = rasterizeEdge(c0[0], c0[1], c1[0], c1[1], edgeres, texture);
            e1 = rasterizeEdge(c1[0], c1[1], c2[0], c2[1], edgeres, texture);
            e2 = rasterizeEdge(c2[0], c2[1], c0[0], c0[1], edgeres, texture);
        }

        const a0, const a1, const a2 = .{ c0[2], c1[2], c2[2] };
        return rasterizeOpacity0(states, result, index, a0, a1, a2, ac, e0, e1, e2, edgeres);
    }

    // The same as recursing, with fewer samples, as edge samples are
    // shared.
    if (level == 1 and edgeres > 0) {
        return rasterizeOpacity1(states, result, index, edgeres, c0, c1, c2, texture);
    }

    // Each edge's midpoint, sampled.
    var c01 = [3]f32{ (c0[0] + c1[0]) / 2, (c0[1] + c1[1]) / 2, 0 };
    var c12 = [3]f32{ (c1[0] + c2[0]) / 2, (c1[1] + c2[1]) / 2, 0 };
    var c20 = [3]f32{ (c2[0] + c0[0]) / 2, (c2[1] + c0[1]) / 2, 0 };

    c01[2] = sampleTexture(texture, c01[0], c01[1]);
    c12[2] = sampleTexture(texture, c12[0], c12[1]);
    c20[2] = sampleTexture(texture, c20[0], c20[1]);

    // Triangles 1 and 3 flip the winding, and 1 is upside down.
    const sub = level - 1;
    rasterizeOpacityRec(states, result, index * 4 + 0, sub, edgeres, c0, &c01, &c20, texture);
    rasterizeOpacityRec(states, result, index * 4 + 1, sub, edgeres, &c20, &c12, &c01, texture);
    rasterizeOpacityRec(states, result, index * 4 + 2, sub, edgeres, &c01, c1, &c12, texture);
    rasterizeOpacityRec(states, result, index * 4 + 3, sub, edgeres, &c12, &c20, c2, texture);
}

/// The special index (-1 to -4) for a micromap whose micro triangles all
/// have one state, or 0.
fn specialIndex(data: []const u8, level: u32, states: u32) i32 {
    const first: i32 = data[0] & @as(u8, if (states == 2) 1 else 3);
    const special = -(1 + first);

    // At level 0, every micromap is one state.
    if (level == 0) return special;

    // At level 1 with 2 states, the byte is half filled.
    if (level == 1 and states == 2) return if ((data[0] & 15) == ((-first) & 15)) special else 0;

    // Otherwise every byte repeats the first state.
    const expected = first * @as(i32, if (states == 2) 0xff else 0x55);

    for (data[0..levelSize(level, states)]) |byte| {
        if (byte != expected) return 0;
    }

    return special;
}

fn checkTexture(width: u32, height: u32) void {
    assert(width -% 1 < 16384 and height -% 1 < 16384);
}

/// Picks a subdivision level for each triangle of `indices`, and merges
/// triangles with the same texture coordinates (`uvs`, 2 floats per vertex)
/// into one micromap entry each, so each is rasterized once. Returns the
/// number of entries.
///
/// `levels[i]` receives entry `i`'s level, and `sources[i]` the triangle to
/// rasterize it from; both hold `indices.len / 3` items, the most there can
/// be. `omm_indices` receives each triangle's entry. With `target_edge`
/// above 0, levels adapt so micro triangles cover about `target_edge`
/// squared texels, up to `max_level` (0 to 12); with 0, every triangle is
/// at `max_level`.
pub fn opacityMapMeasure(
    gpa: Allocator,
    levels: []u8,
    sources: []u32,
    omm_indices: []i32,
    indices: []const u32,
    uvs: VertexFloats,
    texture_width: u32,
    texture_height: u32,
    max_level: u8,
    target_edge: f32,
) Allocator.Error!usize {
    assert(indices.len % 3 == 0);
    assert(uvs.stride >= 2 and uvs.stride <= 64);
    checkTexture(texture_width, texture_height);
    assert(max_level <= 12);
    assert(target_edge >= 0);

    const vertex_count = uvs.count();
    const triangle_count = indices.len / 3;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const texture_area = @as(f32, @floatFromInt(texture_width)) *
        @as(f32, @floatFromInt(texture_height));

    // Requests merge by their texture coordinates.
    const table = try scratch.alloc(u32, hashBuckets(triangle_count));
    @memset(table, none);

    const triangles = try scratch.alloc(TriangleOmm, triangle_count);
    const hasher: TriangleOmmHasher = .{ .data = triangles };

    var result: usize = 0;

    for (0..triangle_count) |i| {
        const a = indices[i * 3 + 0];
        const b = indices[i * 3 + 1];
        const c = indices[i * 3 + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        const ta = uvs.at(a)[0..2].*;
        const tb = uvs.at(b)[0..2].*;
        const tc = uvs.at(c)[0..2].*;

        var level: i32 = max_level;

        if (target_edge > 0) {
            // The ratio of the edge length in texels to the target sets
            // the level.
            const uvcross = (tb[0] - ta[0]) * (tc[1] - ta[1]) - (tc[0] - ta[0]) * (tb[1] - ta[1]);
            const uvarea = @abs(uvcross) * 0.5 * texture_area;
            const ratio = @sqrt(uvarea) / target_edge;
            const levelf = log2f(if (ratio > 1) ratio else 1);

            // Rounded to nearest and clamped.
            level = truncate(levelf + 0.5);
            level = if (level < 0) 0 else level;
            level = if (level < max_level) level else max_level;
        }

        // Requests with the same texture coordinates merge.
        const tri: TriangleOmm = .{
            .uvs = .{
                quantizeSubpixel(ta[0], texture_width),
                quantizeSubpixel(ta[1], texture_height),
                quantizeSubpixel(tb[0], texture_width),
                quantizeSubpixel(tb[1], texture_height),
                quantizeSubpixel(tc[0], texture_width),
                quantizeSubpixel(tc[1], texture_height),
            },
            .level = level,
        };
        // Written ahead, so the hasher can compare it.
        triangles[result] = tri;

        const key: u32 = @intCast(result);
        const entry = hashLookup(u32, table, hasher, key, none);

        if (table[entry] == none) {
            table[entry] = key;
            levels[result] = @intCast(level);
            sources[result] = @intCast(i);
            result += 1;
        }

        omm_indices[i] = @intCast(table[entry]);
    }

    return result;
}

/// The bytes of one micromap entry at `level` (0 to 12).
pub fn opacityMapEntrySize(level: u8, format: OpacityMapFormat) usize {
    assert(level <= 12);

    return levelSize(level, @backingInt(format));
}

/// Writes the opacity states of one micromap entry at `level` (0 to 12) to
/// `result`, which holds `opacityMapEntrySize(level, format)` bytes, by
/// sampling `texture` bilinearly with a 0.5 alpha cutoff over the triangle
/// with texture coordinates `uv0`, `uv1` and `uv2`. The corner order
/// matters: the micromap follows it.
pub fn opacityMapRasterize(
    result: []u8,
    level: u8,
    format: OpacityMapFormat,
    uv0: [2]f32,
    uv1: [2]f32,
    uv2: [2]f32,
    texture: AlphaTexture,
) void {
    assert(level <= 12);
    checkTexture(texture.width, texture.height);
    assert(texture.stride >= 1 and texture.stride <= 4);
    assert(texture.pitch >= texture.stride * texture.width);

    const states: u32 = @backingInt(format);
    @memset(result[0..levelSize(level, states)], 0);

    const width_i: i32 = @intCast(texture.width);
    const height_i: i32 = @intCast(texture.height);
    const sampler: Texture = .{
        .data = texture.data,
        .stride = texture.stride,
        .pitch = texture.pitch,
        .width = texture.width,
        .height = texture.height,
        .widthf = @as(f32, @floatFromInt(width_i)) * 256,
        .heightf = @as(f32, @floatFromInt(height_i)) * 256,
    };

    // Edge samples for a conservative state.
    const texture_area = @as(f32, @floatFromInt(width_i)) * @as(f32, @floatFromInt(height_i));
    const uvcross = (uv1[0] - uv0[0]) * (uv2[1] - uv0[1]) - (uv2[0] - uv0[0]) * (uv1[1] - uv0[1]);
    const uvarea = @abs(uvcross) * 0.5 * texture_area;
    const uvedge = @sqrt(uvarea) / @as(f32, @floatFromInt(@as(i32, 1) << @intCast(level)));

    // About 2 texels between edge samples, for equilateral micro triangles.
    var edgeres = truncate(uvedge * 0.75);
    edgeres = if (edgeres < 0) 0 else edgeres;
    edgeres = if (edgeres > 7) 7 else edgeres;

    // The corners pass down the recursion with their samples.
    const c0 = [3]f32{ uv0[0], uv0[1], sampleTexture(&sampler, uv0[0], uv0[1]) };
    const c1 = [3]f32{ uv1[0], uv1[1], sampleTexture(&sampler, uv1[0], uv1[1]) };
    const c2 = [3]f32{ uv2[0], uv2[1], sampleTexture(&sampler, uv2[0], uv2[1]) };

    switch (format) {
        inline else => |f| rasterizeOpacityRec(
            @backingInt(f),
            result,
            0,
            level,
            edgeres,
            &c0,
            &c1,
            &c2,
            &sampler,
        ),
    }
}

/// Merges identical micromap entries and replaces those whose micro
/// triangles all have one state with special indices (-4 to -1), then
/// returns the number of entries left. `data` holds every entry, entry `i`
/// at `offsets[i]` with level `levels[i]`; the entries left move to the
/// front, with their levels and offsets updated, so `data` can be trimmed
/// after the last. `omm_indices`, one per triangle, are rewritten to the
/// new entries or the special indices; negative ones stay.
pub fn opacityMapCompact(
    gpa: Allocator,
    data: []u8,
    levels: []u8,
    offsets: []u32,
    omm_indices: []i32,
    format: OpacityMapFormat,
) Allocator.Error!usize {
    assert(levels.len == offsets.len);
    const omm_count = levels.len;
    const states: u32 = @backingInt(format);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const data_old = try scratch.alloc(u8, data.len);
    @memcpy(data_old, data);

    const table = try scratch.alloc(u32, hashBuckets(omm_count));
    @memset(table, none);

    const hasher: OmmHasher = .{
        .data = data,
        .offsets = offsets,
        .levels = levels,
        .states = states,
    };

    const remap = try scratch.alloc(i32, omm_count);

    var next: usize = 0;
    var offset: usize = 0;

    for (remap, 0..) |*r, i| {
        const level = levels[i];
        assert(level <= 12);

        const old_offset = offsets[i];
        const size = levelSize(level, states);
        assert(old_offset + size <= data.len);
        const old = data_old[old_offset..][0..size];

        // An entry whose micro triangles all have one state becomes a
        // special index.
        const special = specialIndex(old, level, states);
        if (special < 0) {
            r.* = special;
            continue;
        }

        // Written ahead, so the hasher can compare it.
        @memcpy(data[offset..][0..size], old);
        offsets[next] = @intCast(offset);
        levels[next] = level;

        const key: u32 = @intCast(next);
        const entry = hashLookup(u32, table, hasher, key, none);

        if (table[entry] == none) {
            table[entry] = key;
            next += 1;
            offset += size;
        }

        r.* = @intCast(table[entry]);
    }

    // Triangles point to the new entries, or to special indices.
    for (omm_indices) |*index| {
        assert(index.* < 0 or index.* < omm_count);
        index.* = if (index.* < 0) index.* else remap[@intCast(index.*)];
    }

    return next;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "entry sizes" {
    try testing.expectEqual(1, opacityMapEntrySize(0, .two_state));
    try testing.expectEqual(1, opacityMapEntrySize(1, .two_state));
    try testing.expectEqual(2, opacityMapEntrySize(2, .two_state));
    try testing.expectEqual(1, opacityMapEntrySize(1, .four_state));
    try testing.expectEqual(1 << 22, opacityMapEntrySize(12, .four_state));
}

test "one-state entries become special indices" {
    for (0..3) |level| {
        const expected = [_]struct { format: OpacityMapFormat, byte: u8, index: i32 }{
            .{ .format = .two_state, .byte = 0x00, .index = -1 },
            .{ .format = .two_state, .byte = 0xff, .index = -2 },
            .{ .format = .four_state, .byte = 0x00, .index = -1 },
            .{ .format = .four_state, .byte = 0x55, .index = -2 },
            .{ .format = .four_state, .byte = 0xaa, .index = -3 },
            .{ .format = .four_state, .byte = 0xff, .index = -4 },
        };
        for (expected) |e| {
            var data: [4]u8 = @splat(e.byte);
            var levels = [1]u8{@intCast(level)};
            var offsets = [1]u32{0};
            var omm_indices = [1]i32{0};
            const size = opacityMapEntrySize(levels[0], e.format);
            const left = try opacityMapCompact(
                testing.allocator,
                data[0..size],
                &levels,
                &offsets,
                &omm_indices,
                e.format,
            );
            try testing.expectEqual(0, left);
            try testing.expectEqual(e.index, omm_indices[0]);
        }
    }
}

/// The logarithm the levels come from, for the oracle tests to check
/// against the system's libm.
pub fn log2fForTest(x: f32) f32 {
    return log2f(x);
}
