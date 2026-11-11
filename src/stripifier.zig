//! Triangle strips: turning a vertex cache optimized triangle list into
//! strips, joined by restart indices or degenerate triangles, and strips
//! back into a list.
//!
//! Translated from meshoptimizer's stripifier.cpp, which builds on Evans,
//! Skiena and Varshney, "Optimizing Triangle Strips for Fast Rendering"
//! (1996), and Hoppe, "Optimization of Mesh Locality for Transparent Vertex
//! Caching" (1999).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Scratch = @import("allocator.zig").Scratch;
const checkIndex = @import("index.zig").check;

/// The triangle of `buffer` to start a strip with: `hint` if it is there,
/// else the first whose least used corner has the lowest valence.
fn findStripFirst(
    comptime Index: type,
    buffer: []const [3]Index,
    valence: []const u8,
    hint: [3]Index,
) usize {
    var index: usize = 0;
    var iv: u32 = std.math.maxInt(u32);

    for (buffer, 0..) |triangle, i| {
        if (triangle[0] == hint[0] and triangle[1] == hint[1] and triangle[2] == hint[2]) {
            return i;
        }

        const va = valence[triangle[0]];
        const vb = valence[triangle[1]];
        const vc = valence[triangle[2]];
        const v: u32 = if (va < vb and va < vc) va else if (vb < vc) vb else vc;

        if (v < iv) {
            index = i;
            iv = v;
        }
    }

    return index;
}

/// The first triangle of `buffer` with the directed edge `e0 e1`, as its
/// place times 4 plus the corner opposite the edge, or -1 if none has it.
/// Smaller results are earlier triangles.
fn findStripNext(comptime Index: type, buffer: []const [3]Index, e0: Index, e1: Index) i32 {
    const e = @as(u64, e0) << 32 | e1;

    for (buffer, 0..) |triangle, i| {
        const a = triangle[0];
        const b = triangle[1];
        const c = triangle[2];

        const ab = @as(u64, a) << 32 | b;
        const bc = @as(u64, b) << 32 | c;
        const ca = @as(u64, c) << 32 | a;

        const place: i32 = @intCast(i);
        if (e == ab) {
            return place << 2 | 2;
        } else if (e == bc) {
            return place << 2 | 0;
        } else if (e == ca) {
            return place << 2 | 1;
        }
    }

    return -1;
}

fn countSharedVertices(comptime Index: type, triangle: [3]Index, valence: []const u8) u32 {
    var count: u32 = 0;
    for (triangle) |v| count += @intFromBool(valence[v] > 1);
    return count;
}

