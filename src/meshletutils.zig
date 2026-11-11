//! Work on single meshlets: bounding spheres and normal cones for culling,
//! reordering a meshlet's vertices and triangles for locality, and turning
//! a cluster's mesh indices into a meshlet's local ones.
//!
//! Translated from meshoptimizer's meshletutils.cpp, which builds on
//! Chajdas, "GeometryFX 1.2 - Cluster Culling" (2016); Ritter, "An
//! Efficient Bounding Sphere" (1990); and Larsson, "Fast and Tight Fitting
//! Bounding Spheres" (2008).

const std = @import("std");
const assert = std.debug.assert;
const VertexFloats = @import("strided.zig").VertexFloats;
const quantizeSnorm = @import("quantization.zig").quantizeSnorm;

// At most 256, as meshlet indices are bytes.
const meshlet_max_vertices = 256;

// Around twice the vertex limit or less is reasonable.
const meshlet_max_triangles = 512;

/// Bounding volumes of a cluster, for frustum, occlusion and backface
/// culling.
///
/// With an orthographic projection, a cluster faces away when
/// `dot(view, cone_axis) >= cone_cutoff`. With a perspective one, when
/// `dot(normalize(cone_apex - camera_position), cone_axis) >= cone_cutoff`,
/// or, without the apex but with the bounding sphere, when
/// `dot(normalize(center - camera_position), cone_axis) >= cone_cutoff +
/// radius / length(center - camera_position)`, or the same without a
/// singularity at the center, `dot(center - camera_position, cone_axis) >=
/// cone_cutoff * length(center - camera_position) + radius`. The apex is a
/// little more accurate; the sphere suits a renderer that already culls by
/// it (Real-Time Rendering, 4th edition, section 19.3).
pub const Bounds = extern struct {
    /// The bounding sphere.
    center: [3]f32,
    radius: f32,

    /// The normal cone.
    cone_apex: [3]f32,
    cone_axis: [3]f32,
    /// The sine of half the normal cone's angle.
    cone_cutoff: f32,

    /// The normal cone's axis and cutoff as 8-bit snorm values, for
    /// `x / 127.0`; the cutoff is rounded up, so tests stay conservative.
    cone_axis_s8: [3]i8,
    cone_cutoff_s8: i8,

    const zero: Bounds = .{
        .center = @splat(0),
        .radius = 0,
        .cone_apex = @splat(0),
        .cone_axis = @splat(0),
        .cone_cutoff = 0,
        .cone_axis_s8 = @splat(0),
        .cone_cutoff_s8 = 0,
    };
};

/// Extreme points are searched along the first `axis_count` of these.
const sphere_axes = [7][3]f32{
    // X, Y, Z
    .{ 1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, 0, 1 },

    // XYZ, -XYZ, X-YZ, XY-Z, of unit length
    .{ 0.57735026, 0.57735026, 0.57735026 },
    .{ -0.57735026, 0.57735026, 0.57735026 },
    .{ 0.57735026, -0.57735026, 0.57735026 },
    .{ 0.57735026, 0.57735026, -0.57735026 },
};

fn radiusOf(radii: ?VertexFloats, v: u32) f32 {
    const list = radii orelse return 0;
    return list.data[v * list.stride];
}

