# zig-meshoptimizer

[meshoptimizer](https://github.com/zeux/meshoptimizer) in pure Zig: mesh
optimization for GPU rendering, mesh and vertex compression, simplification
and meshlet generation.

zig-meshoptimizer is a translation of Arseny Kapoulkine's meshoptimizer
1.3, and tests show that it returns **the same bytes as the original** for
the same inputs. It has no dependencies beyond Zig's standard library and
links no libc or libc++.

This port was written by Claude (Anthropic's AI model) for Farhollow Games.
See [STATUS.md](STATUS.md) for what is ported so far, and
[below](#how-the-tests-prove-equivalence) for how the code is verified.

Requires Zig 0.17.0.

## Use

Add the package:

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-meshoptimizer
```

and import its module in `build.zig`:

```zig
const meshoptimizer = b.dependency("meshoptimizer", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("meshoptimizer", meshoptimizer.module("meshoptimizer"));
```

Every function of the original is there under its name without the
`meshopt_` prefix. Buffers are slices, and per-vertex floats inside a vertex
buffer are `VertexFloats` views. A function that needs scratch memory takes
a `std.mem.Allocator` first and frees everything before it returns, newest
first, so stack allocators work:

```zig
const std = @import("std");
const meshopt = @import("meshoptimizer");

const Vertex = struct { position: [3]f32, normal: [3]f32, uv: [2]f32 };

/// Merges equal vertices of an unindexed triangle list into `indices` and
/// returns the unique vertices.
pub fn index(gpa: std.mem.Allocator, soup: []const Vertex, indices: []u32) ![]Vertex {
    const remap = try gpa.alloc(u32, soup.len);
    defer gpa.free(remap);
    const bytes = std.mem.sliceAsBytes(soup);
    const unique = try meshopt.generateVertexRemap(gpa, remap, null, bytes, @sizeOf(Vertex));

    const vertices = try gpa.alloc(Vertex, unique);
    try meshopt.remapVertexBuffer(gpa, std.mem.sliceAsBytes(vertices), bytes, @sizeOf(Vertex), remap);
    meshopt.remapIndexBuffer(indices, null, remap);
    return vertices;
}
```

Positions for the functions that take them:

```zig
const positions: meshopt.VertexFloats = .fromField(Vertex, "position", vertices);
```

## How the tests prove equivalence

`zig build test` fetches the original at tag v1.3 (a lazy dependency, never
part of the package), builds it from source, and runs three test binaries:

- **oracle** (`test/oracle.zig`): the port and the original side by side on
  the same inputs, the original's demo mesh, generated meshes and fuzzed
  ones, and malformed encoded data for the decoders. Every output must be
  identical, floats bit for bit, and decoders must give the same results
  and errors.
- **suite** (`test/suite.zig`): the original's own test suite,
  `demo/tests.cpp` compiled unmodified, run against the port through a C
  interface that exists only for it (`test/capi.zig`). Its allocation
  checks go through the original's allocator hooks, so they also check that
  the port allocates as the original does.
- **unit**: the tests inside `src/`.

Both sides are built with fused multiply-add off, so float steps round as
written.

`zig build bench` times each function against the original, both in
ReleaseFast.

## Licence and credits

MIT ([`LICENSE.md`](LICENSE.md)), the original's licence.

Translated from [meshoptimizer](https://github.com/zeux/meshoptimizer) by
Arseny Kapoulkine (MIT), tag v1.3. The test meshes include the original's
demo mesh, Pirate by Clint Bellanger (CC-BY-SA 3.0), used by the tests only.

Made by Farhollow Games for the Loomwork Engine.
