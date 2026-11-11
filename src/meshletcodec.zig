//! Meshlet compression: one meshlet's triangles, coded against the edges of
//! the last triangles, and its vertex references, coded as grouped varint
//! differences. The decoder has a SIMD path that decodes two triangles or
//! four vertices with one byte shuffle each.
//!
//! Translated from meshoptimizer's meshletcodec.cpp.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Why `decodeMeshlet` rejected its input. The decoder is safe on any
/// input, but data that passes may still decode to garbage.
pub const DecodeError = error{
    /// The buffer is too short for the counts, or its data runs out.
    Truncated,
    /// The data does not end where the buffer's fixed-size tail begins.
    SizeMismatch,
};

const none = std.math.maxInt(u32);

/// The most vertices and triangles a meshlet may have.
const meshlet_vertices_max = 256;
const meshlet_triangles_max = 256;

const EdgeFifo8 = [8][2]u32;

const rotations = [5]u32{ 0, 1, 2, 0, 1 };

fn rotateTriangle(a: u32, b: u32, c: u32) u32 {
    return if (a > b and a > c) 1 else if (b > c) 2 else 0;
}

/// The age of the newest edge in `fifo` that is one of the triangle's,
/// times 4, plus which edge it is (0 for ab, 1 for bc, 2 for ca). Only
/// the 6 newest are searched, as the codes reach no older edge: a match
/// there is coded as none.
fn getEdgeFifo8(fifo: *const EdgeFifo8, a: u32, b: u32, c: u32, offset: usize) ?u32 {
    for (0..6) |i| {
        const index = (offset -% 1 -% i) & 7;

        const e0 = fifo[index][0];
        const e1 = fifo[index][1];

        const age: u32 = @intCast(i);
        if (e0 == a and e1 == b) return (age << 2) | 0;
        if (e0 == b and e1 == c) return (age << 2) | 1;
        if (e0 == c and e1 == a) return (age << 2) | 2;
    }

    return null;
}

fn pushEdgeFifo8(fifo: *EdgeFifo8, a: u32, b: u32, offset: *usize) void {
    fifo[offset.*] = .{ a, b };
    offset.* = (offset.* + 1) & 7;
}

/// Writes a 4-bit code per triangle to `codes` and the vertices the codes
/// do not give to `extra`, and returns the number of extra bytes.
fn encodeTriangles(codes: []u8, extra: []u8, triangles: []const u8) usize {
    const triangle_count = triangles.len / 3;

    var edge_fifo: EdgeFifo8 = @splat(.{ none, none });
    var edge_fifo_offset: usize = 0;

    var next: u32 = 0;

    // The 16 codes: an edge of one of the last three triangles (2 edges
    // each, as the triangles are rotated) with the third vertex next or
    // explicit, 12 codes; and a restart, with 0 to 3 explicit vertices
    // before the rest are next (000, 001, 011, 111), 4 codes. Triangles are
    // rotated so the next vertices line up.
    @memset(codes[0 .. (triangle_count + 1) / 2], 0);

    var written: usize = 0;

    for (0..triangle_count) |i| {
        const triangle = triangles[i * 3 ..][0..3];
        const fer = getEdgeFifo8(
            &edge_fifo,
            triangle[0],
            triangle[1],
            triangle[2],
            edge_fifo_offset,
        );

        const shift: u5 = @intCast((i & 1) * 4);

        if (fer) |found| {
            // getEdgeFifo8 rotates the triangle implicitly, matching a and
            // b to the edge it found.
            const order = rotations[found & 3 ..][0..3];

            const a = triangle[order[0]];
            const b = triangle[order[1]];
            const c = triangle[order[2]];

            var fec: u32 = 1;
            if (c == next) {
                next += 1;
                fec = 0;
            }

            const code = (found >> 2) * 2 + fec;

            codes[i / 2] |= @truncate(code << shift);

            if (fec != 0) {
                extra[written] = c;
                written += 1;
            }

            pushEdgeFifo8(&edge_fifo, c, b, &edge_fifo_offset);
            pushEdgeFifo8(&edge_fifo, a, c, &edge_fifo_offset);
        } else {
            // Rotated so fewer vertices are explicit.
            const rotation = rotateTriangle(triangle[0], triangle[1], triangle[2]);
            const order = rotations[rotation..][0..3];

            const a = triangle[order[0]];
            const b = triangle[order[1]];
            const c = triangle[order[2]];

            // Once a vertex is next, the ones after it are next too.
            var fea: u32 = 1;
            if (a == next and b == next + 1 and c == next + 2) {
                next += 1;
                fea = 0;
            }
            var feb: u32 = 1;
            if (b == next and c == next + 1) {
                next += 1;
                feb = 0;
            }
            var fec: u32 = 1;
            if (c == next) {
                next += 1;
                fec = 0;
            }

            const code = 12 + (fea + feb + fec);

            codes[i / 2] |= @truncate(code << shift);

            if (fea != 0) {
                extra[written] = a;
                written += 1;
            }
            if (feb != 0) {
                extra[written] = b;
                written += 1;
            }
            if (fec != 0) {
                extra[written] = c;
                written += 1;
            }

            pushEdgeFifo8(&edge_fifo, c, b, &edge_fifo_offset);
            pushEdgeFifo8(&edge_fifo, a, c, &edge_fifo_offset);
        }
    }

    return written;
}