/// A sphere holding the points `indices` names, or all of `points` if
/// `indices` is null, each grown by its radius in `radii`, if given: the
/// center, then the radius.
fn computeBoundingSphere(
    comptime axis_count: usize,
    points: VertexFloats,
    radii: ?VertexFloats,
    indices: ?[]const u32,
) [4]f32 {
    const count = if (indices) |list| list.len else points.count();
    assert(count > 0);

    // The points with the smallest and largest coordinates along each axis,
    // one axis per lane; lanes past `axis_count` are left over.
    const lanes = if (axis_count <= 4) 4 else 8;
    const Floats = @Vector(lanes, f32);
    const Points = @Vector(lanes, u32);
    const coefficients = comptime axes: {
        var by_coordinate: [3][lanes]f32 = @splat(@splat(0));
        for (sphere_axes[0..axis_count], 0..) |ax, axis| {
            for (ax, 0..) |a, coordinate| by_coordinate[coordinate][axis] = a;
        }
        break :axes by_coordinate;
    };
    const ax_x: Floats = coefficients[0];
    const ax_y: Floats = coefficients[1];
    const ax_z: Floats = coefficients[2];

    var pmin_lanes: Points = @splat(0);
    var pmax_lanes: Points = @splat(0);
    var tmin: Floats = @splat(std.math.floatMax(f32));
    var tmax: Floats = @splat(-std.math.floatMax(f32));

    for (0..count) |i| {
        const v: u32 = if (indices) |list| list[i] else @intCast(i);
        const p = points.vec3(v);
        const r: Floats = @splat(radiusOf(radii, v));

        const tp = ax_x * @as(Floats, @splat(p[0])) + ax_y * @as(Floats, @splat(p[1])) +
            ax_z * @as(Floats, @splat(p[2]));
        const tpmin = tp - r;
        const tpmax = tp + r;

        const lower = tpmin < tmin;
        const higher = tpmax > tmax;
        pmin_lanes = @select(u32, lower, @as(Points, @splat(v)), pmin_lanes);
        pmax_lanes = @select(u32, higher, @as(Points, @splat(v)), pmax_lanes);
        tmin = @select(f32, lower, tpmin, tmin);
        tmax = @select(f32, higher, tpmax, tmax);
    }

    const pmin_all: [lanes]u32 = pmin_lanes;
    const pmax_all: [lanes]u32 = pmax_lanes;
    const pmin = pmin_all[0..axis_count];
    const pmax = pmax_all[0..axis_count];

    // The pair farthest apart.
    var paxis: usize = 0;
    var paxisdr: f32 = 0;

    for (0..axis_count) |axis| {
        const p1 = points.vec3(pmin[axis]);
        const p2 = points.vec3(pmax[axis]);
        const r1 = radiusOf(radii, pmin[axis]);
        const r2 = radiusOf(radii, pmax[axis]);

        const d2 = (p2[0] - p1[0]) * (p2[0] - p1[0]) +
            (p2[1] - p1[1]) * (p2[1] - p1[1]) +
            (p2[2] - p1[2]) * (p2[2] - p1[2]);
        const dr = @sqrt(d2) + r1 + r2;

        if (dr > paxisdr) {
            paxisdr = dr;
            paxis = axis;
        }
    }

    // The longest segment is the first sphere's diameter.
    const p1 = points.vec3(pmin[paxis]);
    const p2 = points.vec3(pmax[paxis]);
    const r1 = radiusOf(radii, pmin[paxis]);
    const r2 = radiusOf(radii, pmax[paxis]);

    const paxisd = @sqrt((p2[0] - p1[0]) * (p2[0] - p1[0]) +
        (p2[1] - p1[1]) * (p2[1] - p1[1]) +
        (p2[2] - p1[2]) * (p2[2] - p1[2]));
    const paxisk: f32 = if (paxisd > 0) (paxisd + r2 - r1) / (2 * paxisd) else 0;

    var center = [3]f32{
        p1[0] + (p2[0] - p1[0]) * paxisk,
        p1[1] + (p2[1] - p1[1]) * paxisk,
        p1[2] + (p2[2] - p1[2]) * paxisk,
    };
    var radius = paxisdr / 2;

    // Grow the sphere until every point fits.
    for (0..count) |i| {
        const v: u32 = if (indices) |list| list[i] else @intCast(i);
        const p = points.vec3(v);
        const r = radiusOf(radii, v);

        const d2 = (p[0] - center[0]) * (p[0] - center[0]) +
            (p[1] - center[1]) * (p[1] - center[1]) +
            (p[2] - center[2]) * (p[2] - center[2]);
        const d = @sqrt(d2);

        if (d + r > radius) {
            const k: f32 = if (d > 0) (d + r - radius) / (2 * d) else 0;

            center[0] += k * (p[0] - center[0]);
            center[1] += k * (p[1] - center[1]);
            center[2] += k * (p[2] - center[2]);
            radius = (radius + d + r) / 2;
        }
    }

    return .{ center[0], center[1], center[2], radius };
}

