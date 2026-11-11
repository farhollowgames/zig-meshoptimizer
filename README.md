# zig-meshoptimizer

Tracks meshoptimizer 1.3 · Zig 0.17 · [status](STATUS.md)

## What it is

A Zig port of [meshoptimizer](#licence-and-references), Arseny
Kapoulkine's library for preparing meshes for GPU rendering: it reorders
and indexes triangles for the vertex cache and vertex fetch, compresses
vertex and index data, simplifies meshes, and builds meshlets. It is pure
Zig, with no dependencies beyond the standard library, and links no libc
or libc++.

This port is not affiliated with or reviewed by the meshoptimizer authors.
Its code was written with AI assistance (Claude, Anthropic's model) for
Farhollow Games, and has not yet been reviewed by a person.

## Features

- Indexing: vertex remaps (one stream or several, or a comparison of the
  caller's own), shadow and filtered index buffers, adjacency,
  tessellation and provoking-vertex index buffers.
- Vertex cache, overdraw and vertex fetch optimization, triangle strips,
  and analyzers for each.
- Vertex, index and meshlet codecs, with the original's SSE, AVX-512 and
  NEON decoders, and the vertex filters and their encoders.
- Simplification: edge collapse with attributes and vertex flags, sloppy
  and point-cloud simplification, and pruning.
- Meshlets: four builders, meshlet optimization, cluster and sphere bounds,
  and cluster partitioning.
- Spatial sorting, tangent and normal generation, remeshing, opacity
  micromaps, quantization.
- `clusterlod`, the original's cluster LOD demo library
  (`demo/clusterlod.h`).
- 16- and 32-bit indices everywhere the original takes index buffers.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-meshoptimizer#main
```

There is no release tag yet. Then, in `build.zig`:

```zig
const meshoptimizer = b.dependency("meshoptimizer", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("meshoptimizer", meshoptimizer.module("meshoptimizer"));
```

## Use

Index an unindexed triangle list and order it for the vertex cache:

```zig
const std = @import("std");
const meshopt = @import("meshoptimizer");

const Vertex = struct { position: [3]f32, normal: [3]f32, uv: [2]f32 };

/// Merges equal vertices of `soup` into `indices`, one per vertex of
/// `soup`, orders them for the vertex cache, and returns the unique
/// vertices; 16-bit indices hold up to 65536 of them.
pub fn index(gpa: std.mem.Allocator, soup: []const Vertex, indices: []u16) ![]Vertex {
    const remap = try gpa.alloc(u32, soup.len);
    defer gpa.free(remap);
    const bytes = std.mem.sliceAsBytes(soup);
    const unique = try meshopt.generateVertexRemap(u16, gpa, remap, null, bytes, @sizeOf(Vertex));

    const vertices = try gpa.alloc(Vertex, unique);
    errdefer gpa.free(vertices);
    const vertex_bytes = std.mem.sliceAsBytes(vertices);
    try meshopt.remapVertexBuffer(gpa, vertex_bytes, bytes, @sizeOf(Vertex), remap);
    meshopt.remapIndexBuffer(u16, indices, null, remap);
    try meshopt.optimizeVertexCache(u16, gpa, indices, indices, unique);
    return vertices;
}
```

Every function of the original is there under its name without the
`meshopt_` prefix (`meshopt_optimizeVertexCache` is
`meshopt.optimizeVertexCache`), and the doc comments in [`src/`](src)
describe each one. Per-vertex floats are `VertexFloats` views:

```zig
const positions: meshopt.VertexFloats = .fromField(Vertex, "position", vertices);
```

## Differences from the original

[`doc/parity.md`](doc/parity.md) gives the reasons.

*Additions*
- `quantizeUnorm` and `quantizeSnorm` also take vectors of floats.
- `clusterlod`, the original's demo library, is part of the package.

*Changes to expect*
- Functions that take index buffers take the index type first, `u16` or
  `u32`.
- Functions that need scratch memory take a `std.mem.Allocator`, in place
  of the global allocator hooks; `AllocatorCache` takes the place of
  `meshopt_setAllocatorCache`.
- Decoders return Zig errors in place of negative codes.
- Encoder versions are arguments in place of global setters.
- Float to integer conversions that C leaves undefined give x86-64's
  result on every machine.
- `cosf` and `log2f` are the port's own, as glibc computes them, on every
  machine.

## Not included

The SIMD paths for Wasm and 32-bit ARM, run-time SSSE3 detection, the
build switches, and the index templates for types other than `u16` and
`u32`; [`STATUS.md`](STATUS.md#left-out) lists each left-out item and the
reason.

## Testing and benchmarks

365 tests. 184 run the original beside the port on the same inputs and
compare every output byte and returned value; 129 are the original's own
test suite, run against the port; 52 test the port alone. The inputs are
the original's demo mesh, generated meshes, hand-made edge cases, malformed
encoded data and seeded fuzzing, with 1,000 cases or more per fuzz test.

Port time divided by original time on a generated sphere of about a million
triangles, the median of three runs (below 1, the port takes less time):

| function | port ÷ original |
| --- | ---: |
| `generateVertexRemap` | 0.95 |
| `optimizeVertexCache` | 0.99 |
| `buildMeshlets` | 0.77 |
| `simplify` | 1.07 |
| `decodeVertexBuffer` | 1.03 |

Over all 218 benchmark cases the port's time is at most 1.05 of the
original's in 192. The slowest are `quantizeUnorm` and `quantizeSnorm`
called in a loop (4.9 and 5.1), which Zig does not vectorize; their vector
forms take 1.00. AMD Ryzen 9 9950X3D, one core, Linux 7.3.3, Zig 0.17.0
ReleaseFast against clang 22.1.8 `-O3`, measured while other builds ran on
the machine.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): every case's time, the flags
  on both sides, the biases and the command.

## Licence and references

MIT licence, the original's ([`LICENSE.md`](LICENSE.md)). The original's
copyright notice is kept in `LICENSE.md` as it is: "Copyright (c)
2016-2026 Arseny Kapoulkine". `src/cosf.zig` and `src/log2f.zig` are
translated from Arm's optimized-routines and used under the MIT licence;
its text and Arm's copyright notices are in `LICENSE.md` too. The tests
use the original's demo mesh, Pirate by Clint Bellanger (CC-BY-SA 3.0),
which is not part of the package.

- [meshoptimizer](https://github.com/zeux/meshoptimizer), the original, by
  [Arseny Kapoulkine](https://github.com/zeux), and its
  [documentation](https://meshoptimizer.org).
- [optimized-routines](https://github.com/ARM-software/optimized-routines),
  Arm's maths routines, which glibc's `cosf` and `log2f` and the port's
  are built from.
- The papers each part builds on are named in the doc comment at the top
  of its file in [`src/`](src): among them Forsyth's linear-speed vertex
  cache optimisation, Sander, Nehab and Barczak's triangle reordering for
  vertex locality and overdraw, and Garland and Heckbert's quadric error
  metrics.

Made by Farhollow Games for the Loomwork Engine.
