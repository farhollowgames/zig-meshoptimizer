//! Oracle tests of the port's index functions with `u16` indices: each
//! against the original's C++ template for 16-bit indices, which widens
//! the indices through `meshopt_IndexAdapter`, runs the 32-bit function and
//! cuts the results back, on the demo mesh, a mesh whose indices reach the
//! top of the 16-bit range, and fuzzed meshes.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;
const vertex_floats = common.vertex_floats;

/// A mesh with 16-bit indices: the vertices of `mesh` and its indices cut
/// to 16 bits. The caller frees `indices`.
const Mesh16 = struct {
    vertices: []const Vertex,
    indices: []u16,

    fn of(mesh: common.Mesh) !Mesh16 {
        std.debug.assert(mesh.vertices.len <= 1 << 16);
        const indices = try gpa.alloc(u16, mesh.indices.len);
        for (indices, mesh.indices) |*narrow, index| narrow.* = @intCast(index);
        return .{ .vertices = mesh.vertices, .indices = indices };
    }

    fn deinit(self: Mesh16) void {
        gpa.free(self.indices);
    }

    fn floats(self: Mesh16) []const f32 {
        return common.floatsOf(self.vertices);
    }

    fn positions(self: Mesh16) mo.VertexFloats {
        return common.positionsOf(self.vertices);
    }

    fn bytes(self: Mesh16) []const u8 {
        return std.mem.sliceAsBytes(self.vertices);
    }
};

/// Two outputs of `n` items of `T`, the original's and the port's, filled
/// alike, so items that neither side writes compare equal.
fn Outputs(comptime T: type) type {
    return struct {
        want: []T,
        got: []T,

        const Self = @This();

        fn init(n: usize) !Self {
            const want = try gpa.alloc(T, n);
            errdefer gpa.free(want);
            const got = try gpa.alloc(T, n);
            @memset(std.mem.sliceAsBytes(want), 0xcd);
            @memset(std.mem.sliceAsBytes(got), 0xcd);
            return .{ .want = want, .got = got };
        }

        fn deinit(self: Self) void {
            gpa.free(self.want);
            gpa.free(self.got);
        }

        fn expectSame(self: Self, what: []const u8) !void {
            try common.expectSame(T, what, self.want, self.got);
        }

        /// Compares the first `n` items only: the original's 16-bit
        /// versions write their whole output from a scratch copy, past the
        /// `n` they fill.
        fn expectSameFirst(self: Self, what: []const u8, n: usize) !void {
            try common.expectSame(T, what, self.want[0..n], self.got[0..n]);
        }
    };
}

const expectSameFloats = common.expectSameAnyNan;

fn expectSameBytes(what: []const u8, want: anytype, got: anytype) !void {
    try common.expectSame(u8, what, std.mem.asBytes(&want), std.mem.asBytes(&got));
}

const stride = @sizeOf(Vertex);
const float_stride = stride / @sizeOf(f32);

fn streams(mesh: Mesh16) [3]mo.Stream {
    const data = mesh.bytes();
    return .{
        .{ .data = data, .size = 12, .stride = stride },
        .{ .data = data[12..], .size = 12, .stride = stride },
        .{ .data = data[24..], .size = 8, .stride = stride },
    };
}

fn cStreams(mesh: Mesh16) [3]c.Stream {
    var result: [3]c.Stream = undefined;
    for (&result, streams(mesh)) |*r, s| {
        r.* = .{ .data = s.data.ptr, .size = s.size, .stride = s.stride };
    }
    return result;
}

