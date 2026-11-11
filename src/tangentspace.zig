//! Tangent space and normal generation: a tangent and orientation for every
//! triangle corner from texture coordinates, and normals for every corner
//! from positions alone, averaged across soft edges.
//!
//! Translated from meshoptimizer's tangentspace.cpp (normal generation is
//! experimental in the original), which builds on Mikkelsen, "Simulation of
//! Wrinkled Surfaces Revisited" (2008); Teschner et al., "Optimized Spatial
//! Hashing for Collision Detection of Deformable Objects" (2003); and
//! Hastings, "Approximations for Digital Computers" (1955).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const VertexFloats = @import("strided.zig").VertexFloats;
const indexgenerator = @import("indexgenerator.zig");
const hashBuckets = indexgenerator.hashBuckets;
const hashLookup = indexgenerator.hashLookup;
const truncate = @import("convert.zig").truncate;

/// How `generateTangents` weighs and falls back. Each field is the bit of
/// the original's `meshopt_Tangent` flag of the same name.
pub const TangentOptions = packed struct(u32) {
    /// Tangents compatible with MikkTSpace, the same weighting and
    /// fallbacks, at a cost in quality; only for normal maps baked that way.
    compatible: bool = false,
    /// Zero tangents for vertices whose triangles are all degenerate,
    /// instead of an arbitrary fallback.
    zero_fallback: bool = false,
    reserved: u30 = 0,
};

const none = std.math.maxInt(u32);

/// The corner after each corner of a triangle, and the one after that.
const next = [4]u32{ 1, 2, 0, 1 };

const Tangent = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

const Normal = struct {
    x: f32,
    y: f32,
    z: f32,
    /// 1 for a triangle with an area, 0 for a degenerate one.
    id: i32,
};

/// The vertex of corner `corner`.
inline fn vertexOf(indices: ?[]const u32, corner: usize) u32 {
    return if (indices) |list| list[corner] else @intCast(corner);
}

fn computeFaceTangents(
    result: []Tangent,
    indices: ?[]const u32,
    positions: VertexFloats,
    uvs: VertexFloats,
) void {
    for (result, 0..) |*tangent, i| {
        const a = vertexOf(indices, i * 3 + 0);
        const b = vertexOf(indices, i * 3 + 1);
        const c = vertexOf(indices, i * 3 + 2);

        const pa = positions.vec3(a);
        const pb = positions.vec3(b);
        const pc = positions.vec3(c);

        const ta = uvs.at(a)[0..2];
        const tb = uvs.at(b)[0..2];
        const tc = uvs.at(c)[0..2];

        // The face tangent by the chain rule, equation 42.
        const dp1x = pb[0] - pa[0];
        const dp1y = pb[1] - pa[1];
        const dp1z = pb[2] - pa[2];
        const dp2x = pc[0] - pa[0];
        const dp2y = pc[1] - pa[1];
        const dp2z = pc[2] - pa[2];
        const dt1x = tb[0] - ta[0];
        const dt1y = tb[1] - ta[1];
        const dt2x = tc[0] - ta[0];
        const dt2y = tc[1] - ta[1];

        const rx = dt2y * dp1x - dt1y * dp2x;
        const ry = dt2y * dp1y - dt1y * dp2y;
        const rz = dt2y * dp1z - dt1y * dp2z;

        // .w is the orientation (+1 or -1), or 0 for degenerate triangles,
        // equation 48.
        const det = dt1x * dt2y - dt1y * dt2x;
        var rw: f32 = if (det == 0) 0 else if (det > 0) 1 else -1;

        // Triangles without area are degenerate even if their texture
        // coordinates are not, for consistency.
        rw = if (pa[0] == pb[0] and pa[1] == pb[1] and pa[2] == pb[2]) 0 else rw;
        rw = if (pa[0] == pc[0] and pa[1] == pc[1] and pa[2] == pc[2]) 0 else rw;
        rw = if (pb[0] == pc[0] and pb[1] == pc[1] and pb[2] == pc[2]) 0 else rw;

        const rl = @sqrt(rx * rx + ry * ry + rz * rz);
        const rs = if (rl != 0) rw / rl else 0;

        tangent.* = .{ .x = rx * rs, .y = ry * rs, .z = rz * rs, .w = rw };
    }
}

