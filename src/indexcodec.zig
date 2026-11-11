//! Index buffer compression: triangle lists coded against a cache of recent
//! edges and vertices, and arbitrary index sequences coded as deltas from
//! two baselines. Both formats are byte streams that general-purpose
//! compressors shrink further.
//!
//! Translated from meshoptimizer's indexcodec.cpp, which builds on Giesen,
//! "Simple lossless index buffer compression & follow-up" (2013), and
//! Stokes, "Vertex Cache Optimised Index Buffer Compression" (2014).

const std = @import("std");
const assert = std.debug.assert;

const index_header: u8 = 0xe0;
const sequence_header: u8 = 0xd0;

/// The newest format version the decoders read.
const decode_version_max = 1;

/// The format version the encoders write.
pub const IndexVersion = enum(u4) {
    /// Decodable by every version of the library.
    v0 = 0,
    /// Decodable by meshoptimizer 0.14 and later; codes strip-like runs and
    /// restarts more compactly.
    v1 = 1,

    /// The version the original encodes by default.
    pub const default: IndexVersion = .v1;
};

/// Why a decoder rejected its input. The decoders are safe on any input,
/// but data that passes may still decode to garbage, such as indices past
/// the vertex count.
pub const DecodeError = error{
    /// The header is not this format's, or names a version newer than this
    /// decoder reads.
    InvalidHeader,
    /// The buffer is too short for the index count, or its data runs out.
    Truncated,
    /// The data does not end where the buffer's tail begins.
    SizeMismatch,
};

const none = std.math.maxInt(u32);

const VertexFifo = [16]u32;
/// Edges as `.{ from, to }`. The decoder reads the two halves as two
/// loads, as it writes them: one wide load of two narrow stores would miss
/// store forwarding, and packing them into one word would lengthen the
/// chain from one triangle to the next.
const EdgeFifo = [16][2]u32;

/// The codes for the two non-first vertices of a restart that fit the
/// table; the last two entries are not used for encoding.
const code_aux_encoding_table = [16]u8{
    0x00, 0x76, 0x87, 0x56, 0x67, 0x78, 0xa9, 0x86,
    0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0,    0,
};

const rotations = [5]u32{ 0, 1, 2, 0, 1 };

fn rotateTriangle(b: u32, c: u32, next: u32) u32 {
    return if (b == next) 1 else if (c == next) 2 else 0;
}

/// The age of the newest edge in `fifo` that is one of the triangle's,
/// times 4, plus which edge it is (0 for ab, 1 for bc, 2 for ca).
fn getEdgeFifo(fifo: *const EdgeFifo, a: u32, b: u32, c: u32, offset: usize) ?u32 {
    const ab = @as(u64, a) << 32 | b;
    const bc = @as(u64, b) << 32 | c;
    const ca = @as(u64, c) << 32 | a;

    for (0..16) |i| {
        const index = (offset -% 1 -% i) & 15;

        const e = @as(u64, fifo[index][0]) << 32 | fifo[index][1];

        const age: u32 = @intCast(i);
        if (e == ab) return (age << 2) | 0;
        if (e == bc) return (age << 2) | 1;
        if (e == ca) return (age << 2) | 2;
    }

    return null;
}

fn pushEdgeFifo(fifo: *EdgeFifo, a: u32, b: u32, offset: *usize) void {
    fifo[offset.*][0] = a;
    fifo[offset.*][1] = b;
    offset.* = (offset.* + 1) & 15;
}

/// The age of the newest entry of `fifo` that is `v`.
fn getVertexFifo(fifo: *const VertexFifo, v: u32, offset: usize) ?u32 {
    for (0..16) |i| {
        const index = (offset -% 1 -% i) & 15;

        if (fifo[index] == v) return @intCast(i);
    }

    return null;
}

/// Writes `v` at `offset` and moves on by `advance`, 0 or 1: the decoder
/// writes unconditionally, so it stays branchless.
fn pushVertexFifo(fifo: *VertexFifo, v: u32, offset: *usize, advance: u1) void {
    fifo[offset.*] = v;
    offset.* = (offset.* + advance) & 15;
}

fn encodeVByte(buffer: []u8, data: *usize, value: u32) void {
    // A 32-bit value in up to 5 groups of 7 bits.
    var v = value;
    while (true) {
        // Built as a word, then stored as a byte: byte arithmetic would
        // write partial registers, which chain each group to the last.
        const group: u32 = (v & 127) | @as(u32, if (v > 127) 128 else 0);
        buffer[data.*] = @truncate(group);
        data.* += 1;
        v >>= 7;
        if (v == 0) break;
    }
}