fn checkIndexGeneration(mesh: Mesh16) !void {
    const n = mesh.indices.len;
    const vertex_count = mesh.vertices.len;
    const ptr = mesh.indices.ptr;
    const positions_ptr = mesh.floats().ptr;

    // Remaps, with and without the indices.
    var remap: Outputs(u32) = try .init(vertex_count);
    defer remap.deinit();
    const want_unique = c.reference16_generateVertexRemap(
        remap.want.ptr,
        ptr,
        n,
        positions_ptr,
        vertex_count,
        stride,
    );
    const got_unique = try mo.generateVertexRemap(
        u16,
        gpa,
        remap.got,
        mesh.indices,
        mesh.bytes(),
        stride,
    );
    try common.expectSameValue(usize, "generateVertexRemap count", want_unique, got_unique);
    try remap.expectSame("generateVertexRemap");

    var soup_remap: Outputs(u32) = try .init(vertex_count);
    defer soup_remap.deinit();
    _ = c.reference16_generateVertexRemap(
        soup_remap.want.ptr,
        null,
        vertex_count,
        positions_ptr,
        vertex_count,
        stride,
    );
    _ = try mo.generateVertexRemap(u16, gpa, soup_remap.got, null, mesh.bytes(), stride);
    try soup_remap.expectSame("generateVertexRemap without indices");

    const c_streams = cStreams(mesh);
    const zig_streams = streams(mesh);
    var multi: Outputs(u32) = try .init(vertex_count);
    defer multi.deinit();
    const want_multi = c.reference16_generateVertexRemapMulti(
        multi.want.ptr,
        ptr,
        n,
        vertex_count,
        &c_streams,
        3,
    );
    const got_multi = try mo.generateVertexRemapMulti(
        u16,
        gpa,
        multi.got,
        mesh.indices,
        vertex_count,
        &zig_streams,
    );
    try common.expectSameValue(usize, "generateVertexRemapMulti count", want_multi, got_multi);
    try multi.expectSame("generateVertexRemapMulti");

    // The remap applied, with the indices and as a table.
    var remapped: Outputs(u16) = try .init(n);
    defer remapped.deinit();
    c.reference16_remapIndexBuffer(remapped.want.ptr, ptr, n, remap.want.ptr);
    mo.remapIndexBuffer(u16, remapped.got, mesh.indices, remap.got);
    try remapped.expectSame("remapIndexBuffer");

    var table: Outputs(u16) = try .init(vertex_count);
    defer table.deinit();
    c.reference16_remapIndexBuffer(table.want.ptr, null, vertex_count, soup_remap.want.ptr);
    mo.remapIndexBuffer(u16, table.got, null, soup_remap.got);
    try table.expectSame("remapIndexBuffer without indices");

    // Filtered and shadow index buffers, on positions and on every stream.
    const position_stream = zig_streams[0];
    var filtered: Outputs(u16) = try .init(n);
    defer filtered.deinit();
    const want_filtered = c.reference16_filterIndexBuffer(
        filtered.want.ptr,
        ptr,
        n,
        positions_ptr,
        vertex_count,
        12,
        stride,
    );
    const got_filtered = try mo.filterIndexBuffer(
        u16,
        gpa,
        filtered.got,
        mesh.indices,
        vertex_count,
        position_stream,
    );
    try common.expectSameValue(usize, "filterIndexBuffer count", want_filtered, got_filtered);
    try filtered.expectSameFirst("filterIndexBuffer", want_filtered);

    var filtered_multi: Outputs(u16) = try .init(n);
    defer filtered_multi.deinit();
    const want_filtered_multi = c.reference16_filterIndexBufferMulti(
        filtered_multi.want.ptr,
        ptr,
        n,
        vertex_count,
        &c_streams,
        3,
    );
    const got_filtered_multi = try mo.filterIndexBufferMulti(
        u16,
        gpa,
        filtered_multi.got,
        mesh.indices,
        vertex_count,
        &zig_streams,
    );
    try common.expectSameValue(
        usize,
        "filterIndexBufferMulti count",
        want_filtered_multi,
        got_filtered_multi,
    );
    try filtered_multi.expectSameFirst("filterIndexBufferMulti", want_filtered_multi);

    var shadow: Outputs(u16) = try .init(n);
    defer shadow.deinit();
    c.reference16_generateShadowIndexBuffer(
        shadow.want.ptr,
        ptr,
        n,
        positions_ptr,
        vertex_count,
        12,
        stride,
    );
    try mo.generateShadowIndexBuffer(
        u16,
        gpa,
        shadow.got,
        mesh.indices,
        vertex_count,
        position_stream,
    );
    try shadow.expectSame("generateShadowIndexBuffer");

    var shadow_multi: Outputs(u16) = try .init(n);
    defer shadow_multi.deinit();
    c.reference16_generateShadowIndexBufferMulti(
        shadow_multi.want.ptr,
        ptr,
        n,
        vertex_count,
        &c_streams,
        3,
    );
    try mo.generateShadowIndexBufferMulti(
        u16,
        gpa,
        shadow_multi.got,
        mesh.indices,
        vertex_count,
        &zig_streams,
    );
    try shadow_multi.expectSame("generateShadowIndexBufferMulti");

    // Patch index buffers.
    var adjacency: Outputs(u16) = try .init(n * 2);
    defer adjacency.deinit();
    c.reference16_generateAdjacencyIndexBuffer(
        adjacency.want.ptr,
        ptr,
        n,
        positions_ptr,
        vertex_count,
        stride,
    );
    try mo.generateAdjacencyIndexBuffer(u16, gpa, adjacency.got, mesh.indices, mesh.positions());
    try adjacency.expectSame("generateAdjacencyIndexBuffer");

    var tessellation: Outputs(u16) = try .init(n * 4);
    defer tessellation.deinit();
    c.reference16_generateTessellationIndexBuffer(
        tessellation.want.ptr,
        ptr,
        n,
        positions_ptr,
        vertex_count,
        stride,
    );
    try mo.generateTessellationIndexBuffer(
        u16,
        gpa,
        tessellation.got,
        mesh.indices,
        mesh.positions(),
    );
    try tessellation.expectSame("generateTessellationIndexBuffer");

    // Every new vertex needs a 16-bit index.
    if (vertex_count + n / 3 <= 1 << 16) {
        var provoking: Outputs(u16) = try .init(n);
        defer provoking.deinit();
        var reorder: Outputs(u32) = try .init(vertex_count + n / 3);
        defer reorder.deinit();
        const want_reorder = c.reference16_generateProvokingIndexBuffer(
            provoking.want.ptr,
            reorder.want.ptr,
            ptr,
            n,
            vertex_count,
        );
        const got_reorder = try mo.generateProvokingIndexBuffer(
            u16,
            gpa,
            provoking.got,
            reorder.got,
            mesh.indices,
            vertex_count,
        );
        try common.expectSameValue(
            usize,
            "generateProvokingIndexBuffer count",
            want_reorder,
            got_reorder,
        );
        try provoking.expectSame("generateProvokingIndexBuffer");
        try reorder.expectSame("generateProvokingIndexBuffer reorder");
    }
}

