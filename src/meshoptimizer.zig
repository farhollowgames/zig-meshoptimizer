//! meshoptimizer in pure Zig: mesh optimization for GPU rendering, and
//! compression and simplification of meshes.
//!
//! A translation of Arseny Kapoulkine's meshoptimizer 1.3. Every function
//! of the original is here under its name without the `meshopt_` prefix,
//! and returns the same results for the same inputs, byte for byte. Buffers
//! are slices; per-vertex floats are `VertexFloats` views; functions that
//! need scratch memory take a `std.mem.Allocator` first and free all of it
//! before they return.

const std = @import("std");

pub const allocator = @import("allocator.zig");
pub const Scratch = allocator.Scratch;

pub const strided = @import("strided.zig");
pub const VertexFloats = strided.VertexFloats;
pub const VertexFloatsMut = strided.VertexFloatsMut;

pub const quantization = @import("quantization.zig");
pub const quantizeUnorm = quantization.quantizeUnorm;
pub const quantizeSnorm = quantization.quantizeSnorm;
pub const quantizeHalf = quantization.quantizeHalf;
pub const quantizeFloat = quantization.quantizeFloat;
pub const dequantizeHalf = quantization.dequantizeHalf;
pub const computePositionExponent = quantization.computePositionExponent;

pub const indexgenerator = @import("indexgenerator.zig");
pub const Stream = indexgenerator.Stream;
pub const generateVertexRemap = indexgenerator.generateVertexRemap;
pub const generateVertexRemapMulti = indexgenerator.generateVertexRemapMulti;
pub const generateVertexRemapCustom = indexgenerator.generateVertexRemapCustom;
pub const remapVertexBuffer = indexgenerator.remapVertexBuffer;
pub const remapIndexBuffer = indexgenerator.remapIndexBuffer;
pub const filterIndexBuffer = indexgenerator.filterIndexBuffer;
pub const filterIndexBufferMulti = indexgenerator.filterIndexBufferMulti;
pub const generateShadowIndexBuffer = indexgenerator.generateShadowIndexBuffer;
pub const generateShadowIndexBufferMulti = indexgenerator.generateShadowIndexBufferMulti;
pub const generatePositionRemap = indexgenerator.generatePositionRemap;
pub const generateAdjacencyIndexBuffer = indexgenerator.generateAdjacencyIndexBuffer;
pub const generateTessellationIndexBuffer = indexgenerator.generateTessellationIndexBuffer;
pub const generateProvokingIndexBuffer = indexgenerator.generateProvokingIndexBuffer;

pub const remesher = @import("remesher.zig");
pub const RemeshOptions = remesher.RemeshOptions;
pub const remesh = remesher.remesh;

test {
    std.testing.refAllDecls(@This());
    _ = @import("convert.zig");
}
