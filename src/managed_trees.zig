//! Auto-builds MonoBehaviour type trees from a game's .NET assemblies
//! (`managed --trees`): the field layouts Unity's serializer uses, turned
//! into the injected-trees JSON so typeless Mono files decode without a
//! hand-made trees file.
//!
//! Field ordering follows Unity's serializer: base-class fields first, then
//! the derived class, and only the fields Unity actually serializes
//! (public instance fields for classes; all instance fields for structs).
//! Type resolution walks every parsed assembly: UnityEngine.Object-derived
//! classes become PPtrs, enums become int, structs and [Serializable]
//! classes become inline objects, and generics (List<T>, Dictionary<K,V>)
//! become arrays. The tree building is best-effort: unknown types degrade
//! to a 4-byte int with a warning, so the rest of the tree stays aligned.

const std = @import("std");
const streams = @import("streams.zig");
const dotnet = @import("dotnet.zig");
const typetree = @import("typetree.zig");
const value = @import("value.zig");
const object_reader = @import("object_reader.zig");
const serialized = @import("serialized.zig");

/// One MonoScript object found in a serialized file: the script identity
/// that links a MonoBehaviour's m_Script PPtr to a class in the assemblies.
pub const ScriptRef = struct {
    file: []const u8,
    path_id: i64,
    class_name: []const u8,
    namespace: []const u8,
    assembly: []const u8,
};

// ---------------------------------------------------------------------------
// MonoScript scan: class-115 objects decode with a hardcoded tree (the
// layout is version-stable for 2018+ Mono builds).
// ---------------------------------------------------------------------------

fn monoScriptTree(arena: std.mem.Allocator) !typetree.TypeTree {
    var flat: std.ArrayList(typetree.Node) = .empty;
    const n = struct {
        fn add(list: *std.ArrayList(typetree.Node), al: std.mem.Allocator, level: u32, type_name: []const u8, name: []const u8, meta_flags: i32) !void {
            try list.append(al, .{ .level = level, .type_name = type_name, .name = name, .meta_flags = meta_flags });
        }
    };
    try n.add(&flat, arena, 0, "MonoScript", "Base", 32768);
    try n.add(&flat, arena, 1, "string", "m_Name", 557057);
    try n.add(&flat, arena, 2, "Array", "Array", 540673);
    try n.add(&flat, arena, 3, "int", "size", 524289);
    try n.add(&flat, arena, 3, "char", "data", 524289);
    try n.add(&flat, arena, 1, "int", "m_ExecutionOrder", 16);
    try n.add(&flat, arena, 1, "Hash128", "m_PropertiesHash", 16);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try n.add(&flat, arena, 2, "UInt8", try std.fmt.allocPrint(arena, "bytes[{d}]", .{i}), 16);
    }
    try n.add(&flat, arena, 1, "string", "m_ClassName", 32784);
    try n.add(&flat, arena, 2, "Array", "Array", 16401);
    try n.add(&flat, arena, 3, "int", "size", 17);
    try n.add(&flat, arena, 3, "char", "data", 17);
    try n.add(&flat, arena, 1, "string", "m_Namespace", 32784);
    try n.add(&flat, arena, 2, "Array", "Array", 16401);
    try n.add(&flat, arena, 3, "int", "size", 17);
    try n.add(&flat, arena, 3, "char", "data", 17);
    try n.add(&flat, arena, 1, "string", "m_AssemblyName", 32784);
    try n.add(&flat, arena, 2, "Array", "Array", 16401);
    try n.add(&flat, arena, 3, "int", "size", 17);
    try n.add(&flat, arena, 3, "char", "data", 17);
    return typetree.fromFlatNodes(arena, flat.items);
}

fn fieldStr(v: value.Value, name: []const u8) []const u8 {
    if (v != .obj) return "";
    for (v.obj) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            if (f.value == .string) return f.value.string;
        }
    }
    return "";
}

