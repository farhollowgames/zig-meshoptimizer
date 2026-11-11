//! Cluster level of detail: `build` splits a mesh into clusters, then
//! groups and simplifies them level by level into coarser clusters, a DAG
//! that a renderer cuts by screen-space error, as Nanite does; and
//! `buildHierarchy` puts a bounding volume hierarchy over the DAG's groups
//! for finding the clusters to render.
//!
//! Translated from meshoptimizer's demo/clusterlod.h, a small library on
//! top of meshoptimizer that its author offers to use as is or as a
//! reference for an engine's own; it follows Brian Karis, "Nanite: A Deep
//! Dive" (2021).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const strided = @import("strided.zig");
const VertexFloats = strided.VertexFloats;
const VertexFloatsMut = strided.VertexFloatsMut;
const clusterizer = @import("clusterizer.zig");
const Meshlet = clusterizer.Meshlet;
const meshletutils = @import("meshletutils.zig");
const partitionClusters = @import("partition.zig").partitionClusters;
const spatialorder = @import("spatialorder.zig");
const generatePositionRemap = @import("indexgenerator.zig").generatePositionRemap;
const simplifier = @import("simplifier.zig");
const SimplifyOptions = simplifier.SimplifyOptions;
const SimplifyVertexFlags = simplifier.SimplifyVertexFlags;

const float_max = std.math.floatMax(f32);

/// How `build` makes, groups and simplifies clusters; `defaultConfig` and
/// `defaultConfigRT` give settings to start from.
pub const Config = struct {
    /// Each cluster's limits, as `buildMeshletsFlex` and
    /// `buildMeshletsSpatial` take them.
    max_vertices: usize,
    min_triangles: usize,
    max_triangles: usize,

    /// Group clusters that are close in space, not only clusters that share
    /// vertices: `partitionClusters` with positions.
    partition_spatial: bool,
    /// Order each level's groups along a space-filling curve.
    partition_sort: bool,
    /// The clusters a group aims for, not a maximum: groups may be up to a
    /// third larger (a target of 24 gives at most 32).
    partition_size: usize,

    /// Split with `buildMeshletsSpatial`, made for ray tracing, instead of
    /// `buildMeshletsFlex`.
    cluster_spatial: bool,
    /// `buildMeshletsSpatial`'s `fill_weight`.
    cluster_fill_weight: f32,
    /// `buildMeshletsFlex`'s `split_factor`.
    cluster_split_factor: f32,

    /// The share of its triangles each level aims to keep, from 0 to 1.
    simplify_ratio: f32,
    /// The share of its triangles above which a group is stuck, below 1: its
    /// clusters stay as they are, simplified no further.
    simplify_threshold: f32,

    /// A simplified group's error, from the largest error of its clusters
    /// (previous) and its own simplification's (current):
    /// `max(previous * simplify_error_merge_previous, current) +
    /// current * simplify_error_merge_additive`.
    simplify_error_merge_previous: f32,
    simplify_error_merge_additive: f32,

    /// Scales the error of the groups the sloppy fallback simplified, for
    /// their worse appearance.
    simplify_error_factor_sloppy: f32,

    /// Above 0, caps a group's error at this times its triangles' longest
    /// edge length, so dense clusters lose subpixel triangles even where
    /// the attribute error is high. A triangle's length is its shortest
    /// edge's, or a quarter of its longest's when that is more, for thin
    /// and long triangles such as wires.
    simplify_error_edge_limit: f32,

    /// Limit the attribute error to the scale of the position error, so the
    /// levels are not chosen too conservatively: the simplifier's
    /// `error_clamped`.
    simplify_error_clamped: bool,
    /// Simplify permissively, across attribute seams (`permissive`); set
    /// `Mesh.attribute_protect_mask` with it.
    simplify_permissive: bool,
    /// Simplify permissively, or sloppily, only where the regular
    /// simplification gets stuck.
    simplify_fallback_permissive: bool,
    simplify_fallback_sloppy: bool,
    /// Make the triangle density more uniform (`regularize`), at some cost
    /// to the triangle count; for meshes that deform.
    simplify_regularize: bool,
    /// Try to keep the fold lines between opposite-facing triangles
    /// (`preserve_folds`), at a small cost in speed.
    simplify_preserve_folds: bool,
    /// Move each simplified group's open borders outward, to make up for
    /// the area simplification takes away; for foliage, not for every mesh.
    /// It moves vertices in place, so it needs `Mesh.positions_mut`, and
    /// later groups move the positions of the clusters `output` gets: copy
    /// them there.
    simplify_dilate_borders: bool,

    /// Compute each simplified cluster's bounds from its own triangles, not
    /// its group's.
    optimize_bounds: bool,
    /// Reorder each cluster's triangles for locality, with
    /// `optimizeMeshletLevel` at `optimize_clusters_level` (0 to 9), which
    /// helps rasterizing, and ray tracing with fast-build structures.
    optimize_clusters: bool,
    optimize_clusters_level: u4,
};

/// The mesh `build` splits: views of the caller's buffers, which must stay
/// as they are, except through `positions_mut`, until `build` returns.
pub const Mesh = struct {
    /// The triangles, three indices each.
    indices: []const u32,
    /// The first three floats of each vertex; their count is the mesh's
    /// vertex count. They must be finite, and small enough that products of
    /// edge lengths are too: `computeClusterBounds` asserts on triangles
    /// whose normals are NaN.
    positions: VertexFloats,
    /// The same floats as `positions`, writable, for a build with
    /// `Config.simplify_dilate_borders`, which moves them; null otherwise.
    positions_mut: ?VertexFloatsMut = null,
    /// For attribute-aware and permissive simplification:
    /// `attribute_weights.len` floats at the start of each vertex, and the
    /// ones `attribute_protect_mask` names.
    attributes: VertexFloats = .{ .data = &.{}, .stride = 1 },
    /// Flags for every vertex, as the simplifier takes them: `lock` keeps a
    /// vertex in place, and `protect` keeps more seams where
    /// `attribute_protect_mask` is not used.
    vertex_lock: ?[]const SimplifyVertexFlags = null,
    /// The weights of the attributes, as `simplifyWithAttributes` takes
    /// them.
    attribute_weights: []const f32 = &.{},
    /// The attributes whose discontinuities permissive simplification
    /// keeps, such as texture coordinate seams: bit K for attribute K.
    attribute_protect_mask: u32 = 0,
};

