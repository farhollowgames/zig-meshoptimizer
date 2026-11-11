//! The simplifier against the original: every function, option and vertex
//! flag, on the demo mesh, generated meshes with seams, borders, folds and
//! noisy attributes, the cluster groups clusterlod.h simplifies, hand-made
//! edge cases and seeded fuzzing. Every index of the output buffers, every
//! returned count and error, and every float of the vertices
//! `simplifyWithUpdate` writes compare bit for bit; each port call runs a
//! second time into a buffer filled with another pattern, which must give
//! the same result.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const float_max = std.math.floatMax(f32);

/// What output buffers hold before a call: the same pattern on both sides,
/// and another for the port's second run.
const fill_compared = 0xaaaaaaaa;
const fill_rerun = 0x55555555;

/// A mesh as floats: `stride` per vertex, the position first.
const FloatMesh = struct {
    vertices: []f32,
    stride: usize,
    indices: []u32,
    /// Some floats are NaN or infinite. The output floats then compare a NaN
    /// as matching any NaN: when an operation's operands hold several NaNs,
    /// LLVM leaves open which one it returns, so a NaN's sign and payload
    /// follow how each compiler ordered the operands, on both sides.
    non_finite: bool = false,

    fn vertexCount(self: FloatMesh) usize {
        return self.vertices.len / self.stride;
    }

    fn positions(self: FloatMesh) mo.VertexFloats {
        return .init(self.vertices, self.stride);
    }

    fn strideBytes(self: FloatMesh) usize {
        return self.stride * @sizeOf(f32);
    }

    fn fromMesh(mesh: meshes.Mesh) !FloatMesh {
        const vertices = try gpa.dupe(f32, common.floatsOf(mesh.vertices));
        errdefer gpa.free(vertices);
        return .{
            .vertices = vertices,
            .stride = common.vertex_floats,
            .indices = try gpa.dupe(u32, mesh.indices),
        };
    }

    fn deinit(self: *FloatMesh) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        self.* = undefined;
    }
};

/// One edge-collapse call's inputs beyond the mesh.
const Call = struct {
    target_index_count: usize,
    target_error: f32,
    options: mo.SimplifyOptions = .{},
    /// Weights of the attributes from `attribute_offset` in each vertex.
    weights: []const f32 = &.{},
    attribute_offset: usize = 3,
    /// The original's flag bytes, one per vertex.
    locks: ?[]const u8 = null,
    /// `simplifyWithAttributes` even without weights or locks.
    with_attributes: bool = false,
};

fn flagsOf(locks: ?[]const u8) ?[]const mo.SimplifyVertexFlags {
    const list = locks orelse return null;
    return @ptrCast(list);
}

fn lockPointer(locks: ?[]const u8) ?[*]const u8 {
    return if (locks) |list| list.ptr else null;
}

/// The attributes `call` weighs, or an empty view without weights.
fn attributeView(vertices: []const f32, stride: usize, call: Call) mo.VertexFloats {
    if (call.weights.len == 0) return .{ .data = &.{}, .stride = 1 };
    return .{ .data = vertices[call.attribute_offset..], .stride = stride };
}

fn attributeViewMut(vertices: []f32, stride: usize, call: Call) mo.VertexFloatsMut {
    if (call.weights.len == 0) return .{ .data = vertices[0..0], .stride = 1 };
    return .{ .data = vertices[call.attribute_offset..], .stride = stride };
}

fn attributePointer(vertices: []const f32, call: Call) ?[*]const f32 {
    return if (call.weights.len == 0) null else vertices[call.attribute_offset..].ptr;
}

/// `common.expectSame` for floats, except that a NaN matches any NaN when
/// `mesh` holds non-finite floats.
fn expectSameFloats(mesh: FloatMesh, what: []const u8, want: []const f32, got: []const f32) !void {
    if (!mesh.non_finite or want.len != got.len) return common.expectSame(f32, what, want, got);
    for (want, got, 0..) |w, g, i| {
        if (std.math.isNan(w) and std.math.isNan(g)) continue;
        if (@as(u32, @bitCast(w)) != @as(u32, @bitCast(g))) {
            std.debug.print(
                "{s}: item {d} differs: original {any}, port {any}\n",
                .{ what, i, w, g },
            );
            return error.Mismatch;
        }
    }
}

fn fillWith(comptime T: type, items: []T, comptime fill: u32) void {
    for (items) |*item| item.* = @bitCast(@as(u32, fill));
}

/// `simplify` or `simplifyWithAttributes` on both sides.
fn checkSimplify(mesh: FloatMesh, call: Call) !void {
    const n = mesh.indices.len;
    const want = try gpa.alloc(u32, n);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, n);
    defer gpa.free(got);
    const again = try gpa.alloc(u32, n);
    defer gpa.free(again);
    fillWith(u32, want, fill_compared);
    fillWith(u32, got, fill_compared);
    fillWith(u32, again, fill_rerun);

    var want_error: f32 = -1;
    const want_count = if (call.weights.len == 0 and call.locks == null and !call.with_attributes)
        c.meshopt_simplify(
            want.ptr,
            mesh.indices.ptr,
            n,
            mesh.vertices.ptr,
            mesh.vertexCount(),
            mesh.strideBytes(),
            call.target_index_count,
            call.target_error,
            @bitCast(call.options),
            &want_error,
        )
    else
        c.meshopt_simplifyWithAttributes(
            want.ptr,
            mesh.indices.ptr,
            n,
            mesh.vertices.ptr,
            mesh.vertexCount(),
            mesh.strideBytes(),
            attributePointer(mesh.vertices, call),
            mesh.strideBytes(),
            call.weights.ptr,
            call.weights.len,
            lockPointer(call.locks),
            call.target_index_count,
            call.target_error,
            @bitCast(call.options),
            &want_error,
        );

    var got_error: f32 = -2;
    const got_count = try portSimplify(mesh, call, got, &got_error);
    var again_error: f32 = -3;
    const again_count = try portSimplify(mesh, call, again, &again_error);

    try common.expectSameValue(usize, "simplify count", want_count, got_count);
    try common.expectSame(u32, "simplify indices", want, got);
    try expectSameFloats(mesh, "simplify error", &.{want_error}, &.{got_error});
    try common.expectSameValue(usize, "simplify rerun count", got_count, again_count);
    try common.expectSame(u32, "simplify rerun", got[0..got_count], again[0..again_count]);
    try common.expectSameValue(f32, "simplify rerun error", got_error, again_error);
}

fn portSimplify(mesh: FloatMesh, call: Call, destination: []u32, result_error: *f32) !usize {
    if (call.weights.len == 0 and call.locks == null and !call.with_attributes) {
        return mo.simplify(
            gpa,
            destination,
            mesh.indices,
            mesh.positions(),
            call.target_index_count,
            call.target_error,
            call.options,
            result_error,
        );
    }
    return mo.simplifyWithAttributes(
        gpa,
        destination,
        mesh.indices,
        mesh.positions(),
        attributeView(mesh.vertices, mesh.stride, call),
        call.weights,
        flagsOf(call.locks),
        call.target_index_count,
        call.target_error,
        call.options,
        result_error,
    );
}

