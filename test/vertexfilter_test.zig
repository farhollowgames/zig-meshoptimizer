//! The vertex filters against the original. Every encoder at every stride,
//! bit count and exponent mode, on the demo mesh's normals, tangent frames,
//! positions and colors and on special and fuzzed floats; every decoder at
//! every stride on what the encoders write, on special and fuzzed bytes,
//! and on every 8-bit octahedral vector, at every count around the SIMD
//! block sizes. The port's SIMD path is checked against the original's
//! SIMD path, its scalar path against the original built without SIMD:
//! the two round differently.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");

const gpa = common.gpa;
const vf = mo.vertexfilter;

// The original's decoders built without SIMD, by build.zig's scalar reference.
extern fn scalar_meshopt_decodeFilterOct(buffer: ?*anyopaque, count: usize, stride: usize) void;
extern fn scalar_meshopt_decodeFilterQuat(buffer: ?*anyopaque, count: usize, stride: usize) void;
extern fn scalar_meshopt_decodeFilterExp(buffer: ?*anyopaque, count: usize, stride: usize) void;
extern fn scalar_meshopt_decodeFilterColor(
    buffer: ?*anyopaque,
    count: usize,
    stride: usize,
) void;

const Filter = enum { oct, quat, exp, color };

/// The strides each decoder takes; the exponent filter takes any multiple
/// of 4, of which these are a sample.
fn stridesOf(filter: Filter) []const usize {
    return switch (filter) {
        .oct, .color => &.{ 4, 8 },
        .quat => &.{8},
        .exp => &.{ 4, 8, 12, 16, 20, 32, 64, 256 },
    };
}

/// A decoder of the original and the port's decoder that computes as it
/// does.
const Decoder = struct {
    name: []const u8,
    original: *const fn (?*anyopaque, usize, usize) callconv(.c) void,
    port: *const fn ([]u8, usize) void,
};

/// The SIMD path, if the target has one, and the scalar path.
fn decodersOf(filter: Filter) [2]Decoder {
    return switch (filter) {
        inline else => |f| blk: {
            const tag = @tagName(f);
            const name = comptime "decodeFilter" ++ [_]u8{std.ascii.toUpper(tag[0])} ++ tag[1..];
            break :blk .{
                .{
                    .name = name,
                    .original = &@field(c, "meshopt_" ++ name),
                    .port = &@field(mo, name),
                },
                .{
                    .name = name ++ " scalar",
                    .original = &@field(@This(), "scalar_meshopt_" ++ name),
                    .port = &@field(vf, name ++ "Scalar"),
                },
            };
        },
    };
}

/// Decodes `input`, `stride` bytes per item, with the original and the
/// port on each path, and fails unless both write the same bytes, and the
/// port writes them again on a second run.
fn checkDecode(filter: Filter, input: []const u8, stride: usize) !void {
    const count = input.len / stride;
    const want = try gpa.alloc(u8, input.len);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, input.len);
    defer gpa.free(got);
    const again = try gpa.alloc(u8, input.len);
    defer gpa.free(again);

    for (decodersOf(filter), 0..) |decoder, path| {
        // Where the port's build has no kernel for this filter, its
        // decoder runs the scalar loops, as the original's do without SIMD.
        const estimates = (filter == .oct or filter == .color) and stride == 4;
        const simd = vf.has_simd and (vf.simd_estimates or !estimates);
        const scalar = decodersOf(filter)[1];
        const original = if (path == 0 and !simd) scalar.original else decoder.original;

        @memcpy(want, input);
        @memcpy(got, input);
        @memcpy(again, input);
        original(want.ptr, count, stride);
        decoder.port(got, stride);
        common.expectSame(u8, decoder.name, want, got) catch |err| {
            std.debug.print("  stride {d}, count {d}\n", .{ stride, count });
            return err;
        };
        decoder.port(again, stride);
        try common.expectSame(u8, "a second decode", got, again);
    }
}

