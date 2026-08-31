//! TypeTree parsing — the class layout metadata Unity embeds in
//! serialized files.
//!
//! A TypeTree describes the binary layout of one object class: a tree of
//! nodes, each naming a field (`name`) and its type (`type_name`), with
//! size/flags metadata. Two wire encodings exist:
//!
//! - **Legacy** (formats 2-9 and 11): recursive nodes, each with
//!   inline 4-byte-aligned strings. Field presence varies by format
//!   version: format 2 adds `variable_count`; format 3 omits `index` and
//!   `meta_flags`.
//! - **Blob** (formats 10, 12-22): a flat node table whose strings live in
//!   a shared string buffer referenced by offsets; a node's level encodes
//!   the hierarchy. From format 19 each node also carries a reference-type
//!   hash.
//!
//! Blob string offsets with the high bit set (`0x80000000`) reference
//! Unity's global common-string table instead of the local buffer; the
//! remaining bits are an offset into that table. Both are resolved here.
//!
//! All strings and buffers borrow from the source bytes (or the static
//! common-string table); child arrays are allocated from the caller's
//! allocator. Free the allocator (an arena is the intended usage) when the
//! tree is no longer needed — there is no per-tree `deinit`.

const std = @import("std");
const streams = @import("streams.zig");

pub const common_string_flag: u32 = 0x8000_0000;

/// Wire encodings of the TypeTree, selected by SerializedFile format
/// version.
pub const Encoding = enum { legacy_v2, legacy_v3, legacy_standard, blob, blob_with_hash };

/// A node in the type tree. `type_name`/`name` borrow from the source
/// bytes or the common-string table.
pub const Node = struct {
    level: u32,
    type_name: []const u8 = "",
    name: []const u8 = "",
    byte_size: i32 = 0,
    index: i32 = 0,
    type_flags: i32 = 0,
    version: i32 = 0,
    meta_flags: i32 = 0,
    ref_type_hash: u64 = 0,
    children: []Node = &.{},

    pub fn isArray(self: *const Node) bool {
        return std.mem.eql(u8, self.type_name, "Array") or
            std.mem.eql(u8, self.type_name, "TypelessData") or
            std.mem.endsWith(u8, self.type_name, "[]");
    }
};

pub const TypeTree = struct {
    /// SerializedFile format version this tree was parsed from.
    version: u32,
    roots: []Node,
    /// Blob-encoded trees borrow their string buffer from the source.
    string_buffer: []const u8 = &.{},
};

pub const ParseError = error{
    OutOfBounds,
    Corrupt,
    UnsupportedEncoding,
    OutOfMemory,
};

pub const max_nodes: usize = 1_000_000;
pub const max_depth: u32 = 512;

/// Parses a TypeTree with the wire encoding implied by `format_version`.
pub fn parse(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    format_version: u32,
    is_ref_type: bool,
) ParseError!TypeTree {
    _ = is_ref_type; // ref types only differ by the names read after the tree

    // Encoding selection mirrors the SerializedFile format capability map:
    // recursive until 9 and at 11, flat blob at 10 and 12+.
    const encoding: Encoding = switch (format_version) {
        2 => .legacy_v2,
        3 => .legacy_v3,
        4, 5...9 => .legacy_standard,
        10 => .blob,
        11 => .legacy_standard,
        12...18 => .blob,
        19...22 => .blob_with_hash,
        else => return error.UnsupportedEncoding,
    };

    return switch (encoding) {
        .legacy_v2, .legacy_v3, .legacy_standard => parseLegacy(allocator, r, format_version, encoding),
        .blob, .blob_with_hash => parseBlob(allocator, r, format_version, encoding),
    };
}

fn parseLegacy(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    format_version: u32,
    encoding: Encoding,
) ParseError!TypeTree {
    var node_count: usize = 0;
    const root = try readLegacyNode(allocator, r, format_version, encoding, 0, &node_count);
    var roots = allocator.alloc(Node, 1) catch return error.OutOfMemory;
    roots[0] = root;
    return .{ .version = format_version, .roots = roots };
}

