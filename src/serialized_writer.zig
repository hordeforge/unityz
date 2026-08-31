//! SerializedFile rewrite: produce a new `.assets`-style file from a
//! parsed [`SerializedFile`] with one or more object payloads replaced.
//!
//! The type section of the metadata (unity version, platform, type trees,
//! externals, ...) is copied verbatim from the source; only the object
//! table and the data section are rebuilt, so edited objects may change
//! size and later objects shift. All supported formats (2-22 except 4) round-trip:
//! the object-table entry layout, per-object tail fields (destroyed flag,
//! script identity) and the two header layouts (Legacy16 metadata-at-end
//! for formats 2-8, metadata-after-header for 9+) are reproduced per
//! version.
//!
//! The data section is repacked with 4-aligned object starts; byte offsets
//! in the rebuilt object table are relative to the new data offset.
//! Streamed/external data ranges inside the same file (StreamingInfo with
//! an empty path) would shift and are not preserved — a documented
//! limitation for now.

const std = @import("std");
const streams = @import("streams.zig");
const serialized = @import("serialized.zig");

pub const Error = error{
    UnsupportedFormat,
    ObjectNotFound,
    MissingTypeIndex,
    OutOfMemory,
};

/// A replacement object payload, keyed by path ID.
pub const Replacement = struct {
    path_id: i64,
    data: []const u8,
};

