//! Tangent and normal generation against the original: every option,
//! crease angles from 0 to pi and every smoothing range, on the demo mesh,
//! generated meshes with seams, mirrors and degenerate triangles, and
//! fuzzed meshes; and the cosine the crease cutoff comes from, on every
//! angle generateNormals takes.

const std = @import("std");
const builtin = @import("builtin");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;
const Mesh = common.Mesh;

const all_options = [_]mo.TangentOptions{
    .{},
    .{ .compatible = true },
    .{ .zero_fallback = true },
    .{ .compatible = true, .zero_fallback = true },
};

/// Positions, normals and texture coordinates of `vertices`.
const Streams = struct {
    positions: mo.VertexFloats,
    normals: mo.VertexFloats,
    uvs: mo.VertexFloats,

    fn of(vertices: []const Vertex) Streams {
        const floats = common.floatsOf(vertices);
        if (vertices.len == 0) return .{
            .positions = .init(&.{}, common.vertex_floats),
            .normals = .init(&.{}, common.vertex_floats),
            .uvs = .init(&.{}, common.vertex_floats),
        };
        return .{
            .positions = .init(floats, common.vertex_floats),
            .normals = .init(floats[3..], common.vertex_floats),
            .uvs = .init(floats[6..], common.vertex_floats),
        };
    }
};

fn checkTangents(
    what: []const u8,
    vertices: []const Vertex,
    indices: ?[]const u32,
    options: mo.TangentOptions,
) !void {
    errdefer std.debug.print("{s}: options 0x{x}, indexed {}\n", .{
        what,
        @backingInt(options),
        indices != null,
    });

    const index_count = if (indices) |list| list.len else vertices.len;
    const want = try gpa.alloc(f32, index_count * 4);
    defer gpa.free(want);
    const got = try gpa.alloc(f32, index_count * 4);
    defer gpa.free(got);
    @memset(std.mem.sliceAsBytes(want), 0xcd);
    @memset(std.mem.sliceAsBytes(got), 0xcd);

    const floats = common.floatsOf(vertices);
    c.meshopt_generateTangents(
        want.ptr,
        if (indices) |list| list.ptr else null,
        index_count,
        floats.ptr,
        vertices.len,
        @sizeOf(Vertex),
        floats.ptr + 3,
        @sizeOf(Vertex),
        floats.ptr + 6,
        @sizeOf(Vertex),
        @backingInt(options),
    );
    const streams: Streams = .of(vertices);
    try mo.generateTangents(
        u32,
        gpa,
        got,
        indices,
        streams.positions,
        streams.normals,
        streams.uvs,
        options,
    );
    try expectSameFloats("generateTangents", want, got);

    // The port again, over a different fill: the same tangents.
    @memset(std.mem.sliceAsBytes(got), 0x55);
    try mo.generateTangents(
        u32,
        gpa,
        got,
        indices,
        streams.positions,
        streams.normals,
        streams.uvs,
        options,
    );
    try expectSameFloats("generateTangents, second run", want, got);
}

fn checkNormals(
    what: []const u8,
    vertices: []const Vertex,
    indices: ?[]const u32,
    crease_angle: f32,
    smoothing: f32,
) !void {
    errdefer std.debug.print("{s}: crease {e}, smoothing {e}, indexed {}\n", .{
        what,
        crease_angle,
        smoothing,
        indices != null,
    });

    const index_count = if (indices) |list| list.len else vertices.len;
    const want = try gpa.alloc(f32, index_count * 3);
    defer gpa.free(want);
    const got = try gpa.alloc(f32, index_count * 3);
    defer gpa.free(got);
    @memset(std.mem.sliceAsBytes(want), 0xcd);
    @memset(std.mem.sliceAsBytes(got), 0xcd);

    const positions = common.positionsOf(vertices);
    c.meshopt_generateNormals(
        want.ptr,
        if (indices) |list| list.ptr else null,
        index_count,
        positions.data.ptr,
        vertices.len,
        @sizeOf(Vertex),
        crease_angle,
        smoothing,
    );
    try mo.generateNormals(u32, gpa, got, indices, positions, crease_angle, smoothing);
    try expectSameFloats("generateNormals", want, got);

    @memset(std.mem.sliceAsBytes(got), 0x55);
    try mo.generateNormals(u32, gpa, got, indices, positions, crease_angle, smoothing);
    try expectSameFloats("generateNormals, second run", want, got);
}

const expectSameFloats = common.expectSameAnyNan;

const crease_angles = [_]f32{ 0, 1e-6, 0.3, 1, std.math.pi / 2.0, 2, 3, 3.1415927 };
const smoothings = [_]f32{ 0, 0.25, 1, 2.5, 5, 9.5, 10, 11, 3e9, std.math.inf(f32) };