/// `simplify` in place, `destination` the same buffer as `indices`.
fn checkSimplifyInPlace(mesh: FloatMesh, call: Call) !void {
    const want = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(want);
    const got = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(got);

    var want_error: f32 = -1;
    const want_count = c.meshopt_simplifyWithAttributes(
        want.ptr,
        want.ptr,
        want.len,
        mesh.vertices.ptr,
        mesh.vertexCount(),
        mesh.strideBytes(),
        attributePointer(mesh.vertices, call),
        mesh.strideBytes(),
        call.weights.ptr,
        call.weights.len,
        lockPointer(call.locks),
        call.target_index_count,
        call.target_error,
        @bitCast(call.options),
        &want_error,
    );
    var got_error: f32 = -2;
    const got_count = try mo.simplifyWithAttributes(
        gpa,
        got,
        got,
        mesh.positions(),
        attributeView(mesh.vertices, mesh.stride, call),
        call.weights,
        flagsOf(call.locks),
        call.target_index_count,
        call.target_error,
        call.options,
        &got_error,
    );
    try common.expectSameValue(usize, "in place count", want_count, got_count);
    try common.expectSame(u32, "in place indices", want, got);
    try expectSameFloats(mesh, "in place error", &.{want_error}, &.{got_error});
}

/// `simplifyWithUpdate` on copies of the mesh, which it changes.
fn checkUpdate(mesh: FloatMesh, call: Call) !void {
    var want = try Copy.init(mesh);
    defer want.deinit();
    var got = try Copy.init(mesh);
    defer got.deinit();
    var again = try Copy.init(mesh);
    defer again.deinit();

    var want_error: f32 = -1;
    const want_count = c.meshopt_simplifyWithUpdate(
        want.indices.ptr,
        want.indices.len,
        want.vertices.ptr,
        mesh.vertexCount(),
        mesh.strideBytes(),
        @constCast(attributePointer(want.vertices, call)),
        mesh.strideBytes(),
        call.weights.ptr,
        call.weights.len,
        lockPointer(call.locks),
        call.target_index_count,
        call.target_error,
        @bitCast(call.options),
        &want_error,
    );
    var got_error: f32 = -2;
    const got_count = try portUpdate(&got, mesh.stride, call, &got_error);
    var again_error: f32 = -3;
    const again_count = try portUpdate(&again, mesh.stride, call, &again_error);

    try common.expectSameValue(usize, "update count", want_count, got_count);
    try common.expectSame(u32, "update indices", want.indices, got.indices);
    try expectSameFloats(mesh, "update vertices", want.vertices, got.vertices);
    try expectSameFloats(mesh, "update error", &.{want_error}, &.{got_error});
    try common.expectSameValue(usize, "update rerun count", got_count, again_count);
    try common.expectSame(u32, "update rerun indices", got.indices, again.indices);
    try common.expectSame(f32, "update rerun vertices", got.vertices, again.vertices);
    try common.expectSameValue(f32, "update rerun error", got_error, again_error);
}

fn portUpdate(copy: *Copy, stride: usize, call: Call, result_error: *f32) !usize {
    return mo.simplifyWithUpdate(
        gpa,
        copy.indices,
        .init(copy.vertices, stride),
        attributeViewMut(copy.vertices, stride, call),
        call.weights,
        flagsOf(call.locks),
        call.target_index_count,
        call.target_error,
        call.options,
        result_error,
    );
}

const Copy = struct {
    vertices: []f32,
    indices: []u32,

    fn init(mesh: FloatMesh) !Copy {
        const vertices = try gpa.dupe(f32, mesh.vertices);
        errdefer gpa.free(vertices);
        return .{ .vertices = vertices, .indices = try gpa.dupe(u32, mesh.indices) };
    }

    fn deinit(self: *Copy) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        self.* = undefined;
    }
};

/// `simplifyEdge` with its internal options: the solve into a destination
/// other than the indices, and the debug bits.
fn checkEdge(mesh: FloatMesh, call: Call) !void {
    const n = mesh.indices.len;
    var want = try Copy.init(mesh);
    defer want.deinit();
    var got = try Copy.init(mesh);
    defer got.deinit();
    fillWith(u32, want.indices, fill_compared);
    fillWith(u32, got.indices, fill_compared);

    var want_error: f32 = -1;
    const want_count = c.reference_simplifyEdge(
        want.indices.ptr,
        mesh.indices.ptr,
        n,
        want.vertices.ptr,
        mesh.vertexCount(),
        mesh.strideBytes(),
        attributePointer(want.vertices, call),
        mesh.strideBytes(),
        call.weights.ptr,
        call.weights.len,
        lockPointer(call.locks),
        call.target_index_count,
        call.target_error,
        @bitCast(call.options),
        &want_error,
    );
    var got_error: f32 = -2;
    const got_count = if (call.options.internal_solve)
        try mo.simplifyEdge(
            gpa,
            got.indices,
            mesh.indices,
            mo.VertexFloatsMut.init(got.vertices, mesh.stride),
            attributeViewMut(got.vertices, mesh.stride, call),
            call.weights,
            flagsOf(call.locks),
            call.target_index_count,
            call.target_error,
            call.options,
            &got_error,
        )
    else
        try mo.simplifyEdge(
            gpa,
            got.indices,
            mesh.indices,
            mo.VertexFloats.init(got.vertices, mesh.stride),
            attributeView(got.vertices, mesh.stride, call),
            call.weights,
            flagsOf(call.locks),
            call.target_index_count,
            call.target_error,
            call.options,
            &got_error,
        );

    try common.expectSameValue(usize, "edge count", want_count, got_count);
    try common.expectSame(u32, "edge indices", want.indices, got.indices);
    try expectSameFloats(mesh, "edge vertices", want.vertices, got.vertices);
    try expectSameFloats(mesh, "edge error", &.{want_error}, &.{got_error});
}

/// `simplifySloppy` on both sides, in place or into another buffer.
fn checkSloppy(
    mesh: FloatMesh,
    target_index_count: usize,
    target_error: f32,
    locks: ?[]const u8,
    in_place: bool,
) !void {
    const n = mesh.indices.len;
    const want = try gpa.alloc(u32, n);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, n);
    defer gpa.free(got);
    const again = try gpa.alloc(u32, n);
    defer gpa.free(again);
    if (in_place) {
        @memcpy(want, mesh.indices);
        @memcpy(got, mesh.indices);
        @memcpy(again, mesh.indices);
    } else {
        fillWith(u32, want, fill_compared);
        fillWith(u32, got, fill_compared);
        fillWith(u32, again, fill_rerun);
    }

    var want_error: f32 = -1;
    const want_count = c.meshopt_simplifySloppy(
        want.ptr,
        if (in_place) want.ptr else mesh.indices.ptr,
        n,
        mesh.vertices.ptr,
        mesh.vertexCount(),
        mesh.strideBytes(),
        lockPointer(locks),
        target_index_count,
        target_error,
        &want_error,
    );
    var got_error: f32 = -2;
    const got_count = try mo.simplifySloppy(
        gpa,
        got,
        if (in_place) got else mesh.indices,
        mesh.positions(),
        flagsOf(locks),
        target_index_count,
        target_error,
        &got_error,
    );
    var again_error: f32 = -3;
    const again_count = try mo.simplifySloppy(
        gpa,
        again,
        if (in_place) again else mesh.indices,
        mesh.positions(),
        flagsOf(locks),
        target_index_count,
        target_error,
        &again_error,
    );

    try common.expectSameValue(usize, "sloppy count", want_count, got_count);
    try common.expectSame(u32, "sloppy indices", want, got);
    try expectSameFloats(mesh, "sloppy error", &.{want_error}, &.{got_error});
    try common.expectSameValue(usize, "sloppy rerun count", got_count, again_count);
    try common.expectSame(u32, "sloppy rerun", got[0..got_count], again[0..again_count]);
    try common.expectSameValue(f32, "sloppy rerun error", got_error, again_error);
}

