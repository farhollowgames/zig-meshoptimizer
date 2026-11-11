//! The voxel remesher against the original: every option and every
//! capacity case, at resolutions from the smallest to the largest, on the
//! demo mesh, closed and open generated meshes, awkward geometry and fuzzed
//! meshes.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;
const Mesh = common.Mesh;

const all_options = [_]mo.RemeshOptions{
    .{},
    .{ .shell = true },
    .{ .solve = true },
    .{ .shell = true, .solve = true },
    .{ .internal_debug = true },
    .{ .shell = true, .solve = true, .internal_debug = true },
};

/// The original's count, the triangles it writes to `destination` (null
/// to only count) and the port's.
fn original(
    destination: ?[]f32,
    indices: []const u32,
    positions: mo.VertexFloats,
    resolution: u32,
    options: mo.RemeshOptions,
) usize {
    return c.meshopt_remesh(
        if (destination) |d| d.ptr else null,
        if (destination) |d| d.len / 9 else 0,
        indices.ptr,
        indices.len,
        positions.data.ptr,
        positions.count(),
        positions.stride * @sizeOf(f32),
        @intCast(resolution),
        @backingInt(options),
    );
}

/// Runs both on every capacity case: counting only, room for the whole
/// mesh with some to spare, exactly the whole mesh, one triangle short, a
/// few triangles, and none. Every float of the buffers must match, and a
/// second run of the port must give the same floats over a different fill.
fn checkRemesh(
    what: []const u8,
    indices: []const u32,
    positions: mo.VertexFloats,
    resolution: u32,
    options: mo.RemeshOptions,
) !void {
    errdefer std.debug.print("{s}: resolution {d}, options 0x{x}\n", .{
        what,
        resolution,
        @backingInt(options),
    });

    const want_bound = original(null, indices, positions, resolution, options);
    const got_bound = try mo.remesh(gpa, null, indices, positions, resolution, options);
    try common.expectSameValue(usize, "remesh bound", want_bound, got_bound);

    // Room for the bound and two more triangles, so the tail shows what is
    // left unwritten.
    const capacity = want_bound + 2;
    const want = try gpa.alloc(f32, capacity * 9);
    defer gpa.free(want);
    const got = try gpa.alloc(f32, capacity * 9);
    defer gpa.free(got);
    const again = try gpa.alloc(f32, capacity * 9);
    defer gpa.free(again);

    @memset(want, 0);
    @memset(got, 0);
    const want_count = original(want, indices, positions, resolution, options);
    const got_count = try mo.remesh(gpa, got, indices, positions, resolution, options);
    try common.expectSameValue(usize, "remesh count", want_count, got_count);
    try std.testing.expect(want_count <= want_bound);
    try common.expectSame(f32, "remesh triangles", want, got);

    // The port again, over a different fill: the same triangles.
    @memset(std.mem.sliceAsBytes(again), 0x55);
    const again_count = try mo.remesh(gpa, again, indices, positions, resolution, options);
    try common.expectSameValue(usize, "remesh count, second run", got_count, again_count);
    const written = got_count * 9;
    try common.expectSame(f32, "remesh triangles, second run", got[0..written], again[0..written]);

    const short_capacities = [_]usize{
        want_count,
        want_count -| 1,
        @min(want_count, 3),
        @min(want_count, 1),
        0,
    };
    for (short_capacities) |short| {
        @memset(want, 0);
        @memset(got, 0);
        const room = short * 9;
        const short_want = original(want[0..room], indices, positions, resolution, options);
        const short_got = try mo.remesh(gpa, got[0..room], indices, positions, resolution, options);
        try common.expectSameValue(usize, "remesh count, short", short_want, short_got);
        try common.expectSame(f32, "remesh triangles, short", want, got);
    }
}

fn checkMesh(what: []const u8, mesh: Mesh, resolutions: []const u32) !void {
    for (resolutions) |resolution| {
        for (all_options) |options| {
            const positions = common.positionsOf(mesh.vertices);
            try checkRemesh(what, mesh.indices, positions, resolution, options);
        }
    }
}

const every_size = [_]u32{ 4, 5, 6, 7, 8, 13, 16, 31, 32, 64, 100, 128, 255, 256 };
const some_sizes = [_]u32{ 4, 8, 32, 64, 128, 256 };
const small_sizes = [_]u32{ 4, 5, 8, 17, 32, 64 };

