//! meshoptimizer's own test suite, demo/tests.cpp of the pinned upstream,
//! against the port: each test in the order its runTests() runs them, the
//! vertex codec ones once per encoder version. A failed check aborts with the
//! original's assert message.

comptime {
    _ = @import("capi.zig");
}

const std = @import("std");

/// The original's source files, which name the port's modules.
const Module = enum {
    allocator,
    clusterizer,
    indexanalyzer,
    indexcodec,
    indexgenerator,
    meshletcodec,
    meshletutils,
    opacitymap,
    overdrawoptimizer,
    partition,
    quantization,
    rasterizer,
    remesher,
    simplifier,
    spatialorder,
    stripifier,
    tangentspace,
    vcacheoptimizer,
    vertexcodec,
    vertexfilter,
    vfetchoptimizer,
};

/// The modules ported so far; tests that need any other are skipped.
const ported = [_]Module{
    .allocator,
    .quantization,
    .indexgenerator,
    .overdrawoptimizer,
    .vfetchoptimizer,
    .indexanalyzer,
    .rasterizer,
    .stripifier,
    .spatialorder,
    .vcacheoptimizer,
    .clusterizer,
    .meshletutils,
    .partition,
    .indexcodec,
    .meshletcodec,
    .vertexcodec,
};

fn needs(modules: []const Module) !void {
    for (modules) |m| {
        if (std.mem.indexOfScalar(Module, &ported, m) == null) return error.SkipZigTest;
    }
}

