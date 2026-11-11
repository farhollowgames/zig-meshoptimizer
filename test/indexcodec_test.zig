//! The index codec against the original: the encoders byte for byte in
//! both versions, on every test mesh as it is, optimized for the vertex
//! cache and for vertex fetch, and on generated and random index buffers;
//! the decoders on those streams and on truncated, corrupted and random
//! buffers, with the same return codes and the same output.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const common = @import("common.zig");

const gpa = common.gpa;

const versions = [_]mo.IndexVersion{ .v0, .v1 };

test "encodeIndexBuffer and decodeIndexBuffer match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        const vertex_count = mesh.vertices.len;
        try checkIndexBuffer(mesh.indices, vertex_count, .{ .malformed = mesh.indices.len < 3000 });

        // Optimized for the vertex cache, then for vertex fetch, as the
        // encoder works best on.
        const optimized = try gpa.alloc(u32, mesh.indices.len);
        defer gpa.free(optimized);
        c.meshopt_optimizeVertexCache(
            optimized.ptr,
            mesh.indices.ptr,
            mesh.indices.len,
            vertex_count,
        );
        try checkIndexBuffer(optimized, vertex_count, .{});

        const remap = try gpa.alloc(u32, vertex_count);
        defer gpa.free(remap);
        const unique = c.meshopt_optimizeVertexFetchRemap(
            remap.ptr,
            optimized.ptr,
            optimized.len,
            vertex_count,
        );
        c.meshopt_remapIndexBuffer(optimized.ptr, optimized.ptr, optimized.len, remap.ptr);
        try checkIndexBuffer(optimized, unique, .{ .malformed = mesh.indices.len < 3000 });
    }
}

test "encodeIndexBuffer and decodeIndexBuffer match the original on generated buffers" {
    var prng: std.Random.DefaultPrng = .init(0x1dc0dec);
    const rng = prng.random();

    // Strips as triangle lists, both windings, which use the codes for one
    // more and one less than the last index.
    for ([_]u32{ 1, 2, 7, 64 }) |run| {
        const indices = try strip(rng, 300, run);
        defer gpa.free(indices);
        try checkIndexBuffer(indices, 2000, .{ .malformed = true });
    }

    // Restarts: 0, 1, 2 again after other triangles, with and without
    // vertices in between.
    const restarts = [_]u32{
        0, 1, 2, 2, 1, 3, 0, 1, 2, 0, 1, 2, 4, 5, 6, 1, 2, 0, 2, 0, 1,
        0, 1, 2, 3, 4, 5, 3, 3, 3, 0, 0, 0, 0, 1, 2, 7, 7, 8, 0, 1, 2,
    };
    try checkIndexBuffer(&restarts, 9, .{ .malformed = true });

    // Every triangle the same, and degenerate ones.
    var same: [3 * 40 + 9 * 10]u32 = undefined;
    for (0..40) |t| same[t * 3 ..][0..3].* = .{ 5, 9, 2 };
    for (0..10) |t| same[120 + t * 9 ..][0..9].* = .{ 1, 1, 2, 3, 3, 3, 4, 5, 4 };
    try checkIndexBuffer(&same, 10, .{ .malformed = true });

    // The edge fifo full of one edge, and fifo indices of every age.
    var aged: [3 * 200]u32 = undefined;
    for (0..200) |t| {
        const k: u32 = @intCast(t);
        aged[t * 3 ..][0..3].* = .{ k % 17, (k * 7) % 23, k };
    }
    try checkIndexBuffer(&aged, 200, .{ .malformed = true });

    // Large indices, to the full 32 bits, which take 5-byte varints.
    const large = [_]u32{
        0xffff_ffff, 0,           0x8000_0000, 0x7fff_ffff, 0xffff_fffe, 1,
        0xffff_ffff, 0x7fff_ffff, 2,           0x1234_5678, 0x0012_3456, 0xfedc_ba98,
    };
    try checkIndexBuffer(&large, 1 << 32, .{ .malformed = true });

    // No triangles at all.
    try checkIndexBuffer(&.{}, 0, .{ .malformed = true });
}

