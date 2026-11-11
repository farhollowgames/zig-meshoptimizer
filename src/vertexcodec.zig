//! Vertex buffer compression: a lossless codec that makes vertex data
//! smaller, and better compressed by a general-purpose compressor after it.
//! The encoder cuts the vertices into blocks, turns each 4-byte channel of
//! each vertex into a delta from the vertex before it (byte-wise, 16-bit or
//! as a rotated xor), transposes the deltas into byte lanes, and packs each
//! lane in groups of 16 values with 0, 1, 2, 4 or 8 bits each. The decoder
//! reverses it with SIMD on x86 (SSSE3, or AVX-512 with VBMI2) and AArch64
//! (NEON), chosen at compile time from the target's features, and with a
//! scalar decoder elsewhere.
//!
//! Translated from meshoptimizer's vertexcodec.cpp.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The vertex codec's format versions.
pub const VertexVersion = enum(u4) {
    /// Decodes with every version of the original.
    v0 = 0,
    /// Decodes with the original's 0.23 and later. It compresses better, and
    /// only it uses the compression level.
    v1 = 1,

    /// The version the original encodes unless told otherwise.
    pub const default: VertexVersion = .v1;
};

/// Why `decodeVertexBuffer` rejected a buffer.
pub const DecodeVertexError = error{
    /// The first byte is not a vertex buffer header of a version this
    /// decoder reads.
    InvalidHeader,
    /// The buffer ends before the data it describes, or names a channel
    /// encoding that does not exist.
    InvalidData,
    /// The vertex data does not end where the buffer's tail begins: the
    /// buffer holds more or fewer vertices than asked for.
    LengthMismatch,
};

const vertex_header: u8 = 0xa0;

/// The newest version the decoder reads.
const decode_vertex_version = 1;

const vertex_block_size_bytes = 8192;
const vertex_block_max_size = 256;
const byte_group_size = 16;
/// The most bytes one group decodes from: 8 bytes of 4-bit values and 16
/// sentinel bytes. Each group checks for that much room once.
const byte_group_decode_limit = 24;
const tail_min_size_v0 = 32;
const tail_min_size_v1 = 24;

const bits_v0 = [4]u8{ 0, 2, 4, 8 };
const bits_v1 = [5]u8{ 0, 1, 2, 4, 8 };

/// The compression level `encodeVertexBuffer` uses.
const encode_default_level = 2;

fn getVertexBlockSize(vertex_size: usize) usize {
    // The whole block fits in the scratch buffer and is a whole number of
    // byte groups. The block size is part of the format: changing it breaks
    // compatibility.
    const result = (vertex_block_size_bytes / vertex_size) & ~@as(usize, byte_group_size - 1);
    return @min(result, vertex_block_max_size);
}

fn zigzag(comptime T: type, v: T) T {
    return (0 -% (v >> (@bitSizeOf(T) - 1))) ^ (v << 1);
}

fn unzigzag(comptime T: type, v: T) T {
    return (0 -% (v & 1)) ^ (v >> 1);
}

fn unzigzagVector(comptime T: type, v: T) T {
    const one: T = @splat(1);
    return (@as(T, @splat(0)) -% (v & one)) ^ (v >> @splat(1));
}

/// Reverses the bits of a 1-bit group's byte, which the encoder writes in
/// the opposite order to the other groups' values so they decode faster
/// alongside them.
fn reverseBits(byte: u8) u8 {
    return @truncate((((@as(u64, byte) *% 0x80200802) & 0x0884422110) *% 0x0101010101) >> 32);
}

// --------------------------------------------------------
// Encoder
// --------------------------------------------------------

inline fn encodeBytesGroupZero(group: *const [byte_group_size]u8) bool {
    const v0 = std.mem.readInt(u64, group[0..8], .little);
    const v1 = std.mem.readInt(u64, group[8..16], .little);
    return (v0 | v1) == 0;
}

/// The encoded size of `group` with `bits` bits per value; the most a size
/// can be when the group cannot use 0 bits.
inline fn encodeBytesGroupMeasure(group: *const [byte_group_size]u8, bits: u8) usize {
    if (bits == 0) return if (encodeBytesGroupZero(group)) 0 else std.math.maxInt(usize);
    if (bits == 8) return byte_group_size;

    const v0 = std.mem.readInt(u64, group[0..8], .little);
    const v1 = std.mem.readInt(u64, group[8..16], .little);

    const sent = ((@as(u64, 1) << @intCast(bits)) - 1) * 0x0101010101010101;
    const mask: u64 = 0x8080808080808080;

    // Each byte gets its high bit set if it is at least the sentinel: the
    // subtraction borrows the high bit, so it is set again in the bytes
    // that already had it.
    const m0 = (((v0 | mask) - sent) | v0) & mask;
    const m1 = (((v1 | mask) - sent) | v1) & mask;

    // Adds all bytes together: the number of bytes at least the sentinel.
    const rest: usize = @intCast((((m0 >> 7) + (m1 >> 7)) *% 0x0101010101010101) >> 56);

    return byte_group_size / 8 * bits + rest;
}

/// Byte groups measured at once by the estimates: eight fill a 512-bit
/// vector with each half of their bytes.
const measure_width = 8;

/// `measure_width` byte groups of a block's lane, one to an element of each
/// half, measured together as `encodeBytesGroupMeasure` measures one. The
/// measures count bytes, which come out alike in either byte order, so the
/// halves load in the native one.
const GroupChunk = struct {
    lo: @Vector(measure_width, u64),
    hi: @Vector(measure_width, u64),
    /// Which groups are among the lane's first `group_count`: the others
    /// load with them but stay out of every sum.
    used: @Vector(measure_width, bool),

    // Each group is two words, its halves.
    const lo_words = std.simd.iota(i32, measure_width) << @splat(1);
    const hi_words = lo_words | @as(@Vector(measure_width, i32), @splat(1));

    /// The groups from `first` on of the first `group_count` of `lane`.
    fn load(lane: *const [vertex_block_max_size]u8, first: usize, group_count: usize) GroupChunk {
        const bytes: @Vector(measure_width * byte_group_size, u8) =
            lane[first * byte_group_size ..][0 .. measure_width * byte_group_size].*;
        const words: @Vector(2 * measure_width, u64) = @bitCast(bytes);
        const index = std.simd.iota(usize, measure_width) +
            @as(@Vector(measure_width, usize), @splat(first));
        return .{
            .lo = @shuffle(u64, words, undefined, lo_words),
            .hi = @shuffle(u64, words, undefined, hi_words),
            .used = index < @as(@Vector(measure_width, usize), @splat(group_count)),
        };
    }

    /// The groups of all zeros.
    fn zero(chunk: GroupChunk) @Vector(measure_width, bool) {
        return (chunk.lo | chunk.hi) == @as(@Vector(measure_width, u64), @splat(0));
    }

    /// The encoded size of each group with 1, 2 or 4 bits per value.
    fn measure(chunk: GroupChunk, comptime bits: u8) @Vector(measure_width, u64) {
        const sent: @Vector(measure_width, u64) = @splat(((1 << bits) - 1) * 0x0101010101010101);
        const mask: @Vector(measure_width, u64) = @splat(0x8080808080808080);
        const ones: @Vector(measure_width, u64) = @splat(0x0101010101010101);

        const m0 = (((chunk.lo | mask) - sent) | chunk.lo) & mask;
        const m1 = (((chunk.hi | mask) - sent) | chunk.hi) & mask;
        const rest = (((m0 >> @splat(7)) + (m1 >> @splat(7))) *% ones) >> @splat(56);

        return @as(@Vector(measure_width, u64), @splat(byte_group_size / 8 * bits)) + rest;
    }

    /// `values` of the used groups, 0 for the others.
    fn usedOnly(
        chunk: GroupChunk,
        values: @Vector(measure_width, u64),
    ) @Vector(measure_width, u64) {
        return @select(u64, chunk.used, values, @as(@Vector(measure_width, u64), @splat(0)));
    }
};

/// Writes `group` with `bits` bits per value at the start of `data`, which
/// has room for `byte_group_decode_limit` bytes, and returns how many bytes
/// it wrote.
fn encodeBytesGroup(data: []u8, group: *const [byte_group_size]u8, comptime bits: u8) usize {
    if (bits == 0) return 0;

    if (bits == 8) {
        data[0..byte_group_size].* = group.*;
        return byte_group_size;
    }

    const shift: u3 = bits;
    const byte_size = 8 / bits;

    // A fixed part, `bits` bits for each value, then a variable part: a
    // whole byte for each value out of range, which the fixed part marks
    // with the sentinel, all ones.
    const sentinel: u8 = (1 << shift) - 1;

    var pos: usize = 0;
    inline for (0..byte_group_size / byte_size) |b| {
        var byte: u8 = 0;

        for (group[b * byte_size ..][0..byte_size]) |value| {
            const enc = if (value >= sentinel) sentinel else value;

            byte <<= shift;
            byte |= enc;
        }

        if (bits == 1) byte = reverseBits(byte);

        data[pos] = byte;
        pos += 1;
    }

    for (group) |value| {
        // A branchless append of the values out of range.
        data[pos] = value;
        pos += @intFromBool(value >= sentinel);
    }

    return pos;
}

