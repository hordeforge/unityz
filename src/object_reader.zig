//! TypeTree-driven object reader.
//!
//! Reads an object's serialized bytes by walking its TypeTree, producing a
//! [`value.Value`] tree. The wire semantics follow the documented Unity
//! serialization rules (cross-checked against the compiled-schema model of
//! an independent implementation):
//!
//! - Nodes whose `meta_flags` have bit 0x4000 are 4-aligned: after reading
//!   such a node the reader advances to the next 4-byte boundary.
//! - `string` and `TypelessData` are i32 length + bytes. Strings are always
//!   4-aligned after their payload (Unity pads them unconditionally); the
//!   flag-based rule does not apply to them.
//! - Arrays of 1-byte integers (char / UInt8 / SInt8) coalesce into raw
//!   bytes, matching UnityPy's byte-array reads.
//! - Arrays (`Array` type, or a node with a single `Array` child) carry an
//!   i32 count then that many elements; scalar elements are read as one
//!   contiguous run; the whole array aligns as a unit (elements never align
//!   individually, their alignment is promoted to the array).
//! - `map` elements are pairs; `PPtr<T>` is a file ID + path ID pair.
//! - Unknown leaf types with a fixed `byte_size` are kept as raw bytes.
//! - Managed-reference registries (`ReferencedObject`,
//!   `ManagedReferencesRegistry`) decode through their type trees; the raw
//!   managed object graph inside each `TypelessData` payload is exposed as
//!   bytes (its format is not yet parsed).
//!
//! All values allocate from the caller's allocator (an arena is the
//! intended usage); string/bytes values borrow from the source buffer.

const std = @import("std");
const streams = @import("streams.zig");
const typetree = @import("typetree.zig");
const value = @import("value.zig");

pub const Error = error{
    OutOfBounds,
    Corrupt,
    UnsupportedManagedReference,
    OutOfMemory,
};

/// Node alignment flag in `meta_flags`.
pub const align_flag: i32 = 0x4000;

pub const Primitive = enum {
    bool,
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    f32,
    f64,
};

pub fn primitiveKind(type_name: []const u8) ?Primitive {
    const eql = std.mem.eql;
    if (eql(u8, type_name, "bool")) return .bool;
    if (eql(u8, type_name, "SInt8")) return .i8;
    if (eql(u8, type_name, "UInt8") or eql(u8, type_name, "char")) return .u8;
    if (eql(u8, type_name, "SInt16") or eql(u8, type_name, "short")) return .i16;
    if (eql(u8, type_name, "UInt16") or eql(u8, type_name, "unsigned short") or eql(u8, type_name, "ushort")) return .u16;
    if (eql(u8, type_name, "SInt32") or eql(u8, type_name, "int") or eql(u8, type_name, "EntityId")) return .i32;
    if (eql(u8, type_name, "UInt32") or eql(u8, type_name, "unsigned int") or eql(u8, type_name, "uint") or eql(u8, type_name, "Type*")) return .u32;
    if (eql(u8, type_name, "SInt64") or eql(u8, type_name, "long long")) return .i64;
    if (eql(u8, type_name, "UInt64") or eql(u8, type_name, "unsigned long long") or eql(u8, type_name, "FileSize")) return .u64;
    if (eql(u8, type_name, "float")) return .f32;
    if (eql(u8, type_name, "double")) return .f64;
    return null;
}

fn isPPtrType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "PPtr") or std.mem.startsWith(u8, type_name, "PPtr<");
}

pub fn isFileIdName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "fileID") or std.ascii.eqlIgnoreCase(name, "m_FileID");
}

pub fn isPathIdName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "pathID") or std.ascii.eqlIgnoreCase(name, "m_PathID");
}

fn nodeAligned(node: *const typetree.Node) bool {
    return (node.meta_flags & align_flag) != 0;
}

/// Reads one object: the root tree node over `r`, which must be positioned
/// at the object's first byte.
pub fn readObject(allocator: std.mem.Allocator, r: *streams.Reader, root: *const typetree.Node) Error!value.Value {
    return readNode(allocator, r, root, false);
}

fn readNode(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    node: *const typetree.Node,
    suppress_align: bool,
) Error!value.Value {
    const result = try readNodeInner(allocator, r, node, suppress_align);
    return result;
}

