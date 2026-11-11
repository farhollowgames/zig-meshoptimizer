//! Vertex buffer filters: unit vectors in octahedral form, quaternions with
//! their largest component dropped, floats as an exponent and a mantissa,
//! and colors in YCoCg, encoded so that the vertex codec compresses them
//! well and decoded in place after `decodeVertexBuffer`.
//!
//! Translated from meshoptimizer's vertexfilter.cpp. The decoders have the
//! original's scalar loops and its SIMD kernels for x86 (SSE2 and up) and
//! AArch64 (NEON), picked at compile time as the original picks them. Each
//! kernel rounds and estimates with the instructions the original's kernel
//! for its target uses, so it writes the bytes the original writes there.
//! The scalar loops and the kernels round differently, so on some inputs
//! they differ by one in the last bit, as the original's do.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const quantization = @import("quantization.zig");
const truncate = @import("convert.zig").truncate;

/// Which values share an exponent in `encodeFilterExp`.
pub const EncodeExpMode = enum {
    /// Each component has its own exponent: the best quality.
    separate,
    /// All components of a vector share one: better compression.
    shared_vector,
    /// Each component shares one across all vectors: the best compression.
    shared_component,
    /// Each component has its own, but never below 0: good quality where
    /// very small values do not matter.
    clamped,
};

// --------------------------------------------------------
// Decoders
// --------------------------------------------------------

/// Decodes octahedral unit vectors in place. Each `stride`-byte vector is
/// four signed integers of 8 bits (`stride` 4) or 16 bits (`stride` 8):
/// K-bit X and Y, Z holding 1.0 at the same bit count, and W. X, Y and Z
/// become the unit vector as signed normalized integers of the full width;
/// W is kept.
pub fn decodeFilterOct(buffer: []u8, stride: usize) void {
    decodeOct(path_default, buffer, stride);
}

/// Decodes quaternions in place from three K-bit components and the 2-bit
/// index of the fourth, the largest, which is rebuilt. Each quaternion is
/// four 16-bit integers, so `stride` is 8; the result is the unit
/// quaternion as 16-bit signed normalized integers.
pub fn decodeFilterQuat(buffer: []u8, stride: usize) void {
    decodeQuat(path_default, buffer, stride);
}

/// Decodes floats in place from an 8-bit exponent E and a 24-bit integer
/// mantissa M, as 2^E * M. Every 32-bit value decodes on its own, so
/// `stride` is any multiple of 4.
pub fn decodeFilterExp(buffer: []u8, stride: usize) void {
    decodeExp(path_default, buffer, stride);
}

/// Decodes RGBA colors in place from YCoCg with K-bit components and alpha
/// in K-1 bits. Each color is four unsigned normalized integers of 8 bits
/// (`stride` 4) or 16 bits (`stride` 8).
pub fn decodeFilterColor(buffer: []u8, stride: usize) void {
    decodeColor(path_default, buffer, stride);
}

/// How the decoders compute: the original's scalar loops, or its SIMD
/// kernels for x86 or for AArch64.
const Path = enum { scalar, x86, neon };

const llvm = builtin.zig_backend == .stage2_llvm;

/// The original's path for the target. Its NEON kernels for 32-bit ARM
/// refine estimates where AArch64 divides, and are not ported, so 32-bit
/// ARM decodes on the scalar path; the kernels read 16-bit components out
/// of 32-bit lanes, which needs a little-endian target; and Zig's own
/// backends run the x86 kernels only.
const path_default: Path = if (builtin.cpu.arch.endian() != .little)
    .scalar
else if (builtin.cpu.has(.x86, .sse2))
    .x86
else if (llvm and builtin.cpu.arch == .aarch64 and builtin.cpu.has(.aarch64, .neon))
    .neon
else
    .scalar;

/// The path of the decoders whose kernels use estimate instructions, the
/// 8-bit octahedral and color ones: Zig's own x86 backend cannot assemble
/// those, so there these two take the scalar path.
fn withEstimates(comptime path: Path) Path {
    return if (path == .x86 and !llvm) .scalar else path;
}

fn decodeOct(comptime path: Path, buffer: []u8, stride: usize) void {
    assert(stride == 4 or stride == 8);
    assert(buffer.len % stride == 0);

    if (stride == 4) {
        const narrow = comptime withEstimates(path);
        if (narrow == .scalar) {
            octScalar(i8, buffer);
        } else {
            const k = Kernels(narrow);
            decodeBlocks(k.lanes * 4, k.oct8, buffer);
        }
    } else {
        if (path == .scalar) {
            octScalar(i16, buffer);
        } else {
            const k = Kernels(path);
            decodeBlocks(k.lanes * 8, k.oct16, buffer);
        }
    }
}

fn decodeQuat(comptime path: Path, buffer: []u8, stride: usize) void {
    assert(stride == 8);
    assert(buffer.len % stride == 0);

    if (path == .scalar) {
        quatScalar(buffer);
    } else {
        const k = Kernels(path);
        decodeBlocks(k.lanes * 8, k.quat, buffer);
    }
}

