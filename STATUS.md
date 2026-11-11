# Port status

The port of meshoptimizer v1.3 (`f0a684f`): every function, option and mode
of `src/meshoptimizer.h`, the functions upstream exports outside it, and
`demo/clusterlod.h`, each with its state. States:

- **not started**
- **ported**: written and compiling, but not run against the original here
  (code for other CPUs).
- **oracle-tested**: returns what the original returns, byte for byte and
  floats bit for bit, in `test/oracle.zig`: on the demo mesh, generated
  meshes, edge cases (empty, one element, the largest sizes, degenerate
  input) and at least 1000 seeded fuzz cases, rerun into differently filled
  outputs; decoders also on truncated, corrupted and random bytes. The
  original's own tests for it pass in `test/suite.zig`.
- **benchmarked**: oracle-tested, and in `zig build bench` the port's median
  time is at most 1.05 of the original's on every case (the run in the
  README). Rows slower than that stay oracle-tested and give their times;
  the README says why.
- **reviewed**: checked by a reviewer after the tuning pass (none yet).

Loomwork's bake calls `generateVertexRemap`, `remapVertexBuffer`,
`remapIndexBuffer`, `optimizeVertexCache`, `buildMeshletsBound`,
`buildMeshlets` and `optimizeMeshlet`.

Times below are the port's over the original's, on the demo mesh and on the
large mesh.

## Index generation (indexgenerator.cpp)

| function, option or mode | state |
| --- | --- |
| `generateVertexRemap`, with and without an index buffer | oracle-tested; 1.10 and 1.02 |
| `generateVertexRemapMulti` (`Stream`s) | oracle-tested; 1.16 and 1.14 |
| `generateVertexRemapCustom` (a comparison callback, as a comptime context) | benchmarked |
| `remapVertexBuffer`, also in place | benchmarked |
| `remapIndexBuffer`, with and without an index buffer, also in place | oracle-tested; 2.50 and 2.16 without an index buffer |
| `filterIndexBuffer` | oracle-tested; 1.01 and 1.20 |
| `filterIndexBufferMulti` | oracle-tested; 1.01 and 1.12 |
| `generateShadowIndexBuffer` | oracle-tested; 1.46 and 1.29 |
| `generateShadowIndexBufferMulti` | oracle-tested; 1.12 and 1.15 |
| `generatePositionRemap` | benchmarked |
| `generateAdjacencyIndexBuffer` | benchmarked |
| `generateTessellationIndexBuffer` | benchmarked |
| `generateProvokingIndexBuffer` | oracle-tested; 1.04 and 1.14 |

## Vertex cache optimization (vcacheoptimizer.cpp)

