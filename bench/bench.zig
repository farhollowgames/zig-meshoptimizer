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
        var strip_case: VertexCacheCase = try .init(arena, bench.gpa, mesh, .strip);
        bench.run("optimizeVertexCacheStrip " ++ name, &strip_case);
        var fifo_case: VertexCacheCase = try .init(arena, bench.gpa, mesh, .fifo);
        bench.run("optimizeVertexCacheFifo " ++ name, &fifo_case);

        // The meshlet cases take the cache-ordered indices, as a bake does;
        // the filter may have skipped the case that orders them.
        vcache_case.original();
        const ordered: meshes.Mesh = .{
            .vertices = mesh.vertices,
            .indices = vcache_case.destination,
        };
        const builders = .{
            .{ "buildMeshlets ", .standard },
            .{ "buildMeshletsScan ", .scan },
            .{ "buildMeshletsFlex ", .flex },
            .{ "buildMeshletsSpatial ", .spatial },
        };
        inline for (builders) |builder| {
            var builder_case: MeshletsCase = try .init(arena, bench.gpa, ordered, builder[1]);
            bench.run(builder[0] ++ name, &builder_case);
        }

        var meshlets_case: MeshletsCase = try .init(arena, bench.gpa, ordered, .standard);
        meshlets_case.original();
        var optimize_case: OptimizeMeshletCase = try .init(arena, &meshlets_case, 0);
        bench.run("optimizeMeshlet " ++ name, &optimize_case);
        var level_case: OptimizeMeshletCase = try .init(arena, &meshlets_case, 3);
        bench.run("optimizeMeshletLevel 3 " ++ name, &level_case);

        const clusters: Clusters = try .init(arena, &meshlets_case);
        var bounds_case: MeshletBoundsCase = .{ .built = &meshlets_case, .mesh = ordered };
        bench.run("computeMeshletBounds " ++ name, &bounds_case);
        var cluster_case: ClusterBoundsCase = .{ .clusters = &clusters, .mesh = ordered };
        bench.run("computeClusterBounds " ++ name, &cluster_case);
        var extract_case: ExtractCase = .{ .clusters = &clusters };
        bench.run("extractMeshletIndices " ++ name, &extract_case);
        var points_case: SphereBoundsCase = try .init(arena, mesh, false);
        bench.run("computeSphereBounds points " ++ name, &points_case);
        var spheres_case: SphereBoundsCase = try .init(arena, mesh, true);
        bench.run("computeSphereBounds spheres " ++ name, &spheres_case);
        var partition_case: PartitionCase = .{
            .gpa = bench.gpa,
            .vertices = mesh.vertices,
            .clusters = &clusters,
            .destination = try arena.alloc(u32, clusters.counts.len),
        };
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

    const Kind = enum { default, strip, fifo };
    const cache_size = 16;

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
        const d = self.destination.ptr;
        const i = self.mesh.indices;
        const n = self.mesh.vertices.len;
        switch (self.kind) {
            .default => c.meshopt_optimizeVertexCache(d, i.ptr, i.len, n),
            .strip => c.meshopt_optimizeVertexCacheStrip(d, i.ptr, i.len, n),
            .fifo => c.meshopt_optimizeVertexCacheFifo(d, i.ptr, i.len, n, cache_size),
        }
        std.mem.doNotOptimizeAway(self.destination);
    }

    fn port(self: *VertexCacheCase) void {
        const d = self.destination;
        const i = self.mesh.indices;
        const n = self.mesh.vertices.len;
        const done = switch (self.kind) {
            .default => mo.optimizeVertexCache(self.gpa, d, i, n),
            .strip => mo.optimizeVertexCacheStrip(self.gpa, d, i, n),
            .fifo => mo.optimizeVertexCacheFifo(self.gpa, d, i, n, cache_size),
        };
        done catch unreachable;
        std.mem.doNotOptimizeAway(self.destination);
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

    const Kind = enum { standard, scan, flex, spatial };
    const max_vertices = 64;
    const max_triangles = 124;
    const min_triangles = 64;
    const cone_weight = 0.25;
    const split_factor = 2;
    const fill_weight = 0.5;

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
        const p: [*]const f32 = @ptrCast(v.ptr);
        const stride = @sizeOf(Vertex);
        self.count = switch (self.kind) {
            .standard => c.meshopt_buildMeshlets(
                meshlets,
                self.vertices.ptr,
                self.triangles.ptr,
                i.ptr,
                i.len,
                p,
                v.len,
                stride,
                max_vertices,
                max_triangles,
                0,
            ),
            .scan => c.meshopt_buildMeshletsScan(
                meshlets,
                self.vertices.ptr,
                self.triangles.ptr,
                i.ptr,
                i.len,
                v.len,
                max_vertices,
                max_triangles,
            ),
            .flex => c.meshopt_buildMeshletsFlex(
                meshlets,
                self.vertices.ptr,
                self.triangles.ptr,
                i.ptr,
                i.len,
                p,
                v.len,
                stride,
                max_vertices,
                min_triangles,
                max_triangles,
                cone_weight,
                split_factor,
            ),
            .spatial => c.meshopt_buildMeshletsSpatial(
                meshlets,
                self.vertices.ptr,
                self.triangles.ptr,
                i.ptr,
                i.len,
                p,
                v.len,
                stride,
                max_vertices,
                min_triangles,
                max_triangles,
                fill_weight,
            ),
        };
        self.keep();
    }

    fn port(self: *MeshletsCase) void {
        const i = self.mesh.indices;
        const positions = positionsOf(self.mesh.vertices);
        self.count = switch (self.kind) {
            .standard => mo.buildMeshlets(
                self.gpa,
                self.meshlets,
                self.vertices,
                self.triangles,
                i,
                positions,
                max_vertices,
                max_triangles,
                0,
            ),
            .scan => mo.buildMeshletsScan(
                self.gpa,
                self.meshlets,
                self.vertices,
                self.triangles,
                i,
                self.mesh.vertices.len,
                max_vertices,
                max_triangles,
            ),
            .flex => mo.buildMeshletsFlex(
                self.gpa,
                self.meshlets,
                self.vertices,
                self.triangles,
                i,
                positions,
                max_vertices,
                min_triangles,
                max_triangles,
                cone_weight,
                split_factor,
            ),
            .spatial => mo.buildMeshletsSpatial(
                self.gpa,
                self.meshlets,
                self.vertices,
                self.triangles,
                i,
                positions,
                max_vertices,
                min_triangles,
                max_triangles,
                fill_weight,
            ),
        } catch unreachable;
        self.keep();
    }

    fn keep(self: *MeshletsCase) void {
        std.mem.doNotOptimizeAway(self.count);
        std.mem.doNotOptimizeAway(self.meshlets);
        std.mem.doNotOptimizeAway(self.vertices);
        std.mem.doNotOptimizeAway(self.triangles);
    }
};

