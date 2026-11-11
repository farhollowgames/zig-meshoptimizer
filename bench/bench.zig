//! The port's speed against the original's on the same inputs, the port
//! in ReleaseFast and the original at -O3 for the same CPU, on one thread:
//! each function on the demo mesh and on a large generated one, called in
//! turns after a warm-up call of each. It prints the median of the runs in
//! microseconds, their spread (the interquartile range as a share of the
//! median), the port's time over the original's, and the throughput where
//! a case says how much one call processes. `zig build bench -- <filter>`
//! runs only the cases whose name contains the filter.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");

const Vertex = meshes.Vertex;

const runs = 11;

/// What one call of a case processes, for its throughput: a case declares
/// `pub fn work(self) Work`, or has a `bytes` field. (`@hasDecl` sees only
/// public declarations, so the hooks a case declares are `pub`.)
const Work = union(enum) {
    bytes: usize,
    triangles: usize,
    vertices: usize,
    values: usize,

    fn unit(self: Work) []const u8 {
        return switch (self) {
            .bytes => "MB/s",
            .triangles => "Mtri/s",
            .vertices => "Mvtx/s",
            .values => "Mval/s",
        };
    }

    fn amount(self: Work) f64 {
        return switch (self) {
            inline else => |count| @floatFromInt(count),
        };
    }
};