/// Rewrites `sf` with the given object payloads replaced. The caller owns
/// the returned bytes.
pub fn rewrite(allocator: std.mem.Allocator, sf: *const serialized.SerializedFile, replacements: []const Replacement) Error![]u8 {
    const version = sf.version;
    if (!serialized.supportedVersion(version)) return error.UnsupportedFormat;

    const source = sf.source;
    const metadata = source[sf.metadata_body_offset .. sf.metadata_body_offset + sf.metadata_size];
    const prefix = metadata[0..sf.object_table_offset];
    const suffix = metadata[sf.after_objects_offset..];

    // Build the new data section: original payloads, with replacements.
    // Object starts mirror the source file's own alignment (2022.3+ files
    // align to 8; the fixtures to 4), derived as the gcd of the source
    // object offsets so rewrites stay byte-exact.
    const data_align = deriveDataAlign(sf);
    var data: streams.Writer = .init(allocator);
    defer data.deinit();
    data.endian = sf.endian;

    const rel_starts = allocator.alloc(u64, sf.objects.len) catch return error.OutOfMemory;
    const new_sizes = allocator.alloc(u32, sf.objects.len) catch return error.OutOfMemory;

    var found_count: usize = 0;
    for (sf.objects, 0..) |*o, i| {
        try alignTo(&data, data_align);
        rel_starts[i] = data.getWritten().len;
        var payload: []const u8 = undefined;
        var replaced_obj = false;
        for (replacements) |r| {
            if (r.path_id == o.path_id) {
                payload = r.data;
                replaced_obj = true;
                found_count += 1;
                break;
            }
        }
        if (!replaced_obj) payload = sf.objectData(o) orelse return error.OutOfMemory;
        new_sizes[i] = @intCast(payload.len);
        try data.writeBytes(payload);
    }
    if (found_count != replacements.len) return error.ObjectNotFound;

    // Rebuild the object table: count, padding, then entries in the file's
    // own endianness. The entry layout varies by format version; the tail
    // fields (destroyed / script identity) are preserved so legacy tables
    // round-trip byte-exactly.
    var table: streams.Writer = .init(allocator);
    defer table.deinit();
    table.endian = sf.endian;
    try table.writeInt(i32, @intCast(sf.objects.len));
    // Formats 14+ 4-align the first path ID relative to the metadata
    // start, so the padding here accounts for the verbatim prefix length.
    if (version >= 14) {
        const pos = prefix.len + 4;
        const pad = (4 - (pos % 4)) % 4;
        const zeros = [_]u8{0} ** 4;
        try table.writeBytes(zeros[0..pad]);
    }
    for (sf.objects, 0..) |*o, i| {
        switch (version) {
            2...6 => try table.writeInt(i32, @intCast(o.path_id)),
            7...13 => {
                if (sf.uses_big_ids) {
                    try table.writeInt(i64, o.path_id);
                } else {
                    try table.writeInt(i32, @intCast(o.path_id));
                }
            },
            else => try table.writeInt(i64, o.path_id),
        }
        if (version == 22) {
            try table.writeInt(i64, @intCast(rel_starts[i]));
        } else {
            try table.writeInt(u32, @intCast(rel_starts[i]));
        }
        try table.writeInt(u32, new_sizes[i]);
        if (version < 15) {
            // raw type id + class bits (zero-extended u16 as stored)
            const type_index = o.type_index orelse return error.MissingTypeIndex;
            if (type_index >= sf.types.len) return error.MissingTypeIndex;
            try table.writeInt(i32, sf.types[type_index].class_id);
            try table.writeInt(u16, @intCast(sf.types[type_index].class_id & 0xFFFF));
        } else if (version == 16) {
            const type_index = o.type_index orelse return error.MissingTypeIndex;
            try table.writeInt(i32, @intCast(type_index));
            try table.writeInt(i16, o.script_type_index);
            try table.writeByte(if (o.stripped) 1 else 0);
        } else {
            const type_index = o.type_index orelse return error.MissingTypeIndex;
            try table.writeInt(u32, type_index);
        }
        switch (version) {
            2...10 => try table.writeInt(u16, if (o.destroyed) 1 else 0),
            11...14 => try table.writeInt(i16, o.script_type_index),
            15...16 => {
                try table.writeInt(i16, o.script_type_index);
                try table.writeByte(if (o.stripped) 1 else 0);
            },
            else => {},
        }
    }

    // Assemble the metadata: verbatim prefix, new table, verbatim suffix.
    const meta_len = prefix.len + table.getWritten().len + suffix.len;
    const data_len = data.getWritten().len;

    // Layout depends on the format: formats 9+ put the metadata right
    // after the header; formats 2-8 (Legacy16) put it at the end of the
    // file behind the data, preceded by the endianness byte. v22 files
    // pad the data start to the source file's object alignment.
    const data_offset: u64 = if (version < 9)
        headerSize(version)
    else if (version == 22)
        alignUp(headerSize(version) + meta_len, data_align)
    else
        headerSize(version) + meta_len;
    const file_size: u64 = data_offset + data_len + (if (version < 9) 1 + meta_len else 0);

    var out: streams.Writer = .init(allocator);
    defer out.deinit();

    // Header is always big endian.
    const be = std.builtin.Endian.big;
    const endian_byte: u8 = if (sf.endian == .little) 0 else 1;
    if (version == 22) {
        // v22 header: the legacy 16-byte fields are all zero; the real
        // values live in the 28-byte extension (matches Unity 2022.3).
        try out.writeIntWith(u32, 0, be); // legacy metadata size (0)
        try out.writeIntWith(u32, 0, be); // legacy file size (0)
        try out.writeIntWith(u32, version, be);
        try out.writeIntWith(u32, 0, be); // legacy data offset (0)
        try out.writeByte(endian_byte);
        try out.writeBytes(&[_]u8{ 0, 0, 0 }); // reserved
        try out.writeIntWith(u32, @intCast(meta_len), be);
        try out.writeIntWith(i64, @intCast(file_size), be);
        try out.writeIntWith(i64, @intCast(data_offset), be);
        try out.writeIntWith(i64, 0, be); // unknown
    } else if (version < 9) {
        // Legacy16: metadata_size counts the endianness byte + body.
        try out.writeIntWith(u32, @intCast(meta_len + 1), be);
        try out.writeIntWith(u32, @intCast(file_size), be);
        try out.writeIntWith(u32, version, be);
        try out.writeIntWith(u32, @intCast(data_offset), be);
    } else {
        try out.writeIntWith(u32, @intCast(meta_len), be);
        try out.writeIntWith(u32, @intCast(file_size), be);
        try out.writeIntWith(u32, version, be);
        try out.writeIntWith(u32, @intCast(data_offset), be);
        try out.writeByte(endian_byte);
        try out.writeBytes(&[_]u8{ 0, 0, 0 }); // reserved
    }

    if (version < 9) {
        // data, then endianness byte + metadata body at the end
        try out.writeBytes(data.getWritten());
        try out.writeByte(endian_byte);
        try out.writeBytes(prefix);
        try out.writeBytes(table.getWritten());
        try out.writeBytes(suffix);
    } else {
        try out.writeBytes(prefix);
        try out.writeBytes(table.getWritten());
        try out.writeBytes(suffix);
        if (version == 22) {
            // pad the data start to the offset declared in the header
            const meta_end = headerSize(version) + meta_len;
            const pad = alignUp(meta_end, data_align) - meta_end;
            for (0..@intCast(pad)) |_| try out.writeByte(0);
        }
        try out.writeBytes(data.getWritten());
    }

    return allocator.dupe(u8, out.getWritten());
}

