//! The index generator against the original: every test mesh, fuzzed
//! meshes, and fuzzed vertex streams up to the largest count and size.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const Vertex = common.Vertex;

test "generateVertexRemap matches the original on the demo soup" {
    const soup = try meshes.pirateSoup(gpa);
    defer gpa.free(soup);
    try checkVertexRemap(soup, null);
}

test "generateVertexRemap matches the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        try checkVertexRemap(mesh.vertices, mesh.indices);
        try checkVertexRemap(mesh.vertices, null);
    }
}

fn checkVertexRemap(vertices: []const Vertex, indices: ?[]const u32) !void {
    const want = try gpa.alloc(u32, vertices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, vertices.len);
    defer gpa.free(got);
    const index_count = if (indices) |list| list.len else vertices.len;
    const indices_ptr = if (indices) |list| list.ptr else null;

    // The whole vertex, then only the position.
    const bytes = std.mem.sliceAsBytes(vertices);
    for ([_]usize{ @sizeOf(Vertex), 12 }) |size| {
        const c_position: c.Stream = .{ .data = bytes.ptr, .size = 12, .stride = @sizeOf(Vertex) };
        const position: mo.Stream = .{ .data = bytes, .size = 12, .stride = @sizeOf(Vertex) };
        const want_unique = if (size == @sizeOf(Vertex))
            c.meshopt_generateVertexRemap(
                want.ptr,
                indices_ptr,
                index_count,
                vertices.ptr,
                vertices.len,
                size,
            )
        else
            c.meshopt_generateVertexRemapMulti(
                want.ptr,
                indices_ptr,
                index_count,
                vertices.len,
                &.{c_position},
                1,
            );
        const got_unique = if (size == @sizeOf(Vertex))
            try mo.generateVertexRemap(gpa, got, indices, bytes, size)
        else
            try mo.generateVertexRemapMulti(gpa, got, indices, vertices.len, &.{position});
        try common.expectSameValue(usize, "unique vertices", want_unique, got_unique);
        // Vertices no index uses keep the original's marker.
        try common.expectSame(u32, "remap", want, got);
        @memset(got, 0x55555555);
        _ = if (size == @sizeOf(Vertex))
            try mo.generateVertexRemap(gpa, got, indices, bytes, size)
        else
            try mo.generateVertexRemapMulti(gpa, got, indices, vertices.len, &.{position});
        try common.expectSame(u32, "remap again", want, got);

        // Applying the table, into a new buffer and in place.
        if (size == @sizeOf(Vertex)) try checkRemapApply(vertices, indices, want, want_unique);
    }

    // Several streams: positions, normals and texture coordinates.
    const c_streams = [_]c.Stream{
        .{ .data = vertices.ptr, .size = 12, .stride = @sizeOf(Vertex) },
        .{ .data = bytes.ptr + 12, .size = 12, .stride = @sizeOf(Vertex) },
        .{ .data = bytes.ptr + 24, .size = 8, .stride = @sizeOf(Vertex) },
    };
    const streams = [_]mo.Stream{
        .{ .data = bytes, .size = 12, .stride = @sizeOf(Vertex) },
        .{ .data = bytes[12..], .size = 12, .stride = @sizeOf(Vertex) },
        .{ .data = bytes[24..], .size = 8, .stride = @sizeOf(Vertex) },
    };
    const want_multi = c.meshopt_generateVertexRemapMulti(
        want.ptr,
        indices_ptr,
        index_count,
        vertices.len,
        &c_streams,
        c_streams.len,
    );
    const got_multi = try mo.generateVertexRemapMulti(gpa, got, indices, vertices.len, &streams);
    try common.expectSameValue(usize, "unique vertices (streams)", want_multi, got_multi);
    try common.expectSame(u32, "remap (streams)", want, got);

    // Positions compared as floats, with and without a texture coordinate
    // check of our own.
    const positions = common.positionsOf(vertices);
    for ([_]bool{ false, true }) |with_check| {
        const want_custom = c.meshopt_generateVertexRemapCustom(
            want.ptr,
            indices_ptr,
            index_count,
            positions.data.ptr,
            vertices.len,
            @sizeOf(Vertex),
            if (with_check) &sameTexcoordC else null,
            @constCast(vertices.ptr),
        );
        const got_custom = if (with_check)
            try mo.generateVertexRemapCustom(gpa, got, indices, positions, vertices, sameTexcoord)
        else
            try mo.generateVertexRemapCustom(gpa, got, indices, positions, {}, null);
        try common.expectSameValue(usize, "unique vertices (custom)", want_custom, got_custom);
        try common.expectSame(u32, "remap (custom)", want, got);
    }
}