fn readLegacyNode(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    format_version: u32,
    encoding: Encoding,
    level: u32,
    node_count: *usize,
) ParseError!Node {
    if (level > max_depth) return error.Corrupt;
    node_count.* += 1;
    if (node_count.* > max_nodes) return error.Corrupt;

    var node = Node{ .level = level };

    // Legacy trees embed their strings as 4-byte-aligned strings.
    node.type_name = try r.readAlignedStringBorrow();
    node.name = try r.readAlignedStringBorrow();
    // Some Unity writers include the NUL in the aligned length; trim it so
    // comparisons against known type names work.
    node.type_name = trimNul(node.type_name);
    node.name = trimNul(node.name);
    node.byte_size = try r.readInt(i32);

    if (encoding == .legacy_v2) _ = try r.readInt(i32); // variable_count
    if (encoding != .legacy_v3) node.index = try r.readInt(i32);
    node.type_flags = try r.readInt(i32);
    node.version = try r.readInt(i32);
    if (encoding != .legacy_v3) node.meta_flags = try r.readInt(i32);

    const child_count = try r.readInt(i32);
    if (child_count < 0) return error.Corrupt;
    const n: usize = @intCast(child_count);
    if (n > max_nodes -| node_count.*) return error.Corrupt;
    if (n == 0) return node;

    const children = allocator.alloc(Node, n) catch return error.OutOfMemory;
    for (children) |*child| {
        child.* = try readLegacyNode(allocator, r, format_version, encoding, level + 1, node_count);
    }
    node.children = children;
    return node;
}

fn parseBlob(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    format_version: u32,
    encoding: Encoding,
) ParseError!TypeTree {
    const node_count = try r.readInt(i32);
    const string_buffer_size = try r.readInt(i32);
    if (node_count < 0 or string_buffer_size < 0) return error.Corrupt;
    const n: usize = @intCast(node_count);
    if (n > max_nodes) return error.Corrupt;
    const buf_size: usize = @intCast(string_buffer_size);
    if (buf_size > 64 * 1024 * 1024) return error.Corrupt;

    const node_width: usize = if (encoding == .blob_with_hash) 32 else 24;
    if (n > (std.math.maxInt(usize) / node_width)) return error.Corrupt;
    const node_bytes = n * node_width;
    if (node_bytes + buf_size > r.remaining()) return error.OutOfBounds;

    const node_data = r.readSlice(node_bytes) catch return error.OutOfBounds;
    const string_buffer = r.readSlice(buf_size) catch return error.OutOfBounds;

    // Parse the flat node table.
    const flat = allocator.alloc(Node, n) catch return error.OutOfMemory;
    for (flat) |*node| node.* = .{ .level = 0 }; // defaults, incl. empty children
    {
        var nr = streams.Reader.init(node_data);
        nr.endian = r.endian;
        for (flat) |*node| {
            node.version = try nr.readInt(i16);
            const level = try nr.readByte();
            if (level > max_depth) return error.Corrupt;
            node.level = level;
            node.type_flags = try nr.readByte();
            const type_off = try nr.readInt(u32);
            const name_off = try nr.readInt(u32);
            node.byte_size = try nr.readInt(i32);
            node.index = try nr.readInt(i32);
            node.meta_flags = try nr.readInt(i32);
            if (encoding == .blob_with_hash) node.ref_type_hash = try nr.readInt(u64);
            node.type_name = try resolveBlobString(string_buffer, type_off);
            node.name = try resolveBlobString(string_buffer, name_off);
        }
    }
    if (n == 0) return .{ .version = format_version, .roots = &.{} };

    // Pass 1: validate levels, count children per node, count roots.
    const child_counts = allocator.alloc(usize, n) catch return error.OutOfMemory;
    @memset(child_counts, 0);
    var parent_at_level: [max_depth + 1]usize = undefined;
    var root_count: usize = 0;
    var prev_level: ?u32 = null;
    for (flat, 0..) |*node, i| {
        if (node.level > max_depth) return error.Corrupt;
        if (prev_level) |prev| {
            if (node.level > prev + 1) return error.Corrupt;
        } else if (node.level != 0) {
            return error.Corrupt;
        }
        prev_level = node.level;
        if (node.level == 0) {
            root_count += 1;
        } else {
            child_counts[parent_at_level[node.level - 1]] += 1;
        }
        parent_at_level[node.level] = i;
    }

    // Pass 2: allocate each node's children array (only parents need one).
    for (flat, 0..) |*node, i| {
        if (child_counts[i] > 0) {
            node.children = allocator.alloc(Node, child_counts[i]) catch return error.OutOfMemory;
        }
    }

    // Pass 3: stack-walk the flat table and attach children to parents.
    const roots = allocator.alloc(Node, root_count) catch return error.OutOfMemory;
    var open: [max_depth + 1]usize = undefined; // index of the open node at each level
    var written: [max_depth + 1]usize = undefined; // children already attached per level
    @memset(&written, 0);
    var root_pos: usize = 0;
    for (flat, 0..) |*node, i| {
        if (node.level == 0) {
            roots[root_pos] = node.*;
            root_pos += 1;
        } else {
            const parent = &flat[open[node.level - 1]];
            const pos = written[node.level - 1];
            parent.children[pos] = node.*;
            written[node.level - 1] = pos + 1;
        }
        // This node is now the open node at its level; its own children will
        // come next and start filling its children array from zero.
        written[node.level] = 0;
        open[node.level] = i;
    }
    std.debug.assert(root_pos == root_count);

    return .{
        .version = format_version,
        .roots = roots,
        .string_buffer = string_buffer,
    };
}

