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

    // Indexed meshes, as a bake has them after merging vertices.
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
        const mesh: meshes.Mesh = named[1];
        var vcache_case: VertexCacheCase = try .init(arena, bench.gpa, mesh, .default);
        bench.run("optimizeVertexCache " ++ name, &vcache_case);
        var fifo_case: VertexCacheCase = try .init(arena, bench.gpa, mesh, .fifo);
        bench.run("optimizeVertexCacheFifo " ++ name, &fifo_case);

        // The meshlet cases take the cache-ordered indices, as a bake does;
        // the filter may have skipped the case that orders them.
        vcache_case.original();
        const ordered: meshes.Mesh = .{
            .vertices = mesh.vertices,
            .indices = vcache_case.destination,
        };
        var meshlets_case: MeshletsCase = try .init(arena, bench.gpa, ordered, .standard);
        bench.run("buildMeshlets " ++ name, &meshlets_case);
        var spatial_case: MeshletsCase = try .init(arena, bench.gpa, ordered, .spatial);
        bench.run("buildMeshletsSpatial " ++ name, &spatial_case);

        meshlets_case.original();
        var optimize_case: OptimizeMeshletCase = try .init(arena, &meshlets_case);
        bench.run("optimizeMeshlet " ++ name, &optimize_case);
        var bounds_case: MeshletBoundsCase = .{ .built = &meshlets_case, .mesh = ordered };
        bench.run("computeMeshletBounds " ++ name, &bounds_case);
        var partition_case: PartitionCase = try .init(arena, bench.gpa, &meshlets_case);
        bench.run("partitionClusters " ++ name, &partition_case);
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

/// Every vertex's floats, positions first.
fn positionsOf(vertices: []const Vertex) mo.VertexFloats {
    const stride = @sizeOf(Vertex) / @sizeOf(f32);
    const floats: [*]const f32 = @ptrCast(vertices.ptr);
    return .init(floats[0 .. vertices.len * stride], stride);
}

const VertexCacheCase = struct {
    gpa: std.mem.Allocator,
    mesh: meshes.Mesh,
    destination: []u32,
    kind: Kind,

    const Kind = enum { default, fifo };

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: meshes.Mesh,
        kind: Kind,
    ) !VertexCacheCase {
        const destination = try arena.alloc(u32, mesh.indices.len);
        return .{ .gpa = gpa, .mesh = mesh, .destination = destination, .kind = kind };
    }

    fn original(self: *VertexCacheCase) void {
        const i = self.mesh.indices;
        const n = self.mesh.vertices.len;
        switch (self.kind) {
            .default => c.meshopt_optimizeVertexCache(self.destination.ptr, i.ptr, i.len, n),
            .fifo => c.meshopt_optimizeVertexCacheFifo(self.destination.ptr, i.ptr, i.len, n, 16),
        }
    }

    fn port(self: *VertexCacheCase) void {
        const i = self.mesh.indices;
        const n = self.mesh.vertices.len;
        const done = switch (self.kind) {
            .default => mo.optimizeVertexCache(self.gpa, self.destination, i, n),
            .fifo => mo.optimizeVertexCacheFifo(self.gpa, self.destination, i, n, 16),
        };
        done catch unreachable;
    }
};

const MeshletsCase = struct {
    gpa: std.mem.Allocator,
    mesh: meshes.Mesh,
    kind: Kind,
    meshlets: []mo.Meshlet,
    vertices: []u32,
    triangles: []u8,
    count: usize = 0,

    const Kind = enum { standard, spatial };
    const max_vertices = 64;
    const max_triangles = 124;
    const min_triangles = 64;

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: meshes.Mesh,
        kind: Kind,
    ) !MeshletsCase {
        const n = mesh.indices.len;
        const bound = mo.buildMeshletsBound(n, max_vertices, min_triangles);
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .kind = kind,
            .meshlets = try arena.alloc(mo.Meshlet, bound),
            .vertices = try arena.alloc(u32, n),
            .triangles = try arena.alloc(u8, n),
        };
    }

    fn original(self: *MeshletsCase) void {
        const i = self.mesh.indices;
        const v = self.mesh.vertices;
        const meshlets: [*]c.Meshlet = @ptrCast(self.meshlets.ptr);
        self.count = switch (self.kind) {
            .standard => c.meshopt_buildMeshlets(
                meshlets,
                self.vertices.ptr,
                self.triangles.ptr,
                i.ptr,
                i.len,
                @ptrCast(v.ptr),
                v.len,
                @sizeOf(Vertex),
                max_vertices,
                max_triangles,
                0,
            ),
            .spatial => c.meshopt_buildMeshletsSpatial(
                meshlets,
                self.vertices.ptr,
                self.triangles.ptr,
                i.ptr,
                i.len,
                @ptrCast(v.ptr),
                v.len,
                @sizeOf(Vertex),
                max_vertices,
                min_triangles,
                max_triangles,
                0.5,
            ),
        };
    }

    fn port(self: *MeshletsCase) void {
        const positions = positionsOf(self.mesh.vertices);
        self.count = switch (self.kind) {
            .standard => mo.buildMeshlets(
                self.gpa,
                self.meshlets,
                self.vertices,
                self.triangles,
                self.mesh.indices,
                positions,
                max_vertices,
                max_triangles,
                0,
            ),
            .spatial => mo.buildMeshletsSpatial(
                self.gpa,
                self.meshlets,
                self.vertices,
                self.triangles,
                self.mesh.indices,
                positions,
                max_vertices,
                min_triangles,
                max_triangles,
                0.5,
            ),
        } catch unreachable;
    }
};

