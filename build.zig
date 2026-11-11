const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("meshoptimizer", .{
        .root_source_file = b.path("src/meshoptimizer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests default to ReleaseSafe: the fuzzed meshes take minutes in Debug,
    // and ReleaseSafe keeps every assert and overflow check on.
    const test_optimize = b.option(
        std.lang.Optimize,
        "test-optimize",
        "Optimize mode for the tests (default ReleaseSafe)",
    ) orelse .safe;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/meshoptimizer.zig"),
        .target = target,
        .optimize = test_optimize,
    });

    const test_step = b.step("test", "Run unit, oracle and upstream-suite tests");
    const bench_step = b.step("bench", "Time the port against the original (ReleaseFast)");

    const unit_tests = b.addTest(.{ .root_module = test_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The original C++ is fetched only for the tests and the benchmark.
    const upstream = b.lazyDependency("upstream", .{}) orelse return;

    const upstream_mod = b.createModule(.{
        .root_source_file = b.path("test/upstream.zig"),
        .target = target,
    });
    const meshes_mod = demoMeshes(b, upstream, target, test_optimize);

    // Oracle tests: the port and the original side by side on the same
    // inputs, every output compared byte for byte.
    const reference = referenceLibrary(b, upstream, target, .fast);
    const oracle = b.addTest(.{
        .name = "oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/oracle.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "meshoptimizer", .module = test_mod },
                .{ .name = "upstream", .module = upstream_mod },
                .{ .name = "meshes", .module = meshes_mod },
            },
        }),
        .filters = test_filters,
    });
    oracle.root_module.linkLibrary(reference);
    // The original's SIMD files again without SIMD, under other names, so
    // the port's scalar paths are checked against the original's.
    oracle.root_module.linkLibrary(scalarReferenceLibrary(b, upstream, target));
    addReferenceShim(b, oracle.root_module, upstream);
    test_step.dependOn(&b.addRunArtifact(oracle).step);

    // The original's own test suite, demo/tests.cpp unmodified, run against
    // the port through a C ABI that exists only for it.
    const suite = b.addTest(.{
        .name = "suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/suite.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "meshoptimizer", .module = test_mod },
                .{ .name = "upstream", .module = upstream_mod },
            },
        }),
        .filters = test_filters,
    });
    suite.root_module.addIncludePath(upstream.path("demo"));
    suite.root_module.addCSourceFile(.{ .file = b.path("test/suite.cpp"), .flags = &suite_flags });
    // The original's allocator hooks, so the suite's allocation counts see
    // every allocation the port makes; without the original's cache, as
    // test/capi.zig exports meshopt_setAllocatorCache over the port's.
    suite.root_module.addCSourceFile(.{
        .file = upstream.path("src/allocator.cpp"),
        .flags = &suite_allocator_flags,
    });
    test_step.dependOn(&b.addRunArtifact(suite).step);

    // The benchmark always runs in ReleaseFast, against the original at -O3.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "meshoptimizer", .module = b.createModule(.{
                    .root_source_file = b.path("src/meshoptimizer.zig"),
                    .target = target,
                    .optimize = .fast,
                }) },
                .{ .name = "upstream", .module = upstream_mod },
                .{ .name = "meshes", .module = demoMeshes(b, upstream, target, .fast) },
            },
        }),
    });
    bench.root_module.linkLibrary(reference);
    addReferenceShim(b, bench.root_module, upstream);
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    bench_step.dependOn(&run_bench.step);
}

const upstream_sources = [_][]const u8{
    "allocator.cpp",
    "clusterizer.cpp",
    "indexanalyzer.cpp",
    "indexcodec.cpp",
    "indexgenerator.cpp",
    "meshletcodec.cpp",
    "meshletutils.cpp",
    "opacitymap.cpp",
    "overdrawoptimizer.cpp",
    "partition.cpp",
    "quantization.cpp",
    "rasterizer.cpp",
    "remesher.cpp",
    "simplifier.cpp",
    "spatialorder.cpp",
    "stripifier.cpp",
    "tangentspace.cpp",
    "vcacheoptimizer.cpp",
    "vertexcodec.cpp",
    "vertexfilter.cpp",
    "vfetchoptimizer.cpp",
};

// Fused multiply-adds are off so the original's float steps round as written,
// as Zig's do; on targets without FMA, which upstream's default builds are,
// this is what the original computes anyway.
const reference_flags = [_][]const u8{
    "-std=c++11",
    "-O3",
    "-ffp-contract=off",
    "-fno-fast-math",
    "-fno-exceptions",
    "-fno-rtti",
};

