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
| allocator.cpp | `meshopt_setAllocatorCache` (`AllocatorCache`, an allocator the caller makes over a backing allocator and passes, with a `Local` handle per thread): up to 64 blocks, sizes rounded down to 16 bytes, the size clamp on overflow, the block a handle held last or else the lowest free one, the original's fit test and 16-byte steps, the backing allocator for what does not fit, for alignment above 16 and when every block is taken; `deinit` with every block back | benchmarked (simplify on the demo mesh through both caches, 1.00x) |
| allocator.cpp | zero-length scratch arrays: the original passes a request of 0 bytes to its callbacks or cache, where it takes 16 bytes of the block; the port's `Scratch` asks for nothing, as `std.mem.Allocator` hands out empty slices without a call, so for inputs with an empty scratch array (empty meshes) the backing allocator can see fewer calls | differs, for the author |
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
| indexcodec.cpp | `encodeIndexBuffer`, `encodeIndexBufferBound`, `encodeIndexVersion` (an `IndexVersion` argument), `decodeIndexBuffer` (`u16` and `u32`), `decodeIndexVersion`, `encodeIndexSequence`, `encodeIndexSequenceBound`, `decodeIndexSequence` (`u16` and `u32`) | benchmarked |
| meshletcodec.cpp | `encodeMeshlet`, `encodeMeshletBound`, `decodeMeshlet` (every vertex and triangle size, SIMD and scalar), `decodeMeshletRaw` (SIMD and scalar) | oracle-tested |
| vcacheoptimizer.cpp | `optimizeVertexCache`, `optimizeVertexCacheStrip`, `optimizeVertexCacheFifo` | not started |
| clusterizer.cpp | `buildMeshletsBound`, `buildMeshlets`, `buildMeshletsFlex`, `buildMeshletsSpatial`, `buildMeshletsScan` | not started |
| meshletutils.cpp | `optimizeMeshlet`, `optimizeMeshletLevel`, `computeClusterBounds`, `computeMeshletBounds`, `computeSphereBounds`, `extractMeshletIndices` | not started |
| vertexcodec.cpp | `encodeVertexBuffer` (level 2, version 1) | benchmarked |
| vertexcodec.cpp | `encodeVertexBufferLevel`: levels 0 to 3 (4 to 9 encode as 3), versions 0 and 1 | oracle-tested; levels 1 to 3 benchmarked, level 0 up to 1.17x and version 0 up to 1.23x slower (the per-group bit choice) |
| vertexcodec.cpp | `encodeVertexBufferBound` | oracle-tested |
| vertexcodec.cpp | `encodeVertexVersion`: a `version` argument, default `.v1` (the C global stays in test/capi.zig) | oracle-tested |
| vertexcodec.cpp | channel encodings: byte deltas, 16-bit deltas, rotated xor deltas (chosen at levels 2 and 3, the rotation at 3) | oracle-tested |
| vertexcodec.cpp | control modes: bit groups 0/1/2/4 and 1/2/4/8, zeros, literals; version 0's bit groups 0/2/4/8 | oracle-tested |
| vertexcodec.cpp | `decodeVertexBuffer`, scalar decoder (against the original built without SIMD) | oracle-tested |
| vertexcodec.cpp | `decodeVertexBuffer`, SSSE3 decoder | oracle-tested |
| vertexcodec.cpp | `decodeVertexBuffer`, AVX-512 VBMI2 decoder | oracle-tested; 1.00x to 1.04x the original's time |
| vertexcodec.cpp | `decodeVertexBuffer`, AArch64 NEON decoder (tested on x86 with pshufb for tbl; not run on ARM) | oracle-tested |
| vertexcodec.cpp | `decodeVertexBuffer` errors: invalid header, invalid data, length mismatch | oracle-tested |
| vertexcodec.cpp | `decodeVertexVersion` | oracle-tested |
| vertexcodec.cpp | left out: Wasm SIMD and 32-bit ARM NEON decoders (the scalar decoder there); x86 run-time SSSE3 detection (`SIMD_FALLBACK`; chosen at compile time from the target, so baseline x86-64 gets scalar); `MESHOPTIMIZER_VERTEXCODEC_ZEROCOPY`, `MESHOPTIMIZER_VERTEXCODEC_SIMDNOLOPT` and `TRACE` (build options with the same output); NEON's recomputed delta base on Apple and Windows (the same values by a shorter dependency chain) | not started |
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
| partition.cpp | `partitionClusters` with positions | benchmarked |
| partition.cpp | `partitionClusters` without positions, by shared vertices only; every `target_partition_size` | oracle-tested |
| simplifier.cpp | `simplify` | oracle-tested |
| simplifier.cpp | `simplifyWithAttributes`: 0 to 32 attributes, any weights, vertex flags | oracle-tested |
| simplifier.cpp | `simplifyWithUpdate`: positions and attributes moved in place | oracle-tested |
| simplifier.cpp | `simplifyEdge` (`meshopt_simplifyEdge`, exported but not in the header): the internal solve into another destination, the internal debug bits | oracle-tested |
| simplifier.cpp | options `lock_border`, `sparse`, `error_absolute`, `prune`, `regularize`, `permissive`, `regularize_light`, `preserve_folds`, `error_clamped`, alone and in all 512 combinations | oracle-tested |
| simplifier.cpp | vertex flags `lock`, `protect`, `priority`, alone and combined, other bits ignored | oracle-tested |
| simplifier.cpp | `simplifySloppy`, with and without vertex locks | oracle-tested |
| simplifier.cpp | `simplifyPrune` | oracle-tested |
| simplifier.cpp | `simplifyPoints`, with and without colors | oracle-tested |
| simplifier.cpp | `simplifyScale` | oracle-tested |
| partition.cpp | `partitionClusters` | not started |
| opacitymap.cpp | `opacityMapMeasure`, `opacityMapRasterize`, `opacityMapEntrySize`, `opacityMapCompact` | not started |
| tangentspace.cpp | `generateTangents`, `generateNormals` | not started |
| remesher.cpp | `remesh` | not started |
| meshoptimizer.h | C++ index-type template wrappers (16-bit indices) | not started |