fn decodeExp(comptime path: Path, buffer: []u8, stride: usize) void {
    assert(stride > 0 and stride % 4 == 0);
    assert(buffer.len % stride == 0);

    if (path == .scalar) {
        expScalar(buffer);
    } else {
        const k = Kernels(path);
        decodeBlocks(k.lanes * 4, k.exp, buffer);
    }
}

fn decodeColor(comptime path: Path, buffer: []u8, stride: usize) void {
    assert(stride == 4 or stride == 8);
    assert(buffer.len % stride == 0);

    if (stride == 4) {
        const narrow = comptime withEstimates(path);
        if (narrow == .scalar) {
            colorScalar(u8, buffer);
        } else {
            const k = Kernels(narrow);
            decodeBlocks(k.lanes * 4, k.color8, buffer);
        }
    } else {
        if (path == .scalar) {
            colorScalar(u16, buffer);
        } else {
            const k = Kernels(path);
            decodeBlocks(k.lanes * 8, k.color16, buffer);
        }
    }
}

/// Runs `kernel` on each whole block of `buffer`, then on the rest padded
/// with zeros. Every item of a block decodes on its own, so the padding
/// changes nothing that is kept.
fn decodeBlocks(
    comptime block_size: usize,
    comptime kernel: fn (*[block_size]u8) void,
    buffer: []u8,
) void {
    var pos: usize = 0;
    while (buffer.len - pos >= block_size) : (pos += block_size) {
        kernel(buffer[pos..][0..block_size]);
    }

    if (pos < buffer.len) {
        var tail: [block_size]u8 = @splat(0);
        const rest = buffer[pos..];
        @memcpy(tail[0..rest.len], rest);
        kernel(&tail);
        @memcpy(rest, tail[0..rest.len]);
    }
}

fn octScalar(comptime T: type, buffer: []u8) void {
    const max: f32 = @floatFromInt(std.math.maxInt(T));
    const data = std.mem.bytesAsSlice(T, buffer);

    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        const n = data[i..][0..4];

        // X and Y as floats, and Z rebuilt; this assumes Z encodes 1.0 at
        // the same bit count.
        var x: f32 = @floatFromInt(n[0]);
        var y: f32 = @floatFromInt(n[1]);
        const z = @as(f32, @floatFromInt(n[2])) - @abs(x) - @abs(y);

        // Octahedral coordinates fold back for z < 0.
        const t: f32 = if (z >= 0) 0 else z;

        x += if (x >= 0) t else -t;
        y += if (y >= 0) t else -t;

        const l = @sqrt(x * x + y * y + z * z);
        const s = max / l;

        n[0] = @truncate(truncate(x * s + roundingOffset(x)));
        n[1] = @truncate(truncate(y * s + roundingOffset(y)));
        n[2] = @truncate(truncate(z * s + roundingOffset(z)));
    }
}

/// The C `(v >= 0 ? 0.5f : -0.5f)` that rounds a float half away from
/// zero before truncation.
fn roundingOffset(v: f32) f32 {
    return if (v >= 0) 0.5 else -0.5;
}

/// 32767 / sqrt(2) in single precision, as the original computes it.
const quat_scale: f32 = 32767.0 / @sqrt(@as(f32, 2));

fn quatScalar(buffer: []u8) void {
    const data = std.mem.bytesAsSlice(i16, buffer);

    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        const q = data[i..][0..4];

        // The scale is the fourth word with its low 2 bits set.
        const sf: i32 = @as(i32, q[3]) | 3;
        const s: f32 = @floatFromInt(sf);

        // X, Y and Z unscaled: their scale is 1/sqrt(2) * 1/sf.
        const x: f32 = @floatFromInt(q[0]);
        const y: f32 = @floatFromInt(q[1]);
        const z: f32 = @floatFromInt(q[2]);

        // W as an unscaled square root, clamped to 0 against rounding.
        const ws = s * s;
        const ww = ws * 2 - x * x - y * y - z * z;
        const w = @sqrt(if (ww >= 0) ww else 0);

        // Out of fixed point (1/sf), renormalized (1/sqrt(2)) and scaled to
        // the 16-bit range (32767) at once.
        const ss = quat_scale / s;

        const xf = truncate(x * ss + roundingOffset(x));
        const yf = truncate(y * ss + roundingOffset(y));
        const zf = truncate(z * ss + roundingOffset(z));
        const wf = truncate(w * ss + 0.5);

        // The index of the rebuilt component sets the order.
        const qc: u2 = @truncate(@as(u16, @bitCast(q[3])));

        q[qc +% 1] = @truncate(xf);
        q[qc +% 2] = @truncate(yf);
        q[qc +% 3] = @truncate(zf);
        q[qc] = @truncate(wf);
    }
}

fn expScalar(buffer: []u8) void {
    for (std.mem.bytesAsSlice(u32, buffer)) |*d| {
        const v = d.*;

        const m = @as(i32, @bitCast(v << 8)) >> 8;
        const e = @as(i32, @bitCast(v)) >> 24;

        // ldexp(m, e), with 2^e built from its bits.
        const scale: f32 = @bitCast(@as(u32, @bitCast(e +% 127)) << 23);
        d.* = @bitCast(scale * @as(f32, @floatFromInt(m)));
    }
}

