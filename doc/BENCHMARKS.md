# Benchmarks

These are measurements on one machine, under the conditions below. They
are not a verdict on either side.

`zig build bench` times the port against the original on the same inputs,
one function at a time, on one thread, and prints a row per case: each
side's median time and spread, the port's time over the original's, and a
throughput where a case says how much one call processes. `zig build bench
-- <text>` runs only the cases whose name holds the text.

The table below combines three runs of the benchmark binary, pinned to one
core:

```sh
zig build bench -- no-such-case      # builds the binary, runs nothing
taskset -c 5 ./.zig-cache/o/<hash>/bench
```

The binary finds the original's shared library through its run path,
relative to the repository's root, so it runs from there.

## Machine and flags

Measured on 11 November 2026 at commit `a57cfbb`, on an AMD Ryzen 9
9950X3D (16 cores) under Linux 7.3.3 (CachyOS), pinned to CPU 5, one of
the eight with the stacked cache. The two `optimizeVertexFetch` rows are
from the next commit, `e45d890`, which changes only that function, in
three runs of their own.

- **The port:** Zig 0.17.0, ReleaseFast, for the machine's own CPU
  (`znver5`).
- **The original:** meshoptimizer 1.3 (`f0a684f`), built from source by
  the clang that Zig 0.17.0 carries (22.1.8), for the same CPU, at `-O3
  -std=c++11 -ffp-contract=off -fno-fast-math -fno-exceptions -fno-rtti`,
  with `NDEBUG`, which Zig sets for optimized C++, so its asserts are
  off, as the port's are in ReleaseFast. It is a shared library, as the
  original is usually linked, so its calls into the C library bind to
  glibc's.
- **Both:** no fused multiply-adds, which the tests need for equal
  outputs; scratch memory from the C library's `malloc`, through
  `std.heap.c_allocator` on the port's side and the original's default
  allocator on its side.

## Method

- Each case runs both sides once as a warm-up, then 11 timed calls of
  each, taking turns, so drift in clock speed and cache state falls on both.
- Each call is timed by the monotonic clock, as wall time. A side's time
  for a case is the median of its 11 calls; its spread is the
  interquartile range as a share of that median.
- Every constant the port's calls take goes through a volatile load, and
  every case's inputs are opaque to the compiler, so LLVM cannot
  specialize the port on the benchmark's sizes and options, which it
  cannot do for the original's separately built library either. Every
  result and output stays observable, so no work is dropped.
- The benchmark ran three times. Each row's time is the median of the
  three runs' medians, and its ratio is the port's time over the
  original's: below 1, the port takes less time. The range is the lowest
  and highest ratio of the three runs.

## Known biases

- **Calls into a shared library.** The original's functions are called
  through the dynamic linker's tables and cannot be inlined into the
  benchmark; the port's can. For a function that does little per call,
  such as `quantizeHalf` on one value, this is most of the difference.
  The header's inline functions (`quantizeUnorm`, `quantizeSnorm`) are
  compiled into the benchmark's C++ shim, so their loops inline as they do
  in a C++ caller.
- **Vectorization.** Zig 0.17 does not vectorize loops by itself, where
  clang does at `-O3`. The port's hot loops are written on `@Vector`s
  where the original's loops vectorize; loops the original relies on
  clang to vectorize and the port does not yet are among the slower rows
  below.
- **The machine was not idle.** Other builds ran on the other half of the
  processor during the runs; the benchmark ran on a core of the half with
  the stacked cache.

## Results

The inputs: `pirate` is the original's demo mesh, a few thousand
triangles; `sphere 1M` is a generated sphere of about a million
triangles (`sphere 262k`, about a quarter million); `1M` rows run on
about a million values. Each mesh's vertices are 32 bytes: a position, a
normal and texture coordinates. Cases with `u16` in their name take
16-bit indices, against the original's 16-bit templates.

Over all 218 cases, the port's time is at most 1.05 of the original's in
192, and below the original's in 140.