test "encodeIndexBuffer and decodeIndexBuffer match the original on random buffers" {
    for (0..48) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rng = prng.random();
        const triangle_count = rng.uintLessThan(usize, 600);
        const vertex_count: u64 = switch (seed % 4) {
            0 => 3 + rng.uintLessThan(u64, 30),
            1 => 3 + rng.uintLessThan(u64, 1000),
            2 => 3 + rng.uintLessThan(u64, 1 << 20),
            else => 1 << 32,
        };
        const indices = try gpa.alloc(u32, triangle_count * 3);
        defer gpa.free(indices);
        for (indices, 0..) |*index, i| {
            // Mostly near the last ones, as real buffers are, so the
            // fifos hit.
            index.* = if (i > 0 and rng.uintLessThan(u32, 4) != 0)
                indices[i - 1 - rng.uintLessThan(usize, @min(i, 12))]
            else
                @intCast(rng.uintLessThan(u64, vertex_count));
        }
        try checkIndexBuffer(indices, vertex_count, .{ .malformed = triangle_count < 200 });
    }
}

test "encodeIndexBufferBound and encodeIndexSequenceBound match the original" {
    const counts = [_]usize{ 0, 3, 6, 999, 3000, 3 << 20, 3 << 30 };
    const vertex_counts = [_]usize{
        0,       1,       2,                      3,       127,           128,     129,
        1 << 14, 1 << 21, (1 << 21) + 1,          1 << 28, (1 << 28) + 1, 1 << 31, (1 << 31) + 1,
        1 << 32, 1 << 40, std.math.maxInt(usize),
    };
    for (counts) |index_count| for (vertex_counts) |vertex_count| {
        try common.expectSameValue(
            usize,
            "encodeIndexBufferBound",
            c.meshopt_encodeIndexBufferBound(index_count, vertex_count),
            mo.encodeIndexBufferBound(index_count, vertex_count),
        );
        try common.expectSameValue(
            usize,
            "encodeIndexSequenceBound",
            c.meshopt_encodeIndexSequenceBound(index_count, vertex_count),
            mo.encodeIndexSequenceBound(index_count, vertex_count),
        );
    };
}

test "decodeIndexVersion matches the original on every header" {
    for (0..256) |header| {
        const buffer = [_]u8{ @intCast(header), 0x55 };
        for (0..3) |len| {
            const version = mo.decodeIndexVersion(buffer[0..len]);
            const got: c_int = if (version) |v| @backingInt(v) else -1;
            try common.expectSameValue(
                c_int,
                "decodeIndexVersion",
                c.meshopt_decodeIndexVersion(&buffer, len),
                got,
            );
        }
    }
}

test "decodeIndexBuffer matches the original on random buffers" {
    var prng: std.Random.DefaultPrng = .init(0xdec0de);
    const rng = prng.random();
    var buffer: [600]u8 = undefined;
    for (0..4000) |_| {
        const len = rng.uintLessThan(usize, buffer.len);
        rng.bytes(buffer[0..len]);
        // Mostly a valid header, so decoding gets past it.
        if (len > 0 and rng.uintLessThan(u32, 8) != 0) buffer[0] = 0xe0 | rng.uintLessThan(u8, 2);
        const index_count = 3 * rng.uintLessThan(usize, 200);
        try checkDecodeIndexBuffer(buffer[0..len], index_count);
    }
}

test "encodeIndexSequence and decodeIndexSequence match the original on every mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        try checkIndexSequence(mesh.indices, mesh.vertices.len, mesh.indices.len < 3000);
    }
}

