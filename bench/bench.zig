//! The port's speed against the original's, both in ReleaseFast (the
//! original at -O3), on one thread: the best of several runs of each
//! function on the demo mesh and on a large generated one. Prints a table;
//! `zig build bench -- <filter>` runs only the cases whose name contains the
//! filter.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");

const Vertex = meshes.Vertex;

const runs = 7;

const Bench = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    filter: ?[]const u8,
    original_total_ns: u64 = 0,
    port_total_ns: u64 = 0,

    /// Times `case.original()` and `case.port()`; `case` is a struct of the
    /// inputs and outputs both use.
    fn run(self: *Bench, name: []const u8, case: anytype) void {
        if (self.filter) |filter| if (std.mem.indexOf(u8, name, filter) == null) return;
        const original_ns = self.best(case, "original");
        const port_ns = self.best(case, "port");
        self.original_total_ns += original_ns;
        self.port_total_ns += port_ns;
        const ratio = @as(f64, @floatFromInt(port_ns)) / @as(f64, @floatFromInt(original_ns));
        std.debug.print("{s:<48} {d:>10.3} {d:>10.3} {d:>7.2}\n", .{
            name,
            @as(f64, @floatFromInt(original_ns)) / 1e6,
            @as(f64, @floatFromInt(port_ns)) / 1e6,
            ratio,
        });
    }

    fn best(self: *Bench, case: anytype, comptime which: []const u8) u64 {
        var best_ns: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            const t0 = std.Io.Clock.awake.now(self.io);
            @field(@TypeOf(case.*), which)(case);
            const t1 = std.Io.Clock.awake.now(self.io);
            best_ns = @min(best_ns, @as(u64, @intCast(t0.durationTo(t1).nanoseconds)));
        }
        return best_ns;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var bench: Bench = .{
        .io = init.io,
        .gpa = std.heap.c_allocator,
        .filter = if (args.len > 1) args[1] else null,
    };

    const soup = try meshes.pirateSoup(arena);
    const big = try meshes.sphere(arena, 512, 1024);
    const big_soup = try arena.alloc(Vertex, big.indices.len);
    for (big.indices, big_soup) |index, *v| v.* = big.vertices[index];

    std.debug.print("{s:<48} {s:>10} {s:>10} {s:>7}\n", .{ "case", "orig ms", "port ms", "ratio" });

    inline for (.{ .{ "pirate", soup }, .{ "sphere 1M", big_soup } }) |named| {
        const name = named[0];
        const vertices = named[1];
        var remap_case: RemapCase = try .init(arena, bench.gpa, vertices);
        bench.run("generateVertexRemap " ++ name, &remap_case);
        var shadow_case: ShadowCase = try .init(arena, bench.gpa, vertices, remap_case.remap);
        bench.run("generateShadowIndexBuffer " ++ name, &shadow_case);
        var provoking_case: ProvokingCase = try .init(
            arena,
            bench.gpa,
            vertices.len,
            remap_case.remap,
        );
        bench.run("generateProvokingIndexBuffer " ++ name, &provoking_case);
    }

    const pirate = try indexedSoup(arena, soup);
    try benchRemesher(&bench, arena, &pirate, &big);
    try benchTangentSpace(&bench, arena, &pirate, &big);
    try benchOpacityMap(&bench, arena, &pirate, &big);

    const total_ratio = @as(f64, @floatFromInt(bench.port_total_ns)) /
        @as(f64, @floatFromInt(bench.original_total_ns));
    std.debug.print("{s:<48} {d:>10.3} {d:>10.3} {d:>7.2}\n", .{
        "total",
        @as(f64, @floatFromInt(bench.original_total_ns)) / 1e6,
        @as(f64, @floatFromInt(bench.port_total_ns)) / 1e6,
        total_ratio,
    });
}

const RemapCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    remap: []u32,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, vertices: []const Vertex) !RemapCase {
        return .{ .gpa = gpa, .vertices = vertices, .remap = try arena.alloc(u32, vertices.len) };
    }

    fn original(self: *RemapCase) void {
        const v = self.vertices;
        _ = c.meshopt_generateVertexRemap(
            self.remap.ptr,
            null,
            v.len,
            v.ptr,
            v.len,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *RemapCase) void {
        const bytes = std.mem.sliceAsBytes(self.vertices);
        _ = mo.generateVertexRemap(
            self.gpa,
            self.remap,
            null,
            bytes,
            @sizeOf(Vertex),
        ) catch unreachable;
    }
};

const ShadowCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    indices: []const u32,
    destination: []u32,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        vertices: []const Vertex,
        indices: []const u32,
    ) !ShadowCase {
        return .{
            .gpa = gpa,
            .vertices = vertices,
            .indices = indices,
            .destination = try arena.alloc(u32, indices.len),
        };
    }

    fn original(self: *ShadowCase) void {
        const v = self.vertices;
        const i = self.indices;
        c.meshopt_generateShadowIndexBuffer(
            self.destination.ptr,
            i.ptr,
            i.len,
            v.ptr,
            v.len,
            12,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *ShadowCase) void {
        const stream: mo.Stream = .{
            .data = std.mem.sliceAsBytes(self.vertices),
            .size = 12,
            .stride = @sizeOf(Vertex),
        };
        mo.generateShadowIndexBuffer(
            self.gpa,
            self.destination,
            self.indices,
            self.vertices.len,
            stream,
        ) catch
            unreachable;
    }
};

const ProvokingCase = struct {
    gpa: std.mem.Allocator,
    vertex_count: usize,
    indices: []const u32,
    destination: []u32,
    reorder: []u32,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        vertex_count: usize,
        indices: []const u32,
    ) !ProvokingCase {
        return .{
            .gpa = gpa,
            .vertex_count = vertex_count,
            .indices = indices,
            .destination = try arena.alloc(u32, indices.len),
            .reorder = try arena.alloc(u32, vertex_count + indices.len / 3),
        };
    }

    fn original(self: *ProvokingCase) void {
        const i = self.indices;
        _ = c.meshopt_generateProvokingIndexBuffer(
            self.destination.ptr,
            self.reorder.ptr,
            i.ptr,
            i.len,
            self.vertex_count,
        );
    }

    fn port(self: *ProvokingCase) void {
        _ = mo.generateProvokingIndexBuffer(
            self.gpa,
            self.destination,
            self.reorder,
            self.indices,
            self.vertex_count,
        ) catch
            unreachable;
    }
};

// --------------------------------------------------------
// Remesher
// --------------------------------------------------------

/// The demo mesh indexed by the original's `generateVertexRemap`, as its
/// demo indexes it.
fn indexedSoup(arena: std.mem.Allocator, soup: []const Vertex) !meshes.Mesh {
    const remap = try arena.alloc(u32, soup.len);
    const unique = c.meshopt_generateVertexRemap(
        remap.ptr,
        null,
        soup.len,
        soup.ptr,
        soup.len,
        @sizeOf(Vertex),
    );
    return meshes.indexed(arena, soup, remap, unique);
}

fn selected(bench: *const Bench, name: []const u8) bool {
    const filter = bench.filter orelse return true;
    return std.mem.indexOf(u8, name, filter) != null;
}

fn floatsOf(mesh: *const meshes.Mesh) []const f32 {
    return std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(mesh.vertices));
}

const vertex_floats = @sizeOf(Vertex) / @sizeOf(f32);

fn benchRemesher(
    bench: *Bench,
    arena: std.mem.Allocator,
    pirate: *const meshes.Mesh,
    big: *const meshes.Mesh,
) !void {
    inline for (.{ .{ "pirate", pirate }, .{ "sphere 1M", big } }) |named| {
        inline for (.{ 64, 128, 256 }) |resolution| {
            inline for (.{ .{ "", 0 }, .{ " shell", 1 }, .{ " solve", 2 } }) |mode| {
                const case_name = std.fmt.comptimePrint(
                    "remesh {d}{s} {s}",
                    .{ resolution, mode[0], named[0] },
                );
                // Its capacity takes a remesh of its own: only for cases that run.
                if (selected(bench, case_name)) {
                    var remesh_case: RemeshCase = try .init(
                        arena,
                        bench.gpa,
                        named[1],
                        resolution,
                        mode[1],
                    );
                    bench.run(case_name, &remesh_case);
                }
            }
        }
    }
}

