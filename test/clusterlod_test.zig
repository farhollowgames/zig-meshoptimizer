//! The cluster LOD builder against the original's demo/clusterlod.h: every
//! group and cluster `build` hands to output, in order, with their bounds
//! bit for bit, their indices and vertex counts, and the ids output
//! returned as the clusters record them; the vertices after the build,
//! which dilation moves; `localIndices` on every cluster; and
//! `buildHierarchy` over the groups at several node widths, its node
//! buffers compared whole. On the demo mesh and generated ones with every
//! option alone and in the demo's combinations, with and without
//! attributes and vertex flags; on edge cases; and on seeded fuzzing. Every
//! port call runs again into fresh outputs, which must come out the same.

const std = @import("std");
const mo = @import("meshoptimizer");
const c = @import("upstream");
const meshes = @import("meshes");
const common = @import("common.zig");
const fuzzed = @import("fuzzed_meshes.zig");

const clod = mo.clusterlod;
const gpa = common.gpa;
const float_max = std.math.floatMax(f32);

// The hierarchy checks hand the original's groups to the port as they are,
// and compare its nodes with the port's as they are.
comptime {
    std.debug.assert(@sizeOf(clod.Bounds) == @sizeOf(c.ClodBounds));
    std.debug.assert(@sizeOf(clod.Group) == @sizeOf(c.ClodGroup));
    std.debug.assert(@offsetOf(clod.Group, "simplified") == @offsetOf(c.ClodGroup, "simplified"));
    std.debug.assert(@sizeOf(clod.Node) == @sizeOf(c.ClodNode));
    std.debug.assert(@offsetOf(clod.Node, "group") == @offsetOf(c.ClodNode, "group"));
    std.debug.assert(@offsetOf(clod.Node, "child_count") == @offsetOf(c.ClodNode, "child_count"));
}

/// The ids output returns for the groups, by the order it gets them.
const Ids = enum {
    /// Each group's index, as the original's demo returns.
    sequential,
    /// Ids that jump about, among them -1, which the clusters simplified
    /// from a group then record as if they were the mesh's own, and other
    /// negative ones.
    scattered,
    /// -1 for every group, as the original gives without an output.
    none,

    fn of(self: Ids, group: usize) i32 {
        const index: i32 = @intCast(group);
        return switch (self) {
            .sequential => index,
            .scattered => switch (group % 4) {
                0 => std.math.maxInt(i32) - index,
                1 => -1,
                2 => -2 - index,
                else => index * 3,
            },
            .none => -1,
        };
    }

    /// The schemes in turn, by `i`.
    fn cycle(i: usize) Ids {
        const all = std.enums.values(Ids);
        return all[i % all.len];
    }
};

/// A group as output got it, its floats as their bits.
const GroupRecord = extern struct {
    depth: i32,
    bounds: [5]u32,
    cluster_count: u32,
    /// What output returned for it.
    id: i32,
};

/// A cluster as output got it; its indices follow those of the clusters
/// before it in `Record.indices`.
const ClusterRecord = extern struct {
    refined: i32,
    bounds: [5]u32,
    index_count: u32,
    vertex_count: u32,
};

/// Everything one build hands to output, in order.
const Record = struct {
    ids: Ids,
    groups: std.ArrayList(GroupRecord) = .empty,
    clusters: std.ArrayList(ClusterRecord) = .empty,
    indices: std.ArrayList(u32) = .empty,
    /// The original's output cannot return an error; it lands here.
    failed: bool = false,

    fn deinit(self: *Record) void {
        self.groups.deinit(gpa);
        self.clusters.deinit(gpa);
        self.indices.deinit(gpa);
        self.* = undefined;
    }

    fn addGroup(self: *Record, depth: i32, bounds: [5]u32, cluster_count: usize) !i32 {
        const id = self.ids.of(self.groups.items.len);
        try self.groups.append(gpa, .{
            .depth = depth,
            .bounds = bounds,
            .cluster_count = @intCast(cluster_count),
            .id = id,
        });
        return id;
    }

    fn addCluster(
        self: *Record,
        refined: i32,
        bounds: [5]u32,
        indices: []const u32,
        vertex_count: usize,
    ) !void {
        try self.clusters.append(gpa, .{
            .refined = refined,
            .bounds = bounds,
            .index_count = @intCast(indices.len),
            .vertex_count = @intCast(vertex_count),
        });
        try self.indices.appendSlice(gpa, indices);
    }

    /// The port's output.
    pub fn output(self: *Record, group: clod.Group, clusters: []const clod.Cluster) !i32 {
        const id = try self.addGroup(group.depth, bitsOf(group.simplified), clusters.len);
        for (clusters) |cluster| {
            try self.addCluster(
                cluster.refined,
                bitsOf(cluster.bounds),
                cluster.indices,
                cluster.vertex_count,
            );
        }
        return id;
    }

    /// The groups, as the hierarchy builders take them. The caller frees
    /// them.
    fn groupList(self: Record) ![]c.ClodGroup {
        const result = try gpa.alloc(c.ClodGroup, self.groups.items.len);
        for (self.groups.items, result) |record, *group| {
            group.* = .{
                .depth = record.depth,
                .simplified = std.mem.bytesToValue(c.ClodBounds, std.mem.asBytes(&record.bounds)),
            };
        }
        return result;
    }
};

/// The original's output.
fn originalOutput(
    context: ?*anyopaque,
    group: *const c.ClodGroup,
    clusters: [*]const c.ClodCluster,
    cluster_count: usize,
) callconv(.c) c_int {
    const record: *Record = @ptrCast(@alignCast(context.?));
    return originalAdd(record, group.*, clusters[0..cluster_count]) catch {
        record.failed = true;
        return -1;
    };
}

