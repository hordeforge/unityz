//! SerializedFile parser — the core Unity asset format (`.assets`,
//! `.resources`, `level*`, `globalgamemanagers`, ...).
//!
//! Layout (from the public SerializedFile format docs, cross-checked
//! against the wire fixtures of independent implementations):
//!
//! ```text
//! header (always BIG endian):
//!   formats 2-8 (Legacy16):
//!     metadata_size u32, file_size u32, version u32, data_offset u32
//!     endianness byte lives at file_size - metadata_size (start of the
//!     trailing metadata block)
//!   formats 9-21 (Standard20):
//!     + endianness u8, reserved[3]
//!   format 22 (LargeFiles48):
//!     the 20-byte form, then metadata_size u32 (re-read), file_size i64,
//!     data_offset i64, unknown i64 — the 64-bit values override
//!
//! endianness: 0 = little, 1 = big — applies to the metadata and the
//! object data, never to the header itself.
//!
//! metadata (formats 9+ follow the header; formats 2-8 sit at the end of
//! the file after the endian byte), parsed with the file endianness:
//!   unity_version   cstring            version >= 7
//!   target_platform i32                version >= 8
//!   enable_type_tree bool              version >= 13 (implicit before)
//!   type_count i32, SerializedType[] (with embedded TypeTrees when enabled)
//!   big_id_enabled  i32                version 7-13
//!   object_count i32, ObjectInfo[]
//!   script_count i32, script types[]   version >= 11
//!   external_count i32, FileIdentifier[]
//!   ref_count i32, ref types[]         version >= 20
//!   user_information cstring           version >= 5
//!
//! data: objects at data_offset..file_size; each ObjectInfo's byte range
//! is relative to data_offset.
//! ```
//!
//! Everything borrows from the source bytes; the table arrays are
//! allocated from the caller's allocator. Free the allocator (an arena is
//! the intended usage) when the file is no longer needed — there is no
//! per-file `deinit`.

const std = @import("std");
const streams = @import("streams.zig");
const typetree = @import("typetree.zig");

pub const SerializedFile = struct {
    version: u32,
    file_size: u64,
    data_offset: u64,
    metadata_size: u32,
    endian: streams.Endian,
    unknown: i64 = 0,
    unity_version: []const u8 = "",
    target_platform: i32 = 0,
    enable_type_tree: bool = false,
    types: []SerializedType,
    objects: []ObjectInfo,
    script_types: []LocalSerializedObjectIdentifier,
    externals: []FileIdentifier,
    ref_types: []SerializedType,
    user_information: []const u8 = "",
    /// Formats 7-13 store a big-id flag in the metadata that sizes the
    /// path-id field in the object table; kept for rewrites.
    uses_big_ids: bool = false,
    /// The whole source image; object data borrows from it.
    source: []const u8,
    /// Absolute offset of the metadata body in the file (rewrite support).
    metadata_body_offset: usize = 0,
    /// Metadata-relative offset of the object table (rewrite support).
    object_table_offset: usize = 0,
    /// Metadata-relative offset just past the object entries.
    after_objects_offset: usize = 0,

    /// Returns the raw bytes of an object, or null when the declared range
    /// falls outside the file.
    pub fn objectData(self: *const SerializedFile, o: *const ObjectInfo) ?[]const u8 {
        const start: usize = @intCast(o.byte_start);
        const end = start + o.byte_size;
        if (end > self.source.len) return null;
        return self.source[start..end];
    }

    /// Finds an object by path ID.
    pub fn findObject(self: *const SerializedFile, path_id: i64) ?*const ObjectInfo {
        for (self.objects) |*o| {
            if (o.path_id == path_id) return o;
        }
        return null;
    }
};

pub const ObjectInfo = struct {
    path_id: i64,
    /// Absolute byte offset in the file.
    byte_start: u64,
    byte_size: u32,
    class_id: i32,
    /// Index into `SerializedFile.types` when the format stores one.
    type_index: ?u32,
    /// Per-object script identity (formats 11-16) and destroyed flag
    /// (formats 2-10); preserved for byte-exact rewrites.
    script_type_index: i16 = -1,
    stripped: bool = false,
    destroyed: bool = false,
};

