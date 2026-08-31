//! UnityFS bundle parser — the modern Unity asset bundle container
//! (`UnityFS\0` magic, format version 6+).
//!
//! Layout (from the public UnityFS format docs):
//!
//! ```text
//! header (all big-endian, like the rest of the container):
//!   signature            null-terminated string ("UnityFS\0" or legacy
//!                        "UnityWeb\0"/"UnityRaw\0" — legacy is unsupported)
//!   version              u32
//!   unity_version        null-terminated string  (version >= 7)
//!   unity_revision       null-terminated string  (version >= 7)
//!   size                 i64   (total bundle file size)
//!   compressed_block_size   u32
//!   uncompressed_block_size u32
//!   flags                u32
//!                         bits 0-5  compression of the header info
//!                                   (0 none, 1 lzma, 2 lz4, 3 lz4hc, 4 lzham)
//!                         bit  6    blocks + directory info combined at start
//!                         bit  7    header info stored at the END of file
//!                         bit  9    block data padded to 16 bytes
//!   (version >= 7: padded to a 16-byte boundary)
//! [header info (decompressed, big-endian):]
//!   16-byte data hash
//!   block_count          u32
//!   blocks[block_count]  10 bytes each:
//!                         uncompressed_size u32, compressed_size u32,
//!                         flags u16 (bit 0 = compressed with header type)
//!   node_count           u32
//!   nodes[node_count]:
//!                         offset i64, size i64, flags u32,
//!                         path null-terminated string
//!   (version >= 7: optional trailing u64 total file size)
//! [block data: concatenated blocks]
//! ```
//!
//! A block's flag bit 0 means "compressed with the header's compression
//! type"; when clear the block is stored raw. Some writers store an
//! explicit per-block compression type in the low 6 bits instead; both
//! readings are honored (the explicit type wins only when bit 0 is clear).
//!
//! Node data slices borrow from the concatenated decompressed block stream,
//! which `Bundle` owns.

const std = @import("std");
const streams = @import("streams.zig");
const container = @import("container.zig");
const lz4 = @import("lz4.zig");

pub const CompressionType = enum(u32) {
    none = 0,
    lzma = 1,
    lz4 = 2,
    lz4hc = 3,
    lzham = 4,
    _,
};

pub const header_flag_info_at_end: u32 = 0x80;
pub const header_flag_combined: u32 = 0x40;
pub const header_flag_pad_block_data: u32 = 0x200;

pub const Block = struct {
    compressed_size: u32,
    uncompressed_size: u32,
    flags: u16,
};

pub const Node = struct {
    offset: i64,
    size: i64,
    flags: u32,
    path: []const u8,
    /// Borrowed from `Bundle.stream`; empty when the node is streamed or
    /// its declared range falls outside the block stream (corrupt file).
    data: []const u8 = &.{},
};

pub const Bundle = struct {
    version: u32,
    unity_version: []const u8 = "",
    unity_revision: []const u8 = "",
    size: i64,
    flags: u32,
    blocks: []Block,
    nodes: []Node,
    /// Decompressed header info; node paths borrow from it.
    header_info: []u8,
    /// Concatenated decompressed blocks; node data borrows from it.
    stream: []u8,

    pub fn deinit(self: *Bundle, allocator: std.mem.Allocator) void {
        allocator.free(self.header_info);
        allocator.free(self.stream);
        allocator.free(self.blocks);
        allocator.free(self.nodes);
    }

    /// Finds the node with the given path, or null.
    pub fn findNode(self: *const Bundle, path: []const u8) ?*const Node {
        for (self.nodes) |*n| {
            if (std.mem.eql(u8, n.path, path)) return n;
        }
        return null;
    }
};

pub const ParseError = error{
    BadSignature,
    ShortData,
    OutOfBounds,
    UnsupportedVersion,
    UnsupportedCompression,
    DecompressFailed,
    Corrupt,
    OutOfMemory,
};