fn originalAdd(record: *Record, group: c.ClodGroup, clusters: []const c.ClodCluster) !i32 {
    const id = try record.addGroup(group.depth, bitsOf(group.simplified), clusters.len);
    for (clusters) |cluster| {
        const indices = cluster.indices.?[0..cluster.index_count];
        const bounds = bitsOf(cluster.bounds);
        try record.addCluster(cluster.refined, bounds, indices, cluster.vertex_count);
    }
    return id;
}

/// The floats of `bounds`, the port's or the original's, as their bits.
fn bitsOf(bounds: anytype) [5]u32 {
    return std.mem.bytesToValue([5]u32, std.mem.asBytes(&bounds));
}

fn originalConfig(config: clod.Config) c.ClodConfig {
    var result = std.mem.zeroes(c.ClodConfig);
    inline for (@typeInfo(c.ClodConfig).@"struct".field_names) |name| {
        @field(result, name) = @field(config, name);
    }
    return result;
}

fn flagsOf(locks: ?[]const u8) ?[]const mo.SimplifyVertexFlags {
    const list = locks orelse return null;
    return @ptrCast(list);
}

/// Where a build's attributes are.
const Attributes = union(enum) {
    none,
    /// In the vertex buffer, from this float of each vertex.
    interleaved: usize,
    /// In a buffer of their own, `stride` floats per vertex.
    separate: struct { data: []const f32, stride: usize },
};

/// A build's mesh, as both sides take it.
const Input = struct {
    indices: []const u32,
    /// The vertices, `stride` floats each, the position first.
    vertices: []const f32,
    stride: usize,
    attributes: Attributes = .none,
    weights: []const f32 = &.{},
    protect_mask: u32 = 0,
    /// The original's flag bytes, one per vertex.
    locks: ?[]const u8 = null,
    /// Give the port writable positions even when it does not dilate.
    writable: bool = false,

    fn vertexCount(self: Input) usize {
        return self.vertices.len / self.stride;
    }

    /// The mesh as the port takes it, over `vertices`, a copy of the
    /// input's.
    fn port(self: Input, vertices: []f32, writable: bool) clod.Mesh {
        return .{
            .indices = self.indices,
            .positions = .init(vertices, self.stride),
            .positions_mut = if (writable) .init(vertices, self.stride) else null,
            .attributes = switch (self.attributes) {
                .none => .{ .data = &.{}, .stride = 1 },
                .interleaved => |offset| .{
                    .data = if (vertices.len == 0) &.{} else vertices[offset..],
                    .stride = self.stride,
                },
                .separate => |separate| .init(separate.data, separate.stride),
            },
            .vertex_lock = flagsOf(self.locks),
            .attribute_weights = self.weights,
            .attribute_protect_mask = self.protect_mask,
        };
    }

    /// The mesh as the original takes it, over `vertices`, a copy of the
    /// input's.
    fn original(self: Input, vertices: []const f32) c.ClodMesh {
        var attributes: ?[*]const f32 = null;
        var attribute_stride: usize = 0;
        switch (self.attributes) {
            .none => {},
            .interleaved => |offset| {
                attributes = vertices.ptr + offset;
                attribute_stride = self.stride;
            },
            .separate => |separate| {
                attributes = separate.data.ptr;
                attribute_stride = separate.stride;
            },
        }
        return .{
            .indices = self.indices.ptr,
            .index_count = self.indices.len,
            .vertex_count = self.vertexCount(),
            .vertex_positions = vertices.ptr,
            .vertex_positions_stride = self.stride * @sizeOf(f32),
            .vertex_attributes = attributes,
            .vertex_attributes_stride = attribute_stride * @sizeOf(f32),
            .vertex_lock = if (self.locks) |locks| locks.ptr else null,
            .attribute_weights = if (self.weights.len > 0) self.weights.ptr else null,
            .attribute_count = self.weights.len,
            .attribute_protect_mask = self.protect_mask,
        };
    }
};

/// Node widths the builds' hierarchies are checked at.
const node_widths = [_]usize{ 2, 3, 4, 8, 16, 64 };

/// One build on both sides, the port again into fresh outputs, then
/// `localIndices` on the clusters and hierarchies over the groups.
fn checkBuild(input: Input, config: clod.Config, ids: Ids) !void {
    // Each build dilates its own copy of the positions.
    const want_vertices = try gpa.dupe(f32, input.vertices);
    defer gpa.free(want_vertices);
    const got_vertices = try gpa.dupe(f32, input.vertices);
    defer gpa.free(got_vertices);
    const again_vertices = try gpa.dupe(f32, input.vertices);
    defer gpa.free(again_vertices);
    const writable = input.writable or config.simplify_dilate_borders;

    var want: Record = .{ .ids = ids };
    defer want.deinit();
    const original_config = originalConfig(config);
    const original_mesh = input.original(want_vertices);
    c.reference_clodBuild(&original_config, &original_mesh, &want, &originalOutput);
    if (want.failed) return error.OutOfMemory;

    var got: Record = .{ .ids = ids };
    defer got.deinit();
    try clod.build(gpa, config, input.port(got_vertices, writable), &got);

    try common.expectSame(GroupRecord, "groups", want.groups.items, got.groups.items);
    try common.expectSame(ClusterRecord, "clusters", want.clusters.items, got.clusters.items);
    try common.expectSame(u32, "cluster indices", want.indices.items, got.indices.items);
    try common.expectSame(f32, "vertices after the build", want_vertices, got_vertices);

    var again: Record = .{ .ids = ids };
    defer again.deinit();
    try clod.build(gpa, config, input.port(again_vertices, writable), &again);
    try common.expectSame(GroupRecord, "groups, rerun", got.groups.items, again.groups.items);
    try common.expectSame(
        ClusterRecord,
        "clusters, rerun",
        got.clusters.items,
        again.clusters.items,
    );
    try common.expectSame(u32, "cluster indices, rerun", got.indices.items, again.indices.items);
    try common.expectSame(f32, "vertices, rerun", got_vertices, again_vertices);

    try checkLocalIndices(want);
    const groups = try want.groupList();
    defer gpa.free(groups);
    try checkHierarchies(groups, &node_widths);
}

