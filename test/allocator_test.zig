//! The allocation cache against the original's: functions with several
//! scratch allocations, through the port's `AllocatorCache` and through the
//! original's `meshopt_setAllocatorCache`, each over an allocator that
//! records every call, on the same inputs and blocks: the demo mesh and
//! fuzzed meshes, from no blocks to 64, from 16 bytes to more than a
//! function needs. Both allocators must see the same calls (each request's
//! size, and which request each free returns), and the functions must give
//! the same outputs.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Mesh = common.Mesh;
const Vertex = common.Vertex;

/// A cache's blocks, as both sides take them.
const Blocks = struct {
    count: usize,
    size: usize,
};

/// Requests above this are refused on both sides, as memory would refuse a
/// cache too large for it.
const request_max = 1 << 30;

/// One call to the allocator behind a cache.
const Event = extern struct {
    kind: enum(usize) { alloc, free },
    /// The bytes an allocation asks for, or the number of the request whose
    /// memory a free returns, counting from 0.
    value: usize,
};

/// The calls one side's allocator saw, in order.
const Record = struct {
    events: [capacity]Event = undefined,
    event_count: usize = 0,
    /// The address each request returned, by request number: 0 for a
    /// refused request, or once its memory is freed.
    addresses: [capacity]usize = undefined,
    request_count: usize = 0,

    const capacity = 256;

    fn slice(self: *const Record) []const Event {
        return self.events[0..self.event_count];
    }

    fn requested(self: *Record, len: usize, address: usize) void {
        self.events[self.event_count] = .{ .kind = .alloc, .value = len };
        self.event_count += 1;
        self.addresses[self.request_count] = address;
        self.request_count += 1;
    }

    fn freed(self: *Record, address: usize) void {
        const request = for (0..self.request_count) |i| {
            const newest = self.request_count - 1 - i;
            if (self.addresses[newest] == address) break newest;
        } else @panic("a free of memory that no request returned");
        self.addresses[request] = 0;
        self.events[self.event_count] = .{ .kind = .free, .value = request };
        self.event_count += 1;
    }

    /// An allocator that records each call and passes it on to the testing
    /// allocator: the port's side.
    fn allocator(self: *Record) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Record = @ptrCast(@alignCast(context));
        const memory = if (len > request_max) null else gpa.rawAlloc(len, alignment, ret);
        self.requested(len, @intFromPtr(memory));
        return memory;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Record = @ptrCast(@alignCast(context));
        self.freed(@intFromPtr(memory.ptr));
        gpa.rawFree(memory, alignment, ret);
    }
};

/// What the original's callbacks saw: C callbacks take no context.
var original_record: Record = .{};

fn originalAllocate(size: usize) callconv(.c) ?*anyopaque {
    const memory = if (size > request_max) null else std.c.malloc(size);
    original_record.requested(size, @intFromPtr(memory));
    return memory;
}

fn originalDeallocate(memory: ?*anyopaque) callconv(.c) void {
    original_record.freed(@intFromPtr(memory));
    std.c.free(memory);
}

/// The original's side: its cache of `blocks` over the recording
/// callbacks. `c.reference_resetAllocator` ends it, which frees the cache
/// through the callbacks.
fn beginOriginal(blocks: Blocks) void {
    original_record = .{};
    c.meshopt_setAllocator(originalAllocate, originalDeallocate);
    c.meshopt_setAllocatorCache(blocks.count, blocks.size);
}

/// The port's side: its cache of the same blocks over a recording
/// allocator, and a handle of it.
const PortSide = struct {
    record: Record = .{},
    cache: mo.AllocatorCache = undefined,
    local: mo.AllocatorCache.Local = undefined,

    /// The allocator for the function's scratch memory.
    fn begin(self: *PortSide, blocks: Blocks) !std.mem.Allocator {
        self.cache = try .init(self.record.allocator(), blocks.count, blocks.size);
        self.local = .init(&self.cache);
        return self.local.allocator();
    }

    fn end(self: *PortSide) void {
        self.cache.deinit();
    }

    fn expectSameCalls(self: *const PortSide) !void {
        const want = original_record.slice();
        try common.expectSame(Event, "allocator calls", want, self.record.slice());
    }
};

