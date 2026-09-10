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
//!
//! Managed-reference registries (`ReferencedObject`,
//! `ManagedReferencesRegistry`) are the one place the mirror breaks: the
//! reader decodes them, but their payload is a managed object graph it
//! hands back as opaque bytes, so there is no field layout to write from
//! and such a node fails with `error.UnsupportedManagedReference`.

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
    try writeObjectPreserving(w, root, root_value, tail, null);
}

/// Like `writeObject`, but alignment padding bytes are copied from
/// `original` instead of zero-filled. Unity's writer leaves whatever was
/// in memory in a struct's padding, so a byte-exact rewrite against an
/// original object must reproduce those bytes: verify uses this so a
/// correct decode does not fail on meaningless nonzero padding.
pub fn writeObjectPreserving(w: *streams.Writer, root: *const typetree.Node, root_value: value.Value, tail: []const u8, original: ?[]const u8) Error!void {
    try writeNode(w, root, root_value, false, original);
    try w.writeBytes(tail);
}

fn writeNode(
    w: *streams.Writer,
    node: *const typetree.Node,
    v: value.Value,
    suppress_align: bool,
    original: ?[]const u8,
) Error!void {
    const type_name = node.type_name;

    if (std.mem.eql(u8, type_name, "string")) {
        const s = switch (v) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        try w.writeInt(i32, @intCast(s.len));
        try w.writeBytes(s);
        // Strings are always 4-aligned in the wire format, inside arrays
        // too (each element is padded, see the reader); the meta flag is
        // irrelevant.
        try padAlign(w, original);
        return;
    }
    if (std.mem.eql(u8, type_name, "TypelessData")) {
        const b = try asBytes(w.allocator, v);
        try w.writeInt(i32, @intCast(b.len));
        try w.writeBytes(b);
        if (!suppress_align and object_reader.nodeAligned(node)) try padAlign(w, original);
        return;
    }
    if (object_reader.primitiveKind(type_name)) |prim| {
        if (node.children.len != 0) return error.TypeMismatch;
        try writePrimitive(w, prim, v, original);
        if (!suppress_align and object_reader.nodeAligned(node)) try padAlign(w, original);
        return;
    }
    if (std.mem.eql(u8, type_name, "pair")) {
        if (node.children.len != 2) return error.Corrupt;
        const items = switch (v) {
            .array => |a| a,
            else => return error.TypeMismatch,
        };
        if (items.len != 2) return error.TypeMismatch;
        try writeNode(w, &node.children[0], items[0], false, original);
        try writeNode(w, &node.children[1], items[1], false, original);
        if (!suppress_align and object_reader.nodeAligned(node)) try padAlign(w, original);
        return;
    }
    if (object_reader.isPPtrType(type_name)) {
        try writePPtr(w, node, v, suppress_align, original);
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
                try writeNode(w, child, child_value, false, original);
            }
            if (!suppress_align and object_reader.nodeAligned(node)) try padAlign(w, original);
            return;
        }
        // Opaque fixed-size leaf: raw bytes.
        if (node.byte_size < 0) return error.TypeMismatch;
        const b = try asBytes(w.allocator, v);
        if (b.len != @as(usize, @intCast(node.byte_size))) return error.TypeMismatch;
        try w.writeBytes(b);
        if (!suppress_align and object_reader.nodeAligned(node)) try padAlign(w, original);
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
        const aligns = object_reader.nodeAligned(node) or object_reader.nodeAligned(array_node) or object_reader.nodeAligned(element_node);
        if (!suppress_align and aligns) try padAlign(w, original);
        return;
    }

    const items = switch (v) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };
    try w.writeInt(i32, @intCast(items.len));
    if (element_node.children.len == 0 and element_prim != null) {
        for (items) |item| {
            try writePrimitive(w, element_prim.?, item, original);
        }
    } else {
        const suppress_element = object_reader.nodeAligned(element_node);
        for (items) |item| {
            try writeNode(w, element_node, item, suppress_element, original);
        }
    }

    const aligns = object_reader.nodeAligned(node) or object_reader.nodeAligned(array_node) or object_reader.nodeAligned(element_node);
    if (!suppress_align and aligns) try padAlign(w, original);
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

