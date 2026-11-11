//! Meshes for the oracle tests and the benchmark: the original's demo mesh,
//! and generated ones. Everything here is deterministic, from fixed seeds.

const std = @import("std");

/// The vertex of the original's demo, as its OBJ loader builds it.
pub const Vertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
    tx: f32,
    ty: f32,
};

/// An indexed triangle mesh; `deinit` frees both buffers.
pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,

    pub fn deinit(self: *Mesh, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        self.* = undefined;
    }

    pub fn positionBytes(self: Mesh) []const u8 {
        return std.mem.sliceAsBytes(self.vertices);
    }
};

pub const pirate_obj = @embedFile("pirate.obj");

/// The demo mesh as the original's demo reads it: one vertex per triangle
/// corner, polygons split into fans, before any indexing.
pub fn pirateSoup(gpa: std.mem.Allocator) ![]Vertex {
    return objSoup(gpa, pirate_obj);
}

/// Parses `source` as OBJ: positions, normals and texture coordinates, and
/// faces of three or more corners, each a position with optional texture
/// coordinate and normal indices.
pub fn objSoup(gpa: std.mem.Allocator, source: []const u8) ![]Vertex {
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(gpa);
    var normals: std.ArrayList([3]f32) = .empty;
    defer normals.deinit(gpa);
    var texcoords: std.ArrayList([2]f32) = .empty;
    defer texcoords.deinit(gpa);
    var soup: std.ArrayList(Vertex) = .empty;
    errdefer soup.deinit(gpa);

    var lines = std.mem.tokenizeAny(u8, source, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const kind = words.next() orelse continue;
        if (std.mem.eql(u8, kind, "v")) {
            try positions.append(gpa, try floats(3, &words));
        } else if (std.mem.eql(u8, kind, "vn")) {
            try normals.append(gpa, try floats(3, &words));
        } else if (std.mem.eql(u8, kind, "vt")) {
            try texcoords.append(gpa, try floats(2, &words));
        } else if (std.mem.eql(u8, kind, "f")) {
            var corners: std.ArrayList(Vertex) = .empty;
            defer corners.deinit(gpa);
            while (words.next()) |word| {
                var parts = std.mem.splitScalar(u8, word, '/');
                const p = try objIndex(parts.next(), positions.items.len);
                const t = try objIndex(parts.next(), texcoords.items.len);
                const n = try objIndex(parts.next(), normals.items.len);
                const position = positions.items[p orelse return error.InvalidObj];
                const normal = if (n) |i| normals.items[i] else [3]f32{ 0, 0, 0 };
                const texcoord = if (t) |i| texcoords.items[i] else [2]f32{ 0, 0 };
                try corners.append(gpa, .{
                    .px = position[0],
                    .py = position[1],
                    .pz = position[2],
                    .nx = normal[0],
                    .ny = normal[1],
                    .nz = normal[2],
                    .tx = texcoord[0],
                    .ty = texcoord[1],
                });
            }
            if (corners.items.len < 3) continue;
            for (2..corners.items.len) |k| {
                try soup.appendSlice(
                    gpa,
                    &.{
                        corners.items[0],
                        corners.items[k - 1],
                        corners.items[k],
                    },
                );
            }
        }
    }
    return soup.toOwnedSlice(gpa);
}

fn floats(comptime n: usize, words: *std.mem.TokenIterator(u8, .any)) ![n]f32 {
    var result: [n]f32 = undefined;
    for (
        &result,
    ) |*f| f.* = try std.fmt.parseFloat(
        f32,
        words.next() orelse return error.InvalidObj,
    );
    return result;
}

/// An OBJ index, 1-based or negative from the end, as a 0-based one; null
/// when absent.
fn objIndex(part: ?[]const u8, count: usize) !?usize {
    const text = part orelse return null;
    if (text.len == 0) return null;
    const value = try std.fmt.parseInt(i64, text, 10);
    const index = if (value < 0) @as(i64, @intCast(count)) + value else value - 1;
    if (index < 0 or index >= count) return error.InvalidObj;
    return @intCast(index);
}

