//! Unity's compressed mesh block (`Mesh.m_CompressedMesh`).
//!
//! A mesh can ship with its geometry packed into `m_CompressedMesh` instead of laid out in
//! `m_VertexData`: the vertex buffer is empty (`m_VertexCount` 0, no streamed range), and each
//! attribute is a `PackedBitVector`/`PackedFloatVector` of `m_NumItems` values of `m_BitSize`
//! bits, packed LSB-first and contiguous in `m_Data`. Both exporters used to refuse a
//! compressed mesh outright, so a container could report no skips while its meshes were
//! absent (7 Days to Die's loot piles and swing set are six of them).
//!
//! `decode` turns that block back into the channel-packed `Mesh` the exporters already read:
//! position float3 at offset 0, normal float3 at 12, UV float2 at 24, stride 32, and an index
//! buffer of u16 or u32. Nothing in the writers changes.
//!
//! Verified against a real mesh: `medicLootPileA_1` (7,953 vertex components, 10 bits each)
//! decodes to x -0.1481..0.1239, y -0.0005..0.2064, z -0.1020..0.1707 against its
//! `m_LocalAABB` of x -0.1485..0.1243, y -0.0008..0.2068, z -0.1024..0.1712, the gap being
//! the quantisation the AABB is computed before.
const std = @import("std");
const classes = @import("classes.zig");
const value = @import("value.zig");

/// One packed attribute, as the file states it.
const Packed = struct {
    num_items: usize,
    bit_size: u5,
    data: []const u8,
    /// Zero for an index list, which is not scaled.
    start: f32 = 0,
    range: f32 = 0,
};

fn packedValue(v: value.Value) ?Packed {
    if (v != .obj) return null;
    const items = value.intField(v, "m_NumItems") orelse return null;
    const bits = value.intField(v, "m_BitSize") orelse return null;
    if (items <= 0 or bits <= 0 or bits > 32) return null;
    const data = value.bytesField(v, "m_Data") orelse return null;
    const needed = (@as(usize, @intCast(items)) * @as(usize, @intCast(bits)) + 7) / 8;
    if (data.len < needed) return null;
    return .{
        .num_items = @intCast(items),
        .bit_size = @intCast(bits),
        .data = data,
        .start = @floatCast(value.floatField(v, "m_Start") orelse 0),
        .range = @floatCast(value.floatField(v, "m_Range") orelse 0),
    };
}

/// `bit_size` bits starting at `bit_offset`, LSB-first within each byte, as Unity packs them.
fn readBits(data: []const u8, bit_offset: usize, bit_size: u5) u32 {
    var out: u32 = 0;
    var i: u5 = 0;
    while (i < bit_size) : (i += 1) {
        const at = bit_offset + i;
        const bit: u32 = (data[at >> 3] >> @intCast(at & 7)) & 1;
        out |= bit << i;
    }
    return out;
}

fn unpackFloats(arena: std.mem.Allocator, p: Packed) ![]f32 {
    const out = try arena.alloc(f32, p.num_items);
    const mask: f32 = @floatFromInt((@as(u64, 1) << p.bit_size) - 1);
    for (0..p.num_items) |i| {
        const bits = readBits(p.data, i * p.bit_size, p.bit_size);
        out[i] = p.start + @as(f32, @floatFromInt(bits)) * p.range / mask;
    }
    return out;
}

fn unpackInts(arena: std.mem.Allocator, p: Packed) ![]u32 {
    const out = try arena.alloc(u32, p.num_items);
    for (0..p.num_items) |i| {
        out[i] = readBits(p.data, i * p.bit_size, p.bit_size);
    }
    return out;
}