fn colorScalar(comptime T: type, buffer: []u8) void {
    const Signed = @Int(.signed, @bitSizeOf(T));
    const max: f32 = @floatFromInt(std.math.maxInt(T));
    const data = std.mem.bytesAsSlice(T, buffer);

    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        const c = data[i..][0..4];

        // The scale from alpha's high bit.
        var as: i32 = c[3];
        as |= as >> 1;
        as |= as >> 2;
        as |= as >> 4;
        as |= as >> 8;

        // RGB in fixed point, Co and Cg sign extended.
        const y: i32 = c[0];
        const co: i32 = @as(Signed, @bitCast(c[1]));
        const cg: i32 = @as(Signed, @bitCast(c[2]));

        const r = y + co - cg;
        const g = y + cg;
        const b = y - co - cg;

        // Alpha one bit wider, to match the other components.
        var a: i32 = c[3];
        a = ((a << 1) & as) | (a & 1);

        const ss = max / @as(f32, @floatFromInt(as));

        c[0] = @truncate(@as(u32, @bitCast(truncate(@as(f32, @floatFromInt(r)) * ss + 0.5))));
        c[1] = @truncate(@as(u32, @bitCast(truncate(@as(f32, @floatFromInt(g)) * ss + 0.5))));
        c[2] = @truncate(@as(u32, @bitCast(truncate(@as(f32, @floatFromInt(b)) * ss + 0.5))));
        c[3] = @truncate(@as(u32, @bitCast(truncate(@as(f32, @floatFromInt(a)) * ss + 0.5))));
    }
}

/// The original's SIMD kernels, each decoding `lanes` items at once, over
/// the instructions of one target (`X86` or `Neon`): the summing order of
/// a length, the estimate instructions, the rounding to integers and the
/// packing of color bytes, where the original's kernels differ.
fn Kernels(comptime path: Path) type {
    const isa = switch (path) {
        .scalar => unreachable,
        .x86 => X86,
        .neon => Neon,
    };
    return SimdKernels(isa);
}

