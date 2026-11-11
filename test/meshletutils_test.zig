//! The single-meshlet functions against the original: on the meshlets the
//! original builds from every test mesh at several limits, on clusters cut
//! from the meshes, and on degenerate ones.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");
const fuzzed = @import("fuzzed_meshes.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;

/// Meshlets the original builds, for both sides to work on.
const Built = struct {
    /// The meshlets built, at the start of `storage`.
    meshlets: []c.Meshlet,
    storage: []c.Meshlet,
    vertices: []u32,
    triangles: []u8,

    fn init(mesh: meshes.Mesh, max_vertices: usize, max_triangles: usize) !Built {
        const indices = mesh.indices;
        const bound = c.meshopt_buildMeshletsBound(indices.len, max_vertices, max_triangles);
        const meshlets = try gpa.alloc(c.Meshlet, bound);
        errdefer gpa.free(meshlets);
        const vertices = try gpa.alloc(u32, indices.len);
        errdefer gpa.free(vertices);
        const triangles = try gpa.alloc(u8, indices.len);
        errdefer gpa.free(triangles);
        const positions = common.positionsOf(mesh.vertices);
        const count = c.meshopt_buildMeshlets(
            meshlets.ptr,
            vertices.ptr,
            triangles.ptr,
            indices.ptr,
            indices.len,
            positions.data.ptr,
            mesh.vertices.len,
            @sizeOf(Vertex),
            max_vertices,
            max_triangles,
            0.25,
        );
        return .{
            .meshlets = meshlets[0..count],
            .storage = meshlets,
            .vertices = vertices,
            .triangles = triangles,
        };
    }

    fn deinit(self: *Built) void {
        gpa.free(self.storage);
        gpa.free(self.vertices);
        gpa.free(self.triangles);
        self.* = undefined;
    }

    fn vertexRange(self: Built, m: c.Meshlet) []u32 {
        return self.vertices[m.vertex_offset..][0..m.vertex_count];
    }

    fn triangleRange(self: Built, m: c.Meshlet) []u8 {
        return self.triangles[m.triangle_offset..][0 .. m.triangle_count * 3];
    }
};

const limits = [_][2]usize{
    .{ 64, 124 },
    .{ 64, 64 },
    .{ 128, 255 },
    .{ 255, 512 },
    .{ 256, 256 },
    .{ 16, 8 },
    .{ 3, 1 },
};

/// Every level against the original; then the port again on the same
/// input, which must give the same.
fn checkOptimize(vertices: []const u32, triangles: []const u8) !void {
    var want_vertices: [256]u32 = undefined;
    var got_vertices: [256]u32 = undefined;
    var again_vertices: [256]u32 = undefined;
    var want_triangles: [512 * 3]u8 = undefined;
    var got_triangles: [512 * 3]u8 = undefined;
    var again_triangles: [512 * 3]u8 = undefined;
    const n = vertices.len;
    const t = triangles.len;

    for (0..10) |level| {
        @memcpy(want_vertices[0..n], vertices);
        @memcpy(got_vertices[0..n], vertices);
        @memcpy(again_vertices[0..n], vertices);
        @memcpy(want_triangles[0..t], triangles);
        @memcpy(got_triangles[0..t], triangles);
        @memcpy(again_triangles[0..t], triangles);
        if (level == 0) {
            c.meshopt_optimizeMeshlet(&want_vertices, &want_triangles, t / 3, n);
            mo.optimizeMeshlet(got_vertices[0..n], got_triangles[0..t]);
            mo.optimizeMeshlet(again_vertices[0..n], again_triangles[0..t]);
        } else {
            const l: c_int = @intCast(level);
            c.meshopt_optimizeMeshletLevel(&want_vertices, n, &want_triangles, t / 3, l);
            mo.optimizeMeshletLevel(got_vertices[0..n], got_triangles[0..t], @intCast(level));
            mo.optimizeMeshletLevel(again_vertices[0..n], again_triangles[0..t], @intCast(level));
        }
        try common.expectSame(u32, "optimized vertices", want_vertices[0..n], got_vertices[0..n]);
        try common.expectSame(u8, "optimized triangles", want_triangles[0..t], got_triangles[0..t]);
        try common.expectSame(u32, "a second run", got_vertices[0..n], again_vertices[0..n]);
        try common.expectSame(u8, "a second run", got_triangles[0..t], again_triangles[0..t]);
    }
}

/// `got` and `again` are the port's two runs.
fn expectSameBounds(what: []const u8, want: c.Bounds, got: mo.Bounds, again: mo.Bounds) !void {
    try common.expectSame(u8, what, std.mem.asBytes(&want), std.mem.asBytes(&got));
    try common.expectSame(u8, "a second run", std.mem.asBytes(&got), std.mem.asBytes(&again));
}

fn checkClusterBounds(indices: []const u32, positions: mo.VertexFloats, count: usize) !void {
    const want = c.meshopt_computeClusterBounds(
        indices.ptr,
        indices.len,
        positions.data.ptr,
        count,
        positions.stride * @sizeOf(f32),
    );
    const got = mo.computeClusterBounds(u32, indices, positions);
    const again = mo.computeClusterBounds(u32, indices, positions);
    try expectSameBounds("computeClusterBounds", want, got, again);
}

fn checkExtract(indices: []const u32) !void {
    var want_vertices: [256]u32 = @splat(0xcdcdcdcd);
    var got_vertices: [256]u32 = @splat(0xcdcdcdcd);
    var again_vertices: [256]u32 = @splat(0x55555555);
    var want_triangles: [512 * 3]u8 = @splat(fuzzed.first_fill);
    var got_triangles: [512 * 3]u8 = @splat(fuzzed.first_fill);
    var again_triangles: [512 * 3]u8 = @splat(fuzzed.second_fill);
    const want = c.meshopt_extractMeshletIndices(
        &want_vertices,
        &want_triangles,
        indices.ptr,
        indices.len,
    );
    const got = mo.extractMeshletIndices(&got_vertices, &got_triangles, indices);
    try common.expectSameValue(usize, "extractMeshletIndices", want, got);
    try common.expectSame(u32, "extracted vertices", &want_vertices, &got_vertices);
    try common.expectSame(u8, "extracted triangles", &want_triangles, &got_triangles);

    const again = mo.extractMeshletIndices(&again_vertices, &again_triangles, indices);
    try common.expectSameValue(usize, "a second run", got, again);
    try fuzzed.expectRerunSame(
        "extracted vertices",
        std.mem.asBytes(&got_vertices),
        std.mem.asBytes(&again_vertices),
    );
    try fuzzed.expectRerunSame("extracted triangles", &got_triangles, &again_triangles);
}

fn checkMeshlets(mesh: meshes.Mesh) !void {
    const positions = common.positionsOf(mesh.vertices);
    for (limits) |limit| {
        var built: Built = try .init(mesh, limit[0], limit[1]);
        defer built.deinit();

        for (built.meshlets) |m| {
            const vertices = built.vertexRange(m);
            const triangles = built.triangleRange(m);

            try checkOptimize(vertices, triangles);

            const want = c.meshopt_computeMeshletBounds(
                vertices.ptr,
                triangles.ptr,
                m.triangle_count,
                positions.data.ptr,
                mesh.vertices.len,
                @sizeOf(Vertex),
            );
            const got = mo.computeMeshletBounds(vertices, triangles, positions);
            const again = mo.computeMeshletBounds(vertices, triangles, positions);
            try expectSameBounds("computeMeshletBounds", want, got, again);

            // The meshlet's mesh indices, as a cluster.
            var indices: [512 * 3]u32 = undefined;
            for (triangles, indices[0..triangles.len]) |t, *index| index.* = vertices[t];
            try checkClusterBounds(indices[0..triangles.len], positions, mesh.vertices.len);
            try checkExtract(indices[0..triangles.len]);
        }
    }
}

test "the meshlet functions match the original on every mesh's meshlets" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkMeshlets(mesh);
}

