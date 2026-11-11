//! Oracle tests: the port against the original meshoptimizer, built from
//! the pinned upstream sources, on the same inputs: the original's demo
//! mesh, generated meshes and fuzzed ones. Every output must be the same,
//! byte for byte; floats compare bit for bit.

comptime {
    _ = @import("quantization_test.zig");
    _ = @import("indexgenerator_test.zig");
    _ = @import("indexcodec_test.zig");
    _ = @import("meshletcodec_test.zig");
}
