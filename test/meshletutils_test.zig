//! The single-meshlet functions against the original: on the meshlets the
//! original builds from every test mesh at several limits, on clusters cut
//! from the meshes, and on degenerate ones.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

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

fn checkOptimize(vertices: []const u32, triangles: []const u8) !void {
    var want_vertices: [256]u32 = undefined;
    var got_vertices: [256]u32 = undefined;
    var want_triangles: [512 * 3]u8 = undefined;
    var got_triangles: [512 * 3]u8 = undefined;
    const n = vertices.len;
    const t = triangles.len;

    for (0..10) |level| {
        @memcpy(want_vertices[0..n], vertices);
        @memcpy(got_vertices[0..n], vertices);
        @memcpy(want_triangles[0..t], triangles);
        @memcpy(got_triangles[0..t], triangles);
        if (level == 0) {
            c.meshopt_optimizeMeshlet(&want_vertices, &want_triangles, t / 3, n);
            mo.optimizeMeshlet(got_vertices[0..n], got_triangles[0..t]);
        } else {
            const l: c_int = @intCast(level);
            c.meshopt_optimizeMeshletLevel(&want_vertices, n, &want_triangles, t / 3, l);
            mo.optimizeMeshletLevel(got_vertices[0..n], got_triangles[0..t], @intCast(level));
        }
        try common.expectSame(u32, "optimized vertices", want_vertices[0..n], got_vertices[0..n]);
        try common.expectSame(u8, "optimized triangles", want_triangles[0..t], got_triangles[0..t]);
    }
}

fn expectSameBounds(what: []const u8, want: c.Bounds, got: mo.Bounds) !void {
    try common.expectSame(u8, what, std.mem.asBytes(&want), std.mem.asBytes(&got));
}

fn checkClusterBounds(indices: []const u32, positions: mo.VertexFloats, count: usize) !void {
    const want = c.meshopt_computeClusterBounds(
        indices.ptr,
        indices.len,
        positions.data.ptr,
        count,
        positions.stride * @sizeOf(f32),
    );
    try expectSameBounds("computeClusterBounds", want, mo.computeClusterBounds(indices, positions));
}

fn checkExtract(indices: []const u32) !void {
    var want_vertices: [256]u32 = @splat(0xcdcdcdcd);
    var got_vertices: [256]u32 = @splat(0xcdcdcdcd);
    var want_triangles: [512 * 3]u8 = @splat(0xcd);
    var got_triangles: [512 * 3]u8 = @splat(0xcd);
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
            try expectSameBounds("computeMeshletBounds", want, got);

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
    try expectSameBounds("computeSphereBounds", want, got);
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