/// `simplifyPrune` on both sides, in place or into another buffer.
fn checkPrune(mesh: FloatMesh, target_error: f32, in_place: bool) !void {
    const n = mesh.indices.len;
    const want = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(want);
    const got = try gpa.dupe(u32, mesh.indices);
    defer gpa.free(got);
    const again = try gpa.alloc(u32, n);
    defer gpa.free(again);
    if (!in_place) {
        fillWith(u32, want, fill_compared);
        fillWith(u32, got, fill_compared);
    }
    fillWith(u32, again, fill_rerun);

    const want_count = c.meshopt_simplifyPrune(
        want.ptr,
        if (in_place) want.ptr else mesh.indices.ptr,
        n,
        mesh.vertices.ptr,
        mesh.vertexCount(),
        mesh.strideBytes(),
        target_error,
    );
    const got_count = try mo.simplifyPrune(
        gpa,
        got,
        if (in_place) got else mesh.indices,
        mesh.positions(),
        target_error,
    );
    const again_count = try mo.simplifyPrune(
        gpa,
        again,
        mesh.indices,
        mesh.positions(),
        target_error,
    );

    try common.expectSameValue(usize, "prune count", want_count, got_count);
    try common.expectSame(u32, "prune indices", want, got);
    try common.expectSameValue(usize, "prune rerun count", got_count, again_count);
    try common.expectSame(u32, "prune rerun", got[0..got_count], again[0..again_count]);
}

/// `simplifyPoints` on both sides; colors, if any, at `color_offset`.
fn checkPoints(
    mesh: FloatMesh,
    color_offset: ?usize,
    color_weight: f32,
    target_vertex_count: usize,
) !void {
    const want = try gpa.alloc(u32, target_vertex_count);
    defer gpa.free(want);
    const got = try gpa.alloc(u32, target_vertex_count);
    defer gpa.free(got);
    const again = try gpa.alloc(u32, target_vertex_count);
    defer gpa.free(again);
    fillWith(u32, want, fill_compared);
    fillWith(u32, got, fill_compared);
    fillWith(u32, again, fill_rerun);

    const color_data: ?[]const f32 = if (color_offset) |offset|
        mesh.vertices[@min(offset, mesh.vertices.len)..]
    else
        null;
    const colors: ?mo.VertexFloats = if (color_data) |data|
        .{ .data = data, .stride = mesh.stride }
    else
        null;
    const want_count = c.meshopt_simplifyPoints(
        want.ptr,
        mesh.vertices.ptr,
        mesh.vertexCount(),
        mesh.strideBytes(),
        if (color_data) |data| data.ptr else null,
        if (color_offset != null) mesh.strideBytes() else 0,
        color_weight,
        target_vertex_count,
    );
    const got_count = try mo.simplifyPoints(
        gpa,
        got,
        mesh.positions(),
        colors,
        color_weight,
        target_vertex_count,
    );
    const again_count = try mo.simplifyPoints(
        gpa,
        again,
        mesh.positions(),
        colors,
        color_weight,
        target_vertex_count,
    );

    try common.expectSameValue(usize, "points count", want_count, got_count);
    try common.expectSame(u32, "points", want, got);
    try common.expectSameValue(usize, "points rerun count", got_count, again_count);
    try common.expectSame(u32, "points rerun", got[0..got_count], again[0..again_count]);
}

fn checkScale(mesh: FloatMesh) !void {
    const want = c.meshopt_simplifyScale(mesh.vertices.ptr, mesh.vertexCount(), mesh.strideBytes());
    const got = mo.simplifyScale(mesh.positions());
    try expectSameFloats(mesh, "scale", &.{want}, &.{got});
}

// --------------------------------------------------------
// Meshes
// --------------------------------------------------------

/// Floats per vertex of the generated meshes: position, normal and texture
/// coordinates, as the demo mesh has.
const generated_stride = 8;

/// An `n` by `n` grid over the unit square, gently bumped, whose texture
/// coordinates jump at every `seam_every`th inner column: the quads right of
/// such a column use twins of its vertices, at the same positions with
/// other coordinates. Its outer edges are a border.
fn gridSeams(n: u32, seam_every: u32) !FloatMesh {
    const side = n + 1;
    var vertices: std.ArrayList(f32) = .empty;
    errdefer vertices.deinit(gpa);
    const twin = try gpa.alloc(u32, side * side);
    defer gpa.free(twin);

    for (0..side) |y| for (0..side) |x| {
        const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(n));
        const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(n));
        const z = 0.05 * @sin(7 * u) * @cos(5 * v);
        try vertices.appendSlice(gpa, &.{ u, v, z, 0, 0, 1, u, v });
    };
    var next: u32 = side * side;
    for (0..side) |y| for (0..side) |x| {
        const at = y * side + x;
        twin[at] = @intCast(at);
        if (x > 0 and x < n and x % seam_every == 0) {
            const base = vertices.items[at * generated_stride ..][0..generated_stride].*;
            try vertices.appendSlice(gpa, &base);
            vertices.items[vertices.items.len - 2] += 0.5;
            twin[at] = next;
            next += 1;
        }
    };

    const indices = try gpa.alloc(u32, n * n * 6);
    errdefer gpa.free(indices);
    for (0..n) |y| for (0..n) |x| {
        const v0 = twin[y * side + x];
        const v1: u32 = @intCast(y * side + x + 1);
        const v2 = twin[(y + 1) * side + x];
        const v3: u32 = @intCast((y + 1) * side + x + 1);
        indices[(y * n + x) * 6 ..][0..6].* = .{ v0, v1, v2, v2, v1, v3 };
    };
    return .{
        .vertices = try vertices.toOwnedSlice(gpa),
        .stride = generated_stride,
        .indices = indices,
    };
}

const Sides = enum {
    /// The front faces only.
    single,
    /// Back faces too, on the same vertices.
    shared,
    /// Back faces too, on twins of the vertices with flipped normals.
    split,
};

/// An `n` by `n` sheet folded back on itself along its middle, the halves
/// about 20 degrees apart, so the fold is a crease between nearly opposite
/// triangles; with back faces it is a double-sided sheet.
fn foldedSheet(n: u32, sides: Sides) !FloatMesh {
    const side = n + 1;
    const vertex_count = side * side;
    const copies: u32 = if (sides == .split) 2 else 1;
    const vertices = try gpa.alloc(f32, vertex_count * copies * generated_stride);
    errdefer gpa.free(vertices);
    const angle = 0.35;
    for (0..copies) |copy| for (0..side) |y| for (0..side) |x| {
        const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(n));
        const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(n));
        const d = u - 0.5;
        const px = if (d <= 0) u else 0.5 - d * @cos(@as(f32, angle));
        const pz = if (d <= 0) 0 else d * @sin(@as(f32, angle));
        const nz: f32 = if (copy == 0) 1 else -1;
        const at = (copy * vertex_count + y * side + x) * generated_stride;
        vertices[at..][0..generated_stride].* = .{ px, v, pz, 0, 0, nz, u, v };
    };

    const faces: u32 = if (sides == .single) 1 else 2;
    const indices = try gpa.alloc(u32, n * n * 6 * faces);
    errdefer gpa.free(indices);
    for (0..faces) |face| for (0..n) |y| for (0..n) |x| {
        const base: u32 = if (face == 1 and sides == .split) vertex_count else 0;
        const v0: u32 = base + @as(u32, @intCast(y * side + x));
        const v1 = v0 + 1;
        const v2 = v0 + side;
        const v3 = v2 + 1;
        const quad = indices[((face * n + y) * n + x) * 6 ..][0..6];
        quad.* = if (face == 0) .{ v0, v1, v2, v2, v1, v3 } else .{ v0, v2, v1, v2, v3, v1 };
    };
    return .{ .vertices = vertices, .stride = generated_stride, .indices = indices };
}