fn SimdKernels(comptime isa: type) type {
    return struct {
        const lanes = isa.lanes;
        const F = @Vector(lanes, f32);
        const I = @Vector(lanes, i32);
        const U = @Vector(lanes, u32);
        const Words = @Vector(lanes * 2, u32);
        const Quads = @Vector(lanes, u64);

        /// The block's bytes as a vector, loaded in one go; a bit cast of
        /// the array would move them one by one.
        fn load(comptime V: type, block: *const [@sizeOf(V)]u8) V {
            const vector: *align(1) const V = @ptrCast(block);
            return vector.*;
        }

        fn store(comptime V: type, block: *[@sizeOf(V)]u8, v: V) void {
            const vector: *align(1) V = @ptrCast(block);
            vector.* = v;
        }

        /// Each lane's bits shifted up by `shl`, then down with their sign
        /// by `shr`: a signed bit field of the lane.
        fn signedField(v: U, comptime shl: u5, comptime shr: u5) I {
            const up: I = @bitCast(v << @splat(shl));
            return up >> @splat(shr);
        }

        fn toFloat(v: I) F {
            return @floatFromInt(v);
        }

        fn splatU(comptime v: u32) U {
            return @splat(v);
        }

        /// `t` with its sign flipped where `x` is negative.
        fn flipSign(t: F, x: F) F {
            const sign = @as(U, @bitCast(x)) & splatU(0x80000000);
            return @bitCast(@as(U, @bitCast(t)) ^ sign);
        }

        /// `z` where it is negative, and 0 elsewhere, as `minps` with 0
        /// computes it.
        fn negativePart(z: F) F {
            const zero: F = @splat(0);
            return @select(f32, z < zero, z, zero);
        }

        pub fn oct8(block: *[lanes * 4]u8) void {
            const n4 = load(U, block);

            // X and Y sign extended; Z is unsigned and need not be, but is
            // extracted the same way.
            const xf = signedField(n4, 24, 24);
            const yf = signedField(n4, 16, 24);
            const zf = signedField(n4, 8, 24);

            // X and Y as floats, and Z rebuilt; this assumes Z encodes 1.0
            // at the same bit count.
            const x0 = toFloat(xf);
            const y0 = toFloat(yf);
            const z = toFloat(zf) - (@abs(x0) + @abs(y0));

            // Octahedral coordinates fold back for z < 0.
            const t = negativePart(z);

            const x = x0 + flipSign(t, x0);
            const y = y0 + flipSign(t, y0);

            const ll = isa.lengthSquared(x, y, z);
            const s = @as(F, @splat(127)) * isa.rsqrtEstimate(ll);

            const xr: U = @bitCast(isa.scaleRound(x, s));
            const yr: U = @bitCast(isa.scaleRound(y, s));
            const zr: U = @bitCast(isa.scaleRound(z, s));

            // The low byte of each, and W as it was.
            var res = n4 & splatU(0xff000000);
            res |= xr & splatU(0xff);
            res |= (yr & splatU(0xff)) << @splat(8);
            res |= (zr & splatU(0xff)) << @splat(16);

            store(U, block, res);
        }

        pub fn oct16(block: *[lanes * 8]u8) void {
            const words = load(Words, block);

            // X and Y of each vector in one lane, Z and W in another.
            const xy, const zw = std.simd.deinterlace(2, words);

            const xf = signedField(xy, 16, 16);
            const yf = @as(I, @bitCast(xy)) >> @splat(16);
            // Z is unsigned, so masking extracts it.
            const zf: I = @bitCast(zw & splatU(0x7fff));

            const x0 = toFloat(xf);
            const y0 = toFloat(yf);
            const z = toFloat(zf) - (@abs(x0) + @abs(y0));

            const t = negativePart(z);

            const x = x0 + flipSign(t, x0);
            const y = y0 + flipSign(t, y0);

            const ll = isa.lengthSquared(x, y, z);
            const s = @as(F, @splat(32767)) / @sqrt(ll);

            const xr: U = @bitCast(isa.scaleRound(x, s));
            const yr: U = @bitCast(isa.scaleRound(y, s));
            const zr: U = @bitCast(isa.scaleRound(z, s));

            // The low 16 bits of each, and W as it was.
            const lo = (xr & splatU(0xffff)) | (yr << @splat(16));
            const hi = (zr & splatU(0xffff)) | (zw & splatU(0xffff0000));

            store(Words, block, std.simd.interlace(.{ lo, hi }));
        }

        pub fn quat(block: *[lanes * 8]u8) void {
            const words = load(Words, block);

            // X and Y of each quaternion in one lane, Z and the scale with
            // the index in another.
            const xy, const zc = std.simd.deinterlace(2, words);

            const xf = signedField(xy, 16, 16);
            const yf = @as(I, @bitCast(xy)) >> @splat(16);
            const zf = signedField(zc, 16, 16);
            const cf = @as(I, @bitCast(zc)) >> @splat(16);

            // The scale is the fourth word with its low 2 bits set, which
            // stand for 1.0.
            const sf = cf | @as(I, @splat(3));
            const s = toFloat(sf);

            // X, Y and Z unscaled: their scale is 1/sqrt(2) * 1/sf.
            const x = toFloat(xf);
            const y = toFloat(yf);
            const z = toFloat(zf);

            // W as an unscaled square root, clamped to 0 against rounding.
            // s * 2s is the original's x86 form; its NEON kernel adds s * s
            // to itself, which is the same number, as doubling is exact.
            const zero: F = @splat(0);
            const ws = s * (s + s);
            const ww = ws - isa.lengthSquared(x, y, z);
            const w = @sqrt(@select(f32, ww > zero, ww, zero));

            // Out of fixed point (1/sf), renormalized (1/sqrt(2)) and
            // scaled to the 16-bit range (32767) at once.
            const ss = @as(F, @splat(quat_scale)) / s;

            const xr = low16(isa.scaleRound(x, ss));
            const yr = low16(isa.scaleRound(y, ss));
            const zr = low16(isa.scaleRound(z, ss));
            const wr = low16(isa.scaleRound(w, ss));

            // W, X, Y, Z in order, which is right for index 0; each index
            // rotates the quaternion by one more component.
            const wxyz = wr | (xr << @splat(16)) | (yr << @splat(32)) | (zr << @splat(48));
            const Shift = @Vector(lanes, u6);
            const shift: Shift = @intCast((@as(U, @bitCast(cf)) & splatU(3)) << @splat(4));
            const back = @as(Shift, @splat(0)) -% shift;

            store(Quads, block, (wxyz << shift) | (wxyz >> back));
        }

        fn low16(v: I) Quads {
            return @intCast(@as(U, @bitCast(v)) & splatU(0xffff));
        }

        pub fn exp(block: *[lanes * 4]u8) void {
            const v = load(U, block);

            // The exponent as 2^e directly.
            const ef = @as(I, @bitCast(v)) >> @splat(24);
            const es = (@as(U, @bitCast(ef)) +% splatU(127)) << @splat(23);

            // The 24-bit mantissa as a float.
            const m = toFloat(signedField(v, 8, 8));

            const r = @as(F, @bitCast(es)) * m;

            store(F, block, r);
        }

        pub fn color8(block: *[lanes * 4]u8) void {
            const c4 = load(U, block);

            // Y, Co, Cg and A, Co and Cg sign extended.
            const yf: I = @bitCast(c4 & splatU(0xff));
            const cof = signedField(c4, 16, 24);
            const cgf = signedField(c4, 8, 24);
            var af = c4 >> @splat(24);

            // The scale from alpha's high bit.
            var as = af;
            as |= as >> @splat(1);
            as |= as >> @splat(2);
            as |= as >> @splat(4);

            // Alpha one bit wider, to match the other components.
            af = ((af << @splat(1)) & as) | (af & splatU(1));

            const ss = @as(F, @splat(255)) * isa.rcpEstimate(toFloat(@bitCast(as)));

            // RGB in fixed point.
            const rf = yf + (cof - cgf);
            const gf = yf + cgf;
            const bf = yf - (cof + cgf);

            const rr = isa.scaleRound(toFloat(rf), ss);
            const gr = isa.scaleRound(toFloat(gf), ss);
            const br = isa.scaleRound(toFloat(bf), ss);
            const ar = isa.scaleRound(toFloat(@bitCast(af)), ss);

            store(U, block, isa.packColorBytes(rr, gr, br, ar));
        }

        pub fn color16(block: *[lanes * 8]u8) void {
            const words = load(Words, block);

            // Y and Co of each color in one lane, Cg and A in another.
            const yco, const cga = std.simd.deinterlace(2, words);

            const yf: I = @bitCast(yco & splatU(0xffff));
            const cof = @as(I, @bitCast(yco)) >> @splat(16);
            const cgf = signedField(cga, 16, 16);
            var af = cga >> @splat(16);

            var as = af;
            as |= as >> @splat(1);
            as |= as >> @splat(2);
            as |= as >> @splat(4);
            as |= as >> @splat(8);

            af = ((af << @splat(1)) & as) | (af & splatU(1));

            const ss = @as(F, @splat(65535)) / toFloat(@bitCast(as));

            const rf = yf + (cof - cgf);
            const gf = yf + cgf;
            const bf = yf - (cof + cgf);

            const rr: U = @bitCast(isa.scaleRound(toFloat(rf), ss));
            const gr: U = @bitCast(isa.scaleRound(toFloat(gf), ss));
            const br: U = @bitCast(isa.scaleRound(toFloat(bf), ss));
            const ar: U = @bitCast(isa.scaleRound(toFloat(@bitCast(af)), ss));

            // The low 16 bits of each.
            const lo = (rr & splatU(0xffff)) | (gr << @splat(16));
            const hi = (br & splatU(0xffff)) | (ar << @splat(16));

            store(Words, block, std.simd.interlace(.{ lo, hi }));
        }
    };
}

