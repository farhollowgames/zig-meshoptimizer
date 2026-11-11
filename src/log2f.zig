// log2f from Arm's optimized-routines (math/log2f.c and math/log2f_data.c),
// translated to Zig. Copyright (c) 2017-2026, Arm Limited; MIT licence, see
// LICENSE.md. glibc's log2f is built from the same code.

//! The single-precision base-2 logarithm that `opacityMapMeasure` takes
//! its subdivision levels from. The original calls its C library's
//! `log2f`, and C libraries round it their own ways; this is glibc's, with
//! the fused multiply-adds glibc uses on CPUs that have them, so the port's
//! levels are those of the original built on Linux, on every target.

const std = @import("std");

/// For each of 16 subintervals of [0x3f330000, 2 * 0x3f330000) as float
/// bits, 1 / c for a `c` near its center, and log2(c).
const table = [16]struct { invc: f64, logc: f64 }{
    .{ .invc = 0x1.661ec79f8f3bep+0, .logc = -0x1.efec65b963019p-2 },
    .{ .invc = 0x1.571ed4aaf883dp+0, .logc = -0x1.b0b6832d4fca4p-2 },
    .{ .invc = 0x1.49539f0f010bp+0, .logc = -0x1.7418b0a1fb77bp-2 },
    .{ .invc = 0x1.3c995b0b80385p+0, .logc = -0x1.39de91a6dcf7bp-2 },
    .{ .invc = 0x1.30d190c8864a5p+0, .logc = -0x1.01d9bf3f2b631p-2 },
    .{ .invc = 0x1.25e227b0b8eap+0, .logc = -0x1.97c1d1b3b7afp-3 },
    .{ .invc = 0x1.1bb4a4a1a343fp+0, .logc = -0x1.2f9e393af3c9fp-3 },
    .{ .invc = 0x1.12358f08ae5bap+0, .logc = -0x1.960cbbf788d5cp-4 },
    .{ .invc = 0x1.0953f419900a7p+0, .logc = -0x1.a6f9db6475fcep-5 },
    .{ .invc = 0x1p+0, .logc = 0x0p+0 },
    .{ .invc = 0x1.e608cfd9a47acp-1, .logc = 0x1.338ca9f24f53dp-4 },
    .{ .invc = 0x1.ca4b31f026aap-1, .logc = 0x1.476a9543891bap-3 },
    .{ .invc = 0x1.b2036576afce6p-1, .logc = 0x1.e840b4ac4e4d2p-3 },
    .{ .invc = 0x1.9c2d163a1aa2dp-1, .logc = 0x1.40645f0c6651cp-2 },
    .{ .invc = 0x1.886e6037841edp-1, .logc = 0x1.88e9c2c1b9ff8p-2 },
    .{ .invc = 0x1.767dcf5534862p-1, .logc = 0x1.ce0a44eb17bccp-2 },
};

/// The polynomial for log1p(r) / ln 2, highest power first.
const poly = [4]f64{
    -0x1.712b6f70a7e4dp-2,
    0x1.ecabf496832ep-2,
    -0x1.715479ffae3dep-1,
    0x1.715475f35c8b8p0,
};

/// The start of the table's range, as float bits.
const off: u32 = 0x3f330000;

/// The base-2 logarithm of `x`, as glibc's `log2f` gives it: less than
/// 0.76 of a float step from the exact value; -infinity for zero,
/// infinity for infinity, and NaN for NaN and negative `x`.
pub fn log2f(x: f32) f32 {
    var ix: u32 = @bitCast(x);
    // log2(1) is +0 in every rounding mode.
    if (ix == 0x3f800000) return 0;
    if (ix -% 0x00800000 >= 0x7f800000 - 0x00800000) {
        // Zero, subnormal, negative, infinite or NaN.
        if (ix *% 2 == 0) return -std.math.inf(f32);
        if (ix == 0x7f800000) return x;
        if (ix & 0x80000000 != 0 or ix *% 2 >= 0xff000000) return (x - x) / (x - x);
        // Subnormal: normalized, the exponent corrected.
        ix = @bitCast(x * 0x1p23);
        ix -%= 23 << 23;
    }

    // x is 2^k z, with z exact in [off, 2 off) as float bits, in the
    // subinterval i, whose c is near z.
    const tmp = ix -% off;
    const i = (tmp >> 19) % table.len;
    const top = tmp & 0xff800000;
    const iz = ix -% top;
    const k = @as(i32, @bitCast(tmp)) >> 23;
    const z: f64 = @as(f32, @bitCast(iz));

    // log2(x) = log1p(z / c - 1) / ln 2 + log2(c) + k.
    const r = @mulAdd(f64, z, table[i].invc, -1);
    const y0 = table[i].logc + @as(f64, @floatFromInt(k));

    // A pipelined polynomial for log1p(r) / ln 2.
    const r2 = r * r;
    var y = @mulAdd(f64, poly[1], r, poly[2]);
    y = @mulAdd(f64, poly[0], r2, y);
    const p = @mulAdd(f64, poly[3], r, y0);
    y = @mulAdd(f64, y, r2, p);
    return @floatCast(y);
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "the logarithm at landmarks" {
    try testing.expectEqual(0, log2f(1));
    try testing.expectEqual(1, log2f(2));
    try testing.expectEqual(12, log2f(4096));
    try testing.expectEqual(-1, log2f(0.5));
    try testing.expectEqual(-149, log2f(0x1p-149));
    try testing.expect(@abs(log2f(3) - 1.5849625) < 1e-6);
    try testing.expectEqual(std.math.inf(f32), log2f(std.math.inf(f32)));
    try testing.expectEqual(-std.math.inf(f32), log2f(0));
    try testing.expectEqual(-std.math.inf(f32), log2f(-0.0));
    for ([_]f32{ -1, -std.math.inf(f32), std.math.nan(f32) }) |x| {
        try testing.expect(std.math.isNan(log2f(x)));
    }
}