fn decodeVByte(buffer: []const u8, data: *usize) u32 {
    const lead = buffer[data.*];
    data.* += 1;

    // The common case: one byte.
    if (lead < 128) return lead;

    // Up to 4 more bytes; the loop ends on malformed data too.
    var result: u32 = lead & 127;
    var shift: u5 = 7;

    for (0..4) |_| {
        const group = buffer[data.*];
        data.* += 1;
        result |= @as(u32, group & 127) << shift;
        shift +%= 7;

        if (group < 128) break;
    }

    return result;
}

/// The zigzag code of `v` as a two's complement difference: small
/// differences of either sign become small codes.
fn zigzag(d: u32) u32 {
    const sign: u32 = @bitCast(@as(i32, @bitCast(d)) >> 31);
    return (d << 1) ^ sign;
}

fn unzigzag(v: u32) u32 {
    return (v >> 1) ^ (0 -% (v & 1));
}

fn encodeIndex(buffer: []u8, data: *usize, index: u32, last: u32) void {
    encodeVByte(buffer, data, zigzag(index -% last));
}

fn decodeIndex(buffer: []const u8, data: *usize, last: u32) u32 {
    return last +% unzigzag(decodeVByte(buffer, data));
}

fn getCodeAuxIndex(v: u8, table: *const [16]u8) ?u32 {
    for (table, 0..) |entry, i| {
        if (entry == v) return @intCast(i);
    }

    return null;
}

fn writeTriangle(comptime T: type, destination: []T, triangle: usize, a: u32, b: u32, c: u32) void {
    destination[triangle * 3 ..][0..3].* = .{ @truncate(a), @truncate(b), @truncate(c) };
}

fn checkIndexType(comptime T: type) void {
    if (T != u16 and T != u32) @compileError("indices decode to u16 or u32, not " ++ @typeName(T));
}