/// The original's SSE kernels: four items at a time there, which the port
/// widens to the target's vectors, with the same instruction in each lane.
const X86 = struct {
    // Zig's own x86 backend runs the kernels four lanes wide, on the SSE
    // forms of the instructions, which compute the same results.
    const lanes = if (llvm and builtin.cpu.has(.x86, .avx512f))
        16
    else if (llvm and builtin.cpu.has(.x86, .avx2))
        8
    else
        4;
    const F = @Vector(lanes, f32);
    const I = @Vector(lanes, i32);
    const U = @Vector(lanes, u32);

    const avx = llvm and builtin.cpu.has(.x86, .avx);

    fn lengthSquared(x: F, y: F, z: F) F {
        return x * x + (y * y + z * z);
    }

    /// `v * s` rounded to the nearest integer, ties to even, as `cvtps2dq`
    /// rounds under the default MXCSR; NaN and out-of-range products give
    /// the lowest `i32`.
    fn scaleRound(v: F, s: F) I {
        const p = v * s;
        return if (lanes == 16)
            asm ("vcvtps2dq %[p], %[r]"
                : [r] "=v" (-> I),
                : [p] "v" (p),
            )
        else
            asm ((if (avx) "vcvtps2dq" else "cvtps2dq") ++ " %[p], %[r]"
                : [r] "=x" (-> I),
                : [p] "x" (p),
            );
    }

    /// `rsqrtps`, whose estimate is the CPU's own; AVX-512 has no 512-bit
    /// form of it, so 16 lanes take two 256-bit ones.
    fn rsqrtEstimate(v: F) F {
        return estimate("rsqrtps", v);
    }

    /// `rcpps`, as `rsqrtEstimate`.
    fn rcpEstimate(v: F) F {
        return estimate("rcpps", v);
    }

    fn estimate(comptime op: []const u8, v: F) F {
        if (lanes == 16) {
            const Half = @Vector(8, f32);
            const lo = estimateOf(op, Half, std.simd.extract(v, 0, 8));
            const hi = estimateOf(op, Half, std.simd.extract(v, 8, 8));
            return std.simd.join(lo, hi);
        } else {
            return estimateOf(op, F, v);
        }
    }

    fn estimateOf(comptime op: []const u8, comptime V: type, v: V) V {
        return asm ((if (avx) "v" else "") ++ op ++ " %[v], %[r]"
            : [r] "=x" (-> V),
            : [v] "x" (v),
        );
    }

    /// Bytes without masks: a component out of the byte range spills into
    /// the others, as in the original.
    fn packColorBytes(r: I, g: I, b: I, a: I) U {
        const shift8: U = @splat(8);
        const shift16: U = @splat(16);
        const shift24: U = @splat(24);
        var res: U = @bitCast(r);
        res |= @as(U, @bitCast(g)) << shift8;
        res |= @as(U, @bitCast(b)) << shift16;
        res |= @as(U, @bitCast(a)) << shift24;
        return res;
    }
};

