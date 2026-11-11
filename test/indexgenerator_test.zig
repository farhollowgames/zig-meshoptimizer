//! The index generator against the original, on every test mesh.

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
}

test "filterIndexBuffer and generateShadowIndexBuffer match the original" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
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
}

test "position remap, adjacency and tessellation match the original" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
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
}

test "generateProvokingIndexBuffer matches the original" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
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
    }
}
