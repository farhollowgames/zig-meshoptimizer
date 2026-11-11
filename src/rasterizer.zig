//! Overdraw and coverage analysis with a small software rasterizer: the
//! mesh drawn along each axis into a 256 by 256 viewport, with front and
//! back faces in separate depth buffers.
//!
//! Translated from meshoptimizer's rasterizer.cpp, which builds on Capens,
//! "Advanced Rasterization" (2004).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const checkIndex = @import("index.zig").check;
const VertexFloats = @import("strided.zig").VertexFloats;
const truncate = @import("convert.zig").truncate;

const viewport = 256;

/// Depth and draw count of every pixel, for front faces (0) and back
/// faces (1).
const OverdrawBuffer = struct {
    z: [viewport][viewport][2]f32,
    overdraw: [viewport][viewport][2]u32,
};

const Gradients = struct {
    det: f32,
    dzdx: f32,
    dzdy: f32,
};

/// The depth gradients of triangle 123, from
///   z2 = z1 + dzdx * (x2 - x1) + dzdy * (y2 - y1)
///   z3 = z1 + dzdx * (x3 - x1) + dzdy * (y3 - y1)
/// by Cramer's rule, and the system's determinant, which is positive for
/// back faces.
fn depthGradients(
    x1: f32,
    y1: f32,
    z1: f32,
    x2: f32,
    y2: f32,
    z2: f32,
    x3: f32,
    y3: f32,
    z3: f32,
) Gradients {
    const det = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
    const invdet: f32 = if (det == 0) 0 else 1 / det;

    return .{
        .det = det,
        .dzdx = ((z2 - z1) * (y3 - y1) - (y2 - y1) * (z3 - z1)) * invdet,
        .dzdy = ((x2 - x1) * (z3 - z1) - (z2 - z1) * (x3 - x1)) * invdet,
    };
}

/// Draws triangle 123 (x, y and depth for each corner) into `buffer` with a
/// half-space rasterizer in fixed point: every pixel whose center the
/// triangle covers and whose depth it does not lie behind counts one more
/// draw. The corners come as separate floats, which keeps them in
/// registers across the call.
fn rasterize(
    buffer: *OverdrawBuffer,
    v1x: f32,
    v1y: f32,
    v1z_in: f32,
    v2x_in: f32,
    v2y_in: f32,
    v2z: f32,
    v3x_in: f32,
    v3y_in: f32,
    v3z: f32,
) void {
    const gradients = depthGradients(v1x, v1y, v1z_in, v2x_in, v2y_in, v2z, v3x_in, v3y_in, v3z);
    var dzx = gradients.dzdx;
    var dzy = gradients.dzdy;
    const sign: u1 = @intFromBool(gradients.det > 0);

    var v1z = v1z_in;
    var v2x = v2x_in;
    var v2y = v2y_in;
    var v3x = v3x_in;
    var v3y = v3y_in;

    // Back faces turn into front faces, which keeps the rasterization
    // below one case.
    if (sign == 1) {
        // Swapping corners 2 and 3 keeps the depth gradients, which are
        // relative to corner 1; below, only corner 1's depth is used.
        std.mem.swap(f32, &v2x, &v3x);
        std.mem.swap(f32, &v2y, &v3y);

        // Back faces go to the second buffer, with depth reversed.
        v1z = viewport - v1z;
        dzx = -dzx;
        dzy = -dzy;
    }

    // Coordinates in 28.4 fixed point, and the bounding rectangle, clipped
    // to the viewport. Pixels count when their centers are covered, so a
    // minimum above 0.5 rounds up; the top-left fill convention never draws
    // right or bottom edges, so a maximum of 0.5 or more rounds down for an
    // inclusive bound, which is up for the exclusive bound here. A triangle
    // between two rows or columns of pixel centers draws nothing.
    const y1 = truncate(16.0 * v1y + 0.5);
    const y2 = truncate(16.0 * v2y + 0.5);
    const y3 = truncate(16.0 * v3y + 0.5);

    const miny: i32 = @max((@min(y1, y2, y3) + 7) >> 4, 0);
    const maxy: i32 = @min((@max(y1, y2, y3) + 7) >> 4, viewport);
    if (miny >= maxy) return;

    const x1 = truncate(16.0 * v1x + 0.5);
    const x2 = truncate(16.0 * v2x + 0.5);
    const x3 = truncate(16.0 * v3x + 0.5);

    const minx: i32 = @max((@min(x1, x2, x3) + 7) >> 4, 0);
    const maxx: i32 = @min((@max(x1, x2, x3) + 7) >> 4, viewport);
    if (minx >= maxx) return;

    // Edge deltas, 28.4 fixed point.
    const dx12 = x1 -% x2;
    const dx23 = x2 -% x3;
    const dx31 = x3 -% x1;

    const dy12 = y1 -% y2;
    const dy23 = y2 -% y3;
    const dy31 = y3 -% y1;

    // The fill convention's correction.
    const tl1: i32 = @intFromBool(dy12 < 0 or (dy12 == 0 and dx12 > 0));
    const tl2: i32 = @intFromBool(dy23 < 0 or (dy23 == 0 and dx23 > 0));
    const tl3: i32 = @intFromBool(dy31 < 0 or (dy31 == 0 and dx31 > 0));

    // Half-edge equations, 24.8 fixed point, at the first pixel's center.
    const fx = (minx << 4) + 8;
    const fy = (miny << 4) + 8;
    var cy1 = dx12 *% (fy -% y1) -% dy12 *% (fx -% x1) +% tl1 -% 1;
    var cy2 = dx23 *% (fy -% y2) -% dy23 *% (fx -% x2) +% tl2 -% 1;
    var cy3 = dx31 *% (fy -% y3) -% dy31 *% (fx -% x3) +% tl3 -% 1;
    const offset_x: f32 = @floatFromInt(fx -% x1);
    const offset_y: f32 = @floatFromInt(fy -% y1);
    var zy = v1z + (dzx * offset_x + dzy * offset_y) * (1.0 / 16.0);

    var y = miny;
    while (y < maxy) : (y += 1) {
        var cx1 = cy1;
        var cx2 = cy2;
        var cx3 = cy3;
        var zx = zy;

        var x = minx;
        while (x < maxx) : (x += 1) {
            // Inside all three edges.
            if ((cx1 | cx2 | cx3) >= 0) {
                const z = &buffer.z[@intCast(y)][@intCast(x)][sign];
                if (zx >= z.*) {
                    z.* = zx;
                    buffer.overdraw[@intCast(y)][@intCast(x)][sign] += 1;
                }
            }

            cx1 -%= dy12 *% 16;
            cx2 -%= dy23 *% 16;
            cx3 -%= dy31 *% 16;
            zx += dzx;
        }

        cy1 +%= dx12 *% 16;
        cy2 +%= dx23 *% 16;
        cy3 +%= dx31 *% 16;
        zy += dzy;
    }
}

