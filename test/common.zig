//! Helpers the oracle tests share: the test meshes as the port and the
//! original take them, and comparisons that name what differs.

const std = @import("std");
const builtin = @import("builtin");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const test_options = @import("test_options");

pub const Vertex = meshes.Vertex;
pub const Mesh = meshes.Mesh;

pub const gpa = std.testing.allocator;

/// Floats per demo vertex.
pub const vertex_floats = @sizeOf(Vertex) / @sizeOf(f32);

pub fn floatsOf(vertices: []const Vertex) []const f32 {
    return std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(vertices));
}

/// The positions of `vertices`, the first three floats of each.
pub fn positionsOf(vertices: []const Vertex) mo.VertexFloats {
    return .init(floatsOf(vertices), vertex_floats);
}

/// The positions of `vertices`, 3 floats each. The caller frees them.
pub fn packedPositions(vertices: []const Vertex) ![]f32 {
    const result = try gpa.alloc(f32, vertices.len * 3);
    for (vertices, 0..) |v, i| result[i * 3 ..][0..3].* = .{ v.px, v.py, v.pz };
    return result;
}

/// The test meshes: the demo mesh indexed as the original's demo indexes
/// it, then generated ones, and random ones from `random_seeds` seeds.
pub const MeshSet = struct {
    meshes: [fixed_count + random_seeds]Mesh,
    names: [fixed_count + random_seeds][]const u8,

    const fixed_count = 4;
    pub const random_seeds = 12;

    pub fn init() !MeshSet {
        var set: MeshSet = undefined;
        var made: usize = 0;
        errdefer for (set.meshes[0..made]) |*m| m.deinit(gpa);

        set.meshes[0] = try pirate();
        set.names[0] = "pirate";
        made += 1;
        set.meshes[1] = try meshes.grid(gpa, 40);
        set.names[1] = "grid";
        made += 1;
        set.meshes[2] = try meshes.sphere(gpa, 24, 48);
        set.names[2] = "sphere";
        made += 1;
        set.meshes[3] = try meshes.random(gpa, 0, 3, 1);
        set.names[3] = "tiny";
        made += 1;
        for (0..random_seeds) |seed| {
            const vertex_count: u32 = @intCast(16 + seed * seed * 37);
            const triangle_count: u32 = @intCast(8 + seed * seed * 61);
            set.meshes[fixed_count + seed] = try meshes.random(
                gpa,
                seed,
                vertex_count,
                triangle_count,
            );
            set.names[fixed_count + seed] = "random";
            made += 1;
        }
        return set;
    }

    pub fn deinit(self: *MeshSet) void {
        for (&self.meshes) |*m| m.deinit(gpa);
    }
};

/// The demo mesh indexed by the original's `generateVertexRemap`, as its
/// demo does.
pub fn pirate() !Mesh {
    const soup = try meshes.pirateSoup(gpa);
    defer gpa.free(soup);
    const remap = try gpa.alloc(u32, soup.len);
    defer gpa.free(remap);
    const unique = c.meshopt_generateVertexRemap(
        remap.ptr,
        null,
        soup.len,
        soup.ptr,
        soup.len,
        @sizeOf(Vertex),
    );
    return meshes.indexed(gpa, soup, remap, unique);
}

/// Fails, naming `what` and the first differing item, unless `want` and
/// `got` are equal item for item, floats compared bit for bit.
pub fn expectSame(comptime T: type, what: []const u8, want: []const T, got: []const T) !void {
    if (want.len != got.len) {
        std.debug.print("{s}: {d} items from the original, {d} from the port\n", .{
            what,
            want.len,
            got.len,
        });
        return error.Mismatch;
    }
    for (want, got, 0..) |w, g, i| {
        if (!std.mem.eql(u8, std.mem.asBytes(&w), std.mem.asBytes(&g))) {
            std.debug.print(
                "{s}: item {d} differs: original {any}, port {any}\n",
                .{ what, i, w, g },
            );
            return error.Mismatch;
        }
    }
}

