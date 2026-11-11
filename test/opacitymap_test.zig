//! Opacity micromaps against the original: every subdivision level and
//! format, on procedural alpha and RGBA textures of many sizes, triangles
//! inside, across and far outside the texture, degenerate and non-finite
//! ones; measuring on the demo mesh and generated meshes; compaction of
//! whole pipelines and of made-up entries; fuzzed inputs of each; and the
//! logarithm the levels come from, on every ratio measuring takes.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;
const Mesh = common.Mesh;

const formats = [_]mo.OpacityMapFormat{ .two_state, .four_state };

const Pattern = enum { radial, checker, fine_checker, noise, gradient, clear, solid, half };

/// A procedural alpha channel in a texture of `stride` bytes per pixel and
/// `pad` spare bytes per row, the alpha in the pixel's last byte.
const Image = struct {
    bytes: []u8,
    texture: mo.AlphaTexture,

    fn init(
        pattern: Pattern,
        width: u32,
        height: u32,
        stride: usize,
        pad: usize,
        seed: u64,
    ) !Image {
        const pitch = stride * width + pad;
        const bytes = try gpa.alloc(u8, pitch * height);
        var prng: std.Random.DefaultPrng = .init(seed);
        const rng = prng.random();
        // The other channels hold noise, which must not matter.
        rng.bytes(bytes);
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        for (0..height) |y| for (0..width) |x| {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) / w;
            const fy = (@as(f32, @floatFromInt(y)) + 0.5) / h;
            const alpha: u8 = switch (pattern) {
                .radial => radial: {
                    const dx = fx - 0.5;
                    const dy = fy - 0.5;
                    const dc = (0.3 - @sqrt(dx * dx + dy * dy)) * w;
                    break :radial @intCast(mo.quantizeUnorm(dc + 0.5, 8));
                },
                .checker => checker: {
                    const cell = @as(u32, @intFromFloat(fx * 4)) + @as(u32, @intFromFloat(fy * 4));
                    break :checker if (cell % 2 == 0) 255 else 0;
                },
                .fine_checker => if ((x + y) % 2 == 0) 255 else 0,
                .noise => rng.int(u8),
                .gradient => @intFromFloat(fx * 255),
                .clear => 0,
                .solid => 255,
                .half => if (x % 2 == 0) 127 else 128,
            };
            bytes[y * pitch + x * stride + stride - 1] = alpha;
        };
        return .{
            .bytes = bytes,
            .texture = .{
                .data = bytes[stride - 1 ..],
                .stride = stride,
                .pitch = pitch,
                .width = width,
                .height = height,
            },
        };
    }

    fn deinit(self: *Image) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

fn checkRasterize(
    level: u8,
    format: mo.OpacityMapFormat,
    uv0: [2]f32,
    uv1: [2]f32,
    uv2: [2]f32,
    texture: mo.AlphaTexture,
) !void {
    const message = "rasterize: level {d}, {t}, uvs {any} {any} {any}, texture {d}x{d}\n";
    errdefer std.debug.print(message, .{
        level,
        format,
        uv0,
        uv1,
        uv2,
        texture.width,
        texture.height,
    });

    const size = mo.opacityMapEntrySize(level, format);
    try common.expectSameValue(
        usize,
        "opacityMapEntrySize",
        c.meshopt_opacityMapEntrySize(level, @backingInt(format)),
        size,
    );

    // A byte past the entry shows nothing writes beyond it.
    const want = try gpa.alloc(u8, size + 1);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, size + 1);
    defer gpa.free(got);
    @memset(want, 0xcd);
    @memset(got, 0xcd);

    c.meshopt_opacityMapRasterize(
        want.ptr,
        level,
        @backingInt(format),
        &uv0,
        &uv1,
        &uv2,
        texture.data.ptr,
        texture.stride,
        texture.pitch,
        texture.width,
        texture.height,
    );
    mo.opacityMapRasterize(got[0..size], level, format, uv0, uv1, uv2, texture);
    try common.expectSame(u8, "opacityMapRasterize", want, got);

    // The port again, over a different fill.
    @memset(got[0..size], 0x55);
    mo.opacityMapRasterize(got[0..size], level, format, uv0, uv1, uv2, texture);
    try common.expectSame(u8, "opacityMapRasterize, second run", want, got);
}

