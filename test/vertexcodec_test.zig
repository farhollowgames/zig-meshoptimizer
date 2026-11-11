//! The vertex codec against the original. The encoder's bytes at every
//! level and version, on the demo mesh, quantized meshes, generated vertex
//! buffers of every vertex size and fuzzed ones; every decoder of the port
//! on those and on truncated, corrupted and random buffers, with the
//! original's results and, where decoding succeeds, its bytes. The SIMD
//! decoders are checked against the original's SIMD decoder, the scalar one
//! against the original's scalar decoder: on some malformed buffers the two
//! return different errors. Every run of the port is repeated into an
//! output of a different byte pattern, which must come out the same.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const vc = mo.vertexcodec;

/// The original's decoder built without SIMD, from test/reference.cpp.
extern fn reference_scalar_decodeVertexBuffer(
    destination: ?*anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;

/// The original's result code for a decoder result.
fn codeOf(result: mo.DecodeVertexError!void) c_int {
    result catch |err| return switch (err) {
        error.InvalidHeader => -1,
        error.InvalidData => -2,
        error.LengthMismatch => -3,
    };
    return 0;
}

fn blockSize(vertex_size: usize) usize {
    return @min((8192 / vertex_size) & ~@as(usize, 15), 256);
}

/// An encoded stream; `deinit` frees it.
const Encoded = struct {
    bytes: []u8,
    size: usize,

    fn stream(self: Encoded) []const u8 {
        return self.bytes[0..self.size];
    }

    fn deinit(self: *Encoded) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Encodes `vertices` with the original and the port, fails unless both
/// write the same bytes and the same size, and returns the stream.
fn checkEncode(
    vertices: []const u8,
    vertex_size: usize,
    level: u4,
    version: mo.VertexVersion,
) !Encoded {
    const vertex_count = vertices.len / vertex_size;
    const bound = c.meshopt_encodeVertexBufferBound(vertex_count, vertex_size);
    const got_bound = mo.encodeVertexBufferBound(vertex_count, vertex_size);
    try common.expectSameValue(usize, "encodeVertexBufferBound", bound, got_bound);

    const want = try gpa.alloc(u8, bound);
    errdefer gpa.free(want);
    const got = try gpa.alloc(u8, bound);
    defer gpa.free(got);

    const want_size = c.meshopt_encodeVertexBufferLevel(
        want.ptr,
        bound,
        vertices.ptr,
        vertex_count,
        vertex_size,
        level,
        @backingInt(version),
    );
    @memset(got, 0);
    const got_size = mo.encodeVertexBufferLevel(got, vertices, vertex_size, level, version);
    try common.expectSameValue(usize, "encoded size", want_size, got_size);
    try common.expectSame(u8, "encoded bytes", want[0..want_size], got[0..got_size]);
    if (want_size == 0) return error.Mismatch;

    // The same bytes again, over a different pattern.
    @memset(got, 0x55);
    const again_size = mo.encodeVertexBufferLevel(got, vertices, vertex_size, level, version);
    try common.expectSameValue(usize, "encoded size, again", want_size, again_size);
    try common.expectSame(u8, "encoded bytes, again", want[0..want_size], got[0..again_size]);

    if (level == 2 and version == mo.VertexVersion.default) {
        const default_size = mo.encodeVertexBuffer(got, vertices, vertex_size);
        try common.expectSame(u8, "encodeVertexBuffer", want[0..want_size], got[0..default_size]);
    }

    return .{ .bytes = want, .size = want_size };
}

fn expectDecoded(
    what: []const u8,
    want_code: c_int,
    want: []const u8,
    got_code: c_int,
    got: []const u8,
) !void {
    if (want_code != got_code) {
        std.debug.print("{s}: original returns {d}, port {d}\n", .{ what, want_code, got_code });
        return error.Mismatch;
    }
    // On an error the output is unspecified.
    if (want_code == 0) try common.expectSame(u8, what, want, got);
}

/// Decodes `stream` with the original's decoders and every decoder of the
/// port, fails unless each of the port's matches its original, and returns
/// the original's result.
fn checkDecode(stream: []const u8, vertex_count: usize, vertex_size: usize) !c_int {
    const size = vertex_count * vertex_size;
    const want = try gpa.alloc(u8, size);
    defer gpa.free(want);
    const want_scalar = try gpa.alloc(u8, size);
    defer gpa.free(want_scalar);
    const got = try gpa.alloc(u8, size);
    defer gpa.free(got);
    const again = try gpa.alloc(u8, size);
    defer gpa.free(again);

    const want_code = c.meshopt_decodeVertexBuffer(
        want.ptr,
        vertex_count,
        vertex_size,
        stream.ptr,
        stream.len,
    );
    const want_scalar_code = reference_scalar_decodeVertexBuffer(
        want_scalar.ptr,
        vertex_count,
        vertex_size,
        stream.ptr,
        stream.len,
    );

    // The original's two decoders succeed on the same buffers, alike.
    if ((want_code == 0) != (want_scalar_code == 0)) return error.OriginalsDisagree;
    if (want_code == 0) try common.expectSame(u8, "original scalar", want, want_scalar);

    @memset(got, 0);
    const got_code = codeOf(mo.decodeVertexBuffer(got, vertex_size, stream));
    try expectDecoded("decodeVertexBuffer", want_code, want, got_code, got);

    inline for (vc.testable_decoders) |decoder| {
        const name = @tagName(decoder) ++ " decoder";
        @memset(got, 0);
        const code = codeOf(vc.decodeVertexBufferWith(decoder, got, vertex_size, stream));
        if (decoder == .scalar) {
            try expectDecoded(name, want_scalar_code, want_scalar, code, got);
        } else {
            try expectDecoded(name, want_code, want, code, got);
        }

        // The same result again, over a different pattern.
        @memset(again, 0x55);
        const again_code = codeOf(vc.decodeVertexBufferWith(decoder, again, vertex_size, stream));
        try expectDecoded(name ++ ", again", code, got, again_code, again);
    }

    return want_code;
}

/// Encodes `vertices` at `level` and `version` with both, decodes the
/// stream with every decoder, and checks it decodes back to `vertices`.
fn checkRoundTrip(
    vertices: []const u8,
    vertex_size: usize,
    level: u4,
    version: mo.VertexVersion,
) !void {
    var encoded = try checkEncode(vertices, vertex_size, level, version);
    defer encoded.deinit();

    const vertex_count = vertices.len / vertex_size;
    try std.testing.expectEqual(0, try checkDecode(encoded.stream(), vertex_count, vertex_size));

    const decoded = try gpa.alloc(u8, vertices.len);
    defer gpa.free(decoded);
    try mo.decodeVertexBuffer(decoded, vertex_size, encoded.stream());
    try common.expectSame(u8, "round trip", vertices, decoded);
}

/// The kinds of generated vertex data.
const Kind = enum {
    /// Random bytes: literals and 8-bit groups.
    random,
    /// One vertex repeated: zero deltas.
    constant,
    /// 16-bit values walking in small steps across byte boundaries.
    deltas,
    /// Small byte steps with occasional jumps: bit groups with sentinels.
    sentinels,
    /// Slowly changing floats, which share sign, exponent and high mantissa
    /// bits: xor deltas.
    floats,
    /// 32-bit values with a few changing bits at an offset, as in the
    /// original's own xor test: rotated xor deltas.
    bits,
};

fn fill(rng: std.Random, kind: Kind, vertices: []u8, vertex_size: usize) void {
    const vertex_count = vertices.len / vertex_size;
    switch (kind) {
        .random => rng.bytes(vertices),
        .constant => {
            var vertex: [256]u8 = undefined;
            rng.bytes(vertex[0..vertex_size]);
            for (0..vertex_count) |i| {
                @memcpy(vertices[i * vertex_size ..][0..vertex_size], vertex[0..vertex_size]);
            }
        },
        .deltas => {
            var values: [128]u16 = undefined;
            var steps: [128]i16 = undefined;
            for (&values, &steps) |*v, *s| {
                v.* = rng.int(u16);
                s.* = rng.intRangeAtMost(i16, -6, 6);
            }
            for (0..vertex_count) |i| {
                for (0..vertex_size / 2) |l| {
                    const jitter = rng.intRangeAtMost(i16, -1, 1);
                    values[l] +%= @bitCast(steps[l] +% jitter);
                    const at = i * vertex_size + l * 2;
                    std.mem.writeInt(u16, vertices[at..][0..2], values[l], .little);
                }
            }
        },
        .sentinels => {
            var values: [256]u8 = undefined;
            rng.bytes(&values);
            for (0..vertex_count) |i| {
                for (0..vertex_size) |k| {
                    const jump = rng.uintLessThan(u8, 12) == 0;
                    values[k] +%= if (jump) rng.int(u8) else rng.uintLessThan(u8, 3);
                    vertices[i * vertex_size + k] = values[k];
                }
            }
        },
        .floats => {
            var values: [64]f32 = undefined;
            var steps: [64]f32 = undefined;
            for (&values, &steps) |*v, *s| {
                v.* = (rng.float(f32) * 2 - 1) * 100;
                s.* = (rng.float(f32) * 2 - 1) * 0.01;
            }
            for (0..vertex_count) |i| {
                for (0..vertex_size / 4) |l| {
                    values[l] += steps[l] * (1 + rng.float(f32));
                    const v: u32 = @bitCast(values[l]);
                    std.mem.writeInt(u32, vertices[i * vertex_size + l * 4 ..][0..4], v, .little);
                }
            }
        },
        .bits => {
            var shifts: [64]u5 = undefined;
            var bases: [64]u32 = undefined;
            for (&shifts, &bases) |*s, *b| {
                s.* = rng.int(u5);
                b.* = rng.int(u32);
            }
            for (0..vertex_count) |i| {
                for (0..vertex_size / 4) |l| {
                    const noise = rng.uintLessThan(u32, 16) << shifts[l];
                    const v = bases[l] ^ noise;
                    std.mem.writeInt(u32, vertices[i * vertex_size + l * 4 ..][0..4], v, .little);
                }
            }
        },
    }
}

/// Vertex counts around the block and byte group boundaries of
/// `vertex_size`.
fn boundaryCounts(vertex_size: usize) [11]usize {
    const block = blockSize(vertex_size);
    return .{ 0, 1, 2, 15, 16, 17, block - 1, block, block + 1, 2 * block + 7, 3 * block + 16 };
}

/// A fuzz case's vertex buffer and the settings to encode it with, all from
/// its seed; `deinit` frees it.
const FuzzInput = struct {
    vertices: []u8,
    vertex_size: usize,
    vertex_count: usize,
    level: u4,
    version: mo.VertexVersion,

    fn init(rng: std.Random) !FuzzInput {
        const vertex_size = 4 * rng.intRangeAtMost(usize, 1, 64);
        // Half at the block and byte group boundaries, half anywhere
        // through three blocks.
        const counts = boundaryCounts(vertex_size);
        const vertex_count = if (rng.boolean())
            counts[rng.uintLessThan(usize, counts.len)]
        else
            rng.uintAtMost(usize, 3 * blockSize(vertex_size) + 16);
        const vertices = try gpa.alloc(u8, vertex_count * vertex_size);
        fill(rng, rng.enumValue(Kind), vertices, vertex_size);
        return .{
            .vertices = vertices,
            .vertex_size = vertex_size,
            .vertex_count = vertex_count,
            .level = rng.uintAtMost(u4, 9),
            .version = rng.enumValue(mo.VertexVersion),
        };
    }

    fn deinit(self: *FuzzInput) void {
        gpa.free(self.vertices);
        self.* = undefined;
    }

    fn encode(self: FuzzInput) !Encoded {
        return checkEncode(self.vertices, self.vertex_size, self.level, self.version);
    }
};

test "encodeVertexBufferBound matches the original" {
    var vertex_size: usize = 4;
    while (vertex_size <= 256) : (vertex_size += 4) {
        for ([_]usize{ 0, 1, 15, 16, 17, 255, 256, 257, 1000, 100_000 }) |count| {
            try common.expectSameValue(
                usize,
                "encodeVertexBufferBound",
                c.meshopt_encodeVertexBufferBound(count, vertex_size),
                mo.encodeVertexBufferBound(count, vertex_size),
            );
        }
    }
}

test "decodeVertexVersion matches the original" {
    try common.expectSameValue(
        c_int,
        "decodeVertexVersion of nothing",
        c.meshopt_decodeVertexVersion(null, 0),
        if (mo.decodeVertexVersion(&.{})) |v| @backingInt(v) else -1,
    );
    for (0..256) |header| {
        const buffer = [_]u8{ @intCast(header), 0x5a };
        for (1..3) |len| {
            const want = c.meshopt_decodeVertexVersion(&buffer, len);
            const got = mo.decodeVertexVersion(buffer[0..len]);
            const got_code: c_int = if (got) |v| @backingInt(v) else -1;
            try common.expectSameValue(c_int, "decodeVertexVersion", want, got_code);
        }
    }
}

test "the encoder and decoders match the original on generated vertices" {
    var prng: std.Random.DefaultPrng = .init(0x7e57c0dec);
    const rng = prng.random();
    const vertices = try gpa.alloc(u8, (3 * 256 + 16) * 256);
    defer gpa.free(vertices);

    var vertex_size: usize = 4;
    while (vertex_size <= 256) : (vertex_size += 4) {
        for (std.enums.values(Kind)) |kind| {
            for (boundaryCounts(vertex_size)) |count| {
                const data = vertices[0 .. count * vertex_size];
                fill(rng, kind, data, vertex_size);
                for ([_]mo.VertexVersion{ .v0, .v1 }) |version| {
                    for (0..4) |level| {
                        try checkRoundTrip(data, vertex_size, @intCast(level), version);
                    }
                }
            }
        }
    }
}

test "levels 4 to 9 match the original" {
    var prng: std.Random.DefaultPrng = .init(49);
    const rng = prng.random();
    var vertices: [600 * 16]u8 = undefined;
    for (std.enums.values(Kind)) |kind| {
        fill(rng, kind, &vertices, 16);
        for (4..10) |level| {
            for ([_]mo.VertexVersion{ .v0, .v1 }) |version| {
                try checkRoundTrip(&vertices, 16, @intCast(level), version);
            }
        }
    }
}

/// The demo mesh's vertices, 32 bytes of floats each and quantized into
/// 16 bytes.
const DemoBuffers = struct {
    mesh: common.Mesh,
    quantized: []u8,

    fn init() !DemoBuffers {
        var mesh = try common.pirate();
        errdefer mesh.deinit(gpa);
        return .{ .mesh = mesh, .quantized = try meshes.quantized(gpa, mesh.vertices) };
    }

    fn deinit(self: *DemoBuffers) void {
        self.mesh.deinit(gpa);
        gpa.free(self.quantized);
        self.* = undefined;
    }

    fn raw(self: DemoBuffers) []const u8 {
        return std.mem.sliceAsBytes(self.mesh.vertices);
    }
};

test "the encoder and decoders match the original on the demo mesh" {
    var demo: DemoBuffers = try .init();
    defer demo.deinit();
    for ([_]mo.VertexVersion{ .v0, .v1 }) |version| {
        for (0..10) |level| {
            try checkRoundTrip(demo.raw(), @sizeOf(common.Vertex), @intCast(level), version);
            const size = meshes.quantized_vertex_size;
            try checkRoundTrip(demo.quantized, size, @intCast(level), version);
        }
    }
    // Every stream of the demo mesh as 4-byte channels on their own.
    for (0..@sizeOf(common.Vertex) / 4) |channel| {
        const channel_bytes = try gpa.alloc(u8, demo.mesh.vertices.len * 4);
        defer gpa.free(channel_bytes);
        const raw = demo.raw();
        for (0..demo.mesh.vertices.len) |i| {
            const vertex = raw[i * @sizeOf(common.Vertex) ..];
            @memcpy(channel_bytes[i * 4 ..][0..4], vertex[channel * 4 ..][0..4]);
        }
        for (0..4) |level| try checkRoundTrip(channel_bytes, 4, @intCast(level), .v1);
    }
}

test "the encoder and decoders match the original on every test mesh" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes) |mesh| {
        const raw = std.mem.sliceAsBytes(mesh.vertices);
        const quantized = try meshes.quantized(gpa, mesh.vertices);
        defer gpa.free(quantized);
        for ([_]mo.VertexVersion{ .v0, .v1 }) |version| {
            for (0..4) |level| {
                try checkRoundTrip(raw, @sizeOf(common.Vertex), @intCast(level), version);
                const size = meshes.quantized_vertex_size;
                try checkRoundTrip(quantized, size, @intCast(level), version);
            }
        }
    }
}

