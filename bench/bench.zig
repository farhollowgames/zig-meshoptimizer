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
            // Cases that change their inputs restore them, untimed, in a public
            // `prepare`.
            if (@hasDecl(@TypeOf(case.*), "prepare")) case.prepare();
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

    // The simplifier, on indexed meshes: the demo mesh as the original's
    // demo indexes it, and the large sphere.
    const pirate_remap = try arena.alloc(u32, soup.len);
    const pirate_unique = c.meshopt_generateVertexRemap(
        pirate_remap.ptr,
        null,
        soup.len,
        soup.ptr,
        soup.len,
        @sizeOf(Vertex),
    );
    const pirate = try meshes.indexed(arena, soup, pirate_remap, pirate_unique);
    inline for (.{ .{ "pirate", pirate }, .{ "sphere 1M", big } }) |named| {
        const name = named[0];
        inline for (comptime std.enums.values(SimplifyCase.Kind)) |kind| {
            var case: SimplifyCase = try .init(arena, bench.gpa, named[1], kind);
            bench.run(@tagName(kind) ++ " " ++ name, &case);
        }
    }

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

/// One simplifier function on an indexed mesh, to a tenth of its triangles
/// or vertices, with the error bound the original's demo uses.
const SimplifyCase = struct {
    gpa: std.mem.Allocator,
    kind: Kind,
    mesh: meshes.Mesh,
    /// What `simplifyWithUpdate` changes, copied from `mesh` by `prepare`.
    vertices: []Vertex,
    indices: []u32,
    destination: []u32,
    result: usize = 0,

    const Kind = enum {
        simplify,
        simplifyWithAttributes,
        simplifyWithUpdate,
        simplifySloppy,
        simplifyPrune,
        simplifyPoints,
    };

    const target_error = 1e-2;
    /// Normals at half the weight of texture coordinates.
    const weights = [_]f32{ 0.5, 0.5, 0.5, 1, 1 };
    const stride = @sizeOf(Vertex);

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: meshes.Mesh,
        kind: Kind,
    ) !SimplifyCase {
        return .{
            .gpa = gpa,
            .kind = kind,
            .mesh = mesh,
            .vertices = try arena.dupe(Vertex, mesh.vertices),
            .indices = try arena.dupe(u32, mesh.indices),
            .destination = try arena.alloc(u32, @max(mesh.indices.len, mesh.vertices.len)),
        };
    }

    /// `simplifyWithUpdate` moves vertices and rewrites indices in place.
    pub fn prepare(self: *SimplifyCase) void {
        if (self.kind != .simplifyWithUpdate) return;
        @memcpy(self.vertices, self.mesh.vertices);
        @memcpy(self.indices, self.mesh.indices);
    }

    fn targetIndexCount(self: *const SimplifyCase) usize {
        return self.mesh.indices.len / 3 / 10 * 3;
    }

    fn positions(self: *const SimplifyCase) [*]const f32 {
        return @ptrCast(self.mesh.vertices.ptr);
    }

    fn attributes(self: *const SimplifyCase) [*]const f32 {
        return self.positions() + 3;
    }

    fn original(self: *SimplifyCase) void {
        const m = self.mesh;
        const n = m.indices.len;
        const vertex_count = m.vertices.len;
        var result_error: f32 = 0;
        self.result = switch (self.kind) {
            .simplify => c.meshopt_simplify(
                self.destination.ptr,
                m.indices.ptr,
                n,
                self.positions(),
                vertex_count,
                stride,
                self.targetIndexCount(),
                target_error,
                0,
                &result_error,
            ),
            .simplifyWithAttributes => c.meshopt_simplifyWithAttributes(
                self.destination.ptr,
                m.indices.ptr,
                n,
                self.positions(),
                vertex_count,
                stride,
                self.attributes(),
                stride,
                &weights,
                weights.len,
                null,
                self.targetIndexCount(),
                target_error,
                0,
                &result_error,
            ),
            .simplifyWithUpdate => update: {
                const floats: [*]f32 = @ptrCast(self.vertices.ptr);
                break :update c.meshopt_simplifyWithUpdate(
                    self.indices.ptr,
                    n,
                    floats,
                    vertex_count,
                    stride,
                    floats + 3,
                    stride,
                    &weights,
                    weights.len,
                    null,
                    self.targetIndexCount(),
                    target_error,
                    0,
                    &result_error,
                );
            },
            .simplifySloppy => c.meshopt_simplifySloppy(
                self.destination.ptr,
                m.indices.ptr,
                n,
                self.positions(),
                vertex_count,
                stride,
                null,
                self.targetIndexCount(),
                std.math.floatMax(f32),
                &result_error,
            ),
            .simplifyPrune => c.meshopt_simplifyPrune(
                self.destination.ptr,
                m.indices.ptr,
                n,
                self.positions(),
                vertex_count,
                stride,
                target_error,
            ),
            .simplifyPoints => c.meshopt_simplifyPoints(
                self.destination.ptr,
                self.positions(),
                vertex_count,
                stride,
                self.attributes(),
                stride,
                1,
                vertex_count / 10,
            ),
        };
        std.mem.doNotOptimizeAway(self.result);
        std.mem.doNotOptimizeAway(result_error);
    }

    fn port(self: *SimplifyCase) void {
        self.result = self.portCall() catch unreachable;
        std.mem.doNotOptimizeAway(self.result);
    }

    fn portCall(self: *SimplifyCase) !usize {
        const m = self.mesh;
        const floats = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(m.vertices));
        const view: mo.VertexFloats = .init(floats, stride / @sizeOf(f32));
        const attribute_view: mo.VertexFloats = .init(floats[3..], stride / @sizeOf(f32));
        var result_error: f32 = 0;
        defer std.mem.doNotOptimizeAway(result_error);
        return switch (self.kind) {
            .simplify => mo.simplify(
                self.gpa,
                self.destination,
                m.indices,
                view,
                self.targetIndexCount(),
                target_error,
                .{},
                &result_error,
            ),
            .simplifyWithAttributes => mo.simplifyWithAttributes(
                self.gpa,
                self.destination,
                m.indices,
                view,
                attribute_view,
                &weights,
                null,
                self.targetIndexCount(),
                target_error,
                .{},
                &result_error,
            ),
            .simplifyWithUpdate => update: {
                const copy = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(self.vertices));
                break :update mo.simplifyWithUpdate(
                    self.gpa,
                    self.indices,
                    .init(copy, stride / @sizeOf(f32)),
                    .init(copy[3..], stride / @sizeOf(f32)),
                    &weights,
                    null,
                    self.targetIndexCount(),
                    target_error,
                    .{},
                    &result_error,
                );
            },
            .simplifySloppy => mo.simplifySloppy(
                self.gpa,
                self.destination,
                m.indices,
                view,
                null,
                self.targetIndexCount(),
                std.math.floatMax(f32),
                &result_error,
            ),
            .simplifyPrune => mo.simplifyPrune(
                self.gpa,
                self.destination,
                m.indices,
                view,
                target_error,
            ),
            .simplifyPoints => mo.simplifyPoints(
                self.gpa,
                self.destination[0 .. m.vertices.len / 10],
                view,
                attribute_view,
                1,
                m.vertices.len / 10,
            ),
        };
    }
};