fn checkVertexFetch(mesh: Mesh, in_place: bool, blocks: Blocks) !void {
    const want_indices = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(want_indices);
    const got_indices = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(got_indices);
    const want_vertices = try gpa.dupe(Vertex, mesh.vertices);
    defer gpa.free(want_vertices);
    const got_vertices = try gpa.dupe(Vertex, mesh.vertices);
    defer gpa.free(got_vertices);

    beginOriginal(blocks);
    const want = c.meshopt_optimizeVertexFetch(
        want_vertices.ptr,
        want_indices.ptr,
        want_indices.len,
        if (in_place) want_vertices.ptr else mesh.vertices.ptr,
        mesh.vertices.len,
        @sizeOf(Vertex),
    );
    c.reference_resetAllocator();

    var port: PortSide = .{};
    const got = got: {
        const scratch = try port.begin(blocks);
        defer port.end();
        const source: []const Vertex = if (in_place) got_vertices else mesh.vertices;
        break :got try mo.optimizeVertexFetch(
            u32,
            scratch,
            std.mem.sliceAsBytes(got_vertices),
            got_indices,
            std.mem.sliceAsBytes(source),
            @sizeOf(Vertex),
        );
    };

    try port.expectSameCalls();
    try common.expectSameValue(usize, "vertices used", want, got);
    try common.expectSame(u32, "indices", want_indices, got_indices);
    try common.expectSame(Vertex, "vertices", want_vertices, got_vertices);
}

fn checkVertexCache(mesh: Mesh, in_place: bool, blocks: Blocks) !void {
    const want = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(want);
    const got = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(got);

    beginOriginal(blocks);
    c.meshopt_optimizeVertexCache(
        want.ptr,
        if (in_place) want.ptr else mesh.indices.ptr,
        want.len,
        mesh.vertices.len,
    );
    c.reference_resetAllocator();

    var port: PortSide = .{};
    {
        const scratch = try port.begin(blocks);
        defer port.end();
        const source: []const u32 = if (in_place) got else mesh.indices;
        try mo.optimizeVertexCache(u32, scratch, got, source, mesh.vertices.len);
    }

    try port.expectSameCalls();
    try common.expectSame(u32, "indices", want, got);
}

fn checkOverdraw(mesh: Mesh, blocks: Blocks) !void {
    const indices = try common.vertexCacheOptimized(mesh.indices, mesh.vertices.len);
    defer gpa.free(indices);
    const want = try gpa.alloc(u32, indices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, indices.len);
    defer gpa.free(got);
    const threshold = 1.05;

    beginOriginal(blocks);
    c.meshopt_optimizeOverdraw(
        want.ptr,
        indices.ptr,
        indices.len,
        @ptrCast(mesh.vertices.ptr),
        mesh.vertices.len,
        @sizeOf(Vertex),
        threshold,
    );
    c.reference_resetAllocator();

    var port: PortSide = .{};
    {
        const scratch = try port.begin(blocks);
        defer port.end();
        const positions = common.positionsOf(mesh.vertices);
        try mo.optimizeOverdraw(u32, scratch, got, indices, positions, threshold);
    }

    try port.expectSameCalls();
    try common.expectSame(u32, "indices", want, got);
}

/// The simplifier, with each option that changes its scratch memory:
/// `sparse` builds and frees a remap of the used vertices, `prune` its
/// components.
fn checkSimplify(mesh: Mesh, options: mo.SimplifyOptions, target: usize, blocks: Blocks) !void {
    const want = try gpa.alloc(u32, mesh.indices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, mesh.indices.len);
    defer gpa.free(got);
    const target_error = 1e-2;

    beginOriginal(blocks);
    const want_count = c.meshopt_simplify(
        want.ptr,
        mesh.indices.ptr,
        mesh.indices.len,
        @ptrCast(mesh.vertices.ptr),
        mesh.vertices.len,
        @sizeOf(Vertex),
        target,
        target_error,
        @bitCast(options),
        null,
    );
    c.reference_resetAllocator();

    var port: PortSide = .{};
    const got_count = got: {
        const scratch = try port.begin(blocks);
        defer port.end();
        break :got try mo.simplify(
            u32,
            scratch,
            got,
            mesh.indices,
            common.positionsOf(mesh.vertices),
            target,
            target_error,
            options,
            null,
        );
    };

    try port.expectSameCalls();
    try common.expectSameValue(usize, "index count", want_count, got_count);
    try common.expectSame(u32, "indices", want[0..want_count], got[0..got_count]);
}

const simplify_options = [_]mo.SimplifyOptions{
    .{},
    .{ .sparse = true },
    .{ .prune = true },
    .{ .sparse = true, .prune = true },
};

/// From no blocks to more than any function here needs on the demo mesh,
/// around the sizes of its scratch arrays, most not multiples of 16.
const demo_blocks = [_]Blocks{
    .{ .count = 0, .size = 0 },
    .{ .count = 0, .size = 4096 },
    .{ .count = 1, .size = 16 },
    .{ .count = 2, .size = 47 },
    .{ .count = 1, .size = 4000 },
    .{ .count = 3, .size = 20_007 },
    .{ .count = 1, .size = 100_003 },
    .{ .count = 2, .size = 400_009 },
    .{ .count = 64, .size = 1 << 18 },
    .{ .count = 1, .size = 1 << 24 },
};