test "encodeIndexSequence and decodeIndexSequence match the original on generated sequences" {
    var prng: std.Random.DefaultPrng = .init(0x5e9);
    const rng = prng.random();

    // Differences right at the baseline switch, of either sign, and the
    // largest the format holds.
    const edges = [_]u32{
        0, 29, 0, 30, 0, 31, 61,  30, 1,  0x3fff_ffff, 0, 0x3fff_ffff, 0x7fff_ffff,
        5, 4,  3, 2,  1, 0,  100, 70, 41, 12,          0, 0xc000_0000, 0x4000_0000,
    };
    try checkIndexSequence(&edges, 1 << 32, true);

    // Differences of 2^30 and more do not fit the format, but the encoder
    // and decoder still agree with the original's.
    const wide = [_]u32{ 0x8000_0000, 0, 0xffff_ffff, 0x4000_0000, 0x8000_0001, 1, 0x7fff_ffff };
    try checkIndexSequence(&wide, 1 << 32, true);

    // Two interleaved runs, as from strips or lines, which the two
    // baselines follow.
    for (0..6) |seed| {
        const count = 50 + seed * 97;
        const sequence = try gpa.alloc(u32, count);
        defer gpa.free(sequence);
        var runs: [2]u32 = .{ rng.int(u32) >> 4, rng.int(u32) >> 4 };
        for (sequence) |*index| {
            const run = rng.uintLessThan(usize, 2);
            const step = rng.intRangeAtMost(i32, -40, 40);
            runs[run] +%= @bitCast(step);
            index.* = runs[run];
        }
        try checkIndexSequence(sequence, 1 << 32, count < 400);
    }

    // Uniformly random sequences, and none at all.
    for (0..8) |seed| {
        const count = rng.uintLessThan(usize, 500);
        const sequence = try gpa.alloc(u32, count);
        defer gpa.free(sequence);
        const range: u64 = @as(u64, 1) << @intCast(4 + seed * 4);
        for (sequence) |*index| index.* = @intCast(rng.uintLessThan(u64, range));
        try checkIndexSequence(sequence, range, true);
    }
    try checkIndexSequence(&.{}, 0, true);
}

test "decodeIndexSequence matches the original on random buffers" {
    var prng: std.Random.DefaultPrng = .init(0x5e9dec);
    const rng = prng.random();
    var buffer: [400]u8 = undefined;
    for (0..4000) |_| {
        const len = rng.uintLessThan(usize, buffer.len);
        rng.bytes(buffer[0..len]);
        // Mostly a valid header, and mostly one-byte varints, so decoding
        // gets past them.
        if (len > 0 and rng.uintLessThan(u32, 8) != 0) buffer[0] = 0xd0 | rng.uintLessThan(u8, 2);
        if (rng.boolean()) {
            for (buffer[@min(len, 1)..len]) |*b| b.* &= 0x7f | (rng.int(u8) & rng.int(u8) & 0x80);
        }
        const index_count = rng.uintLessThan(usize, 300);
        try checkDecodeIndexSequence(buffer[0..len], index_count);
    }
}

// --------------------------------------------------------
// Helpers
// --------------------------------------------------------

const CheckOptions = struct {
    /// Also decode every truncation and many corruptions of the streams.
    malformed: bool = false,
};

/// A triangle strip over consecutive vertices, as a list; every `run`
/// triangles it jumps to a random place.
fn strip(rng: std.Random, triangle_count: usize, run: u32) ![]u32 {
    const indices = try gpa.alloc(u32, triangle_count * 3);
    var base: u32 = 0;
    for (0..triangle_count) |t| {
        if (t % run == 0) base = rng.uintLessThan(u32, 1000);
        const k: u32 = @intCast(t % run);
        const v = base + k;
        indices[t * 3 ..][0..3].* = if (k & 1 == 0) .{ v, v + 1, v + 2 } else .{ v + 1, v, v + 2 };
    }
    return indices;
}

