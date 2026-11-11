//! Quantization into fixed point normalized formats, half floats, and floats
//! with fewer mantissa bits; and the shared exponent for quantizing positions.
//!
//! Translated from meshoptimizer's quantization.cpp and the inline functions
//! of meshoptimizer.h.

const std = @import("std");
const assert = std.debug.assert;

/// Quantizes `v` in [0, 1] into a `bits`-bit unorm value, for the
/// reconstruction `q / (2^bits - 1)` that fixed-function normalized
/// formats use; out-of-range values clamp, and NaN gives 0. The largest
/// reconstruction error is 1/2^(bits+1). `bits` is 1 to 30.
pub fn quantizeUnorm(v: f32, bits: u5) u32 {
    const scale: f32 = @floatFromInt((@as(u32, 1) << bits) - 1);

    var clamped = if (v >= 0) v else 0;
    clamped = if (clamped <= 1) clamped else 1;

    return @intFromFloat(clamped * scale + 0.5);
}

/// Quantizes `v` in [-1, 1] into a `bits`-bit snorm value, for the
/// reconstruction `q / (2^(bits-1) - 1)` that fixed-function normalized
/// formats use (except early OpenGL); out-of-range values clamp, and NaN
/// gives the minimum. The largest reconstruction error is 1/2^bits. `bits`
/// is 1 to 31.
pub fn quantizeSnorm(v: f32, bits: u5) i32 {
    const scale: f32 = @floatFromInt((@as(i32, 1) << (bits - 1)) - 1);

    const round: f32 = if (v >= 0) 0.5 else -0.5;

    var clamped = if (v >= -1) v else -1;
    clamped = if (clamped <= 1) clamped else 1;

    return @intFromFloat(clamped * scale + round);
}

/// Quantizes `v` into an IEEE-754 half float, rounding to nearest: overflow
/// gives infinity, denormals flush to zero, and every NaN becomes a quiet
/// NaN. Magnitudes from 6e-5 to 65504 are representable, with a relative
/// error of at most 5e-4.
pub fn quantizeHalf(v: f32) u16 {
    const ui: u32 = @bitCast(v);

    const s: i32 = @intCast((ui >> 16) & 0x8000);
    const em: i32 = @intCast(ui & 0x7fffffff);

    // Bias the exponent and round to nearest; 112 is the relative exponent
    // bias (127 - 15).
    var h = (em - (112 << 23) + (1 << 12)) >> 13;

    // Underflow flushes to zero; 113 encodes exponent -14.
    h = if (em < (113 << 23)) 0 else h;

    // Overflow gives infinity; 143 encodes exponent 16.
    h = if (em >= (143 << 23)) 0x7c00 else h;

    h = if (em > (255 << 23)) 0x7e00 else h;

    return @intCast(s | h);
}

/// Rounds `v` to nearest with `bits` significant mantissa bits, keeping the
/// IEEE-754 single-precision layout: infinities and NaN are kept, and
/// denormals flush to zero. `bits` is 0 to 23.
pub fn quantizeFloat(v: f32, bits: u5) f32 {
    assert(bits <= 23);

    var ui: u32 = @bitCast(v);

    const mask = (@as(u32, 1) << (23 - bits)) - 1;
    const round = (@as(u32, 1) << (23 - bits)) >> 1;

    const e = ui & 0x7f800000;
    const rui = (ui +% round) & ~mask;

    // Every number except infinity and NaN rounds, so that no NaN overflows
    // into -0.
    ui = if (e == 0x7f800000) ui else rui;

    ui = if (e == 0) 0 else ui;

    return @bitCast(ui);
}

/// The float a half float stands for: infinities and NaN are kept, NaN with
/// its payload, and denormals flush to zero.
pub fn dequantizeHalf(h: u16) f32 {
    const s = @as(u32, h & 0x8000) << 16;
    const em: i32 = h & 0x7fff;

    // Bias the exponent and pad the mantissa with zeros; 112 is the relative
    // exponent bias (127 - 15).
    var r = (em + (112 << 10)) << 13;

    r = if (em < (1 << 10)) 0 else r;

    // Infinity and NaN: applying the bias fixup a second time turns exponent
    // 31 into 255, which also keeps a NaN's payload.
    r += if (em >= (31 << 10)) (112 << 23) else 0;

    return @bitCast(s | @as(u32, @intCast(r)));
}

