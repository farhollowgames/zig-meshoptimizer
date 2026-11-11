//! Mesh simplification: edge collapses ranked by quadric error, with or
//! without vertex attributes and with optional updates of the kept
//! vertices; a sloppy simplifier that clusters vertices on a grid; a pruner
//! of small disconnected parts; a point cloud simplifier; and the scale that
//! turns relative errors into absolute ones.
//!
//! Translated from meshoptimizer's simplifier.cpp, which builds on Garland
//! and Heckbert, "Surface Simplification Using Quadric Error Metrics"
//! (1997); Garland, "Quadric-Based Polygonal Surface Simplification" (1999);
//! Lindstrom, "Out-of-Core Simplification of Large Polygonal Models" (2000);
//! Teschner et al., "Optimized Spatial Hashing for Collision Detection of
//! Deformable Objects" (2003); Van Sandt, Chronis and Patel, "Efficiently
//! Searching In-Memory Sorted Arrays: Revenge of the Interpolation Search?"
//! (2019); Hoppe, "New Quadric Metric for Simplifying Meshes with Appearance
//! Attributes" (1999); and Hoppe and Marschner, "Efficient Minimization of
//! New Quadric Metric for Simplifying Meshes with Appearance Attributes"
//! (2000).

const std = @import("std");
const assert = std.debug.assert;
const convert = @import("convert.zig");
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const strided = @import("strided.zig");
const VertexFloats = strided.VertexFloats;
const VertexFloatsMut = strided.VertexFloatsMut;
const indexgenerator = @import("indexgenerator.zig");
const hashBuckets = indexgenerator.hashBuckets;
const hashLookup = indexgenerator.hashLookup;

/// What the simplifiers may do; the bits are the original's
/// `meshopt_SimplifyX` flags, so `@bitCast` converts between the two.
pub const SimplifyOptions = packed struct(u32) {
    /// Do not move vertices on the topological border: vertices on
    /// triangle edges that have no paired triangle. Useful for simplifying
    /// parts of a larger mesh.
    lock_border: bool = false,
    /// Run faster when the indices use a small part of the vertex buffer.
    /// The error is then relative to the extents of that part.
    sparse: bool = false,
    /// Take the target error and give the result error in the mesh's own
    /// units, not relative to its extents.
    error_absolute: bool = false,
    /// Remove disconnected parts of the mesh as simplification goes,
    /// whatever the topology inside them.
    prune: bool = false,
    /// Make triangle sizes and shapes more regular, at some cost to
    /// geometric and attribute quality.
    regularize: bool = false,
    /// Collapse across attribute discontinuities, except at vertices whose
    /// `vertex_lock` flags have `protect`.
    permissive: bool = false,
    /// Make triangle sizes and shapes more regular, at a small cost to
    /// geometric and attribute quality.
    regularize_light: bool = false,
    /// Experimental: try to keep the fold lines between opposite-facing
    /// triangles, at a small performance cost.
    preserve_folds: bool = false,
    /// Experimental: limit the attribute error to the scale of the position
    /// error, so areas of high attribute variance do not give extreme
    /// errors.
    error_clamped: bool = false,
    _unused: u20 = 0,
    /// For development only, as in the original: `simplifyWithUpdate` sets
    /// it to move the kept vertices; `simplify` and
    /// `simplifyWithAttributes` refuse it.
    internal_solve: bool = false,
    /// For development only, as in the original: each index of the result
    /// carries its vertex's kind in bits 28 to 30 and, in bit 31, whether
    /// the edge to the next corner is on an edge loop. Ignored with
    /// `sparse`.
    internal_debug: bool = false,
    _unused_high: u1 = 0,
};

/// Per-vertex flags for the `vertex_lock` lists of the simplifiers; the
/// bits are the original's `meshopt_SimplifyVertex_X` flags, so a list of
/// the original's bytes is a list of these.
pub const SimplifyVertexFlags = packed struct(u8) {
    /// Do not move this vertex.
    lock: bool = false,
    /// Keep the attribute discontinuity at this vertex; works with the
    /// `permissive` option.
    protect: bool = false,
    /// Make this vertex more likely to survive simplification.
    priority: bool = false,
    _unused: u5 = 0,
};

const none = std.math.maxInt(u32);
const float_max = std.math.floatMax(f32);

/// The most attributes the attribute metric takes.
pub const attribute_count_max = 32;