/// A square grid of `n` by `n` quads, two triangles each, on the z = 0
/// plane, with normals up and texture coordinates over the unit square.
pub fn grid(gpa: std.mem.Allocator, n: u32) !Mesh {
    const side = n + 1;
    const vertices = try gpa.alloc(Vertex, side * side);
    errdefer gpa.free(vertices);
    for (0..side) |y| for (0..side) |x| {
        const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(n));
        const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(n));
        vertices[y * side + x] = .{
            .px = u,
            .py = v,
            .pz = 0,
            .nx = 0,
            .ny = 0,
            .nz = 1,
            .tx = u,
            .ty = v,
        };
    };
    const indices = try gpa.alloc(u32, n * n * 6);
    for (0..n) |y| for (0..n) |x| {
        const v0: u32 = @intCast(y * side + x);
        const v1 = v0 + 1;
        const v2 = v0 + side;
        const v3 = v2 + 1;
        indices[(y * n + x) * 6 ..][0..6].* = .{ v0, v1, v2, v2, v1, v3 };
    };
    return .{ .vertices = vertices, .indices = indices };
}

/// A unit sphere of `rings` latitude bands and `segments` longitude ones,
/// with a seam where texture coordinates wrap, so positions repeat with
/// different attributes.
pub fn sphere(gpa: std.mem.Allocator, rings: u32, segments: u32) !Mesh {
    const vertices = try gpa.alloc(Vertex, (rings + 1) * (segments + 1));
    errdefer gpa.free(vertices);
    for (0..rings + 1) |r| for (0..segments + 1) |s| {
        const v = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings));
        const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments));
        const theta = v * std.math.pi;
        const phi = u * 2 * std.math.pi;
        const x = @sin(theta) * @cos(phi);
        const y = @cos(theta);
        const z = @sin(theta) * @sin(phi);
        vertices[r * (segments + 1) + s] = .{
            .px = x,
            .py = y,
            .pz = z,
            .nx = x,
            .ny = y,
            .nz = z,
            .tx = u,
            .ty = v,
        };
    };
    const indices = try gpa.alloc(u32, rings * segments * 6);
    for (0..rings) |r| for (0..segments) |s| {
        const v0: u32 = @intCast(r * (segments + 1) + s);
        const v1 = v0 + 1;
        const v2 = v0 + segments + 1;
        const v3 = v2 + 1;
        indices[(r * segments + s) * 6 ..][0..6].* = .{ v0, v2, v1, v1, v2, v3 };
    };
    return .{ .vertices = vertices, .indices = indices };
}

/// A random mesh: `vertex_count` vertices on a small integer lattice, so
/// positions repeat, some with equal attributes too; and `triangle_count`
/// triangles of random corners, some degenerate and some repeated.
pub fn random(gpa: std.mem.Allocator, seed: u64, vertex_count: u32, triangle_count: u32) !Mesh {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const vertices = try gpa.alloc(Vertex, vertex_count);
    errdefer gpa.free(vertices);
    for (vertices, 0..) |*v, i| {
        if (i > 0 and rng.uintLessThan(u32, 8) == 0) {
            v.* = vertices[rng.uintLessThan(usize, i)];
            if (rng.boolean()) v.tx += 1;
            continue;
        }
        v.* = .{
            .px = @floatFromInt(rng.intRangeAtMost(i32, -8, 8)),
            .py = @floatFromInt(rng.intRangeAtMost(i32, -8, 8)),
            .pz = @floatFromInt(rng.intRangeAtMost(i32, -8, 8)),
            .nx = rng.float(f32),
            .ny = rng.float(f32),
            .nz = rng.float(f32),
            .tx = @floatFromInt(rng.uintLessThan(u32, 4)),
            .ty = @floatFromInt(rng.uintLessThan(u32, 4)),
        };
    }
    const indices = try gpa.alloc(u32, triangle_count * 3);
    for (0..triangle_count) |t| {
        const triangle = indices[t * 3 ..][0..3];
        if (t > 0 and rng.uintLessThan(u32, 16) == 0) {
            triangle.* = indices[rng.uintLessThan(usize, t) * 3 ..][0..3].*;
            continue;
        }
        for (triangle) |*index| index.* = rng.uintLessThan(u32, vertex_count);
    }
    return .{ .vertices = vertices, .indices = indices };
}