/// Converts the triangle list `indices` into a triangle strip in
/// `destination` and returns its index count. Strips are joined with
/// `restart_index`, or with degenerate triangles when it is 0; use 0xffff
/// or 0xffffffff, as the index size of the draw call requires. Restart
/// indices give 5 to 10% smaller strips, but may draw slower on some GPUs.
/// Optimize `indices` for the vertex cache first for the best strips.
/// `destination` needs `stripifyBound(indices.len)` entries and must not
/// overlap `indices`.
pub fn stripify(
    comptime Index: type,
    gpa: Allocator,
    destination: []Index,
    indices: []const Index,
    vertex_count: usize,
    restart_index: Index,
) Allocator.Error!usize {
    comptime checkIndex(Index);
    assert(indices.len == 0 or destination.ptr != indices.ptr);
    assert(indices.len % 3 == 0);

    var scratch: Scratch = .init(gpa);
    defer scratch.deinit();

    const buffer_capacity = 12;

    var buffer: [buffer_capacity][3]Index = @splat(@splat(0));
    var buffer_size: usize = 0;

    var index_offset: usize = 0;

    var strip: [2]Index = @splat(0);
    var parity = false;

    var strip_size: usize = 0;

    // Vertex valences, to choose the triangles that start and continue
    // strips. They are 8-bit counters for speed: an outlier's count wraps,
    // which only weakens the heuristic.
    const valence = try scratch.alloc(u8, vertex_count);
    @memset(valence, 0);

    for (indices) |index| {
        assert(index < vertex_count);

        valence[index] +%= 1;
    }

    var next: i32 = -1;
    var skipped: [3]Index = @splat(0);

    while (buffer_size > 0 or index_offset < indices.len) {
        // `next` was found in the buffer before it was refilled; refilling
        // only appends.
        assert(next < 0 or @as(usize, @intCast(next >> 2)) < buffer_size);

        // Fill the triangle buffer.
        while (buffer_size < buffer_capacity and index_offset < indices.len) {
            buffer[buffer_size] = indices[index_offset..][0..3].*;

            buffer_size += 1;
            index_offset += 3;
        }

        if (next >= 0) {
            const i: usize = @intCast(next >> 2);
            const a = buffer[i][0];
            const b = buffer[i][1];
            const c = buffer[i][2];
            const v = buffer[i][@intCast(next & 3)];

            // Remove the triangle, keeping the buffer's order.
            const rest = buffer[i + 1 .. buffer_size];
            std.mem.copyForwards([3]Index, buffer[i..][0..rest.len], rest);
            buffer_size -= 1;

            // Update the valences for the strip start and continuation
            // heuristics.
            valence[a] -%= 1;
            valence[b] -%= 1;
            valence[c] -%= 1;

            // Find the next triangle; the edge's direction flips every
            // step. Sometimes a swap picks a different outgoing edge: for
            // [a b c] the strip's edge is [b c], but [a c] may be better.
            // The search is skipped when the older strip vertex has no
            // triangles left, for speed.
            const live = buffer[0..buffer_size];
            var cont: i32 = if (valence[strip[1]] != 0)
                findStripNext(Index, live, if (parity) strip[1] else v, if (parity) v else strip[1])
            else
                -1;
            const swap: i32 = if (valence[strip[0]] != 0)
                findStripNext(Index, live, if (parity) v else strip[0], if (parity) strip[0] else v)
            else
                -1;

            // When both edges continue, take the triangle with fewer
            // neighbors, to avoid dead ends later: locally worse, one index
            // spent on the swap, but smaller strips in the end.
            if (cont >= 0 and swap >= 0) {
                const swap_shared = countSharedVertices(
                    Index,
                    buffer[@intCast(swap >> 2)],
                    valence,
                );
                const cont_shared = countSharedVertices(
                    Index,
                    buffer[@intCast(cont >> 2)],
                    valence,
                );
                const use_swap = swap_shared < cont_shared;

                // Remember the triangle not taken, to restart a strip from.
                skipped = buffer[@intCast((if (use_swap) cont else swap) >> 2)];
                if (use_swap) cont = -1;
            }

            if (cont < 0 and swap >= 0) {
                // [a b c] => [a b a c]
                destination[strip_size] = strip[0];
                destination[strip_size + 1] = v;
                strip_size += 2;

                // The next strip step has the same winding: ? a b => b a v.
                strip[1] = v;

                next = swap;
            } else {
                // The strip's next vertex.
                destination[strip_size] = v;
                strip_size += 1;

                // The next strip step has the opposite winding.
                strip[0] = strip[1];
                strip[1] = v;
                parity = !parity;

                next = cont;
            }
        } else {
            // Nothing continues the strip: start a new one, from the
            // triangle the heuristic expects to give the longest strip.
            const i = findStripFirst(Index, buffer[0..buffer_size], valence, skipped);
            var a = buffer[i][0];
            var b = buffer[i][1];
            var c = buffer[i][2];

            // Remove the triangle, keeping the buffer's order.
            const rest = buffer[i + 1 .. buffer_size];
            std.mem.copyForwards([3]Index, buffer[i..][0..rest.len], rest);
            buffer_size -= 1;

            // Update the valences for the strip start and continuation
            // heuristics.
            valence[a] -%= 1;
            valence[b] -%= 1;
            valence[c] -%= 1;

            // Rotate the triangle so the next step finds its continuation
            // in the buffer.
            const live = buffer[0..buffer_size];
            const ea = findStripNext(Index, live, c, b);
            const eb = findStripNext(Index, live, a, c);
            const ec = findStripNext(Index, live, b, a);

            // Several edges may continue; any would do, and the one with
            // the earliest triangle in the buffer weakens the vertex cache
            // order least and, for unclear reasons, gives slightly better
            // strips.
            var mine: i32 = std.math.maxInt(i32);
            mine = if (ea >= 0 and mine > ea) ea else mine;
            mine = if (eb >= 0 and mine > eb) eb else mine;
            mine = if (ec >= 0 and mine > ec) ec else mine;

            if (ea == mine) {
                // keep abc
                next = ea;
            } else if (eb == mine) {
                // abc -> bca
                const t = a;
                a = b;
                b = c;
                c = t;

                next = eb;
            } else if (ec == mine) {
                // abc -> cab
                const t = c;
                c = b;
                b = a;
                a = t;

                next = ec;
            }

            if (restart_index != 0) {
                if (strip_size != 0) {
                    destination[strip_size] = restart_index;
                    strip_size += 1;
                }

                destination[strip_size..][0..3].* = .{ a, b, c };
                strip_size += 3;

                // A new strip always starts with the same edge winding.
                strip = .{ b, c };
                parity = true;
            } else {
                if (strip_size != 0) {
                    // Join the last strip with degenerate triangles.
                    destination[strip_size..][0..2].* = .{ strip[1], a };
                    strip_size += 2;
                }

                // The triangle may have to flip with the parity, to end
                // with the outgoing edge c b either way.
                const e0 = if (parity) c else b;
                const e1 = if (parity) b else c;

                destination[strip_size..][0..3].* = .{ a, e0, e1 };
                strip_size += 3;

                strip = .{ e0, e1 };
                parity = !parity;
            }
        }
    }

    return strip_size;
}