/// Writes 2 bits of control per vertex to `ctrl` and the differences to
/// `data`, and returns the number of data bytes.
fn encodeVertices(ctrl: []u8, data: []u8, vertices: []const u32) usize {
    // Grouped varint: 2 bits per value give 0 to 3 bytes for its
    // difference, and a group of four can fall back to 4 bytes each.
    @memset(ctrl[0 .. (vertices.len + 3) / 4], 0);

    var written: usize = 0;

    var last: u32 = none;

    var i: usize = 0;
    while (i < vertices.len) : (i += 4) {
        var gv: [4]u32 = @splat(0);

        inline for (&gv, 0..) |*g, k| {
            if (i + k < vertices.len) {
                g.* = zigzag(vertices[i + k] -% last -% 1);
                last = vertices[i + k];
            }
        }

        // 4 bytes for all four if any needs 4, or if all four need 3: most
        // 3-byte differences stay 3 bytes, which is smaller overall.
        const use4 = (gv[0] | gv[1] | gv[2] | gv[3]) > 0xffffff or
            (gv[0] > 0xffff and gv[1] > 0xffff and gv[2] > 0xffff and gv[3] > 0xffff);

        inline for (gv, 0..) |v, k| {
            // 0 to 3 bytes for each value, or 4 for all four.
            const code: u32 = if (use4)
                3
            else if (v == 0)
                0
            else if (v < 256)
                1
            else if (v < 65536)
                2
            else
                3;

            const length: usize = if (use4) 4 else code;
            data[written..][0..4].* = @bitCast(std.mem.nativeToLittle(u32, v));
            written += length;

            // The low and high bits go to separate nibbles, which pack
            // better.
            ctrl[i / 4] |= @truncate(((code & 1) << k) | ((code >> 1) << (k + 4)));
        }
    }

    return written;
}

fn zigzag(d: u32) u32 {
    const sign: u32 = @bitCast(@as(i32, @bitCast(d)) >> 31);
    return (d << 1) ^ sign;
}

fn unzigzag(v: u32) u32 {
    return (v >> 1) ^ (0 -% (v & 1));
}

// --------------------------------------------------------
// The scalar decoder
// --------------------------------------------------------

/// The next vertex, or the next extra byte if `from_extra` is 1, read
/// either way so the choice stays branchless.
inline fn nextOrExtra(buffer: []const u8, extra: *usize, next: *u32, from_extra: u32) u32 {
    const e = buffer[extra.*];
    const v = if (from_extra != 0) e else next.*;
    extra.* += from_extra;
    next.* +%= 1 - from_extra;
    return v;
}

/// Writes a triangle kept as 0xcbac, its first edge's vertices with c
/// below them, without the c below.
fn writeTriangle(comptime T: type, triangles: []T, i: usize, fifo: u32) void {
    if (T == u32) {
        triangles[i] = fifo >> 8;
    } else {
        triangles[i * 3 ..][0..3].* = .{
            @truncate(fifo >> 8),
            @truncate(fifo >> 16),
            @truncate(fifo >> 24),
        };
    }
}

/// Decodes `triangle_count` triangles from the codes and the extra bytes
/// at `start`, and returns where the extra bytes end, or null if they run
/// past `bound`.
fn decodeTriangles(
    comptime T: type,
    triangles: []T,
    triangle_count: usize,
    codes: []const u8,
    buffer: []const u8,
    start: usize,
    bound: usize,
) ?usize {
    var extra = start;
    var next: u32 = 0;
    // The last three triangles, each with both its edges in one word:
    // 0xcbac.
    var fifo: [3]u32 = @splat(0);

    for (0..triangle_count) |i| {
        if (extra > bound) return null;

        const shift: u3 = @intCast((i & 1) * 4);
        const code: u32 = (codes[i / 2] >> shift) & 0xf;
        var tri: u32 = undefined;

        if (code < 12) {
            // An edge again: shift by 16 for the second edge of a triangle.
            var edge = fifo[code / 4];
            edge >>= @intCast((code << 3) & 16);

            // 0 or 1 extra vertices.
            const c = nextOrExtra(buffer, &extra, &next, code & 1);

            // Repacked as 0xcbac.
            tri = ((edge & 0xff) << 16) | (edge & 0xff00) | c | (c << 24);
        } else {
            // A restart: 0 to 3 extra vertices.
            const a = nextOrExtra(buffer, &extra, &next, @intFromBool(code > 12));
            const b = nextOrExtra(buffer, &extra, &next, @intFromBool(code > 13));
            const c = nextOrExtra(buffer, &extra, &next, @intFromBool(code > 14));

            // Repacked as 0xcbac.
            tri = c | (a << 8) | (b << 16) | (c << 24);
        }

        writeTriangle(T, triangles, i, tri);

        fifo[2] = fifo[1];
        fifo[1] = fifo[0];
        fifo[0] = tri;
    }

    return extra;
}