/// `mesh`'s positions and indices with `attribute_count` attributes per
/// vertex: smooth functions of the position plus noise of `amplitude`.
fn noisyAttributes(
    mesh: FloatMesh,
    attribute_count: usize,
    amplitude: f32,
    seed: u64,
) !FloatMesh {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const stride = 3 + attribute_count;
    const vertex_count = mesh.vertexCount();
    const vertices = try gpa.alloc(f32, vertex_count * stride);
    errdefer gpa.free(vertices);
    for (0..vertex_count) |i| {
        const p = mesh.vertices[i * mesh.stride ..][0..3];
        const out = vertices[i * stride ..][0..stride];
        out[0..3].* = p.*;
        for (out[3..], 0..) |*a, k| {
            const f: f32 = @floatFromInt(k + 1);
            const smooth = @sin(p[0] * f) + @cos(p[1] * f * 0.5) + p[2] * f;
            a.* = smooth + (rng.float(f32) * 2 - 1) * amplitude;
        }
    }
    return .{ .vertices = vertices, .stride = stride, .indices = try gpa.dupe(u32, mesh.indices) };
}

/// Hand-made trouble: three triangles on one edge, a bow tie joined at one
/// vertex, degenerate and zero-area triangles, a duplicate and a mirrored
/// triangle, and a small separate part.
fn nonManifold() !FloatMesh {
    const positions = [_]f32{
        0,   0,  0,
        1,   0,  0,
        0.5, 1,  0,
        0.5, -1, 0,
        0.5, 0,  1,
        2,   0,  0,
        3,   1,  0,
        3,   -1, 0,
        1.5,  0,    0, // on the 1-5 line
        5,    5,    5,
        5.1,  5,    5,
        5,    5.1,  5,
        0.25, 0.5,  0,
        0.75, 0.5,  0,
        0.5,  0.25, 0.25,
    };
    const indices = [_]u32{
        0, 1, 2, // three triangles on edge 0-1
        1, 0, 3,
        0, 1, 4,
        1, 5, 6, // bow tie at 5
        5, 7, 6,
        1, 8, 5, // zero area
        2,  2,  12, // degenerate
        12, 13, 2,
        12, 13, 2, // duplicate
        13, 12, 2, // mirrored
        2,  13, 14,
        9,  10, 11, // separate part
        0,  12, 2,
        13, 1,  2,
    };
    return .{
        .vertices = try gpa.dupe(f32, &positions),
        .stride = 3,
        .indices = try gpa.dupe(u32, &indices),
    };
}

/// A random mesh as upstream's simplifyfuzz builds one: 100 vertices of
/// small integers, and up to 333 triangles of random corners. `stride` is
/// at least 4, so attributes follow the position.
fn fuzzMesh(rng: std.Random, stride: usize) !FloatMesh {
    const vertices = try gpa.alloc(f32, 100 * stride);
    errdefer gpa.free(vertices);
    for (vertices) |*v| v.* = @floatFromInt(rng.uintLessThan(u32, 10));
    const index_count = rng.uintLessThan(usize, 334) * 3;
    const indices = try gpa.alloc(u32, index_count);
    for (indices) |*index| index.* = rng.uintLessThan(u32, 100);
    return .{ .vertices = vertices, .stride = stride, .indices = indices };
}

/// Random flags for every vertex: none, one or several of the defined
/// ones, and sometimes bits the simplifier ignores.
fn randomLocks(rng: std.Random, vertex_count: usize) ![]u8 {
    const locks = try gpa.alloc(u8, vertex_count);
    const density = rng.uintLessThan(u32, 4);
    for (locks) |*l| {
        l.* = if (rng.uintLessThan(u32, 4) < density) rng.int(u8) else 0;
        if (rng.boolean()) l.* &= 7;
    }
    return locks;
}

fn randomWeights(rng: std.Random, buffer: []f32, count_max: usize) []f32 {
    const count = rng.uintAtMost(usize, count_max);
    for (buffer[0..count]) |*w| {
        w.* = switch (rng.uintLessThan(u32, 5)) {
            0 => 0,
            1 => 1,
            2 => 0.01,
            3 => 100,
            else => rng.float(f32) * 2,
        };
    }
    return buffer[0..count];
}

fn randomOptions(rng: std.Random) mo.SimplifyOptions {
    var options: mo.SimplifyOptions = @bitCast(@as(u32, rng.int(u9)));
    options.internal_debug = rng.uintLessThan(u32, 8) == 0;
    return options;
}

const errors = [_]f32{ 0, 1e-4, 1e-3, 1e-2, 0.05, 0.1, 0.5, 1, 2, float_max };

/// Every public option alone, as the original's bit.
const single_options = [_]mo.SimplifyOptions{
    .{},
    .{ .lock_border = true },
    .{ .sparse = true },
    .{ .error_absolute = true },
    .{ .prune = true },
    .{ .regularize = true },
    .{ .permissive = true },
    .{ .regularize_light = true },
    .{ .preserve_folds = true },
    .{ .error_clamped = true },
    .{ .internal_debug = true },
};

/// Index counts from none to all, whole triangles.
fn targets(index_count: usize) [8]usize {
    const t = index_count / 3;
    return .{ 0, 3, t / 100 * 3, t / 10 * 3, t / 4 * 3, t / 2 * 3, t * 9 / 10 * 3, index_count };
}

// --------------------------------------------------------
// The demo mesh and generated meshes
// --------------------------------------------------------

/// The demo mesh's attributes: normals and texture coordinates, weighed as
/// demos usually do, and texture coordinates alone.
const demo_weights = [_]f32{ 0.5, 0.5, 0.5, 1, 1 };
const uv_weights = [_]f32{ 0, 0, 0, 1, 1 };

test "simplify matches the original on the demo mesh" {
    var pirate = try common.pirate();
    defer pirate.deinit(gpa);
    var mesh: FloatMesh = try .fromMesh(pirate);
    defer mesh.deinit();

    for (targets(mesh.indices.len)) |target| {
        for ([_]f32{ 1e-3, 1e-2, 0.1, float_max }) |target_error| {
            for (single_options) |options| {
                const call: Call = .{
                    .target_index_count = target,
                    .target_error = target_error,
                    .options = options,
                };
                try checkSimplify(mesh, call);
                var with_demo = call;
                with_demo.weights = &demo_weights;
                try checkSimplify(mesh, with_demo);
                var with_uv = call;
                with_uv.weights = &uv_weights;
                try checkSimplify(mesh, with_uv);
            }
        }
    }
}

test "simplifyWithUpdate matches the original on the demo mesh" {
    var pirate = try common.pirate();
    defer pirate.deinit(gpa);
    var mesh: FloatMesh = try .fromMesh(pirate);
    defer mesh.deinit();

    for (targets(mesh.indices.len)) |target| {
        for ([_]f32{ 1e-2, float_max }) |target_error| {
            for (single_options) |options| {
                for ([_][]const f32{ &.{}, &demo_weights, &uv_weights }) |weights| {
                    try checkUpdate(mesh, .{
                        .target_index_count = target,
                        .target_error = target_error,
                        .options = options,
                        .weights = weights,
                    });
                }
            }
        }
    }
}

test "every option combination matches the original" {
    var pirate = try common.pirate();
    defer pirate.deinit(gpa);
    var demo: FloatMesh = try .fromMesh(pirate);
    defer demo.deinit();
    var grid = try gridSeams(12, 4);
    defer grid.deinit();
    var sphere_mesh = try meshes.sphere(gpa, 8, 16);
    defer sphere_mesh.deinit(gpa);
    var sphere: FloatMesh = try .fromMesh(sphere_mesh);
    defer sphere.deinit();
    var folded = try foldedSheet(10, .shared);
    defer folded.deinit();

    var prng: std.Random.DefaultPrng = .init(512);
    const rng = prng.random();
    for ([_]FloatMesh{ demo, grid, sphere, folded }) |mesh| {
        const locks = try randomLocks(rng, mesh.vertexCount());
        defer gpa.free(locks);
        for (0..512) |bits| {
            const options: mo.SimplifyOptions = @bitCast(@as(u32, @intCast(bits)));
            const call: Call = .{
                .target_index_count = mesh.indices.len / 3 / 4 * 3,
                .target_error = 0.05,
                .options = options,
            };
            try checkSimplify(mesh, call);
            var with_attributes = call;
            with_attributes.weights = &demo_weights;
            with_attributes.locks = locks;
            try checkSimplify(mesh, with_attributes);
            if (bits % 7 == 0) try checkUpdate(mesh, with_attributes);
        }
    }
}