/// Guards against absurd counts in the header info.
const max_entries: u32 = 1 << 20;

/// Pads the reader position up to a multiple of `n` (16-byte alignment
/// used by UnityFS v7+).
fn alignTo(r: *streams.Reader, n: usize) ParseError!void {
    const rem = r.position() % n;
    if (rem != 0) try r.skip(n - rem);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!Bundle {
    if (data.len < 8) return error.ShortData;
    var r = streams.Reader.init(data);

    const signature = try r.readStringToNull();
    if (!std.mem.eql(u8, signature, "UnityFS")) {
        if (std.mem.eql(u8, signature, "UnityWeb") or std.mem.eql(u8, signature, "UnityRaw"))
            return error.UnsupportedVersion; // legacy bundles are a later milestone
        return error.BadSignature;
    }

    // UnityFS container fields are big-endian (the serialized files inside
    // carry their own endianness byte).
    r.endian = .big;

    const version = try r.readInt(u32);
    if (version < 6) return error.UnsupportedVersion;

    var unity_version: []const u8 = "";
    var unity_revision: []const u8 = "";
    // UnityPy reads both strings for every UnityFS version, including the
    // format-6 bundles produced by Unity 5.x/2017/2018 (earlier code only
    // read them for >= 7, misparsing v6 headers).
    unity_version = try r.readStringToNull();
    unity_revision = try r.readStringToNull();

    const size = try r.readInt(i64);
    const compressed_block_size = try r.readInt(u32);
    const uncompressed_block_size = try r.readInt(u32);
    const flags = try r.readInt(u32);

    // Format version 7+ pads the header to a 16-byte boundary.
    if (version >= 7) try alignTo(&r, 16);
    const block_data_start = r.position();

    const header_info_at_end = (flags & header_flag_info_at_end) != 0;
    if (compressed_block_size > data.len) return error.ShortData;
    const header_info_offset: usize = if (header_info_at_end)
        data.len - compressed_block_size
    else
        block_data_start;
    var block_data_offset: usize = if (header_info_at_end)
        block_data_start
    else
        header_info_offset + compressed_block_size;
    if (block_data_offset > data.len) return error.ShortData;

    const header_compressed = data[header_info_offset .. header_info_offset + compressed_block_size];
    const header_info = try decompressRaw(
        allocator,
        header_compressed,
        uncompressed_block_size,
        compressionType(flags),
    );
    errdefer allocator.free(header_info);

    // Empty until allocated, with function-scope errdefers: a block-scoped
    // errdefer is discharged when the block below exits normally, which
    // would leak both tables on every error raised after it (short block
    // data, a failed block decompress, ...). Freeing an empty slice is a
    // no-op, so the errdefers are safe before the allocations happen.
    var blocks: []Block = &.{};
    var nodes: []Node = &.{};
    errdefer allocator.free(blocks);
    errdefer allocator.free(nodes);
    {
        var hr = streams.Reader.init(header_info);
        hr.endian = .big;
        try hr.skip(16); // uncompressed data hash
        const block_count = try hr.readInt(u32);
        if (block_count > max_entries) return error.Corrupt;
        blocks = try allocator.alloc(Block, block_count);
        for (blocks) |*b| {
            b.uncompressed_size = try hr.readInt(u32);
            b.compressed_size = try hr.readInt(u32);
            b.flags = try hr.readInt(u16);
        }

        const node_count = try hr.readInt(u32);
        if (node_count > max_entries) return error.Corrupt;
        nodes = try allocator.alloc(Node, node_count);
        for (nodes) |*n| {
            // `alloc` does not apply the struct's field defaults, so `data`
            // has to be set here: a node whose range is rejected below would
            // otherwise be handed out as an undefined slice.
            n.data = &.{};
            n.offset = try hr.readInt(i64);
            n.size = try hr.readInt(i64);
            n.flags = try hr.readInt(u32);
            n.path = try hr.readStringToNull();
        }
        // Version >= 7 files may append a u64 total file size after the
        // nodes; read it only when it is exactly the remaining content.
        if (version >= 7 and hr.remaining() == 8) _ = try hr.readInt(u64);
    }

    // Some writers pad the block data to a 16-byte boundary after the info.
    if (!header_info_at_end and (flags & header_flag_pad_block_data) != 0) {
        block_data_offset = (block_data_offset + 15) & ~@as(usize, 15);
        if (block_data_offset > data.len) return error.ShortData;
    }

    // Concatenate the decompressed blocks into one stream.
    var total: usize = 0;
    for (blocks) |b| total += b.uncompressed_size;
    const stream = try allocator.alloc(u8, total);
    errdefer allocator.free(stream);

    var out_pos: usize = 0;
    var in_pos: usize = 0;
    for (blocks) |b| {
        const end = block_data_offset + in_pos + b.compressed_size;
        if (end > data.len) return error.ShortData;
        const raw = data[block_data_offset + in_pos .. end];
        in_pos += b.compressed_size;

        const out = try decompressRaw(allocator, raw, b.uncompressed_size, blockCompressionType(b.flags));
        defer allocator.free(out);
        // A block that decodes short would leave the rest of `stream`
        // uninitialized, and nodes may point at it: reject instead of
        // handing out uninitialized heap.
        if (out.len != b.uncompressed_size) return error.Corrupt;
        @memcpy(stream[out_pos .. out_pos + out.len], out);
        out_pos += out.len;
    }

    for (nodes) |*n| {
        // offset/size come straight from the header info; a negative or
        // overflowing range must not wrap into an in-bounds slice.
        if (n.offset < 0 or n.size < 0) continue;
        const off: usize = @intCast(n.offset);
        const len: usize = @intCast(n.size);
        const end = std.math.add(usize, off, len) catch continue;
        if (end <= stream.len) n.data = stream[off..end];
    }

    return .{
        .version = version,
        .unity_version = unity_version,
        .unity_revision = unity_revision,
        .size = size,
        .flags = flags,
        .blocks = blocks,
        .nodes = nodes,
        .header_info = header_info,
        .stream = stream,
    };
}

/// One node's replacement data for `rebuild`.
pub const NodeReplacement = struct {
    path: []const u8,
    data: []const u8,
};

/// Rebuilds a UnityFS bundle with the given node payloads replaced.
/// Writes a single uncompressed block (flags 0), which is valid UnityFS;
/// avoids needing an LZ4/LZMA encoder. The header keeps the source
/// bundle's version and Unity version strings; the 16-byte data hash is
/// written as zeros (parsers accept it). The caller owns the returned
/// bytes.
pub fn rebuild(allocator: std.mem.Allocator, b: *const Bundle, replacements: []const NodeReplacement) ![]u8 {
    // resolve the new node payloads
    const data = allocator.alloc([]const u8, b.nodes.len) catch return error.OutOfMemory;
    defer allocator.free(data);
    for (b.nodes, 0..) |n, i| {
        data[i] = n.data;
        for (replacements) |r| {
            if (std.mem.eql(u8, r.path, n.path)) {
                data[i] = r.data;
                break;
            }
        }
    }

    var total: usize = 0;
    for (data) |d| total += d.len;

    // header info (big endian)
    var info: streams.Writer = .init(allocator);
    defer info.deinit();
    info.endian = .big;
    try info.writeBytes(&[_]u8{0} ** 16); // data hash
    try info.writeInt(u32, 1); // one block
    try info.writeInt(u32, @intCast(total));
    try info.writeInt(u32, @intCast(total));
    try info.writeInt(u16, 0); // block flags: uncompressed
    try info.writeInt(u32, @intCast(b.nodes.len));
    var offset: u64 = 0;
    for (b.nodes, 0..) |n, i| {
        try info.writeInt(i64, @intCast(offset));
        try info.writeInt(i64, @intCast(data[i].len));
        try info.writeInt(u32, n.flags);
        try info.writeStringToNull(n.path);
        offset += data[i].len;
    }
    const info_bytes = info.getWritten();

    // header
    var out: streams.Writer = .init(allocator);
    defer out.deinit();
    out.endian = .big;
    try out.writeStringToNull("UnityFS");
    try out.writeInt(u32, b.version);
    if (b.version >= 7) {
        try out.writeStringToNull(b.unity_version);
        try out.writeStringToNull(b.unity_revision);
    }
    try out.writeInt(i64, 0); // size placeholder
    try out.writeInt(u32, @intCast(info_bytes.len));
    try out.writeInt(u32, @intCast(info_bytes.len));
    try out.writeInt(u32, 0); // flags: uncompressed, info at start
    if (b.version >= 7) {
        const rem = out.getWritten().len % 16;
        for (0..(16 - rem) % 16) |_| try out.writeByte(0);
    }
    try out.writeBytes(info_bytes);
    for (data) |d| try out.writeBytes(d);

    // patch the size field: after signature(8) + version(4) [+ unity + revision]
    var size_off: usize = 12;
    if (b.version >= 7) {
        size_off += b.unity_version.len + 1;
        size_off += b.unity_revision.len + 1;
    }
    const written = out.getWritten();
    var fixed = try allocator.dupe(u8, written);
    std.mem.writeInt(i64, fixed[size_off..][0..8], @intCast(fixed.len), .big);
    return fixed;
}

fn compressionType(flags: u32) CompressionType {
    return @enumFromInt(flags & 0x3F);
}

/// Block-level compression: each block carries its own compression in the
/// low 6 bits of its flags (0 none, 1 LZMA, 2 LZ4, 3 LZ4HC), independent
/// of the header's compression (verified against UnityPy, which decodes
/// every block with `flags & 0x3F`).
fn blockCompressionType(block_flags: u16) CompressionType {
    return @enumFromInt(block_flags & 0x3F);
}

/// Decompresses `raw` to `uncompressed_size` bytes using `ctype`.
fn decompressRaw(
    allocator: std.mem.Allocator,
    raw: []const u8,
    uncompressed_size: u32,
    ctype: CompressionType,
) ParseError![]u8 {
    return switch (ctype) {
        .none => blk: {
            if (raw.len != uncompressed_size) return error.Corrupt;
            break :blk allocator.dupe(u8, raw) catch return error.OutOfMemory;
        },
        .lz4, .lz4hc => lz4.decompress(allocator, raw, uncompressed_size) catch return error.DecompressFailed,
        .lzma => lzmaDecompress(allocator, raw, uncompressed_size) catch return error.DecompressFailed,
        .lzham => error.UnsupportedCompression,
        else => error.UnsupportedCompression,
    };
}

/// LZMA block. Unity's native framing is props(1) + dict size(4) + the
/// stream (no size field — the block table knows the output size); some
/// writers include the 8-byte unpacked size (the `.lzma` container). Both
/// are normalized to a 13-byte header before decoding: the header's dict
/// field is raised to at least the output size, because std's lzma
/// circular buffer mis-decodes streams whose output exceeds the dict
/// (verified against UnityPy: a 2 MB block with a 512 KB dict fails with
/// std but decodes cleanly with the reference decoder). The first range
/// byte is ignored by the reference decoder, so a non-zero value is
/// normalized to 0x00 for std's stricter check.
fn lzmaDecompress(allocator: std.mem.Allocator, raw: []const u8, uncompressed_size: u32) ![]u8 {
    const lzma = std.compress.lzma;
    var last_err: ?anyerror = null;
    for ([_]usize{ 5, 13 }) |data_off| {
        if (raw.len < data_off) continue;
        var syn: [13]u8 = undefined;
        syn[0] = raw[0];
        const hdr_dict = std.mem.readInt(u32, raw[1..5], .little);
        std.mem.writeInt(u32, syn[1..5], @max(hdr_dict, uncompressed_size), .little);
        std.mem.writeInt(u64, syn[5..13], uncompressed_size, .little);
        const owned = try allocator.alloc(u8, 13 + (raw.len - data_off));
        defer allocator.free(owned);
        @memcpy(owned[0..13], &syn);
        @memcpy(owned[13..], raw[data_off..]);
        if (owned.len > 13 and owned[13] != 0) owned[13] = 0;
        var input = std.Io.Reader.fixed(owned);
        var decomp = lzma.Decompress.initOptions(
            &input,
            allocator,
            try allocator.alloc(u8, 0),
            .{ .unpacked_size = .{ .read_header_but_use_provided = uncompressed_size } },
            std.math.maxInt(u32),
        ) catch |e| {
            last_err = e;
            continue;
        };
        defer decomp.deinit();
        const out = decomp.reader.readAlloc(allocator, uncompressed_size) catch |e| {
            last_err = e;
            continue;
        };
        // `readAlloc` treats the size as a ceiling, so a truncated stream
        // decodes "successfully" but short. The block table declares the
        // exact size and `parse` sizes its concatenated buffer from it, so a
        // short block would leave that buffer's tail uninitialized. Reject
        // it here, like the `.none` and lz4 branches of `decompressRaw` do,
        // and let the other framing offset have its turn.
        if (out.len != uncompressed_size) {
            allocator.free(out);
            last_err = error.EndOfStream;
            continue;
        }
        return out;
    }
    return last_err orelse error.DecompressFailed;
}

test "parse an uncompressed unityfs bundle, info at start" {
    const a = std.testing.allocator;
    const payload = "CAB-abcdefgh";

    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .none,
        .payload = payload,
        .payload_path = "CAB-abc",
    });
    defer a.free(bundle_bytes);

    var b = try parse(a, bundle_bytes);
    defer b.deinit(a);

    try std.testing.expectEqual(@as(u32, 7), b.version);
    try std.testing.expectEqualStrings("2020.3.33f1", b.unity_version);
    try std.testing.expectEqual(@as(usize, 1), b.nodes.len);
    try std.testing.expectEqualStrings("CAB-abc", b.nodes[0].path);
    try std.testing.expectEqualStrings(payload, b.nodes[0].data);
    try std.testing.expect(b.findNode("CAB-abc") != null);
    try std.testing.expect(b.findNode("nope") == null);
}