/// A shared exponent for quantizing positions within the box from `minv` to
/// `maxv`, a mesh's or a cluster's bounds, to a 24-bit integer grid: with
/// `scale = 2^exponent`, every position `v` in the box quantizes to the
/// integer `round(v / scale)`, which fits signed 24 bits, and any two of them
/// differ by less than `2^max_bits`, so a position can also be stored as an
/// unsigned `max_bits` offset from a shared signed 24-bit anchor (as
/// D3D12_VERTEX_FORMAT_COMPRESSED1 does with `max_bits` 16).
///
/// `min_exp` is the smallest exponent returned, which bounds precision to
/// save bits: -10 limits it to a millimetre in metres. `min_exp` is at least
/// -126, and `max_bits` 2 to 24.
pub fn computePositionExponent(minv: [3]f32, maxv: [3]f32, min_exp: i32, max_bits: u5) i32 {
    assert(min_exp >= -126);
    assert(max_bits >= 2 and max_bits <= 24);

    var exp = min_exp;

    // The largest absolute component, so that each endpoint fits a 24-bit
    // signed grid.
    var maxc: f32 = 0;
    for (minv, maxv) |lo, hi| {
        maxc = if (maxc < @abs(lo)) @abs(lo) else maxc;
        maxc = if (maxc < @abs(hi)) @abs(hi) else maxc;
    }

    const maxc_parts = std.math.frexp(maxc);

    // maxc is 2^(exponent - 24) times a 24-bit unsigned integer; a signed
    // grid loses the last bit, and rounding a mantissa of 1.111... can raise
    // the exponent by one, which the offset allows for.
    const maxc_rounds_up = maxc_parts.significand >= 1 - std.math.floatEps(f32) / 2;
    const maxc_off = 23 - @as(i32, @intFromBool(maxc_rounds_up));

    exp = if (exp < maxc_parts.exponent - maxc_off) maxc_parts.exponent - maxc_off else exp;

    // The range with conservative rounding, which leaves the caller free to
    // round either way.
    const scale = std.math.ldexp(@as(f32, 1), -exp);
    var range: f32 = 0;

    for (minv, maxv) |lo, hi| {
        const a = @floor(lo * scale);
        const v = @ceil(hi * scale);
        range = if (range < v - a) v - a else range;
    }

    // The range must fit max_bits unsigned bits.
    const range_parts = std.math.frexp(range);

    exp += if (range_parts.exponent > max_bits) range_parts.exponent - max_bits else 0;

    // At the rounding boundary the range would still overflow max_bits.
    const range_max: f32 = @floatFromInt((@as(u32, 1) << max_bits) - 1);
    const at_boundary = range_parts.significand >= 1 - 1 / range_max;
    exp += @intFromBool(range_parts.exponent > max_bits and at_boundary);

    return exp;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "half floats round trip" {
    try testing.expectEqual(0x3c00, quantizeHalf(1));
    try testing.expectEqual(0xc000, quantizeHalf(-2));
    try testing.expectEqual(0x7c00, quantizeHalf(65520));
    try testing.expectEqual(0x7e00, quantizeHalf(std.math.nan(f32)));
    try testing.expectEqual(0, quantizeHalf(1e-8));
    try testing.expectEqual(@as(f32, 1), dequantizeHalf(0x3c00));
    try testing.expectEqual(std.math.inf(f32), dequantizeHalf(0x7c00));
}

test "normalized fixed point clamps" {
    try testing.expectEqual(255, quantizeUnorm(1.5, 8));
    try testing.expectEqual(0, quantizeUnorm(-1, 8));
    try testing.expectEqual(128, quantizeUnorm(0.5, 8));
    try testing.expectEqual(127, quantizeSnorm(2, 8));
    try testing.expectEqual(-127, quantizeSnorm(-2, 8));
}