test "simplify matches the original on every test mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |m| {
        var mesh: FloatMesh = try .fromMesh(m);
        defer mesh.deinit();
        for (targets(mesh.indices.len)) |target| {
            for (errors) |target_error| {
                for ([_]mo.SimplifyOptions{
                    .{},
                    .{ .lock_border = true },
                    .{ .sparse = true, .error_absolute = true },
                    .{ .prune = true },
                    .{ .permissive = true },
                    .{ .regularize = true, .preserve_folds = true },
                }) |options| {
                    const call: Call = .{
                        .target_index_count = target,
                        .target_error = target_error,
                        .options = options,
                    };
                    try checkSimplify(mesh, call);
                    var with_attributes = call;
                    with_attributes.weights = &demo_weights;
                    try checkSimplify(mesh, with_attributes);
                }
            }
            try checkUpdate(mesh, .{
                .target_index_count = target,
                .target_error = float_max,
                .weights = &demo_weights,
            });
        }
    }
}

test "simplify matches the original on seams, borders and folds" {
    var generated: [7]FloatMesh = undefined;
    var made: usize = 0;
    defer for (generated[0..made]) |*m| m.deinit();
    generated[0] = try gridSeams(40, 8);
    made += 1;
    generated[1] = try gridSeams(33, 2);
    made += 1;
    generated[2] = try foldedSheet(16, .single);
    made += 1;
    generated[3] = try foldedSheet(16, .shared);
    made += 1;
    generated[4] = try foldedSheet(16, .split);
    made += 1;
    var sphere_mesh = try meshes.sphere(gpa, 24, 48);
    defer sphere_mesh.deinit(gpa);
    generated[5] = try .fromMesh(sphere_mesh);
    made += 1;
    // The top half of the sphere: a border along the equator, and the pole's
    // seam of many wedges.
    generated[6] = try .fromMesh(sphere_mesh);
    made += 1;
    generated[6].indices = try gpa.realloc(generated[6].indices, generated[6].indices.len / 2);

    for (generated) |mesh| {
        for (targets(mesh.indices.len)) |target| {
            for ([_]f32{ 1e-3, 1e-2, 0.1, float_max }) |target_error| {
                for (single_options) |options| {
                    const call: Call = .{
                        .target_index_count = target,
                        .target_error = target_error,
                        .options = options,
                    };
                    try checkSimplify(mesh, call);
                    var with_attributes = call;
                    with_attributes.weights = &demo_weights;
                    try checkSimplify(mesh, with_attributes);
                    var with_folds = with_attributes;
                    with_folds.options.preserve_folds = true;
                    try checkSimplify(mesh, with_folds);
                }
            }
            for ([_][]const f32{ &.{}, &demo_weights }) |weights| {
                try checkUpdate(mesh, .{
                    .target_index_count = target,
                    .target_error = float_max,
                    .weights = weights,
                    .options = .{ .preserve_folds = true },
                });
                try checkUpdate(mesh, .{
                    .target_index_count = target,
                    .target_error = float_max,
                    .weights = weights,
                    .options = .{ .permissive = true, .regularize_light = true },
                });
            }
        }
    }
}

test "attributes of every count and weight match the original" {
    var base = try gridSeams(20, 5);
    defer base.deinit();
    var prng: std.Random.DefaultPrng = .init(32);
    const rng = prng.random();
    for ([_]usize{ 1, 2, 3, 4, 5, 7, 8, 13, 16, 31, 32 }) |count| {
        for ([_]f32{ 0, 0.01, 1, 100 }) |amplitude| {
            var mesh = try noisyAttributes(base, count, amplitude, count);
            defer mesh.deinit();
            var buffer: [32]f32 = undefined;
            for (0..4) |round| {
                const weights = buffer[0..count];
                for (weights) |*w| w.* = switch (round) {
                    0 => 1,
                    1 => 0.1,
                    2 => if (rng.boolean()) 0 else rng.float(f32) * 10,
                    else => 1000,
                };
                for ([_]mo.SimplifyOptions{
                    .{},
                    .{ .error_clamped = true },
                    .{ .error_clamped = true, .permissive = true, .sparse = true },
                    .{ .error_absolute = true, .regularize = true },
                }) |options| {
                    const call: Call = .{
                        .target_index_count = mesh.indices.len / 3 / 5 * 3,
                        .target_error = if (round == 3) float_max else 0.2,
                        .options = options,
                        .weights = weights,
                    };
                    try checkSimplify(mesh, call);
                    try checkUpdate(mesh, call);
                }
            }
        }
    }
}

test "the widest vertices and the most attributes match the original" {
    // 256 bytes a vertex, the most the original takes, with the last 32
    // floats weighed, the most attributes it takes.
    var base = try gridSeams(16, 4);
    defer base.deinit();
    var mesh = try noisyAttributes(base, 61, 0.1, 64);
    defer mesh.deinit();
    var weights: [mo.simplifier.attribute_count_max]f32 = undefined;
    for (&weights, 0..) |*w, k| w.* = @as(f32, @floatFromInt(k % 4)) * 0.25;
    for ([_]mo.SimplifyOptions{ .{}, .{ .sparse = true, .permissive = true } }) |options| {
        const call: Call = .{
            .target_index_count = mesh.indices.len / 3 / 4 * 3,
            .target_error = float_max,
            .options = options,
            .weights = &weights,
            .attribute_offset = 32,
        };
        try checkSimplify(mesh, call);
        try checkUpdate(mesh, call);
    }
    try checkSloppy(mesh, mesh.indices.len / 3 / 4 * 3, float_max, null, false);
    try checkPrune(mesh, 0.1, false);
    try checkPoints(mesh, 61, 1, mesh.vertexCount() / 4);
    try checkScale(mesh);
}

test "vertex flags alone and combined match the original" {
    var grid = try gridSeams(16, 4);
    defer grid.deinit();
    var pirate = try common.pirate();
    defer pirate.deinit(gpa);
    var demo: FloatMesh = try .fromMesh(pirate);
    defer demo.deinit();

    var prng: std.Random.DefaultPrng = .init(7);
    const rng = prng.random();
    for ([_]FloatMesh{ grid, demo }) |mesh| {
        const locks = try gpa.alloc(u8, mesh.vertexCount());
        defer gpa.free(locks);
        // Every combination of the three flags, and an ignored bit, on all
        // vertices, on every other one, and on a random third.
        for (0..16) |flags| {
            const value: u8 = @intCast(if (flags & 8 != 0) (flags & 7) | 0x80 else flags);
            for (0..3) |pattern| {
                for (locks, 0..) |*l, i| l.* = switch (pattern) {
                    0 => value,
                    1 => if (i % 2 == 0) value else 0,
                    else => if (rng.uintLessThan(u32, 3) == 0) value else 0,
                };
                for ([_]mo.SimplifyOptions{
                    .{},
                    .{ .permissive = true },
                    .{ .permissive = true, .sparse = true, .lock_border = true },
                    .{ .regularize = true },
                }) |options| {
                    const call: Call = .{
                        .target_index_count = mesh.indices.len / 3 / 4 * 3,
                        .target_error = float_max,
                        .options = options,
                        .weights = &demo_weights,
                        .locks = locks,
                    };
                    try checkSimplify(mesh, call);
                    var no_weights = call;
                    no_weights.weights = &.{};
                    try checkSimplify(mesh, no_weights);
                    try checkUpdate(mesh, call);
                    try checkSloppy(mesh, call.target_index_count, 1, locks, false);
                }
            }
        }
    }
}