/// `localIndices` on every cluster of `record` against the original's,
/// its count against the cluster's vertex count; the buffers compared
/// whole, then the port again into buffers of another fill.
fn checkLocalIndices(record: Record) !void {
    var want_vertices: [256]u32 = undefined;
    var got_vertices: [256]u32 = undefined;
    var again_vertices: [256]u32 = undefined;
    var want_triangles: [512 * 3]u8 = undefined;
    var got_triangles: [512 * 3]u8 = undefined;
    var again_triangles: [512 * 3]u8 = undefined;

    var offset: usize = 0;
    for (record.clusters.items) |cluster| {
        const indices = record.indices.items[offset..][0..cluster.index_count];
        offset += indices.len;

        @memset(std.mem.asBytes(&want_vertices), fuzzed.first_fill);
        @memset(std.mem.asBytes(&got_vertices), fuzzed.first_fill);
        @memset(std.mem.asBytes(&again_vertices), fuzzed.second_fill);
        @memset(&want_triangles, fuzzed.first_fill);
        @memset(&got_triangles, fuzzed.first_fill);
        @memset(&again_triangles, fuzzed.second_fill);

        const want_count = c.clodLocalIndices(
            &want_vertices,
            &want_triangles,
            indices.ptr,
            indices.len,
        );
        const got_count = clod.localIndices(&got_vertices, &got_triangles, indices);
        try common.expectSameValue(usize, "local vertex count", want_count, got_count);
        try common.expectSameValue(
            usize,
            "local vertex count against the cluster's",
            cluster.vertex_count,
            got_count,
        );
        try common.expectSame(u32, "local vertices", &want_vertices, &got_vertices);
        try common.expectSame(u8, "local triangles", &want_triangles, &got_triangles);

        const again_count = clod.localIndices(&again_vertices, &again_triangles, indices);
        try common.expectSameValue(usize, "local vertex count, rerun", got_count, again_count);
        try fuzzed.expectRerunSame(
            "local vertices",
            std.mem.asBytes(&got_vertices),
            std.mem.asBytes(&again_vertices),
        );
        try fuzzed.expectRerunSame("local triangles", &got_triangles, &again_triangles);
    }
}

/// `buildHierarchy` over `groups` at each of `widths` against the
/// original: the bounds, the node counts, and the node buffers whole,
/// unwritten nodes included; then the port again into a buffer of another
/// fill.
fn checkHierarchies(groups: []const c.ClodGroup, widths: []const usize) !void {
    var level_count: usize = 0;
    for (groups) |group| level_count = @max(level_count, @as(usize, @intCast(group.depth)) + 1);
    const port_groups: []const clod.Group = @ptrCast(groups);

    for (widths) |width| {
        const bound = c.clodBuildHierarchyBound(groups.len, width, level_count);
        const port_bound = clod.buildHierarchyBound(groups.len, width, level_count);
        try common.expectSameValue(usize, "hierarchy bound", bound, port_bound);

        const want = try gpa.alloc(c.ClodNode, bound);
        defer gpa.free(want);
        const got = try gpa.alloc(clod.Node, bound);
        defer gpa.free(got);
        const again = try gpa.alloc(clod.Node, bound);
        defer gpa.free(again);
        @memset(std.mem.sliceAsBytes(want), fuzzed.first_fill);
        @memset(std.mem.sliceAsBytes(got), fuzzed.first_fill);
        @memset(std.mem.sliceAsBytes(again), fuzzed.second_fill);

        const want_count = c.clodBuildHierarchy(
            want.ptr,
            groups.ptr,
            groups.len,
            width,
            level_count,
        );
        const got_count = try clod.buildHierarchy(gpa, got, port_groups, width, level_count);
        try common.expectSameValue(usize, "hierarchy nodes", want_count, got_count);
        try common.expectSame(clod.Node, "hierarchy", @ptrCast(want), got);

        const again_count = try clod.buildHierarchy(gpa, again, port_groups, width, level_count);
        try common.expectSameValue(usize, "hierarchy nodes, rerun", got_count, again_count);
        try fuzzed.expectRerunSame(
            "hierarchy",
            std.mem.sliceAsBytes(got),
            std.mem.sliceAsBytes(again),
        );
    }
}

/// A config to check, named for failure messages: changes from a base.
const Variant = struct {
    base: []const u8 = "",
    name: []const u8,
    config: clod.Config,
};

/// `base` with the fields of `changes` set.
fn variant(name: []const u8, base: clod.Config, changes: anytype) Variant {
    var config = base;
    inline for (@typeInfo(@TypeOf(changes)).@"struct".field_names) |field| {
        @field(config, field) = @field(changes, field);
    }
    return .{ .name = name, .config = config };
}

const raster = clod.defaultConfig(128);
const ray_tracing = clod.defaultConfigRT(128);

