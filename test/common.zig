//! Helpers the oracle tests share: the test meshes as the port and the
//! original take them, and comparisons that name what differs.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");

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

/// How many cases every fuzz test runs.
pub const fuzz_cases = 1000;

/// Runs `check` on `fuzz_cases` seeds from `first_seed`, each case building its inputs
/// from its own seed, and prints the seed of the case that fails.
pub fn fuzz(name: []const u8, first_seed: u64, check: *const fn (seed: u64) anyerror!void) !void {
    for (0..fuzz_cases) |i| {
        const seed = first_seed + i;
        check(seed) catch |err| {
            std.debug.print("{s}: failed at seed {d}\n", .{ name, seed });
            return err;
        };
    }
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