fn sameTexcoord(vertices: []const Vertex, lhs: u32, rhs: u32) bool {
    return vertices[lhs].tx == vertices[rhs].tx and vertices[lhs].ty == vertices[rhs].ty;
}

fn sameTexcoordC(context: ?*anyopaque, lhs: u32, rhs: u32) callconv(.c) c_int {
    const vertices: [*]const Vertex = @ptrCast(@alignCast(context.?));
    const same = vertices[lhs].tx == vertices[rhs].tx and vertices[lhs].ty == vertices[rhs].ty;
    return @intFromBool(same);
}

fn checkRemapApply(
    vertices: []const Vertex,
    indices: ?[]const u32,
    remap: []const u32,
    unique: usize,
) !void {
    const want = try gpa.alloc(Vertex, unique);
    defer gpa.free(want);
    const got = try gpa.alloc(Vertex, unique);
    defer gpa.free(got);
    // Every byte set, so unwritten vertices compare equal too.
    @memset(std.mem.sliceAsBytes(want), 0xcd);
    @memset(std.mem.sliceAsBytes(got), 0xcd);
    c.meshopt_remapVertexBuffer(want.ptr, vertices.ptr, vertices.len, @sizeOf(Vertex), remap.ptr);
    try mo.remapVertexBuffer(
        gpa,
        std.mem.sliceAsBytes(got),
        std.mem.sliceAsBytes(vertices),
        @sizeOf(Vertex),
        remap,
    );
    try common.expectSame(
        u8,
        "remapVertexBuffer",
        std.mem.sliceAsBytes(want),
        std.mem.sliceAsBytes(got),
    );

    // In place, at every size the port's loop has its own copy for.
    for ([_]usize{ 4, 8, 12, 16, 32 }) |size| {
        const count = vertices.len;
        const want_in_place = try gpa.alloc(u8, count * size);
        defer gpa.free(want_in_place);
        const got_in_place = try gpa.alloc(u8, count * size);
        defer gpa.free(got_in_place);
        for (0..count) |i| {
            @memcpy(
                want_in_place[i * size ..][0..size],
                std.mem.sliceAsBytes(vertices[i .. i + 1])[0..size],
            );
        }
        @memcpy(got_in_place, want_in_place);
        c.meshopt_remapVertexBuffer(want_in_place.ptr, want_in_place.ptr, count, size, remap.ptr);
        try mo.remapVertexBuffer(gpa, got_in_place, got_in_place, size, remap);
        try common.expectSame(u8, "remapVertexBuffer in place", want_in_place, got_in_place);
    }

    const index_count = if (indices) |list| list.len else vertices.len;
    const want_indices = try gpa.alloc(u32, index_count);
    defer gpa.free(want_indices);
    const got_indices = try gpa.alloc(u32, index_count);
    defer gpa.free(got_indices);
    c.meshopt_remapIndexBuffer(
        want_indices.ptr,
        if (indices) |list| list.ptr else null,
        index_count,
        remap.ptr,
    );
    mo.remapIndexBuffer(got_indices, indices, remap);
    try common.expectSame(u32, "remapIndexBuffer", want_indices, got_indices);

    // Without indices the table itself is read, and may be overwritten as
    // it is read: in place, and shifted by one either way.
    if (indices == null and remap.len > 1) {
        const want_table = try gpa.alloc(u32, remap.len + 1);
        defer gpa.free(want_table);
        const got_table = try gpa.alloc(u32, remap.len + 1);
        defer gpa.free(got_table);
        const n = remap.len;
        for ([_][2]usize{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 } }) |shift| {
            @memcpy(want_table[shift[1]..][0..n], remap);
            @memcpy(got_table[shift[1]..][0..n], remap);
            want_table[if (shift[1] == 0) n else 0] = 7;
            got_table[if (shift[1] == 0) n else 0] = 7;
            const dst = shift[0];
            const src = shift[1];
            c.meshopt_remapIndexBuffer(want_table[dst..].ptr, null, n, want_table[src..].ptr);
            mo.remapIndexBuffer(got_table[dst..][0..n], null, got_table[src..][0..n]);
            try common.expectSame(u32, "remapIndexBuffer overlapping", want_table, got_table);
        }
    }
}

test "filterIndexBuffer and generateShadowIndexBuffer match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkFilterAndShadow(mesh);
}