fn computeFaceNormals(result: []Normal, indices: ?[]const u32, positions: VertexFloats) void {
    for (result, 0..) |*normal, i| {
        const pa = positions.vec3(vertexOf(indices, i * 3 + 0));
        const pb = positions.vec3(vertexOf(indices, i * 3 + 1));
        const pc = positions.vec3(vertexOf(indices, i * 3 + 2));

        const dp1x = pb[0] - pa[0];
        const dp1y = pb[1] - pa[1];
        const dp1z = pb[2] - pa[2];
        const dp2x = pc[0] - pa[0];
        const dp2y = pc[1] - pa[1];
        const dp2z = pc[2] - pa[2];

        const nx = dp1y * dp2z - dp1z * dp2y;
        const ny = dp1z * dp2x - dp1x * dp2z;
        const nz = dp1x * dp2y - dp1y * dp2x;

        const nl = @sqrt(nx * nx + ny * ny + nz * nz);
        const ns = if (nl != 0) 1 / nl else 0;

        normal.* = .{ .x = nx * ns, .y = ny * ns, .z = nz * ns, .id = @intFromBool(nl != 0) };
    }
}

/// Vertices hash by position, and also normal and texture coordinate
/// unless `position_only`, compared as floats (so -0 matches 0, and NaN
/// matches nothing).
fn VertexHasher(comptime position_only: bool) type {
    return struct {
        positions: VertexFloats,
        normals: VertexFloats,
        uvs: VertexFloats,

        const Self = @This();

        pub fn hash(self: Self, index: u32) u32 {
            const p: [3]u32 = @bitCast(self.positions.vec3(index));
            var x, var y, var z = p;

            // Negative zero hashes as zero.
            x = if (x == 0x80000000) 0 else x;
            y = if (y == 0x80000000) 0 else y;
            z = if (z == 0x80000000) 0 else z;

            // Scramble the bits so integer coordinates have entropy in the
            // lower bits.
            x ^= x >> 17;
            y ^= y >> 17;
            z ^= z >> 17;

            if (position_only) return (x *% 73856093) ^ (y *% 19349663) ^ (z *% 83492791);

            const n: [3]u32 = @bitCast(self.normals.vec3(index));
            const t: [2]u32 = @bitCast(self.uvs.at(index)[0..2].*);

            // Mix in the normal's bits.
            x ^= if (n[0] == 0x80000000) 0 else n[0] >> 15;
            y ^= if (n[1] == 0x80000000) 0 else n[1] >> 15;
            z ^= if (n[2] == 0x80000000) 0 else n[2] >> 15;

            // The texture coordinate's bits, with simpler -0 handling and
            // scrambling.
            var w = (t[0] ^ t[1]) & 0x7fffffff;
            w ^= w >> 13;

            return (x *% 73856093) ^ (y *% 19349663) ^ (z *% 83492791) ^ (w *% 50331653);
        }

        pub fn equal(self: Self, lhs: u32, rhs: u32) bool {
            const lp = self.positions.vec3(lhs);
            const rp = self.positions.vec3(rhs);

            if (position_only) return lp[0] == rp[0] and lp[1] == rp[1] and lp[2] == rp[2];

            const ln = self.normals.vec3(lhs);
            const lt = self.uvs.at(lhs)[0..2];
            const rn = self.normals.vec3(rhs);
            const rt = self.uvs.at(rhs)[0..2];

            return lp[0] == rp[0] and lp[1] == rp[1] and lp[2] == rp[2] and
                ln[0] == rn[0] and ln[1] == rn[1] and ln[2] == rn[2] and
                lt[0] == rt[0] and lt[1] == rt[1];
        }
    };
}

/// Maps each vertex to the first vertex equal to it.
fn buildVertexRemap(scratch: *Scratch, remap: []u32, hasher: anytype) !void {
    const vertex_table = try scratch.alloc(u32, hashBuckets(remap.len));
    @memset(vertex_table, none);

    for (remap, 0..) |*r, i| {
        const index: u32 = @intCast(i);
        const entry = hashLookup(u32, vertex_table, hasher, index, none);

        if (vertex_table[entry] == none) vertex_table[entry] = index;

        r.* = vertex_table[entry];
    }

    scratch.free(vertex_table);
}

