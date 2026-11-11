//! The meshlet builders against the original, at many limits, on every test
//! mesh, on large ones and on degenerate ones: every output buffer is
//! compared whole, unwritten entries included.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;

pub const Builder = union(enum) {
    standard: struct { max_vertices: usize, max_triangles: usize, cone_weight: f32 },
    scan: struct { max_vertices: usize, max_triangles: usize },
    flex: struct {
        max_vertices: usize,
        min_triangles: usize,
        max_triangles: usize,
        cone_weight: f32,
        split_factor: f32,
    },
    spatial: Spatial,
    /// The port's path without SIMD against the original's SIMD one, which
    /// agree on finite positions.
    spatial_scalar: Spatial,

    const Spatial = struct {
        max_vertices: usize,
        min_triangles: usize,
        max_triangles: usize,
        fill_weight: f32,
    };

    fn bound(self: Builder, index_count: usize) usize {
        return switch (self) {
            .standard => |s| c.meshopt_buildMeshletsBound(
                index_count,
                s.max_vertices,
                s.max_triangles,
            ),
            .scan => |s| c.meshopt_buildMeshletsBound(index_count, s.max_vertices, s.max_triangles),
            .flex => |s| c.meshopt_buildMeshletsBound(index_count, s.max_vertices, s.min_triangles),
            .spatial, .spatial_scalar => |s| c.meshopt_buildMeshletsBound(
                index_count,
                s.max_vertices,
                s.min_triangles,
            ),
        };
    }
};

pub const standard_settings = [_]Builder{
    .{ .standard = .{ .max_vertices = 64, .max_triangles = 124, .cone_weight = 0 } },
    .{ .standard = .{ .max_vertices = 64, .max_triangles = 64, .cone_weight = 0.25 } },
    .{ .standard = .{ .max_vertices = 64, .max_triangles = 255, .cone_weight = 0.1 } },
    .{ .standard = .{ .max_vertices = 128, .max_triangles = 256, .cone_weight = 0.5 } },
    .{ .standard = .{ .max_vertices = 255, .max_triangles = 512, .cone_weight = 0 } },
    .{ .standard = .{ .max_vertices = 256, .max_triangles = 256, .cone_weight = 1 } },
    .{ .standard = .{ .max_vertices = 256, .max_triangles = 512, .cone_weight = 0.9 } },
    .{ .standard = .{ .max_vertices = 32, .max_triangles = 64, .cone_weight = 0 } },
    .{ .standard = .{ .max_vertices = 16, .max_triangles = 8, .cone_weight = 0.7 } },
    .{ .standard = .{ .max_vertices = 3, .max_triangles = 1, .cone_weight = 0 } },
};

const other_settings = [_]Builder{
    .{ .scan = .{ .max_vertices = 64, .max_triangles = 124 } },
    .{ .scan = .{ .max_vertices = 255, .max_triangles = 512 } },
    .{ .scan = .{ .max_vertices = 256, .max_triangles = 256 } },
    .{ .scan = .{ .max_vertices = 16, .max_triangles = 8 } },
    .{ .scan = .{ .max_vertices = 3, .max_triangles = 1 } },
    .{ .flex = .{
        .max_vertices = 64,
        .min_triangles = 32,
        .max_triangles = 128,
        .cone_weight = 0,
        .split_factor = 0,
    } },
    .{ .flex = .{
        .max_vertices = 64,
        .min_triangles = 32,
        .max_triangles = 128,
        .cone_weight = 0.25,
        .split_factor = 2,
    } },
    .{ .flex = .{
        .max_vertices = 128,
        .min_triangles = 64,
        .max_triangles = 256,
        .cone_weight = 0,
        .split_factor = 1,
    } },
    .{ .flex = .{
        .max_vertices = 255,
        .min_triangles = 100,
        .max_triangles = 512,
        .cone_weight = 0.5,
        .split_factor = 0.5,
    } },
    .{ .flex = .{
        .max_vertices = 64,
        .min_triangles = 1,
        .max_triangles = 124,
        .cone_weight = 0,
        .split_factor = 0.1,
    } },
    .{ .flex = .{
        .max_vertices = 16,
        .min_triangles = 4,
        .max_triangles = 8,
        .cone_weight = 0,
        .split_factor = 10,
    } },
    .{ .flex = .{
        .max_vertices = 256,
        .min_triangles = 256,
        .max_triangles = 256,
        .cone_weight = 1,
        .split_factor = 1,
    } },
};