/// Writes the byte groups of `buffer` at `data[start..]`, each with the
/// cheapest of the four bit counts in `bits`, and returns where they end,
/// or null if `data` is too short.
fn encodeBytes(data: []u8, start: usize, buffer: []const u8, comptime bits: [4]u8) ?usize {
    assert(buffer.len % byte_group_size == 0);

    const header = start;

    // Four groups to a header byte.
    const header_size = (buffer.len / byte_group_size + 3) / 4;

    if (data.len - start < header_size) return null;

    var pos = start + header_size;

    @memset(data[header..][0..header_size], 0);

    var last_bits: i16 = -1;

    var i: usize = 0;
    while (i < buffer.len) : (i += byte_group_size) {
        if (data.len - pos < byte_group_decode_limit) return null;

        const group = buffer[i..][0..byte_group_size];

        var best_bitk: u2 = 3;
        var best_size = encodeBytesGroupMeasure(group, bits[3]);

        inline for (0..3) |bitk| {
            const size = encodeBytesGroupMeasure(group, bits[bitk]);

            // Favor the same bit count across groups, but never replace
            // literals.
            const same = bits[bitk] == last_bits and bits[best_bitk] != 8;
            if (size < best_size or (size == best_size and same)) {
                best_bitk = bitk;
                best_size = size;
            }
        }

        const header_offset = i / byte_group_size;
        const header_shift: u3 = @intCast((header_offset % 4) * 2);
        data[header + header_offset / 4] |= @as(u8, best_bitk) << header_shift;

        const size = switch (best_bitk) {
            inline else => |bitk| encodeBytesGroup(data[pos..], group, bits[bitk]),
        };

        assert(size == best_size);
        pos += size;
        last_bits = bits[best_bitk];
    }

    return pos;
}

/// Writes the deltas of one 4-byte channel of `vertex_count` vertices,
/// `vertex_size` bytes apart from the start of `vertices`, into the
/// channel's four byte lanes of `buffer`: each as a `T` from the vertex
/// before it (`last_vertex` before the first), zigzagged, or for `xor` as
/// the rotated xor with it.
fn encodeDeltas4(
    comptime T: type,
    comptime xor: bool,
    buffer: *[vertex_block_max_size * 4]u8,
    vertices: []const u8,
    vertex_count: usize,
    vertex_size: usize,
    last_vertex: *const [4]u8,
    rot: u5,
) void {
    var previous: *const [4]u8 = last_vertex;

    for (0..vertex_count) |i| {
        const vertex = vertices[i * vertex_size ..][0..4];

        inline for (0..4 / @sizeOf(T)) |n| {
            const k = n * @sizeOf(T);

            const p = std.mem.readInt(T, previous[k..][0..@sizeOf(T)], .little);
            const v = std.mem.readInt(T, vertex[k..][0..@sizeOf(T)], .little);

            const d = if (xor) std.math.rotl(T, v ^ p, rot) else zigzag(T, v -% p);

            inline for (0..@sizeOf(T)) |j| {
                buffer[(k + j) * vertex_block_max_size + i] = @truncate(d >> (j * 8));
            }
        }

        previous = vertex;
    }
}

/// Writes the deltas of the channel at byte `k` into the four lanes of
/// `buffer`, encoded as `channel` says: its low two bits name the delta
/// (0 bytes, 1 16-bit values, 2 rotated xor) and, for xor, its high four
/// bits the rotation.
fn encodeDeltas(
    buffer: *[vertex_block_max_size * 4]u8,
    vertices: []const u8,
    vertex_count: usize,
    vertex_size: usize,
    last_vertex: *const [256]u8,
    k: usize,
    channel: u8,
) void {
    const channel_data = vertices[k..];
    const last = last_vertex[k..][0..4];
    switch (channel & 3) {
        0 => encodeDeltas4(u8, false, buffer, channel_data, vertex_count, vertex_size, last, 0),
        1 => encodeDeltas4(u16, false, buffer, channel_data, vertex_count, vertex_size, last, 0),
        2 => {
            const rot: u5 = @intCast(channel >> 4);
            encodeDeltas4(u32, true, buffer, channel_data, vertex_count, vertex_size, last, rot);
        },
        else => unreachable,
    }
}

fn estimateBits(v: u8) usize {
    return if (v <= 15) (if (v <= 3) (if (v == 0) 0 else 2) else 4) else 8;
}

/// The rotation of the xor deltas of the channel at byte `k` that leaves
/// the fewest bits changing, judged over groups of `group_size` vertices.
fn estimateRotate(
    vertices: []const u8,
    vertex_count: usize,
    vertex_size: usize,
    k: usize,
    group_size: usize,
) u5 {
    var sizes: [8]usize = @splat(0);

    var offset = k;
    var last = std.mem.readInt(u32, vertices[offset..][0..4], .little);

    var i: usize = 0;
    while (i < vertex_count) : (i += group_size) {
        var bitg: u32 = 0;

        // The bits that change anywhere in the group.
        var j: usize = 0;
        while (j < group_size and i + j < vertex_count) : (j += 1) {
            const v = std.mem.readInt(u32, vertices[offset..][0..4], .little);
            const d = v ^ last;

            bitg |= d;
            last = v;
            offset += vertex_size;
        }

        for (&sizes, 0..) |*size, r| {
            const bitr = std.math.rotl(u32, bitg, r);

            size.* += estimateBits(@truncate(bitr >> 0)) + estimateBits(@truncate(bitr >> 8));
            size.* += estimateBits(@truncate(bitr >> 16)) + estimateBits(@truncate(bitr >> 24));
        }
    }

    var best_rot: u5 = 0;
    for (1..8) |rot| {
        best_rot = if (sizes[rot] < sizes[best_rot]) @intCast(rot) else best_rot;
    }

    return best_rot;
}

/// The channel encoding, of the first `max_channel`, that measures
/// smallest for the channel at byte `k` over every `block_skip`th block,
/// with the xor rotation `xor_rot`.
fn estimateChannel(
    vertices: []const u8,
    vertex_count: usize,
    vertex_size: usize,
    k: usize,
    vertex_block_size: usize,
    block_skip: usize,
    max_channel: u8,
    xor_rot: u5,
) u8 {
    // Zeroed, so the bytes past a short block, which load along with its
    // last groups, are defined.
    var blocks: [vertex_block_max_size * 4]u8 = @splat(0);
    assert(vertex_block_size <= vertex_block_max_size);

    var last_vertex: [256]u8 = @splat(0);

    var sizes: [3]usize = @splat(0);
    assert(max_channel <= 3);

    var i: usize = 0;
    while (i < vertex_count) : (i += vertex_block_size * block_skip) {
        const block_size = if (i + vertex_block_size < vertex_count)
            vertex_block_size
        else
            vertex_count - i;
        const block_size_aligned = std.mem.alignForward(usize, block_size, byte_group_size);
        const group_count = block_size_aligned / byte_group_size;

        const previous = if (i == 0) 0 else i - 1;
        @memcpy(last_vertex[0..vertex_size], vertices[previous * vertex_size ..][0..vertex_size]);

        // The groups past the end of a short block measure zeros.
        if (block_size < block_size_aligned) {
            for (0..4) |j| {
                const lane = blocks[j * vertex_block_max_size ..];
                @memset(lane[block_size..block_size_aligned], 0);
            }
        }

        const channel_xor = @as(u8, xor_rot) << 4;
        for (0..max_channel) |channel| {
            for (0..4) |j| {
                // The deltas of the channel's four bytes fill the four lanes
                // at once.
                if (j == 0) {
                    encodeDeltas(
                        &blocks,
                        vertices[i * vertex_size ..],
                        block_size,
                        vertex_size,
                        &last_vertex,
                        k,
                        @as(u8, @intCast(channel)) | channel_xor,
                    );
                }

                const lane = blocks[j * vertex_block_max_size ..][0..vertex_block_max_size];

                var lane_sizes: @Vector(measure_width, u64) = @splat(0);
                var first: usize = 0;
                while (first < group_count) : (first += measure_width) {
                    const chunk: GroupChunk = .load(lane, first, group_count);

                    // Only 1, 2, 4 and 8 bits, for the encoder's speed.
                    const size12 = @min(chunk.measure(1), chunk.measure(2));
                    const size124 = @min(size12, chunk.measure(4));
                    const size8: @Vector(measure_width, u64) = @splat(byte_group_size);
                    const best_size = @min(size124, size8);

                    lane_sizes += chunk.usedOnly(best_size);
                }
                sizes[channel] += @intCast(@reduce(.Add, lane_sizes));
            }
        }
    }

    var best_channel: u8 = 0;
    for (1..max_channel) |channel| {
        if (sizes[channel] < sizes[best_channel]) best_channel = @intCast(channel);
    }

    return if (best_channel == 2) best_channel | (@as(u8, xor_rot) << 4) else best_channel;
}