/// `int(value)` as the original computes it on x86-64: truncated toward
/// zero, and the minimum `i32` for NaN and values out of range, which is
/// what `cvttss2si` gives.
fn truncateToInt(value: f32) i32 {
    if (!(value >= -2147483648.0 and value < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(value);
}

fn toFloat(n: usize) f32 {
    return @floatFromInt(n);
}

const EdgeAdjacency = struct {
    offsets: []u32,
    data: []Edge,

    const Edge = struct {
        next: u32,
        prev: u32,
    };

    fn init(scratch: *Scratch, index_count: usize, vertex_count: usize) !EdgeAdjacency {
        const offsets = try scratch.alloc(u32, vertex_count + 1);
        const data = try scratch.alloc(Edge, index_count);
        return .{ .offsets = offsets, .data = data };
    }

    /// The half-edges out of `vertex`, each with the triangle's other two
    /// corners in winding order.
    fn edgesOf(self: EdgeAdjacency, vertex: u32) []const Edge {
        return self.data[self.offsets[vertex]..self.offsets[vertex + 1]];
    }

    /// Rebuilds the adjacency of `indices`, through `remap` if given.
    fn update(
        self: EdgeAdjacency,
        indices: []const u32,
        vertex_count: usize,
        remap: ?[]const u32,
    ) void {
        const offsets = self.offsets[1..][0..vertex_count];

        // Edge counts.
        @memset(offsets, 0);

        for (indices) |index| {
            const v = if (remap) |r| r[index] else index;
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

        // Edge data.
        var i: usize = 0;
        while (i < indices.len) : (i += 3) {
            var a = indices[i + 0];
            var b = indices[i + 1];
            var c = indices[i + 2];

            if (remap) |r| {
                a = r[a];
                b = r[b];
                c = r[c];
            }

            self.data[offsets[a]] = .{ .next = b, .prev = c };
            offsets[a] += 1;

            self.data[offsets[b]] = .{ .next = c, .prev = a };
            offsets[b] += 1;

            self.data[offsets[c]] = .{ .next = a, .prev = b };
            offsets[c] += 1;
        }

        // Each offset now holds the next vertex's start.
        self.offsets[0] = 0;
    }
};

/// Hashes and compares positions, read through `sparse_remap` if given.
const PositionHasher = struct {
    positions: VertexFloats,
    sparse_remap: ?[]const u32,

    fn position(self: PositionHasher, index: u32) *const [3]f32 {
        const ri = if (self.sparse_remap) |s| s[index] else index;
        return self.positions.data[ri * self.positions.stride ..][0..3];
    }

    pub fn hash(self: PositionHasher, index: u32) u32 {
        const key: [3]u32 = @bitCast(self.position(index).*);
        var x, var y, var z = key;

        // Negative zero hashes as zero.
        x = if (x == 0x80000000) 0 else x;
        y = if (y == 0x80000000) 0 else y;
        z = if (z == 0x80000000) 0 else z;

        // Scramble the bits so integer coordinates have entropy in the lower
        // bits.
        x ^= x >> 17;
        y ^= y >> 17;
        z ^= z >> 17;

        return (x *% 73856093) ^ (y *% 19349663) ^ (z *% 83492791);
    }

    pub fn equal(self: PositionHasher, lhs: u32, rhs: u32) bool {
        const lv = self.position(lhs);
        const rv = self.position(rhs);

        return lv[0] == rv[0] and lv[1] == rv[1] and lv[2] == rv[2];
    }
};

/// Finds the dense index of a sparse one: the table holds dense indices,
/// `remap` their sparse ones.
const RemapHasher = struct {
    remap: []const u32,

    pub fn hash(_: RemapHasher, id: u32) u32 {
        return id *% 0x5bd1e995;
    }

    pub fn equal(self: RemapHasher, lhs: u32, rhs: u32) bool {
        return self.remap[lhs] == rhs;
    }
};

/// Fills `remap` with the first vertex of each vertex's position, and
/// `wedge`, if given, with the next vertex of the same position: each
/// position's vertices form a cycle, and a vertex alone at its position
/// points to itself.
fn buildPositionRemap(
    scratch: *Scratch,
    remap: []u32,
    wedge: ?[]u32,
    positions: VertexFloats,
    sparse_remap: ?[]const u32,
) !void {
    const hasher: PositionHasher = .{ .positions = positions, .sparse_remap = sparse_remap };

    const table = try scratch.alloc(u32, hashBuckets(remap.len));
    @memset(table, none);

    for (remap, 0..) |*r, i| {
        const index: u32 = @intCast(i);
        const entry = hashLookup(u32, table, hasher, index, none);

        if (table[entry] == none) table[entry] = index;

        r.* = table[entry];
    }

    scratch.free(table);

    const wedges = wedge orelse return;

    for (wedges, 0..) |*w, i| w.* = @intCast(i);

    for (remap, 0..) |r, i| {
        if (r != i) {
            wedges[i] = wedges[r];
            wedges[r] = @intCast(i);
        }
    }
}

/// Rewrites `indices` to a dense numbering of the vertices they use and
/// returns the vertex each dense index stands for.
fn buildSparseRemap(scratch: *Scratch, indices: []u32, vertex_count: usize) ![]u32 {
    // A bit set gives the exact number of unique vertices. Only the bytes
    // the indices touch are cleared, and only those are read.
    const filter = try scratch.alloc(u8, (vertex_count + 7) / 8);

    for (indices) |index| {
        assert(index < vertex_count);
        filter[index / 8] = 0;
    }

    var unique: usize = 0;
    for (indices) |index| {
        const bit = @as(u8, 1) << @as(u3, @truncate(index));
        unique += @intFromBool(filter[index / 8] & bit == 0);
        filter[index / 8] |= bit;
    }

    const remap = try scratch.alloc(u32, unique);
    var offset: u32 = 0;

    // Dense to sparse, allocated last so it can be freed at once.
    const revremap = try scratch.alloc(u32, hashBuckets(unique));
    @memset(revremap, none);

    // Fill the remap and rewrite the indices in one pass.
    const hasher: RemapHasher = .{ .remap = remap };

    for (indices) |*index| {
        const entry = hashLookup(u32, revremap, hasher, index.*, none);

        if (revremap[entry] == none) {
            remap[offset] = index.*;
            revremap[entry] = offset;
            offset += 1;
        }

        index.* = revremap[entry];
    }

    scratch.free(revremap);

    return remap;
}

const Kind = enum(u8) {
    /// On no attribute seam and no border.
    manifold,
    /// On no attribute seam, with exactly two open edges.
    border,
    /// On an attribute seam with exactly two seam edges.
    seam,
    /// None of the above; it moves only if all its wedges move to the
    /// target vertex.
    complex,
    /// A complex vertex on a geometric border; it moves only to another
    /// fringe vertex.
    fringe,
    /// None of the above; it never moves.
    locked,
};

const kind_count = @typeInfo(Kind).@"enum".field_names.len;

// Manifold vertices collapse onto anything; border and seam vertices onto
// border and seam respectively, or locked; complex onto complex or locked;
// fringe only onto fringe, while border, manifold and complex vertices can
// collapse onto fringe ones. As a rule, collapsing kind A into kind B keeps
// the target vertex of kind B: a complex vertex could collapse into a
// manifold one, but the target would not be manifold any more.
const can_collapse = [kind_count][kind_count]bool{
    .{ true, true, true, true, true, true },
    .{ false, true, false, false, true, true },
    .{ false, false, true, false, false, true },
    .{ false, false, false, true, true, true },
    .{ false, false, false, false, true, false },
    .{ false, false, false, false, false, false },
};

// Edges at manifold and seam vertices have an opposite edge; for seam edges
// it is not in the attribute topology, only in the position-only mesh. Many
// complex collapses have one too, but since complex vertices collapse onto
// the same wedge, keeping opposite edges apart improves quality by weighing
// both targets.
const has_opposite = [kind_count][kind_count]bool{
    .{ true, true, true, true, true, true },
    .{ true, false, true, false, false, false },
    .{ true, true, true, false, false, true },
    .{ true, false, false, false, false, false },
    .{ true, false, false, false, false, false },
    .{ true, false, true, false, false, false },
};

fn canCollapse(from: Kind, to: Kind) bool {
    return can_collapse[@backingInt(from)][@backingInt(to)];
}

fn hasOpposite(from: Kind, to: Kind) bool {
    return has_opposite[@backingInt(from)][@backingInt(to)];
}

fn hasEdge(adjacency: EdgeAdjacency, a: u32, b: u32) bool {
    for (adjacency.edgesOf(a)) |edge| {
        if (edge.next == b) return true;
    }

    return false;
}

/// `hasEdge` between positions: from any wedge of `a` to any vertex at
/// `b`'s position.
fn hasWedgeEdge(
    adjacency: EdgeAdjacency,
    a: u32,
    b: u32,
    remap: []const u32,
    wedge: []const u32,
) bool {
    var v = a;

    while (true) {
        for (adjacency.edgesOf(v)) |edge| {
            if (remap[edge.next] == remap[b]) return true;
        }

        v = wedge[v];
        if (v == a) break;
    }

    return false;
}

fn classifyVertices(
    result: []Kind,
    loop: []u32,
    loopback: []u32,
    adjacency: EdgeAdjacency,
    remap: []const u32,
    wedge: []const u32,
    vertex_lock: ?[]const SimplifyVertexFlags,
    sparse_remap: ?[]const u32,
    options: SimplifyOptions,
) void {
    const vertex_count = result.len;

    @memset(loop, none);
    @memset(loopback, none);

    // Incoming and outgoing open edges: `none` if a vertex has none, the
    // vertex itself if it has more than one. This is the data the loops
    // need; they are used only for border and seam vertices by default, but
    // permissive mode also uses them to guide complex collapses, so they are
    // filled for every vertex.
    const openinc = loopback;
    const openout = loop;

    for (0..vertex_count) |i| {
        const vertex: u32 = @intCast(i);

        for (adjacency.edgesOf(vertex)) |edge| {
            const target = edge.next;

            if (target == vertex) {
                // A degenerate triangle has two distinct edges instead of
                // three, and the self edge goes both ways by definition. It
                // can close another triangle's open edge and make the vertex
                // look manifold, so the vertex is marked as having several
                // open edges, which makes it locked or complex.
                openinc[vertex] = vertex;
                openout[vertex] = vertex;
            } else if (!hasEdge(adjacency, target, vertex)) {
                openinc[target] = if (openinc[target] == none) vertex else target;
                openout[vertex] = if (openout[vertex] == none) target else vertex;
            }
        }
    }

    for (0..vertex_count) |i| {
        if (remap[i] == i) {
            if (wedge[i] == i) {
                // No attribute seam: is it manifold?
                const openi = openinc[i];
                const openo = openout[i];

                // Vertices with no open edges are manifold. Strictly this
                // is wrong (four triangles on one edge make their vertices
                // manifold too), but it is unclear that it matters.
                if (openi == none and openo == none) {
                    result[i] = .manifold;
                } else if (openi != none and openo != none and
                    remap[openi] == remap[openo] and openi != i)
                {
                    // A half-seam, one vertex joined to both vertices of a
                    // seam, would pass as a border below; as a seam, the
                    // full seam vertex can collapse onto it.
                    result[i] = .seam;
                } else if (openi != i and openo != i) {
                    result[i] = .border;
                } else {
                    result[i] = .locked;
                }
            } else if (wedge[wedge[i]] == i) {
                // An attribute seam: seam or locked?
                const w = wedge[i];
                const openiv = openinc[i];
                const openov = openout[i];
                const openiw = openinc[w];
                const openow = openout[w];

                // A seam has one open half-edge at each vertex, and the edges
                // connect: they lead to the same positions.
                if (openiv != none and openiv != i and openov != none and openov != i and
                    openiw != none and openiw != w and openow != none and openow != w and
                    remap[openiv] == remap[openow] and remap[openov] == remap[openiw] and
                    remap[openiv] != remap[openov])
                {
                    result[i] = .seam;
                } else {
                    // Mismatched or disconnected seam ends: no class fits.
                    result[i] = .locked;
                }
            } else {
                // More than two vertices share the position: no class fits.
                result[i] = .locked;
            }
        } else {
            assert(remap[i] < i);

            result[i] = result[remap[i]];
        }
    }

    if (options.permissive) {
        for (0..vertex_count) |i| {
            if (result[i] != .seam and result[i] != .locked) continue;

            if (remap[i] != i) {
                // Only primary vertices are processed; wedges copy theirs.
                result[i] = result[remap[i]];
                continue;
            }

            var v: u32 = @intCast(i);

            // `vertex_lock` may protect any wedge, not only the primary
            // vertex: the vertex turns complex only if none is protected.
            var protect = false;
            while (true) {
                const rv = if (sparse_remap) |s| s[v] else v;
                if (vertex_lock) |locks| protect = protect or locks[rv].protect;
                v = wedge[v];
                if (v == i) break;
            }

            // An edge without an opposite puts the vertex on the border.
            var border = false;
            while (true) {
                for (adjacency.edgesOf(v)) |edge| {
                    border = border or !hasWedgeEdge(adjacency, edge.next, v, remap, wedge);
                }
                v = wedge[v];
                if (v == i) break;
            }

            // Border vertices with attribute discontinuities collapse only
            // along the border, so they get their own kind.
            if (!protect) result[i] = if (border) .fringe else .complex;
        }
    }

    if (vertex_lock) |locks| {
        // `vertex_lock` may lock any wedge, not only the primary vertex:
        // lock the primary vertex, then every wedge of a locked one.
        for (0..vertex_count) |i| {
            const ri = if (sparse_remap) |s| s[i] else i;

            if (locks[ri].lock) result[remap[i]] = .locked;
        }

        for (0..vertex_count) |i| {
            if (result[remap[i]] == .locked) result[i] = .locked;
        }
    }

    if (options.lock_border) {
        for (result) |*kind| {
            if (kind.* == .border or kind.* == .fringe) kind.* = .locked;
        }
    }
}

const Vector3 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

fn sub(a: Vector3, b: Vector3) Vector3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

fn cross(a: Vector3, b: Vector3) Vector3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

fn dot(a: Vector3, b: Vector3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

/// Copies the positions (through `sparse_remap`, if given) into `result`,
/// if given, scaled into the unit cube from the corner `out_offset`
/// receives, and returns the largest extent along an axis.
fn rescalePositions(
    result: ?[]Vector3,
    positions: VertexFloats,
    vertex_count: usize,
    sparse_remap: ?[]const u32,
    out_offset: ?*[3]f32,
) f32 {
    var minv: [3]f32 = @splat(float_max);
    var maxv: [3]f32 = @splat(-float_max);

    for (0..vertex_count) |i| {
        const ri: usize = if (sparse_remap) |s| s[i] else i;
        const v = positions.data[ri * positions.stride ..][0..3];

        if (result) |r| r[i] = .{ .x = v[0], .y = v[1], .z = v[2] };

        for (0..3) |j| {
            const vj = v[j];

            minv[j] = if (minv[j] > vj) vj else minv[j];
            maxv[j] = if (maxv[j] < vj) vj else maxv[j];
        }
    }

    var extent: f32 = 0;

    extent = if ((maxv[0] - minv[0]) < extent) extent else (maxv[0] - minv[0]);
    extent = if ((maxv[1] - minv[1]) < extent) extent else (maxv[1] - minv[1]);
    extent = if ((maxv[2] - minv[2]) < extent) extent else (maxv[2] - minv[2]);

    if (result) |r| {
        const scale: f32 = if (extent == 0) 0 else 1 / extent;

        for (r[0..vertex_count]) |*p| {
            p.x = (p.x - minv[0]) * scale;
            p.y = (p.y - minv[1]) * scale;
            p.z = (p.z - minv[2]) * scale;
        }
    }

    if (out_offset) |offset| offset.* = minv;

    return extent;
}

/// Copies the weighted attributes in `attribute_remap` into `result`, one
/// row of `attribute_remap.len` per vertex.
fn rescaleAttributes(
    result: []f32,
    attributes: VertexFloats,
    vertex_count: usize,
    attribute_weights: []const f32,
    attribute_remap: []const u32,
    sparse_remap: ?[]const u32,
) void {
    const attribute_count = attribute_remap.len;

    for (0..vertex_count) |i| {
        const ri: usize = if (sparse_remap) |s| s[i] else i;

        for (attribute_remap, 0..) |rk, k| {
            const a = attributes.data[ri * attributes.stride + rk];

            result[i * attribute_count + k] = a * attribute_weights[rk];
        }
    }
}

/// Writes the solved positions and attributes of the vertices in
/// `vertex_update` back to the caller's buffers, undoing the scaling.
fn finalizeVertices(
    positions: VertexFloatsMut,
    attributes: VertexFloatsMut,
    attribute_weights: []const f32,
    attribute_remap: []const u32,
    vertex_positions: []const Vector3,
    vertex_attributes: []const f32,
    sparse_remap: ?[]const u32,
    vertex_scale: f32,
    vertex_offset: [3]f32,
    vertex_kind: []const Kind,
    vertex_update: []const bool,
    vertex_lock: ?[]const SimplifyVertexFlags,
) void {
    const attribute_count = attribute_remap.len;

    for (vertex_update, 0..) |update, i| {
        if (!update) continue;

        const ri: usize = if (sparse_remap) |s| s[i] else i;

        // Vertices the caller locked are never updated.
        if (vertex_lock) |locks| if (locks[ri].lock) continue;

        // Moving locked vertices could drift them by rounding.
        if (vertex_kind[i] != .locked) {
            const p = vertex_positions[i];
            const v = positions.data[ri * positions.stride ..][0..3];

            v[0] = p.x * vertex_scale + vertex_offset[0];
            v[1] = p.y * vertex_scale + vertex_offset[1];
            v[2] = p.z * vertex_scale + vertex_offset[2];
        }

        if (attribute_count > 0) {
            const sa = vertex_attributes[i * attribute_count ..][0..attribute_count];
            const va = attributes.data[ri * attributes.stride ..];

            for (attribute_remap, sa) |rk, a| va[rk] = a / attribute_weights[rk];
        }
    }
}

/// a00*x^2 + a11*y^2 + a22*z^2 + 2*a10*xy + 2*a20*xz + 2*a21*yz + 2*b0*x +
/// 2*b1*y + 2*b2*z + c, and the weight it was built with.
const Quadric = extern struct {
    a00: f32,
    a11: f32,
    a22: f32,
    a10: f32,
    a20: f32,
    a21: f32,
    b0: f32,
    b1: f32,
    b2: f32,
    c: f32,
    w: f32,

    const zero = std.mem.zeroes(Quadric);

    fn add(q: *Quadric, r: Quadric) void {
        q.a00 += r.a00;
        q.a11 += r.a11;
        q.a22 += r.a22;
        q.a10 += r.a10;
        q.a20 += r.a20;
        q.a21 += r.a21;
        q.b0 += r.b0;
        q.b1 += r.b1;
        q.b2 += r.b2;
        q.c += r.c;
        q.w += r.w;
    }
};

/// gx*x + gy*y + gz*z + gw
const QuadricGrad = extern struct {
    gx: f32,
    gy: f32,
    gz: f32,
    gw: f32,

    const zero = std.mem.zeroes(QuadricGrad);

    fn add(g: *QuadricGrad, r: QuadricGrad) void {
        g.gx += r.gx;
        g.gy += r.gy;
        g.gz += r.gz;
        g.gw += r.gw;
    }
};

fn addGradients(g: []QuadricGrad, r: []const QuadricGrad) void {
    for (g, r) |*gk, rk| {
        gk.gx += rk.gx;
        gk.gy += rk.gy;
        gk.gz += rk.gz;
        gk.gw += rk.gw;
    }
}

/// A sum of points and colors in a grid cell, and their count.
const Reservoir = extern struct {
    x: f32,
    y: f32,
    z: f32,
    r: f32,
    g: f32,
    b: f32,
    w: f32,
};

/// An edge to collapse, `v0` onto `v1`.
const Collapse = extern struct {
    v0: u32,
    v1: u32,
    rank: extern union {
        /// Before ranking: 1 if the edge collapses either way, else 0.
        bidi: u32,
        /// After ranking: the error of the collapse, which then goes the
        /// cheaper way.
        cost: f32,
    },
};

fn normalize(v: *Vector3) f32 {
    const length = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);

    if (length > 0) {
        v.x /= length;
        v.y /= length;
        v.z /= length;
    }

    return length;
}

fn quadricEval(q: Quadric, v: Vector3) f32 {
    var rx = (q.b0 + q.a10 * v.y) * 2;
    var ry = (q.b1 + q.a21 * v.z) * 2;
    var rz = (q.b2 + q.a20 * v.x) * 2;

    rx += q.a00 * v.x;
    ry += q.a11 * v.y;
    rz += q.a22 * v.z;

    return q.c + rx * v.x + ry * v.y + rz * v.z;
}

fn quadricError(q: Quadric, v: Vector3) f32 {
    const r = quadricEval(q, v);
    const s: f32 = if (q.w == 0) 0 else 1 / q.w;

    return @abs(r) * s;
}

fn quadricErrorAttributes(
    q: Quadric,
    g: []const QuadricGrad,
    v: Vector3,
    va: []const f32,
    clamped: bool,
) f32 {
    var r = quadricEval(q, v);

    // Add the parts of (eval(pos) - attr)^2 that depend on attr; see
    // quadricFromAttributes for the derivation.
    for (g, va) |gk, a| {
        const e = v.x * gk.gx + v.y * gk.gy + v.z * gk.gz + gk.gw;

        r += a * (a * q.w - 2 * e);
    }

    // Unlike the position error, this is not divided by the weight, which
    // keeps the edge scaling described in quadricFromAttributes. Clamping
    // limits it to the summed weight (the area), which brings perceptual
    // error closer to position error.
    const e = @abs(r);
    return if (clamped) (if (e < q.w) e else q.w) else e;
}

fn quadricFromPlane(a: f32, b: f32, c: f32, d: f32, w: f32) Quadric {
    const aw = a * w;
    const bw = b * w;
    const cw = c * w;
    const dw = d * w;

    return .{
        .a00 = a * aw,
        .a11 = b * bw,
        .a22 = c * cw,
        .a10 = a * bw,
        .a20 = a * cw,
        .a21 = b * cw,
        .b0 = a * dw,
        .b1 = b * dw,
        .b2 = c * dw,
        .c = d * dw,
        .w = w,
    };
}

fn quadricFromPoint(x: f32, y: f32, z: f32, w: f32) Quadric {
    return .{
        .a00 = w,
        .a11 = w,
        .a22 = w,
        .a10 = 0,
        .a20 = 0,
        .a21 = 0,
        .b0 = -x * w,
        .b1 = -y * w,
        .b2 = -z * w,
        .c = (x * x + y * y + z * z) * w,
        .w = w,
    };
}

fn quadricFromTriangle(p0: Vector3, p1: Vector3, p2: Vector3, weight: f32) Quadric {
    const p10 = sub(p1, p0);
    const p20 = sub(p2, p0);

    var normal = cross(p10, p20);
    const area = normalize(&normal);

    const distance = dot(normal, p0);

    // The square root of the area scales the error linearly, which tends
    // to improve silhouettes.
    return quadricFromPlane(normal.x, normal.y, normal.z, -distance, @sqrt(area) * weight);
}

fn quadricFromTriangleEdge(p0: Vector3, p1: Vector3, p2: Vector3, weight: f32) Quadric {
    const p10 = sub(p1, p0);

    // The edge length, and its square for the projection below.
    const lengthsq = dot(p10, p10);
    const length = @sqrt(lengthsq);

    // The length of p2-p0's projection onto p1-p0, times |p1-p0|, as p10 is
    // not normalized.
    const p20 = sub(p2, p0);
    const p20p = dot(p20, p10);

    // The perpendicular from p2 to the edge. p10 is not normalized, so p20
    // is scaled instead, which the normalization below absorbs.
    var perp: Vector3 = .{
        .x = p20.x * lengthsq - p10.x * p20p,
        .y = p20.y * lengthsq - p10.y * p20p,
        .z = p20.z * lengthsq - p10.z * p20p,
    };
    _ = normalize(&perp);

    const distance = dot(perp, p0);

    // The weight scales linearly with the edge length, to match the
    // triangle weight.
    return quadricFromPlane(perp.x, perp.y, perp.z, -distance, length * weight);
}

fn quadricFromAttributes(
    g: []QuadricGrad,
    p0: Vector3,
    p1: Vector3,
    p2: Vector3,
    va0: []const f32,
    va1: []const f32,
    va2: []const f32,
) Quadric {
    // Each attribute adds (eval(pos) - attr)^2, where eval(pos) interpolates
    // the attribute across the triangle: pos.x * gx + pos.y * gy + pos.z * gz
    // + gw, with gx, gy, gz and gw its gradients.
    const p10 = sub(p1, p0);
    const p20 = sub(p2, p0);

    const normal = cross(p10, p20);
    const area = @sqrt(dot(normal, normal)) * 0.5;

    // The weight is the square of the edge length (the area), which gives
    // the error the units of the normalized position error (a squared
    // distance): a change in weighted attribute of 1 along a distance d is
    // about a change in position of d.
    const w = area;

    // The gradients come from barycentric coordinates:
    // v = (d11 * d20 - d01 * d21) / denom
    // w = (d00 * d21 - d01 * d20) / denom
    // u = 1 - v - w
    // with v0 and v1 the triangle's edges, v2 the vector from the point to
    // the corner, and dij = dot(vi, vj). v2 is the unknown, so d20 and d21
    // only appear in the derivation.
    const v0 = p10;
    const v1 = p20;
    const d00 = dot(v0, v0);
    const d01 = dot(v0, v1);
    const d11 = dot(v1, v1);
    const denom = d00 * d11 - d01 * d01;
    const denomr: f32 = if (denom == 0) 0 else 1 / denom;

    // Gradient factors, from the derivative of eval(pos) = a0 * u + a1 * v
    // + a2 * w with the parts every attribute shares taken out.
    const gx1 = (d11 * v0.x - d01 * v1.x) * denomr;
    const gx2 = (d00 * v1.x - d01 * v0.x) * denomr;
    const gy1 = (d11 * v0.y - d01 * v1.y) * denomr;
    const gy2 = (d00 * v1.y - d01 * v0.y) * denomr;
    const gz1 = (d11 * v0.z - d01 * v1.z) * denomr;
    const gz2 = (d00 * v1.z - d01 * v0.z) * denomr;

    var q: Quadric = .zero;

    q.w = w;

    for (g, va0, va1, va2) |*gk, a0, a1, a2| {
        // The gradient of eval(pos) in x, y, z and w.
        const gx = gx1 * (a1 - a0) + gx2 * (a2 - a0);
        const gy = gy1 * (a1 - a0) + gy2 * (a2 - a0);
        const gz = gz1 * (a1 - a0) + gz2 * (a2 - a0);
        const gw = a0 - p0.x * gx - p0.y * gy - p0.z * gz;

        // Expanding (eval(pos)-attr)^2 gives terms such as pos.x * pos.y * K,
        // which the quadric's own fields already hold, so almost all of it
        // accumulates there; each term is weighted here for simplicity.
        q.a00 += w * (gx * gx);
        q.a11 += w * (gy * gy);
        q.a22 += w * (gz * gz);

        q.a10 += w * (gy * gx);
        q.a20 += w * (gz * gx);
        q.a21 += w * (gz * gy);

        q.b0 += w * (gx * gw);
        q.b1 += w * (gy * gw);
        q.b2 += w * (gz * gw);

        q.c += w * (gw * gw);

        // The terms that depend on attr are added when the error is
        // evaluated; see quadricErrorAttributes.
        gk.* = .{ .gx = w * gx, .gy = w * gy, .gz = w * gz, .gw = w * gw };
    }

    return q;
}

fn quadricVolumeGradient(p0: Vector3, p1: Vector3, p2: Vector3) QuadricGrad {
    const p10 = sub(p1, p0);
    const p20 = sub(p2, p0);

    var normal = cross(p10, p20);
    const area = normalize(&normal) * 0.5;

    return .{
        .gx = normal.x * area,
        .gy = normal.y * area,
        .gz = normal.z * area,
        .gw = (-p0.x * normal.x - p0.y * normal.y - p0.z * normal.z) * area,
    };
}

/// Solves A*p = -b, with A the quadric's matrix and b its linear term, under
/// the linear constraint `gv`; false when the system is degenerate.
fn quadricSolve(p: *Vector3, q: Quadric, gv: QuadricGrad) bool {
    const a00 = q.a00;
    const a11 = q.a11;
    const a22 = q.a22;
    const a10 = q.a10;
    const a20 = q.a20;
    const a21 = q.a21;
    const x0 = -q.b0;
    const x1 = -q.b1;
    const x2 = -q.b2;

    const eps = 1e-6 * q.w;

    // LDL decomposition: A = LDL^T
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

    // Augment the system with the linear constraint, by a Lagrange
    // multiplier.
    const a30 = gv.gx;
    const a31 = gv.gy;
    const a32 = gv.gz;
    const x3 = -gv.gw;

    const l30 = a30 / d0;
    const dl31 = a31 - a30 * l10;
    const l31 = dl31 / d1;
    const dl32 = a32 - a30 * l20 - dl31 * l21;
    const l32 = dl32 / d2;
    const d3 = 0 - a30 * l30 - dl31 * l31 - dl32 * l32;

    const y3 = x3 - l30 * y0 - l31 * y1 - l32 * y2;
    // A zero d3 means the constraint can be ignored.
    const z3 = if (@abs(d3) > eps) y3 / d3 else 0;

    // Substitute L^T*p = z.
    const lambda = z3;
    const pz = z2 - l32 * lambda;
    const py = z1 - l21 * pz - l31 * lambda;
    const px = z0 - l10 * py - l20 * pz - l30 * lambda;

    p.* = .{ .x = px, .y = py, .z = pz };

    return @abs(d0) > eps and @abs(d1) > eps and @abs(d2) > eps;
}

/// Adds the attribute quadric `a` with gradients `g` to the vertex quadric
/// `q`, scaled by the vertex weight to minimize the normalized error.
fn quadricReduceAttributes(q: *Quadric, a: Quadric, g: []const QuadricGrad) void {
    q.a00 += a.a00 * q.w;
    q.a11 += a.a11 * q.w;
    q.a22 += a.a22 * q.w;
    q.a10 += a.a10 * q.w;
    q.a20 += a.a20 * q.w;
    q.a21 += a.a21 * q.w;
    q.b0 += a.b0 * q.w;
    q.b1 += a.b1 * q.w;
    q.b2 += a.b2 * q.w;

    const iaw: f32 = if (a.w == 0) 0 else q.w / a.w;

    // The linear system's update from the attribute gradients (BB^T/a).
    for (g) |gk| {
        q.a00 -= (gk.gx * gk.gx) * iaw;
        q.a11 -= (gk.gy * gk.gy) * iaw;
        q.a22 -= (gk.gz * gk.gz) * iaw;
        q.a10 -= (gk.gx * gk.gy) * iaw;
        q.a20 -= (gk.gx * gk.gz) * iaw;
        q.a21 -= (gk.gy * gk.gz) * iaw;

        q.b0 -= (gk.gx * gk.gw) * iaw;
        q.b1 -= (gk.gy * gk.gw) * iaw;
        q.b2 -= (gk.gz * gk.gw) * iaw;
    }
}

fn fillFaceQuadrics(
    vertex_quadrics: []Quadric,
    volume_gradients: ?[]QuadricGrad,
    indices: []const u32,
    vertex_positions: []const Vector3,
    remap: []const u32,
) void {
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const index0 = indices[i + 0];
        const index1 = indices[i + 1];
        const index2 = indices[i + 2];

        const p0 = vertex_positions[index0];
        const p1 = vertex_positions[index1];
        const p2 = vertex_positions[index2];

        const q = quadricFromTriangle(p0, p1, p2, 1);

        vertex_quadrics[remap[index0]].add(q);
        vertex_quadrics[remap[index1]].add(q);
        vertex_quadrics[remap[index2]].add(q);

        if (volume_gradients) |gradients| {
            const gv = quadricVolumeGradient(p0, p1, p2);

            gradients[remap[index0]].add(gv);
            gradients[remap[index1]].add(gv);
            gradients[remap[index2]].add(gv);
        }
    }
}

fn fillVertexQuadrics(
    vertex_quadrics: []Quadric,
    vertex_positions: []const Vector3,
    remap: []const u32,
    vertex_lock: ?[]const SimplifyVertexFlags,
    sparse_remap: ?[]const u32,
    options: SimplifyOptions,
) void {
    // By default, a very small weight improves triangulation and numerical
    // stability without changing the shape or the error.
    const factor: f32 = if (options.regularize_light)
        1e-2
    else if (options.regularize) 1e-1 else 1e-7;

    for (remap, 0..) |r, i| {
        if (r != i) continue;

        // Priority vertices get a larger regularization weight; only the
        // primary vertex is examined.
        const ri: usize = if (sparse_remap) |s| s[i] else i;
        const priority = if (vertex_lock) |locks| locks[ri].priority else false;

        const p = vertex_positions[i];
        const w = vertex_quadrics[i].w * (if (priority) 1.0 else factor);

        vertex_quadrics[i].add(quadricFromPoint(p.x, p.y, p.z, w));
    }
}

fn fillEdgeQuadrics(
    vertex_quadrics: []Quadric,
    indices: []const u32,
    vertex_positions: []const Vector3,
    remap: []const u32,
    vertex_kind: []const Kind,
    loop: []const u32,
    loopback: []const u32,
) void {
    const next = [4]usize{ 1, 2, 0, 1 };

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        for (0..3) |e| {
            const index0 = indices[i + e];
            const index1 = indices[i + next[e]];

            const k0 = vertex_kind[index0];
            const k1 = vertex_kind[index1];

            // Manifold vertices are never on a border.
            if (k0 == .manifold or k1 == .manifold) continue;

            // One end must be border, seam or fringe; the checks below
            // confirm the border.
            if (k0 != .border and k0 != .seam and k0 != .fringe and
                k1 != .border and k1 != .seam and k1 != .fringe) continue;

            // Border and seam ends must be on the same edge loop. Edges from
            // border to locked count too: without them, the next border to
            // border edge would get the wrong error at corners.
            if ((k0 == .border or k0 == .seam) and loop[index0] != index1) continue;

            if ((k1 == .border or k1 == .seam) and loopback[index1] != index0) continue;

            // Fringe vertices have no proper edge loops, so fringe to fringe
            // and fringe to locked edges get edge quadrics too; border to
            // fringe edges went through the loop check above.
            if ((k0 == .fringe or k1 == .fringe) and (k0 == .complex or k1 == .complex)) continue;

            const index2 = indices[i + next[e + 1]];

            // Border edges keep their geometry hard; seam edges move more
            // freely, as the collapse rules already constrain them and
            // their quadrics only slightly improve the result. The seam
            // weight applies twice, once per opposite edge.
            const edge_weight_seam = 0.5;
            const edge_weight_border = 10.0;

            const edge_weight: f32 = if (k0 == .seam or k1 == .seam)
                edge_weight_seam
            else
                edge_weight_border;

            const p0 = vertex_positions[index0];
            const p1 = vertex_positions[index1];
            const p2 = vertex_positions[index2];

            var q = quadricFromTriangleEdge(p0, p1, p2, edge_weight);

            var qt = quadricFromTriangle(p0, p1, p2, edge_weight);

            // The triangle quadric steadies collapses both ways; both carry
            // the edge weight so their errors add up.
            qt.w = 0;
            q.add(qt);

            vertex_quadrics[remap[index0]].add(q);
            vertex_quadrics[remap[index1]].add(q);
        }
    }
}

/// The vertex across the edge from `b` to `a`'s position, or `none` if
/// there is not exactly one.
fn oppositeVertex(
    adjacency: EdgeAdjacency,
    a: u32,
    b: u32,
    remap: []const u32,
    wedge: []const u32,
) u32 {
    var v = a;
    var r: u32 = none;

    while (true) {
        for (adjacency.edgesOf(v)) |edge| {
            if (remap[edge.next] == remap[b]) r = if (r == none) edge.prev else a;
        }

        v = wedge[v];
        if (v == a) break;
    }

    return if (r == a) none else r;
}

fn fillFoldQuadrics(
    vertex_quadrics: []Quadric,
    adjacency: EdgeAdjacency,
    vertex_positions: []const Vector3,
    remap: []const u32,
    wedge: []const u32,
) void {
    for (0..remap.len) |i| {
        const index0: u32 = @intCast(i);

        for (adjacency.edgesOf(index0)) |edge| {
            const index1 = edge.next;
            const index2 = edge.prev;

            // Paired edges come twice; take each once.
            if (remap[index1] > remap[index0]) continue;

            const index3 = oppositeVertex(adjacency, index1, index0, remap, wedge);

            if (index3 == none) continue;

            const p10 = sub(vertex_positions[index1], vertex_positions[index0]);
            const p20 = sub(vertex_positions[index2], vertex_positions[index0]);
            const p30 = sub(vertex_positions[index3], vertex_positions[index0]);

            const normal = cross(p10, p20);
            const opposite = cross(p30, p10);
            const nl = @sqrt(dot(normal, normal));
            const ol = @sqrt(dot(opposite, opposite));

            // A fold is a dihedral angle under a somewhat arbitrary cutoff
            // of about 30 degrees.
            if (dot(normal, opposite) >= -0.85 * nl * ol) continue;

            // Both triangles count, as this edge is not visited again.
            const p0 = vertex_positions[index0];
            const p1 = vertex_positions[index1];
            var q = quadricFromTriangleEdge(p0, p1, vertex_positions[index2], 1);
            const qo = quadricFromTriangleEdge(p0, p1, vertex_positions[index3], 1);
            q.add(qo);

            vertex_quadrics[remap[index0]].add(q);
            vertex_quadrics[remap[index1]].add(q);
        }
    }
}

fn fillAttributeQuadrics(
    attribute_quadrics: []Quadric,
    attribute_gradients: []QuadricGrad,
    indices: []const u32,
    vertex_positions: []const Vector3,
    vertex_attributes: []const f32,
    attribute_count: usize,
) void {
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const index0 = indices[i + 0];
        const index1 = indices[i + 1];
        const index2 = indices[i + 2];

        var gradients: [attribute_count_max]QuadricGrad = undefined;
        const g = gradients[0..attribute_count];
        const qa = quadricFromAttributes(
            g,
            vertex_positions[index0],
            vertex_positions[index1],
            vertex_positions[index2],
            vertex_attributes[index0 * attribute_count ..][0..attribute_count],
            vertex_attributes[index1 * attribute_count ..][0..attribute_count],
            vertex_attributes[index2 * attribute_count ..][0..attribute_count],
        );

        attribute_quadrics[index0].add(qa);
        attribute_quadrics[index1].add(qa);
        attribute_quadrics[index2].add(qa);

        addGradients(attribute_gradients[index0 * attribute_count ..][0..attribute_count], g);
        addGradients(attribute_gradients[index1 * attribute_count ..][0..attribute_count], g);
        addGradients(attribute_gradients[index2 * attribute_count ..][0..attribute_count], g);
    }
}