/// A sphere around a cluster or group and its simplification error, in the
/// mesh's units. The error on screen, from 0 to 1 (times the screen height
/// for pixels), ignoring perspective distortion, is
/// `error / max(distance(center, camera) - radius, znear) * (proj * 0.5)`,
/// where `proj` is projection[1][1], cot(fovy / 2), and `znear` the
/// positive near plane distance.
pub const Bounds = extern struct {
    center: [3]f32,
    radius: f32,
    @"error": f32,
};

/// A cluster `build` hands to `output`.
pub const Cluster = struct {
    /// The id `output` returned for the group, with more triangles, whose
    /// simplification made this cluster; -1 for the mesh's own triangles.
    refined: i32,
    /// For culling only: `bounds.error` is not monotonic across the DAG.
    bounds: Bounds,
    /// The triangles, as indices of the mesh's vertices: a slice of
    /// `build`'s scratch memory, valid only until `output` returns, so copy
    /// what you keep.
    indices: []const u32,
    /// How many distinct vertices `indices` uses.
    vertex_count: usize,
};

/// A group of clusters `build` hands to `output`. Render a cluster when its
/// group's `simplified` error is over the threshold, and its `refined` is
/// -1 or names a group whose `simplified` error is at or under it.
pub const Group = extern struct {
    /// The DAG level the group was made at, from 0.
    depth: i32,
    /// The bounds of the group simplified: the error is that of the clusters
    /// whose `refined` is this group's id, and the largest float for a
    /// group simplified no further.
    simplified: Bounds,
};

/// A node of `buildHierarchy`'s trees. Descend into a node while its error
/// is over the threshold; at a leaf, render the group's clusters whose
/// `refined` is -1 or names a group whose `simplified` error is at or under
/// the threshold.
pub const Node = extern struct {
    /// Bounds around the subtree's groups, with the largest of their errors.
    bounds: Bounds,
    /// A leaf's group, by its index in the groups; -1 for an internal node.
    group: i32,
    /// An internal node's children: `nodes[child_offset..][0..child_count]`.
    child_offset: u32,
    child_count: u32,
};

/// Settings for clusters of `max_triangles` (4 to 256) to rasterize.
pub fn defaultConfig(max_triangles: usize) Config {
    assert(max_triangles >= 4 and max_triangles <= 256);

    return .{
        .max_vertices = max_triangles,
        .min_triangles = max_triangles / 3,
        .max_triangles = max_triangles,

        .partition_spatial = true,
        .partition_sort = false,
        .partition_size = 16,

        .cluster_spatial = false,
        .cluster_fill_weight = 0,
        .cluster_split_factor = 2.0,

        .simplify_ratio = 0.5,
        .simplify_threshold = 0.85,
        .simplify_error_merge_previous = 1.0,
        .simplify_error_merge_additive = 0,
        .simplify_error_factor_sloppy = 2.0,
        .simplify_error_edge_limit = 0,
        .simplify_error_clamped = true,
        .simplify_permissive = true,
        // Permissive by default, though it can also serve only as a
        // fallback.
        .simplify_fallback_permissive = false,
        .simplify_fallback_sloppy = true,
        .simplify_regularize = false,
        .simplify_preserve_folds = false,
        .simplify_dilate_borders = false,

        .optimize_bounds = false,
        .optimize_clusters = true,
        .optimize_clusters_level = 1,
    };
}

/// `defaultConfig` for clusters to ray trace.
pub fn defaultConfigRT(max_triangles: usize) Config {
    var config = defaultConfig(max_triangles);

    // Smaller clusters where they make a better BVH; the fastest tracing may
    // want them smaller still.
    config.min_triangles = max_triangles / 4;

    // More vertices fill clusters better, and ray tracing does not care how
    // many vertices a cluster has.
    config.max_vertices = @min(256, max_triangles * 2);

    config.cluster_spatial = true;
    config.cluster_fill_weight = 0.5;

    return config;
}