/// The control mode of a byte lane: 0 or 1 for byte groups with the bit
/// counts from `bits_v1` at that offset, 2 for all zeros, 3 for literals.
fn estimateControl(
    lane: *const [vertex_block_max_size]u8,
    vertex_count: usize,
    vertex_count_aligned: usize,
    level: u4,
) u2 {
    const group_count = vertex_count_aligned / byte_group_size;

    var nonzero: @Vector(measure_width, u64) = @splat(0);
    var first: usize = 0;
    while (first < group_count) : (first += measure_width) {
        const chunk: GroupChunk = .load(lane, first, group_count);
        nonzero |= chunk.usedOnly(chunk.lo | chunk.hi);
    }

    // Zero encoding.
    if (@reduce(.Or, nonzero) == 0) return 2;

    // 1, 2, 4 and 8 bits at level 0, for the encoder's speed.
    if (level == 0) return 1;

    // Four groups to a header byte.
    const header_size = (group_count + 3) / 4;

    var est0: @Vector(measure_width, u64) = @splat(0);
    var est1: @Vector(measure_width, u64) = @splat(0);

    first = 0;
    while (first < group_count) : (first += measure_width) {
        const chunk: GroupChunk = .load(lane, first, group_count);

        // These are the counts of `bits_v1`; both control modes have 1, 2
        // and 4 bits.
        const size12 = @min(chunk.measure(1), chunk.measure(2));
        const size124 = @min(size12, chunk.measure(4));

        // Mode 0 adds 0 bits, for the groups of zeros, and mode 1 adds 8.
        const size0: @Vector(measure_width, u64) = @splat(0);
        const size8: @Vector(measure_width, u64) = @splat(byte_group_size);
        const size1240 = @select(u64, chunk.zero(), size0, size124);
        const size1248 = @min(size124, size8);
        est0 += chunk.usedOnly(size1240);
        est1 += chunk.usedOnly(size1248);
    }

    const est_bytes0 = header_size + @as(usize, @intCast(@reduce(.Add, est0)));
    const est_bytes1 = header_size + @as(usize, @intCast(@reduce(.Add, est1)));

    // The shorter control mode, but literals when neither saves anything.
    if (est_bytes0 < vertex_count or est_bytes1 < vertex_count) {
        return if (est_bytes0 < est_bytes1) 0 else 1;
    }
    return 3;
}

/// Writes one block of `vertex_count` vertices at `data[start..]` and
/// returns where it ends, or null if `data` is too short. `last_vertex`
/// holds the vertex before the block, and the block's last on return.
fn encodeVertexBlock(
    data: []u8,
    start: usize,
    vertices: []const u8,
    vertex_count: usize,
    vertex_size: usize,
    last_vertex: *[256]u8,
    channels: *const [64]u8,
    version: VertexVersion,
    level: u4,
) ?usize {
    assert(vertex_count > 0 and vertex_count <= vertex_block_max_size);
    assert(vertex_size % 4 == 0);

    // The groups past the end of a short block encode zeros.
    var buffers: [vertex_block_max_size * 4]u8 = @splat(0);

    const vertex_count_aligned = std.mem.alignForward(usize, vertex_count, byte_group_size);

    const control_size = if (version == .v0) 0 else vertex_size / 4;
    if (data.len - start < control_size) return null;

    const control = data[start..][0..control_size];
    var pos = start + control_size;

    @memset(control, 0);

    for (0..vertex_size) |k| {
        // The deltas of a channel's four bytes fill the four lanes at once.
        if (k % 4 == 0) {
            const channel = if (version == .v0) 0 else channels[k / 4];
            encodeDeltas(&buffers, vertices, vertex_count, vertex_size, last_vertex, k, channel);
        }

        const buffer = buffers[(k % 4) * vertex_block_max_size ..][0..vertex_block_max_size];

        var ctrl: u2 = 0;

        if (version != .v0) {
            ctrl = estimateControl(buffer, vertex_count, vertex_count_aligned, level);

            const ctrl_shift: u3 = @intCast((k % 4) * 2);
            control[k / 4] |= @as(u8, ctrl) << ctrl_shift;
        }

        if (ctrl == 3) {
            // Literal encoding.
            if (data.len - pos < vertex_count) return null;

            @memcpy(data[pos..][0..vertex_count], buffer[0..vertex_count]);
            pos += vertex_count;
        } else if (ctrl != 2) {
            // Byte groups; 2 is zero encoding, which writes nothing.
            const groups = buffer[0..vertex_count_aligned];
            const end = if (version == .v0)
                encodeBytes(data, pos, groups, bits_v0)
            else switch (ctrl) {
                inline 0, 1 => |c| encodeBytes(data, pos, groups, bits_v1[c..][0..4].*),
                else => unreachable,
            };
            pos = end orelse return null;
        }
    }

    const last_offset = vertex_size * (vertex_count - 1);
    @memcpy(last_vertex[0..vertex_size], vertices[last_offset..][0..vertex_size]);

    return pos;
}

/// Encodes `vertices`, `vertex_size` bytes each, into `buffer` at the
/// default compression level, 2, in the default version, and returns the
/// encoded size, or 0 if `buffer` is too small (`encodeVertexBufferBound`
/// is always enough). Every byte of every vertex is kept as it is, padding
/// too, so zero the padding. This encodes one vertex stream: encode each
/// stream of a mesh with several on its own. It compresses best when the
/// vertices are quantized and ordered for locality of reference (vertex
/// cache and fetch optimization) first.
///
/// `vertex_size` is a multiple of 4, at most 256.
pub fn encodeVertexBuffer(buffer: []u8, vertices: []const u8, vertex_size: usize) usize {
    return encodeVertexBufferLevel(buffer, vertices, vertex_size, encode_default_level, .default);
}

/// `encodeVertexBuffer` at compression `level`, from 0, the fastest, to 3,
/// the slowest and smallest (4 to 9 encode as 3), in format `version`. The
/// level changes only version 1's output; `encodeVertexBuffer` uses level 2.
pub fn encodeVertexBufferLevel(
    buffer: []u8,
    vertices: []const u8,
    vertex_size: usize,
    level: u4,
    version: VertexVersion,
) usize {
    assert(vertex_size > 0 and vertex_size <= 256);
    assert(vertex_size % 4 == 0);
    // Only a part of this range does anything different so far.
    assert(level <= 9);
    assert(vertices.len % vertex_size == 0);
    const vertex_count = vertices.len / vertex_size;

    if (buffer.len < 1) return 0;

    buffer[0] = vertex_header | @as(u8, @backingInt(version));
    var pos: usize = 1;

    var first_vertex: [256]u8 = @splat(0);
    if (vertex_count > 0) @memcpy(first_vertex[0..vertex_size], vertices[0..vertex_size]);

    var last_vertex = first_vertex;

    const vertex_block_size = getVertexBlockSize(vertex_size);

    var channels: [64]u8 = @splat(0);
    if (version != .v0 and level > 1 and vertex_count > 1) {
        var k: usize = 0;
        while (k < vertex_size) : (k += 4) {
            const rot = if (level >= 3)
                estimateRotate(vertices, vertex_count, vertex_size, k, 16)
            else
                0;
            const channel = estimateChannel(
                vertices,
                vertex_count,
                vertex_size,
                k,
                vertex_block_size,
                3,
                if (level >= 3) 3 else 2,
                rot,
            );

            channels[k / 4] = channel;
        }
    }

    var vertex_offset: usize = 0;

    while (vertex_offset < vertex_count) {
        const block_size = if (vertex_offset + vertex_block_size < vertex_count)
            vertex_block_size
        else
            vertex_count - vertex_offset;

        pos = encodeVertexBlock(
            buffer,
            pos,
            vertices[vertex_offset * vertex_size ..][0 .. block_size * vertex_size],
            block_size,
            vertex_size,
            &last_vertex,
            &channels,
            version,
            level,
        ) orelse return 0;

        vertex_offset += block_size;
    }

    const tail_size = vertex_size + (if (version == .v0) 0 else vertex_size / 4);
    const tail_size_min: usize = if (version == .v0) tail_min_size_v0 else tail_min_size_v1;
    const tail_size_pad = @max(tail_size, tail_size_min);

    if (buffer.len - pos < tail_size_pad) return 0;

    if (tail_size < tail_size_pad) {
        @memset(buffer[pos..][0 .. tail_size_pad - tail_size], 0);
        pos += tail_size_pad - tail_size;
    }

    @memcpy(buffer[pos..][0..vertex_size], first_vertex[0..vertex_size]);
    pos += vertex_size;

    if (version != .v0) {
        @memcpy(buffer[pos..][0 .. vertex_size / 4], channels[0 .. vertex_size / 4]);
        pos += vertex_size / 4;
    }

    return pos;
}