/// Decodes every MonoScript (class 115) object of a serialized file.
pub fn scanMonoScripts(arena: std.mem.Allocator, bytes: []const u8, own_basename: []const u8) ![]const ScriptRef {
    const sf = try serialized.parse(arena, bytes);
    const tree = try monoScriptTree(arena);
    var out: std.ArrayList(ScriptRef) = .empty;
    for (sf.objects) |*o| {
        if (o.class_id != 115) continue;
        const data = sf.objectData(o) orelse continue;
        var r = streams.Reader.init(data);
        r.endian = sf.endian;
        const v = object_reader.readObject(arena, &r, &tree.roots[0]) catch continue;
        const cn = fieldStr(v, "m_ClassName");
        const ns = fieldStr(v, "m_Namespace");
        const asm_name = fieldStr(v, "m_AssemblyName");
        if (cn.len == 0) continue;
        try out.append(arena, .{
            .file = own_basename,
            .path_id = o.path_id,
            .class_name = cn,
            .namespace = ns,
            .assembly = asm_name,
        });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Type map: every type of every assembly, indexed by full name.
// ---------------------------------------------------------------------------

pub const TypeInfo = struct {
    fields: []const dotnet.Field = &.{},
    is_object_derived: bool = false,
    is_enum: bool = false,
    is_struct: bool = false,
};

pub const TypeMap = std.StringHashMapUnmanaged(TypeInfo);

fn isEnum(td: dotnet.TypeDef) bool {
    const base = td.base_name orelse return false;
    return std.mem.eql(u8, base, "System.Enum");
}

/// Whether a type derives (transitively) from UnityEngine.Object, i.e. it
/// serializes as a PPtr rather than an inline object.
fn isObjectDerived(arena: std.mem.Allocator, td: dotnet.TypeDef, type_defs: []const dotnet.TypeDef) bool {
    const roots = [_][]const u8{
        "UnityEngine.Object",
        "UnityEngine.Component",
        "UnityEngine.Behaviour",
        "UnityEngine.MonoBehaviour",
        "UnityEngine.ScriptableObject",
        "UnityEngine.StateMachineBehaviour",
        "UnityEngine.GameObject",
        "UnityEngine.AnimationClip",
        "UnityEngine.Motion",
    };
    var seen: usize = 0;
    var current: ?dotnet.TypeDef = td;
    while (current) |c| {
        if (seen > 64) return false;
        seen += 1;
        const base = c.base_name orelse return false;
        for (roots) |r| {
            if (std.mem.eql(u8, base, r)) return true;
        }
        var found: ?dotnet.TypeDef = null;
        for (type_defs) |d| {
            if (std.mem.eql(u8, d.fullName(arena), base)) {
                found = d;
                break;
            }
        }
        if (found == null) return false;
        current = found;
    }
    return false;
}

pub fn buildTypeMap(arena: std.mem.Allocator, assemblies: []const dotnet.Assembly) !TypeMap {
    var map: TypeMap = .empty;
    for (assemblies) |assembly| {
        for (assembly.type_defs) |td| {
            const name = td.fullName(arena);
            if (map.contains(name)) continue;
            var info = TypeInfo{};
            if (isEnum(td)) {
                info.is_enum = true;
            } else {
                info.fields = try dotnet.collectFields(arena, td, assembly.type_defs, assembly.field_serialized, assembly.field_nonserialized);
                info.is_object_derived = isObjectDerived(arena, td, assembly.type_defs);
                info.is_struct = (td.flags & 0x100) != 0; // ValueType
            }
            try map.put(arena, name, info);
        }
    }
    return map;
}

// ---------------------------------------------------------------------------
// Field -> flat typetree nodes
// ---------------------------------------------------------------------------

/// Appends one flat node (and its children) for a managed field.
/// `types` resolves class/valuetype names; `warn` collects unsupported
/// types so the caller can report them.
fn appendFieldNodes(
    arena: std.mem.Allocator,
    out: *std.ArrayList(typetree.Node),
    level: u32,
    depth: u32,
    budget: *NodeBudget,
    field: dotnet.Field,
    types: *const TypeMap,
    warnings: *std.ArrayList([]const u8),
) BuildError!void {
    const t = field.elem_type;
    if (t == dotnet.element.string) {
        try appendNode(out, arena, level, "string", field.name, align_flag);
        return;
    }
    if (dotnet.elementTypeName(t).len != 0) {
        try appendNode(out, arena, level, dotnet.elementTypeName(t), field.name, 0);
        return;
    }
    // arrays: T[] (szarray) or List<T> (genericinst with generic_arg)
    if (t == dotnet.element.szarray) {
        try appendArray(out, arena, level, depth, budget, field.name, field.type_name, types, warnings);
        return;
    }
    if (t == dotnet.element.genericinst) {
        if (std.mem.startsWith(u8, field.type_name, "System.Collections.Generic.Dictionary`2")) {
            try appendDictionary(out, arena, level, depth, budget, field.name, field.generic_arg, field, types, warnings);
            return;
        }
        // List<T> and friends serialize as an array of the first arg
        try appendArray(out, arena, level, depth, budget, field.name, field.generic_arg, types, warnings);
        return;
    }
    if (t == dotnet.element.class or t == dotnet.element.valuetype) {
        try appendClassField(out, arena, level, depth, budget, field.name, field.type_name, types, warnings);
        return;
    }
    // unknown element types (pointers, byref, fnptr...): skip, Unity does
    // not serialize them
}

const align_flag: i32 = 0x4000;

/// Errors the recursive tree builder can produce.
const BuildError = error{ OutOfMemory, NoSpaceLeft };

/// Inline class nesting cap: cyclic [Serializable] classes (A has a field
/// of type B, B of type A) would recurse forever; Unity itself rejects
/// recursive serialization.
const max_inline_depth: u32 = 8;

/// Node-count budget per tree: pathological classes (a field whose type
/// expands to hundreds of thousands of nodes) are truncated instead of
/// exhausting memory.
pub const NodeBudget = struct {
    count: usize = 0,
    limit: usize = 100_000,
};

fn appendNode(out: *std.ArrayList(typetree.Node), arena: std.mem.Allocator, level: u32, type_name: []const u8, name: []const u8, meta: i32) !void {
    try out.append(arena, .{ .level = level, .type_name = type_name, .name = name, .meta_flags = meta });
}

fn appendArray(
    out: *std.ArrayList(typetree.Node),
    arena: std.mem.Allocator,
    level: u32,
    depth: u32,
    budget: *NodeBudget,
    name: []const u8,
    elem_name: []const u8,
    types: *const TypeMap,
    warnings: *std.ArrayList([]const u8),
) BuildError!void {
    try appendNode(out, arena, level, "Array", name, align_flag);
    try appendNode(out, arena, level + 1, "int", "size", 0);
    try appendElement(out, arena, level + 1, depth + 1, budget, "data", elem_name, types, warnings);
}

fn appendDictionary(
    out: *std.ArrayList(typetree.Node),
    arena: std.mem.Allocator,
    level: u32,
    depth: u32,
    budget: *NodeBudget,
    name: []const u8,
    elem_name: []const u8,
    field: dotnet.Field,
    types: *const TypeMap,
    warnings: *std.ArrayList([]const u8),
) BuildError!void {
    // Unity serializes Dictionary<K,V> as a List<KeyValuePair<K,V>> where
    // each entry is an inline struct with key/value fields.
    try appendNode(out, arena, level, "Array", name, align_flag);
    try appendNode(out, arena, level + 1, "int", "size", 0);
    try appendNode(out, arena, level + 1, "KeyValuePair`2", "data", 0);
    try appendElement(out, arena, level + 2, depth + 1, budget, "key", elem_name, types, warnings);
    try appendElement(out, arena, level + 2, depth + 1, budget, "value", field.generic_arg2, types, warnings);
}

/// The short class name for a PPtr: "UnityEngine.UI.Text" -> "Text".
fn shortName(arena: std.mem.Allocator, full: []const u8) ![]const u8 {
    if (std.mem.lastIndexOfScalar(u8, full, '.')) |i| return full[i + 1 ..];
    return arena.dupe(u8, full);
}

/// A class/valuetype field: PPtr for Object-derived, inline object for
/// structs and [Serializable] classes, int for enums.
fn appendClassField(
    out: *std.ArrayList(typetree.Node),
    arena: std.mem.Allocator,
    level: u32,
    depth: u32,
    budget: *NodeBudget,
    name: []const u8,
    full_name: []const u8,
    types: *const TypeMap,
    warnings: *std.ArrayList([]const u8),
) BuildError!void {
    if (depth > max_inline_depth) {
        try appendNode(out, arena, level, "int", name, 0);
        try warnings.append(arena, try std.fmt.allocPrint(arena, "  {s}: {s} nested too deep -> int placeholder", .{ name, full_name }));
        return;
    }
    if (types.get(full_name)) |info| {
        if (info.is_enum) {
            try appendNode(out, arena, level, "int", name, 0);
            return;
        }
        if (info.is_object_derived) {
            const sn = try shortName(arena, full_name);
            try appendNode(out, arena, level, try std.fmt.allocPrint(arena, "PPtr<{s}>", .{sn}), name, 0);
            try appendNode(out, arena, level + 1, "int", "m_FileID", 0);
            try appendNode(out, arena, level + 1, "SInt64", "m_PathID", 0);
            return;
        }
        // inline struct / class: its fields, base-first
        try appendNode(out, arena, level, full_name, name, 0);
        try appendFields(out, arena, level + 1, depth + 1, budget, info.fields, types, warnings);
        return;
    }
    // not in the assemblies (e.g. a System.* type Unity skips, or an
    // unknown third-party struct): keep alignment with a 4-byte int
    try appendNode(out, arena, level, "int", name, 0);
    try warnings.append(arena, try std.fmt.allocPrint(arena, "  {s}: unknown type {s} -> int placeholder", .{ name, full_name }));
}

fn appendFields(
    out: *std.ArrayList(typetree.Node),
    arena: std.mem.Allocator,
    level: u32,
    depth: u32,
    budget: *NodeBudget,
    fields: []const dotnet.Field,
    types: *const TypeMap,
    warnings: *std.ArrayList([]const u8),
) BuildError!void {
    for (fields) |f| {
        budget.count += 1;
        if (budget.count > budget.limit) return;
        try appendFieldNodes(arena, out, level, depth, budget, f, types, warnings);
    }
}

fn appendElement(
    out: *std.ArrayList(typetree.Node),
    arena: std.mem.Allocator,
    level: u32,
    depth: u32,
    budget: *NodeBudget,
    name: []const u8,
    type_name: []const u8,
    types: *const TypeMap,
    warnings: *std.ArrayList([]const u8),
) BuildError!void {
    if (depth > max_inline_depth) {
        try appendNode(out, arena, level, "int", name, 0);
        return;
    }
    // element types come from resolved names; map them back to a Field-like
    // spec and recurse
    if (std.mem.endsWith(u8, type_name, "[]")) {
        const base = type_name[0 .. type_name.len - 2];
        try appendNode(out, arena, level, "Array", name, align_flag);
        try appendNode(out, arena, level + 1, "int", "size", 0);
        try appendElement(out, arena, level + 1, depth + 1, budget, "data", base, types, warnings);
        return;
    }
    if (std.mem.eql(u8, type_name, "string")) {
        try appendNode(out, arena, level, "string", name, align_flag);
        return;
    }
    if (primitiveWireName(type_name)) |pw| {
        try appendNode(out, arena, level, pw, name, 0);
        return;
    }
    if (types.get(type_name)) |info| {
        if (info.is_enum) {
            try appendNode(out, arena, level, "int", name, 0);
            return;
        }
        if (info.is_object_derived) {
            const sn = try shortName(arena, type_name);
            try appendNode(out, arena, level, try std.fmt.allocPrint(arena, "PPtr<{s}>", .{sn}), name, 0);
            try appendNode(out, arena, level + 1, "int", "m_FileID", 0);
            try appendNode(out, arena, level + 1, "SInt64", "m_PathID", 0);
            return;
        }
        try appendNode(out, arena, level, type_name, name, 0);
        try appendFields(out, arena, level + 1, depth + 1, budget, info.fields, types, warnings);
        return;
    }
    try appendNode(out, arena, level, "int", name, 0);
}

fn primitiveWireName(type_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, type_name, "bool")) return "bool";
    if (std.mem.eql(u8, type_name, "int")) return "int";
    if (std.mem.eql(u8, type_name, "float")) return "float";
    if (std.mem.eql(u8, type_name, "double")) return "double";
    if (std.mem.eql(u8, type_name, "uint")) return "unsigned int";
    if (std.mem.eql(u8, type_name, "byte")) return "UInt8";
    if (std.mem.eql(u8, type_name, "sbyte")) return "SInt8";
    if (std.mem.eql(u8, type_name, "short")) return "SInt16";
    if (std.mem.eql(u8, type_name, "ushort")) return "UInt16";
    if (std.mem.eql(u8, type_name, "long")) return "SInt64";
    if (std.mem.eql(u8, type_name, "ulong")) return "UInt64";
    return null;
}