/// Triangles inside the texture, across its edges, wrapped far outside it,
/// flipped, thin, degenerate and non-finite.
const triangles = [_][3][2]f32{
    .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } },
    .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 } },
    .{ .{ 0.1, 0.2 }, .{ 0.9, 0.3 }, .{ 0.4, 0.8 } },
    .{ .{ 0.45, 0.45 }, .{ 0.55, 0.47 }, .{ 0.5, 0.56 } },
    .{ .{ -0.3, -0.2 }, .{ 1.7, 0.1 }, .{ 0.4, 1.9 } },
    .{ .{ 3.25, -7.5 }, .{ 4.5, -7.25 }, .{ 3.5, -6.0 } },
    .{ .{ 1e6, 1e6 }, .{ 1e6 + 1, 1e6 }, .{ 1e6, 1e6 + 1 } },
    .{ .{ 0, 0 }, .{ 1, 1 }, .{ 0.5, 0.5 } },
    .{ .{ 0.3, 0.3 }, .{ 0.3, 0.3 }, .{ 0.3, 0.3 } },
    .{ .{ 0, 0 }, .{ 1, 0.001 }, .{ 0.5, 0.0005 } },
    .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1e5 } },
    .{ .{ 0, 0 }, .{ std.math.nan(f32), 0 }, .{ 0, 1 } },
    .{ .{ 0, 0 }, .{ std.math.inf(f32), 0 }, .{ 0, 1 } },
    .{ .{ -std.math.inf(f32), 0.5 }, .{ 0.5, 0.5 }, .{ 0.5, 1 } },
    .{ .{ 1e30, 0 }, .{ 0, 1e30 }, .{ -1e30, -1e30 } },
};

test "opacityMapRasterize matches the original at every level and format" {
    const sizes = [_][2]u32{
        .{ 1, 1 },
        .{ 7, 1 },
        .{ 1, 9 },
        .{ 32, 32 },
        .{ 13, 9 },
        .{ 256, 128 },
    };
    const strides = [_][2]usize{ .{ 1, 0 }, .{ 4, 0 }, .{ 2, 3 }, .{ 3, 1 } };
    for (std.enums.values(Pattern)) |pattern| {
        for (sizes, 0..) |size, s| {
            const layout = strides[s % strides.len];
            var image: Image = try .init(pattern, size[0], size[1], layout[0], layout[1], s);
            defer image.deinit();
            for (0..9) |level| {
                for (formats) |format| {
                    for (triangles) |tri| {
                        try checkRasterize(
                            @intCast(level),
                            format,
                            tri[0],
                            tri[1],
                            tri[2],
                            image.texture,
                        );
                    }
                }
            }
        }
    }
}

test "opacityMapRasterize matches the original at the deepest levels and largest textures" {
    var image: Image = try .init(.radial, 1024, 1024, 1, 0, 1);
    defer image.deinit();
    for (9..13) |level| {
        for (formats) |format| {
            try checkRasterize(
                @intCast(level),
                format,
                .{ 0, 0 },
                .{ 1, 0 },
                .{ 0, 1 },
                image.texture,
            );
        }
    }
    try checkRasterize(
        12,
        .four_state,
        .{ 0.2, 0.1 },
        .{ 0.9, 0.4 },
        .{ 0.3, 0.95 },
        image.texture,
    );

    // The widest and tallest textures the original takes.
    var wide: Image = try .init(.gradient, 16384, 2, 4, 0, 2);
    defer wide.deinit();
    var tall: Image = try .init(.noise, 1, 16384, 1, 0, 3);
    defer tall.deinit();
    for (0..7) |level| {
        for (formats) |format| {
            for (triangles[0..6]) |tri| {
                try checkRasterize(@intCast(level), format, tri[0], tri[1], tri[2], wide.texture);
                try checkRasterize(@intCast(level), format, tri[0], tri[1], tri[2], tall.texture);
            }
        }
    }
}

test "opacityMapEntrySize matches the original" {
    for (0..13) |level| {
        for (formats) |format| {
            const want = c.meshopt_opacityMapEntrySize(@intCast(level), @backingInt(format));
            const got = mo.opacityMapEntrySize(@intCast(level), format);
            try common.expectSameValue(usize, "opacityMapEntrySize", want, got);
        }
    }
}

/// Texture coordinates of `vertices`, 2 floats each, `stride` floats apart.
fn uvsOf(vertices: []const Vertex) mo.VertexFloats {
    const floats = common.floatsOf(vertices);
    if (vertices.len == 0) return .init(&.{}, common.vertex_floats);
    return .init(floats[6..], common.vertex_floats);
}

