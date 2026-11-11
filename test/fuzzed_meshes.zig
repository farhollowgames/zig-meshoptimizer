//! Inputs for the fuzz tests of the vertex cache optimizer, the meshlet
//! builders and utilities and the partitioner, each built from one seed;
//! and the check that a second run of the port writes what its first did.

const std = @import("std");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;

/// The byte every output is set to before the original's run and the
/// port's first.
pub const first_fill = 0xcd;
/// The byte every output is set to before the port's second run.
pub const second_fill = 0x55;

/// Fails unless the port's second run, into an output set to
/// `second_fill`, wrote what its first run, into one set to `first_fill`,
/// wrote: every byte is the same, or left unwritten by both runs.
pub fn expectRerunSame(what: []const u8, first: []const u8, second: []const u8) !void {
    std.debug.assert(first.len == second.len);
    for (first, second, 0..) |a, b, i| {
        if (a == b or (a == first_fill and b == second_fill)) continue;
        std.debug.print("{s}: the second run wrote byte {d} as {d}, the first as {d}\n", .{
            what,
            i,
            b,
            a,
        });
        return error.Nondeterministic;
    }
}

/// A fuzzed mesh: `finite` tells whether every position is finite.
pub const FuzzMesh = struct {
    mesh: meshes.Mesh,
    finite: bool,

    pub fn deinit(self: *FuzzMesh) void {
        self.mesh.deinit(gpa);
        self.* = undefined;
    }
};

const Shape = enum { grid, sphere, soup };

const Layout = enum {
    /// As the shape made them.
    kept,
    /// A small integer lattice, so positions and distances tie.
    lattice,
    /// Random floats at a random scale.
    floats,
    /// Every vertex at one point.
    single,
    /// A few far outliers among nearby points.
    outliers,
    /// Some NaN and infinite coordinates.
    special,
};

/// A mesh from `rng`: a grid or sphere whose triangles may come shuffled,
/// rotated or thinned out, or a random soup; sometimes many vertices no
/// triangle uses; positions in one of `Layout`. Most have up to a few
/// thousand triangles, one in twenty up to about twenty thousand.
pub fn mesh(rng: std.Random) !FuzzMesh {
    const big = rng.uintLessThan(u32, 20) == 0;
    var m: meshes.Mesh = switch (rng.enumValue(Shape)) {
        .grid => try meshes.grid(gpa, 1 + rng.uintLessThan(u32, if (big) 100 else 32)),
        .sphere => try meshes.sphere(
            gpa,
            2 + rng.uintLessThan(u32, if (big) 80 else 24),
            3 + rng.uintLessThan(u32, if (big) 120 else 32),
        ),
        .soup => try meshes.random(
            gpa,
            rng.int(u64),
            3 + rng.uintLessThan(u32, if (big) 20000 else 3000),
            1 + rng.uintLessThan(u32, if (big) 20000 else 2000),
        ),
    };
    errdefer m.deinit(gpa);

    const triangle_count = m.indices.len / 3;
    if (rng.boolean()) {
        // Shuffled triangle order.
        var i = triangle_count;
        while (i > 1) : (i -= 1) {
            const j = rng.uintLessThan(usize, i);
            const a = m.indices[(i - 1) * 3 ..][0..3];
            const b = m.indices[j * 3 ..][0..3];
            std.mem.swap([3]u32, a, b);
        }
    }
    if (rng.uintLessThan(u32, 3) == 0) {
        // Rotated corners, keeping each triangle's winding.
        for (0..triangle_count) |t| {
            const triangle = m.indices[t * 3 ..][0..3];
            const r = rng.uintLessThan(usize, 3);
            std.mem.rotate(u32, triangle, r);
        }
    }
    if (rng.uintLessThan(u32, 4) == 0) {
        // Holes: keep about four triangles in five, at least one.
        var kept: usize = 0;
        for (0..triangle_count) |t| {
            if (kept > 0 and rng.uintLessThan(u32, 5) == 0) continue;
            const triangle = m.indices[t * 3 ..][0..3].*;
            m.indices[kept * 3 ..][0..3].* = triangle;
            kept += 1;
        }
        m.indices = try gpa.realloc(m.indices, kept * 3);
    }
    if (rng.uintLessThan(u32, 4) == 0) {
        // More vertices than indices, which no triangle uses.
        const extra = m.indices.len + rng.uintLessThan(usize, 3 * m.indices.len + 1);
        const old = m.vertices.len;
        m.vertices = try gpa.realloc(m.vertices, old + extra);
        for (m.vertices[old..], 0..) |*v, i| v.* = m.vertices[i % old];
    }

    const layout = rng.enumValue(Layout);
    const scale = std.math.pow(f32, 10, @floatFromInt(rng.intRangeAtMost(i32, -3, 4)));
    const range = rng.intRangeAtMost(i32, 0, 8);
    for (m.vertices) |*v| {
        const p: [3]*f32 = .{ &v.px, &v.py, &v.pz };
        switch (layout) {
            .kept => {},
            .lattice => for (p) |x| {
                x.* = @floatFromInt(rng.intRangeAtMost(i32, -range, range));
            },
            .floats => for (p) |x| {
                x.* = (rng.float(f32) * 2 - 1) * scale;
            },
            .single => for (p) |x| {
                x.* = scale;
            },
            .outliers => if (rng.uintLessThan(u32, 64) == 0) {
                for (p) |x| x.* = (rng.float(f32) * 2 - 1) * 1e30;
            },
            .special => if (rng.uintLessThan(u32, 16) == 0) {
                const odd = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
                p[rng.uintLessThan(usize, 3)].* = odd[rng.uintLessThan(usize, odd.len)];
            },
        }
    }
    return .{ .mesh = m, .finite = layout != .special };
}

/// A float in [0, 1]: zero, one or random.
pub fn weight(rng: std.Random) f32 {
    return switch (rng.uintLessThan(u32, 6)) {
        0, 1 => 0,
        2 => 1,
        else => rng.float(f32),
    };
}

/// A size in [low, high], often one of the ends.
pub fn size(rng: std.Random, low: usize, high: usize) usize {
    return switch (rng.uintLessThan(u32, 8)) {
        0 => low,
        1 => high,
        else => rng.intRangeAtMost(usize, low, high),
    };
}
