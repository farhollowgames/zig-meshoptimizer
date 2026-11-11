//! Cluster partitioning: grouping meshlets into partitions of similar size,
//! by the vertices they share and, given positions, by how close they are,
//! as hierarchical level of detail needs before simplifying each group.
//!
//! Translated from meshoptimizer's partition.cpp, which builds on Kurita,
//! "An efficient agglomerative clustering algorithm using a heap" (1991).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const VertexFloats = @import("strided.zig").VertexFloats;

// Past this depth the spatial merge bisects, which bounds the recursion on
// malformed inputs.
const merge_depth_cutoff = 40;

/// For each cluster, the clusters that share vertices with it and how many:
/// `clusters[offsets[i]..offsets[i + 1]]` and the same range of `shared`.
/// Its slices are scratch memory, invalid once that is freed.
const ClusterAdjacency = struct {
    offsets: []u32,
    clusters: []u32,
    shared: []u32,

    fn init(
        scratch: *Scratch,
        cluster_indices: []const u32,
        cluster_offsets: []const u32,
        vertex_count: usize,
    ) Allocator.Error!ClusterAdjacency {
        const cluster_count = cluster_offsets.len - 1;

        const ref_offsets = try scratch.alloc(u32, vertex_count + 1);

        // How many clusters use each vertex.
        @memset(ref_offsets[0..vertex_count], 0);

        for (0..cluster_count) |i| {
            const cluster = cluster_indices[cluster_offsets[i]..cluster_offsets[i + 1]];
            for (cluster) |v| ref_offsets[v] += 1;
        }

        // The most clusters each cluster can be next to.
        var total_adjacency: usize = 0;

        for (0..cluster_count) |i| {
            var count: usize = 0;

            // At worst, every vertex has its own clusters...
            const cluster = cluster_indices[cluster_offsets[i]..cluster_offsets[i + 1]];
            for (cluster) |v| count += ref_offsets[v] - 1;

            // ...but it can be next to each other cluster only once.
            total_adjacency += @min(count, cluster_count - 1);
        }

        const adjacency: ClusterAdjacency = .{
            .offsets = try scratch.alloc(u32, cluster_count + 1),
            .clusters = try scratch.alloc(u32, total_adjacency),
            .shared = try scratch.alloc(u32, total_adjacency),
        };

        // Counts become offsets.
        var total_refs: usize = 0;

        for (ref_offsets[0..vertex_count]) |*r| {
            const count = r.*;
            r.* = @intCast(total_refs);
            total_refs += count;
        }

        const ref_data = try scratch.alloc(u32, total_refs);

        // The clusters of each vertex.
        for (0..cluster_count) |i| {
            const cluster = cluster_indices[cluster_offsets[i]..cluster_offsets[i + 1]];
            for (cluster) |v| {
                ref_data[ref_offsets[v]] = @intCast(i);
                ref_offsets[v] += 1;
            }
        }

        // Each offset is at its list's end now: shifting them up one makes
        // them starts.
        @memmove(ref_offsets[1..][0..vertex_count], ref_offsets[0..vertex_count]);
        ref_offsets[0] = 0;

        const slots = try scratch.alloc(u32, cluster_count);
        @memset(slots, std.math.maxInt(u32));

        adjacency.offsets[0] = 0;

        for (0..cluster_count) |i| {
            const adj = adjacency.clusters[adjacency.offsets[i]..];
            const shd = adjacency.shared[adjacency.offsets[i]..];
            var count: usize = 0;

            for (cluster_indices[cluster_offsets[i]..cluster_offsets[i + 1]]) |v| {
                // Merge the clusters of each vertex into this cluster's list.
                for (ref_data[ref_offsets[v]..ref_offsets[v + 1]]) |c| {
                    if (c == i) continue;

                    // A cluster already listed shares one more vertex. The
                    // slots need no clearing between clusters, as the list
                    // confirms each one.
                    const slot = slots[c];
                    if (slot < count and adj[slot] == c) {
                        shd[slot] += 1;
                    } else {
                        slots[c] = @intCast(count);
                        adj[count] = c;
                        shd[count] = 1;
                        count += 1;
                    }
                }
            }

            // The list ends where the next cluster's starts.
            adjacency.offsets[i + 1] = adjacency.offsets[i] + @as(u32, @intCast(count));
        }

        assert(adjacency.offsets[cluster_count] <= total_adjacency);

        // ref_offsets was allocated before the adjacency, so it stays.
        scratch.free(slots);
        scratch.free(ref_data);

        return adjacency;
    }
};

