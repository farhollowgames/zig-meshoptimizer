# Port status

The port of meshoptimizer v1.3 (`f0a684f`), file by file. States: **not
started**; **ported** (written, compiles); **oracle-tested** (matches the
original byte for byte in `test/oracle.zig`, and the original's own tests
for it pass in `test/suite.zig`); **benchmarked** (timed against the
original in `bench/bench.zig`, same or better).

Loomwork's bake calls `generateVertexRemap`, `remapVertexBuffer`,
`remapIndexBuffer`, `optimizeVertexCache`, `buildMeshletsBound`,
`buildMeshlets` and `optimizeMeshlet`.

| upstream file | functions | state |
| --- | --- | --- |
| allocator.cpp | `meshopt_setAllocator` (a `std.mem.Allocator` argument), `meshopt_Allocator` (`Scratch`) | ported |
| allocator.cpp | `meshopt_setAllocatorCache` | not started |
| quantization.cpp, meshoptimizer.h | `quantizeUnorm`, `quantizeSnorm`, `quantizeHalf`, `quantizeFloat`, `dequantizeHalf`, `computePositionExponent` | ported |
| indexgenerator.cpp | `generateVertexRemap`, `generateVertexRemapMulti`, `generateVertexRemapCustom`, `remapVertexBuffer`, `remapIndexBuffer` | ported |
| indexgenerator.cpp | `filterIndexBuffer`, `filterIndexBufferMulti`, `generateShadowIndexBuffer`, `generateShadowIndexBufferMulti`, `generatePositionRemap` | ported |
| indexgenerator.cpp | `generateAdjacencyIndexBuffer`, `generateTessellationIndexBuffer`, `generateProvokingIndexBuffer` | ported |
| vcacheoptimizer.cpp | `optimizeVertexCache`, `optimizeVertexCacheStrip`, `optimizeVertexCacheFifo` | not started |
| clusterizer.cpp | `buildMeshletsBound`, `buildMeshlets`, `buildMeshletsFlex`, `buildMeshletsSpatial`, `buildMeshletsScan` | not started |
| meshletutils.cpp | `optimizeMeshlet`, `optimizeMeshletLevel`, `computeClusterBounds`, `computeMeshletBounds`, `computeSphereBounds`, `extractMeshletIndices` | not started |
| vertexcodec.cpp | `encodeVertexBuffer`, `encodeVertexBufferLevel`, `encodeVertexBufferBound`, `encodeVertexVersion`, `decodeVertexBuffer` (scalar and SIMD), `decodeVertexVersion` | not started |
| indexcodec.cpp | `encodeIndexBuffer`, `encodeIndexBufferBound`, `encodeIndexVersion`, `decodeIndexBuffer`, `decodeIndexVersion`, `encodeIndexSequence`, `encodeIndexSequenceBound`, `decodeIndexSequence` | not started |
| meshletcodec.cpp | `encodeMeshlet`, `encodeMeshletBound`, `decodeMeshlet`, `decodeMeshletRaw` | not started |
| vertexfilter.cpp | `encodeFilterOct`, `encodeFilterQuat`, `encodeFilterExp`, `encodeFilterColor`, `decodeFilterOct`, `decodeFilterQuat`, `decodeFilterExp`, `decodeFilterColor` (scalar and SIMD) | not started |
| overdrawoptimizer.cpp | `optimizeOverdraw` | not started |
| vfetchoptimizer.cpp | `optimizeVertexFetch`, `optimizeVertexFetchRemap` | not started |
| indexanalyzer.cpp | `analyzeVertexCache`, `analyzeVertexFetch` | not started |
| rasterizer.cpp | `analyzeOverdraw`, `analyzeCoverage` | not started |
| stripifier.cpp | `stripify`, `stripifyBound`, `unstripify`, `unstripifyBound` | not started |
| spatialorder.cpp | `spatialSortRemap`, `spatialSortTriangles`, `spatialClusterPoints` | not started |
| simplifier.cpp | `simplify`, `simplifyWithAttributes`, `simplifyWithUpdate`, `simplifySloppy`, `simplifyPrune`, `simplifyPoints`, `simplifyScale`, every option and vertex lock flag | not started |
| partition.cpp | `partitionClusters` | not started |
| opacitymap.cpp | `opacityMapMeasure` (levels 0 to 12 from texture size, max level and target edge; micromaps shared by triangles with equal texture coordinates) | benchmarked |
| opacitymap.cpp | `opacityMapRasterize` (levels 0 to 12; textures of 1 to 4 channels, any pitch) | oracle-tested; 1.0 to 1.16 times the original's time |
| opacitymap.cpp | `opacityMapEntrySize` | oracle-tested |
| opacitymap.cpp | `opacityMapCompact` (equal micromaps merged, uniform ones turned into special indices) | oracle-tested |
| opacitymap.cpp | formats: two-state (`OpacityMapFormat.two_state`), four-state (`four_state`) | oracle-tested; rasterized as above |
| tangentspace.cpp | `generateTangents`; options `TangentCompatible` (`compatible`), `TangentZeroFallback` (`zero_fallback`) | benchmarked |
| tangentspace.cpp | `generateNormals`; crease angles 0 to pi, smoothing 0 to any (passes capped at 10) | benchmarked |
| remesher.cpp | `remesh` (resolutions 4 to 256; no destination: the bound; a destination: the exact count, cut off at its capacity) | benchmarked |
| remesher.cpp | options `RemeshShell` (`shell`), `RemeshSolve` (`solve`) | benchmarked |
| remesher.cpp | the original's hidden internal debug bit 30 (`internal_debug`, not in meshoptimizer.h) | oracle-tested |
| meshoptimizer.h | C++ index-type template wrappers (16-bit indices) | not started |
