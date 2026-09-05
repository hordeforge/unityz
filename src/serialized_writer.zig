//! SerializedFile rewrite: produce a new `.assets`-style file from a
//! parsed [`SerializedFile`] with one or more object payloads replaced.
//!
//! The type section of the metadata (unity version, platform, type trees,
//! externals, ...) is copied verbatim from the source; only the object
//! table and the data section are rebuilt, so edited objects may change
//! size and later objects shift. All supported formats (2-22) round-trip:
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
    // Format versions < 9 store the endianness byte in the metadata block
    // (`metadata_size` includes it); the body runs one byte shorter.
    const metadata_body_len = if (version < 9) sf.metadata_size - 1 else sf.metadata_size;
    const metadata = source[sf.metadata_body_offset .. sf.metadata_body_offset + metadata_body_len];
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
    for (sf.objects, 0..) |*o, i| {
        // Formats 14+ 4-align *every* path ID relative to the metadata
        // start, so the padding accounts for the verbatim prefix length.
        // Formats 15 and 16 have entry sizes that are not multiples of 4
        // (25 and 23 bytes), so this pads between entries as well as
        // before the first one.
        if (version >= 14) {
            const pos = prefix.len + table.getWritten().len;
            const pad = (4 - (pos % 4)) % 4;
            const zeros = [_]u8{0} ** 4;
            try table.writeBytes(zeros[0..pad]);
        }
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
        if (version < 16) {
            // raw type id + class bits (zero-extended u16 as stored)
            const type_index = o.type_index orelse return error.MissingTypeIndex;
            if (type_index >= sf.types.len) return error.MissingTypeIndex;
            try table.writeInt(i32, sf.types[type_index].class_id);
            try table.writeInt(u16, @intCast(sf.types[type_index].class_id & 0xFFFF));
        } else if (version == 16) {
            // Only the type index here; the script identity and stripped
            // flag are the shared tail fields written below.
            const type_index = o.type_index orelse return error.MissingTypeIndex;
            try table.writeInt(i32, @intCast(type_index));
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
        2, 3, 4, 5...8 => 16,
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

fn alignTo(w: *streams.Writer, n: usize) error{OutOfMemory}!void {
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

    // Formats outside the supported 2-22 range are refused up front, before
    // any object table is rebuilt, so an unrecognised layout is never
    // written back over the user's file.
    var unsupported = sf;
    unsupported.version = 1;
    try std.testing.expectError(error.UnsupportedFormat, rewrite(a, &unsupported, &.{}));
    unsupported.version = 23;
    try std.testing.expectError(error.UnsupportedFormat, rewrite(a, &unsupported, &.{}));
}

test "parse and rewrite a v4 file byte-exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A minimal SerializedFile v4 (Unity 4.x): one MonoBehaviour (114) with an
    // int field `m_Value`. The header is big-endian; the object data uses the
    // trailing-endianness byte; the type tree is the legacy recursive format
    // with 4-byte-aligned length-prefixed strings (the documented Unity
    // encoding; UnityPy's own legacy parser uses NUL-terminated strings and
    // cannot decode the real format here).
    const bytes = [_]u8{
        0x00, 0x00, 0x00, 0x95, 0x00, 0x00, 0x00, 0xa9, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x10,
        0x07, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00, 0x00, 0x0e, 0x00, 0x00,
        0x00, 0x4d, 0x6f, 0x6e, 0x6f, 0x42, 0x65, 0x68, 0x61, 0x76, 0x69, 0x6f, 0x75, 0x72, 0x00, 0x00,
        0x00, 0x14, 0x00, 0x00, 0x00, 0x42, 0x61, 0x73, 0x65, 0x3c, 0x4d, 0x6f, 0x6e, 0x6f, 0x42, 0x65,
        0x68, 0x61, 0x76, 0x69, 0x6f, 0x75, 0x72, 0x3e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x04, 0x00, 0x00, 0x00, 0x69, 0x6e, 0x74, 0x00, 0x08, 0x00, 0x00, 0x00, 0x6d, 0x5f, 0x56,
        0x61, 0x6c, 0x75, 0x65, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00,
        0x00, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var sf = try serialized.parse(a, &bytes);
    try std.testing.expectEqual(@as(u32, 4), sf.version);
    try std.testing.expectEqual(@as(usize, 1), sf.objects.len);
    const o1 = sf.findObject(1).?;
    try std.testing.expectEqual(@as(i32, 114), o1.class_id);
    try std.testing.expectEqualSlices(u8, "\x07\x00\x00\x00", sf.objectData(o1).?);

    // A no-op rewrite reproduces the file byte-for-byte.
    const out = try rewrite(a, &sf, &.{});
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &bytes, out);
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
    const buf = try a.dupe(u8, "MonoBehaviour\x00Base<MonoBehaviour>\x00int\x00m_Value\x00");
    const buf_len = buf.len;
    const s1 = "MonoBehaviour\x00".len;
    const s2 = s1 + "Base<MonoBehaviour>\x00".len;
    const s3 = s2 + "int\x00".len;

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
    const buf = try a.dupe(u8, "MonoBehaviour\x00Base<MonoBehaviour>\x00int\x00m_Value\x00");
    const buf_len = buf.len;
    const s1 = "MonoBehaviour\x00".len;
    const s2 = s1 + "Base<MonoBehaviour>\x00".len;
    const s3 = s2 + "int\x00".len;

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

test "rewrite v15 and v16 files (entry sizes that are not multiples of 4)" {
    // Formats 15 and 16 are the only ones whose object-table entry is not a
    // multiple of 4 bytes (25 and 23), so the reader's per-entry 4-alignment
    // has to be reproduced between entries, not just before the first one.
    for ([_]u32{ 15, 16 }) |version| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const bytes = try buildLegacyTailFixture(a, version);
        var sf = try serialized.parse(a, bytes);
        try std.testing.expectEqual(version, sf.version);
        try std.testing.expectEqual(@as(usize, 2), sf.objects.len);
        try std.testing.expectEqual(@as(i32, 114), sf.objects[0].class_id);
        try std.testing.expectEqual(@as(i16, -1), sf.objects[0].script_type_index);

        const new_payload = "REPLACED-PAYLOAD";
        const out = try rewrite(a, &sf, &.{.{ .path_id = 100, .data = new_payload }});
        defer a.free(out);

        var sf2 = try serialized.parse(a, out);
        try std.testing.expectEqual(version, sf2.version);
        try std.testing.expectEqual(@as(usize, 2), sf2.objects.len);
        try std.testing.expectEqualStrings(new_payload, sf2.objectData(sf2.findObject(100).?).?);
        try std.testing.expectEqualStrings("DATAONE2", sf2.objectData(sf2.findObject(200).?).?);
        try std.testing.expectEqual(@as(i32, 114), sf2.objects[0].class_id);
        try std.testing.expectEqual(@as(?u32, 0), sf2.objects[0].type_index);
    }
}

/// A MonoBehaviour-only fixture in format 15 or 16: the two versions that
/// carry both the legacy script identity and the stripped flag as object
/// tail fields.
fn buildLegacyTailFixture(a: std.mem.Allocator, version: u32) ![]u8 {
    var meta: streams.Writer = .init(a);
    defer meta.deinit();
    try meta.writeStringToNull("5.3.0f1");
    try meta.writeInt(i32, 5); // target platform
    try meta.writeByte(1); // enable type tree
    try meta.writeInt(i32, 1); // type count
    try meta.writeInt(i32, 114); // class MonoBehaviour
    if (version >= 16) {
        try meta.writeByte(0); // is_stripped
        try meta.writeBytes(&[_]u8{0} ** 16); // script id (class 114)
    }
    try meta.writeBytes(&[_]u8{0} ** 16); // old type hash
    try writeMonoTree(&meta, a);

    try meta.writeInt(i32, 2); // object count
    const path_ids = [_]i64{ 100, 200 };
    const sizes = [_]u32{ 5, 8 };
    const starts = [_]u32{ 0, 8 };
    for (path_ids, 0..) |path_id, i| {
        try meta.alignTo4();
        try meta.writeInt(i64, path_id);
        try meta.writeInt(u32, starts[i]);
        try meta.writeInt(u32, sizes[i]);
        if (version < 16) {
            try meta.writeInt(i32, 114); // type id, matched by class id
            try meta.writeInt(u16, 114); // class bits
        } else {
            try meta.writeInt(i32, 0); // type index
        }
        try meta.writeInt(i16, -1); // script type index
        try meta.writeByte(0); // stripped
    }
    try meta.writeInt(i32, 0); // script types
    try meta.writeInt(i32, 0); // externals
    try meta.writeStringToNull("user info here");

    const header_size: usize = 20;
    const meta_len: u32 = @intCast(meta.getWritten().len);
    const data_offset: u64 = header_size + meta_len;
    const data = "DATA0" ++ "\x00\x00\x00" ++ "DATAONE2";
    const file_size: u64 = data_offset + data.len;

    var out: streams.Writer = .init(a);
    defer out.deinit();
    const be = std.builtin.Endian.big;
    try out.writeIntWith(u32, meta_len, be);
    try out.writeIntWith(u32, @intCast(file_size), be);
    try out.writeIntWith(u32, version, be);
    try out.writeIntWith(u32, @intCast(data_offset), be);
    try out.writeByte(0); // little endian
    try out.writeBytes(&[_]u8{ 0, 0, 0 });
    try out.writeBytes(meta.getWritten());
    try out.writeBytes(data);
    return a.dupe(u8, out.getWritten());
}

test "rewrite survives mutated parsed files and hostile replacements" {
    // The rewrite path must never crash: (a) rewriting a mutated-but-
    // parseable v22 file (the #62-style input) must produce bytes or an
    // error, and (b) random replacement payloads of varied sizes must not
    // overflow the length fields or fault.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v22 = try buildV22Fixture(a);
    var prng = std.Random.DefaultPrng.init(0x77e2);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        // (a) mutated parseable file, no replacements
        const mode = rnd.int(u8) % 3;
        const blen = switch (mode) {
            0 => rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(v22.len))),
            1 => v22.len,
            else => rnd.intRangeAtMost(u32, 0, 128),
        };
        @memcpy(buf[0..v22.len], v22);
        if (mode == 1 and v22.len > 0) {
            const m = rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(v22.len - 1)));
            buf[m] ^= @intCast(rnd.int(u8) | 1);
        } else if (mode == 2 and blen > 0) {
            rnd.bytes(buf[0..blen]);
        }
        const sf = serialized.parse(a, buf[0..blen]) catch continue;
        const out = rewrite(a, &sf, &.{}) catch continue;
        // the output must be a well-formed buffer we can at least walk
        if (out.len > 0) _ = serialized.parse(a, out) catch {};
        // (b) random replacement payload for object 100
        const repl_len: usize = @intCast(rnd.intRangeAtMost(u32, 0, 4096));
        rnd.bytes(buf[0..repl_len]);
        const out2 = rewrite(a, &sf, &.{.{ .path_id = 100, .data = buf[0..repl_len] }}) catch continue;
        if (out2.len > 0) _ = serialized.parse(a, out2) catch {};
    }
}