/// Resolves a blob string offset against the local buffer or the common
/// string table.
fn resolveBlobString(buffer: []const u8, offset: u32) ParseError![]const u8 {
    if ((offset & common_string_flag) != 0) {
        return getCommonString(offset & ~common_string_flag) orelse error.Corrupt;
    }
    if (offset >= buffer.len) return error.Corrupt;
    // The offset must point at the start of a NUL-terminated string.
    if (offset != 0 and buffer[offset - 1] != 0) return error.Corrupt;
    const rest = buffer[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Corrupt;
    return rest[0..end];
}

fn trimNul(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == 0) return s[0 .. s.len - 1];
    return s;
}

/// Unity's global common-string table (blob TypeTrees). Offsets are
/// cumulative string lengths + 1, in list order.
const common_strings = [_][]const u8{
    "AABB",                "AnimationClip",       "AnimationCurve",
    "AnimationState",      "Array",               "Base",
    "BitField",            "bitset",              "bool",
    "char",                "ColorRGBA",           "Component",
    "data",                "deque",               "double",
    "dynamic_array",       "FastPropertyName",    "first",
    "float",               "Font",                "GameObject",
    "Generic Mono",        "GradientNEW",         "GUID",
    "GUIStyle",            "int",                 "list",
    "long long",           "map",                 "Matrix4x4f",
    "MdFour",              "MonoBehaviour",       "MonoScript",
    "m_ByteSize",          "m_Curve",             "m_EditorClassIdentifier",
    "m_EditorHideFlags",   "m_Enabled",           "m_ExtensionPtr",
    "m_GameObject",        "m_Index",             "m_IsArray",
    "m_IsStatic",          "m_MetaFlag",          "m_Name",
    "m_ObjectHideFlags",   "m_PrefabInternal",    "m_PrefabParentObject",
    "m_Script",            "m_StaticEditorFlags", "m_Type",
    "m_Version",           "Object",              "pair",
    "PPtr<Component>",     "PPtr<GameObject>",    "PPtr<Material>",
    "PPtr<MonoBehaviour>", "PPtr<MonoScript>",    "PPtr<Object>",
    "PPtr<Prefab>",        "PPtr<Sprite>",        "PPtr<TextAsset>",
    "PPtr<Texture>",       "PPtr<Texture2D>",     "PPtr<Transform>",
    "Prefab",              "Quaternionf",         "Rectf",
    "RectInt",             "RectOffset",          "second",
    "set",                 "short",               "size",
    "SInt16",              "SInt32",              "SInt64",
    "SInt8",               "staticvector",        "string",
    "TextAsset",           "TextMesh",            "Texture",
    "Texture2D",           "Transform",           "TypelessData",
    "UInt16",              "UInt32",              "UInt64",
    "UInt8",               "unsigned int",        "unsigned long long",
    "unsigned short",      "vector",              "Vector2f",
    "Vector3f",            "Vector4f",            "m_ScriptingClassIdentifier",
    "Gradient",            "Type*",               "int2_storage",
    "int3_storage",        "BoundsInt",           "m_CorrespondingSourceObject",
    "m_PrefabInstance",    "m_PrefabAsset",       "FileSize",
    "Hash128",             "RenderingLayerMask",  "fixed_array",
};