/// `checkDecode` on every prefix of `input` up to a few SIMD blocks, and on
/// all of it: every count of whole blocks and tails.
fn checkDecodeCounts(filter: Filter, input: []const u8, stride: usize) !void {
    const count = input.len / stride;
    for (0..@min(count, 70) + 1) |n| try checkDecode(filter, input[0 .. n * stride], stride);
    try checkDecode(filter, input, stride);
}

/// Encodes `data` with the original and the port, into outputs filled
/// with different bytes before, and fails unless both write the same
/// bytes; then checks the decoders on them. Returns the original's bytes.
fn checkEncode(
    filter: Filter,
    data: []const f32,
    stride: usize,
    bits: u5,
    mode: mo.EncodeExpMode,
) ![]u8 {
    const floats_per_item = if (filter == .exp) stride / 4 else 4;
    const count = data.len / floats_per_item;
    const want = try gpa.alloc(u8, count * stride);
    errdefer gpa.free(want);
    const got = try gpa.alloc(u8, count * stride);
    defer gpa.free(got);
    const again = try gpa.alloc(u8, count * stride);
    defer gpa.free(again);
    @memset(want, 0x55);
    @memset(got, 0xaa);
    @memset(again, 0x55);

    const c_bits: c_int = bits;
    switch (filter) {
        .oct => {
            c.meshopt_encodeFilterOct(want.ptr, count, stride, c_bits, data.ptr);
            mo.encodeFilterOct(got, stride, bits, data);
            mo.encodeFilterOct(again, stride, bits, data);
        },
        .quat => {
            c.meshopt_encodeFilterQuat(want.ptr, count, stride, c_bits, data.ptr);
            mo.encodeFilterQuat(got, stride, bits, data);
            mo.encodeFilterQuat(again, stride, bits, data);
        },
        .exp => {
            const c_mode: c.EncodeExpMode = switch (mode) {
                inline else => |m| @field(c.EncodeExpMode, @tagName(m)),
            };
            c.meshopt_encodeFilterExp(want.ptr, count, stride, c_bits, data.ptr, c_mode);
            mo.encodeFilterExp(got, stride, bits, data, mode);
            mo.encodeFilterExp(again, stride, bits, data, mode);
        },
        .color => {
            c.meshopt_encodeFilterColor(want.ptr, count, stride, c_bits, data.ptr);
            mo.encodeFilterColor(got, stride, bits, data);
            mo.encodeFilterColor(again, stride, bits, data);
        },
    }
    common.expectSame(u8, @tagName(filter), want, got) catch |err| {
        std.debug.print("  stride {d}, bits {d}, mode {t}\n", .{ stride, bits, mode });
        return err;
    };
    try common.expectSame(u8, "a second encode", got, again);

    try checkDecode(filter, want, stride);
    return want;
}

/// The bit counts each encoder takes at `stride`.
fn bitsOf(filter: Filter, stride: usize) [2]u5 {
    return switch (filter) {
        .oct, .color => .{ 2, if (stride == 4) 8 else 16 },
        .quat => .{ 4, 16 },
        .exp => .{ 1, 24 },
    };
}

const modes = [_]mo.EncodeExpMode{ .separate, .shared_vector, .shared_component, .clamped };