test "parse an lz4-compressed unityfs bundle, info at end" {
    const a = std.testing.allocator;
    // "ab" + match len 18 at offset 2 → "ab" x10
    const lz4_compressed = [_]u8{ 0x2E, 'a', 'b', 0x02, 0x00 };
    const payload = "abababababababababab";

    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = true,
        .compression = .lz4,
        .payload = payload,
        .payload_path = "CAB-abc",
        .raw_block = &lz4_compressed,
        .block_flags = 0x02, // LZ4: blocks carry their own compression
    });
    defer a.free(bundle_bytes);

    var b = try parse(a, bundle_bytes);
    defer b.deinit(a);

    try std.testing.expectEqual(@as(u32, 7), b.version);
    try std.testing.expectEqual(@as(u32, 0x82), b.flags);
    try std.testing.expectEqualStrings(payload, b.nodes[0].data);
    try std.testing.expectEqualStrings("2020.3.33f1", b.unity_version);
}

test "rebuild replaces a node and stays parseable" {
    const a = std.testing.allocator;

    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .none,
        .payload = "CAB-abcdefgh",
        .payload_path = "CAB-abc",
    });
    defer a.free(bundle_bytes);

    var b = try parse(a, bundle_bytes);
    defer b.deinit(a);

    const rebuilt = try rebuild(a, &b, &.{.{ .path = "CAB-abc", .data = "NEWDATA" }});
    defer a.free(rebuilt);

    var b2 = try parse(a, rebuilt);
    defer b2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), b2.nodes.len);
    try std.testing.expectEqualStrings("NEWDATA", b2.nodes[0].data);
    try std.testing.expectEqualStrings(b.unity_version, b2.unity_version);
    try std.testing.expectEqual(b.version, b2.version);
    // an untouched rebuild reproduces the node payload byte-for-byte
    const rebuilt2 = try rebuild(a, &b, &.{});
    defer a.free(rebuilt2);
    var b3 = try parse(a, rebuilt2);
    defer b3.deinit(a);
    try std.testing.expectEqualStrings("CAB-abcdefgh", b3.nodes[0].data);
}

