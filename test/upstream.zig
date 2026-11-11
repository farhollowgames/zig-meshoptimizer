//! The original meshoptimizer's C interface, as declared in its
//! meshoptimizer.h, for the oracle tests and the benchmark, which link the
//! original built from source. C types map to Zig's: `unsigned int` is
//! `u32`, `int` is `c_int`, `size_t` is `usize`.

pub const Stream = extern struct {
    data: ?*const anyopaque,
    size: usize,
    stride: usize,
};

pub const VertexCacheStatistics = extern struct {
    vertices_transformed: u32,
    warps_executed: u32,
    acmr: f32,
    atvr: f32,
};

pub const VertexFetchStatistics = extern struct {
    bytes_fetched: u32,
    overfetch: f32,
};

pub const OverdrawStatistics = extern struct {
    pixels_covered: u32,
    pixels_shaded: u32,
    overdraw: f32,
};

pub const CoverageStatistics = extern struct {
    coverage: [3]f32,
    extent: f32,
};

pub const Meshlet = extern struct {
    vertex_offset: u32,
    triangle_offset: u32,
    vertex_count: u32,
    triangle_count: u32,
};

pub const Bounds = extern struct {
    center: [3]f32,
    radius: f32,
    cone_apex: [3]f32,
    cone_axis: [3]f32,
    cone_cutoff: f32,
    cone_axis_s8: [3]i8,
    cone_cutoff_s8: i8,
};

pub const EncodeExpMode = enum(c_int) { separate, shared_vector, shared_component, clamped };

pub const RemapCallback = *const fn (?*anyopaque, u32, u32) callconv(.c) c_int;