/// Every encoder at every bit count, stride and mode on `vectors`,
/// `frames`, `colors` (4 floats each) and `floats`, then every decoder on
/// what the original wrote, at every count around the SIMD blocks for the
/// widest encoding.
fn checkAll(
    vectors: []const f32,
    frames: []const f32,
    colors: []const f32,
    floats: []const f32,
) !void {
    for ([_]Filter{ .oct, .quat, .color }) |filter| {
        const data = switch (filter) {
            .oct => vectors,
            .quat => frames,
            else => colors,
        };
        for (stridesOf(filter)) |stride| {
            const range = bitsOf(filter, stride);
            for (range[0]..range[1] + 1) |bits| {
                const encoded = try checkEncode(filter, data, stride, @intCast(bits), .separate);
                defer gpa.free(encoded);
                if (bits == range[1]) try checkDecodeCounts(filter, encoded, stride);
            }
        }
    }

    // Strides that divide the floats evenly.
    for ([_]usize{ 4, 8, 12, 16, 32 }) |stride| {
        const per_item = stride / 4;
        const data = floats[0 .. floats.len / per_item * per_item];
        for (1..25) |bits| {
            for (modes) |mode| {
                const encoded = try checkEncode(.exp, data, stride, @intCast(bits), mode);
                defer gpa.free(encoded);
                if (bits == 24 and mode == .separate) try checkDecodeCounts(.exp, encoded, stride);
            }
        }
    }
}

test "the filters match the original on the demo mesh" {
    var pirate = try common.pirate();
    defer pirate.deinit(gpa);
    try checkMesh(pirate.vertices);
}

test "the filters match the original on the generated meshes" {
    var set: common.MeshSet = try .init();
    defer set.deinit();
    for (set.meshes[1..]) |mesh| try checkMesh(mesh.vertices);
}

fn checkMesh(vertices: []const meshes.Vertex) !void {
    const vectors = try meshes.unitVectors(gpa, vertices);
    defer gpa.free(vectors);
    const frames = try meshes.tangentFrames(gpa, vertices);
    defer gpa.free(frames);
    const colors = try meshes.colors(gpa, vertices);
    defer gpa.free(colors);
    try checkAll(vectors, frames, colors, common.floatsOf(vertices));
}

/// Floats at the edges: zeros, ones, infinities, NaNs, denormals, the
/// extremes, and values just past 1.
const special_floats = [_]f32{
    0,
    -0.0,
    1,
    -1,
    0.5,
    -0.5,
    0.99999994,
    -0.99999994,
    1.0000001,
    -1.0000001,
    2,
    -2,
    255.99998,
    1e-40,
    -1e-40,
    std.math.floatTrueMin(f32),
    std.math.floatMin(f32),
    -std.math.floatMin(f32),
    std.math.floatMax(f32),
    -std.math.floatMax(f32),
    std.math.inf(f32),
    -std.math.inf(f32),
    std.math.nan(f32),
    -std.math.nan(f32),
    0.70710677,
    -0.70710677,
    1e30,
    -1e-30,
};

test "the encoders match the original on special floats" {
    // Every combination of three special components, and a fourth one.
    var data: std.ArrayList(f32) = .empty;
    defer data.deinit(gpa);
    for (special_floats) |x| for (special_floats) |y| for (special_floats) |z| {
        const w = special_floats[(data.items.len / 4) % special_floats.len];
        try data.appendSlice(gpa, &.{ x, y, z, w });
    };
    try checkAll(data.items, data.items, data.items, data.items);
}

test "encodeFilterExp matches the original at 24 bits around every power of two" {
    // Mantissas of all ones round up to the next power of two at 24 bits,
    // where the mantissa must clamp.
    var data: std.ArrayList(f32) = .empty;
    defer data.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(7);
    const rng = prng.random();
    for (0..256) |biased| {
        const power: u32 = @intCast(biased << 23);
        for ([_]u32{ power, power -% 1, power +% 1, power | 0x7fffff, power | 0x400000 }) |bits| {
            const v: f32 = @bitCast(bits & 0x7fffffff);
            try data.appendSlice(gpa, &.{ v, -v });
        }
        try data.append(gpa, @bitCast(power | rng.int(u23)));
    }
    for ([_]usize{ 4, 8, 12 }) |stride| {
        const per_item = stride / 4;
        const floats = data.items[0 .. data.items.len / per_item * per_item];
        for ([_]u5{ 22, 23, 24 }) |bits| {
            for (modes) |mode| gpa.free(try checkEncode(.exp, floats, stride, bits, mode));
        }
    }
}