fn checkFilterAndShadow(mesh: common.Mesh) !void {
    const indices = mesh.indices;
    const bytes = std.mem.sliceAsBytes(mesh.vertices);
    const want = try gpa.alloc(u32, indices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, indices.len);
    defer gpa.free(got);

    // Positions alone, and the whole vertex.
    for ([_]usize{ 12, @sizeOf(Vertex) }) |size| {
        const stream: mo.Stream = .{ .data = bytes, .size = size, .stride = @sizeOf(Vertex) };
        const c_stream: c.Stream = .{
            .data = bytes.ptr,
            .size = size,
            .stride = @sizeOf(Vertex),
        };

        const want_count = c.meshopt_filterIndexBuffer(
            want.ptr,
            indices.ptr,
            indices.len,
            bytes.ptr,
            mesh.vertices.len,
            size,
            @sizeOf(Vertex),
        );
        const got_count = try mo.filterIndexBuffer(
            gpa,
            got,
            indices,
            mesh.vertices.len,
            stream,
        );
        try common.expectSame(u32, "filterIndexBuffer", want[0..want_count], got[0..got_count]);

        const want_multi = c.meshopt_filterIndexBufferMulti(
            want.ptr,
            indices.ptr,
            indices.len,
            mesh.vertices.len,
            &.{c_stream},
            1,
        );
        const got_multi = try mo.filterIndexBufferMulti(
            gpa,
            got,
            indices,
            mesh.vertices.len,
            &.{stream},
        );
        try common.expectSame(
            u32,
            "filterIndexBufferMulti",
            want[0..want_multi],
            got[0..got_multi],
        );

        // In place.
        @memcpy(want, indices);
        @memcpy(got, indices);
        const want_in_place = c.meshopt_filterIndexBuffer(
            want.ptr,
            want.ptr,
            indices.len,
            bytes.ptr,
            mesh.vertices.len,
            size,
            @sizeOf(Vertex),
        );
        const got_in_place = try mo.filterIndexBuffer(gpa, got, got, mesh.vertices.len, stream);
        try common.expectSame(
            u32,
            "filterIndexBuffer in place",
            want[0..want_in_place],
            got[0..got_in_place],
        );

        c.meshopt_generateShadowIndexBuffer(
            want.ptr,
            indices.ptr,
            indices.len,
            bytes.ptr,
            mesh.vertices.len,
            size,
            @sizeOf(Vertex),
        );
        try mo.generateShadowIndexBuffer(gpa, got, indices, mesh.vertices.len, stream);
        try common.expectSame(u32, "generateShadowIndexBuffer", want, got);
        @memset(got, 0x55555555);
        try mo.generateShadowIndexBuffer(gpa, got, indices, mesh.vertices.len, stream);
        try common.expectSame(u32, "generateShadowIndexBuffer again", want, got);

        c.meshopt_generateShadowIndexBufferMulti(
            want.ptr,
            indices.ptr,
            indices.len,
            mesh.vertices.len,
            &.{c_stream},
            1,
        );
        try mo.generateShadowIndexBufferMulti(gpa, got, indices, mesh.vertices.len, &.{stream});
        try common.expectSame(u32, "generateShadowIndexBufferMulti", want, got);
    }
}

test "position remap, adjacency and tessellation match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkPositionRemapAndPatches(mesh);
}

fn checkPositionRemapAndPatches(mesh: common.Mesh) !void {
    const indices = mesh.indices;
    const positions = common.positionsOf(mesh.vertices);
    const n = mesh.vertices.len;

    const want_remap = try gpa.alloc(u32, n);
    defer gpa.free(want_remap);
    const got_remap = try gpa.alloc(u32, n);
    defer gpa.free(got_remap);
    c.meshopt_generatePositionRemap(want_remap.ptr, positions.data.ptr, n, @sizeOf(Vertex));
    try mo.generatePositionRemap(gpa, got_remap, positions);
    try common.expectSame(u32, "generatePositionRemap", want_remap, got_remap);
    @memset(got_remap, 0x55555555);
    try mo.generatePositionRemap(gpa, got_remap, positions);
    try common.expectSame(u32, "generatePositionRemap again", want_remap, got_remap);

    const want = try gpa.alloc(u32, indices.len * 4);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, indices.len * 4);
    defer gpa.free(got);

    c.meshopt_generateAdjacencyIndexBuffer(
        want.ptr,
        indices.ptr,
        indices.len,
        positions.data.ptr,
        n,
        @sizeOf(Vertex),
    );
    try mo.generateAdjacencyIndexBuffer(gpa, got, indices, positions);
    try common.expectSame(
        u32,
        "generateAdjacencyIndexBuffer",
        want[0 .. indices.len * 2],
        got[0 .. indices.len * 2],
    );

    c.meshopt_generateTessellationIndexBuffer(
        want.ptr,
        indices.ptr,
        indices.len,
        positions.data.ptr,
        n,
        @sizeOf(Vertex),
    );
    try mo.generateTessellationIndexBuffer(gpa, got, indices, positions);
    try common.expectSame(u32, "generateTessellationIndexBuffer", want, got);
}