/// The most bytes `encodeVertexBuffer` writes for `vertex_count` vertices
/// of `vertex_size` bytes, at any level and version.
pub fn encodeVertexBufferBound(vertex_count: usize, vertex_size: usize) usize {
    assert(vertex_size > 0 and vertex_size <= 256);
    assert(vertex_size % 4 == 0);

    const vertex_block_size = getVertexBlockSize(vertex_size);
    const vertex_block_count = (vertex_count + vertex_block_size - 1) / vertex_block_size;

    const vertex_block_control_size = vertex_size / 4;
    const vertex_byte_header_size = (vertex_block_size / byte_group_size + 3) / 4;
    const vertex_byte_data_size = vertex_block_size;

    const tail_size = vertex_size + (vertex_size / 4);
    const tail_size_min = @max(tail_min_size_v0, tail_min_size_v1);
    const tail_size_pad = @max(tail_size, tail_size_min);

    const block_size = vertex_block_control_size +
        vertex_size * (vertex_byte_header_size + vertex_byte_data_size);
    return 1 + vertex_block_count * block_size + tail_size_pad;
}

// --------------------------------------------------------
// Decoder
// --------------------------------------------------------

/// The format version of `buffer`, or null if its header is not a vertex
/// buffer header of a version this decoder reads. A version does not mean
/// the rest of a malformed buffer decodes.
pub fn decodeVertexVersion(buffer: []const u8) ?VertexVersion {
    if (buffer.len < 1) return null;

    const header = buffer[0];

    if (header & 0xf0 != vertex_header) return null;

    const version_bits: u4 = @truncate(header);
    if (version_bits > decode_vertex_version) return null;

    const version: VertexVersion = @fromBackingInt(version_bits);
    return version;
}

/// Decodes `buffer`, as `encodeVertexBuffer` writes it, into `destination`,
/// whose length is the vertex count times `vertex_size`. Untrusted input is
/// safe: a malformed buffer fails or decodes to garbage, and never makes the
/// decoder read or write out of bounds. After an error, `destination` holds
/// unspecified bytes.
///
/// `vertex_size` is a multiple of 4, at most 256.
pub fn decodeVertexBuffer(
    destination: []u8,
    vertex_size: usize,
    buffer: []const u8,
) DecodeVertexError!void {
    return decode(decoder_default, destination, vertex_size, buffer);
}

/// The decoders: the scalar one, and the SIMD one with the byte group
/// decoding of each instruction set.
const Decoder = enum { scalar, ssse3, avx512, neon };

/// The byte group decoding of a SIMD decoder.
fn groupDecoder(comptime decoder: Decoder) type {
    return switch (decoder) {
        .scalar => unreachable,
        .ssse3 => ssse3,
        .avx512 => avx512,
        .neon => neon,
    };
}

/// The SIMD decoders call LLVM's intrinsics for the instructions vectors
/// cannot express, so they need the LLVM backend; and their bit tricks read
/// bytes as little-endian words.
const simd_backend = builtin.zig_backend == .stage2_llvm and
    builtin.cpu.arch.endian() == .little;

/// The decoder `decodeVertexBuffer` uses, chosen as the original chooses
/// its SIMD path at compile time.
const decoder_default: Decoder = if (!simd_backend)
    .scalar
else if (builtin.cpu.hasAll(.x86, &.{ .avx512vbmi2, .avx512vbmi, .avx512vl }))
    .avx512
else if (builtin.cpu.has(.x86, .avx) or builtin.cpu.hasAll(.x86, &.{ .ssse3, .popcnt }))
    .ssse3
else if (builtin.cpu.arch == .aarch64 and builtin.cpu.has(.aarch64, .neon))
    .neon
else
    .scalar;

fn decode(
    comptime decoder: Decoder,
    destination: []u8,
    vertex_size: usize,
    buffer: []const u8,
) DecodeVertexError!void {
    assert(vertex_size > 0 and vertex_size <= 256);
    assert(vertex_size % 4 == 0);
    assert(destination.len % vertex_size == 0);
    const vertex_count = destination.len / vertex_size;

    if (buffer.len < 1) return error.InvalidData;

    const data_header = buffer[0];

    if (data_header & 0xf0 != vertex_header) return error.InvalidHeader;

    const version_bits: u4 = @truncate(data_header);
    if (version_bits > decode_vertex_version) return error.InvalidHeader;
    const version: VertexVersion = @fromBackingInt(version_bits);

    const tail_size = vertex_size + (if (version == .v0) 0 else vertex_size / 4);
    const tail_size_min: usize = if (version == .v0) tail_min_size_v0 else tail_min_size_v1;
    const tail_size_pad = @max(tail_size, tail_size_min);

    if (buffer.len - 1 < tail_size_pad) return error.InvalidData;

    const tail = buffer[buffer.len - tail_size ..];

    var last_vertex: [256]u8 = undefined;
    @memcpy(last_vertex[0..vertex_size], tail[0..vertex_size]);

    const channels = tail[vertex_size..];

    const vertex_block_size = getVertexBlockSize(vertex_size);

    var pos: usize = 1;
    var vertex_offset: usize = 0;

    while (vertex_offset < vertex_count) {
        const block_size = if (vertex_offset + vertex_block_size < vertex_count)
            vertex_block_size
        else
            vertex_count - vertex_offset;

        const block = destination[vertex_offset * vertex_size ..][0 .. block_size * vertex_size];
        const end = switch (decoder) {
            .scalar => decodeVertexBlock(
                buffer,
                pos,
                block,
                vertex_size,
                &last_vertex,
                channels,
                version,
            ),
            else => decodeVertexBlockSimd(
                groupDecoder(decoder),
                buffer,
                pos,
                block,
                vertex_size,
                &last_vertex,
                channels,
                version,
            ),
        };
        pos = end orelse return error.InvalidData;

        vertex_offset += block_size;
    }

    if (buffer.len - pos != tail_size_pad) return error.LengthMismatch;
}

// --------------------------------------------------------
// Scalar decoder
// --------------------------------------------------------

/// Decodes the group of `bits`-bit values at `data[pos..]`, which has
/// `byte_group_decode_limit` bytes, into `out`, and returns where the group
/// ends.
fn decodeBytesGroup(data: []const u8, pos: usize, out: *[byte_group_size]u8, bits: u8) usize {
    switch (bits) {
        0 => {
            out.* = @splat(0);
            return pos;
        },
        1 => return decodeBytesGroupBits(1, data, pos, out),
        2 => return decodeBytesGroupBits(2, data, pos, out),
        4 => return decodeBytesGroupBits(4, data, pos, out),
        8 => {
            out.* = data[pos..][0..byte_group_size].*;
            return pos + byte_group_size;
        },
        else => unreachable,
    }
}

fn decodeBytesGroupBits(
    comptime bits: u4,
    data: []const u8,
    pos: usize,
    out: *[byte_group_size]u8,
) usize {
    const sentinel = (1 << bits) - 1;
    const per_byte: usize = 8 / @as(usize, bits);
    const selector_size = byte_group_size / per_byte;

    // The sentinels' bytes follow the selectors.
    var var_pos = pos + selector_size;

    inline for (0..selector_size) |s| {
        var byte = data[pos + s];
        if (bits == 1) byte = reverseBits(byte);

        inline for (0..per_byte) |n| {
            const enc = byte >> (8 - bits);
            byte <<= bits;
            const encv = data[var_pos];
            out[s * per_byte + n] = if (enc == sentinel) encv else enc;
            var_pos += @intFromBool(enc == sentinel);
        }
    }

    return var_pos;
}

/// Decodes the byte groups at `data[start..]` into `buffer` with the bit
/// counts `bits` that the headers select, and returns where they end, or
/// null if `data` is too short.
fn decodeBytes(data: []const u8, start: usize, buffer: []u8, bits: *const [4]u8) ?usize {
    assert(buffer.len % byte_group_size == 0);

    // Four groups to a header byte.
    const header_size = (buffer.len / byte_group_size + 3) / 4;
    if (data.len - start < header_size) return null;

    const header = data[start..][0..header_size];
    var pos = start + header_size;

    var i: usize = 0;
    while (i < buffer.len) : (i += byte_group_size) {
        if (data.len - pos < byte_group_decode_limit) return null;

        const header_offset = i / byte_group_size;
        const header_shift: u3 = @intCast((header_offset % 4) * 2);
        const bitsk: u2 = @truncate(header[header_offset / 4] >> header_shift);

        pos = decodeBytesGroup(data, pos, buffer[i..][0..byte_group_size], bits[bitsk]);
    }

    return pos;
}