// ---------------------------------------------------------------------------
// Script tree assembly
// ---------------------------------------------------------------------------

/// The standard MonoBehaviour header: what every script object starts with.
/// Flags match the TypeTreeGeneratorAPI output the injected-trees mechanism
/// was validated against.
pub fn monoBehaviourHeader(arena: std.mem.Allocator) ![]typetree.Node {
    var out: std.ArrayList(typetree.Node) = .empty;
    try appendNode(&out, arena, 1, "PPtr<GameObject>", "m_GameObject", 0x41);
    try appendNode(&out, arena, 2, "int", "m_FileID", 0x41);
    try appendNode(&out, arena, 2, "SInt64", "m_PathID", 0x41);
    try appendNode(&out, arena, 1, "UInt8", "m_Enabled", 0x4101);
    try appendNode(&out, arena, 1, "PPtr<MonoScript>", "m_Script", 0x0);
    try appendNode(&out, arena, 2, "int", "m_FileID", 0x800001);
    try appendNode(&out, arena, 2, "SInt64", "m_PathID", 0x800001);
    try appendNode(&out, arena, 1, "string", "m_Name", 0x88001);
    return out.toOwnedSlice(arena);
}

/// The full flat tree for one script class: root + header + script fields.
pub fn buildScriptTree(
    arena: std.mem.Allocator,
    class_key: []const u8,
    header: []const typetree.Node,
    script_fields: []const dotnet.Field,
    budget: *NodeBudget,
    types: *const TypeMap,
    warnings: *std.ArrayList([]const u8),
) BuildError![]typetree.Node {
    var out: std.ArrayList(typetree.Node) = .empty;
    try appendNode(&out, arena, 0, class_key, "Base", 32768);
    for (header) |h| {
        try out.append(arena, h);
    }
    try appendFields(&out, arena, 1, 0, budget, script_fields, types, warnings);
    const nodes = try out.toOwnedSlice(arena);
    markSmallRunAlignment(nodes);
    return nodes;
}