/// Decodes `vertex_count` vertex references from `ctrl` and the data at
/// `start`, and returns where the data ends, or null if it runs past
/// `bound`.
fn decodeVertices(
    comptime V: type,
    vertices: []V,
    vertex_count: usize,
    ctrl: []const u8,
    buffer: []const u8,
    start: usize,
    bound: usize,
) ?usize {
    var data = start;
    var last: u32 = none;

    var i: usize = 0;
    while (i < vertex_count) : (i += 4) {
        if (data > bound) return null;

        const code4 = ctrl[i / 4];

        inline for (0..4) |k| {
            const code: u32 = ((code4 >> k) & 1) | ((code4 >> (k + 3)) & 2);
            const length: u32 = if (code4 == 0xff) 4 else code;

            // Up to 4 bytes, read without branches.
            const mask: u32 = if (length == 4) none else (@as(u32, 1) << @intCast(8 * length)) - 1;
            const v = std.mem.readInt(u32, buffer[data..][0..4], .little) & mask;

            // Unzigzag, plus 1.
            const r = last +% unzigzag(v) +% 1;

            if (i + k < vertex_count) vertices[i + k] = @truncate(r);

            data += length;
            last = r;
        }
    }

    return data;
}

fn decodeScalar(
    comptime V: type,
    comptime T: type,
    vertices: []V,
    vertex_count: usize,
    triangles: []T,
    triangle_count: usize,
    buffer: []const u8,
    layout: Layout,
) DecodeError!void {
    const ctrl = buffer[layout.ctrl..layout.codes];
    const codes = buffer[layout.codes..];

    var data = decodeVertices(V, vertices, vertex_count, ctrl, buffer, 0, layout.bound) orelse
        return error.Truncated;
    data = decodeTriangles(T, triangles, triangle_count, codes, buffer, data, layout.bound) orelse
        return error.Truncated;

    if (data != layout.bound) return error.SizeMismatch;
}

// --------------------------------------------------------
// The SIMD decoder
// --------------------------------------------------------

// The triangle decoder's state is one 16-byte register:
//   0..5: the next 6 extra bytes;
//   6..14: 9 bytes, the vertices of the last three triangles;
//   15: next.
// Decoding a pair of triangles turns it into the state that holds them,
// which is a byte permutation of the old state plus a per-byte addition.
// The second triangle's permutation chains onto the first's, so one table
// entry for each of the 256 pairs of 4-bit codes decodes a pair with one
// shuffle and one add, plus refilling the extra bytes.

const Bytes = @Vector(16, u8);
const Words = @Vector(4, u32);

/// SIMD decoding where the original has it: x86 with SSE4.1 and
/// little-endian AArch64 (NEON).
const simd_available = builtin.cpu.arch.endian() == .little and
    (builtin.cpu.has(.x86, .sse4_1) or builtin.cpu.has(.aarch64, .neon));

const Path = enum { scalar, simd };

const default_path: Path = if (simd_available) .simd else .scalar;

const TriangleTables = struct {
    /// Bytes 0..5 are the additions to state bytes 10..15; bytes 6..15
    /// are the shuffle for state bytes 6..15. Shuffle bytes 0..5 are never
    /// used, as the extra bytes are refilled each time.
    masks: [256][16]u8,
    /// The extra bytes each pair of codes takes.
    extra: [256]u8,
};

const triangle_tables: TriangleTables = buildTriangleTables();