/// Builds the cluster LOD DAG of `mesh` and hands it to `context.output`
/// one group at a time, from the mesh's own triangles up: `output(group:
/// Group, clusters: []const Cluster)` returns the group's id, an `i32` or
/// an error union of one, which the clusters simplified from the group
/// record as `refined`. `context` is usually a pointer to the caller's
/// state. An error from `output` stops the build, and `build` returns it.
///
/// The clusters' indices are `build`'s scratch memory, valid only until
/// `output` returns. Its lists grow as the levels are built, as the
/// original's vectors do, so `gpa` frees out of allocation order: it must
/// be a general-purpose allocator, not a stack-ordered one such as an
/// `AllocatorCache` handle.
pub fn build(gpa: Allocator, config: Config, mesh: Mesh, context: anytype) !void {
    comptime checkContext(@TypeOf(context));

    assert(mesh.attribute_weights.len <= mesh.attributes.stride);
    assert(mesh.attributes.stride >= 32 or
        mesh.attribute_protect_mask < @as(u32, 1) << @intCast(mesh.attributes.stride));
    // Dilation writes the positions it reads through `positions`.
    assert(!config.simplify_dilate_borders or mesh.positions_mut != null);
    if (mesh.positions_mut) |writable| {
        assert(writable.data.ptr == mesh.positions.data.ptr);
        assert(writable.data.len == mesh.positions.data.len);
        assert(writable.stride == mesh.positions.stride);
    }

    const vertex_count = mesh.positions.count();

    const locks = try gpa.alloc(u8, vertex_count);
    defer gpa.free(locks);
    @memset(locks, 0);

    // For the clusters' connectivity, a remap that sends the vertices of
    // one position to one index.
    const remap = try gpa.alloc(u32, vertex_count);
    defer gpa.free(remap);
    try generatePositionRemap(gpa, remap, mesh.positions);

    // Protect bits on the seams of the protected attributes, for permissive
    // simplification.
    if (mesh.attribute_protect_mask != 0) {
        const attribute_count = @min(mesh.attributes.stride, 32);

        for (remap, locks, 0..) |r, *lock, i| {
            // `r` is the first vertex at `i`'s position.
            if (r == i) continue;

            const attributes = mesh.attributes.at(i);
            const canonical = mesh.attributes.at(r);

            for (0..attribute_count) |j| {
                const bit = @as(u32, 1) << @intCast(j);
                const protected = (mesh.attribute_protect_mask & bit) != 0;
                if (protected and attributes[j] != canonical[j]) lock.* |= protect_bit;
            }
        }
    }

    const dilate_count = if (config.simplify_dilate_borders) vertex_count * 4 else 0;
    const dilate_offsets = try gpa.alloc(f32, dilate_count);
    defer gpa.free(dilate_offsets);
    @memset(dilate_offsets, 0);
    var dilate_table: std.ArrayList(u64) = .empty;
    defer dilate_table.deinit(gpa);

    // The first clusters split the mesh itself.
    var cluster_indices: std.ArrayList(u32) = .empty;
    defer cluster_indices.deinit(gpa);
    var clusters: std.ArrayList(LevelCluster) = .empty;
    defer clusters.deinit(gpa);
    try clusterize(gpa, &clusters, &cluster_indices, config, mesh, mesh.indices, -1);

    // Their precise bounds; later clusters take their groups' merged bounds.
    for (clusters.items) |*cluster| {
        const indices = cluster_indices.items[cluster.index_offset..][0..cluster.index_count];
        cluster.bounds = boundsCompute(mesh, indices, 0);
    }

    var pending: std.ArrayList(LevelCluster) = .empty;
    defer pending.deinit(gpa);
    var pending_indices: std.ArrayList(u32) = .empty;
    defer pending_indices.deinit(gpa);
    try pending.ensureTotalCapacity(gpa, clusters.items.len);
    try pending_indices.ensureTotalCapacity(gpa, cluster_indices.items.len);

    var merged: std.ArrayList(u32) = .empty;
    defer merged.deinit(gpa);
    var simplified: std.ArrayList(u32) = .empty;
    defer simplified.deinit(gpa);
    const group_clusters_max = config.partition_size + config.partition_size / 3;
    try merged.ensureTotalCapacity(gpa, group_clusters_max * config.max_triangles * 3);

    var depth: i32 = 0;

    // Merge and simplify clusters until they no longer merge.
    while (clusters.items.len > 1) {
        const group_offsets = try partition(
            gpa,
            &clusters,
            config,
            mesh,
            cluster_indices.items,
            remap,
        );
        defer gpa.free(group_offsets);

        pending.clearRetainingCapacity();
        pending_indices.clearRetainingCapacity();

        // A lock bit on the borders between groups keeps the simplified
        // groups free of gaps.
        lockBoundary(
            locks,
            clusters.items,
            group_offsets,
            cluster_indices.items,
            remap,
            mesh.vertex_lock,
        );

        // Every group is simplified now.
        for (group_offsets[0 .. group_offsets.len - 1], group_offsets[1..]) |start, end| {
            const group = clusters.items[start..end];

            merged.clearRetainingCapacity();
            for (group) |cluster| {
                const indices = cluster_indices.items[cluster.index_offset..];
                try merged.appendSlice(gpa, indices[0..cluster.index_count]);
            }

            const merged_triangles: f32 = @floatFromInt(merged.items.len / 3);
            const target_triangles: usize = @intFromFloat(merged_triangles * config.simplify_ratio);
            const target_size = target_triangles * 3;

            // Bounds and errors that grow monotonically up the DAG, which
            // the precise bounds of the merged or simplified triangles may
            // not.
            var bounds = boundsMerge(LevelCluster, group);

            var err: f32 = 0;
            try simplify(gpa, &simplified, config, mesh, merged.items, locks, target_size, &err);

            const kept: f32 = @floatFromInt(simplified.items.len);
            const merged_count: f32 = @floatFromInt(merged.items.len);
            if (kept > merged_count * config.simplify_threshold) {
                // Stuck: the merge is abandoned, and the group is terminal.
                bounds.@"error" = float_max;
                _ = try outputGroup(
                    gpa,
                    config,
                    mesh,
                    group,
                    cluster_indices.items,
                    bounds,
                    depth,
                    context,
                );
                continue;
            }

            // The error grows monotonically, with an optional extra term
            // that spreads the transitions apart.
            const previous = bounds.@"error" * config.simplify_error_merge_previous;
            const larger = if (previous < err) err else previous;
            bounds.@"error" = larger + err * config.simplify_error_merge_additive;

            // The group goes out with its clusters; the clusters simplified
            // from it record its id.
            const refined = try outputGroup(
                gpa,
                config,
                mesh,
                group,
                cluster_indices.items,
                bounds,
                depth,
                context,
            );

            // With the group's clusters out, the simplified ones may dilate.
            if (config.simplify_dilate_borders) {
                try dilateBorders(
                    gpa,
                    mesh,
                    merged.items,
                    simplified.items,
                    locks,
                    remap,
                    &bounds,
                    dilate_offsets,
                    &dilate_table,
                );
            }

            // The new clusters, for the next level.
            const cluster_offset = pending.items.len;
            try clusterize(
                gpa,
                &pending,
                &pending_indices,
                config,
                mesh,
                simplified.items,
                refined,
            );

            // They take the group's merged bounds, so whatever group they
            // join gets conservative bounds.
            for (pending.items[cluster_offset..]) |*cluster| cluster.bounds = bounds;
        }

        std.mem.swap(std.ArrayList(LevelCluster), &clusters, &pending);
        std.mem.swap(std.ArrayList(u32), &cluster_indices, &pending_indices);
        depth += 1;
    }

    if (clusters.items.len > 0) {
        // The last cluster: a terminal group.
        var bounds = clusters.items[0].bounds;
        bounds.@"error" = float_max;

        _ = try outputGroup(
            gpa,
            config,
            mesh,
            clusters.items,
            cluster_indices.items,
            bounds,
            depth,
            context,
        );
    }
}

/// The meshlet-local indices of a cluster `build` made: fills `vertices`
/// (room for 256) and `triangles` (room for `indices.len`) so that
/// `vertices[triangles[i]] == indices[i]`, and returns the vertex count,
/// the cluster's `vertex_count`.
pub fn localIndices(vertices: []u32, triangles: []u8, indices: []const u32) usize {
    return meshletutils.extractMeshletIndices(vertices, triangles, indices);
}