test "generateProvokingIndexBuffer matches the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| try checkProvoking(mesh);
}

fn checkProvoking(mesh: common.Mesh) !void {
    const indices = mesh.indices;
    const n = mesh.vertices.len;
    const reorder_size = n + indices.len / 3;

    const want = try gpa.alloc(u32, indices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, indices.len);
    defer gpa.free(got);
    const want_reorder = try gpa.alloc(u32, reorder_size);
    defer gpa.free(want_reorder);
    const got_reorder = try gpa.alloc(u32, reorder_size);
    defer gpa.free(got_reorder);

    const want_count = c.meshopt_generateProvokingIndexBuffer(
        want.ptr,
        want_reorder.ptr,
        indices.ptr,
        indices.len,
        n,
    );
    const got_count = try mo.generateProvokingIndexBuffer(gpa, got, got_reorder, indices, n);
    try common.expectSame(u32, "provoking indices", want, got);
    try common.expectSame(
        u32,
        "provoking reorder",
        want_reorder[0..want_count],
        got_reorder[0..got_count],
    );

    // Again, into buffers holding other values.
    @memset(got, 0x55555555);
    @memset(got_reorder, 0x55555555);
    const again = try mo.generateProvokingIndexBuffer(gpa, got, got_reorder, indices, n);
    try common.expectSame(u32, "provoking indices again", want, got);
    try common.expectSame(
        u32,
        "provoking reorder again",
        want_reorder[0..want_count],
        got_reorder[0..again],
    );
}

test "the index generator matches the original on fuzzed meshes" {
    try common.fuzz("index generator on meshes", 0, fuzzIndexGenerator);
}

fn fuzzIndexGenerator(seed: u64) !void {
    var mesh = try common.fuzzMesh(seed, 200, 300);
    defer mesh.deinit(gpa);
    try checkVertexRemap(mesh.vertices, mesh.indices);
    try checkVertexRemap(mesh.vertices, null);
    try checkFilterAndShadow(mesh);
    try checkPositionRemapAndPatches(mesh);
    try checkProvoking(mesh);
}

test "the index generator matches the original on fuzzed streams" {
    try common.fuzz("index generator on streams", 0, fuzzStreams);
}