/// Each option changed alone from `base`.
fn alone(comptime base_name: []const u8, comptime base: clod.Config) [option_count]Variant {
    var list: [option_count]Variant = .{
        variant("partition_spatial off", base, .{ .partition_spatial = false }),
        variant("partition_sort", base, .{ .partition_sort = true }),
        variant("partition_size 1", base, .{ .partition_size = 1 }),
        variant("partition_size 4", base, .{ .partition_size = 4 }),
        variant("partition_size 24", base, .{ .partition_size = 24 }),
        variant("partition_size 48", base, .{ .partition_size = 48 }),
        variant("cluster_spatial", base, .{ .cluster_spatial = true }),
        variant("cluster_spatial, fill 1", base, .{
            .cluster_spatial = true,
            .cluster_fill_weight = 1,
        }),
        variant("cluster_split_factor 0", base, .{ .cluster_split_factor = 0 }),
        variant("cluster_split_factor 1", base, .{ .cluster_split_factor = 1 }),
        variant("simplify_ratio 0", base, .{ .simplify_ratio = 0 }),
        variant("simplify_ratio 0.25", base, .{ .simplify_ratio = 0.25 }),
        variant("simplify_ratio 0.75", base, .{ .simplify_ratio = 0.75 }),
        variant("simplify_ratio 1", base, .{ .simplify_ratio = 1 }),
        variant("simplify_threshold 0", base, .{ .simplify_threshold = 0 }),
        variant("simplify_threshold 0.5", base, .{ .simplify_threshold = 0.5 }),
        variant("simplify_threshold 0.95", base, .{ .simplify_threshold = 0.95 }),
        variant("simplify_error_merge_previous 0.5", base, .{
            .simplify_error_merge_previous = 0.5,
        }),
        variant("simplify_error_merge_previous 1.5", base, .{
            .simplify_error_merge_previous = 1.5,
        }),
        variant("simplify_error_merge_additive 0.25", base, .{
            .simplify_error_merge_additive = 0.25,
        }),
        variant("simplify_error_merge_additive 1", base, .{
            .simplify_error_merge_additive = 1,
        }),
        variant("simplify_error_factor_sloppy 1", base, .{ .simplify_error_factor_sloppy = 1 }),
        variant("simplify_error_factor_sloppy 4", base, .{ .simplify_error_factor_sloppy = 4 }),
        variant("simplify_error_edge_limit 0.5", base, .{ .simplify_error_edge_limit = 0.5 }),
        variant("simplify_error_edge_limit 2", base, .{ .simplify_error_edge_limit = 2 }),
        variant("simplify_error_edge_limit 10", base, .{ .simplify_error_edge_limit = 10 }),
        variant("simplify_error_clamped off", base, .{ .simplify_error_clamped = false }),
        variant("simplify_permissive off", base, .{ .simplify_permissive = false }),
        variant("simplify_fallback_permissive", base, .{ .simplify_fallback_permissive = true }),
        variant("simplify_fallback_sloppy off", base, .{ .simplify_fallback_sloppy = false }),
        variant("simplify_regularize", base, .{ .simplify_regularize = true }),
        variant("simplify_preserve_folds", base, .{ .simplify_preserve_folds = true }),
        variant("simplify_dilate_borders", base, .{ .simplify_dilate_borders = true }),
        variant("optimize_bounds", base, .{ .optimize_bounds = true }),
        variant("optimize_clusters off", base, .{ .optimize_clusters = false }),
        variant("optimize_clusters_level 0", base, .{ .optimize_clusters_level = 0 }),
        variant("optimize_clusters_level 2", base, .{ .optimize_clusters_level = 2 }),
        variant("optimize_clusters_level 3", base, .{ .optimize_clusters_level = 3 }),
        variant("optimize_clusters_level 4", base, .{ .optimize_clusters_level = 4 }),
        variant("optimize_clusters_level 5", base, .{ .optimize_clusters_level = 5 }),
        variant("optimize_clusters_level 6", base, .{ .optimize_clusters_level = 6 }),
        variant("optimize_clusters_level 7", base, .{ .optimize_clusters_level = 7 }),
        variant("optimize_clusters_level 8", base, .{ .optimize_clusters_level = 8 }),
        variant("optimize_clusters_level 9", base, .{ .optimize_clusters_level = 9 }),
    };
    for (&list) |*v| v.base = base_name;
    return list;
}

const option_count = 44;

/// The default configs, each option changed alone, and options together,
/// among them the original demo's.
const variants = defaults ++ alone("defaultConfig(128)", raster) ++
    alone("defaultConfig(32)", clod.defaultConfig(32)) ++ combinations;

const defaults = [_]Variant{
    variant("defaultConfig(128)", raster, .{}),
    variant("defaultConfigRT(128)", ray_tracing, .{}),
    variant("defaultConfig(4)", clod.defaultConfig(4), .{}),
    variant("defaultConfig(64)", clod.defaultConfig(64), .{}),
    variant("defaultConfig(256)", clod.defaultConfig(256), .{}),
    variant("defaultConfigRT(4)", clod.defaultConfigRT(4), .{}),
    variant("defaultConfigRT(64)", clod.defaultConfigRT(64), .{}),
    variant("defaultConfigRT(256)", clod.defaultConfigRT(256), .{}),
};

const combinations = [_]Variant{
    // Permissive simplification only where the regular one gets stuck,
    // with and without the sloppy one after it; and no fallback at all.
    variant("fallback permissive", raster, .{
        .simplify_permissive = false,
        .simplify_fallback_permissive = true,
    }),
    variant("fallback permissive, not sloppy", raster, .{
        .simplify_permissive = false,
        .simplify_fallback_permissive = true,
        .simplify_fallback_sloppy = false,
    }),
    variant("no fallback", raster, .{
        .simplify_permissive = false,
        .simplify_fallback_sloppy = false,
    }),
    variant("fallback sloppy alone, small clusters", clod.defaultConfig(8), .{
        .simplify_permissive = false,
        .simplify_error_factor_sloppy = 3,
    }),
    // The original demo's ray tracing settings, with its fill weights.
    variant("defaultConfigRT(128), fill 0", ray_tracing, .{ .cluster_fill_weight = 0 }),
    variant("defaultConfigRT(128), fill 0.25", ray_tracing, .{ .cluster_fill_weight = 0.25 }),
    variant("defaultConfigRT(128), fill 1", ray_tracing, .{ .cluster_fill_weight = 1 }),
    variant("dilate, optimize bounds, sorted partitions", raster, .{
        .simplify_dilate_borders = true,
        .optimize_bounds = true,
        .partition_sort = true,
    }),
    variant("dilate, not permissive", raster, .{
        .simplify_dilate_borders = true,
        .simplify_permissive = false,
    }),
    variant("regularize, preserve folds, edge limit", raster, .{
        .simplify_regularize = true,
        .simplify_preserve_folds = true,
        .simplify_error_edge_limit = 1,
    }),
    variant("defaultConfigRT(128), dilate, optimize bounds", ray_tracing, .{
        .simplify_dilate_borders = true,
        .optimize_bounds = true,
    }),
};