// ---------------------------------------------------------------------------
// Creation from empty state (format 22, the layout Unity 2022.3 writes).
// ---------------------------------------------------------------------------

const typetree = @import("typetree.zig");

pub const CreateError = error{
    NoObjects,
    NoTypes,
    ZeroPathId,
    DuplicatePathId,
    TypeIndexOutOfRange,
    UnsupportedEncoding,
    TooDeep,
    OutOfMemory,
};

pub const CreateType = struct {
    class_id: i32,
    tree: *const typetree.TypeTree,
};

pub const CreateObject = struct {
    path_id: i64,
    /// Index into `CreateSpec.types`.
    type_index: u32,
    /// The object's serialized bytes (from `object_writer.writeObject`).
    data: []const u8,
};

pub const CreateSpec = struct {
    unity_version: []const u8,
    target_platform: i32,
    types: []const CreateType,
    objects: []const CreateObject,
    /// External file references (`PPtr.m_FileID` > 0 indexes them 1-based).
    externals: []const []const u8 = &.{},
};

/// The format-22 file version `create` writes.
pub const create_version: u32 = 22;
/// Object data alignment in created files, as Unity 2022.3 writes.
pub const create_data_align: usize = 8;

/// Builds a brand-new little-endian format-22 SerializedFile: type trees
/// embedded (old type hashes zero, no dependencies), a 4-aligned object
/// table, no script or reference types, the given externals, empty user
/// information. Objects are laid out 8-aligned in declaration order. The
/// caller owns the returned bytes.
pub fn create(allocator: std.mem.Allocator, spec: CreateSpec) CreateError![]u8 {
    if (spec.types.len == 0) return error.NoTypes;
    if (spec.objects.len == 0) return error.NoObjects;
    for (spec.objects, 0..) |o, i| {
        if (o.path_id == 0) return error.ZeroPathId;
        if (o.type_index >= spec.types.len) return error.TypeIndexOutOfRange;
        for (spec.objects[0..i]) |prev| if (prev.path_id == o.path_id) return error.DuplicatePathId;
    }

    var meta: streams.Writer = .init(allocator);
    defer meta.deinit();
    try meta.writeStringToNull(spec.unity_version);
    try meta.writeInt(i32, spec.target_platform);
    try meta.writeByte(1); // type trees embedded
    try meta.writeInt(i32, @intCast(spec.types.len));
    for (spec.types) |t| {
        try meta.writeInt(i32, t.class_id);
        try meta.writeByte(0); // not stripped
        try meta.writeInt(i16, -1); // no script type
        if (t.class_id == 114) try meta.writeBytes(&[_]u8{0} ** 16); // script id
        try meta.writeBytes(&[_]u8{0} ** 16); // old type hash
        try typetree.writeBlob(&meta, t.tree, create_version);
        try meta.writeInt(i32, 0); // type dependencies
    }

    var data: streams.Writer = .init(allocator);
    defer data.deinit();
    try meta.writeInt(i32, @intCast(spec.objects.len));
    for (spec.objects) |o| {
        try alignTo(&data, create_data_align);
        try meta.alignTo4();
        try meta.writeInt(i64, o.path_id);
        try meta.writeInt(i64, @intCast(data.getWritten().len));
        try meta.writeInt(u32, @intCast(o.data.len));
        try meta.writeInt(u32, o.type_index);
        try data.writeBytes(o.data);
    }
    try meta.writeInt(i32, 0); // script types
    try meta.writeInt(i32, @intCast(spec.externals.len));
    for (spec.externals) |path| {
        try meta.writeStringToNull(""); // temp_empty
        try meta.writeBytes(&[_]u8{0} ** 16); // guid
        try meta.writeInt(i32, 0); // type
        try meta.writeStringToNull(path);
    }
    try meta.writeInt(i32, 0); // reference types
    try meta.writeStringToNull(""); // user information

    const header_size = headerSize(create_version);
    const meta_len = meta.getWritten().len;
    const data_offset = alignUp(header_size + meta_len, create_data_align);
    const file_size = data_offset + data.getWritten().len;

    var out: streams.Writer = .init(allocator);
    defer out.deinit();
    const be = std.builtin.Endian.big;
    try out.writeIntWith(u32, 0, be); // legacy metadata size
    try out.writeIntWith(u32, 0, be); // legacy file size
    try out.writeIntWith(u32, create_version, be);
    try out.writeIntWith(u32, 0, be); // legacy data offset
    try out.writeByte(0); // little endian
    try out.writeBytes(&[_]u8{ 0, 0, 0 });
    try out.writeIntWith(u32, @intCast(meta_len), be);
    try out.writeIntWith(i64, @intCast(file_size), be);
    try out.writeIntWith(i64, @intCast(data_offset), be);
    try out.writeIntWith(i64, 0, be);
    try out.writeBytes(meta.getWritten());
    for (0..@intCast(data_offset - header_size - meta_len)) |_| try out.writeByte(0);
    try out.writeBytes(data.getWritten());
    return allocator.dupe(u8, out.getWritten());
}