const suite_flags = reference_flags ++ [_][]const u8{"-DMESHOPTIMIZER_ALLOC_EXPORT"};

const suite_allocator_flags = suite_flags ++ [_][]const u8{"-DMESHOPTIMIZER_ALLOC_NOCACHE"};

/// The original library, built from the pinned upstream sources as a
/// shared library, so its calls into the C library bind to the system's, as
/// in a normal build of it. Linked into a binary Zig links, they would bind
/// to compiler_rt's versions instead: its `bcmp`, which the original's
/// `memcmp` calls become, compares a byte at a time, and its `cosf` and
/// `log2f` round differently from glibc's.
fn referenceLibrary(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const reference = b.addLibrary(.{
        .name = "meshoptimizer_reference",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    reference.bundle_compiler_rt = false;
    reference.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &upstream_sources,
        .flags = &reference_flags,
    });
    reference.root_module.addCSourceFile(.{
        .file = b.path("test/system_libm.cpp"),
        .flags = &reference_flags,
    });
    return reference;
}

/// The original's files with SIMD paths, which the scalar reference builds
/// without them.
const scalar_sources = [_][]const u8{
    "meshletcodec.cpp",
    "vertexcodec.cpp",
    "vertexfilter.cpp",
};

/// Their functions, each renamed `scalar_<name>` so they link beside the
/// original's, and their internal namespace renamed too, so no inline
/// function of the scalar build stands in for its SIMD build's twin.
const scalar_flags = reference_flags ++ [_][]const u8{
    "-DMESHOPTIMIZER_NO_SIMD",
    "-Dmeshopt=scalar_meshopt",
    "-Dmeshopt_encodeMeshlet=scalar_meshopt_encodeMeshlet",
    "-Dmeshopt_encodeMeshletBound=scalar_meshopt_encodeMeshletBound",
    "-Dmeshopt_decodeMeshlet=scalar_meshopt_decodeMeshlet",
    "-Dmeshopt_decodeMeshletRaw=scalar_meshopt_decodeMeshletRaw",
    "-Dmeshopt_encodeVertexBuffer=scalar_meshopt_encodeVertexBuffer",
    "-Dmeshopt_encodeVertexBufferBound=scalar_meshopt_encodeVertexBufferBound",
    "-Dmeshopt_encodeVertexBufferLevel=scalar_meshopt_encodeVertexBufferLevel",
    "-Dmeshopt_encodeVertexVersion=scalar_meshopt_encodeVertexVersion",
    "-Dmeshopt_decodeVertexBuffer=scalar_meshopt_decodeVertexBuffer",
    "-Dmeshopt_decodeVertexVersion=scalar_meshopt_decodeVertexVersion",
    "-Dmeshopt_decodeFilterOct=scalar_meshopt_decodeFilterOct",
    "-Dmeshopt_decodeFilterQuat=scalar_meshopt_decodeFilterQuat",
    "-Dmeshopt_decodeFilterExp=scalar_meshopt_decodeFilterExp",
    "-Dmeshopt_decodeFilterColor=scalar_meshopt_decodeFilterColor",
    "-Dmeshopt_encodeFilterOct=scalar_meshopt_encodeFilterOct",
    "-Dmeshopt_encodeFilterQuat=scalar_meshopt_encodeFilterQuat",
    "-Dmeshopt_encodeFilterExp=scalar_meshopt_encodeFilterExp",
    "-Dmeshopt_encodeFilterColor=scalar_meshopt_encodeFilterColor",
};

/// The original's SIMD files built with their scalar paths, for the oracle
/// tests of the port's scalar paths.
fn scalarReferenceLibrary(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.Compile {
    const reference = b.addLibrary(.{
        .name = "meshoptimizer_scalar_reference",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    reference.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &scalar_sources,
        .flags = &scalar_flags,
    });
    return reference;
}

/// The original's inline C++ functions, given C names for the tests.
fn addReferenceShim(
    b: *std.Build,
    module: *std.Build.Module,
    upstream: *std.Build.Dependency,
) void {
    module.addIncludePath(upstream.path("src"));
    module.addCSourceFile(.{ .file = b.path("test/reference.cpp"), .flags = &reference_flags });
}

/// The original's demo mesh, embedded for the tests and the benchmark.
fn demoMeshes(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(upstream.path("demo/pirate.obj"), "pirate.obj");
    _ = files.addCopyFile(b.path("test/meshes.zig"), "meshes.zig");
    return b.createModule(.{
        .root_source_file = files.getDirectory().path(b, "meshes.zig"),
        .target = target,
        .optimize = optimize,
    });
}