/// Looks up a common string by its offset (cumulative length + 1).
pub fn getCommonString(offset: u32) ?[]const u8 {
    var cum: u32 = 0;
    for (common_strings) |s| {
        if (cum == offset) return s;
        cum += @as(u32, @intCast(s.len)) + 1;
    }
    return null;
}

/// Inverse of `getCommonString`: the offset of `name` in the common table.
pub fn commonStringOffset(name: []const u8) ?u32 {
    var cum: u32 = 0;
    for (common_strings) |s| {
        if (std.mem.eql(u8, s, name)) return cum;
        cum += @as(u32, @intCast(s.len)) + 1;
    }
    return null;
}

test "common string offsets are cumulative and resolvable" {
    try std.testing.expectEqualStrings("AABB", getCommonString(0).?);
    // "AABB\0" = 5, then "AnimationClip" starts at 5
    try std.testing.expectEqualStrings("AnimationClip", getCommonString(5).?);
    // last entry: "fixed_array"
    var cum: u32 = 0;
    for (common_strings) |s| cum += @as(u32, @intCast(s.len)) + 1;
    try std.testing.expect(getCommonString(cum) == null);
    try std.testing.expectEqualStrings("fixed_array", getCommonString(cum - @as(u32, @intCast(common_strings[common_strings.len - 1].len)) - 1).?);
    // round trip through the inverse lookup
    try std.testing.expectEqualStrings("GameObject", getCommonString(commonStringOffset("GameObject").?).?);
    try std.testing.expect(commonStringOffset("NotACommonString") == null);
}

test "resolve blob strings" {
    const buffer = "int\x00m_Size\x00Vector3f\x00";
    try std.testing.expectEqualStrings("int", try resolveBlobString(buffer, 0));
    try std.testing.expectEqualStrings("m_Size", try resolveBlobString(buffer, 4));
    try std.testing.expectEqualStrings("Vector3f", try resolveBlobString(buffer, 11));
    // common-string flag bypasses the local buffer
    try std.testing.expectEqualStrings("AABB", try resolveBlobString(buffer, common_string_flag));
    // out of bounds
    try std.testing.expectError(error.Corrupt, resolveBlobString(buffer, 100));
    // offset not at a string start
    try std.testing.expectError(error.Corrupt, resolveBlobString(buffer, 1));
}