test "create builds a parseable v22 file whose objects round-trip" {
    const object_reader = @import("object_reader.zig");
    const object_writer = @import("object_writer.zig");
    const value = @import("value.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat = [_]typetree.Node{
        .{ .level = 0, .type_name = "TextAsset", .name = "Base", .byte_size = -1 },
        .{ .level = 1, .type_name = "string", .name = "m_Name", .byte_size = -1, .meta_flags = 0x4000 },
        .{ .level = 2, .type_name = "Array", .name = "Array", .byte_size = -1, .meta_flags = 0x4000 },
        .{ .level = 3, .type_name = "int", .name = "size", .byte_size = 4 },
        .{ .level = 3, .type_name = "char", .name = "data", .byte_size = 1 },
        .{ .level = 1, .type_name = "string", .name = "m_Script", .byte_size = -1, .meta_flags = 0x4000 },
        .{ .level = 2, .type_name = "Array", .name = "Array", .byte_size = -1, .meta_flags = 0x4000 },
        .{ .level = 3, .type_name = "int", .name = "size", .byte_size = 4 },
        .{ .level = 3, .type_name = "char", .name = "data", .byte_size = 1 },
    };
    const tree = try typetree.fromFlatNodes(a, &flat);

    const v: value.Value = .{ .obj = &.{
        .{ .name = "m_Name", .value = .{ .string = "hello" } },
        .{ .name = "m_Script", .value = .{ .string = "payload text" } },
    } };
    var ow: streams.Writer = .init(a);
    defer ow.deinit();
    try object_writer.writeObject(&ow, &tree.roots[0], v, "");

    const types = [_]CreateType{.{ .class_id = 49, .tree = &tree }};
    const objects = [_]CreateObject{
        .{ .path_id = 1, .type_index = 0, .data = ow.getWritten() },
        .{ .path_id = 7, .type_index = 0, .data = ow.getWritten() },
    };
    const bytes = try create(a, .{ .unity_version = "2022.3.62f2", .target_platform = 19, .types = &types, .objects = &objects, .externals = &.{"library/unity default resources"} });

    const sf = try serialized.parse(a, bytes);
    try std.testing.expectEqual(@as(u32, 22), sf.version);
    try std.testing.expectEqual(streams.Endian.little, sf.endian);
    try std.testing.expectEqualStrings("2022.3.62f2", sf.unity_version);
    try std.testing.expectEqual(@as(i32, 19), sf.target_platform);
    try std.testing.expect(sf.enable_type_tree);
    try std.testing.expectEqual(@as(usize, 1), sf.types.len);
    try std.testing.expectEqual(@as(i32, 49), sf.types[0].class_id);
    try std.testing.expectEqual(@as(usize, 2), sf.objects.len);
    try std.testing.expectEqual(@as(i64, 7), sf.objects[1].path_id);
    try std.testing.expectEqual(@as(u64, 0), sf.data_offset % 8);
    try std.testing.expectEqual(@as(u64, 0), sf.objects[1].byte_start % 8);
    try std.testing.expectEqual(@as(usize, 1), sf.externals.len);
    try std.testing.expectEqualStrings("library/unity default resources", sf.externals[0].path);
    try std.testing.expectEqual(bytes.len, @as(usize, @intCast(sf.file_size)));

    // the embedded tree decodes the object back to the same value
    const data = sf.objectData(&sf.objects[1]).?;
    var r = streams.Reader.init(data);
    const back = try object_reader.readObject(a, &r, &sf.types[0].type_tree.roots[0]);
    try std.testing.expectEqualStrings("payload text", value.fieldOf(back, "m_Script").?.string);
    // and the rewrite path accepts the created file (one more consumer)
    _ = try rewrite(a, &sf, &.{});
}