fn writePrimitive(w: *streams.Writer, prim: object_reader.Primitive, v: value.Value, original: ?[]const u8) Error!void {
    switch (prim) {
        .bool => {
            const b = switch (v) {
                .bool => |b| b,
                else => return error.TypeMismatch,
            };
            if (b) {
                // Preserve the original byte when rewriting an existing
                // object: Unity stores `true` as any nonzero byte, and a
                // normalized 0x01 would differ from a 0x02 original. Only
                // verify passes `original`; edits write 0x01.
                if (original) |o| {
                    const pos = w.getWritten().len;
                    if (pos < o.len and o[pos] != 0) {
                        try w.writeByte(o[pos]);
                        return;
                    }
                }
            }
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
        .f32 => try w.writeFloat(f32, try narrowFloat(try asFloat(v))),
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

/// Narrows an edited float to the `float` width its type tree node
/// declares, the way `narrowInt` narrows an integer. A magnitude past f32's
/// range (`unityz edit ... m_Radius 1e300`) is a value the field cannot
/// hold, but `@floatCast` turns it into +/-Inf instead of failing, so the
/// edit landed as a corrupt float in the rewritten asset rather than as the
/// operating error the integer path already reports. Ordinary precision
/// loss is expected and kept, and a non-finite input passes through so a
/// field that already held one still round-trips.
fn narrowFloat(v: f64) Error!f32 {
    const narrowed: f32 = @floatCast(v);
    if (std.math.isFinite(v) and !std.math.isFinite(narrowed)) return error.TypeMismatch;
    return narrowed;
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

fn writePPtr(w: *streams.Writer, node: *const typetree.Node, v: value.Value, suppress_align: bool, original: ?[]const u8) Error!void {
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
            try writePrimitive(w, prim, .{ .int = p.file_id }, original);
            file_written = true;
        } else if (object_reader.isPathIdName(child.name)) {
            const prim = object_reader.primitiveKind(child.type_name) orelse return error.Corrupt;
            try writePrimitive(w, prim, .{ .int = p.path_id }, original);
            path_written = true;
        } else {
            // Extra fields: take from the object form when present.
            const extra = switch (v) {
                .obj => |fields| findField(fields, child.name),
                else => null,
            } orelse return error.MissingField;
            try writeNode(w, child, extra, false, original);
        }
    }
    if (!file_written or !path_written) return error.Corrupt;
    if (!suppress_align and object_reader.nodeAligned(node)) try padAlign(w, original);
}

/// Aligns the writer to 4 bytes. When `original` is present, the padding
/// bytes are copied from it at the matching offset (Unity leaves struct
/// memory in padding, and a byte-exact rewrite must reproduce it);
/// otherwise the pad is zero-filled.
fn padAlign(w: *streams.Writer, original: ?[]const u8) !void {
    const pos = w.getWritten().len;
    const pad = (4 - (pos % 4)) % 4;
    if (pad == 0) return;
    if (original) |o| {
        if (pos + pad <= o.len) {
            try w.writeBytes(o[pos .. pos + pad]);
            return;
        }
    }
    const zeros = [_]u8{0} ** 4;
    try w.writeBytes(zeros[0..pad]);
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
    try wire.alignTo4();
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

test "write rejects type-confused, out-of-range and unwritable nodes" {
    // `edit`/`create` feed user JSON straight into this writer, so every
    // mismatch between the value and the node's declared type has to be an
    // error the CLI reports. Silently narrowing or coercing here writes a
    // wrong byte into someone's asset. Each case pairs the largest value
    // the field does hold with the first one it does not, so the check is
    // pinned at the boundary and not just somewhere past it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const run = struct {
        fn go(al: std.mem.Allocator, node: *const typetree.Node, v: value.Value) Error![]const u8 {
            var w: streams.Writer = .init(al);
            try writeObject(&w, node, v, &.{});
            return w.getWritten();
        }
    }.go;

    // Integer narrowing: the declared width decides, not the JSON literal.
    const i8_node = try allocNode(a, "SInt8", "v", 0, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7f}, try run(a, i8_node, .{ .int = 127 }));
    try std.testing.expectError(error.TypeMismatch, run(a, i8_node, .{ .int = 128 }));
    const u8_node = try allocNode(a, "UInt8", "v", 0, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{0xff}, try run(a, u8_node, .{ .int = 255 }));
    try std.testing.expectError(error.TypeMismatch, run(a, u8_node, .{ .int = 256 }));
    try std.testing.expectError(error.TypeMismatch, run(a, u8_node, .{ .int = -1 }));
    const i32_node = try allocNode(a, "int", "v", 0, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff, 0x7f }, try run(a, i32_node, .{ .int = 2147483647 }));
    // the documented `unityz edit ... m_Width 99999999999` case
    try std.testing.expectError(error.TypeMismatch, run(a, i32_node, .{ .int = 99999999999 }));
    // An unsigned field takes the full u64 range but never a negative.
    const u64_node = try allocNode(a, "UInt64", "v", 0, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{0xff} ** 8, try run(a, u64_node, .{ .uint = std.math.maxInt(u64) }));
    try std.testing.expectError(error.TypeMismatch, run(a, u64_node, .{ .int = -1 }));

    // Float narrowing: a `float` node holds f32, so a magnitude past its
    // range is a value the field cannot carry and must be reported, not
    // turned into an infinity. Ordinary precision loss is kept, and a
    // non-finite input passes through so a field that already held one
    // still round-trips.
    const f32_node = try allocNode(a, "float", "v", 0, &.{});
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xff, 0xff, 0x7f, 0x7f },
        try run(a, f32_node, .{ .float = std.math.floatMax(f32) }),
    );
    try std.testing.expectError(error.TypeMismatch, run(a, f32_node, .{ .float = 1e300 }));
    try std.testing.expectError(error.TypeMismatch, run(a, f32_node, .{ .float = -1e300 }));
    // 0.1 is not representable in f32; rounding to the nearest f32 is the
    // expected outcome, not an error.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcd, 0xcc, 0xcc, 0x3d }, try run(a, f32_node, .{ .float = 0.1 }));
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0x00, 0x80, 0x7f },
        try run(a, f32_node, .{ .float = std.math.inf(f64) }),
    );
    // An f64 node takes the same magnitude unchanged - the rejection above
    // is the declared width, not the value.
    try std.testing.expectEqualSlices(
        u8,
        &@as([8]u8, @bitCast(@as(u64, @bitCast(@as(f64, 1e300))))),
        try run(a, try allocNode(a, "double", "v", 0, &.{}), .{ .float = 1e300 }),
    );

    // Wrong value kind for the node's type.
    try std.testing.expectError(error.TypeMismatch, run(a, try allocNode(a, "string", "v", 0, &.{}), .{ .int = 5 }));
    try std.testing.expectError(error.TypeMismatch, run(a, try allocNode(a, "bool", "v", 0, &.{}), .{ .int = 1 }));
    try std.testing.expectError(error.TypeMismatch, run(a, try allocNode(a, "float", "v", 0, &.{}), .{ .string = "1.5" }));
    // ... but int/uint literals do widen into a float field.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x80, 0x3f }, try run(a, try allocNode(a, "float", "v", 0, &.{}), .{ .int = 1 }));

    // A record needs an object, and a PPtr needs both halves.
    const record = try allocNode(a, "SomeClass", "Base", 0, &.{
        try allocNode(a, "int", "m_Value", 0, &.{}),
    });
    try std.testing.expectError(error.TypeMismatch, run(a, record, .{ .int = 1 }));
    const pptr = try allocNode(a, "PPtr<GameObject>", "m_Ref", 0, &.{
        try allocNode(a, "int", "m_FileID", 0, &.{}),
        try allocNode(a, "SInt64", "m_PathID", 0, &.{}),
    });
    try std.testing.expectError(error.TypeMismatch, run(a, pptr, .{ .obj = &[_]value.Field{
        .{ .name = "m_FileID", .value = .{ .int = 0 } },
    } }));

    // A base64 payload that does not decode is a bad patch, not raw bytes.
    const typeless = try allocNode(a, "TypelessData", "m_Blob", 0, &.{});
    try std.testing.expectError(error.TypeMismatch, run(a, typeless, .{ .string = "abc" }));
    try std.testing.expectError(error.TypeMismatch, run(a, typeless, .{ .string = "!!!!" }));

    // An opaque fixed-size leaf only takes exactly its declared width.
    const hash = try allocNode(a, "Hash128", "m_Hash", 0, &.{});
    hash.byte_size = 16;
    try std.testing.expectEqualSlices(u8, "0123456789abcdef", try run(a, hash, .{ .bytes = "0123456789abcdef" }));
    try std.testing.expectError(error.TypeMismatch, run(a, hash, .{ .bytes = "short" }));

    // A byte array carried as a value array narrows each element.
    const bytes_array = try allocNode(a, "vector", "m_Bytes", 0, &.{
        try allocNode(a, "Array", "Array", 0, &.{
            try allocNode(a, "int", "size", 0, &.{}),
            try allocNode(a, "UInt8", "data", 0, &.{}),
        }),
    });
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x02, 0x00, 0x00, 0x00, 0x01, 0xff },
        try run(a, bytes_array, .{ .array = &[_]value.Value{ .{ .int = 1 }, .{ .int = 255 } } }),
    );
    try std.testing.expectError(error.TypeMismatch, run(a, bytes_array, .{ .array = &[_]value.Value{.{ .int = 256 }} }));
    try std.testing.expectError(error.TypeMismatch, run(a, bytes_array, .{ .array = &[_]value.Value{.{ .string = "x" }} }));

    // Unnamed children cannot be reconstructed from a value tree, and
    // managed-reference registries have no field layout to write from -
    // both are documented at the top of this file as hard rejections.
    const unnamed = try allocNode(a, "SomeClass", "Base", 0, &.{
        try allocNode(a, "int", "", 0, &.{}),
    });
    try std.testing.expectError(error.UnnamedChild, run(a, unnamed, .{ .obj = &.{} }));
    for ([_][]const u8{ "ReferencedObject", "ManagedReferencesRegistry" }) |t| {
        const node = try allocNode(a, t, "m_Refs", 0, &.{});
        try std.testing.expectError(error.UnsupportedManagedReference, run(a, node, .{ .obj = &.{} }));
    }
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

