//! Float to integer conversion as the original compiles it.

const std = @import("std");
const builtin = @import("builtin");

/// `int(v)` in C as the original's x86 build computes it: truncated toward
/// zero, and the lowest `i32` when `v` is NaN or out of range, on every
/// target. C leaves out-of-range conversions undefined; this keeps the
/// results of such inputs the same everywhere.
pub fn truncate(v: f32) i32 {
    if (builtin.cpu.arch == .x86_64) {
        // The instruction C compilers emit, which gives the lowest `i32` for
        // NaN and out-of-range values by itself: through LLVM's intrinsic,
        // which it schedules as any other instruction, or as assembly for
        // Zig's own backend.
        if (builtin.zig_backend == .stage2_llvm) return @"llvm.x86.sse.cvttss2si"(.{ v, 0, 0, 0 });
        const avx = comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx);
        return asm ((if (avx) "vcvttss2si" else "cvttss2si") ++ " %[v], %[r]"
            : [r] "=r" (-> i32),
            : [v] "x" (v),
        );
    }
    if (v >= -2147483648.0 and v < 2147483648.0) return @intFromFloat(v);
    return std.math.minInt(i32);
}

extern fn @"llvm.x86.sse.cvttss2si"(@Vector(4, f32)) i32;

/// `truncate` on each lane, for loops Zig leaves scalar unless they are
/// written on vectors.
pub fn truncateLanes(comptime n: comptime_int, v: @Vector(n, f32)) @Vector(n, i32) {
    const in_range = (v >= @as(@Vector(n, f32), @splat(-2147483648.0))) &
        (v < @as(@Vector(n, f32), @splat(2147483648.0)));
    const finite = @select(f32, in_range, v, @as(@Vector(n, f32), @splat(0)));
    const truncated: @Vector(n, i32) = @intFromFloat(finite);
    return @select(i32, in_range, truncated, @as(@Vector(n, i32), @splat(std.math.minInt(i32))));
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "truncation gives the lowest int out of range" {
    try testing.expectEqual(3, truncate(3.9));
    try testing.expectEqual(-3, truncate(-3.9));
    try testing.expectEqual(std.math.minInt(i32), truncate(-2147483648.0));
    try testing.expectEqual(std.math.minInt(i32), truncate(-2147483904.0));
    try testing.expectEqual(std.math.minInt(i32), truncate(2147483648.0));
    try testing.expectEqual(std.math.minInt(i32), truncate(std.math.inf(f32)));
    try testing.expectEqual(std.math.minInt(i32), truncate(-std.math.inf(f32)));
    try testing.expectEqual(std.math.minInt(i32), truncate(std.math.nan(f32)));
    try testing.expectEqual(2147483520, truncate(2147483520.0));
}

test "lanes truncate as one value does" {
    const values = [8]f32{
        3.9,               -3.9,
        -2147483648.0,     2147483648.0,
        std.math.inf(f32), std.math.nan(f32),
        2147483520.0,      -0.5,
    };
    const lanes: [8]i32 = truncateLanes(8, values);
    for (values, lanes) |v, lane| try testing.expectEqual(truncate(v), lane);
}