test "create rejects malformed specs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const flat = [_]typetree.Node{.{ .level = 0, .type_name = "Object", .name = "Base" }};
    const tree = try typetree.fromFlatNodes(a, &flat);
    const types = [_]CreateType{.{ .class_id = 0, .tree = &tree }};
    const one = [_]CreateObject{.{ .path_id = 1, .type_index = 0, .data = "" }};
    const base: CreateSpec = .{ .unity_version = "2022.3.62f2", .target_platform = 19, .types = &types, .objects = &one };

    var s = base;
    s.types = &.{};
    try std.testing.expectError(error.NoTypes, create(a, s));
    s = base;
    s.objects = &.{};
    try std.testing.expectError(error.NoObjects, create(a, s));
    s = base;
    s.objects = &.{.{ .path_id = 0, .type_index = 0, .data = "" }};
    try std.testing.expectError(error.ZeroPathId, create(a, s));
    s = base;
    s.objects = &.{ .{ .path_id = 3, .type_index = 0, .data = "" }, .{ .path_id = 3, .type_index = 0, .data = "" } };
    try std.testing.expectError(error.DuplicatePathId, create(a, s));
    s = base;
    s.objects = &.{.{ .path_id = 1, .type_index = 1, .data = "" }};
    try std.testing.expectError(error.TypeIndexOutOfRange, create(a, s));
}