fn checkMesh(what: []const u8, mesh: Mesh) !void {
    // Indexed, and as one vertex per corner.
    const soup = try gpa.alloc(Vertex, mesh.indices.len);
    defer gpa.free(soup);
    for (mesh.indices, soup) |index, *v| v.* = mesh.vertices[index];

    for (all_options) |options| {
        try checkTangents(what, mesh.vertices, mesh.indices, options);
        try checkTangents(what, soup, null, options);
    }
    for (crease_angles) |crease| {
        for (smoothings) |smoothing| {
            try checkNormals(what, mesh.vertices, mesh.indices, crease, smoothing);
        }
        try checkNormals(what, soup, null, crease, 1.5);
    }
}

test "tangents and normals match the original on the demo mesh" {
    var mesh = try common.pirate();
    defer mesh.deinit(gpa);
    try checkMesh("pirate", mesh);
}

test "tangents and normals match the original on every test mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes, set.names) |mesh, name| try checkMesh(name, mesh);
}

test "tangents and normals match the original on seams, mirrors and degenerate triangles" {
    // A sphere's texture seam and poles.
    var sphere = try meshes.sphere(gpa, 16, 32);
    defer sphere.deinit(gpa);
    try checkMesh("sphere", sphere);

    // A grid whose texture mirrors at its middle, so orientations flip.
    var mirrored = try meshes.grid(gpa, 12);
    defer mirrored.deinit(gpa);
    for (mirrored.vertices) |*v| {
        if (v.px > 0.5) v.tx = 1 - v.tx;
    }
    try checkMesh("mirrored grid", mirrored);

    // Every texture coordinate the same: no triangle has a texture area.
    var flat_uvs = try meshes.grid(gpa, 6);
    defer flat_uvs.deinit(gpa);
    for (flat_uvs.vertices) |*v| v.tx = 0.5;
    try checkMesh("collinear uvs", flat_uvs);
    for (flat_uvs.vertices) |*v| v.ty = 0.5;
    try checkMesh("zero-area uvs", flat_uvs);

    // Every third triangle collapsed to a point or a line, some isolated.
    var degenerate = try meshes.sphere(gpa, 8, 16);
    defer degenerate.deinit(gpa);
    var t: usize = 0;
    while (t + 9 <= degenerate.indices.len) : (t += 9) {
        degenerate.indices[t + 1] = degenerate.indices[t];
        degenerate.indices[t + 5] = degenerate.indices[t + 4];
    }
    try checkMesh("degenerate", degenerate);

    // Two triangles of one vertex each, and a single triangle.
    const lone = [_]Vertex{
        .{ .px = 0, .py = 0, .pz = 0, .nx = 0, .ny = 0, .nz = 1, .tx = 0, .ty = 0 },
        .{ .px = 1, .py = 0, .pz = 0, .nx = 0, .ny = 0, .nz = 1, .tx = 1, .ty = 0 },
        .{ .px = 0, .py = 1, .pz = 0, .nx = 0, .ny = 0, .nz = 1, .tx = 0, .ty = 1 },
    };
    try checkMesh(
        "one triangle",
        .{ .vertices = @constCast(&lone), .indices = @constCast(&[_]u32{ 0, 1, 2 }) },
    );
    try checkMesh(
        "points",
        .{ .vertices = @constCast(&lone), .indices = @constCast(&[_]u32{ 0, 0, 0, 1, 1, 1 }) },
    );
    try checkMesh("empty", .{ .vertices = @constCast(lone[0..0]), .indices = &.{} });
}

test "tangents and normals match the original on non-finite input" {
    var sphere = try meshes.sphere(gpa, 6, 12);
    defer sphere.deinit(gpa);
    const specials = [_]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 3e38 };
    for (specials, 0..) |special, k| {
        var broken = try meshes.sphere(gpa, 6, 12);
        defer broken.deinit(gpa);
        broken.vertices[k * 5 + 7].py = special;
        broken.vertices[k * 3 + 2].nx = special;
        broken.vertices[k * 11 + 1].ty = special;
        try checkMesh("non-finite", broken);
    }
}