extern fn suite_decodeIndexV0() void;
extern fn suite_decodeIndexV1() void;
extern fn suite_decodeIndexV1More() void;
extern fn suite_decodeIndexV1ThreeEdges() void;
extern fn suite_decodeIndex16() void;
extern fn suite_encodeIndexMemorySafe() void;
extern fn suite_decodeIndexMemorySafe() void;
extern fn suite_decodeIndexRejectExtraBytes() void;
extern fn suite_decodeIndexRejectMalformedHeaders() void;
extern fn suite_decodeIndexRejectInvalidVersion() void;
extern fn suite_decodeIndexMalformedVByte() void;
extern fn suite_roundtripIndexTricky() void;
extern fn suite_encodeIndexEmpty() void;
extern fn suite_decodeIndexSequence() void;
extern fn suite_decodeIndexSequence16() void;
extern fn suite_encodeIndexSequenceMemorySafe() void;
extern fn suite_decodeIndexSequenceMemorySafe() void;
extern fn suite_decodeIndexSequenceRejectExtraBytes() void;
extern fn suite_decodeIndexSequenceRejectMalformedHeaders() void;
extern fn suite_decodeIndexSequenceRejectInvalidVersion() void;
extern fn suite_encodeIndexSequenceEmpty() void;
extern fn suite_decodeVertexV0() void;
extern fn suite_decodeVertexV0More() void;
extern fn suite_decodeVertexV0Mode2() void;
extern fn suite_decodeVertexV1() void;
extern fn suite_decodeVertexV1Custom() void;
extern fn suite_decodeVertexV1Deltas() void;
extern fn suite_decodeVertexMemorySafe(version: c_int) void;
extern fn suite_decodeVertexRejectExtraBytes(version: c_int) void;
extern fn suite_decodeVertexRejectMalformedHeaders(version: c_int) void;
extern fn suite_decodeVertexBitGroups(version: c_int) void;
extern fn suite_decodeVertexBitGroupSentinels(version: c_int) void;
extern fn suite_decodeVertexBitGroupSentinelCount(version: c_int) void;
extern fn suite_decodeVertexDeltas(version: c_int) void;
extern fn suite_decodeVertexBitXor(version: c_int) void;
extern fn suite_decodeVertexLarge(version: c_int) void;
extern fn suite_decodeVertexSmall(version: c_int) void;
extern fn suite_encodeVertexEmpty(version: c_int) void;
extern fn suite_encodeVertexMemorySafe(version: c_int) void;
extern fn suite_decodeVersion() void;
extern fn suite_decodeFilterOct8() void;
extern fn suite_decodeFilterOct12() void;
extern fn suite_decodeFilterQuat12() void;
extern fn suite_decodeFilterExp() void;
extern fn suite_encodeFilterOct8() void;
extern fn suite_encodeFilterOct12() void;
extern fn suite_encodeFilterQuat12() void;
extern fn suite_encodeFilterExp() void;
extern fn suite_encodeFilterExpZero() void;
extern fn suite_encodeFilterExpOverflow() void;
extern fn suite_encodeFilterExpZeroShared() void;
extern fn suite_encodeFilterExpAlias() void;
extern fn suite_encodeFilterExpClamp() void;
extern fn suite_encodeFilterColor8() void;
extern fn suite_encodeFilterColor12() void;
extern fn suite_clusterBoundsDegenerate() void;
extern fn suite_sphereBounds() void;
extern fn suite_extractMeshlet() void;
extern fn suite_meshletsEmpty() void;
extern fn suite_meshletsDense() void;
extern fn suite_meshletsSparse() void;
extern fn suite_meshletsFlex() void;
extern fn suite_meshletsMax() void;
extern fn suite_meshletsSpatial() void;
extern fn suite_meshletsSpatialDeep() void;
extern fn suite_partitionBasic() void;
extern fn suite_partitionSpatial() void;
extern fn suite_partitionSpatialMerge() void;
extern fn suite_remapCustom() void;
extern fn suite_customAllocator() void;
extern fn suite_customAllocatorCache() void;
extern fn suite_emptyMesh() void;
extern fn suite_simplify() void;
extern fn suite_simplifyStuck() void;
extern fn suite_simplifySloppyStuck() void;
extern fn suite_simplifySloppyLocks() void;
extern fn suite_simplifyPointsStuck() void;
extern fn suite_simplifyFlip() void;
extern fn suite_simplifyScale() void;
extern fn suite_simplifyDegenerate() void;
extern fn suite_simplifyLockBorder() void;
extern fn suite_simplifyAttr(arg: c_int) void;
extern fn suite_simplifyLockFlags() void;
extern fn suite_simplifyLockFlagsSeam() void;
extern fn suite_simplifySparse() void;
extern fn suite_simplifyErrorAbsolute() void;
extern fn suite_simplifySeam() void;
extern fn suite_simplifySeamFake() void;
extern fn suite_simplifySeamAttr() void;
extern fn suite_simplifyDebug() void;
extern fn suite_simplifyPrune() void;
extern fn suite_simplifyPruneCleanup() void;
extern fn suite_simplifyPruneFunc() void;
extern fn suite_simplifyUpdate() void;
extern fn suite_simplifyUpdateLocked(arg: u32) void;
extern fn suite_simplifyFolds() void;
extern fn suite_filterTriangles() void;
extern fn suite_adjacency() void;
extern fn suite_tessellation() void;
extern fn suite_provoking() void;
extern fn suite_quantizeFloat() void;
extern fn suite_quantizeHalf() void;
extern fn suite_dequantizeHalf() void;
extern fn suite_computePositionExponent() void;
extern fn suite_encodeMeshletBound() void;
extern fn suite_decodeMeshletSafety() void;
extern fn suite_decodeMeshletBasic() void;
extern fn suite_decodeMeshletTypical() void;
extern fn suite_opacityMap() void;
extern fn suite_opacityMapRasterize0() void;
extern fn suite_opacityMapSpecial() void;
extern fn suite_tangentsBasic() void;
extern fn suite_tangentDegenerate() void;
extern fn suite_normalsBasic() void;
extern fn suite_normalsDegenerate() void;

test "decodeIndexV0" {
    try needs(&.{.indexcodec});
    suite_decodeIndexV0();
}

test "decodeIndexV1" {
    try needs(&.{.indexcodec});
    suite_decodeIndexV1();
}

test "decodeIndexV1More" {
    try needs(&.{.indexcodec});
    suite_decodeIndexV1More();
}

test "decodeIndexV1ThreeEdges" {
    try needs(&.{.indexcodec});
    suite_decodeIndexV1ThreeEdges();
}

test "decodeIndex16" {
    try needs(&.{.indexcodec});
    suite_decodeIndex16();
}

test "encodeIndexMemorySafe" {
    try needs(&.{.indexcodec});
    suite_encodeIndexMemorySafe();
}

test "decodeIndexMemorySafe" {
    try needs(&.{.indexcodec});
    suite_decodeIndexMemorySafe();
}

