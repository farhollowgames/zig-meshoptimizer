//! Oracle tests: the port against the original meshoptimizer, built from
//! the pinned upstream sources, on the same inputs: the original's demo
//! mesh, generated meshes and fuzzed ones. Every output must be the same,
//! byte for byte; floats compare bit for bit.

comptime {
    _ = @import("quantization_test.zig");
    _ = @import("indexgenerator_test.zig");
    _ = @import("vcacheoptimizer_test.zig");
    _ = @import("clusterizer_test.zig");
    _ = @import("meshletutils_test.zig");
    _ = @import("partition_test.zig");
}