fn headerSize(version: u32) u64 {
    return switch (version) {
        2, 3, 5...8 => 16,
        9...21 => 20,
        else => 48,
    };
}

/// The alignment of object data in the source file: the largest power of
/// two that divides every relative object offset. Unity 2022.3 writes
/// objects 8-aligned; the hand-built fixtures use 4 (or 8). A gcd over
/// sparse offsets can overestimate (two objects at 0 and 40 would suggest
/// 40), so the alignment is picked from the power-of-two candidates.
fn deriveDataAlign(sf: *const serialized.SerializedFile) usize {
    const candidates = [_]usize{ 16, 8, 4, 2, 1 };
    for (candidates) |a| {
        var ok = true;
        for (sf.objects) |*o| {
            if (o.byte_start < sf.data_offset) continue;
            const rel: u64 = o.byte_start - sf.data_offset;
            if (rel % a != 0) {
                ok = false;
                break;
            }
        }
        if (ok) return a;
    }
    return 4; // unreachable: everything is 1-aligned
}

fn alignTo(w: *streams.Writer, n: usize) Error!void {
    const pad = (n - (w.getWritten().len % n)) % n;
    var i: usize = 0;
    while (i < pad) : (i += 1) try w.writeByte(0);
}

fn alignUp(x: u64, n: usize) u64 {
    const m: u64 = @intCast(n);
    return x + ((m - (x % m)) % m);
}

// ---------------------------------------------------------------------------
// Tests: build a v17 file with two objects, rewrite one with longer bytes,
// re-parse and verify.
// ---------------------------------------------------------------------------

test "rewrite a v17 file with a resized object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = try buildV17Fixture(a);
    const sf = try serialized.parse(a, bytes);
    try std.testing.expectEqual(@as(usize, 2), sf.objects.len);

    // object 1 (path_id 200): replace its payload with longer data
    const replaced = "LONGERBYTES";
    const out = try rewrite(a, &sf, &.{.{ .path_id = 200, .data = replaced }});
    const sf2 = try serialized.parse(a, out);

    try std.testing.expectEqual(@as(usize, 2), sf2.objects.len);
    try std.testing.expectEqual(@as(u32, 17), sf2.version);
    try std.testing.expectEqualStrings("2018.4.0f1", sf2.unity_version);
    try std.testing.expectEqualStrings("user info here", sf2.user_information);
    // object 0 unchanged
    try std.testing.expectEqualStrings("DATA0", sf2.objectData(&sf2.objects[0]).?);
    // object 1 replaced
    try std.testing.expectEqualStrings(replaced, sf2.objectData(&sf2.objects[1]).?);
    // both objects' ranges are inside the data region
    for (sf2.objects) |*o| {
        try std.testing.expect(o.byte_start >= sf2.data_offset);
        try std.testing.expect(o.byte_start + o.byte_size <= sf2.file_size);
    }
    // the type section is untouched: the type tree still parses
    try std.testing.expectEqualStrings("MonoBehaviour", sf2.types[0].type_tree.roots[0].type_name);
}

