# Port status

The port of meshoptimizer v1.3 (`f0a684f`): every function, option and mode
of `src/meshoptimizer.h`, the functions upstream exports outside it, and
`demo/clusterlod.h`, each with its state. States:

- **not started**
- **ported**: written and compiling, but not run against the original
  (none left).
- **oracle-tested**: returns what the original returns, byte for byte and
  floats bit for bit, in `test/oracle.zig`: on the demo mesh, generated
  meshes, edge cases (empty, one element, the largest sizes, degenerate
  input) and at least 1000 seeded fuzz cases, rerun into differently filled
  outputs; decoders also on truncated, corrupted and random bytes. The
  original's own tests for it pass in `test/suite.zig`. Code for aarch64
  runs under QEMU against the original built for aarch64
  ([doc/TESTING.md](doc/TESTING.md)).
- **benchmarked**: oracle-tested, and in `zig build bench` the port's median
  time is at most 1.05 of the original's on every case (the run in
  [doc/BENCHMARKS.md](doc/BENCHMARKS.md)). Rows slower than that stay
  oracle-tested and give their times; doc/BENCHMARKS.md says why.
- **reviewed**: checked by a reviewer after the tuning pass (none yet).

Loomwork's bake calls `generateVertexRemap`, `remapVertexBuffer`,
`remapIndexBuffer`, `optimizeVertexCache`, `buildMeshletsBound`,
`buildMeshlets` and `optimizeMeshlet`.

Times below are the port's over the original's, on the demo mesh and on the
large mesh.

## Index generation (indexgenerator.cpp)

| function, option or mode | state |
| --- | --- |
| `generateVertexRemap`, with and without an index buffer | benchmarked |
| `generateVertexRemapMulti` (`Stream`s) | oracle-tested; 1.07 and 1.09 |
| `generateVertexRemapCustom` (a comparison callback, as a comptime context) | benchmarked |
| `remapVertexBuffer`, also in place | benchmarked |
| `remapIndexBuffer`, with and without an index buffer, also in place | benchmarked |
| `filterIndexBuffer` | oracle-tested; 0.96 and 1.13 |
| `filterIndexBufferMulti` | oracle-tested; 0.99 and 1.08 |
| `generateShadowIndexBuffer` | benchmarked |
| `generateShadowIndexBufferMulti` | benchmarked |
| `generatePositionRemap` | benchmarked |
| `generateAdjacencyIndexBuffer` | benchmarked |
| `generateTessellationIndexBuffer` | benchmarked |
| `generateProvokingIndexBuffer` | benchmarked |

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
| `encodeIndexSequence`, versions 0 and 1 | oracle-tested; 1.07 and 1.02 |
| `encodeIndexSequenceBound` | oracle-tested |
| `decodeIndexSequence`, 16- and 32-bit indices, every error | benchmarked |

## Meshlet codec (meshletcodec.cpp)

| function, option or mode | state |
| --- | --- |
| `encodeMeshlet` | benchmarked |
| `encodeMeshletBound` | oracle-tested |
| `decodeMeshlet`, every vertex and triangle element size, SIMD path (x86) and scalar path, every error (`MeshletDecodeError`) | benchmarked |
| `decodeMeshletRaw`, SIMD path (x86) and scalar path | oracle-tested; 1.07 and 1.06 |
| `decodeMeshlet` and `decodeMeshletRaw` with NEON (aarch64) | oracle-tested, under QEMU |

## Vertex codec (vertexcodec.cpp)