/// Whether triangle abc flips when c moves to d.
fn hasTriangleFlip(a: Vector3, b: Vector3, c: Vector3, d: Vector3) bool {
    const eb = sub(b, a);
    const ec = sub(c, a);
    const ed = sub(d, a);

    const nbc = cross(eb, ec);
    const nbd = cross(eb, ed);

    const ndp = dot(nbc, nbd);
    const abc = dot(nbc, nbc);
    const abd = dot(nbd, nbd);

    // The scale is the cosine of a somewhat arbitrary 75 degrees. The pure
    // check, ndp <= 0, a 90 degree cutoff, lets a series of collapses near
    // 90 degrees flip a triangle.
    return ndp <= 0.25 * @sqrt(abc * abd);
}

/// Whether collapsing `index0` onto `index1` flips a triangle around `index0`.
fn hasTriangleFlips(
    adjacency: EdgeAdjacency,
    vertex_positions: []const Vector3,
    collapse_remap: []const u32,
    index0: u32,
    index1: u32,
) bool {
    assert(collapse_remap[index0] == index0);
    assert(collapse_remap[index1] == index1);

    const v0 = vertex_positions[index0];
    const v1 = vertex_positions[index1];

    for (adjacency.edgesOf(index0)) |edge| {
        const a = collapse_remap[edge.next];
        const b = collapse_remap[edge.prev];

        // Skip triangles this collapse removes, and ones already collapsed.
        if (a == index1 or b == index1 or a == b) continue;

        // One flip is enough to refuse the collapse.
        if (hasTriangleFlip(vertex_positions[a], vertex_positions[b], v0, v1)) return true;
    }

    return false;
}