/// What a build gets beside positions.
const Setup = enum {
    plain,
    /// The original demo's attributes.
    attributes,
    /// Vertex flags: some vertices locked, some protected, some with
    /// priority.
    flags,
    both,
};

/// The original demo's attributes, from the normal of each vertex: the
/// normal at half weight, and seams of the texture coordinates after it
/// protected.
const demo_weights = [_]f32{ 0.5, 0.5, 0.5 };
const demo_protect_mask: u32 = (1 << 3) | (1 << 4);

/// `mesh` with `setup`; `flags` has a byte for each vertex.
fn meshInput(mesh: meshes.Mesh, setup: Setup, flags: []const u8) Input {
    const with_attributes = setup == .attributes or setup == .both;
    const with_flags = setup == .flags or setup == .both;
    return .{
        .indices = mesh.indices,
        .vertices = common.floatsOf(mesh.vertices),
        .stride = common.vertex_floats,
        .attributes = if (with_attributes) .{ .interleaved = 3 } else .none,
        .weights = if (with_attributes) &demo_weights else &.{},
        .protect_mask = if (with_attributes) demo_protect_mask else 0,
        .locks = if (with_flags) flags else null,
    };
}

/// Flags for `count` vertices from `seed`: about one vertex in twelve
/// locked, one in eight protected and one in eight with priority. The
/// caller frees them.
fn randomFlags(seed: u64, count: usize) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const flags = try gpa.alloc(u8, count);
    for (flags) |*flag| {
        const value: mo.SimplifyVertexFlags = .{
            .lock = rng.uintLessThan(u32, 12) == 0,
            .protect = rng.uintLessThan(u32, 8) == 0,
            .priority = rng.uintLessThan(u32, 8) == 0,
        };
        flag.* = @bitCast(value);
    }
    return flags;
}

/// A grid of `n` by `n` quads folded back on itself along x = 0.5: the
/// right half lies over the left, a little above it and facing the other
/// way, so the triangles on either side of the fold face apart.
fn foldedGrid(n: u32) !meshes.Mesh {
    const mesh = try meshes.grid(gpa, n);
    for (mesh.vertices) |*v| {
        if (v.px <= 0.5) continue;
        v.pz = (v.px - 0.5) * 0.1;
        v.px = 1 - v.px;
    }
    return mesh;
}

/// `mesh` with noise from `seed` on its normals and texture coordinates,
/// so attribute errors differ everywhere.
fn addNoise(mesh: meshes.Mesh, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    for (mesh.vertices) |*v| {
        v.nx += (rng.float(f32) - 0.5) * 0.2;
        v.ny += (rng.float(f32) - 0.5) * 0.2;
        v.nz += (rng.float(f32) - 0.5) * 0.2;
        v.tx += (rng.float(f32) - 0.5) * 0.02;
        v.ty += (rng.float(f32) - 0.5) * 0.02;
    }
}

/// The meshes every variant runs on.
const TestMeshes = struct {
    meshes: [count]meshes.Mesh,

    const count = 6;
    const names = [count][]const u8{
        "pirate",
        "sphere",
        "grid",
        "folded grid",
        "noisy sphere",
        "random soup",
    };

    fn init() !TestMeshes {
        var set: TestMeshes = undefined;
        var made: usize = 0;
        errdefer for (set.meshes[0..made]) |*m| m.deinit(gpa);

        set.meshes[0] = try common.pirate();
        made += 1;
        set.meshes[1] = try meshes.sphere(gpa, 16, 32);
        made += 1;
        set.meshes[2] = try meshes.grid(gpa, 24);
        made += 1;
        set.meshes[3] = try foldedGrid(24);
        made += 1;
        set.meshes[4] = try meshes.sphere(gpa, 16, 32);
        addNoise(set.meshes[4], 4);
        made += 1;
        set.meshes[5] = try meshes.random(gpa, 7, 400, 800);
        made += 1;
        return set;
    }

    fn deinit(self: *TestMeshes) void {
        for (&self.meshes) |*m| m.deinit(gpa);
    }
};

test "the structs have the original's layout" {
    var sizes: [6]usize = undefined;
    c.reference_clodSizes(&sizes);
    try common.expectSame(usize, "struct sizes", &sizes, &.{
        @sizeOf(c.ClodConfig),
        @sizeOf(c.ClodMesh),
        @sizeOf(c.ClodBounds),
        @sizeOf(c.ClodCluster),
        @sizeOf(c.ClodGroup),
        @sizeOf(c.ClodNode),
    });
}

test "defaultConfig and defaultConfigRT match the original" {
    for (4..257) |max_triangles| {
        var want: c.ClodConfig = undefined;
        c.reference_clodDefaultConfig(&want, max_triangles);
        try common.expectSameFields(want, clod.defaultConfig(max_triangles));
        c.reference_clodDefaultConfigRT(&want, max_triangles);
        try common.expectSameFields(want, clod.defaultConfigRT(max_triangles));
    }
}