/// Unity packs consecutive sub-4-byte fields (bool/char/byte/short runs)
/// and pads only after the run's last member, before the next value that
/// needs 4-byte alignment (a string, int, PPtr, or nested record). Real
/// type trees mark that last member with the 0x4000 align flag. Without
/// the flag the reader stops right after the small field and skips the
/// wire padding, misreading everything that follows (every pre-2019
/// MonoBehaviour whose fields end a small run decoded as Corrupt).
fn markSmallRunAlignment(nodes: []typetree.Node) void {
    const is_small = struct {
        fn f(t: []const u8) bool {
            return std.mem.eql(u8, t, "bool") or std.mem.eql(u8, t, "char") or
                std.mem.eql(u8, t, "UInt8") or std.mem.eql(u8, t, "SInt8") or
                std.mem.eql(u8, t, "UInt16") or std.mem.eql(u8, t, "SInt16");
        }
    }.f;
    for (nodes, 0..) |*node, i| {
        if (!is_small(node.type_name)) continue;
        if (i + 1 >= nodes.len) continue; // object-final field: no pad follows
        if (is_small(nodes[i + 1].type_name)) continue; // packed with the next
        node.meta_flags |= align_flag;
    }
}

/// The flat tree for the "MonoBehaviour" class: the header only (used to
/// read m_Script before the script tree is known).
pub fn monoHeaderTree(arena: std.mem.Allocator, header: []const typetree.Node) ![]typetree.Node {
    var out: std.ArrayList(typetree.Node) = .empty;
    try appendNode(&out, arena, 0, "MonoBehaviour", "Base", 32768);
    for (header) |h| {
        try out.append(arena, h);
    }
    return out.toOwnedSlice(arena);
}