test "remesh matches the original on the demo mesh" {
    var mesh = try common.pirate();
    defer mesh.deinit(gpa);
    try checkMesh("pirate", mesh, &every_size);

    // Positions alone, three floats apart.
    const packed_positions = try gpa.alloc(f32, mesh.vertices.len * 3);
    defer gpa.free(packed_positions);
    for (mesh.vertices, 0..) |v, i| packed_positions[i * 3 ..][0..3].* = .{ v.px, v.py, v.pz };
    for (some_sizes) |resolution| {
        for (all_options) |options| {
            const view: mo.VertexFloats = .init(packed_positions, 3);
            try checkRemesh("pirate positions", mesh.indices, view, resolution, options);
        }
    }
}

test "remesh matches the original on every test mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes, set.names) |mesh, name| try checkMesh(name, mesh, &small_sizes);
}

test "remesh matches the original on closed and open shapes" {
    var sphere = try meshes.sphere(gpa, 24, 48);
    defer sphere.deinit(gpa);
    try checkMesh("sphere", sphere, &some_sizes);

    var sheet = try meshes.grid(gpa, 30);
    defer sheet.deinit(gpa);
    try checkMesh("grid", sheet, &some_sizes);

    // Two sheets a sliver apart, facing away from each other.
    var near = try transformed(sheet, 1, .{ 0, 0, 1e-3 });
    defer near.deinit(gpa);
    flip(near);
    var thin = try merged(sheet, near);
    defer thin.deinit(gpa);
    try checkMesh("thin sheets", thin, &some_sizes);

    // A sheet bent into a slab one voxel thick at the coarsest grids.
    var slab_top = try transformed(sheet, 1, .{ 0, 0, 0.05 });
    defer slab_top.deinit(gpa);
    var slab = try merged(sheet, slab_top);
    defer slab.deinit(gpa);
    try checkMesh("slab", slab, &some_sizes);

    // A sphere inside another, and two that cross.
    var inner = try transformed(sphere, 0.5, .{ 0.1, 0, 0 });
    defer inner.deinit(gpa);
    flip(inner);
    var nested = try merged(sphere, inner);
    defer nested.deinit(gpa);
    try checkMesh("nested spheres", nested, &some_sizes);

    var shifted = try transformed(sphere, 1, .{ 0.8, 0.3, 0 });
    defer shifted.deinit(gpa);
    var crossing = try merged(sphere, shifted);
    defer crossing.deinit(gpa);
    try checkMesh("crossing spheres", crossing, &some_sizes);
}

test "remesh matches the original on degenerate and tiny triangles" {
    var sphere = try meshes.sphere(gpa, 12, 24);
    defer sphere.deinit(gpa);

    // Every third triangle collapsed to a point or a line.
    var degenerate = try transformed(sphere, 1, .{ 0, 0, 0 });
    defer degenerate.deinit(gpa);
    var t: usize = 0;
    while (t < degenerate.indices.len) : (t += 9) {
        degenerate.indices[t + 1] = degenerate.indices[t];
        if (t + 5 < degenerate.indices.len) degenerate.indices[t + 5] = degenerate.indices[t + 4];
    }
    try checkMesh("degenerate", degenerate, &small_sizes);

    // A tiny sphere beside a large one: triangles far smaller than a voxel.
    var tiny = try transformed(sphere, 1e-4, .{ 2, 0, 0 });
    defer tiny.deinit(gpa);
    var mixed = try merged(sphere, tiny);
    defer mixed.deinit(gpa);
    try checkMesh("tiny triangles", mixed, &some_sizes);

    // Every vertex at one point: the grid has no extent.
    var point = try transformed(sphere, 0, .{ 3, 4, 5 });
    defer point.deinit(gpa);
    try checkMesh("one point", point, &small_sizes);

    // One triangle, and no triangles at all.
    const one = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const one_view: mo.VertexFloats = .init(&one, 3);
    for (every_size) |resolution| {
        for (all_options) |options| {
            try checkRemesh("one triangle", &.{ 0, 1, 2 }, one_view, resolution, options);
            try checkRemesh("no triangles", &.{}, one_view, resolution, options);
            try checkRemesh("no vertices", &.{}, .init(&.{}, 3), resolution, options);
        }
    }
}

