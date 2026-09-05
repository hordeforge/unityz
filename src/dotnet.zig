//! .NET assembly metadata reader — the piece that makes MonoBehaviour
//! decoding possible without Unity's type trees.
//!
//! Unity serializes a MonoBehaviour's managed fields in the class's .NET
//! layout, which lives in the game's managed assemblies (Assembly-CSharp.dll
//! et al.), not in the serialized file. UnityPy can only decode those
//! objects by loading the assemblies through an external CLR (pythonnet /
//! Mono.Cecil); this module reads the ECMA-335 metadata directly in Zig.
//!
//! Coverage is the minimal slice that answers "which scripts exist and what
//! do they serialize": PE/CLI header walk, the `#~` metadata table stream,
//! and the TypeDef / TypeRef / Field / AssemblyRef tables with field
//! signature decoding. Everything else (methods, properties, custom
//! attributes, generics instantiation) is skipped. Rows that do not resolve
//! (missing heaps, out-of-range coded indices) are skipped defensively; a
//! malformed assembly fails with a parse error, never a crash.

const std = @import("std");
const streams = @import("streams.zig");

pub const Error = error{
    NotPe,
    NoCliHeader,
    NoMetadata,
    Corrupt,
    OutOfMemory,
    OutOfBounds,
};

/// One serialized-visible field of a managed class.
pub const Field = struct {
    name: []const u8,
    /// CLR field flags: 0x6 = public, 0x10 = static, 0x20 = literal,
    /// 0x80 = fdNotSerialized (the C# compiler's encoding of [NonSerialized]).
    flags: u16,
    /// ECMA-335 element type byte of the field signature (ELEMENT_TYPE_*).
    elem_type: u8,
    /// Resolved type name for class/valuetype/szarray signatures
    /// ("System.String", "UnityEngine.Vector3", "System.Int32[]", ...);
    /// empty for the plain primitives (named by `elementTypeName`).
    type_name: []const u8 = "",
    /// For generic instantiations (List<T>, Dictionary<K,V>): the resolved
    /// first type argument.
    generic_arg: []const u8 = "",
    /// The resolved second type argument (Dictionary<K,V> values).
    generic_arg2: []const u8 = "",
    /// 1-based Field-table row (for custom-attribute lookups).
    row: u32 = 0,

    pub fn isPublic(self: Field) bool {
        return (self.flags & 0x6) == 0x6;
    }
    pub fn isStatic(self: Field) bool {
        return (self.flags & 0x10) != 0;
    }
    pub fn isLiteral(self: Field) bool {
        return (self.flags & 0x20) != 0;
    }
    /// fdNotSerialized (0x80): the IL flag C# emits for [NonSerialized].
    /// Unity skips such fields even when public or [SerializeField]-marked.
    pub fn isNotSerialized(self: Field) bool {
        return (self.flags & 0x80) != 0;
    }
};

/// One managed class definition.
pub const TypeDef = struct {
    name: []const u8,
    namespace: []const u8,
    flags: u32,
    fields: []const Field,
    /// Base class as resolved: the same-assembly TypeDef's full name, or the
    /// TypeRef's namespace-qualified name ("UnityEngine.MonoBehaviour").
    /// Null when the row has no base (object) or it does not resolve.
    base_name: ?[]const u8 = null,
    /// Coded TypeDefOrRef value of `extends` (0 = no base).
    extends_coded: u32 = 0,

    pub fn fullName(self: TypeDef, arena: std.mem.Allocator) []const u8 {
        return if (self.namespace.len != 0)
            std.fmt.allocPrint(arena, "{s}.{s}", .{ self.namespace, self.name }) catch self.name
        else
            self.name;
    }
};

pub const Assembly = struct {
    /// Assembly name (the file name; the metadata carries it only via
    /// AssemblyDef, which this reader skips).
    name: []const u8 = "",
    type_defs: []const TypeDef,
    /// Per field-row (1-based) custom-attribute marks: whether the field
    /// carries [SerializeField] (private fields Unity serializes anyway)
    /// or [NonSerialized] (public fields Unity skips).
    field_serialized: []const bool = &.{},
    field_nonserialized: []const bool = &.{},
    /// Per TypeDef-row mark: whether the class carries [Serializable].
    type_serializable: []const bool = &.{},
};

/// ELEMENT_TYPE_* constants used by field signatures.
pub const element = struct {
    pub const boolean: u8 = 0x02;
    pub const t_i1: u8 = 0x04;
    pub const t_u1: u8 = 0x05;
    pub const t_i2: u8 = 0x06;
    pub const t_u2: u8 = 0x07;
    pub const t_i4: u8 = 0x08;
    pub const t_u4: u8 = 0x09;
    pub const t_i8: u8 = 0x0a;
    pub const t_u8: u8 = 0x0b;
    pub const r4: u8 = 0x0c;
    pub const r8: u8 = 0x0d;
    pub const string: u8 = 0x0e;
    pub const object: u8 = 0x1c;
    pub const genericinst: u8 = 0x15;
    pub const class: u8 = 0x12;
    pub const valuetype: u8 = 0x11;
    pub const szarray: u8 = 0x1d;
    pub const array: u8 = 0x14;
};

/// Human-readable name for the plain primitive element types.
pub fn elementTypeName(e: u8) []const u8 {
    return switch (e) {
        element.boolean => "bool",
        element.t_i1 => "sbyte",
        element.t_u1 => "byte",
        element.t_i2 => "short",
        element.t_u2 => "ushort",
        element.t_i4 => "int",
        element.t_u4 => "uint",
        element.t_i8 => "long",
        element.t_u8 => "ulong",
        element.r4 => "float",
        element.r8 => "double",
        element.string => "string",
        element.object => "object",
        else => "",
    };
}

// ---------------------------------------------------------------------------
// PE container
// ---------------------------------------------------------------------------

const Section = struct { virtual_address: u32, raw_offset: u32, raw_size: u32 };

fn parsePeSections(bytes: []const u8, arena: std.mem.Allocator) Error![]const Section {
    var r = streams.Reader.init(bytes);
    try r.seek(0x3C);
    const e_lfanew = try r.readInt(u32);
    if (e_lfanew + 4 > bytes.len) return error.NotPe;
    try r.seek(e_lfanew);
    const sig = try r.readInt(u32);
    if (sig != 0x0000_4550) return error.NotPe; // "PE\0\0"
    try r.skip(2); // machine
    const num_sections = try r.readInt(u16);
    try r.skip(4); // timestamp
    try r.skip(4); // symbol table pointer
    try r.skip(4); // symbol count
    const opt_size = try r.readInt(u16);
    try r.skip(2); // characteristics
    try r.seek(e_lfanew + 24 + opt_size);
    const sections = try arena.alloc(Section, num_sections);
    for (sections) |*s| {
        try r.skip(8); // name
        try r.skip(4); // virtual size
        s.virtual_address = try r.readInt(u32);
        s.raw_size = try r.readInt(u32); // size of raw data
        s.raw_offset = try r.readInt(u32); // pointer to raw data
        try r.skip(16); // relocations, line numbers, characteristics
    }
    return sections;
}