/// Encodes the triangle list `indices` into `buffer` and returns the
/// encoded size, usually under 1.5 bytes per triangle, and under 1 byte
/// once compressed. Optimize the index buffer for the vertex cache and for
/// vertex fetch first, for the smallest result. `buffer` needs at most
/// `encodeIndexBufferBound` bytes; with fewer, the encoding may not fit.
pub fn encodeIndexBuffer(
    buffer: []u8,
    indices: []const u32,
    version: IndexVersion,
) error{NoSpaceLeft}!usize {
    assert(indices.len % 3 == 0);
    const triangle_count = indices.len / 3;

    // The smallest valid encoding: the header, 1 byte per triangle and the
    // 16-byte code table.
    if (buffer.len < 1 + triangle_count + 16) return error.NoSpaceLeft;

    const v1 = version != .v0;

    buffer[0] = index_header | @as(u8, @backingInt(version));

    var edge_fifo: EdgeFifo = @splat(.{ none, none });
    var vertex_fifo: VertexFifo = @splat(none);

    var edge_fifo_offset: usize = 0;
    var vertex_fifo_offset: usize = 0;

    var next: u32 = 0;
    var last: u32 = 0;

    var code: usize = 1;
    var data: usize = 1 + triangle_count;
    const data_safe_end = buffer.len - 16;

    const fecmax: u32 = if (v1) 13 else 15;

    // A fixed table, built from symbol frequencies over a set of training
    // meshes; packing once, building an optimal table and packing again
    // would compress better.
    const code_aux_table = &code_aux_encoding_table;

    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        // A triangle writes at most 16 bytes, 1 for the code and 5 for each
        // free index, so the writes below need no checks of their own.
        if (data > data_safe_end) return error.NoSpaceLeft;

        const triangle = indices[i..][0..3];
        const fer = getEdgeFifo(
            &edge_fifo,
            triangle[0],
            triangle[1],
            triangle[2],
            edge_fifo_offset,
        );

        if (fer != null and (fer.? >> 2) < 15) {
            // getEdgeFifo rotates the triangle implicitly, matching a and b
            // to the edge it found.
            const order = rotations[fer.? & 3 ..][0..3];

            const a = triangle[order[0]];
            const b = triangle[order[1]];
            const c = triangle[order[2]];

            // The edge's age, and the vertex's age in the fifo, next, or a
            // free index.
            const fe = fer.? >> 2;
            const fc = getVertexFifo(&vertex_fifo, c, vertex_fifo_offset);

            var fec: u32 = undefined;
            if (fc != null and fc.? >= 1 and fc.? < fecmax) {
                fec = fc.?;
            } else if (c == next) {
                next +%= 1;
                fec = 0;
            } else {
                fec = 15;
            }

            if (fec == 15 and v1) {
                // last-1 and last+1, for strip-like sequences.
                if (c +% 1 == last) {
                    fec = 13;
                    last = c;
                }
                if (c == last +% 1) {
                    fec = 14;
                    last = c;
                }
            }

            buffer[code] = @intCast((fe << 4) | fec);
            code += 1;

            // Free indices are differences from the last one.
            if (fec == 15) {
                encodeIndex(buffer, &data, c, last);
                last = c;
            }

            // Only the third vertex is pushed; the first two are likely in
            // the fifo already.
            if (fec == 0 or fec >= fecmax) pushVertexFifo(&vertex_fifo, c, &vertex_fifo_offset, 1);

            // Only two new edges; the third is in the fifo already.
            pushEdgeFifo(&edge_fifo, c, b, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, a, c, &edge_fifo_offset);
        } else {
            const rotation = rotateTriangle(triangle[1], triangle[2], next);
            const order = rotations[rotation..][0..3];

            const a = triangle[order[0]];
            const b = triangle[order[1]];
            const c = triangle[order[2]];

            // A triangle 0, 1, 2 is coded as a restart.
            var reset = false;

            if (a == 0 and b == 1 and c == 2 and next > 0 and v1) {
                reset = true;
                next = 0;

                // Clear the vertex fifo so later triangles never refer to
                // vertices from before, and next keeps counting up.
                vertex_fifo = @splat(none);
            }

            const fb = getVertexFifo(&vertex_fifo, b, vertex_fifo_offset);
            const fc = getVertexFifo(&vertex_fifo, c, vertex_fifo_offset);

            // After the rotation, a is almost always next, so no bits go to
            // a fifo age for it. The decoder takes feb = fec = 0 to mean
            // fea = 0 (a restart); the rotation ensures that.
            var fea: u32 = 15;
            if (a == next) {
                next +%= 1;
                fea = 0;
            }
            var feb: u32 = 15;
            if (fb != null and fb.? < 14) {
                feb = fb.? + 1;
            } else if (b == next) {
                next +%= 1;
                feb = 0;
            }
            var fec: u32 = 15;
            if (fc != null and fc.? < 14) {
                fec = fc.? + 1;
            } else if (c == next) {
                next +%= 1;
                fec = 0;
            }

            // feb and fec go as a 4-bit table position when the table has
            // them, and as a full byte otherwise.
            const code_aux: u8 = @intCast((feb << 4) | fec);
            const code_aux_index = getCodeAuxIndex(code_aux, code_aux_table);

            // Below 14 is a table position; 14 means fea = 0, 15 fea = 15.
            if (fea == 0 and code_aux_index != null and code_aux_index.? < 14 and !reset) {
                buffer[code] = @intCast((15 << 4) | code_aux_index.?);
                code += 1;
            } else {
                buffer[code] = @intCast((15 << 4) | 14 | fea);
                code += 1;
                buffer[data] = code_aux;
                data += 1;
            }

            // Free indices are differences from the last one.
            if (fea == 15) {
                encodeIndex(buffer, &data, a, last);
                last = a;
            }

            if (feb == 15) {
                encodeIndex(buffer, &data, b, last);
                last = b;
            }

            if (fec == 15) {
                encodeIndex(buffer, &data, c, last);
                last = c;
            }

            // Only vertices the fifo does not have yet.
            if (fea == 0 or fea == 15) pushVertexFifo(&vertex_fifo, a, &vertex_fifo_offset, 1);
            if (feb == 0 or feb == 15) pushVertexFifo(&vertex_fifo, b, &vertex_fifo_offset, 1);
            if (fec == 0 or fec == 15) pushVertexFifo(&vertex_fifo, c, &vertex_fifo_offset, 1);

            // None of the three edges is in the fifo; all go in, so later
            // triangles can match them.
            pushEdgeFifo(&edge_fifo, b, a, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, c, b, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, a, c, &edge_fifo_offset);
        }
    }

    if (data > data_safe_end) return error.NoSpaceLeft;

    // The code table ends the stream: the decoder reads restart codes from
    // it, and it is the padding that lets the decoder take every triangle
    // as at most 16 bytes of data (a code byte and three 5-byte indices)
    // without checking each read. Restarts are coded as a full byte of 0,
    // so the table's first entry must be 0, and no entry may name a free
    // index (15).
    comptime {
        assert(code_aux_encoding_table[0] == 0);
        for (code_aux_encoding_table) |entry| {
            assert(entry & 0xf != 0xf and entry >> 4 != 0xf);
        }
    }
    buffer[data..][0..16].* = code_aux_table.*;
    data += 16;

    return data;
}

