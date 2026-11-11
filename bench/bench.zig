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

    try vertexCodec(&bench, arena, soup);

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

/// The vertex codec on the demo mesh and on a sphere of a million vertices,
/// each as 32 bytes of floats and quantized into 16 bytes: the encoder at
/// each level, and the decoder on streams of both versions.
fn vertexCodec(bench: *Bench, arena: std.mem.Allocator, soup: []const Vertex) !void {
    const remap = try arena.alloc(u32, soup.len);
    const unique = c.meshopt_generateVertexRemap(
        remap.ptr,
        null,
        soup.len,
        soup.ptr,
        soup.len,
        @sizeOf(Vertex),
    );
    const pirate = try meshes.indexed(arena, soup, remap, unique);
    const sphere = try meshes.sphere(arena, 999, 999);

    const quantized_size = meshes.quantized_vertex_size;
    const buffers = .{
        .{ "pirate", std.mem.sliceAsBytes(pirate.vertices), @sizeOf(Vertex) },
        .{ "pirate q16", try meshes.quantized(arena, pirate.vertices), quantized_size },
        .{ "sphere 1M", std.mem.sliceAsBytes(sphere.vertices), @sizeOf(Vertex) },
        .{ "sphere 1M q16", try meshes.quantized(arena, sphere.vertices), quantized_size },
    };

    inline for (buffers) |named| {
        const name = named[0];
        const vertices: []const u8 = named[1];
        const vertex_size = named[2];
        const vertex_count = vertices.len / vertex_size;
        const bound = mo.encodeVertexBufferBound(vertex_count, vertex_size);

        inline for (vertex_codec_settings) |setting| {
            var encode: VertexEncodeCase = .{
                .vertices = vertices,
                .vertex_size = vertex_size,
                .level = setting[1],
                .version = setting[2],
                .buffer = try arena.alloc(u8, bound),
            };
            bench.run("encodeVertexBuffer " ++ setting[0] ++ " " ++ name, &encode);

            // The original's stream, which is the port's too, so that the
            // port's encoder stays out of the decoder's profile.
            const size = c.meshopt_encodeVertexBufferLevel(
                encode.buffer.ptr,
                encode.buffer.len,
                vertices.ptr,
                vertex_count,
                vertex_size,
                setting[1],
                @backingInt(encode.version),
            );
            var decode: VertexDecodeCase = .{
                .stream = encode.buffer[0..size],
                .destination = try arena.alloc(u8, vertices.len),
                .vertex_size = vertex_size,
            };
            bench.run("decodeVertexBuffer " ++ setting[0] ++ " " ++ name, &decode);
        }
    }
}

/// The encoder settings the vertex codec cases time: version 1 at each
/// level, and version 0.
const vertex_codec_settings = .{
    .{ "v1 L0", 0, .v1 },
    .{ "v1 L1", 1, .v1 },
    .{ "v1 L2", 2, .v1 },
    .{ "v1 L3", 3, .v1 },
    .{ "v0", 2, .v0 },
};

const VertexEncodeCase = struct {
    vertices: []const u8,
    vertex_size: usize,
    level: u4,
    version: mo.VertexVersion,
    buffer: []u8,

    fn original(self: *VertexEncodeCase) void {
        const size = c.meshopt_encodeVertexBufferLevel(
            self.buffer.ptr,
            self.buffer.len,
            self.vertices.ptr,
            self.vertices.len / self.vertex_size,
            self.vertex_size,
            self.level,
            @backingInt(self.version),
        );
        std.mem.doNotOptimizeAway(size);
        std.mem.doNotOptimizeAway(self.buffer.ptr);
    }

    fn port(self: *VertexEncodeCase) void {
        const size = mo.encodeVertexBufferLevel(
            self.buffer,
            self.vertices,
            self.vertex_size,
            self.level,
            self.version,
        );
        std.mem.doNotOptimizeAway(size);
        std.mem.doNotOptimizeAway(self.buffer.ptr);
    }
};

const VertexDecodeCase = struct {
    stream: []const u8,
    destination: []u8,
    vertex_size: usize,

    fn original(self: *VertexDecodeCase) void {
        const result = c.meshopt_decodeVertexBuffer(
            self.destination.ptr,
            self.destination.len / self.vertex_size,
            self.vertex_size,
            self.stream.ptr,
            self.stream.len,
        );
        std.debug.assert(result == 0);
        std.mem.doNotOptimizeAway(self.destination.ptr);
    }

    fn port(self: *VertexDecodeCase) void {
        mo.decodeVertexBuffer(self.destination, self.vertex_size, self.stream) catch unreachable;
        std.mem.doNotOptimizeAway(self.destination.ptr);
    }
};