/// The corners around each unique vertex: vertex `v`'s are
/// `data[offsets[v]..offsets[v + 1]]`, each a triangle index shifted left
/// by 2 with the corner in the low bits.
const CornerAdjacency = struct {
    offsets: []u32,
    data: []u32,
};

fn buildCornerAdjacency(
    scratch: *Scratch,
    indices: ?[]const u32,
    index_count: usize,
    remap: []const u32,
) !CornerAdjacency {
    const vertex_count = remap.len;
    const adjacency: CornerAdjacency = .{
        .offsets = try scratch.alloc(u32, vertex_count + 1),
        .data = try scratch.alloc(u32, index_count),
    };

    const face_count = index_count / 3;
    const offsets = adjacency.offsets[1..];

    // Corner counts.
    @memset(offsets, 0);

    for (0..index_count) |i| {
        const v = remap[vertexOf(indices, i)];
        assert(v < vertex_count);

        offsets[v] += 1;
    }

    // The offset table.
    var offset: u32 = 0;

    for (offsets) |*o| {
        const count = o.*;
        o.* = offset;
        offset += count;
    }

    assert(offset == index_count);

    // The corners.
    for (0..face_count) |i| {
        const a = remap[vertexOf(indices, i * 3 + 0)];
        const b = remap[vertexOf(indices, i * 3 + 1)];
        const c = remap[vertexOf(indices, i * 3 + 2)];
        const triangle: u32 = @intCast(i << 2);

        adjacency.data[offsets[a]] = triangle | 0;
        offsets[a] += 1;
        adjacency.data[offsets[b]] = triangle | 1;
        offsets[b] += 1;
        adjacency.data[offsets[c]] = triangle | 2;
        offsets[c] += 1;
    }

    // Each offset moved to the next vertex's start.
    adjacency.offsets[0] = 0;
    assert(adjacency.offsets[vertex_count] == index_count);

    return adjacency;
}

/// The root of `index`'s set, halving the path on the way.
fn follow2(parents: []u32, start: u32) u32 {
    var index = start;
    while (index != parents[index]) {
        const parent = parents[index];
        parents[index] = parents[parent];
        index = parent;
    }

    return index;
}

/// Merges the tangent groups of the corners `data` around one vertex.
fn mergeTangentGroups(
    groups: []u32,
    facegroups: []u32,
    facesign: []u8,
    data: []const u32,
    indices: ?[]const u32,
    remap: []const u32,
) void {
    for (data, 0..) |di, i| {
        const ti = di >> 2;
        const cib = ti * 3 + next[(di & 3) + 0];
        const cic = ti * 3 + next[(di & 3) + 1];

        const nib = remap[vertexOf(indices, cib)];
        const nic = remap[vertexOf(indices, cic)];

        for (data[i + 1 ..]) |dj| {
            const tj = dj >> 2;
            const cjb = tj * 3 + next[(dj & 3) + 0];
            const cjc = tj * 3 + next[(dj & 3) + 1];

            const njb = remap[vertexOf(indices, cjb)];
            const njc = remap[vertexOf(indices, cjc)];

            // Adjacent triangles merge when their orientations agree or
            // either is degenerate.
            if ((njb == nic or njc == nib) and (facesign[ti] | facesign[tj]) != 3) {
                // A degenerate triangle may have taken an orientation
                // already; the face groups know.
                if ((facesign[ti] & facesign[tj]) == 0) {
                    const gti = follow2(facegroups, ti);
                    const gtj = follow2(facegroups, tj);

                    // Diverging orientations do not merge; otherwise the
                    // groups join under gti.
                    if (gti != gtj) {
                        if ((facesign[gti] | facesign[gtj]) == 3) continue;

                        facegroups[gtj] = gti;
                        facesign[gti] |= facesign[gtj];
                    }
                }

                // The corners' groups join under gi; the face groups
                // above make their orientations match.
                const gi = follow2(groups, ti * 3 + (di & 3));
                const gj = follow2(groups, tj * 3 + (dj & 3));

                if (gi != gj) groups[gj] = gi;
            }
        }
    }
}