/// The most bytes `encodeIndexBuffer` writes for `index_count` indices of
/// a mesh with `vertex_count` vertices.
pub fn encodeIndexBufferBound(index_count: usize, vertex_count: usize) usize {
    assert(index_count % 3 == 0);

    // The bits of each index.
    var vertex_bits: u32 = 1;

    while (vertex_bits < 32 and vertex_count > @as(usize, 1) << @intCast(vertex_bits)) {
        vertex_bits += 1;
    }

    // The worst case is 2 code bytes and 3 indices as 7-bit groups.
    const vertex_groups = (vertex_bits + 1 + 6) / 7;

    return 1 + (index_count / 3) * (2 + 3 * vertex_groups) + 16;
}

/// The format version of an encoded index buffer or sequence, or null if
/// its header is not one of theirs. A version does not mean the rest
/// decodes.
pub fn decodeIndexVersion(buffer: []const u8) ?IndexVersion {
    if (buffer.len < 1) return null;

    const header = buffer[0];

    if (header & 0xf0 != index_header and header & 0xf0 != sequence_header) return null;

    const version: u4 = @truncate(header);
    if (version > decode_version_max) return null;

    return @fromBackingInt(version);
}

/// Decodes the triangle list `encodeIndexBuffer` wrote into `buffer`, as
/// `destination.len` indices of type `T` (`u16` or `u32`); on an error,
/// `destination` holds what was decoded before it.
pub fn decodeIndexBuffer(comptime T: type, destination: []T, buffer: []const u8) DecodeError!void {
    comptime checkIndexType(T);
    assert(destination.len % 3 == 0);
    const triangle_count = destination.len / 3;

    // The smallest valid encoding: the header, 1 byte per triangle and the
    // 16-byte code table.
    if (buffer.len < 1 + triangle_count + 16) return error.Truncated;

    if (buffer[0] & 0xf0 != index_header) return error.InvalidHeader;

    const version = buffer[0] & 0x0f;
    if (version > decode_version_max) return error.InvalidHeader;

    var edge_fifo: EdgeFifo = @splat(.{ none, none });
    var vertex_fifo: VertexFifo = @splat(none);

    var edge_fifo_offset: usize = 0;
    var vertex_fifo_offset: usize = 0;

    var next: u32 = 0;
    var last: u32 = 0;

    const fecmax: u32 = if (version >= 1) 13 else 15;

    // The triangle data begins after the codes and has to end where the
    // 16-byte code table begins.
    const code_end = 1 + triangle_count;
    var data = code_end;

    // A triangle reads at most 16 bytes of data, 1 for the code and 5 for
    // each free index.
    const data_safe_end = buffer.len - 16;

    const code_aux_table = buffer[data_safe_end..][0..16];

    for (buffer[1..code_end], 0..) |code_tri, t| {
        if (code_tri < 0xf0) {
            const fe = code_tri >> 4;

            // The fifos wrap around their 16 entries.
            const edge = &edge_fifo[(edge_fifo_offset -% 1 -% fe) & 15];
            const a = edge[0];
            const b = edge[1];
            var c: u32 = 0;

            const fec = code_tri & 15;

            // The decoder's hottest path. Its outcomes are unpredictable,
            // so it is written as selects, which the compiler may still
            // turn into branches; a barrier against that, as the original
            // has, measured slower here.
            if (fec < fecmax) {
                const cf = vertex_fifo[(vertex_fifo_offset -% 1 -% fec) & 15];

                c = if (fec == 0) next else cf;

                const fec0: u1 = @intFromBool(fec == 0);
                next +%= fec0;

                // The fifo pushes must match the encoder's exactly, or the
                // data decodes wrong.
                pushVertexFifo(&vertex_fifo, c, &vertex_fifo_offset, fec0);
            } else {
                // Enough data for the worst case of one triangle.
                if (data > data_safe_end) return error.Truncated;

                // fec * 2 - 27 turns 13 and 14 into -1 and 1. Free indices
                // are differences from the last one.
                c = if (fec != 15)
                    last +% @as(u32, @bitCast(@as(i32, fec) * 2 - 27))
                else
                    decodeIndex(buffer, &data, last);
                last = c;

                pushVertexFifo(&vertex_fifo, c, &vertex_fifo_offset, 1);
            }

            pushEdgeFifo(&edge_fifo, c, b, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, a, c, &edge_fifo_offset);

            writeTriangle(T, destination, t, a, b, c);
        } else if (code_tri < 0xfe) {
            // A restart whose codes are in the table.
            const code_aux = code_aux_table[code_tri & 15];

            // The table never holds feb or fec 15.
            const feb = code_aux >> 4;
            const fec = code_aux & 15;

            // next counts up for all three vertices before any free index
            // decodes, as in the encoder.
            const a = next;
            next +%= 1;

            const bf = vertex_fifo[(vertex_fifo_offset -% feb) & 15];
            const b = if (feb == 0) next else bf;

            const feb0: u1 = @intFromBool(feb == 0);
            next +%= feb0;

            const cf = vertex_fifo[(vertex_fifo_offset -% fec) & 15];
            const c = if (fec == 0) next else cf;

            const fec0: u1 = @intFromBool(fec == 0);
            next +%= fec0;

            writeTriangle(T, destination, t, a, b, c);

            pushVertexFifo(&vertex_fifo, a, &vertex_fifo_offset, 1);
            pushVertexFifo(&vertex_fifo, b, &vertex_fifo_offset, feb0);
            pushVertexFifo(&vertex_fifo, c, &vertex_fifo_offset, fec0);

            pushEdgeFifo(&edge_fifo, b, a, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, c, b, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, a, c, &edge_fifo_offset);
        } else {
            // Enough data for the worst case of one triangle.
            if (data > data_safe_end) return error.Truncated;

            // A restart with its codes in a full byte.
            const code_aux = buffer[data];
            data += 1;

            const fea: u32 = if (code_tri == 0xfe) 0 else 15;
            const feb = code_aux >> 4;
            const fec = code_aux & 15;

            // A code byte of 0 outside the table is a reset.
            if (code_aux == 0) next = 0;

            // next counts up for all three vertices before any free index
            // decodes, as in the encoder.
            var a: u32 = 0;
            if (fea == 0) {
                a = next;
                next +%= 1;
            }
            var b: u32 = undefined;
            if (feb == 0) {
                b = next;
                next +%= 1;
            } else {
                b = vertex_fifo[(vertex_fifo_offset -% feb) & 15];
            }
            var c: u32 = undefined;
            if (fec == 0) {
                c = next;
                next +%= 1;
            } else {
                c = vertex_fifo[(vertex_fifo_offset -% fec) & 15];
            }

            // Free indices are differences from the last one.
            if (fea == 15) {
                a = decodeIndex(buffer, &data, last);
                last = a;
            }

            if (feb == 15) {
                b = decodeIndex(buffer, &data, last);
                last = b;
            }

            if (fec == 15) {
                c = decodeIndex(buffer, &data, last);
                last = c;
            }

            writeTriangle(T, destination, t, a, b, c);

            const feb_new: u1 = @intFromBool(feb == 0 or feb == 15);
            const fec_new: u1 = @intFromBool(fec == 0 or fec == 15);
            pushVertexFifo(&vertex_fifo, a, &vertex_fifo_offset, 1);
            pushVertexFifo(&vertex_fifo, b, &vertex_fifo_offset, feb_new);
            pushVertexFifo(&vertex_fifo, c, &vertex_fifo_offset, fec_new);

            pushEdgeFifo(&edge_fifo, b, a, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, c, b, &edge_fifo_offset);
            pushEdgeFifo(&edge_fifo, a, c, &edge_fifo_offset);
        }
    }

    // All the data is read, up to the code table.
    if (data != data_safe_end) return error.SizeMismatch;
}