pub extern fn meshopt_generateVertexRemap(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
) usize;
pub extern fn meshopt_generateVertexRemapMulti(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    streams: ?[*]const Stream,
    stream_count: usize,
) usize;
pub extern fn meshopt_generateVertexRemapCustom(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    callback: ?RemapCallback,
    context: ?*anyopaque,
) usize;
pub extern fn meshopt_remapVertexBuffer(
    destination: ?*anyopaque,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    remap: ?[*]const u32,
) void;
pub extern fn meshopt_remapIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    remap: ?[*]const u32,
) void;
pub extern fn meshopt_filterIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    vertex_stride: usize,
) usize;
pub extern fn meshopt_filterIndexBufferMulti(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    streams: ?[*]const Stream,
    stream_count: usize,
) usize;
pub extern fn meshopt_generateShadowIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    vertex_stride: usize,
) void;
pub extern fn meshopt_generateShadowIndexBufferMulti(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    streams: ?[*]const Stream,
    stream_count: usize,
) void;
pub extern fn meshopt_generatePositionRemap(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void;
pub extern fn meshopt_generateAdjacencyIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void;
pub extern fn meshopt_generateTessellationIndexBuffer(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void;
pub extern fn meshopt_generateProvokingIndexBuffer(
    destination: ?[*]u32,
    reorder: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) usize;

pub extern fn meshopt_optimizeVertexCache(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) void;
/// vcacheoptimizer.cpp's `meshopt::VertexScoreTable`.
pub const VertexScoreTable = extern struct {
    cache: [17]f32,
    live: [9]f32,
};

/// vcacheoptimizer.cpp exports this without declaring it in the header, so
/// it has C++ linkage: this is its Itanium ABI name.
pub extern fn _Z32meshopt_optimizeVertexCacheTablePjPKjmmPKN7meshopt16VertexScoreTableE(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    table: *const VertexScoreTable,
) void;
pub const meshopt_optimizeVertexCacheTable =
    _Z32meshopt_optimizeVertexCacheTablePjPKjmmPKN7meshopt16VertexScoreTableE;
pub extern fn meshopt_optimizeVertexCacheStrip(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) void;
pub extern fn meshopt_optimizeVertexCacheFifo(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    cache_size: u32,
) void;
pub extern fn meshopt_optimizeOverdraw(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    threshold: f32,
) void;
pub extern fn meshopt_optimizeVertexFetch(
    destination: ?*anyopaque,
    indices: ?[*]u32,
    index_count: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
) usize;
pub extern fn meshopt_optimizeVertexFetchRemap(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
) usize;

pub extern fn meshopt_encodeIndexBuffer(
    buffer: ?[*]u8,
    buffer_size: usize,
    indices: ?[*]const u32,
    index_count: usize,
) usize;
pub extern fn meshopt_encodeIndexBufferBound(index_count: usize, vertex_count: usize) usize;
pub extern fn meshopt_encodeIndexVersion(version: c_int) void;
pub extern fn meshopt_decodeIndexBuffer(
    destination: ?*anyopaque,
    index_count: usize,
    index_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;
pub extern fn meshopt_decodeIndexVersion(buffer: ?[*]const u8, buffer_size: usize) c_int;
pub extern fn meshopt_encodeIndexSequence(
    buffer: ?[*]u8,
    buffer_size: usize,
    indices: ?[*]const u32,
    index_count: usize,
) usize;
pub extern fn meshopt_encodeIndexSequenceBound(index_count: usize, vertex_count: usize) usize;
pub extern fn meshopt_decodeIndexSequence(
    destination: ?*anyopaque,
    index_count: usize,
    index_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;

pub extern fn meshopt_encodeMeshlet(
    buffer: ?[*]u8,
    buffer_size: usize,
    vertices: ?[*]const u32,
    vertex_count: usize,
    triangles: ?[*]const u8,
    triangle_count: usize,
) usize;
pub extern fn meshopt_encodeMeshletBound(max_vertices: usize, max_triangles: usize) usize;
pub extern fn meshopt_decodeMeshlet(
    vertices: ?*anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    triangles: ?*anyopaque,
    triangle_count: usize,
    triangle_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;
pub extern fn meshopt_decodeMeshletRaw(
    vertices: ?[*]u32,
    vertex_count: usize,
    triangles: ?[*]u32,
    triangle_count: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;

pub extern fn meshopt_encodeVertexBuffer(
    buffer: ?[*]u8,
    buffer_size: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
) usize;
pub extern fn meshopt_encodeVertexBufferBound(vertex_count: usize, vertex_size: usize) usize;
pub extern fn meshopt_encodeVertexBufferLevel(
    buffer: ?[*]u8,
    buffer_size: usize,
    vertices: ?*const anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    level: c_int,
    version: c_int,
) usize;
pub extern fn meshopt_encodeVertexVersion(version: c_int) void;
pub extern fn meshopt_decodeVertexBuffer(
    destination: ?*anyopaque,
    vertex_count: usize,
    vertex_size: usize,
    buffer: ?[*]const u8,
    buffer_size: usize,
) c_int;
pub extern fn meshopt_decodeVertexVersion(buffer: ?[*]const u8, buffer_size: usize) c_int;

pub extern fn meshopt_decodeFilterOct(buffer: ?*anyopaque, count: usize, stride: usize) void;
pub extern fn meshopt_decodeFilterQuat(buffer: ?*anyopaque, count: usize, stride: usize) void;
pub extern fn meshopt_decodeFilterExp(buffer: ?*anyopaque, count: usize, stride: usize) void;
pub extern fn meshopt_decodeFilterColor(buffer: ?*anyopaque, count: usize, stride: usize) void;
pub extern fn meshopt_encodeFilterOct(
    destination: ?*anyopaque,
    count: usize,
    stride: usize,
    bits: c_int,
    data: ?[*]const f32,
) void;
pub extern fn meshopt_encodeFilterQuat(
    destination: ?*anyopaque,
    count: usize,
    stride: usize,
    bits: c_int,
    data: ?[*]const f32,
) void;
pub extern fn meshopt_encodeFilterExp(
    destination: ?*anyopaque,
    count: usize,
    stride: usize,
    bits: c_int,
    data: ?[*]const f32,
    mode: EncodeExpMode,
) void;
pub extern fn meshopt_encodeFilterColor(
    destination: ?*anyopaque,
    count: usize,
    stride: usize,
    bits: c_int,
    data: ?[*]const f32,
) void;

pub extern fn meshopt_simplify(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: ?*f32,
) usize;
pub extern fn meshopt_simplifyWithAttributes(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_attributes: ?[*]const f32,
    vertex_attributes_stride: usize,
    attribute_weights: ?[*]const f32,
    attribute_count: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: ?*f32,
) usize;
pub extern fn meshopt_simplifyWithUpdate(
    indices: ?[*]u32,
    index_count: usize,
    vertex_positions: ?[*]f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_attributes: ?[*]f32,
    vertex_attributes_stride: usize,
    attribute_weights: ?[*]const f32,
    attribute_count: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: ?*f32,
) usize;
pub extern fn meshopt_simplifySloppy(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    result_error: ?*f32,
) usize;
pub extern fn meshopt_simplifyPrune(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    target_error: f32,
) usize;
pub extern fn meshopt_simplifyPoints(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_colors: ?[*]const f32,
    vertex_colors_stride: usize,
    color_weight: f32,
    target_vertex_count: usize,
) usize;
pub extern fn meshopt_simplifyScale(
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) f32;

pub extern fn meshopt_stripify(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    restart_index: u32,
) usize;
pub extern fn meshopt_stripifyBound(index_count: usize) usize;
pub extern fn meshopt_unstripify(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    restart_index: u32,
) usize;
pub extern fn meshopt_unstripifyBound(index_count: usize) usize;

pub extern fn meshopt_analyzeVertexCache(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    cache_size: u32,
    warp_size: u32,
    primgroup_size: u32,
) VertexCacheStatistics;
pub extern fn meshopt_analyzeVertexFetch(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    vertex_size: usize,
) VertexFetchStatistics;
pub extern fn meshopt_analyzeOverdraw(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) OverdrawStatistics;
pub extern fn meshopt_analyzeCoverage(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) CoverageStatistics;

pub extern fn meshopt_buildMeshlets(
    meshlets: ?[*]Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    max_vertices: usize,
    max_triangles: usize,
    cone_weight: f32,
) usize;
pub extern fn meshopt_buildMeshletsScan(
    meshlets: ?[*]Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_count: usize,
    max_vertices: usize,
    max_triangles: usize,
) usize;
pub extern fn meshopt_buildMeshletsBound(
    index_count: usize,
    max_vertices: usize,
    max_triangles: usize,
) usize;
pub extern fn meshopt_buildMeshletsFlex(
    meshlets: ?[*]Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,
    cone_weight: f32,
    split_factor: f32,
) usize;
pub extern fn meshopt_buildMeshletsSpatial(
    meshlets: ?[*]Meshlet,
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,
    fill_weight: f32,
) usize;
pub extern fn meshopt_optimizeMeshlet(
    meshlet_vertices: ?[*]u32,
    meshlet_triangles: ?[*]u8,
    triangle_count: usize,
    vertex_count: usize,
) void;
pub extern fn meshopt_optimizeMeshletLevel(
    meshlet_vertices: ?[*]u32,
    vertex_count: usize,
    meshlet_triangles: ?[*]u8,
    triangle_count: usize,
    level: c_int,
) void;
pub extern fn meshopt_computeClusterBounds(
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) Bounds;
pub extern fn meshopt_computeMeshletBounds(
    meshlet_vertices: ?[*]const u32,
    meshlet_triangles: ?[*]const u8,
    triangle_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) Bounds;
pub extern fn meshopt_computeSphereBounds(
    positions: ?[*]const f32,
    count: usize,
    positions_stride: usize,
    radii: ?[*]const f32,
    radii_stride: usize,
) Bounds;
pub extern fn meshopt_extractMeshletIndices(
    vertices: ?[*]u32,
    triangles: ?[*]u8,
    indices: ?[*]const u32,
    index_count: usize,
) usize;
pub extern fn meshopt_partitionClusters(
    destination: ?[*]u32,
    cluster_indices: ?[*]const u32,
    total_index_count: usize,
    cluster_index_counts: ?[*]const u32,
    cluster_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    target_partition_size: usize,
) usize;

pub extern fn meshopt_spatialSortRemap(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void;
pub extern fn meshopt_spatialSortTriangles(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) void;
pub extern fn meshopt_spatialClusterPoints(
    destination: ?[*]u32,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    cluster_size: usize,
) void;

pub extern fn meshopt_opacityMapMeasure(
    levels: ?[*]u8,
    sources: ?[*]u32,
    omm_indices: ?[*]c_int,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_uvs: ?[*]const f32,
    vertex_count: usize,
    vertex_uvs_stride: usize,
    texture_width: u32,
    texture_height: u32,
    max_level: c_int,
    target_edge: f32,
) usize;
pub extern fn meshopt_opacityMapRasterize(
    result: ?[*]u8,
    level: c_int,
    states: c_int,
    uv0: ?[*]const f32,
    uv1: ?[*]const f32,
    uv2: ?[*]const f32,
    texture_data: ?[*]const u8,
    texture_stride: usize,
    texture_pitch: usize,
    texture_width: u32,
    texture_height: u32,
) void;
pub extern fn meshopt_opacityMapEntrySize(level: c_int, states: c_int) usize;
pub extern fn meshopt_opacityMapCompact(
    data: ?[*]u8,
    data_size: usize,
    levels: ?[*]u8,
    offsets: ?[*]u32,
    omm_count: usize,
    omm_indices: ?[*]c_int,
    triangle_count: usize,
    states: c_int,
) usize;

pub extern fn meshopt_generateTangents(
    result: ?[*]f32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_normals: ?[*]const f32,
    vertex_normals_stride: usize,
    vertex_uvs: ?[*]const f32,
    vertex_uvs_stride: usize,
    options: u32,
) void;
pub extern fn meshopt_generateNormals(
    result: ?[*]f32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    crease_angle: f32,
    smoothing: f32,
) void;
pub extern fn meshopt_remesh(
    destination: ?[*]f32,
    max_triangle_count: usize,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    resolution: c_int,
    options: u32,
) usize;

pub extern fn meshopt_quantizeHalf(v: f32) u16;
pub extern fn meshopt_quantizeFloat(v: f32, N: c_int) f32;
pub extern fn meshopt_dequantizeHalf(h: u16) f32;
pub extern fn meshopt_computePositionExponent(
    minv: *const [3]f32,
    maxv: *const [3]f32,
    min_exp: c_int,
    max_bits: c_int,
) c_int;

/// meshoptimizer.h's inline C++ quantizers, exported by test/reference.cpp.
pub extern fn reference_quantizeUnorm(v: f32, N: c_int) c_int;
pub extern fn reference_quantizeSnorm(v: f32, N: c_int) c_int;
pub extern fn reference_quantizeUnormArray(
    destination: [*]c_int,
    values: [*]const f32,
    count: usize,
    N: c_int,
) void;
pub extern fn reference_quantizeSnormArray(
    destination: [*]c_int,
    values: [*]const f32,
    count: usize,
    N: c_int,
) void;

/// meshoptimizer.h's `MESHOPTIMIZER_VERSION`, from test/reference.cpp.
pub extern fn reference_version() c_int;

/// The function under meshopt_simplify, meshopt_simplifyWithAttributes and
/// meshopt_simplifyWithUpdate, with the internal option bits: simplifier.cpp
/// defines it with C++ linkage and the header leaves it out, so
/// test/reference.cpp exports it under a C name.
pub extern fn reference_simplifyEdge(
    destination: ?[*]u32,
    indices: ?[*]const u32,
    index_count: usize,
    vertex_positions: ?[*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_attributes: ?[*]const f32,
    vertex_attributes_stride: usize,
    attribute_weights: ?[*]const f32,
    attribute_count: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: ?*f32,
) usize;