/// The bounds of the triangles of `indices`, whose distinct vertices are
/// `corners`.
fn clusterBounds(indices: []const u32, corners: []const u32, positions: VertexFloats) Bounds {
    // Triangle normals, each with the plane equation's distance last.
    var normals: [meshlet_max_triangles][4]f32 = undefined;
    var triangles: usize = 0;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const p0 = positions.vec3(indices[i + 0]);
        const p1 = positions.vec3(indices[i + 1]);
        const p2 = positions.vec3(indices[i + 2]);

        const p10 = [3]f32{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
        const p20 = [3]f32{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };

        var normalx = p10[1] * p20[2] - p10[2] * p20[1];
        var normaly = p10[2] * p20[0] - p10[0] * p20[2];
        var normalz = p10[0] * p20[1] - p10[1] * p20[0];

        const area = @sqrt(normalx * normalx + normaly * normaly + normalz * normalz);

        // Degenerate triangles are invisible anyway.
        if (area == 0) continue;

        normalx /= area;
        normaly /= area;
        normalz /= area;

        // The normal and corner 0 make the plane equation.
        normals[triangles] = .{
            normalx,
            normaly,
            normalz,
            -(normalx * p0[0] + normaly * p0[1] + normalz * p0[2]),
        };
        triangles += 1;
    }

    var bounds: Bounds = .zero;

    // No visible triangle: always rejected, with a zero cone.
    if (triangles == 0) return bounds;

    // The cluster's bounding sphere; its center is the cone apex's too.
    const psphere = computeBoundingSphere(7, positions, null, corners);

    const center = psphere[0..3].*;

    // The normals' bounding sphere, as points: its center is the best cone
    // axis.
    const flat: *const [meshlet_max_triangles * 4]f32 = @ptrCast(&normals);
    const normal_points: VertexFloats = .init(flat[0 .. triangles * 4], 4);
    const nsphere = computeBoundingSphere(3, normal_points, null, null);

    var axis = nsphere[0..3].*;
    const axislength = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    const invaxislength: f32 = if (axislength == 0) 0 else 1 / axislength;

    axis[0] *= invaxislength;
    axis[1] *= invaxislength;
    axis[2] *= invaxislength;

    // The tightest cone around every normal: mindp is cos(angle / 2).
    var mindp: f32 = 1;

    for (normals[0..triangles]) |n| {
        const dp = n[0] * axis[0] + n[1] * axis[1] + n[2] * axis[2];

        mindp = if (dp < mindp) dp else mindp;
    }

    // The sphere stays even when the cone does not.
    bounds.center = center;
    bounds.radius = psphere[3];

    // A normal cone wider than a hemisphere always passes. Near that the
    // apex below gets unstable, so a cone of about 168 degrees or more
    // counts as useless.
    if (mindp <= 0.1) {
        bounds.cone_cutoff = 1;
        bounds.cone_cutoff_s8 = 127;
        return bounds;
    }

    var maxt: f32 = 0;

    // The point on the ray center - t * axis behind every triangle's plane:
    // dot(center - t * axis - corner, normal) = 0 gives
    // t = dot(center - corner, normal) / dot(axis, normal).
    for (normals[0..triangles]) |n| {
        const dc = center[0] * n[0] + center[1] * n[1] + center[2] * n[2] + n[3];
        const dn = axis[0] * n[0] + axis[1] * n[1] + axis[2] * n[2];

        // At least mindp, which passed the cutoff above.
        assert(dn > 0);
        const t = dc / dn;

        maxt = if (t > maxt) t else maxt;
    }

    bounds.cone_apex = .{
        center[0] - axis[0] * maxt,
        center[1] - axis[1] * maxt,
        center[2] - axis[2] * maxt,
    };

    // The normal cone's axis; the perspective test negates it in effect.
    bounds.cone_axis = axis;

    // The normal cone's cos(a) is mindp; adding 90 degrees on both sides
    // and inverting gives -cos(a + 90) = sin(a) = sqrt(1 - cos^2(a)).
    bounds.cone_cutoff = @sqrt(1 - mindp * mindp);

    for (&bounds.cone_axis_s8, bounds.cone_axis) |*q, v| q.* = @intCast(quantizeSnorm(v, 8));

    // The 8-bit test stays conservative when the cutoff grows by the
    // axis's largest quantization error.
    var errors: [3]f32 = undefined;
    for (&errors, bounds.cone_axis_s8, bounds.cone_axis) |*e, q, v| {
        e.* = @abs(@as(f32, @floatFromInt(q)) / 127 - v);
    }

    // Rounded up, not to nearest, hence the + 1.
    const cutoff_sum = bounds.cone_cutoff + errors[0] + errors[1] + errors[2];
    const cone_cutoff_s8: i32 = @intFromFloat(127 * cutoff_sum + 1);

    bounds.cone_cutoff_s8 = if (cone_cutoff_s8 > 127) 127 else @intCast(cone_cutoff_s8);

    return bounds;
}