fn readNodeInner(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    node: *const typetree.Node,
    suppress_align: bool,
) Error!value.Value {
    const type_name = node.type_name;

    if (std.mem.eql(u8, type_name, "string")) {
        const s = try readLengthBytes(r, 64 * 1024 * 1024);
        // Strings are always 4-aligned in the wire format; the meta flag is
        // irrelevant (Unity's writer pads unconditionally). Array runs
        // suppress per-element alignment and promote it to the run end,
        // which yields identical padding.
        if (!suppress_align) try r.alignTo4();
        return .{ .string = s };
    }
    if (std.mem.eql(u8, type_name, "TypelessData")) {
        const b = try readLengthBytes(r, std.math.maxInt(u32));
        if (!suppress_align and nodeAligned(node)) try r.alignTo4();
        return .{ .bytes = b };
    }
    if (primitiveKind(type_name)) |prim| {
        if (node.children.len != 0) return error.Corrupt;
        const v = try readPrimitive(r, prim);
        if (!suppress_align and nodeAligned(node)) try r.alignTo4();
        return v;
    }
    if (std.mem.eql(u8, type_name, "pair")) {
        if (node.children.len != 2) return error.Corrupt;
        const items = allocator.alloc(value.Value, 2) catch return error.OutOfMemory;
        items[0] = try readNode(allocator, r, &node.children[0], false);
        items[1] = try readNode(allocator, r, &node.children[1], false);
        if (!suppress_align and nodeAligned(node)) try r.alignTo4();
        return .{ .array = items };
    }
    if (isPPtrType(type_name)) {
        return readPPtr(allocator, r, node, suppress_align);
    }

    // Arrays: either the node itself is "Array", or it has exactly one
    // "Array" child (the map layout).
    const array_node = collectionArray(node) orelse {
        if (std.mem.eql(u8, type_name, "map")) return error.Corrupt;
        if (node.children.len != 0) {
            // Ordinary record: read children in order into named fields.
            var named: usize = 0;
            for (node.children) |*child| {
                if (child.name.len != 0) named += 1;
            }
            const fields = allocator.alloc(value.Field, named) catch return error.OutOfMemory;
            var count: usize = 0;
            for (node.children) |*child| {
                const v = try readNode(allocator, r, child, false);
                if (child.name.len == 0) continue;
                fields[count] = .{ .name = child.name, .value = v };
                count += 1;
            }
            std.debug.assert(count == named);
            if (!suppress_align and nodeAligned(node)) try r.alignTo4();
            return .{ .obj = fields };
        }
        // Unknown leaf with a fixed size: keep raw bytes.
        if (node.byte_size < 0) return error.Corrupt;
        const b = r.readSlice(@intCast(node.byte_size)) catch return error.OutOfBounds;
        if (!suppress_align and nodeAligned(node)) try r.alignTo4();
        return .{ .bytes = b };
    };

    // Collection (sequence or map).
    if (array_node.children.len != 2) return error.Corrupt;
    const size_node = &array_node.children[0];
    if (size_node.children.len != 0 or primitiveKind(size_node.type_name) != .i32) return error.Corrupt;
    const element_node = &array_node.children[1];

    const count = try r.readInt(i32);
    if (count < 0) return error.Corrupt;
    const n: usize = @intCast(count);
    // each element needs at least one wire byte; bounding the count by the
    // remaining data stops corrupt files from triggering huge allocations
    // or effectively-infinite loops
    if (n > r.remaining()) return error.Corrupt;
    const element_is_primitive = element_node.children.len == 0 and primitiveKind(element_node.type_name) != null;

    // Arrays of 1-byte integers (char / UInt8 / SInt8) coalesce into a raw
    // byte string, matching UnityPy's read_u_byte_array — far more compact
    // than one value per byte (e.g. a mesh index buffer).
    if (element_is_primitive and isByteKind(primitiveKind(element_node.type_name).?)) {
        const raw = try r.readSlice(n);
        const aligns = nodeAligned(node) or nodeAligned(array_node) or nodeAligned(element_node);
        if (!suppress_align and aligns) try r.alignTo4();
        return .{ .bytes = raw };
    }

    var items: []value.Value = undefined;
    if (n != 0) {
        items = allocator.alloc(value.Value, n) catch return error.OutOfMemory;
        if (element_is_primitive) {
            // Contiguous run of scalars.
            for (items) |*item| {
                item.* = try readPrimitive(r, primitiveKind(element_node.type_name).?);
            }
        } else {
            const suppress_element = nodeAligned(element_node);
            for (items) |*item| {
                item.* = try readNode(allocator, r, element_node, suppress_element);
            }
        }
    } else {
        items = &.{};
    }

    // The collection aligns as a unit; a single element's own alignment is
    // promoted here instead.
    const aligns = nodeAligned(node) or nodeAligned(array_node) or nodeAligned(element_node);
    if (!suppress_align and aligns) try r.alignTo4();

    return .{ .array = items };
}