| case | original µs | port µs | port ÷ original | range |
| --- | ---: | ---: | ---: | ---: |
| quantizeHalf 1M | 990.3 | 708.8 | 0.72 | 0.53 to 0.72 |
| dequantizeHalf 1M | 1,184 | 568.1 | 0.48 | 0.44 to 0.48 |
| quantizeFloat 1M | 1,583 | 426.8 | 0.27 | 0.27 to 0.31 |
| quantizeUnorm 1M | 70.2 | 340.4 | 4.85 | 4.39 to 6.14 |
| quantizeSnorm 1M | 77.3 | 396.1 | 5.12 | 5.10 to 6.68 |
| quantizeUnorm x16 1M | 74.2 | 74.3 | 1.00 | 1.00 to 1.00 |
| quantizeSnorm x16 1M | 78.0 | 78.2 | 1.00 | 0.99 to 1.02 |
| computePositionExponent 1M | 13,490 | 10,687 | 0.79 | 0.76 to 0.79 |
| generateVertexRemap pirate | 113.6 | 105.0 | 0.92 | 0.92 to 0.96 |
| generateVertexRemapMulti pirate | 177.0 | 188.9 | 1.07 | 1.07 to 1.08 |
| generateVertexRemapCustom pirate | 29.6 | 23.0 | 0.78 | 0.72 to 0.78 |
| remapVertexBuffer pirate | 18.5 | 15.3 | 0.83 | 0.79 to 0.96 |
| remapIndexBuffer pirate | 0.6 | 0.5 | 0.83 | 0.83 to 1.00 |
| generateShadowIndexBuffer pirate | 13.7 | 13.5 | 0.99 | 0.99 to 1.13 |
| generateShadowIndexBufferMulti pirate | 21.6 | 15.5 | 0.72 | 0.68 to 0.73 |
| filterIndexBuffer pirate | 70.9 | 67.8 | 0.96 | 0.96 to 1.00 |
| filterIndexBufferMulti pirate | 51.4 | 51.1 | 0.99 | 0.99 to 1.05 |
| generateProvokingIndexBuffer pirate | 16.5 | 15.9 | 0.96 | 0.95 to 0.99 |
| generateVertexRemap sphere 1M | 24,457 | 23,333 | 0.95 | 0.95 to 1.06 |
| generateVertexRemapMulti sphere 1M | 35,055 | 38,298 | 1.09 | 1.09 to 1.11 |
| generateVertexRemapCustom sphere 1M | 9,285 | 8,052 | 0.87 | 0.86 to 0.87 |
| remapVertexBuffer sphere 1M | 4,974 | 4,665 | 0.94 | 0.93 to 0.94 |
| remapIndexBuffer sphere 1M | 154.6 | 154.6 | 1.00 | 0.99 to 1.00 |
| generateShadowIndexBuffer sphere 1M | 3,186 | 3,050 | 0.96 | 0.95 to 0.96 |
| generateShadowIndexBufferMulti sphere 1M | 3,864 | 3,276 | 0.85 | 0.84 to 0.87 |
| filterIndexBuffer sphere 1M | 9,323 | 10,534 | 1.13 | 1.13 to 1.15 |
| filterIndexBufferMulti sphere 1M | 10,001 | 10,850 | 1.08 | 1.08 to 1.09 |
| generateProvokingIndexBuffer sphere 1M | 2,775 | 2,502 | 0.90 | 0.85 to 0.98 |
| optimizeOverdraw pirate | 66.0 | 64.7 | 0.98 | 0.98 to 0.99 |
| optimizeVertexFetch pirate | 7.0 | 5.6 | 0.80 | 0.78 to 0.80 |
| stripify pirate | 110.5 | 104.5 | 0.95 | 0.91 to 0.97 |
| spatialSortTriangles pirate | 41.2 | 35.5 | 0.86 | 0.86 to 0.86 |
| spatialClusterPoints pirate | 36.3 | 33.3 | 0.92 | 0.91 to 0.92 |
| spatialSortRemap pirate | 20.7 | 18.5 | 0.89 | 0.89 to 0.89 |
| analyzeVertexCache pirate | 7.4 | 7.5 | 1.01 | 1.00 to 1.01 |
| analyzeVertexFetch pirate | 14.2 | 16.6 | 1.17 | 1.11 to 1.17 |
| analyzeOverdraw pirate | 824.4 | 811.7 | 0.98 | 0.96 to 0.99 |
| analyzeCoverage pirate | 820.4 | 803.1 | 0.98 | 0.97 to 0.98 |
| optimizeVertexFetchRemap pirate | 3.7 | 3.1 | 0.84 | 0.83 to 0.85 |
| unstripify pirate | 4.6 | 6.2 | 1.35 | 1.31 to 1.36 |
| generatePositionRemap pirate | 5.9 | 5.1 | 0.86 | 0.85 to 0.91 |
| generateAdjacencyIndexBuffer pirate | 173.8 | 172.2 | 0.99 | 0.99 to 1.00 |
| generateTessellationIndexBuffer pirate | 171.5 | 167.6 | 0.98 | 0.97 to 0.99 |
| optimizeOverdraw sphere 1M | 5,375 | 5,303 | 0.99 | 0.98 to 0.99 |
| optimizeVertexFetch sphere 1M | 1,537 | 1,462 | 0.95 | 0.76 to 0.95 |
| stripify sphere 1M | 14,338 | 12,138 | 0.85 | 0.71 to 0.88 |
| spatialSortTriangles sphere 1M | 10,377 | 9,026 | 0.87 | 0.87 to 0.89 |
| spatialClusterPoints sphere 1M | 11,802 | 11,137 | 0.94 | 0.94 to 0.95 |
| spatialSortRemap sphere 1M | 3,439 | 3,084 | 0.90 | 0.89 to 0.90 |
| analyzeVertexCache sphere 1M | 1,645 | 1,576 | 0.96 | 0.91 to 0.96 |
| analyzeVertexFetch sphere 1M | 3,115 | 3,368 | 1.08 | 1.08 to 1.08 |
| analyzeOverdraw sphere 1M | 27,234 | 26,787 | 0.98 | 0.84 to 0.99 |
| analyzeCoverage sphere 1M | 27,269 | 27,118 | 0.99 | 0.98 to 1.00 |
| optimizeVertexFetchRemap sphere 1M | 632.5 | 537.4 | 0.85 | 0.83 to 0.89 |
| unstripify sphere 1M | 1,399 | 1,144 | 0.82 | 0.82 to 0.90 |
| generatePositionRemap sphere 1M | 3,162 | 3,180 | 1.01 | 1.01 to 1.02 |
| generateAdjacencyIndexBuffer sphere 1M | 75,376 | 76,254 | 1.01 | 1.00 to 1.01 |
| generateTessellationIndexBuffer sphere 1M | 74,363 | 73,280 | 0.99 | 0.98 to 0.99 |
| optimizeVertexCache pirate | 450.8 | 436.9 | 0.97 | 0.96 to 0.98 |
| optimizeVertexCacheStrip pirate | 422.3 | 404.8 | 0.96 | 0.95 to 0.96 |
| optimizeVertexCacheFifo pirate | 92.8 | 93.5 | 1.01 | 1.00 to 1.01 |
| buildMeshlets pirate | 1,316 | 1,128 | 0.86 | 0.86 to 0.86 |
| buildMeshletsScan pirate | 10.3 | 7.9 | 0.77 | 0.77 to 0.78 |
| buildMeshletsFlex pirate | 1,301 | 1,117 | 0.86 | 0.86 to 0.86 |
| buildMeshletsSpatial pirate | 474.8 | 487.6 | 1.03 | 1.03 to 1.04 |
| optimizeMeshlet pirate | 80.7 | 84.2 | 1.04 | 1.04 to 1.09 |
| optimizeMeshletLevel 3 pirate | 464.4 | 443.0 | 0.95 | 0.95 to 0.96 |
| computeMeshletBounds pirate | 61.2 | 46.6 | 0.76 | 0.76 to 0.76 |
| computeClusterBounds pirate | 65.3 | 49.3 | 0.75 | 0.75 to 0.76 |
| extractMeshletIndices pirate | 7.0 | 6.2 | 0.89 | 0.72 to 0.91 |
| computeSphereBounds points pirate | 11.1 | 6.3 | 0.57 | 0.57 to 0.57 |
| computeSphereBounds spheres pirate | 11.1 | 6.4 | 0.58 | 0.57 to 0.58 |
| partitionClusters pirate | 20.0 | 20.2 | 1.01 | 1.01 to 1.02 |
| optimizeVertexCache sphere 1M | 41,158 | 40,908 | 0.99 | 0.98 to 0.99 |
| optimizeVertexCacheStrip sphere 1M | 53,902 | 48,894 | 0.91 | 0.90 to 0.92 |
| optimizeVertexCacheFifo sphere 1M | 10,276 | 9,053 | 0.88 | 0.88 to 0.95 |
| buildMeshlets sphere 1M | 345,719 | 267,152 | 0.77 | 0.77 to 0.78 |
| buildMeshletsScan sphere 1M | 2,186 | 1,776 | 0.81 | 0.81 to 0.84 |
| buildMeshletsFlex sphere 1M | 345,361 | 265,650 | 0.77 | 0.77 to 0.79 |
| buildMeshletsSpatial sphere 1M | 199,562 | 217,058 | 1.09 | 1.04 to 1.09 |
| optimizeMeshlet sphere 1M | 19,098 | 20,568 | 1.08 | 1.07 to 1.09 |
| optimizeMeshletLevel 3 sphere 1M | 97,614 | 94,993 | 0.97 | 0.95 to 0.98 |
| computeMeshletBounds sphere 1M | 13,294 | 12,668 | 0.95 | 0.95 to 0.95 |
| computeClusterBounds sphere 1M | 19,329 | 14,127 | 0.73 | 0.73 to 0.74 |
| extractMeshletIndices sphere 1M | 29,373 | 21,026 | 0.72 | 0.71 to 0.72 |
| computeSphereBounds points sphere 1M | 1,838 | 1,046 | 0.57 | 0.57 to 0.57 |
| computeSphereBounds spheres sphere 1M | 1,855 | 1,076 | 0.58 | 0.58 to 0.58 |
| partitionClusters sphere 1M | 7,622 | 8,100 | 1.06 | 1.06 to 1.09 |
| optimizeVertexCache u16 pirate | 460.1 | 441.7 | 0.96 | 0.96 to 0.96 |
| simplify u16 pirate | 751.3 | 748.7 | 1.00 | 0.96 to 1.00 |
| buildMeshlets u16 pirate | 1,304 | 1,092 | 0.84 | 0.84 to 0.87 |
| encodeIndexBuffer pirate | 3,184 | 3,177 | 1.00 | 0.99 to 1.00 |
| decodeIndexBuffer u32 pirate | 836.6 | 753.9 | 0.90 | 0.90 to 0.91 |
| decodeIndexBuffer u16 pirate | 832.6 | 746.4 | 0.90 | 0.90 to 0.90 |
| encodeIndexSequence pirate | 2,031 | 2,174 | 1.07 | 1.07 to 1.09 |
| decodeIndexSequence pirate | 1,371 | 1,058 | 0.77 | 0.77 to 0.79 |
| encodeMeshlet pirate | 1,409 | 1,384 | 0.98 | 0.97 to 1.05 |
| decodeMeshlet u32/u8 pirate | 313.7 | 304.0 | 0.97 | 0.97 to 1.01 |
| decodeMeshlet u16/u32 pirate | 317.3 | 306.2 | 0.97 | 0.94 to 0.99 |
| decodeMeshletRaw pirate | 299.2 | 320.8 | 1.07 | 1.01 to 1.07 |
| encodeIndexBuffer sphere 1M | 7,330 | 7,193 | 0.98 | 0.98 to 0.99 |
| decodeIndexBuffer u32 sphere 1M | 1,667 | 1,535 | 0.92 | 0.82 to 0.92 |
| decodeIndexBuffer u16 sphere 1M | 1,666 | 1,529 | 0.92 | 0.92 to 1.04 |
| encodeIndexSequence sphere 1M | 4,296 | 4,363 | 1.02 | 1.00 to 1.02 |
| decodeIndexSequence sphere 1M | 4,078 | 2,132 | 0.52 | 0.52 to 0.52 |
| encodeMeshlet sphere 1M | 4,039 | 4,110 | 1.02 | 0.98 to 1.02 |
| decodeMeshlet u32/u8 sphere 1M | 658.0 | 638.6 | 0.97 | 0.97 to 1.00 |
| decodeMeshlet u16/u32 sphere 1M | 667.9 | 639.4 | 0.96 | 0.95 to 0.97 |
| decodeMeshletRaw sphere 1M | 622.5 | 660.0 | 1.06 | 1.02 to 1.07 |
| simplify pirate | 804.3 | 811.0 | 1.01 | 0.99 to 1.01 |
| simplifyWithAttributes pirate | 1,098 | 1,180 | 1.08 | 1.08 to 1.10 |
| simplifyWithUpdate pirate | 1,163 | 1,237 | 1.06 | 1.04 to 1.07 |
| simplifySloppy pirate | 63.0 | 62.9 | 1.00 | 0.99 to 1.01 |
| simplifyPrune pirate | 80.0 | 73.0 | 0.91 | 0.91 to 1.00 |
| simplifyPoints pirate | 32.4 | 29.6 | 0.91 | 0.89 to 0.92 |
| simplify sphere 1M | 208,835 | 223,636 | 1.07 | 0.99 to 1.12 |
| simplifyWithAttributes sphere 1M | 378,362 | 414,720 | 1.10 | 1.03 to 1.10 |
| simplifyWithUpdate sphere 1M | 361,854 | 376,336 | 1.04 | 1.04 to 1.10 |
| simplifySloppy sphere 1M | 18,800 | 18,389 | 0.98 | 0.98 to 0.98 |
| simplifyPrune sphere 1M | 11,680 | 10,742 | 0.92 | 0.92 to 0.93 |
| simplifyPoints sphere 1M | 9,794 | 9,718 | 0.99 | 0.99 to 0.99 |
| simplify pirate, allocator cache | 821.8 | 829.7 | 1.01 | 1.01 to 1.01 |
| clusterlod build default(128) pirate | 5,365 | 5,156 | 0.96 | 0.96 to 0.96 |
| clusterlod build defaultRT(128) pirate | 3,520 | 3,588 | 1.02 | 1.02 to 1.02 |
| clusterlod build default(128) sphere 262k | 274,194 | 251,758 | 0.92 | 0.91 to 0.92 |
| clusterlod build defaultRT(128) sphere 262k | 150,750 | 157,979 | 1.05 | 1.05 to 1.05 |
| clusterlod buildHierarchy sphere 262k | 1,408 | 1,184 | 0.84 | 0.83 to 0.84 |
| encodeVertexBuffer v1 L0 pirate | 67.6 | 70.3 | 1.04 | 1.04 to 1.04 |
| decodeVertexBuffer v1 L0 pirate | 14.4 | 15.0 | 1.04 | 1.03 to 1.04 |
| encodeVertexBuffer v1 L1 pirate | 60.4 | 57.1 | 0.95 | 0.95 to 0.95 |
| decodeVertexBuffer v1 L1 pirate | 13.8 | 14.4 | 1.04 | 1.04 to 1.04 |
| encodeVertexBuffer v1 L2 pirate | 67.7 | 68.5 | 1.01 | 1.01 to 1.02 |
| decodeVertexBuffer v1 L2 pirate | 13.7 | 14.3 | 1.04 | 1.04 to 1.05 |
| encodeVertexBuffer v1 L3 pirate | 93.8 | 93.9 | 1.00 | 0.99 to 1.00 |
| decodeVertexBuffer v1 L3 pirate | 13.8 | 14.3 | 1.04 | 1.04 to 1.04 |
| encodeVertexBuffer v0 pirate | 64.1 | 64.7 | 1.01 | 1.00 to 1.02 |
| decodeVertexBuffer v0 pirate | 14.1 | 14.5 | 1.03 | 1.03 to 1.04 |
| encodeVertexBuffer v1 L0 pirate q16 | 33.9 | 33.0 | 0.97 | 0.97 to 0.98 |
| decodeVertexBuffer v1 L0 pirate q16 | 7.4 | 7.7 | 1.04 | 1.03 to 1.04 |
| encodeVertexBuffer v1 L1 pirate q16 | 31.7 | 28.8 | 0.91 | 0.91 to 0.91 |
| decodeVertexBuffer v1 L1 pirate q16 | 7.2 | 7.5 | 1.04 | 1.04 to 1.04 |
| encodeVertexBuffer v1 L2 pirate q16 | 36.7 | 35.5 | 0.97 | 0.97 to 0.98 |
| decodeVertexBuffer v1 L2 pirate q16 | 7.2 | 7.5 | 1.04 | 1.04 to 1.06 |
| encodeVertexBuffer v1 L3 pirate q16 | 49.0 | 47.4 | 0.97 | 0.96 to 0.97 |
| decodeVertexBuffer v1 L3 pirate q16 | 7.2 | 7.5 | 1.04 | 1.04 to 1.06 |
| encodeVertexBuffer v0 pirate q16 | 35.2 | 36.9 | 1.05 | 1.03 to 1.05 |
| decodeVertexBuffer v0 pirate q16 | 7.4 | 7.7 | 1.04 | 1.04 to 1.04 |
| encodeVertexBuffer v1 L0 sphere 1M | 20,510 | 18,958 | 0.92 | 0.92 to 0.93 |
| decodeVertexBuffer v1 L0 sphere 1M | 4,510 | 4,692 | 1.04 | 1.04 to 1.04 |
| encodeVertexBuffer v1 L1 sphere 1M | 17,322 | 14,779 | 0.85 | 0.85 to 0.85 |
| decodeVertexBuffer v1 L1 sphere 1M | 4,100 | 4,272 | 1.04 | 1.04 to 1.05 |
| encodeVertexBuffer v1 L2 sphere 1M | 18,304 | 17,105 | 0.93 | 0.93 to 0.93 |
| decodeVertexBuffer v1 L2 sphere 1M | 3,898 | 4,007 | 1.03 | 1.03 to 1.03 |
| encodeVertexBuffer v1 L3 sphere 1M | 27,163 | 26,155 | 0.96 | 0.95 to 0.96 |
| decodeVertexBuffer v1 L3 sphere 1M | 3,895 | 4,003 | 1.03 | 1.02 to 1.04 |
| encodeVertexBuffer v0 sphere 1M | 19,239 | 21,194 | 1.10 | 1.10 to 1.11 |
| decodeVertexBuffer v0 sphere 1M | 4,272 | 4,366 | 1.02 | 1.01 to 1.03 |
| encodeVertexBuffer v1 L0 sphere 1M q16 | 9,946 | 9,022 | 0.91 | 0.91 to 0.91 |
| decodeVertexBuffer v1 L0 sphere 1M q16 | 2,216 | 2,314 | 1.04 | 1.04 to 1.05 |
| encodeVertexBuffer v1 L1 sphere 1M q16 | 9,597 | 8,336 | 0.87 | 0.87 to 0.87 |
| decodeVertexBuffer v1 L1 sphere 1M q16 | 2,151 | 2,248 | 1.05 | 1.04 to 1.05 |
| encodeVertexBuffer v1 L2 sphere 1M q16 | 9,512 | 8,806 | 0.93 | 0.92 to 0.93 |
| decodeVertexBuffer v1 L2 sphere 1M q16 | 1,930 | 1,995 | 1.03 | 1.03 to 1.03 |
| encodeVertexBuffer v1 L3 sphere 1M q16 | 14,373 | 13,701 | 0.95 | 0.95 to 0.95 |
| decodeVertexBuffer v1 L3 sphere 1M q16 | 1,928 | 1,994 | 1.03 | 1.03 to 1.03 |
| encodeVertexBuffer v0 sphere 1M q16 | 10,343 | 9,849 | 0.95 | 0.95 to 0.97 |
| decodeVertexBuffer v0 sphere 1M q16 | 2,234 | 2,328 | 1.04 | 1.04 to 1.05 |
| encodeFilter oct 8-bit | 6,802 | 6,730 | 0.99 | 0.99 to 0.99 |
| decodeFilter oct 8-bit | 2,284 | 648.7 | 0.28 | 0.28 to 0.28 |
| encodeFilter oct 16-bit | 6,415 | 6,409 | 1.00 | 1.00 to 1.00 |
| decodeFilter oct 16-bit | 2,875 | 698.6 | 0.24 | 0.24 to 0.24 |
| encodeFilter quat | 8,174 | 4,874 | 0.60 | 0.59 to 0.60 |
| decodeFilter quat | 1,983 | 935.4 | 0.47 | 0.47 to 0.47 |
| encodeFilter exp separate | 15,414 | 9,240 | 0.60 | 0.60 to 0.60 |
| decodeFilter exp separate | 928.5 | 457.3 | 0.49 | 0.45 to 0.53 |
| encodeFilter exp shared_vector | 11,747 | 6,688 | 0.57 | 0.57 to 0.57 |
| encodeFilter exp shared_component | 14,966 | 4,520 | 0.30 | 0.30 to 0.31 |
| encodeFilter exp clamped | 12,598 | 7,271 | 0.58 | 0.58 to 0.58 |
| encodeFilter color 8-bit | 6,124 | 5,573 | 0.91 | 0.91 to 0.91 |
| decodeFilter color 8-bit | 2,045 | 577.7 | 0.28 | 0.28 to 0.28 |
| encodeFilter color 16-bit | 6,129 | 5,581 | 0.91 | 0.91 to 0.92 |
| decodeFilter color 16-bit | 2,376 | 622.7 | 0.26 | 0.26 to 0.26 |
| remesh 64 pirate | 590.6 | 613.0 | 1.04 | 1.03 to 1.04 |
| remesh 64 shell pirate | 539.2 | 525.9 | 0.98 | 0.98 to 0.98 |
| remesh 64 solve pirate | 682.1 | 725.0 | 1.06 | 1.06 to 1.07 |
| remesh 128 pirate | 2,187 | 2,316 | 1.06 | 1.06 to 1.06 |
| remesh 128 shell pirate | 1,896 | 1,924 | 1.01 | 1.01 to 1.02 |
| remesh 128 solve pirate | 2,544 | 2,766 | 1.09 | 1.09 to 1.09 |
| remesh 256 pirate | 11,018 | 11,428 | 1.04 | 1.04 to 1.05 |
| remesh 256 shell pirate | 8,673 | 9,046 | 1.04 | 1.04 to 1.04 |
| remesh 256 solve pirate | 13,266 | 14,199 | 1.07 | 1.07 to 1.07 |
| remesh 64 sphere 1M | 32,075 | 28,538 | 0.89 | 0.89 to 0.89 |
| remesh 64 shell sphere 1M | 31,808 | 27,994 | 0.88 | 0.88 to 0.88 |
| remesh 64 solve sphere 1M | 34,622 | 32,334 | 0.93 | 0.93 to 0.94 |
| remesh 128 sphere 1M | 35,331 | 32,169 | 0.91 | 0.91 to 0.91 |
| remesh 128 shell sphere 1M | 34,177 | 30,706 | 0.90 | 0.90 to 0.90 |
| remesh 128 solve sphere 1M | 38,973 | 37,205 | 0.95 | 0.95 to 0.96 |
| remesh 256 sphere 1M | 78,819 | 75,557 | 0.96 | 0.96 to 0.97 |
| remesh 256 shell sphere 1M | 67,982 | 65,559 | 0.96 | 0.96 to 0.97 |
| remesh 256 solve sphere 1M | 84,604 | 83,054 | 0.98 | 0.97 to 0.99 |
| generateTangents pirate | 340.5 | 338.4 | 0.99 | 0.98 to 0.99 |
| generateTangents compatible pirate | 336.5 | 333.2 | 0.99 | 0.98 to 0.99 |
| generateTangents zero fallback pirate | 336.3 | 333.2 | 0.99 | 0.99 to 0.99 |
| generateNormals pirate | 310.5 | 319.5 | 1.03 | 1.00 to 1.04 |
| generateNormals smooth 1.5 pirate | 386.9 | 381.8 | 0.99 | 0.97 to 1.00 |
| generateTangents sphere 1M | 63,983 | 58,030 | 0.91 | 0.88 to 0.93 |
| generateTangents compatible sphere 1M | 63,022 | 58,455 | 0.93 | 0.88 to 0.93 |
| generateTangents zero fallback sphere 1M | 64,718 | 58,204 | 0.90 | 0.86 to 0.94 |
| generateNormals sphere 1M | 47,304 | 45,106 | 0.95 | 0.91 to 0.95 |
| generateNormals smooth 1.5 sphere 1M | 70,517 | 62,050 | 0.88 | 0.88 to 0.92 |
| opacityMapMeasure pirate | 64.7 | 54.7 | 0.85 | 0.80 to 0.85 |
| opacityMapMeasure sphere 1M | 16,590 | 14,294 | 0.86 | 0.81 to 0.86 |
| opacityMapRasterize 2-state pirate | 3,044 | 3,517 | 1.16 | 1.16 to 1.16 |
| opacityMapRasterize 2-state level 10 | 44,233 | 40,914 | 0.92 | 0.92 to 0.94 |
| opacityMapRasterize 2-state level 12 | 706,325 | 653,732 | 0.93 | 0.93 to 0.93 |
| opacityMapRasterize 4-state pirate | 3,567 | 3,784 | 1.06 | 1.06 to 1.07 |
| opacityMapRasterize 4-state level 10 | 48,644 | 47,574 | 0.98 | 0.97 to 0.98 |
| opacityMapRasterize 4-state level 12 | 778,610 | 785,398 | 1.01 | 0.98 to 1.03 |