/// The bounding sphere and normal cone of the triangles of `indices`, at
/// most 512 of them using at most 256 distinct vertices of `positions`
/// (the whole mesh's). A cluster without visible triangles gets all zeros;
/// one whose normal cone is wider than about 168 degrees gets its sphere and
/// a cutoff of 1, which no view passes.
pub fn computeClusterBounds(indices: []const u32, positions: VertexFloats) Bounds {
    assert(indices.len % 3 == 0);
    assert(indices.len / 3 <= meshlet_max_triangles);
    assert(positions.stride >= 3 and positions.stride <= 64);

    const vertex_count = positions.count();

    var cache: [512]u32 = @splat(std.math.maxInt(u32));

    // One more for the branchless append.
    var corners: [meshlet_max_triangles * 3 + 1]u32 = undefined;
    var corner_count: usize = 0;

    for (indices) |v| {
        assert(v < vertex_count);

        const c = &cache[v & (cache.len - 1)];

        // Appends the vertex unless the cache has it.
        corners[corner_count] = v;
        corner_count += @intFromBool(c.* != v);
        c.* = v;
    }

    return clusterBounds(indices, corners[0..corner_count], positions);
}

/// `computeClusterBounds` for a meshlet: `meshlet_vertices` are its
/// vertices, indices into `positions`, and `meshlet_triangles` its
/// triangles, indices into `meshlet_vertices`, at most 512 of them. Every
/// vertex of `meshlet_vertices` up to the last a triangle uses should be
/// used, as a builder leaves them.
pub fn computeMeshletBounds(
    meshlet_vertices: []const u32,
    meshlet_triangles: []const u8,
    positions: VertexFloats,
) Bounds {
    assert(meshlet_triangles.len % 3 == 0);
    assert(meshlet_triangles.len / 3 <= meshlet_max_triangles);
    assert(positions.stride >= 3 and positions.stride <= 64);

    const vertex_count = positions.count();

    var indices: [meshlet_max_triangles * 3]u32 = undefined;
    var corner_count: usize = 0;

    for (meshlet_triangles, indices[0..meshlet_triangles.len]) |t, *index| {
        index.* = meshlet_vertices[t];
        assert(index.* < vertex_count);

        corner_count = if (t >= corner_count) @as(usize, t) + 1 else corner_count;
    }

    return clusterBounds(
        indices[0..meshlet_triangles.len],
        meshlet_vertices[0..corner_count],
        positions,
    );
}

/// The bounding sphere of `positions`, as points, or as spheres when
/// `radii` gives each one's non-negative radius (in its first float);
/// every other field is zero.
pub fn computeSphereBounds(positions: VertexFloats, radii: ?VertexFloats) Bounds {
    assert(positions.stride >= 3 and positions.stride <= 64);
    if (radii) |list| assert(list.stride >= 1 and list.stride <= 64);

    var bounds: Bounds = .zero;

    if (positions.count() == 0) return bounds;

    const psphere = computeBoundingSphere(7, positions, radii, null);

    bounds.center = psphere[0..3].*;
    bounds.radius = psphere[3];

    return bounds;
}