const RemeshCase = struct {
    gpa: std.mem.Allocator,
    mesh: *const meshes.Mesh,
    resolution: u32,
    options: u32,
    destination: []f32,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: *const meshes.Mesh,
        resolution: u32,
        options: u32,
    ) !RemeshCase {
        var case: RemeshCase = .{
            .gpa = gpa,
            .mesh = mesh,
            .resolution = resolution,
            .options = options,
            .destination = &.{},
        };
        const capacity = case.call(null, 0);
        case.destination = try arena.alloc(f32, capacity * 9);
        return case;
    }

    fn call(self: *RemeshCase, destination: ?[*]f32, max_triangle_count: usize) usize {
        const m = self.mesh;
        return c.meshopt_remesh(
            destination,
            max_triangle_count,
            m.indices.ptr,
            m.indices.len,
            floatsOf(m).ptr,
            m.vertices.len,
            @sizeOf(Vertex),
            @intCast(self.resolution),
            self.options,
        );
    }

    fn original(self: *RemeshCase) void {
        std.mem.doNotOptimizeAway(self.call(self.destination.ptr, self.destination.len / 9));
    }

    fn port(self: *RemeshCase) void {
        const count = mo.remesh(
            self.gpa,
            self.destination,
            self.mesh.indices,
            .init(floatsOf(self.mesh), vertex_floats),
            self.resolution,
            @fromBackingInt(self.options),
        ) catch unreachable;
        std.mem.doNotOptimizeAway(count);
    }
};

// --------------------------------------------------------
// Tangent space
// --------------------------------------------------------

fn benchTangentSpace(
    bench: *Bench,
    arena: std.mem.Allocator,
    pirate: *const meshes.Mesh,
    big: *const meshes.Mesh,
) !void {
    inline for (.{ .{ "pirate", pirate }, .{ "sphere 1M", big } }) |named| {
        inline for (.{ .{ "", 0 }, .{ " compatible", 1 }, .{ " zero fallback", 2 } }) |mode| {
            var tangents_case: TangentsCase = try .init(arena, bench.gpa, named[1], mode[1]);
            bench.run("generateTangents" ++ mode[0] ++ " " ++ named[0], &tangents_case);
        }
        inline for (.{ .{ "", 0.0 }, .{ " smooth 1.5", 1.5 } }) |mode| {
            var normals_case: NormalsCase = try .init(arena, bench.gpa, named[1], mode[1]);
            bench.run("generateNormals" ++ mode[0] ++ " " ++ named[0], &normals_case);
        }
    }
}

const TangentsCase = struct {
    gpa: std.mem.Allocator,
    mesh: *const meshes.Mesh,
    options: u32,
    result: []f32,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: *const meshes.Mesh,
        options: u32,
    ) !TangentsCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .options = options,
            .result = try arena.alloc(f32, mesh.indices.len * 4),
        };
    }

    fn original(self: *TangentsCase) void {
        const m = self.mesh;
        c.meshopt_generateTangents(
            self.result.ptr,
            m.indices.ptr,
            m.indices.len,
            floatsOf(m).ptr,
            m.vertices.len,
            @sizeOf(Vertex),
            floatsOf(m)[3..].ptr,
            @sizeOf(Vertex),
            floatsOf(m)[6..].ptr,
            @sizeOf(Vertex),
            self.options,
        );
        std.mem.doNotOptimizeAway(self.result[0]);
    }

    fn port(self: *TangentsCase) void {
        const floats = floatsOf(self.mesh);
        mo.generateTangents(
            self.gpa,
            self.result,
            self.mesh.indices,
            .init(floats, vertex_floats),
            .init(floats[3..], vertex_floats),
            .init(floats[6..], vertex_floats),
            @fromBackingInt(self.options),
        ) catch unreachable;
        std.mem.doNotOptimizeAway(self.result[0]);
    }
};