test "parse rejects bad signature" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadSignature, parse(a, "NotAUnityFS\x00rest"));
}

test "parse rejects legacy bundles for now" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedVersion, parse(a, "UnityWeb\x00\x00\x00\x00\x00"));
}

test "parse rejects truncated file" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "UnityFS\x00");
    try buf.appendSlice(a, &[_]u8{ 0x07, 0x00, 0x00, 0x00 }); // version 7
    try std.testing.expectError(error.OutOfBounds, parse(a, buf.items));
}

test "parse rejects unsupported compression" {
    const a = std.testing.allocator;
    // build an uncompressed bundle, then lie about the header compression:
    // the header info is stored raw but the flags claim LZHAM
    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .none,
        .payload = "data",
        .payload_path = "CAB-x",
        .header_flags_override = 0x04,
    });
    defer a.free(bundle_bytes);
    try std.testing.expectError(error.UnsupportedCompression, parse(a, bundle_bytes));
}

test "parse a format-6 bundle (two version strings in the header)" {
    const a = std.testing.allocator;
    // format-6 bundles (Unity 5.x/2017/2018) carry both version strings,
    // like v7+; the parser must read them for every UnityFS version.
    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .none,
        .payload = "v6 payload",
        .payload_path = "CAB-x",
        .version = 6,
    });
    defer a.free(bundle_bytes);
    var b = try parse(a, bundle_bytes);
    defer b.deinit(a);
    try std.testing.expectEqual(@as(u32, 6), b.version);
    try std.testing.expectEqualStrings("2020.3.33f1", b.unity_version);
    try std.testing.expectEqualStrings("revision", b.unity_revision);
}