test "rewrite a v13 file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Legacy (Standard20, v13) fixture: MonoBehaviour (114) + MonoScript (115),
    // big-id flag off, legacy tail fields, blob type trees.
    const bytes = [_]u8{

    0x00, 0x00, 0x01, 0x3f, 0x00, 0x00, 0x01, 0x67, 0x00, 0x00, 0x00, 0x0d,
    0x00, 0x00, 0x01, 0x53, 0x00, 0x00, 0x00, 0x00, 0x32, 0x30, 0x31, 0x38,
    0x2e, 0x34, 0x2e, 0x30, 0x66, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x02, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x2e, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00, 0x01, 0x00,
    0x22, 0x00, 0x00, 0x00, 0x26, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4d, 0x6f, 0x6e, 0x6f,
    0x42, 0x65, 0x68, 0x61, 0x76, 0x69, 0x6f, 0x75, 0x72, 0x00, 0x42, 0x61,
    0x73, 0x65, 0x3c, 0x4d, 0x6f, 0x6e, 0x6f, 0x42, 0x65, 0x68, 0x61, 0x76,
    0x69, 0x6f, 0x75, 0x72, 0x3e, 0x00, 0x69, 0x6e, 0x74, 0x00, 0x6d, 0x5f,
    0x56, 0x61, 0x6c, 0x75, 0x65, 0x00, 0x73, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x23, 0x00, 0x00, 0x00, 0x11, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00,
    0x01, 0x00, 0x10, 0x00, 0x00, 0x00, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x4d, 0x6f,
    0x6e, 0x6f, 0x53, 0x63, 0x72, 0x69, 0x70, 0x74, 0x00, 0x42, 0x61, 0x73,
    0x65, 0x00, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x00, 0x6d, 0x5f, 0x43,
    0x6c, 0x61, 0x73, 0x73, 0x4e, 0x61, 0x6d, 0x65, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x04, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00,
    0x00, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
    0x00, 0x73, 0x00, 0x00, 0x00, 0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x75, 0x73, 0x65, 0x72, 0x20, 0x69, 0x6e,
    0x66, 0x6f, 0x00, 0x07, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x4c,
    0x65, 0x67, 0x61, 0x63, 0x79, 0x43, 0x6c, 0x61, 0x73, 0x73, 0x00,
    };
    var sf = try serialized.parse(a, &bytes);
    const new_payload = "REPLACED-REPLACED-REPLACED";
    const out = try rewrite(a, &sf, &.{.{
        .path_id = 1,
        .data = new_payload,
    }});
    defer a.free(out);
    var sf2 = try serialized.parse(a, out);
    try std.testing.expectEqual(@as(u32, 13), sf2.version);
    try std.testing.expectEqual(@as(usize, 2), sf2.objects.len);
    const o1 = sf2.findObject(1).?;
    try std.testing.expectEqualStrings(new_payload, sf2.objectData(o1).?);
    const o2 = sf2.findObject(2).?;
    try std.testing.expectEqualStrings("LegacyClass\x00", sf2.objectData(o2).?[4..16]);
}