fn checkOptimizers(mesh: Mesh16) !void {
    const n = mesh.indices.len;
    const vertex_count = mesh.vertices.len;
    const ptr = mesh.indices.ptr;
    const positions_ptr = mesh.floats().ptr;

    var cache: Outputs(u16) = try .init(n);
    defer cache.deinit();
    c.reference16_optimizeVertexCache(cache.want.ptr, ptr, n, vertex_count);
    try mo.optimizeVertexCache(u16, gpa, cache.got, mesh.indices, vertex_count);
    try cache.expectSame("optimizeVertexCache");

    // In place too.
    const in_place = try gpa.dupe(u16, mesh.indices);
    defer gpa.free(in_place);
    try mo.optimizeVertexCache(u16, gpa, in_place, in_place, vertex_count);
    try common.expectSame(u16, "optimizeVertexCache in place", cache.want, in_place);

    var strip: Outputs(u16) = try .init(n);
    defer strip.deinit();
    c.reference16_optimizeVertexCacheStrip(strip.want.ptr, ptr, n, vertex_count);
    try mo.optimizeVertexCacheStrip(u16, gpa, strip.got, mesh.indices, vertex_count);
    try strip.expectSame("optimizeVertexCacheStrip");

    var fifo: Outputs(u16) = try .init(n);
    defer fifo.deinit();
    c.reference16_optimizeVertexCacheFifo(fifo.want.ptr, ptr, n, vertex_count, 16);
    try mo.optimizeVertexCacheFifo(u16, gpa, fifo.got, mesh.indices, vertex_count, 16);
    try fifo.expectSame("optimizeVertexCacheFifo");

    var overdraw: Outputs(u16) = try .init(n);
    defer overdraw.deinit();
    c.reference16_optimizeOverdraw(
        overdraw.want.ptr,
        cache.want.ptr,
        n,
        positions_ptr,
        vertex_count,
        stride,
        1.05,
    );
    try mo.optimizeOverdraw(u16, gpa, overdraw.got, cache.want, mesh.positions(), 1.05);
    try overdraw.expectSame("optimizeOverdraw");

    var fetch_remap: Outputs(u32) = try .init(vertex_count);
    defer fetch_remap.deinit();
    const want_used = c.reference16_optimizeVertexFetchRemap(
        fetch_remap.want.ptr,
        ptr,
        n,
        vertex_count,
    );
    const got_used = mo.optimizeVertexFetchRemap(u16, fetch_remap.got, mesh.indices, vertex_count);
    try common.expectSameValue(usize, "optimizeVertexFetchRemap count", want_used, got_used);
    try fetch_remap.expectSame("optimizeVertexFetchRemap");

    var fetch_indices: Outputs(u16) = try .init(n);
    defer fetch_indices.deinit();
    @memcpy(fetch_indices.want, mesh.indices);
    @memcpy(fetch_indices.got, mesh.indices);
    var fetch_vertices: Outputs(Vertex) = try .init(vertex_count);
    defer fetch_vertices.deinit();
    const want_fetched = c.reference16_optimizeVertexFetch(
        fetch_vertices.want.ptr,
        fetch_indices.want.ptr,
        n,
        mesh.vertices.ptr,
        vertex_count,
        stride,
    );
    const got_fetched = try mo.optimizeVertexFetch(
        u16,
        gpa,
        std.mem.sliceAsBytes(fetch_vertices.got),
        fetch_indices.got,
        mesh.bytes(),
        stride,
    );
    try common.expectSameValue(usize, "optimizeVertexFetch count", want_fetched, got_fetched);
    try fetch_indices.expectSame("optimizeVertexFetch indices");
    try common.expectSame(
        u8,
        "optimizeVertexFetch vertices",
        std.mem.sliceAsBytes(fetch_vertices.want),
        std.mem.sliceAsBytes(fetch_vertices.got),
    );

    // Strips, with and without restart indices, and back.
    for ([_]u16{ 0, 0xffff }) |restart| {
        const bound = mo.stripifyBound(n);
        var stripped: Outputs(u16) = try .init(bound);
        defer stripped.deinit();
        const want_strip = c.reference16_stripify(
            stripped.want.ptr,
            cache.want.ptr,
            n,
            vertex_count,
            restart,
        );
        const got_strip = try mo.stripify(
            u16,
            gpa,
            stripped.got,
            cache.want,
            vertex_count,
            restart,
        );
        try common.expectSameValue(usize, "stripify count", want_strip, got_strip);
        try stripped.expectSameFirst("stripify", want_strip);

        var list: Outputs(u16) = try .init(mo.unstripifyBound(want_strip));
        defer list.deinit();
        const want_list = c.reference16_unstripify(
            list.want.ptr,
            stripped.want.ptr,
            want_strip,
            restart,
        );
        const got_list = mo.unstripify(u16, list.got, stripped.want[0..want_strip], restart);
        try common.expectSameValue(usize, "unstripify count", want_list, got_list);
        try list.expectSameFirst("unstripify", want_list);
    }
}