/// The runs of one side, sorted: their median, and their spread.
const Timing = struct {
    median_ns: u64,
    spread: f64,

    fn of(samples: *[runs]u64) Timing {
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        const median_ns = samples[runs / 2];
        const quartiles = samples[runs - 1 - runs / 4] - samples[runs / 4];
        return .{
            .median_ns = median_ns,
            .spread = @as(f64, @floatFromInt(quartiles)) /
                @as(f64, @floatFromInt(@max(median_ns, 1))),
        };
    }

    fn micros(self: Timing) f64 {
        return @as(f64, @floatFromInt(self.median_ns)) / 1e3;
    }

    /// Millions of `work`'s items a second, or megabytes.
    fn rate(self: Timing, work: Work) f64 {
        return work.amount() / @as(f64, @floatFromInt(@max(self.median_ns, 1))) * 1e3;
    }
};

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

        // Taking turns spreads drift in clock speed and cache state over both.
        _ = self.time(case, "original");
        _ = self.time(case, "port");
        var original_samples: [runs]u64 = undefined;
        var port_samples: [runs]u64 = undefined;
        for (&original_samples, &port_samples) |*o, *p| {
            o.* = self.time(case, "original");
            p.* = self.time(case, "port");
        }
        const original: Timing = .of(&original_samples);
        const port: Timing = .of(&port_samples);

        self.original_total_ns += original.median_ns;
        self.port_total_ns += port.median_ns;
        const ratio = @as(f64, @floatFromInt(port.median_ns)) /
            @as(f64, @floatFromInt(@max(original.median_ns, 1)));
        std.debug.print("{s:<44} {d:>10.1} {d:>5.1}% {d:>10.1} {d:>5.1}% {d:>6.2}", .{
            name,
            original.micros(),
            original.spread * 100,
            port.micros(),
            port.spread * 100,
            ratio,
        });
        const Case = @TypeOf(case.*);
        const work: ?Work = if (@hasDecl(Case, "work"))
            case.work()
        else if (@hasField(Case, "bytes"))
            .{ .bytes = case.bytes }
        else
            null;
        if (work) |w| {
            std.debug.print(" {d:>9.1} {d:>9.1} {s}", .{
                original.rate(w),
                port.rate(w),
                w.unit(),
            });
        }
        std.debug.print("\n", .{});
    }

    fn time(self: *Bench, case: anytype, comptime which: []const u8) u64 {
        // Cases that change their inputs restore them, untimed, in a public
        // `prepare`.
        if (@hasDecl(@TypeOf(case.*), "prepare")) case.prepare();
        const t0 = std.Io.Clock.awake.now(self.io);
        const result = @field(@TypeOf(case.*), which)(case);
        // The result and everything the call wrote stay observable, so the
        // compiler cannot drop the work.
        std.mem.doNotOptimizeAway(result);
        std.mem.doNotOptimizeAway(case);
        const t1 = std.Io.Clock.awake.now(self.io);
        return @intCast(t0.durationTo(t1).nanoseconds);
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

    std.debug.print("{s:<44} {s:>10} {s:>6} {s:>10} {s:>6} {s:>6} {s:>9} {s:>9}\n", .{
        "case",
        "orig us",
        "iqr",
        "port us",
        "iqr",
        "ratio",
        "orig",
        "port",
    });

    var quantize_case: QuantizeCase = try .init(arena);
    inline for (@typeInfo(QuantizeCase.Kind).@"enum".field_names) |kind| {
        quantize_case.kind = @field(QuantizeCase.Kind, kind);
        bench.run(kind ++ " 1M", &quantize_case);
    }

    inline for (.{ .{ "pirate", soup }, .{ "sphere 1M", big_soup } }) |named| {
        const name = named[0];
        const vertices = named[1];
        var remap_case: RemapCase = try .init(arena, bench.gpa, vertices);
        bench.run("generateVertexRemap " ++ name, &remap_case);
        // The cases after it take its table; the filter may have skipped it.
        remap_case.original();
        var multi_case: RemapMultiCase = try .init(arena, bench.gpa, vertices);
        bench.run("generateVertexRemapMulti " ++ name, &multi_case);
        var custom_case: RemapCustomCase = try .init(arena, bench.gpa, vertices);
        bench.run("generateVertexRemapCustom " ++ name, &custom_case);
        const remap = remap_case.remap;
        var vertices_case: RemapVerticesCase = try .init(arena, bench.gpa, vertices, remap);
        bench.run("remapVertexBuffer " ++ name, &vertices_case);
        var indices_case: RemapIndicesCase = try .init(arena, remap_case.remap);
        bench.run("remapIndexBuffer " ++ name, &indices_case);
        var shadow_case: ShadowCase = try .init(arena, bench.gpa, vertices, remap_case.remap);
        bench.run("generateShadowIndexBuffer " ++ name, &shadow_case);
        shadow_case.multi = true;
        bench.run("generateShadowIndexBufferMulti " ++ name, &shadow_case);
        var filter_case: FilterCase = try .init(arena, bench.gpa, vertices, remap_case.remap);
        bench.run("filterIndexBuffer " ++ name, &filter_case);
        filter_case.multi = true;
        bench.run("filterIndexBufferMulti " ++ name, &filter_case);
        var provoking_case: ProvokingCase = try .init(
            arena,
            bench.gpa,
            vertices.len,
            remap_case.remap,
        );
        bench.run("generateProvokingIndexBuffer " ++ name, &provoking_case);
    }

    const pirate = try indexedPirate(arena, soup);
    inline for (.{ .{ "pirate", pirate }, .{ "sphere 1M", big } }) |named| {
        const name = named[0];
        const mesh: meshes.Mesh = named[1];
        const optimized = try arena.alloc(u32, mesh.indices.len);
        c.meshopt_optimizeVertexCache(
            optimized.ptr,
            mesh.indices.ptr,
            mesh.indices.len,
            mesh.vertices.len,
        );
        const indexed: Indexed = .{ .vertices = mesh.vertices, .indices = optimized };
        var overdraw_case: OverdrawCase = try .init(arena, bench.gpa, indexed);
        bench.run("optimizeOverdraw " ++ name, &overdraw_case);
        var fetch_case: FetchCase = try .init(arena, bench.gpa, indexed);
        bench.run("optimizeVertexFetch " ++ name, &fetch_case);
        var strip_case: StripCase = try .init(arena, bench.gpa, indexed);
        bench.run("stripify " ++ name, &strip_case);
        var sort_case: SortTrianglesCase = try .init(arena, bench.gpa, indexed);
        bench.run("spatialSortTriangles " ++ name, &sort_case);
        var cluster_case: ClusterPointsCase = try .init(arena, bench.gpa, indexed);
        bench.run("spatialClusterPoints " ++ name, &cluster_case);
        var sort_remap_case: SortRemapCase = try .init(arena, bench.gpa, indexed);
        bench.run("spatialSortRemap " ++ name, &sort_remap_case);
        var cache_stats_case: CacheStatsCase = .{ .gpa = bench.gpa, .mesh = indexed };
        bench.run("analyzeVertexCache " ++ name, &cache_stats_case);
        var fetch_stats_case: FetchStatsCase = .{ .gpa = bench.gpa, .mesh = indexed };
        bench.run("analyzeVertexFetch " ++ name, &fetch_stats_case);
        var overdraw_stats_case: OverdrawStatsCase = .{ .gpa = bench.gpa, .mesh = indexed };
        bench.run("analyzeOverdraw " ++ name, &overdraw_stats_case);
        overdraw_stats_case.coverage = true;
        bench.run("analyzeCoverage " ++ name, &overdraw_stats_case);
        var fetch_remap_case: FetchRemapCase = try .init(arena, indexed);
        bench.run("optimizeVertexFetchRemap " ++ name, &fetch_remap_case);
        // The strip the stripify case makes, back to a list.
        strip_case.original();
        var unstrip_case: UnstripCase = try .init(arena, &strip_case);
        bench.run("unstripify " ++ name, &unstrip_case);
        var position_remap_case: PositionRemapCase = try .init(arena, bench.gpa, indexed);
        bench.run("generatePositionRemap " ++ name, &position_remap_case);
        var adjacency_case: PatchCase = try .init(arena, bench.gpa, indexed, .adjacency);
        bench.run("generateAdjacencyIndexBuffer " ++ name, &adjacency_case);
        var tessellation_case: PatchCase = try .init(arena, bench.gpa, indexed, .tessellation);
        bench.run("generateTessellationIndexBuffer " ++ name, &tessellation_case);
    }

    // The vertex cache, meshlet and partition functions on the indexed meshes.

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
    std.debug.print("{s:<44} {d:>10.1} {s:>6} {d:>10.1} {s:>6} {d:>6.2}\n", .{
        "total",
        @as(f64, @floatFromInt(bench.original_total_ns)) / 1e3,
        "",
        @as(f64, @floatFromInt(bench.port_total_ns)) / 1e3,
        "",
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

    pub fn work(self: *const RemapCase) Work {
        return .{ .bytes = self.vertices.len * @sizeOf(Vertex) };
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
    /// Through the streams interface, with one stream of the positions.
    multi: bool = false,

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

    pub fn work(self: *const ShadowCase) Work {
        return .{ .triangles = self.indices.len / 3 };
    }

    fn original(self: *ShadowCase) void {
        const v = self.vertices;
        const i = self.indices;
        if (self.multi) {
            const stream: c.Stream = .{ .data = v.ptr, .size = 12, .stride = @sizeOf(Vertex) };
            c.meshopt_generateShadowIndexBufferMulti(
                self.destination.ptr,
                i.ptr,
                i.len,
                v.len,
                &.{stream},
                1,
            );
        } else {
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
    }

    fn port(self: *ShadowCase) void {
        const stream: mo.Stream = .{
            .data = std.mem.sliceAsBytes(self.vertices),
            .size = 12,
            .stride = @sizeOf(Vertex),
        };
        const done = if (self.multi)
            mo.generateShadowIndexBufferMulti(
                self.gpa,
                self.destination,
                self.indices,
                self.vertices.len,
                &.{stream},
            )
        else
            mo.generateShadowIndexBuffer(
                self.gpa,
                self.destination,
                self.indices,
                self.vertices.len,
                stream,
            );
        done catch unreachable;
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

    pub fn work(self: *const ProvokingCase) Work {
        return .{ .triangles = self.indices.len / 3 };
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

/// The demo mesh indexed as the original's demo indexes it.
fn indexedPirate(arena: std.mem.Allocator, soup: []const Vertex) !meshes.Mesh {
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

/// An indexed mesh, its indices optimized for the vertex cache.
const Indexed = struct {
    vertices: []const Vertex,
    indices: []const u32,

    fn positions(self: Indexed) mo.VertexFloats {
        const floats = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(self.vertices));
        return .init(floats, @sizeOf(Vertex) / @sizeOf(f32));
    }

    fn positionsPtr(self: Indexed) [*]const f32 {
        return @ptrCast(self.vertices.ptr);
    }
};

const OverdrawCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    destination: []u32,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, mesh: Indexed) !OverdrawCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .destination = try arena.alloc(u32, mesh.indices.len),
        };
    }

    pub fn work(self: *const OverdrawCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *OverdrawCase) void {
        const m = self.mesh;
        c.meshopt_optimizeOverdraw(
            self.destination.ptr,
            m.indices.ptr,
            m.indices.len,
            m.positionsPtr(),
            m.vertices.len,
            @sizeOf(Vertex),
            1.05,
        );
    }

    fn port(self: *OverdrawCase) void {
        const m = self.mesh;
        mo.optimizeOverdraw(self.gpa, self.destination, m.indices, m.positions(), 1.05) catch
            unreachable;
    }
};

const FetchCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    indices: []u32,
    destination: []Vertex,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, mesh: Indexed) !FetchCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .indices = try arena.alloc(u32, mesh.indices.len),
            .destination = try arena.alloc(Vertex, mesh.vertices.len),
        };
    }

    pub fn prepare(self: *FetchCase) void {
        @memcpy(self.indices, self.mesh.indices);
    }

    pub fn work(self: *const FetchCase) Work {
        return .{ .vertices = self.mesh.vertices.len };
    }

    fn original(self: *FetchCase) void {
        const m = self.mesh;
        _ = c.meshopt_optimizeVertexFetch(
            self.destination.ptr,
            self.indices.ptr,
            self.indices.len,
            m.vertices.ptr,
            m.vertices.len,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *FetchCase) void {
        _ = mo.optimizeVertexFetch(
            self.gpa,
            std.mem.sliceAsBytes(self.destination),
            self.indices,
            std.mem.sliceAsBytes(self.mesh.vertices),
            @sizeOf(Vertex),
        ) catch unreachable;
    }
};

const StripCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    destination: []u32,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, mesh: Indexed) !StripCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .destination = try arena.alloc(u32, mo.stripifyBound(mesh.indices.len)),
        };
    }

    pub fn work(self: *const StripCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *StripCase) void {
        const m = self.mesh;
        _ = c.meshopt_stripify(
            self.destination.ptr,
            m.indices.ptr,
            m.indices.len,
            m.vertices.len,
            0,
        );
    }

    fn port(self: *StripCase) void {
        const m = self.mesh;
        _ = mo.stripify(self.gpa, self.destination, m.indices, m.vertices.len, 0) catch
            unreachable;
    }
};

const SortTrianglesCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    destination: []u32,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, mesh: Indexed) !SortTrianglesCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .destination = try arena.alloc(u32, mesh.indices.len),
        };
    }

    pub fn work(self: *const SortTrianglesCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *SortTrianglesCase) void {
        const m = self.mesh;
        c.meshopt_spatialSortTriangles(
            self.destination.ptr,
            m.indices.ptr,
            m.indices.len,
            m.positionsPtr(),
            m.vertices.len,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *SortTrianglesCase) void {
        const m = self.mesh;
        mo.spatialSortTriangles(self.gpa, self.destination, m.indices, m.positions()) catch
            unreachable;
    }
};

const ClusterPointsCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    destination: []u32,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, mesh: Indexed) !ClusterPointsCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .destination = try arena.alloc(u32, mesh.vertices.len),
        };
    }

    pub fn work(self: *const ClusterPointsCase) Work {
        return .{ .vertices = self.mesh.vertices.len };
    }

    fn original(self: *ClusterPointsCase) void {
        const m = self.mesh;
        c.meshopt_spatialClusterPoints(
            self.destination.ptr,
            m.positionsPtr(),
            m.vertices.len,
            @sizeOf(Vertex),
            64,
        );
    }

    fn port(self: *ClusterPointsCase) void {
        const m = self.mesh;
        mo.spatialClusterPoints(self.gpa, self.destination, m.positions(), 64) catch
            unreachable;
    }
};

const CacheStatsCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,

    pub fn work(self: *const CacheStatsCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *CacheStatsCase) void {
        const m = self.mesh;
        const stats = c.meshopt_analyzeVertexCache(
            m.indices.ptr,
            m.indices.len,
            m.vertices.len,
            16,
            32,
            32,
        );
        std.mem.doNotOptimizeAway(stats);
    }

    fn port(self: *CacheStatsCase) void {
        const m = self.mesh;
        const stats = mo.analyzeVertexCache(self.gpa, m.indices, m.vertices.len, 16, 32, 32) catch
            unreachable;
        std.mem.doNotOptimizeAway(stats);
    }
};

