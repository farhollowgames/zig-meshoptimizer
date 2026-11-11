// cosf from Arm's optimized-routines (math/cosf.c, math/sincosf.h and
// math/sincosf_data.c), translated to Zig. Copyright (c) 2018-2026, Arm
// Limited; MIT licence, see LICENSE.md. glibc's cosf is built from the same
// code.

//! The single-precision cosine that `generateNormals` takes its crease
//! cutoff from. The original calls its C library's `cosf`, and C libraries
//! round it their own ways; this is glibc's, with the fused multiply-adds
//! glibc uses on CPUs that have them, so the port's cutoffs are those of
//! the original built on Linux, on every target.

const std = @import("std");

/// The quadrants' signs, the reduction's constants and the polynomials of
/// the cosine (`c0` to `c4`) and the sine (`s1` to `s3`).
const SincosTable = struct {
    /// The sign of the sine in each quadrant.
    sign: [4]f64,
    /// 2 / pi, scaled by 2^24 so the quadrant lands in the top byte.
    hpi_inv: f64,
    /// pi / 2.
    hpi: f64,
    c0: f64,
    c1: f64,
    c2: f64,
    c3: f64,
    c4: f64,
    s1: f64,
    s2: f64,
    s3: f64,
};

/// The second table's cosine polynomial is negated, for the quadrants
/// where the cosine is negative.
const tables = [2]SincosTable{
    .{
        .sign = .{ 1, -1, -1, 1 },
        .hpi_inv = 0x1.45f306dc9c883p+23,
        .hpi = 0x1.921fb54442d18p0,
        .c0 = 0x1p0,
        .c1 = -0x1.ffffffd0c621cp-2,
        .c2 = 0x1.55553e1068f19p-5,
        .c3 = -0x1.6c087e89a359dp-10,
        .c4 = 0x1.99343027bf8c3p-16,
        .s1 = -0x1.555545995a603p-3,
        .s2 = 0x1.1107605230bc4p-7,
        .s3 = -0x1.994eb3774cf24p-13,
    },
    .{
        .sign = .{ 1, -1, -1, 1 },
        .hpi_inv = 0x1.45f306dc9c883p+23,
        .hpi = 0x1.921fb54442d18p0,
        .c0 = -0x1p0,
        .c1 = 0x1.ffffffd0c621cp-2,
        .c2 = -0x1.55553e1068f19p-5,
        .c3 = 0x1.6c087e89a359dp-10,
        .c4 = -0x1.99343027bf8c3p-16,
        .s1 = -0x1.555545995a603p-3,
        .s2 = 0x1.1107605230bc4p-7,
        .s3 = -0x1.994eb3774cf24p-13,
    },
};

/// 4 / pi to 192 bits, each entry adding 8 bits to the one before.
const inv_pio4 = [24]u32{
    0xa2,       0xa2f9,     0xa2f983,   0xa2f9836e,
    0xf9836e4e, 0x836e4e44, 0x6e4e4415, 0x4e441529,
    0x441529fc, 0x1529fc27, 0x29fc2757, 0xfc2757d1,
    0x2757d1f5, 0x57d1f534, 0xd1f534dd, 0xf534ddc0,
    0x34ddc0db, 0xddc0db62, 0xc0db6295, 0xdb629599,
    0x6295993c, 0x95993c43, 0x993c4390, 0x3c439041,
};

/// 2 pi * 2^-64.
const pi63: f64 = 0x1.921fb54442d18p-62;

/// pi / 4.
const pio4: f32 = 0x1.921fb6p-1;

/// The top 12 bits of `x` without its sign: the exponent and the top three
/// bits of the mantissa.
fn abstop12(x: f32) u32 {
    return (@as(u32, @bitCast(x)) >> 20) & 0x7ff;
}

/// An angle reduced to between -pi/4 and pi/4, and its quadrant.
const Reduced = struct {
    x: f64,
    n: i32,
};

/// The reduction for |x| below 120, by one multiply-subtract.
fn reduceFast(x: f64) Reduced {
    const r = x * tables[0].hpi_inv;
    const n = (@as(i32, @intFromFloat(r)) + 0x800000) >> 24;
    return .{ .x = @mulAdd(f64, -@as(f64, @floatFromInt(n)), tables[0].hpi, x), .n = n };
}