test "parse a blob typetree" {
    // parse() allocates arena-style (free the arena, not the tree)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w = streams.Writer.init(a);
    defer w.deinit();
    try w.writeInt(i32, 4); // node count
    try w.writeInt(i32, 0); // string buffer size (strings all common)

    // node 0: root "GameObject" level 0
    try writeBlobNode(&w, 1, 0, common_string_flag + commonStringOffset("GameObject").?, common_string_flag + commonStringOffset("m_GameObject").?, 0, 0, 0);
    // node 1: child "Transform" level 1
    try writeBlobNode(&w, 1, 1, common_string_flag + commonStringOffset("Transform").?, common_string_flag + commonStringOffset("m_Index").?, 0, 0, 0);
    // node 2: child "Texture2D" level 1
    try writeBlobNode(&w, 1, 1, common_string_flag + commonStringOffset("Texture2D").?, common_string_flag + commonStringOffset("m_Type").?, 0, 0, 0);
    // node 3: child of node 2, "m_Name" level 2
    try writeBlobNode(&w, 1, 2, common_string_flag + commonStringOffset("string").?, common_string_flag + commonStringOffset("m_Name").?, 0, 0, 0);

    var r = streams.Reader.init(w.getWritten());
    const tree = try parse(a, &r, 17, false);
    try std.testing.expectEqual(@as(usize, 1), tree.roots.len);
    try std.testing.expectEqualStrings("GameObject", tree.roots[0].type_name);
    try std.testing.expectEqualStrings("m_GameObject", tree.roots[0].name);
    try std.testing.expectEqual(@as(usize, 2), tree.roots[0].children.len);
    try std.testing.expectEqualStrings("Transform", tree.roots[0].children[0].type_name);
    try std.testing.expectEqualStrings("m_Index", tree.roots[0].children[0].name);
    try std.testing.expectEqualStrings("Texture2D", tree.roots[0].children[1].type_name);
    try std.testing.expectEqual(@as(usize, 1), tree.roots[0].children[1].children.len);
    try std.testing.expectEqualStrings("m_Name", tree.roots[0].children[1].children[0].name);
}

test "parse a legacy typetree with aligned strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w = streams.Writer.init(a);
    defer w.deinit();
    try w.writeAlignedString("MonoBehaviour");
    try w.writeAlignedString("Base<MonoBehaviour>");
    try w.writeInt(i32, 0); // byte_size
    try w.writeInt(i32, 0); // index
    try w.writeInt(i32, 0); // type_flags
    try w.writeInt(i32, 1); // version
    try w.writeInt(i32, 0); // meta_flags
    try w.writeInt(i32, 1); // child_count
    try w.writeAlignedString("int");
    try w.writeAlignedString("m_Enabled");
    try w.writeInt(i32, 4);
    try w.writeInt(i32, 0);
    try w.writeInt(i32, 0);
    try w.writeInt(i32, 1);
    try w.writeInt(i32, 0);
    try w.writeInt(i32, 0); // leaf: no children

    var r = streams.Reader.init(w.getWritten());
    const tree = try parse(a, &r, 11, false);
    try std.testing.expectEqual(@as(usize, 1), tree.roots.len);
    try std.testing.expectEqualStrings("MonoBehaviour", tree.roots[0].type_name);
    try std.testing.expectEqual(@as(usize, 1), tree.roots[0].children.len);
    try std.testing.expectEqualStrings("int", tree.roots[0].children[0].type_name);
    try std.testing.expectEqualStrings("m_Enabled", tree.roots[0].children[0].name);
    try std.testing.expectEqual(@as(i32, 4), tree.roots[0].children[0].byte_size);
}

fn writeBlobNode(w: *streams.Writer, version: i16, level: u8, type_off: u32, name_off: u32, byte_size: i32, index: i32, meta: i32) !void {
    try w.writeInt(i16, version);
    try w.writeByte(level);
    try w.writeByte(0); // type_flags
    try w.writeInt(u32, type_off);
    try w.writeInt(u32, name_off);
    try w.writeInt(i32, byte_size);
    try w.writeInt(i32, index);
    try w.writeInt(i32, meta);
}