/// Serializes a flat node list to the injected-trees JSON form.
pub fn nodesToJson(arena: std.mem.Allocator, nodes: []const typetree.Node) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const w = &aw.writer;
    try w.writeByte('[');
    for (nodes, 0..) |n, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"m_Type\":", .{});
        try writeJsonString(w, n.type_name);
        try w.writeAll(",\"m_Name\":");
        try writeJsonString(w, n.name);
        try w.print(",\"m_Level\":{d},\"m_MetaFlag\":{d},\"m_ByteSize\":{d},\"m_Version\":{d},\"m_TypeFlags\":{d},\"m_Index\":{d}}}", .{ n.level, n.meta_flags, n.byte_size, n.version, n.type_flags, n.index });
    }
    try w.writeByte(']');
    var list = aw.toArrayList();
    return list.toOwnedSlice(arena);
}

pub fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "markSmallRunAlignment flags the run end before aligned data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list: std.ArrayList(typetree.Node) = .empty;
    const n = struct {
        fn add(l: *std.ArrayList(typetree.Node), al: std.mem.Allocator, t: []const u8) !void {
            try l.append(al, .{ .level = 1, .type_name = t, .name = "", .meta_flags = 0 });
        }
    };
    // bool, bool, string  -> the two bools pack; nothing aligns before the
    // string (2 bytes then pad is written after the run's last member)
    try n.add(&list, a, "bool");
    try n.add(&list, a, "bool");
    try n.add(&list, a, "string");
    // bool, int -> the bool's pad lands before the int
    try n.add(&list, a, "bool");
    try n.add(&list, a, "int");
    // char at the very end of the object: no pad stored, no flag
    try n.add(&list, a, "char");
    const nodes = try list.toOwnedSlice(a);
    markSmallRunAlignment(nodes);
    try std.testing.expectEqual(@as(i32, 0), nodes[0].meta_flags); // packed: followed by another bool
    try std.testing.expectEqual(@as(i32, 0x4000), nodes[1].meta_flags); // run end: pads before the string
    try std.testing.expectEqual(@as(i32, 0), nodes[2].meta_flags); // string, not small
    try std.testing.expectEqual(@as(i32, 0x4000), nodes[3].meta_flags); // bool before int
    try std.testing.expectEqual(@as(i32, 0), nodes[4].meta_flags); // int
    try std.testing.expectEqual(@as(i32, 0), nodes[5].meta_flags); // final char, no pad
}