pub const SerializedType = struct {
    class_id: i32,
    is_stripped: bool = false,
    script_type_index: i16 = -1,
    script_id: [16]u8 = .{0} ** 16,
    old_type_hash: [16]u8 = .{0} ** 16,
    type_tree: typetree.TypeTree = .{ .version = 0, .roots = &.{} },
    type_dependencies: []i32 = &.{},
    class_name: []const u8 = "",
    namespace: []const u8 = "",
    assembly_name: []const u8 = "",
};

pub const FileIdentifier = struct {
    temp_empty: []const u8 = "",
    guid: [16]u8 = .{0} ** 16,
    type_: i32 = 0,
    path: []const u8 = "",
};

pub const LocalSerializedObjectIdentifier = struct {
    file_index: i32,
    path_id: i64,
};

pub const ParseError = error{
    ShortData,
    UnsupportedVersion,
    UnsupportedEndianness,
    UnsupportedEncoding,
    OutOfBounds,
    Corrupt,
    OutOfMemory,
};

/// Serialized-file format versions this parser accepts: 2 through 22.
/// Version 4 is supported (its metadata and object-info layout match
/// versions 3 and 5, which share the same code path); `parse` returns
/// `error.UnsupportedVersion` only for versions outside that range.
pub fn supportedVersion(version: u32) bool {
    return switch (version) {
        2...22 => true,
        else => false,
    };
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!SerializedFile {
    if (source.len < 16) return error.ShortData;

    // ---- header: always big endian ----
    var hr = streams.Reader.init(source);
    hr.endian = .big;
    var metadata_size = try hr.readInt(u32);
    var file_size: u64 = try hr.readInt(u32);
    const version = try hr.readInt(u32);
    var data_offset: u64 = try hr.readInt(u32);
    if (!supportedVersion(version)) return error.UnsupportedVersion;

    var endian: streams.Endian = .little;
    switch (version) {
        2, 3, 4, 5...8 => {
            // Endianness byte: first byte of the trailing metadata block.
            if (metadata_size == 0 or metadata_size > file_size) return error.Corrupt;
            const endian_pos: usize = @intCast(file_size - metadata_size);
            if (endian_pos >= source.len) return error.Corrupt;
            endian = endianFromByte(source[endian_pos]) catch return error.UnsupportedEndianness;
        },
        9...21 => {
            endian = endianFromByte(try hr.readByte()) catch return error.UnsupportedEndianness;
            _ = try hr.readBytes(3); // reserved
        },
        22 => {
            endian = endianFromByte(try hr.readByte()) catch return error.UnsupportedEndianness;
            _ = try hr.readBytes(3); // reserved
            metadata_size = try hr.readInt(u32);
            file_size = try readNonNegI64(&hr);
            data_offset = try readNonNegI64(&hr);
            _ = try hr.readInt(i64); // unknown
        },
        else => unreachable,
    }

    const header_size: u64 = switch (version) {
        2, 3, 4, 5...8 => 16,
        9...21 => 20,
        else => 48,
    };
    if (file_size > source.len) return error.Corrupt;
    if (data_offset < header_size or data_offset > file_size) return error.Corrupt;
    if (metadata_size == 0) return error.Corrupt;

    // ---- metadata region ----
    const metadata_body_start: usize = if (version < 9) blk: {
        const start: usize = @intCast(file_size - metadata_size + 1); // skip endian byte
        if (start > source.len) return error.Corrupt;
        break :blk start;
    } else @intCast(header_size);
    const metadata_body: []const u8 = if (version < 9)
        source[metadata_body_start..@intCast(file_size)]
    else blk: {
        const end = metadata_body_start + metadata_size;
        if (end > data_offset) return error.Corrupt;
        break :blk source[metadata_body_start..end];
    };

    var mr = streams.Reader.init(metadata_body);
    mr.endian = endian;

    var unity_version: []const u8 = "";
    if (version >= 7) unity_version = try mr.readStringToNull();

    var target_platform: i32 = 0;
    if (version >= 8) target_platform = try mr.readInt(i32);

    var enable_type_tree = true; // implicit before format 13
    if (version >= 13) enable_type_tree = try mr.readByte() != 0;

    const type_count = try readCount(&mr);
    const types = try allocator.alloc(SerializedType, type_count);
    for (types) |*t| {
        t.* = try readSerializedType(allocator, &mr, version, enable_type_tree, false);
    }

    var legacy_big_id: i32 = 0;
    if (version >= 7 and version < 14) legacy_big_id = try mr.readInt(i32);
    const uses_big_ids = legacy_big_id != 0;

    const object_table_offset = mr.position();
    const object_count = try readCount(&mr);
    const objects = try allocator.alloc(ObjectInfo, object_count);
    for (objects) |*o| {
        o.* = try readObjectInfo(&mr, version, uses_big_ids, data_offset, file_size, types);
    }
    const after_objects_offset = mr.position();

    var script_types: []LocalSerializedObjectIdentifier = &.{};
    if (version >= 11) {
        const script_count = try readCount(&mr);
        script_types = try allocator.alloc(LocalSerializedObjectIdentifier, script_count);
        for (script_types) |*s| {
            s.file_index = try mr.readInt(i32);
            s.path_id = switch (version) {
                11...13 => try mr.readInt(i32),
                else => blk: {
                    try mr.alignTo4();
                    break :blk try mr.readInt(i64);
                },
            };
        }
    }

    const external_count = try readCount(&mr);
    const externals = try allocator.alloc(FileIdentifier, external_count);
    for (externals) |*e| {
        e.* = try readFileIdentifier(&mr, version);
    }

    var ref_types: []SerializedType = &.{};
    if (version >= 20) {
        const ref_count = try readCount(&mr);
        ref_types = try allocator.alloc(SerializedType, ref_count);
        for (ref_types) |*t| {
            t.* = try readSerializedType(allocator, &mr, version, enable_type_tree, true);
        }
    }

    var user_information: []const u8 = "";
    if (version >= 5) user_information = try mr.readStringToNull();

    if (mr.remaining() != 0) return error.Corrupt;

    return .{
        .version = version,
        .file_size = file_size,
        .data_offset = data_offset,
        .metadata_size = metadata_size,
        .endian = endian,
        .unity_version = unity_version,
        .target_platform = target_platform,
        .enable_type_tree = enable_type_tree,
        .types = types,
        .objects = objects,
        .script_types = script_types,
        .externals = externals,
        .ref_types = ref_types,
        .user_information = user_information,
        .source = source,
        .metadata_body_offset = metadata_body_start,
        .object_table_offset = object_table_offset,
        .after_objects_offset = after_objects_offset,
        .uses_big_ids = uses_big_ids,
    };
}

fn endianFromByte(b: u8) error{UnsupportedEndianness}!streams.Endian {
    return switch (b) {
        0 => .little,
        1 => .big,
        else => error.UnsupportedEndianness,
    };
}

fn readNonNegI64(r: *streams.Reader) ParseError!u64 {
    const v = try r.readInt(i64);
    if (v < 0) return error.Corrupt;
    return @intCast(v);
}

fn readCount(r: *streams.Reader) ParseError!usize {
    const raw = try r.readInt(i32);
    if (raw < 0) return error.Corrupt;
    // Every entry consumes at least one byte of metadata, so a count past
    // the remaining metadata is corrupt: reject it before it sizes an
    // allocation.
    if (raw > r.remaining()) return error.Corrupt;
    return @intCast(raw);
}

fn readSerializedType(
    allocator: std.mem.Allocator,
    r: *streams.Reader,
    version: u32,
    enable_type_tree: bool,
    is_ref_type: bool,
) ParseError!SerializedType {
    var t = SerializedType{ .class_id = try r.readInt(i32) };

    if (version >= 16) t.is_stripped = try r.readByte() != 0;
    if (version >= 17) t.script_type_index = try r.readInt(i16);

    if (version >= 13) {
        if (typeHasScriptId(version, t.class_id, t.script_type_index, is_ref_type)) {
            t.script_id = try r.readBytes(16);
        }
        t.old_type_hash = try r.readBytes(16);
    }

    if (enable_type_tree) {
        t.type_tree = try typetree.parse(allocator, r, version, is_ref_type);
        if (is_ref_type and version >= 21) {
            t.class_name = try r.readStringToNull();
            t.namespace = try r.readStringToNull();
            t.assembly_name = try r.readStringToNull();
        } else if (!is_ref_type and version >= 21) {
            const dep_count = try readCount(r);
            t.type_dependencies = try allocator.alloc(i32, dep_count);
            for (t.type_dependencies) |*d| d.* = try r.readInt(i32);
        }
    }
    return t;
}

/// Whether the SerializedType record carries a 16-byte script ID.
fn typeHasScriptId(version: u32, class_id: i32, script_type_index: i16, is_ref_type: bool) bool {
    if (is_ref_type and script_type_index >= 0) return true;
    if (version < 16 and class_id < 0) return true;
    if (version >= 16 and class_id == 114) return true; // MonoBehaviour
    return false;
}

fn readObjectInfo(
    r: *streams.Reader,
    version: u32,
    uses_big_ids: bool,
    data_offset: u64,
    file_size: u64,
    types: []SerializedType,
) ParseError!ObjectInfo {
    const path_id: i64 = switch (version) {
        2...6 => try r.readInt(i32),
        7...13 => if (uses_big_ids) try r.readInt(i64) else try r.readInt(i32),
        else => blk: {
            try r.alignTo4();
            break :blk try r.readInt(i64);
        },
    };

    const rel_start: u64 = if (version == 22)
        try readNonNegI64(r)
    else
        try r.readInt(u32);
    const byte_size = try r.readInt(u32);
    const byte_start = data_offset + rel_start;
    if (byte_start < data_offset or byte_start > file_size) return error.Corrupt;
    if (byte_start + byte_size > file_size) return error.Corrupt;

    var class_id: i32 = undefined;
    var type_index: ?u32 = null;

    if (version < 16) {
        const type_id = try r.readInt(i32);
        const class_bits = try r.readInt(u16);
        class_id = class_bits; // zero-extended, as stored
        type_index = try resolveLegacyTypeIndex(types, type_id);
    } else if (version == 16) {
        const raw = try r.readInt(i32);
        // The script identity (i16) and stripped flag (u8) that follow are
        // consumed once, by the tail-field switch below. Peek at the
        // stripped flag here without advancing, because the type-ID
        // fallback lookup is keyed by it.
        const stripped = (try r.peek(3))[2] != 0;
        if (raw >= 0 and raw < types.len) {
            class_id = types[@intCast(raw)].class_id;
            type_index = @intCast(raw);
        } else {
            // fall back to a type-ID lookup keyed by (class_id, stripped)
            var match: ?usize = null;
            for (types, 0..) |*t, i| {
                if (t.class_id == raw and t.is_stripped == stripped) {
                    if (match != null) return error.Corrupt; // ambiguous
                    match = i;
                }
            }
            const idx = match orelse return error.Corrupt;
            class_id = types[idx].class_id;
            type_index = @intCast(idx);
        }
    } else {
        const index = try r.readInt(u32);
        if (index >= types.len) return error.Corrupt;
        class_id = types[index].class_id;
        type_index = index;
    }

    // tail fields
    var destroyed = false;
    var script_type_index: i16 = -1;
    var stripped = false;
    switch (version) {
        2...10 => destroyed = try r.readInt(u16) != 0,
        11...14 => script_type_index = try r.readInt(i16),
        15...16 => {
            script_type_index = try r.readInt(i16);
            stripped = try r.readByte() != 0;
        },
        else => {},
    }

    return .{
        .path_id = path_id,
        .byte_start = byte_start,
        .byte_size = byte_size,
        .class_id = class_id,
        .type_index = type_index,
        .script_type_index = script_type_index,
        .stripped = stripped,
        .destroyed = destroyed,
    };
}

/// Legacy object table: the raw type ID references the SerializedType
/// table by class ID. Returns the unique matching index, or null when no
/// type matches; ambiguous matches are an error.
fn resolveLegacyTypeIndex(types: []SerializedType, type_id: i32) ParseError!?u32 {
    var match: ?usize = null;
    for (types, 0..) |*t, i| {
        if (t.class_id == type_id) {
            if (match != null) return error.Corrupt;
            match = i;
        }
    }
    const idx = match orelse return null;
    return @intCast(idx);
}

fn readFileIdentifier(r: *streams.Reader, version: u32) ParseError!FileIdentifier {
    var e = FileIdentifier{};
    if (version >= 6) e.temp_empty = try r.readStringToNull();
    if (version >= 5) {
        e.guid = try r.readBytes(16);
        e.type_ = try r.readInt(i32);
    }
    e.path = try r.readStringToNull();
    return e;
}

test "supportedVersion" {
    try std.testing.expect(supportedVersion(2));
    try std.testing.expect(supportedVersion(3));
    try std.testing.expect(supportedVersion(5));
    try std.testing.expect(supportedVersion(13));
    try std.testing.expect(supportedVersion(22));
    try std.testing.expect(supportedVersion(4));
    try std.testing.expect(!supportedVersion(1));
    try std.testing.expect(!supportedVersion(23));
}

test "parse a modern v22 serialized file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = try buildV22Fixture(a);
    var sf = try parse(a, bytes);
    try std.testing.expectEqual(@as(u32, 22), sf.version);
    try std.testing.expectEqual(streams.Endian.little, sf.endian);
    try std.testing.expectEqualStrings("2020.1.0f1", sf.unity_version);
    try std.testing.expectEqual(@as(i32, 3), sf.target_platform);
    try std.testing.expect(sf.enable_type_tree);
    try std.testing.expectEqual(@as(usize, 2), sf.types.len);
    try std.testing.expectEqual(@as(i32, 4), sf.types[0].class_id); // Transform
    try std.testing.expectEqualStrings("Transform", sf.types[0].type_tree.roots[0].type_name);
    try std.testing.expectEqual(@as(i32, 28), sf.types[1].class_id); // Texture2D
    try std.testing.expectEqual(@as(usize, 2), sf.objects.len);
    try std.testing.expectEqual(@as(i64, 100), sf.objects[0].path_id);
    try std.testing.expectEqual(@as(i32, 4), sf.objects[0].class_id);
    try std.testing.expectEqual(@as(i64, 200), sf.objects[1].path_id);
    try std.testing.expectEqual(@as(i32, 28), sf.objects[1].class_id);
    try std.testing.expectEqual(@as(usize, 1), sf.externals.len);
    try std.testing.expectEqualStrings("library/unity default resources", sf.externals[0].path);
    try std.testing.expectEqualStrings("user info here", sf.user_information);

    // object data slices the data section correctly
    const data = sf.objectData(&sf.objects[1]).?;
    try std.testing.expectEqualStrings("TEXTUREBYTES", data);
}