/// Merges the normal groups of the corners `data` around one vertex.
fn mergeNormalGroups(
    groups: []u32,
    data: []const u32,
    indices: ?[]const u32,
    remap: []const u32,
    face_normals: []const Normal,
    crease_cutoff: f32,
) void {
    for (data, 0..) |di, i| {
        const ti = di >> 2;
        const ci = ti * 3 + (di & 3);

        const cib = ti * 3 + next[(di & 3) + 0];
        const cic = ti * 3 + next[(di & 3) + 1];

        const nib = remap[vertexOf(indices, cib)];
        const nic = remap[vertexOf(indices, cic)];

        const fi = face_normals[ti];

        for (data[i + 1 ..]) |dj| {
            const tj = dj >> 2;
            const cj = tj * 3 + (dj & 3);

            const cjb = tj * 3 + next[(dj & 3) + 0];
            const cjc = tj * 3 + next[(dj & 3) + 1];

            const njb = remap[vertexOf(indices, cjb)];
            const njc = remap[vertexOf(indices, cjc)];

            const fj = face_normals[tj];

            const adjacent = njb == nic or njc == nib;
            const dot = fi.x * fj.x + fi.y * fj.y + fi.z * fj.z;

            // Adjacent triangles with areas merge when the angle between
            // them is below the crease.
            if (adjacent and dot > crease_cutoff and fi.id == fj.id and fi.id != 0) {
                // The corners' groups join under gi.
                const gi = follow2(groups, ci);
                const gj = follow2(groups, cj);

                if (gi != gj) groups[gj] = gi;
            } else if (adjacent and (fi.id == 0) != (fj.id == 0)) {
                // A degenerate triangle's corners join the first adjacent
                // group with an area, so no degenerate bridge joins two
                // triangles with areas.
                const cd = if (fi.id != 0) cj else ci;
                const cn = if (fi.id != 0) ci else cj;

                if (groups[cd] == cd) groups[cd] = follow2(groups, cn);
            }
        }
    }
}

/// acos(x) as sqrt(1 - |x|) times a 2-degree polynomial, within 5e-4;
/// clamps `x` to [-1, 1].
inline fn optacos(x: f32) f32 {
    var ax = @abs(x);
    ax = if (ax > 1) 1 else ax;
    var r = 1.570337 + ax * (-0.2053972 + ax * 0.05147786);
    r *= @sqrt(1.0 - ax);
    return if (x < 0) 3.1415926 - r else r;
}

fn accumulateTangents(
    result: []f32,
    groups: []const u32,
    indices: ?[]const u32,
    face_tangents: []const Tangent,
    positions: VertexFloats,
    normals: VertexFloats,
    options: TangentOptions,
) void {
    for (face_tangents, 0..) |t, i| {
        if (t.w == 0) continue;

        for (0..3) |k| {
            const r = result[@as(usize, groups[i * 3 + k]) * 4 ..][0..3];

            const a = vertexOf(indices, i * 3 + k);
            const b = vertexOf(indices, i * 3 + next[k]);
            const c = vertexOf(indices, i * 3 + next[k + 1]);

            const pa = positions.vec3(a);
            const pb = positions.vec3(b);
            const pc = positions.vec3(c);

            const n = normals.vec3(a);

            // The tangent projected onto the vertex normal's plane.
            const sd = t.x * n[0] + t.y * n[1] + t.z * n[2];
            const sx = t.x - n[0] * sd;
            const sy = t.y - n[1] * sd;
            const sz = t.z - n[2] * sd;
            const sl = @sqrt(sx * sx + sy * sy + sz * sz);

            // The corner's angle in the tangent plane, for weighting; the
            // paper has no such step, and its reference implementation
            // projects the edges to the tangent plane first.
            var dp1x = pb[0] - pa[0];
            var dp1y = pb[1] - pa[1];
            var dp1z = pb[2] - pa[2];
            var dp2x = pc[0] - pa[0];
            var dp2y = pc[1] - pa[1];
            var dp2z = pc[2] - pa[2];

            const dp1d = dp1x * n[0] + dp1y * n[1] + dp1z * n[2];
            const dp2d = dp2x * n[0] + dp2y * n[1] + dp2z * n[2];

            dp1x -= n[0] * dp1d;
            dp1y -= n[1] * dp1d;
            dp1z -= n[2] * dp1d;
            dp2x -= n[0] * dp2d;
            dp2y -= n[1] * dp2d;
            dp2z -= n[2] * dp2d;

            const dp1l = dp1x * dp1x + dp1y * dp1y + dp1z * dp1z;
            const dp2l = dp2x * dp2x + dp2y * dp2y + dp2z * dp2z;
            const dpl = @sqrt(dp1l * dp2l);

            const cosa = (dp1x * dp2x + dp1y * dp2y + dp1z * dp2z) * (if (dpl == 0) 0 else 1 / dpl);
            const angle = optacos(cosa);

            // The renormalized tangent, weighted by the angle.
            var w = angle * (if (sl == 0) 0 else 1 / sl);

            // Larger triangles weigh more, against interpolation artifacts
            // from slivers; the reference implementation does not, at a
            // cost in quality.
            if (!options.compatible) w *= dpl;

            r[0] += sx * w;
            r[1] += sy * w;
            r[2] += sz * w;
        }
    }
}