## Slower rows

Cases where the port's time is more than 1.05 of the original's:

- **`quantizeUnorm` and `quantizeSnorm` as a loop of calls (4.85 and
  5.12).** These are inline functions; clang vectorizes the C++ loop that
  calls them into 16-lane AVX-512 code, and Zig 0.17 vectorizes no loop by
  itself, so the Zig loop stays scalar. Called on vectors of 16 floats,
  which the port adds, they take 1.00 of the original's time.
- **Vertex hashing with sizes known only at run time:**
  `generateVertexRemapMulti` (1.07 and 1.09), `filterIndexBuffer` and
  `filterIndexBufferMulti` on the sphere (1.13 and 1.08). The port
  compares vertices with `std.mem.eql` and copies them with
  compiler_rt's `memcpy`, where the original calls glibc's `memcmp`
  and `memcpy`; the shadow index buffers, which hash the same way, are
  0.72 to 0.99, so this is likely only part of the cause.
- **`unstripify` on the demo mesh (1.35).** A 5 µs case whose spread is
  91% of its median: noise in timing a call that short. On the sphere it
  is 0.82.
- **Loops clang vectorizes** (1.06 to 1.17): `analyzeVertexFetch`,
  `buildMeshletsSpatial` and `partitionClusters` on the sphere,
  `simplify`, `simplifyWithAttributes` and `simplifyWithUpdate`, the
  remesher on the demo mesh, and version 0 vertex encoding on the sphere.
  In the original's build these functions hold 256- and 512-bit vector
  instructions that clang's loop vectorizer made; the port's loops follow
  the original's step by step, and those not yet written on `@Vector`s
  stay scalar.
- **No cause found yet** (1.06 to 1.16): `optimizeMeshlet` on the sphere,
  `opacityMapRasterize` and `encodeIndexSequence` on the demo mesh, and
  `decodeMeshletRaw` (whose SIMD paths both sides write by hand).
