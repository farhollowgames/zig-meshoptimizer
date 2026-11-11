//! Spatial ordering: points and triangles sorted along a Morton curve, and
//! points grouped into clusters by recursive splits, for memory locality.
//!
//! Translated from meshoptimizer's spatialorder.cpp, which builds on
//! Giesen, "Decoding Morton codes" (2009).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const VertexFloats = @import("strided.zig").VertexFloats;
const checkIndex = @import("index.zig").check;
const convert = @import("convert.zig");
const truncate = convert.truncate;

/// `x` converted to 64 bits as C converts an `int` to `unsigned long long`:
/// sign-extended. `x` is an `i32` or a vector of them.
fn widen(x: anytype) Wide(@TypeOf(x)) {
    return @bitCast(@as(Signed(@TypeOf(x)), x));
}

fn Wide(comptime T: type) type {
    return if (T == i32) u64 else @Vector(@typeInfo(T).vector.len, u64);
}

fn Signed(comptime T: type) type {
    return if (T == i32) i64 else @Vector(@typeInfo(T).vector.len, i64);
}

/// Spreads the low 20 bits of `x` apart, two zero bits after each. `x` is a
/// `u64` or a vector of them.
fn part1By2(x_in: anytype) @TypeOf(x_in) {
    const T = @TypeOf(x_in);
    const Amount = if (T == u64) u6 else @Vector(@typeInfo(T).vector.len, u6);
    const mask = struct {
        fn of(comptime m: u64) T {
            return if (T == u64) m else @splat(m);
        }
    }.of;
    const by = struct {
        fn of(comptime n: u6) Amount {
            return if (T == u64) n else @splat(n);
        }
    }.of;
    // ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- ---- jihg fedc ba98 7654 3210
    var x = x_in & mask(0x000fffff);
    // ---- ---- ---- jihg ---- ---- ---- ---- ---- ---- ---- ---- fedc ba98 7654 3210
    x = (x ^ (x << by(32))) & mask(0x000f00000000ffff);
    // ---- ---- ---- jihg ---- ---- ---- ---- fedc ba98 ---- ---- ---- ---- 7654 3210
    x = (x ^ (x << by(16))) & mask(0x000f0000ff0000ff);
    // ---- ---- ---- jihg ---- ---- fedc ---- ---- ba98 ---- ---- 7654 ---- ---- 3210
    x = (x ^ (x << by(8))) & mask(0x000f00f00f00f00f);
    // ---- ---- ji-- --hg ---- fe-- --dc ---- ba-- --98 ---- 76-- --54 ---- 32-- --10
    x = (x ^ (x << by(4))) & mask(0x00c30c30c30c30c3);
    // ---- --j- -i-- h--g --f- -e-- d--c --b- -a-- 9--8 --7- -6-- 5--4 --3- -2-- 1--0
    x = (x ^ (x << by(2))) & mask(0x0249249249249249);
    return x;
}

/// Vertices per vector step of the loops Zig would leave scalar.
const lanes = 8;