/// Encodes `indices` with both, in each version, into buffers of the
/// bound's size and of sizes around the encoded size, then decodes the
/// stream with both.
fn checkIndexBuffer(indices: []const u32, vertex_count: u64, options: CheckOptions) !void {
    defer c.meshopt_encodeIndexVersion(1);

    const bound = c.meshopt_encodeIndexBufferBound(indices.len, vertex_count);
    try common.expectSameValue(
        usize,
        "encodeIndexBufferBound",
        bound,
        mo.encodeIndexBufferBound(indices.len, vertex_count),
    );

    const want = try gpa.alloc(u8, bound);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, bound);
    defer gpa.free(got);

    for (versions) |version| {
        c.meshopt_encodeIndexVersion(@backingInt(version));

        const want_size = c.meshopt_encodeIndexBuffer(want.ptr, want.len, indices.ptr, indices.len);
        const got_size = mo.encodeIndexBuffer(got, indices, version) catch 0;
        try common.expectSameValue(usize, "encodeIndexBuffer size", want_size, got_size);
        try common.expectSame(u8, "encodeIndexBuffer", want[0..want_size], got[0..got_size]);

        // Buffers too small, just big enough, and in between.
        const sizes = [_]usize{
            0,
            1,
            16,
            indices.len / 3 + 16,
            indices.len / 3 + 17,
            want_size / 2,
            want_size -| 1,
            want_size,
        };
        for (sizes) |size| {
            const want_fit = c.meshopt_encodeIndexBuffer(want.ptr, size, indices.ptr, indices.len);
            const got_fit = mo.encodeIndexBuffer(got[0..size], indices, version) catch 0;
            try common.expectSameValue(usize, "encodeIndexBuffer fit", want_fit, got_fit);
        }

        const stream = want[0..want_size];
        try checkDecodeIndexBuffer(stream, indices.len);

        // The decoded triangles are the input's, in the same order and
        // winding, possibly rotated.
        const decoded = try gpa.alloc(u32, indices.len);
        defer gpa.free(decoded);
        try mo.decodeIndexBuffer(u32, decoded, stream);
        for (0..indices.len / 3) |t| {
            const in = common.canonicalTriangle(u32, indices[t * 3 ..][0..3].*);
            const out = common.canonicalTriangle(u32, decoded[t * 3 ..][0..3].*);
            try common.expectSameValue([3]u32, "decodeIndexBuffer round trip", in, out);
        }

        if (options.malformed) try checkMalformedIndexBuffer(stream, indices.len);
    }
}

/// Decodes `stream` truncated at every length from either end, with wrong
/// index counts, and with bytes changed one at a time.
fn checkMalformedIndexBuffer(stream: []const u8, index_count: usize) !void {
    for (0..stream.len) |len| {
        try checkDecodeIndexBuffer(stream[0..len], index_count);
        try checkDecodeIndexBuffer(stream[stream.len - len ..], index_count);
    }
    for ([_]usize{ 3, 6, 30 }) |delta| {
        try checkDecodeIndexBuffer(stream, index_count + delta);
        if (index_count >= delta) try checkDecodeIndexBuffer(stream, index_count - delta);
    }

    const copy = try gpa.dupe(u8, stream);
    defer gpa.free(copy);
    var prng: std.Random.DefaultPrng = .init(stream.len);
    const rng = prng.random();
    for (0..copy.len) |i| {
        for ([_]u8{ 0x01, 0x80, 0xff, rng.int(u8) | 1 }) |flip| {
            copy[i] ^= flip;
            try checkDecodeIndexBuffer(copy, index_count);
            copy[i] ^= flip;
        }
    }
}

/// Decodes `buffer` as `index_count` indices of either size with both,
/// into outputs filled alike, and compares the results and all of the
/// outputs.
fn checkDecodeIndexBuffer(buffer: []const u8, index_count: usize) !void {
    inline for (.{ u16, u32 }) |T| {
        const want = try gpa.alloc(T, index_count);
        defer gpa.free(want);
        const got = try gpa.alloc(T, index_count);
        defer gpa.free(got);
        @memset(want, @truncate(0xa5a5_a5a5));
        @memset(got, @truncate(0xa5a5_a5a5));

        const want_rc = c.meshopt_decodeIndexBuffer(
            want.ptr,
            index_count,
            @sizeOf(T),
            buffer.ptr,
            buffer.len,
        );
        const got_rc = resultCode(mo.decodeIndexBuffer(T, got, buffer));
        try common.expectSameValue(c_int, "decodeIndexBuffer result", want_rc, got_rc);
        try common.expectSame(T, "decodeIndexBuffer", want, got);
    }
}

