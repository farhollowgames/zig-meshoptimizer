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
        // NaN and out-of-range values by itself.
        const avx = comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx);
        return asm ((if (avx) "vcvttss2si" else "cvttss2si") ++ " %[v], %[r]"
            : [r] "=r" (-> i32),
            : [v] "x" (v),
        );
    }
    if (v >= -2147483648.0 and v < 2147483648.0) return @intFromFloat(v);
    return std.math.minInt(i32);
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
