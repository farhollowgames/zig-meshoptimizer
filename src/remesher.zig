//! Voxel remeshing: a new mesh, closed and evenly tessellated, that
//! approximates the input at a voxel resolution, for automatic levels of
//! detail and cluster hierarchies. The input is voxelized, its inside filled
//! unless a shell is asked for, and the occupied voxels joined by triangles,
//! one vertex per voxel at the centroid of the surface inside it or at the
//! point its error quadric puts closest to that surface.
//!
//! Translated from meshoptimizer's remesher.cpp, experimental in the
//! original, which builds on Lorensen and Cline, "Marching Cubes: A High
//! Resolution 3D Surface Construction Algorithm" (1987), and Garland and
//! Heckbert, "Surface Simplification Using Quadric Error Metrics" (1997).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const VertexFloats = @import("strided.zig").VertexFloats;
const truncate = @import("convert.zig").truncate;

/// What `remesh` builds. Each field is the bit of the original's
/// `meshopt_Remesh` flag of the same name.
pub const RemeshOptions = packed struct(u32) {
    /// A two-sided shell wrapping the surfaces of the input, instead of a
    /// solid mesh.
    shell: bool = false,
    /// Places each vertex where it approximates the input's surface as
    /// closely as it can, instead of at the centroid of the surface in its
    /// voxel; slower.
    solve: bool = false,
    reserved: u28 = 0,
    /// For development: places each vertex at the center of its voxel, to
    /// show the grid. The original keeps this flag out of its header and
    /// asks that it not be used.
    internal_debug: bool = false,
    reserved_high: u1 = 0,
};

const empty_row = std.math.maxInt(u32);

/// The grid value of an empty voxel inside a solid; an occupied voxel holds
/// its position in its row's run of occupied voxels, from 1.
const inside = 0xff;

/// A cube case of the base triangulation. A triangle is three corner codes
/// in three nibbles, and a corner code has the bits XYZ of the corner (3 is
/// X=1 Y=1 Z=0).
const Case = struct {
    code: u8,
    altmode: u8,
    triangles: []const u16,
    /// A triangulation used instead when a decider picks it, with no more
    /// triangles than the primary.
    alternate: []const u16,
};

fn case(code: u8, altmode: u8, triangles: []const u16, alternate: []const u16) Case {
    return .{ .code = code, .altmode = altmode, .triangles = triangles, .alternate = alternate };
}

// The base cases give a canonical triangulation; unlike classical Marching
// Cubes, triangles join cube corners, not edges. Each case may have an
// alternate triangulation, picked by a decider; open boundary edges stay
// consistent whatever each cell's decider picks.
const base_cases = [_]Case{
    case(0x00, 0, &.{}, &.{}),
    case(0x01, 0, &.{}, &.{}),
    case(0x03, 0, &.{}, &.{}),
    case(0x06, 0, &.{}, &.{}),
    case(0x07, 0, &.{0x120}, &.{}),
    case(0x0f, 2, &.{ 0x130, 0x032 }, &.{ 0x321, 0x120 }),
    case(0x16, 1, &.{ 0x124, 0x142 }, &.{}),
    case(0x17, 0, &.{0x124}, &.{}),
    case(0x18, 0, &.{}, &.{}),
    case(0x19, 1, &.{ 0x043, 0x403 }, &.{}),
    case(0x1b, 1, &.{ 0x134, 0x430 }, &.{ 0x410, 0x013 }),
    case(0x1d, 1, &.{ 0x243, 0x340 }, &.{ 0x320, 0x024 }),
    case(0x1e, 1, &.{ 0x142, 0x432, 0x341 }, &.{0x132}),
    case(0x1f, 2, &.{ 0x412, 0x213 }, &.{ 0x134, 0x432 }),
    case(0x3c, 1, &.{ 0x345, 0x324, 0x543, 0x423 }, &.{}),
    case(0x3d, 1, &.{ 0x253, 0x524, 0x350 }, &.{ 0x240, 0x504, 0x320 }),
    case(0x3f, 2, &.{ 0x325, 0x524 }, &.{ 0x243, 0x345 }),
    case(0x69, 1, &.{ 0x035, 0x560, 0x306, 0x536 }, &.{}),
    case(0x6b, 1, &.{ 0x063, 0x605, 0x365 }, &.{0x305}),
    case(0x6f, 1, &.{ 0x365, 0x560 }, &.{ 0x530, 0x036 }),
    case(0x7e, 0, &.{ 0x142, 0x536 }, &.{}),
    case(0x7f, 0, &.{0x365}, &.{}),
    case(0xf0, 2, &.{ 0x547, 0x746 }, &.{ 0x465, 0x567 }),
    case(0xff, 0, &.{}, &.{}),
};