const NormalsCase = struct {
    gpa: std.mem.Allocator,
    mesh: *const meshes.Mesh,
    smoothing: f32,
    result: []f32,

    /// The crease angle the original's demo uses: 1 radian, about 60 degrees.
    const crease_angle = 1.0;

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: *const meshes.Mesh,
        smoothing: f32,
    ) !NormalsCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .smoothing = smoothing,
            .result = try arena.alloc(f32, mesh.indices.len * 3),
        };
    }

    fn original(self: *NormalsCase) void {
        const m = self.mesh;
        c.meshopt_generateNormals(
            self.result.ptr,
            m.indices.ptr,
            m.indices.len,
            floatsOf(m).ptr,
            m.vertices.len,
            @sizeOf(Vertex),
            crease_angle,
            self.smoothing,
        );
        std.mem.doNotOptimizeAway(self.result[0]);
    }

    fn port(self: *NormalsCase) void {
        mo.generateNormals(
            self.gpa,
            self.result,
            self.mesh.indices,
            .init(floatsOf(self.mesh), vertex_floats),
            crease_angle,
            self.smoothing,
        ) catch unreachable;
        std.mem.doNotOptimizeAway(self.result[0]);
    }
};

// --------------------------------------------------------
// Opacity maps
// --------------------------------------------------------

fn benchOpacityMap(
    bench: *Bench,
    arena: std.mem.Allocator,
    pirate: *const meshes.Mesh,
    big: *const meshes.Mesh,
) !void {
    inline for (.{ .{ "pirate", pirate }, .{ "sphere 1M", big } }) |named| {
        var measure_case: MeasureCase = try .init(arena, bench.gpa, named[1]);
        bench.run("opacityMapMeasure " ++ named[0], &measure_case);
    }

    // Every micromap the demo mesh needs at up to level 8, then large
    // triangles at the deepest levels.
    const texture = try circlesTexture(arena, texture_size);
    var measure_case: MeasureCase = try .init(arena, bench.gpa, pirate);
    measure_case.port();
    inline for (.{ .{ "2-state", 2 }, .{ "4-state", 4 } }) |format| {
        var rasterize_case: RasterizeCase = try .initMesh(
            arena,
            &measure_case,
            texture,
            format[1],
        );
        bench.run("opacityMapRasterize " ++ format[0] ++ " pirate", &rasterize_case);
        inline for (.{ 10, 12 }) |level| {
            var deep_case: RasterizeCase = try .initDeep(arena, texture, level, format[1]);
            const case_name = std.fmt.comptimePrint(
                "opacityMapRasterize {s} level {d}",
                .{ format[0], level },
            );
            bench.run(case_name, &deep_case);
        }
    }
}

const texture_size = 1024;

/// Rings of alpha from clear to opaque around the middle: every opacity
/// state, at every scale the micromap levels see.
fn circlesTexture(arena: std.mem.Allocator, size: u32) ![]u8 {
    const texture = try arena.alloc(u8, size * size);
    const center = @as(f32, @floatFromInt(size)) * 0.5;
    for (0..size) |y| for (0..size) |x| {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - center;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - center;
        const distance = @sqrt(dx * dx + dy * dy);
        texture[y * size + x] = @intFromFloat(127.5 + 127.5 * @sin(distance * 0.05));
    };
    return texture;
}

const MeasureCase = struct {
    gpa: std.mem.Allocator,
    mesh: *const meshes.Mesh,
    levels: []u8,
    sources: []u32,
    omm_indices: []i32,
    count: usize = 0,

    const max_level = 8;
    const target_edge = 2.5;

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: *const meshes.Mesh,
    ) !MeasureCase {
        const triangle_count = mesh.indices.len / 3;
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .levels = try arena.alloc(u8, triangle_count),
            .sources = try arena.alloc(u32, triangle_count),
            .omm_indices = try arena.alloc(i32, triangle_count),
        };
    }

    fn original(self: *MeasureCase) void {
        const m = self.mesh;
        self.count = c.meshopt_opacityMapMeasure(
            self.levels.ptr,
            self.sources.ptr,
            @ptrCast(self.omm_indices.ptr),
            m.indices.ptr,
            m.indices.len,
            floatsOf(m)[6..].ptr,
            m.vertices.len,
            @sizeOf(Vertex),
            texture_size,
            texture_size,
            max_level,
            target_edge,
        );
        std.mem.doNotOptimizeAway(self.count);
    }

    fn port(self: *MeasureCase) void {
        self.count = mo.opacityMapMeasure(
            self.gpa,
            self.levels,
            self.sources,
            self.omm_indices,
            self.mesh.indices,
            .init(floatsOf(self.mesh)[6..], vertex_floats),
            texture_size,
            texture_size,
            max_level,
            target_edge,
        ) catch unreachable;
        std.mem.doNotOptimizeAway(self.count);
    }
};