fn accumulateNormals(
    result: []f32,
    groups: []const u32,
    indices: ?[]const u32,
    face_normals: []const Normal,
    positions: VertexFloats,
) void {
    for (face_normals, 0..) |n, i| {
        for (0..3) |k| {
            const r = result[@as(usize, groups[i * 3 + k]) * 3 ..][0..3];

            const pa = positions.vec3(vertexOf(indices, i * 3 + k));
            const pb = positions.vec3(vertexOf(indices, i * 3 + next[k]));
            const pc = positions.vec3(vertexOf(indices, i * 3 + next[k + 1]));

            // The corner's angle, for weighting.
            const dp1x = pb[0] - pa[0];
            const dp1y = pb[1] - pa[1];
            const dp1z = pb[2] - pa[2];
            const dp2x = pc[0] - pa[0];
            const dp2y = pc[1] - pa[1];
            const dp2z = pc[2] - pa[2];

            const dp1l = dp1x * dp1x + dp1y * dp1y + dp1z * dp1z;
            const dp2l = dp2x * dp2x + dp2y * dp2y + dp2z * dp2z;
            const dpl = @sqrt(dp1l * dp2l);

            const cosa = (dp1x * dp2x + dp1y * dp2y + dp1z * dp2z) * (if (dpl == 0) 0 else 1 / dpl);
            const angle = optacos(cosa);

            // Weighted by the angle and the product of the edge lengths, as
            // tangents are by default.
            const w = angle * dpl;

            r[0] += n.x * w;
            r[1] += n.y * w;
            r[2] += n.z * w;
        }
    }
}

/// Moves each group's normal towards its neighbors' by `alpha` of the
/// average difference, weighted by alignment, and renormalizes it.
fn smoothNormals(
    result: []f32,
    deltas: []f32,
    groups: []const u32,
    face_normals: []const Normal,
    alpha: f32,
) void {
    @memset(deltas, 0);

    // Each triangle adds the normal differences along its edges, both ways.
    for (face_normals, 0..) |normal, i| {
        // Degenerate triangles may join groups across hard edges.
        if (normal.id == 0) continue;

        for (0..3) |k| {
            const ga: usize = groups[i * 3 + k];
            const gb: usize = groups[i * 3 + next[k]];

            const na = result[ga * 3 ..][0..3];
            const nb = result[gb * 3 ..][0..3];

            // Alignment is symmetric, so it is computed once per edge; its
            // square aligns more strongly.
            const dp = na[0] * nb[0] + na[1] * nb[1] + na[2] * nb[2];
            const w = if (dp > 0) dp * dp else 0;

            const nx = (nb[0] - na[0]) * w;
            const ny = (nb[1] - na[1]) * w;
            const nz = (nb[2] - na[2]) * w;

            // The differences, and in the last float their count, for the
            // average below. The two may be the same group.
            deltas[ga * 4 + 0] += nx;
            deltas[ga * 4 + 1] += ny;
            deltas[ga * 4 + 2] += nz;
            deltas[ga * 4 + 3] += 1;

            deltas[gb * 4 + 0] -= nx;
            deltas[gb * 4 + 1] -= ny;
            deltas[gb * 4 + 2] -= nz;
            deltas[gb * 4 + 3] += 1;
        }
    }

    // The average difference goes to each group root, renormalized.
    for (groups, 0..) |group, i| {
        if (group != i or !(deltas[i * 4 + 3] > 0)) continue;

        const r = result[i * 3 ..][0..3];
        const s = deltas[i * 4 ..][0..4];

        const sw = alpha / s[3];
        const rx = r[0] + s[0] * sw;
        const ry = r[1] + s[1] * sw;
        const rz = r[2] + s[2] * sw;

        const rl = @sqrt(rx * rx + ry * ry + rz * rz);
        const rs = if (rl == 0) 0 else 1 / rl;

        r.* = .{ rx * rs, ry * rs, rz * rs };
    }
}