test "parse rejects bad endianness flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildV22Fixture(a);
    bytes[16] = 2; // endianness byte: invalid
    try std.testing.expectError(error.UnsupportedEndianness, parse(a, bytes));
}

test "parse rejects unsupported version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildV22Fixture(a);
    std.mem.writeInt(u32, bytes[8..12], 1, .big); // version 1 is out of range
    try std.testing.expectError(error.UnsupportedVersion, parse(a, bytes));
}

test "parse a minimal version-4 serialized file" {
    // A bare v4 file (Unity 3.x-4.x era): 16-byte header, trailing metadata
    // opened by the endianness byte, no type trees, no objects. The legacy
    // layout is what `container.sniff` now routes to the CLI.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = [_]u8{
        0x00, 0x00, 0x00, 0x0d, // metadata size 13
        0x00, 0x00, 0x00, 0x1d, // file size 29
        0x00, 0x00, 0x00, 0x04, // format version 4
        0x00, 0x00, 0x00, 0x10, // data offset 16 (empty data section)
        0x00, // trailing metadata opens with the endianness byte (little)
        0x00, 0x00, 0x00, 0x00, // type count 0
        0x00, 0x00, 0x00, 0x00, // object count 0
        0x00, 0x00, 0x00, 0x00, // external count 0
    };
    const sf = try parse(a, &bytes);
    try std.testing.expectEqual(@as(u32, 4), sf.version);
    try std.testing.expectEqual(@as(u64, 29), sf.file_size);
    try std.testing.expectEqual(streams.Endian.little, sf.endian);
    try std.testing.expectEqual(@as(usize, 0), sf.types.len);
    try std.testing.expectEqual(@as(usize, 0), sf.objects.len);
    try std.testing.expectEqual(@as(usize, 0), sf.externals.len);
    try std.testing.expectEqualStrings("", sf.user_information);
}