const Measured = struct {
    count: usize,
    levels: []u8,
    sources: []u32,
    omm_indices: []i32,

    fn deinit(self: *Measured) void {
        gpa.free(self.levels);
        gpa.free(self.sources);
        gpa.free(self.omm_indices);
        self.* = undefined;
    }
};

fn checkMeasure(
    indices: []const u32,
    uvs: mo.VertexFloats,
    width: u32,
    height: u32,
    max_level: u8,
    target_edge: f32,
) !Measured {
    errdefer std.debug.print("measure: texture {d}x{d}, max level {d}, target edge {e}\n", .{
        width,
        height,
        max_level,
        target_edge,
    });

    const triangle_count = indices.len / 3;
    var want: Measured = .{
        .count = 0,
        .levels = try gpa.alloc(u8, triangle_count),
        .sources = try gpa.alloc(u32, triangle_count),
        .omm_indices = try gpa.alloc(i32, triangle_count),
    };
    defer want.deinit();
    var got: Measured = .{
        .count = 0,
        .levels = try gpa.alloc(u8, triangle_count),
        .sources = try gpa.alloc(u32, triangle_count),
        .omm_indices = try gpa.alloc(i32, triangle_count),
    };
    errdefer got.deinit();
    for ([_]*Measured{ &want, &got }) |m| {
        @memset(m.levels, 0xcd);
        @memset(m.sources, 0xcdcdcdcd);
        @memset(m.omm_indices, -7);
    }

    want.count = c.meshopt_opacityMapMeasure(
        want.levels.ptr,
        want.sources.ptr,
        @ptrCast(want.omm_indices.ptr),
        indices.ptr,
        indices.len,
        uvs.data.ptr,
        uvs.count(),
        uvs.stride * @sizeOf(f32),
        width,
        height,
        max_level,
        target_edge,
    );
    got.count = try mo.opacityMapMeasure(
        gpa,
        got.levels,
        got.sources,
        got.omm_indices,
        indices,
        uvs,
        width,
        height,
        max_level,
        target_edge,
    );
    try common.expectSameValue(usize, "opacityMapMeasure count", want.count, got.count);
    try common.expectSame(u8, "opacityMapMeasure levels", want.levels, got.levels);
    try common.expectSame(u32, "opacityMapMeasure sources", want.sources, got.sources);
    try common.expectSame(i32, "opacityMapMeasure indices", want.omm_indices, got.omm_indices);

    // The port again, over a different fill.
    const again_levels = try gpa.dupe(u8, got.levels);
    defer gpa.free(again_levels);
    const again_sources = try gpa.dupe(u32, got.sources);
    defer gpa.free(again_sources);
    const again_indices = try gpa.dupe(i32, got.omm_indices);
    defer gpa.free(again_indices);
    @memset(again_levels[0..got.count], 0x55);
    @memset(again_sources[0..got.count], 0x55555555);
    @memset(again_indices, 0x55555555);
    const again = try mo.opacityMapMeasure(
        gpa,
        again_levels,
        again_sources,
        again_indices,
        indices,
        uvs,
        width,
        height,
        max_level,
        target_edge,
    );
    try common.expectSameValue(usize, "opacityMapMeasure count, second run", got.count, again);
    try common.expectSame(u8, "opacityMapMeasure levels, second run", got.levels, again_levels);
    try common.expectSame(u32, "opacityMapMeasure sources, second run", got.sources, again_sources);
    try common.expectSame(
        i32,
        "opacityMapMeasure indices, second run",
        got.omm_indices,
        again_indices,
    );
    return got;
}

/// Measures, rasterizes and compacts `indices` over `uvs` with `texture`,
/// both ways, comparing every step.
fn checkPipeline(
    indices: []const u32,
    uvs: mo.VertexFloats,
    texture: mo.AlphaTexture,
    max_level: u8,
    target_edge: f32,
    format: mo.OpacityMapFormat,
) !void {
    var measured = try checkMeasure(
        indices,
        uvs,
        texture.width,
        texture.height,
        max_level,
        target_edge,
    );
    defer measured.deinit();

    const count = measured.count;
    const offsets = try gpa.alloc(u32, count);
    defer gpa.free(offsets);
    var data_size: usize = 0;
    for (measured.levels[0..count], offsets) |level, *offset| {
        offset.* = @intCast(data_size);
        data_size += mo.opacityMapEntrySize(level, format);
    }

    const data = try gpa.alloc(u8, data_size);
    defer gpa.free(data);
    for (measured.levels[0..count], measured.sources[0..count], offsets) |level, source, offset| {
        const uv0 = uvs.at(indices[source * 3 + 0])[0..2].*;
        const uv1 = uvs.at(indices[source * 3 + 1])[0..2].*;
        const uv2 = uvs.at(indices[source * 3 + 2])[0..2].*;
        try checkRasterize(level, format, uv0, uv1, uv2, texture);
        const entry = data[offset..][0..mo.opacityMapEntrySize(level, format)];
        mo.opacityMapRasterize(entry, level, format, uv0, uv1, uv2, texture);
    }

    try checkCompact(data, measured.levels[0..count], offsets, measured.omm_indices, format);
}

