//! The meshlet builders against the original, at many limits, on every test
//! mesh, on large ones and on degenerate ones: every output buffer is
//! compared whole, unwritten entries included.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");
const fuzzed = @import("fuzzed_meshes.zig");

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
    .{ .flex = .{
        .max_vertices = 256,
        .min_triangles = 1,
        .max_triangles = 512,
        .cone_weight = 0.5,
        .split_factor = 2,
    } },
    .{ .flex = .{
        .max_vertices = 256,
        .min_triangles = 512,
        .max_triangles = 512,
        .cone_weight = 0,
        .split_factor = 0,
    } },
    .{ .flex = .{
        .max_vertices = 256,
        .min_triangles = 128,
        .max_triangles = 512,
        .cone_weight = 1,
        .split_factor = 0.25,
    } },
    .{ .scan = .{ .max_vertices = 256, .max_triangles = 512 } },
};

pub const spatial_settings = [_]Builder.Spatial{
    .{ .max_vertices = 64, .min_triangles = 64, .max_triangles = 64, .fill_weight = 0 },
    .{ .max_vertices = 64, .min_triangles = 32, .max_triangles = 124, .fill_weight = 0.5 },
    .{ .max_vertices = 64, .min_triangles = 1, .max_triangles = 512, .fill_weight = 0.25 },
    .{ .max_vertices = 124, .min_triangles = 124, .max_triangles = 124, .fill_weight = 2 },
    .{ .max_vertices = 128, .min_triangles = 128, .max_triangles = 256, .fill_weight = 0 },
    .{ .max_vertices = 255, .min_triangles = 64, .max_triangles = 512, .fill_weight = 1 },
    .{ .max_vertices = 256, .min_triangles = 256, .max_triangles = 256, .fill_weight = 0.5 },
    .{ .max_vertices = 256, .min_triangles = 1, .max_triangles = 512, .fill_weight = 0.5 },
    .{ .max_vertices = 256, .min_triangles = 512, .max_triangles = 512, .fill_weight = 0 },
    .{ .max_vertices = 256, .min_triangles = 200, .max_triangles = 512, .fill_weight = 3 },
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

/// The three buffers a builder writes, sized for `builder` on `index_count`
/// indices.
const Outputs = struct {
    meshlets: []mo.Meshlet,
    vertices: []u32,
    triangles: []u8,

    fn init(builder: Builder, index_count: usize) !Outputs {
        const meshlets = try gpa.alloc(mo.Meshlet, builder.bound(index_count));
        errdefer gpa.free(meshlets);
        const vertices = try gpa.alloc(u32, index_count);
        errdefer gpa.free(vertices);
        return .{
            .meshlets = meshlets,
            .vertices = vertices,
            .triangles = try gpa.alloc(u8, index_count),
        };
    }

    fn deinit(self: *Outputs) void {
        gpa.free(self.meshlets);
        gpa.free(self.vertices);
        gpa.free(self.triangles);
        self.* = undefined;
    }

    /// Every byte set to `byte`, so unwritten entries compare too.
    fn fill(self: Outputs, byte: u8) void {
        @memset(std.mem.sliceAsBytes(self.meshlets), byte);
        @memset(std.mem.sliceAsBytes(self.vertices), byte);
        @memset(self.triangles, byte);
    }
};

fn runOriginal(builder: Builder, out: Outputs, indices: []const u32, positions: Positions) usize {
    const meshlets: [*]c.Meshlet = @ptrCast(out.meshlets.ptr);
    const p = positions.floats.ptr;
    const n = positions.count;
    const stride = positions.stride * @sizeOf(f32);
    return switch (builder) {
        .standard => |s| c.meshopt_buildMeshlets(
            meshlets,
            out.vertices.ptr,
            out.triangles.ptr,
            indices.ptr,
            indices.len,
            p,
            n,
            stride,
            s.max_vertices,
            s.max_triangles,
            s.cone_weight,
        ),
        .scan => |s| c.meshopt_buildMeshletsScan(
            meshlets,
            out.vertices.ptr,
            out.triangles.ptr,
            indices.ptr,
            indices.len,
            n,
            s.max_vertices,
            s.max_triangles,
        ),
        .flex => |s| c.meshopt_buildMeshletsFlex(
            meshlets,
            out.vertices.ptr,
            out.triangles.ptr,
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
        .spatial, .spatial_scalar => |s| c.meshopt_buildMeshletsSpatial(
            meshlets,
            out.vertices.ptr,
            out.triangles.ptr,
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
    };
}

fn runPort(builder: Builder, out: Outputs, indices: []const u32, positions: Positions) !usize {
    const view = positions.view();
    return switch (builder) {
        .standard => |s| mo.buildMeshlets(
            gpa,
            out.meshlets,
            out.vertices,
            out.triangles,
            indices,
            view,
            s.max_vertices,
            s.max_triangles,
            s.cone_weight,
        ),
        .scan => |s| mo.buildMeshletsScan(
            gpa,
            out.meshlets,
            out.vertices,
            out.triangles,
            indices,
            positions.count,
            s.max_vertices,
            s.max_triangles,
        ),
        .flex => |s| mo.buildMeshletsFlex(
            gpa,
            out.meshlets,
            out.vertices,
            out.triangles,
            indices,
            view,
            s.max_vertices,
            s.min_triangles,
            s.max_triangles,
            s.cone_weight,
            s.split_factor,
        ),
        inline .spatial, .spatial_scalar => |s, tag| mo.clusterizer.buildMeshletsSpatialMerge(
            if (tag == .spatial) mo.clusterizer.target_box_merge else .scalar,
            gpa,
            out.meshlets,
            out.vertices,
            out.triangles,
            indices,
            view,
            s.max_vertices,
            s.min_triangles,
            s.max_triangles,
            s.fill_weight,
        ),
    };
}

/// The builder against the original, every output buffer whole; then the
/// port again, which must write the same.
fn checkBuilder(builder: Builder, indices: []const u32, positions: Positions) !void {
    var want: Outputs = try .init(builder, indices.len);
    defer want.deinit();
    var got: Outputs = try .init(builder, indices.len);
    defer got.deinit();
    var again: Outputs = try .init(builder, indices.len);
    defer again.deinit();
    want.fill(fuzzed.first_fill);
    got.fill(fuzzed.first_fill);
    again.fill(fuzzed.second_fill);

    const want_count = runOriginal(builder, want, indices, positions);
    const got_count = try runPort(builder, got, indices, positions);
    try common.expectSameValue(usize, @tagName(builder), want_count, got_count);
    try common.expectSame(
        u8,
        "meshlets",
        std.mem.sliceAsBytes(want.meshlets),
        std.mem.sliceAsBytes(got.meshlets),
    );
    try common.expectSame(u32, "meshlet vertices", want.vertices, got.vertices);
    try common.expectSame(u8, "meshlet triangles", want.triangles, got.triangles);

    const again_count = try runPort(builder, again, indices, positions);
    try common.expectSameValue(usize, "a second run", got_count, again_count);
    try fuzzed.expectRerunSame(
        "meshlets",
        std.mem.sliceAsBytes(got.meshlets),
        std.mem.sliceAsBytes(again.meshlets),
    );
    try fuzzed.expectRerunSame(
        "meshlet vertices",
        std.mem.sliceAsBytes(got.vertices),
        std.mem.sliceAsBytes(again.vertices),
    );
    try fuzzed.expectRerunSame("meshlet triangles", got.triangles, again.triangles);
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
            // All but the smallest limits, the largest included.
            for (other_settings[0..9].* ++ other_settings[12..].*) |builder| {
                try checkBuilder(builder, indices, .of(mesh.vertices));
            }
            for (spatial_settings[0..10]) |s| {
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

/// Limits for every builder from `rng`, each in its whole range.
fn fuzzBuilders(rng: std.Random) [4]Builder {
    const max_vertices = fuzzed.size(rng, 3, 256);
    const max_triangles = fuzzed.size(rng, 1, 512);
    const min_triangles = fuzzed.size(rng, 1, max_triangles);
    const split_factor: f32 = switch (rng.uintLessThan(u32, 3)) {
        0 => 0,
        else => rng.float(f32) * 4,
    };
    const fill_weight: f32 = switch (rng.uintLessThan(u32, 6)) {
        0, 1 => 0,
        2 => 0.5,
        else => rng.float(f32) * 3,
    };
    return .{
        .{ .standard = .{
            .max_vertices = max_vertices,
            .max_triangles = max_triangles,
            .cone_weight = fuzzed.weight(rng),
        } },
        .{ .scan = .{ .max_vertices = max_vertices, .max_triangles = max_triangles } },
        .{ .flex = .{
            .max_vertices = max_vertices,
            .min_triangles = min_triangles,
            .max_triangles = max_triangles,
            .cone_weight = fuzzed.weight(rng),
            .split_factor = split_factor,
        } },
        .{ .spatial = .{
            .max_vertices = max_vertices,
            .min_triangles = min_triangles,
            .max_triangles = max_triangles,
            .fill_weight = fill_weight,
        } },
    };
}

/// One fuzzed mesh, as generated or ordered for the vertex cache, through
/// every builder with fuzzed limits; the spatial one also without SIMD
/// where positions are finite.
fn checkFuzzed(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var fuzz_mesh = try fuzzed.mesh(rng);
    defer fuzz_mesh.deinit();
    const mesh = fuzz_mesh.mesh;

    if (rng.boolean()) {
        c.meshopt_optimizeVertexCache(
            mesh.indices.ptr,
            mesh.indices.ptr,
            mesh.indices.len,
            mesh.vertices.len,
        );
    }

    const positions: Positions = .of(mesh.vertices);
    const builders = fuzzBuilders(rng);
    for (builders) |builder| try checkBuilder(builder, mesh.indices, positions);
    if (fuzz_mesh.finite) {
        const scalar: Builder = .{ .spatial_scalar = builders[3].spatial };
        try checkBuilder(scalar, mesh.indices, positions);
    }
}

test "the meshlet builders match the original on fuzzed meshes" {
    try common.fuzz("buildMeshlets", 0, checkFuzzed);
}
