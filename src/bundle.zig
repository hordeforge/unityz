//! UnityFS bundle parser — the modern Unity asset bundle container
//! (`UnityFS\0` magic, format version 6+).
//!
//! Layout (from the public UnityFS format docs):
//!
//! ```text
//! header (all big-endian, like the rest of the container):
//!   signature            null-terminated string ("UnityFS\0" or legacy
//!                        "UnityWeb\0"/"UnityRaw\0"; legacy v2-5 parsed)
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

/// Vendored LZHAM decompressor (UnityFS block compression type 4). Returns 0
/// on success; `dst_len` is in/out.
extern fn lzham_unpack(src: [*]const u8, src_len: c_uint, dst: [*]u8, dst_len: *c_uint, dict_size_log2: c_uint) c_int;

/// LZHAM dictionary size (log2) UnityFS blocks use. Not encoded in the
/// stream; a 64 KB dictionary is LZHAM's common default for small blocks.
const lzham_dict_size_log2: c_uint = 16;

fn lzhamDecompress(allocator: std.mem.Allocator, raw: []const u8, uncompressed_size: u32) ParseError![]u8 {
    const out = allocator.alloc(u8, uncompressed_size) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    var dst_len: c_uint = @intCast(uncompressed_size);
    if (lzham_unpack(raw.ptr, @intCast(raw.len), out.ptr, &dst_len, lzham_dict_size_log2) != 0)
        return error.DecompressFailed;
    if (dst_len != uncompressed_size) return error.DecompressFailed;
    return out;
}

// The container magics in `container.zig` carry their NUL terminator;
// `readStringToNull`/`writeStringToNull` handle it, so compare and write
// the signature without it rather than repeating the literals here.
const unityfs_signature = container.unityfs_magic[0 .. container.unityfs_magic.len - 1];
const unityweb_signature = container.unityweb_magic[0 .. container.unityweb_magic.len - 1];
const unityraw_signature = container.unityraw_magic[0 .. container.unityraw_magic.len - 1];

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