test "decodeIndexRejectExtraBytes" {
    try needs(&.{.indexcodec});
    suite_decodeIndexRejectExtraBytes();
}

test "decodeIndexRejectMalformedHeaders" {
    try needs(&.{.indexcodec});
    suite_decodeIndexRejectMalformedHeaders();
}

test "decodeIndexRejectInvalidVersion" {
    try needs(&.{.indexcodec});
    suite_decodeIndexRejectInvalidVersion();
}

test "decodeIndexMalformedVByte" {
    try needs(&.{.indexcodec});
    suite_decodeIndexMalformedVByte();
}

test "roundtripIndexTricky" {
    try needs(&.{.indexcodec});
    suite_roundtripIndexTricky();
}

test "encodeIndexEmpty" {
    try needs(&.{.indexcodec});
    suite_encodeIndexEmpty();
}

test "decodeIndexSequence" {
    try needs(&.{.indexcodec});
    suite_decodeIndexSequence();
}

test "decodeIndexSequence16" {
    try needs(&.{.indexcodec});
    suite_decodeIndexSequence16();
}

test "encodeIndexSequenceMemorySafe" {
    try needs(&.{.indexcodec});
    suite_encodeIndexSequenceMemorySafe();
}

test "decodeIndexSequenceMemorySafe" {
    try needs(&.{.indexcodec});
    suite_decodeIndexSequenceMemorySafe();
}

test "decodeIndexSequenceRejectExtraBytes" {
    try needs(&.{.indexcodec});
    suite_decodeIndexSequenceRejectExtraBytes();
}

test "decodeIndexSequenceRejectMalformedHeaders" {
    try needs(&.{.indexcodec});
    suite_decodeIndexSequenceRejectMalformedHeaders();
}

test "decodeIndexSequenceRejectInvalidVersion" {
    try needs(&.{.indexcodec});
    suite_decodeIndexSequenceRejectInvalidVersion();
}

test "encodeIndexSequenceEmpty" {
    try needs(&.{.indexcodec});
    suite_encodeIndexSequenceEmpty();
}

test "decodeVertexV0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexV0();
}

test "decodeVertexV0More" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexV0More();
}

test "decodeVertexV0Mode2" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexV0Mode2();
}

test "decodeVertexV1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexV1();
}

test "decodeVertexV1Custom" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexV1Custom();
}

test "decodeVertexV1Deltas" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexV1Deltas();
}

test "decodeVertexMemorySafe, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexMemorySafe(0);
}

test "decodeVertexRejectExtraBytes, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexRejectExtraBytes(0);
}

test "decodeVertexRejectMalformedHeaders, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexRejectMalformedHeaders(0);
}

test "decodeVertexBitGroups, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitGroups(0);
}

test "decodeVertexBitGroupSentinels, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitGroupSentinels(0);
}

test "decodeVertexBitGroupSentinelCount, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitGroupSentinelCount(0);
}

test "decodeVertexDeltas, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexDeltas(0);
}

test "decodeVertexBitXor, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitXor(0);
}

test "decodeVertexLarge, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexLarge(0);
}

test "decodeVertexSmall, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexSmall(0);
}

test "encodeVertexEmpty, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_encodeVertexEmpty(0);
}

test "encodeVertexMemorySafe, vertex codec version 0" {
    try needs(&.{.vertexcodec});
    suite_encodeVertexMemorySafe(0);
}

test "decodeVertexMemorySafe, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexMemorySafe(1);
}

test "decodeVertexRejectExtraBytes, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexRejectExtraBytes(1);
}

test "decodeVertexRejectMalformedHeaders, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexRejectMalformedHeaders(1);
}

test "decodeVertexBitGroups, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitGroups(1);
}

test "decodeVertexBitGroupSentinels, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitGroupSentinels(1);
}

test "decodeVertexBitGroupSentinelCount, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitGroupSentinelCount(1);
}

test "decodeVertexDeltas, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexDeltas(1);
}

test "decodeVertexBitXor, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexBitXor(1);
}

test "decodeVertexLarge, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexLarge(1);
}

test "decodeVertexSmall, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_decodeVertexSmall(1);
}

test "encodeVertexEmpty, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_encodeVertexEmpty(1);
}