/// The most nodes `buildHierarchy` makes for `group_count` groups of
/// `level_count` DAG levels, the largest group depth plus one.
pub fn buildHierarchyBound(group_count: usize, node_width: usize, level_count: usize) usize {
    // Nodes for each tree depth, each padded by the level count, since the
    // groups may fall into the levels' trees in any way.
    var total = level_count;
    var frontier = group_count;
    while (frontier > 1) : (frontier = @divCeil(frontier, node_width)) {
        // A width of 1 never narrows the frontier.
        assert(node_width > 1);
        total += frontier + level_count;
    }

    return total;
}

/// Builds a bounding volume hierarchy over the groups `build` made, which
/// speeds up finding the clusters to render, into `nodes` (room for
/// `buildHierarchyBound`), and returns the node count. `level_count` is the
/// largest group depth plus one; every level has groups. The result is a
/// forest of one tree per level: nodes 0 to `level_count - 1` are the
/// trees' roots, each over the groups of its depth; the others are the
/// trees' nodes, internal ones with up to `node_width` (at least 2)
/// children and leaves of one group each.
pub fn buildHierarchy(
    gpa: Allocator,
    nodes: []Node,
    groups: []const Group,
    node_width: usize,
    level_count: usize,
) Allocator.Error!usize {
    // The first nodes are the levels' roots.
    var offset = level_count;

    var row: std.ArrayList(Node) = try .initCapacity(gpa, groups.len);
    defer row.deinit(gpa);
    const order = try gpa.alloc(u32, groups.len);
    defer gpa.free(order);

    for (0..level_count) |level| {
        // Each level's tree starts from the level's groups, as leaves.
        row.clearRetainingCapacity();
        for (groups, 0..) |group, i| {
            if (group.depth != @as(i32, @intCast(level))) continue;
            row.appendAssumeCapacity(.{
                .bounds = group.simplified,
                .group = @intCast(i),
                .child_offset = 0,
                .child_count = 0,
            });
        }

        // The tree, one level up at a time, grouping nearby centers as a
        // proxy for locality.
        while (row.items.len > 1) {
            // A width of 1 never narrows the row.
            assert(node_width > 1);

            const count = row.items.len;
            const centers: VertexFloats = .fromField(Node, "bounds", row.items);
            try spatialorder.spatialClusterPoints(gpa, order[0..count], centers, node_width);

            for (order[0..count], nodes[offset..][0..count]) |o, *node| node.* = row.items[o];

            row.clearRetainingCapacity();
            var i: usize = 0;
            while (i < count) : (i += node_width) {
                // spatialClusterPoints fills every cluster but the last.
                const children = @min(node_width, count - i);
                row.appendAssumeCapacity(mergeNodes(nodes, offset + i, children));
            }

            offset += count;
        }

        // The level's root goes to the part at the start.
        assert(row.items.len == 1);
        nodes[level] = row.items[0];
    }

    assert(offset <= buildHierarchyBound(groups.len, node_width, level_count));
    return offset;
}

/// The flag bits `build` reads and sets in its locks, one byte per vertex.
const lock_bit: u8 = @bitCast(SimplifyVertexFlags{ .lock = true });
const protect_bit: u8 = @bitCast(SimplifyVertexFlags{ .protect = true });
/// For `lockBoundary` alone: an earlier group used the position.
const seen_bit: u8 = 1 << 7;

/// A cluster of the level being built: its triangles are a range of the
/// level's index list.
const LevelCluster = struct {
    vertex_count: usize,
    index_offset: usize,
    index_count: usize,
    refined: i32,
    bounds: Bounds,
};

const zero_bounds: Bounds = .{ .center = @splat(0), .radius = 0, .@"error" = 0 };

/// Fails to compile, naming what is missing, unless a `Context` value has
/// the `output` method `build` calls.
fn checkContext(comptime Context: type) void {
    const Holder = switch (@typeInfo(Context)) {
        .pointer => |pointer| pointer.child,
        else => Context,
    };
    const message = "clusterlod.build: the context needs a method " ++
        "`output(self, group: Group, clusters: []const Cluster)` that returns i32 " ++
        "or an error union of i32; " ++ @typeName(Context) ++ " has none";
    if (!@hasDecl(Holder, "output")) @compileError(message);

    const info = switch (@typeInfo(@TypeOf(Holder.output))) {
        .@"fn" => |function| function,
        else => @compileError(message),
    };
    if (info.param_types.len != 3 or
        (info.param_types[1] orelse void) != Group or
        (info.param_types[2] orelse void) != []const Cluster)
    {
        @compileError(message);
    }
    const Return = info.return_type orelse @compileError(message);
    const Id = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => Return,
    };
    if (Id != i32) @compileError(message);
}

fn boundsCompute(mesh: Mesh, indices: []const u32, err: f32) Bounds {
    const bounds = meshletutils.computeClusterBounds(u32, indices, mesh.positions);

    return .{ .center = bounds.center, .radius = bounds.radius, .@"error" = err };
}

/// Bounds around those of `items`, clusters or nodes, never none, with the
/// largest of their errors.
fn boundsMerge(comptime T: type, items: []const T) Bounds {
    const all: VertexFloats = .fromField(T, "bounds", items);
    // Each radius follows its center.
    const radii: VertexFloats = .{ .data = all.data[3..], .stride = all.stride };
    const merged = meshletutils.computeSphereBounds(all, radii);

    // The merged error must be conservative with respect to the items'.
    var err: f32 = 0;
    for (items) |item| err = if (err < item.bounds.@"error") item.bounds.@"error" else err;

    return .{ .center = merged.center, .radius = merged.radius, .@"error" = err };
}