/// The node's "Array" layout:
/// - the node itself when it is `Array`-typed;
/// - the sole `Array` child for `map` (and legacy vector-like) wrappers;
/// - null otherwise — a record may contain `Array`-typed fields, which are
///   handled when the recursion reaches them.
fn collectionArray(node: *const typetree.Node) ?*const typetree.Node {
    if (std.mem.eql(u8, node.type_name, "Array")) return node;
    if (node.children.len != 1) return null;
    const only = &node.children[0];
    if (std.mem.eql(u8, only.type_name, "Array")) return only;
    return null;
}

fn readLengthBytes(r: *streams.Reader, max: usize) Error![]const u8 {
    const len = try r.readInt(i32);
    if (len < 0 or @as(usize, @intCast(len)) > max) return error.Corrupt;
    return r.readSlice(@intCast(len)) catch return error.OutOfBounds;
}

fn readPrimitive(r: *streams.Reader, prim: Primitive) Error!value.Value {
    return switch (prim) {
        .bool => .{ .bool = try r.readByte() != 0 },
        .i8 => .{ .int = try r.readInt(i8) },
        .u8 => .{ .uint = try r.readInt(u8) },
        .i16 => .{ .int = try r.readInt(i16) },
        .u16 => .{ .uint = try r.readInt(u16) },
        .i32 => .{ .int = try r.readInt(i32) },
        .u32 => .{ .uint = try r.readInt(u32) },
        .i64 => .{ .int = try r.readInt(i64) },
        .u64 => .{ .uint = try r.readInt(u64) },
        .f32 => .{ .float = try r.readFloat(f32) },
        .f64 => .{ .float = try r.readFloat(f64) },
    };
}

fn readPPtr(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    node: *const typetree.Node,
    suppress_align: bool,
) Error!value.Value {
    if (node.children.len == 0) return error.Corrupt;

    var file_id: ?i32 = null;
    var path_id: ?i64 = null;
    var extras: std.ArrayList(value.Field) = .empty;

    for (node.children) |*child| {
        if (isFileIdName(child.name)) {
            if (file_id != null) return error.Corrupt;
            const prim = primitiveKind(child.type_name) orelse return error.Corrupt;
            if (!isInteger(prim) or widthOf(prim) > 4) return error.Corrupt;
            const v = try readPrimitive(r, prim);
            file_id = @intCast(v.asInt() orelse return error.Corrupt);
            continue;
        }
        if (isPathIdName(child.name)) {
            if (path_id != null) return error.Corrupt;
            const prim = primitiveKind(child.type_name) orelse return error.Corrupt;
            if (!isInteger(prim)) return error.Corrupt;
            const v = try readPrimitive(r, prim);
            path_id = v.asInt() orelse return error.Corrupt;
            continue;
        }
        // Extra fields beyond file/path (rare): read and keep.
        const v = try readNode(allocator, r, child, false);
        if (child.name.len != 0) {
            extras.append(allocator, .{ .name = child.name, .value = v }) catch return error.OutOfMemory;
        }
    }

    const pptr = value.PPtr{
        .file_id = file_id orelse return error.Corrupt,
        .path_id = path_id orelse return error.Corrupt,
    };
    if (!suppress_align and nodeAligned(node)) try r.alignTo4();

    // A PPtr with extra fields is represented as an object so nothing is
    // lost; the common case is a plain reference.
    if (extras.items.len == 0) return .{ .pptr = pptr };
    const fields = allocator.alloc(value.Field, extras.items.len + 2) catch return error.OutOfMemory;
    fields[0] = .{ .name = "m_FileID", .value = .{ .int = pptr.file_id } };
    fields[1] = .{ .name = "m_PathID", .value = .{ .int = pptr.path_id } };
    @memcpy(fields[2..], extras.items);
    return .{ .obj = fields };
}