// ---------------------------------------------------------------------------
// Fixture builder (tests only): a minimal v22 serialized file with two
// types (Transform, Texture2D), two objects, one external, user info.
// ---------------------------------------------------------------------------

fn buildV22Fixture(a: std.mem.Allocator) ![]u8 {
    var meta: streams.Writer = .init(a);
    defer meta.deinit();

    try meta.writeStringToNull("2020.1.0f1"); // unity_version
    try meta.writeInt(i32, 3); // target_platform (Android-ish)
    try meta.writeByte(1); // enable_type_tree

    // two types
    try meta.writeInt(i32, 2);
    try writeType(&meta, 4, "Transform"); // class 4, tree "Transform"
    try writeType(&meta, 28, "Texture2D"); // class 28, tree "Texture2D"

    // big_id (v7-13 only; skipped for 22)

    // two objects
    try meta.writeInt(i32, 2);
    try writeObject(&meta, 100, 0, 0, 0); // path_id 100, rel 0, size 0, type idx 0
    try writeObject(&meta, 200, 0, 12, 1); // path_id 200, rel 0, size 12, type idx 1

    // script types (v11+): none
    try meta.writeInt(i32, 0);

    // one external
    try meta.writeInt(i32, 1);
    try meta.writeStringToNull(""); // temp_empty
    try meta.writeBytes(&[_]u8{0} ** 16); // guid
    try meta.writeInt(i32, 0); // type
    try meta.writeStringToNull("library/unity default resources"); // path

    // ref types (v20+): none
    try meta.writeInt(i32, 0);

    // user info
    try meta.writeStringToNull("user info here");

    // Assemble the file: header (48 bytes) + metadata + object data.
    var out: streams.Writer = .init(a);
    defer out.deinit();
    const meta_len: u32 = @intCast(meta.getWritten().len);
    const data_len: usize = 12;
    const data_offset: u64 = 48 + meta_len;
    const file_size: u64 = data_offset + data_len;

    // base header (big endian)
    try out.writeIntWith(u32, 0, .big); // metadata_size placeholder
    try out.writeIntWith(u32, 0, .big); // file_size placeholder
    try out.writeIntWith(u32, 22, .big); // version
    try out.writeIntWith(u32, 0, .big); // data_offset placeholder
    try out.writeByte(0); // endianness: little
    try out.writeBytes(&[_]u8{ 0xa1, 0xb2, 0xc3 }); // reserved
    // 64-bit extension
    try out.writeIntWith(u32, meta_len, .big); // metadata_size
    try out.writeIntWith(i64, @intCast(file_size), .big);
    try out.writeIntWith(i64, @intCast(data_offset), .big);
    try out.writeIntWith(i64, 7, .big); // unknown
    try out.writeBytes(meta.getWritten());
    try out.writeBytes("TEXTUREBYTES");

    return a.dupe(u8, out.getWritten());
}