test "the meshlet functions match the original on a large mesh's meshlets" {
    var sphere = try meshes.sphere(gpa, 128, 256);
    defer sphere.deinit(gpa);
    try checkMeshlets(sphere);

    // One meshlet of 256 vertices and 450 triangles.
    var grid = try meshes.grid(gpa, 15);
    defer grid.deinit(gpa);
    try checkMeshlets(grid);
}

test "computeClusterBounds matches the original on clusters cut from every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        const positions = common.positionsOf(mesh.vertices);
        const triangle_count = mesh.indices.len / 3;
        for ([_]usize{ 1, 2, 7, 64, 124, 256, 511, 512 }) |size| {
            var start: usize = 0;
            while (start < triangle_count) : (start += size * 3 + 1) {
                const end = @min(start + size, triangle_count);
                const cluster = mesh.indices[start * 3 .. end * 3];
                try checkClusterBounds(cluster, positions, mesh.vertices.len);
            }
        }
    }
}

test "computeClusterBounds matches the original on degenerate clusters" {
    const zeros: [9]f32 = @splat(0);
    const corners = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const flat: mo.VertexFloats = .init(&zeros, 3);
    const unit: mo.VertexFloats = .init(&corners, 3);

    // No triangles, a triangle with repeated corners, one with no area, and
    // two facing apart.
    try checkClusterBounds(&.{}, .{ .data = &.{}, .stride = 3 }, 0);
    try checkClusterBounds(&.{ 0, 0, 0 }, flat, 3);
    try checkClusterBounds(&.{ 0, 1, 2 }, flat, 3);
    try checkClusterBounds(&.{ 0, 1, 2, 0, 2, 1 }, unit, 3);
    try checkClusterBounds(&.{ 0, 1, 2 }, unit, 3);
    try checkClusterBounds(&.{ 0, 1, 2, 0, 1, 2, 2, 2, 1 }, unit, 3);
}