/// Copies each cluster's indices to `data`, without repeats, and writes
/// where each cluster starts to `offsets`, and where the last ends.
fn filterClusterIndices(
    data: []u32,
    offsets: []u32,
    cluster_indices: []const u32,
    cluster_index_counts: []const u32,
    used: []u8,
) void {
    var cluster_start: usize = 0;
    var cluster_write: usize = 0;

    for (cluster_index_counts, 0..) |count, i| {
        offsets[i] = @intCast(cluster_write);

        // Copy the cluster's indices, skipping repeats.
        for (cluster_indices[cluster_start..][0..count]) |v| {
            assert(v < used.len);

            data[cluster_write] = v;
            cluster_write += 1 - used[v];
            used[v] = 1;
        }

        // Clear the marks for the next cluster.
        for (data[offsets[i]..cluster_write]) |v| used[v] = 0;

        cluster_start += count;
    }

    assert(cluster_start == cluster_indices.len);
    offsets[cluster_index_counts.len] = @intCast(cluster_write);
}

/// The bounding sphere of a cluster's vertices: its center in `out_center`
/// and its radius returned.
fn clusterBounds(indices: []const u32, positions: VertexFloats, out_center: *[3]f32) f32 {
    var center: [3]f32 = @splat(0);

    // The average of the vertices is close to the center.
    for (indices) |index| {
        const p = positions.vec3(index);

        center[0] += p[0];
        center[1] += p[1];
        center[2] += p[2];
    }

    // Clusters are never empty, but the division is guarded all the same.
    if (indices.len != 0) {
        const count: f32 = @floatFromInt(indices.len);
        center[0] /= count;
        center[1] /= count;
        center[2] /= count;
    }

    var radiussq: f32 = 0;

    for (indices) |index| {
        const p = positions.vec3(index);

        const d2 = (p[0] - center[0]) * (p[0] - center[0]) +
            (p[1] - center[1]) * (p[1] - center[1]) +
            (p[2] - center[2]) * (p[2] - center[2]);

        radiussq = if (radiussq < d2) d2 else radiussq;
    }

    out_center.* = center;
    return @sqrt(radiussq);
}

/// A group of clusters, linked through `next` from its root.
const ClusterGroup = struct {
    /// The root of the cluster's group, or -1 while it is out of merging.
    group: i32,
    /// The next cluster of the group, or -1.
    next: i32,
    /// The group's cluster count at its root, 0 elsewhere.
    size: u32,
    /// About how many vertices the group has.
    vertices: u32,

    center: [3]f32,
    radius: f32,

    const zero: ClusterGroup = .{
        .group = 0,
        .next = 0,
        .size = 0,
        .vertices = 0,
        .center = @splat(0),
        .radius = 0,
    };
};

/// A group in the merge heap, smallest `order` on top.
const GroupOrder = extern struct {
    id: u32,
    order: i32,
};

fn heapPush(heap: []GroupOrder, size: usize, item: GroupOrder) void {
    // At the end, which breaks the heap order...
    heap[size] = item;

    // ...until it bubbles up to its place.
    var i = size;
    while (i > 0 and heap[i].order < heap[(i - 1) / 2].order) {
        const p = (i - 1) / 2;

        std.mem.swap(GroupOrder, &heap[i], &heap[p]);
        i = p;
    }
}

fn heapPop(heap: []GroupOrder, size: usize) GroupOrder {
    assert(size > 0);
    const top = heap[0];

    // The last item on top, which breaks the heap order...
    const rest = size - 1;
    heap[0] = heap[rest];

    // ...until it bubbles down to its place.
    var i: usize = 0;
    while (i * 2 + 1 < rest) {
        // The smaller child.
        var j = i * 2 + 1;
        j += @intFromBool(j + 1 < rest and heap[j + 1].order < heap[j].order);

        // The parent is no larger than its children: done.
        if (heap[j].order >= heap[i].order) break;

        std.mem.swap(GroupOrder, &heap[i], &heap[j]);
        i = j;
    }

    return top;
}

/// Grows `target`'s bounding sphere to hold `source`'s.
fn mergeBounds(target: *ClusterGroup, source: ClusterGroup) void {
    const r1 = target.radius;
    const r2 = source.radius;
    const dx = source.center[0] - target.center[0];
    const dy = source.center[1] - target.center[1];
    const dz = source.center[2] - target.center[2];
    const d = @sqrt(dx * dx + dy * dy + dz * dz);

    if (d + r1 < r2) {
        target.center = source.center;
        target.radius = source.radius;
        return;
    }

    if (d + r2 > r1) {
        const k: f32 = if (d > 0) (d + r2 - r1) / (2 * d) else 0;

        target.center[0] += dx * k;
        target.center[1] += dy * k;
        target.center[2] += dz * k;
        target.radius = (d + r2 + r1) / 2;
    }
}