/// Each run optimizes fresh copies of the built meshlets.
const OptimizeMeshletCase = struct {
    built: *const MeshletsCase,
    vertices: []u32,
    triangles: []u8,
    level: u4,

    fn init(arena: std.mem.Allocator, built: *const MeshletsCase, level: u4) !OptimizeMeshletCase {
        return .{
            .built = built,
            .vertices = try arena.dupe(u32, built.vertices),
            .triangles = try arena.dupe(u8, built.triangles),
            .level = level,
        };
    }

    fn original(self: *OptimizeMeshletCase) void {
        @memcpy(self.vertices, self.built.vertices);
        @memcpy(self.triangles, self.built.triangles);
        for (self.built.meshlets[0..self.built.count]) |m| {
            c.meshopt_optimizeMeshletLevel(
                self.vertices[m.vertex_offset..].ptr,
                m.vertex_count,
                self.triangles[m.triangle_offset..].ptr,
                m.triangle_count,
                self.level,
            );
        }
        std.mem.doNotOptimizeAway(self.vertices);
        std.mem.doNotOptimizeAway(self.triangles);
    }

    fn port(self: *OptimizeMeshletCase) void {
        @memcpy(self.vertices, self.built.vertices);
        @memcpy(self.triangles, self.built.triangles);
        for (self.built.meshlets[0..self.built.count]) |m| {
            mo.optimizeMeshletLevel(
                self.vertices[m.vertex_offset..][0..m.vertex_count],
                self.triangles[m.triangle_offset..][0 .. m.triangle_count * 3],
                self.level,
            );
        }
        std.mem.doNotOptimizeAway(self.vertices);
        std.mem.doNotOptimizeAway(self.triangles);
    }
};

const MeshletBoundsCase = struct {
    built: *const MeshletsCase,
    mesh: meshes.Mesh,

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
            std.mem.doNotOptimizeAway(bounds);
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
            std.mem.doNotOptimizeAway(bounds);
        }
    }
};

/// The built meshlets as clusters of their triangles' mesh indices.
const Clusters = struct {
    indices: []u32,
    counts: []u32,

    fn init(arena: std.mem.Allocator, built: *const MeshletsCase) !Clusters {
        const meshlets = built.meshlets[0..built.count];
        const indices = try arena.alloc(u32, built.mesh.indices.len);
        const counts = try arena.alloc(u32, meshlets.len);
        var written: usize = 0;
        for (meshlets, counts) |m, *n| {
            const local = built.vertices[m.vertex_offset..];
            for (built.triangles[m.triangle_offset..][0 .. m.triangle_count * 3]) |t| {
                indices[written] = local[t];
                written += 1;
            }
            n.* = m.triangle_count * 3;
        }
        return .{ .indices = indices[0..written], .counts = counts };
    }
};