test "computeClusterBounds matches the original on NaN and overflowing positions" {
    // A NaN corner, and finite corners 1e20 apart, whose normal overflows:
    // both give NaN normals, which the original's release build carries
    // through to its cone.
    const nan = std.math.nan(f32);
    const cases = [_][9]f32{
        .{ 0, 0, 0, 1, 0, 0, 0, 1, nan },
        .{ 0, 0, 0, 1e20, 0, 0, 0, 1e20, 0 },
        .{ nan, nan, nan, nan, nan, nan, nan, nan, nan },
        .{ 0, 0, 0, std.math.inf(f32), 0, 0, 0, 1, 0 },
    };
    for (&cases) |*positions| {
        const indices = [_]u32{ 0, 1, 2 };
        const want = c.meshopt_computeClusterBounds(&indices, 3, positions, 3, 12);
        const got = mo.computeClusterBounds(u32, &indices, .init(positions, 3));
        try common.expectSameBoundsAnyNan("computeClusterBounds", want, got);
    }
}

test "computeSphereBounds matches the original on special points and radii" {
    const points = &common.special_points;
    const count_max = points.len / 3;
    const radii_values = [_]f32{
        0,                 1,                  -1,   std.math.nan(f32),
        std.math.inf(f32), -std.math.inf(f32), 1e30, 0.5,
        3,
    };
    var prng: std.Random.DefaultPrng = .init(7);
    const rng = prng.random();
    // Every prefix of every rotation of the special points, with and
    // without radii.
    var rotated: [common.special_points.len]f32 = undefined;
    for (0..count_max) |shift| {
        for (0..count_max) |i| {
            rotated[i * 3 ..][0..3].* = points[((i + shift) % count_max) * 3 ..][0..3].*;
        }
        for (1..count_max + 1) |n| {
            const data = rotated[0 .. n * 3];
            const want = c.meshopt_computeSphereBounds(data.ptr, n, 12, null, 0);
            const got = mo.computeSphereBounds(.init(data, 3), null);
            try common.expectSameBoundsAnyNan("computeSphereBounds", want, got);

            var radii: [count_max]f32 = undefined;
            for (&radii) |*r| r.* = radii_values[rng.uintLessThan(usize, radii_values.len)];
            const want_radii = c.meshopt_computeSphereBounds(data.ptr, n, 12, &radii, 4);
            const got_radii = mo.computeSphereBounds(.init(data, 3), .init(radii[0..n], 1));
            try common.expectSameBoundsAnyNan(
                "computeSphereBounds with radii",
                want_radii,
                got_radii,
            );
        }
    }
}