/// How close merging would keep `target`'s sphere to its size: its radius
/// over the merged sphere's.
fn boundsScore(target: ClusterGroup, source: ClusterGroup) f32 {
    const r1 = target.radius;
    const r2 = source.radius;
    const dx = source.center[0] - target.center[0];
    const dy = source.center[1] - target.center[1];
    const dz = source.center[2] - target.center[2];
    const d = @sqrt(dx * dx + dy * dy + dz * dz);

    const mr = if (d + r1 < r2) r2 else if (d + r2 < r1) r1 else (d + r2 + r1) / 2;

    return if (mr > 0) r1 / mr else 0;
}

/// The vertex count of a group as a float, as the original converts it.
fn vertexWeight(vertices: u32) f32 {
    return @floatFromInt(@as(i32, @bitCast(vertices)));
}

/// The group next to `id` that is best to merge it with, if any can be,
/// and in `out_shared` the vertices they share. `shared_acc` is all zeros,
/// and is left so.
fn pickGroupToMerge(
    groups: []const ClusterGroup,
    id: u32,
    adjacency: ClusterAdjacency,
    max_partition_size: usize,
    use_bounds: bool,
    shared_acc: []u32,
    out_shared: *u32,
) ?u32 {
    assert(groups[id].size > 0);

    const group_rsqrt = 1 / @sqrt(vertexWeight(groups[id].vertices));

    var best_group: ?u32 = null;
    var best_score: f32 = 0;
    var best_shared: u32 = 0;

    // The vertices each adjacent group shares, over all the clusters.
    var ci: i32 = @intCast(id);
    while (ci >= 0) : (ci = groups[@intCast(ci)].next) {
        const first = adjacency.offsets[@intCast(ci)];
        const last = adjacency.offsets[@as(usize, @intCast(ci)) + 1];
        for (adjacency.clusters[first..last], adjacency.shared[first..last]) |cluster, shared| {
            const other = groups[cluster].group;
            if (other >= 0) shared_acc[@intCast(other)] += shared;
        }
    }

    // Score each adjacent group and pick the best, zeroing shared_acc.
    ci = @intCast(id);
    while (ci >= 0) : (ci = groups[@intCast(ci)].next) {
        const first = adjacency.offsets[@intCast(ci)];
        const last = adjacency.offsets[@as(usize, @intCast(ci)) + 1];
        for (adjacency.clusters[first..last]) |cluster| {
            const group = groups[cluster].group;
            if (group < 0) continue;
            const other: u32 = @intCast(group);
            if (shared_acc[other] == 0) continue;

            // Zeroed before any skip, so the next call sees zeros.
            const shared = shared_acc[other];
            shared_acc[other] = 0;

            assert(groups[other].size > 0);
            if (groups[id].size + groups[other].size > max_partition_size) continue;

            const other_rsqrt = 1 / @sqrt(vertexWeight(groups[other].vertices));

            // The shared count over the expected boundary of each group;
            // the sum keeps the score symmetric.
            var score = vertexWeight(shared) * (group_rsqrt + other_rsqrt);

            // Nearby groups merge first.
            if (use_bounds) score *= 1 + 0.4 * boundsScore(groups[id], groups[other]);

            if (score > best_score) {
                best_group = other;
                best_score = score;
                best_shared = shared;
            }
        }
    }

    out_shared.* = best_shared;
    return best_group;
}

/// Links group `id`'s clusters after the last of `into`'s.
fn linkGroup(groups: []ClusterGroup, into: u32, id: u32) void {
    var tail = into;
    while (groups[tail].next >= 0) tail = @intCast(groups[tail].next);

    groups[tail].next = @intCast(id);
}