const ClusterBoundsCase = struct {
    clusters: *const Clusters,
    mesh: meshes.Mesh,

    fn original(self: *ClusterBoundsCase) void {
        const v = self.mesh.vertices;
        var start: usize = 0;
        for (self.clusters.counts) |n| {
            const bounds = c.meshopt_computeClusterBounds(
                self.clusters.indices[start..].ptr,
                n,
                @ptrCast(v.ptr),
                v.len,
                @sizeOf(Vertex),
            );
            std.mem.doNotOptimizeAway(bounds);
            start += n;
        }
    }

    fn port(self: *ClusterBoundsCase) void {
        const positions = positionsOf(self.mesh.vertices);
        var start: usize = 0;
        for (self.clusters.counts) |n| {
            const indices = self.clusters.indices[start..][0..n];
            std.mem.doNotOptimizeAway(mo.computeClusterBounds(indices, positions));
            start += n;
        }
    }
};

const ExtractCase = struct {
    clusters: *const Clusters,
    vertices: [256]u32 = undefined,
    triangles: [512 * 3]u8 = undefined,

    fn original(self: *ExtractCase) void {
        var start: usize = 0;
        for (self.clusters.counts) |n| {
            const unique = c.meshopt_extractMeshletIndices(
                &self.vertices,
                &self.triangles,
                self.clusters.indices[start..].ptr,
                n,
            );
            std.mem.doNotOptimizeAway(unique);
            std.mem.doNotOptimizeAway(&self.triangles);
            start += n;
        }
    }

    fn port(self: *ExtractCase) void {
        var start: usize = 0;
        for (self.clusters.counts) |n| {
            const indices = self.clusters.indices[start..][0..n];
            const unique = mo.extractMeshletIndices(&self.vertices, &self.triangles, indices);
            std.mem.doNotOptimizeAway(unique);
            std.mem.doNotOptimizeAway(&self.triangles);
            start += n;
        }
    }
};

/// One sphere around every vertex of the mesh, or around spheres of the
/// radii in `radii`.
const SphereBoundsCase = struct {
    mesh: meshes.Mesh,
    radii: ?[]const f32,

    fn init(arena: std.mem.Allocator, mesh: meshes.Mesh, spheres: bool) !SphereBoundsCase {
        if (!spheres) return .{ .mesh = mesh, .radii = null };
        const radii = try arena.alloc(f32, mesh.vertices.len);
        for (radii, mesh.vertices) |*r, v| r.* = @abs(v.nx) * 0.01;
        return .{ .mesh = mesh, .radii = radii };
    }

    fn original(self: *SphereBoundsCase) void {
        const v = self.mesh.vertices;
        const bounds = c.meshopt_computeSphereBounds(
            @ptrCast(v.ptr),
            v.len,
            @sizeOf(Vertex),
            if (self.radii) |r| r.ptr else null,
            if (self.radii != null) @sizeOf(f32) else 0,
        );
        std.mem.doNotOptimizeAway(bounds);
    }

    fn port(self: *SphereBoundsCase) void {
        const radii: ?mo.VertexFloats = if (self.radii) |r| .init(r, 1) else null;
        const bounds = mo.computeSphereBounds(positionsOf(self.mesh.vertices), radii);
        std.mem.doNotOptimizeAway(bounds);
    }
};

/// Partitions the built meshlets, given by their triangles' indices.
const PartitionCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    clusters: *const Clusters,
    destination: []u32,

    const target = 16;

    fn original(self: *PartitionCase) void {
        const v = self.vertices;
        const partitions = c.meshopt_partitionClusters(
            self.destination.ptr,
            self.clusters.indices.ptr,
            self.clusters.indices.len,
            self.clusters.counts.ptr,
            self.clusters.counts.len,
            @ptrCast(v.ptr),
            v.len,
            @sizeOf(Vertex),
            target,
        );
        std.mem.doNotOptimizeAway(partitions);
        std.mem.doNotOptimizeAway(self.destination);
    }

    fn port(self: *PartitionCase) void {
        const partitions = mo.partitionClusters(
            self.gpa,
            self.destination,
            self.clusters.indices,
            self.clusters.counts,
            positionsOf(self.vertices),
            self.vertices.len,
            target,
        ) catch unreachable;
        std.mem.doNotOptimizeAway(partitions);
        std.mem.doNotOptimizeAway(self.destination);
    }
};