/// The overdraw analyzer, or with `coverage` the coverage analyzer.
const OverdrawStatsCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    coverage: bool = false,

    pub fn work(self: *const OverdrawStatsCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *OverdrawStatsCase) void {
        const m = self.mesh;
        if (self.coverage) {
            std.mem.doNotOptimizeAway(c.meshopt_analyzeCoverage(
                m.indices.ptr,
                m.indices.len,
                m.positionsPtr(),
                m.vertices.len,
                @sizeOf(Vertex),
            ));
        } else {
            std.mem.doNotOptimizeAway(c.meshopt_analyzeOverdraw(
                m.indices.ptr,
                m.indices.len,
                m.positionsPtr(),
                m.vertices.len,
                @sizeOf(Vertex),
            ));
        }
    }

    fn port(self: *OverdrawStatsCase) void {
        const m = self.mesh;
        if (self.coverage) {
            std.mem.doNotOptimizeAway(mo.analyzeCoverage(self.gpa, m.indices, m.positions()) catch
                unreachable);
        } else {
            std.mem.doNotOptimizeAway(mo.analyzeOverdraw(self.gpa, m.indices, m.positions()) catch
                unreachable);
        }
    }
};

/// The quantization functions on a million values each: floats spread
/// over every magnitude a half float holds, and boxes for the exponent.
const QuantizeCase = struct {
    kind: Kind = .quantizeHalf,
    values: []f32,
    halves: []u16,
    ints: []i32,
    floats: []f32,
    boxes: [][2][3]f32,
    exponents: []i32,

    const count = 1 << 20;

    const Kind = enum {
        quantizeHalf,
        dequantizeHalf,
        quantizeFloat,
        quantizeUnorm,
        quantizeSnorm,
        computePositionExponent,
    };

    fn init(arena: std.mem.Allocator) !QuantizeCase {
        var prng: std.Random.DefaultPrng = .init(1);
        const rng = prng.random();
        const self: QuantizeCase = .{
            .values = try arena.alloc(f32, count),
            .halves = try arena.alloc(u16, count),
            .ints = try arena.alloc(i32, count),
            .floats = try arena.alloc(f32, count),
            .boxes = try arena.alloc([2][3]f32, count),
            .exponents = try arena.alloc(i32, count),
        };
        for (self.values, self.halves) |*v, *h| {
            const magnitude = std.math.ldexp(@as(f32, 1), rng.intRangeAtMost(i32, -16, 16));
            v.* = (rng.float(f32) * 2 - 1) * magnitude;
            h.* = rng.int(u16);
        }
        for (self.boxes) |*box| {
            const scale = std.math.ldexp(@as(f32, 1), rng.intRangeAtMost(i32, -20, 20));
            for (&box[0], &box[1]) |*lo, *hi| {
                lo.* = -rng.float(f32) * scale;
                hi.* = rng.float(f32) * scale;
            }
        }
        return self;
    }

    pub fn work(self: *const QuantizeCase) Work {
        _ = self;
        return .{ .values = count };
    }

    fn original(self: *QuantizeCase) void {
        switch (self.kind) {
            .quantizeHalf => for (self.values, self.halves) |v, *h| {
                h.* = c.meshopt_quantizeHalf(v);
            },
            .dequantizeHalf => for (self.halves, self.floats) |h, *f| {
                f.* = c.meshopt_dequantizeHalf(h);
            },
            .quantizeFloat => for (self.values, self.floats) |v, *f| {
                f.* = c.meshopt_quantizeFloat(v, 10);
            },
            .quantizeUnorm => c.reference_quantizeUnormArray(
                self.ints.ptr,
                self.values.ptr,
                count,
                10,
            ),
            .quantizeSnorm => c.reference_quantizeSnormArray(
                self.ints.ptr,
                self.values.ptr,
                count,
                10,
            ),
            .computePositionExponent => for (self.boxes, self.exponents) |*box, *e| {
                e.* = c.meshopt_computePositionExponent(&box[0], &box[1], -20, 16);
            },
        }
    }

    fn port(self: *QuantizeCase) void {
        switch (self.kind) {
            .quantizeHalf => for (self.values, self.halves) |v, *h| {
                h.* = mo.quantizeHalf(v);
            },
            .dequantizeHalf => for (self.halves, self.floats) |h, *f| {
                f.* = mo.dequantizeHalf(h);
            },
            .quantizeFloat => for (self.values, self.floats) |v, *f| {
                f.* = mo.quantizeFloat(v, 10);
            },
            .quantizeUnorm => for (self.values, self.ints) |v, *i| {
                i.* = @bitCast(mo.quantizeUnorm(v, 10));
            },
            .quantizeSnorm => for (self.values, self.ints) |v, *i| {
                i.* = mo.quantizeSnorm(v, 10);
            },
            .computePositionExponent => for (self.boxes, self.exponents) |box, *e| {
                e.* = mo.computePositionExponent(box[0], box[1], -20, 16);
            },
        }
    }
};