/// Writes to `result` a tangent for every triangle corner: the normalized
/// tangent (x, y, z) and its orientation (w, +1 or -1), 4 floats each, so
/// `result` holds at least 4 floats per corner. The bitangent is
/// `cross(normal, tangent.xyz) * tangent.w`.
///
/// To apply them, deindex the mesh and index it again with the tangents,
/// or copy them to the vertices, duplicating those with different tangents
/// (on texture mirror seams, for example). With `indices` null, every
/// vertex is a corner; indexing does not change the tangents, but indexed
/// meshes are faster. `normals` are unit normals, and `uvs` texture
/// coordinates (2 floats), for every vertex of `positions`.
pub fn generateTangents(
    gpa: Allocator,
    result: []f32,
    indices: ?[]const u32,
    positions: VertexFloats,
    normals: VertexFloats,
    uvs: VertexFloats,
    options: TangentOptions,
) Allocator.Error!void {
    const vertex_count = positions.count();
    const index_count = if (indices) |list| list.len else vertex_count;
    assert(index_count % 3 == 0);
    // The corner adjacency keeps triangle indices in 30 bits.
    assert(index_count < 3 << 30);
    assert(positions.stride >= 3 and positions.stride <= 64);
    assert(normals.stride >= 3 and normals.stride <= 64);
    assert(uvs.stride >= 2 and uvs.stride <= 64);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const face_count = index_count / 3;

    // Each vertex mapped to its first equal vertex.
    const remap = try scratch.alloc(u32, vertex_count);
    const hasher: VertexHasher(false) = .{ .positions = positions, .normals = normals, .uvs = uvs };
    try buildVertexRemap(&scratch, remap, hasher);

    const adjacency = try buildCornerAdjacency(&scratch, indices, index_count, remap);

    const face_tangents = try scratch.alloc(Tangent, face_count);
    computeFaceTangents(face_tangents, indices, positions, uvs);

    // Corner tangent groups: triangles around a vertex with the same
    // orientation merge in strips.
    const groups = try scratch.alloc(u32, index_count);
    for (groups, 0..) |*g, i| g.* = @intCast(i);

    // Face orientation groups: degenerate triangles merge with adjacent
    // ones that have an area, and take their orientation, as a bitmask.
    const facegroups = try scratch.alloc(u32, face_count);
    const facesign = try scratch.alloc(u8, face_count);

    for (facegroups, facesign, face_tangents, 0..) |*group, *sign, tangent, i| {
        group.* = @intCast(i);
        sign.* = @as(u8, @intFromBool(tangent.w > 0)) | @as(u8, @intFromBool(tangent.w < 0)) << 1;
    }

    for (0..vertex_count) |i| {
        const corners = adjacency.data[adjacency.offsets[i]..adjacency.offsets[i + 1]];
        if (corners.len > 0) {
            mergeTangentGroups(groups, facegroups, facesign, corners, indices, remap);
        }
    }

    for (0..index_count) |i| groups[i] = follow2(groups, @intCast(i));

    // Each group gathers its tangents.
    @memset(result[0 .. index_count * 4], 0);
    accumulateTangents(result, groups, indices, face_tangents, positions, normals, options);

    // Each face's sign from its face group.
    for (0..face_count) |i| {
        const fg = follow2(facegroups, @intCast(i));
        // A degenerate face's sign is -1, for consistency.
        const w: f32 = if (facesign[fg] & 1 != 0) 1 else -1;

        result[(i * 3 + 0) * 4 + 3] = w;
        result[(i * 3 + 1) * 4 + 3] = w;
        result[(i * 3 + 2) * 4 + 3] = w;
    }

    // Group roots normalized, then copied to the other corners.
    for (groups, 0..) |group, i| {
        if (group != i) continue;

        const r = result[i * 4 ..][0..3];
        const l = @sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
        const s = if (l == 0) 0 else 1 / l;

        r[0] *= s;
        r[1] *= s;
        r[2] *= s;

        // Isolated degenerate triangles get the tangent (1, 0, 0), for
        // consistency.
        r[0] = if (l == 0 and !options.zero_fallback) 1 else r[0];
    }

    for (groups, 0..) |group, i| {
        // .w was set per face above.
        if (group != i) result[i * 4 ..][0..3].* = result[@as(usize, group) * 4 ..][0..3].*;
    }
}