fn buildTriangleTables() TriangleTables {
    @setEvalBranchQuota(100_000);
    var tables: TriangleTables = undefined;

    for (0..256) |code| {
        var shuf: [16]u8 = @splat(0);
        var next: [16]u8 = @splat(0);
        var extra: u8 = 0;
        var next_offset: u8 = 0;

        const Next = struct {
            /// The vertex at `at` is the next extra byte or next.
            fn take(s: *[16]u8, n: *[16]u8, e: *u8, no: *u8, at: usize, from_extra: bool) void {
                s[at] = if (from_extra) e.* else 15;
                n[at] = if (from_extra) 0 else no.*;
                if (from_extra) e.* += 1 else no.* += 1;
            }
        };

        // Bytes 6..8 always end up holding the last triangle the old state
        // held, as every triangle moves the fifo on by one.
        shuf[6] = 12;
        shuf[7] = 13;
        shuf[8] = 14;

        // Byte 15 holds next, counted up.
        shuf[15] = 15;

        // Bytes 9..11 get the first triangle, from extra, next or the old
        // triangles; bytes 12..14 the second, whose edge, if it reuses the
        // first triangle's, comes from the bytes just decoded.
        for (0..2) |k| {
            const tri = (code >> @intCast(k * 4)) & 0xf;

            if (tri < 12) {
                if (k == 1 and tri / 4 == 0) {
                    // An edge of the triangle decoded just before: copy
                    // its two vertices' shuffle and addition.
                    const first: usize = 9 + @as(usize, if (tri & 2 != 0) 2 else 0);
                    const second: usize = 9 + @as(usize, if (tri & 2 != 0) 1 else 2);
                    shuf[9 + k * 3] = shuf[first];
                    next[9 + k * 3] = next[first];

                    shuf[10 + k * 3] = shuf[second];
                    next[10 + k * 3] = next[second];
                } else {
                    // An edge from the old triangles, one further back as
                    // the first triangle took the newest place.
                    const trioff = 6 + k * 3 + (2 - tri / 4) * 3;

                    // Edge cb or ac.
                    shuf[9 + k * 3] = @intCast(trioff + @as(usize, if (tri & 2 != 0) 2 else 0));
                    shuf[10 + k * 3] = @intCast(trioff + @as(usize, if (tri & 2 != 0) 1 else 2));
                }

                // The third vertex is next or extra.
                Next.take(&shuf, &next, &extra, &next_offset, 11 + k * 3, tri & 1 != 0);
            } else {
                // A restart: each vertex is next or extra.
                Next.take(&shuf, &next, &extra, &next_offset, 9 + k * 3, tri > 12);
                Next.take(&shuf, &next, &extra, &next_offset, 10 + k * 3, tri > 13);
                Next.take(&shuf, &next, &extra, &next_offset, 11 + k * 3, tri > 14);
            }
        }

        // next moves on.
        next[15] = next_offset;

        // Additions 0..8 are never written, and 9 is 0 as next_offset
        // starts at 0, so additions 10..15 and shuffle 6..15 fill one
        // entry.
        assert(next[9] == 0);
        tables.masks[code][0..6].* = next[10..16].*;
        tables.masks[code][6..16].* = shuf[6..16].*;
        tables.extra[code] = extra;
    }

    return tables;
}

const VertexTables = struct {
    /// Gathers four values of 0 to 4 bytes each into four words; 0x80
    /// gives a zero byte.
    shuffles: [256][16]u8,
    /// The data bytes each control byte takes.
    lengths: [256]u8,
};

const vertex_tables: VertexTables = buildVertexTables();

fn buildVertexTables() VertexTables {
    @setEvalBranchQuota(100_000);
    var tables: VertexTables = undefined;

    for (0..256) |i| {
        var shuf: [16]u8 = @splat(0);
        var offset: u8 = 0;

        for (0..4) |k| {
            const code = ((i >> @intCast(k)) & 1) | ((i >> @intCast(k + 3)) & 2);
            // 0 to 3 bytes, or 4 for all four if the control byte is 0xff.
            const length: u8 = if (i == 0xff) 4 else @intCast(code);

            for (0..4) |j| {
                shuf[k * 4 + j] = if (length > j) offset + @as(u8, @intCast(j)) else 0x80;
            }

            offset += length;
        }

        tables.shuffles[i] = shuf;
        tables.lengths[i] = offset;
    }

    return tables;
}

/// Byte `indices[i]` of `table`, or 0 where `indices[i]` has its top bit
/// set; every index below is under 16 or 0x80, where SSSE3's `pshufb` and
/// NEON's `tbl` agree.
inline fn shuffleBytes(table: Bytes, indices: Bytes) Bytes {
    if (comptime builtin.cpu.has(.x86, .avx)) {
        return asm ("vpshufb %[indices], %[table], %[out]"
            : [out] "=x" (-> Bytes),
            : [table] "x" (table),
              [indices] "x" (indices),
        );
    }
    if (comptime builtin.cpu.has(.x86, .ssse3)) {
        return asm ("pshufb %[indices], %[out]"
            : [out] "=x" (-> Bytes),
            : [table] "0" (table),
              [indices] "x" (indices),
        );
    }
    if (comptime builtin.cpu.has(.aarch64, .neon)) {
        return asm ("tbl %[out].16b, { %[table].16b }, %[indices].16b"
            : [out] "=w" (-> Bytes),
            : [table] "w" (table),
              [indices] "w" (indices),
        );
    }
    @compileError("no byte shuffle on this target");
}

const zero_bytes: Bytes = @splat(0);
const zero_words: Words = @splat(0);

/// The first 6 bytes, the extra bytes, from the second vector.
const extra_lanes: @Vector(16, bool) = .{
    true,  true,  true,  true,  true,  true,  false, false,
    false, false, false, false, false, false, false, false,
};

inline fn decodeTriangleGroup(state: Bytes, code: u8, buffer: []const u8, extra: *usize) Bytes {
    const shuf: Bytes = triangle_tables.masks[code];
    // The additions, moved up to bytes 10..15.
    const next = @shuffle(u8, shuf, zero_bytes, [16]i32{
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4, 5,
    });

    // Refill the first 6 bytes with the next extra bytes, and move the
    // state on.
    const word = std.mem.readInt(u64, buffer[extra.*..][0..8], .little);
    const ext: Bytes = @bitCast(@Vector(2, u64){ word, 0 });
    const refilled = @select(u8, extra_lanes, ext, state);
    const result = shuffleBytes(refilled, shuf) +% next;

    extra.* += triangle_tables.extra[code];

    return result;
}