/// The soup's vertices as three streams: positions, normals and texture
/// coordinates.
fn soupStreams(vertices: []const Vertex) [3]mo.Stream {
    const bytes = std.mem.sliceAsBytes(vertices);
    return .{
        .{ .data = bytes, .size = 12, .stride = @sizeOf(Vertex) },
        .{ .data = bytes[12..], .size = 12, .stride = @sizeOf(Vertex) },
        .{ .data = bytes[24..], .size = 8, .stride = @sizeOf(Vertex) },
    };
}

fn cStreams(streams: [3]mo.Stream) [3]c.Stream {
    var result: [3]c.Stream = undefined;
    for (&result, streams) |*r, stream| {
        r.* = .{ .data = stream.data.ptr, .size = stream.size, .stride = stream.stride };
    }
    return result;
}

const RemapMultiCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    remap: []u32,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        vertices: []const Vertex,
    ) !RemapMultiCase {
        return .{ .gpa = gpa, .vertices = vertices, .remap = try arena.alloc(u32, vertices.len) };
    }

    pub fn work(self: *const RemapMultiCase) Work {
        return .{ .bytes = self.vertices.len * @sizeOf(Vertex) };
    }

    fn original(self: *RemapMultiCase) usize {
        const v = self.vertices;
        const streams = cStreams(soupStreams(v));
        return c.meshopt_generateVertexRemapMulti(self.remap.ptr, null, v.len, v.len, &streams, 3);
    }

    fn port(self: *RemapMultiCase) usize {
        const v = self.vertices;
        const streams = soupStreams(v);
        return mo.generateVertexRemapMulti(self.gpa, self.remap, null, v.len, &streams) catch
            unreachable;
    }
};

/// Positions compared as floats, with no callback.
const RemapCustomCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    remap: []u32,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        vertices: []const Vertex,
    ) !RemapCustomCase {
        return .{ .gpa = gpa, .vertices = vertices, .remap = try arena.alloc(u32, vertices.len) };
    }

    pub fn work(self: *const RemapCustomCase) Work {
        return .{ .vertices = self.vertices.len };
    }

    fn original(self: *RemapCustomCase) usize {
        const v = self.vertices;
        return c.meshopt_generateVertexRemapCustom(
            self.remap.ptr,
            null,
            v.len,
            @ptrCast(v.ptr),
            v.len,
            @sizeOf(Vertex),
            null,
            null,
        );
    }

    fn port(self: *RemapCustomCase) usize {
        const floats = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(self.vertices));
        const positions: mo.VertexFloats = .init(floats, @sizeOf(Vertex) / @sizeOf(f32));
        return mo.generateVertexRemapCustom(self.gpa, self.remap, null, positions, {}, null) catch
            unreachable;
    }
};

const RemapVerticesCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    remap: []const u32,
    destination: []Vertex,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        vertices: []const Vertex,
        remap: []const u32,
    ) !RemapVerticesCase {
        var unique: usize = 0;
        for (remap) |r| unique = @max(unique, r + 1);
        return .{
            .gpa = gpa,
            .vertices = vertices,
            .remap = remap,
            .destination = try arena.alloc(Vertex, unique),
        };
    }

    pub fn work(self: *const RemapVerticesCase) Work {
        return .{ .bytes = self.vertices.len * @sizeOf(Vertex) };
    }

    fn original(self: *RemapVerticesCase) void {
        const v = self.vertices;
        c.meshopt_remapVertexBuffer(
            self.destination.ptr,
            v.ptr,
            v.len,
            @sizeOf(Vertex),
            self.remap.ptr,
        );
    }

    fn port(self: *RemapVerticesCase) void {
        mo.remapVertexBuffer(
            self.gpa,
            std.mem.sliceAsBytes(self.destination),
            std.mem.sliceAsBytes(self.vertices),
            @sizeOf(Vertex),
            self.remap,
        ) catch unreachable;
    }
};

/// The soup's index buffer, which is no buffer at all: index i is i.
const RemapIndicesCase = struct {
    remap: []const u32,
    destination: []u32,

    fn init(arena: std.mem.Allocator, remap: []const u32) !RemapIndicesCase {
        return .{ .remap = remap, .destination = try arena.alloc(u32, remap.len) };
    }

    pub fn work(self: *const RemapIndicesCase) Work {
        return .{ .triangles = self.remap.len / 3 };
    }

    fn original(self: *RemapIndicesCase) void {
        c.meshopt_remapIndexBuffer(self.destination.ptr, null, self.remap.len, self.remap.ptr);
    }

    fn port(self: *RemapIndicesCase) void {
        mo.remapIndexBuffer(self.destination, null, self.remap);
    }
};

/// Triangles that are degenerate by their positions removed.
const FilterCase = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vertex,
    indices: []const u32,
    destination: []u32,
    /// Through the streams interface, with one stream of the positions.
    multi: bool = false,

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        vertices: []const Vertex,
        indices: []const u32,
    ) !FilterCase {
        return .{
            .gpa = gpa,
            .vertices = vertices,
            .indices = indices,
            .destination = try arena.alloc(u32, indices.len),
        };
    }

    pub fn work(self: *const FilterCase) Work {
        return .{ .triangles = self.indices.len / 3 };
    }

    fn original(self: *FilterCase) usize {
        const v = self.vertices;
        const i = self.indices;
        if (self.multi) {
            const stream: c.Stream = .{ .data = v.ptr, .size = 12, .stride = @sizeOf(Vertex) };
            return c.meshopt_filterIndexBufferMulti(
                self.destination.ptr,
                i.ptr,
                i.len,
                v.len,
                &.{stream},
                1,
            );
        }
        return c.meshopt_filterIndexBuffer(
            self.destination.ptr,
            i.ptr,
            i.len,
            v.ptr,
            v.len,
            12,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *FilterCase) usize {
        const stream: mo.Stream = .{
            .data = std.mem.sliceAsBytes(self.vertices),
            .size = 12,
            .stride = @sizeOf(Vertex),
        };
        const count = if (self.multi)
            mo.filterIndexBufferMulti(
                self.gpa,
                self.destination,
                self.indices,
                self.vertices.len,
                &.{stream},
            )
        else
            mo.filterIndexBuffer(
                self.gpa,
                self.destination,
                self.indices,
                self.vertices.len,
                stream,
            );
        return count catch unreachable;
    }
};

const SortRemapCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    destination: []u32,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, mesh: Indexed) !SortRemapCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .destination = try arena.alloc(u32, mesh.vertices.len),
        };
    }

    pub fn work(self: *const SortRemapCase) Work {
        return .{ .vertices = self.mesh.vertices.len };
    }

    fn original(self: *SortRemapCase) void {
        const m = self.mesh;
        c.meshopt_spatialSortRemap(
            self.destination.ptr,
            m.positionsPtr(),
            m.vertices.len,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *SortRemapCase) void {
        mo.spatialSortRemap(self.gpa, self.destination, self.mesh.positions()) catch unreachable;
    }
};

const FetchStatsCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,

    pub fn work(self: *const FetchStatsCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *FetchStatsCase) c.VertexFetchStatistics {
        const m = self.mesh;
        return c.meshopt_analyzeVertexFetch(
            m.indices.ptr,
            m.indices.len,
            m.vertices.len,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *FetchStatsCase) mo.VertexFetchStatistics {
        const m = self.mesh;
        return mo.analyzeVertexFetch(self.gpa, m.indices, m.vertices.len, @sizeOf(Vertex)) catch
            unreachable;
    }
};