test "the encoder matches the original on short buffers" {
    var prng: std.Random.DefaultPrng = .init(11);
    const rng = prng.random();
    var vertices: [300 * 12]u8 = undefined;
    for (std.enums.values(Kind)) |kind| {
        fill(rng, kind, &vertices, 12);
        for ([_]mo.VertexVersion{ .v0, .v1 }) |version| {
            var encoded = try checkEncode(&vertices, 12, 3, version);
            defer encoded.deinit();
            const got = try gpa.alloc(u8, encoded.size);
            defer gpa.free(got);
            // Every buffer short of the encoded size fails, in both.
            for (0..encoded.size + 1) |len| {
                const want_size = c.meshopt_encodeVertexBufferLevel(
                    encoded.bytes.ptr,
                    len,
                    &vertices,
                    300,
                    12,
                    3,
                    @backingInt(version),
                );
                const got_size = mo.encodeVertexBufferLevel(got[0..len], &vertices, 12, 3, version);
                try common.expectSameValue(usize, "short buffer encode", want_size, got_size);
            }
        }
    }
}

test "the decoders match the original on truncated and padded buffers" {
    var prng: std.Random.DefaultPrng = .init(12);
    const rng = prng.random();
    var vertices: [200 * 20]u8 = undefined;
    for (std.enums.values(Kind)) |kind| {
        fill(rng, kind, &vertices, 20);
        for ([_]mo.VertexVersion{ .v0, .v1 }) |version| {
            var encoded = try checkEncode(&vertices, 20, 2, version);
            defer encoded.deinit();
            // Every prefix, then the whole stream with extra bytes.
            for (0..encoded.size + 1) |len| {
                const code = try checkDecode(encoded.bytes[0..len], 200, 20);
                try std.testing.expect((code == 0) == (len == encoded.size));
            }
            const padded = try gpa.alloc(u8, encoded.size + 40);
            defer gpa.free(padded);
            @memcpy(padded[0..encoded.size], encoded.stream());
            rng.bytes(padded[encoded.size..]);
            for (encoded.size + 1..padded.len) |len| _ = try checkDecode(padded[0..len], 200, 20);
        }
    }

    // A large stream at random lengths.
    var demo: DemoBuffers = try .init();
    defer demo.deinit();
    var encoded = try checkEncode(demo.quantized, 16, 2, .v1);
    defer encoded.deinit();
    const vertex_count = demo.quantized.len / 16;
    for (0..200) |_| {
        const len = rng.uintLessThan(usize, encoded.size);
        try std.testing.expect(try checkDecode(encoded.bytes[0..len], vertex_count, 16) < 0);
    }
}