/// Writes a key per vertex: its position inside the mesh's bounding cube,
/// 16 bits per axis, as a Morton code if `morton`, else as x, y and z in
/// fields of 20 bits.
fn computeOrder(result: []u64, positions: VertexFloats, comptime morton: bool) void {
    // The bounds in the first three lanes of four; the fourth repeats z.
    var min4: @Vector(4, f32) = @splat(std.math.floatMax(f32));
    var max4: @Vector(4, f32) = @splat(-std.math.floatMax(f32));

    for (0..result.len) |i| {
        const v = positions.vec3(i);
        const v4: @Vector(4, f32) = .{ v[0], v[1], v[2], v[2] };

        min4 = @select(f32, min4 > v4, v4, min4);
        max4 = @select(f32, max4 < v4, v4, max4);
    }

    const minv: [3]f32 = .{ min4[0], min4[1], min4[2] };
    const maxv: [3]f32 = .{ max4[0], max4[1], max4[2] };

    var extent: f32 = 0;

    for (minv, maxv) |min, max| extent = if (max - min < extent) extent else max - min;

    // Each axis scales to 16 bits, for 48-bit Morton codes.
    const scale: f32 = if (extent == 0) 0 else 65535.0 / extent;

    const Floats = @Vector(lanes, f32);
    const Keys = @Vector(lanes, u64);
    var start: usize = 0;
    while (start + lanes <= result.len) : (start += lanes) {
        var axes: [3][lanes]f32 = undefined;
        for (0..lanes) |l| {
            const v = positions.vec3(start + l);
            for (&axes, v) |*axis, vj| axis[l] = vj;
        }

        var cells: [3]Keys = undefined;
        for (&cells, axes, minv) |*cell, axis, min| {
            const offset = @as(Floats, axis) - @as(Floats, @splat(min));
            const rounded = offset * @as(Floats, @splat(scale)) + @as(Floats, @splat(0.5));
            cell.* = widen(convert.truncateLanes(lanes, rounded));
        }
        const x, const y, const z = cells;

        result[start..][0..lanes].* = if (morton)
            part1By2(x) | (part1By2(y) << @splat(1)) | (part1By2(z) << @splat(2))
        else
            x | (y << @splat(20)) | (z << @splat(40));
    }

    for (result[start..], start..) |*key, i| {
        const v = positions.vec3(i);

        const x = widen(truncate((v[0] - minv[0]) * scale + 0.5));
        const y = widen(truncate((v[1] - minv[1]) * scale + 0.5));
        const z = widen(truncate((v[2] - minv[2]) * scale + 0.5));

        key.* = if (morton)
            part1By2(x) | (part1By2(y) << 1) | (part1By2(z) << 2)
        else
            (x << 0) | (y << 20) | (z << 40);
    }
}

/// Writes 0, 1, 2 and on to `list`.
fn writeIdentity(list: []u32) void {
    const Indices = @Vector(lanes, u32);
    var next: Indices = std.simd.iota(u32, lanes);
    var start: usize = 0;
    while (start + lanes <= list.len) : (start += lanes) {
        list[start..][0..lanes].* = next;
        next += @splat(lanes);
    }
    for (list[start..], start..) |*item, i| item.* = @intCast(i);
}

/// Writes `(key >> shift) & mask` of each key to `segments`.
fn writeSegments(segments: []u16, keys: []const u64, shift: u6, mask: u16) void {
    const Keys = @Vector(lanes, u64);
    var start: usize = 0;
    while (start + lanes <= keys.len) : (start += lanes) {
        const key: Keys = keys[start..][0..lanes].*;
        const segment = (key >> @splat(shift)) & @as(Keys, @splat(mask));
        segments[start..][0..lanes].* = @as(@Vector(lanes, u16), @intCast(segment));
    }
    for (keys[start..], segments[start..]) |key, *segment| {
        segment.* = @intCast((key >> shift) & mask);
    }
}

/// One counting sort pass over 10-bit `keys`: `source`'s items, which index
/// `keys`, go to `destination` in key order, equal keys keeping their order.
fn radixSort10(destination: []u32, source: []const u32, keys: []const u16) void {
    var hist: [1024]u32 = @splat(0);

    for (keys) |key| hist[key] += 1;

    // Each key's first place.
    var sum: u32 = 0;

    for (&hist) |*h| {
        const count = h.*;
        h.* = sum;
        sum += count;
    }

    for (source) |item| {
        const id = keys[item];

        destination[hist[id]] = item;
        hist[id] += 1;
    }
}

/// Two 8-bit histograms of `data` at once, the low and the high byte, as
/// each value's first place in a counting sort by that byte.
fn computeHistogram(hist: *[256][2]u32, data: []const u16) void {
    hist.* = @splat(@splat(0));

    for (data) |id| {
        hist[id & 255][0] += 1;
        hist[id >> 8][1] += 1;
    }

    var sum0: u32 = 0;
    var sum1: u32 = 0;

    for (hist) |*h| {
        const h0 = h[0];
        const h1 = h[1];

        h[0] = sum0;
        h[1] = sum1;

        sum0 += h0;
        sum1 += h1;
    }
}

/// One counting sort pass of `source`'s items, which index `keys`, by the
/// low byte of their keys (pass 0) or the high one (pass 1).
fn radixPass(
    destination: []u32,
    source: []const u32,
    keys: []const u16,
    hist: *[256][2]u32,
    comptime pass: u1,
) void {
    const bitoff = @as(u4, pass) * 8;

    for (source) |item| {
        const id: u8 = @truncate(keys[item] >> bitoff);

        destination[hist[id][pass]] = item;
        hist[id][pass] += 1;
    }
}