fn checkCodecsAndAnalysis(mesh: Mesh16) !void {
    const n = mesh.indices.len;
    const vertex_count = mesh.vertices.len;
    const ptr = mesh.indices.ptr;
    const positions_ptr = mesh.floats().ptr;

    for ([_]mo.IndexVersion{ .v0, .v1 }) |version| {
        // The original takes the version as a global setting, 1 by default.
        c.meshopt_encodeIndexVersion(@backingInt(version));
        defer c.meshopt_encodeIndexVersion(1);

        const bound = mo.encodeIndexBufferBound(n, vertex_count);
        var encoded: Outputs(u8) = try .init(bound);
        defer encoded.deinit();
        const want_size = c.reference16_encodeIndexBuffer(encoded.want.ptr, bound, ptr, n);
        const got_size = try mo.encodeIndexBuffer(u16, encoded.got, mesh.indices, version);
        try common.expectSameValue(usize, "encodeIndexBuffer size", want_size, got_size);
        try encoded.expectSame("encodeIndexBuffer");

        var decoded: Outputs(u16) = try .init(n);
        defer decoded.deinit();
        const rc = c.reference16_decodeIndexBuffer(
            decoded.want.ptr,
            n,
            encoded.want.ptr,
            want_size,
        );
        try std.testing.expectEqual(0, rc);
        try mo.decodeIndexBuffer(u16, decoded.got, encoded.want[0..want_size]);
        try decoded.expectSame("decodeIndexBuffer");

        const sequence_bound = mo.encodeIndexSequenceBound(n, vertex_count);
        var sequence: Outputs(u8) = try .init(sequence_bound);
        defer sequence.deinit();
        const want_sequence = c.reference16_encodeIndexSequence(
            sequence.want.ptr,
            sequence_bound,
            ptr,
            n,
        );
        const got_sequence = try mo.encodeIndexSequence(u16, sequence.got, mesh.indices, version);
        try common.expectSameValue(usize, "encodeIndexSequence size", want_sequence, got_sequence);
        try sequence.expectSame("encodeIndexSequence");

        var decoded_sequence: Outputs(u16) = try .init(n);
        defer decoded_sequence.deinit();
        const rc_sequence = c.reference16_decodeIndexSequence(
            decoded_sequence.want.ptr,
            n,
            sequence.want.ptr,
            want_sequence,
        );
        try std.testing.expectEqual(0, rc_sequence);
        try mo.decodeIndexSequence(u16, decoded_sequence.got, sequence.want[0..want_sequence]);
        try decoded_sequence.expectSame("decodeIndexSequence");
    }

    const want_cache = c.reference16_analyzeVertexCache(ptr, n, vertex_count, 16, 32, 32);
    const got_cache = try mo.analyzeVertexCache(u16, gpa, mesh.indices, vertex_count, 16, 32, 32);
    try expectSameBytes("analyzeVertexCache", want_cache, got_cache);

    const want_fetch = c.reference16_analyzeVertexFetch(ptr, n, vertex_count, stride);
    const got_fetch = try mo.analyzeVertexFetch(u16, gpa, mesh.indices, vertex_count, stride);
    try expectSameBytes("analyzeVertexFetch", want_fetch, got_fetch);

    const want_overdraw = c.reference16_analyzeOverdraw(
        ptr,
        n,
        positions_ptr,
        vertex_count,
        stride,
    );
    const got_overdraw = try mo.analyzeOverdraw(u16, gpa, mesh.indices, mesh.positions());
    try expectSameBytes("analyzeOverdraw", want_overdraw, got_overdraw);

    const want_coverage = c.reference16_analyzeCoverage(
        ptr,
        n,
        positions_ptr,
        vertex_count,
        stride,
    );
    const got_coverage = try mo.analyzeCoverage(u16, gpa, mesh.indices, mesh.positions());
    try expectSameBytes("analyzeCoverage", want_coverage, got_coverage);
}