/// Reorders a meshlet's vertices and triangles for locality, as
/// `optimizeMeshlet` does at `level` 0; higher levels, to 9, take longer
/// and give smaller compressed meshlets, best around 3. From level 1 on,
/// triangles' corners may rotate, which can change the provoking vertex.
pub fn optimizeMeshletLevel(meshlet_vertices: []u32, meshlet_triangles: []u8, level: u4) void {
    assert(meshlet_triangles.len % 3 == 0);
    assert(meshlet_triangles.len / 3 <= meshlet_max_triangles);
    assert(meshlet_vertices.len <= meshlet_max_vertices);
    assert(level <= 9);

    const indices = meshlet_triangles;
    const vertices = meshlet_vertices;
    const vertex_count = vertices.len;
    const triangle_count = indices.len / 3;

    // Each vertex's timestamp: the triangle that last used it, as all three
    // corners enter together and never leave.
    var cache: [meshlet_max_vertices]u8 = undefined;
    @memset(cache[0..vertex_count], 0);

    // A start that puts no vertex in the cache.
    var cache_last: u8 = 128;
    // 3 triangles are about 5 to 9 vertices, by reuse.
    const cache_cutoff = 3;

    // Vertex valences rank triangles from level 1 on. They are 8-bit
    // counters for speed: an outlier's count wraps, which only weakens the
    // heuristic.
    var valence: [meshlet_max_vertices]u8 = undefined;
    @memset(valence[0..vertex_count], 0);

    for (indices) |index| {
        assert(index < vertex_count);

        valence[index] +%= 1;
    }

    for (0..triangle_count) |i| {
        var next: ?usize = null;
        var next_score: i32 = -1;
        var edges: u32 = 0;

        for (i..triangle_count) |j| {
            const a = indices[j * 3 + 0];
            const b = indices[j * 3 + 1];
            const c = indices[j * 3 + 2];

            // Cache distances in wrapping 8-bit arithmetic, so timestamps
            // can overflow.
            const ad = cache_last -% cache[a];
            const bd = cache_last -% cache[b];
            const cd = cache_last -% cache[c];

            const match = @as(i32, @intFromBool(ad < cache_cutoff)) +
                @intFromBool(bd < cache_cutoff) +
                @intFromBool(cd < cache_cutoff);

            if (level != 0) {
                // A low smallest valence wins.
                const vmin: i32 = @min(valence[a], valence[b], valence[c]);

                // So do small cache distances and valences, for locality.
                var score = match * 1024 + (1023 - @as(i32, ad) - bd - cd);
                score = score * 256 + (255 - vmin);

                next = if (score > next_score) j else next;
                next_score = if (score > next_score) score else next_score;

                // Stop after enough edge matches.
                if (match >= 2) {
                    edges += 1;
                    if (edges >= level) break;
                }
            } else {
                const score = match;

                next = if (score > next_score) j else next;
                next_score = if (score > next_score) score else next_score;

                // Settle for the first edge match, which makes this about
                // linear in practice.
                if (match >= 2) break;
            }
        }

        // The first candidate scores above -1, so one is always chosen.
        const best = next.?;

        const a = indices[best * 3 + 0];
        const b = indices[best * 3 + 1];
        const c = indices[best * 3 + 2];

        // Shift the triangles before it up, to keep their order; swapping
        // triangles i and best would distort the order and the output.
        const shifted = (best - i) * 3;
        @memmove(indices[(i + 1) * 3 ..][0..shifted], indices[i * 3 ..][0..shifted]);

        indices[i * 3 ..][0..3].* = .{ a, b, c };

        // One timestamp for all three corners, so it overflows less.
        cache_last +%= 1;
        cache[a] = cache_last;
        cache[b] = cache_last;
        cache[c] = cache_last;

        valence[a] -%= 1;
        valence[b] -%= 1;
        valence[c] -%= 1;
    }

    // Rotate triangles to compress better; only from level 1 on, so level 0
    // keeps the original's older results.
    if (level >= 1) {
        @memset(cache[0..vertex_count], 0);

        for (0..triangle_count) |i| {
            var a = indices[i * 3 + 0];
            var b = indices[i * 3 + 1];
            var c = indices[i * 3 + 2];

            if (cache[a] == 0 and cache[b] != 0 and cache[c] == 0) {
                // Only the middle vertex was used: rotate so new vertices
                // are always in sequence. abc -> bca
                const t = a;
                a = b;
                b = c;
                c = t;
            } else if (cache[a] == 0 and cache[b] == 0 and cache[c] == 0) {
                // Some encodings cannot reuse edge ab in the next
                // triangles; rotate if they do not share edge ca or bc.
                var needab = false;
                var needbc = false;
                var needca = false;

                var j = i + 1;
                while (j < triangle_count and j <= i + cache_cutoff) : (j += 1) {
                    const oa = indices[j * 3 + 0];
                    const ob = indices[j * 3 + 1];
                    const oc = indices[j * 3 + 2];

                    // A reused edge runs the other way.
                    needab = needab or (oa == b and ob == a) or (ob == b and oc == a) or
                        (oc == b and oa == a);
                    needbc = needbc or (oa == c and ob == b) or (ob == c and oc == b) or
                        (oc == c and oa == b);
                    needca = needca or (oa == a and ob == c) or (ob == a and oc == c) or
                        (oc == a and oa == c);
                }

                if (needab and !needbc) {
                    // abc -> bca
                    const t = a;
                    a = b;
                    b = c;
                    c = t;
                } else if (needab and !needca) {
                    // abc -> cab
                    const t = c;
                    c = b;
                    b = a;
                    a = t;
                } else if (!needab and needbc and !needca) {
                    // abc -> cab, putting bc last in the FIFO.
                    const t = c;
                    c = b;
                    b = a;
                    a = t;
                }
            }

            indices[i * 3 ..][0..3].* = .{ a, b, c };

            cache[a] = 1;
            cache[b] = 1;
            cache[c] = 1;
        }
    }

    // Order the vertices by first use, for locality when the triangles are
    // read in order.
    var order: [meshlet_max_vertices]u32 = undefined;

    var remap: [meshlet_max_vertices]i16 = undefined;
    @memset(remap[0..vertex_count], -1);

    var vertex_offset: usize = 0;

    for (indices) |*index| {
        const r = &remap[index.*];

        if (r.* < 0) {
            r.* = @intCast(vertex_offset);
            order[vertex_offset] = vertices[index.*];
            vertex_offset += 1;
        }

        index.* = @intCast(r.*);
    }

    @memcpy(vertices[0..vertex_offset], order[0..vertex_offset]);
}