/// The triangulation of every cube case, derived from the base cases by 90
/// degree rotations.
const Tables = struct {
    /// Primary and alternate triangles of each case, up to 4 and a 0 end.
    triangles: [256][2][5]u16,
    count: [256]u8,
    /// 0 for no alternate, 1 for the octant decider, 2 for the quadric one.
    alt: [256]u8,
};

const tables: Tables = buildTables();

fn buildTables() Tables {
    @setEvalBranchQuota(100_000);

    // Corner remaps for 90 degree rotations around X and Y.
    const rotations = [2][8]u8{ .{ 2, 3, 6, 7, 0, 1, 4, 5 }, .{ 4, 0, 6, 2, 5, 1, 7, 3 } };

    var result: Tables = .{
        .triangles = @splat(@splat(@splat(0))),
        .count = @splat(0),
        .alt = @splat(0),
    };
    var filled: [256]u8 = @splat(0);

    for (base_cases) |c| {
        const alternate = if (c.altmode != 0) c.alternate else c.triangles;
        @memcpy(result.triangles[c.code][0][0..c.triangles.len], c.triangles);
        @memcpy(result.triangles[c.code][1][0..alternate.len], alternate);
        result.alt[c.code] = c.altmode;
        filled[c.code] = 1;
    }

    // The worst case takes 5 passes, but 3 fill every case.
    for (0..3) |_| {
        for (0..256) |code| {
            if (filled[code] != 1) continue;

            for (rotations) |rotation| {
                var rotated: u8 = 0;
                for (0..8) |i| {
                    const bit: u8 = @intCast((code >> @intCast(i)) & 1);
                    rotated |= bit << @intCast(rotation[i]);
                }

                if (filled[rotated] != 0) continue;

                for (0..2) |k| {
                    for (result.triangles[code][k], 0..) |tri, i| {
                        if (tri == 0) break;
                        const a: u16 = rotation[(tri >> 8) & 0xf];
                        const b: u16 = rotation[(tri >> 4) & 0xf];
                        result.triangles[rotated][k][i] = a << 8 | b << 4 | rotation[tri & 0xf];
                    }
                }

                result.alt[rotated] = result.alt[code];
                // Pending.
                filled[rotated] = 1;
            }

            // Processed.
            filled[code] = 2;
        }
    }

    for (0..256) |code| {
        assert(filled[code] != 0);

        var count: usize = 0;
        while (result.triangles[code][0][count] != 0) count += 1;
        result.count[code] = @intCast(count);

        // Counting reads no alternate, so none has more triangles than its
        // primary.
        assert(result.triangles[code][1][count] == 0);

        // The quadric decider reads a quad as the triangles 0xabc 0xcbd.
        if (result.alt[code] == 2) {
            const first = result.triangles[code][0][0];
            const second = result.triangles[code][0][1];
            assert(count == 2);
            assert((first & 0xf0) == (second & 0xf0) and (first & 0xf) == second >> 8);
        }
    }

    return result;
}

const Voxel = struct {
    coord: u32 = 0,
    octants: u8 = 0,

    px: f32 = 0,
    py: f32 = 0,
    pz: f32 = 0,
    w: f32 = 0,

    // The error quadric a00*x^2 + a11*y^2 + a22*z^2 + 2*a10*xy + 2*a20*xz +
    // 2*a21*yz + 2*b0*x + 2*b1*y + 2*b2*z + c.
    a00: f32 = 0,
    a11: f32 = 0,
    a22: f32 = 0,
    a10: f32 = 0,
    a20: f32 = 0,
    a21: f32 = 0,
    b0: f32 = 0,
    b1: f32 = 0,
    b2: f32 = 0,
    c: f32 = 0,

    fn accumulate(vox: *Voxel, px: f32, py: f32, pz: f32, w: f32) void {
        vox.px += px * w;
        vox.py += py * w;
        vox.pz += pz * w;
        vox.w += w;
    }

    /// Adds the quadric of the plane `a*x + b*y + c*z + d = 0` with weight
    /// `w`.
    fn accumulateQuadric(vox: *Voxel, a: f32, b: f32, c: f32, d: f32, w: f32) void {
        const aw = a * w;
        const bw = b * w;
        const cw = c * w;
        const dw = d * w;

        vox.a00 += a * aw;
        vox.a11 += b * bw;
        vox.a22 += c * cw;
        vox.a10 += a * bw;
        vox.a20 += a * cw;
        vox.a21 += b * cw;
        vox.b0 += a * dw;
        vox.b1 += b * dw;
        vox.b2 += c * dw;
        vox.c += d * dw;
    }

    fn quadricError(vox: Voxel, x: f32, y: f32, z: f32) f32 {
        const rx = (vox.b0 + vox.a10 * y) * 2 + vox.a00 * x;
        const ry = (vox.b1 + vox.a21 * z) * 2 + vox.a11 * y;
        const rz = (vox.b2 + vox.a20 * x) * 2 + vox.a22 * z;

        return @abs(vox.c + rx * x + ry * y + rz * z);
    }

    /// The point that minimizes the quadric, pulled towards the centroid by
    /// `lambda`; null when the system is too close to singular.
    fn solveQuadric(vox: Voxel, lambda: f32) ?[3]f32 {
        // Solve A*p = -b, where A is the quadric matrix and b its linear
        // term.
        const rw = lambda * vox.w;
        const a00 = rw + vox.a00;
        const a11 = rw + vox.a11;
        const a22 = rw + vox.a22;
        const a10 = vox.a10;
        const a20 = vox.a20;
        const a21 = vox.a21;
        const x0 = lambda * vox.px - vox.b0;
        const x1 = lambda * vox.py - vox.b1;
        const x2 = lambda * vox.pz - vox.b2;

        const eps = 1e-6 * vox.w;

        // LDL decomposition: A = LDL^T.
        const d0 = a00;
        const l10 = a10 / d0;
        const l20 = a20 / d0;

        const d1 = a11 - a10 * l10;
        const dl21 = a21 - a20 * l10;
        const l21 = dl21 / d1;

        const d2 = a22 - a20 * l20 - dl21 * l21;

        // Solve L*y = x.
        const y0 = x0;
        const y1 = x1 - l10 * y0;
        const y2 = x2 - l20 * y0 - l21 * y1;

        // Solve D*z = y.
        const z0 = y0 / d0;
        const z1 = y1 / d1;
        const z2 = y2 / d2;

        // Substitute L^T*p = z.
        const rz = z2;
        const ry = z1 - l21 * rz;
        const rx = z0 - l10 * ry - l20 * rz;

        if (@abs(d0) > eps and @abs(d1) > eps and @abs(d2) > eps) return .{ rx, ry, rz };
        return null;
    }
};