pub const spatial_settings = [_]Builder.Spatial{
    .{ .max_vertices = 64, .min_triangles = 64, .max_triangles = 64, .fill_weight = 0 },
    .{ .max_vertices = 64, .min_triangles = 32, .max_triangles = 124, .fill_weight = 0.5 },
    .{ .max_vertices = 64, .min_triangles = 1, .max_triangles = 512, .fill_weight = 0.25 },
    .{ .max_vertices = 124, .min_triangles = 124, .max_triangles = 124, .fill_weight = 2 },
    .{ .max_vertices = 128, .min_triangles = 128, .max_triangles = 256, .fill_weight = 0 },
    .{ .max_vertices = 255, .min_triangles = 64, .max_triangles = 512, .fill_weight = 1 },
    .{ .max_vertices = 256, .min_triangles = 256, .max_triangles = 256, .fill_weight = 0.5 },
    .{ .max_vertices = 16, .min_triangles = 4, .max_triangles = 8, .fill_weight = 0 },
    .{ .max_vertices = 3, .min_triangles = 1, .max_triangles = 1, .fill_weight = 0 },
};

/// Positions as both sides take them: `stride` floats per vertex.
pub const Positions = struct {
    floats: []const f32,
    stride: usize,
    count: usize,

    pub fn of(vertices: []const Vertex) Positions {
        return .{
            .floats = common.floatsOf(vertices),
            .stride = common.vertex_floats,
            .count = vertices.len,
        };
    }

    pub fn view(self: Positions) mo.VertexFloats {
        if (self.count == 0) return .{ .data = &.{}, .stride = self.stride };
        return .init(self.floats[0 .. (self.count - 1) * self.stride + 3], self.stride);
    }
};

/// Every vertex's position packed in `stride` floats, the rest of each
/// zero; the caller frees the result.
fn repack(vertices: []const Vertex, stride: usize) ![]f32 {
    const floats = try gpa.alloc(f32, vertices.len * stride);
    @memset(floats, 0);
    for (vertices, 0..) |v, i| floats[i * stride ..][0..3].* = .{ v.px, v.py, v.pz };
    return floats;
}