test "encodeVertexMemorySafe, vertex codec version 1" {
    try needs(&.{.vertexcodec});
    suite_encodeVertexMemorySafe(1);
}

test "decodeVersion" {
    try needs(&.{ .indexcodec, .vertexcodec });
    suite_decodeVersion();
}

test "decodeFilterOct8" {
    try needs(&.{.vertexfilter});
    suite_decodeFilterOct8();
}

test "decodeFilterOct12" {
    try needs(&.{.vertexfilter});
    suite_decodeFilterOct12();
}

test "decodeFilterQuat12" {
    try needs(&.{.vertexfilter});
    suite_decodeFilterQuat12();
}

test "decodeFilterExp" {
    try needs(&.{.vertexfilter});
    suite_decodeFilterExp();
}

test "encodeFilterOct8" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterOct8();
}

test "encodeFilterOct12" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterOct12();
}

test "encodeFilterQuat12" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterQuat12();
}

test "encodeFilterExp" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterExp();
}

test "encodeFilterExpZero" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterExpZero();
}

test "encodeFilterExpOverflow" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterExpOverflow();
}

test "encodeFilterExpZeroShared" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterExpZeroShared();
}

test "encodeFilterExpAlias" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterExpAlias();
}

test "encodeFilterExpClamp" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterExpClamp();
}

test "encodeFilterColor8" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterColor8();
}

test "encodeFilterColor12" {
    try needs(&.{.vertexfilter});
    suite_encodeFilterColor12();
}

test "clusterBoundsDegenerate" {
    try needs(&.{.meshletutils});
    suite_clusterBoundsDegenerate();
}

test "sphereBounds" {
    try needs(&.{.meshletutils});
    suite_sphereBounds();
}

test "extractMeshlet" {
    try needs(&.{.meshletutils});
    suite_extractMeshlet();
}

test "meshletsEmpty" {
    try needs(&.{.clusterizer});
    suite_meshletsEmpty();
}

test "meshletsDense" {
    try needs(&.{.clusterizer});
    suite_meshletsDense();
}

test "meshletsSparse" {
    try needs(&.{.clusterizer});
    suite_meshletsSparse();
}

test "meshletsFlex" {
    try needs(&.{.clusterizer});
    suite_meshletsFlex();
}

test "meshletsMax" {
    try needs(&.{ .clusterizer, .meshletutils });
    suite_meshletsMax();
}

test "meshletsSpatial" {
    try needs(&.{.clusterizer});
    suite_meshletsSpatial();
}

test "meshletsSpatialDeep" {
    try needs(&.{.clusterizer});
    suite_meshletsSpatialDeep();
}

test "partitionBasic" {
    try needs(&.{.partition});
    suite_partitionBasic();
}

test "partitionSpatial" {
    try needs(&.{.partition});
    suite_partitionSpatial();
}

test "partitionSpatialMerge" {
    try needs(&.{.partition});
    suite_partitionSpatialMerge();
}

test "remapCustom" {
    try needs(&.{.indexgenerator});
    suite_remapCustom();
}

test "customAllocator" {
    try needs(&.{ .allocator, .meshletutils, .vfetchoptimizer });
    suite_customAllocator();
}

test "customAllocatorCache" {
    try needs(&.{ .allocator, .vfetchoptimizer });
    suite_customAllocatorCache();
}

test "emptyMesh" {
    try needs(&.{ .overdrawoptimizer, .vcacheoptimizer });
    suite_emptyMesh();
}

test "simplify" {
    try needs(&.{.simplifier});
    suite_simplify();
}

test "simplifyStuck" {
    try needs(&.{.simplifier});
    suite_simplifyStuck();
}

test "simplifySloppyStuck" {
    try needs(&.{.simplifier});
    suite_simplifySloppyStuck();
}

test "simplifySloppyLocks" {
    try needs(&.{.simplifier});
    suite_simplifySloppyLocks();
}

test "simplifyPointsStuck" {
    try needs(&.{.simplifier});
    suite_simplifyPointsStuck();
}

test "simplifyFlip" {
    try needs(&.{.simplifier});
    suite_simplifyFlip();
}

test "simplifyScale" {
    try needs(&.{.simplifier});
    suite_simplifyScale();
}

test "simplifyDegenerate" {
    try needs(&.{.simplifier});
    suite_simplifyDegenerate();
}