/// Writes the corners of every triangle of `indices` to `triangles`, three
/// floats each, scaled so the mesh's largest extent spans the viewport, and
/// returns that extent.
fn transformTriangles(
    comptime Index: type,
    triangles: []f32,
    indices: []const Index,
    positions: VertexFloats,
) f32 {
    const vertex_count = positions.count();

    var minv: [3]f32 = @splat(std.math.floatMax(f32));
    var maxv: [3]f32 = @splat(-std.math.floatMax(f32));

    for (0..vertex_count) |i| {
        const v = positions.vec3(i);

        for (&minv, &maxv, v) |*min, *max, vj| {
            min.* = if (min.* > vj) vj else min.*;
            max.* = if (max.* < vj) vj else max.*;
        }
    }

    var extent: f32 = 0;

    for (minv, maxv) |min, max| extent = if (max - min < extent) extent else max - min;

    const scale: f32 = if (extent == 0) 0 else viewport / extent;

    for (indices, 0..) |index, i| {
        assert(index < vertex_count);

        const v = positions.vec3(index);

        triangles[i * 3 + 0] = (v[0] - minv[0]) * scale;
        triangles[i * 3 + 1] = (v[1] - minv[1]) * scale;
        triangles[i * 3 + 2] = (v[2] - minv[2]) * scale;
    }

    return extent;
}

/// Draws every triangle seen along `axis`: the viewport's x and y are the
/// other two axes, and depth is `axis`.
fn rasterizeTriangles(buffer: *OverdrawBuffer, triangles: []const f32, comptime axis: u2) void {
    const x, const y, const z = switch (axis) {
        0 => .{ 2, 1, 0 },
        1 => .{ 0, 2, 1 },
        2 => .{ 1, 0, 2 },
        3 => unreachable,
    };

    var i: usize = 0;
    while (i < triangles.len) : (i += 9) {
        const v0 = triangles[i..][0..3];
        const v1 = triangles[i + 3 ..][0..3];
        const v2 = triangles[i + 6 ..][0..3];

        rasterize(buffer, v0[x], v0[y], v0[z], v1[x], v1[y], v1[z], v2[x], v2[y], v2[z]);
    }
}