pub fn isInteger(self: Primitive) bool {
    return switch (self) {
        .bool, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64 => true,
        .f32, .f64 => false,
    };
}

fn widthOf(self: Primitive) usize {
    return switch (self) {
        .bool, .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64 => 8,
    };
}

/// Whether the primitive is a 1-byte integer type; arrays of these are
/// represented as raw bytes.
pub fn isByteKind(self: Primitive) bool {
    return self == .u8 or self == .i8;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

fn fieldOf(v: value.Value, name: []const u8) ?value.Value {
    switch (v) {
        .obj => |fields| {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return f.value;
            }
        },
        else => {},
    }
    return null;
}

test "read a rich record: primitives, string, pptr, struct, arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "MonoBehaviour", "Base<MonoBehaviour>", 0, &[_]*const typetree.Node{
        try allocNode(a, "bool", "m_Enabled", 0, &[_]*const typetree.Node{}),
        try allocNode(a, "string", "m_Name", align_flag, &[_]*const typetree.Node{}),
        try allocNode(a, "PPtr<MonoBehaviour>", "m_Script", 0, &[_]*const typetree.Node{
            try allocNode(a, "int", "m_FileID", 0, &[_]*const typetree.Node{}),
            try allocNode(a, "SInt64", "m_PathID", 0, &[_]*const typetree.Node{}),
        }),
        try allocNode(a, "int", "m_Count", 0, &[_]*const typetree.Node{}),
        try allocNode(a, "Vector3f", "m_Vector3", 0, &[_]*const typetree.Node{
            try allocNode(a, "float", "x", 0, &[_]*const typetree.Node{}),
            try allocNode(a, "float", "y", 0, &[_]*const typetree.Node{}),
            try allocNode(a, "float", "z", 0, &[_]*const typetree.Node{}),
        }),
        try allocNode(a, "Array", "m_Values", align_flag, &[_]*const typetree.Node{
            try allocNode(a, "int", "size", 0, &[_]*const typetree.Node{}),
            try allocNode(a, "int", "Array", 0, &[_]*const typetree.Node{}),
        }),
        try allocNode(a, "Array", "m_Names", align_flag, &[_]*const typetree.Node{
            try allocNode(a, "int", "size", 0, &[_]*const typetree.Node{}),
            try allocNode(a, "string", "Array", align_flag, &[_]*const typetree.Node{}),
        }),
    });

    var w = streams.Writer.init(a);
    defer w.deinit();
    try w.writeByte(1); // m_Enabled
    try w.writeInt(i32, 7); // m_Name: len + "Player\0"
    try w.writeBytes("Player\x00");
    try w.alignTo4(); // string is aligned
    try w.writeInt(i32, 0); // m_Script file
    try w.writeInt(i64, 42); // m_Script path
    try w.writeInt(i32, 3); // m_Count
    try w.writeFloat(f32, 1.0); // m_Vector3
    try w.writeFloat(f32, 2.0);
    try w.writeFloat(f32, 3.0);
    try w.writeInt(i32, 3); // m_Values count
    try w.writeInt(i32, 10);
    try w.writeInt(i32, 20);
    try w.writeInt(i32, 30);
    try w.writeInt(i32, 2); // m_Names count
    try w.writeInt(i32, 1);
    try w.writeBytes("a");
    try w.writeInt(i32, 2);
    try w.writeBytes("bb");
    try w.alignTo4(); // the string array aligns as a unit

    var r = streams.Reader.init(w.getWritten());
    const v = try readObject(a, &r, root);

    try std.testing.expectEqual(@as(usize, 7), v.childCount());
    try std.testing.expect((fieldOf(v, "m_Enabled")).?.bool);
    try std.testing.expectEqualStrings("Player\x00", (fieldOf(v, "m_Name")).?.string);
    const script = (fieldOf(v, "m_Script")).?.pptr;
    try std.testing.expectEqual(@as(i32, 0), script.file_id);
    try std.testing.expectEqual(@as(i64, 42), script.path_id);
    try std.testing.expectEqual(@as(i64, 3), (fieldOf(v, "m_Count")).?.asInt().?);
    const vec = (fieldOf(v, "m_Vector3")).?;
    try std.testing.expectEqual(@as(f64, 1.0), (fieldOf(vec, "x")).?.float);
    try std.testing.expectEqual(@as(f64, 3.0), (fieldOf(vec, "z")).?.float);
    const values = (fieldOf(v, "m_Values")).?.array;
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqual(@as(i64, 30), values[2].asInt().?);
    const names = (fieldOf(v, "m_Names")).?.array;
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("bb", names[1].string);
    try std.testing.expect(r.eof());
}