/// Encodes the index sequence `indices`, of any topology, into `buffer` and
/// returns the encoded size. For triangle lists `encodeIndexBuffer` usually
/// does better. `buffer` needs at most `encodeIndexSequenceBound` bytes;
/// with fewer, the encoding may not fit.
pub fn encodeIndexSequence(
    buffer: []u8,
    indices: []const u32,
    version: IndexVersion,
) error{NoSpaceLeft}!usize {
    // The smallest valid encoding: the header, 1 byte per index and a 4-byte
    // tail.
    if (buffer.len < 1 + indices.len + 4) return error.NoSpaceLeft;

    buffer[0] = sequence_header | @as(u8, @backingInt(version));

    var last: [2]u32 = .{ 0, 0 };
    var current: u32 = 0;
    // last[current] at the top of each step, kept apart so the baseline
    // choice does not wait on it.
    var previous: u32 = 0;

    var data: usize = 1;
    const data_safe_end = buffer.len - 4;

    for (indices) |index| {
        // An index writes at most 5 bytes, and the 4-byte tail follows the
        // safe end, so the writes below need no checks of their own.
        if (data >= data_safe_end) return error.NoSpaceLeft;

        // Switch baselines as soon as the difference grows too large: the
        // difference should fit one byte (7 bits), and 2 bits go to its
        // sign and the baseline. The threshold could be tuned.
        const cd: i32 = @bitCast(index -% previous);
        current ^= @intFromBool(@abs(cd) >= 30);

        // The difference from the baseline's last index; the low bit names
        // the baseline.
        const v = zigzag(index -% last[current]);
        encodeVByte(buffer, &data, (v << 1) | current);

        last[current] = index;
        previous = index;
    }

    if (data > data_safe_end) return error.NoSpaceLeft;

    buffer[data..][0..4].* = @splat(0);
    data += 4;

    return data;
}