test "writeObjectPreserving copies nonzero pads and bool bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Record: bool (aligned cell) then UInt8 (aligned cell) then int.
    const root = try allocNode(a, "SomeClass", "Base", 0, &.{
        try allocNode(a, "bool", "flag", object_reader.align_flag, &.{}),
        try allocNode(a, "UInt8", "small", object_reader.align_flag, &.{}),
        try allocNode(a, "int", "count", 0, &.{}),
    });

    // A wire Unity might write: true stored as 0x02, garbage in the pads.
    const original = [_]u8{ 0x02, 0x5a, 0x00, 0x00, 0x07, 0x2b, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00 };

    var out: streams.Writer = .init(a);
    defer out.deinit();
    try writeObjectPreserving(&out, root, .{ .obj = &[_]value.Field{
        .{ .name = "flag", .value = .{ .bool = true } },
        .{ .name = "small", .value = .{ .int = 7 } },
        .{ .name = "count", .value = .{ .int = 42 } },
    } }, &.{}, &original);
    try std.testing.expectEqualSlices(u8, &original, out.getWritten());

    // Without the original the pads zero and the bool normalizes to 1.
    var plain: streams.Writer = .init(a);
    defer plain.deinit();
    try writeObject(&plain, root, .{ .obj = &[_]value.Field{
        .{ .name = "flag", .value = .{ .bool = true } },
        .{ .name = "small", .value = .{ .int = 7 } },
        .{ .name = "count", .value = .{ .int = 42 } },
    } }, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00 }, plain.getWritten());
}