/// Reorders a meshlet's vertices and triangles for locality, which can
/// speed up rasterizing, or ray tracing with fast-build structures: its
/// triangles in a cache-friendly order, then its vertices by first use.
/// Pass the meshlet's own ranges of a builder's arrays, at most 256
/// vertices and 512 triangles.
pub fn optimizeMeshlet(meshlet_vertices: []u32, meshlet_triangles: []u8) void {
    optimizeMeshletLevel(meshlet_vertices, meshlet_triangles, 0);
}

/// Writes the meshlet that cluster `indices`, at most 512 triangles using at
/// most 256 distinct vertices, makes: `vertices` gets the distinct
/// vertices in order of first use and `triangles` the local indices, so
/// `vertices[triangles[i]] == indices[i]`; returns the vertex count.
/// `vertices` holds up to 256 entries and `triangles` `indices.len`.
pub fn extractMeshletIndices(vertices: []u32, triangles: []u8, indices: []const u32) usize {
    assert(indices.len % 3 == 0);
    assert(indices.len / 3 <= meshlet_max_triangles);

    var unique: usize = 0;

    // A direct mapped cache by the low bits of the index (as NVIDIA's
    // vk_lod_clusters does) finds most vertices quickly.
    var cache: [1024]i16 = @splat(-1);

    for (indices, triangles[0..indices.len]) |v, *t| {
        const key = v & (cache.len - 1);
        const c = cache[key];

        // Seen before.
        if (c >= 0 and vertices[@intCast(c)] == v) {
            t.* = @intCast(c);
            continue;
        }

        // Never seen before.
        if (c < 0) {
            assert(unique < meshlet_max_vertices);
            cache[key] = @intCast(unique);
            t.* = @intCast(unique);
            vertices[unique] = v;
            unique += 1;
            continue;
        }

        // Another vertex has the entry: search them all.
        const pos = std.mem.indexOfScalar(u32, vertices[0..unique], v) orelse found: {
            assert(unique < meshlet_max_vertices);
            vertices[unique] = v;
            unique += 1;
            break :found unique - 1;
        };

        cache[key] = @intCast(pos);
        t.* = @intCast(pos);
    }

    return unique;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "an optimized meshlet uses its vertices in order" {
    var vertices = [_]u32{ 10, 11, 12, 13 };
    var triangles = [_]u8{ 3, 2, 1, 1, 2, 0 };
    optimizeMeshletLevel(&vertices, &triangles, 3);
    var next: u8 = 0;
    for (triangles) |t| {
        try testing.expect(t <= next);
        if (t == next) next += 1;
    }
    try testing.expectEqual(4, next);
}