/// The scale from model space to grid coordinates, and in `offset` the
/// model-space position of the grid's origin.
fn measureGrid(positions: VertexFloats, resolution: u32, offset: *[3]f32) f32 {
    var minv: [3]f32 = @splat(std.math.floatMax(f32));
    var maxv: [3]f32 = @splat(-std.math.floatMax(f32));

    for (0..positions.count()) |i| {
        const v = positions.vec3(i);

        for (0..3) |j| {
            minv[j] = if (minv[j] > v[j]) v[j] else minv[j];
            maxv[j] = if (maxv[j] < v[j]) v[j] else maxv[j];
        }
    }

    var extent: f32 = 0;

    extent = if (maxv[0] - minv[0] < extent) extent else maxv[0] - minv[0];
    extent = if (maxv[1] - minv[1] < extent) extent else maxv[1] - minv[1];
    extent = if (maxv[2] - minv[2] < extent) extent else maxv[2] - minv[2];

    // A small subvoxel padding keeps vertices inside the last valid voxel,
    // so they need no clamping.
    const resolution_f: f32 = @floatFromInt(resolution);
    extent *= (resolution_f + 1e-2) / resolution_f;

    // Extents map to [0, resolution - 2], because the first and last voxels
    // are empty padding.
    const scale = if (extent == 0) 0 else @as(f32, @floatFromInt(resolution - 2)) / extent;

    // Centering the mesh in the grid voxelizes symmetric inputs better.
    for (0..3) |j| offset[j] = minv[j] - (extent - (maxv[j] - minv[j])) * 0.5;

    return scale;
}