/// Whether moving `index0` to `v1` flips a triangle around it.
fn hasTriangleFlipsAt(
    adjacency: EdgeAdjacency,
    vertex_positions: []const Vector3,
    index0: u32,
    v1: Vector3,
) bool {
    const v0 = vertex_positions[index0];

    for (adjacency.edgesOf(index0)) |edge| {
        const a = edge.next;
        const b = edge.prev;

        if (hasTriangleFlip(vertex_positions[a], vertex_positions[b], v0, v1)) return true;
    }

    return false;
}

fn getNeighborhoodRadius(
    adjacency: EdgeAdjacency,
    vertex_positions: []const Vector3,
    index0: u32,
) f32 {
    const v0 = vertex_positions[index0];

    var result: f32 = 0;

    for (adjacency.edgesOf(index0)) |edge| {
        const va = vertex_positions[edge.next];
        const vb = vertex_positions[edge.prev];

        const da = (va.x - v0.x) * (va.x - v0.x) + (va.y - v0.y) * (va.y - v0.y) +
            (va.z - v0.z) * (va.z - v0.z);
        const db = (vb.x - v0.x) * (vb.x - v0.x) + (vb.y - v0.y) * (vb.y - v0.y) +
            (vb.z - v0.z) * (vb.z - v0.z);

        result = if (result < da) da else result;
        result = if (result < db) db else result;
    }

    return @sqrt(result);
}

/// The wedge of `target`'s position that wedge `v` of a complex vertex
/// collapses to.
fn getComplexTarget(
    v: u32,
    target: u32,
    remap: []const u32,
    loop: []const u32,
    loopback: []const u32,
) u32 {
    const r = remap[target];

    // The loops guide complex collapses to the right wedge: on attribute
    // discontinuities they hold the single unpaired half-edge, as on seams.
    if (loop[v] != none and remap[loop[v]] == r) {
        return loop[v];
    } else if (loopback[v] != none and remap[loopback[v]] == r) {
        return loopback[v];
    } else {
        return target;
    }
}

fn boundEdgeCollapses(
    adjacency: EdgeAdjacency,
    index_count: usize,
    vertex_kind: []const Kind,
) usize {
    var dual_count: usize = 0;

    for (vertex_kind, 0..) |k, i| {
        const e = adjacency.offsets[i + 1] - adjacency.offsets[i];

        dual_count += if (k == .manifold or k == .seam) e else 0;
    }

    // Three spare entries let the overflow check run once per triangle
    // instead of once per edge.
    return (index_count - dual_count / 2) + 3;
}

fn pickEdgeCollapses(
    collapses: []Collapse,
    indices: []const u32,
    remap: []const u32,
    vertex_kind: []const Kind,
    loop: []const u32,
    loopback: []const u32,
) usize {
    const next = [3]usize{ 1, 2, 0 };

    var collapse_count: usize = 0;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        // boundEdgeCollapses bounds the count, so this should never happen;
        // if it does, the extra collapses are dropped.
        if (collapse_count + 3 > collapses.len) break;

        for (0..3) |e| {
            const index0 = indices[i + e];
            const index1 = indices[i + next[e]];

            // A zero-length input edge, or a manifold vertex joined to both
            // wedges of a seam collapsed onto one of them in complex
            // topology. These edges may hold the mesh together, so they
            // stay.
            if (remap[index0] == remap[index1]) continue;

            const k0 = vertex_kind[index0];
            const k1 = vertex_kind[index1];

            // The edge must collapse at least one way.
            if (!(canCollapse(k0, k1) or canCollapse(k1, k0))) continue;

            // Manifold and seam edges come twice (index0->index1 and index1->index0): skip
            // one.
            if (hasOpposite(k0, k1) and remap[index1] > remap[index0]) continue;

            // Two border or seam vertices without an edge between them are
            // on different edge loops, and the edge must not collapse. The
            // loops track half-edges, so checking one is enough.
            if ((k0 == .border or k0 == .seam) and k1 != .manifold and loop[index0] != index1)
                continue;
            if ((k1 == .border or k1 == .seam) and k0 != .manifold and loopback[index1] != index0)
                continue;

            if (canCollapse(k0, k1) and canCollapse(k1, k0)) {
                // Either way: ranking picks the cheaper one later.
                collapses[collapse_count] = .{ .v0 = index0, .v1 = index1, .rank = .{ .bidi = 1 } };
            } else {
                // One way only.
                const e0 = if (canCollapse(k0, k1)) index0 else index1;
                const e1 = if (canCollapse(k0, k1)) index1 else index0;

                collapses[collapse_count] = .{ .v0 = e0, .v1 = e1, .rank = .{ .bidi = 0 } };
            }
            collapse_count += 1;
        }
    }

    return collapse_count;
}

fn rankEdgeCollapses(
    collapses: []Collapse,
    vertex_positions: []const Vector3,
    vertex_attributes: []const f32,
    vertex_quadrics: []const Quadric,
    attribute_quadrics: []const Quadric,
    attribute_gradients: []const QuadricGrad,
    attribute_count: usize,
    remap: []const u32,
    wedge: []const u32,
    vertex_kind: []const Kind,
    loop: []const u32,
    loopback: []const u32,
    clamped: bool,
) void {
    for (collapses) |*c| {
        const index0 = c.v0;
        const index1 = c.v1;
        const bidi = c.rank.bidi != 0;

        var ei = quadricError(vertex_quadrics[remap[index0]], vertex_positions[index1]);
        var ej = if (bidi)
            quadricError(vertex_quadrics[remap[index1]], vertex_positions[index0])
        else
            float_max;

        if (attribute_count > 0) {
            const attribute_error: AttributeError = .{
                .vertex_positions = vertex_positions,
                .vertex_attributes = vertex_attributes,
                .attribute_quadrics = attribute_quadrics,
                .attribute_gradients = attribute_gradients,
                .attribute_count = attribute_count,
                .clamped = clamped,
            };

            ei += attribute_error.of(index0, index1);
            ej += if (bidi) attribute_error.of(index1, index0) else 0;

            // Seam edges add the errors of both sides, as each side has its
            // own attribute quadrics.
            if (vertex_kind[index0] == .seam) {
                // The seam pair comes from the edge loops, as the target
                // vertex may be locked and have more than two wedges.
                const s0 = wedge[index0];
                var s1 = if (loop[index0] == index1) loopback[s0] else loop[s0];

                // s0 is index0 for half-seams.
                assert(wedge[s0] == index0);
                assert(s1 != none and remap[s1] == remap[index1]);

                // The assert above rules this out; if it were off and this
                // happened, the reads below would go out of bounds.
                s1 = if (s1 != none) s1 else wedge[index1];

                ei += attribute_error.of(s0, s1);
                ej += if (bidi) attribute_error.of(s1, s0) else 0;
            } else {
                // Complex edges can have several wedges: add the errors of
                // all of them, each to its target.
                if (vertex_kind[index0] == .complex or vertex_kind[index0] == .fringe) {
                    var v = wedge[index0];
                    while (v != index0) : (v = wedge[v]) {
                        const t = getComplexTarget(v, index1, remap, loop, loopback);

                        ei += attribute_error.of(v, t);
                    }
                }

                if ((vertex_kind[index1] == .complex or vertex_kind[index1] == .fringe) and bidi) {
                    var v = wedge[index1];
                    while (v != index1) : (v = wedge[v]) {
                        const t = getComplexTarget(v, index0, remap, loop, loopback);

                        ej += attribute_error.of(v, t);
                    }
                }
            }
        }

        // The cheaper way, without a branch.
        const rev = bidi and ej < ei;

        c.v0 = if (rev) index1 else index0;
        c.v1 = if (rev) index0 else index1;
        c.rank = .{ .cost = if (ej < ei) ej else ei };
    }
}

/// The attribute error of moving one vertex onto another.
const AttributeError = struct {
    vertex_positions: []const Vector3,
    vertex_attributes: []const f32,
    attribute_quadrics: []const Quadric,
    attribute_gradients: []const QuadricGrad,
    attribute_count: usize,
    clamped: bool,

    fn of(self: AttributeError, from: u32, to: u32) f32 {
        const n = self.attribute_count;
        return quadricErrorAttributes(
            self.attribute_quadrics[from],
            self.attribute_gradients[from * n ..][0..n],
            self.vertex_positions[to],
            self.vertex_attributes[to * n ..][0..n],
            self.clamped,
        );
    }
};

// A counting sort by error. The exact order matters little, so only the
// top 12 bits of exponent and mantissa (8 of exponent, 4 of mantissa)
// count, and the exponent range is clamped to keep the histogram small,
// as collapses with errors much above 1 are of no use.
const sort_bits = 12;
const sort_bins = 2048 + 512; // exponents in [-127, 32)

fn sortKey(c: Collapse) u32 {
    // The sign bit is dropped, as errors are not negative.
    const bits: u32 = @bitCast(c.rank.cost);
    const key = (bits << 1) >> (32 - sort_bits);
    return if (key < sort_bins) key else sort_bins - 1;
}

fn sortEdgeCollapses(sort_order: []u32, collapses: []const Collapse) void {
    // The histogram.
    var histogram: [sort_bins]u32 = @splat(0);

    for (collapses) |c| histogram[sortKey(c)] += 1;

    // Offsets from the histogram.
    var histogram_sum: usize = 0;

    for (&histogram) |*h| {
        const count = h.*;
        h.* = @intCast(histogram_sum);
        histogram_sum += count;
    }

    // The sort order from the offsets.
    for (collapses, 0..) |c, i| {
        const key = sortKey(c);

        sort_order[histogram[key]] = @intCast(i);
        histogram[key] += 1;
    }
}