test "extractMeshletIndices matches the original when low bits collide" {
    var prng: std.Random.DefaultPrng = .init(11);
    const rng = prng.random();
    for (0..50) |round| {
        // Up to 256 distinct vertices, many of them 1024 apart.
        var pool: [256]u32 = undefined;
        const distinct = 1 + rng.uintLessThan(usize, 256);
        for (pool[0..distinct], 0..) |*v, i| {
            const low: u32 = @intCast(i % 7);
            v.* = if (round % 2 == 0) low + 1024 * @as(u32, @intCast(i)) else rng.int(u32);
        }
        var indices: [512 * 3]u32 = undefined;
        const count = 3 * (1 + rng.uintLessThan(usize, 512));
        for (indices[0..count]) |*index| index.* = pool[rng.uintLessThan(usize, distinct)];
        try checkExtract(indices[0..count]);
    }
    try checkExtract(&.{});
    try checkExtract(&.{ 0, 7, 15, 1039, 7, 15 });
}

fn checkSphere(
    floats: []const f32,
    stride: usize,
    count: usize,
    radii: ?[]const f32,
    radius_stride: usize,
) !void {
    const positions: mo.VertexFloats = if (count == 0)
        .{ .data = &.{}, .stride = stride }
    else
        .init(floats[0 .. (count - 1) * stride + 3], stride);
    const radius_view: ?mo.VertexFloats = if (radii) |r|
        if (count == 0)
            .{ .data = &.{}, .stride = radius_stride }
        else
            .init(r[0 .. (count - 1) * radius_stride + 1], radius_stride)
    else
        null;
    const want = c.meshopt_computeSphereBounds(
        floats.ptr,
        count,
        stride * @sizeOf(f32),
        if (radii) |r| r.ptr else null,
        if (radii != null) radius_stride * @sizeOf(f32) else 0,
    );
    const got = mo.computeSphereBounds(positions, radius_view);
    const again = mo.computeSphereBounds(positions, radius_view);
    try expectSameBounds("computeSphereBounds", want, got, again);
}

test "computeSphereBounds matches the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    var prng: std.Random.DefaultPrng = .init(3);
    const rng = prng.random();
    for (set.meshes) |mesh| {
        const floats = common.floatsOf(mesh.vertices);
        const n = mesh.vertices.len;
        try checkSphere(floats, common.vertex_floats, n, null, 0);
        // A few points, then the first point alone.
        try checkSphere(floats, common.vertex_floats, @min(n, 5), null, 0);
        try checkSphere(floats, common.vertex_floats, 1, null, 0);

        // Radii in their own array, then in the vertex's normal field.
        const radii = try gpa.alloc(f32, n);
        defer gpa.free(radii);
        for (radii) |*r| r.* = rng.float(f32) * 3;
        try checkSphere(floats, common.vertex_floats, n, radii, 1);
        try checkSphere(floats, common.vertex_floats, n, floats[3..], common.vertex_floats);
    }
    try checkSphere(&.{}, 3, 0, null, 0);

    // The original's own example: points, then spheres around them.
    const spheres = [_]f32{ 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 2, 1, 0, 1, 3 };
    try checkSphere(&spheres, 4, 4, null, 0);
    try checkSphere(&spheres, 4, 4, spheres[3..], 4);
}