test "scratch memory goes through both caches alike on the demo mesh" {
    var mesh = try common.pirate();
    defer mesh.deinit(gpa);
    const target = mesh.indices.len / 3 / 10 * 3;
    for (demo_blocks) |blocks| {
        for ([_]bool{ false, true }) |in_place| {
            try checkVertexFetch(mesh, in_place, blocks);
            try checkVertexCache(mesh, in_place, blocks);
        }
        try checkOverdraw(mesh, blocks);
        for (simplify_options) |options| try checkSimplify(mesh, options, target, blocks);
    }
}

test "the caches serve what fits: all of the demo mesh's scratch in a large block, some in less" {
    var mesh = try common.pirate();
    defer mesh.deinit(gpa);
    const target = mesh.indices.len / 3 / 10 * 3;
    const options: mo.SimplifyOptions = .{ .sparse = true, .prune = true };

    // The allocator behind the cache sees only the cache's own memory.
    try checkSimplify(mesh, options, target, .{ .count = 1, .size = 1 << 24 });
    try std.testing.expectEqual(2, original_record.event_count);
    // A block too small for any array sends each one on: a request and a
    // free each, around the cache's own two calls.
    try checkSimplify(mesh, options, target, .{ .count = 1, .size = 16 });
    const each_sent = original_record.event_count;
    try std.testing.expect(each_sent > 2 + 2 * 10);
    // A block for some of them sends on the rest.
    try checkSimplify(mesh, options, target, .{ .count = 1, .size = 100_003 });
    try std.testing.expect(original_record.event_count > 2);
    try std.testing.expect(original_record.event_count < each_sent);
}

test "scratch memory goes through both caches alike on fuzzed meshes and blocks" {
    try common.fuzz("allocation cache", 0, fuzzCache);
}

fn fuzzCache(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    // At least a triangle, so that no scratch array is empty: the port asks
    // the allocator for none of those, the original for each.
    const vertex_count = rng.intRangeAtMost(u32, 1, 300);
    const triangle_count = rng.intRangeAtMost(u32, 1, 600);
    var mesh = try meshes.random(gpa, rng.int(u64), vertex_count, triangle_count);
    defer mesh.deinit(gpa);

    const count = rng.uintAtMost(usize, mo.AllocatorCache.block_count_max);
    const size = if (count == 0)
        rng.uintAtMost(usize, 100)
    else
        rng.intRangeAtMost(usize, 16, @as(usize, 16) << rng.uintAtMost(u6, 12));
    const blocks: Blocks = .{ .count = count, .size = size };

    for ([_]bool{ false, true }) |in_place| {
        try checkVertexFetch(mesh, in_place, blocks);
        try checkVertexCache(mesh, in_place, blocks);
    }
    try checkOverdraw(mesh, blocks);
    const options = simplify_options[rng.uintLessThan(usize, simplify_options.len)];
    const target = rng.uintAtMost(usize, triangle_count) * 3;
    try checkSimplify(mesh, options, target, blocks);
}

test "a cache too large for memory fails alike, its size clamped on overflow" {
    const max = std.math.maxInt(usize);
    const too_large = [_]Blocks{
        .{ .count = 64, .size = max },
        .{ .count = 2, .size = max / 2 + 1 },
        .{ .count = 1, .size = 1 << 40 },
    };
    for (too_large) |blocks| {
        beginOriginal(blocks);
        c.reference_resetAllocator();

        var record: Record = .{};
        const result = mo.AllocatorCache.init(record.allocator(), blocks.count, blocks.size);
        try std.testing.expectError(error.OutOfMemory, result);
        try common.expectSame(Event, "allocator calls", original_record.slice(), record.slice());
    }
}