/// Merges each group of `order` below the target size into the nearest
/// group it fits with.
fn mergeLeaf(
    groups: []ClusterGroup,
    order: []const u32,
    target_partition_size: usize,
    max_partition_size: usize,
) void {
    for (order) |id| {
        if (groups[id].size == 0 or groups[id].size >= target_partition_size) continue;

        var best_score: f32 = -1;
        var best_group: ?u32 = null;

        for (order) |other| {
            if (id == other or groups[other].size == 0) continue;

            if (groups[id].size + groups[other].size > max_partition_size) continue;

            // Nearby groups merge first.
            const score = boundsScore(groups[id], groups[other]);

            if (score > best_score) {
                best_score = score;
                best_group = other;
            }
        }

        // Merging id into best_group, not the other way, lets more groups
        // join best_group, which then more likely reaches the target.
        if (best_group) |best| {
            linkGroup(groups, best, id);

            // The vertex count stays, as the spatial merge does not use it.
            groups[best].size += groups[id].size;
            groups[id].size = 0;

            mergeBounds(&groups[best], groups[id]);
            groups[id].radius = 0;
        }
    }
}

/// Moves the groups of `order` whose center is below `pivot` on `axis` to
/// the front, and returns how many there are.
fn mergePartition(order: []u32, groups: []const ClusterGroup, axis: usize, pivot: f32) usize {
    var m: usize = 0;

    // Groups before m are below the pivot, groups from m to i are not.
    for (0..order.len) |i| {
        const v = groups[order[i]].center[axis];

        // Swapping unconditionally keeps both runs when v is not below.
        std.mem.swap(u32, &order[m], &order[i]);

        m += @intFromBool(v < pivot);
    }

    return m;
}

/// Merges small groups of `order` with nearby ones, within halves of space
/// split recursively.
fn mergeSpatial(
    groups: []ClusterGroup,
    order: []u32,
    target_partition_size: usize,
    max_partition_size: usize,
    leaf_size: usize,
    depth: u32,
) void {
    const count = order.len;

    var total: usize = 0;
    for (order) |id| total += groups[id].size;

    if (total <= max_partition_size or count <= leaf_size) {
        return mergeLeaf(groups, order, target_partition_size, max_partition_size);
    }

    var mean: [3]f32 = @splat(0);
    var vars: [3]f32 = @splat(0);
    var runc: f32 = 1;
    var runs: f32 = 1;

    // The centers' statistics, by Welford's algorithm.
    for (order) |id| {
        const point = groups[id].center;

        for (0..3) |k| {
            const delta = point[k] - mean[k];
            mean[k] += delta * runs;
            vars[k] += delta * (point[k] - mean[k]);
        }

        runc += 1;
        runs = 1 / runc;
    }

    // Split on the axis of largest variance.
    const axis: usize = if (vars[0] >= vars[1] and vars[0] >= vars[2])
        0
    else if (vars[1] >= vars[2]) 1 else 2;

    const split = mean[axis];
    var middle = mergePartition(order, groups, axis, split);

    // A degenerate partition splits in half; so does the depth cutoff,
    // which bounds the recursion on pathological inputs.
    if (middle <= leaf_size / 2 or count - middle <= leaf_size / 2 or depth >= merge_depth_cutoff) {
        middle = count / 2;
    }

    // The recursion is logarithmic, and bounded by the cutoff.
    mergeSpatial(
        groups,
        order[0..middle],
        target_partition_size,
        max_partition_size,
        leaf_size,
        depth + 1,
    );
    mergeSpatial(
        groups,
        order[middle..],
        target_partition_size,
        max_partition_size,
        leaf_size,
        depth + 1,
    );
}