/// The most bytes `encodeIndexSequence` writes for `index_count` indices
/// below `vertex_count`.
pub fn encodeIndexSequenceBound(index_count: usize, vertex_count: usize) usize {
    // The bits of each index.
    var vertex_bits: u32 = 1;

    while (vertex_bits < 32 and vertex_count > @as(usize, 1) << @intCast(vertex_bits)) {
        vertex_bits += 1;
    }

    // The worst case is one difference of that many bits, plus the
    // baseline bit, as 7-bit groups.
    const vertex_groups = (vertex_bits + 1 + 1 + 6) / 7;

    return 1 + index_count * vertex_groups + 4;
}

/// Decodes the index sequence `encodeIndexSequence` wrote into `buffer`, as
/// `destination.len` indices of type `T` (`u16` or `u32`); on an error,
/// `destination` holds what was decoded before it.
pub fn decodeIndexSequence(
    comptime T: type,
    destination: []T,
    buffer: []const u8,
) DecodeError!void {
    comptime checkIndexType(T);

    // The smallest valid encoding: the header, 1 byte per index and a 4-byte
    // tail.
    if (buffer.len < 1 + destination.len + 4) return error.Truncated;

    if (buffer[0] & 0xf0 != sequence_header) return error.InvalidHeader;

    const version = buffer[0] & 0x0f;
    if (version > decode_version_max) return error.InvalidHeader;

    var data: usize = 1;
    const data_safe_end = buffer.len - 4;

    var last: [2]u32 = .{ 0, 0 };

    for (destination) |*d| {
        // An index reads at most 5 bytes, and the 4-byte tail follows the
        // safe end, so the reads below need no checks of their own.
        if (data >= data_safe_end) return error.Truncated;

        const v = decodeVByte(buffer, &data);

        // The low bit names the baseline; the rest is the difference.
        const current: u1 = @truncate(v);
        const index = last[current] +% unzigzag(v >> 1);

        last[current] = index;

        d.* = @truncate(index);
    }

    // All the data is read, up to the tail.
    if (data != data_safe_end) return error.SizeMismatch;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a triangle list round-trips in either version" {
    const indices = [_]u32{ 0, 1, 2, 2, 1, 3, 4, 5, 6, 0, 1, 2, 7, 8, 9, 300, 2, 70000 };
    var buffer: [encodeIndexBufferBound(indices.len, 70001)]u8 = undefined;
    for ([_]IndexVersion{ .v0, .v1 }) |version| {
        const size = try encodeIndexBuffer(&buffer, &indices, version);
        try testing.expectEqual(version, decodeIndexVersion(buffer[0..size]));
        var decoded: [indices.len]u32 = undefined;
        try decodeIndexBuffer(u32, &decoded, buffer[0..size]);
        try testing.expectEqualSlices(u32, &indices, &decoded);
    }
}

test "an index sequence round-trips" {
    // Differences take 30 bits at most, with the sign and the baseline bit.
    const indices = [_]u32{ 0, 1, 51, 2, 49, 1000, 0x3fff_ffff, 7 };
    var buffer: [encodeIndexSequenceBound(indices.len, 0x4000_0000)]u8 = undefined;
    const size = try encodeIndexSequence(&buffer, &indices, .default);
    var decoded: [indices.len]u32 = undefined;
    try decodeIndexSequence(u32, &decoded, buffer[0..size]);
    try testing.expectEqualSlices(u32, &indices, &decoded);
}
