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
| demo/clusterlod.h | `clodConfig` (`clusterlod.Config`, the original's field names), `clodDefaultConfig`, `clodDefaultConfigRT` (`defaultConfig`, `defaultConfigRT`), every `max_triangles` from 4 to 256 | oracle-tested |
| demo/clusterlod.h | `clodBuild` (`build`): `clodMesh` as `Mesh` (slices and `VertexFloats`), the output callback as a context's `output` method returning `i32` or an error union, whose error stops the build | oracle-tested; benchmarked with `defaultConfig(128)`, `defaultConfigRT(128)` up to 1.05x slower (in `buildMeshletsSpatial`'s split and the simplifier) |
| demo/clusterlod.h | `build` limits: `max_vertices` 3 to 256, `min_triangles` and `max_triangles` 1 to 512 | oracle-tested |
| demo/clusterlod.h | `partition_spatial` | oracle-tested |
| demo/clusterlod.h | `partition_sort` | oracle-tested |
| demo/clusterlod.h | `partition_size`, from 1, groups past 32 clusters included | oracle-tested |
| demo/clusterlod.h | `cluster_spatial`, `cluster_fill_weight` | oracle-tested |
| demo/clusterlod.h | `cluster_split_factor` | oracle-tested |
| demo/clusterlod.h | `simplify_ratio`, 0 to 1 | oracle-tested |
| demo/clusterlod.h | `simplify_threshold`, below 1 | oracle-tested |
| demo/clusterlod.h | `simplify_error_merge_previous`, `simplify_error_merge_additive` | oracle-tested |
| demo/clusterlod.h | `simplify_error_factor_sloppy` | oracle-tested |
| demo/clusterlod.h | `simplify_error_edge_limit` | oracle-tested |
| demo/clusterlod.h | `simplify_error_clamped` | oracle-tested |
| demo/clusterlod.h | `simplify_permissive` | oracle-tested |
| demo/clusterlod.h | `simplify_fallback_permissive`, with the zeros the original's vector resize leaves when the permissive count is the larger | oracle-tested |
| demo/clusterlod.h | `simplify_fallback_sloppy` | oracle-tested |
| demo/clusterlod.h | `simplify_regularize` | oracle-tested |
| demo/clusterlod.h | `simplify_preserve_folds` | oracle-tested |
| demo/clusterlod.h | `simplify_dilate_borders`, writing through `Mesh.positions_mut` (the original casts away `const`) | oracle-tested |
| demo/clusterlod.h | `optimize_bounds` | oracle-tested |
| demo/clusterlod.h | `optimize_clusters`, `optimize_clusters_level` 0 to 9 (a `u4`) | oracle-tested |
| demo/clusterlod.h | mesh inputs: attributes in the vertices or a buffer of their own, up to 16 weighed; `attribute_protect_mask`; `vertex_lock` flags `lock`, `protect` and `priority`; position strides from 3 to 64 floats; vertices no triangle uses | oracle-tested |
| demo/clusterlod.h | ids from output, recorded as `Cluster.refined`: any `i32`, -1 among them (as for the mesh's own triangles) | oracle-tested |
| demo/clusterlod.h | `clodLocalIndices` (`localIndices`) | oracle-tested |
| demo/clusterlod.h | `clodBuildHierarchyBound`, `clodBuildHierarchy` (`buildHierarchyBound`, `buildHierarchy`), node widths 2 to 80 | benchmarked |
| demo/clusterlod.h | left out: `clodBuild` without an output callback (a context whose `output` returns -1 does the same); the C++ template overload for lambdas (any context with `output`); NaN, infinite or overflowing positions, on which `computeClusterBounds` asserts (the original too, with asserts on); an `attribute_protect_mask` with attribute strides of 32 floats or more, where the original shifts past 31 bits (undefined) and the port reads attributes 0 to 31 | not started |