/// Undoes `encodeDeltas4` for `vertex_count` vertices from the four lanes
/// at the start of `buffer`, `vertex_count` bytes each, into the channel's
/// bytes of each vertex in `transposed`, `vertex_size` bytes apart.
fn decodeDeltas4(
    comptime T: type,
    comptime xor: bool,
    buffer: []const u8,
    transposed: []u8,
    vertex_count: usize,
    vertex_size: usize,
    last_vertex: *const [4]u8,
    rot: u5,
) void {
    inline for (0..4 / @sizeOf(T)) |n| {
        const k = n * @sizeOf(T);
        const lanes = buffer[k * vertex_count ..];

        var vertex_offset: usize = k;

        var p = std.mem.readInt(T, last_vertex[k..][0..@sizeOf(T)], .little);

        for (0..vertex_count) |i| {
            var v: T = lanes[i];
            inline for (1..@sizeOf(T)) |j| v |= @as(T, lanes[i + vertex_count * j]) << (8 * j);

            v = if (xor) std.math.rotl(T, v, rot) ^ p else unzigzag(T, v) +% p;

            std.mem.writeInt(T, transposed[vertex_offset..][0..@sizeOf(T)], v, .little);

            p = v;

            vertex_offset += vertex_size;
        }
    }
}

/// Decodes one block at `data[start..]` into `vertex_data`, its vertices,
/// and returns where it ends, or null if the block is malformed.
/// `last_vertex` holds the vertex before the block, and the block's last on
/// return.
fn decodeVertexBlock(
    data: []const u8,
    start: usize,
    vertex_data: []u8,
    vertex_size: usize,
    last_vertex: *[256]u8,
    channels: []const u8,
    version: VertexVersion,
) ?usize {
    const vertex_count = vertex_data.len / vertex_size;
    assert(vertex_count > 0 and vertex_count <= vertex_block_max_size);

    var buffer: [vertex_block_max_size * 4]u8 = undefined;
    var transposed: [vertex_block_size_bytes]u8 = undefined;

    const vertex_count_aligned = std.mem.alignForward(usize, vertex_count, byte_group_size);

    const control_size = if (version == .v0) 0 else vertex_size / 4;
    if (data.len - start < control_size) return null;

    const control = data[start..][0..control_size];
    var pos = start + control_size;

    var k: usize = 0;
    while (k < vertex_size) : (k += 4) {
        const ctrl_byte = if (version == .v0) 0 else control[k / 4];

        for (0..4) |j| {
            const ctrl_shift: u3 = @intCast(j * 2);
            const ctrl: u2 = @truncate(ctrl_byte >> ctrl_shift);
            const lane = buffer[j * vertex_count ..];

            switch (ctrl) {
                3 => {
                    // Literal encoding.
                    if (data.len - pos < vertex_count) return null;

                    @memcpy(lane[0..vertex_count], data[pos..][0..vertex_count]);
                    pos += vertex_count;
                },
                2 => {
                    // Zero encoding.
                    @memset(lane[0..vertex_count], 0);
                },
                else => {
                    const bits = if (version == .v0) &bits_v0 else bits_v1[ctrl..][0..4];
                    const lane_groups = lane[0..vertex_count_aligned];
                    pos = decodeBytes(data, pos, lane_groups, bits) orelse return null;
                },
            }
        }

        const channel = if (version == .v0) 0 else channels[k / 4];
        const target = transposed[k..];
        const last = last_vertex[k..][0..4];

        switch (channel & 3) {
            0 => decodeDeltas4(u8, false, &buffer, target, vertex_count, vertex_size, last, 0),
            1 => decodeDeltas4(u16, false, &buffer, target, vertex_count, vertex_size, last, 0),
            2 => {
                const rot: u5 = @truncate(32 - @as(u32, channel >> 4));
                decodeDeltas4(u32, true, &buffer, target, vertex_count, vertex_size, last, rot);
            },
            // An unknown channel encoding.
            else => return null,
        }
    }

    @memcpy(vertex_data, transposed[0 .. vertex_count * vertex_size]);

    const last_offset = vertex_size * (vertex_count - 1);
    @memcpy(last_vertex[0..vertex_size], transposed[last_offset..][0..vertex_size]);

    return pos;
}

// --------------------------------------------------------
// SIMD decoder
// --------------------------------------------------------

/// For each mask of eight lanes, the shuffle that moves the next sentinel
/// byte to each set lane (0x80 zeroes the lane).
const decode_shuffle: [256][8]u8 = shuffles: {
    var shuffles: [256][8]u8 = undefined;

    @setEvalBranchQuota(10_000);
    for (&shuffles, 0..) |*shuffle, mask| {
        var count: u8 = 0;

        for (shuffle, 0..) |*index, i| {
            const maski = (mask >> i) & 1;
            index.* = if (maski != 0) count else 0x80;
            count += maski;
        }
    }

    break :shuffles shuffles;
};

/// For each mask of eight lanes, the number of set lanes.
const decode_count: [256]u8 = counts: {
    var counts: [256]u8 = undefined;
    for (&counts, 0..) |*count, mask| count.* = @popCount(mask);
    break :counts counts;
};

/// Header bits (0 to 3 for version 0's 0, 2, 4 and 8 bits; 4 to 8 for
/// version 1's 0, 1, 2, 4 and 8) as 0 for 1-bit groups, 1 for 2-bit, 2 for
/// 4-bit, 3 for 8-bit and 4 for 0-bit, which makes some uses easier.
const header_bits_shift = [9]u3{ 4, 1, 2, 3, 4, 0, 1, 2, 3 };

/// The bit of each group value that `sentinelBits` sets when all its bits
/// are one, by header bits.
const header_bits_lanes = [9]u64{
    0,
    0x55555555,
    0x1111111111111111,
    0,
    0,
    0xffff,
    0x55555555,
    0x1111111111111111,
    0,
};

/// The values of the group at the start of `window` that are sentinels, one
/// bit each at the bits `header_bits_lanes` picks; `n` from
/// `header_bits_shift`. Counting them from the selectors as plain bytes is
/// shorter than through the vector mask, and the next group's position
/// waits on the count.
fn sentinelBits(window: *const [byte_group_decode_limit]u8, n: u3) u64 {
    var data64: u64 = @bitCast(window[0..8].*);
    data64 &= data64 >> n;
    data64 &= data64 >> (n >> 1);
    return data64;
}

/// Where a group with `header_bits_shift` value `n` and `count` sentinels
/// ends: 0-bit groups wrap the shift to zero.
fn groupEnd(pos: usize, n: u3, count: usize) usize {
    return pos + ((@as(usize, 2) << n) & 31) + count;
}

// LLVM's intrinsics for the byte shuffles, expands and bit-field selects
// that vector code cannot express. The SIMD decoders that use them exist
// only for targets with them.
extern fn @"llvm.x86.ssse3.pshuf.b.128"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);
extern fn @"llvm.x86.sse2.psad.bw"(@Vector(16, u8), @Vector(16, u8)) @Vector(2, u64);
extern fn @"llvm.x86.avx512.pmultishift.qb.128"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);
extern fn @"llvm.x86.avx512.mask.expand.v16i8"(
    @Vector(16, u8),
    @Vector(16, u8),
    @Vector(16, u1),
) @Vector(16, u8);
extern fn @"llvm.aarch64.neon.tbl1.v16i8"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);

/// Byte `indices[i]` of `table` in lane `i`, or zero for indices of 0x80
/// and up; other indices of 16 and up are not used.
fn shuffleBytes(table: @Vector(16, u8), indices: @Vector(16, u8)) @Vector(16, u8) {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => @"llvm.x86.ssse3.pshuf.b.128"(table, indices),
        .aarch64 => @"llvm.aarch64.neon.tbl1.v16i8"(table, indices),
        else => @compileError("no byte shuffle for this target"),
    };
}

const zero8: @Vector(8, u8) = @splat(0);

/// Each lane of `is` as a byte of all ones or all zeros.
fn laneMask(is: @Vector(16, bool)) @Vector(16, u8) {
    return @select(u8, is, @as(@Vector(16, u8), @splat(0xff)), @as(@Vector(16, u8), @splat(0)));
}

/// Interleaves the bytes of the low halves of `a` and `b`, or of the high
/// halves.
fn zipBytes(comptime half: enum { lo, hi }, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const len = @typeInfo(@TypeOf(a)).vector.len;
    const base = if (half == .lo) 0 else len / 2;
    const mask = comptime mask: {
        var mask: [len]i32 = undefined;
        for (0..len / 2) |i| {
            mask[2 * i] = base + i;
            mask[2 * i + 1] = ~@as(i32, base + i);
        }
        break :mask mask;
    };
    return @shuffle(u8, a, b, mask);
}

