//! Quantization against the original: every float for half floats, every
//! half for their floats, and sampled floats at every bit count for the
//! others.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const common = @import("common.zig");

/// A sample of float bit patterns: every 65521st one (a prime, so the
/// samples fall all over the mantissa), and the special values.
fn sampledFloats(gpa: std.mem.Allocator) ![]f32 {
    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(gpa);
    var bits: u64 = 0;
    while (bits <= std.math.maxInt(u32)) : (bits += 65521) {
        try list.append(gpa, @bitCast(@as(u32, @intCast(bits))));
    }
    const specials = [_]f32{
        0,                       -0.0,               1,
        -1,                      0.5,                -0.5,
        1e-40,                   -1e-40,             std.math.floatMax(f32),
        -std.math.floatMax(f32), std.math.inf(f32),  -std.math.inf(f32),
        std.math.nan(f32),       -std.math.nan(f32), std.math.floatMin(f32),
        65504,                   65519.99,           65520,
        6.1035156e-5,            6.1035152e-5,       0.99999994,
        1.0000001,               2,                  -2,
    };
    try list.appendSlice(gpa, &specials);
    return list.toOwnedSlice(gpa);
}

test "quantizeHalf matches the original on every float" {
    var bits: u32 = 0;
    while (true) : (bits += 1) {
        const v: f32 = @bitCast(bits);
        const want = c.meshopt_quantizeHalf(v);
        const got = mo.quantizeHalf(v);
        if (want != got) {
            std.debug.print(
                "quantizeHalf(0x{x:0>8}): original 0x{x}, port 0x{x}\n",
                .{ bits, want, got },
            );
            return error.Mismatch;
        }
        if (bits == std.math.maxInt(u32)) break;
    }
}

test "dequantizeHalf matches the original on every half" {
    for (0..1 << 16) |h| {
        const want: u32 = @bitCast(c.meshopt_dequantizeHalf(@intCast(h)));
        const got: u32 = @bitCast(mo.dequantizeHalf(@intCast(h)));
        try common.expectSameValue(u32, "dequantizeHalf", want, got);
    }
}

test "quantizeFloat matches the original at every bit count" {
    const samples = try sampledFloats(common.gpa);
    defer common.gpa.free(samples);
    for (0..24) |bits| {
        for (samples) |v| {
            const want: u32 = @bitCast(c.meshopt_quantizeFloat(v, @intCast(bits)));
            const got: u32 = @bitCast(mo.quantizeFloat(v, @intCast(bits)));
            try common.expectSameValue(u32, "quantizeFloat", want, got);
        }
    }
}

test "quantizeUnorm and quantizeSnorm match the original" {
    const samples = try sampledFloats(common.gpa);
    defer common.gpa.free(samples);
    var prng: std.Random.DefaultPrng = .init(1);
    const rng = prng.random();
    var values: std.ArrayList(f32) = .empty;
    defer values.deinit(common.gpa);
    try values.appendSlice(common.gpa, samples);
    for (0..100_000) |_| try values.append(common.gpa, rng.float(f32) * 2.5 - 1.25);

    for (1..31) |bits| {
        for (values.items) |v| {
            const want = c.reference_quantizeUnorm(v, @intCast(bits));
            const got = mo.quantizeUnorm(v, @intCast(bits));
            try common.expectSameValue(i64, "quantizeUnorm", want, got);
        }
    }
    for (1..32) |bits| {
        for (values.items) |v| {
            const want = c.reference_quantizeSnorm(v, @intCast(bits));
            const got = mo.quantizeSnorm(v, @intCast(bits));
            try common.expectSameValue(i64, "quantizeSnorm", want, got);
        }
    }
}

test "computePositionExponent matches the original" {
    var prng: std.Random.DefaultPrng = .init(2);
    const rng = prng.random();
    for (0..200_000) |i| {
        var minv: [3]f32 = undefined;
        var maxv: [3]f32 = undefined;
        // Boxes of every magnitude, some degenerate, some with an infinity.
        const scale = std.math.ldexp(@as(f32, 1), rng.intRangeAtMost(i32, -40, 40));
        for (&minv, &maxv) |*lo, *hi| {
            const a = (rng.float(f32) * 2 - 1) * scale;
            const b = if (i % 7 == 0) a else (rng.float(f32) * 2 - 1) * scale;
            lo.* = @min(a, b);
            hi.* = @max(a, b);
        }
        if (i % 1009 == 0) maxv[i % 3] = std.math.inf(f32);
        const min_exp = rng.intRangeAtMost(i32, -126, 20);
        const max_bits = rng.intRangeAtMost(u5, 2, 24);
        const want = c.meshopt_computePositionExponent(&minv, &maxv, min_exp, max_bits);
        const got = mo.computePositionExponent(minv, maxv, min_exp, max_bits);
        try common.expectSameValue(i32, "computePositionExponent", want, got);
    }
}