inline fn decodeVertexGroup(last: Words, code: u8, buffer: []const u8, data: *usize) Words {
    const word: Bytes = buffer[data.*..][0..16].*;
    const shuf: Bytes = vertex_tables.shuffles[code];

    const v: Words = @bitCast(shuffleBytes(word, shuf));

    // Unzigzag, plus 1.
    const one: Words = @splat(1);
    const xl = zero_words -% (v & one);
    const xr = v >> @as(@Vector(4, u5), @splat(1));
    var x = (xl ^ xr) +% one;

    // The prefix sum, from the last group's last value.
    x +%= @shuffle(u32, x, zero_words, [4]i32{ -1, -1, 0, 1 });
    x +%= @shuffle(u32, x, zero_words, [4]i32{ -1, 0, 1, 2 });
    x +%= @as(Words, @splat(last[3]));

    data.* += vertex_tables.lengths[code];

    return x;
}

/// Decodes `triangle_count` triangles, a pair at a time, as 32-bit words.
/// An odd count writes an even number of words, the last pair's second
/// one; the caller has room for it as for the original's 4-byte rounding,
/// since a word is 4 bytes.
fn decodeTrianglesSimdWords(
    triangles: []u32,
    triangle_count: usize,
    codes: []const u8,
    buffer: []const u8,
    start: usize,
    bound: usize,
) ?usize {
    // The new triangles' bytes as two words, each with a zero top byte.
    const repack = [8]i32{ 9, 10, 11, -1, 12, 13, 14, -1 };

    var state: Bytes = @splat(0);
    var extra = start;

    const groups = triangle_count / 2;

    for (0..groups) |i| {
        const code = codes[i];

        if (extra > bound) return null;

        state = decodeTriangleGroup(state, code, buffer, &extra);

        const r: @Vector(8, u8) = @shuffle(u8, state, zero_bytes, repack);
        triangles[i * 2 ..][0..2].* = @bitCast(r);
    }

    // A last single triangle writes one word, to stay within the output.
    if (triangle_count & 1 != 0) {
        const code = codes[groups];

        if (extra > bound) return null;

        state = decodeTriangleGroup(state, code, buffer, &extra);

        const r: @Vector(8, u8) = @shuffle(u8, state, zero_bytes, repack);
        const pair: [2]u32 = @bitCast(r);
        triangles[triangle_count & ~@as(usize, 1)] = pair[0];
    }

    return extra;
}

/// Decodes `triangle_count` triangles as 3 bytes each. The output has room
/// for a multiple of 4 bytes, so two pairs go at a time as 12 bytes, and a
/// count of 3 modulo 4 decodes its last group whole, writing up to 3 bytes
/// past the triangles.
fn decodeTrianglesSimdBytes(
    triangles: []u8,
    triangle_count: usize,
    codes: []const u8,
    buffer: []const u8,
    start: usize,
    bound: usize,
) ?usize {
    var state: Bytes = @splat(0);
    var extra = start;

    const groups = (triangle_count + 1) / 4;

    for (0..groups) |i| {
        const code0 = codes[i * 2];
        const code1 = codes[i * 2 + 1];

        // A pair reads at most 6 extra bytes, so two read at most 12, and
        // the gap leaves 16 to read past the bound.
        if (extra > bound) return null;

        state = decodeTriangleGroup(state, code0, buffer, &extra);

        // The first triangle and the first vertex of the second.
        const r0: [4]u8 = @shuffle(u8, state, undefined, [4]i32{ 9, 10, 11, 12 });
        triangles[i * 12 ..][0..4].* = r0;

        state = decodeTriangleGroup(state, code1, buffer, &extra);

        // The second triangle's other two vertices, now at bytes 7 and 8
        // after the shift, and the two new triangles.
        const r1: [8]u8 = @shuffle(u8, state, undefined, [8]i32{ 7, 8, 9, 10, 11, 12, 13, 14 });
        triangles[i * 12 + 4 ..][0..8].* = r1;
    }

    // A last one or two triangles write one or two words, to stay within
    // the output.
    if (groups * 4 < triangle_count) {
        const code = codes[groups * 2];

        if (extra > bound) return null;

        state = decodeTriangleGroup(state, code, buffer, &extra);

        const tail = triangles[(triangle_count & ~@as(usize, 3)) * 3 ..];
        const r: [8]u8 = @shuffle(u8, state, zero_bytes, [8]i32{
            9, 10, 11, 12, 13, 14, 15, -1,
        });

        tail[0..4].* = r[0..4].*;
        if (triangle_count & 3 > 1) tail[4..8].* = r[4..8].*;
    }

    return extra;
}