/// Up to 16 streams of random bytes, each up to 256 bytes a vertex, where
/// vertices repeat whole or in only some streams.
fn fuzzStreams(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const vertex_count = rng.intRangeAtMost(usize, 1, 300);
    const stream_count = if (rng.uintLessThan(u32, 8) == 0)
        16
    else
        rng.intRangeAtMost(usize, 1, 16);

    // The earlier vertex each vertex copies, or itself.
    const source = try gpa.alloc(usize, vertex_count);
    defer gpa.free(source);
    for (source, 0..) |*s, i| s.* = if (i > 0 and rng.boolean()) rng.uintLessThan(usize, i) else i;

    var buffers: [16][]u8 = undefined;
    var made: usize = 0;
    defer for (buffers[0..made]) |buffer| gpa.free(buffer);
    var streams: [16]mo.Stream = undefined;
    var c_streams: [16]c.Stream = undefined;
    for (0..stream_count) |k| {
        const size = if (rng.uintLessThan(u32, 8) == 0) 256 else rng.intRangeAtMost(usize, 1, 64);
        const stride = @min(256, size + rng.uintAtMost(usize, 8));
        const buffer = try gpa.alloc(u8, vertex_count * stride);
        buffers[k] = buffer;
        made += 1;
        rng.bytes(buffer);
        // Few distinct bytes in some streams, so values repeat by chance too.
        if (rng.boolean()) for (buffer) |*b| {
            b.* &= 1;
        };
        for (source, 0..) |j, i| {
            if (j == i or rng.uintLessThan(u32, 4) == 0) continue;
            @memcpy(buffer[i * stride ..][0..size], buffer[j * stride ..][0..size]);
        }
        streams[k] = .{ .data = buffer, .size = size, .stride = stride };
        c_streams[k] = .{ .data = buffer.ptr, .size = size, .stride = stride };
    }

    const indices = try gpa.alloc(u32, rng.uintAtMost(usize, 300) * 3);
    defer gpa.free(indices);
    for (indices) |*index| index.* = rng.uintLessThan(u32, @intCast(vertex_count));

    const want = try gpa.alloc(u32, @max(vertex_count, indices.len));
    defer gpa.free(want);
    const got = try gpa.alloc(u32, @max(vertex_count, indices.len));
    defer gpa.free(got);

    // Remap tables from all the streams, and from the first one's whole
    // stride as one vertex; with an index buffer and without.
    for ([_]?[]const u32{ indices, null }) |list| {
        const index_count = if (list) |l| l.len else vertex_count;
        const list_ptr = if (list) |l| l.ptr else null;
        const want_unique = c.meshopt_generateVertexRemapMulti(
            want.ptr,
            list_ptr,
            index_count,
            vertex_count,
            &c_streams,
            stream_count,
        );
        const got_unique = try mo.generateVertexRemapMulti(
            gpa,
            got[0..vertex_count],
            list,
            vertex_count,
            streams[0..stream_count],
        );
        try common.expectSameValue(usize, "unique vertices (streams)", want_unique, got_unique);
        try common.expectSame(u32, "remap (streams)", want[0..vertex_count], got[0..vertex_count]);

        const stride = streams[0].stride;
        const want_single = c.meshopt_generateVertexRemap(
            want.ptr,
            list_ptr,
            index_count,
            buffers[0].ptr,
            vertex_count,
            stride,
        );
        const got_single = try mo.generateVertexRemap(
            gpa,
            got[0..vertex_count],
            list,
            buffers[0],
            stride,
        );
        try common.expectSameValue(usize, "unique vertices", want_single, got_single);
        try common.expectSame(u32, "remap", want[0..vertex_count], got[0..vertex_count]);
        try checkRemapBytes(buffers[0], stride, list, want[0..vertex_count], want_single);
    }

    const want_filtered = c.meshopt_filterIndexBufferMulti(
        want.ptr,
        indices.ptr,
        indices.len,
        vertex_count,
        &c_streams,
        stream_count,
    );
    const got_filtered = try mo.filterIndexBufferMulti(
        gpa,
        got[0..indices.len],
        indices,
        vertex_count,
        streams[0..stream_count],
    );
    try common.expectSame(
        u32,
        "filterIndexBufferMulti",
        want[0..want_filtered],
        got[0..got_filtered],
    );

    c.meshopt_generateShadowIndexBufferMulti(
        want.ptr,
        indices.ptr,
        indices.len,
        vertex_count,
        &c_streams,
        stream_count,
    );
    try mo.generateShadowIndexBufferMulti(
        gpa,
        got[0..indices.len],
        indices,
        vertex_count,
        streams[0..stream_count],
    );
    try common.expectSame(
        u32,
        "generateShadowIndexBufferMulti",
        want[0..indices.len],
        got[0..indices.len],
    );
}

/// `remapVertexBuffer` and `remapIndexBuffer` on bytes, into new buffers,
/// then the vertices in place.
fn checkRemapBytes(
    vertices: []const u8,
    vertex_size: usize,
    indices: ?[]const u32,
    remap: []const u32,
    unique: usize,
) !void {
    const vertex_count = vertices.len / vertex_size;
    const want = try gpa.alloc(u8, vertices.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, vertices.len);
    defer gpa.free(got);
    c.meshopt_remapVertexBuffer(want.ptr, vertices.ptr, vertex_count, vertex_size, remap.ptr);
    try mo.remapVertexBuffer(gpa, got[0 .. unique * vertex_size], vertices, vertex_size, remap);
    const used = unique * vertex_size;
    try common.expectSame(u8, "remapVertexBuffer", want[0..used], got[0..used]);

    @memcpy(want, vertices);
    @memcpy(got, vertices);
    c.meshopt_remapVertexBuffer(want.ptr, want.ptr, vertex_count, vertex_size, remap.ptr);
    try mo.remapVertexBuffer(gpa, got, got, vertex_size, remap);
    try common.expectSame(u8, "remapVertexBuffer in place", want, got);

    const index_count = if (indices) |list| list.len else vertex_count;
    const want_indices = try gpa.alloc(u32, index_count);
    defer gpa.free(want_indices);
    const got_indices = try gpa.alloc(u32, index_count);
    defer gpa.free(got_indices);
    c.meshopt_remapIndexBuffer(
        want_indices.ptr,
        if (indices) |list| list.ptr else null,
        index_count,
        remap.ptr,
    );
    mo.remapIndexBuffer(got_indices, indices, remap);
    try common.expectSame(u32, "remapIndexBuffer", want_indices, got_indices);
}