/// Samples each triangle about twice per voxel edge. Without `accumulate`,
/// tags each voxel a sample falls in; with it, adds the samples to the
/// voxels, which `rowpack` has numbered, with their quadrics if
/// `with_quadrics`.
fn voxelize(
    comptime accumulate: bool,
    comptime with_quadrics: bool,
    grid: []u8,
    rowmap: []const u32,
    voxels: []Voxel,
    indices: []const u32,
    positions: VertexFloats,
    resolution: usize,
    scale: f32,
    offset: [3]f32,
) void {
    const vertex_count = positions.count();
    const resolution_i: i32 = @intCast(resolution);

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const a = indices[i + 0];
        const b = indices[i + 1];
        const c = indices[i + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        const va = positions.vec3(a);
        const vb = positions.vec3(b);
        const vc = positions.vec3(c);

        const ex = vb[0] - va[0];
        const ey = vb[1] - va[1];
        const ez = vb[2] - va[2];
        const fx = vc[0] - va[0];
        const fy = vc[1] - va[1];
        const fz = vc[2] - va[2];
        const gx = vc[0] - vb[0];
        const gy = vc[1] - vb[1];
        const gz = vc[2] - vb[2];

        // The longest edge sets the sampling rate.
        const el2 = ex * ex + ey * ey + ez * ez;
        const fl2 = fx * fx + fy * fy + fz * fz;
        const gl2 = gx * gx + gy * gy + gz * gz;

        var max_edge = if (el2 > fl2) el2 else fl2;
        max_edge = if (max_edge > gl2) max_edge else gl2;
        max_edge = @sqrt(max_edge);

        // Two samples per voxel edge hit every voxel at any rotation.
        var samples = truncate(max_edge * scale * 2);
        samples = if (samples > 1) samples else 1;
        samples = if (samples < resolution_i * 2) samples else resolution_i * 2;

        // The normal gives the area, for weighting, and the quadric.
        var nx = ey * fz - ez * fy;
        var ny = ez * fx - ex * fz;
        var nz = ex * fy - ey * fx;
        const area = @sqrt(nx * nx + ny * ny + nz * nz);

        // Degenerate triangles add nothing, and could make a voxel's
        // centroid NaN.
        if (area == 0) continue;

        const ns = 1 / area;
        nx *= ns;
        ny *= ns;
        nz *= ns;

        const sx = va[0] - offset[0];
        const sy = va[1] - offset[1];
        const sz = va[2] - offset[2];
        var sr: f32 = 1;
        const weight = area / @as(f32, @floatFromInt((samples + 1) * (samples + 2)));

        // The division is on the critical path, and dense meshes almost
        // never need it.
        if (samples > 1) sr = 1 / @as(f32, @floatFromInt(samples));

        var u: i32 = 0;
        while (u <= samples) : (u += 1) {
            var v: i32 = 0;
            while (v <= samples - u) : (v += 1) {
                const su = @as(f32, @floatFromInt(u)) * sr;
                const sv = @as(f32, @floatFromInt(v)) * sr;
                const px = sx + su * ex + sv * fx;
                const py = sy + su * ey + sv * fy;
                const pz = sz + su * ez + sv * fz;

                // Coordinates with an extra bit, for the octant mask.
                const hx = truncate(px * (scale * 2));
                const hy = truncate(py * (scale * 2));
                const hz = truncate(pz * (scale * 2));
                var x = hx >> 1;
                var y = hy >> 1;
                var z = hz >> 1;

                // Rounding and non-finite inputs can give coordinates out
                // of bounds; they go to the last voxel.
                const cutoff = resolution_i - 3;
                x = if (@as(u32, @bitCast(x)) < @as(u32, @bitCast(cutoff))) x else cutoff;
                y = if (@as(u32, @bitCast(y)) < @as(u32, @bitCast(cutoff))) y else cutoff;
                z = if (@as(u32, @bitCast(z)) < @as(u32, @bitCast(cutoff))) z else cutoff;

                const row = @as(usize, @intCast(y + 1)) + resolution * @as(usize, @intCast(z + 1));
                const idx = @as(usize, @intCast(x + 1)) + resolution * row;

                if (!accumulate) {
                    grid[idx] = 1;
                    continue;
                }

                assert(grid[idx] != 0 and grid[idx] != inside);
                const vox = &voxels[rowmap[row] + @as(usize, grid[idx] - 1)];

                vox.coord = @as(u32, @bitCast(x)) << 20 | @as(u32, @bitCast(y)) << 10 |
                    @as(u32, @bitCast(z));
                const octant = (hx & 1) | ((hy & 1) << 1) | ((hz & 1) << 2);
                vox.octants |= @as(u8, 1) << @intCast(octant);

                vox.accumulate(px, py, pz, weight);

                if (with_quadrics) {
                    const distance = nx * px + ny * py + nz * pz;
                    vox.accumulateQuadric(nx, ny, nz, -distance, weight);
                }
            }
        }
    }
}

/// Numbers the occupied voxels of each row from 1 and returns how many
/// there are; `rowmap` receives each row's first voxel, or `empty_row`.
// Row loops go a vector at a time: Zig does not vectorize them by itself,
// as C compilers do the original's, and its memcmp is a vectorized library
// call.
const row_lanes = 32;
const RowChunk = @Vector(row_lanes, u8);

/// Whether `row` holds only zeros.
fn isEmptyRow(row: []const u8) bool {
    var i: usize = 0;
    while (i + row_lanes <= row.len) : (i += row_lanes) {
        const chunk: RowChunk = row[i..][0..row_lanes].*;
        if (@reduce(.Or, chunk) != 0) return false;
    }
    for (row[i..]) |d| {
        if (d != 0) return false;
    }
    return true;
}

fn rowpack(grid: []u8, rowmap: []u32, resolution: usize) usize {
    var result: usize = 0;

    for (rowmap, 0..) |*first, i| {
        const data = grid[i * resolution ..][0..resolution];

        // Marking empty rows speeds up everything after.
        if (isEmptyRow(data)) {
            first.* = empty_row;
            continue;
        }

        var count: u32 = 0;

        for (data) |*d| {
            // Voxelizing only writes 0 or 1.
            assert(d.* <= 1);

            count += d.*;
            d.* = if (d.* != 0) @intCast(count) else 0;
        }

        // A voxel's number is one byte, with 0 for empty voxels and
        // `inside` for interior ones.
        assert(count < inside);

        first.* = @intCast(result);
        result += count;
    }

    return result;
}