/// Parses a legacy `UnityWeb`/`UnityRaw` bundle (Unity 2.x-5.x era web /
/// standalone bundles). The header is little-endian; the version-player
/// and version-engine strings precede the level table, then a block at
/// `headerSize` holds the file table and the serialized files - LZMA-
/// compressed for UnityWeb, plain for UnityRaw. The layout mirrors
/// UnityPy's `read_web_raw`; version-6 legacy bundles switch to the
/// UnityFS-style layout and are not handled here.
fn parseLegacy(allocator: std.mem.Allocator, data: []const u8, signature: []const u8) ParseError!Bundle {
    if (data.len < 8) return error.ShortData;
    var r = streams.Reader.init(data);
    // Legacy bundle fields are big-endian, like the UnityFS header (and
    // like UnityPy's reader default).
    r.endian = .big;
    // `parse` already consumed the signature; skip it here.
    try r.skip(signature.len + 1);

    const version = try r.readInt(u32);
    if (version < 2 or version > 5) return error.UnsupportedVersion;
    const unity_version = try r.readStringToNull();
    const unity_revision = try r.readStringToNull();
    if (version >= 4) {
        _ = try r.readBytes(16); // content hash
        _ = try r.readInt(u32); // crc
    }
    _ = try r.readInt(u32); // minimumStreamedBytes
    const header_size = try r.readInt(u32);
    _ = try r.readInt(u32); // numberOfLevelsToDownloadBeforeStreaming
    const level_count = try r.readInt(i32);
    if (level_count < 1 or level_count > 16) return error.Corrupt;
    try r.skip(4 * 2 * @as(usize, @intCast(level_count - 1)));
    const compressed_size = try r.readInt(u32);
    const uncompressed_size = try r.readInt(u32);
    if (version >= 2) _ = try r.readInt(u32); // completeFileSize
    if (version >= 3) _ = try r.readInt(u32); // fileInfoHeaderSize
    if (header_size > data.len or compressed_size > data.len - header_size) return error.Corrupt;

    // the block at headerSize: the file table followed by the serialized
    // files; UnityWeb stores it LZMA-compressed
    const raw = data[header_size .. header_size + compressed_size];
    var stream: []u8 = undefined;
    if (std.mem.eql(u8, signature, unityweb_signature)) {
        stream = lzmaDecompress(allocator, raw, uncompressed_size) catch return error.DecompressFailed;
    } else {
        if (raw.len != uncompressed_size) return error.Corrupt;
        stream = try allocator.dupe(u8, raw);
    }
    errdefer allocator.free(stream);

    var dr = streams.Reader.init(stream);
    dr.endian = .big;
    const node_count = try dr.readInt(i32);
    if (node_count < 0 or node_count > max_entries) return error.Corrupt;
    const nodes = try allocator.alloc(Node, @intCast(node_count));
    errdefer allocator.free(nodes);
    // `alloc` does not apply struct field defaults; data must be set here so
    // a node whose range is rejected is handed out as an empty slice.
    for (nodes) |*n| {
        n.data = &.{};
        n.offset = 0;
        n.size = 0;
        n.flags = 0;
        n.path = try dr.readStringToNull();
        n.offset = try dr.readInt(u32);
        n.size = try dr.readInt(u32);
    }
    for (nodes) |*n| {
        if (n.offset < 0 or n.size < 0) continue;
        const off: usize = @intCast(n.offset);
        const end = off + @as(usize, @intCast(n.size));
        if (end <= stream.len) n.data = stream[off..end];
    }

    const header_info = allocator.alloc(u8, 0) catch return error.OutOfMemory;
    return .{
        .version = version,
        .unity_version = unity_version,
        .unity_revision = unity_revision,
        .size = @intCast(data.len),
        .flags = 0,
        .blocks = &.{},
        .nodes = nodes,
        .header_info = header_info,
        .stream = stream,
    };
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!Bundle {
    if (data.len < 8) return error.ShortData;
    var r = streams.Reader.init(data);

    const signature = try r.readStringToNull();
    if (!std.mem.eql(u8, signature, unityfs_signature)) {
        if (std.mem.eql(u8, signature, unityweb_signature) or std.mem.eql(u8, signature, unityraw_signature))
            return parseLegacy(allocator, data, signature);
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

        // Decode straight into the stream: a scratch buffer per block would
        // cost one allocation and one full copy of the bundle's payload for
        // nothing. A block that decodes short would leave the rest of
        // `stream` uninitialized, and nodes may point at it, so the
        // decoders below reject that instead of handing out uninitialized
        // heap.
        if (b.uncompressed_size > total - out_pos) return error.Corrupt;
        try decompressRawInto(allocator, raw, stream[out_pos..][0..b.uncompressed_size], blockCompressionType(b.flags));
        out_pos += b.uncompressed_size;
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
/// Writes a single block that keeps the source's compression: when any
/// source block was compressed, the output block is LZ4-encoded (the
/// cheapest encoder; LZMA/LZHAM sources convert losslessly), otherwise
/// it stays uncompressed - mirroring Unity's own writer, which skips
/// compression when it does not shrink. The header keeps the source
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

    // Keep the source bundle's compression: when any source block was
    // compressed, the single output block is written LZ4-compressed (the
    // cheapest encoder; LZMA/LZHAM inputs convert losslessly). If the
    // compressed form is not smaller, the block stays uncompressed, like
    // Unity's own writer.
    var any_compressed = false;
    for (b.blocks) |blk| {
        if (blockCompressionType(blk.flags) != .none) {
            any_compressed = true;
            break;
        }
    }
    // One owner per buffer: `compressed` holds the LZ4 block, `raw_payload`
    // the fallback uncompressed copy; `block_data` borrows whichever applies.
    var compressed: ?[]u8 = null;
    defer if (compressed) |c| allocator.free(c);
    var raw_payload: ?[]u8 = null;
    defer if (raw_payload) |p| allocator.free(p);
    if (any_compressed) {
        var sw: streams.Writer = .init(allocator);
        defer sw.deinit();
        for (data) |d| try sw.writeBytes(d);
        const payload = sw.getWritten();
        const c = try lz4.compress(allocator, payload);
        if (c.len < total) {
            compressed = c;
        } else {
            allocator.free(c);
            raw_payload = try allocator.dupe(u8, payload);
        }
    }
    const block_data: []const u8 = if (compressed) |c| c else if (raw_payload) |p| p else &.{};
    const block_flags: u16 = if (compressed != null) 0x40 | @intFromEnum(CompressionType.lz4) else 0;

    // header info (big endian)
    var info: streams.Writer = .init(allocator);
    defer info.deinit();
    info.endian = .big;
    try info.writeBytes(&[_]u8{0} ** 16); // data hash
    try info.writeInt(u32, 1); // one block
    try info.writeInt(u32, @intCast(total));
    try info.writeInt(u32, @intCast(if (compressed) |c| c.len else total));
    try info.writeInt(u16, block_flags); // 0 uncompressed, 0x40|lz4 compressed
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
    try out.writeStringToNull(unityfs_signature);
    try out.writeInt(u32, b.version);
    // The parser reads both version strings for every UnityFS version
    // (including format-6 bundles from Unity 5.x/2017/2018); the rebuild
    // must write them unconditionally too, or v6 output misparses.
    try out.writeStringToNull(b.unity_version);
    try out.writeStringToNull(b.unity_revision);
    try out.writeInt(i64, 0); // size placeholder
    try out.writeInt(u32, @intCast(info_bytes.len));
    try out.writeInt(u32, @intCast(info_bytes.len));
    try out.writeInt(u32, 0); // flags: uncompressed, info at start
    if (b.version >= 7) {
        const rem = out.getWritten().len % 16;
        for (0..(16 - rem) % 16) |_| try out.writeByte(0);
    }
    try out.writeBytes(info_bytes);
    if (block_data.len != 0) {
        try out.writeBytes(block_data);
    } else {
        for (data) |d| try out.writeBytes(d);
    }

    // patch the size field: after signature(8) + version(4) [+ unity + revision]
    var size_off: usize = 12;
    {
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
/// Decompresses one block into a caller-owned `dst`, which must be exactly
/// the block's decompressed size.
fn decompressRawInto(
    allocator: std.mem.Allocator,
    raw: []const u8,
    dst: []u8,
    ctype: CompressionType,
) ParseError!void {
    switch (ctype) {
        .none => {
            if (raw.len != dst.len) return error.Corrupt;
            @memcpy(dst, raw);
        },
        .lz4, .lz4hc => lz4.decompressInto(dst, raw) catch return error.DecompressFailed,
        .lzma => {
            const out = lzmaDecompress(allocator, raw, @intCast(dst.len)) catch return error.DecompressFailed;
            defer allocator.free(out);
            if (out.len != dst.len) return error.Corrupt;
            @memcpy(dst, out);
        },
        .lzham => return error.UnsupportedCompression,
        else => return error.UnsupportedCompression,
    }
}

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
        .lzham => lzhamDecompress(allocator, raw, uncompressed_size) catch return error.DecompressFailed,
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

test "rebuild converts an LZMA source to LZ4" {
    const a = std.testing.allocator;
    // python: lzma.compress(payload, FORMAT_RAW, FILTER_LZMA1, lc3/lp0/pb2,
    // dict 64K), prefixed with the UnityFS 5-byte props+dict header. The
    // block's own flags carry the compression, so the header info stays
    // uncompressed (header flags 0).
    const payload = "abababababababababab" ** 10;
    const lzma_block = [_]u8{
        0x5d, 0x00, 0x00, 0x01, 0x00, // props (lc3/lp0/pb2) + dict size 64K
        0x00, 0x30, 0x98, 0xaa, 0xd0,
        0x18, 0x3d, 0xff, 0xff, 0xff,
        0xfc, 0x20, 0x00, 0x00,
    };
    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .none,
        .payload = payload,
        .payload_path = "CAB-abc",
        .raw_block = &lzma_block,
        .block_flags = 0x40 | @intFromEnum(CompressionType.lzma),
    });
    defer a.free(bundle_bytes);

    var b = try parse(a, bundle_bytes);
    defer b.deinit(a);
    // the LZMA block decodes to the exact payload
    try std.testing.expectEqualStrings(payload, b.nodes[0].data);

    // rebuilding converts the LZMA source to a single LZ4 block (large
    // enough replacement that compression actually shrinks)
    const newdata = "NEWDATA" ** 50;
    const rebuilt = try rebuild(a, &b, &.{.{ .path = "CAB-abc", .data = newdata }});
    defer a.free(rebuilt);
    var b2 = try parse(a, rebuilt);
    defer b2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), b2.blocks.len);
    try std.testing.expect(blockCompressionType(b2.blocks[0].flags) == .lz4);
    try std.testing.expectEqualStrings(newdata, b2.nodes[0].data);
}