fn checkSimplifiers(mesh: Mesh16, locks: []const u8) !void {
    const n = mesh.indices.len;
    const vertex_count = mesh.vertices.len;
    const ptr = mesh.indices.ptr;
    const floats = mesh.floats();
    const target = n / 3 / 4 * 3;
    const target_error = 1e-2;
    const weights = [_]f32{ 0.5, 0.5, 0.5, 1, 1 };
    const attributes: mo.VertexFloats = .init(floats[3..], float_stride);
    const flags: []const mo.SimplifyVertexFlags = @ptrCast(locks);

    for (
        [_]mo.SimplifyOptions{ .{}, .{ .lock_border = true, .sparse = true, .prune = true } },
    ) |options| {
        var simplified: Outputs(u16) = try .init(n);
        defer simplified.deinit();
        var want_error: f32 = -1;
        var got_error: f32 = -2;
        const want_count = c.reference16_simplify(
            simplified.want.ptr,
            ptr,
            n,
            floats.ptr,
            vertex_count,
            stride,
            target,
            target_error,
            @bitCast(options),
            &want_error,
        );
        const got_count = try mo.simplify(
            u16,
            gpa,
            simplified.got,
            mesh.indices,
            mesh.positions(),
            target,
            target_error,
            options,
            &got_error,
        );
        try common.expectSameValue(usize, "simplify count", want_count, got_count);
        try simplified.expectSameFirst("simplify", want_count);
        try expectSameFloats("simplify error", &.{want_error}, &.{got_error});

        var attributed: Outputs(u16) = try .init(n);
        defer attributed.deinit();
        const want_attributed = c.reference16_simplifyWithAttributes(
            attributed.want.ptr,
            ptr,
            n,
            floats.ptr,
            vertex_count,
            stride,
            floats[3..].ptr,
            stride,
            &weights,
            weights.len,
            locks.ptr,
            target,
            target_error,
            @bitCast(options),
            &want_error,
        );
        const got_attributed = try mo.simplifyWithAttributes(
            u16,
            gpa,
            attributed.got,
            mesh.indices,
            mesh.positions(),
            attributes,
            &weights,
            flags,
            target,
            target_error,
            options,
            &got_error,
        );
        try common.expectSameValue(
            usize,
            "simplifyWithAttributes count",
            want_attributed,
            got_attributed,
        );
        try attributed.expectSameFirst("simplifyWithAttributes", want_attributed);
        try expectSameFloats("simplifyWithAttributes error", &.{want_error}, &.{got_error});

        // Updated in place: indices and vertices both change.
        var updated: Outputs(u16) = try .init(n);
        defer updated.deinit();
        @memcpy(updated.want, mesh.indices);
        @memcpy(updated.got, mesh.indices);
        const want_vertices = try gpa.dupe(Vertex, mesh.vertices);
        defer gpa.free(want_vertices);
        const got_vertices = try gpa.dupe(Vertex, mesh.vertices);
        defer gpa.free(got_vertices);
        const want_floats: []f32 = @ptrCast(want_vertices);
        const got_floats: []f32 = @ptrCast(got_vertices);
        const want_updated = c.reference16_simplifyWithUpdate(
            updated.want.ptr,
            n,
            want_floats.ptr,
            vertex_count,
            stride,
            want_floats[3..].ptr,
            stride,
            &weights,
            weights.len,
            locks.ptr,
            target,
            target_error,
            @bitCast(options),
            &want_error,
        );
        const got_updated = try mo.simplifyWithUpdate(
            u16,
            gpa,
            updated.got,
            .init(got_floats, float_stride),
            .init(got_floats[3..], float_stride),
            &weights,
            flags,
            target,
            target_error,
            options,
            &got_error,
        );
        try common.expectSameValue(usize, "simplifyWithUpdate count", want_updated, got_updated);
        try updated.expectSame("simplifyWithUpdate");
        try expectSameFloats("simplifyWithUpdate vertices", want_floats, got_floats);
        try expectSameFloats("simplifyWithUpdate error", &.{want_error}, &.{got_error});
    }

    for ([_]bool{ false, true }) |with_locks| {
        var sloppy: Outputs(u16) = try .init(n);
        defer sloppy.deinit();
        var want_error: f32 = -1;
        var got_error: f32 = -2;
        const want_count = if (with_locks)
            c.reference16_simplifySloppyLocks(
                sloppy.want.ptr,
                ptr,
                n,
                floats.ptr,
                vertex_count,
                stride,
                locks.ptr,
                target,
                target_error,
                &want_error,
            )
        else
            c.reference16_simplifySloppy(
                sloppy.want.ptr,
                ptr,
                n,
                floats.ptr,
                vertex_count,
                stride,
                target,
                target_error,
                &want_error,
            );
        const got_count = try mo.simplifySloppy(
            u16,
            gpa,
            sloppy.got,
            mesh.indices,
            mesh.positions(),
            if (with_locks) flags else null,
            target,
            target_error,
            &got_error,
        );
        try common.expectSameValue(usize, "simplifySloppy count", want_count, got_count);
        try sloppy.expectSameFirst("simplifySloppy", want_count);
        try expectSameFloats("simplifySloppy error", &.{want_error}, &.{got_error});
    }

    var pruned: Outputs(u16) = try .init(n);
    defer pruned.deinit();
    const want_pruned = c.reference16_simplifyPrune(
        pruned.want.ptr,
        ptr,
        n,
        floats.ptr,
        vertex_count,
        stride,
        0.05,
    );
    const got_pruned = try mo.simplifyPrune(
        u16,
        gpa,
        pruned.got,
        mesh.indices,
        mesh.positions(),
        0.05,
    );
    try common.expectSameValue(usize, "simplifyPrune count", want_pruned, got_pruned);
    try pruned.expectSameFirst("simplifyPrune", want_pruned);
}