fn checkCompact(
    data: []const u8,
    levels: []const u8,
    offsets: []const u32,
    omm_indices: []const i32,
    format: mo.OpacityMapFormat,
) !void {
    errdefer std.debug.print("compact: {d} entries, {d} triangles, {t}\n", .{
        levels.len,
        omm_indices.len,
        format,
    });

    const want_data = try gpa.dupe(u8, data);
    defer gpa.free(want_data);
    const want_levels = try gpa.dupe(u8, levels);
    defer gpa.free(want_levels);
    const want_offsets = try gpa.dupe(u32, offsets);
    defer gpa.free(want_offsets);
    const want_indices = try gpa.dupe(i32, omm_indices);
    defer gpa.free(want_indices);
    const got_data = try gpa.dupe(u8, data);
    defer gpa.free(got_data);
    const got_levels = try gpa.dupe(u8, levels);
    defer gpa.free(got_levels);
    const got_offsets = try gpa.dupe(u32, offsets);
    defer gpa.free(got_offsets);
    const got_indices = try gpa.dupe(i32, omm_indices);
    defer gpa.free(got_indices);

    const want = c.meshopt_opacityMapCompact(
        want_data.ptr,
        want_data.len,
        want_levels.ptr,
        want_offsets.ptr,
        want_levels.len,
        @ptrCast(want_indices.ptr),
        want_indices.len,
        @backingInt(format),
    );
    const got = try mo.opacityMapCompact(
        gpa,
        got_data,
        got_levels,
        got_offsets,
        got_indices,
        format,
    );
    try common.expectSameValue(usize, "opacityMapCompact count", want, got);
    try common.expectSame(u8, "opacityMapCompact data", want_data, got_data);
    try common.expectSame(u8, "opacityMapCompact levels", want_levels, got_levels);
    try common.expectSame(u32, "opacityMapCompact offsets", want_offsets, got_offsets);
    try common.expectSame(i32, "opacityMapCompact indices", want_indices, got_indices);

    // The port again: the same result.
    @memcpy(got_data, data);
    @memcpy(got_levels, levels);
    @memcpy(got_offsets, offsets);
    @memcpy(got_indices, omm_indices);
    const again = try mo.opacityMapCompact(
        gpa,
        got_data,
        got_levels,
        got_offsets,
        got_indices,
        format,
    );
    try common.expectSameValue(usize, "opacityMapCompact count, second run", want, again);
    try common.expectSame(u8, "opacityMapCompact data, second run", want_data, got_data);
    try common.expectSame(i32, "opacityMapCompact indices, second run", want_indices, got_indices);
}

const texture_sizes = [_][2]u32{
    .{ 1, 1 },
    .{ 32, 32 },
    .{ 1024, 512 },
    .{ 16384, 16384 },
    .{ 16384, 1 },
};
const target_edges = [_]f32{ 0, 1e-20, 0.5, 1, 2.5, 7, 64, std.math.inf(f32) };

fn checkMeasureEverywhere(mesh: Mesh) !void {
    const uvs = uvsOf(mesh.vertices);
    for (texture_sizes) |size| {
        for (0..13) |max_level| {
            for (target_edges) |target_edge| {
                var measured = try checkMeasure(
                    mesh.indices,
                    uvs,
                    size[0],
                    size[1],
                    @intCast(max_level),
                    target_edge,
                );
                measured.deinit();
            }
        }
    }
}