test "simplifyEdge with the internal options matches the original" {
    var pirate = try common.pirate();
    defer pirate.deinit(gpa);
    var demo: FloatMesh = try .fromMesh(pirate);
    defer demo.deinit();
    var grid = try gridSeams(16, 4);
    defer grid.deinit();
    for ([_]FloatMesh{ demo, grid }) |mesh| {
        for (targets(mesh.indices.len)) |target| {
            for ([_]mo.SimplifyOptions{
                .{},
                .{ .internal_debug = true },
                .{ .internal_debug = true, .sparse = true },
                .{ .internal_solve = true },
                .{ .internal_solve = true, .sparse = true, .permissive = true },
                .{ .internal_solve = true, .internal_debug = true, .prune = true },
            }) |options| {
                for ([_][]const f32{ &.{}, &demo_weights }) |weights| {
                    try checkEdge(mesh, .{
                        .target_index_count = target,
                        .target_error = float_max,
                        .options = options,
                        .weights = weights,
                    });
                }
            }
        }
    }
}

test "simplifySloppy matches the original on every test mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    var prng: std.Random.DefaultPrng = .init(3);
    const rng = prng.random();
    for (set.meshes) |m| {
        var mesh: FloatMesh = try .fromMesh(m);
        defer mesh.deinit();
        const locks = try randomLocks(rng, mesh.vertexCount());
        defer gpa.free(locks);
        for (targets(mesh.indices.len)) |target| {
            for (errors) |target_error| {
                try checkSloppy(mesh, target, target_error, null, false);
                try checkSloppy(mesh, target, target_error, locks, false);
                try checkSloppy(mesh, target, target_error, null, true);
            }
        }
    }
}

test "simplifyPrune matches the original" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    var parts = try nonManifold();
    defer parts.deinit();
    for (set.meshes) |m| {
        var mesh: FloatMesh = try .fromMesh(m);
        defer mesh.deinit();
        for (errors) |target_error| {
            try checkPrune(mesh, target_error, false);
            try checkPrune(mesh, target_error, true);
        }
    }
    for (errors) |target_error| try checkPrune(parts, target_error, false);
}

test "simplifyPoints matches the original" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |m| {
        var mesh: FloatMesh = try .fromMesh(m);
        defer mesh.deinit();
        const n = mesh.vertexCount();
        for ([_]usize{ 0, 1, 2, n / 100, n / 10, n / 3, n / 2, n - n / 10, n }) |target| {
            if (target > n) continue;
            try checkPoints(mesh, null, 1, target);
            for ([_]f32{ 0, 0.5, 1, 10 }) |weight| try checkPoints(mesh, 3, weight, target);
        }
    }
}

test "simplifyScale matches the original" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |m| {
        var mesh: FloatMesh = try .fromMesh(m);
        defer mesh.deinit();
        try checkScale(mesh);
    }
}

test "edge cases match the original" {
    // No triangles, with and without vertices.
    var empty: FloatMesh = .{
        .vertices = try gpa.alloc(f32, 0),
        .stride = 3,
        .indices = try gpa.alloc(u32, 0),
    };
    defer empty.deinit();
    var parts = try nonManifold();
    defer parts.deinit();
    var lonely: FloatMesh = .{
        .vertices = try gpa.dupe(f32, parts.vertices),
        .stride = 3,
        .indices = try gpa.alloc(u32, 0),
    };
    defer lonely.deinit();
    // One triangle.
    var one: FloatMesh = .{
        .vertices = try gpa.dupe(f32, &.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 }),
        .stride = 3,
        .indices = try gpa.dupe(u32, &.{ 0, 1, 2 }),
    };
    defer one.deinit();
    // Degenerate triangles only, on distinct and on equal positions.
    var degenerate: FloatMesh = .{
        .vertices = try gpa.dupe(f32, &.{ 0, 0, 0, 1, 1, 1, 2, 2, 2, 0, 0, 0 }),
        .stride = 3,
        .indices = try gpa.dupe(u32, &.{ 0, 1, 2, 0, 0, 1, 1, 2, 2, 0, 3, 1, 0, 3, 0 }),
    };
    defer degenerate.deinit();
    // Non-finite and huge coordinates.
    var wild: FloatMesh = .{
        .vertices = try gpa.dupe(f32, &.{
            0,                  0,                 0,
            1,                  0,                 0,
            0,                  1,                 0,
            std.math.nan(f32),  0,                 0,
            1,                  std.math.inf(f32), 1,
            3e38,               -3e38,             0,
            -std.math.inf(f32), 2,                 2,
            0.5,                0.5,               std.math.nan(f32),
        }),
        .stride = 3,
        .indices = try gpa.dupe(u32, &.{ 0, 1, 2, 1, 3, 2, 2, 4, 0, 5, 0, 1, 6, 7, 0, 7, 2, 1 }),
        .non_finite = true,
    };
    defer wild.deinit();

    const all_flags = [_]u8{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 };
    for ([_]FloatMesh{ empty, lonely, one, degenerate, parts, wild }) |mesh| {
        const locks = all_flags[0..mesh.vertexCount()];
        for ([_]usize{ 0, mesh.indices.len / 2 / 3 * 3, mesh.indices.len }) |target| {
            for ([_]f32{ 0, 1e-2, float_max }) |target_error| {
                for (single_options) |options| {
                    const call: Call = .{
                        .target_index_count = target,
                        .target_error = target_error,
                        .options = options,
                    };
                    try checkSimplify(mesh, call);
                    var with_attributes = call;
                    with_attributes.with_attributes = true;
                    try checkSimplify(mesh, with_attributes);
                    with_attributes.locks = locks;
                    try checkSimplify(mesh, with_attributes);
                    if (mesh.vertexCount() > 0) {
                        var weighted = call;
                        weighted.weights = &.{ 1, 0.5 };
                        weighted.attribute_offset = 1;
                        try checkSimplify(mesh, weighted);
                        try checkUpdate(mesh, weighted);
                    }
                    try checkUpdate(mesh, call);
                    try checkSimplifyInPlace(mesh, call);
                }
                try checkSloppy(mesh, target, target_error, null, false);
                try checkSloppy(mesh, target, target_error, locks, true);
            }
        }
        for ([_]f32{ 0, 0.1, float_max }) |target_error| try checkPrune(mesh, target_error, false);
        for (0..mesh.vertexCount() + 1) |target| {
            try checkPoints(mesh, null, 1, target);
            try checkPoints(mesh, 0, 1, target);
        }
        try checkScale(mesh);
    }
}

// --------------------------------------------------------
// Cluster groups, as clusterlod.h simplifies them
// --------------------------------------------------------