fn fuzzMesh(seed: u64) !struct { vertices: []Vertex, indices: []u32, indexed: bool } {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();

    const vertex_count = rng.intRangeAtMost(u32, 3, 40);
    const triangle_count = rng.intRangeAtMost(u32, 1, 50);
    const vertices = try gpa.alloc(Vertex, vertex_count);
    errdefer gpa.free(vertices);

    // Lattice positions and texture coordinates repeat, so vertices merge,
    // triangles fold and texture areas vanish.
    const lattice = rng.boolean();
    for (vertices) |*v| {
        const p = if (lattice) [3]f32{
            @floatFromInt(rng.intRangeAtMost(i32, -2, 2)),
            @floatFromInt(rng.intRangeAtMost(i32, -2, 2)),
            @floatFromInt(rng.intRangeAtMost(i32, -2, 2)),
        } else [3]f32{ rng.float(f32) * 2 - 1, rng.float(f32) * 2 - 1, rng.float(f32) * 2 - 1 };
        var n = [3]f32{ rng.float(f32) * 2 - 1, rng.float(f32) * 2 - 1, rng.float(f32) * 2 - 1 };
        const length = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (length > 0 and rng.uintLessThan(u32, 4) != 0) {
            for (&n) |*x| x.* /= length;
        }
        v.* = .{
            .px = p[0],
            .py = p[1],
            .pz = p[2],
            .nx = n[0],
            .ny = n[1],
            .nz = n[2],
            .tx = if (lattice) @floatFromInt(rng.uintLessThan(u32, 3)) else rng.float(f32),
            .ty = if (lattice) @floatFromInt(rng.uintLessThan(u32, 3)) else rng.float(f32),
        };
        // Some copies of earlier vertices, some with a texture mirrored.
        if (rng.uintLessThan(u32, 6) == 0) {
            const earlier = vertices[rng.uintLessThan(usize, vertex_count)];
            v.px = earlier.px;
            v.py = earlier.py;
            v.pz = earlier.pz;
        }
    }

    const indexed = rng.uintLessThan(u32, 4) != 0;
    const indices = try gpa.alloc(u32, triangle_count * 3);
    for (indices) |*index| index.* = rng.uintLessThan(u32, vertex_count);
    return .{ .vertices = vertices, .indices = indices, .indexed = indexed };
}

fn fuzzTangents(seed: u64) !void {
    const mesh = try fuzzMesh(seed);
    defer gpa.free(mesh.vertices);
    defer gpa.free(mesh.indices);
    const options: mo.TangentOptions = @fromBackingInt(@as(u32, @truncate(seed * 2654435761)));
    if (mesh.indexed) {
        try checkTangents("fuzz", mesh.vertices, mesh.indices, options);
    } else {
        const soup = try gpa.alloc(Vertex, mesh.indices.len);
        defer gpa.free(soup);
        for (mesh.indices, soup) |index, *v| v.* = mesh.vertices[index];
        try checkTangents("fuzz", soup, null, options);
    }
}

fn fuzzNormals(seed: u64) !void {
    const mesh = try fuzzMesh(seed);
    defer gpa.free(mesh.vertices);
    defer gpa.free(mesh.indices);
    var prng: std.Random.DefaultPrng = .init(seed ^ 0x9e3779b97f4a7c15);
    const rng = prng.random();
    const crease = rng.float(f32) * 3.1415927;
    const smoothing = if (rng.boolean()) 0 else rng.float(f32) * 12;
    if (mesh.indexed) {
        try checkNormals("fuzz", mesh.vertices, mesh.indices, crease, smoothing);
    } else {
        const soup = try gpa.alloc(Vertex, mesh.indices.len);
        defer gpa.free(soup);
        for (mesh.indices, soup) |index, *v| v.* = mesh.vertices[index];
        try checkNormals("fuzz", soup, null, crease, smoothing);
    }
}

test "tangents match the original on fuzzed meshes" {
    try common.fuzz("generateTangents", 0, fuzzTangents);
}

test "normals match the original on fuzzed meshes" {
    try common.fuzz("generateNormals", 0, fuzzNormals);
}

test "the crease cosine matches the system libm on every angle from 0 to pi" {
    // 3.1415927, the largest crease angle.
    try expectSameCosf(0, 0x40490fdb, 1);
}

test "the cosine matches the system libm on every float" {
    // Every float in the optimized modes; every 7th in Debug, where the
    // whole sweep takes minutes.
    const step = if (builtin.mode == .debug) 7 else 1;
    try expectSameCosf(0x40490fdc, std.math.maxInt(u32), step);
}

/// Compares the port's cosine with the system libm's on the float bits
/// from `first` to `last`, `step` apart.
fn expectSameCosf(first: u32, last: u32, step: u32) !void {
    var bits: u64 = first;
    while (bits <= last) : (bits += step) {
        const x: f32 = @bitCast(@as(u32, @intCast(bits)));
        const want: u32 = @bitCast(c.reference_cosf(x));
        const got: u32 = @bitCast(mo.tangentspace.cosfForTest(x));
        // A NaN result is any NaN: the libm returns the input NaN, quieted,
        // or makes a new one, as the port does.
        if (want != got and !(std.math.isNan(@as(f32, @bitCast(want))) and
            std.math.isNan(@as(f32, @bitCast(got)))))
        {
            std.debug.print(
                "cosf(0x{x:0>8}): libm 0x{x:0>8}, port 0x{x:0>8}\n",
                .{ bits, want, got },
            );
            return error.Mismatch;
        }
    }
}