/// Splits `indices` into meshlets and appends them to `clusters`, with
/// their indices to `cluster_indices`, each recording `refined`.
fn clusterize(
    gpa: Allocator,
    clusters: *std.ArrayList(LevelCluster),
    cluster_indices: *std.ArrayList(u32),
    config: Config,
    mesh: Mesh,
    indices: []const u32,
    refined: i32,
) !void {
    const max_meshlets = clusterizer.buildMeshletsBound(
        indices.len,
        config.max_vertices,
        config.min_triangles,
    );

    // A stack buffer for small parts of the mesh, enough for a group's; the
    // first split takes the heap.
    var buffer_stack: [32768]u8 align(@alignOf(Meshlet)) = undefined;
    var buffer: std.heap.BufferFirstAllocator = .init(&buffer_stack, gpa);
    const buffer_gpa = buffer.allocator();

    const meshlets = try buffer_gpa.alloc(Meshlet, max_meshlets);
    defer buffer_gpa.free(meshlets);
    const meshlet_vertices = try buffer_gpa.alloc(u32, indices.len);
    defer buffer_gpa.free(meshlet_vertices);
    const meshlet_triangles = try buffer_gpa.alloc(u8, indices.len);
    defer buffer_gpa.free(meshlet_triangles);

    const meshlet_count = if (config.cluster_spatial)
        try clusterizer.buildMeshletsSpatial(
            u32,
            gpa,
            meshlets,
            meshlet_vertices,
            meshlet_triangles,
            indices,
            mesh.positions,
            config.max_vertices,
            config.min_triangles,
            config.max_triangles,
            config.cluster_fill_weight,
        )
    else
        try clusterizer.buildMeshletsFlex(
            u32,
            gpa,
            meshlets,
            meshlet_vertices,
            meshlet_triangles,
            indices,
            mesh.positions,
            config.max_vertices,
            config.min_triangles,
            config.max_triangles,
            0,
            config.cluster_split_factor,
        );

    const new_clusters = try clusters.addManyAsSlice(gpa, meshlet_count);
    var index_offset = cluster_indices.items.len;
    _ = try cluster_indices.addManyAsSlice(gpa, indices.len);

    for (meshlets[0..meshlet_count], new_clusters) |meshlet, *cluster| {
        const vertices = meshlet_vertices[meshlet.vertex_offset..][0..meshlet.vertex_count];
        const triangles =
            meshlet_triangles[meshlet.triangle_offset..][0 .. meshlet.triangle_count * 3];

        if (config.optimize_clusters) {
            meshletutils.optimizeMeshletLevel(vertices, triangles, config.optimize_clusters_level);
        }

        // The meshlet-local indices go; `localIndices` gives them back.
        const corners = cluster_indices.items[index_offset..][0..triangles.len];
        for (triangles, corners) |t, *corner| corner.* = vertices[t];

        cluster.* = .{
            .vertex_count = meshlet.vertex_count,
            .index_offset = index_offset,
            .index_count = triangles.len,
            .refined = refined,
            .bounds = zero_bounds,
        };
        index_offset += triangles.len;
    }

    // Room is made for every triangle, as the original makes it, and zeros
    // fill what the builders leave, as its vector's resize does: they place
    // every triangle of finite positions.
    @memset(cluster_indices.items[index_offset..], 0);
}

/// Groups the level's clusters into partitions, reorders `clusters`
/// partition by partition, and returns the offset of each partition's
/// first cluster, then the cluster count; the caller frees the result.
fn partition(
    gpa: Allocator,
    clusters: *std.ArrayList(LevelCluster),
    config: Config,
    mesh: Mesh,
    indices: []const u32,
    remap: []const u32,
) ![]u32 {
    const cluster_count = clusters.items.len;

    if (cluster_count <= config.partition_size) {
        const offsets = try gpa.alloc(u32, 2);
        offsets[0] = 0;
        offsets[1] = @intCast(cluster_count);
        return offsets;
    }

    // The clusters' indices, remapped, one cluster after another, for the
    // partitioner.
    const cluster_counts = try gpa.alloc(u32, cluster_count);
    defer gpa.free(cluster_counts);
    const cluster_indices = try gpa.alloc(u32, indices.len);
    defer gpa.free(cluster_indices);
    var written: usize = 0;

    for (clusters.items, cluster_counts) |cluster, *count| {
        count.* = @intCast(cluster.index_count);

        for (indices[cluster.index_offset..][0..cluster.index_count]) |v| {
            cluster_indices[written] = remap[v];
            written += 1;
        }
    }

    // A partition for each cluster.
    const cluster_part = try gpa.alloc(u32, cluster_count);
    defer gpa.free(cluster_part);
    const partition_count = try partitionClusters(
        u32,
        gpa,
        cluster_part,
        cluster_indices[0..written],
        cluster_counts,
        if (config.partition_spatial) mesh.positions else null,
        remap.len,
        config.partition_size,
    );

    if (config.partition_sort) {
        // A point for each partition to sort by; any of its clusters' will
        // do, so its last cluster's center.
        const partition_point = try gpa.alloc(f32, partition_count * 3);
        defer gpa.free(partition_point);
        @memset(partition_point, 0);
        for (clusters.items, cluster_part) |cluster, part| {
            partition_point[@as(usize, part) * 3 ..][0..3].* = cluster.bounds.center;
        }

        // The partitions in spatial order, as a table from old ids to new.
        const partition_remap = try gpa.alloc(u32, partition_count);
        defer gpa.free(partition_remap);
        try spatialorder.spatialSortRemap(gpa, partition_remap, .init(partition_point, 3));

        for (cluster_part) |*part| part.* = partition_remap[part.*];
    }

    // The clusters of each partition, counted, then summed into offsets.
    const partition_offsets = try gpa.alloc(u32, partition_count + 1);
    errdefer gpa.free(partition_offsets);
    @memset(partition_offsets, 0);
    for (cluster_part) |part| partition_offsets[part + 1] += 1;

    for (1..partition_count + 1) |i| partition_offsets[i] += partition_offsets[i - 1];

    // The clusters, partition by partition.
    const write = try gpa.dupe(u32, partition_offsets);
    defer gpa.free(write);
    var result: std.ArrayList(LevelCluster) = try .initCapacity(gpa, cluster_count);
    const sorted = result.addManyAsSliceAssumeCapacity(cluster_count);
    for (clusters.items, cluster_part) |cluster, part| {
        sorted[write[part]] = cluster;
        write[part] += 1;
    }

    std.mem.swap(std.ArrayList(LevelCluster), clusters, &result);
    result.deinit(gpa);
    return partition_offsets;
}

