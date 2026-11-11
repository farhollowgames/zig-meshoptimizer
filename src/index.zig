//! The index types of index buffers.

/// Fails to compile unless `Index` is `u16` or `u32`, the index types the
/// library's functions take, as GPUs do.
pub fn check(comptime Index: type) void {
    if (Index != u16 and Index != u32) {
        @compileError("indices are u16 or u32, not " ++ @typeName(Index));
    }
}