/// `expectSame` for floats, except that a NaN matches any NaN. Non-finite
/// or overflowing inputs make NaNs, and when an operation's operands hold
/// several, LLVM leaves open which one it returns, so a NaN's sign and
/// payload follow how each compiler ordered the operands, on both sides.
pub fn expectSameAnyNan(what: []const u8, want: []const f32, got: []const f32) !void {
    if (want.len != got.len) return expectSame(f32, what, want, got);
    for (want, got, 0..) |w, g, i| {
        if (std.math.isNan(w) and std.math.isNan(g)) continue;
        if (@as(u32, @bitCast(w)) != @as(u32, @bitCast(g))) {
            std.debug.print(
                "{s}: item {d} differs: original {any}, port {any}\n",
                .{ what, i, w, g },
            );
            return error.Mismatch;
        }
    }
}

/// Fails unless the bounds are the same, floats as `expectSameAnyNan`
/// compares them.
pub fn expectSameBoundsAnyNan(what: []const u8, want: c.Bounds, got: mo.Bounds) !void {
    const want_floats: [11]f32 = @bitCast(std.mem.asBytes(&want)[0..44].*);
    const got_floats: [11]f32 = @bitCast(std.mem.asBytes(&got)[0..44].*);
    try expectSameAnyNan(what, &want_floats, &got_floats);
    try expectSame(u8, what, std.mem.asBytes(&want)[44..], std.mem.asBytes(&got)[44..]);
}

/// `expectSame` for one value.
pub fn expectSameValue(comptime T: type, what: []const u8, want: T, got: T) !void {
    return expectSame(T, what, &.{want}, &.{got});
}

/// The rotation of `triangle` that sorts first: the codecs keep each
/// triangle's winding but may rotate it.
pub fn canonicalTriangle(comptime T: type, triangle: [3]T) [3]T {
    const a, const b, const c_ = triangle;
    var best = triangle;
    for ([_][3]T{ .{ b, c_, a }, .{ c_, a, b } }) |rotated| {
        if (std.mem.order(T, &rotated, &best) == .lt) best = rotated;
    }
    return best;
}

/// Fails unless the structs `want` and `got` have the same value in every
/// field of `want`'s type, compared as `expectSame` does.
pub fn expectSameFields(want: anytype, got: anytype) !void {
    const info = @typeInfo(@TypeOf(want)).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        try expectSameValue(T, name, @field(want, name), @field(got, name));
    }
}

/// `indices` optimized for the vertex cache by the original, the input the
/// functions after it in a pipeline expect. The caller frees the result.
pub fn vertexCacheOptimized(indices: []const u32, vertex_count: usize) ![]u32 {
    const result = try gpa.alloc(u32, indices.len);
    c.meshopt_optimizeVertexCache(result.ptr, indices.ptr, indices.len, vertex_count);
    return result;
}

/// `count` random points of 3 floats from `seed`, uniform in a cube of side
/// `extent` around the origin. The caller frees them.
pub fn randomPoints(seed: u64, count: usize, extent: f32) ![]f32 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const points = try gpa.alloc(f32, count * 3);
    for (points) |*p| p.* = (rng.float(f32) - 0.5) * extent;
    return points;
}

/// Points of 3 floats with the values that test edge cases: zeros of both
/// signs, infinities, NaN, the largest and smallest floats and denormals.
pub const special_points = [_]f32{
    0,                      0,                       0,
    -0.0,                   1,                       -1,
    std.math.floatMax(f32), -std.math.floatMax(f32), 0,
    std.math.inf(f32),      2,                       3,
    -std.math.inf(f32),     -2,                      -3,
    std.math.nan(f32),      4,                       5,
    1e-40,                  -1e-40,                  std.math.floatMin(f32),
    1e30,                   -1e30,                   1e-30,
    0.5,                    0.25,                    0.125,
};

/// How many cases every fuzz test runs.
pub const fuzz_cases = 1000;