/// Decodes `vertex_count` vertex references, four at a time, as 32-bit
/// values.
fn decodeVerticesSimdWords(
    vertices: []u32,
    vertex_count: usize,
    ctrl: []const u8,
    buffer: []const u8,
    start: usize,
    bound: usize,
) ?usize {
    var last: Words = @splat(none);
    var data = start;

    const groups = vertex_count / 4;

    for (0..groups) |i| {
        const code = ctrl[i];
        if (data > bound) return null;

        last = decodeVertexGroup(last, code, buffer, &data);

        vertices[i * 4 ..][0..4].* = last;
    }

    // A last one to three vertices, written one by one to stay within the
    // output.
    if (vertex_count & 3 != 0) {
        const code = ctrl[groups];

        if (data > bound) return null;

        last = decodeVertexGroup(last, code, buffer, &data);

        const tail = vertices[vertex_count & ~@as(usize, 3) ..];

        tail[0] = last[0];
        if (vertex_count & 3 > 1) tail[1] = last[1];
        if (vertex_count & 3 > 2) tail[2] = last[2];
    }

    return data;
}

/// Decodes `vertex_count` vertex references as 16-bit values. The output
/// has room for a multiple of 4 bytes, so a count of 3 modulo 4 decodes
/// its last group whole, writing one value past the references.
fn decodeVerticesSimdHalves(
    vertices: []u16,
    vertex_count: usize,
    ctrl: []const u8,
    buffer: []const u8,
    start: usize,
    bound: usize,
) ?usize {
    var last: Words = @splat(none);
    var data = start;

    const groups = (vertex_count + 1) / 4;

    for (0..groups) |i| {
        const code = ctrl[i];

        if (data > bound) return null;

        last = decodeVertexGroup(last, code, buffer, &data);

        vertices[i * 4 ..][0..4].* = @as(@Vector(4, u16), @truncate(last));
    }

    // A last one or two vertices write one 4-byte pair, to stay within the
    // output.
    if (groups * 4 < vertex_count) {
        const code = ctrl[groups];

        if (data > bound) return null;

        last = decodeVertexGroup(last, code, buffer, &data);

        const tail = vertices[vertex_count & ~@as(usize, 3) ..];
        tail[0..2].* = .{ @truncate(last[0]), @truncate(last[1]) };
    }

    return data;
}

fn decodeSimd(
    comptime raw: bool,
    comptime V: type,
    comptime T: type,
    vertices: []V,
    vertex_count: usize,
    triangles: []T,
    triangle_count: usize,
    buffer: []const u8,
    layout: Layout,
) DecodeError!void {
    const ctrl = buffer[layout.ctrl..layout.codes];
    const codes = buffer[layout.codes..];

    // Four vertices at a time, with a tail; raw decoding rounds the count up
    // instead, as its output has room and the tail's control bits are 0.
    const data = if (V == u32) decodeVerticesSimdWords(
        vertices,
        if (raw) (vertex_count + 3) & ~@as(usize, 3) else vertex_count,
        ctrl,
        buffer,
        0,
        layout.bound,
    ) else decodeVerticesSimdHalves(vertices, vertex_count, ctrl, buffer, 0, layout.bound);

    const start = data orelse return error.Truncated;

    // Two or four triangles at a time, with a tail; raw decoding rounds the
    // count up instead, as its output has room and the tail's code is 0.
    const end = if (T == u32) decodeTrianglesSimdWords(
        triangles,
        if (raw) (triangle_count + 1) & ~@as(usize, 1) else triangle_count,
        codes,
        buffer,
        start,
        layout.bound,
    ) else decodeTrianglesSimdBytes(triangles, triangle_count, codes, buffer, start, layout.bound);

    if ((end orelse return error.Truncated) != layout.bound) return error.SizeMismatch;
}

// --------------------------------------------------------
// The interface
// --------------------------------------------------------

/// Where the parts of an encoded meshlet begin: the variable-size data
/// first, from 0 to `bound`, then a gap that gives the SIMD decoder 16
/// bytes to read past `bound`, then the vertex control bytes at `ctrl`, and
/// the triangle codes at `codes`, up to the end.
const Layout = struct {
    ctrl: usize,
    codes: usize,
    bound: usize,
};

fn layoutOf(buffer_size: usize, vertex_count: usize, triangle_count: usize) DecodeError!Layout {
    const codes_size = (triangle_count + 1) / 2;
    const ctrl_size = (vertex_count + 3) / 4;
    const gap_size = gapSize(codes_size, ctrl_size);

    if (buffer_size < codes_size + ctrl_size + gap_size) return error.Truncated;

    const codes = buffer_size - codes_size;
    const ctrl = codes - ctrl_size;
    return .{ .ctrl = ctrl, .codes = codes, .bound = ctrl - gap_size };
}

/// The zero bytes between the variable-size data and the fixed-size tail,
/// so the tail and the gap hold at least 16.
fn gapSize(codes_size: usize, ctrl_size: usize) usize {
    return if (codes_size + ctrl_size < 16) 16 - (codes_size + ctrl_size) else 0;
}