fn checkMeshlets(mesh: Mesh16) !void {
    const n = mesh.indices.len;
    const vertex_count = mesh.vertices.len;
    const ptr = mesh.indices.ptr;
    const positions_ptr = mesh.floats().ptr;
    const max_vertices = 64;
    const min_triangles = 32;
    const max_triangles = 124;

    const bound = mo.buildMeshletsBound(n, max_vertices, min_triangles);
    var meshlets: Outputs(c.Meshlet) = try .init(bound);
    defer meshlets.deinit();
    var vertices: Outputs(u32) = try .init(n);
    defer vertices.deinit();
    var triangles: Outputs(u8) = try .init(n);
    defer triangles.deinit();

    const Kind = enum { standard, scan, flex, spatial };
    for ([_]Kind{ .standard, .scan, .flex, .spatial }) |kind| {
        const got_meshlets: []mo.Meshlet = @ptrCast(meshlets.got);
        const want_count = switch (kind) {
            .standard => c.reference16_buildMeshlets(
                meshlets.want.ptr,
                vertices.want.ptr,
                triangles.want.ptr,
                ptr,
                n,
                positions_ptr,
                vertex_count,
                stride,
                max_vertices,
                max_triangles,
                0.25,
            ),
            .scan => c.reference16_buildMeshletsScan(
                meshlets.want.ptr,
                vertices.want.ptr,
                triangles.want.ptr,
                ptr,
                n,
                vertex_count,
                max_vertices,
                max_triangles,
            ),
            .flex => c.reference16_buildMeshletsFlex(
                meshlets.want.ptr,
                vertices.want.ptr,
                triangles.want.ptr,
                ptr,
                n,
                positions_ptr,
                vertex_count,
                stride,
                max_vertices,
                min_triangles,
                max_triangles,
                0.25,
                2,
            ),
            .spatial => c.reference16_buildMeshletsSpatial(
                meshlets.want.ptr,
                vertices.want.ptr,
                triangles.want.ptr,
                ptr,
                n,
                positions_ptr,
                vertex_count,
                stride,
                max_vertices,
                min_triangles,
                max_triangles,
                0.5,
            ),
        };
        const got_count = try switch (kind) {
            .standard => mo.buildMeshlets(
                u16,
                gpa,
                got_meshlets,
                vertices.got,
                triangles.got,
                mesh.indices,
                mesh.positions(),
                max_vertices,
                max_triangles,
                0.25,
            ),
            .scan => mo.buildMeshletsScan(
                u16,
                gpa,
                got_meshlets,
                vertices.got,
                triangles.got,
                mesh.indices,
                vertex_count,
                max_vertices,
                max_triangles,
            ),
            .flex => mo.buildMeshletsFlex(
                u16,
                gpa,
                got_meshlets,
                vertices.got,
                triangles.got,
                mesh.indices,
                mesh.positions(),
                max_vertices,
                min_triangles,
                max_triangles,
                0.25,
                2,
            ),
            .spatial => mo.buildMeshletsSpatial(
                u16,
                gpa,
                got_meshlets,
                vertices.got,
                triangles.got,
                mesh.indices,
                mesh.positions(),
                max_vertices,
                min_triangles,
                max_triangles,
                0.5,
            ),
        };
        try common.expectSameValue(usize, "buildMeshlets count", want_count, got_count);
        try meshlets.expectSame("buildMeshlets meshlets");
        try vertices.expectSame("buildMeshlets vertices");
        try triangles.expectSame("buildMeshlets triangles");
    }

    // Cluster bounds of runs of up to 512 triangles.
    const triangle_count = n / 3;
    var start: usize = 0;
    while (start < triangle_count) : (start += 97) {
        const end = @min(start + 300, triangle_count);
        const cluster = mesh.indices[start * 3 .. end * 3];
        const want = c.reference16_computeClusterBounds(
            cluster.ptr,
            cluster.len,
            positions_ptr,
            vertex_count,
            stride,
        );
        const got = mo.computeClusterBounds(u16, cluster, mesh.positions());
        try common.expectSameBoundsAnyNan("computeClusterBounds", want, got);
    }

    // Partitions of the triangles in runs of 30, as clusters of indices.
    const cluster_count = (triangle_count + 29) / 30;
    const counts = try gpa.alloc(u32, cluster_count);
    defer gpa.free(counts);
    for (counts, 0..) |*count, i| {
        const cluster_triangles: usize = @min(30, triangle_count - i * 30);
        count.* = @intCast(cluster_triangles * 3);
    }
    var partition: Outputs(u32) = try .init(cluster_count);
    defer partition.deinit();
    for ([_]bool{ false, true }) |with_positions| {
        const want_partitions = c.reference16_partitionClusters(
            partition.want.ptr,
            ptr,
            n,
            counts.ptr,
            cluster_count,
            if (with_positions) positions_ptr else null,
            vertex_count,
            stride,
            4,
        );
        const got_partitions = try mo.partitionClusters(
            u16,
            gpa,
            partition.got,
            mesh.indices,
            counts,
            if (with_positions) mesh.positions() else null,
            vertex_count,
            4,
        );
        try common.expectSameValue(
            usize,
            "partitionClusters count",
            want_partitions,
            got_partitions,
        );
        try partition.expectSame("partitionClusters");
    }
}