/// Writes to `result` a normal for every triangle corner, 3 floats each,
/// so `result` holds at least 3 floats per corner. Normals average across
/// soft edges: an edge is soft when the angle between its triangles is
/// below `crease_angle`, in radians from 0 to pi.
///
/// `smoothing` (at least 0, best up to 5) smooths the normals afterwards,
/// a pass for each whole unit and a partial pass for the rest, up to 10
/// passes. To apply the normals, deindex the mesh and index it again with
/// them, or copy them to the vertices, duplicating those on normal seams.
/// With `indices` null, every vertex is a corner; indexing does not change
/// the normals, but indexed meshes are faster.
pub fn generateNormals(
    gpa: Allocator,
    result: []f32,
    indices: ?[]const u32,
    positions: VertexFloats,
    crease_angle: f32,
    smoothing: f32,
) Allocator.Error!void {
    const vertex_count = positions.count();
    const index_count = if (indices) |list| list.len else vertex_count;
    assert(index_count % 3 == 0);
    // The corner adjacency keeps triangle indices in 30 bits.
    assert(index_count < 3 << 30);
    assert(positions.stride >= 3 and positions.stride <= 64);
    assert(crease_angle >= 0 and crease_angle <= 3.1415927);
    assert(smoothing >= 0);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const face_count = index_count / 3;
    const crease_cutoff = cosf(crease_angle);

    // Each vertex mapped to its first vertex at the same position.
    const remap = try scratch.alloc(u32, vertex_count);
    // Only positions are read.
    const hasher: VertexHasher(true) = .{
        .positions = positions,
        .normals = positions,
        .uvs = positions,
    };
    try buildVertexRemap(&scratch, remap, hasher);

    const adjacency = try buildCornerAdjacency(&scratch, indices, index_count, remap);

    const face_normals = try scratch.alloc(Normal, face_count);
    computeFaceNormals(face_normals, indices, positions);

    // Corner normal groups: triangles around a vertex with similar normals
    // merge in strips.
    const groups = try scratch.alloc(u32, index_count);
    for (groups, 0..) |*g, i| g.* = @intCast(i);

    for (0..vertex_count) |i| {
        const corners = adjacency.data[adjacency.offsets[i]..adjacency.offsets[i + 1]];
        if (corners.len > 0) {
            mergeNormalGroups(groups, corners, indices, remap, face_normals, crease_cutoff);
        }
    }

    for (0..index_count) |i| groups[i] = follow2(groups, @intCast(i));

    // Each group gathers its normals.
    @memset(result[0 .. index_count * 3], 0);
    accumulateNormals(result, groups, indices, face_normals, positions);

    // Smoothing expects unit normals, so roots are normalized first.
    for (groups, 0..) |group, i| {
        if (group != i) continue;

        const r = result[i * 3 ..][0..3];
        const l = @sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
        const s = if (l == 0) 0 else 1 / l;

        r[0] *= s;
        r[1] *= s;
        r[2] *= s;
    }

    if (smoothing > 0) {
        var passes = truncate(@ceil(smoothing));
        // A cap against pathological cases.
        passes = if (passes < 10) passes else 10;

        const deltas = try scratch.alloc(f32, index_count * 4);

        var pass: i32 = 0;
        while (pass < passes) : (pass += 1) {
            const rem = smoothing - @as(f32, @floatFromInt(pass));
            const alpha = 0.5 * (if (rem < 1) rem else 1);

            smoothNormals(result, deltas, groups, face_normals, alpha);
        }
    }

    // The roots' normals copied to the other corners.
    for (groups, 0..) |group, i| {
        if (group != i) result[i * 3 ..][0..3].* = result[@as(usize, group) * 3 ..][0..3].*;
    }
}