fn writeType(w: *streams.Writer, class_id: i32, tree_name: []const u8) !void {
    try w.writeInt(i32, class_id);
    try w.writeByte(0); // stripped (v16+)
    try w.writeInt(i16, -1); // script_type_index (v17+)
    try w.writeBytes(&[_]u8{0} ** 16); // old_type_hash (v13+; not a script type)
    // TypeTree (blob, v22, with ref_type_hash):
    try w.writeInt(i32, 1); // node count
    try w.writeInt(i32, 0); // string buffer size
    try w.writeInt(i16, 22); // node version
    try w.writeByte(0); // level
    try w.writeByte(0); // type_flags
    try w.writeInt(u32, typetree.common_string_flag + typetree.commonStringOffset(tree_name).?);
    try w.writeInt(u32, typetree.common_string_flag + typetree.commonStringOffset("m_Name").?);
    try w.writeInt(i32, 0); // byte_size
    try w.writeInt(i32, 0); // index
    try w.writeInt(i32, 0); // meta_flags
    try w.writeInt(u64, 0); // ref_type_hash
    try w.writeInt(i32, 0); // type dependencies (v21+)
}

fn writeObject(w: *streams.Writer, path_id: i64, rel_start: i64, size: u32, type_index: u32) !void {
    try w.alignTo4();
    try w.writeInt(i64, path_id);
    try w.writeInt(i64, rel_start); // v22: i64 offsets
    try w.writeInt(u32, size);
    try w.writeInt(u32, type_index);
}

