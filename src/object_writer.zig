//! TypeTree-driven object serializer — the inverse of `object_reader`.
//!
//! Writes a [`value.Value`] tree back to Unity's wire format by walking
//! the same TypeTree the reader uses, mirroring every rule:
//!
//! - nodes with `meta_flags & 0x4000` are padded to a 4-byte boundary
//!   after writing;
//! - `string`/`TypelessData` are i32 length + bytes; strings are always
//!   4-aligned after their payload, matching Unity's writer;
//! - arrays carry an i32 count then elements (scalars as one contiguous
//!   run); the array pads as a unit;
//! - `map` elements are pairs; `PPtr<T>` writes file ID + path ID;
//! - unknown fixed-size leaves write their raw bytes.
//!
//! Byte-array fields (`TypelessData`, 1-byte element arrays, opaque
//! leaves) accept raw `.bytes` or the base64 string `value.jsonWrite`
//! exports, so a JSON export writes back without a separate conversion.
//!
//! Records require a value for every *named* child. Unnamed children
//! cannot be reconstructed from a value tree and are rejected; callers
//! editing real files will not hit them in practice.

const std = @import("std");
const streams = @import("streams.zig");
const typetree = @import("typetree.zig");
const value = @import("value.zig");
const object_reader = @import("object_reader.zig");

pub const Error = error{
    MissingField,
    UnnamedChild,
    TypeMismatch,
    Corrupt,
    UnsupportedManagedReference,
    OutOfMemory,
};

/// Writes `root_value` to `w` (which must be positioned at the object's
/// first byte), consuming exactly the object's serialized extent. `tail`
/// holds the bytes that follow the type tree's fields (the raw serialized
/// script graph of a MonoBehaviour); UnityPy preserves them the same way,
/// so rewrites do not silently drop payload data.
pub fn writeObject(w: *streams.Writer, root: *const typetree.Node, root_value: value.Value, tail: []const u8) Error!void {
    try writeNode(w, root, root_value, false);
    try w.writeBytes(tail);
}

fn writeNode(
    w: *streams.Writer,
    node: *const typetree.Node,
    v: value.Value,
    suppress_align: bool,
) Error!void {
    const type_name = node.type_name;

    if (std.mem.eql(u8, type_name, "string")) {
        const s = switch (v) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        try w.writeInt(i32, @intCast(s.len));
        try w.writeBytes(s);
        // Strings are always 4-aligned in the wire format (see the reader).
        if (!suppress_align) try w.alignTo4();
        return;
    }
    if (std.mem.eql(u8, type_name, "TypelessData")) {
        const b = try asBytes(w.allocator, v);
        try w.writeInt(i32, @intCast(b.len));
        try w.writeBytes(b);
        if (!suppress_align and nodeAligned(node)) try w.alignTo4();
        return;
    }
    if (object_reader.primitiveKind(type_name)) |prim| {
        if (node.children.len != 0) return error.TypeMismatch;
        try writePrimitive(w, prim, v);
        if (!suppress_align and nodeAligned(node)) try w.alignTo4();
        return;
    }
    if (std.mem.eql(u8, type_name, "pair")) {
        if (node.children.len != 2) return error.Corrupt;
        const items = switch (v) {
            .array => |a| a,
            else => return error.TypeMismatch,
        };
        if (items.len != 2) return error.TypeMismatch;
        try writeNode(w, &node.children[0], items[0], false);
        try writeNode(w, &node.children[1], items[1], false);
        if (!suppress_align and nodeAligned(node)) try w.alignTo4();
        return;
    }
    if (object_reader.isPPtrType(type_name)) {
        try writePPtr(w, node, v, suppress_align);
        return;
    }
    if (std.mem.eql(u8, type_name, "ReferencedObject") or
        std.mem.eql(u8, type_name, "ManagedReferencesRegistry"))
    {
        return error.UnsupportedManagedReference;
    }

    const array_node = object_reader.collectionArray(node) orelse {
        if (std.mem.eql(u8, type_name, "map")) return error.TypeMismatch;
        if (node.children.len != 0) {
            // Record: write each child's value in order.
            const fields = switch (v) {
                .obj => |f| f,
                else => return error.TypeMismatch,
            };
            for (node.children) |*child| {
                if (child.name.len == 0) return error.UnnamedChild;
                const child_value = findField(fields, child.name) orelse return error.MissingField;
                try writeNode(w, child, child_value, false);
            }
            if (!suppress_align and nodeAligned(node)) try w.alignTo4();
            return;
        }
        // Opaque fixed-size leaf: raw bytes.
        if (node.byte_size < 0) return error.TypeMismatch;
        const b = try asBytes(w.allocator, v);
        if (b.len != @as(usize, @intCast(node.byte_size))) return error.TypeMismatch;
        try w.writeBytes(b);
        if (!suppress_align and nodeAligned(node)) try w.alignTo4();
        return;
    };

    // Collection (sequence or map).
    if (array_node.children.len != 2) return error.Corrupt;
    const size_node = &array_node.children[0];
    if (size_node.children.len != 0 or object_reader.primitiveKind(size_node.type_name) != .i32) return error.Corrupt;
    const element_node = &array_node.children[1];
    const element_prim = object_reader.primitiveKind(element_node.type_name);

    // Arrays of 1-byte integers may be carried as raw bytes (the reader's
    // coalesced form) or as an array of values (a JSON edit).
    if (element_node.children.len == 0 and element_prim != null and object_reader.isByteKind(element_prim.?)) {
        const b = switch (v) {
            .bytes, .string => try asBytes(w.allocator, v),
            .array => |a| blk: {
                const out = try w.allocator.alloc(u8, a.len);
                for (a, 0..) |item, i| {
                    out[i] = try narrowInt(u8, item.asInt() orelse return error.TypeMismatch);
                }
                break :blk out;
            },
            else => return error.TypeMismatch,
        };
        try w.writeInt(i32, @intCast(b.len));
        try w.writeBytes(b);
        const aligns = nodeAligned(node) or nodeAligned(array_node) or nodeAligned(element_node);
        if (!suppress_align and aligns) try w.alignTo4();
        return;
    }

    const items = switch (v) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };
    try w.writeInt(i32, @intCast(items.len));
    if (element_node.children.len == 0 and element_prim != null) {
        for (items) |item| {
            try writePrimitive(w, element_prim.?, item);
        }
    } else {
        const suppress_element = nodeAligned(element_node);
        for (items) |item| {
            try writeNode(w, element_node, item, suppress_element);
        }
    }

    const aligns = nodeAligned(node) or nodeAligned(array_node) or nodeAligned(element_node);
    if (!suppress_align and aligns) try w.alignTo4();
}

