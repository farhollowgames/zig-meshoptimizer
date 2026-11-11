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
| vcacheoptimizer.cpp | `optimizeVertexCache` | benchmarked |
| vcacheoptimizer.cpp | `optimizeVertexCacheStrip` | benchmarked |
| vcacheoptimizer.cpp | `optimizeVertexCacheFifo`, every `cache_size` from 3 | benchmarked |
| vcacheoptimizer.cpp | `meshopt_optimizeVertexCacheTable` (not in meshoptimizer.h; its tests declare it) as `optimizeVertexCacheTable` with `VertexScoreTable` | oracle-tested |
| vcacheoptimizer.cpp | each optimizer in place (`destination` is `indices`) | oracle-tested |
| clusterizer.cpp | `meshopt_Meshlet` (`Meshlet`), `buildMeshletsBound` | oracle-tested |
| clusterizer.cpp | `buildMeshlets`, `cone_weight` 0 to 1 | benchmarked |
| clusterizer.cpp | `buildMeshletsScan` | benchmarked |
| clusterizer.cpp | `buildMeshletsFlex`: `min_triangles` to `max_triangles`, `cone_weight`, `split_factor` | benchmarked |
| clusterizer.cpp | `buildMeshletsSpatial`, `fill_weight`, with the SSE box merge (x86) | benchmarked |
| clusterizer.cpp | `buildMeshletsSpatial` without SIMD (`MESHOPTIMIZER_NO_SIMD`, other targets), on finite positions | oracle-tested |
| clusterizer.cpp | `buildMeshletsSpatial` with the NEON box merge (aarch64) | ported |
| clusterizer.cpp | limits up to `max_vertices` 256 and `max_triangles` 512; position strides from 12 to 256 bytes | oracle-tested |
| clusterizer.cpp | `MESHOPTIMIZER_CLUSTERIZER_INDEXLIMIT`, an undocumented compile-time define that repeats vertices so each triangle's local indices stay within 32 of the meshlet's newest; upstream's builds leave it off | left out, for the author |
| meshletutils.cpp | `optimizeMeshlet` | benchmarked |
| meshletutils.cpp | `optimizeMeshletLevel`, levels 0 to 9 | benchmarked |
| meshletutils.cpp | `meshopt_Bounds` (`Bounds`), `computeClusterBounds`, `computeMeshletBounds` | benchmarked |
| meshletutils.cpp | `computeSphereBounds`, of points and of spheres (`radii`) | benchmarked |
| meshletutils.cpp | `extractMeshletIndices` | benchmarked |
| vertexcodec.cpp | `encodeVertexBuffer`, `encodeVertexBufferLevel`, `encodeVertexBufferBound`, `encodeVertexVersion`, `decodeVertexBuffer` (scalar and SIMD), `decodeVertexVersion` | not started |
| indexcodec.cpp | `encodeIndexBuffer`, `encodeIndexBufferBound`, `encodeIndexVersion`, `decodeIndexBuffer`, `decodeIndexVersion`, `encodeIndexSequence`, `encodeIndexSequenceBound`, `decodeIndexSequence` | not started |
| meshletcodec.cpp | `encodeMeshlet`, `encodeMeshletBound`, `decodeMeshlet`, `decodeMeshletRaw` | not started |
| vertexfilter.cpp | `decodeFilterOct`, strides 4 and 8, with the SSE kernels (x86; 8, 16 lanes with AVX2, AVX-512) | benchmarked |
| vertexfilter.cpp | `decodeFilterQuat`, with the SSE kernel (x86) | benchmarked |
| vertexfilter.cpp | `decodeFilterExp`, every stride, with the SSE kernel (x86) | benchmarked |
| vertexfilter.cpp | `decodeFilterColor`, strides 4 and 8, with the SSE kernels (x86) | benchmarked |
| vertexfilter.cpp | each decoder without SIMD (`MESHOPTIMIZER_NO_SIMD`, other targets), every stride | oracle-tested |
| vertexfilter.cpp | each decoder with the NEON kernels (aarch64), which compile but have not run on an aarch64 machine | ported |
| vertexfilter.cpp | 8-bit `decodeFilterOct` and `decodeFilterColor` on Zig's own x86 backend (Debug), which cannot assemble `rsqrtps` and `rcpps`: they take the scalar path, whose bytes differ from the SSE kernels' as the original's do | oracle-tested |
| vertexfilter.cpp | `encodeFilterOct`, strides 4 and 8, `bits` 2 to 16 | benchmarked |
| vertexfilter.cpp | `encodeFilterQuat`, `bits` 4 to 16 | oracle-tested; 3 to 4% slower than the original |
| vertexfilter.cpp | `encodeFilterExp`, `meshopt_EncodeExpMode` (`EncodeExpMode`) `separate`, `shared_vector`, `shared_component`, `clamped`, `bits` 1 to 24, in place (`destination` is `data`) | oracle-tested; 3 to 13% slower than the original |
| vertexfilter.cpp | `encodeFilterColor`, strides 4 and 8, `bits` 2 to 16 | benchmarked |
| vertexfilter.cpp | the Wasm SIMD kernels, and the NEON kernels on 32-bit ARM (those targets take the scalar path) | left out, for the author |
| overdrawoptimizer.cpp | `optimizeOverdraw` | not started |
| vfetchoptimizer.cpp | `optimizeVertexFetch`, `optimizeVertexFetchRemap` | not started |
| indexanalyzer.cpp | `analyzeVertexCache`, `analyzeVertexFetch` | not started |
| rasterizer.cpp | `analyzeOverdraw`, `analyzeCoverage` | not started |
| stripifier.cpp | `stripify`, `stripifyBound`, `unstripify`, `unstripifyBound` | not started |
| spatialorder.cpp | `spatialSortRemap`, `spatialSortTriangles`, `spatialClusterPoints` | not started |
| simplifier.cpp | `simplify`, `simplifyWithAttributes`, `simplifyWithUpdate`, `simplifySloppy`, `simplifyPrune`, `simplifyPoints`, `simplifyScale`, every option and vertex lock flag | not started |
| partition.cpp | `partitionClusters` with positions | benchmarked |
| partition.cpp | `partitionClusters` without positions, by shared vertices only; every `target_partition_size` | oracle-tested |
| opacitymap.cpp | `opacityMapMeasure`, `opacityMapRasterize`, `opacityMapEntrySize`, `opacityMapCompact` | not started |
| tangentspace.cpp | `generateTangents`, `generateNormals` | not started |
| remesher.cpp | `remesh` | not started |
| meshoptimizer.h | C++ index-type template wrappers (16-bit indices) | not started |