test "buildHierarchyBound matches the original" {
    var group_count: usize = 0;
    while (group_count < 100_000) : (group_count = group_count * 2 + 1) {
        for ([_]usize{ 2, 3, 4, 7, 8, 16, 32, 64, 100 }) |width| {
            for ([_]usize{ 0, 1, 2, 5, 16, 40 }) |level_count| {
                try common.expectSameValue(
                    usize,
                    "buildHierarchyBound",
                    c.clodBuildHierarchyBound(group_count, width, level_count),
                    clod.buildHierarchyBound(group_count, width, level_count),
                );
            }
        }
    }
    // With one group at most, any width will do.
    for (0..2) |count| for (0..2) |width| for (0..3) |level_count| {
        try common.expectSameValue(
            usize,
            "buildHierarchyBound",
            c.clodBuildHierarchyBound(count, width, level_count),
            clod.buildHierarchyBound(count, width, level_count),
        );
    };
}

test "build matches the original with each option, on the demo mesh and generated ones" {
    var set: TestMeshes = try .init();
    defer set.deinit();

    for (set.meshes, TestMeshes.names, 0..) |mesh, name, m| {
        const flags = try randomFlags(m, mesh.vertices.len);
        defer gpa.free(flags);
        for (std.enums.values(Setup)) |setup| {
            for (variants, 0..) |v, i| {
                const ids: Ids = .cycle(i);
                checkBuild(meshInput(mesh, setup, flags), v.config, ids) catch |err| {
                    const message = "{s}, {s}, {s} {s}\n";
                    std.debug.print(message, .{ name, @tagName(setup), v.base, v.name });
                    return err;
                };
            }
        }
    }
}

test "build matches the original on large meshes" {
    var sphere = try meshes.sphere(gpa, 96, 192);
    defer sphere.deinit(gpa);
    var grid = try meshes.grid(gpa, 128);
    defer grid.deinit(gpa);
    addNoise(grid, 9);

    const large_variants = [_]Variant{
        variant("defaultConfig(128)", raster, .{}),
        variant("defaultConfigRT(128)", ray_tracing, .{}),
        variant("defaultConfig(32)", clod.defaultConfig(32), .{}),
        variant("dilate, optimize bounds, sorted partitions", raster, .{
            .simplify_dilate_borders = true,
            .optimize_bounds = true,
            .partition_sort = true,
        }),
        variant("fallback permissive", raster, .{
            .simplify_permissive = false,
            .simplify_fallback_permissive = true,
        }),
    };

    for ([_]meshes.Mesh{ sphere, grid }, [_][]const u8{ "sphere", "grid" }, 0..) |mesh, name, m| {
        const flags = try randomFlags(100 + m, mesh.vertices.len);
        defer gpa.free(flags);
        for ([_]Setup{ .attributes, .both }) |setup| {
            for (large_variants) |v| {
                checkBuild(meshInput(mesh, setup, flags), v.config, .sequential) catch |err| {
                    const message = "{s}, {s}, {s} {s}\n";
                    std.debug.print(message, .{ name, @tagName(setup), v.base, v.name });
                    return err;
                };
            }
        }
    }
}

/// The configs every edge case runs with.
const edge_variants = [_]Variant{
    variant("defaultConfig(128)", raster, .{}),
    variant("defaultConfigRT(128)", ray_tracing, .{}),
    variant("defaultConfig(4)", clod.defaultConfig(4), .{}),
    variant("defaultConfigRT(4), sorted partitions of 1", clod.defaultConfigRT(4), .{
        .partition_size = 1,
        .partition_sort = true,
    }),
    variant("dilate, optimize bounds, edge limit", raster, .{
        .simplify_dilate_borders = true,
        .optimize_bounds = true,
        .simplify_error_edge_limit = 1,
    }),
    variant("fallback permissive, not sloppy", raster, .{
        .simplify_permissive = false,
        .simplify_fallback_permissive = true,
        .simplify_fallback_sloppy = false,
    }),
    variant("no fallback, regularize, preserve folds", clod.defaultConfig(16), .{
        .simplify_permissive = false,
        .simplify_fallback_sloppy = false,
        .simplify_regularize = true,
        .simplify_preserve_folds = true,
    }),
};

fn checkEdgeCase(name: []const u8, input: Input) !void {
    for (edge_variants, 0..) |v, i| {
        const ids: Ids = .cycle(i);
        checkBuild(input, v.config, ids) catch |err| {
            std.debug.print("{s}, {s} {s}\n", .{ name, v.base, v.name });
            return err;
        };
    }
}

/// `mesh` as an input without attributes or flags.
fn plainInput(mesh: meshes.Mesh) Input {
    return meshInput(mesh, .plain, &.{});
}