fn rvaToOffset(rva: u32, sections: []const Section) ?u32 {
    for (sections) |s| {
        if (rva >= s.virtual_address and rva < s.virtual_address + s.raw_size) {
            return s.raw_offset + (rva - s.virtual_address);
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Metadata root + heaps
// ---------------------------------------------------------------------------

const Heaps = struct {
    strings: []const u8 = &.{},
    blob: []const u8 = &.{},
    /// heap index widths: bit 0 = strings 4-byte, bit 2 = blob 4-byte
    heap_sizes: u8 = 0,
    /// per-table row counts from the #~ stream mask; coded-index widths are
    /// decided from these, exactly like tableRowSize does
    table_counts: [64]u32 = [_]u32{0} ** 64,
    valid_mask: u64 = 0,
};

/// Reads a #Strings heap index (4 bytes when heap_sizes bit 0 set).
fn readString(r: *streams.Reader, heaps: *const Heaps) Error![]const u8 {
    const idx: usize = if ((heaps.heap_sizes & 1) != 0) try r.readInt(u32) else try r.readInt(u16);
    if (idx >= heaps.strings.len) return error.Corrupt;
    const rest = heaps.strings[idx..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    return rest[0..end];
}

fn readBlob(r: *streams.Reader, heaps: *const Heaps) Error![]const u8 {
    const idx: usize = if ((heaps.heap_sizes & 4) != 0) try r.readInt(u32) else try r.readInt(u16);
    if (idx >= heaps.blob.len) return error.Corrupt;
    const blob = heaps.blob[idx..];
    if (blob.len == 0) return error.Corrupt;
    var pos: usize = 0;
    const b0 = blob[0];
    const len: usize = if (b0 < 0x80) blk: {
        pos = 1;
        break :blk b0;
    } else if ((b0 & 0xc0) == 0x80) blk: {
        if (blob.len < 2) return error.Corrupt;
        pos = 2;
        break :blk (@as(usize, b0 & 0x3f) << 8) | blob[1];
    } else if ((b0 & 0xe0) == 0xc0) blk: {
        if (blob.len < 4) return error.Corrupt;
        pos = 4;
        break :blk (@as(usize, b0 & 0x1f) << 24) | (@as(usize, blob[1]) << 16) | (@as(usize, blob[2]) << 8) | blob[3];
    } else return error.Corrupt;
    if (pos + len > blob.len) return error.Corrupt;
    return blob[pos .. pos + len];
}

// ---------------------------------------------------------------------------
// #~ table stream
// ---------------------------------------------------------------------------

/// ECMA-335 metadata table numbers (II.22). Pointer tables (FieldPtr etc.)
/// are absent from optimized `#~` streams but listed for completeness.
const tables = struct {
    pub const module: u32 = 0x00;
    pub const typeref: u32 = 0x01;
    pub const typedef: u32 = 0x02;
    pub const field: u32 = 0x04;
    pub const methoddef: u32 = 0x06;
    pub const param: u32 = 0x08;
    pub const memberref: u32 = 0x0a;
    pub const customattr: u32 = 0x0c;
    pub const property: u32 = 0x17;
    pub const moduleref: u32 = 0x1a;
    pub const typespec: u32 = 0x1b;
    pub const assembly: u32 = 0x20;
    pub const assemblyref: u32 = 0x23;
    pub const genericparam: u32 = 0x2a;
};

const TableData = struct {
    /// The whole `#~` stream; row cursors are readers over slices of it.
    bytes: []const u8,
    offsets: [64]u32 = [_]u32{0} ** 64,
    row_counts: [64]u32 = [_]u32{0} ** 64,
    row_sizes: [64]u32 = [_]u32{0} ** 64,
};

/// Parses the `#~` (or `#-`) stream: masks, row counts, and row widths.
fn parseTableStream(bytes: []const u8, heaps: *Heaps) Error!TableData {
    var r = streams.Reader.init(bytes);
    try r.seek(4); // reserved
    try r.skip(2); // major/minor version
    heaps.heap_sizes = try r.readByte();
    try r.skip(1); // reserved
    heaps.valid_mask = try r.readInt(u64);
    try r.skip(8); // sorted mask

    var counts: [64]u32 = [_]u32{0} ** 64;
    var t: u32 = 0;
    while (t < 64) : (t += 1) {
        if ((heaps.valid_mask & (@as(u64, 1) << @as(u6, @intCast(t)))) != 0) {
            counts[t] = try r.readInt(u32);
        }
    }
    for (counts, 0..) |c, i| {
        heaps.table_counts[i] = c;
    }

    var out: TableData = .{ .bytes = bytes };
    var off: u32 = @intCast(r.position());
    var cur: u32 = 0;
    while (cur < 64) : (cur += 1) {
        if (counts[cur] == 0) continue;
        const row_size = tableRowSize(cur, counts, heaps);
        out.row_counts[cur] = counts[cur];
        out.row_sizes[cur] = row_size;
        out.offsets[cur] = off;
        off +%= row_size * counts[cur];
    }
    return out;
}

/// Byte width of one row of metadata table `t`. Every column's width is
/// decided by the largest row count of the tables it indexes (ECMA-335
/// II.24.2.4): heap indices are 4 bytes when `heap_sizes` says so, plain
/// table indices are 4 bytes when the target table has >= 2^16 rows, and
/// coded indices are 4 bytes when the largest tagged table has >= 2^(16-tags)
/// rows. Getting any of these wrong shifts every later table's offset.
fn tableRowSize(t: u32, counts: [64]u32, heaps: *const Heaps) u32 {
    const sz = heaps.heap_sizes;
    const s2: u32 = if ((sz & 1) != 0) 4 else 2; // string heap
    const b2: u32 = if ((sz & 4) != 0) 4 else 2; // blob heap
    const g2: u32 = if ((sz & 2) != 0) 4 else 2; // guid heap
    // largest tagged-table row count per coded index
    const type_def_or_ref = maxCount(counts, &.{ 0x02, 0x01, 0x1b });
    const type_or_method_def = maxCount(counts, &.{ 0x02, tables.methoddef });
    const method_def_or_ref = maxCount(counts, &.{ tables.methoddef, tables.memberref });
    const resolution_scope = maxCount(counts, &.{ 0x00, 0x1a, 0x23, 0x01 });
    const member_ref_parent = maxCount(counts, &.{ 0x02, 0x01, 0x1a, tables.methoddef, 0x1b });
    const has_constant = maxCount(counts, &.{ 0x04, 0x08, 0x17 });
    const has_custom_attr = maxCount(counts, &.{ 0x06, 0x04, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x00, 0x0e, 0x17, 0x14, 0x11, 0x1a, 0x1b, 0x20, 0x23, 0x26, 0x27, 0x28, 0x2a, 0x2c, 0x2b });
    const has_field_marshal = maxCount(counts, &.{ 0x04, 0x08 });
    const has_decl_security = maxCount(counts, &.{ 0x02, tables.methoddef, 0x20 });
    const has_semantics = maxCount(counts, &.{ 0x14, 0x17 });
    const member_forwarded = maxCount(counts, &.{ 0x04, tables.methoddef });
    const implementation = maxCount(counts, &.{ 0x26, 0x23, 0x27 });
    return switch (t) {
        0x00 => 2 + s2 + 3 * g2, // Module
        0x01 => 2 * s2 + codedSize(resolution_scope, 2), // TypeRef
        0x02 => 4 + 2 * s2 + codedSize(type_def_or_ref, 2) + idxWidth(counts[0x04]) + idxWidth(counts[tables.methoddef]), // TypeDef
        0x03 => idxWidth(counts[0x04]), // FieldPtr
        0x04 => 2 + s2 + b2, // Field
        0x05 => idxWidth(counts[tables.methoddef]), // MethodPtr
        0x06 => 4 + 2 + 2 + s2 + b2 + idxWidth(counts[0x08]), // MethodDef: RVA, impl flags, flags, name, sig, param list
        0x07 => idxWidth(counts[0x08]), // ParamPtr
        // Param has only three columns (flags, sequence, name): the
        // parameter types live in the method's signature blob, not here.
        0x08 => 2 + 2 + s2,
        0x09 => idxWidth(counts[0x02]) + codedSize(type_def_or_ref, 2), // InterfaceImpl
        0x0a => codedSize(member_ref_parent, 3) + s2 + b2, // MemberRef
        0x0b => 2 + codedSize(has_constant, 2) + b2, // Constant
        0x0c => codedSize(has_custom_attr, 5) + codedSize(method_def_or_ref, 3) + b2, // CustomAttribute; Type tag needs 3 bits (MethodDef=2, MemberRef=3)
        0x0d => codedSize(has_field_marshal, 1) + b2, // FieldMarshal: Field=0, Param=1 (1-bit tag)
        0x0e => 2 + codedSize(has_decl_security, 2) + b2, // DeclSecurity
        0x0f => 2 + 4 + idxWidth(counts[0x02]), // ClassLayout
        0x10 => 4 + idxWidth(counts[0x04]), // FieldLayout
        0x11 => b2, // StandAloneSig
        0x12 => idxWidth(counts[0x02]) + idxWidth(counts[0x14]), // EventMap
        0x13 => idxWidth(counts[0x14]), // EventPtr
        0x14 => 2 + s2 + codedSize(type_def_or_ref, 2), // Event
        0x15 => idxWidth(counts[0x02]) + idxWidth(counts[0x17]), // PropertyMap
        0x16 => idxWidth(counts[0x17]), // PropertyPtr
        0x17 => 2 + s2 + b2, // Property (its Type is a blob index)
        0x18 => 2 + idxWidth(counts[tables.methoddef]) + codedSize(has_semantics, 1), // MethodSemantics
        0x19 => idxWidth(counts[0x02]) + 2 * codedSize(method_def_or_ref, 1), // MethodImpl
        0x1a => s2, // ModuleRef
        0x1b => b2, // TypeSpec
        0x1c => 2 + codedSize(member_forwarded, 1) + s2 + idxWidth(counts[0x1a]), // ImplMap
        0x1d => 4 + idxWidth(counts[0x04]), // FieldRva
        0x1e => 8, // ENCLog
        0x1f => 4, // ENCMap
        0x20 => 4 + 8 + 4 + b2 + s2 + s2, // Assembly: hashalg, 4 version u16s, flags, public key, name, culture
        0x21 => 4, // AssemblyProcessor
        0x22 => 12, // AssemblyOS
        0x23 => 8 + 4 + b2 + s2 + s2 + b2, // AssemblyRef: 4 version u16s, flags, public key/token, name, culture, hash
        0x24 => 4 + idxWidth(counts[0x23]), // AssemblyRefProcessor
        0x25 => 12 + idxWidth(counts[0x23]), // AssemblyRefOS
        0x26 => 4 + s2 + b2, // File
        0x27 => 4 + 4 + 2 * s2 + codedSize(implementation, 2), // ExportedType
        0x28 => 4 + 4 + s2 + codedSize(implementation, 2), // ManifestResource
        0x29 => 2 * idxWidth(counts[0x02]), // NestedClass
        0x2a => 2 + 2 + codedSize(type_or_method_def, 1) + s2, // GenericParam: TypeDef=0, MethodDef=1 (1-bit tag)
        0x2b => codedSize(method_def_or_ref, 1) + b2, // MethodSpec
        0x2c => idxWidth(counts[0x2a]) + codedSize(type_def_or_ref, 2), // GenericParamConstraint
        else => 0, // reserved table numbers never appear in a valid mask
    };
}

fn maxCount(counts: [64]u32, comptime ts: []const u32) u32 {
    var mx: u32 = 0;
    inline for (ts) |t| mx = @max(mx, counts[t]);
    return mx;
}

fn resolutionScopeMax(counts: [64]u32) u32 {
    return maxCount(counts, &.{ 0x00, 0x1a, 0x23, 0x01 });
}

fn typedefOrRefMax(counts: [64]u32) u32 {
    return maxCount(counts, &.{ 0x02, 0x01, 0x1b });
}

/// Plain table index width: 2 bytes when the table has fewer than 2^16 rows.
fn idxWidth(count: u32) u32 {
    return if (count < 0x10000) 2 else 4;
}

fn codedSize(max_count: u32, tag_bits: u32) u32 {
    return if (max_count >= (@as(u32, 1) << @as(u5, @intCast(16 - tag_bits)))) 4 else 2;
}

/// A reader positioned at the start of one table row.
fn rowReader(td: *const TableData, t: u32, row: u32) streams.Reader {
    const start = td.offsets[t] + (row - 1) * td.row_sizes[t];
    const end = @min(start + td.row_sizes[t], td.bytes.len);
    return streams.Reader.init(td.bytes[start..end]);
}

/// Reads a coded index: `tag_bits` low bits tag which table, rest is the
/// 1-based row number. The width is 4 bytes when any tagged table has >=
/// 2^(16-tag_bits) rows (ECMA-335 II.24.2.6), matching tableRowSize.
fn readCoded(r: *streams.Reader, tag_bits: u8, tag_tables: []const u32, heaps: *const Heaps) Error!u32 {
    var max: u32 = 0;
    for (tag_tables) |t| max = @max(max, heaps.table_counts[t]);
    const size: usize = if (max >= (@as(u32, 1) << @as(u5, @intCast(16 - tag_bits)))) 4 else 2;
    const raw: u32 = if (size == 4) try r.readInt(u32) else try r.readInt(u16);
    return raw;
}

// ---------------------------------------------------------------------------
// Field signatures
// ---------------------------------------------------------------------------

/// Reads an ECMA-335 compressed unsigned integer (the encoding used for
/// blob-length prefixes and for coded indices inside signatures).
fn readCompressed(r: *streams.Reader) Error!u32 {
    const b0 = try r.readByte();
    if (b0 < 0x80) return b0;
    if ((b0 & 0xc0) == 0x80) {
        return (@as(u32, b0 & 0x3f) << 8) | try r.readByte();
    }
    if ((b0 & 0xe0) == 0xc0) {
        const v = (@as(u32, b0 & 0x1f) << 24) |
            (@as(u32, try r.readByte()) << 16) |
            (@as(u32, try r.readByte()) << 8) |
            try r.readByte();
        return v;
    }
    return error.Corrupt;
}

/// Resolves a TypeDefOrRef coded value to a full type name.
fn resolveTypeName(arena: std.mem.Allocator, coded: u32, td: *const TableData, heaps: *const Heaps) Error![]const u8 {
    const tag = coded & 0x3;
    const row = coded >> 2;
    switch (tag) {
        0 => { // TypeDef
            if (row == 0 or row > td.row_counts[tables.typedef]) return arena.dupe(u8, "?TypeDef");
            var r = rowReader(td, tables.typedef, row);
            try r.skip(4); // flags
            const name = try readString(&r, heaps);
            const ns = try readString(&r, heaps);
            return if (ns.len != 0) std.fmt.allocPrint(arena, "{s}.{s}", .{ ns, name }) else arena.dupe(u8, name);
        },
        1 => { // TypeRef
            if (row == 0 or row > td.row_counts[tables.typeref]) return arena.dupe(u8, "?TypeRef");
            var r = rowReader(td, tables.typeref, row);
            try r.skip(codedSize(resolutionScopeMaxFromHeaps(heaps), 2));
            const name = try readString(&r, heaps);
            const ns = try readString(&r, heaps);
            return if (ns.len != 0) std.fmt.allocPrint(arena, "{s}.{s}", .{ ns, name }) else arena.dupe(u8, name);
        },
        else => { // TypeSpec: a signature blob naming the constructed type
            if (row == 0 or row > td.row_counts[tables.typespec]) return arena.dupe(u8, "TypeSpec");
            const blob = try typeSpecBlob(td, heaps, row);
            var r = streams.Reader.init(blob);
            return readTypeName(arena, &r, td, heaps);
        },
    }
}

fn typeSpecBlob(td: *const TableData, heaps: *const Heaps, row: u32) Error![]const u8 {
    // TypeSpec row: one blob index (sized like a blob heap index).
    var r = rowReader(td, tables.typespec, row);
    return readBlob(&r, heaps);
}

fn resolutionScopeMaxFromHeaps(heaps: *const Heaps) u32 {
    return @max(@max(heaps.table_counts[0x00], heaps.table_counts[0x1a]), @max(heaps.table_counts[tables.assemblyref], heaps.table_counts[tables.typeref]));
}

/// Reads one type from a signature cursor and names it. Handles primitives,
/// class/valuetype (compressed coded indices), szarray, and genericinst.
fn readTypeName(arena: std.mem.Allocator, r: *streams.Reader, td: *const TableData, heaps: *const Heaps) Error![]const u8 {
    const e = try r.readByte();
    switch (e) {
        element.class, element.valuetype => {
            const coded = try readCompressed(r);
            return resolveTypeName(arena, coded, td, heaps);
        },
        element.szarray => {
            const base = try readTypeName(arena, r, td, heaps);
            return std.fmt.allocPrint(arena, "{s}[]", .{base});
        },
        element.genericinst => {
            const gtype = try readTypeName(arena, r, td, heaps);
            const arity = try readCompressed(r);
            var i: u32 = 0;
            while (i < arity) : (i += 1) _ = try readTypeName(arena, r, td, heaps);
            if (arity == 0) return gtype;
            return std.fmt.allocPrint(arena, "{s}<{d}>", .{ gtype, arity });
        },
        else => {
            const prim = elementTypeName(e);
            if (prim.len != 0) return arena.dupe(u8, prim);
            // uncommon signature element types (byref, var, mvar, fnptr...):
            // name them from a scratch buffer, owned by the arena
            var name_buf: [16]u8 = undefined;
            const nm = std.fmt.bufPrint(&name_buf, "type{x}", .{e}) catch return arena.dupe(u8, "?");
            return arena.dupe(u8, nm);
        },
    }
}

/// Parses a field signature blob (0x06 + type). `resolve` names
/// class/valuetype entries.
fn parseFieldSig(arena: std.mem.Allocator, blob: []const u8, td: *const TableData, heaps: *const Heaps) Error!Field {
    var r = streams.Reader.init(blob);
    const sig_kind = try r.readByte();
    if (sig_kind != 0x06) return error.Corrupt;
    const e = try r.readByte();
    var field = Field{ .name = "", .flags = 0, .elem_type = e };
    switch (e) {
        element.class, element.valuetype => {
            const coded = try readCompressed(&r);
            field.type_name = try resolveTypeName(arena, coded, td, heaps);
        },
        element.szarray => {
            field.type_name = try readTypeName(arena, &r, td, heaps);
            field.elem_type = element.szarray;
        },
        element.genericinst => {
            field.type_name = try readTypeName(arena, &r, td, heaps);
            const arity = try readCompressed(&r);
            var gi: u32 = 0;
            while (gi < arity) : (gi += 1) {
                const arg = try readTypeName(arena, &r, td, heaps);
                if (gi == 0) {
                    field.generic_arg = arg;
                } else if (gi == 1) {
                    field.generic_arg2 = arg;
                }
            }
        },
        else => {},
    }
    return field;
}

// ---------------------------------------------------------------------------
// Assembly-level parse
// ---------------------------------------------------------------------------

pub fn parseAssembly(arena: std.mem.Allocator, name: []const u8, bytes: []const u8) Error!Assembly {
    const sections = try parsePeSections(bytes, arena);

    // optional header data directory 14 = CLI header
    var r = streams.Reader.init(bytes);
    try r.seek(0x3C);
    const e_lfanew = try r.readInt(u32);
    try r.seek(e_lfanew + 4);
    try r.skip(4); // machine + num sections
    try r.skip(4); // timestamp
    try r.skip(8); // symbol table
    const opt_size = try r.readInt(u16);
    try r.skip(2); // characteristics
    try r.seek(e_lfanew + 24); // optional header start
    const magic = try r.readInt(u16);
    const dd_offset: usize = if (magic == 0x010b)
        e_lfanew + 24 + 96
    else if (magic == 0x020b)
        e_lfanew + 24 + 112
    else
        return error.NotPe;
    _ = opt_size;
    try r.seek(dd_offset + 14 * 8);
    const cli_rva = try r.readInt(u32);
    try r.skip(4); // cli size
    const cli_off = rvaToOffset(cli_rva, sections) orelse return error.NoCliHeader;
    if (cli_off + 16 > bytes.len) return error.NoCliHeader;

    try r.seek(cli_off + 8); // metadata RVA/size at CLI header offset 8
    const meta_rva = try r.readInt(u32);
    try r.skip(4); // metadata size
    const meta_off = rvaToOffset(meta_rva, sections) orelse return error.NoMetadata;

    var heaps: Heaps = .{};
    var table_data: TableData = .{ .bytes = &.{} };
    {
        var mr = streams.Reader.init(bytes[meta_off..]);
        const sig = try mr.readInt(u32);
        if (sig != 0x424a_5342) return error.NoMetadata; // "BSJB"
        try mr.skip(4); // major + minor (2 bytes each)
        try mr.skip(4); // reserved
        const ver_len = try mr.readInt(u32);
        try mr.skip(ver_len);
        try mr.skip(2); // flags
        const num_streams = try mr.readInt(u16);
        var n: usize = 0;
        while (n < num_streams) : (n += 1) {
            const off = try mr.readInt(u32);
            const size = try mr.readInt(u32);
            const name_start = mr.position();
            while (try mr.readByte() != 0) {}
            const name_end = mr.position() - 1;
            const sname = bytes[meta_off + name_start .. meta_off + name_end];
            const sb = bytes[meta_off + off .. meta_off + off + size];
            if (std.mem.eql(u8, sname, "#Strings")) {
                heaps.strings = sb;
            } else if (std.mem.eql(u8, sname, "#Blob")) {
                heaps.blob = sb;
            } else if (std.mem.eql(u8, sname, "#GUID")) {
                // unused by this reader, but present in real assemblies
            } else if (std.mem.eql(u8, sname, "#~") or std.mem.eql(u8, sname, "#-")) {
                table_data = try parseTableStream(sb, &heaps);
            }
            // streams are 4-aligned
            const pos = mr.position();
            try mr.seek((pos + 3) & ~@as(usize, 3));
        }
    }
    if (heaps.strings.len == 0) return error.NoMetadata;

    const n_typedefs = table_data.row_counts[tables.typedef];
    const type_defs = try arena.alloc(TypeDef, n_typedefs);
    for (type_defs) |*d| d.* = .{ .name = "", .namespace = "", .flags = 0, .fields = &.{} };
    const method_starts = try arena.alloc(u32, n_typedefs + 1);
    @memset(method_starts, 0);

    var i: u32 = 0;
    while (i < n_typedefs) : (i += 1) {
        var rr = rowReader(&table_data, tables.typedef, i + 1);
        const flags = try rr.readInt(u32);
        const tname = try readString(&rr, &heaps);
        const tns = try readString(&rr, &heaps);
        const extends = try readCoded(&rr, 2, &.{ tables.typedef, tables.typeref, tables.typespec }, &heaps);
        const field_list = if (idxWidth(table_data.row_counts[tables.field]) == 4) try rr.readInt(u32) else try rr.readInt(u16);
        const method_list = if (idxWidth(table_data.row_counts[tables.methoddef]) == 4) try rr.readInt(u32) else try rr.readInt(u16);
        const type_defs_count = table_data.row_counts[tables.typedef];
        const next_field_list = if (i + 1 < type_defs_count) blk: {
            var nr = rowReader(&table_data, tables.typedef, i + 2);
            const s_width: usize = if ((heaps.heap_sizes & 1) != 0) 4 else 2;
            try nr.skip(4 + 2 * s_width + @as(usize, codedSize(typedefOrRefMax(table_data.row_counts), 2)));
            break :blk if (idxWidth(table_data.row_counts[tables.field]) == 4) try nr.readInt(u32) else try nr.readInt(u16);
        } else table_data.row_counts[tables.field] + 1;

        type_defs[i] = .{
            .name = tname,
            .namespace = tns,
            .flags = flags,
            .fields = &.{},
            .base_name = null,
            .extends_coded = extends,
        };
        method_starts[i] = method_list;

        // fields: rows [field_list, next_field_list)
        if (field_list == 0 or field_list > table_data.row_counts[tables.field]) continue;
        const field_end = @min(next_field_list, table_data.row_counts[tables.field] + 1);
        if (field_end <= field_list) continue;
        const count: usize = @intCast(field_end - field_list);
        const fields = try arena.alloc(Field, count);
        var fi: u32 = 0;
        while (fi < count) : (fi += 1) {
            var fr = rowReader(&table_data, tables.field, field_list + fi);
            const fflags = try fr.readInt(u16);
            const fname = try readString(&fr, &heaps);
            const sig_blob = try readBlob(&fr, &heaps);
            fields[fi] = parseFieldSig(arena, sig_blob, &table_data, &heaps) catch .{ .name = fname, .flags = fflags, .elem_type = 0 };
            fields[fi].name = fname;
            fields[fi].flags = fflags;
            fields[fi].row = field_list + fi;
        }
        type_defs[i].fields = fields;
    }

    if (n_typedefs > 0) {
        // the sentinel: the first method row past the last type's range
        var nr = rowReader(&table_data, tables.typedef, n_typedefs);
        const s_width: usize = if ((heaps.heap_sizes & 1) != 0) 4 else 2;
        try nr.skip(4 + 2 * s_width + @as(usize, codedSize(typedefOrRefMax(table_data.row_counts), 2)) + @as(usize, idxWidth(table_data.row_counts[tables.field])));
        method_starts[n_typedefs] = if (idxWidth(table_data.row_counts[tables.methoddef]) == 4) try nr.readInt(u32) else try nr.readInt(u16);
    }

    // resolve base names (TypeDef rows may reference other TypeDefs)
    for (type_defs) |*d| {
        if (d.extends_coded == 0) continue;
        const tag = d.extends_coded & 0x3;
        const row = d.extends_coded >> 2;
        if (tag == 0) {
            if (row > 0 and row <= n_typedefs) {
                const base = type_defs[row - 1];
                d.base_name = try std.fmt.allocPrint(arena, "{s}", .{base.fullName(arena)});
            }
        } else if (tag == 1) {
            if (row > 0 and row <= table_data.row_counts[tables.typeref]) {
                var tr = rowReader(&table_data, tables.typeref, row);
                try tr.skip(codedSize(resolutionScopeMax(table_data.row_counts), 2));
                const tname = try readString(&tr, &heaps);
                const tns = try readString(&tr, &heaps);
                d.base_name = if (tns.len != 0)
                    try std.fmt.allocPrint(arena, "{s}.{s}", .{ tns, tname })
                else
                    try arena.dupe(u8, tname);
            }
        } else if (tag == 2) {
            // TypeSpec extends: the base is a constructed generic type
            // (`class X : Base<Arg>`), e.g. Stranded Deep's netcode classes
            // deriving through `Funlabs.MultiplayerBehaviour`1` whose own
            // base is `Photon.Bolt.EntityEventListener`1<...>`. Name the
            // base after the generic type itself (no argument decoration)
            // so Object-derived detection can keep walking the chain
            // across assemblies.
            if (row > 0 and row <= table_data.row_counts[tables.typespec]) {
                const blob = typeSpecBlob(&table_data, &heaps, row) catch null;
                if (blob) |b| {
                    var sr = streams.Reader.init(b);
                    // genericinst signature: 0x15, class/valuetype marker,
                    // then the generic type's TypeDefOrRefEncoded.
                    const e0 = sr.readByte() catch 0;
                    if (e0 == 0x15) {
                        const marker = sr.readByte() catch 0;
                        if (marker == element.class or marker == element.valuetype) {
                            const coded = readCompressed(&sr) catch 0;
                            if (coded != 0) d.base_name = resolveTypeName(arena, coded, &table_data, &heaps) catch null;
                        }
                    }
                }
            }
        }
    }

    // custom-attribute marks per field row, read from the CustomAttribute
    // table: [SerializeField] pulls private fields in; [NonSerialized]
    // (rarely emitted as an attribute row — the C# compiler encodes it as
    // the fdNotSerialized field flag, handled in collectFields) pushes
    // public ones out. [HideInInspector] marks nothing here: it hides a
    // field in the editor but Unity still serializes it.
    const n_fields = table_data.row_counts[tables.field];
    const serialized_rows = try arena.alloc(bool, n_fields);
    const nonserialized_rows = try arena.alloc(bool, n_fields);
    @memset(serialized_rows, false);
    @memset(nonserialized_rows, false);
    // [Serializable] per TypeDef row: a single plain-class field serializes
    // inline only when its class carries it (arrays of plain classes
    // serialize regardless, so the array path ignores this mark).
    const type_serializable = try arena.alloc(bool, n_typedefs);
    @memset(type_serializable, false);
    if (n_typedefs > 0 and table_data.row_counts[tables.customattr] > 0) {
        var ci: u32 = 0;
        while (ci < table_data.row_counts[tables.customattr]) : (ci += 1) {
            var cr = rowReader(&table_data, tables.customattr, ci + 1);
            const parent = try readCoded(&cr, 5, &hasCustomAttrTagTables(), &heaps);
            const tag = parent & 0x1f;
            const trow = parent >> 5;
            if (tag == 1) { // Field parent
                if (trow == 0 or trow > n_fields) continue;
                const typ = try readCoded(&cr, 3, &.{ tables.methoddef, tables.memberref }, &heaps);
                const attr = try resolveAttributeName(arena, typ, &table_data, &heaps, method_starts, n_typedefs);
                if (attr) |a| {
                    if (std.mem.eql(u8, a, "UnityEngine.SerializeFieldAttribute") or std.mem.eql(u8, a, "UnityEngine.SerializeField")) {
                        serialized_rows[trow - 1] = true;
                    } else if (std.mem.eql(u8, a, "System.NonSerializedAttribute")) {
                        // [NonSerialized] is the only marker that stops Unity
                        // writing a public field; [HideInInspector] hides it
                        // from the editor but still serializes it.
                        nonserialized_rows[trow - 1] = true;
                    }
                }
            } else if (tag == 3) { // TypeDef parent
                if (trow == 0 or trow > n_typedefs) continue;
                const typ = try readCoded(&cr, 3, &.{ tables.methoddef, tables.memberref }, &heaps);
                const attr = try resolveAttributeName(arena, typ, &table_data, &heaps, method_starts, n_typedefs);
                if (attr) |a| {
                    if (std.mem.eql(u8, a, "System.SerializableAttribute")) {
                        type_serializable[trow - 1] = true;
                    }
                }
            }
        }
    }
    return .{ .name = name, .type_defs = type_defs, .field_serialized = serialized_rows, .field_nonserialized = nonserialized_rows, .type_serializable = type_serializable };
}

/// The tables tagged by the HasCustomAttribute coded index (5 bits), for
/// sizing. The 22-entry list follows ECMA-335 II.24.2.6.
fn hasCustomAttrTagTables() [22]u32 {
    return .{ 0x06, 0x04, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x00, 0x0e, 0x17, 0x14, 0x11, 0x1a, 0x1b, 0x20, 0x23, 0x26, 0x27, 0x28, 0x2a, 0x2c, 0x2b };
}

/// The tables tagged by the MemberRefParent coded index (3 bits).
fn memberRefParentTagTables() [5]u32 {
    return .{ tables.typedef, tables.typeref, 0x1a, tables.methoddef, tables.typespec };
}

/// Resolves a CustomAttributeType coded value to the attribute class's full
/// name: MethodDef (the .ctor lives in this assembly) or MemberRef (the
/// .ctor is imported, its class is a TypeRef/TypeDef).
fn resolveAttributeName(
    arena: std.mem.Allocator,
    typ: u32,
    td: *const TableData,
    heaps: *const Heaps,
    method_starts: []const u32,
    n_typedefs: u32,
) Error!?[]const u8 {
    const tag = typ & 0x7;
    const row = typ >> 3;
    switch (tag) {
        2 => { // MethodDef: find the containing TypeDef via method ranges
            if (row == 0 or row > td.row_counts[tables.methoddef]) return null;
            var lo: usize = 0;
            var hi: usize = n_typedefs;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (method_starts[mid] <= row) lo = mid + 1 else hi = mid;
            }
            if (lo == 0) return null;
            const tdi = lo - 1;
            var r = rowReader(td, tables.typedef, @as(u32, @intCast(tdi)) + 1);
            try r.skip(4); // flags
            const tname = try readString(&r, heaps);
            const tns = try readString(&r, heaps);
            return if (tns.len != 0) try std.fmt.allocPrint(arena, "{s}.{s}", .{ tns, tname }) else try arena.dupe(u8, tname);
        },
        3 => { // MemberRef: its Class names the attribute type
            if (row == 0 or row > td.row_counts[tables.memberref]) return null;
            var mr = rowReader(td, tables.memberref, row);
            const cls = try readCoded(&mr, 3, &memberRefParentTagTables(), heaps);
            const ct = cls & 0x7;
            const crow = cls >> 3;
            if (ct == 0) { // TypeDef
                if (crow == 0 or crow > td.row_counts[tables.typedef]) return null;
                var r = rowReader(td, tables.typedef, crow);
                try r.skip(4);
                const tname = try readString(&r, heaps);
                const tns = try readString(&r, heaps);
                return if (tns.len != 0) try std.fmt.allocPrint(arena, "{s}.{s}", .{ tns, tname }) else try arena.dupe(u8, tname);
            } else if (ct == 1) { // TypeRef
                if (crow == 0 or crow > td.row_counts[tables.typeref]) return null;
                var r = rowReader(td, tables.typeref, crow);
                try r.skip(codedSize(resolutionScopeMax(td.row_counts), 2));
                const tname = try readString(&r, heaps);
                const tns = try readString(&r, heaps);
                return if (tns.len != 0) try std.fmt.allocPrint(arena, "{s}.{s}", .{ tns, tname }) else try arena.dupe(u8, tname);
            }
            return null;
        },
        else => return null,
    }
}

/// Whether a type derives (transitively) from `UnityEngine.MonoBehaviour`.
/// Same-assembly bases are followed by name; external bases match the
/// qualified name.
pub fn isMonoBehaviour(arena: std.mem.Allocator, td: TypeDef, type_defs: []const TypeDef) bool {
    var seen: usize = 0;
    var current: ?TypeDef = td;
    while (current) |c| {
        if (seen > 64) return false; // cycle guard
        seen += 1;
        const base = c.base_name orelse return false;
        if (std.mem.eql(u8, base, "MonoBehaviour") or std.mem.endsWith(u8, base, ".MonoBehaviour")) return true;
        // same-assembly base: find it and continue the walk
        var found: ?TypeDef = null;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "readCompressed decodes the 1/2/4-byte forms" {
    var r = streams.Reader.init(&[_]u8{0x7f});
    try std.testing.expectEqual(@as(u32, 0x7f), try readCompressed(&r));
    r = streams.Reader.init(&[_]u8{ 0x80, 0x01 });
    try std.testing.expectEqual(@as(u32, 0x01), try readCompressed(&r));
    r = streams.Reader.init(&[_]u8{ 0xbf, 0xff });
    try std.testing.expectEqual(@as(u32, 0x3fff), try readCompressed(&r));
    r = streams.Reader.init(&[_]u8{ 0xc0, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u32, 0), try readCompressed(&r));
    r = streams.Reader.init(&[_]u8{ 0xdf, 0xff, 0xff, 0xff });
    try std.testing.expectEqual(@as(u32, 0x1fff_ffff), try readCompressed(&r));
}

test "readBlob decodes length-prefixed heap entries" {
    // Three 2-byte index slots pointing at entries with 1/2/4-byte lengths.
    const heap = [_]u8{
        0x06, 0x00, // idx 0 -> entry at 6
        0x0a, 0x00, // idx 1 -> entry at 10
        0x10, 0x00, // idx 2 -> entry at 16
        0x03, 0xaa, 0xbb, 0xcc, // len 3
        0x80, 0x04, 1, 2, 3, 4, // 2-byte len 4
        0xc0, 0x00, 0x00, 0x05, 5, 6, 7, 8, 9, // 4-byte len 5
    };
    var heaps: Heaps = .{ .blob = &heap, .heap_sizes = 0 };
    var r = streams.Reader.init(&heap);
    const b1 = try readBlob(&r, &heaps);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, b1);
    r = streams.Reader.init(&heap);
    try r.seek(2);
    const b2 = try readBlob(&r, &heaps);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, b2);
    r = streams.Reader.init(&heap);
    try r.seek(4);
    const b3 = try readBlob(&r, &heaps);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 9 }, b3);
}

test "elementTypeName maps the CLR primitives" {
    try std.testing.expectEqualStrings("bool", elementTypeName(element.boolean));
    try std.testing.expectEqualStrings("int", elementTypeName(element.t_i4));
    try std.testing.expectEqualStrings("float", elementTypeName(element.r4));
    try std.testing.expectEqualStrings("string", elementTypeName(element.string));
    try std.testing.expectEqualStrings("", elementTypeName(element.class));
}

test "parseTableStream sizes rows and offsets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bw = streams.Writer.init(a);
    try bw.writeIntWith(u32, 0, .little); // reserved
    try bw.writeByte(2); // major
    try bw.writeByte(5); // minor
    try bw.writeByte(0x05); // heap sizes: strings + blob 4-byte
    try bw.writeByte(1); // reserved
    try bw.writeIntWith(u64, 0x17, .little); // valid: Module, TypeRef, TypeDef, Field
    try bw.writeIntWith(u64, 0, .little); // sorted
    try bw.writeIntWith(u32, 1, .little); // Module count
    try bw.writeIntWith(u32, 1, .little); // TypeRef count
    try bw.writeIntWith(u32, 2, .little); // TypeDef count
    try bw.writeIntWith(u32, 2, .little); // Field count
    // Module row (12): generation, name, mvid, encid, encbaseid
    try bw.writeIntWith(u16, 0, .little);
    try bw.writeIntWith(u32, 1, .little);
    try bw.writeIntWith(u16, 1, .little);
    try bw.writeIntWith(u16, 0, .little);
    try bw.writeIntWith(u16, 0, .little);
    // TypeRef row (10): scope coded(2), name(4), ns(4)
    try bw.writeIntWith(u16, 0, .little);
    try bw.writeIntWith(u32, 5, .little);
    try bw.writeIntWith(u32, 9, .little);
    // TypeDef row 1: <Module> (18)
    try bw.writeIntWith(u32, 0, .little);
    try bw.writeIntWith(u32, 1, .little);
    try bw.writeIntWith(u32, 0, .little);
    try bw.writeIntWith(u16, 0, .little);
    try bw.writeIntWith(u16, 1, .little);
    try bw.writeIntWith(u16, 1, .little);
    // TypeDef row 2: MyBehaviour extends TypeRef 1 (coded 5)
    try bw.writeIntWith(u32, 0, .little);
    try bw.writeIntWith(u32, 13, .little);
    try bw.writeIntWith(u32, 18, .little);
    try bw.writeIntWith(u16, 5, .little);
    try bw.writeIntWith(u16, 1, .little);
    try bw.writeIntWith(u16, 1, .little);
    // Field rows (10 each): flags(2), name(4), sig(4)
    try bw.writeIntWith(u16, 0x6, .little);
    try bw.writeIntWith(u32, 22, .little);
    try bw.writeIntWith(u32, 0, .little);
    try bw.writeIntWith(u16, 0x6, .little);
    try bw.writeIntWith(u32, 26, .little);
    try bw.writeIntWith(u32, 3, .little);

    var heaps: Heaps = .{};
    const td = try parseTableStream(bw.getWritten(), &heaps);
    try std.testing.expectEqual(@as(u32, 1), td.row_counts[0]);
    try std.testing.expectEqual(@as(u32, 1), td.row_counts[tables.typeref]);
    try std.testing.expectEqual(@as(u32, 2), td.row_counts[tables.typedef]);
    try std.testing.expectEqual(@as(u32, 2), td.row_counts[tables.field]);
    try std.testing.expectEqual(@as(u32, 12), td.row_sizes[0]);
    try std.testing.expectEqual(@as(u32, 10), td.row_sizes[tables.typeref]);
    try std.testing.expectEqual(@as(u32, 18), td.row_sizes[tables.typedef]);
    try std.testing.expectEqual(@as(u32, 10), td.row_sizes[tables.field]);
    // rows start after the 24-byte header + 4 counts
    const rows_start: u32 = 24 + 4 * 4;
    try std.testing.expectEqual(rows_start, td.offsets[0]);
    try std.testing.expectEqual(rows_start + 12, td.offsets[tables.typeref]);
    try std.testing.expectEqual(rows_start + 12 + 10, td.offsets[tables.typedef]);
    try std.testing.expectEqual(rows_start + 12 + 10 + 36, td.offsets[tables.field]);
}