fn checkGeometry(mesh: Mesh16) !void {
    const n = mesh.indices.len;
    const vertex_count = mesh.vertices.len;
    const ptr = mesh.indices.ptr;
    const floats = mesh.floats();

    var sorted: Outputs(u16) = try .init(n);
    defer sorted.deinit();
    c.reference16_spatialSortTriangles(sorted.want.ptr, ptr, n, floats.ptr, vertex_count, stride);
    try mo.spatialSortTriangles(u16, gpa, sorted.got, mesh.indices, mesh.positions());
    try sorted.expectSame("spatialSortTriangles");

    var tangents: Outputs(f32) = try .init(n * 4);
    defer tangents.deinit();
    c.reference16_generateTangents(
        tangents.want.ptr,
        ptr,
        n,
        floats.ptr,
        vertex_count,
        stride,
        floats[3..].ptr,
        stride,
        floats[6..].ptr,
        stride,
        0,
    );
    try mo.generateTangents(
        u16,
        gpa,
        tangents.got,
        mesh.indices,
        mesh.positions(),
        .init(floats[3..], float_stride),
        .init(floats[6..], float_stride),
        .{},
    );
    try expectSameFloats("generateTangents", tangents.want, tangents.got);

    var normals: Outputs(f32) = try .init(n * 3);
    defer normals.deinit();
    c.reference16_generateNormals(
        normals.want.ptr,
        ptr,
        n,
        floats.ptr,
        vertex_count,
        stride,
        1.0,
        1.0,
    );
    try mo.generateNormals(u16, gpa, normals.got, mesh.indices, mesh.positions(), 1.0, 1.0);
    try expectSameFloats("generateNormals", normals.want, normals.got);

    const resolution = 16;
    const want_bound = c.reference16_remesh(
        null,
        0,
        ptr,
        n,
        floats.ptr,
        vertex_count,
        stride,
        resolution,
        0,
    );
    const got_bound = try mo.remesh(
        u16,
        gpa,
        null,
        mesh.indices,
        mesh.positions(),
        resolution,
        .{},
    );
    try common.expectSameValue(usize, "remesh bound", want_bound, got_bound);
    var remeshed: Outputs(f32) = try .init(want_bound * 9);
    defer remeshed.deinit();
    const want_count = c.reference16_remesh(
        remeshed.want.ptr,
        want_bound,
        ptr,
        n,
        floats.ptr,
        vertex_count,
        stride,
        resolution,
        0,
    );
    const got_count = try mo.remesh(
        u16,
        gpa,
        remeshed.got,
        mesh.indices,
        mesh.positions(),
        resolution,
        .{},
    );
    try common.expectSameValue(usize, "remesh count", want_count, got_count);
    try expectSameFloats("remesh", remeshed.want, remeshed.got);
}