/// Writes the points of `order` to `target` with those on side 0 first,
/// `split` of them, each side keeping its order.
fn partitionPoints(target: []u32, order: []const u32, sides: []const u8, split: usize) void {
    var l: usize = 0;
    var r = split;

    for (order) |point| {
        const side = sides[point];
        target[if (side != 0) r else l] = point;
        l += 1;
        l -= side;
        r += side;
    }

    // `sides` marked exactly `split` of the points 0.
    assert(l == split and r == order.len);
}

/// Writes the points to `destination` in clusters of `cluster_size`, each
/// compact in space: the points, sorted along each axis in `orderx`,
/// `ordery` and `orderz`, split in about half across their widest axis,
/// and each half again until it fits a cluster. `scratch` holds 8 bytes per
/// point of the whole set.
fn splitPoints(
    destination: []u32,
    orderx: []u32,
    ordery: []u32,
    orderz: []u32,
    keys: []const u64,
    scratch: []u32,
    cluster_size: usize,
) void {
    const count = orderx.len;

    if (count <= cluster_size) {
        @memcpy(destination[0..count], orderx);
        return;
    }

    const axes = [3][]u32{ orderx, ordery, orderz };

    var bestk: usize = 0;
    var bestdim: u32 = 0;

    for (axes, 0..) |axis, k| {
        const mask = (1 << 20) - 1;
        const shift: u6 = @intCast(k * 20);
        const last: u32 = @truncate(keys[axis[count - 1]] >> shift);
        const first: u32 = @truncate(keys[axis[0]] >> shift);
        const dim = (last & mask) -% (first & mask);

        if (dim >= bestdim) {
            bestk = k;
            bestdim = dim;
        }
    }

    // Split in about half, the left side a whole number of clusters.
    const split = ((count / 2) + cluster_size - 1) / cluster_size * cluster_size;

    // Mark the side of the split each point is on; points index the marks.
    const sides = std.mem.sliceAsBytes(scratch)[count * @sizeOf(u32) ..];

    for (axes[bestk][0..split]) |point| sides[point] = 0;

    for (axes[bestk][split..]) |point| sides[point] = 1;

    // Split the other axes the same way, each side keeping its order.
    const temp = scratch[0..count];

    for (axes, 0..) |axis, k| {
        if (k == bestk) continue;

        @memcpy(temp, axis);
        partitionPoints(axis, temp, sides, split);
    }

    // Each split halves the points, so the recursion is about
    // log2(count / cluster_size) deep.
    splitPoints(
        destination,
        orderx[0..split],
        ordery[0..split],
        orderz[0..split],
        keys,
        scratch,
        cluster_size,
    );
    splitPoints(
        destination[split..],
        orderx[split..],
        ordery[split..],
        orderz[split..],
        keys,
        scratch,
        cluster_size,
    );
}

/// Fills `destination[0..vertex_count]` with a remap table that orders the
/// points along a Morton curve, for spatial locality; it maps old places to
/// new ones, for `remapVertexBuffer`.
pub fn spatialSortRemap(
    gpa: Allocator,
    destination: []u32,
    positions: VertexFloats,
) Allocator.Error!void {
    assert(positions.stride >= 3 and positions.stride <= 64);
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const keys = try scratch.alloc(u64, vertex_count);
    computeOrder(keys, positions, true);

    // 4 bytes per point for an order, then 2 for its key segment.
    const work = try scratch.alloc(u32, vertex_count * 2);
    const key_segments = std.mem.bytesAsSlice(
        u16,
        std.mem.sliceAsBytes(work[vertex_count..]),
    )[0..vertex_count];

    const remap = destination[0..vertex_count];

    writeIdentity(remap);

    const order = [2][]u32{ work[0..vertex_count], remap };

    // A 5-pass radix sort, which leaves the order in `work`.
    inline for (0..5) |k| {
        // Each pass's 10-bit key segments go in their own array, to ease
        // the pass's cache pressure.
        const shift: u6 = @intCast(k * 10);

        writeSegments(key_segments, keys, shift, 1023);

        radixSort10(order[k % 2], order[(k + 1) % 2], key_segments);
    }

    // The table maps old places to new ones, the order's inverse.
    for (order[0], 0..) |point, i| remap[point] = @intCast(i);
}