test "the decoders match the original on corrupted buffers" {
    var prng: std.Random.DefaultPrng = .init(13);
    const rng = prng.random();
    var vertices: [700 * 8]u8 = undefined;
    var successes: usize = 0;
    var failures: usize = 0;
    for (std.enums.values(Kind)) |kind| {
        for ([_]usize{ 4, 8 }) |vertex_size| {
            const data = vertices[0 .. 700 / (vertex_size / 4) * vertex_size];
            const vertex_count = data.len / vertex_size;
            fill(rng, kind, data, vertex_size);
            for ([_]mo.VertexVersion{ .v0, .v1 }) |version| {
                var encoded = try checkEncode(data, vertex_size, 3, version);
                defer encoded.deinit();
                const corrupt = try gpa.alloc(u8, encoded.size);
                defer gpa.free(corrupt);
                for (0..300) |round| {
                    @memcpy(corrupt, encoded.stream());
                    for (0..1 + round % 3) |_| {
                        const at = rng.uintLessThan(usize, corrupt.len);
                        if (rng.boolean()) {
                            corrupt[at] ^= @as(u8, 1) << rng.int(u3);
                        } else {
                            corrupt[at] = rng.int(u8);
                        }
                    }
                    // The vertex count and size the stream holds, and some it
                    // does not.
                    const count = switch (round % 5) {
                        0 => vertex_count + 1,
                        1 => vertex_count - 1,
                        else => vertex_count,
                    };
                    const code = try checkDecode(corrupt, count, vertex_size);
                    if (code == 0) successes += 1 else failures += 1;
                }
            }
        }
    }
    // Both kinds of outcome occur, so both comparisons ran.
    try std.testing.expect(successes > 100);
    try std.testing.expect(failures > 100);
}