test "build matches the original on edge cases" {
    const quad = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0 };

    try checkEdgeCase("no triangles", .{ .indices = &.{}, .vertices = &quad, .stride = 3 });
    try checkEdgeCase("no vertices", .{ .indices = &.{}, .vertices = &.{}, .stride = 3 });
    try checkEdgeCase("one triangle", .{
        .indices = &.{ 0, 1, 2 },
        .vertices = &quad,
        .stride = 3,
    });
    try checkEdgeCase("degenerate triangles", .{
        .indices = &.{ 0, 0, 0, 0, 0, 1, 1, 2, 2, 0, 1, 2, 3, 3, 3, 2, 1, 3 },
        .vertices = &quad,
        .stride = 3,
    });

    // One triangle over and over, and both of a quad.
    var repeated: [600]u32 = undefined;
    for (0..repeated.len / 3) |t| {
        repeated[t * 3 ..][0..3].* = if (t % 2 == 0) .{ 0, 1, 2 } else .{ 2, 1, 3 };
    }
    try checkEdgeCase("repeated triangles", .{
        .indices = &repeated,
        .vertices = &quad,
        .stride = 3,
    });

    // A strip of exactly one cluster's triangles at 128, and one more.
    inline for (.{ 64, 65 }) |n| {
        var strip = try meshes.grid(gpa, n);
        defer strip.deinit(gpa);
        const row = strip.indices[0 .. n * 6];
        try checkEdgeCase("strip", .{
            .indices = row,
            .vertices = common.floatsOf(strip.vertices),
            .stride = common.vertex_floats,
        });
    }

    // Small open sheets, and a sheet with every vertex locked.
    for ([_]u32{ 1, 2, 3, 8 }) |n| {
        var sheet = try meshes.grid(gpa, n);
        defer sheet.deinit(gpa);
        try checkEdgeCase("open sheet", plainInput(sheet));
    }
    {
        var sheet = try meshes.grid(gpa, 16);
        defer sheet.deinit(gpa);
        const locked = try gpa.alloc(u8, sheet.vertices.len);
        defer gpa.free(locked);
        @memset(locked, @bitCast(mo.SimplifyVertexFlags{ .lock = true }));
        try checkEdgeCase("every vertex locked", meshInput(sheet, .flags, locked));
        const protected = try gpa.alloc(u8, sheet.vertices.len);
        defer gpa.free(protected);
        @memset(protected, @bitCast(mo.SimplifyVertexFlags{ .protect = true, .priority = true }));
        try checkEdgeCase("every vertex protected", meshInput(sheet, .both, protected));
    }

    // Every vertex at one point; and collinear ones.
    {
        var point = try meshes.grid(gpa, 12);
        defer point.deinit(gpa);
        for (point.vertices) |*v| {
            v.px = 0.5;
            v.py = 0.5;
            v.pz = 0.5;
        }
        try checkEdgeCase("one point", plainInput(point));
        var line = try meshes.grid(gpa, 12);
        defer line.deinit(gpa);
        for (line.vertices) |*v| v.py = v.px;
        try checkEdgeCase("collinear", meshInput(line, .attributes, &.{}));
    }

    // Large coordinates far from the origin, and tiny ones.
    for ([_][2]f32{ .{ 2e5, 8e5 }, .{ 1e-3, 0 } }) |scale_offset| {
        var sheet = try meshes.sphere(gpa, 12, 24);
        defer sheet.deinit(gpa);
        const scale, const offset = scale_offset;
        for (sheet.vertices) |*v| {
            v.px = v.px * scale + offset;
            v.py = v.py * scale - offset;
            v.pz = v.pz * scale;
        }
        try checkEdgeCase("scaled", meshInput(sheet, .attributes, &.{}));
    }

    // Vertices that no triangle uses.
    {
        var sheet = try meshes.grid(gpa, 8);
        defer sheet.deinit(gpa);
        const vertices = try gpa.alloc(meshes.Vertex, sheet.vertices.len + 100);
        defer gpa.free(vertices);
        @memcpy(vertices[100..], sheet.vertices);
        for (vertices[0..100], 0..) |*v, i| v.* = sheet.vertices[i % sheet.vertices.len];
        const indices = try gpa.alloc(u32, sheet.indices.len);
        defer gpa.free(indices);
        for (sheet.indices, indices) |index, *moved| moved.* = index + 100;
        try checkEdgeCase("unused vertices", meshInput(
            .{ .vertices = vertices, .indices = indices },
            .attributes,
            &.{},
        ));
    }
}

test "build matches the original on other vertex layouts" {
    var sphere = try meshes.sphere(gpa, 12, 24);
    defer sphere.deinit(gpa);
    const n = sphere.vertices.len;

    // Positions packed, attributes in a buffer of their own: normals, then
    // texture coordinates, whose seams are protected.
    const positions = try common.packedPositions(sphere.vertices);
    defer gpa.free(positions);
    const attributes = try gpa.alloc(f32, n * 5);
    defer gpa.free(attributes);
    for (sphere.vertices, 0..) |v, i| {
        attributes[i * 5 ..][0..5].* = .{ v.nx, v.ny, v.nz, v.tx, v.ty };
    }
    try checkEdgeCase("packed positions, attributes apart", .{
        .indices = sphere.indices,
        .vertices = positions,
        .stride = 3,
        .attributes = .{ .separate = .{ .data = attributes, .stride = 5 } },
        .weights = &demo_weights,
        .protect_mask = demo_protect_mask,
    });
    // Protected seams without weights.
    try checkEdgeCase("protected seams alone", .{
        .indices = sphere.indices,
        .vertices = positions,
        .stride = 3,
        .attributes = .{ .separate = .{ .data = attributes, .stride = 5 } },
        .protect_mask = demo_protect_mask,
    });

    // Wide vertices: 20 floats, 16 attributes after the position, some of
    // no weight, every other one's seams protected.
    const stride = 20;
    const wide = try gpa.alloc(f32, n * stride);
    defer gpa.free(wide);
    var prng: std.Random.DefaultPrng = .init(5);
    const rng = prng.random();
    for (sphere.vertices, 0..) |v, i| {
        const vertex = wide[i * stride ..][0..stride];
        vertex[0..8].* = std.mem.bytesToValue([8]f32, std.mem.asBytes(&v));
        for (vertex[8..]) |*f| f.* = @floatFromInt(rng.uintLessThan(u32, 3));
    }
    var weights: [16]f32 = undefined;
    for (&weights, 0..) |*w, i| w.* = if (i % 5 == 4) 0 else 0.1 * @as(f32, @floatFromInt(i + 1));
    try checkEdgeCase("wide vertices", .{
        .indices = sphere.indices,
        .vertices = wide,
        .stride = stride,
        .attributes = .{ .interleaved = 3 },
        .weights = &weights,
        .protect_mask = 0x5555,
        .writable = true,
    });

    // The widest positions the original takes, 64 floats, without
    // attributes.
    const widest = try common.strided(positions, 64);
    defer gpa.free(widest);
    try checkEdgeCase("positions 64 floats apart", .{
        .indices = sphere.indices,
        .vertices = widest,
        .stride = 64,
    });
}