/// The original's NEON kernels as AArch64 compiles them.
const Neon = struct {
    const lanes = 4;
    const F = @Vector(lanes, f32);
    const I = @Vector(lanes, i32);
    const U = @Vector(lanes, u32);

    /// 3 << 22: adding it leaves a float whose low mantissa bits are the
    /// integer nearest the sum, ties to even, offset by 0x4b40_0000; only
    /// the low 8 or 16 bits are kept, so the offset is never taken off.
    const snap: F = @splat(3 << 22);

    fn lengthSquared(x: F, y: F, z: F) F {
        return @mulAdd(F, z, z, @mulAdd(F, y, y, x * x));
    }

    fn scaleRound(v: F, s: F) I {
        return @bitCast(@mulAdd(F, v, s, snap));
    }

    /// `frsqrte`, whose estimate the architecture defines.
    fn rsqrtEstimate(v: F) F {
        return asm ("frsqrte %[r].4s, %[v].4s"
            : [r] "=w" (-> F),
            : [v] "w" (v),
        );
    }

    /// `frecpe`, whose estimate the architecture defines.
    fn rcpEstimate(v: F) F {
        return asm ("frecpe %[r].4s, %[v].4s"
            : [r] "=w" (-> F),
            : [v] "w" (v),
        );
    }

    /// Each component's low byte, inserted with `sli`.
    fn packColorBytes(r: I, g: I, b: I, a: I) U {
        const byte: U = @splat(0xff);
        var res = @as(U, @bitCast(r)) & byte;
        res |= (@as(U, @bitCast(g)) & byte) << @splat(8);
        res |= (@as(U, @bitCast(b)) & byte) << @splat(16);
        res |= @as(U, @bitCast(a)) << @splat(24);
        return res;
    }
};

// --------------------------------------------------------
// Encoders
// --------------------------------------------------------

/// Encodes unit vectors for `decodeFilterOct`: each vector in `data` is 4
/// floats, X, Y, Z and W, and becomes `stride` bytes of `destination`,
/// four signed integers of 8 bits (`stride` 4, `bits` at most 8) or 16
/// bits (`stride` 8): X and Y in octahedral form with `bits` bits (2 to
/// 16), Z holding 1.0, and W as a signed normalized integer of the full
/// width.
pub fn encodeFilterOct(destination: []u8, stride: usize, bits: u5, data: []const f32) void {
    assert(stride == 4 or stride == 8);
    assert(bits >= 2 and bits <= 16);
    assert(stride == 8 or bits <= 8);
    assert(data.len % 4 == 0);

    const count = data.len / 4;
    const byte_bits: u5 = @intCast(stride * 2);
    const out = destination[0 .. count * stride];

    for (0..count) |i| {
        const n = data[i * 4 ..][0..4];

        // The octahedral form of a unit vector.
        var nx = n[0];
        var ny = n[1];
        const nz = n[2];
        const nw = n[3];
        const nl = @abs(nx) + @abs(ny) + @abs(nz);
        const ns: f32 = if (nl == 0) 0 else 1 / nl;

        nx *= ns;
        ny *= ns;

        const u = if (nz >= 0) nx else (1 - @abs(ny)) * signOf(nx);
        const v = if (nz >= 0) ny else (1 - @abs(nx)) * signOf(ny);

        const encoded = [4]i32{
            quantization.quantizeSnorm(u, bits),
            quantization.quantizeSnorm(v, bits),
            quantization.quantizeSnorm(1, bits),
            quantization.quantizeSnorm(nw, byte_bits),
        };

        if (stride == 4) {
            storeComponents(i8, out[i * 4 ..][0..4], encoded);
        } else {
            storeComponents(i16, out[i * 8 ..][0..8], encoded);
        }
    }
}

/// The C `(v >= 0 ? 1.f : -1.f)`.
fn signOf(v: f32) f32 {
    return if (v >= 0) 1 else -1;
}

/// The low `T` bits of each value, in place of four `T`s.
fn storeComponents(comptime T: type, out: *[4 * @sizeOf(T)]u8, values: [4]i32) void {
    const Unsigned = @Int(.unsigned, @bitSizeOf(T));
    for (std.mem.bytesAsSlice(Unsigned, out), values) |*d, v| {
        d.* = @truncate(@as(u32, @bitCast(v)));
    }
}

/// Encodes unit quaternions for `decodeFilterQuat`: each quaternion in
/// `data` is 4 floats and becomes 8 bytes of `destination` (`stride` 8),
/// three components of `bits` bits (4 to 16) and the index of the largest,
/// dropped one.
pub fn encodeFilterQuat(destination: []u8, stride: usize, bits: u5, data: []const f32) void {
    assert(stride == 8);
    assert(bits >= 4 and bits <= 16);
    assert(data.len % 4 == 0);

    const count = data.len / 4;
    const out = std.mem.bytesAsSlice(i16, destination[0 .. count * 8]);
    const scaler = @sqrt(@as(f32, 2));

    for (0..count) |i| {
        const q = data[i * 4 ..][0..4];
        const d = out[i * 4 ..][0..4];

        // The largest component.
        var qc: u2 = 0;
        qc = if (@abs(q[1]) > @abs(q[qc])) 1 else qc;
        qc = if (@abs(q[2]) > @abs(q[qc])) 2 else qc;
        qc = if (@abs(q[3]) > @abs(q[qc])) 3 else qc;

        // The double cover of rotations lets the sign go.
        const sign: f32 = if (q[qc] < 0) -1 else 1;

        // The swizzle is always cyclic, so a rotation recovers the order.
        d[0] = @truncate(quantization.quantizeSnorm(q[qc +% 1] * scaler * sign, bits));
        d[1] = @truncate(quantization.quantizeSnorm(q[qc +% 2] * scaler * sign, bits));
        d[2] = @truncate(quantization.quantizeSnorm(q[qc +% 3] * scaler * sign, bits));
        d[3] = @truncate((quantization.quantizeSnorm(1, bits) & ~@as(i32, 3)) | qc);
    }
}