/// A fuzzed meshlet over a fuzzed mesh's vertices: up to 256 vertices and
/// 512 triangles of random corners, a fan around one vertex (whose valence
/// passes the original's 8-bit counters) or a strip. Positions are finite
/// and below 1e6, as the original's cone needs; it asserts on others.
fn checkFuzzed(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var fuzz_mesh = try fuzzed.mesh(rng);
    defer fuzz_mesh.deinit();
    const pool = fuzz_mesh.mesh.vertices;
    for (pool) |*v| {
        for ([_]*f32{ &v.px, &v.py, &v.pz }) |x| {
            if (!std.math.isFinite(x.*) or @abs(x.*) > 1e6) x.* = 0;
        }
    }
    const positions = common.positionsOf(pool);

    const vertex_count = fuzzed.size(rng, 1, 256);
    const triangle_count = fuzzed.size(rng, 0, 512);
    var vertices: [256]u32 = undefined;
    for (vertices[0..vertex_count]) |*v| v.* = rng.uintLessThan(u32, @intCast(pool.len));
    var triangles: [512 * 3]u8 = undefined;
    const t = triangles[0 .. triangle_count * 3];
    for (0..triangle_count) |i| {
        const corners: [3]usize = switch (seed % 3) {
            0 => .{
                rng.uintLessThan(usize, vertex_count),
                rng.uintLessThan(usize, vertex_count),
                rng.uintLessThan(usize, vertex_count),
            },
            1 => .{ 0, (i + 1) % vertex_count, (i + 2) % vertex_count },
            else => .{ i % vertex_count, (i + 1) % vertex_count, (i + 2) % vertex_count },
        };
        for (t[i * 3 ..][0..3], corners) |*corner, k| corner.* = @intCast(k);
    }
    const local = vertices[0..vertex_count];

    try checkOptimize(local, t);

    const want = c.meshopt_computeMeshletBounds(
        local.ptr,
        t.ptr,
        triangle_count,
        positions.data.ptr,
        pool.len,
        @sizeOf(Vertex),
    );
    const got = mo.computeMeshletBounds(local, t, positions);
    const again = mo.computeMeshletBounds(local, t, positions);
    try expectSameBounds("computeMeshletBounds", want, got, again);

    var indices: [512 * 3]u32 = undefined;
    for (t, indices[0..t.len]) |corner, *index| index.* = local[corner];
    try checkClusterBounds(indices[0..t.len], positions, pool.len);
    try checkExtract(indices[0..t.len]);

    // Spheres around some of the positions, with radii apart, in the
    // vertex's normal field, or none.
    const floats = common.floatsOf(pool);
    const count = fuzzed.size(rng, 0, pool.len);
    const radii = try gpa.alloc(f32, count);
    defer gpa.free(radii);
    for (radii) |*r| r.* = if (rng.boolean()) 0 else rng.float(f32) * 4;
    switch (rng.uintLessThan(u32, 3)) {
        0 => try checkSphere(floats, common.vertex_floats, count, null, 0),
        1 => try checkSphere(floats, common.vertex_floats, count, radii, 1),
        else => {
            for (pool) |*v| v.nx = @abs(v.nx);
            try checkSphere(floats, common.vertex_floats, count, floats[3..], common.vertex_floats);
        },
    }
}

test "the meshlet functions match the original on fuzzed meshlets" {
    try common.fuzz("meshletutils", 0, checkFuzzed);
}

test "the meshlet functions match the original at the largest meshlet" {
    var prng: std.Random.DefaultPrng = .init(1);
    const rng = prng.random();
    var grid = try meshes.grid(gpa, 15);
    defer grid.deinit(gpa);
    const positions = common.positionsOf(grid.vertices);

    // 256 vertices and 512 triangles: a fan around vertex 0, and random.
    var vertices: [256]u32 = undefined;
    for (&vertices, 0..) |*v, i| v.* = @intCast(i);
    var triangles: [512 * 3]u8 = undefined;
    for (0..2) |round| {
        for (0..512) |i| {
            const corners: [3]usize = if (round == 0)
                .{ 0, i % 255 + 1, (i + 1) % 255 + 1 }
            else
                .{ rng.uintLessThan(usize, 256), rng.uintLessThan(usize, 256), i % 256 };
            for (triangles[i * 3 ..][0..3], corners) |*corner, k| corner.* = @intCast(k);
        }
        try checkOptimize(&vertices, &triangles);

        const want = c.meshopt_computeMeshletBounds(
            &vertices,
            &triangles,
            512,
            positions.data.ptr,
            grid.vertices.len,
            @sizeOf(Vertex),
        );
        const got = mo.computeMeshletBounds(&vertices, &triangles, positions);
        const again = mo.computeMeshletBounds(&vertices, &triangles, positions);
        try expectSameBounds("computeMeshletBounds", want, got, again);

        var indices: [512 * 3]u32 = undefined;
        for (triangles, &indices) |corner, *index| index.* = vertices[corner];
        try checkClusterBounds(&indices, positions, grid.vertices.len);
        try checkExtract(&indices);
    }
}