fn solidifyQueue(row: u32, worklist: []u32, queued: []u8, pending: *usize) void {
    if (queued[row] != 0) return;

    queued[row] = 1;
    worklist[pending.*] = row;
    pending.* += 1;
}

/// Marks the empty voxels of `data` as `inside`.
fn fillInside(data: []u8) void {
    const zeros: RowChunk = @splat(0);
    const insides: RowChunk = @splat(inside);
    var i: usize = 0;
    while (i + row_lanes <= data.len) : (i += row_lanes) {
        const d: RowChunk = data[i..][0..row_lanes].*;
        data[i..][0..row_lanes].* = @select(u8, d == zeros, insides, d);
    }
    for (data[i..]) |*d| d.* = if (d.* == 0) inside else d.*;
}

/// Clears each inside voxel of `next` whose voxel in `data` is empty, and
/// returns whether any was cleared.
fn spreadOutside(data: []const u8, next: []u8) bool {
    assert(data.len == next.len);
    const zeros: RowChunk = @splat(0);
    const insides: RowChunk = @splat(inside);
    var changed: RowChunk = zeros;
    var i: usize = 0;
    while (i + row_lanes <= data.len) : (i += row_lanes) {
        const d: RowChunk = data[i..][0..row_lanes].*;
        const n: RowChunk = next[i..][0..row_lanes].*;
        const rep = @select(u8, d == zeros, @select(u8, n == insides, zeros, n), n);
        changed |= rep ^ n;
        next[i..][0..row_lanes].* = rep;
    }
    var tail: u8 = 0;
    for (data[i..], next[i..]) |d, *n| {
        const rep: u8 = if (d == 0 and n.* == inside) 0 else n.*;
        tail |= rep ^ n.*;
        n.* = rep;
    }
    return (@reduce(.Or, changed) | tail) != 0;
}

/// Marks the empty voxels the grid's boundary cannot reach as `inside`.
fn solidify(
    grid: []u8,
    rowmap: []const u32,
    worklist: []u32,
    queued: []u8,
    resolution: usize,
) void {
    var pending: usize = 0;
    @memset(queued, 0);

    // Every interior empty voxel starts inside; the outside then spreads
    // from the boundary.
    for (1..resolution - 1) |z| {
        for (1..resolution - 1) |y| {
            // Rows without occupied voxels cut the spreading short and stay
            // empty.
            if (rowmap[y + resolution * z] == empty_row) continue;

            const data = grid[resolution * (y + resolution * z) ..][0..resolution];

            fillInside(data[1 .. resolution - 1]);
        }
    }

    // Every row is queued; boundary rows are always empty, but they spread
    // into their neighbors.
    for (0..resolution) |z| {
        for (0..resolution) |y| {
            solidifyQueue(@intCast(y + resolution * z), worklist, queued, &pending);
        }
    }

    while (pending > 0) {
        pending -= 1;
        const row = worklist[pending];
        assert(queued[row] != 0);
        queued[row] = 0;

        const data = grid[resolution * row ..][0..resolution];

        // The outside spreads along the row; rows without occupied voxels
        // have no inside voxels.
        if (rowmap[row] != empty_row) {
            for (1..resolution - 1) |x| {
                data[x] = if (data[x] == inside and data[x - 1] == 0) 0 else data[x];
            }

            var x = resolution - 2;
            while (x >= 1) : (x -= 1) {
                data[x] = if (data[x] == inside and data[x + 1] == 0) 0 else data[x];
            }
        }

        // The outside spreads into the neighboring rows.
        const y: i32 = @intCast(row % resolution);
        const z: i32 = @intCast(row / resolution);
        const last: i32 = @intCast(resolution - 1);

        for (0..4) |k| {
            const yn = y + @as(i32, if (k == 0) -1 else if (k == 1) 1 else 0);
            const zn = z + @as(i32, if (k == 2) -1 else if (k == 3) 1 else 0);

            if (yn < 1 or yn >= last or zn < 1 or zn >= last) continue;

            const neighbor = @as(usize, @intCast(yn)) + resolution * @as(usize, @intCast(zn));

            // Neighboring rows without occupied voxels have no inside voxels.
            if (rowmap[neighbor] == empty_row) continue;

            const datan = grid[resolution * neighbor ..][0..resolution];
            const changed = spreadOutside(data[1 .. resolution - 1], datan[1 .. resolution - 1]);
            if (changed) solidifyQueue(@intCast(neighbor), worklist, queued, &pending);
        }
    }
}