test "rebuild keeps compression for a compressed source bundle" {
    const a = std.testing.allocator;
    // A compressible payload so LZ4 actually shrinks it.
    const payload = "abababababababababab";
    // A hand-built LZ4 block: "ab" + match len 18 at offset 2.
    const lz4_compressed = [_]u8{ 0x2E, 'a', 'b', 0x02, 0x00 };

    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .lz4,
        .payload = payload,
        .payload_path = "CAB-abc",
        .raw_block = &lz4_compressed,
        .block_flags = 0x02,
    });
    defer a.free(bundle_bytes);

    var b = try parse(a, bundle_bytes);
    defer b.deinit(a);

    // Rebuild with a replacement: the output block must stay LZ4-compressed
    // (a compressed source is re-encoded, not flattened to uncompressed).
    const rebuilt = try rebuild(a, &b, &.{.{ .path = "CAB-abc", .data = "ababababababababababX" }});
    defer a.free(rebuilt);

    var b2 = try parse(a, rebuilt);
    defer b2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), b2.blocks.len);
    const ctype = blockCompressionType(b2.blocks[0].flags);
    try std.testing.expect(ctype == .lz4);
    try std.testing.expect(b2.blocks[0].compressed_size < b2.blocks[0].uncompressed_size);
    try std.testing.expectEqualStrings("ababababababababababX", b2.nodes[0].data);
    // the header flags stay uncompressed-info-at-start; only the block
    // carries its own compression
    try std.testing.expect((b2.flags & 0x80) == 0);
}