/// Row-count profile like Raft's Assembly-CSharp (MethodDef and Field over
/// 2^14 rows, so every coded index that can tag them is 4 bytes wide).
fn raftLikeCounts() [64]u32 {
    var counts: [64]u32 = [_]u32{0} ** 64;
    counts[0x00] = 1; // Module
    counts[0x01] = 666; // TypeRef
    counts[0x02] = 3033; // TypeDef
    counts[0x04] = 16920; // Field
    counts[tables.methoddef] = 19512;
    counts[0x08] = 14625; // Param
    counts[0x09] = 714; // InterfaceImpl
    counts[tables.memberref] = 5693;
    counts[0x0b] = 2643; // Constant
    counts[tables.customattr] = 7678;
    return counts;
}

test "tableRowSize: Param rows have three columns, not four" {
    // Regression: a phantom MethodDef index made Param rows 10 bytes; the
    // real width is 8 (flags + sequence + name). 14625 x 2 over-charged
    // bytes silently shifted every later table (CustomAttribute ended up
    // 0x7242 bytes late, so its rows read as garbage).
    const counts = raftLikeCounts();
    var heaps: Heaps = .{ .heap_sizes = 5 };
    try std.testing.expectEqual(@as(u32, 8), tableRowSize(0x08, counts, &heaps));
    try std.testing.expectEqual(@as(u32, 18), tableRowSize(tables.methoddef, counts, &heaps));
    // CustomAttribute rows must land byte-exact: hasCustomAttr 5-bit coded
    // (4) + type 3-bit coded (4) + blob index (4).
    try std.testing.expectEqual(@as(u32, 12), tableRowSize(tables.customattr, counts, &heaps));
    // Cumulative spans through Constant are content-verified against
    // Raft's Assembly-CSharp: rows begin 0x90 into the #~ stream and the
    // CustomAttribute table starts at stream offset 0xc270c, so the span
    // sum before it is 0xc270c - 0x90.
    try std.testing.expectEqual(@as(u32, 0xc267c), cumulativeSpanBefore(tables.customattr, counts, &heaps));
}