/// 16-bit words at the edges of each bit count's range: zero, one, the
/// largest and smallest K-bit values and their neighbours, the top bit, and
/// all ones.
fn specialWords(list: *std.ArrayList(u16)) !void {
    for (2..17) |bits| {
        const max: u16 = @intCast((@as(u32, 1) << @intCast(bits - 1)) - 1);
        try list.appendSlice(gpa, &.{
            max,
            max - 1,
            ~max,
            ~max +% 1,
            max >> 1,
            max | 1,
            max & ~@as(u16, 3),
        });
    }
    try list.appendSlice(gpa, &.{ 0, 1, 2, 3, 0x7fff, 0x8000, 0x8001, 0xfffc, 0xffff });
}

test "the decoders match the original on special components" {
    var words: std.ArrayList(u16) = .empty;
    defer words.deinit(gpa);
    try specialWords(&words);

    // Every pair of special words in X and Y, with the third and fourth
    // words cycling through them, at 16 bits; and the same in bytes.
    var wide: std.ArrayList(u16) = .empty;
    defer wide.deinit(gpa);
    var narrow: std.ArrayList(u8) = .empty;
    defer narrow.deinit(gpa);
    var k: usize = 0;
    for (words.items) |x| for (words.items) |y| {
        const z = words.items[k % words.items.len];
        const w = words.items[(k / words.items.len + k * 7) % words.items.len];
        k += 1;
        try wide.appendSlice(gpa, &.{ x, y, z, w });
        // The low bytes, then the high ones, keeping the low byte of Z.
        for ([_]u4{ 0, 8 }) |shift| {
            try narrow.appendSlice(gpa, &.{
                @truncate(x >> shift),
                @truncate(y >> shift),
                @truncate(z),
                @truncate(w >> shift),
            });
        }
    };
    const wide_bytes = std.mem.sliceAsBytes(wide.items);
    for ([_]Filter{ .oct, .quat, .color, .exp }) |filter| {
        for (stridesOf(filter)) |stride| {
            const bytes = if (stride == 4 and filter != .exp) narrow.items else wide_bytes;
            try checkDecode(filter, bytes[0 .. bytes.len / stride * stride], stride);
        }
    }
}

test "decodeFilterExp matches the original on every exponent" {
    // Every exponent with special mantissas, NaN and infinity patterns
    // among them.
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    const mantissas = [_]u32{
        0,        1,        2,        0x7fffff, 0x800000, 0x800001,
        0xffffff, 0xfffffe, 0x400000, 0x3fffff, 0xc00000,
    };
    for (0..256) |e| for (mantissas) |m| try words.append(gpa, @as(u32, @intCast(e)) << 24 | m);
    try words.appendSlice(gpa, &special_words);
    try checkDecodeCounts(.exp, std.mem.sliceAsBytes(words.items), 4);
}

test "decodeFilterOct matches the original on every 8-bit vector" {
    // Every X, Y and Z byte, with W from a hash.
    const bytes = try gpa.alloc(u8, 4 << 24);
    defer gpa.free(bytes);
    for (0..1 << 24) |i| {
        const v: u32 = @intCast(i);
        const w: u32 = (v *% 0x9e3779b1) >> 24;
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], v | w << 24, .little);
    }
    try checkDecode(.oct, bytes, 4);
}

test "decodeFilterColor matches the original on every 8-bit Y, Co and Cg" {
    // Every Y, Co and Cg byte with alpha from a hash, then every alpha with
    // the rest from a hash.
    const bytes = try gpa.alloc(u8, 4 << 24);
    defer gpa.free(bytes);
    for (0..1 << 24) |i| {
        const v: u32 = @intCast(i);
        const a: u32 = (v *% 0x9e3779b1) >> 24;
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], v | a << 24, .little);
    }
    try checkDecode(.color, bytes, 4);

    for (0..1 << 24) |i| {
        const v: u32 = @intCast(i);
        const rest: u32 = (v *% 0x9e3779b1) >> 8;
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], (v & 0xff) << 24 | rest, .little);
    }
    try checkDecode(.color, bytes, 4);
}