fn performEdgeCollapses(
    collapse_remap: []u32,
    collapse_locked: []bool,
    collapses: []const Collapse,
    collapse_order: []const u32,
    remap: []const u32,
    wedge: []const u32,
    vertex_kind: []const Kind,
    loop: []const u32,
    loopback: []const u32,
    vertex_positions: []const Vector3,
    adjacency: EdgeAdjacency,
    triangle_collapse_goal: usize,
    error_limit: f32,
    result_error: *f32,
) usize {
    var edge_collapses: usize = 0;
    var triangle_collapses: usize = 0;

    // Most collapses remove 2 triangles, which bounds the pass by the error
    // limit. This is an estimate; the triangle goal is the real limit.
    var edge_collapse_goal = triangle_collapse_goal / 2;

    for (collapse_order) |order| {
        const c = collapses[order];
        const cost = c.rank.cost;

        if (cost > error_limit) break;

        if (triangle_collapses >= triangle_collapse_goal) break;

        // Each pass's error is limited by the error of the best last
        // collapse. Many collapses get locked by sharing vertices with
        // successful ones, so the acceptable error grows by a factor.
        const error_goal = if (edge_collapse_goal < collapses.len)
            1.5 * collapses[collapse_order[edge_collapse_goal]].rank.cost
        else
            float_max;

        // Each collapse locks about 6 others on average; to avoid useless
        // passes on meshes of odd topology, stop only after 1/6 of the
        // collapses.
        if (cost > error_goal and cost > result_error.* and
            triangle_collapses > triangle_collapse_goal / 6) break;

        const index0 = c.v0;
        const index1 = c.v1;

        const r0 = remap[index0];
        const r1 = remap[index1];

        const kind = vertex_kind[index0];

        // A vertex never moves twice, which would complicate the remap,
        // and nothing moves onto a moved vertex, as collapses are not
        // re-ranked within a pass and the error would be wrong.
        if (collapse_locked[r0] or collapse_locked[r1]) continue;

        if (hasTriangleFlips(adjacency, vertex_positions, collapse_remap, r0, r1)) {
            // This collapse is invalid and must not count toward the error
            // goal.
            edge_collapse_goal += 1;

            continue;
        }

        if (kind == .complex or kind == .fringe) {
            collapse_remap[index0] = index1;

            // Every wedge moves to its target, ranked as in
            // rankEdgeCollapses.
            var v = wedge[index0];
            while (v != index0) : (v = wedge[v]) {
                collapse_remap[v] = getComplexTarget(v, index1, remap, loop, loopback);
            }
        } else if (kind == .seam) {
            // The seam pair moves together; it comes from the edge loops,
            // as the target vertex may be locked and have more than two
            // wedges.
            const s0 = wedge[index0];
            var s1 = if (loop[index0] == index1) loopback[s0] else loop[s0];
            // s0 is index0 for half-seams.
            assert(wedge[s0] == index0);
            assert(s1 != none and remap[s1] == r1);

            // The seam pair is consistent.
            assert(kind != vertex_kind[index1] or s1 == wedge[index1]);
            assert(loop[index0] == index1 or loopback[index0] == index1);
            assert(loop[s0] == s1 or loopback[s0] == s1);

            // The asserts above rule this out; if they were off and this
            // happened, the write below would go out of bounds.
            s1 = if (s1 != none) s1 else wedge[index1];

            collapse_remap[index0] = index1;
            collapse_remap[s0] = s1;
        } else {
            assert(wedge[index0] == index0);

            collapse_remap[index0] = index1;
        }

        // r1 need not be locked when it is a locked vertex, which cannot
        // move and whose quadric goes unused; but locking it keeps locked
        // collapses from an unfair scheduling advantage, which slightly
        // improves the error on some meshes.
        collapse_locked[r0] = true;
        collapse_locked[r1] = true;

        // Border edges collapse 1 triangle, others 2 or more. Fringe edges
        // often collapse 1 but may collapse 2, as they ignore loops, so they
        // count as 2.
        triangle_collapses += if (kind == .border) 1 else 2;
        edge_collapses += 1;

        result_error.* = if (result_error.* < cost) cost else result_error.*;
    }

    return edge_collapses;
}

fn updateQuadrics(
    collapse_remap: []const u32,
    vertex_quadrics: []Quadric,
    volume_gradients: ?[]QuadricGrad,
    attribute_quadrics: []Quadric,
    attribute_gradients: []QuadricGrad,
    attribute_count: usize,
    vertex_positions: []const Vector3,
    remap: []const u32,
    vertex_error: *f32,
) void {
    for (collapse_remap, 0..) |target, i| {
        if (target == i) continue;

        const index0: u32 = @intCast(i);
        const index1 = target;

        const r0 = remap[index0];
        const r1 = remap[index1];

        // The vertex quadrics update once: the primary vertex moves if any
        // wedge does.
        if (index0 == r0) {
            vertex_quadrics[r1].add(vertex_quadrics[r0]);

            if (volume_gradients) |gradients| gradients[r1].add(gradients[r0]);
        }

        if (attribute_count > 0) {
            attribute_quadrics[index1].add(attribute_quadrics[index0]);
            addGradients(
                attribute_gradients[index1 * attribute_count ..][0..attribute_count],
                attribute_gradients[index0 * attribute_count ..][0..attribute_count],
            );

            if (index0 == r0) {
                // With attributes, collapses do not track the distance
                // error, so it is computed here; doing so after the quadric
                // update is safe.
                const derr = quadricError(vertex_quadrics[r0], vertex_positions[r1]);
                vertex_error.* = if (vertex_error.* < derr) derr else vertex_error.*;
            }
        }
    }
}

fn solvePositions(
    vertex_positions: []Vector3,
    vertex_quadrics: []const Quadric,
    volume_gradients: ?[]const QuadricGrad,
    attribute_quadrics: []const Quadric,
    attribute_gradients: []const QuadricGrad,
    attribute_count: usize,
    remap: []const u32,
    wedge: []const u32,
    adjacency: EdgeAdjacency,
    vertex_kind: []const Kind,
    vertex_update: []const bool,
) void {
    for (vertex_update, 0..) |update, i| {
        if (!update) continue;

        // Moving vertices on an attribute discontinuity may extrapolate
        // texture coordinates outside their chart; moving border vertices
        // would need a stronger edge quadric to keep the border's shape.
        if (vertex_kind[i] != .manifold and vertex_kind[i] != .complex) continue;

        if (remap[i] != i) {
            vertex_positions[i] = vertex_positions[remap[i]];
            continue;
        }

        const vp = vertex_positions[i];

        var q = vertex_quadrics[i];
        var gv: QuadricGrad = .zero;

        // A point quadric regularizes the solution.
        q.add(quadricFromPoint(vp.x, vp.y, vp.z, q.w * 1e-4));

        if (attribute_count > 0) {
            // The best point minimizes the attribute quadrics of all wedges
            // at once.
            var v: u32 = @intCast(i);
            while (true) {
                quadricReduceAttributes(
                    &q,
                    attribute_quadrics[v],
                    attribute_gradients[v * attribute_count ..][0..attribute_count],
                );
                v = wedge[v];
                if (v == i) break;
            }

            // Minimizing the attribute quadrics loses volume, so the volume
            // gradient constrains the solution.
            if (volume_gradients) |gradients| gv = gradients[i];
        }

        var p: Vector3 = undefined;
        if (!quadricSolve(&p, q, gv)) continue;

        // Refuse updates that move the vertex too far from its
        // neighborhood, which catches most ill-defined quadrics.
        const nr = getNeighborhoodRadius(adjacency, vertex_positions, @intCast(i));
        const dp = (p.x - vp.x) * (p.x - vp.x) + (p.y - vp.y) * (p.y - vp.y) +
            (p.z - vp.z) * (p.z - vp.z);

        if (dp > nr * nr) continue;

        // Refuse updates that flip a neighboring triangle, as collapses do.
        if (hasTriangleFlipsAt(adjacency, vertex_positions, @intCast(i), p)) continue;

        // Refuse updates that increase the position error too much; some
        // tolerance improves attribute quality.
        if (quadricError(vertex_quadrics[i], p) > quadricError(vertex_quadrics[i], vp) * 1.5 + 1e-6)
            continue;

        vertex_positions[i] = p;
    }
}

fn solveAttributes(
    vertex_positions: []const Vector3,
    vertex_attributes: []f32,
    attribute_quadrics: []const Quadric,
    attribute_gradients: []const QuadricGrad,
    attribute_count: usize,
    remap: []const u32,
    wedge: []const u32,
    vertex_kind: []const Kind,
    vertex_update: []const bool,
) void {
    for (vertex_update, 0..) |update, i| {
        if (!update) continue;

        if (remap[i] != i) continue;

        for (0..attribute_count) |k| {
            var shared: u32 = none;

            // Complex vertices keep attribute continuity: where the wedges
            // share a value, they take the heaviest wedge's.
            if (vertex_kind[i] == .complex or vertex_kind[i] == .fringe) {
                shared = @intCast(i);

                var v = wedge[i];
                while (v != i) : (v = wedge[v]) {
                    if (vertex_attributes[v * attribute_count + k] !=
                        vertex_attributes[i * attribute_count + k])
                    {
                        shared = none;
                    } else if (shared != none and
                        attribute_quadrics[v].w > attribute_quadrics[shared].w)
                    {
                        shared = v;
                    }
                }
            }

            // Update every wedge.
            var v: u32 = @intCast(i);
            while (true) {
                const r = if (shared == none) v else shared;

                const p = vertex_positions[i]; // the same for every wedge
                const a = attribute_quadrics[r];
                const g = attribute_gradients[r * attribute_count + k];

                const iw: f32 = if (a.w == 0) 0 else 1 / a.w;
                const av = (g.gx * p.x + g.gy * p.y + g.gz * p.z + g.gw) * iw;

                vertex_attributes[v * attribute_count + k] = av;
                v = wedge[v];
                if (v == i) break;
            }
        }
    }
}

/// Applies the pass's collapses to `indices`, dropping triangles left with
/// two corners at one position, and returns how many indices are left.
fn remapIndexBuffer(indices: []u32, collapse_remap: []const u32, remap: []const u32) usize {
    var write: usize = 0;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const v0 = collapse_remap[indices[i + 0]];
        const v1 = collapse_remap[indices[i + 1]];
        const v2 = collapse_remap[indices[i + 2]];

        // A pass never moves a vertex twice.
        assert(collapse_remap[v0] == v0);
        assert(collapse_remap[v1] == v1);
        assert(collapse_remap[v2] == v2);

        // Zero-area triangles go even when they are not degenerate in
        // topology: manifold to seam collapses onto a seam pair, complex
        // collapses and other collapses across wedges leave them.
        const r0 = remap[v0];
        const r1 = remap[v1];
        const r2 = remap[v2];

        if (r0 != r1 and r0 != r2 and r1 != r2) {
            indices[write..][0..3].* = .{ v0, v1, v2 };
            write += 3;
        }
    }

    return write;
}

fn remapEdgeLoops(loop: []u32, collapse_remap: []const u32) void {
    for (0..loop.len) |i| {
        // This leaves the loops of moved vertices alone. They go unused,
        // and clearing them would take another pass, as the remap needs
        // them.
        if (loop[i] != none) {
            const l = loop[i];
            const r = collapse_remap[l];

            // i == r when the seam edge collapses against the loop's
            // direction.
            if (i == r) {
                loop[i] = if (loop[l] != none) collapse_remap[loop[l]] else none;
            } else {
                loop[i] = r;
            }
        }
    }
}

fn follow(parents: []u32, start: u32) u32 {
    var index = start;

    while (index != parents[index]) {
        const parent = parents[index];
        parents[index] = parents[parent];
        index = parent;
    }

    return index;
}

/// Numbers the connected parts of the mesh, by position, from 0 in order
/// of their smallest vertex, and returns how many there are.
fn buildComponents(components: []u32, indices: []const u32, remap: []const u32) usize {
    const next = [4]usize{ 1, 2, 0, 1 };

    for (components, 0..) |*c, i| c.* = @intCast(i);

    // A unique (not sequential) number for each component, by union-find.
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        for (0..3) |e| {
            const index0 = indices[i + e];
            const index1 = indices[i + next[e]];

            const r0 = follow(components, remap[index0]);
            const r1 = follow(components, remap[index1]);

            // The larger root joins the smaller, so a component's root is
            // always its smallest vertex.
            if (r0 != r1) components[@max(r0, r1)] = @min(r0, r1);
        }
    }

    // Every element points to its root before the renumbering.
    for (components, remap, 0..) |*c, r, v| {
        if (r == v) c.* = follow(components, @intCast(v));
    }

    var next_component: u32 = 0;

    // Sequential numbers. One pass is enough, as a root is its component's
    // smallest vertex. follow() is unsafe here, as the links are being
    // replaced by numbers in place.
    for (remap, 0..) |r, v| {
        if (r == v) {
            const root = components[v];
            components[v] = if (root == v) next_component else components[root];
            if (root == v) next_component += 1;
        } else {
            assert(r < v);
            components[v] = components[r];
        }
    }

    return next_component;
}

/// Fills `component_errors[0..component_count]` with each component's
/// squared radius around its average point; `component_errors` holds 4
/// floats per component, which serve as scratch.
fn measureComponents(
    component_errors: []f32,
    component_count: usize,
    components: []const u32,
    vertex_positions: []const Vector3,
) void {
    @memset(component_errors[0 .. component_count * 4], 0);

    // An approximate center for each component: the average.
    for (components, vertex_positions) |c, v| {
        assert(c < component_count);

        component_errors[c * 4 + 0] += v.x;
        component_errors[c * 4 + 1] += v.y;
        component_errors[c * 4 + 2] += v.z;
        component_errors[c * 4 + 3] += 1; // weight
    }

    // Finish the centers; [3] becomes the radius.
    for (0..component_count) |i| {
        const w = component_errors[i * 4 + 3];
        const iw: f32 = if (w == 0) 0 else 1 / w;

        component_errors[i * 4 + 0] *= iw;
        component_errors[i * 4 + 1] *= iw;
        component_errors[i * 4 + 2] *= iw;
        component_errors[i * 4 + 3] = 0; // radius
    }

    // The squared radius of each component.
    for (components, vertex_positions) |c, v| {
        const dx = v.x - component_errors[c * 4 + 0];
        const dy = v.y - component_errors[c * 4 + 1];
        const dz = v.z - component_errors[c * 4 + 2];
        const r = dx * dx + dy * dy + dz * dz;

        const radius = &component_errors[c * 4 + 3];
        radius.* = if (radius.* < r) r else radius.*;
    }

    // Move the results to their places. The error stays squared, to match
    // the quadric error.
    for (0..component_count) |i| component_errors[i] = component_errors[i * 4 + 3];
}