test "remesh matches the original far from the origin and at extreme scales" {
    var sphere = try meshes.sphere(gpa, 12, 24);
    defer sphere.deinit(gpa);

    const placements = [_]struct { scale: f32, offset: [3]f32 }{
        .{ .scale = 1, .offset = .{ 1e6, -1e6, 1e5 } },
        .{ .scale = 1, .offset = .{ 3e7, 0, 0 } },
        .{ .scale = 1e-30, .offset = .{ 0, 0, 0 } },
        .{ .scale = 1e-20, .offset = .{ 1, 1, 1 } },
        .{ .scale = 1e18, .offset = .{ 0, 0, 0 } },
        .{ .scale = 1e30, .offset = .{ 0, 0, 0 } },
        .{ .scale = 3e38, .offset = .{ 0, 0, 0 } },
    };
    for (placements) |placement| {
        var moved = try transformed(sphere, placement.scale, placement.offset);
        defer moved.deinit(gpa);
        try checkMesh("moved sphere", moved, &small_sizes);
    }
}

test "remesh matches the original on non-finite positions" {
    var sphere = try meshes.sphere(gpa, 8, 16);
    defer sphere.deinit(gpa);
    const specials = [_]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 1e38 };
    for (specials, 0..) |special, k| {
        var broken = try transformed(sphere, 1, .{ 0, 0, 0 });
        defer broken.deinit(gpa);
        broken.vertices[k * 7 + 3].py = special;
        try checkMesh("non-finite", broken, &.{ 4, 16, 64 });
    }
}

fn fuzzRemesh(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();

    const vertex_count = rng.intRangeAtMost(u32, 3, 60);
    const triangle_count = rng.intRangeAtMost(u32, 1, 80);
    const vertices = try gpa.alloc(f32, vertex_count * 3);
    defer gpa.free(vertices);

    // Positions on a lattice (repeats and flat shapes) or anywhere, in a box
    // of random size and place.
    const lattice = rng.boolean();
    const extent = std.math.pow(f32, 10, rng.float(f32) * 8 - 4);
    const center = (rng.float(f32) - 0.5) * extent * 10;
    for (vertices) |*v| {
        const unit = if (lattice)
            @as(f32, @floatFromInt(rng.intRangeAtMost(i32, -3, 3))) / 3
        else
            rng.float(f32) * 2 - 1;
        v.* = center + unit * extent;
    }

    const indices = try gpa.alloc(u32, triangle_count * 3);
    defer gpa.free(indices);
    for (indices) |*index| index.* = rng.uintLessThan(u32, vertex_count);

    const resolution = if (rng.uintLessThan(u32, 8) == 0)
        rng.intRangeAtMost(u32, 4, 256)
    else
        rng.intRangeAtMost(u32, 4, 40);
    // Any bits: the original reads only its own.
    const options: mo.RemeshOptions = @fromBackingInt(rng.int(u32));

    try checkRemesh("fuzz", indices, .init(vertices, 3), resolution, options);
}

test "remesh matches the original on fuzzed meshes" {
    try common.fuzz("remesh", 0, fuzzRemesh);
}

/// A copy of `mesh` with every position scaled by `scale`, then moved by
/// `offset`.
fn transformed(mesh: Mesh, scale: f32, offset: [3]f32) !Mesh {
    const vertices = try gpa.dupe(Vertex, mesh.vertices);
    errdefer gpa.free(vertices);
    for (vertices) |*v| {
        v.px = v.px * scale + offset[0];
        v.py = v.py * scale + offset[1];
        v.pz = v.pz * scale + offset[2];
    }
    return .{ .vertices = vertices, .indices = try gpa.dupe(u32, mesh.indices) };
}

/// Reverses the winding of every triangle of `mesh`.
fn flip(mesh: Mesh) void {
    var t: usize = 0;
    while (t < mesh.indices.len) : (t += 3) {
        std.mem.swap(u32, &mesh.indices[t + 1], &mesh.indices[t + 2]);
    }
}

/// One mesh of the triangles of both.
fn merged(a: Mesh, b: Mesh) !Mesh {
    const vertices = try std.mem.concat(gpa, Vertex, &.{ a.vertices, b.vertices });
    errdefer gpa.free(vertices);
    const indices = try std.mem.concat(gpa, u32, &.{ a.indices, b.indices });
    const base: u32 = @intCast(a.vertices.len);
    for (indices[a.indices.len..]) |*index| index.* += base;
    return .{ .vertices = vertices, .indices = indices };
}