fn checkIndexSequence(indices: []const u32, vertex_count: u64, malformed: bool) !void {
    defer c.meshopt_encodeIndexVersion(1);

    const bound = c.meshopt_encodeIndexSequenceBound(indices.len, vertex_count);
    try common.expectSameValue(
        usize,
        "encodeIndexSequenceBound",
        bound,
        mo.encodeIndexSequenceBound(indices.len, vertex_count),
    );

    // Room for differences the bound does not count on.
    const capacity = bound + indices.len * 5;
    const want = try gpa.alloc(u8, capacity);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, capacity);
    defer gpa.free(got);

    for (versions) |version| {
        c.meshopt_encodeIndexVersion(@backingInt(version));

        const want_size = c.meshopt_encodeIndexSequence(
            want.ptr,
            want.len,
            indices.ptr,
            indices.len,
        );
        const got_size = mo.encodeIndexSequence(got, indices, version) catch 0;
        try common.expectSameValue(usize, "encodeIndexSequence size", want_size, got_size);
        try common.expectSame(u8, "encodeIndexSequence", want[0..want_size], got[0..got_size]);

        const sizes = [_]usize{
            0,
            1,
            4,
            indices.len + 4,
            indices.len + 5,
            want_size / 2,
            want_size -| 1,
            want_size,
        };
        for (sizes) |size| {
            const want_fit = c.meshopt_encodeIndexSequence(
                want.ptr,
                size,
                indices.ptr,
                indices.len,
            );
            const got_fit = mo.encodeIndexSequence(got[0..size], indices, version) catch 0;
            try common.expectSameValue(usize, "encodeIndexSequence fit", want_fit, got_fit);
        }

        const stream = want[0..want_size];
        try checkDecodeIndexSequence(stream, indices.len);

        if (malformed) {
            for (0..stream.len) |len| {
                try checkDecodeIndexSequence(stream[0..len], indices.len);
                try checkDecodeIndexSequence(stream[stream.len - len ..], indices.len);
            }
            for ([_]usize{ 1, 2, 10 }) |delta| {
                try checkDecodeIndexSequence(stream, indices.len + delta);
                if (indices.len >= delta) try checkDecodeIndexSequence(stream, indices.len - delta);
            }
            const copy = try gpa.dupe(u8, stream);
            defer gpa.free(copy);
            for (0..copy.len) |i| {
                for ([_]u8{ 0x01, 0x40, 0x80, 0xff }) |flip| {
                    copy[i] ^= flip;
                    try checkDecodeIndexSequence(copy, indices.len);
                    copy[i] ^= flip;
                }
            }
        }
    }
}

fn checkDecodeIndexSequence(buffer: []const u8, index_count: usize) !void {
    inline for (.{ u16, u32 }) |T| {
        const want = try gpa.alloc(T, index_count);
        defer gpa.free(want);
        const got = try gpa.alloc(T, index_count);
        defer gpa.free(got);
        @memset(want, @truncate(0xa5a5_a5a5));
        @memset(got, @truncate(0xa5a5_a5a5));

        const want_rc = c.meshopt_decodeIndexSequence(
            want.ptr,
            index_count,
            @sizeOf(T),
            buffer.ptr,
            buffer.len,
        );
        const got_rc = resultCode(mo.decodeIndexSequence(T, got, buffer));
        try common.expectSameValue(c_int, "decodeIndexSequence result", want_rc, got_rc);
        try common.expectSame(T, "decodeIndexSequence", want, got);
    }
}

/// The original's return code for a decoder's result.
fn resultCode(result: mo.IndexDecodeError!void) c_int {
    result catch |err| return switch (err) {
        error.InvalidHeader => -1,
        error.Truncated => -2,
        error.SizeMismatch => -3,
    };
    return 0;
}