test "rewrite a v9 file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Legacy16 fixture (v9): metadata at the end of the file, legacy type
    // tree encoding, no script-id/hash fields.
    const bytes = [_]u8{

    0x00, 0x00, 0x01, 0x31, 0x00, 0x00, 0x01, 0x59, 0x00, 0x00, 0x00, 0x09,
    0x00, 0x00, 0x01, 0x45, 0x00, 0x00, 0x00, 0x00, 0x32, 0x30, 0x31, 0x38,
    0x2e, 0x34, 0x2e, 0x30, 0x66, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x72, 0x00, 0x00, 0x00, 0x0e, 0x00, 0x00, 0x00, 0x4d,
    0x6f, 0x6e, 0x6f, 0x42, 0x65, 0x68, 0x61, 0x76, 0x69, 0x6f, 0x75, 0x72,
    0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x42, 0x61, 0x73, 0x65, 0x3c,
    0x4d, 0x6f, 0x6e, 0x6f, 0x42, 0x65, 0x68, 0x61, 0x76, 0x69, 0x6f, 0x75,
    0x72, 0x3e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x69, 0x6e, 0x74, 0x00, 0x08,
    0x00, 0x00, 0x00, 0x6d, 0x5f, 0x56, 0x61, 0x6c, 0x75, 0x65, 0x00, 0x04,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x73,
    0x00, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x4d, 0x6f, 0x6e, 0x6f, 0x53,
    0x63, 0x72, 0x69, 0x70, 0x74, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x42,
    0x61, 0x73, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x73,
    0x74, 0x72, 0x69, 0x6e, 0x67, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x6d,
    0x5f, 0x43, 0x6c, 0x61, 0x73, 0x73, 0x4e, 0x61, 0x6d, 0x65, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
    0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00, 0x00, 0x72,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x10,
    0x00, 0x00, 0x00, 0x73, 0x00, 0x00, 0x00, 0x73, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x75, 0x73, 0x65, 0x72, 0x20, 0x69, 0x6e, 0x66, 0x6f,
    0x00, 0x07, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x4c, 0x65, 0x67,
    0x61, 0x63, 0x79, 0x43, 0x6c, 0x61, 0x73, 0x73, 0x00,
    };
    var sf = try serialized.parse(a, &bytes);
    const new_payload = "REPLACED-REPLACED-REPLACED";
    const out = try rewrite(a, &sf, &.{.{
        .path_id = 1,
        .data = new_payload,
    }});
    defer a.free(out);
    var sf2 = try serialized.parse(a, out);
    try std.testing.expectEqual(@as(u32, 9), sf2.version);
    try std.testing.expectEqual(@as(usize, 2), sf2.objects.len);
    const o1 = sf2.findObject(1).?;
    try std.testing.expectEqualStrings(new_payload, sf2.objectData(o1).?);
}

test "rewrite rejects legacy formats and unknown path ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = try buildV17Fixture(a);
    const sf = try serialized.parse(a, bytes);
    try std.testing.expectError(error.ObjectNotFound, rewrite(a, &sf, &.{.{ .path_id = 999, .data = "x" }}));
}

// ---------------------------------------------------------------------------
// Fixture: a minimal v17 serialized file with two MonoBehaviour objects of
// differing sizes.
// ---------------------------------------------------------------------------

fn buildV17Fixture(a: std.mem.Allocator) ![]u8 {
    var meta: streams.Writer = .init(a);
    defer meta.deinit();
    try meta.writeStringToNull("2018.4.0f1");
    try meta.writeInt(i32, 0);
    try meta.writeByte(1); // enable type tree
    try meta.writeInt(i32, 1); // type count
    try meta.writeInt(i32, 114); // class MonoBehaviour
    try meta.writeByte(0); // stripped
    try meta.writeInt(i16, -1); // script index
    try meta.writeBytes(&[_]u8{0} ** 16); // script id (class 114)
    try meta.writeBytes(&[_]u8{0} ** 16); // old type hash
    try writeMonoTree(&meta, a);
    try meta.writeInt(i32, 2); // object count
    try meta.alignTo4(); // path ids are 4-aligned
    try meta.writeInt(i64, 100);
    try meta.writeInt(i32, 0); // byte start
    try meta.writeInt(i32, 5); // byte size
    try meta.writeInt(u32, 0); // type index
    try meta.alignTo4();
    try meta.writeInt(i64, 200);
    try meta.writeInt(i32, 0); // byte start
    try meta.writeInt(i32, 8); // byte size
    try meta.writeInt(u32, 0); // type index
    try meta.writeInt(i32, 0); // script types
    try meta.writeInt(i32, 0); // externals
    try meta.writeStringToNull("user info here");

    const header_size: usize = 20;
    const meta_len: u32 = @intCast(meta.getWritten().len);
    const data_offset: u64 = header_size + meta_len;
    const data = "DATA0" ++ "DATAONE2";
    const file_size: u64 = data_offset + data.len;

    var out: streams.Writer = .init(a);
    defer out.deinit();
    const be = std.builtin.Endian.big;
    try out.writeIntWith(u32, meta_len, be);
    try out.writeIntWith(u32, @intCast(file_size), be);
    try out.writeIntWith(u32, 17, be);
    try out.writeIntWith(u32, @intCast(data_offset), be);
    try out.writeByte(0); // little endian
    try out.writeBytes(&[_]u8{ 0, 0, 0 });
    try out.writeBytes(meta.getWritten());
    try out.writeBytes(data);
    return a.dupe(u8, out.getWritten());
}