fn checkBuilder(builder: Builder, indices: []const u32, positions: Positions) !void {
    const bound = builder.bound(indices.len);

    const want_meshlets = try gpa.alloc(c.Meshlet, bound);
    defer gpa.free(want_meshlets);
    const got_meshlets = try gpa.alloc(mo.Meshlet, bound);
    defer gpa.free(got_meshlets);
    const want_vertices = try gpa.alloc(u32, indices.len);
    defer gpa.free(want_vertices);
    const got_vertices = try gpa.alloc(u32, indices.len);
    defer gpa.free(got_vertices);
    const want_triangles = try gpa.alloc(u8, indices.len);
    defer gpa.free(want_triangles);
    const got_triangles = try gpa.alloc(u8, indices.len);
    defer gpa.free(got_triangles);

    // Every byte set, so unwritten entries compare too.
    @memset(std.mem.sliceAsBytes(want_meshlets), 0xcd);
    @memset(std.mem.sliceAsBytes(got_meshlets), 0xcd);
    @memset(want_vertices, 0xcdcdcdcd);
    @memset(got_vertices, 0xcdcdcdcd);
    @memset(want_triangles, 0xcd);
    @memset(got_triangles, 0xcd);

    const p = positions.floats.ptr;
    const n = positions.count;
    const stride = positions.stride * @sizeOf(f32);
    const view = positions.view();

    const want_count, const got_count = switch (builder) {
        .standard => |s| .{
            c.meshopt_buildMeshlets(
                want_meshlets.ptr,
                want_vertices.ptr,
                want_triangles.ptr,
                indices.ptr,
                indices.len,
                p,
                n,
                stride,
                s.max_vertices,
                s.max_triangles,
                s.cone_weight,
            ),
            try mo.buildMeshlets(
                gpa,
                got_meshlets,
                got_vertices,
                got_triangles,
                indices,
                view,
                s.max_vertices,
                s.max_triangles,
                s.cone_weight,
            ),
        },
        .scan => |s| .{
            c.meshopt_buildMeshletsScan(
                want_meshlets.ptr,
                want_vertices.ptr,
                want_triangles.ptr,
                indices.ptr,
                indices.len,
                n,
                s.max_vertices,
                s.max_triangles,
            ),
            try mo.buildMeshletsScan(
                gpa,
                got_meshlets,
                got_vertices,
                got_triangles,
                indices,
                n,
                s.max_vertices,
                s.max_triangles,
            ),
        },
        .flex => |s| .{
            c.meshopt_buildMeshletsFlex(
                want_meshlets.ptr,
                want_vertices.ptr,
                want_triangles.ptr,
                indices.ptr,
                indices.len,
                p,
                n,
                stride,
                s.max_vertices,
                s.min_triangles,
                s.max_triangles,
                s.cone_weight,
                s.split_factor,
            ),
            try mo.buildMeshletsFlex(
                gpa,
                got_meshlets,
                got_vertices,
                got_triangles,
                indices,
                view,
                s.max_vertices,
                s.min_triangles,
                s.max_triangles,
                s.cone_weight,
                s.split_factor,
            ),
        },
        inline .spatial, .spatial_scalar => |s, tag| .{
            c.meshopt_buildMeshletsSpatial(
                want_meshlets.ptr,
                want_vertices.ptr,
                want_triangles.ptr,
                indices.ptr,
                indices.len,
                p,
                n,
                stride,
                s.max_vertices,
                s.min_triangles,
                s.max_triangles,
                s.fill_weight,
            ),
            try mo.clusterizer.buildMeshletsSpatialMerge(
                if (tag == .spatial) mo.clusterizer.target_box_merge else .scalar,
                gpa,
                got_meshlets,
                got_vertices,
                got_triangles,
                indices,
                view,
                s.max_vertices,
                s.min_triangles,
                s.max_triangles,
                s.fill_weight,
            ),
        },
    };

    try common.expectSameValue(usize, @tagName(builder), want_count, got_count);
    try common.expectSame(
        u8,
        "meshlets",
        std.mem.sliceAsBytes(want_meshlets),
        std.mem.sliceAsBytes(got_meshlets),
    );
    try common.expectSame(u32, "meshlet vertices", want_vertices, got_vertices);
    try common.expectSame(u8, "meshlet triangles", want_triangles, got_triangles);
}

fn checkAll(indices: []const u32, positions: Positions, finite: bool) !void {
    for (standard_settings ++ other_settings) |builder| {
        try checkBuilder(builder, indices, positions);
    }
    for (spatial_settings) |s| {
        try checkBuilder(.{ .spatial = s }, indices, positions);
        if (finite) try checkBuilder(.{ .spatial_scalar = s }, indices, positions);
    }
}

test "buildMeshletsBound matches the original" {
    var index_count: usize = 0;
    while (index_count < 100_000) : (index_count = index_count * 3 + 3) {
        for ([_]usize{ 3, 4, 16, 64, 124, 128, 255, 256 }) |max_vertices| {
            for ([_]usize{ 1, 2, 8, 64, 124, 126, 255, 256, 511, 512 }) |max_triangles| {
                try common.expectSameValue(
                    usize,
                    "buildMeshletsBound",
                    c.meshopt_buildMeshletsBound(index_count, max_vertices, max_triangles),
                    mo.buildMeshletsBound(index_count, max_vertices, max_triangles),
                );
            }
        }
    }
}

test "the meshlet builders match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkAll(mesh.indices, .of(mesh.vertices), true);
}

test "the meshlet builders match the original with packed and wide positions" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes[0..3]) |mesh| {
        for ([_]usize{ 3, 64 }) |stride| {
            const floats = try repack(mesh.vertices, stride);
            defer gpa.free(floats);
            const positions: Positions = .{
                .floats = floats,
                .stride = stride,
                .count = mesh.vertices.len,
            };
            try checkAll(mesh.indices, positions, true);
        }
    }
}