/// The demo mesh indexed by the port's own `generateVertexRemap` result,
/// which the index generator's oracle test checks: give it the remap table
/// and unique count computed for `soup`.
pub fn indexed(
    gpa: std.mem.Allocator,
    soup: []const Vertex,
    remap: []const u32,
    unique: usize,
) !Mesh {
    const vertices = try gpa.alloc(Vertex, unique);
    errdefer gpa.free(vertices);
    for (soup, remap) |v, r| vertices[r] = v;
    const indices = try gpa.dupe(u32, remap);
    return .{ .vertices = vertices, .indices = indices };
}

/// Each vertex's normal as 4 floats, X, Y, Z and a W of 1 or -1 (a
/// tangent's handedness), as the octahedral filter takes them. The caller
/// frees the floats.
pub fn unitVectors(gpa: std.mem.Allocator, vertices: []const Vertex) ![]f32 {
    const out = try gpa.alloc(f32, vertices.len * 4);
    for (vertices, 0..) |v, i| {
        const w: f32 = if (v.tx - @floor(v.tx) < 0.5) 1 else -1;
        out[i * 4 ..][0..4].* = .{ v.nx, v.ny, v.nz, w };
    }
    return out;
}

/// Each vertex's tangent frame as a unit quaternion, X, Y, Z and W: the
/// shortest rotation of +Z onto the normal, after a twist about +Z by the
/// first texture coordinate. The caller frees the floats.
pub fn tangentFrames(gpa: std.mem.Allocator, vertices: []const Vertex) ![]f32 {
    const out = try gpa.alloc(f32, vertices.len * 4);
    for (vertices, 0..) |v, i| {
        const length = @sqrt(v.nx * v.nx + v.ny * v.ny + v.nz * v.nz);
        const n: [3]f32 = if (length > 0)
            .{ v.nx / length, v.ny / length, v.nz / length }
        else
            .{ 0, 0, 1 };

        // The shortest arc, or a half turn about X when the normal is -Z.
        var arc = [4]f32{ -n[1], n[0], 0, 1 + n[2] };
        const arc_length = @sqrt(arc[0] * arc[0] + arc[1] * arc[1] + arc[3] * arc[3]);
        arc = if (arc_length > 1e-6)
            .{ arc[0] / arc_length, arc[1] / arc_length, 0, arc[3] / arc_length }
        else
            .{ 1, 0, 0, 0 };

        const half = v.tx * std.math.pi;
        const s = @sin(half);
        const c = @cos(half);
        out[i * 4 ..][0..4].* = .{
            arc[0] * c + arc[1] * s,
            arc[1] * c - arc[0] * s,
            arc[3] * s + arc[2] * c,
            arc[3] * c - arc[2] * s,
        };
    }
    return out;
}

/// A color per vertex as RGBA floats: the normal mapped to [0, 1], and the
/// fraction of the second texture coordinate as alpha. The caller frees the
/// floats.
pub fn colors(gpa: std.mem.Allocator, vertices: []const Vertex) ![]f32 {
    const out = try gpa.alloc(f32, vertices.len * 4);
    for (vertices, 0..) |v, i| {
        out[i * 4 ..][0..4].* = .{
            v.nx * 0.5 + 0.5,
            v.ny * 0.5 + 0.5,
            v.nz * 0.5 + 0.5,
            v.ty - @floor(v.ty),
        };
    }
    return out;
}