/// Simplifies `mesh` group by group as clusterlod.h's clodBuild does at
/// one level: groups of about `group_triangles` triangles, close in space;
/// vertices shared between groups locked, by position; texture coordinate
/// seams protected; each group half simplified, sparse and in absolute
/// error, with the variants of its configuration, then by the sloppy
/// fallback on the deindexed group.
fn checkClusterGroups(mesh: FloatMesh, group_triangles: usize) !void {
    const vertex_count = mesh.vertexCount();
    const triangle_count = mesh.indices.len / 3;

    const remap = try gpa.alloc(u32, vertex_count);
    defer gpa.free(remap);
    try mo.generatePositionRemap(gpa, remap, mesh.positions());

    // Protect bits on texture coordinate seams, the attribute protect mask
    // of the demo's configuration.
    const locks = try gpa.alloc(u8, vertex_count);
    defer gpa.free(locks);
    @memset(locks, 0);
    for (remap, 0..) |r, i| {
        const uv = mesh.vertices[i * mesh.stride + 6 ..][0..2];
        const uv_r = mesh.vertices[r * mesh.stride + 6 ..][0..2];
        if (r != i and (uv[0] != uv_r[0] or uv[1] != uv_r[1])) locks[i] |= 2;
    }

    // Groups: triangles sorted by the cell of their first corner, in a
    // grid of about one group per cell over the mesh's surface.
    const cells_per_side = @max(1, std.math.sqrt(triangle_count / group_triangles));
    const order = try gpa.alloc(u64, triangle_count);
    defer gpa.free(order);
    const scale = mo.simplifyScale(mesh.positions());
    var minv: [3]f32 = @splat(float_max);
    for (0..vertex_count) |i| {
        for (0..3) |k| minv[k] = @min(minv[k], mesh.vertices[i * mesh.stride + k]);
    }
    for (order, 0..) |*o, t| {
        const p = mesh.vertices[mesh.indices[t * 3] * mesh.stride ..][0..3];
        var cell: u64 = 0;
        for (0..3) |k| {
            const f = (p[k] - minv[k]) / scale * @as(f32, @floatFromInt(cells_per_side));
            const last: f32 = @floatFromInt(cells_per_side - 1);
            const ci: u64 = @intFromFloat(@min(@max(f, 0), last));
            cell = cell * cells_per_side + ci;
        }
        o.* = cell << 32 | t;
    }
    std.mem.sort(u64, order, {}, std.sort.asc(u64));

    var group_starts: std.ArrayList(usize) = .empty;
    defer group_starts.deinit(gpa);
    for (order, 0..) |o, i| {
        if (i == 0 or o >> 32 != order[i - 1] >> 32) try group_starts.append(gpa, i);
    }
    try group_starts.append(gpa, order.len);

    // The lock bit on positions used by more than one group.
    const seen = try gpa.alloc(u32, vertex_count);
    defer gpa.free(seen);
    @memset(seen, std.math.maxInt(u32));
    for (0..group_starts.items.len - 1) |g| {
        for (order[group_starts.items[g]..group_starts.items[g + 1]]) |o| {
            const t: usize = @as(u32, @truncate(o));
            for (mesh.indices[t * 3 ..][0..3]) |v| {
                const r = remap[v];
                if (seen[r] != std.math.maxInt(u32) and seen[r] != g) locks[r] |= 1;
                seen[r] = @intCast(g);
            }
        }
    }
    for (remap, 0..) |r, i| locks[i] = (locks[r] & 1) | (locks[i] & 2);

    var group = std.ArrayList(u32).empty;
    defer group.deinit(gpa);
    for (0..group_starts.items.len - 1) |g| {
        group.clearRetainingCapacity();
        for (order[group_starts.items[g]..group_starts.items[g + 1]]) |o| {
            const t: usize = @as(u32, @truncate(o));
            try group.appendSlice(gpa, mesh.indices[t * 3 ..][0..3]);
        }
        const merged: FloatMesh = .{
            .vertices = mesh.vertices,
            .stride = mesh.stride,
            .indices = group.items,
        };
        const target = group.items.len / 3 / 2 * 3;
        const clod: mo.SimplifyOptions = .{ .sparse = true, .error_absolute = true };
        for ([_]mo.SimplifyOptions{
            .{ .sparse = true, .error_absolute = true, .error_clamped = true, .permissive = true },
            .{
                .sparse = true,
                .error_absolute = true,
                .error_clamped = true,
                .permissive = true,
                .regularize = true,
                .preserve_folds = true,
            },
            clod,
            .{ .sparse = true, .error_absolute = true, .preserve_folds = true },
            .{ .sparse = true, .error_absolute = true, .regularize_light = true, .prune = true },
        }) |options| {
            try checkSimplify(merged, .{
                .target_index_count = target,
                .target_error = float_max,
                .options = options,
                .weights = &demo_weights,
                .locks = locks,
            });
        }
        try checkUpdate(merged, .{
            .target_index_count = target,
            .target_error = float_max,
            .options = .{ .sparse = true, .error_absolute = true, .permissive = true },
            .weights = &demo_weights,
            .locks = locks,
        });
        try checkSloppyFallback(mesh, group.items, locks, target);
    }
}

/// clusterlod.h's sloppy fallback: the group deindexed into a vertex of
/// its own per corner, then simplified sloppily, the error made absolute.
fn checkSloppyFallback(
    mesh: FloatMesh,
    group: []const u32,
    locks: []const u8,
    target: usize,
) !void {
    const subset = try gpa.alloc(f32, group.len * 4);
    defer gpa.free(subset);
    const subset_locks = try gpa.alloc(u8, group.len);
    defer gpa.free(subset_locks);
    const lod = try gpa.alloc(u32, group.len);
    defer gpa.free(lod);
    for (group, 0..) |v, i| {
        subset[i * 4 ..][0..3].* = mesh.vertices[v * mesh.stride ..][0..3].*;
        subset[i * 4 + 3] = @bitCast(v);
        subset_locks[i] = locks[v];
        lod[i] = @intCast(i);
    }
    const deindexed: FloatMesh = .{ .vertices = subset, .stride = 4, .indices = lod };
    try checkSloppy(deindexed, target, float_max, subset_locks, true);
    try checkScale(deindexed);
}

test "cluster groups simplify as the original's" {
    var pirate = try common.pirate();
    defer pirate.deinit(gpa);
    var demo: FloatMesh = try .fromMesh(pirate);
    defer demo.deinit();
    var sphere_mesh = try meshes.sphere(gpa, 64, 128);
    defer sphere_mesh.deinit(gpa);
    var sphere: FloatMesh = try .fromMesh(sphere_mesh);
    defer sphere.deinit();
    var grid = try gridSeams(96, 16);
    defer grid.deinit();
    for ([_]FloatMesh{ demo, sphere, grid }) |mesh| {
        for ([_]usize{ 256, 1024, 4096 }) |group_triangles| {
            try checkClusterGroups(mesh, group_triangles);
        }
    }
}

// --------------------------------------------------------
// Fuzzing
// --------------------------------------------------------

test "fuzzed meshes simplify as the original's, as upstream fuzzes them" {
    try common.fuzz("simplifyfuzz", 0, fuzzUpstream);
}

/// The calls of upstream's tools/simplifyfuzz.cpp.
fn fuzzUpstream(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    var mesh = try fuzzMesh(prng.random(), 4);
    defer mesh.deinit();
    try checkSimplify(mesh, .{ .target_index_count = 0, .target_error = 1e-1 });
    try checkSimplify(mesh, .{ .target_index_count = 0, .target_error = float_max });
    for ([_]mo.SimplifyOptions{
        .{ .lock_border = true },
        .{ .sparse = true },
        .{ .prune = true },
        .{ .permissive = true },
    }) |options| {
        try checkSimplify(mesh, .{
            .target_index_count = 0,
            .target_error = float_max,
            .options = options,
        });
    }
    const call: Call = .{ .target_index_count = 0, .target_error = float_max, .weights = &.{1} };
    try checkSimplify(mesh, call);
    try checkUpdate(mesh, call);
}

test "fuzzed meshes with random options, attributes and flags simplify as the original's" {
    try common.fuzz("simplify options", 1 << 20, fuzzOptions);
}