test "opacityMapMeasure matches the original on the demo mesh and every test mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkMeasureEverywhere(mesh);

    // Texture coordinates far outside the texture, huge, and non-finite.
    var sphere = try meshes.sphere(gpa, 8, 16);
    defer sphere.deinit(gpa);
    const specials = [_]f32{ -3.75, 1e9, 3e38, std.math.inf(f32), std.math.nan(f32) };
    for (specials, 0..) |special, k| {
        sphere.vertices[k * 7 + 3].tx = special;
        sphere.vertices[k * 5 + 2].ty = -special;
    }
    try checkMeasureEverywhere(sphere);
    try checkMeasureEverywhere(.{ .vertices = sphere.vertices, .indices = &.{} });
}

test "opacity map pipelines match the original on the demo mesh" {
    var mesh = try common.pirate();
    defer mesh.deinit(gpa);
    var image: Image = try .init(.radial, 64, 64, 4, 0, 5);
    defer image.deinit();
    var noise: Image = try .init(.noise, 32, 16, 1, 3, 6);
    defer noise.deinit();
    for (formats) |format| {
        for ([_]f32{ 0, 2.5, 8 }) |target_edge| {
            try checkPipeline(
                mesh.indices,
                uvsOf(mesh.vertices),
                image.texture,
                4,
                target_edge,
                format,
            );
            try checkPipeline(
                mesh.indices,
                uvsOf(mesh.vertices),
                noise.texture,
                3,
                target_edge,
                format,
            );
        }
    }
}

test "opacity map pipelines match the original on generated meshes" {
    var grid = try meshes.grid(gpa, 10);
    defer grid.deinit(gpa);
    var sphere = try meshes.sphere(gpa, 6, 12);
    defer sphere.deinit(gpa);
    for (std.enums.values(Pattern), 0..) |pattern, p| {
        var image: Image = try .init(pattern, 48, 40, 1 + p % 4, p % 3, p);
        defer image.deinit();
        for (formats) |format| {
            for ([_]u8{ 0, 1, 2, 5 }) |max_level| {
                try checkPipeline(
                    grid.indices,
                    uvsOf(grid.vertices),
                    image.texture,
                    max_level,
                    0,
                    format,
                );
                try checkPipeline(
                    sphere.indices,
                    uvsOf(sphere.vertices),
                    image.texture,
                    max_level,
                    1.5,
                    format,
                );
            }
        }
    }
}

test "opacityMapCompact matches the original on special and repeated entries" {
    for (formats) |format| {
        for (0..13) |level| {
            const size = mo.opacityMapEntrySize(@intCast(level), format);
            // Every one-state pattern, a near miss of each, and repeats.
            const bytes = [_]u8{ 0x00, 0xff, 0x55, 0xaa, 0x0f, 0x01, 0xfe, 0x54 };
            const data = try gpa.alloc(u8, size * bytes.len * 2);
            defer gpa.free(data);
            const levels = try gpa.alloc(u8, bytes.len * 2);
            defer gpa.free(levels);
            const offsets = try gpa.alloc(u32, bytes.len * 2);
            defer gpa.free(offsets);
            for (0..bytes.len * 2) |i| {
                const entry = data[i * size ..][0..size];
                @memset(entry, bytes[i % bytes.len]);
                // A near miss: one byte off at the end.
                if (i >= bytes.len and size > 1) entry[size - 1] ^= 0x40;
                levels[i] = @intCast(level);
                offsets[i] = @intCast(i * size);
            }
            const omm_indices = [_]i32{
                0,  1,  2,  3,  4,  5,  6,  7,  8, 9,
                10, 11, 12, 13, 14, 15, -1, -3, 3, 3,
            };
            try checkCompact(data, levels, offsets, &omm_indices, format);
        }
    }
    try checkCompact(&.{}, &.{}, &.{}, &.{ -1, -2 }, .two_state);
}

fn fuzzRasterize(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const pattern = rng.enumValue(Pattern);
    const width = if (rng.boolean()) rng.intRangeAtMost(u32, 1, 8) else rng.intRangeAtMost(
        u32,
        1,
        300,
    );
    const height = if (rng.boolean()) rng.intRangeAtMost(u32, 1, 8) else rng.intRangeAtMost(
        u32,
        1,
        300,
    );
    var image: Image = try .init(
        pattern,
        width,
        height,
        rng.intRangeAtMost(usize, 1, 4),
        rng.uintLessThan(usize, 4),
        seed,
    );
    defer image.deinit();
    const spread = std.math.pow(f32, 10, rng.float(f32) * 4 - 2);
    var uvs: [3][2]f32 = undefined;
    for (&uvs) |*uv| {
        for (uv) |*x| x.* = (rng.float(f32) - 0.3) * spread;
    }
    const level = rng.uintAtMost(u8, 7);
    try checkRasterize(
        level,
        rng.enumValue(mo.OpacityMapFormat),
        uvs[0],
        uvs[1],
        uvs[2],
        image.texture,
    );
}