/// Sets the lock bit of every position that two groups share, and of every
/// vertex at such a position; keeps the protect bits and adds the mesh's
/// own flags.
fn lockBoundary(
    locks: []u8,
    clusters: []const LevelCluster,
    group_offsets: []const u32,
    cluster_indices: []const u32,
    remap: []const u32,
    vertex_lock: ?[]const SimplifyVertexFlags,
) void {
    for (locks) |*lock| lock.* &= ~(lock_bit | seen_bit);

    for (group_offsets[0 .. group_offsets.len - 1], group_offsets[1..]) |start, end| {
        const group = clusters[start..end];

        // Every position an earlier group used is locked.
        for (group) |cluster| {
            for (cluster_indices[cluster.index_offset..][0..cluster.index_count]) |v| {
                const r = remap[v];
                locks[r] |= locks[r] >> 7;
            }
        }

        // Every position this group uses is marked as used.
        for (group) |cluster| {
            for (cluster_indices[cluster.index_offset..][0..cluster.index_count]) |v| {
                locks[remap[v]] |= seen_bit;
            }
        }
    }

    for (locks, remap, 0..) |*lock, r, i| {
        // The vertices of one position lock alike; protect bits stay.
        lock.* = (locks[r] & lock_bit) | (lock.* & protect_bit);

        if (vertex_lock) |flags| lock.* |= @bitCast(flags[i]);
    }
}

/// A corner of a group deindexed for `simplifySloppy`: its position and
/// the vertex it came from.
const SloppyVertex = struct {
    position: [3]f32,
    id: u32,
};

/// Simplifies the group `indices` sloppily into `lod`, with the error in
/// the mesh's units.
fn simplifyFallback(
    gpa: Allocator,
    lod: *std.ArrayList(u32),
    mesh: Mesh,
    indices: []const u32,
    locks: []const u8,
    target_count: usize,
    result_error: *f32,
) !void {
    const subset = try gpa.alloc(SloppyVertex, indices.len);
    defer gpa.free(subset);
    const subset_locks = try gpa.alloc(u8, indices.len);
    defer gpa.free(subset_locks);

    try lod.resize(gpa, indices.len);

    // The group deindexed, as simplifySloppy on the whole vertex buffer
    // costs too much without sparsity.
    for (indices, subset, subset_locks, lod.items, 0..) |v, *vertex, *lock, *index, i| {
        vertex.* = .{ .position = mesh.positions.vec3(v), .id = v };
        lock.* = locks[v];
        index.* = @intCast(i);
    }

    const positions: VertexFloats = .fromField(SloppyVertex, "position", subset);
    const count = try simplifier.simplifySloppy(
        u32,
        gpa,
        lod.items,
        lod.items,
        positions,
        @ptrCast(subset_locks),
        target_count,
        float_max,
        result_error,
    );
    lod.shrinkRetainingCapacity(count);

    // The error in the mesh's units.
    result_error.* *= simplifier.simplifyScale(positions);

    // Back to the mesh's vertices.
    for (lod.items) |*index| index.* = subset[index.*].id;
}

/// Simplifies the group `indices` into `lod`, toward `target_count`
/// indices, sparse and in absolute error, with the fallbacks `config` asks
/// for, and sets `result_error`.
fn simplify(
    gpa: Allocator,
    lod: *std.ArrayList(u32),
    config: Config,
    mesh: Mesh,
    indices: []const u32,
    locks: []const u8,
    target_count: usize,
    result_error: *f32,
) !void {
    assert(target_count <= indices.len);
    try lod.resize(gpa, indices.len);

    const options: SimplifyOptions = .{
        .sparse = true,
        .error_absolute = true,
        .error_clamped = config.simplify_error_clamped,
        .permissive = config.simplify_permissive,
        .regularize = config.simplify_regularize,
        .preserve_folds = config.simplify_preserve_folds,
    };
    const vertex_lock: []const SimplifyVertexFlags = @ptrCast(locks);

    const count = try simplifier.simplifyWithAttributes(
        u32,
        gpa,
        lod.items,
        indices,
        mesh.positions,
        mesh.attributes,
        mesh.attribute_weights,
        vertex_lock,
        target_count,
        float_max,
        options,
        result_error,
    );
    lod.shrinkRetainingCapacity(count);

    if (lod.items.len > target_count and
        config.simplify_fallback_permissive and !config.simplify_permissive)
    {
        var permissive = options;
        permissive.permissive = true;

        // The simplifier writes every index first, and the list still has
        // room for them.
        const permissive_count = try simplifier.simplifyWithAttributes(
            u32,
            gpa,
            lod.allocatedSlice()[0..indices.len],
            indices,
            mesh.positions,
            mesh.attributes,
            mesh.attribute_weights,
            vertex_lock,
            target_count,
            float_max,
            permissive,
            result_error,
        );

        // The original resizes its vector to the new count, which sets the
        // entries past the old count to zero when it grows.
        const old_count = lod.items.len;
        try lod.resize(gpa, permissive_count);
        if (permissive_count > old_count) @memset(lod.items[old_count..], 0);
    }

    // simplifySloppy has neither sparsity nor absolute errors, which the
    // fallback makes up for.
    if (lod.items.len > target_count and config.simplify_fallback_sloppy) {
        try simplifyFallback(gpa, lod, mesh, indices, locks, target_count, result_error);
        // More error, for the worse appearance.
        result_error.* *= config.simplify_error_factor_sloppy;
    }

    // A degenerate result becomes the first triangle, so no cluster is
    // empty, which would break the DAG.
    if (lod.items.len == 0 and indices.len > 0) try lod.appendSlice(gpa, indices[0..3]);

    // The error, optionally limited by edge length, so dense clusters lose
    // subpixel triangles even where the attribute error is high.
    if (config.simplify_error_edge_limit > 0) {
        var max_edge_sq: f32 = 0;

        for (0..indices.len / 3) |t| {
            const triangle = indices[t * 3 ..][0..3];
            const va = mesh.positions.vec3(triangle[0]);
            const vb = mesh.positions.vec3(triangle[1]);
            const vc = mesh.positions.vec3(triangle[2]);

            // The squared edge lengths.
            const eab = (va[0] - vb[0]) * (va[0] - vb[0]) +
                (va[1] - vb[1]) * (va[1] - vb[1]) +
                (va[2] - vb[2]) * (va[2] - vb[2]);
            const eac = (va[0] - vc[0]) * (va[0] - vc[0]) +
                (va[1] - vc[1]) * (va[1] - vc[1]) +
                (va[2] - vc[2]) * (va[2] - vc[2]);
            const ebc = (vb[0] - vc[0]) * (vb[0] - vc[0]) +
                (vb[1] - vc[1]) * (vb[1] - vc[1]) +
                (vb[2] - vc[2]) * (vb[2] - vc[2]);

            const emax_ab = if (eab < eac) eac else eab;
            const emax = if (emax_ab < ebc) ebc else emax_ab;
            const emin_ab = if (eac < eab) eac else eab;
            const emin = if (ebc < emin_ab) ebc else emin_ab;

            // The shortest edge, to drop triangles under a pixel thick, but
            // a quarter of the longest stops thin and long ones such as
            // wires.
            const length_sq = if (emin < emax / 4) emax / 4 else emin;
            max_edge_sq = if (max_edge_sq < length_sq) length_sq else max_edge_sq;
        }

        // The error, limited for dense clusters by their edge lengths.
        const limit = @sqrt(max_edge_sq) * config.simplify_error_edge_limit;
        result_error.* = if (limit < result_error.*) limit else result_error.*;
    }
}

