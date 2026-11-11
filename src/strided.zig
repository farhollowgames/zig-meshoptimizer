//! Views of per-vertex floats inside a vertex buffer: positions, normals,
//! texture coordinates, attributes.

const std = @import("std");
const assert = std.debug.assert;

/// A run of floats per vertex, `stride` floats apart: vertex `i`'s floats
/// start at `data[i * stride]`. `data` runs from vertex 0's first float to at
/// least the last vertex's last float read, and at most the end of the last
/// vertex, so `count` is `data.len` divided by `stride`, rounded up.
///
/// The view borrows the buffer; anything that frees or moves it invalidates
/// the view.
pub const VertexFloats = struct {
    data: []const f32,
    /// Floats from the start of one vertex to the start of the next.
    stride: usize,

    /// Vertices of `stride` floats each, with nothing else between them.
    pub fn init(data: []const f32, stride: usize) VertexFloats {
        assert(stride > 0);
        return .{ .data = data, .stride = stride };
    }

    /// The field `name` of every vertex in `vertices`; the field must be
    /// floats (`f32`, or an array or vector of them), and `Vertex` a whole
    /// number of floats.
    pub fn fromField(
        comptime Vertex: type,
        comptime name: []const u8,
        vertices: []const Vertex,
    ) VertexFloats {
        comptime assert(@sizeOf(Vertex) % @sizeOf(f32) == 0);
        comptime assert(@offsetOf(Vertex, name) % @sizeOf(f32) == 0);
        const stride = @sizeOf(Vertex) / @sizeOf(f32);
        const width = @sizeOf(@FieldType(Vertex, name)) / @sizeOf(f32);
        if (vertices.len == 0) return .{ .data = &.{}, .stride = stride };
        const first: [*]const f32 = @ptrCast(&@field(vertices[0], name));
        return .{ .data = first[0 .. (vertices.len - 1) * stride + width], .stride = stride };
    }

    pub fn count(self: VertexFloats) usize {
        return @divCeil(self.data.len, self.stride);
    }

    /// The floats of vertex `i`, from its first to the end of `data`.
    pub fn at(self: VertexFloats, i: usize) []const f32 {
        return self.data[i * self.stride ..];
    }

    /// The first three floats of vertex `i`.
    pub fn vec3(self: VertexFloats, i: usize) [3]f32 {
        return self.data[i * self.stride ..][0..3].*;
    }
};

/// `VertexFloats` that the function it is passed to may change.
pub const VertexFloatsMut = struct {
    data: []f32,
    stride: usize,

    pub fn init(data: []f32, stride: usize) VertexFloatsMut {
        assert(stride > 0);
        return .{ .data = data, .stride = stride };
    }

    pub fn fromField(
        comptime Vertex: type,
        comptime name: []const u8,
        vertices: []Vertex,
    ) VertexFloatsMut {
        const view: VertexFloats = .fromField(Vertex, name, vertices);
        return .{ .data = @constCast(view.data), .stride = view.stride };
    }

    pub fn toConst(self: VertexFloatsMut) VertexFloats {
        return .{ .data = self.data, .stride = self.stride };
    }

    pub fn count(self: VertexFloatsMut) usize {
        return @divCeil(self.data.len, self.stride);
    }

    pub fn at(self: VertexFloatsMut, i: usize) []f32 {
        return self.data[i * self.stride ..];
    }
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a field's view counts every vertex" {
    const Vertex = struct { normal: [3]f32, position: [3]f32, uv: [2]f32 };
    var vertices: [5]Vertex = undefined;
    for (&vertices, 0..) |*v, i| {
        const f: f32 = @floatFromInt(i);
        v.* = .{ .normal = @splat(0), .position = .{ f, f + 1, f + 2 }, .uv = @splat(0) };
    }
    const positions: VertexFloats = .fromField(Vertex, "position", &vertices);
    try testing.expectEqual(5, positions.count());
    try testing.expectEqual(8, positions.stride);
    try testing.expectEqual([3]f32{ 4, 5, 6 }, positions.vec3(4));
    const uvs: VertexFloats = .fromField(Vertex, "uv", &vertices);
    try testing.expectEqual(5, uvs.count());
    const none: VertexFloats = .fromField(Vertex, "position", vertices[0..0]);
    try testing.expectEqual(0, none.count());
}