/// Encodes finite floats for `decodeFilterExp`: each vector in `data` is
/// `stride / 4` floats, and each float becomes 4 bytes of `destination`,
/// an 8-bit exponent and a `bits`-bit integer mantissa (1 to 24), with the
/// exponents shared as `mode` says. `stride` is a multiple of 4, at most
/// 256. `destination` may be `data` itself.
pub fn encodeFilterExp(
    destination: []u8,
    stride: usize,
    bits: u5,
    data: []const f32,
    mode: EncodeExpMode,
) void {
    assert(stride > 0 and stride % 4 == 0 and stride <= 256);
    assert(bits >= 1 and bits <= 24);

    const stride_float = stride / 4;
    assert(data.len % stride_float == 0);
    const count = data.len / stride_float;
    const out = std.mem.bytesAsSlice(u32, destination[0 .. count * stride]);

    var component_exp_buffer: [64]i32 = undefined;
    const component_exp = component_exp_buffer[0..stride_float];

    const min_exp = -100;

    // The largest exponent of each component for shared_component, and the
    // exponent that zeros reuse for separate.
    @memset(component_exp, if (mode == .separate) 0 else min_exp);

    if (mode == .shared_component) {
        for (0..count) |i| {
            const v = data[i * stride_float ..][0..stride_float];

            // The largest exponent keeps every mantissa in [-1, 1].
            for (v, component_exp) |value, *ce| {
                const e = optlog2(value);
                ce.* = if (ce.* < e) e else ce.*;
            }
        }
    }

    for (0..count) |i| {
        const v = data[i * stride_float ..][0..stride_float];
        const d = out[i * stride_float ..][0..stride_float];

        var vector_exp: i32 = min_exp;

        switch (mode) {
            .shared_vector => {
                // The largest exponent keeps every mantissa in [-1, 1].
                for (v) |value| {
                    const e = optlog2(value);
                    vector_exp = if (vector_exp < e) e else vector_exp;
                }
            },
            .separate => {
                for (v, component_exp) |value, *ce| {
                    const e = optlog2(value);

                    // Zeros keep the last exponent, which compresses better.
                    if (value != 0) ce.* = if (min_exp < e) e else min_exp;
                }
            },
            .clamped => {
                for (v, component_exp) |value, *ce| {
                    const e = optlog2(value);
                    ce.* = if (0 < e) e else 0;
                }
            },
            .shared_component => {},
        }

        for (0..stride_float) |j| {
            var exp = if (mode == .shared_vector) vector_exp else component_exp[j];

            // The mantissa is scaled to a K-bit signed integer, with K-1 bits
            // of magnitude.
            exp -= @as(i32, bits) - 1;

            const mmask = (1 << 24) - 1;
            const mmax = mmask >> 1;

            // The mantissa, renormalized and rounded half away from zero.
            var m = truncate(v[j] * optexp2(-exp) + roundingOffset(v[j]));

            // Rounding away from zero must not overflow the mantissa.
            m = if (m > mmax) mmax else m;

            d[j] = (@as(u32, @bitCast(m)) & mmask) | (@as(u32, @bitCast(exp)) << 24);
        }
    }
}

/// `frexp`'s exponent of `v`, from its bits; zero and denormals give -126,
/// which the callers clamp, so a zero never raises a shared exponent.
fn optlog2(v: f32) i32 {
    const biased: i32 = @intCast((@as(u32, @bitCast(v)) >> 23) & 0xff);
    // The + 1 accounts for the mantissa's implicit 1.
    return biased - 127 + 1;
}

/// 2^e, from its bits.
fn optexp2(e: i32) f32 {
    return @bitCast(@as(u32, @bitCast(e +% 127)) << 23);
}