/// The reduction of a finite float `xi` of 120 or more in magnitude, by an
/// exact fixed-point product with 4 / pi.
fn reduceLarge(xi: u32) Reduced {
    const arr = inv_pio4[(xi >> 26) & 15 ..];
    const shift: u5 = @intCast((xi >> 23) & 7);
    const m = ((xi & 0xffffff) | 0x800000) << shift;

    var res0: u64 = m *% arr[0];
    const res1 = @as(u64, m) * arr[4];
    const res2 = @as(u64, m) * arr[8];
    res0 = (res2 >> 32) | (res0 << 32);
    res0 +%= res1;

    const n = (res0 +% (1 << 61)) >> 62;
    res0 -%= n << 62;
    const x: f64 = @floatFromInt(@as(i64, @bitCast(res0)));
    return .{ .x = x * pi63, .n = @intCast(n) };
}

/// The sine polynomial at `x` for an even `n`, the cosine's for an odd one.
fn sinfPoly(x: f64, x2: f64, p: *const SincosTable, n: i32) f32 {
    if (n & 1 == 0) {
        const x3 = x * x2;
        const s1 = @mulAdd(f64, x2, p.s3, p.s2);
        const x7 = x3 * x2;
        const s = @mulAdd(f64, x3, p.s1, x);
        return @floatCast(@mulAdd(f64, x7, s1, s));
    }
    const x4 = x2 * x2;
    const c2 = @mulAdd(f64, x2, p.c4, p.c3);
    const c1 = @mulAdd(f64, x2, p.c1, p.c0);
    const x6 = x4 * x2;
    const c = @mulAdd(f64, x4, p.c2, c1);
    return @floatCast(@mulAdd(f64, x6, c2, c));
}

/// The cosine of `y` radians, as glibc's `cosf` gives it: less than 0.57
/// of a float step from the exact cosine, and NaN for an infinite or NaN
/// `y`.
pub fn cosf(y: f32) f32 {
    const x: f64 = y;
    const top = abstop12(y);

    if (top < abstop12(pio4)) {
        if (top < abstop12(0x1p-12)) return 1;
        return sinfPoly(x, x * x, &tables[0], 1);
    }
    if (top < abstop12(120)) {
        const r = reduceFast(x);
        const s = tables[0].sign[@intCast(r.n & 3)];
        const p = &tables[if (r.n & 2 != 0) 1 else 0];
        return sinfPoly(r.x * s, r.x * r.x, p, r.n ^ 1);
    }
    if (top < abstop12(std.math.inf(f32))) {
        const xi: u32 = @bitCast(y);
        const r = reduceLarge(xi);
        const quadrant = r.n + @as(i32, @intCast(xi >> 31));
        const s = tables[0].sign[@intCast(quadrant & 3)];
        const p = &tables[if (quadrant & 2 != 0) 1 else 0];
        return sinfPoly(r.x * s, r.x * r.x, p, r.n ^ 1);
    }
    return (y - y) / (y - y);
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

/// The float `x` rounded to from the double cosine.
fn roundedCos(x: f32) f32 {
    return @floatCast(@cos(@as(f64, x)));
}

/// How many float steps apart two finite floats of one sign are.
fn steps(a: f32, b: f32) u32 {
    const ia: i32 = @bitCast(a);
    const ib: i32 = @bitCast(b);
    return @abs(ia - ib);
}

test "the cosine at landmarks" {
    try testing.expectEqual(1, cosf(0));
    try testing.expectEqual(1, cosf(-0.0));
    try testing.expectEqual(1, cosf(0x1p-13));
    try testing.expectEqual(-1, cosf(3.14159265));
    try testing.expect(@abs(cosf(1.0471976) - 0.5) < 1e-7);
    for ([_]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |x| {
        try testing.expect(std.math.isNan(cosf(x)));
    }
}

test "the cosine is within a float step of the rounded double cosine on a sweep of all floats" {
    // Below 120 the fast reduction runs, above it the 192-bit one.
    var bits: u64 = 0;
    while (bits <= std.math.maxInt(u32)) : (bits += 65_537) {
        const x: f32 = @bitCast(@as(u32, @intCast(bits)));
        if (!std.math.isFinite(x)) continue;
        const want = roundedCos(x);
        const got = cosf(x);
        try testing.expectEqual(std.math.signbit(want), std.math.signbit(got));
        try testing.expect(steps(want, got) <= 1);
    }
}