test "the decoders match the original on unknown channel encodings" {
    var prng: std.Random.DefaultPrng = .init(14);
    const rng = prng.random();
    var vertices: [100 * 16]u8 = undefined;
    fill(rng, .floats, &vertices, 16);
    var encoded = try checkEncode(&vertices, 16, 3, .v1);
    defer encoded.deinit();
    const corrupt = try gpa.alloc(u8, encoded.size);
    defer gpa.free(corrupt);
    // The tail ends with one channel byte per 4 bytes of vertex.
    for (0..4) |channel| {
        for (0..256) |value| {
            @memcpy(corrupt, encoded.stream());
            corrupt[corrupt.len - 4 + channel] = @intCast(value);
            const code = try checkDecode(corrupt, 100, 16);
            if (value & 3 == 3) try std.testing.expectEqual(-2, code);
        }
    }
}

test "the encoder and decoders match the original on fuzzed vertices" {
    try common.fuzz("fuzzed vertices", 0x5eed0000, struct {
        fn check(seed: u64) !void {
            var prng: std.Random.DefaultPrng = .init(seed);
            var input: FuzzInput = try .init(prng.random());
            defer input.deinit();
            try checkRoundTrip(input.vertices, input.vertex_size, input.level, input.version);
        }
    }.check);
}