/// Hands the group and its clusters to `context.output` and returns the id
/// it gives.
fn outputGroup(
    gpa: Allocator,
    config: Config,
    mesh: Mesh,
    group: []const LevelCluster,
    cluster_indices: []const u32,
    simplified: Bounds,
    depth: i32,
    context: anytype,
) !i32 {
    // A stack buffer for small groups, which should be nearly all of them.
    var clusters_stack: [32]Cluster = undefined;
    const on_stack = group.len <= clusters_stack.len;
    const clusters_heap: []Cluster = if (on_stack) &.{} else try gpa.alloc(Cluster, group.len);
    defer gpa.free(clusters_heap);
    const clusters = if (on_stack) clusters_stack[0..group.len] else clusters_heap;

    for (group, clusters) |cluster, *result| {
        const indices = cluster_indices[cluster.index_offset..][0..cluster.index_count];
        result.* = .{
            .refined = cluster.refined,
            .bounds = if (config.optimize_bounds and cluster.refined != -1)
                boundsCompute(mesh, indices, cluster.bounds.@"error")
            else
                cluster.bounds,
            .indices = indices,
            .vertex_count = cluster.vertex_count,
        };
    }

    const id = context.output(.{ .depth = depth, .simplified = simplified }, clusters);
    return if (@typeInfo(@TypeOf(id)) == .error_union) try id else id;
}

/// A directed edge of two positions, `a << 32 | b`, that no edge takes.
const empty_edge = std.math.maxInt(u64);

/// The entry of `key` in the edge table, or the empty one where it goes.
fn edgeLookup(table: []u64, key: u64) *u64 {
    const mask = table.len - 1;
    var h: usize = @as(usize, @intCast((key *% 0x9E3779B97F4A7C15) >> 32)) & mask;

    while (table[h] != empty_edge and table[h] != key) h = (h + 1) & mask;

    return &table[h];
}

/// The area of the triangles of `indices` on its open borders: those with
/// an unlocked edge whose reverse edge no triangle has. Leaves `table`
/// holding the edges of `indices`.
fn boundaryArea(
    mesh: Mesh,
    indices: []const u32,
    locks: []const u8,
    remap: []const u32,
    table: []u64,
) f32 {
    @memset(table, empty_edge);

    for (0..indices.len / 3) |t| {
        const triangle = indices[t * 3 ..][0..3];
        for (0..3) |e| {
            const a = remap[triangle[e]];
            const b = remap[triangle[if (e == 2) 0 else e + 1]];
            const id = @as(u64, a) << 32 | b;
            edgeLookup(table, id).* = id;
        }
    }

    var area: f32 = 0;

    for (0..indices.len / 3) |t| {
        const triangle = indices[t * 3 ..][0..3];
        var border = false;

        for (0..3) |e| {
            const a = remap[triangle[e]];
            const b = remap[triangle[if (e == 2) 0 else e + 1]];
            const id = @as(u64, b) << 32 | a;

            // Border triangles only: at least one edge unlocked and open, its
            // reverse edge missing.
            border = border or
                ((locks[a] & locks[b] & lock_bit) == 0 and edgeLookup(table, id).* == empty_edge);
        }

        if (!border) continue;

        const va = mesh.positions.vec3(triangle[0]);
        const vb = mesh.positions.vec3(triangle[1]);
        const vc = mesh.positions.vec3(triangle[2]);

        const ab = [3]f32{ vb[0] - va[0], vb[1] - va[1], vb[2] - va[2] };
        const ac = [3]f32{ vc[0] - va[0], vc[1] - va[1], vc[2] - va[2] };
        const nt = [3]f32{
            ab[1] * ac[2] - ab[2] * ac[1],
            ab[2] * ac[0] - ab[0] * ac[2],
            ab[0] * ac[1] - ab[1] * ac[0],
        };

        area += @sqrt(nt[0] * nt[0] + nt[1] * nt[1] + nt[2] * nt[2]) * 0.5;
    }

    return area;
}