/// Micromaps rasterized one after another into one buffer: `levels[i]` at
/// `offsets[i]`, over the triangle with texture coordinates `uvs[i]`.
const RasterizeCase = struct {
    texture: []const u8,
    states: u8,
    levels: []const u8,
    offsets: []const usize,
    uvs: []const [3][2]f32,
    data: []u8,

    fn initMesh(
        arena: std.mem.Allocator,
        measured: *const MeasureCase,
        texture: []const u8,
        states: u8,
    ) !RasterizeCase {
        const count = measured.count;
        const levels = measured.levels[0..count];
        const uvs = try arena.alloc([3][2]f32, count);
        const m = measured.mesh;
        for (uvs, measured.sources[0..count]) |*corners, source| {
            for (corners, m.indices[source * 3 ..][0..3]) |*uv, index| {
                uv.* = .{ m.vertices[index].tx, m.vertices[index].ty };
            }
        }
        return initLayout(arena, texture, states, levels, uvs);
    }

    /// Four triangles that together cover the texture, at `level`.
    fn initDeep(
        arena: std.mem.Allocator,
        texture: []const u8,
        level: u8,
        states: u8,
    ) !RasterizeCase {
        const levels = try arena.alloc(u8, 4);
        @memset(levels, level);
        const uvs = try arena.dupe([3][2]f32, &.{
            .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0.5, 0.5 } },
            .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0.5, 0.5 } },
            .{ .{ 1, 1 }, .{ 0, 1 }, .{ 0.5, 0.5 } },
            .{ .{ 0, 1 }, .{ 0, 0 }, .{ 0.5, 0.5 } },
        });
        return initLayout(arena, texture, states, levels, uvs);
    }

    fn initLayout(
        arena: std.mem.Allocator,
        texture: []const u8,
        states: u8,
        levels: []const u8,
        uvs: []const [3][2]f32,
    ) !RasterizeCase {
        const offsets = try arena.alloc(usize, levels.len);
        var size: usize = 0;
        for (levels, offsets) |level, *offset| {
            offset.* = size;
            size += c.meshopt_opacityMapEntrySize(level, states);
        }
        return .{
            .texture = texture,
            .states = states,
            .levels = levels,
            .offsets = offsets,
            .uvs = uvs,
            .data = try arena.alloc(u8, size),
        };
    }

    fn original(self: *RasterizeCase) void {
        for (self.levels, self.offsets, self.uvs) |level, offset, corners| {
            c.meshopt_opacityMapRasterize(
                self.data[offset..].ptr,
                level,
                self.states,
                &corners[0],
                &corners[1],
                &corners[2],
                self.texture.ptr,
                1,
                texture_size,
                texture_size,
                texture_size,
            );
        }
        std.mem.doNotOptimizeAway(self.data[0]);
    }

    fn port(self: *RasterizeCase) void {
        const format: mo.OpacityMapFormat = @fromBackingInt(self.states);
        const texture: mo.AlphaTexture = .{
            .data = self.texture,
            .stride = 1,
            .pitch = texture_size,
            .width = texture_size,
            .height = texture_size,
        };
        for (self.levels, self.offsets, self.uvs) |level, offset, corners| {
            const size = mo.opacityMapEntrySize(level, format);
            mo.opacityMapRasterize(
                self.data[offset..][0..size],
                level,
                format,
                corners[0],
                corners[1],
                corners[2],
                texture,
            );
        }
        std.mem.doNotOptimizeAway(self.data[0]);
    }
};