test "block flags carry their own compression, overriding the header" {
    const a = std.testing.allocator;
    // header says uncompressed, but the block's own flags say LZ4 and the
    // block bytes are LZ4-compressed: the block must decode as LZ4
    // (UnityPy decodes every block with `flags & 0x3F`).
    const payload = "lz4 block payload";
    const compressed = try lz4CompressLiterals(a, payload);
    defer a.free(compressed);
    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .none,
        .payload = payload,
        .payload_path = "CAB-x",
        .raw_block = compressed,
        .block_flags = 2, // LZ4
    });
    defer a.free(bundle_bytes);
    var b = try parse(a, bundle_bytes);
    defer b.deinit(a);
    try std.testing.expectEqualStrings(payload, b.nodes[0].data);
}

// ---------------------------------------------------------------------------
// Fixture builder (tests only): frames a payload as a one-block, one-node
// UnityFS v7 bundle with the requested layout. The header info is stored
// with the header's declared compression.
// ---------------------------------------------------------------------------

const Fixture = struct {
    info_at_end: bool,
    compression: CompressionType,
    payload: []const u8,
    payload_path: []const u8,
    raw_block: ?[]const u8 = null,
    block_flags: u16 = 0,
    /// When set, replaces the computed header flags (for corruption tests).
    header_flags_override: ?u32 = null,
    /// Format version to write in the header; the version strings are
    /// always present (they are read unconditionally for every UnityFS
    /// version, including the format-6 bundles of Unity 5.x/2017/2018).
    version: u32 = 7,
};