/// Writes the triangles of `indices` to `destination` sorted along a Morton
/// curve by their centroids, for spatial locality; optimize the result for
/// the vertex cache after. `destination` may be `indices` itself.
pub fn spatialSortTriangles(
    comptime Index: type,
    gpa: Allocator,
    destination: []Index,
    indices: []const Index,
    positions: VertexFloats,
) Allocator.Error!void {
    comptime checkIndex(Index);
    assert(indices.len % 3 == 0);
    assert(positions.stride >= 3 and positions.stride <= 64);
    const vertex_count = positions.count();

    const face_count = indices.len / 3;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const centroids = try scratch.alloc(f32, face_count * 3);

    for (0..face_count) |i| {
        const a = indices[i * 3 + 0];
        const b = indices[i * 3 + 1];
        const c = indices[i * 3 + 2];
        assert(a < vertex_count and b < vertex_count and c < vertex_count);

        const va = positions.vec3(a);
        const vb = positions.vec3(b);
        const vc = positions.vec3(c);

        centroids[i * 3 + 0] = (va[0] + vb[0] + vc[0]) / 3.0;
        centroids[i * 3 + 1] = (va[1] + vb[1] + vc[1]) / 3.0;
        centroids[i * 3 + 2] = (va[2] + vb[2] + vc[2]) / 3.0;
    }

    const remap = try scratch.alloc(u32, face_count);

    try spatialSortRemap(gpa, remap, .init(centroids, 3));

    var source = indices;
    if (destination.ptr == indices.ptr) {
        const copy = try scratch.alloc(Index, indices.len);
        @memcpy(copy, indices);
        source = copy;
    }

    for (remap, 0..) |r, i| {
        destination[@as(usize, r) * 3 ..][0..3].* = source[i * 3 ..][0..3].*;
    }
}

/// Writes the points to `destination` in clusters of `cluster_size` points,
/// each compact in space, as indices; only the last cluster may be smaller.
pub fn spatialClusterPoints(
    gpa: Allocator,
    destination: []u32,
    positions: VertexFloats,
    cluster_size: usize,
) Allocator.Error!void {
    assert(positions.stride >= 3 and positions.stride <= 64);
    assert(cluster_size > 0);
    const vertex_count = positions.count();

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const keys = try scratch.alloc(u64, vertex_count);
    computeOrder(keys, positions, false);

    const order = try scratch.alloc(u32, vertex_count * 3);
    // 4 bytes per point for an order, then 1 for a side or 2 for a key
    // segment.
    const work = try scratch.alloc(u32, vertex_count * 2);
    const key_segments = std.mem.bytesAsSlice(
        u16,
        std.mem.sliceAsBytes(work[vertex_count..]),
    )[0..vertex_count];

    inline for (0..3) |k| {
        // The axis's 16-bit key segments go in their own array, to ease the
        // passes' cache pressure.
        const shift: u6 = @intCast(k * 20);

        writeSegments(key_segments, keys, shift, 0xffff);

        var hist: [256][2]u32 = undefined;
        computeHistogram(&hist, key_segments);

        const axis = order[k * vertex_count ..][0..vertex_count];

        writeIdentity(axis);

        radixPass(work[0..vertex_count], axis, key_segments, &hist, 0);
        radixPass(axis, work[0..vertex_count], key_segments, &hist, 1);
    }

    splitPoints(
        destination[0..vertex_count],
        order[0..vertex_count],
        order[vertex_count..][0..vertex_count],
        order[2 * vertex_count ..],
        keys,
        work,
        cluster_size,
    );
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "morton codes interleave the axes" {
    const one = part1By2(@as(u64, 1));
    try testing.expectEqual(0b111, one | one << 1 | one << 2);
    try testing.expectEqual(0b1000, part1By2(@as(u64, 2)));
    try testing.expectEqual(0x0249249249249249, part1By2(@as(u64, 0xfffff)));
    const lanes_in: @Vector(2, u64) = .{ 2, 0xfffff };
    const spread: [2]u64 = part1By2(lanes_in);
    try testing.expectEqual([2]u64{ 0b1000, 0x0249249249249249 }, spread);
}

test "a remap orders points along the curve" {
    // Corners of a square, out of curve order.
    const positions = [_]f32{ 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    var remap: [4]u32 = undefined;
    try spatialSortRemap(testing.allocator, &remap, .init(&positions, 3));
    try testing.expectEqualSlices(u32, &.{ 3, 0, 1, 2 }, &remap);
}