/// The most indices `stripify` writes for `index_count` list indices.
pub fn stripifyBound(index_count: usize) usize {
    assert(index_count % 3 == 0);

    // At worst a triangle takes 2 degenerate indices and its 3 without
    // restarts, or a restart index and its 3 with them.
    return (index_count / 3) * 5;
}

/// Converts the triangle strip `indices`, with strips separated by
/// `restart_index` (0 for none), into a triangle list in `destination`, and
/// returns its index count. Degenerate triangles are left out.
/// `destination` needs `unstripifyBound(indices.len)` entries and must not
/// overlap `indices`.
pub fn unstripify(
    comptime Index: type,
    destination: []Index,
    indices: []const Index,
    restart_index: Index,
) usize {
    comptime checkIndex(Index);
    assert(indices.len == 0 or destination.ptr != indices.ptr);

    var offset: usize = 0;
    var start: usize = 0;

    for (indices, 0..) |index, i| {
        if (restart_index != 0 and index == restart_index) {
            start = i + 1;
        } else if (i - start >= 2) {
            var a = indices[i - 2];
            var b = indices[i - 1];
            const c = indices[i];

            // Odd triangles have the opposite winding.
            if ((i - start) & 1 != 0) std.mem.swap(Index, &a, &b);

            // Swaps in the strip make degenerate triangles, restart indices
            // or not; leave them out.
            if (a != b and a != c and b != c) {
                destination[offset..][0..3].* = .{ a, b, c };
                offset += 3;
            }
        }
    }

    return offset;
}

/// The most indices `unstripify` writes for `index_count` strip indices
/// (0, or at least 3).
pub fn unstripifyBound(index_count: usize) usize {
    assert(index_count == 0 or index_count >= 3);

    return if (index_count == 0) 0 else (index_count - 2) * 3;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a strip turns back into its triangles" {
    // A quad as two triangles sharing the edge 1 2.
    const list = [_]u32{ 0, 1, 2, 2, 1, 3 };
    var strip: [10]u32 = undefined;
    const strip_size = try stripify(u32, testing.allocator, &strip, &list, 4, 0);
    try testing.expectEqual(4, strip_size);
    var back: [6]u32 = undefined;
    try testing.expectEqual(6, unstripify(u32, &back, strip[0..strip_size], 0));
    try testing.expectEqualSlices(u32, &list, &back);
}