const FetchRemapCase = struct {
    mesh: Indexed,
    destination: []u32,

    fn init(arena: std.mem.Allocator, mesh: Indexed) !FetchRemapCase {
        return .{ .mesh = mesh, .destination = try arena.alloc(u32, mesh.vertices.len) };
    }

    pub fn work(self: *const FetchRemapCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *FetchRemapCase) usize {
        const m = self.mesh;
        return c.meshopt_optimizeVertexFetchRemap(
            self.destination.ptr,
            m.indices.ptr,
            m.indices.len,
            m.vertices.len,
        );
    }

    fn port(self: *FetchRemapCase) usize {
        const m = self.mesh;
        return mo.optimizeVertexFetchRemap(self.destination, m.indices, m.vertices.len);
    }
};

const UnstripCase = struct {
    strip: []const u32,
    destination: []u32,

    /// The strip `built` holds after its original ran, without restarts.
    fn init(arena: std.mem.Allocator, built: *const StripCase) !UnstripCase {
        const m = built.mesh;
        const size = c.meshopt_stripify(
            built.destination.ptr,
            m.indices.ptr,
            m.indices.len,
            m.vertices.len,
            0,
        );
        const strip = built.destination[0..size];
        return .{ .strip = strip, .destination = try arena.alloc(u32, mo.unstripifyBound(size)) };
    }

    pub fn work(self: *const UnstripCase) Work {
        return .{ .vertices = self.strip.len };
    }

    fn original(self: *UnstripCase) usize {
        return c.meshopt_unstripify(self.destination.ptr, self.strip.ptr, self.strip.len, 0);
    }

    fn port(self: *UnstripCase) usize {
        return mo.unstripify(self.destination, self.strip, 0);
    }
};

const PositionRemapCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    destination: []u32,

    fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, mesh: Indexed) !PositionRemapCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .destination = try arena.alloc(u32, mesh.vertices.len),
        };
    }

    pub fn work(self: *const PositionRemapCase) Work {
        return .{ .vertices = self.mesh.vertices.len };
    }

    fn original(self: *PositionRemapCase) void {
        const m = self.mesh;
        c.meshopt_generatePositionRemap(
            self.destination.ptr,
            m.positionsPtr(),
            m.vertices.len,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *PositionRemapCase) void {
        mo.generatePositionRemap(self.gpa, self.destination, self.mesh.positions()) catch
            unreachable;
    }
};

/// Adjacency or tessellation index buffers, 6 or 12 indices a triangle.
const PatchCase = struct {
    gpa: std.mem.Allocator,
    mesh: Indexed,
    kind: Kind,
    destination: []u32,

    const Kind = enum { adjacency, tessellation };

    fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        mesh: Indexed,
        kind: Kind,
    ) !PatchCase {
        return .{
            .gpa = gpa,
            .mesh = mesh,
            .kind = kind,
            .destination = try arena.alloc(u32, mesh.indices.len * 4),
        };
    }

    pub fn work(self: *const PatchCase) Work {
        return .{ .triangles = self.mesh.indices.len / 3 };
    }

    fn original(self: *PatchCase) void {
        const m = self.mesh;
        const generate = switch (self.kind) {
            .adjacency => &c.meshopt_generateAdjacencyIndexBuffer,
            .tessellation => &c.meshopt_generateTessellationIndexBuffer,
        };
        generate(
            self.destination.ptr,
            m.indices.ptr,
            m.indices.len,
            m.positionsPtr(),
            m.vertices.len,
            @sizeOf(Vertex),
        );
    }

    fn port(self: *PatchCase) void {
        const m = self.mesh;
        const done = switch (self.kind) {
            .adjacency => mo.generateAdjacencyIndexBuffer(
                self.gpa,
                self.destination[0 .. m.indices.len * 2],
                m.indices,
                m.positions(),
            ),
            .tessellation => mo.generateTessellationIndexBuffer(
                self.gpa,
                self.destination,
                m.indices,
                m.positions(),
            ),
        };
        done catch unreachable;
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