/// Gives each voxel its final position, in grid space.
fn solve(voxels: []Voxel, scale: f32, options: RemeshOptions) void {
    // Regularization trades the solve's stability and uniformity against
    // staying on the original surface.
    const factor: f32 = 3e-2;

    // A squared distance in model space; sqrt(3) / scale is the voxel's
    // diagonal.
    const cutoff = 3 / (scale * scale);
    const rscale = 1 / scale;

    for (voxels) |*vox| {
        var px = vox.px / vox.w;
        var py = vox.py / vox.w;
        var pz = vox.pz / vox.w;

        // The voxel's corner, for clamping and debug positions.
        const cx = @as(f32, @floatFromInt((vox.coord >> 20) & 1023)) * rscale;
        const cy = @as(f32, @floatFromInt((vox.coord >> 10) & 1023)) * rscale;
        const cz = @as(f32, @floatFromInt((vox.coord >> 0) & 1023)) * rscale;

        if (options.solve) {
            // The minimizing point, regularized for a stable solve.
            if (vox.solveQuadric(factor)) |s| {
                const sx, const sy, const sz = s;
                const d = (sx - px) * (sx - px) + (sy - py) * (sy - py) + (sz - pz) * (sz - pz);

                // A solution far from the centroid is rejected, a safety
                // net for when regularization falls short.
                if (d < cutoff) {
                    // Clamped to the voxel, to reduce intersections.
                    px = if (sx > cx) sx else cx;
                    px = if (px < cx + rscale) px else cx + rscale;
                    py = if (sy > cy) sy else cy;
                    py = if (py < cy + rscale) py else cy + rscale;
                    pz = if (sz > cz) sz else cz;
                    pz = if (pz < cz + rscale) pz else cz + rscale;
                }
            }
        }

        if (options.internal_debug) {
            px = cx + 0.5 * rscale;
            py = cy + 0.5 * rscale;
            pz = cz + 0.5 * rscale;
        }

        vox.px = px;
        vox.py = py;
        vox.pz = pz;
    }
}

/// The occupied voxel at corner `corner` of the cell at `x`, `y`, `z`.
fn cornerVoxel(
    x: usize,
    y: usize,
    z: usize,
    corner: u32,
    grid: []const u8,
    rowmap: []const u32,
    voxels: []const Voxel,
    resolution: usize,
) *const Voxel {
    const row = (y + ((corner >> 1) & 1)) + resolution * (z + ((corner >> 2) & 1));
    const idx = (x + (corner & 1)) + resolution * row;

    assert(grid[idx] != 0 and grid[idx] != inside);
    return &voxels[rowmap[row] + @as(usize, grid[idx] - 1)];
}

fn emitVertex(
    result: *[3]f32,
    x: usize,
    y: usize,
    z: usize,
    corner: u32,
    grid: []const u8,
    rowmap: []const u32,
    voxels: []const Voxel,
    resolution: usize,
    offset: [3]f32,
) void {
    const vox = cornerVoxel(x, y, z, corner, grid, rowmap, voxels, resolution);

    result.* = .{ vox.px + offset[0], vox.py + offset[1], vox.pz + offset[2] };
}

/// Whether the cell takes its alternate triangulation: when none of its
/// occupied corners' voxels has a sample in the octant inside the cell.
fn octantDecider(
    x: usize,
    y: usize,
    z: usize,
    cube: u32,
    grid: []const u8,
    rowmap: []const u32,
    voxels: []const Voxel,
    resolution: usize,
) bool {
    for (0..8) |c| {
        if (cube & (@as(u32, 1) << @intCast(c)) == 0) continue;

        const row = (y + ((c >> 1) & 1)) + resolution * (z + ((c >> 2) & 1));
        const idx = (x + (c & 1)) + resolution * row;

        assert(grid[idx] != 0);

        // Unlike vertex emission, which never reads an interior corner,
        // this sees corners without an occupied voxel, and skips them.
        if (grid[idx] == inside) continue;

        const vox = &voxels[rowmap[row] + @as(usize, grid[idx] - 1)];

        // The octant inside the cell is opposite the corner.
        if (vox.octants & (@as(u8, 1) << @intCast(7 - c)) != 0) return false;
    }

    return true;
}