test "the meshlet builders match the original on large meshes" {
    var sphere = try meshes.sphere(gpa, 256, 512);
    defer sphere.deinit(gpa);
    var grid = try meshes.grid(gpa, 200);
    defer grid.deinit(gpa);
    var random = try meshes.random(gpa, 31, 30000, 100000);
    defer random.deinit(gpa);

    for ([_]meshes.Mesh{ sphere, grid, random }) |mesh| {
        // Optimized for the vertex cache first, as a bake does.
        const ordered = try gpa.alloc(u32, mesh.indices.len);
        defer gpa.free(ordered);
        c.meshopt_optimizeVertexCache(
            ordered.ptr,
            mesh.indices.ptr,
            mesh.indices.len,
            mesh.vertices.len,
        );

        for ([_][]const u32{ mesh.indices, ordered }) |indices| {
            for (standard_settings[0..7]) |builder| {
                try checkBuilder(builder, indices, .of(mesh.vertices));
            }
            for (other_settings[0..9]) |builder| {
                try checkBuilder(builder, indices, .of(mesh.vertices));
            }
            for (spatial_settings[0..7]) |s| {
                try checkBuilder(.{ .spatial = s }, indices, .of(mesh.vertices));
                try checkBuilder(.{ .spatial_scalar = s }, indices, .of(mesh.vertices));
            }
        }
    }
}

test "the meshlet builders match the original on degenerate meshes" {
    var grid = try meshes.grid(gpa, 30);
    defer grid.deinit(gpa);

    // Every position the same, so every triangle has no area and every
    // centroid is the same point.
    const flat = try gpa.dupe(Vertex, grid.vertices);
    defer gpa.free(flat);
    for (flat) |*v| {
        v.px = 0;
        v.py = 0;
        v.pz = 0;
    }
    try checkAll(grid.indices, .of(flat), true);

    // Triangles that repeat a corner, or all three.
    var repeats: [3 * 300]u32 = undefined;
    for (0..300) |i| {
        const k: u32 = @intCast(i % 50);
        repeats[i * 3 ..][0..3].* = switch (i % 3) {
            0 => .{ k, k, k },
            1 => .{ k, k + 1, k },
            else => .{ k, k + 1, k + 2 },
        };
    }
    try checkAll(&repeats, .of(grid.vertices), true);

    // One triangle.
    try checkAll(grid.indices[0..3], .of(grid.vertices), true);

    // No triangles.
    try checkAll(&.{}, .of(grid.vertices), true);

    // A few vertices of many: the sparse adjacency.
    var sparse = try meshes.random(gpa, 5, 50000, 2000);
    defer sparse.deinit(gpa);
    try checkAll(sparse.indices[0..300], .of(sparse.vertices), true);

    // Points far apart in a geometric run, deep in the trees.
    var deep: [401]Vertex = undefined;
    var deep_indices: [400 * 3]u32 = undefined;
    deep[0] = std.mem.zeroes(Vertex);
    for (0..400) |i| {
        const x = std.math.pow(f32, 1.2, @floatFromInt(i));
        deep[i + 1] = std.mem.zeroes(Vertex);
        deep[i + 1].px = x;
        deep[i + 1].py = x;
        deep[i + 1].pz = x;
        const k: u32 = @intCast(i + 1);
        deep_indices[i * 3 ..][0..3].* = .{ 0, k, k };
    }
    try checkAll(&deep_indices, .of(&deep), true);

    // Positions with NaN, infinity and huge values; the port's scalar path
    // is not the original's x86 one there.
    const odd = try gpa.dupe(Vertex, grid.vertices);
    defer gpa.free(odd);
    for (odd, 0..) |*v, i| {
        switch (i % 37) {
            0 => v.px = std.math.nan(f32),
            1 => v.py = std.math.inf(f32),
            2 => v.pz = -std.math.inf(f32),
            3 => v.px = 3e38,
            else => {},
        }
    }
    try checkAll(grid.indices, .of(odd), false);
}