/// Each run optimizes fresh copies of the built meshlets.
const OptimizeMeshletCase = struct {
    built: *const MeshletsCase,
    vertices: []u32,
    triangles: []u8,

    fn init(arena: std.mem.Allocator, built: *const MeshletsCase) !OptimizeMeshletCase {
        return .{
            .built = built,
            .vertices = try arena.dupe(u32, built.vertices),
            .triangles = try arena.dupe(u8, built.triangles),
        };
    }

    fn original(self: *OptimizeMeshletCase) void {
        @memcpy(self.vertices, self.built.vertices);
        @memcpy(self.triangles, self.built.triangles);
        for (self.built.meshlets[0..self.built.count]) |m| {
            c.meshopt_optimizeMeshlet(
                self.vertices[m.vertex_offset..].ptr,
                self.triangles[m.triangle_offset..].ptr,
                m.triangle_count,
                m.vertex_count,
            );
        }
    }

    fn port(self: *OptimizeMeshletCase) void {
        @memcpy(self.vertices, self.built.vertices);
        @memcpy(self.triangles, self.built.triangles);
        for (self.built.meshlets[0..self.built.count]) |m| {
            mo.optimizeMeshlet(
                self.vertices[m.vertex_offset..][0..m.vertex_count],
                self.triangles[m.triangle_offset..][0 .. m.triangle_count * 3],
            );
        }
    }
};

const MeshletBoundsCase = struct {
    built: *const MeshletsCase,
    mesh: meshes.Mesh,
    sink: f32 = 0,

    fn original(self: *MeshletBoundsCase) void {
        const v = self.mesh.vertices;
        for (self.built.meshlets[0..self.built.count]) |m| {
            const bounds = c.meshopt_computeMeshletBounds(
                self.built.vertices[m.vertex_offset..].ptr,
                self.built.triangles[m.triangle_offset..].ptr,
                m.triangle_count,
                @ptrCast(v.ptr),
                v.len,
                @sizeOf(Vertex),
            );
            self.sink += bounds.radius;
        }
    }

    fn port(self: *MeshletBoundsCase) void {
        const positions = positionsOf(self.mesh.vertices);
        for (self.built.meshlets[0..self.built.count]) |m| {
            const bounds = mo.computeMeshletBounds(
                self.built.vertices[m.vertex_offset..][0..m.vertex_count],
                self.built.triangles[m.triangle_offset..][0 .. m.triangle_count * 3],
                positions,
            );
            self.sink += bounds.radius;
        }
    }
};

/// Partitions the built meshlets, given by their triangles' indices.
const PartitionCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    cluster_indices: []u32,
    counts: []u32,
    destination: []u32,

    const target = 16;

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        built: *const MeshletsCase,
    ) !PartitionCase {
        const meshlets = built.meshlets[0..built.count];
        const cluster_indices = try arena.alloc(u32, built.mesh.indices.len);
        const counts = try arena.alloc(u32, meshlets.len);
        var written: usize = 0;
        for (meshlets, counts) |m, *n| {
            const local = built.vertices[m.vertex_offset..];
            for (built.triangles[m.triangle_offset..][0 .. m.triangle_count * 3]) |t| {
                cluster_indices[written] = local[t];
                written += 1;
            }
            n.* = m.triangle_count * 3;
        }
        return .{
            .gpa = gpa,
            .vertices = built.mesh.vertices,
            .cluster_indices = cluster_indices[0..written],
            .counts = counts,
            .destination = try arena.alloc(u32, meshlets.len),
        };
    }

    fn original(self: *PartitionCase) void {
        const v = self.vertices;
        _ = c.meshopt_partitionClusters(
            self.destination.ptr,
            self.cluster_indices.ptr,
            self.cluster_indices.len,
            self.counts.ptr,
            self.counts.len,
            @ptrCast(v.ptr),
            v.len,
            @sizeOf(Vertex),
            target,
        );
    }

    fn port(self: *PartitionCase) void {
        const positions = positionsOf(self.vertices);
        _ = mo.partitionClusters(
            self.gpa,
            self.destination,
            self.cluster_indices,
            self.counts,
            positions,
            self.vertices.len,
            target,
        ) catch unreachable;
    }
};