/// Appends a big-endian integer to the fixture buffer (tests only).
fn appendBe(a: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &bytes, value, .big);
    try out.appendSlice(a, &bytes);
}

fn buildBundleFixture(a: std.mem.Allocator, f: Fixture) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    // header info (big-endian): 16-byte hash, 1 block, 1 node,
    // trailing u64 (version >= 7)
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(a);
    try info.appendSlice(a, &[_]u8{0} ** 16); // data hash
    try appendBe(a, &info, @as(u32, 1)); // block count
    try appendBe(a, &info, @as(u32, @intCast(f.payload.len))); // uncompressed
    try appendBe(a, &info, @as(u32, @intCast(if (f.raw_block) |r| r.len else f.payload.len))); // compressed
    try appendBe(a, &info, f.block_flags);
    try appendBe(a, &info, @as(u32, 1)); // node count
    try appendBe(a, &info, @as(i64, 0)); // offset
    try appendBe(a, &info, @as(i64, @intCast(f.payload.len))); // size
    try appendBe(a, &info, @as(u32, 0)); // flags
    try info.appendSlice(a, f.payload_path);
    try info.appendSlice(a, &[_]u8{0}); // NUL
    try appendBe(a, &info, @as(i64, @intCast(f.payload.len))); // trailing total size

    // the header info is stored with the header's declared compression
    const owned_info: ?[]u8 = switch (f.compression) {
        .none => null,
        .lz4, .lz4hc => try lz4CompressLiterals(a, info.items),
        else => return error.TestUnsupportedCompressionForFixture,
    };
    defer if (owned_info) |oi| a.free(oi);
    const stored_info = owned_info orelse info.items;
    const stored_info_size: u32 = @intCast(stored_info.len);

    // block data (compressed form when provided, else the raw payload)
    const block_data: []const u8 = if (f.raw_block) |r| r else f.payload;

    // header (big-endian, padded to 16 bytes after the flags)
    try out.appendSlice(a, "UnityFS\x00");
    try appendBe(a, &out, f.version);
    try out.appendSlice(a, "2020.3.33f1\x00");
    try out.appendSlice(a, "revision\x00");
    var flags: u32 = @intFromEnum(f.compression);
    if (f.info_at_end) flags |= header_flag_info_at_end;
    if (f.header_flags_override) |override_flags| flags = override_flags;
    try appendBe(a, &out, @as(i64, 0)); // size, filled later
    try appendBe(a, &out, stored_info_size);
    try appendBe(a, &out, @as(u32, @intCast(info.items.len))); // uncompressed
    try appendBe(a, &out, flags);
    while (out.items.len % 16 != 0) try out.append(a, 0);

    // layout order depends on where the header info lives
    if (f.info_at_end) {
        try out.appendSlice(a, block_data);
        try out.appendSlice(a, stored_info);
    } else {
        try out.appendSlice(a, stored_info);
        try out.appendSlice(a, block_data);
    }

    // patch the size field (i64 after signature/version/unity_version/revision)
    const size_off = "UnityFS\x00".len + 4 + "2020.3.33f1".len + 1 + "revision".len + 1;
    std.mem.writeInt(i64, out.items[size_off .. size_off + 8], @intCast(out.items.len), .big);

    return out.toOwnedSlice(a);
}

/// Minimal all-literals LZ4 block encoder (tests only). Produces a valid
/// LZ4 block whose literal runs carry no matches.
fn lz4CompressLiterals(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var pos: usize = 0;
    while (pos < data.len) {
        const run = @min(15 + 254, data.len - pos); // one extension byte max
        const token: u8 = if (run >= 15) 0xF0 else @as(u8, @intCast(run)) << 4;
        try out.append(a, token);
        if (run >= 15) try out.append(a, @intCast(run - 15));
        try out.appendSlice(a, data[pos .. pos + run]);
        pos += run;
    }
    return out.toOwnedSlice(a);
}