test "serialized parser survives mutated and truncated input" {
    // Hostile input must never crash the serialized parser: mutations of
    // valid v22 and v4 files (bytes flipped, lengths nudged, headers
    // truncated, header fields corrupted) must parse cleanly or fail with
    // an error - never panic, never hand out mis-sized object data.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v22 = try buildV22Fixture(a);
    defer a.free(v22);
    // the minimal v4 fixture from the parse test
    const v4 = [_]u8{
        0x00, 0x00, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x1d,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x10,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    };

    var prng = std.Random.DefaultPrng.init(0x5e21);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        const source: []const u8 = if (iter % 2 == 0) v22 else &v4;
        const mode = rnd.int(u8) % 4;
        const blen = switch (mode) {
            0 => rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(source.len))), // truncate
            1 => source.len, // mutate in place
            2 => @min(source.len + rnd.intRangeAtMost(u32, 1, 64), buf.len), // extend
            else => rnd.intRangeAtMost(u32, 0, 64), // tiny random
        };
        @memcpy(buf[0..source.len], source);
        if (mode == 1) {
            const m = rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(source.len)));
            buf[m] ^= @intCast(rnd.int(u8) | 1);
        } else if (mode == 3 and blen > 0) {
            rnd.bytes(buf[0..blen]);
        } else if (mode == 2 and source.len >= 12) {
            // nudge a header length field (metadata/file size)
            const m = rnd.intRangeAtMost(u32, 0, 11);
            buf[m] ^= @intCast(rnd.int(u8) | 1);
        }
        const sf = parse(a, buf[0..blen]) catch continue;
        // if it parsed, every object's data must be within the source
        for (sf.objects) |*o| {
            if (sf.objectData(o)) |d| {
                // the data must borrow from the (possibly truncated) source
                const src = buf[0..blen];
                const d_start = @intFromPtr(d.ptr);
                const d_end = d_start + d.len;
                const s_start = @intFromPtr(src.ptr);
                if (d_start < s_start or d_end > s_start + src.len) return error.BadSlice;
            }
        }
    }
}