/// A config from `rng` within the original's limits: a default config,
/// or limits of its own, with each option changed or not.
fn fuzzConfig(rng: std.Random) clod.Config {
    const default_triangles = fuzzed.size(rng, 4, 256);
    var config = if (rng.boolean())
        clod.defaultConfig(default_triangles)
    else
        clod.defaultConfigRT(default_triangles);

    if (rng.uintLessThan(u32, 3) == 0) {
        config.max_vertices = fuzzed.size(rng, 3, 256);
        config.max_triangles = fuzzed.size(rng, 1, 512);
        config.min_triangles = fuzzed.size(rng, 1, config.max_triangles);
    }
    if (rng.boolean()) config.partition_spatial = rng.boolean();
    if (rng.boolean()) config.partition_sort = rng.boolean();
    if (rng.boolean()) config.partition_size = fuzzed.size(rng, 1, 40);
    if (rng.boolean()) config.cluster_spatial = rng.boolean();
    if (rng.boolean()) config.cluster_fill_weight = fuzzed.weight(rng);
    if (rng.boolean()) config.cluster_split_factor = fuzzed.weight(rng) * 4;
    if (rng.boolean()) config.simplify_ratio = fuzzed.weight(rng);
    // Under 1, or a level that keeps every triangle would never end; at
    // most 0.9, so each level loses at least a tenth.
    if (rng.boolean()) config.simplify_threshold = fuzzed.weight(rng) * 0.9;
    if (rng.boolean()) config.simplify_error_merge_previous = fuzzed.weight(rng) * 2;
    if (rng.boolean()) config.simplify_error_merge_additive = fuzzed.weight(rng);
    if (rng.boolean()) config.simplify_error_factor_sloppy = fuzzed.weight(rng) * 4;
    if (rng.boolean()) config.simplify_error_edge_limit = fuzzed.weight(rng) * 4;
    if (rng.boolean()) config.simplify_error_clamped = rng.boolean();
    if (rng.boolean()) config.simplify_permissive = rng.boolean();
    if (rng.boolean()) config.simplify_fallback_permissive = rng.boolean();
    if (rng.boolean()) config.simplify_fallback_sloppy = rng.boolean();
    if (rng.boolean()) config.simplify_regularize = rng.boolean();
    if (rng.boolean()) config.simplify_preserve_folds = rng.boolean();
    config.simplify_dilate_borders = rng.uintLessThan(u32, 3) == 0;
    if (rng.boolean()) config.optimize_bounds = rng.boolean();
    if (rng.boolean()) config.optimize_clusters = rng.boolean();
    if (rng.boolean()) config.optimize_clusters_level = rng.uintAtMost(u4, 9);
    return config;
}

/// One fuzzed mesh with a fuzzed config, attributes, flags and ids.
fn checkBuildFuzzed(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var fuzz_mesh = try fuzzed.mesh(rng);
    defer fuzz_mesh.deinit();
    const mesh = fuzz_mesh.mesh;
    // Positions finite and below 1e6, as the cluster bounds need; their
    // cone asserts on others.
    for (mesh.vertices) |*v| {
        for ([_]*f32{ &v.px, &v.py, &v.pz }) |x| {
            if (!std.math.isFinite(x.*) or @abs(x.*) > 1e6) x.* = 0;
        }
    }

    // Attributes from the normal, the five floats left in each vertex: up
    // to five weighed, and any of them with protected seams.
    var weights: [5]f32 = undefined;
    for (&weights) |*w| w.* = fuzzed.weight(rng);
    var input = meshInput(mesh, .plain, &.{});
    if (rng.uintLessThan(u32, 3) != 0) {
        input.attributes = .{ .interleaved = 3 };
        input.weights = weights[0..rng.uintAtMost(usize, weights.len)];
        if (rng.boolean()) input.protect_mask = rng.uintLessThan(u32, 1 << 5);
    }
    const flags = try randomFlags(rng.int(u64), mesh.vertices.len);
    defer gpa.free(flags);
    if (rng.boolean()) input.locks = flags;
    input.writable = rng.boolean();

    try checkBuild(input, fuzzConfig(rng), rng.enumValue(Ids));
}

test "build matches the original on fuzzed meshes and configs" {
    try common.fuzz("clusterlod.build", 0, checkBuildFuzzed);
}

/// Groups of every level up to a fuzzed count, at random points or on a
/// small lattice where centers tie, in random order, through
/// `buildHierarchy` at fuzzed widths.
fn checkHierarchyFuzzed(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const level_count = fuzzed.size(rng, 1, 12);
    const group_count = level_count + fuzzed.size(rng, 0, 600);
    const lattice = rng.boolean();

    const groups = try gpa.alloc(c.ClodGroup, group_count);
    defer gpa.free(groups);
    for (groups, 0..) |*group, i| {
        // The first groups give every level one.
        const depth = if (i < level_count) i else rng.uintLessThan(usize, level_count);
        var center: [3]f32 = undefined;
        for (&center) |*x| {
            x.* = if (lattice)
                @floatFromInt(rng.intRangeAtMost(i32, -3, 3))
            else
                (rng.float(f32) - 0.5) * 100;
        }
        group.* = .{
            .depth = @intCast(depth),
            .simplified = .{
                .center = center,
                .radius = rng.float(f32) * 10,
                .@"error" = if (rng.uintLessThan(u32, 8) == 0) float_max else rng.float(f32),
            },
        };
    }
    rng.shuffle(c.ClodGroup, groups);

    const widths = [_]usize{ fuzzed.size(rng, 2, 80), fuzzed.size(rng, 2, 8) };
    try checkHierarchies(groups, &widths);
}

test "buildHierarchy matches the original on fuzzed groups" {
    try common.fuzz("clusterlod.buildHierarchy", 0, checkHierarchyFuzzed);
}