/// The most bytes `encodeMeshlet` writes for a meshlet of up to
/// `vertices_max` vertices and `triangles_max` triangles.
pub fn encodeMeshletBound(vertices_max: usize, triangles_max: usize) usize {
    const codes_size = (triangles_max + 1) / 2;
    const extra_size = triangles_max * 3;

    const ctrl_size = (vertices_max + 3) / 4;
    // The worst case: 16 bytes per group of four vertices.
    const data_size = (vertices_max + 3) / 4 * 16;

    const gap_size = gapSize(codes_size, ctrl_size);

    return codes_size + extra_size + ctrl_size + data_size + gap_size;
}

/// Encodes one meshlet, its vertex references `vertices` and its triangles
/// `triangles` (three local indices each), into `buffer` and returns the
/// encoded size. `vertices` may be empty, to encode the triangles only.
/// Each holds at most 256 items. Store the counts and the size yourself
/// when you encode several meshlets. For the smallest result, optimize the
/// meshlet with `optimizeMeshletLevel` at level 1 or more (3 is best) and
/// order the vertex references for locality. `buffer` needs at most
/// `encodeMeshletBound` bytes; with fewer, the encoding may not fit.
pub fn encodeMeshlet(
    buffer: []u8,
    vertices: []const u32,
    triangles: []const u8,
) error{NoSpaceLeft}!usize {
    assert(triangles.len % 3 == 0);
    const triangle_count = triangles.len / 3;
    assert(triangle_count <= meshlet_triangles_max and vertices.len <= meshlet_vertices_max);

    // 4 bits per triangle, and up to three extra bytes.
    var codes: [meshlet_triangles_max / 2]u8 = undefined;
    var extra: [meshlet_triangles_max * 3]u8 = undefined;
    const codes_size = (triangle_count + 1) / 2;
    const extra_size = encodeTriangles(&codes, &extra, triangles);

    // 2 bits per vertex, and up to 4 bytes of data. The data gets 3 bytes
    // more, as each value is written as a whole word.
    var ctrl: [meshlet_vertices_max / 4]u8 = undefined;
    var data: [meshlet_vertices_max * 4 + 3]u8 = undefined;
    const ctrl_size = (vertices.len + 3) / 4;
    const data_size = encodeVertices(&ctrl, &data, vertices);

    // The SIMD decoder reads up to 16 bytes past the variable-size data,
    // so the fixed-size tail goes last, with a gap before it if it is
    // shorter.
    const gap_size = gapSize(codes_size, ctrl_size);

    const result = codes_size + extra_size + ctrl_size + data_size + gap_size;

    if (result > buffer.len) return error.NoSpaceLeft;

    // The variable-size data first.
    var out = buffer;
    @memcpy(out[0..data_size], data[0..data_size]);
    out = out[data_size..];
    @memcpy(out[0..extra_size], extra[0..extra_size]);
    out = out[extra_size..];

    // The gap.
    @memset(out[0..gap_size], 0);
    out = out[gap_size..];

    // The fixed-size data last, found from the end when decoding.
    @memcpy(out[0..ctrl_size], ctrl[0..ctrl_size]);
    out = out[ctrl_size..];
    @memcpy(out[0..codes_size], codes[0..codes_size]);

    return result;
}

fn checkDecodeTypes(comptime V: type, comptime T: type) void {
    if (V != u16 and V != u32) {
        @compileError("vertex references decode to u16 or u32, not " ++ @typeName(V));
    }
    if (T != u8 and T != u32) {
        @compileError("triangles decode to u8 (3 per triangle) or u32, not " ++ @typeName(T));
    }
}

/// The elements of `T` that `count` items of `size` bytes, rounded up to
/// 4 bytes, take.
fn paddedLen(comptime T: type, count: usize, size: usize) usize {
    return std.mem.alignForward(usize, count * size, 4) / @sizeOf(T);
}

/// Decodes the meshlet `encodeMeshlet` wrote into `buffer` (all of it, and
/// nothing more), with the vertex and triangle counts it was encoded with.
///
/// Vertex references decode as `V`, `u16` or `u32`. Triangles decode as
/// `T`: `u8` gives three bytes per triangle, `u32` one packed word, `a |
/// b << 8 | c << 16`. Both outputs are written in 4-byte steps, so they
/// need room for their size rounded up to 4 bytes, and the bytes past the
/// counts are left undefined. `vertices` may be empty when the meshlet has
/// triangles only. On an error, the outputs hold what was decoded before
/// it.
pub fn decodeMeshlet(
    comptime V: type,
    comptime T: type,
    vertices: []V,
    vertex_count: usize,
    triangles: []T,
    triangle_count: usize,
    buffer: []const u8,
) DecodeError!void {
    const path = default_path;
    return decodeWith(path, V, T, vertices, vertex_count, triangles, triangle_count, buffer);
}