/// The decoded mesh as the channel-packed `Mesh` the exporters read, or null when the object
/// carries no compressed geometry. `uv_index` is the channel UV0 lives in for the file's Unity
/// version (4 from 2018, 3 before), so the writers find it where they look.
pub fn decode(
    arena: std.mem.Allocator,
    v: value.Value,
    uv_index: usize,
) !?classes.Mesh {
    const block = value.fieldOf(v, "m_CompressedMesh") orelse return null;
    if (block != .obj) return null;
    const vertices = packedValue(value.fieldOf(block, "m_Vertices") orelse return null) orelse return null;
    if (vertices.num_items == 0 or vertices.num_items % 3 != 0) return null;
    const count = vertices.num_items / 3;
    const positions = try unpackFloats(arena, vertices);

    const normals: ?[]f32 = blk: {
        const raw = value.fieldOf(block, "m_Normals") orelse break :blk null;
        const nvec = packedValue(raw) orelse break :blk null;
        if (nvec.num_items != vertices.num_items) break :blk null;
        break :blk try unpackFloats(arena, nvec);
    };
    const uvs: ?[]f32 = blk: {
        const raw = value.fieldOf(block, "m_UV") orelse break :blk null;
        const uvec = packedValue(raw) orelse break :blk null;
        if (uvec.num_items != count * 2) break :blk null;
        break :blk try unpackFloats(arena, uvec);
    };
    const indices: ?[]u32 = blk: {
        const raw = value.fieldOf(block, "m_Triangles") orelse break :blk null;
        const tvec = packedValue(raw) orelse break :blk null;
        if (tvec.num_items == 0) break :blk null;
        break :blk try unpackInts(arena, tvec);
    };

    // The interleaved layout the writers already understand: 32 bytes a vertex, position at 0,
    // normal at 12, UV at 24. A missing attribute keeps its channel dimension at zero, so the
    // writer skips it the same way it skips an absent channel in an uncompressed mesh.
    const stride = 32;
    const bytes = try arena.alloc(u8, count * stride);
    @memset(bytes, 0);
    for (0..count) |i| {
        const floats = [_]f32{
            positions[i * 3 + 0],
            positions[i * 3 + 1],
            positions[i * 3 + 2],
            if (normals) |n| n[i * 3 + 0] else 0,
            if (normals) |n| n[i * 3 + 1] else 0,
            if (normals) |n| n[i * 3 + 2] else 0,
            if (uvs) |u| u[i * 2 + 0] else 0,
            if (uvs) |u| u[i * 2 + 1] else 0,
        };
        for (floats, 0..) |f, slot| {
            std.mem.writeInt(u32, bytes[i * stride + slot * 4 ..][0..4], @bitCast(f), .little);
        }
    }

    var mesh = classes.Mesh{
        .name = value.stringField(v, "m_Name") orelse "",
        .vertex_count = @intCast(count),
        .vertex_data = bytes,
        .index_format = if (count < 0x10000) 0 else 1,
    };
    mesh.channels[0] = .{
        .stream = 0,
        .offset = 0,
        .format = 0,
        .dimension = 3,
        .real_dimension = 3,
    };
    var channel_count: usize = 1;
    if (normals != null) {
        mesh.channels[1] = .{
            .stream = 0,
            .offset = 12,
            .format = 0,
            .dimension = 3,
            .real_dimension = 3,
        };
        channel_count = 2;
    }
    if (uvs != null and uv_index < mesh.channels.len) {
        mesh.channels[uv_index] = .{
            .stream = 0,
            .offset = 24,
            .format = 0,
            .dimension = 2,
            .real_dimension = 2,
        };
        channel_count = @max(channel_count, uv_index + 1);
    }
    mesh.channel_count = channel_count;

    if (indices) |list| {
        const width: usize = if (mesh.index_format == 1) 4 else 2;
        const buffer = try arena.alloc(u8, list.len * width);
        for (list, 0..) |index, i| {
            if (width == 4) {
                std.mem.writeInt(u32, buffer[i * 4 ..][0..4], index, .little);
            } else {
                std.mem.writeInt(u16, buffer[i * 2 ..][0..2], @intCast(index), .little);
            }
        }
        mesh.index_buffer = buffer;
    }
    return mesh;
}