/// The SSSE3 decoder: the values are unpacked with a byte shuffle and two
/// multiplies, and the sentinels expanded with a byte shuffle from a table.
const ssse3 = struct {
    /// Every header byte of zeros or of all 8-bit groups is decoded with
    /// one store or copy: there the branchless decoders are slower than
    /// branching over them.
    const skips_uniform_headers = true;

    /// The sentinel mask, the shuffle that copies each selector byte to both
    /// halves of a 16-bit lane, and the two multipliers (even and odd values)
    /// that emulate a multishift, by header bits.
    const config = [9][4][16]u8{
        .{
            .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
            @splat(128),
            @splat(0),
            @splat(0),
        },
        .{
            @splat(3),
            .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 },
            .{ 4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0 },
            .{ 16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1 },
        },
        .{
            @splat(15),
            .{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 },
            .{ 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0 },
            .{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 },
        },
        .{ @splat(0), @splat(128), @splat(0), @splat(0) },
        .{ @splat(1), @splat(128), @splat(0), @splat(0) },
        .{
            @splat(1),
            .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 },
            .{ 0, 1, 64, 0, 16, 0, 4, 0, 0, 1, 64, 0, 16, 0, 4, 0 },
            .{ 128, 0, 32, 0, 8, 0, 2, 0, 128, 0, 32, 0, 8, 0, 2, 0 },
        },
        .{
            @splat(3),
            .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 },
            .{ 4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0 },
            .{ 16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1 },
        },
        .{
            @splat(15),
            .{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 },
            .{ 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0 },
            .{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 },
        },
        .{ @splat(0), @splat(128), @splat(0), @splat(0) },
    };

    fn mulhi(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
        const a16: @Vector(8, u32) = @as(@Vector(8, u16), @bitCast(a));
        const b16: @Vector(8, u32) = @as(@Vector(8, u16), @bitCast(b));
        const high: @Vector(8, u16) = @truncate((a16 * b16) >> @splat(16));
        return @bitCast(high);
    }

    fn decode(data: []const u8, pos: usize, out: *[byte_group_size]u8, hbits: u4) usize {
        const n = header_bits_shift[hbits];
        const window = data[pos..][0..byte_group_decode_limit];

        const datacnt = @popCount(sentinelBits(window, n) & header_bits_lanes[hbits]);

        // 8-bit groups load their bytes through `skip`, where they are
        // easier to keep; for 0-bit groups the loads do not matter, as the
        // mask is zero. In both cases the shift wraps to zero.
        const skip = (@as(usize, 2) << n) & 15;

        const selb = std.simd.join(@as(@Vector(8, u8), window[0..8].*), zero8);
        const rest: @Vector(16, u8) = window[skip..][0..16].*;

        const cfg = &config[hbits];

        // Unpacks the 1-, 2- or 4-bit values: the shuffle copies each source
        // byte to both halves of a 16-bit lane, and the high half of each
        // multiply moves the even and the odd values to the low byte.
        const selw = shuffleBytes(selb, cfg[1]);
        const sel0 = mulhi(selw, cfg[2]);
        const sel1 = mulhi(selw, cfg[3]);
        const sel1_odd = @as(@Vector(8, u16), @bitCast(sel1)) << @splat(8);
        const seli = sel0 | @as(@Vector(16, u8), @bitCast(sel1_odd));

        // Masks the values to their bits: for 0- and 8-bit groups the
        // multiplies made zeros.
        const sent: @Vector(16, u8) = cfg[0];
        const sel = seli & sent;

        // The sentinels: none in 0-bit groups (zero values, sentinel 1), all
        // in 8-bit ones (zero values, sentinel 0).
        const is_sentinel = sel == sent;
        const mask = laneMask(is_sentinel);
        const mask16: u16 = @bitCast(is_sentinel);
        const mask0: u8 = @truncate(mask16);
        const mask1: u8 = @truncate(mask16 >> 8);

        // The shuffle from both halves' tables; the second half's moves on
        // by the first half's count.
        const sm0: @Vector(8, u8) = decode_shuffle[mask0];
        const sm1: @Vector(8, u8) = decode_shuffle[mask1];

        // With each mask lane 0x00 or 0xff, the low word of the sum is 255
        // times the first half's count: its low byte is minus the count.
        const npops: @Vector(16, u8) = @bitCast(@"llvm.x86.sse2.psad.bw"(mask, @splat(0)));
        const sm1r = sm1 -% @shuffle(u8, npops, undefined, @as([8]i32, @splat(0)));
        const shuf = std.simd.join(sm0, sm1r);

        // Expands the sentinels' bytes into their lanes and combines them
        // with the other values; the shuffle zeroes the lanes of the latter.
        out.* = shuffleBytes(rest, shuf) | (~mask & sel);

        return groupEnd(pos, n, datacnt);
    }
};

/// The AVX-512 decoder: the values are unpacked with a multishift, and the
/// sentinels expanded with an expand.
const avx512 = struct {
    const skips_uniform_headers = true;

    /// The mask of each value's bits, the multishift control that moves
    /// value i to byte i, and what each value is compared with to find the
    /// sentinels, by header bits. 0-bit groups compare with a value no zero
    /// matches and 8-bit groups with zero, so that the expand keeps the
    /// zero values of the former and takes every byte of the latter.
    const config = [9][3][16]u8{
        .{ @splat(0), @splat(0), @splat(0xff) },
        .{
            @splat(3),
            .{ 6, 4, 2, 0, 14, 12, 10, 8, 22, 20, 18, 16, 30, 28, 26, 24 },
            @splat(3),
        },
        .{
            @splat(15),
            .{ 4, 0, 12, 8, 20, 16, 28, 24, 36, 32, 44, 40, 52, 48, 60, 56 },
            @splat(15),
        },
        .{ @splat(0), @splat(0), @splat(0) },
        .{ @splat(0), @splat(0), @splat(0xff) },
        .{
            @splat(1),
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
            @splat(1),
        },
        .{
            @splat(3),
            .{ 6, 4, 2, 0, 14, 12, 10, 8, 22, 20, 18, 16, 30, 28, 26, 24 },
            @splat(3),
        },
        .{
            @splat(15),
            .{ 4, 0, 12, 8, 20, 16, 28, 24, 36, 32, 44, 40, 52, 48, 60, 56 },
            @splat(15),
        },
        .{ @splat(0), @splat(0), @splat(0) },
    };

    fn decode(data: []const u8, pos: usize, out: *[byte_group_size]u8, hbits: u4) usize {
        const n = header_bits_shift[hbits];
        const window = data[pos..][0..byte_group_decode_limit];

        const datacnt = @popCount(sentinelBits(window, n) & header_bits_lanes[hbits]);

        // 8-bit groups load their bytes through `skip`, where they are
        // easier to keep; the shift wraps to zero.
        const skip = (@as(usize, 2) << n) & 15;

        const selb: u64 = @bitCast(window[0..8].*);
        const rest: @Vector(16, u8) = window[skip..][0..16].*;

        const cfg = &config[hbits];

        // Unpacks the 1-, 2- or 4-bit values and masks them to their bits;
        // for 0- and 8-bit groups they are all zero.
        const selw: @Vector(16, u8) = @bitCast(@as(@Vector(2, u64), @splat(selb)));
        const keep: @Vector(16, u8) = cfg[0];
        const sel = keep & @"llvm.x86.avx512.pmultishift.qb.128"(cfg[1], selw);

        // Expands the sentinels' bytes into the sentinels' lanes.
        const is_sentinel: @Vector(16, u1) = @bitCast(sel == @as(@Vector(16, u8), cfg[2]));
        out.* = @"llvm.x86.avx512.mask.expand.v16i8"(rest, sel, is_sentinel);

        return groupEnd(pos, n, datacnt);
    }
};