test "the decoders match the original on fuzzed truncated and padded streams" {
    try common.fuzz("truncated and padded streams", 0x5eed1000, struct {
        fn check(seed: u64) !void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const rng = prng.random();
            var input: FuzzInput = try .init(rng);
            defer input.deinit();
            var encoded = try input.encode();
            defer encoded.deinit();
            const count = input.vertex_count;
            const size = input.vertex_size;

            // Every stream short of the whole fails.
            for (0..8) |_| {
                const len = rng.uintLessThan(usize, encoded.size);
                try std.testing.expect(try checkDecode(encoded.bytes[0..len], count, size) < 0);
            }

            // Bytes past the end.
            const padded = try gpa.alloc(u8, encoded.size + 40);
            defer gpa.free(padded);
            @memcpy(padded[0..encoded.size], encoded.stream());
            rng.bytes(padded[encoded.size..]);
            const len = encoded.size + rng.intRangeAtMost(usize, 1, 40);
            _ = try checkDecode(padded[0..len], count, size);
        }
    }.check);
}

test "the decoders match the original on fuzzed corrupted streams" {
    const Outcomes = struct {
        var successes: usize = 0;
        var failures: usize = 0;

        fn check(seed: u64) !void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const rng = prng.random();
            var input: FuzzInput = try .init(rng);
            defer input.deinit();
            var encoded = try input.encode();
            defer encoded.deinit();

            const corrupt = try gpa.alloc(u8, encoded.size);
            defer gpa.free(corrupt);
            @memcpy(corrupt, encoded.stream());
            for (0..rng.intRangeAtMost(usize, 1, 3)) |_| {
                const at = rng.uintLessThan(usize, corrupt.len);
                if (rng.boolean()) {
                    corrupt[at] ^= @as(u8, 1) << rng.int(u3);
                } else {
                    corrupt[at] = rng.int(u8);
                }
            }

            // Mostly the vertex count the stream holds, sometimes one more
            // or one fewer.
            const count = switch (rng.uintLessThan(u8, 5)) {
                0 => input.vertex_count + 1,
                1 => input.vertex_count -| 1,
                else => input.vertex_count,
            };
            const code = try checkDecode(corrupt, count, input.vertex_size);
            if (code == 0) successes += 1 else failures += 1;
        }
    };
    try common.fuzz("corrupted streams", 0x5eed2000, Outcomes.check);

    // Both kinds of outcome occur, so both comparisons ran.
    try std.testing.expect(Outcomes.successes > 100);
    try std.testing.expect(Outcomes.failures > 100);
}

test "the decoders match the original on fuzzed random bytes" {
    try common.fuzz("random bytes", 0x5eed3000, struct {
        fn check(seed: u64) !void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const rng = prng.random();
            var buffer: [1200]u8 = undefined;
            const alphabet = [_]u8{ 0x00, 0xff, 0x55, 0xaa, 0x01, 0x80 };
            for (0..20) |round| {
                const len = rng.uintLessThanBiased(usize, buffer.len + 1);
                const stream = buffer[0..len];
                // Bytes from a few patterns reach deeper than random bytes.
                if (round % 2 == 0) {
                    rng.bytes(stream);
                } else {
                    for (stream) |*b| b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
                }
                // Mostly a valid header.
                if (len > 0 and round % 4 != 3) {
                    stream[0] = 0xa0 | @as(u8, rng.uintLessThan(u8, 2));
                }
                const vertex_size = 4 * rng.intRangeAtMost(usize, 1, 16);
                const vertex_count = rng.uintLessThan(usize, 80);
                _ = try checkDecode(stream, vertex_count, vertex_size);
            }
        }
    }.check);
}