fn checkAll(mesh: common.Mesh, locks: []const u8) !void {
    const mesh16: Mesh16 = try .of(mesh);
    defer mesh16.deinit();
    try checkIndexGeneration(mesh16);
    try checkOptimizers(mesh16);
    try checkCodecsAndAnalysis(mesh16);
    try checkSimplifiers(mesh16, locks);
    try checkMeshlets(mesh16);
    try checkGeometry(mesh16);
}

/// Lock flags for every vertex: about one in eight locked, protected or
/// prioritized.
fn randomLocks(rng: std.Random, vertex_count: usize) ![]u8 {
    const locks = try gpa.alloc(u8, vertex_count);
    for (locks) |*l| {
        l.* = if (rng.uintLessThan(u32, 8) == 0) @as(u8, 1) << rng.int(u2) else 0;
    }
    return locks;
}

test "u16 indices match the original's 16-bit templates on the demo mesh" {
    var mesh = try common.pirate();
    defer mesh.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(16);
    const locks = try randomLocks(prng.random(), mesh.vertices.len);
    defer gpa.free(locks);
    try checkAll(mesh, locks);
}

test "u16 indices match the original's 16-bit templates up to the largest index" {
    // 65536 vertices, 0 to 0xffff.
    var mesh = try meshes.grid(gpa, 255);
    defer mesh.deinit(gpa);
    try std.testing.expectEqual(1 << 16, mesh.vertices.len);
    var prng: std.Random.DefaultPrng = .init(17);
    const locks = try randomLocks(prng.random(), mesh.vertices.len);
    defer gpa.free(locks);
    try checkAll(mesh, locks);
}

fn fuzzMesh(seed: u64) !void {
    var mesh = try common.fuzzMesh(seed, 300, 400);
    defer mesh.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(seed);
    const locks = try randomLocks(prng.random(), mesh.vertices.len);
    defer gpa.free(locks);
    try checkAll(mesh, locks);
}

test "u16 indices match the original's 16-bit templates on fuzzed meshes" {
    try common.fuzz("u16 indices", 16 << 20, fuzzMesh);
}