/// Drops the triangles of components whose error is at most
/// `error_cutoff`, returns how many indices are left, and sets `nexterror`
/// to the smallest error of the components left.
fn pruneComponents(
    indices: []u32,
    components: []const u32,
    component_errors: []const f32,
    error_cutoff: f32,
    nexterror: *f32,
) usize {
    var write: usize = 0;
    var min_error: f32 = float_max;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const v0 = indices[i + 0];
        const v1 = indices[i + 1];
        const v2 = indices[i + 2];
        const c = components[v0];
        assert(c == components[v1] and c == components[v2]);

        if (component_errors[c] > error_cutoff) {
            min_error = if (min_error > component_errors[c]) component_errors[c] else min_error;

            indices[write..][0..3].* = .{ v0, v1, v2 };
            write += 3;
        }
    }

    nexterror.* = min_error;
    return write;
}

/// Hashes and compares vertices by their grid cell ids, or ids themselves
/// when `vertex_ids` is null.
const CellHasher = struct {
    vertex_ids: ?[]const u32,

    pub fn hash(self: CellHasher, i: u32) u32 {
        var h = if (self.vertex_ids) |ids| ids[i] else i;

        // MurmurHash2 finalizer
        h ^= h >> 13;
        h *%= 0x5bd1e995;
        h ^= h >> 15;
        return h;
    }

    pub fn equal(self: CellHasher, lhs: u32, rhs: u32) bool {
        const ids = self.vertex_ids orelse return lhs == rhs;
        return ids[lhs] == ids[rhs];
    }
};

/// Hashes and compares triangles by number, in `indices`.
const TriangleHasher = struct {
    indices: []const u32,

    pub fn hash(self: TriangleHasher, i: u32) u32 {
        const tri = self.indices[i * 3 ..][0..3];

        return (tri[0] *% 73856093) ^ (tri[1] *% 19349663) ^ (tri[2] *% 83492791);
    }

    pub fn equal(self: TriangleHasher, lhs: u32, rhs: u32) bool {
        const lt = self.indices[lhs * 3 ..][0..3];
        const rt = self.indices[rhs * 3 ..][0..3];

        return lt[0] == rt[0] and lt[1] == rt[1] and lt[2] == rt[2];
    }
};

/// Each vertex's cell in a grid of `grid_size` cells per side over the unit
/// cube, as one id; locked vertices get cells of their own.
fn computeVertexIds(
    vertex_ids: []u32,
    vertex_positions: []const Vector3,
    vertex_lock: ?[]const SimplifyVertexFlags,
    grid_size: i32,
) void {
    assert(grid_size >= 1 and grid_size <= 1024);
    const cell_scale: f32 = @floatFromInt(grid_size - 1);

    // Eight vertices at a time: Zig leaves the loop below scalar, where
    // clang vectorizes the original's.
    const lanes = 8;
    const Floats = @Vector(lanes, f32);
    const Ids = @Vector(lanes, u32);
    const floats: []const f32 = @ptrCast(vertex_positions);
    var start: usize = 0;
    while (start + lanes <= vertex_ids.len) : (start += lanes) {
        const xyz: @Vector(3 * lanes, f32) = floats[start * 3 ..][0 .. 3 * lanes].*;
        var cells: [3]Ids = undefined;
        inline for (&cells, 0..) |*cell, axis| {
            const along = @shuffle(f32, xyz, undefined, everyThird(lanes, axis));
            const scaled = along * @as(Floats, @splat(cell_scale)) + @as(Floats, @splat(0.5));
            cell.* = @bitCast(convert.truncateLanes(lanes, scaled));
        }
        var ids = (cells[0] << @splat(20)) | (cells[1] << @splat(10)) | cells[2];
        if (vertex_lock) |locks| {
            const flags: @Vector(lanes, u8) = @bitCast(locks[start..][0..lanes].*);
            const lock: u8 = @bitCast(SimplifyVertexFlags{ .lock = true });
            const lock_bit: @Vector(lanes, u8) = @splat(lock);
            const locked = flags & lock_bit != @as(@Vector(lanes, u8), @splat(0));
            const first: u32 = @intCast(start);
            const own = std.simd.iota(u32, lanes) + @as(Ids, @splat(1 << 30 | first));
            ids = @select(u32, locked, own, ids);
        }
        vertex_ids[start..][0..lanes].* = ids;
    }

    for (vertex_ids[start..], vertex_positions[start..], start..) |*id, v, i| {
        const xi: u32 = @bitCast(truncateToInt(v.x * cell_scale + 0.5));
        const yi: u32 = @bitCast(truncateToInt(v.y * cell_scale + 0.5));
        const zi: u32 = @bitCast(truncateToInt(v.z * cell_scale + 0.5));

        const locked = if (vertex_lock) |locks| locks[i].lock else false;
        id.* = if (locked) 1 << 30 | @as(u32, @intCast(i)) else (xi << 20) | (yi << 10) | zi;
    }
}

/// The shuffle mask that takes lane `first`, then every third lane after
/// it, `n` lanes in all.
fn everyThird(comptime n: usize, comptime first: usize) [n]i32 {
    var mask: [n]i32 = undefined;
    for (&mask, 0..) |*m, i| m.* = @intCast(first + 3 * i);
    return mask;
}

fn countTriangles(vertex_ids: []const u32, indices: []const u32) usize {
    var result: usize = 0;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const id0 = vertex_ids[indices[i + 0]];
        const id1 = vertex_ids[indices[i + 1]];
        const id2 = vertex_ids[indices[i + 2]];

        result += @intFromBool(id0 != id1 and id0 != id2 and id1 != id2);
    }

    return result;
}

/// Numbers the cells vertices fall into from 0, in order of their first
/// vertex, and returns how many there are.
fn fillVertexCells(table: []u32, vertex_cells: []u32, vertex_ids: []const u32) usize {
    const hasher: CellHasher = .{ .vertex_ids = vertex_ids };

    @memset(table, none);

    var result: u32 = 0;

    for (vertex_cells, 0..) |*cell, i| {
        const entry = hashLookup(u32, table, hasher, @intCast(i), none);

        if (table[entry] == none) {
            table[entry] = @intCast(i);
            cell.* = result;
            result += 1;
        } else {
            cell.* = vertex_cells[table[entry]];
        }
    }

    return result;
}

fn countVertexCells(table: []u32, vertex_ids: []const u32) usize {
    const hasher: CellHasher = .{ .vertex_ids = null };

    @memset(table, none);

    var result: usize = 0;

    for (vertex_ids) |id| {
        const entry = hashLookup(u32, table, hasher, id, none);

        result += @intFromBool(table[entry] == none);
        table[entry] = id;
    }

    return result;
}

fn fillCellQuadrics(
    cell_quadrics: []Quadric,
    indices: []const u32,
    vertex_positions: []const Vector3,
    vertex_cells: []const u32,
) void {
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const index0 = indices[i + 0];
        const index1 = indices[i + 1];
        const index2 = indices[i + 2];

        const c0 = vertex_cells[index0];
        const c1 = vertex_cells[index1];
        const c2 = vertex_cells[index2];

        const single_cell = c0 == c1 and c0 == c2;

        const q = quadricFromTriangle(
            vertex_positions[index0],
            vertex_positions[index1],
            vertex_positions[index2],
            if (single_cell) 3 else 1,
        );

        if (single_cell) {
            cell_quadrics[c0].add(q);
        } else {
            cell_quadrics[c0].add(q);
            cell_quadrics[c1].add(q);
            cell_quadrics[c2].add(q);
        }
    }
}

fn fillCellReservoirs(
    cell_reservoirs: []Reservoir,
    vertex_positions: []const Vector3,
    colors: ?VertexFloats,
    vertex_cells: []const u32,
) void {
    const dummy_color = [3]f32{ 0, 0, 0 };

    for (vertex_cells, vertex_positions, 0..) |cell, v, i| {
        const r = &cell_reservoirs[cell];

        const color = if (colors) |c| c.data[i * c.stride ..][0..3] else &dummy_color;

        r.x += v.x;
        r.y += v.y;
        r.z += v.z;
        r.r += color[0];
        r.g += color[1];
        r.b += color[2];
        r.w += 1;
    }

    for (cell_reservoirs) |*r| {
        const iw: f32 = if (r.w == 0) 0 else 1 / r.w;

        r.x *= iw;
        r.y *= iw;
        r.z *= iw;
        r.r *= iw;
        r.g *= iw;
        r.b *= iw;
    }
}

/// Picks the vertex of least quadric error in each cell.
fn fillCellRemap(
    cell_remap: []u32,
    cell_errors: []f32,
    vertex_cells: []const u32,
    cell_quadrics: []const Quadric,
    vertex_positions: []const Vector3,
) void {
    @memset(cell_remap, none);

    for (vertex_cells, vertex_positions, 0..) |cell, v, i| {
        const err = quadricError(cell_quadrics[cell], v);

        if (cell_remap[cell] == none or cell_errors[cell] > err) {
            cell_remap[cell] = @intCast(i);
            cell_errors[cell] = err;
        }
    }
}

/// Picks the vertex closest to the cell's average point and color in each
/// cell.
fn fillCellRemapColors(
    cell_remap: []u32,
    cell_errors: []f32,
    vertex_cells: []const u32,
    cell_reservoirs: []const Reservoir,
    vertex_positions: []const Vector3,
    colors: ?VertexFloats,
    color_weight: f32,
) void {
    const dummy_color = [3]f32{ 0, 0, 0 };

    @memset(cell_remap, none);

    for (vertex_cells, vertex_positions, 0..) |cell, v, i| {
        const r = cell_reservoirs[cell];

        const color = if (colors) |c| c.data[i * c.stride ..][0..3] else &dummy_color;

        const pos_error = (v.x - r.x) * (v.x - r.x) + (v.y - r.y) * (v.y - r.y) +
            (v.z - r.z) * (v.z - r.z);
        const col_error = (color[0] - r.r) * (color[0] - r.r) +
            (color[1] - r.g) * (color[1] - r.g) + (color[2] - r.b) * (color[2] - r.b);
        const err = pos_error + color_weight * col_error;

        if (cell_remap[cell] == none or cell_errors[cell] > err) {
            cell_remap[cell] = @intCast(i);
            cell_errors[cell] = err;
        }
    }
}

/// Writes the triangles whose corners fall in three different cells to
/// `destination`, each corner moved to its cell's vertex and duplicates
/// dropped, and returns how many indices it wrote. Writes trail the reads,
/// so `destination` may be `indices`.
fn filterTriangles(
    destination: []u32,
    tritable: []u32,
    indices: []const u32,
    vertex_cells: []const u32,
    cell_remap: []const u32,
) usize {
    const hasher: TriangleHasher = .{ .indices = destination };

    @memset(tritable, none);

    var result: usize = 0;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const c0 = vertex_cells[indices[i + 0]];
        const c1 = vertex_cells[indices[i + 1]];
        const c2 = vertex_cells[indices[i + 2]];

        if (c0 != c1 and c0 != c2 and c1 != c2) {
            var a = cell_remap[c0];
            var b = cell_remap[c1];
            var c = cell_remap[c2];

            if (b < a and b < c) {
                const t = a;
                a = b;
                b = c;
                c = t;
            } else if (c < a and c < b) {
                const t = c;
                c = b;
                b = a;
                a = t;
            }

            destination[result * 3 ..][0..3].* = .{ a, b, c };

            const entry = hashLookup(u32, tritable, hasher, @intCast(result), none);

            if (tritable[entry] == none) {
                tritable[entry] = @intCast(result);
                result += 1;
            }
        }
    }

    return result * 3;
}

fn interpolate(y: f32, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    // Three-point interpolation, from the "revenge of interpolation search"
    // paper.
    const num = (y1 - y) * (x1 - x2) * (x1 - x0) * (y2 - y0);
    const den = (y2 - y) * (x1 - x2) * (y0 - y1) + (y0 - y) * (x1 - x0) * (y1 - y2);
    return x1 + (if (den == 0) 0 else num / den);
}

