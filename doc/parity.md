# Differences from the original

Where the port's output or interface differs from meshoptimizer 1.3, and
why. Everything else gives the original's bytes; [TESTING.md](TESTING.md)
says how that is checked.

## Additions

- **`quantizeUnorm` and `quantizeSnorm` also take vectors.** The same
  function takes an `f32`, giving an integer as the original's does, or a
  `@Vector` of `f32`, giving a vector of integers with each lane as the
  scalar call gives it; any other type is a compile error. Zig 0.17 does
  not vectorize a loop of scalar calls on its own, where C++ compilers
  vectorize the original's loop, so code that quantizes arrays passes
  vectors to run at the original's speed
  ([BENCHMARKS.md](BENCHMARKS.md#slower-rows)).
- **`clusterlod`** is the original's `demo/clusterlod.h`, a header the
  original ships as a demo, ported with the library.
- **`-Dfuzz-seed`** shifts every fuzz test's seeds, for new cases.

## Changes to expect

Interface:

- **Index types.** Every function that reads or writes an index buffer
  takes the index type first, `u16` or `u32`, where the original's C++
  templates take any integer type. The original's 32-bit functions are the
  `u32` forms.
- **Allocators.** Functions that need scratch memory take a
  `std.mem.Allocator` in place of the original's global allocator hooks
  (`meshopt_setAllocator`), and free everything they allocate before they
  return, newest first. `clusterlod.build` is the exception: it frees out
  of order, so it needs a general-purpose allocator.
- **Zero-length scratch arrays** (empty meshes) make no allocator call; the
  original asks its hooks or cache for 0 bytes, which its cache rounds up
  to 16. `std.mem.Allocator` hands out empty slices without a call, so the
  backing allocator can see fewer calls.
- **`AllocatorCache`** is the original's `meshopt_setAllocatorCache` as an
  allocator the caller makes and passes, with a `Local` handle per thread.
  Its `init` returns `error.OutOfMemory` when it cannot reserve its blocks;
  the original's cache silently runs without them.
- **Errors.** Decoders return Zig error sets (`DecodeVertexError`,
  `IndexDecodeError`, `MeshletDecodeError`) instead of negative codes.
- **Encoder versions** are arguments (`VertexVersion`, `IndexVersion`)
  instead of the global setters `meshopt_encodeVertexVersion` and
  `meshopt_encodeIndexVersion`.
- **Hidden bits.** The remesher's undocumented debug bit 30 has no named
  field in `RemeshOptions`; set through `@fromBackingInt`, it acts as the
  original's. The simplifier keeps its two internal bits as fields
  (`internal_solve`, `internal_debug`), since `simplifyEdge`, which the
  original exports outside its header, takes `internal_solve` to move
  vertices.
- **Cluster LOD** border dilation writes through `Mesh.positions_mut`, an
  optional writable view of the positions, where the original casts away
  `const`. The output callback is a context's `output` method; a context
  whose `output` returns -1 does what the original does without a
  callback.

Output:

- **Float-to-integer conversions of NaN, infinities and values past the
  `i32` range**, which C leaves undefined, give the original's x86 results
  on every target: truncation toward zero, and the lowest `i32` out of
  range. The original built for aarch64 saturates instead, so there its
  scalar vertex filters, its filter encoders, and the other functions that
  convert floats give other integers on such input: an alpha of 0 in
  `decodeFilterColor`'s scalar loop, or a mantissa past 24 bits in
  `encodeFilterExp`, which the x86 build writes as 0 and the aarch64 build
  clamps. The port's NEON filter kernels use the NEON conversions, as the
  original's do. Outside those kernels, the same input gives the same
  output on every machine.
- **`cosf` and `log2f`** are the port's own, translated from Arm's
  optimized-routines, the code glibc's are built from, in the form glibc
  runs on x86-64 CPUs with fused multiply-add. The original calls them
  through its C library, so the port gives the original's results with
  glibc on every target, and other C libraries' rounding nowhere.
- **NaN results.** Where an operation's operands hold several NaNs, LLVM
  does not fix which one it returns, in either build, so a NaN's sign and
  payload can differ from the original's.
- **The NEON vertex decoder**, on a malformed buffer whose 2- or 4-bit
  group holds 16 sentinels, advances 16 bytes less than the other
  decoders, as the original's NEON build does, so its result there can
  differ from theirs.
- **The decoder a build picks.** The port picks its vertex decoder at
  compile time from the target, where the original's x86 build checks for
  SSSE3 at run time. A baseline x86-64 build, or a Debug build on Zig's own
  x86 backend, which builds no SIMD decoders, decodes with the scalar one.
  Valid buffers decode to the same bytes either way; on a malformed buffer
  the scalar decoder can return `error.LengthMismatch` where the
  original's SSSE3 decoder returns its `error.InvalidData` code, as the
  original's scalar build does.
- **16-bit output past the returned count.** The original's 16-bit
  templates copy their whole scratch buffer to the destination, past the
  count they return, where the port leaves the destination as it was.