fn fuzzPipeline(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const vertex_count = rng.intRangeAtMost(u32, 3, 30);
    const triangle_count = rng.intRangeAtMost(u32, 1, 40);
    const vertices = try gpa.alloc(Vertex, vertex_count);
    defer gpa.free(vertices);
    // Coordinates on a lattice repeat, so requests merge.
    const lattice = rng.boolean();
    for (vertices) |*v| {
        v.* = std.mem.zeroes(Vertex);
        for ([_]*f32{ &v.tx, &v.ty }) |t| {
            const step: f32 = @floatFromInt(rng.uintLessThan(u32, 5));
            t.* = if (lattice) step / 4 else rng.float(f32) * 2 - 0.5;
        }
    }
    const indices = try gpa.alloc(u32, triangle_count * 3);
    defer gpa.free(indices);
    for (indices) |*index| index.* = rng.uintLessThan(u32, vertex_count);
    const pattern = rng.enumValue(Pattern);
    var image: Image = try .init(
        pattern,
        rng.intRangeAtMost(u32, 1, 64),
        rng.intRangeAtMost(u32, 1, 64),
        1,
        0,
        seed,
    );
    defer image.deinit();
    const target_edge = if (rng.boolean()) 0 else rng.float(f32) * 8;
    try checkPipeline(
        indices,
        uvsOf(vertices),
        image.texture,
        rng.uintAtMost(u8, 5),
        target_edge,
        rng.enumValue(mo.OpacityMapFormat),
    );
}

fn fuzzCompact(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const format = rng.enumValue(mo.OpacityMapFormat);
    const omm_count = rng.uintAtMost(usize, 24);
    const levels = try gpa.alloc(u8, omm_count);
    defer gpa.free(levels);
    const offsets = try gpa.alloc(u32, omm_count);
    defer gpa.free(offsets);
    var data_size: usize = 0;
    for (levels, offsets) |*level, *offset| {
        level.* = rng.uintAtMost(u8, 4);
        offset.* = @intCast(data_size);
        data_size += mo.opacityMapEntrySize(level.*, format);
    }
    const data = try gpa.alloc(u8, data_size);
    defer gpa.free(data);
    // Entries of few distinct bytes, so some repeat and some are one state.
    const palette = [_]u8{ 0x00, 0xff, 0x55, 0xaa, rng.int(u8) };
    for (levels, offsets) |level, offset| {
        const entry = data[offset..][0..mo.opacityMapEntrySize(level, format)];
        const fill = palette[rng.uintLessThan(usize, palette.len)];
        @memset(entry, fill);
        if (rng.uintLessThan(u32, 3) == 0) entry[rng.uintLessThan(usize, entry.len)] = rng.int(u8);
    }
    const omm_indices = try gpa.alloc(i32, rng.uintAtMost(usize, 30));
    defer gpa.free(omm_indices);
    for (omm_indices) |*index| {
        index.* = if (omm_count == 0 or rng.uintLessThan(u32, 5) == 0)
            -rng.intRangeAtMost(i32, 1, 4)
        else
            @intCast(rng.uintLessThan(usize, omm_count));
    }
    try checkCompact(data, levels, offsets, omm_indices, format);
}

test "opacityMapRasterize matches the original on fuzzed triangles" {
    try common.fuzz("opacityMapRasterize", 0, fuzzRasterize);
}

test "opacity map pipelines match the original on fuzzed meshes" {
    try common.fuzz("opacity map pipeline", 0, fuzzPipeline);
}

test "opacityMapCompact matches the original on fuzzed entries" {
    try common.fuzz("opacityMapCompact", 0, fuzzCompact);
}

test "the level logarithm matches the system libm on every ratio from 1" {
    var bits: u32 = 0x3f800000;
    // Up to infinity.
    while (bits <= 0x7f800000) : (bits += 1) {
        const x: f32 = @bitCast(bits);
        const want: u32 = @bitCast(c.reference_log2f(x));
        const got: u32 = @bitCast(mo.opacitymap.log2fForTest(x));
        if (want != got) {
            std.debug.print(
                "log2f(0x{x:0>8}): libm 0x{x:0>8}, port 0x{x:0>8}\n",
                .{ bits, want, got },
            );
            return error.Mismatch;
        }
    }
}