test "rebuild keeps an uncompressed source uncompressed" {
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
    try std.testing.expect(blockCompressionType(b2.blocks[0].flags) == .none);
    try std.testing.expectEqualStrings("NEWDATA", b2.nodes[0].data);
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

test "parse a legacy UnityRaw bundle" {
    const a = std.testing.allocator;
    // v5 UnityRaw: little-endian header (signature, version, engine
    // strings, hash+crc, level table, sizes), then a plain directory
    // block with one node.
    var w = streams.Writer.init(a);
    defer w.deinit();
    w.endian = .big;
    try w.writeStringToNull(unityraw_signature);
    try w.writeInt(u32, 5); // version
    try w.writeStringToNull("5.x.x");
    try w.writeStringToNull("5.6.7f1");
    try w.writeBytes(&[_]u8{0} ** 16); // hash
    try w.writeInt(u32, 0); // crc
    try w.writeInt(u32, 0); // minimumStreamedBytes
    const header_size_off = w.getWritten().len;
    try w.writeInt(u32, 0); // headerSize (patched below)
    try w.writeInt(u32, 1); // levels to download before streaming
    try w.writeInt(i32, 1); // level count
    try w.writeInt(u32, 0); // compressedSize (patched)
    try w.writeInt(u32, 0); // uncompressedSize (patched)
    try w.writeInt(u32, 0); // completeFileSize (patched)
    try w.writeInt(u32, 0); // fileInfoHeaderSize

    const payload = "CAB-abcdefgh";
    var dir = streams.Writer.init(a);
    defer dir.deinit();
    dir.endian = .big;
    try dir.writeInt(i32, 1); // node count
    try dir.writeStringToNull("CAB-abc");
    const dir_data_off = dir.getWritten().len + 8; // offset + size fields follow
    try dir.writeInt(u32, @intCast(dir_data_off));
    try dir.writeInt(u32, @intCast(payload.len));
    try dir.writeBytes(payload);

    const header_size = w.getWritten().len; // sizes already written; patched below
    std.mem.writeInt(u32, w.buf.items[header_size_off..][0..4], @intCast(header_size), .big);
    std.mem.writeInt(u32, w.buf.items[header_size_off + 12 ..][0..4], @intCast(dir.getWritten().len), .big); // compressed
    std.mem.writeInt(u32, w.buf.items[header_size_off + 16 ..][0..4], @intCast(dir.getWritten().len), .big); // uncompressed
    std.mem.writeInt(u32, w.buf.items[header_size_off + 20 ..][0..4], @intCast(header_size + dir.getWritten().len), .big); // complete file size
    try w.writeBytes(dir.getWritten());

    var b = try parse(a, w.getWritten());
    defer b.deinit(a);
    try std.testing.expectEqual(@as(u32, 5), b.version);
    try std.testing.expectEqualStrings("5.x.x", b.unity_version);
    try std.testing.expectEqual(@as(usize, 1), b.nodes.len);
    try std.testing.expectEqualStrings("CAB-abc", b.nodes[0].path);
    try std.testing.expectEqualStrings(payload, b.nodes[0].data);
}

test "parse a legacy UnityWeb bundle (LZMA directory block)" {
    const a = std.testing.allocator;
    // The directory block is LZMA-compressed (python FORMAT_RAW LZMA1,
    // lc3/lp0/pb2, 64K dict, prefixed with the props+dict header), the
    // same framing UnityFS lzma blocks use.
    const lzma_block = [_]u8{
        0x5d, 0x00, 0x00, 0x01, 0x00, // props + dict size (LE)
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // decompressed size (u64 LE)
        0x00, 0x00, 0x67, 0xfe, 0xa8, 0xe4, 0xd2, 0x5f,
        0x58, 0xcb, 0x2a, 0x00, 0x18, 0xdb, 0x73, 0x1e,
        0x4a, 0x6a, 0xb3, 0xdd, 0xe7, 0xee, 0x92, 0x52,
        0x25, 0x0a, 0x4f, 0xcb, 0x1f, 0xff, 0x92, 0x95,
        0x80, 0x00,
    };
    var w = streams.Writer.init(a);
    defer w.deinit();
    w.endian = .big;
    try w.writeStringToNull(unityweb_signature);
    try w.writeInt(u32, 5);
    try w.writeStringToNull("5.x.x");
    try w.writeStringToNull("5.6.7f1");
    try w.writeBytes(&[_]u8{0} ** 16);
    try w.writeInt(u32, 0);
    try w.writeInt(u32, 0);
    const header_size_off = w.getWritten().len;
    try w.writeInt(u32, 0);
    try w.writeInt(u32, 1);
    try w.writeInt(i32, 1);
    try w.writeInt(u32, 0);
    try w.writeInt(u32, 0);
    try w.writeInt(u32, 0);
    try w.writeInt(u32, 0);
    const header_size = w.getWritten().len;
    std.mem.writeInt(u32, w.buf.items[header_size_off..][0..4], @intCast(header_size), .big);
    std.mem.writeInt(u32, w.buf.items[header_size_off + 12 ..][0..4], @intCast(lzma_block.len), .big);
    std.mem.writeInt(u32, w.buf.items[header_size_off + 16 ..][0..4], 32, .big); // uncompressed dir block
    std.mem.writeInt(u32, w.buf.items[header_size_off + 20 ..][0..4], @intCast(header_size + lzma_block.len), .big);
    try w.writeBytes(&lzma_block);

    var b = try parse(a, w.getWritten());
    defer b.deinit(a);
    try std.testing.expectEqual(@as(u32, 5), b.version);
    try std.testing.expectEqual(@as(usize, 1), b.nodes.len);
    try std.testing.expectEqualStrings("CAB-abc", b.nodes[0].path);
    try std.testing.expectEqualStrings("CAB-abcdefgh", b.nodes[0].data);
}

test "parse rejects unsupported legacy versions" {
    const a = std.testing.allocator;
    // version 0 is out of the supported v2-5 range
    try std.testing.expectError(error.UnsupportedVersion, parse(a, "UnityWeb\x00\x00\x00\x00\x00"));
    // v6 legacy bundles switch to the UnityFS-style layout: unsupported here
    try std.testing.expectError(error.UnsupportedVersion, parse(a, "UnityRaw\x00\x06\x00\x00\x00"));
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
    // the header info is stored raw but the flags claim a type (5) that is
    // beyond the known set (0 none, 1 lzma, 2 lz4, 3 lz4hc, 4 lzham).
    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .none,
        .payload = "data",
        .payload_path = "CAB-x",
        .header_flags_override = 0x05,
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

test "lzham decompresses a known UnityFS block" {
    const a = std.testing.allocator;
    // Compressed with the lzham compressor (dict size 16), the same library
    // family as the vendored decompressor; a UnityFS block's LZHAM stream is
    // a plain lzham-compressed byte run.
    const compressed = [_]u8{
        0xe0, 0x00, 0x03, 0x83, 0x80, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x4c, 0x5a, 0x48, 0x41,
        0x4d, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x20, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36,
        0x37, 0x38, 0x39, 0x20, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c,
        0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0xc0, 0x02,
        0x55, 0x13, 0x92,
    };
    const expected = "Hello, LZHAM world! 0123456789 abcdefghijklmnopqrstuvwxyz";
    const out = try lzhamDecompress(a, &compressed, expected.len);
    defer a.free(out);
    try std.testing.expectEqualStrings(expected, out);

    // A corrupt/truncated stream fails rather than faulting.
    try std.testing.expectError(error.DecompressFailed, lzhamDecompress(a, compressed[0..10], expected.len));
}

test "bundle parser survives mutated and truncated input" {
    // Hostile input must never crash the bundle parser: mutations of a
    // valid bundle (bytes flipped, lengths nudged, headers truncated) must
    // either parse cleanly or fail with an error - never panic.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bundle_bytes = try buildBundleFixture(a, .{
        .info_at_end = false,
        .compression = .lz4,
        .payload = "the quick brown fox jumps over the lazy dog\n" ** 8,
        .payload_path = "CAB-abc",
        .raw_block = &[_]u8{ 0x2E, 'a', 'b', 0x02, 0x00 },
        .block_flags = 0x02,
    });
    defer a.free(bundle_bytes);

    var prng = std.Random.DefaultPrng.init(0xbb0b);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        const mode = rnd.int(u8) % 4;
        const blen = switch (mode) {
            0 => rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(bundle_bytes.len))), // truncate
            1 => @min(bundle_bytes.len + rnd.intRangeAtMost(u32, 1, 64), buf.len), // extend
            2 => bundle_bytes.len, // mutate
            else => rnd.intRangeAtMost(u32, 0, 256), // tiny random
        };
        @memcpy(buf[0..bundle_bytes.len], bundle_bytes);
        if (mode == 0 or mode == 3) {
            // zero random bytes for tiny/truncated inputs
            if (blen > 0) rnd.bytes(buf[0..@min(blen, 64)]);
        } else if (mode == 2) {
            const m = rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(bundle_bytes.len)));
            buf[m] ^= @intCast(rnd.int(u8) | 1);
        }
        var b = parse(a, buf[0..blen]) catch continue;
        defer b.deinit(a);
        // if it parsed, the node data must be readable without faulting
        for (b.nodes) |n| _ = n.data;
    }
}