test "strings align even without the 0x4000 meta flag" {
    // Unity pads every string to a 4-byte boundary regardless of its
    // meta flag (read_aligned_string); a string node without 0x4000
    // must still leave the reader aligned. Regression for real
    // AssetBundle/Shader/Mesh objects whose string nodes carry no flag.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "AssetBundle", "Base", 0, &[_]*const typetree.Node{
        try allocNode(a, "string", "m_Name", 0x88001, &[_]*const typetree.Node{
            try allocNode(a, "Array", "Array", 0x84001, &[_]*const typetree.Node{
                try allocNode(a, "int", "size", 0x80001, &[_]*const typetree.Node{}),
                try allocNode(a, "char", "data", 0x80001, &[_]*const typetree.Node{}),
            }),
        }),
        try allocNode(a, "int", "m_Count", 0, &[_]*const typetree.Node{}),
    });

    var w = streams.Writer.init(a);
    defer w.deinit();
    // m_Name: 19 bytes, no align flag on the node — Unity still pads to 4
    // (the wire's trailing NUL lands in the padding).
    try w.writeInt(i32, 19);
    try w.writeBytes("entityprobe.unity3d");
    try w.alignTo4();
    try w.writeInt(i32, 7);

    var r = streams.Reader.init(w.getWritten());
    const v = try readObject(a, &r, root);
    try std.testing.expectEqualStrings("entityprobe.unity3d", (fieldOf(v, "m_Name")).?.string);
    try std.testing.expectEqual(@as(i64, 7), (fieldOf(v, "m_Count")).?.asInt().?);
    try std.testing.expect(r.eof());
}

test "read map and typeless data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "SomeClass", "Base", 0, &[_]*const typetree.Node{
        try allocNode(a, "map", "m_Map", align_flag, &[_]*const typetree.Node{
            try allocNode(a, "Array", "Array", 0, &[_]*const typetree.Node{
                try allocNode(a, "int", "size", 0, &[_]*const typetree.Node{}),
                try allocNode(a, "pair", "data", 0, &[_]*const typetree.Node{
                    try allocNode(a, "string", "first", align_flag, &[_]*const typetree.Node{}),
                    try allocNode(a, "int", "second", 0, &[_]*const typetree.Node{}),
                }),
            }),
        }),
        try allocNode(a, "TypelessData", "m_Blob", align_flag, &[_]*const typetree.Node{}),
        hash_node: {
            const node = try allocNode(a, "Hash128", "m_Hash", 0, &[_]*const typetree.Node{});
            node.byte_size = 16; // opaque fixed 16 bytes
            break :hash_node node;
        },
    });

    var w = streams.Writer.init(a);
    defer w.deinit();
    try w.writeInt(i32, 2); // map count
    try w.writeInt(i32, 2); // key "k1"
    try w.writeBytes("k1");
    try w.alignTo4(); // aligned string inside the pair
    try w.writeInt(i32, 5); // value
    try w.writeInt(i32, 2); // key "k2"
    try w.writeBytes("k2");
    try w.alignTo4();
    try w.writeInt(i32, 7); // value
    try w.alignTo4(); // map aligns as a unit
    try w.writeInt(i32, 4); // typeless length
    try w.writeBytes("blob");
    try w.alignTo4(); // typeless aligns
    try w.writeBytes("0123456789abcdef"); // opaque 16 bytes

    var r = streams.Reader.init(w.getWritten());
    const v = try readObject(a, &r, root);

    const map = (fieldOf(v, "m_Map")).?.array;
    try std.testing.expectEqual(@as(usize, 2), map.len);
    try std.testing.expectEqualStrings("k1", map[0].array[0].string);
    try std.testing.expectEqual(@as(i64, 5), map[0].array[1].asInt().?);
    try std.testing.expectEqualStrings("k2", map[1].array[0].string);
    try std.testing.expectEqual(@as(i64, 7), map[1].array[1].asInt().?);
    try std.testing.expectEqualStrings("blob", (fieldOf(v, "m_Blob")).?.bytes);
    try std.testing.expectEqualStrings("0123456789abcdef", (fieldOf(v, "m_Hash")).?.bytes);
    try std.testing.expect(r.eof());
}

