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

    // The codecs, on index buffers optimized for the vertex cache and for
    // vertex fetch, and on the meshlets of those, as they are usually used.
    // The demo mesh runs many rounds per timing, as one is short.
    const pirate = try indexed(arena, soup);
    inline for (.{ .{ "pirate", pirate, 100 }, .{ "sphere 1M", big, 1 } }) |named| {
        const name = named[0];
        const mesh: meshes.Mesh = named[1];
        const rounds: usize = named[2];
        const indices = try optimized(arena, mesh);

        var index_case: IndexCodecCase = try .init(arena, indices, mesh.vertices.len, rounds);
        bench.run("encodeIndexBuffer " ++ name, &index_case.encode);
        bench.run("decodeIndexBuffer u32 " ++ name, &index_case.decode32);
        bench.run("decodeIndexBuffer u16 " ++ name, &index_case.decode16);
        bench.run("encodeIndexSequence " ++ name, &index_case.encode_sequence);
        bench.run("decodeIndexSequence " ++ name, &index_case.decode_sequence);

        var meshlet_case: MeshletCodecCase = try .init(arena, mesh, indices, rounds);
        bench.run("encodeMeshlet " ++ name, &meshlet_case.encode);
        bench.run("decodeMeshlet u32/u8 " ++ name, &meshlet_case.decode_bytes);
        bench.run("decodeMeshlet u16/u32 " ++ name, &meshlet_case.decode_words);
        bench.run("decodeMeshletRaw " ++ name, &meshlet_case.decode_raw);
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

/// The demo mesh indexed by the original, as its demo does.
fn indexed(arena: std.mem.Allocator, soup: []const Vertex) !meshes.Mesh {
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

/// `mesh`'s indices optimized by the original for the vertex cache and
/// then for vertex fetch.
fn optimized(arena: std.mem.Allocator, mesh: meshes.Mesh) ![]u32 {
    const indices = try arena.alloc(u32, mesh.indices.len);
    const vertex_count = mesh.vertices.len;
    c.meshopt_optimizeVertexCache(indices.ptr, mesh.indices.ptr, indices.len, vertex_count);
    const remap = try arena.alloc(u32, vertex_count);
    _ = c.meshopt_optimizeVertexFetchRemap(remap.ptr, indices.ptr, indices.len, vertex_count);
    c.meshopt_remapIndexBuffer(indices.ptr, indices.ptr, indices.len, remap.ptr);
    return indices;
}

const IndexCodecCase = struct {
    encode: Encode,
    decode32: Decode(u32, false),
    decode16: Decode(u16, false),
    encode_sequence: Encode,
    decode_sequence: Decode(u32, true),

    const Encode = struct {
        indices: []const u32,
        buffer: []u8,
        rounds: usize,
        sequence: bool,

        fn original(self: *Encode) void {
            const i = self.indices;
            for (0..self.rounds) |_| {
                const size = if (self.sequence)
                    c.meshopt_encodeIndexSequence(self.buffer.ptr, self.buffer.len, i.ptr, i.len)
                else
                    c.meshopt_encodeIndexBuffer(self.buffer.ptr, self.buffer.len, i.ptr, i.len);
                std.mem.doNotOptimizeAway(size);
            }
        }

        // Calls, not inlined, as the original's are.
        fn port(self: *Encode) void {
            const args = .{ self.buffer, self.indices, mo.IndexVersion.default };
            for (0..self.rounds) |_| {
                const size = if (self.sequence)
                    @call(.never_inline, mo.encodeIndexSequence, args)
                else
                    @call(.never_inline, mo.encodeIndexBuffer, args);
                std.mem.doNotOptimizeAway(size catch unreachable);
            }
        }
    };

    fn Decode(comptime T: type, comptime sequence: bool) type {
        return struct {
            stream: []const u8,
            destination: []T,
            rounds: usize,

            const Self = @This();

            fn original(self: *Self) void {
                const d = self.destination;
                const s = self.stream;
                for (0..self.rounds) |_| {
                    const rc = if (sequence)
                        c.meshopt_decodeIndexSequence(d.ptr, d.len, @sizeOf(T), s.ptr, s.len)
                    else
                        c.meshopt_decodeIndexBuffer(d.ptr, d.len, @sizeOf(T), s.ptr, s.len);
                    std.debug.assert(rc == 0);
                }
            }

            fn port(self: *Self) void {
                const decode = if (sequence) mo.decodeIndexSequence else mo.decodeIndexBuffer;
                for (0..self.rounds) |_| {
                    @call(.never_inline, decode, .{ T, self.destination, self.stream }) catch
                        unreachable;
                }
            }
        };
    }

    fn init(
        arena: std.mem.Allocator,
        indices: []const u32,
        vertex_count: usize,
        rounds: usize,
    ) !IndexCodecCase {
        const buffer_bound = c.meshopt_encodeIndexBufferBound(indices.len, vertex_count);
        const buffer = try arena.alloc(u8, buffer_bound);
        const size = c.meshopt_encodeIndexBuffer(buffer.ptr, buffer.len, indices.ptr, indices.len);
        const sequence_bound = c.meshopt_encodeIndexSequenceBound(indices.len, vertex_count);
        const sequence = try arena.alloc(u8, sequence_bound);
        const sequence_size = c.meshopt_encodeIndexSequence(
            sequence.ptr,
            sequence.len,
            indices.ptr,
            indices.len,
        );
        const stream = try arena.dupe(u8, buffer[0..size]);
        const sequence_stream = try arena.dupe(u8, sequence[0..sequence_size]);
        const halves = try arena.alloc(u16, indices.len);
        const words = try arena.alloc(u32, indices.len);
        return .{
            .encode = .{
                .indices = indices,
                .buffer = buffer,
                .rounds = rounds,
                .sequence = false,
            },
            .decode32 = .{ .stream = stream, .destination = words, .rounds = rounds },
            .decode16 = .{ .stream = stream, .destination = halves, .rounds = rounds },
            .encode_sequence = .{
                .indices = indices,
                .buffer = sequence,
                .rounds = rounds,
                .sequence = true,
            },
            .decode_sequence = .{
                .stream = sequence_stream,
                .destination = words,
                .rounds = rounds,
            },
        };
    }
};

const MeshletCodecCase = struct {
    encode: Encode,
    decode_bytes: Decode(u32, u8, false),
    decode_words: Decode(u16, u32, false),
    decode_raw: Decode(u32, u32, true),

    const vertices_max = 64;
    const triangles_max = 96;

    const Encode = struct {
        meshlets: []const c.Meshlet,
        vertices: []const u32,
        triangles: []const u8,
        buffer: []u8,
        rounds: usize,

        fn original(self: *Encode) void {
            for (0..self.rounds) |_| for (self.meshlets) |m| {
                const size = c.meshopt_encodeMeshlet(
                    self.buffer.ptr,
                    self.buffer.len,
                    self.vertices[m.vertex_offset..].ptr,
                    m.vertex_count,
                    self.triangles[m.triangle_offset..].ptr,
                    m.triangle_count,
                );
                std.mem.doNotOptimizeAway(size);
            };
        }

        fn port(self: *Encode) void {
            for (0..self.rounds) |_| for (self.meshlets) |m| {
                const size = @call(.never_inline, mo.encodeMeshlet, .{
                    self.buffer,
                    self.vertices[m.vertex_offset..][0..m.vertex_count],
                    self.triangles[m.triangle_offset..][0 .. m.triangle_count * 3],
                }) catch unreachable;
                std.mem.doNotOptimizeAway(size);
            };
        }
    };

    /// Each meshlet as its vertex count, triangle count and 2-byte size,
    /// then its encoding, as the original's codec benchmark packs them.
    fn Decode(comptime V: type, comptime T: type, comptime raw: bool) type {
        return struct {
            packed_meshlets: []const u8,
            rounds: usize,

            const Self = @This();
            const triangle_size = if (T == u8) 3 else 4;

            fn original(self: *Self) void {
                var vertices: [256]V = undefined;
                var triangles: [256 * 4]T = undefined;
                for (0..self.rounds) |_| {
                    var p = self.packed_meshlets;
                    while (p.len > 0) {
                        const size = @as(usize, p[2]) | @as(usize, p[3]) << 8;
                        const rc = if (raw) c.meshopt_decodeMeshletRaw(
                            &vertices,
                            p[0],
                            &triangles,
                            p[1],
                            p[4..].ptr,
                            size,
                        ) else c.meshopt_decodeMeshlet(
                            &vertices,
                            p[0],
                            @sizeOf(V),
                            &triangles,
                            p[1],
                            triangle_size,
                            p[4..].ptr,
                            size,
                        );
                        std.debug.assert(rc == 0);
                        p = p[4 + size ..];
                    }
                }
                std.mem.doNotOptimizeAway(&vertices);
                std.mem.doNotOptimizeAway(&triangles);
            }

            fn port(self: *Self) void {
                var vertices: [256]V = undefined;
                var triangles: [256 * 4]T = undefined;
                for (0..self.rounds) |_| {
                    var p = self.packed_meshlets;
                    while (p.len > 0) {
                        const size = @as(usize, p[2]) | @as(usize, p[3]) << 8;
                        const stream = p[4..][0..size];
                        if (raw) {
                            mo.decodeMeshletRaw(&vertices, p[0], &triangles, p[1], stream) catch
                                unreachable;
                        } else {
                            mo.decodeMeshlet(V, T, &vertices, p[0], &triangles, p[1], stream) catch
                                unreachable;
                        }
                        p = p[4 + size ..];
                    }
                }
                std.mem.doNotOptimizeAway(&vertices);
                std.mem.doNotOptimizeAway(&triangles);
            }
        };
    }

    fn init(
        arena: std.mem.Allocator,
        mesh: meshes.Mesh,
        indices: []const u32,
        rounds: usize,
    ) !MeshletCodecCase {
        const meshlets_max = c.meshopt_buildMeshletsBound(indices.len, vertices_max, triangles_max);
        const meshlets = try arena.alloc(c.Meshlet, meshlets_max);
        const vertices = try arena.alloc(u32, indices.len);
        const triangles = try arena.alloc(u8, indices.len);
        const count = c.meshopt_buildMeshlets(
            meshlets.ptr,
            vertices.ptr,
            triangles.ptr,
            indices.ptr,
            indices.len,
            @ptrCast(mesh.vertices.ptr),
            mesh.vertices.len,
            @sizeOf(Vertex),
            vertices_max,
            triangles_max,
            0,
        );
        for (meshlets[0..count]) |m| {
            c.meshopt_optimizeMeshletLevel(
                vertices[m.vertex_offset..].ptr,
                m.vertex_count,
                triangles[m.triangle_offset..].ptr,
                m.triangle_count,
                3,
            );
        }

        const bound = c.meshopt_encodeMeshletBound(vertices_max, triangles_max);
        const buffer = try arena.alloc(u8, bound);
        var packed_meshlets: std.ArrayList(u8) = .empty;
        for (meshlets[0..count]) |m| {
            const size = c.meshopt_encodeMeshlet(
                buffer.ptr,
                buffer.len,
                vertices[m.vertex_offset..].ptr,
                m.vertex_count,
                triangles[m.triangle_offset..].ptr,
                m.triangle_count,
            );
            try packed_meshlets.appendSlice(arena, &.{
                @intCast(m.vertex_count),
                @intCast(m.triangle_count),
                @truncate(size),
                @truncate(size >> 8),
            });
            try packed_meshlets.appendSlice(arena, buffer[0..size]);
        }

        return .{
            .encode = .{
                .meshlets = meshlets[0..count],
                .vertices = vertices,
                .triangles = triangles,
                .buffer = buffer,
                .rounds = rounds,
            },
            .decode_bytes = .{ .packed_meshlets = packed_meshlets.items, .rounds = rounds },
            .decode_words = .{ .packed_meshlets = packed_meshlets.items, .rounds = rounds },
            .decode_raw = .{ .packed_meshlets = packed_meshlets.items, .rounds = rounds },
        };
    }
};