/// The NEON decoder: one branch for each bit count, the values unpacked
/// with shifts and zips, and the sentinels expanded with two 8-byte table
/// lookups. On x86 it runs on SSSE3's byte shuffle, for tests.
const neon = struct {
    const skips_uniform_headers = false;

    /// The bytes of `rest0` and of `rest1` that the set bits of `mask0`
    /// and of `mask1` take, in order, in the set bits' lanes.
    fn expandBytes(
        mask0: u8,
        mask1: u8,
        rest0: @Vector(8, u8),
        rest1: @Vector(8, u8),
    ) @Vector(16, u8) {
        const sm0: @Vector(8, u8) = decode_shuffle[mask0];
        const sm1: @Vector(8, u8) = decode_shuffle[mask1];

        // One table of both halves: the second half's indices point past
        // the first's 8 bytes, and 0x80 stays 0x80 and up.
        const table = std.simd.join(rest0, rest1);
        const indices = std.simd.join(sm0, sm1 | @as(@Vector(8, u8), @splat(8)));
        return shuffleBytes(table, indices);
    }

    /// The set lanes of `mask`, each 0x00 or 0xff, as the bits of two bytes.
    fn moveMask(mask: @Vector(16, u8)) [2]u8 {
        // Found with the Z3 SMT solver, for eight bytes of 0xff or 0x00.
        const magic: u64 = 0x000103070f1f3f80;

        const mask2: [2]u64 = @bitCast(mask);

        return .{ @truncate((mask2[0] *% magic) >> 56), @truncate((mask2[1] *% magic) >> 56) };
    }

    /// The number of nibbles of `x` with their low bit set, 0 to 16.
    fn countNibbleBits(x: u64) usize {
        const low: u64 = 0x1111111111111111;
        // Adds all low bits of the nibbles into the top nibble, which holds
        // up to 15; all 16 set wraps to 0.
        const sum = ((x & low) *% low) >> 60;
        const all: u64 = @intFromBool((x & low) == low);
        return @intCast(sum | (all << 4));
    }

    fn decode(data: []const u8, pos: usize, out: *[byte_group_size]u8, hbits: u4) usize {
        switch (hbits) {
            0, 4 => {
                out.* = @splat(0);
                return pos;
            },
            1, 6 => {
                const window = data[pos..][0..byte_group_decode_limit];

                var data32: u32 = @bitCast(window[0..4].*);
                data32 &= data32 >> 1;

                // The low bits of data64's nibbles hold all 2-bit values of
                // data32.
                const data64 = (@as(u64, data32) << 30) | data32;
                const datacnt = countNibbleBits(data64);

                const sel2: @Vector(8, u8) = window[0..8].*;
                const sel22 = zipBytes(.lo, sel2 >> @splat(4), sel2);
                const sel2_shifted = sel22 >> @splat(2);
                const sel2222 = std.simd.join(
                    zipBytes(.lo, sel2_shifted, sel22),
                    zipBytes(.hi, sel2_shifted, sel22),
                );
                const sel = sel2222 & @as(@Vector(16, u8), @splat(3));

                const is_sentinel = sel == @as(@Vector(16, u8), @splat(3));
                const mask = laneMask(is_sentinel);
                const mask0, const mask1 = moveMask(mask);

                const rest0: @Vector(8, u8) = window[4..][0..8].*;
                const rest1: @Vector(8, u8) = window[4 + decode_count[mask0] ..][0..8].*;

                const sentinels = expandBytes(mask0, mask1, rest0, rest1);
                out.* = @select(u8, is_sentinel, sentinels, sel);

                return pos + 4 + datacnt;
            },
            2, 7 => {
                const window = data[pos..][0..byte_group_decode_limit];

                var data64: u64 = @bitCast(window[0..8].*);
                data64 &= data64 >> 1;
                data64 &= data64 >> 2;

                const datacnt = countNibbleBits(data64);

                const sel4: @Vector(8, u8) = window[0..8].*;
                const sel4_high = sel4 >> @splat(4);
                const sel4_low = sel4 & @as(@Vector(8, u8), @splat(15));
                const sel = std.simd.join(
                    zipBytes(.lo, sel4_high, sel4_low),
                    zipBytes(.hi, sel4_high, sel4_low),
                );

                const is_sentinel = sel == @as(@Vector(16, u8), @splat(15));
                const mask = laneMask(is_sentinel);
                const mask0, const mask1 = moveMask(mask);

                const rest0: @Vector(8, u8) = window[8..][0..8].*;
                const rest1: @Vector(8, u8) = window[8 + decode_count[mask0] ..][0..8].*;

                const sentinels = expandBytes(mask0, mask1, rest0, rest1);
                out.* = @select(u8, is_sentinel, sentinels, sel);

                return pos + 8 + datacnt;
            },
            3, 8 => {
                out.* = data[pos..][0..byte_group_size].*;
                return pos + byte_group_size;
            },
            5 => {
                const window = data[pos..][0..byte_group_decode_limit];

                const mask0 = window[0];
                const mask1 = window[1];

                const rest0: @Vector(8, u8) = window[2..][0..8].*;
                const rest1: @Vector(8, u8) = window[2 + decode_count[mask0] ..][0..8].*;

                out.* = expandBytes(mask0, mask1, rest0, rest1);

                return pos + 2 + @as(usize, decode_count[mask0]) + decode_count[mask1];
            },
            else => unreachable,
        }
    }
};

/// Decodes the byte groups at `data[start..]` into `buffer` with `groups`,
/// the headers' bit counts offset by `hshift` (0 for version 0, 4 plus the
/// control mode for version 1), and returns where they end, or null if
/// `data` is too short.
fn decodeBytesSimd(
    comptime groups: type,
    data: []const u8,
    start: usize,
    buffer: []u8,
    hshift: u4,
) ?usize {
    assert(buffer.len % byte_group_size == 0);

    // Four groups to a header byte.
    const header_size = (buffer.len / byte_group_size + 3) / 4;
    if (data.len - start < header_size) return null;

    const header = data[start..][0..header_size];
    var pos = start + header_size;

    var i: usize = 0;

    // Four groups at a time, with one bounds check.
    const quad = byte_group_size * 4;
    while (i + quad <= buffer.len and data.len - pos >= byte_group_decode_limit * 4) : (i += quad) {
        const header_byte = header[i / quad];

        if (groups.skips_uniform_headers) {
            // Four 0-bit groups (version 0, or version 1 mode 0), or four
            // 8-bit groups (version 0, or version 1 mode 1).
            if (hshift != 5 and header_byte == 0) {
                @memset(buffer[i..][0..quad], 0);
                continue;
            } else if (hshift != 4 and header_byte == 255) {
                buffer[i..][0..quad].* = data[pos..][0..quad].*;
                pos += quad;
                continue;
            }
        }

        inline for (0..4) |g| {
            const bits: u4 = @truncate(header_byte >> (g * 2));
            const out = buffer[i + byte_group_size * g ..][0..byte_group_size];
            pos = groups.decode(data, pos, out, hshift + (bits & 3));
        }
    }

    // The remaining groups.
    while (i < buffer.len) : (i += byte_group_size) {
        if (data.len - pos < byte_group_decode_limit) return null;

        const header_offset = i / byte_group_size;
        const header_shift: u3 = @intCast((header_offset % 4) * 2);
        const bits: u4 = @truncate(header[header_offset / 4] >> header_shift);

        const out = buffer[i..][0..byte_group_size];
        pos = groups.decode(data, pos, out, hshift + (bits & 3));
    }

    return pos;
}

/// Transposes 16 vertices' four byte lanes, one vector each, into four
/// vectors of four vertices' 4-byte channels.
fn transpose8(x: *[4]@Vector(16, u8)) void {
    const t0 = zipBytes(.lo, x[0], x[1]);
    const t1 = zipBytes(.hi, x[0], x[1]);
    const t2 = zipBytes(.lo, x[2], x[3]);
    const t3 = zipBytes(.hi, x[2], x[3]);

    x[0] = zipWords(.lo, t0, t2);
    x[1] = zipWords(.hi, t0, t2);
    x[2] = zipWords(.lo, t1, t3);
    x[3] = zipWords(.hi, t1, t3);
}

/// Interleaves the 16-bit words of the low halves of `a` and `b`, or of
/// the high halves.
fn zipWords(
    comptime half: enum { lo, hi },
    a: @Vector(16, u8),
    b: @Vector(16, u8),
) @Vector(16, u8) {
    const base = if (half == .lo) 0 else 4;
    const mask = comptime mask: {
        var mask: [8]i32 = undefined;
        for (0..4) |i| {
            mask[2 * i] = base + i;
            mask[2 * i + 1] = ~@as(i32, base + i);
        }
        break :mask mask;
    };
    const a16: @Vector(8, u16) = @bitCast(a);
    const b16: @Vector(8, u16) = @bitCast(b);
    return @bitCast(@shuffle(u16, a16, b16, mask));
}