/// The pixels of `counts` drawn at least once, and the draws in all.
fn countDraws(counts: *const [viewport * viewport * 2]u32) struct { u32, u32 } {
    const lanes = 16;
    const V = @Vector(lanes, u32);
    const zero: V = @splat(0);

    var covered = zero;
    var shaded = zero;

    var i: usize = 0;
    while (i < counts.len) : (i += lanes) {
        const v: V = counts[i..][0..lanes].*;
        covered += @select(u32, v != zero, @as(V, @splat(1)), zero);
        shaded +%= v;
    }

    var total_shaded: u32 = 0;
    inline for (0..lanes) |lane| total_shaded +%= shaded[lane];
    return .{ @reduce(.Add, covered), total_shaded };
}

/// The pixels of `counts` that front or back faces drew.
fn countCovered(counts: *const [viewport * viewport * 2]u32) u32 {
    const lanes = 8;
    const V = @Vector(lanes, u32);

    var covered: V = @splat(0);

    var i: usize = 0;
    while (i < counts.len) : (i += lanes * 2) {
        // A pixel's two counts as one 64-bit lane: nonzero when either is.
        const pair: @Vector(lanes * 2, u32) = counts[i..][0 .. lanes * 2].*;
        const pixels: @Vector(lanes, u64) = @bitCast(pair);
        const drawn = pixels != @as(@Vector(lanes, u64), @splat(0));
        covered += @select(u32, drawn, @as(V, @splat(1)), @as(V, @splat(0)));
    }

    return @reduce(.Add, covered);
}

pub const OverdrawStatistics = struct {
    pixels_covered: u32 = 0,
    pixels_shaded: u32 = 0,
    /// Shaded pixels per covered pixel: 1 at best.
    overdraw: f32 = 0,
};

/// Measures the overdraw of drawing `indices` in order, with a software
/// rasterizer that draws the mesh along each axis, front and back faces
/// apart. Real GPUs may differ.
pub fn analyzeOverdraw(
    comptime Index: type,
    gpa: Allocator,
    indices: []const Index,
    positions: VertexFloats,
) Allocator.Error!OverdrawStatistics {
    comptime checkIndex(Index);
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    var result: OverdrawStatistics = .{};

    const triangles = try scratch.alloc(f32, indices.len * 3);
    _ = transformTriangles(Index, triangles, indices, positions);

    const buffer = &(try scratch.alloc(OverdrawBuffer, 1))[0];

    inline for (0..3) |axis| {
        @memset(std.mem.asBytes(buffer), 0);
        rasterizeTriangles(buffer, triangles, axis);

        const covered, const shaded = countDraws(@ptrCast(&buffer.overdraw));
        result.pixels_covered += covered;
        result.pixels_shaded +%= shaded;
    }

    result.overdraw = if (result.pixels_covered == 0)
        0
    else
        @as(f32, @floatFromInt(result.pixels_shaded)) /
            @as(f32, @floatFromInt(result.pixels_covered));

    return result;
}

pub const CoverageStatistics = struct {
    /// The share of the viewport's pixels the mesh covers, seen along each
    /// axis.
    coverage: [3]f32 = @splat(0),
    /// The viewport's size in mesh units.
    extent: f32 = 0,
};

/// Measures how much of the viewport the mesh covers seen along each axis,
/// with the software rasterizer of `analyzeOverdraw`.
pub fn analyzeCoverage(
    comptime Index: type,
    gpa: Allocator,
    indices: []const Index,
    positions: VertexFloats,
) Allocator.Error!CoverageStatistics {
    comptime checkIndex(Index);
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    var result: CoverageStatistics = .{};

    const triangles = try scratch.alloc(f32, indices.len * 3);
    const extent = transformTriangles(Index, triangles, indices, positions);

    const buffer = &(try scratch.alloc(OverdrawBuffer, 1))[0];

    inline for (0..3) |axis| {
        @memset(std.mem.asBytes(buffer), 0);
        rasterizeTriangles(buffer, triangles, axis);

        const covered = countCovered(@ptrCast(&buffer.overdraw));
        result.coverage[axis] = @as(f32, @floatFromInt(covered)) / (viewport * viewport);
    }

    result.extent = extent;

    return result;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a square seen face on covers the viewport" {
    // Two triangles making the unit square in the xy plane, and a corner
    // out on z so the mesh is a cube's extent.
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0 };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const stats = try analyzeCoverage(u32, testing.allocator, &indices, .init(&positions, 3));
    try testing.expectEqual(1.0, stats.coverage[2]);
    try testing.expectEqual(1.0, stats.extent);
}