test "read a managed reference registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Modern MonoBehaviour type tree carries the serialized-reference
    // registry as a regular struct: a version int and a vector of
    // ReferencedObject records whose payload is raw TypelessData bytes.
    const root = try allocNode(a, "MonoBehaviour", "Base", 0, &[_]*const typetree.Node{
        try allocNode(a, "ManagedReferencesRegistry", "m_ManagedReferencesRegistry", 0, &[_]*const typetree.Node{
            try allocNode(a, "int", "m_Version", 0, &[_]*const typetree.Node{}),
            try allocNode(a, "Array", "m_RefIds", align_flag, &[_]*const typetree.Node{
                try allocNode(a, "int", "size", 0, &[_]*const typetree.Node{}),
                try allocNode(a, "ReferencedObject", "Array", align_flag, &[_]*const typetree.Node{
                    try allocNode(a, "int", "m_ClassId", 0, &[_]*const typetree.Node{}),
                    try allocNode(a, "string", "m_ClassName", align_flag, &[_]*const typetree.Node{}),
                    try allocNode(a, "TypelessData", "m_Object", align_flag, &[_]*const typetree.Node{}),
                }),
            }),
        }),
    });

    var w = streams.Writer.init(a);
    defer w.deinit();
    try w.writeInt(i32, 1); // m_Version
    try w.writeInt(i32, 2); // m_RefIds count
    // reference 0
    try w.writeInt(i32, 7); // m_ClassId
    try w.writeInt(i32, 4); // m_ClassName "Foo\x00"
    try w.writeBytes("Foo\x00");
    try w.alignTo4();
    try w.writeInt(i32, 3); // m_Object
    try w.writeBytes("abc");
    try w.alignTo4();
    // reference 1
    try w.writeInt(i32, 9);
    try w.writeInt(i32, 4); // "Bar\x00"
    try w.writeBytes("Bar\x00");
    try w.alignTo4();
    try w.writeInt(i32, 0); // empty m_Object

    var r = streams.Reader.init(w.getWritten());
    const v = try readObject(a, &r, root);

    const reg = (fieldOf(v, "m_ManagedReferencesRegistry")).?;
    try std.testing.expectEqual(@as(i64, 1), (fieldOf(reg, "m_Version")).?.asInt().?);
    const refs = (fieldOf(reg, "m_RefIds")).?.array;
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqual(@as(i64, 7), (fieldOf(refs[0], "m_ClassId")).?.asInt().?);
    try std.testing.expectEqualStrings("Foo\x00", (fieldOf(refs[0], "m_ClassName")).?.string);
    try std.testing.expectEqualStrings("abc", (fieldOf(refs[0], "m_Object")).?.bytes);
    try std.testing.expectEqualStrings("Bar\x00", (fieldOf(refs[1], "m_ClassName")).?.string);
    try std.testing.expect(r.eof());
}

test "read rejects truncated data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try allocNode(a, "SomeClass", "Base", 0, &[_]*const typetree.Node{
        try allocNode(a, "int", "m_Value", 0, &[_]*const typetree.Node{}),
    });
    var w = streams.Writer.init(a);
    defer w.deinit();
    try w.writeBytes("ab"); // an int needs 4 bytes; only 2 present
    var r = streams.Reader.init(w.getWritten());
    try std.testing.expectError(error.OutOfBounds, readObject(a, &r, root));
}