/// glibc's sinf and cosf constants (sincosf_data.c): the signs by
/// quadrant, 2/pi scaled by 2^24, pi/2, and the cosine and sine
/// polynomials, the cosine's negated in the second table.
const SincosTable = struct {
    sign: [4]f64,
    hpi_inv: f64,
    hpi: f64,
    c0: f64,
    c1: f64,
    s1: f64,
    c2: f64,
    s2: f64,
    c3: f64,
    s3: f64,
    c4: f64,
};

const sincos_table = [2]SincosTable{
    .{
        .sign = .{ 1, -1, -1, 1 },
        .hpi_inv = 0x1.45f306dc9c883p+23,
        .hpi = 0x1.921fb54442d18p+0,
        .c0 = 0x1p0,
        .c1 = -0x1.ffffffd0c621cp-2,
        .s1 = -0x1.555545995a603p-3,
        .c2 = 0x1.55553e1068f19p-5,
        .s2 = 0x1.1107605230bc4p-7,
        .c3 = -0x1.6c087e89a359dp-10,
        .s3 = -0x1.994eb3774cf24p-13,
        .c4 = 0x1.99343027bf8c3p-16,
    },
    .{
        .sign = .{ 1, -1, -1, 1 },
        .hpi_inv = 0x1.45f306dc9c883p+23,
        .hpi = 0x1.921fb54442d18p+0,
        .c0 = -0x1p0,
        .c1 = 0x1.ffffffd0c621cp-2,
        .s1 = -0x1.555545995a603p-3,
        .c2 = -0x1.55553e1068f19p-5,
        .s2 = 0x1.1107605230bc4p-7,
        .c3 = 0x1.6c087e89a359dp-10,
        .s3 = -0x1.994eb3774cf24p-13,
        .c4 = -0x1.99343027bf8c3p-16,
    },
};

/// cosf as glibc 2.44's libm computes it with fused multiply-adds (the
/// variant x86-64 CPUs with FMA run, and the one aarch64 builds), for
/// |y| < 120: the angle reduced by multiples of pi/2, then a polynomial in
/// double precision. The original takes its crease cutoff from it; Zig's
/// own cosine rounds differently for some angles.
fn cosf(y: f32) f32 {
    const top12 = (@as(u32, @bitCast(y)) >> 20) & 0x7ff;
    assert(top12 < 0x42f);

    const x: f64 = y;

    // |y| < 0.75: no reduction.
    if (top12 < 0x3f4) {
        // |y| < 2^-12.
        if (top12 < 0x398) return 1;
        return cosPolynomial(x * x, &sincos_table[0]);
    }

    const n = (@as(i32, @intFromFloat(x * sincos_table[0].hpi_inv)) + 0x800000) >> 24;
    const reduced = @mulAdd(f64, -@as(f64, @floatFromInt(n)), sincos_table[0].hpi, x);
    const table = &sincos_table[if (n & 2 != 0) 1 else 0];
    const reduced2 = reduced * reduced;

    if (n & 1 == 0) return cosPolynomial(reduced2, table);

    const xs = reduced * sincos_table[0].sign[@intCast(n & 3)];
    const s1 = @mulAdd(f64, reduced2, table.s3, table.s2);
    const x3 = reduced2 * xs;
    const x5 = reduced2 * x3;
    const s = @mulAdd(f64, x3, table.s1, xs);
    return @floatCast(@mulAdd(f64, s1, x5, s));
}

fn cosPolynomial(x2: f64, table: *const SincosTable) f32 {
    const x4 = x2 * x2;
    const c2 = @mulAdd(f64, x2, table.c4, table.c3);
    const x6 = x2 * x4;
    const c1 = @mulAdd(f64, x2, table.c1, table.c0);
    const c = @mulAdd(f64, x4, table.c2, c1);
    return @floatCast(@mulAdd(f64, c2, x6, c));
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "options keep the original's bits" {
    try testing.expectEqual(1, @backingInt(TangentOptions{ .compatible = true }));
    try testing.expectEqual(2, @backingInt(TangentOptions{ .zero_fallback = true }));
}

test "the cosine at landmarks" {
    try testing.expectEqual(1, cosf(0));
    try testing.expectEqual(1, cosf(1e-5));
    try testing.expectEqual(-1, cosf(3.1415927));
    try testing.expect(@abs(cosf(1.0471976) - 0.5) < 1e-7);
}

/// glibc's cosf, for the oracle tests to check `cosf` against.
pub fn cosfForTest(y: f32) f32 {
    return cosf(y);
}