/// Raw bytes of a byte-array value: `.bytes` as read, or a base64 string
/// as `value.jsonWrite` exports them, so JSON exports feed straight back
/// into the writer (`edit --patch`, `create`).
fn asBytes(allocator: std.mem.Allocator, v: value.Value) Error![]const u8 {
    return switch (v) {
        .bytes => |b| b,
        .string => |s| blk: {
            const size = std.base64.standard.Decoder.calcSizeForSlice(s) catch return error.TypeMismatch;
            const buf = try allocator.alloc(u8, size);
            std.base64.standard.Decoder.decode(buf, s) catch return error.TypeMismatch;
            break :blk buf;
        },
        else => error.TypeMismatch,
    };
}

fn findField(fields: []const value.Field, name: []const u8) ?value.Value {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

fn nodeAligned(node: *const typetree.Node) bool {
    return (node.meta_flags & object_reader.align_flag) != 0;
}

fn writePrimitive(w: *streams.Writer, prim: object_reader.Primitive, v: value.Value) Error!void {
    switch (prim) {
        .bool => {
            const b = switch (v) {
                .bool => |b| b,
                else => return error.TypeMismatch,
            };
            try w.writeByte(@intFromBool(b));
        },
        .i8 => try w.writeInt(i8, try narrowInt(i8, try asInt(v))),
        .u8 => try w.writeInt(u8, try narrowInt(u8, try asInt(v))),
        .i16 => try w.writeInt(i16, try narrowInt(i16, try asInt(v))),
        .u16 => try w.writeInt(u16, try narrowInt(u16, try asInt(v))),
        .i32 => try w.writeInt(i32, try narrowInt(i32, try asInt(v))),
        .u32 => try w.writeInt(u32, try narrowInt(u32, try asInt(v))),
        .i64 => try w.writeInt(i64, try asInt(v)),
        .u64 => try w.writeInt(u64, try asUint(v)),
        .f32 => try w.writeFloat(f32, @floatCast(try asFloat(v))),
        .f64 => try w.writeFloat(f64, try asFloat(v)),
    }
}

fn asInt(v: value.Value) Error!i64 {
    return v.asInt() orelse error.TypeMismatch;
}

/// Narrows an edited integer to the width its type tree node declares.
/// Values come from user JSON (`unityz edit ... m_Width 99999999999`), so a
/// value the field cannot hold is an operating error to report, not a
/// `@intCast` the compiler is allowed to turn into a crash.
fn narrowInt(comptime T: type, v: i64) Error!T {
    return std.math.cast(T, v) orelse error.TypeMismatch;
}

fn asUint(v: value.Value) Error!u64 {
    return switch (v) {
        .uint => |u| u,
        .int => |i| if (i >= 0) @intCast(i) else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn asFloat(v: value.Value) Error!f64 {
    // int/uint literals widen, mirroring `value.asFloat`: `extract --json`
    // emits whole-number floats (quaternion w:1, position x:0) without a
    // decimal point, and the round-trip back through `edit --patch` must
    // accept them. `asInt` has always been lenient the same way.
    return switch (v) {
        .float => |f| f,
        .int => |i| @floatFromInt(i),
        .uint => |u| @floatFromInt(u),
        else => error.TypeMismatch,
    };
}

fn writePPtr(w: *streams.Writer, node: *const typetree.Node, v: value.Value, suppress_align: bool) Error!void {
    if (node.children.len == 0) return error.Corrupt;

    const p = switch (v) {
        .pptr => |p| p,
        .obj => |fields| blk: {
            const file = findField(fields, "m_FileID") orelse return error.TypeMismatch;
            const path = findField(fields, "m_PathID") orelse return error.TypeMismatch;
            break :blk value.PPtr{ .file_id = try narrowInt(i32, try asInt(file)), .path_id = try asInt(path) };
        },
        else => return error.TypeMismatch,
    };

    var file_written = false;
    var path_written = false;
    for (node.children) |*child| {
        if (object_reader.isFileIdName(child.name)) {
            const prim = object_reader.primitiveKind(child.type_name) orelse return error.Corrupt;
            try writePrimitive(w, prim, .{ .int = p.file_id });
            file_written = true;
        } else if (object_reader.isPathIdName(child.name)) {
            const prim = object_reader.primitiveKind(child.type_name) orelse return error.Corrupt;
            try writePrimitive(w, prim, .{ .int = p.path_id });
            path_written = true;
        } else {
            // Extra fields: take from the object form when present.
            const extra = switch (v) {
                .obj => |fields| findField(fields, child.name),
                else => null,
            } orelse return error.MissingField;
            try writeNode(w, child, extra, false);
        }
    }
    if (!file_written or !path_written) return error.Corrupt;
    if (!suppress_align and nodeAligned(node)) try w.alignTo4();
}

// ---------------------------------------------------------------------------
// Tests: read a value, write it back, expect byte-identical output.
// ---------------------------------------------------------------------------

test "round trip: rich record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "MonoBehaviour", "Base<MonoBehaviour>", 0, &.{
        try allocNode(a, "bool", "m_Enabled", 0, &.{}),
        try allocNode(a, "string", "m_Name", object_reader.align_flag, &.{}),
        try allocNode(a, "PPtr<MonoBehaviour>", "m_Script", 0, &.{
            try allocNode(a, "int", "m_FileID", 0, &.{}),
            try allocNode(a, "SInt64", "m_PathID", 0, &.{}),
        }),
        try allocNode(a, "int", "m_Count", 0, &.{}),
        try allocNode(a, "Vector3f", "m_Vector3", 0, &.{
            try allocNode(a, "float", "x", 0, &.{}),
            try allocNode(a, "float", "y", 0, &.{}),
            try allocNode(a, "float", "z", 0, &.{}),
        }),
        try allocNode(a, "Array", "m_Values", object_reader.align_flag, &.{
            try allocNode(a, "int", "size", 0, &.{}),
            try allocNode(a, "int", "Array", 0, &.{}),
        }),
        try allocNode(a, "Array", "m_Names", object_reader.align_flag, &.{
            try allocNode(a, "int", "size", 0, &.{}),
            try allocNode(a, "string", "Array", object_reader.align_flag, &.{}),
        }),
    });

    // Build the same wire bytes the object_reader test uses.
    var wire: streams.Writer = .init(a);
    defer wire.deinit();
    try wire.writeByte(1);
    try wire.writeInt(i32, 7);
    try wire.writeBytes("Player\x00");
    try wire.alignTo4();
    try wire.writeInt(i32, 0);
    try wire.writeInt(i64, 42);
    try wire.writeInt(i32, 3);
    try wire.writeFloat(f32, 1.0);
    try wire.writeFloat(f32, 2.0);
    try wire.writeFloat(f32, 3.0);
    try wire.writeInt(i32, 3);
    try wire.writeInt(i32, 10);
    try wire.writeInt(i32, 20);
    try wire.writeInt(i32, 30);
    try wire.writeInt(i32, 2);
    try wire.writeInt(i32, 1);
    try wire.writeBytes("a");
    try wire.writeInt(i32, 2);
    try wire.writeBytes("bb");
    try wire.alignTo4();

    // Read it back into a value...
    var r = streams.Reader.init(wire.getWritten());
    const v = try object_reader.readObject(a, &r, root);

    // ...and write it out again: the bytes must match exactly.
    var out: streams.Writer = .init(a);
    defer out.deinit();
    try writeObject(&out, root, v, &.{});
    try std.testing.expectEqualSlices(u8, wire.getWritten(), out.getWritten());
}