test "tableRowSize: CustomAttributeType tag needs 3 bits (tags 2/3/4)" {
    // With max(methoddef, memberref) between 2^13 and 2^14 rows the type
    // column is 4 bytes wide: sizing it as a 2-bit coded index (threshold
    // 2^14) would under-size the row by 2 bytes.
    var counts: [64]u32 = [_]u32{0} ** 64;
    counts[0x00] = 1;
    counts[0x02] = 1000;
    counts[0x04] = 1000;
    counts[tables.methoddef] = 10000;
    counts[0x08] = 1000;
    counts[tables.customattr] = 500;
    var heaps: Heaps = .{ .heap_sizes = 5 };
    // hasCustomAttr (5-bit, threshold 2^11) -> 4; type (3-bit, threshold
    // 2^13 -> 10000 >= 8192) -> 4; blob -> 4.
    try std.testing.expectEqual(@as(u32, 12), tableRowSize(tables.customattr, counts, &heaps));
}

test "readCoded sizes coded indices from row counts, not byte widths" {
    // The old code compared table_sizes (2 or 4) against the coded-index
    // threshold, so a tagged table with 16384..65535 rows was misread as a
    // 2-byte index even though the column is 4 bytes wide.
    var heaps: Heaps = .{ .heap_sizes = 5 };
    var buf: [8]u8 = [_]u8{ 0x21, 0x00, 0x00, 0x00, 0xaa, 0xbb, 0xcc, 0xdd };
    // methoddef = 19512 rows >= 2^(16-5): the HasCustomAttribute parent
    // column is 4 bytes, so a full u32 must be consumed.
    heaps.table_counts[tables.methoddef] = 19512;
    var r = streams.Reader.init(&buf);
    try std.testing.expectEqual(@as(u32, 0x21), try readCoded(&r, 5, &.{tables.methoddef}, &heaps));
    // Small table (< 2^(16-5) rows): the same value is a 2-byte index.
    heaps.table_counts[tables.methoddef] = 100;
    r = streams.Reader.init(&buf);
    try std.testing.expectEqual(@as(u32, 0x21), try readCoded(&r, 5, &.{tables.methoddef}, &heaps));
}