fn testObject(fields: []const value.Field) value.Value {
    return .{ .obj = fields };
}

test "a packed float is start plus its bits scaled by the range" {
    // 8-bit values 0, 255 and 128 of range 1 starting at 0: the ends are exact and the middle
    // is 128/255.
    const data = [_]u8{ 0, 255, 128 };
    const vec = Packed{ .num_items = 3, .bit_size = 8, .data = &data, .start = 0, .range = 1 };
    const floats = try unpackFloats(std.testing.allocator, vec);
    defer std.testing.allocator.free(floats);
    try std.testing.expectApproxEqAbs(@as(f32, 0), floats[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), floats[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), floats[2], 1e-6);
}

test "bits are packed contiguously and read least significant first" {
    // Three 3-bit values, 1, 2 and 7, occupy nine bits, least significant first: value 1 puts
    // its bit at position 0, value 2 puts its middle bit at 4, and value 7 fills 6, 7 and 8, so
    // byte 0 is 1 + 16 + 64 + 128 = 0b1101_0001 and byte 1 is 0b0000_0001.
    const data = [_]u8{ 0b1101_0001, 0b0000_0001 };
    const vec = Packed{ .num_items = 3, .bit_size = 3, .data = &data };
    const ints = try unpackInts(std.testing.allocator, vec);
    defer std.testing.allocator.free(ints);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 7 }, ints);
}

test "a compressed mesh decodes into the channel layout the writers read" {
    // Two vertices: (0, 0, 0) and (1, 1, 1), one byte a component.
    const vertex_data = [_]u8{ 0, 0, 0, 255, 255, 255 };
    const index_data = [_]u8{ 0, 1, 2 };
    const fields = [_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "compressed" } },
        .{
            .name = "m_CompressedMesh",
            .value = testObject(&[_]value.Field{
                .{
                    .name = "m_Vertices",
                    .value = testObject(&[_]value.Field{
                        .{ .name = "m_NumItems", .value = .{ .int = 6 } },
                        .{ .name = "m_BitSize", .value = .{ .int = 8 } },
                        .{ .name = "m_Data", .value = .{ .bytes = &vertex_data } },
                        .{ .name = "m_Start", .value = .{ .float = 0 } },
                        .{ .name = "m_Range", .value = .{ .float = 1 } },
                    }),
                },
                .{
                    .name = "m_Triangles",
                    .value = testObject(&[_]value.Field{
                        .{ .name = "m_NumItems", .value = .{ .int = 3 } },
                        .{ .name = "m_BitSize", .value = .{ .int = 8 } },
                        .{ .name = "m_Data", .value = .{ .bytes = &index_data } },
                    }),
                },
            }),
        },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const decoded = (try decode(arena_state.allocator(), testObject(&fields), 4)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("compressed", decoded.name);
    try std.testing.expectEqual(@as(u32, 2), decoded.vertex_count);
    try std.testing.expectEqual(@as(usize, 1), decoded.channel_count);
    try std.testing.expectEqual(@as(i32, 0), decoded.index_format);
    try std.testing.expectEqual(@as(usize, 3) * 2, decoded.index_buffer.len);
    // Two vertices, both at x 0: the second's y is 1 and its z is 0.
    try std.testing.expectApproxEqAbs(
        @as(f32, 1),
        std.mem.bytesToValue(f32, decoded.vertex_data[32 + 4 ..][0..4]),
        1e-6,
    );
    try std.testing.expect(decoded.channel(0) != null);
    try std.testing.expect(decoded.channel(4) == null); // no UV vector in this fixture
}

test "an object with no compressed block decodes to nothing" {
    const fields = [_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "plain" } },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect((try decode(arena_state.allocator(), testObject(&fields), 4)) == null);
}