test "write widens int and uint literals to float fields" {
    // `extract --json` prints whole-number floats without a decimal point
    // (quaternion w:1, position x:0), so `edit --patch` feeding that JSON
    // back must accept int/uint literals where the type tree declares a
    // float. Each writes the exact float bits of the widened value.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "Vector3f", "m_Scale", 0, &.{
        try allocNode(a, "float", "x", 0, &.{}),
        try allocNode(a, "float", "y", 0, &.{}),
        try allocNode(a, "float", "z", 0, &.{}),
    });

    var out: streams.Writer = .init(a);
    defer out.deinit();
    try writeObject(&out, root, .{ .obj = &[_]value.Field{
        .{ .name = "x", .value = .{ .int = 0 } },
        .{ .name = "y", .value = .{ .float = 1.5 } },
        .{ .name = "z", .value = .{ .uint = 1 } },
    } }, &.{});

    var expect: streams.Writer = .init(a);
    defer expect.deinit();
    try expect.writeFloat(f32, 0.0);
    try expect.writeFloat(f32, 1.5);
    try expect.writeFloat(f32, 1.0);
    try std.testing.expectEqualSlices(u8, expect.getWritten(), out.getWritten());
}

test "round trip: map and typeless data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "SomeClass", "Base", 0, &.{
        try allocNode(a, "map", "m_Map", object_reader.align_flag, &.{
            try allocNode(a, "Array", "Array", 0, &.{
                try allocNode(a, "int", "size", 0, &.{}),
                try allocNode(a, "pair", "data", 0, &.{
                    try allocNode(a, "string", "first", object_reader.align_flag, &.{}),
                    try allocNode(a, "int", "second", 0, &.{}),
                }),
            }),
        }),
        try allocNode(a, "TypelessData", "m_Blob", object_reader.align_flag, &.{}),
        hash_node: {
            const node = try allocNode(a, "Hash128", "m_Hash", 0, &.{});
            node.byte_size = 16; // opaque fixed 16 bytes
            break :hash_node node;
        },
    });

    var wire: streams.Writer = .init(a);
    defer wire.deinit();
    try wire.writeInt(i32, 2);
    try wire.writeInt(i32, 2);
    try wire.writeBytes("k1");
    try wire.alignTo4();
    try wire.writeInt(i32, 5);
    try wire.writeInt(i32, 2);
    try wire.writeBytes("k2");
    try wire.alignTo4();
    try wire.writeInt(i32, 7);
    try wire.alignTo4();
    try wire.writeInt(i32, 4);
    try wire.writeBytes("blob");
    try wire.alignTo4();
    try wire.writeBytes("0123456789abcdef");

    var r = streams.Reader.init(wire.getWritten());
    const v = try object_reader.readObject(a, &r, root);

    var out: streams.Writer = .init(a);
    defer out.deinit();
    try writeObject(&out, root, v, &.{});
    try std.testing.expectEqualSlices(u8, wire.getWritten(), out.getWritten());
}

test "write rejects missing field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "SomeClass", "Base", 0, &.{
        try allocNode(a, "int", "m_Value", 0, &.{}),
    });
    var w: streams.Writer = .init(a);
    defer w.deinit();
    try std.testing.expectError(error.MissingField, writeObject(&w, root, value.Value{ .obj = &.{} }, &.{}));
}

// --- shared test helpers (mirror object_reader's) ---

fn allocNode(
    a: std.mem.Allocator,
    type_name: []const u8,
    name: []const u8,
    meta_flags: i32,
    children: []const *const typetree.Node,
) !*typetree.Node {
    const node = try a.create(typetree.Node);
    node.* = .{ .level = 0, .type_name = type_name, .name = name, .meta_flags = meta_flags };
    if (children.len > 0) {
        const arr = try a.alloc(typetree.Node, children.len);
        for (children, 0..) |child, i| arr[i] = child.*;
        node.children = arr;
    }
    return node;
}