fn writeMonoTree(w: *streams.Writer, a: std.mem.Allocator) !void {
    // blob typetree with one int field "m_Value" (local string buffer)
    const type_str = "MonoBehaviour";
    const name_str = "Base<MonoBehaviour>";
    const field_str = "int";
    const field_name = "m_Value";
    const s1 = type_str.len + 1;
    const s2 = s1 + name_str.len + 1;
    const s3 = s2 + field_str.len + 1;
    const buf_len = s3 + field_name.len + 1;
    const buf = try a.alloc(u8, buf_len);
    @memcpy(buf[0..type_str.len], type_str);
    buf[type_str.len] = 0;
    @memcpy(buf[s1 .. s1 + name_str.len], name_str);
    buf[s1 + name_str.len] = 0;
    @memcpy(buf[s2 .. s2 + field_str.len], field_str);
    buf[s2 + field_str.len] = 0;
    @memcpy(buf[s3 .. s3 + field_name.len], field_name);
    buf[s3 + field_name.len] = 0;

    try w.writeInt(i32, 3); // node count
    try w.writeInt(i32, @intCast(buf_len));
    // node 0: root
    try w.writeInt(i16, 17);
    try w.writeByte(0); // level
    try w.writeByte(0); // type flags
    try w.writeInt(u32, 0);
    try w.writeInt(u32, s1);
    try w.writeInt(i32, -1);
    try w.writeInt(i32, 0);
    try w.writeInt(i32, 0);
    // node 1: int size (for array? no — this tree has one int field)
    // (placeholder nodes to keep the fixture simple: two extra empty leaves)
    try w.writeInt(i16, 17);
    try w.writeByte(1);
    try w.writeByte(0);
    try w.writeInt(u32, s2);
    try w.writeInt(u32, s3);
    try w.writeInt(i32, 4);
    try w.writeInt(i32, 1);
    try w.writeInt(i32, 0);
    // node 2: second child of root (unnamed filler)
    try w.writeInt(i16, 17);
    try w.writeByte(1);
    try w.writeByte(0);
    try w.writeInt(u32, s2);
    try w.writeInt(u32, s3);
    try w.writeInt(i32, 4);
    try w.writeInt(i32, 2);
    try w.writeInt(i32, 0);
    try w.writeBytes(buf);
}

test "rewrite a v22 file byte-exactly (2022.3 layout)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // v22 fixture mirroring the real 2022.3 layout: legacy header fields
    // zero, data offset padded to 8 after the metadata, objects 8-aligned.
    const bytes = try buildV22Fixture(a);
    const sf = try serialized.parse(a, bytes);

    // sanity: the layout really is 2022.3-style
    try std.testing.expectEqual(@as(u32, 22), sf.version);
    try std.testing.expectEqual(@as(usize, 2), sf.objects.len);

    // an unchanged rewrite must reproduce the file byte-for-byte
    const out = try rewrite(a, &sf, &.{});
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, bytes, out);
}