/// Encodes RGBA colors for `decodeFilterColor`: each color in `data` is 4
/// floats and becomes `stride` bytes of `destination`, four unsigned
/// integers of 8 bits (`stride` 4, `bits` at most 8) or 16 bits (`stride`
/// 8): RGB in YCoCg with `bits` bits (2 to 16), and alpha in `bits` - 1.
pub fn encodeFilterColor(destination: []u8, stride: usize, bits: u5, data: []const f32) void {
    assert(stride == 4 or stride == 8);
    assert(bits >= 2 and bits <= 16);
    assert(stride == 8 or bits <= 8);
    assert(data.len % 4 == 0);

    const count = data.len / 4;
    const out = destination[0 .. count * stride];

    for (0..count) |i| {
        const c = data[i * 4 ..][0..4];

        const fr: i32 = @intCast(quantization.quantizeUnorm(c[0], bits));
        const fg: i32 = @intCast(quantization.quantizeUnorm(c[1], bits));
        const fb: i32 = @intCast(quantization.quantizeUnorm(c[2], bits));

        // YCoCg-R with Co and Cg truncated, so that decoding needs only
        // integers, and R, G and B come back in K bits.
        const fco = @divTrunc(fr - fb, 2);
        const tmp = fb + fco;
        const fcg = @divTrunc(fg - tmp, 2);
        const fy = tmp + fcg;

        // Alpha in K-1 bits, with the high bit set.
        const fa = (quantization.quantizeUnorm(c[3], bits) >> 1) | (@as(u32, 1) << (bits - 1));

        const encoded = [4]i32{ fy, fco, fcg, @intCast(fa) };

        if (stride == 4) {
            storeComponents(u8, out[i * 4 ..][0..4], encoded);
        } else {
            storeComponents(u16, out[i * 8 ..][0..8], encoded);
        }
    }
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

/// Whether the decoders above run SIMD kernels on this build: all of them,
/// the 16-bit and exponent ones only (`simd_estimates` false), or none.
pub const has_simd = path_default != .scalar;
pub const simd_estimates = withEstimates(path_default) != .scalar;

/// The decoders on the scalar path, for checking it on targets that have
/// a SIMD path.
pub fn decodeFilterOctScalar(buffer: []u8, stride: usize) void {
    decodeOct(.scalar, buffer, stride);
}

pub fn decodeFilterQuatScalar(buffer: []u8, stride: usize) void {
    decodeQuat(.scalar, buffer, stride);
}

pub fn decodeFilterExpScalar(buffer: []u8, stride: usize) void {
    decodeExp(.scalar, buffer, stride);
}

pub fn decodeFilterColorScalar(buffer: []u8, stride: usize) void {
    decodeColor(.scalar, buffer, stride);
}

/// The NEON kernels with exact reciprocals in place of the estimate
/// instructions, so that their unpacking, rounding and packing run on
/// every target.
const NeonExact = struct {
    const lanes = Neon.lanes;
    const F = Neon.F;
    const lengthSquared = Neon.lengthSquared;
    const scaleRound = Neon.scaleRound;
    const packColorBytes = Neon.packColorBytes;

    fn rsqrtEstimate(v: F) F {
        return @as(F, @splat(1)) / @sqrt(v);
    }

    fn rcpEstimate(v: F) F {
        return @as(F, @splat(1)) / v;
    }
};

/// Fails unless `decode`, a NEON decoder with exact reciprocals, writes
/// what the scalar loops write for `encoded`, within one unit in every
/// component of `T`: the two round differently.
fn expectNearScalar(
    comptime T: type,
    encoded: []const u8,
    stride: usize,
    comptime decode: fn ([]u8) void,
    comptime scalar: fn ([]u8, usize) void,
) !void {
    const want = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(want);
    const got = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(got);
    scalar(want, stride);
    decode(got);
    for (std.mem.bytesAsSlice(T, want), std.mem.bytesAsSlice(T, got)) |w, g| {
        try testing.expect(@abs(@as(i32, w) - @as(i32, g)) <= 1);
    }
}

test "the NEON kernels decode within one unit of the scalar loops" {
    const k = SimdKernels(NeonExact);
    const decoders = struct {
        fn oct8(buffer: []u8) void {
            decodeBlocks(k.lanes * 4, k.oct8, buffer);
        }
        fn oct16(buffer: []u8) void {
            decodeBlocks(k.lanes * 8, k.oct16, buffer);
        }
        fn quat(buffer: []u8) void {
            decodeBlocks(k.lanes * 8, k.quat, buffer);
        }
        fn color8(buffer: []u8) void {
            decodeBlocks(k.lanes * 4, k.color8, buffer);
        }
        fn color16(buffer: []u8) void {
            decodeBlocks(k.lanes * 8, k.color16, buffer);
        }
    };

    // Random unit vectors and quaternions, and colors in [0, 1].
    const count = 1001;
    var prng: std.Random.DefaultPrng = .init(5);
    const rng = prng.random();
    var units: [count * 4]f32 = undefined;
    var colors: [count * 4]f32 = undefined;
    for (0..count) |i| {
        const v = units[i * 4 ..][0..4];
        for (v) |*x| x.* = rng.floatNorm(f32);
        const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]);
        for (v) |*x| x.* /= length;
        for (colors[i * 4 ..][0..4]) |*x| x.* = rng.float(f32);
    }

    var narrow: [count * 4]u8 = undefined;
    var wide: [count * 8]u8 = undefined;

    encodeFilterOct(&narrow, 4, 8, &units);
    try expectNearScalar(i8, &narrow, 4, decoders.oct8, decodeFilterOctScalar);
    encodeFilterOct(&wide, 8, 12, &units);
    try expectNearScalar(i16, &wide, 8, decoders.oct16, decodeFilterOctScalar);
    encodeFilterQuat(&wide, 8, 12, &units);
    try expectNearScalar(i16, &wide, 8, decoders.quat, decodeFilterQuatScalar);
    encodeFilterColor(&narrow, 4, 8, &colors);
    try expectNearScalar(u8, &narrow, 4, decoders.color8, decodeFilterColorScalar);
    encodeFilterColor(&wide, 8, 12, &colors);
    try expectNearScalar(u16, &wide, 8, decoders.color16, decodeFilterColorScalar);
}

test "the NEON exponent kernel decodes as the scalar loop" {
    const k = SimdKernels(NeonExact);
    var prng: std.Random.DefaultPrng = .init(6);
    var want: [4 * 1001]u8 = undefined;
    prng.random().bytes(&want);
    var got = want;
    decodeFilterExpScalar(&want, 4);
    decodeBlocks(k.lanes * 4, k.exp, &got);
    try testing.expectEqualSlices(u8, &want, &got);
}