/// Whether the quad cell takes its alternate diagonal: when it is clearly
/// closer to the surface by the corners' quadrics, and the primary is not
/// close enough already, so diagonals do not flip needlessly.
fn quadricDecider(
    x: usize,
    y: usize,
    z: usize,
    cube: u32,
    grid: []const u8,
    rowmap: []const u32,
    voxels: []const Voxel,
    resolution: usize,
    rscale: f32,
) bool {
    // A quad is encoded as the triangles 0xabc 0xcbd.
    const quad = @as(u32, tables.triangles[cube][0][0]) << 4 | (tables.triangles[cube][0][1] & 0xf);

    var corner: [4]*const Voxel = undefined;
    for (&corner, 0..) |*v, i| {
        const c = (quad >> @intCast(12 - i * 4)) & 0xf;
        v.* = cornerVoxel(x, y, z, c, grid, rowmap, voxels, resolution);
    }

    // The four corners' quadrics, summed as (a + d) + (b + c) to get the
    // same result on both sides of thin sheets.
    const va, const vb, const vc, const vd = corner;

    var sum: Voxel = .{};
    sum.a00 = (va.a00 + vd.a00) + (vb.a00 + vc.a00);
    sum.a11 = (va.a11 + vd.a11) + (vb.a11 + vc.a11);
    sum.a22 = (va.a22 + vd.a22) + (vb.a22 + vc.a22);
    sum.a10 = (va.a10 + vd.a10) + (vb.a10 + vc.a10);
    sum.a20 = (va.a20 + vd.a20) + (vb.a20 + vc.a20);
    sum.a21 = (va.a21 + vd.a21) + (vb.a21 + vc.a21);
    sum.b0 = (va.b0 + vd.b0) + (vb.b0 + vc.b0);
    sum.b1 = (va.b1 + vd.b1) + (vb.b1 + vc.b1);
    sum.b2 = (va.b2 + vd.b2) + (vb.b2 + vc.b2);
    sum.c = (va.c + vd.c) + (vb.c + vc.c);
    sum.w = (va.w + vd.w) + (vb.w + vc.w);

    // The errors at the midpoints of the primary (bc) and alternate (ad)
    // diagonals.
    const error0 = sum.quadricError(
        (vb.px + vc.px) * 0.5,
        (vb.py + vc.py) * 0.5,
        (vb.pz + vc.pz) * 0.5,
    );
    const error1 = sum.quadricError(
        (va.px + vd.px) * 0.5,
        (va.py + vd.py) * 0.5,
        (va.pz + vd.pz) * 0.5,
    );

    const tenth: f32 = 0.1;
    const keep: f32 = 0.85;
    return error0 > sum.w * (tenth * tenth * rscale * rscale) and error1 < error0 * (keep * keep);
}

/// Triangulates every cell of the grid. With `emit`, writes the first
/// `max_triangle_count` triangles to `destination` and counts all of them;
/// without it, counts each cell's primary triangulation only, an upper
/// bound.
fn polygonize(
    comptime emit: bool,
    destination: []f32,
    max_triangle_count: usize,
    grid: []const u8,
    rowmap: []const u32,
    voxels: []const Voxel,
    resolution: usize,
    scale: f32,
    offset: [3]f32,
    options: RemeshOptions,
) usize {
    var result: usize = 0;
    const slice = resolution * resolution;
    const rscale = 1 / scale;

    for (0..resolution - 1) |z| {
        for (0..resolution - 1) |y| {
            const row = y + resolution * z;

            // Four empty rows give no triangles (three would do, but cost
            // more to check).
            const rows = rowmap[row] & rowmap[row + 1] & rowmap[row + resolution] &
                rowmap[row + resolution + 1];
            if (rows == empty_row) continue;

            const data = grid[resolution * row ..];

            // Each slice of the row is an 8-bit code, in cube order, so each
            // voxel is read once.
            var last = sliceCode(data, 0, resolution, slice);

            for (0..resolution - 1) |x| {
                const next = sliceCode(data, x + 1, resolution, slice);

                // The next slice's bits are in place for the next step; shifted,
                // they complete this cube's code.
                const cube = last | (next << 1);
                last = next;

                if (cube == 0 or cube == 0xff) continue;

                if (!emit) {
                    // Each cube's primary triangulation bounds its output.
                    result += tables.count[cube];
                    continue;
                }

                // Deciders run only for cells with an alternate.
                var alt: usize = 0;

                if (tables.alt[cube] == 1) {
                    const pick = octantDecider(x, y, z, cube, grid, rowmap, voxels, resolution);
                    alt = @intFromBool(pick);
                } else if (tables.alt[cube] == 2 and options.solve) {
                    const pick = quadricDecider(
                        x,
                        y,
                        z,
                        cube,
                        grid,
                        rowmap,
                        voxels,
                        resolution,
                        rscale,
                    );
                    alt = @intFromBool(pick);
                }

                for (tables.triangles[cube][alt]) |tri| {
                    if (tri == 0) break;

                    // Triangles past the capacity are counted all the same,
                    // so the count is the whole output's.
                    if (result < max_triangle_count) {
                        const out = destination[result * 9 ..][0..9];
                        const corners = [3]u32{ (tri >> 8) & 0xf, (tri >> 4) & 0xf, tri & 0xf };
                        for (corners, 0..) |corner, k| {
                            emitVertex(
                                out[k * 3 ..][0..3],
                                x,
                                y,
                                z,
                                corner,
                                grid,
                                rowmap,
                                voxels,
                                resolution,
                                offset,
                            );
                        }
                    }

                    result += 1;
                }
            }
        }
    }

    return result;
}