/// Sums the byte spans of every table strictly before `target` (what
/// parseTableStream adds up to place the target table's first row, not
/// counting the #~ header that precedes the first table).
fn cumulativeSpanBefore(target: u32, counts: [64]u32, heaps: *const Heaps) u32 {
    var off: u32 = 0;
    var t: u32 = 0;
    while (t < target) : (t += 1) {
        if (counts[t] == 0) continue;
        off += tableRowSize(t, counts, heaps) * counts[t];
    }
    return off;
}

/// The serialized-visible fields of a class, base classes first: Unity
/// serializes base fields before derived ones, and only instance fields
/// that are public (unless [NonSerialized]) or carry [SerializeField],
/// never static or const. [NonSerialized] shows up two ways: the
/// System.NonSerializedAttribute custom attribute, or the fdNotSerialized
/// field flag the C# compiler emits for it — both stop Unity writing the
/// field, so both exclude it here.
pub fn collectFields(arena: std.mem.Allocator, td: TypeDef, type_defs: []const TypeDef, serialized_rows: []const bool, nonserialized_rows: []const bool) ![]const Field {
    // walk the same-assembly base chain into a stack
    var chain: [64]TypeDef = undefined;
    var n: usize = 0;
    var current: ?TypeDef = td;
    while (current) |c| {
        if (n >= chain.len) break;
        chain[n] = c;
        n += 1;
        const base = c.base_name orelse break;
        var found: ?TypeDef = null;
        for (type_defs) |d| {
            if (std.mem.eql(u8, d.fullName(arena), base)) {
                found = d;
                break;
            }
        }
        if (found == null) break;
        current = found;
    }
    var out: std.ArrayList(Field) = .empty;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        for (chain[i].fields) |f| {
            if (f.isStatic() or f.isLiteral()) continue;
            const serialized = f.row != 0 and f.row <= serialized_rows.len and serialized_rows[f.row - 1];
            const attr_nonserialized = f.row != 0 and f.row <= nonserialized_rows.len and nonserialized_rows[f.row - 1];
            if (f.isNotSerialized() or attr_nonserialized) continue;
            if (f.isPublic()) {
                try out.append(arena, f);
            } else if (serialized) {
                try out.append(arena, f);
            }
        }
    }
    return out.toOwnedSlice(arena);
}
