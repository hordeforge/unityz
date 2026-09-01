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
    /// CLR field flags: 0x6 = public, 0x10 = static, 0x20 = literal.
    flags: u16,
    /// ECMA-335 element type byte of the field signature (ELEMENT_TYPE_*).
    elem_type: u8,
    /// Resolved type name for class/valuetype/szarray signatures
    /// ("System.String", "UnityEngine.Vector3", "System.Int32[]", ...);
    /// empty for the plain primitives (named by `elementTypeName`).
    type_name: []const u8 = "",

    pub fn isPublic(self: Field) bool {
        return (self.flags & 0x6) == 0x6;
    }
    pub fn isStatic(self: Field) bool {
        return (self.flags & 0x10) != 0;
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
    /// table row-count widths (2 or 4), set from the #~ row counts
    table_sizes: [64]u8 = [_]u8{0} ** 64,
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

const tables = struct {
    pub const typeref: u32 = 0x01;
    pub const typedef: u32 = 0x02;
    pub const field: u32 = 0x04;
    pub const assemblyref: u32 = 0x20;
    pub const typespec: u32 = 0x1b;
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
        heaps.table_sizes[i] = if (c < 0x10000) 2 else 4;
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

fn tableRowSize(t: u32, counts: [64]u32, heaps: *const Heaps) u32 {
    const sz = heaps.heap_sizes;
    const s2: u32 = if ((sz & 1) != 0) 4 else 2; // strings
    const b2: u32 = if ((sz & 4) != 0) 4 else 2; // blob
    const g2: u32 = if ((sz & 2) != 0) 4 else 2; // guid
    return switch (t) {
        0x00 => 2 + s2 + 3 * g2, // Module: generation, name, mvid, encid, encbaseid
        tables.typeref => 2 * s2 + codedSize(resolutionScopeMax(counts), 2),
        // FieldList / MethodList are plain table indices, 2 bytes when the
        // target table has fewer than 2^16 rows (the common case).
        tables.typedef => 4 + 2 * s2 + codedSize(typedefOrRefMax(counts), 2) + idxWidth(counts[tables.field]) + idxWidth(counts[0x06]),
        tables.field => 2 + s2 + b2,
        tables.assemblyref => 8 + 4 + b2 + s2 + s2 + b2,
        else => 0,
    };
}

fn resolutionScopeMax(counts: [64]u32) u32 {
    return @max(@max(counts[0x00], counts[0x1a]), @max(counts[tables.assemblyref], counts[tables.typeref]));
}

fn typedefOrRefMax(counts: [64]u32) u32 {
    return @max(@max(counts[tables.typedef], counts[tables.typeref]), counts[tables.typespec]);
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
/// 1-based row number.
fn readCoded(r: *streams.Reader, tag_bits: u8, tag_tables: []const u32, heaps: *const Heaps) Error!u32 {
    var max: u32 = 0;
    for (tag_tables) |t| max = @max(max, heaps.table_sizes[t]);
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
    return @max(@max(heaps.table_sizes[0x00], heaps.table_sizes[0x1a]), @max(heaps.table_sizes[tables.assemblyref], heaps.table_sizes[tables.typeref]));
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
            var name_buf: [16]u8 = undefined;
            return std.fmt.bufPrint(&name_buf, "type{x}", .{e}) catch arena.dupe(u8, "?");
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

    var i: u32 = 0;
    while (i < n_typedefs) : (i += 1) {
        var rr = rowReader(&table_data, tables.typedef, i + 1);
        const flags = try rr.readInt(u32);
        const tname = try readString(&rr, &heaps);
        const tns = try readString(&rr, &heaps);
        const extends = try readCoded(&rr, 2, &.{ tables.typedef, tables.typeref, tables.typespec }, &heaps);
        const field_list = if (idxWidth(table_data.row_counts[tables.field]) == 4) try rr.readInt(u32) else try rr.readInt(u16);
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
        }
        type_defs[i].fields = fields;
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
        }
    }

    return .{ .name = name, .type_defs = type_defs };
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