/// 32-bit words that make special floats and special components.
const special_words = [_]u32{
    0,          0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0xffc00000,
    0x00000001, 0x007fffff, 0x7f7fffff, 0x3f800000, 0xbf800000, 0x7fff7fff,
    0x80008000, 0xffffffff, 0x7fff0000, 0x00007fff, 0x80000001, 0xff7fffff,
};

/// `len` bytes from `rng`, a word in eight from `special_words`.
fn fuzzBytes(rng: std.Random, len: usize) ![]u8 {
    const bytes = try gpa.alloc(u8, len);
    rng.bytes(bytes);
    var i: usize = 0;
    while (i + 4 <= len) : (i += 4) {
        if (rng.uintLessThan(u8, 8) == 0) {
            const w = special_words[rng.uintLessThan(usize, special_words.len)];
            std.mem.writeInt(u32, bytes[i..][0..4], w, .little);
        }
    }
    return bytes;
}

fn fuzzDecode(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const filter = rng.enumValue(Filter);
    const strides = stridesOf(filter);
    const stride = strides[rng.uintLessThan(usize, strides.len)];
    const count = rng.uintLessThan(usize, 100);
    const bytes = try fuzzBytes(rng, count * stride);
    defer gpa.free(bytes);
    try checkDecode(filter, bytes, stride);
}

test "the decoders match the original on fuzzed bytes" {
    try common.fuzz("vertexfilter decode", 1, fuzzDecode);
}

/// A float from `rng`: a special one, a unit-range one, or any bit pattern.
fn fuzzFloat(rng: std.Random) f32 {
    return switch (rng.uintLessThan(u8, 4)) {
        0 => special_floats[rng.uintLessThan(usize, special_floats.len)],
        1 => @bitCast(rng.int(u32)),
        else => rng.float(f32) * 2.5 - 1.25,
    };
}

fn fuzzEncode(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const filter = rng.enumValue(Filter);
    const stride = switch (filter) {
        .oct, .color => @as(usize, if (rng.boolean()) 4 else 8),
        .quat => 8,
        .exp => 4 * (1 + rng.uintLessThan(usize, 64)),
    };
    const range = bitsOf(filter, stride);
    const bits = rng.intRangeAtMost(u5, range[0], range[1]);
    const mode = rng.enumValue(mo.EncodeExpMode);
    const count = rng.uintLessThan(usize, 100);
    const floats_per_item = if (filter == .exp) stride / 4 else 4;
    const data = try gpa.alloc(f32, count * floats_per_item);
    defer gpa.free(data);
    for (data) |*v| v.* = fuzzFloat(rng);
    gpa.free(try checkEncode(filter, data, stride, bits, mode));
}

test "the encoders match the original on fuzzed floats" {
    try common.fuzz("vertexfilter encode", 1, fuzzEncode);
}

test "encodeFilterExp writes in place as the original does" {
    var prng: std.Random.DefaultPrng = .init(3);
    const rng = prng.random();
    const data = try gpa.alloc(f32, 3 * 60);
    defer gpa.free(data);
    for (data) |*v| v.* = fuzzFloat(rng);
    const want = try gpa.dupe(f32, data);
    defer gpa.free(want);
    const got = try gpa.dupe(f32, data);
    defer gpa.free(got);
    for (modes) |mode| {
        @memcpy(want, data);
        @memcpy(got, data);
        const c_mode: c.EncodeExpMode = switch (mode) {
            inline else => |m| @field(c.EncodeExpMode, @tagName(m)),
        };
        c.meshopt_encodeFilterExp(want.ptr, 60, 12, 15, want.ptr, c_mode);
        mo.encodeFilterExp(std.mem.sliceAsBytes(got), 12, 15, got, mode);
        try common.expectSame(
            u32,
            "in place",
            std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(want)),
            std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(got)),
        );
    }
}