/// The edge-collapse simplifier that `simplify`, `simplifyWithAttributes`
/// and `simplifyWithUpdate` run, under the original's name for it, which
/// its library exports without declaring. `positions` and `attributes` are
/// both `VertexFloats`, or both `VertexFloatsMut` when
/// `options.internal_solve` asks to move the kept vertices, as
/// `simplifyWithUpdate` does; the result then goes to `destination`, which
/// may be `indices` itself.
pub fn simplifyEdge(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    positions: anytype,
    attributes: anytype,
    attribute_weights: []const f32,
    vertex_lock: ?[]const SimplifyVertexFlags,
    target_index_count: usize,
    target_error: f32,
    options: SimplifyOptions,
    result_error: ?*f32,
) Allocator.Error!usize {
    const Floats = @TypeOf(positions);
    if (comptime (Floats != VertexFloats and Floats != VertexFloatsMut) or
        @TypeOf(attributes) != Floats)
    {
        @compileError("simplifyEdge takes positions and attributes as both VertexFloats " ++
            "or both VertexFloatsMut");
    }
    const writable = Floats == VertexFloatsMut;
    assert(writable or !options.internal_solve);

    const position_view: VertexFloats = if (writable) positions.toConst() else positions;
    const attribute_view: VertexFloats = if (writable) attributes.toConst() else attributes;

    assert(indices.len % 3 == 0);
    assert(position_view.stride >= 3 and position_view.stride <= 64);
    assert(target_index_count <= indices.len);
    assert(target_error >= 0);
    assert(attribute_view.stride >= attribute_weights.len and attribute_view.stride <= 64);
    assert(attribute_weights.len <= attribute_count_max);
    for (attribute_weights) |w| assert(w >= 0);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const result = destination[0..indices.len];
    if (result.ptr != indices.ptr) @memcpy(result, indices);

    // A remap to the vertices the indices use, and indices and a vertex
    // count rewritten to it, keep the work below small. The errors are then
    // relative to the extents of that part of the mesh.
    const sparse_remap: ?[]const u32 = if (options.sparse)
        try buildSparseRemap(&scratch, result, position_view.count())
    else
        null;
    const vertex_count = if (sparse_remap) |s| s.len else position_view.count();

    // Adjacency.
    const adjacency: EdgeAdjacency = try .init(&scratch, indices.len, vertex_count);
    adjacency.update(result, vertex_count, null);

    // Each vertex's first vertex of the same position, and the cycle of
    // vertices at each position (its wedges).
    const remap = try scratch.alloc(u32, vertex_count);
    const wedge = try scratch.alloc(u32, vertex_count);
    try buildPositionRemap(&scratch, remap, wedge, position_view, sparse_remap);

    // Vertex kinds, which set what collapses are allowed (can_collapse).
    const vertex_kind = try scratch.alloc(Kind, vertex_count);
    const loop = try scratch.alloc(u32, vertex_count);
    const loopback = try scratch.alloc(u32, vertex_count);
    classifyVertices(
        vertex_kind,
        loop,
        loopback,
        adjacency,
        remap,
        wedge,
        vertex_lock,
        sparse_remap,
        options,
    );

    const vertex_positions = try scratch.alloc(Vector3, vertex_count);
    var vertex_offset: [3]f32 = @splat(0);
    const vertex_scale = rescalePositions(
        vertex_positions,
        position_view,
        vertex_count,
        sparse_remap,
        &vertex_offset,
    );

    var vertex_attributes: []f32 = &.{};
    var attribute_remap_buffer: [attribute_count_max]u32 = undefined;
    var attribute_count: usize = 0;

    if (attribute_weights.len > 0) {
        // Only attributes of positive weight take part, which saves memory
        // and work on the quadrics.
        for (attribute_weights, 0..) |w, i| {
            if (w > 0) {
                attribute_remap_buffer[attribute_count] = @intCast(i);
                attribute_count += 1;
            }
        }

        vertex_attributes = try scratch.alloc(f32, vertex_count * attribute_count);
        rescaleAttributes(
            vertex_attributes,
            attribute_view,
            vertex_count,
            attribute_weights,
            attribute_remap_buffer[0..attribute_count],
            sparse_remap,
        );
    }
    const attribute_remap = attribute_remap_buffer[0..attribute_count];

    const vertex_quadrics = try scratch.alloc(Quadric, vertex_count);
    @memset(vertex_quadrics, .zero);

    var attribute_quadrics: []Quadric = &.{};
    var attribute_gradients: []QuadricGrad = &.{};
    var volume_gradients: ?[]QuadricGrad = null;

    if (attribute_count > 0) {
        attribute_quadrics = try scratch.alloc(Quadric, vertex_count);
        @memset(attribute_quadrics, .zero);

        attribute_gradients = try scratch.alloc(QuadricGrad, vertex_count * attribute_count);
        @memset(attribute_gradients, .zero);

        if (options.internal_solve) {
            volume_gradients = try scratch.alloc(QuadricGrad, vertex_count);
            @memset(volume_gradients.?, .zero);
        }
    }

    fillFaceQuadrics(vertex_quadrics, volume_gradients, result, vertex_positions, remap);
    fillVertexQuadrics(
        vertex_quadrics,
        vertex_positions,
        remap,
        vertex_lock,
        sparse_remap,
        options,
    );
    fillEdgeQuadrics(vertex_quadrics, result, vertex_positions, remap, vertex_kind, loop, loopback);

    if (options.preserve_folds) {
        fillFoldQuadrics(vertex_quadrics, adjacency, vertex_positions, remap, wedge);
    }

    if (attribute_count > 0) {
        fillAttributeQuadrics(
            attribute_quadrics,
            attribute_gradients,
            result,
            vertex_positions,
            vertex_attributes,
            attribute_count,
        );
    }

    var components: []u32 = &.{};
    var component_errors: []f32 = &.{};
    var component_count: usize = 0;
    var component_nexterror: f32 = 0;

    if (options.prune) {
        components = try scratch.alloc(u32, vertex_count);
        component_count = buildComponents(components, result, remap);

        // Four floats per component, as measureComponents needs scratch.
        component_errors = try scratch.alloc(f32, component_count * 4);
        measureComponents(component_errors, component_count, components, vertex_positions);

        component_nexterror = float_max;
        for (component_errors[0..component_count]) |e| {
            component_nexterror = if (component_nexterror > e) e else component_nexterror;
        }
    }

    const collapse_capacity = boundEdgeCollapses(adjacency, indices.len, vertex_kind);

    const edge_collapses = try scratch.alloc(Collapse, collapse_capacity);
    const collapse_order = try scratch.alloc(u32, collapse_capacity);
    const collapse_remap = try scratch.alloc(u32, vertex_count);
    const collapse_locked = try scratch.alloc(bool, vertex_count);

    var result_count = indices.len;
    // Squared, in the units of the quadric error, as is vertex_error.
    var result_error_squared: f32 = 0;
    var vertex_error: f32 = 0;

    // The target error is linear; the quadric error is squared.
    const error_scale: f32 = if (options.error_absolute) vertex_scale else 1;
    const error_limit = (target_error * target_error) / (error_scale * error_scale);

    while (result_count > target_index_count) {
        // The adjacency follows the welded topology of the result so far.
        adjacency.update(result[0..result_count], vertex_count, remap);

        const edge_collapse_count = pickEdgeCollapses(
            edge_collapses,
            result[0..result_count],
            remap,
            vertex_kind,
            loop,
            loopback,
        );

        // The topology allows no more collapses.
        if (edge_collapse_count == 0) break;

        const pass_collapses = edge_collapses[0..edge_collapse_count];
        const pass_order = collapse_order[0..edge_collapse_count];

        rankEdgeCollapses(
            pass_collapses,
            vertex_positions,
            vertex_attributes,
            vertex_quadrics,
            attribute_quadrics,
            attribute_gradients,
            attribute_count,
            remap,
            wedge,
            vertex_kind,
            loop,
            loopback,
            options.error_clamped,
        );

        sortEdgeCollapses(pass_order, pass_collapses);

        const triangle_collapse_goal = (result_count - target_index_count) / 3;

        for (collapse_remap, 0..) |*r, i| r.* = @intCast(i);

        @memset(collapse_locked, false);

        const collapses = performEdgeCollapses(
            collapse_remap,
            collapse_locked,
            pass_collapses,
            pass_order,
            remap,
            wedge,
            vertex_kind,
            loop,
            loopback,
            vertex_positions,
            adjacency,
            triangle_collapse_goal,
            error_limit,
            &result_error_squared,
        );

        // The error limit or the triangle goal allows no more collapses.
        if (collapses == 0) break;

        updateQuadrics(
            collapse_remap,
            vertex_quadrics,
            volume_gradients,
            attribute_quadrics,
            attribute_gradients,
            attribute_count,
            vertex_positions,
            remap,
            &vertex_error,
        );

        // updateQuadrics updates the vertex error when there are
        // attributes; without them it equals the result error.
        vertex_error = if (attribute_count == 0) result_error_squared else vertex_error;

        // The loops follow the collapses but may still go stale, when a
        // triangle with a loop edge collapses along another edge. A loop
        // that leads to a vertex no longer connected does not change the
        // collapse logic, so that is fine.
        remapEdgeLoops(loop, collapse_remap);
        remapEdgeLoops(loopback, collapse_remap);

        result_count = remapIndexBuffer(result[0..result_count], collapse_remap, remap);

        if (options.prune and result_count > target_index_count and
            component_nexterror <= vertex_error)
        {
            result_count = pruneComponents(
                result[0..result_count],
                components,
                component_errors,
                vertex_error,
                &component_nexterror,
            );
        }
    }

    // component_nexterror may be stale now: its component may be gone
    // after a series of collapses.
    var component_nextstale = true;

    // Simplification is done but short of the target: prune harder, up to
    // the error limit.
    while (options.prune and result_count > target_index_count and
        component_nexterror <= error_limit)
    {
        const component_cutoff = if (component_nexterror * 1.5 < error_limit)
            component_nexterror * 1.5
        else
            error_limit;

        // The largest error of the components to go, as the result error
        // grows.
        var component_maxerror: f32 = 0;
        for (component_errors[0..component_count]) |e| {
            if (e > component_maxerror and e <= component_cutoff) component_maxerror = e;
        }

        const new_count = pruneComponents(
            result[0..result_count],
            components,
            component_errors,
            component_cutoff,
            &component_nexterror,
        );
        if (new_count == result_count and !component_nextstale) break;

        // pruneComponents leaves the next error up to date.
        component_nextstale = false;
        result_count = new_count;
        result_error_squared = if (result_error_squared < component_maxerror)
            component_maxerror
        else
            result_error_squared;
        vertex_error = if (vertex_error < component_maxerror) component_maxerror else vertex_error;
    }

    // Write the solved vertices back to the caller's buffers.
    if (writable and options.internal_solve) {
        // collapse_locked serves as scratch.
        const vertex_update = collapse_locked;
        @memset(vertex_update, false);

        // Only vertices the result still uses are solved.
        for (result[0..result_count]) |v| {
            // The vertex for finalizeVertices, its primary for the solve.
            vertex_update[remap[v]] = true;
            vertex_update[v] = true;
        }

        // The adjacency may be stale after the last collapses.
        adjacency.update(result[0..result_count], vertex_count, remap);

        solvePositions(
            vertex_positions,
            vertex_quadrics,
            volume_gradients,
            attribute_quadrics,
            attribute_gradients,
            attribute_count,
            remap,
            wedge,
            adjacency,
            vertex_kind,
            vertex_update,
        );

        if (attribute_count > 0) {
            solveAttributes(
                vertex_positions,
                vertex_attributes,
                attribute_quadrics,
                attribute_gradients,
                attribute_count,
                remap,
                wedge,
                vertex_kind,
                vertex_update,
            );
        }

        finalizeVertices(
            positions,
            attributes,
            attribute_weights,
            attribute_remap,
            vertex_positions,
            vertex_attributes,
            sparse_remap,
            vertex_scale,
            vertex_offset,
            vertex_kind,
            vertex_update,
            vertex_lock,
        );
    }

    // Debug data in place of the index data; for simplicity, not with
    // sparsity.
    if (options.internal_debug and sparse_remap == null) {
        // 3 bits of kind, 1 of loop.
        comptime assert(kind_count <= 8);
        assert(vertex_count < 1 << 28);

        var i: usize = 0;
        while (i < result_count) : (i += 3) {
            const a = result[i + 0];
            const b = result[i + 1];
            const c = result[i + 2];

            result[i + 0] |= debugBits(vertex_kind[a], loop[a] == b or loopback[b] == a);
            result[i + 1] |= debugBits(vertex_kind[b], loop[b] == c or loopback[c] == b);
            result[i + 2] |= debugBits(vertex_kind[c], loop[c] == a or loopback[a] == c);
        }
    }

    // Back to the numbering of the whole mesh.
    if (sparse_remap) |s| {
        for (result[0..result_count]) |*r| r.* = s[r.*];
    }

    // The error was squared; it goes out linear.
    if (result_error) |out| out.* = @sqrt(result_error_squared) * error_scale;

    return result_count;
}

fn debugBits(kind: Kind, on_loop: bool) u32 {
    return @as(u32, @backingInt(kind)) << 28 | @as(u32, @intFromBool(on_loop)) << 31;
}

/// Reduces the triangles of the mesh `indices` and `positions` describe,
/// keeping its appearance as well as it can, and returns the number of
/// indices left, which `destination` holds. It stops short of
/// `target_index_count` where the topology or `target_error` forbids
/// further collapses. The result uses the original vertices; drop the
/// unused ones with `optimizeVertexFetch`. Reindex the mesh without
/// attributes it does not need first, so they do not split vertices.
///
/// `destination` needs room for every index, not only the target count,
/// and may be `indices` itself. Positions are the first three floats of
/// each vertex. `target_error` is relative to the mesh's extents (0.01 for
/// 1% deformation) unless `options.error_absolute` is set; `result_error`,
/// if given, receives the error reached, in the same units.
pub fn simplify(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    positions: VertexFloats,
    target_index_count: usize,
    target_error: f32,
    options: SimplifyOptions,
    result_error: ?*f32,
) Allocator.Error!usize {
    // simplifyWithUpdate moves vertices.
    assert(!options.internal_solve);

    const no_attributes: VertexFloats = .{ .data = &.{}, .stride = 1 };
    return simplifyEdge(
        gpa,
        destination,
        indices,
        positions,
        no_attributes,
        &.{},
        null,
        target_index_count,
        target_error,
        options,
        result_error,
    );
}

/// `simplify` with an error metric that weighs vertex attributes too:
/// `attribute_weights.len` floats at the start of each vertex of
/// `attributes`, at most 32, each weighed against the others and against
/// position by its weight in `attribute_weights` (the attributes are not
/// read when there are no weights). The number of attributes of nonzero
/// weight sets the memory and time it takes.
///
/// `vertex_lock`, if given, holds flags for every vertex.
pub fn simplifyWithAttributes(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    positions: VertexFloats,
    attributes: VertexFloats,
    attribute_weights: []const f32,
    vertex_lock: ?[]const SimplifyVertexFlags,
    target_index_count: usize,
    target_error: f32,
    options: SimplifyOptions,
    result_error: ?*f32,
) Allocator.Error!usize {
    // simplifyWithUpdate moves vertices.
    assert(!options.internal_solve);

    return simplifyEdge(
        gpa,
        destination,
        indices,
        positions,
        attributes,
        attribute_weights,
        vertex_lock,
        target_index_count,
        target_error,
        options,
        result_error,
    );
}