/// Moves the vertices on the open borders of `simplified` outward, by the
/// width that makes up for the border area simplifying `merged` lost, and
/// grows `bounds` to take them in.
fn dilateBorders(
    gpa: Allocator,
    mesh: Mesh,
    merged: []const u32,
    simplified: []const u32,
    locks: []const u8,
    remap: []const u32,
    bounds: *Bounds,
    dilate_offsets: []f32,
    edge_table: *std.ArrayList(u64),
) !void {
    // A table with room for every edge.
    var table_size: usize = 16;
    while (table_size < merged.len + merged.len / 2) table_size *= 2;

    try edge_table.resize(gpa, table_size);
    const table = edge_table.items;

    const old_area = boundaryArea(mesh, merged, locks, remap, table);
    if (old_area == 0) return;

    // Only a moderate loss of area is safe to make up for.
    const new_area = boundaryArea(mesh, simplified, locks, remap, table);
    if (new_area >= old_area or new_area < old_area / 4) return;

    const positions = mesh.positions;
    var perimeter: f32 = 0;

    for (0..simplified.len / 3) |t| {
        const triangle = simplified[t * 3 ..][0..3];
        for (0..3) |e| {
            const next = if (e == 2) 0 else e + 1;
            const a = remap[triangle[e]];
            const b = remap[triangle[next]];
            const id = @as(u64, b) << 32 | a;

            // boundaryArea's border test, on the table it left holding the
            // simplified edges.
            const locked = (locks[a] & locks[b] & lock_bit) != 0;
            if (locked or edgeLookup(table, id).* != empty_edge) continue;

            const va = positions.vec3(triangle[e]);
            const vb = positions.vec3(triangle[next]);
            const vc = positions.vec3(triangle[(e + 2) % 3]);

            const ev = [3]f32{ vb[0] - va[0], vb[1] - va[1], vb[2] - va[2] };
            const el = @sqrt(ev[0] * ev[0] + ev[1] * ev[1] + ev[2] * ev[2]);

            // The edge normal, from C projected onto AB.
            const cv = [3]f32{ va[0] - vc[0], va[1] - vc[1], va[2] - vc[2] };
            const cp = (cv[0] * ev[0] + cv[1] * ev[1] + cv[2] * ev[2]) /
                (if (el > 0) el * el else 1);
            const nv = [3]f32{ cv[0] - ev[0] * cp, cv[1] - ev[1] * cp, cv[2] - ev[2] * cp };
            const nl = @sqrt(nv[0] * nv[0] + nv[1] * nv[1] + nv[2] * nv[2]);

            // Edge normals summed by edge length; the perimeter scales them
            // before they apply.
            const ns: f32 = if (nl > 0) el / nl else 0;

            if ((locks[a] & lock_bit) == 0) {
                addEdgeNormal(dilate_offsets[@as(usize, a) * 4 ..][0..4], nv, ns, el);
            }
            if ((locks[b] & lock_bit) == 0) {
                addEdgeNormal(dilate_offsets[@as(usize, b) * 4 ..][0..4], nv, ns, el);
            }

            perimeter += el;
        }
    }

    const distance: f32 = if (perimeter > 0) (old_area - new_area) / perimeter else 0;
    const writable = mesh.positions_mut.?;

    for (simplified) |v| {
        const r = remap[v];
        if ((locks[r] & lock_bit) != 0) continue;

        const vi = writable.at(v)[0..3];
        const vr = writable.at(r)[0..3];
        const n = dilate_offsets[@as(usize, r) * 4 ..][0..4];

        if (n[3] > 0) {
            // The normals averaged, then divided by length twice: once to
            // normalize, and once to extend the offset into a miter.
            const nx = n[0] / n[3];
            const ny = n[1] / n[3];
            const nz = n[2] / n[3];
            const nn = nx * nx + ny * ny + nz * nz;
            const ns = distance / (if (nn > 0.15) nn else 0.15);

            vr[0] += nx * ns;
            vr[1] += ny * ns;
            vr[2] += nz * ns;
            n.* = @splat(0);

            // The group's bounds grow to take in the moved vertex.
            const dx = vr[0] - bounds.center[0];
            const dy = vr[1] - bounds.center[1];
            const dz = vr[2] - bounds.center[2];
            const reach = @sqrt(dx * dx + dy * dy + dz * dz);
            bounds.radius = if (bounds.radius < reach) reach else bounds.radius;
        }

        // Every wedge copies the position of its position's first vertex,
        // moved or not.
        vi[0] = vr[0];
        vi[1] = vr[1];
        vi[2] = vr[2];
    }
}

fn addEdgeNormal(offset: *[4]f32, nv: [3]f32, ns: f32, el: f32) void {
    offset[0] += nv[0] * ns;
    offset[1] += nv[1] * ns;
    offset[2] += nv[2] * ns;
    offset[3] += el;
}

fn mergeNodes(nodes: []const Node, offset: usize, count: usize) Node {
    return .{
        .bounds = boundsMerge(Node, nodes[offset..][0..count]),
        .group = -1,
        .child_offset = @intCast(offset),
        .child_count = @intCast(count),
    };
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

fn TestGrid(comptime side: usize) type {
    return struct {
        positions: [(side + 1) * (side + 1) * 3]f32,
        indices: [side * side * 6]u32,
    };
}

/// A `side` by `side` grid of quads on the z = 0 plane, three floats per
/// vertex.
fn testGrid(comptime side: usize) TestGrid(side) {
    var result: TestGrid(side) = undefined;
    for (0..side + 1) |y| for (0..side + 1) |x| {
        const at = (y * (side + 1) + x) * 3;
        result.positions[at..][0..3].* = .{ @floatFromInt(x), @floatFromInt(y), 0 };
    };
    for (0..side) |y| for (0..side) |x| {
        const v0: u32 = @intCast(y * (side + 1) + x);
        const v2: u32 = v0 + @as(u32, side) + 1;
        result.indices[(y * side + x) * 6 ..][0..6].* = .{ v0, v0 + 1, v2, v2, v0 + 1, v2 + 1 };
    };
    return result;
}

test "an error from output stops the build" {
    const grid = testGrid(16);
    const Failing = struct {
        calls: usize = 0,

        pub fn output(self: *@This(), group: Group, clusters: []const Cluster) !i32 {
            _ = group;
            _ = clusters;
            self.calls += 1;
            if (self.calls == 2) return error.Enough;
            return @intCast(self.calls);
        }
    };

    var failing: Failing = .{};
    const mesh: Mesh = .{ .indices = &grid.indices, .positions = .init(&grid.positions, 3) };
    const result = build(testing.allocator, defaultConfig(8), mesh, &failing);
    try testing.expectError(error.Enough, result);
    try testing.expectEqual(2, failing.calls);
}

test "output may return a plain id from a context passed by value" {
    const grid = testGrid(16);
    const Counting = struct {
        triangles: *usize,

        pub fn output(self: @This(), group: Group, clusters: []const Cluster) i32 {
            for (clusters) |cluster| {
                if (cluster.refined == -1) self.triangles.* += cluster.indices.len / 3;
            }
            return group.depth;
        }
    };

    var triangles: usize = 0;
    const mesh: Mesh = .{ .indices = &grid.indices, .positions = .init(&grid.positions, 3) };
    try build(testing.allocator, defaultConfig(8), mesh, Counting{ .triangles = &triangles });
    // The clusters of the mesh's own triangles, each handed out once.
    try testing.expectEqual(grid.indices.len / 3, triangles);
}

test "a build without triangles hands out nothing" {
    const Never = struct {
        pub fn output(_: @This(), _: Group, _: []const Cluster) i32 {
            unreachable;
        }
    };
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0 };
    const mesh: Mesh = .{ .indices = &.{}, .positions = .init(&positions, 3) };
    try build(testing.allocator, defaultConfig(128), mesh, Never{});
}