| function, option or mode | state |
| --- | --- |
| `optimizeVertexCache`, also in place | benchmarked |
| `optimizeVertexCacheStrip`, also in place | benchmarked |
| `optimizeVertexCacheFifo`, every `cache_size` from 3, also in place | benchmarked |
| `optimizeVertexCacheTable` with `VertexScoreTable` (`meshopt_optimizeVertexCacheTable`, exported but not in the header; the original's tests declare it) | oracle-tested |

## Overdraw and vertex fetch (overdrawoptimizer.cpp, vfetchoptimizer.cpp)

| function, option or mode | state |
| --- | --- |
| `optimizeOverdraw`, any `threshold` | benchmarked |
| `optimizeVertexFetch`, also in place | benchmarked |
| `optimizeVertexFetchRemap` | benchmarked |

## Index codec (indexcodec.cpp)

| function, option or mode | state |
| --- | --- |
| `encodeIndexBuffer`, versions 0 and 1 (`IndexVersion`, in place of `meshopt_encodeIndexVersion`) | benchmarked |
| `encodeIndexBufferBound` | oracle-tested |
| `decodeIndexBuffer`, 16- and 32-bit indices, every error (`IndexDecodeError`) | benchmarked |
| `decodeIndexVersion` | oracle-tested |
| `encodeIndexSequence`, versions 0 and 1 | benchmarked |
| `encodeIndexSequenceBound` | oracle-tested |
| `decodeIndexSequence`, 16- and 32-bit indices, every error | benchmarked |

## Meshlet codec (meshletcodec.cpp)

| function, option or mode | state |
| --- | --- |
| `encodeMeshlet` | benchmarked |
| `encodeMeshletBound` | oracle-tested |
| `decodeMeshlet`, every vertex and triangle element size, SIMD path (x86) and scalar path, every error (`MeshletDecodeError`) | benchmarked |
| `decodeMeshletRaw`, SIMD path (x86) and scalar path | oracle-tested; 1.08 and 1.07 |
| `decodeMeshlet` and `decodeMeshletRaw` with NEON (aarch64) | ported |

## Vertex codec (vertexcodec.cpp)

| function, option or mode | state |
| --- | --- |
| `encodeVertexBuffer` (level 2, version 1) | benchmarked |
| `encodeVertexBufferLevel`, levels 1 to 3 (4 to 9 encode as 3) | benchmarked |
| `encodeVertexBufferLevel`, level 0 | oracle-tested; 1.15 and 1.03 |
| version 0 encoding (`VertexVersion`, in place of `meshopt_encodeVertexVersion`) | oracle-tested; 1.10 and 1.22 |
| channel encodings: byte deltas, 16-bit deltas, rotated xor deltas | oracle-tested |
| control modes: bit groups 0/1/2/4 and 1/2/4/8, zeros, literals; version 0's 0/2/4/8 | oracle-tested |
| `encodeVertexBufferBound` | oracle-tested |
| `decodeVertexBuffer`, scalar decoder | oracle-tested |
| `decodeVertexBuffer`, SSSE3 decoder | oracle-tested |
| `decodeVertexBuffer`, AVX-512 VBMI2 decoder (the test machine's) | oracle-tested; 1.02 to 1.06 |
| `decodeVertexBuffer`, AArch64 NEON decoder (its shuffles checked on x86 with `pshufb` for `tbl`) | ported |
| `decodeVertexBuffer` errors: invalid header, invalid data, length mismatch (`DecodeVertexError`) | oracle-tested |
| `decodeVertexVersion` | oracle-tested |

## Vertex filters (vertexfilter.cpp)

| function, option or mode | state |
| --- | --- |
| `decodeFilterOct`, strides 4 and 8, SSE kernels (8 and 16 lanes with AVX2 and AVX-512) | benchmarked |
| `decodeFilterQuat`, SSE kernel | benchmarked |
| `decodeFilterExp`, every stride, SSE kernel | benchmarked |
| `decodeFilterColor`, strides 4 and 8, SSE kernels | benchmarked |
| each decoder's scalar path (other targets), every stride | oracle-tested |
| each decoder's NEON kernels (aarch64) | ported |
| 8-bit `decodeFilterOct` and `decodeFilterColor` in Debug builds, whose x86 backend cannot assemble `rsqrtps` and `rcpps`: the scalar path, whose bytes differ from the SSE kernels' as the original's two builds do | oracle-tested |
| `encodeFilterOct`, strides 4 and 8, `bits` 2 to 16 | benchmarked |
| `encodeFilterQuat`, `bits` 4 to 16 | benchmarked |
| `encodeFilterExp`, `EncodeExpMode` `separate` and `shared_component`, `bits` 1 to 24, also in place | benchmarked |
| `encodeFilterExp`, modes `shared_vector` and `clamped` | oracle-tested; 1.08 and 1.11 |
| `encodeFilterColor`, strides 4 and 8, `bits` 2 to 16 | benchmarked |

## Simplification (simplifier.cpp)

| function, option or mode | state |
| --- | --- |
| `simplify` | benchmarked |
| `simplifyWithAttributes`: 0 to 32 attributes, any weights, vertex flags | oracle-tested; 1.07 and 1.04 |
| `simplifyWithUpdate`: positions and attributes updated in place | oracle-tested; 1.06 and 1.05 |
| `simplifyEdge` (`meshopt_simplifyEdge`, exported but not in the header): its internal solve and debug bits | oracle-tested |
| `SimplifyOptions`: `lock_border`, `sparse`, `error_absolute`, `prune`, `regularize`, `permissive`, `regularize_light`, `preserve_folds`, `error_clamped`, alone and in all 512 combinations | oracle-tested |
| `SimplifyVertexFlags`: `lock`, `protect`, `priority`, alone and combined, other bits ignored | oracle-tested |
| `simplifySloppy`, with and without vertex locks | oracle-tested; 1.09 and 1.11 |
| `simplifyPrune` | benchmarked |
| `simplifyPoints`, with and without colors | oracle-tested; 1.19 and 1.15 |
| `simplifyScale` | oracle-tested |

## Strips (stripifier.cpp)

| function, option or mode | state |
| --- | --- |
| `stripify`, restart index 0 or none | benchmarked |
| `stripifyBound` | oracle-tested |
| `unstripify`, with and without a restart index | benchmarked |
| `unstripifyBound` | oracle-tested |

## Analysis (indexanalyzer.cpp, rasterizer.cpp)

| function, option or mode | state |
| --- | --- |
| `analyzeVertexCache` (`VertexCacheStatistics`), any cache, warp and primitive group size | benchmarked |
| `analyzeVertexFetch` (`VertexFetchStatistics`) | oracle-tested; 1.09 and 1.05 |
| `analyzeOverdraw` (`OverdrawStatistics`) | benchmarked |
| `analyzeCoverage` (`CoverageStatistics`) | benchmarked |

## Meshlets (clusterizer.cpp, meshletutils.cpp, partition.cpp)

| function, option or mode | state |
| --- | --- |
| `Meshlet`, `buildMeshletsBound` | oracle-tested |
| `buildMeshlets`, `cone_weight` 0 to 1 | benchmarked |
| `buildMeshletsScan` | benchmarked |
| `buildMeshletsFlex`: `min_triangles` to `max_triangles`, `cone_weight`, `split_factor` | benchmarked |
| `buildMeshletsSpatial`, `fill_weight`, with the SSE box merge (x86) | oracle-tested; 1.04 and 1.09 |
| `buildMeshletsSpatial` without SIMD (other targets), on finite positions | oracle-tested |
| `buildMeshletsSpatial` with the NEON box merge (aarch64) | ported |
| limits up to `max_vertices` 256 and `max_triangles` 512; position strides from 12 to 256 bytes | oracle-tested |
| `optimizeMeshlet` | benchmarked |
| `optimizeMeshletLevel`, levels 0 to 9 | benchmarked |
| `Bounds`, `computeClusterBounds` | benchmarked |
| `computeMeshletBounds` | oracle-tested; 0.94 and 1.11 |
| `computeSphereBounds`, of points and of spheres (`radii`) | oracle-tested; 1.05 to 1.13 |
| `extractMeshletIndices` | oracle-tested; 1.08 (a 6 µs case with a 39% spread) and 0.68 |
| `partitionClusters`, with and without positions, every `target_partition_size` | oracle-tested; 1.04 and 1.06 |

## Spatial order (spatialorder.cpp)

| function, option or mode | state |
| --- | --- |
| `spatialSortRemap` | oracle-tested; 1.19 and 1.17 |
| `spatialSortTriangles` | oracle-tested; 1.10 and 1.07 |
| `spatialClusterPoints`, any cluster size | benchmarked |

## Tangent space (tangentspace.cpp)

| function, option or mode | state |
| --- | --- |
| `generateTangents`; `TangentOptions` `compatible` and `zero_fallback` | benchmarked |
| `generateNormals`; crease angles 0 to pi, smoothing 0 and up (passes capped at 10) | benchmarked |
| glibc's `cosf`, which the crease test calls, as the port's own function (matches glibc on every float from 0 to pi) | oracle-tested |

## Remeshing (remesher.cpp)

| function, option or mode | state |
| --- | --- |
| `remesh`, resolutions 4 to 256; without a destination, the bound; with one, the exact count, cut off at its capacity | benchmarked |
| `RemeshOptions` `shell` | benchmarked |
| `RemeshOptions` `solve` | oracle-tested; 1.04 to 1.06 and 0.91 to 0.93 |
| the hidden debug bit 30 (`internal_debug`, not in the header) | oracle-tested |

## Opacity micromaps (opacitymap.cpp)

| function, option or mode | state |
| --- | --- |
| `opacityMapMeasure`: levels 0 to 12 from texture size, maximum level and target edge; equal texture coordinates share a micromap | benchmarked |
| `opacityMapRasterize`: levels 0 to 12, textures of 1 to 4 channels and any pitch (`AlphaTexture`) | oracle-tested; 1.12 to 1.16 on the demo mesh, 1.00 to 1.06 at levels 10 and 12 |
| `OpacityMapFormat` `two_state` and `four_state` | oracle-tested |
| `opacityMapEntrySize` | oracle-tested |
| `opacityMapCompact`: equal micromaps merged, uniform ones turned into special indices | oracle-tested |
| glibc's `log2f`, which the level choice calls, as the port's own function (matches glibc on every float from 1 up) | oracle-tested |

## Quantization (quantization.cpp, meshoptimizer.h)

| function, option or mode | state |
| --- | --- |
| `quantizeUnorm`, `quantizeSnorm` (the header's inline functions), every bit count | oracle-tested; 3.91 and 4.47 |
| `quantizeHalf`, on every float | benchmarked |
| `dequantizeHalf`, on every half | benchmarked |
| `quantizeFloat`, every bit count | benchmarked |
| `computePositionExponent` | benchmarked |

## Allocation (allocator.cpp)

| function, option or mode | state |
| --- | --- |
| `meshopt_setAllocator`: every function that needs memory takes a `std.mem.Allocator`; the original's suite counts its allocations through its own hooks | oracle-tested |
| `meshopt_Allocator`: `Scratch`, the same allocations in the same order, freed newest first | oracle-tested |
| `meshopt_setAllocatorCache`: `AllocatorCache`, an allocator the caller makes over a backing allocator and passes, with a `Local` handle per thread; up to 64 blocks, sizes rounded down to 16 bytes, the size clamp on overflow, the block a handle held last or else the lowest free one, the original's fit test and 16-byte steps, the backing allocator for what does not fit, for alignment above 16 and when every block is taken; `deinit` with every block back; the same backing calls as the original's cache | benchmarked |
| zero-length scratch arrays (empty meshes): the original asks its callbacks or cache for 0 bytes, which its cache rounds up to 16; the port's `Scratch` asks for nothing, as `std.mem.Allocator` hands out empty slices without a call, so the backing allocator can see fewer calls | differs, for the author |

## Cluster LOD (demo/clusterlod.h)

| function, option or mode | state |
| --- | --- |
| `clodBuild`, `clodDefaultConfig`, `clodDefaultConfigRT`, `clodLocalIndices`, `clodBuildHierarchyBound`, `clodBuildHierarchy`, every config option | not started |

## The header

| function, option or mode | state |
| --- | --- |
| `MESHOPTIMIZER_VERSION` (`version`) | oracle-tested |
| the C++ templates for 16-bit and other index types, and `meshopt_IndexAdapter` | left out, for the author: the port's functions take `u32` indices (the decoders also `u16`) |

## Left out, for the author

- **Wasm SIMD and 32-bit ARM NEON paths** of the vertex codec, the vertex
  filters and the meshlet codec: those targets take the scalar paths, which
  give the same bytes as the original's scalar build.
- **x86 run-time SSSE3 detection** in the vertex codec (`SIMD_FALLBACK`):
  the port chooses its decoder at compile time from the target, so a
  baseline x86-64 build decodes with the scalar path.
- **Build switches**: `MESHOPTIMIZER_NO_SIMD` (the target's features choose
  the path; no switch forces the scalar one), `MESHOPTIMIZER_ALLOC_NOCACHE`,
  `MESHOPTIMIZER_ALLOC_EXPORT`, `MESHOPTIMIZER_ALLOC_CALLCONV`,
  `MESHOPTIMIZER_NO_WRAPPERS`, `MESHOPTIMIZER_API` and
  `MESHOPTIMIZER_EXPERIMENTAL` (C linkage and allocator plumbing the port
  has no use for); `MESHOPTIMIZER_VERTEXCODEC_ZEROCOPY`,
  `MESHOPTIMIZER_VERTEXCODEC_SIMDNOLOPT`, `MESHOPTIMIZER_VERTEXFILTER_SIMDNOTAIL`
  and the vertex codec's `TRACE` (speed and debugging switches with the same
  output); `MESHOPTIMIZER_CLUSTERIZER_INDEXLIMIT`, an undocumented switch
  that repeats vertices so each triangle's local indices stay within 32 of
  the meshlet's newest, off in upstream's builds.
- **The NEON vertex decoder's recomputed delta base on Apple and Windows**:
  the same values by a shorter dependency chain.
- **The C++ index-type templates**, above.