test "simplifyLockBorder" {
    try needs(&.{.simplifier});
    suite_simplifyLockBorder();
}

test "simplifyAttr(false)" {
    try needs(&.{.simplifier});
    suite_simplifyAttr(0);
}

test "simplifyAttr(true)" {
    try needs(&.{.simplifier});
    suite_simplifyAttr(1);
}

test "simplifyLockFlags" {
    try needs(&.{.simplifier});
    suite_simplifyLockFlags();
}

test "simplifyLockFlagsSeam" {
    try needs(&.{.simplifier});
    suite_simplifyLockFlagsSeam();
}

test "simplifySparse" {
    try needs(&.{.simplifier});
    suite_simplifySparse();
}

test "simplifyErrorAbsolute" {
    try needs(&.{.simplifier});
    suite_simplifyErrorAbsolute();
}

test "simplifySeam" {
    try needs(&.{.simplifier});
    suite_simplifySeam();
}

test "simplifySeamFake" {
    try needs(&.{.simplifier});
    suite_simplifySeamFake();
}

test "simplifySeamAttr" {
    try needs(&.{.simplifier});
    suite_simplifySeamAttr();
}

test "simplifyDebug" {
    try needs(&.{.simplifier});
    suite_simplifyDebug();
}

test "simplifyPrune" {
    try needs(&.{.simplifier});
    suite_simplifyPrune();
}

test "simplifyPruneCleanup" {
    try needs(&.{.simplifier});
    suite_simplifyPruneCleanup();
}

test "simplifyPruneFunc" {
    try needs(&.{.simplifier});
    suite_simplifyPruneFunc();
}

test "simplifyUpdate" {
    try needs(&.{.simplifier});
    suite_simplifyUpdate();
}

test "simplifyUpdateLocked(0)" {
    try needs(&.{.simplifier});
    suite_simplifyUpdateLocked(0);
}

test "simplifyUpdateLocked(meshopt_SimplifySparse)" {
    try needs(&.{.simplifier});
    suite_simplifyUpdateLocked(1 << 1);
}

test "simplifyFolds" {
    try needs(&.{.simplifier});
    suite_simplifyFolds();
}

test "filterTriangles" {
    try needs(&.{.indexgenerator});
    suite_filterTriangles();
}

test "adjacency" {
    try needs(&.{.indexgenerator});
    suite_adjacency();
}

test "tessellation" {
    try needs(&.{.indexgenerator});
    suite_tessellation();
}

test "provoking" {
    try needs(&.{.indexgenerator});
    suite_provoking();
}

test "quantizeFloat" {
    try needs(&.{.quantization});
    suite_quantizeFloat();
}

test "quantizeHalf" {
    try needs(&.{.quantization});
    suite_quantizeHalf();
}

test "dequantizeHalf" {
    try needs(&.{.quantization});
    suite_dequantizeHalf();
}

test "computePositionExponent" {
    try needs(&.{.quantization});
    suite_computePositionExponent();
}

test "encodeMeshletBound" {
    try needs(&.{.meshletcodec});
    suite_encodeMeshletBound();
}

test "decodeMeshletSafety" {
    try needs(&.{.meshletcodec});
    suite_decodeMeshletSafety();
}

test "decodeMeshletBasic" {
    try needs(&.{.meshletcodec});
    suite_decodeMeshletBasic();
}

test "decodeMeshletTypical" {
    try needs(&.{.meshletcodec});
    suite_decodeMeshletTypical();
}

test "opacityMap" {
    try needs(&.{ .opacitymap, .quantization });
    suite_opacityMap();
}

test "opacityMapRasterize0" {
    try needs(&.{ .opacitymap, .quantization });
    suite_opacityMapRasterize0();
}

test "opacityMapSpecial" {
    try needs(&.{.opacitymap});
    suite_opacityMapSpecial();
}

test "tangentsBasic" {
    try needs(&.{.tangentspace});
    suite_tangentsBasic();
}

test "tangentDegenerate" {
    try needs(&.{.tangentspace});
    suite_tangentDegenerate();
}

test "normalsBasic" {
    try needs(&.{.tangentspace});
    suite_normalsBasic();
}

test "normalsDegenerate" {
    try needs(&.{.tangentspace});
    suite_normalsDegenerate();
}