/// Runs the allocating functions the other tests do not run through a cache
/// on `mesh`, through `a`, and after each `check.empty()`, which fails
/// unless `a` has nothing live.
fn libraryCalls(mesh: Mesh, a: std.mem.Allocator, check: anytype) !void {
    const positions = common.positionsOf(mesh.vertices);
    const floats = common.floatsOf(mesh.vertices);
    const n = mesh.indices.len;
    const vertex_count = mesh.vertices.len;

    const out = try gpa.alloc(u32, n * 2);
    defer gpa.free(out);
    const reorder = try gpa.alloc(u32, n);
    defer gpa.free(reorder);
    const per_vertex = try gpa.alloc(u32, vertex_count);
    defer gpa.free(per_vertex);
    const normals = try gpa.alloc(f32, n * 3);
    defer gpa.free(normals);
    const tangents = try gpa.alloc(f32, n * 4);
    defer gpa.free(tangents);
    const stream: mo.Stream = .{
        .data = std.mem.sliceAsBytes(mesh.vertices),
        .size = 12,
        .stride = @sizeOf(Vertex),
    };

    try mo.spatialSortTriangles(u32, a, out[0..n], mesh.indices, positions);
    try check.empty();
    try mo.spatialClusterPoints(a, per_vertex, positions, 64);
    try check.empty();
    try mo.generatePositionRemap(a, per_vertex, positions);
    try check.empty();
    _ = try mo.filterIndexBuffer(u32, a, out[0..n], mesh.indices, vertex_count, stream);
    try check.empty();
    try mo.generateShadowIndexBuffer(u32, a, out[0..n], mesh.indices, vertex_count, stream);
    try check.empty();
    try mo.generateAdjacencyIndexBuffer(u32, a, out[0 .. n * 2], mesh.indices, positions);
    try check.empty();
    _ = try mo.generateProvokingIndexBuffer(u32, a, out[0..n], reorder, mesh.indices, vertex_count);
    try check.empty();
    _ = try mo.stripify(u32, a, out, mesh.indices, vertex_count, 0);
    try check.empty();
    try mo.optimizeVertexCacheStrip(u32, a, out[0..n], mesh.indices, vertex_count);
    try check.empty();
    _ = try mo.analyzeOverdraw(u32, a, mesh.indices, positions);
    try check.empty();
    _ = try mo.analyzeCoverage(u32, a, mesh.indices, positions);
    try check.empty();
    try mo.generateNormals(u32, a, normals, mesh.indices, positions, 1.0, 1.0);
    try check.empty();
    const normal_view: mo.VertexFloats = .init(floats[3..], common.vertex_floats);
    const uv_view: mo.VertexFloats = .init(floats[6..], common.vertex_floats);
    try mo.generateTangents(u32, a, tangents, mesh.indices, positions, normal_view, uv_view, .{});
    try check.empty();

    const bound = mo.buildMeshletsBound(n, 64, 124);
    const meshlets = try gpa.alloc(mo.Meshlet, bound);
    defer gpa.free(meshlets);
    const meshlet_vertices = try gpa.alloc(u32, n);
    defer gpa.free(meshlet_vertices);
    const meshlet_triangles = try gpa.alloc(u8, n);
    defer gpa.free(meshlet_triangles);
    _ = try mo.buildMeshlets(
        u32,
        a,
        meshlets,
        meshlet_vertices,
        meshlet_triangles,
        mesh.indices,
        positions,
        64,
        124,
        0.25,
    );
    try check.empty();
    _ = try mo.buildMeshletsSpatial(
        u32,
        a,
        meshlets,
        meshlet_vertices,
        meshlet_triangles,
        mesh.indices,
        positions,
        64,
        32,
        124,
        0.5,
    );
    try check.empty();

    const attributes: mo.VertexFloats = .init(floats[3..], common.vertex_floats);
    const weights = [_]f32{ 0.5, 0.5, 0.5, 1, 1 };
    const target = n / 4;
    _ = try mo.simplifyWithAttributes(
        u32,
        a,
        out[0..n],
        mesh.indices,
        positions,
        attributes,
        &weights,
        null,
        target,
        1e-2,
        .{},
        null,
    );
    try check.empty();
    _ = try mo.simplifySloppy(u32, a, out[0..n], mesh.indices, positions, null, target, 1e-2, null);
    try check.empty();
    _ = try mo.simplifyPrune(u32, a, out[0..n], mesh.indices, positions, 1e-2);
    try check.empty();
    _ = try mo.simplifyPoints(a, per_vertex, positions, null, 1, vertex_count / 4);
    try check.empty();

    const remesh_bound = try mo.remesh(u32, a, null, mesh.indices, positions, 32, .{});
    try check.empty();
    const triangles = try gpa.alloc(f32, remesh_bound * 9);
    defer gpa.free(triangles);
    _ = try mo.remesh(u32, a, triangles, mesh.indices, positions, 32, .{});
    try check.empty();
}

test "the library's functions free newest first, as cache handles need" {
    var mesh = try common.pirate();
    defer mesh.deinit(gpa);

    // A handle asserts that each free is of the newest allocation in its
    // block, and gives the block back once all of it is free.
    var cache: mo.AllocatorCache = try .init(std.heap.page_allocator, 1, 64 << 20);
    defer cache.deinit();
    var local: mo.AllocatorCache.Local = .init(&cache);
    const Handle = struct {
        local: *mo.AllocatorCache.Local,
        fn empty(self: @This()) !void {
            try std.testing.expectEqual(null, self.local.block);
        }
    };
    try libraryCalls(mesh, local.allocator(), Handle{ .local = &local });
}