/// `decodeDeltas4` with vectors, for the channel encoding `channel`, from
/// lanes `vertex_count_aligned` bytes long: 16 vertices at a time, which
/// writes the channels of the vertices past the block's end too.
fn decodeDeltas4Simd(
    comptime channel: u2,
    buffer: *const [vertex_block_max_size * 4]u8,
    transposed: []u8,
    vertex_count_aligned: usize,
    vertex_size: usize,
    last_vertex: *const [4]u8,
    rot: u5,
) void {
    var pi: @Vector(4, u8) = last_vertex.*;

    var save: usize = 0;

    var j: usize = 0;
    while (j < vertex_count_aligned) : (j += 16) {
        var r: [4]@Vector(16, u8) = undefined;
        inline for (&r, 0..) |*lane, i| lane.* = buffer[j + i * vertex_count_aligned ..][0..16].*;

        transpose8(&r);

        inline for (r) |deltas| {
            const values = switch (channel) {
                0 => unzigzagVector(@Vector(16, u8), deltas),
                1 => @as(@Vector(16, u8), @bitCast(
                    unzigzagVector(@Vector(8, u16), @bitCast(deltas)),
                )),
                2 => @as(@Vector(16, u8), @bitCast(
                    std.math.rotl(@Vector(4, u32), @bitCast(deltas), rot),
                )),
                3 => unreachable,
            };

            inline for (0..4) |v| {
                const channel_bytes = [4]i32{ 4 * v, 4 * v + 1, 4 * v + 2, 4 * v + 3 };
                const t = @shuffle(u8, values, undefined, channel_bytes);
                pi = switch (channel) {
                    0 => pi +% t,
                    1 => @bitCast(
                        @as(@Vector(2, u16), @bitCast(pi)) +% @as(@Vector(2, u16), @bitCast(t)),
                    ),
                    2 => pi ^ t,
                    3 => unreachable,
                };

                transposed[save..][0..4].* = pi;
                save += vertex_size;
            }
        }
    }
}

/// `decodeVertexBlock` with SIMD, decoding the byte groups with `groups`.
fn decodeVertexBlockSimd(
    comptime groups: type,
    data: []const u8,
    start: usize,
    vertex_data: []u8,
    vertex_size: usize,
    last_vertex: *[256]u8,
    channels: []const u8,
    version: VertexVersion,
) ?usize {
    const vertex_count = vertex_data.len / vertex_size;
    assert(vertex_count > 0 and vertex_count <= vertex_block_max_size);

    var buffer: [vertex_block_max_size * 4]u8 = undefined;
    var transposed: [vertex_block_size_bytes]u8 = undefined;

    const vertex_count_aligned = std.mem.alignForward(usize, vertex_count, byte_group_size);

    const control_size = if (version == .v0) 0 else vertex_size / 4;
    if (data.len - start < control_size) return null;

    const control = data[start..][0..control_size];
    var pos = start + control_size;

    var k: usize = 0;
    while (k < vertex_size) : (k += 4) {
        const ctrl_byte = if (version == .v0) 0 else control[k / 4];

        for (0..4) |j| {
            const ctrl_shift: u3 = @intCast(j * 2);
            const ctrl: u2 = @truncate(ctrl_byte >> ctrl_shift);
            const lane = buffer[j * vertex_count_aligned ..][0..vertex_count_aligned];

            switch (ctrl) {
                3 => {
                    // Literal encoding; copying the whole aligned lane is
                    // safe, as the tail follows.
                    if (data.len - pos < vertex_count_aligned) return null;

                    @memcpy(lane, data[pos..][0..vertex_count_aligned]);
                    pos += vertex_count;
                },
                2 => {
                    // Zero encoding.
                    @memset(lane, 0);
                },
                else => {
                    // Version 0's headers map to 0 to 3, version 1's to 4 to 8.
                    const hshift: u4 = if (version == .v0) 0 else 4 + @as(u4, ctrl);

                    pos = decodeBytesSimd(groups, data, pos, lane, hshift) orelse return null;
                },
            }
        }

        const channel = if (version == .v0) 0 else channels[k / 4];
        const target = transposed[k..];
        const last = last_vertex[k..][0..4];

        switch (channel & 3) {
            0 => decodeDeltas4Simd(0, &buffer, target, vertex_count_aligned, vertex_size, last, 0),
            1 => decodeDeltas4Simd(1, &buffer, target, vertex_count_aligned, vertex_size, last, 0),
            2 => {
                const rot: u5 = @truncate(32 - @as(u32, channel >> 4));
                decodeDeltas4Simd(2, &buffer, target, vertex_count_aligned, vertex_size, last, rot);
            },
            // An unknown channel encoding.
            else => return null,
        }
    }

    @memcpy(vertex_data, transposed[0 .. vertex_count * vertex_size]);

    const last_offset = vertex_size * (vertex_count - 1);
    @memcpy(last_vertex[0..vertex_size], transposed[last_offset..][0..vertex_size]);

    return pos;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

/// The decoders this machine runs: the scalar one, and each SIMD one whose
/// instructions the target has. The NEON one runs on x86 with SSSE3, too.
pub const testable_decoders = decoders: {
    var list: [4]Decoder = undefined;
    var len: usize = 0;
    list[len] = .scalar;
    len += 1;
    if (simd_backend) {
        const x86_ssse3 = builtin.cpu.has(.x86, .ssse3);
        if (x86_ssse3) {
            list[len] = .ssse3;
            len += 1;
        }
        if (builtin.cpu.hasAll(.x86, &.{ .avx512vbmi2, .avx512vbmi, .avx512vl, .avx512bw })) {
            list[len] = .avx512;
            len += 1;
        }
        if (x86_ssse3 or (builtin.cpu.arch == .aarch64 and builtin.cpu.has(.aarch64, .neon))) {
            list[len] = .neon;
            len += 1;
        }
    }
    break :decoders list[0..len].*;
};

/// `decodeVertexBuffer` with `decoder` instead of the target's best, for
/// tests that check every decoder this machine runs.
pub fn decodeVertexBufferWith(
    comptime decoder: Decoder,
    destination: []u8,
    vertex_size: usize,
    buffer: []const u8,
) DecodeVertexError!void {
    return decode(decoder, destination, vertex_size, buffer);
}

test "decode shuffle tables" {
    for (0..256) |mask| {
        try testing.expectEqual(@popCount(mask), decode_count[mask]);
        var next: u8 = 0;
        for (0..8) |i| {
            if ((mask >> @intCast(i)) & 1 != 0) {
                try testing.expectEqual(next, decode_shuffle[mask][i]);
                next += 1;
            } else {
                try testing.expectEqual(0x80, decode_shuffle[mask][i]);
            }
        }
    }
}

test "the NEON move mask gives each lane's bit" {
    for (0..256) |lo| {
        for ([_]u8{ 0, 0x5a, 0xff, @truncate(lo *% 37) }) |hi| {
            var lanes: [16]u8 = undefined;
            for (0..8) |i| {
                lanes[i] = if ((lo >> @intCast(i)) & 1 != 0) 0xff else 0;
                lanes[8 + i] = if ((hi >> @intCast(i)) & 1 != 0) 0xff else 0;
            }
            const masks = neon.moveMask(lanes);
            try testing.expectEqual(@as(u8, @intCast(lo)), masks[0]);
            try testing.expectEqual(hi, masks[1]);
        }
    }
}

test "the NEON decoder counts sixteen sentinels in 2- and 4-bit groups" {
    // Encoders never write these groups, as fewer bits would be smaller,
    // but a malformed buffer may hold them: every decoder counts them alike.
    try testing.expectEqual(16, neon.countNibbleBits(0x1111111111111111));
    try testing.expectEqual(15, neon.countNibbleBits(0x1111111111111110));
    try testing.expectEqual(0, neon.countNibbleBits(0xeeeeeeeeeeeeeeee));

    var data: [64]u8 = @splat(0xff);
    for (data[8..24], 0..) |*b, i| b.* = @intCast(i);
    inline for (testable_decoders) |decoder| {
        if (decoder == .scalar) continue;
        const groups = groupDecoder(decoder);
        for ([_]u4{ 1, 2, 6, 7 }) |hbits| {
            var out: [16]u8 = undefined;
            const end = groups.decode(&data, 0, &out, hbits);
            var want: [16]u8 = undefined;
            const scalar_bits: u8 = if (hbits == 1 or hbits == 6) 2 else 4;
            const want_end = decodeBytesGroup(&data, 0, &want, scalar_bits);
            try testing.expectEqual(want_end, end);
            try testing.expectEqualSlices(u8, &want, &out);
        }
    }
}

test "every decoder round-trips random vertices" {
    var prng: std.Random.DefaultPrng = .init(7);
    const rng = prng.random();
    var vertices: [300 * 16]u8 = undefined;
    var encoded: [encodeVertexBufferBound(300, 16)]u8 = undefined;
    var decoded: [300 * 16]u8 = undefined;
    for (0..20) |round| {
        // Small values, so every bit count and sentinels occur.
        for (&vertices) |*b| b.* = rng.int(u8) >> @intCast(round % 8);
        const count = rng.intRangeAtMost(usize, 0, 300);
        const bytes = vertices[0 .. count * 16];
        const version: VertexVersion = if (round % 3 == 0) .v0 else .v1;
        const size = encodeVertexBufferLevel(&encoded, bytes, 16, @intCast(round % 4), version);
        try testing.expect(size > 0);
        inline for (testable_decoders) |decoder| {
            try decodeVertexBufferWith(decoder, decoded[0..bytes.len], 16, encoded[0..size]);
            try testing.expectEqualSlices(u8, bytes, decoded[0..bytes.len]);
        }
    }
}