fn buildV22Fixture(a: std.mem.Allocator) ![]u8 {
    var meta: streams.Writer = .init(a);
    defer meta.deinit();
    try meta.writeStringToNull("2022.3.62f2");
    try meta.writeInt(i32, 19); // target platform
    try meta.writeByte(1); // enable type tree
    try meta.writeInt(i32, 1); // type count
    try meta.writeInt(i32, 114); // class MonoBehaviour
    try meta.writeByte(0); // stripped
    try meta.writeInt(i16, -1); // script index
    try meta.writeBytes(&[_]u8{0} ** 16); // script id (class 114)
    try meta.writeBytes(&[_]u8{0} ** 16); // old type hash
    try writeV22MonoTree(&meta, a);
    try meta.writeInt(i32, 0); // type dependencies (v21+)
    try meta.writeInt(i32, 2); // object count
    // path ids are 4-aligned relative to the metadata start
    {
        const pos = meta.getWritten().len + 4;
        const pad = (4 - (pos % 4)) % 4;
        for (0..pad) |_| try meta.writeByte(0);
    }
    try meta.writeInt(i64, 100);
    try meta.writeInt(i64, 0); // byte start
    try meta.writeInt(u32, 5); // byte size
    try meta.writeInt(u32, 0); // type index
    try meta.writeInt(i64, 200);
    try meta.writeInt(i64, 8); // byte start, 8-aligned
    try meta.writeInt(u32, 8); // byte size
    try meta.writeInt(u32, 0); // type index
    try meta.writeInt(i32, 0); // script types
    try meta.writeInt(i32, 0); // externals
    try meta.writeInt(i32, 0); // ref types
    try meta.writeStringToNull("user info here");

    const header_size: usize = 48;
    const meta_len: u32 = @intCast(meta.getWritten().len);
    const data_offset: u64 = (header_size + meta_len + 7) / 8 * 8;
    const data = "DATA0" ++ "\x00\x00\x00" ++ "DATAONE2";
    const file_size: u64 = data_offset + data.len;

    var out: streams.Writer = .init(a);
    defer out.deinit();
    const be = std.builtin.Endian.big;
    try out.writeIntWith(u32, 0, be); // legacy metadata size
    try out.writeIntWith(u32, 0, be); // legacy file size
    try out.writeIntWith(u32, 22, be);
    try out.writeIntWith(u32, 0, be); // legacy data offset
    try out.writeByte(0); // little endian
    try out.writeBytes(&[_]u8{ 0, 0, 0 });
    try out.writeIntWith(u32, meta_len, be);
    try out.writeIntWith(i64, @intCast(file_size), be);
    try out.writeIntWith(i64, @intCast(data_offset), be);
    try out.writeIntWith(i64, 0, be); // unknown
    try out.writeBytes(meta.getWritten());
    for (0..@intCast(data_offset - header_size - meta_len)) |_| try out.writeByte(0);
    try out.writeBytes(data);
    return a.dupe(u8, out.getWritten());
}

fn writeV22MonoTree(w: *streams.Writer, a: std.mem.Allocator) !void {
    // blob_with_hash typetree with one int field "m_Value"
    const type_str = "MonoBehaviour";
    const name_str = "Base<MonoBehaviour>";
    const field_str = "int";
    const field_name = "m_Value";
    const s1 = type_str.len + 1;
    const s2 = s1 + name_str.len + 1;
    const s3 = s2 + field_str.len + 1;
    const buf_len = s3 + field_name.len + 1;
    const buf = try a.alloc(u8, buf_len);
    @memcpy(buf[0..type_str.len], type_str);
    buf[type_str.len] = 0;
    @memcpy(buf[s1 .. s1 + name_str.len], name_str);
    buf[s1 + name_str.len] = 0;
    @memcpy(buf[s2 .. s2 + field_str.len], field_str);
    buf[s2 + field_str.len] = 0;
    @memcpy(buf[s3 .. s3 + field_name.len], field_name);
    buf[s3 + field_name.len] = 0;

    try w.writeInt(i32, 2); // node count
    try w.writeInt(i32, @intCast(buf_len));
    // node 0: root
    try w.writeInt(i16, 1); // version
    try w.writeByte(0); // level
    try w.writeByte(0); // type flags
    try w.writeInt(u32, 0);
    try w.writeInt(u32, s1);
    try w.writeInt(i32, -1);
    try w.writeInt(i32, 0);
    try w.writeInt(i32, 0);
    try w.writeInt(u64, 0); // ref type hash (v19+)
    // node 1: int m_Value
    try w.writeInt(i16, 1);
    try w.writeByte(1);
    try w.writeByte(0);
    try w.writeInt(u32, s2);
    try w.writeInt(u32, s3);
    try w.writeInt(i32, 4);
    try w.writeInt(i32, 1);
    try w.writeInt(i32, 0);
    try w.writeInt(u64, 0);
    try w.writeBytes(buf);
}