/// `decodeMeshlet` into 32-bit vertex references and packed triangles,
/// with outputs that have room for their counts rounded up to 4, so the
/// SIMD decoder skips its tails.
pub fn decodeMeshletRaw(
    vertices: []u32,
    vertex_count: usize,
    triangles: []u32,
    triangle_count: usize,
    buffer: []const u8,
) DecodeError!void {
    return decodeRawWith(default_path, vertices, vertex_count, triangles, triangle_count, buffer);
}

fn decodeWith(
    comptime path: Path,
    comptime V: type,
    comptime T: type,
    vertices: []V,
    vertex_count: usize,
    triangles: []T,
    triangle_count: usize,
    buffer: []const u8,
) DecodeError!void {
    comptime checkDecodeTypes(V, T);
    assert(triangle_count <= meshlet_triangles_max and vertex_count <= meshlet_vertices_max);
    assert(vertices.len >= paddedLen(V, vertex_count, @sizeOf(V)));
    assert(triangles.len >= paddedLen(T, triangle_count, if (T == u8) 3 else 4));

    const layout = try layoutOf(buffer.len, vertex_count, triangle_count);

    return switch (path) {
        .scalar => decodeScalar(
            V,
            T,
            vertices,
            vertex_count,
            triangles,
            triangle_count,
            buffer,
            layout,
        ),
        .simd => decodeSimd(
            false,
            V,
            T,
            vertices,
            vertex_count,
            triangles,
            triangle_count,
            buffer,
            layout,
        ),
    };
}

fn decodeRawWith(
    comptime path: Path,
    vertices: []u32,
    vertex_count: usize,
    triangles: []u32,
    triangle_count: usize,
    buffer: []const u8,
) DecodeError!void {
    assert(triangle_count <= meshlet_triangles_max and vertex_count <= meshlet_vertices_max);
    assert(vertices.len >= std.mem.alignForward(usize, vertex_count, 4));
    assert(triangles.len >= std.mem.alignForward(usize, triangle_count, 4));

    const layout = try layoutOf(buffer.len, vertex_count, triangle_count);

    return switch (path) {
        .scalar => decodeScalar(
            u32,
            u32,
            vertices,
            vertex_count,
            triangles,
            triangle_count,
            buffer,
            layout,
        ),
        .simd => decodeSimd(
            true,
            u32,
            u32,
            vertices,
            vertex_count,
            triangles,
            triangle_count,
            buffer,
            layout,
        ),
    };
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

/// Whether this target decodes with SIMD; the scalar decoder is
/// `decodeMeshletScalar`.
pub const has_simd = simd_available;

/// `decodeMeshlet` on the scalar path, for the oracle tests on targets that
/// decode with SIMD.
pub fn decodeMeshletScalar(
    comptime V: type,
    comptime T: type,
    vertices: []V,
    vertex_count: usize,
    triangles: []T,
    triangle_count: usize,
    buffer: []const u8,
) DecodeError!void {
    return decodeWith(.scalar, V, T, vertices, vertex_count, triangles, triangle_count, buffer);
}

/// `decodeMeshletRaw` on the scalar path, for the oracle tests.
pub fn decodeMeshletRawScalar(
    vertices: []u32,
    vertex_count: usize,
    triangles: []u32,
    triangle_count: usize,
    buffer: []const u8,
) DecodeError!void {
    return decodeRawWith(.scalar, vertices, vertex_count, triangles, triangle_count, buffer);
}

test "a meshlet round-trips on both paths" {
    const vertices = [_]u32{ 5, 6, 7, 100, 70000, 3, 0xffff_ffff };
    const triangles = [_]u8{ 0, 1, 2, 2, 1, 3, 3, 1, 4, 5, 6, 0, 6, 5, 4 };
    var buffer: [encodeMeshletBound(vertices.len, triangles.len / 3)]u8 = undefined;
    const size = try encodeMeshlet(&buffer, &vertices, &triangles);

    const paths = if (simd_available) [_]Path{ .scalar, .simd } else [_]Path{.scalar};
    inline for (paths) |path| {
        var rv: [8]u32 = undefined;
        var rt: [16]u8 = undefined;
        try decodeWith(path, u32, u8, &rv, vertices.len, &rt, 5, buffer[0..size]);
        try testing.expectEqualSlices(u32, &vertices, rv[0..vertices.len]);
        // Triangles may come back rotated, in the same winding.
        for (0..5) |t| {
            const want = canonical(triangles[t * 3 ..][0..3].*);
            try testing.expectEqual(want, canonical(rt[t * 3 ..][0..3].*));
        }
    }
}

/// The rotation of the triangle that sorts first.
fn canonical(triangle: [3]u8) [3]u8 {
    const a, const b, const c = triangle;
    var best = triangle;
    for ([_][3]u8{ .{ b, c, a }, .{ c, a, b } }) |rotated| {
        if (std.mem.order(u8, &rotated, &best) == .lt) best = rotated;
    }
    return best;
}
