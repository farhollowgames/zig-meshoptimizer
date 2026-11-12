# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.

## In this repository

### The tests

`zig build test` fetches meshoptimizer 1.3 (commit `f0a684f`) as a lazy
dependency, which is never part of the package, and builds three test
binaries:

- **oracle** (`test/oracle.zig` and the `*_test.zig` files beside it): the
  port against the original on the original's demo mesh (Pirate), generated
  meshes and fuzzed ones. `test/reference.cpp` exports the header's inline
  functions and the 16-bit index templates (`meshopt_*<unsigned short>`),
  which the original has no symbols for, so the `u16` versions of the
  port's functions are compared with the original's own 16-bit code.
- **suite** (`test/suite.zig`): the original's test suite,
  `demo/tests.cpp`, compiled unmodified and run against the port through a
  C interface that exists only for it (`test/capi.zig`). Its allocation
  counts go through the original's allocator hooks, so they also check that
  the port allocates as the original does.
- **unit**: the tests inside `src/`.

Specifics:

- Both sides are built with fused multiply-add off, so float steps round as
  written.
- The original's SIMD files are built a second time without SIMD, under
  other names, so the port's scalar paths are compared with the original's
  scalar paths on x86 too.
- The NEON paths (the vertex codec, the vertex filters, the meshlet codec
  and the spatial clusterizer) run against the original built for aarch64,
  under QEMU's user mode, as CI does. `qemu-aarch64` must be on the `PATH`:

  ```sh
  zig build test -Dtarget=aarch64-linux-musl -fqemu \
      -Dtest-filter=vertexcodec -Dtest-filter=vertexfilter \
      -Dtest-filter=meshletcodec -Dtest-filter=clusterizer
  ```

  QEMU was not installed on the machine the release was checked on, so
  for this release the NEON paths are covered by the repository's CI
  workflow only, not by a local run.

  There C's undefined float-to-integer conversions, which the original's
  aarch64 build saturates and the port computes as on x86, are left out of
  the scalar comparisons ([parity](parity.md)).
- In Debug, the x86 backend cannot assemble `rsqrtps` and `rcpps`, so the
  8-bit `decodeFilterOct` and `decodeFilterColor` take the scalar path,
  whose bytes differ from the SSE kernels' as the original's two builds do;
  the tests compare them with the original's scalar build there. The same
  backend builds no SIMD vertex decoders, so `decodeVertexBuffer` decodes
  with the scalar one; on malformed buffers its error codes follow the
  original's scalar build, and the tests compare it with that build there.
- The library has no threads of its own. `AllocatorCache` is the one part
  meant for several threads, and its unit tests share one cache between
  threads.
- The original's 16-bit templates widen the indices to 32 bits, run the
  32-bit function and cut the results back. The port runs most functions
  on `u16` directly, and widens as the original does in the edge-collapse
  and sloppy simplifiers and in pruning; the tests compare every function
  with the original's templates on the demo mesh, on a grid whose indices
  reach 65535, and on 1,000 fuzzed meshes.
- `cosf` and `log2f`, the port's copies of glibc's, are compared with the
  system's glibc on every float in ReleaseSafe and ReleaseFast, and on
  every 7th float in Debug.

### What "the same output" means here

- Integers, indices and encoded data: the same bytes. Floats: the same
  bits.
- NaN: where an input holds NaN or infinity, or values whose arithmetic
  overflows, an operation can meet several NaNs, and LLVM leaves open which
  one it returns, in either build. For those inputs only, a NaN matches any
  NaN; every other float still compares bit for bit. Each test that does
  this says so.
- Output the original leaves unwritten: both sides start from the same
  fill, so bytes neither side writes compare equal, and bytes only one side
  writes do not.

### Fuzzing

Each fuzz test runs at least 1,000 cases. Case `i` builds its inputs from
the seed `first_seed + fuzz_seed + i`, where `first_seed` is fixed per test
and `fuzz_seed` comes from the build:

```sh
zig build test -Dfuzz-seed=12345
```

The default, 0, gives the cases CI runs. On a failure the test prints its
name and the seed of the failing case; a failed safety check (outside
Windows) prints the seed after the panic.

### Malformed input

Every decoder runs on truncated, corrupted and random bytes, and must give
the original's result: the same error, or the same output where the
original accepts the input.

### Determinism

Most fuzz tests run the port a second time into output buffers filled with
a different byte, and it must write the same bytes.

### Build modes

The tests default to ReleaseSafe. Debug and ReleaseFast run too:

```sh
zig build test                            # ReleaseSafe
zig build test -Dtest-optimize=Debug
zig build test -Dtest-optimize=ReleaseFast
```

The original is always built optimized, so the port in each mode is
compared with the same reference.
