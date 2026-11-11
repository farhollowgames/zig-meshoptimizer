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

pub const overdrawoptimizer = @import("overdrawoptimizer.zig");
pub const optimizeOverdraw = overdrawoptimizer.optimizeOverdraw;

pub const vfetchoptimizer = @import("vfetchoptimizer.zig");
pub const optimizeVertexFetch = vfetchoptimizer.optimizeVertexFetch;
pub const optimizeVertexFetchRemap = vfetchoptimizer.optimizeVertexFetchRemap;

pub const indexanalyzer = @import("indexanalyzer.zig");
pub const VertexCacheStatistics = indexanalyzer.VertexCacheStatistics;
pub const VertexFetchStatistics = indexanalyzer.VertexFetchStatistics;
pub const analyzeVertexCache = indexanalyzer.analyzeVertexCache;
pub const analyzeVertexFetch = indexanalyzer.analyzeVertexFetch;

pub const rasterizer = @import("rasterizer.zig");
pub const OverdrawStatistics = rasterizer.OverdrawStatistics;
pub const CoverageStatistics = rasterizer.CoverageStatistics;
pub const analyzeOverdraw = rasterizer.analyzeOverdraw;
pub const analyzeCoverage = rasterizer.analyzeCoverage;

pub const stripifier = @import("stripifier.zig");
pub const stripify = stripifier.stripify;
pub const stripifyBound = stripifier.stripifyBound;
pub const unstripify = stripifier.unstripify;
pub const unstripifyBound = stripifier.unstripifyBound;

pub const spatialorder = @import("spatialorder.zig");
pub const spatialSortRemap = spatialorder.spatialSortRemap;
pub const spatialSortTriangles = spatialorder.spatialSortTriangles;
pub const spatialClusterPoints = spatialorder.spatialClusterPoints;
pub const vcacheoptimizer = @import("vcacheoptimizer.zig");
pub const VertexScoreTable = vcacheoptimizer.VertexScoreTable;
pub const optimizeVertexCache = vcacheoptimizer.optimizeVertexCache;
pub const optimizeVertexCacheStrip = vcacheoptimizer.optimizeVertexCacheStrip;
pub const optimizeVertexCacheFifo = vcacheoptimizer.optimizeVertexCacheFifo;
pub const optimizeVertexCacheTable = vcacheoptimizer.optimizeVertexCacheTable;

pub const clusterizer = @import("clusterizer.zig");
pub const Meshlet = clusterizer.Meshlet;
pub const buildMeshletsBound = clusterizer.buildMeshletsBound;
pub const buildMeshlets = clusterizer.buildMeshlets;
pub const buildMeshletsScan = clusterizer.buildMeshletsScan;
pub const buildMeshletsFlex = clusterizer.buildMeshletsFlex;
pub const buildMeshletsSpatial = clusterizer.buildMeshletsSpatial;

pub const meshletutils = @import("meshletutils.zig");
pub const Bounds = meshletutils.Bounds;
pub const optimizeMeshlet = meshletutils.optimizeMeshlet;
pub const optimizeMeshletLevel = meshletutils.optimizeMeshletLevel;
pub const computeClusterBounds = meshletutils.computeClusterBounds;
pub const computeMeshletBounds = meshletutils.computeMeshletBounds;
pub const computeSphereBounds = meshletutils.computeSphereBounds;
pub const extractMeshletIndices = meshletutils.extractMeshletIndices;

pub const partition = @import("partition.zig");
pub const partitionClusters = partition.partitionClusters;
pub const indexcodec = @import("indexcodec.zig");
pub const IndexVersion = indexcodec.IndexVersion;
pub const IndexDecodeError = indexcodec.DecodeError;
pub const encodeIndexBuffer = indexcodec.encodeIndexBuffer;
pub const encodeIndexBufferBound = indexcodec.encodeIndexBufferBound;
pub const decodeIndexBuffer = indexcodec.decodeIndexBuffer;
pub const decodeIndexVersion = indexcodec.decodeIndexVersion;
pub const encodeIndexSequence = indexcodec.encodeIndexSequence;
pub const encodeIndexSequenceBound = indexcodec.encodeIndexSequenceBound;
pub const decodeIndexSequence = indexcodec.decodeIndexSequence;

pub const meshletcodec = @import("meshletcodec.zig");
pub const MeshletDecodeError = meshletcodec.DecodeError;
pub const encodeMeshlet = meshletcodec.encodeMeshlet;
pub const encodeMeshletBound = meshletcodec.encodeMeshletBound;
pub const decodeMeshlet = meshletcodec.decodeMeshlet;
pub const decodeMeshletRaw = meshletcodec.decodeMeshletRaw;

test {
    std.testing.refAllDecls(@This());
    _ = @import("convert.zig");
}