fn fuzzOptions(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var mesh = switch (rng.uintLessThan(u32, 3)) {
        0 => try fuzzMesh(rng, 8),
        1 => try gridSeams(rng.uintLessThan(u32, 12) + 1, rng.uintLessThan(u32, 4) + 1),
        else => try foldedSheet(rng.uintLessThan(u32, 8) + 2, rng.enumValue(Sides)),
    };
    defer mesh.deinit();
    if (mesh.indices.len > 0 and rng.boolean()) {
        // A random part of the mesh, for sparse use.
        const triangles = mesh.indices.len / 3;
        const first = rng.uintLessThan(usize, triangles);
        const last = rng.intRangeAtMost(usize, first, triangles);
        std.mem.copyForwards(u32, mesh.indices, mesh.indices[first * 3 .. last * 3]);
        mesh.indices = try gpa.realloc(mesh.indices, (last - first) * 3);
    }
    if (rng.boolean()) {
        // Perturbed positions.
        for (0..mesh.vertexCount()) |i| {
            for (mesh.vertices[i * mesh.stride ..][0..3]) |*p| p.* += (rng.float(f32) - 0.5) * 0.02;
        }
    }

    const locks = try randomLocks(rng, mesh.vertexCount());
    defer gpa.free(locks);
    var buffer: [5]f32 = undefined;
    const triangles = mesh.indices.len / 3;
    const call: Call = .{
        .target_index_count = rng.uintAtMost(usize, triangles) * 3,
        .target_error = errors[rng.uintLessThan(usize, errors.len)],
        .options = randomOptions(rng),
        .weights = randomWeights(rng, &buffer, 5),
        .locks = if (rng.boolean()) locks else null,
        .with_attributes = rng.boolean(),
    };
    try checkSimplify(mesh, call);
    if (rng.uintLessThan(u32, 3) == 0) try checkSimplifyInPlace(mesh, call);
    var update = call;
    update.options.internal_debug = false;
    if (rng.uintLessThan(u32, 3) == 0) try checkUpdate(mesh, update);
    if (rng.uintLessThan(u32, 4) == 0) {
        var edge = call;
        edge.options.internal_solve = rng.boolean();
        try checkEdge(mesh, edge);
    }
}

test "fuzzed meshes simplify sloppily as the original's" {
    try common.fuzz("simplifySloppy", 2 << 20, fuzzSloppy);
}

fn fuzzSloppy(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var mesh = if (rng.boolean())
        try fuzzMesh(rng, 3 + rng.uintLessThan(usize, 3))
    else
        try gridSeams(rng.uintLessThan(u32, 30) + 1, rng.uintLessThan(u32, 6) + 1);
    defer mesh.deinit();
    if (rng.boolean()) {
        for (mesh.vertices) |*v| v.* += rng.float(f32) * 0.1;
    }
    const locks = try randomLocks(rng, mesh.vertexCount());
    defer gpa.free(locks);
    const triangles = mesh.indices.len / 3;
    const target_error = if (rng.boolean())
        errors[rng.uintLessThan(usize, errors.len)]
    else
        rng.float(f32) * 0.2;
    try checkSloppy(
        mesh,
        rng.uintAtMost(usize, triangles) * 3,
        target_error,
        if (rng.boolean()) locks else null,
        rng.boolean(),
    );
}

test "fuzzed point clouds simplify as the original's" {
    try common.fuzz("simplifyPoints", 3 << 20, fuzzPoints);
}

fn fuzzPoints(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const vertex_count = rng.uintAtMost(usize, 600);
    const stride = 3 + rng.uintLessThan(usize, 4) * 2;
    var mesh: FloatMesh = .{
        .vertices = try gpa.alloc(f32, vertex_count * stride),
        .stride = stride,
        .indices = try gpa.alloc(u32, 0),
    };
    defer mesh.deinit();
    const integer = rng.boolean();
    for (mesh.vertices, 0..) |*v, i| {
        if (i >= stride and rng.uintLessThan(u32, 10) == 0) {
            v.* = mesh.vertices[i - stride];
            continue;
        }
        v.* = if (integer)
            @floatFromInt(rng.intRangeAtMost(i32, -20, 20))
        else
            rng.float(f32) * 50 - 25;
    }
    const target = rng.uintAtMost(usize, vertex_count);
    const color_offset: ?usize = if (stride >= 6 and rng.boolean()) 3 else null;
    const weight: f32 = switch (rng.uintLessThan(u32, 3)) {
        0 => 1,
        1 => 0,
        else => rng.float(f32) * 5,
    };
    try checkPoints(mesh, color_offset, weight, target);
}

test "fuzzed meshes prune as the original's" {
    try common.fuzz("simplifyPrune", 4 << 20, fuzzPrune);
}

fn fuzzPrune(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var mesh = try fuzzMesh(rng, 3);
    defer mesh.deinit();
    // Spread the vertices into a few distant groups, so some parts are
    // small and far apart.
    for (0..mesh.vertexCount()) |i| {
        const group: f32 = @floatFromInt(i % (rng.uintLessThan(usize, 8) + 1));
        const p = mesh.vertices[i * 3 ..][0..3];
        for (p) |*x| x.* = x.* * (0.01 + rng.float(f32)) + group * 20;
    }
    try checkPrune(mesh, rng.float(f32) * 0.5, rng.boolean());
    try checkPrune(mesh, errors[rng.uintLessThan(usize, errors.len)], false);
}

test "fuzzed cluster groups simplify as the original's" {
    try common.fuzz("cluster groups", 5 << 20, fuzzClusterGroup);
}

/// A random rectangle of a grid with seams, simplified as clusterlod.h
/// simplifies a group: its edge to the rest of the grid locked, seams
/// protected, sparse and in absolute error, with random extra options.
fn fuzzClusterGroup(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const n = rng.uintLessThan(u32, 40) + 8;
    var grid = try gridSeams(n, rng.uintLessThan(u32, 8) + 2);
    defer grid.deinit();

    const x0 = rng.uintLessThan(u32, n - 1);
    const x1 = rng.intRangeAtMost(u32, x0 + 1, n);
    const y0 = rng.uintLessThan(u32, n - 1);
    const y1 = rng.intRangeAtMost(u32, y0 + 1, n);
    var group: std.ArrayList(u32) = .empty;
    defer group.deinit(gpa);
    for (y0..y1) |y| try group.appendSlice(gpa, grid.indices[(y * n + x0) * 6 .. (y * n + x1) * 6]);

    const remap = try gpa.alloc(u32, grid.vertexCount());
    defer gpa.free(remap);
    try mo.generatePositionRemap(gpa, remap, grid.positions());
    const locks = try gpa.alloc(u8, grid.vertexCount());
    defer gpa.free(locks);
    @memset(locks, 0);
    for (remap, 0..) |r, i| {
        if (r != i) locks[i] |= 2;
        const p = grid.vertices[i * grid.stride ..][0..2];
        const side: f32 = @floatFromInt(n);
        const gx = @round(p[0] * side);
        const gy = @round(p[1] * side);
        const on_edge = (gx == @as(f32, @floatFromInt(x0)) and x0 > 0) or
            (gx == @as(f32, @floatFromInt(x1)) and x1 < n) or
            (gy == @as(f32, @floatFromInt(y0)) and y0 > 0) or
            (gy == @as(f32, @floatFromInt(y1)) and y1 < n);
        if (on_edge) locks[i] |= 1;
    }

    var buffer: [5]f32 = undefined;
    var options: mo.SimplifyOptions = @bitCast(@as(u32, rng.int(u9)));
    options.sparse = true;
    options.error_absolute = true;
    const call: Call = .{
        .target_index_count = group.items.len / 3 / 2 * 3,
        .target_error = if (rng.boolean()) float_max else rng.float(f32) * 0.1,
        .options = options,
        .weights = randomWeights(rng, &buffer, 5),
        .locks = locks,
    };
    const merged: FloatMesh = .{
        .vertices = grid.vertices,
        .stride = grid.stride,
        .indices = group.items,
    };
    try checkSimplify(merged, call);
    if (rng.uintLessThan(u32, 4) == 0) try checkUpdate(merged, call);
    if (rng.uintLessThan(u32, 4) == 0) {
        try checkSloppyFallback(grid, group.items, locks, call.target_index_count);
    }
}