/// Groups clusters into partitions of about `target_partition_size`
/// clusters each, at most a third more, favoring clusters that share
/// vertices or, given `positions`, are close; writes each cluster's
/// partition to `destination` and returns the partition count. Without
/// positions, only clusters that share vertices group, which can leave
/// small partitions.
///
/// `cluster_indices` holds every cluster's vertex indices, one cluster
/// after another, `cluster_index_counts[i]` of them for cluster `i`; they
/// refer to `vertex_count` vertices, which `positions`, if given, holds.
/// `destination` holds a partition for each cluster.
pub fn partitionClusters(
    gpa: Allocator,
    destination: []u32,
    cluster_indices: []const u32,
    cluster_index_counts: []const u32,
    positions: ?VertexFloats,
    vertex_count: usize,
    target_partition_size: usize,
) Allocator.Error!usize {
    if (positions) |p| assert(p.stride >= 3 and p.stride <= 64);
    assert(target_partition_size > 0);

    const cluster_count = cluster_index_counts.len;
    const max_partition_size = target_partition_size + target_partition_size / 3;

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const used = try scratch.alloc(u8, vertex_count);
    @memset(used, 0);

    const cluster_newindices = try scratch.alloc(u32, cluster_indices.len);
    const cluster_offsets = try scratch.alloc(u32, cluster_count + 1);

    // The clusters' indices without repeats.
    filterClusterIndices(
        cluster_newindices,
        cluster_offsets,
        cluster_indices,
        cluster_index_counts,
        used,
    );
    const indices = cluster_newindices;

    // Which clusters share vertices, and how many.
    const adjacency: ClusterAdjacency = try .init(&scratch, indices, cluster_offsets, vertex_count);

    const groups = try scratch.alloc(ClusterGroup, cluster_count);
    @memset(groups, .zero);

    const order = try scratch.alloc(GroupOrder, cluster_count);
    var pending: usize = 0;

    const shared_acc = try scratch.alloc(u32, cluster_count);
    @memset(shared_acc, 0);

    // A group of its own for each cluster, in the heap by vertex count.
    for (groups, 0..) |*group, i| {
        group.group = @intCast(i);
        group.next = -1;
        group.size = 1;
        group.vertices = cluster_offsets[i + 1] - cluster_offsets[i];
        assert(group.vertices > 0);

        if (positions) |p| {
            const cluster = indices[cluster_offsets[i]..cluster_offsets[i + 1]];
            group.radius = clusterBounds(cluster, p, &group.center);
        }

        heapPush(order, pending, .{ .id = @intCast(i), .order = @bitCast(group.vertices) });
        pending += 1;
    }

    // Merge the smallest group with its best neighbor, over and over.
    while (pending > 0) {
        var top = heapPop(order, pending);
        pending -= 1;

        // Merged into another group already.
        if (groups[top.id].size == 0) continue;

        // Take its clusters out of merging; they come back if the group
        // returns to the heap.
        var i: i32 = @intCast(top.id);
        while (i >= 0) : (i = groups[@intCast(i)].next) {
            assert(groups[@intCast(i)].group == top.id);
            groups[@intCast(i)].group = -1;
        }

        // Large enough: it stays as it is.
        if (groups[top.id].size >= target_partition_size) continue;

        var best_shared: u32 = 0;
        // No group to grow with: it stays as it is.
        const best_group = pickGroupToMerge(
            groups,
            top.id,
            adjacency,
            max_partition_size,
            positions != null,
            shared_acc,
            &best_shared,
        ) orelse continue;

        linkGroup(groups, top.id, best_group);

        // The vertex count is an approximation, which saves recounting.
        const top_group = &groups[top.id];
        top_group.size += groups[best_group].size;
        top_group.vertices += groups[best_group].vertices;
        top_group.vertices = if (top_group.vertices > best_shared)
            top_group.vertices - best_shared
        else
            1;

        groups[best_group].size = 0;
        groups[best_group].vertices = 0;

        if (positions != null) {
            mergeBounds(top_group, groups[best_group]);
            groups[best_group].radius = 0;
        }

        // The clusters come back, as one group.
        i = @intCast(top.id);
        while (i >= 0) : (i = groups[@intCast(i)].next) {
            groups[@intCast(i)].group = @intCast(top.id);
        }

        top.order = @bitCast(top_group.vertices);
        heapPush(order, pending, top);
        pending += 1;
    }

    // With positions, small groups that remain merge by distance alone.
    if (positions != null) {
        const merge_order = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(order));
        var merge_offset: usize = 0;

        for (groups, 0..) |group, i| {
            if (group.size != 0) {
                merge_order[merge_offset] = @intCast(i);
                merge_offset += 1;
            }
        }

        mergeSpatial(
            groups,
            merge_order[0..merge_offset],
            target_partition_size,
            max_partition_size,
            8,
            0,
        );
    }

    // Number the groups that remain.
    var next_group: u32 = 0;

    for (groups, 0..) |group, i| {
        if (group.size == 0) continue;

        var j: i32 = @intCast(i);
        while (j >= 0) : (j = groups[@intCast(j)].next) destination[@intCast(j)] = next_group;

        next_group += 1;
    }

    return next_group;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "clusters that share vertices group" {
    // Two pairs of triangles, each pair sharing an edge.
    const indices = [_]u32{ 0, 1, 2, 1, 2, 3, 4, 5, 6, 5, 6, 7 };
    const counts = [_]u32{ 3, 3, 3, 3 };
    var destination: [4]u32 = undefined;
    const partitions = try partitionClusters(
        testing.allocator,
        &destination,
        &indices,
        &counts,
        null,
        8,
        2,
    );
    try testing.expectEqual(2, partitions);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1 }, &destination);
}