/// Runs `check(seed)` on `fuzz_cases` seeds from `first_seed` plus the
/// build's `-Dfuzz-seed`, each case building its inputs from its own seed,
/// and prints the seed of the case that fails, by an error or, outside
/// Windows, by a failed safety check.
pub fn fuzz(name: []const u8, first_seed: u64, check: anytype) !void {
    const report_crashes = builtin.os.tag != .windows;
    var previous: std.posix.Sigaction = undefined;
    if (report_crashes) {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = reportCrash },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESETHAND,
        };
        std.posix.sigaction(.ABRT, &action, &previous);
    }
    defer if (report_crashes) std.posix.sigaction(.ABRT, &previous, null);

    for (0..fuzz_cases) |i| {
        const seed = first_seed +% test_options.fuzz_seed +% i;
        running = .{ .name = name, .seed = seed };
        check(seed) catch |err| {
            std.debug.print("{s}: failed at seed {d}\n", .{ name, seed });
            return err;
        };
    }
}

/// The fuzz case running now.
var running: struct { name: []const u8 = "", seed: u64 = 0 } = .{};

/// Names the fuzz case that was running when a failed safety check aborts
/// the process, after the panic's own message.
fn reportCrash(_: std.posix.SIG) callconv(.c) void {
    var buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}: crashed at seed {d}\n", .{
        running.name,
        running.seed,
    }) catch return;
    _ = std.c.write(2, line.ptr, line.len);
}

/// A random mesh for the fuzz case `seed`, with one to `max_vertices`
/// vertices and up to `max_triangles` triangles, made by `meshes.random`.
/// Its positions stay on the lattice in one case in four, where many
/// triangles are degenerate or coplanar; in the others they move into a
/// random cloud, onto a plane, or get the float range's special values.
/// The caller frees it.
pub fn fuzzMesh(seed: u64, max_vertices: u32, max_triangles: u32) !Mesh {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const vertex_count = rng.uintLessThan(u32, max_vertices) + 1;
    const triangle_count = rng.uintAtMost(u32, max_triangles);
    const mesh = try meshes.random(gpa, rng.int(u64), vertex_count, triangle_count);
    switch (rng.uintLessThan(u32, 4)) {
        0 => {},
        1 => {
            const extent = std.math.pow(f32, 10, @floatFromInt(rng.intRangeAtMost(i32, -3, 6)));
            for (mesh.vertices) |*v| {
                v.px = (rng.float(f32) - 0.5) * extent;
                v.py = (rng.float(f32) - 0.5) * extent;
                v.pz = (rng.float(f32) - 0.5) * extent;
            }
        },
        2 => {
            const axis = rng.uintLessThan(usize, 3);
            for (mesh.vertices) |*v| position(v)[axis] = 0.25;
        },
        else => for (mesh.vertices) |*v| {
            if (rng.uintLessThan(u32, 4) != 0) continue;
            const axis = rng.uintLessThan(usize, 3);
            position(v)[axis] = special_points[rng.uintLessThan(usize, special_points.len)];
        },
    }
    return mesh;
}

fn position(v: *Vertex) *[3]f32 {
    return @ptrCast(v);
}

/// The points of 3 floats in `points` spread `stride` floats apart, the
/// floats between them NaN, which no position read may see. The caller
/// frees the result.
pub fn strided(points: []const f32, stride: usize) ![]f32 {
    const count = points.len / 3;
    const result = try gpa.alloc(f32, count * stride);
    @memset(result, std.math.nan(f32));
    for (0..count) |i| result[i * stride ..][0..3].* = points[i * 3 ..][0..3].*;
    return result;
}

/// The byte every output is filled with before a second run of the port,
/// which differs from the first run's fill.
pub const rerun_fill = 0x55;

/// Fails unless a rerun of the port into an output filled with
/// `rerun_fill` wrote what the first run did: each byte is the same, or
/// left at its fill in both runs.
pub fn expectSameRerun(
    comptime T: type,
    what: []const u8,
    first: []const T,
    first_fill: u8,
    rerun: []const T,
) !void {
    const a = std.mem.sliceAsBytes(first);
    const b = std.mem.sliceAsBytes(rerun);
    std.debug.assert(a.len == b.len);
    for (a, b, 0..) |x, y, i| {
        if (x == y or (x == first_fill and y == rerun_fill)) continue;
        std.debug.print("{s}: byte {d} differs on a rerun: {x} then {x}\n", .{ what, i, x, y });
        return error.Mismatch;
    }
}