/// The occupancy of the four voxels at `x` in a row, the row after it, and
/// the same two in the next slice, as the bits 0, 2, 4 and 6.
inline fn sliceCode(data: []const u8, x: usize, resolution: usize, slice: usize) u32 {
    return @as(u32, @intFromBool(data[x] != 0)) |
        @as(u32, @intFromBool(data[x + resolution] != 0)) << 2 |
        @as(u32, @intFromBool(data[x + slice] != 0)) << 4 |
        @as(u32, @intFromBool(data[x + slice + resolution] != 0)) << 6;
}

/// Builds a new mesh that approximates the triangles `indices` over
/// `positions` at a voxel grid of `resolution` (4 to 256) voxels a side,
/// and returns its triangle count. Its look is kept at that resolution but
/// not its topology: features closer than a voxel may merge, and small gaps
/// may close.
///
/// `destination` receives the triangles as 9 floats each, three corner
/// positions, for as many as it holds (`destination.len / 9`). With
/// `destination` null, nothing is built and the count returned is an upper
/// bound, for sizing `destination`; otherwise it is the whole mesh's,
/// written or not.
pub fn remesh(
    gpa: Allocator,
    destination: ?[]f32,
    indices: []const u32,
    positions: VertexFloats,
    resolution: u32,
    options: RemeshOptions,
) Allocator.Error!usize {
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);
    assert(resolution >= 4 and resolution <= 256);

    const size: usize = resolution;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    // The grid's place, mapping positions to voxels.
    var offset: [3]f32 = @splat(0);
    const scale = measureGrid(positions, resolution, &offset);

    // The first pass only tags the voxels triangles cross.
    const grid = try scratch.alloc(u8, size * size * size);
    @memset(grid, 0);

    voxelize(false, false, grid, &.{}, &.{}, indices, positions, size, scale, offset);

    // Each row's first voxel; empty rows are marked, to skip them after.
    const rowmap = try scratch.alloc(u32, size * size);
    const voxel_count = rowpack(grid, rowmap, size);

    // Each occupied voxel's data, filled by the second pass; counting skips
    // it.
    var voxels: []Voxel = &.{};

    if (destination != null) {
        voxels = try scratch.alloc(Voxel, voxel_count);
        @memset(voxels, .{});
    }

    // The empty voxels the boundary cannot reach become inside voxels;
    // they have no voxel data, as no triangle crossed them.
    if (!options.shell) {
        const worklist = try scratch.alloc(u32, size * size);
        const queued = try scratch.alloc(u8, size * size);

        solidify(grid, rowmap, worklist, queued, size);
    }

    const out = destination orelse
        return polygonize(false, &.{}, 0, grid, rowmap, voxels, size, scale, offset, options);

    // The second pass gathers what each voxel needs for its position.
    if (options.solve) {
        voxelize(true, true, grid, rowmap, voxels, indices, positions, size, scale, offset);
    } else {
        voxelize(true, false, grid, rowmap, voxels, indices, positions, size, scale, offset);
    }

    // One position per voxel, for every triangle corner on it.
    solve(voxels, scale, options);

    const max_triangle_count = out.len / 9;
    return polygonize(
        true,
        out,
        max_triangle_count,
        grid,
        rowmap,
        voxels,
        size,
        scale,
        offset,
        options,
    );
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "every cube case has a triangulation" {
    // The rotations reach every case; a cell with all corners set or none
    // has no triangles.
    try testing.expectEqual(0, tables.count[0]);
    try testing.expectEqual(0, tables.count[0xff]);
    for (base_cases) |c| try testing.expectEqual(c.triangles.len, tables.count[c.code]);
}

test "options keep the original's bits" {
    try testing.expectEqual(1, @backingInt(RemeshOptions{ .shell = true }));
    try testing.expectEqual(2, @backingInt(RemeshOptions{ .solve = true }));
    try testing.expectEqual(1 << 30, @backingInt(RemeshOptions{ .internal_debug = true }));
}

test "a cube remeshes into a closed mesh" {
    const positions = [_]f32{
        0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0,
        0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1,
    };
    const indices = [_]u32{
        0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6,
        0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7,
        0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5,
    };
    const view: VertexFloats = .init(&positions, 3);
    const bound = try remesh(testing.allocator, null, &indices, view, 8, .{});
    const triangles = try testing.allocator.alloc(f32, bound * 9);
    defer testing.allocator.free(triangles);
    const count = try remesh(testing.allocator, triangles, &indices, view, 8, .{});
    try testing.expect(count > 0 and count <= bound);
}