| function, option or mode | state |
| --- | --- |
| `encodeVertexBuffer` (level 2, version 1) | benchmarked |
| `encodeVertexBufferLevel`, levels 1 to 3 (4 to 9 encode as 3) | benchmarked |
| `encodeVertexBufferLevel`, level 0 | benchmarked |
| version 0 encoding (`VertexVersion`, in place of `meshopt_encodeVertexVersion`) | oracle-tested; 1.10 encoding the sphere, 0.95 to 1.05 elsewhere |
| channel encodings: byte deltas, 16-bit deltas, rotated xor deltas | oracle-tested |
| control modes: bit groups 0/1/2/4 and 1/2/4/8, zeros, literals; version 0's 0/2/4/8 | oracle-tested |
| `encodeVertexBufferBound` | oracle-tested |
| `decodeVertexBuffer`, scalar decoder | oracle-tested |
| `decodeVertexBuffer`, SSSE3 decoder | oracle-tested |
| `decodeVertexBuffer` in Debug builds, whose x86 backend builds no SIMD decoders: the scalar decoder, whose error codes on malformed buffers follow the original's scalar build | oracle-tested |
| `decodeVertexBuffer`, AVX-512 VBMI2 decoder (the test machine's) | benchmarked |
| `decodeVertexBuffer`, AArch64 NEON decoder, under QEMU; on x86 too, with `pshufb` for `tbl`, on the encoder's streams. A malformed buffer's 2- or 4-bit group of 16 sentinels advances it 16 bytes less than the other decoders, as in the original's NEON build, so its result there can differ from theirs | oracle-tested |
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
| each decoder's NEON kernels (aarch64) | oracle-tested, under QEMU |
| 8-bit `decodeFilterOct` and `decodeFilterColor` in Debug builds, whose x86 backend cannot assemble `rsqrtps` and `rcpps`: the scalar path, whose bytes differ from the SSE kernels' as the original's two builds do | oracle-tested |
| `encodeFilterOct`, strides 4 and 8, `bits` 2 to 16 | benchmarked |
| `encodeFilterQuat`, `bits` 4 to 16 | benchmarked |
| `encodeFilterExp`, `EncodeExpMode` `separate` and `shared_component`, `bits` 1 to 24, also in place | benchmarked |
| `encodeFilterExp`, modes `shared_vector` and `clamped` | benchmarked |
| `encodeFilterColor`, strides 4 and 8, `bits` 2 to 16 | benchmarked |

## Simplification (simplifier.cpp)

| function, option or mode | state |
| --- | --- |
| `simplify` | oracle-tested; 1.01 and 1.07 |
| `simplifyWithAttributes`: 0 to 32 attributes, any weights, vertex flags | oracle-tested; 1.08 and 1.10 |
| `simplifyWithUpdate`: positions and attributes updated in place | oracle-tested; 1.06 and 1.04 |
| `simplifyEdge` (`meshopt_simplifyEdge`, exported but not in the header): its internal solve and debug bits | oracle-tested |
| `SimplifyOptions`: `lock_border`, `sparse`, `error_absolute`, `prune`, `regularize`, `permissive`, `regularize_light`, `preserve_folds`, `error_clamped`, alone and in all 512 combinations | oracle-tested |
| `SimplifyVertexFlags`: `lock`, `protect`, `priority`, alone and combined, other bits ignored | oracle-tested |
| `simplifySloppy`, with and without vertex locks | benchmarked |
| `simplifyPrune` | benchmarked |
| `simplifyPoints`, with and without colors | benchmarked |
| `simplifyScale` | oracle-tested |

## Strips (stripifier.cpp)

| function, option or mode | state |
| --- | --- |
| `stripify`, restart index 0 or none | benchmarked |
| `stripifyBound` | oracle-tested |
| `unstripify`, with and without a restart index | oracle-tested; 1.35 (a 5 µs case with a 91% spread) and 0.82 |
| `unstripifyBound` | oracle-tested |

## Analysis (indexanalyzer.cpp, rasterizer.cpp)

| function, option or mode | state |
| --- | --- |
| `analyzeVertexCache` (`VertexCacheStatistics`), any cache, warp and primitive group size | benchmarked |
| `analyzeVertexFetch` (`VertexFetchStatistics`) | oracle-tested; 1.17 and 1.08 |
| `analyzeOverdraw` (`OverdrawStatistics`) | benchmarked |
| `analyzeCoverage` (`CoverageStatistics`) | benchmarked |

## Meshlets (clusterizer.cpp, meshletutils.cpp, partition.cpp)

| function, option or mode | state |
| --- | --- |
| `Meshlet`, `buildMeshletsBound` | oracle-tested |
| `buildMeshlets`, `cone_weight` 0 to 1 | benchmarked |
| `buildMeshletsScan` | benchmarked |
| `buildMeshletsFlex`: `min_triangles` to `max_triangles`, `cone_weight`, `split_factor` | benchmarked |
| `buildMeshletsSpatial`, `fill_weight`, with the SSE box merge (x86) | oracle-tested; 1.03 and 1.09 |
| `buildMeshletsSpatial` without SIMD (other targets), on finite positions | oracle-tested |
| `buildMeshletsSpatial` with the NEON box merge (aarch64) | oracle-tested, under QEMU |
| limits up to `max_vertices` 256 and `max_triangles` 512; position strides from 12 to 256 bytes | oracle-tested |
| `optimizeMeshlet` | oracle-tested; 1.04 and 1.08 |
| `optimizeMeshletLevel`, levels 0 to 9 | benchmarked |
| `Bounds`, `computeClusterBounds` | benchmarked |
| `computeMeshletBounds` | benchmarked |
| `computeSphereBounds`, of points and of spheres (`radii`) | benchmarked |
| `extractMeshletIndices` | benchmarked |
| `partitionClusters`, with and without positions, every `target_partition_size` | oracle-tested; 1.01 and 1.06 |

## Spatial order (spatialorder.cpp)

| function, option or mode | state |
| --- | --- |
| `spatialSortRemap` | benchmarked |
| `spatialSortTriangles` | benchmarked |
| `spatialClusterPoints`, any cluster size | benchmarked |

## Tangent space (tangentspace.cpp)

| function, option or mode | state |
| --- | --- |
| `generateTangents`; `TangentOptions` `compatible` and `zero_fallback` | benchmarked |
| `generateNormals`; crease angles 0 to pi, smoothing 0 and up (passes capped at 10) | benchmarked |
| `cosf`, which the crease test calls, as the port's own function (`src/cosf.zig`, translated from Arm's optimized-routines, which glibc's is built from; matches glibc on every float) | oracle-tested |

## Remeshing (remesher.cpp)

| function, option or mode | state |
| --- | --- |
| `remesh`, resolutions 4 to 256; without a destination, the bound; with one, the exact count, cut off at its capacity | oracle-tested; 1.04 to 1.06 on the demo mesh, 0.89 to 0.96 on the sphere |
| `RemeshOptions` `shell` | benchmarked |
| `RemeshOptions` `solve` | oracle-tested; 1.06 to 1.09 on the demo mesh, 0.93 to 0.98 on the sphere |
| the hidden debug bit 30, not in the header: no named field, read from `reserved` as the original reads it | oracle-tested |

## Opacity micromaps (opacitymap.cpp)

| function, option or mode | state |
| --- | --- |
| `opacityMapMeasure`: levels 0 to 12 from texture size, maximum level and target edge; equal texture coordinates share a micromap | benchmarked |
| `opacityMapRasterize`: levels 0 to 12, textures of 1 to 4 channels and any pitch (`AlphaTexture`) | oracle-tested; 1.16 and 1.06 on the demo mesh, 0.92 to 1.01 at levels 10 and 12 |
| `OpacityMapFormat` `two_state` and `four_state` | oracle-tested |
| `opacityMapEntrySize` | oracle-tested |
| `opacityMapCompact`: equal micromaps merged, uniform ones turned into special indices | oracle-tested |
| `log2f`, which the level choice calls, as the port's own function (`src/log2f.zig`, translated from Arm's optimized-routines, which glibc's is built from; matches glibc on every float) | oracle-tested |

## Quantization (quantization.cpp, meshoptimizer.h)

| function, option or mode | state |
| --- | --- |
| `quantizeUnorm`, `quantizeSnorm` (the header's inline functions), every bit count | oracle-tested; 4.85 and 5.12 as a loop of calls, which Zig leaves scalar |
| `quantizeUnorm`, `quantizeSnorm` on vectors of floats (an addition: each lane as the scalar form gives it) | benchmarked; 1.00 and 1.00 on 16 lanes |
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
| zero-length scratch arrays (empty meshes): the original asks its callbacks or cache for 0 bytes, which its cache rounds up to 16; the port's `Scratch` asks for nothing, as `std.mem.Allocator` hands out empty slices without a call, so the backing allocator can see fewer calls | differs (approved) |

## Cluster LOD (demo/clusterlod.h)

| function, option or mode | state |
| --- | --- |
| `clodConfig` (`clusterlod.Config`, the original's field names), `clodDefaultConfig`, `clodDefaultConfigRT` (`defaultConfig`, `defaultConfigRT`), every `max_triangles` from 4 to 256 | oracle-tested |
| `clodBuild` (`build`): `clodMesh` as `Mesh` (slices and `VertexFloats`), the output callback as a context's `output` method returning `i32` or an error union, whose error stops the build | benchmarked |
| `build` limits: `max_vertices` 3 to 256, `min_triangles` and `max_triangles` 1 to 512 | oracle-tested |
| `partition_spatial` | oracle-tested |
| `partition_sort` | oracle-tested |
| `partition_size`, from 1, groups past 32 clusters included | oracle-tested |
| `cluster_spatial`, `cluster_fill_weight` | oracle-tested |
| `cluster_split_factor` | oracle-tested |
| `simplify_ratio`, 0 to 1 | oracle-tested |
| `simplify_threshold`, below 1 | oracle-tested |
| `simplify_error_merge_previous`, `simplify_error_merge_additive` | oracle-tested |
| `simplify_error_factor_sloppy` | oracle-tested |
| `simplify_error_edge_limit` | oracle-tested |
| `simplify_error_clamped` | oracle-tested |
| `simplify_permissive` | oracle-tested |
| `simplify_fallback_permissive`, with the zeros the original's vector resize leaves when the permissive count is the larger | oracle-tested |
| `simplify_fallback_sloppy` | oracle-tested |
| `simplify_regularize` | oracle-tested |
| `simplify_preserve_folds` | oracle-tested |
| `simplify_dilate_borders`, writing through `Mesh.positions_mut` (the original casts away `const`) | oracle-tested |
| `optimize_bounds` | oracle-tested |
| `optimize_clusters`, `optimize_clusters_level` 0 to 9 (a `u4`) | oracle-tested |
| mesh inputs: attributes in the vertices or a buffer of their own, up to 16 weighed; `attribute_protect_mask`; `vertex_lock` flags `lock`, `protect` and `priority`; position strides from 3 to 64 floats; vertices no triangle uses | oracle-tested |
| ids from output, recorded as `Cluster.refined`: any `i32`, -1 among them (as for the mesh's own triangles) | oracle-tested |
| `clodLocalIndices` (`localIndices`) | oracle-tested |
| `clodBuildHierarchyBound`, `clodBuildHierarchy` (`buildHierarchyBound`, `buildHierarchy`), node widths 2 to 80 | benchmarked |

## The header

| function, option or mode | state |
| --- | --- |
| `MESHOPTIMIZER_VERSION` (`version`) | oracle-tested |
| the C++ templates for 16-bit indices, and `meshopt_IndexAdapter`: every function the original templates takes its index type as a comptime parameter, `u16` or `u32` | oracle-tested, against the original's 16-bit templates |
| the templates for other index types (the original's accept any integer type) | left out (approved scope: `u16` and `u32`, the index types GPUs take) |

## Left out

Each approved by the author.

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
- **Cluster LOD**: `clodBuild` without an output callback (a context whose `output` returns -1 does the same); the C++ template overload for lambdas (any context with `output`); NaN, infinite or overflowing positions, on which `computeClusterBounds` asserts (the original too, with asserts on); an `attribute_protect_mask` with attribute strides of 32 floats or more, where the original shifts past 31 bits (undefined) and the port reads attributes 0 to 31.

## Differences from the original

[`doc/parity.md`](doc/parity.md) lists where the port's output or
interface differs from the original's, and why.