/// `simplifyWithAttributes` that also moves the vertices it keeps, and
/// their attributes, for the best appearance: it simplifies `indices` in
/// place, returns the number of indices left, and writes the new positions
/// and attribute values over the old ones (attributes of zero weight stay
/// as they are). Copy the vertices first if the originals are still
/// needed, and compact them with `optimizeVertexFetch` after.
pub fn simplifyWithUpdate(
    gpa: Allocator,
    indices: []u32,
    positions: VertexFloatsMut,
    attributes: VertexFloatsMut,
    attribute_weights: []const f32,
    vertex_lock: ?[]const SimplifyVertexFlags,
    target_index_count: usize,
    target_error: f32,
    options: SimplifyOptions,
    result_error: ?*f32,
) Allocator.Error!usize {
    var solve = options;
    solve.internal_solve = true;

    return simplifyEdge(
        gpa,
        indices,
        indices,
        positions,
        attributes,
        attribute_weights,
        vertex_lock,
        target_index_count,
        target_error,
        solve,
        result_error,
    );
}

/// Reduces the triangles of the mesh fast, at the cost of its appearance,
/// by merging the vertices in each cell of a grid; it ignores the topology,
/// and returns the number of indices left, which `destination` holds. It
/// stops short of `target_index_count` where `target_error`, relative to
/// the mesh's extents and at most 1, forbids a coarser grid; `result_error`,
/// if given, receives the relative error reached. The result uses the
/// original vertices.
///
/// `destination` needs room for every index, not only the target count,
/// and may be `indices` itself. `vertex_lock`, if given, holds flags for
/// every vertex; set `lock` alike on all vertices of a position.
pub fn simplifySloppy(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    positions: VertexFloats,
    vertex_lock: ?[]const SimplifyVertexFlags,
    target_index_count: usize,
    target_error: f32,
    result_error: ?*f32,
) Allocator.Error!usize {
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);
    assert(target_index_count <= indices.len);
    assert(target_error >= 0);

    const vertex_count = positions.count();

    // About 2 triangles per vertex come out.
    const target_cell_count = target_index_count / 6;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const vertex_positions = try scratch.alloc(Vector3, vertex_count);
    _ = rescalePositions(vertex_positions, positions, vertex_count, null, null);

    // The grid size, by a guided binary search.
    const vertex_ids = try scratch.alloc(u32, vertex_count);

    const interpolation_passes = 5;

    // The triangles of min_grid are never more than the target.
    const clamped_error: f32 = if (target_error < 1e-3)
        1e-3
    else if (target_error < 1) target_error else 1;
    var min_grid = truncateToInt(1 / clamped_error);
    var max_grid: i32 = 1025;
    var min_triangles: usize = 0;
    var max_triangles = indices.len / 3;

    // When the error limits the grid, counting min_grid's triangles speeds
    // up the search and gives the answer when no larger grid will do.
    if (min_grid > 1 or vertex_lock != null) {
        computeVertexIds(vertex_ids, vertex_positions, vertex_lock, min_grid);
        min_triangles = countTriangles(vertex_ids, indices);
    }

    // Start from a guess instead of the middle: the triangle count usually
    // grows as the square of the grid size.
    var next_grid_size = truncateToInt(@sqrt(toFloat(target_cell_count)) + 0.5);

    for (0..10 + interpolation_passes) |pass| {
        if (min_triangles >= target_index_count / 3 or max_grid - min_grid <= 1) break;

        // Clamping the guess makes the search converge.
        var grid_size = next_grid_size;
        grid_size = if (grid_size <= min_grid)
            min_grid + 1
        else if (grid_size >= max_grid) max_grid - 1 else grid_size;

        computeVertexIds(vertex_ids, vertex_positions, vertex_lock, grid_size);
        const triangles = countTriangles(vertex_ids, indices);

        const tip = interpolate(
            toFloat(target_index_count / 3),
            @floatFromInt(min_grid),
            toFloat(min_triangles),
            @floatFromInt(grid_size),
            toFloat(triangles),
            @floatFromInt(max_grid),
            toFloat(max_triangles),
        );

        if (triangles <= target_index_count / 3) {
            min_grid = grid_size;
            min_triangles = triangles;
        } else {
            max_grid = grid_size;
            max_triangles = triangles;
        }

        // Interpolation search usually converges faster, but its worst case
        // is O(N), so binary search, O(log N), takes over after a few passes.
        next_grid_size = if (pass < interpolation_passes)
            truncateToInt(tip + 0.5)
        else
            @divTrunc(min_grid + max_grid, 2);
    }

    if (min_triangles == 0) {
        if (result_error) |out| out.* = 1;

        return 0;
    }

    // Vertices of the same quantized position share a cell.
    const table = try scratch.alloc(u32, hashBuckets(vertex_count));

    const vertex_cells = try scratch.alloc(u32, vertex_count);

    computeVertexIds(vertex_ids, vertex_positions, vertex_lock, min_grid);
    const cell_count = fillVertexCells(table, vertex_cells, vertex_ids);

    // A quadric for each cell.
    const cell_quadrics = try scratch.alloc(Quadric, cell_count);
    @memset(cell_quadrics, .zero);

    fillCellQuadrics(cell_quadrics, indices, vertex_positions, vertex_cells);

    // The vertex of least error in each cell.
    const cell_remap = try scratch.alloc(u32, cell_count);
    const cell_errors = try scratch.alloc(f32, cell_count);

    fillCellRemap(cell_remap, cell_errors, vertex_cells, cell_quadrics, vertex_positions);

    // The error.
    var max_error: f32 = 0;

    for (cell_errors) |e| max_error = if (max_error < e) e else max_error;

    // Merged vertices often leave duplicate triangles, which a table
    // filters out.
    const tritable = try scratch.alloc(u32, hashBuckets(min_triangles));

    // The only write to destination, which lets it be indices.
    const write = filterTriangles(destination, tritable, indices, vertex_cells, cell_remap);

    if (result_error) |out| out.* = @sqrt(max_error);

    return write;
}

/// Removes the small disconnected parts of the mesh: those whose radius,
/// relative to the mesh's extents, is at most `target_error` (at most 1).
/// Returns the number of indices left, which `destination` holds; the
/// result uses the original vertices. `destination` needs room for every
/// index and may be `indices` itself.
pub fn simplifyPrune(
    gpa: Allocator,
    destination: []u32,
    indices: []const u32,
    positions: VertexFloats,
    target_error: f32,
) Allocator.Error!usize {
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);
    assert(target_error >= 0);

    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const result = destination[0..indices.len];
    if (result.ptr != indices.ptr) @memcpy(result, indices);

    // Each vertex's first vertex of the same position.
    const remap = try scratch.alloc(u32, vertex_count);
    try buildPositionRemap(&scratch, remap, null, positions, null);

    const vertex_positions = try scratch.alloc(Vector3, vertex_count);
    _ = rescalePositions(vertex_positions, positions, vertex_count, null, null);

    const components = try scratch.alloc(u32, vertex_count);
    const component_count = buildComponents(components, indices, remap);

    // Four floats per component, as measureComponents needs scratch.
    const component_errors = try scratch.alloc(f32, component_count * 4);
    measureComponents(component_errors, component_count, components, vertex_positions);

    var component_nexterror: f32 = 0;
    return pruneComponents(
        result,
        components,
        component_errors,
        target_error * target_error,
        &component_nexterror,
    );
}

/// Reduces a point cloud to about `target_vertex_count` points, merging
/// the points in each cell of a grid, and returns the number of points
/// left, whose vertex indices `destination` holds (room for
/// `target_vertex_count`). `colors`, if given, holds three floats at the
/// start of each vertex, weighed against position by `color_weight` (1 is
/// a safe default).
pub fn simplifyPoints(
    gpa: Allocator,
    destination: []u32,
    positions: VertexFloats,
    colors: ?VertexFloats,
    color_weight: f32,
    target_vertex_count: usize,
) Allocator.Error!usize {
    assert(positions.stride >= 3 and positions.stride <= 64);
    if (colors) |c| assert(c.stride >= 3 and c.stride <= 64);

    const vertex_count = positions.count();
    assert(target_vertex_count <= vertex_count);

    const target_cell_count = target_vertex_count;

    if (target_cell_count == 0) return 0;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const vertex_positions = try scratch.alloc(Vector3, vertex_count);
    _ = rescalePositions(vertex_positions, positions, vertex_count, null, null);

    // The grid size, by a guided binary search.
    const vertex_ids = try scratch.alloc(u32, vertex_count);

    const table = try scratch.alloc(u32, hashBuckets(vertex_count));

    const interpolation_passes = 5;

    // The vertices of min_grid are never more than the target.
    var min_grid: i32 = 0;
    var max_grid: i32 = 1025;
    var min_vertices: usize = 0;
    var max_vertices = vertex_count;

    // Start from a guess instead of the middle: the point count of a
    // surface usually grows as the square of the grid size.
    var next_grid_size = truncateToInt(@sqrt(toFloat(target_cell_count)) + 0.5);

    for (0..10 + interpolation_passes) |pass| {
        // Clamping the guess makes the search converge.
        var grid_size = next_grid_size;
        grid_size = if (grid_size <= min_grid)
            min_grid + 1
        else if (grid_size >= max_grid) max_grid - 1 else grid_size;

        computeVertexIds(vertex_ids, vertex_positions, null, grid_size);
        const vertices = countVertexCells(table, vertex_ids);

        const tip = interpolate(
            toFloat(target_vertex_count),
            @floatFromInt(min_grid),
            toFloat(min_vertices),
            @floatFromInt(grid_size),
            toFloat(vertices),
            @floatFromInt(max_grid),
            toFloat(max_vertices),
        );

        if (vertices <= target_vertex_count) {
            min_grid = grid_size;
            min_vertices = vertices;
        } else {
            max_grid = grid_size;
            max_vertices = vertices;
        }

        if (vertices == target_vertex_count or max_grid - min_grid <= 1) break;

        // Interpolation search usually converges faster, but its worst case
        // is O(N), so binary search, O(log N), takes over after a few passes.
        next_grid_size = if (pass < interpolation_passes)
            truncateToInt(tip + 0.5)
        else
            @divTrunc(min_grid + max_grid, 2);
    }

    if (min_vertices == 0) return 0;

    // Vertices of the same quantized position share a cell.
    const vertex_cells = try scratch.alloc(u32, vertex_count);

    computeVertexIds(vertex_ids, vertex_positions, null, min_grid);
    const cell_count = fillVertexCells(table, vertex_cells, vertex_ids);

    // A reservoir of the points in each cell.
    const cell_reservoirs = try scratch.alloc(Reservoir, cell_count);
    @memset(cell_reservoirs, std.mem.zeroes(Reservoir));

    fillCellReservoirs(cell_reservoirs, vertex_positions, colors, vertex_cells);

    // The vertex of least error in each cell.
    const cell_remap = try scratch.alloc(u32, cell_count);
    const cell_errors = try scratch.alloc(f32, cell_count);

    // The color weight scales to the grid, so color and position errors
    // add up in the same units.
    const color_weight_scaled = color_weight *
        (if (min_grid == 1) 1 else 1 / @as(f32, @floatFromInt(min_grid - 1)));

    fillCellRemapColors(
        cell_remap,
        cell_errors,
        vertex_cells,
        cell_reservoirs,
        vertex_positions,
        colors,
        color_weight_scaled * color_weight_scaled,
    );

    // The search counted the same cells.
    assert(cell_count <= target_vertex_count);
    @memcpy(destination[0..cell_count], cell_remap);

    return cell_count;
}

/// The factor between the simplifiers' relative errors and absolute ones:
/// the mesh's largest extent along an axis. Divide an absolute error by it
/// to pass it as `target_error`; multiply a `result_error` by it to get an
/// absolute one.
pub fn simplifyScale(positions: VertexFloats) f32 {
    assert(positions.stride >= 3 and positions.stride <= 64);

    return rescalePositions(null, positions, positions.count(), null, null);
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "options keep the original's bits" {
    const Bits = struct {
        fn of(options: SimplifyOptions) u32 {
            return @bitCast(options);
        }
    };
    try testing.expectEqual(1 << 0, Bits.of(.{ .lock_border = true }));
    try testing.expectEqual(1 << 1, Bits.of(.{ .sparse = true }));
    try testing.expectEqual(1 << 2, Bits.of(.{ .error_absolute = true }));
    try testing.expectEqual(1 << 3, Bits.of(.{ .prune = true }));
    try testing.expectEqual(1 << 4, Bits.of(.{ .regularize = true }));
    try testing.expectEqual(1 << 5, Bits.of(.{ .permissive = true }));
    try testing.expectEqual(1 << 6, Bits.of(.{ .regularize_light = true }));
    try testing.expectEqual(1 << 7, Bits.of(.{ .preserve_folds = true }));
    try testing.expectEqual(1 << 8, Bits.of(.{ .error_clamped = true }));
    try testing.expectEqual(1 << 29, Bits.of(.{ .internal_solve = true }));
    try testing.expectEqual(1 << 30, Bits.of(.{ .internal_debug = true }));

    const flags = [_]SimplifyVertexFlags{
        .{ .lock = true },
        .{ .protect = true },
        .{ .priority = true },
    };
    try testing.expectEqualSlices(u8, &.{ 1, 2, 4 }, std.mem.sliceAsBytes(&flags));
}

test "float to int conversions follow x86-64" {
    try testing.expectEqual(3, truncateToInt(3.9));
    try testing.expectEqual(-3, truncateToInt(-3.9));
    try testing.expectEqual(std.math.minInt(i32), truncateToInt(-2147483648.0));
    try testing.expectEqual(std.math.minInt(i32), truncateToInt(2147483648.0));
    try testing.expectEqual(std.math.minInt(i32), truncateToInt(std.math.nan(f32)));
    try testing.expectEqual(std.math.minInt(i32), truncateToInt(-std.math.inf(f32)));
    try testing.expectEqual(2147483520, truncateToInt(2147483520.0));
}
