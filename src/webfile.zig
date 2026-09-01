//! WebFile parser and writer — Unity's web-player bundle container.
//!
//! Real format (cross-checked against UnityPy's WebFile, which reads real
//! Unity webfiles):
//!
//! ```text
//! signature:  "UnityWebData1.0\0"  (16 bytes)
//! head_size:  u32, little endian — byte offset where the file data begins
//! file table (until the reader reaches head_size):
//!   offset:      u32 LE — absolute offset of the file data in this file
//!   length:      u32 LE
//!   path_len:    u32 LE
//!   path:        path_len bytes (no NUL)
//! file data follows at the recorded offsets.
//! ```
//!
//! The whole file may be wrapped in gzip (detected by magic); `parse`
//! decompresses the stream first and the resulting `WebFile` owns the
//! plaintext. Entry data always borrows — from the caller's buffer for a
//! plain file, from that owned plaintext for a gzip-wrapped one — so a
//! `WebFile` must outlive any use of its entries. Only the entry array
//! and the decompressed buffer are allocated; `deinit` frees both.

const std = @import("std");
const streams = @import("streams.zig");
const container = @import("container.zig");

pub const Entry = struct {
    path: []const u8,
    data: []const u8,
};

pub const WebFile = struct {
    entries: []Entry,
    /// Owned decompressed source (gzip-wrapped webfiles); null for
    /// plain files, whose entries borrow from the caller's buffer.
    owned: ?[]u8 = null,

    pub fn deinit(self: *WebFile, allocator: std.mem.Allocator) void {
        if (self.owned) |o| allocator.free(o);
        allocator.free(self.entries);
    }
};

/// One entry's replacement data for `rebuild`.
pub const EntryReplacement = struct {
    path: []const u8,
    data: []const u8,
};

/// Rebuilds a WebFile with the given entries replaced (uncompressed).
/// The caller owns the returned bytes.
pub fn rebuild(allocator: std.mem.Allocator, wf: *const WebFile, replacements: []const EntryReplacement) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // signature + head_size placeholder
    try out.appendSlice(allocator, container.webfile_magic);
    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

    // data begins right after the header table
    var data_start: u64 = container.webfile_magic.len + 4;
    for (wf.entries) |e| data_start += 12 + e.path.len;

    var offset = data_start;
    var data_offsets: std.ArrayList(u64) = .empty;
    defer data_offsets.deinit(allocator);
    for (wf.entries) |e| {
        var data = e.data;
        for (replacements) |r| {
            if (std.mem.eql(u8, r.path, e.path)) {
                data = r.data;
                break;
            }
        }
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], @intCast(offset), .little);
        std.mem.writeInt(u32, buf[4..8], @intCast(data.len), .little);
        std.mem.writeInt(u32, buf[8..12], @intCast(e.path.len), .little);
        try out.appendSlice(allocator, &buf);
        try out.appendSlice(allocator, e.path);
        try data_offsets.append(allocator, offset);
        offset += data.len;
    }
    // patch head_size: the offset where the data begins
    std.mem.writeInt(u32, out.items[container.webfile_magic.len..][0..4], @intCast(out.items.len), .little);
    // write the data
    for (wf.entries, 0..) |e, i| {
        var data = e.data;
        for (replacements) |r| {
            if (std.mem.eql(u8, r.path, e.path)) {
                data = r.data;
                break;
            }
        }
        // pad to the recorded offset (should be exact, but be safe)
        while (out.items.len < data_offsets.items[i]) try out.append(allocator, 0);
        try out.appendSlice(allocator, data);
    }
    const plain = try out.toOwnedSlice(allocator);
    // A gzip-wrapped source stays gzip-wrapped: `owned` is only set when
    // the parser had to decompress the input, so the rebuilt file keeps
    // the source's compression instead of silently growing.
    if (wf.owned == null) return plain;
    errdefer allocator.free(plain);
    const gz = try gzipCompress(allocator, plain);
    allocator.free(plain);
    return gz;
}

/// Compresses a whole buffer into a gzip stream (std flate, gzip
/// container). The caller owns the returned bytes.
fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // `initCapacity` gives the writer a real buffer up front: flate's
    // Compress asserts on an output buffer of <= 8 bytes.
    var aw = std.Io.Writer.Allocating.initCapacity(allocator, 64 * 1024) catch return error.OutOfMemory;
    errdefer aw.deinit();
    var input: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&aw.writer, &input, .gzip, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return aw.toOwnedSlice();
}

pub const ParseError = error{
    BadSignature,
    ShortData,
    OutOfBounds,
    DecompressFailed,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, data_in: []const u8) ParseError!WebFile {
    var data = data_in;
    var owned: ?[]u8 = null;
    // freed only on error; on success the WebFile owns it via `owned`
    errdefer if (owned) |o| allocator.free(o);
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) {
        // gzip-wrapped webfile: decompress the whole stream first
        const plain = gzipDecompress(allocator, data) catch return error.DecompressFailed;
        owned = plain;
        data = plain;
    }
    if (!std.mem.startsWith(u8, data, container.webfile_magic)) return error.BadSignature;
    if (data.len < container.webfile_magic.len + 4) return error.ShortData;

    var r = streams.Reader.init(data[container.webfile_magic.len..]);
    r.endian = .little;
    const head_size = try r.readInt(u32);
    if (head_size < container.webfile_magic.len + 4 or head_size > data.len) return error.OutOfBounds;

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    while (r.position() < head_size - container.webfile_magic.len) {
        const offset = try r.readInt(u32);
        const length = try r.readInt(u32);
        const path_len = try r.readInt(u32);
        const path = try r.readSlice(path_len);
        const start: usize = offset;
        const end = start + length;
        if (end > data.len) return error.OutOfBounds;
        entries.append(allocator, .{ .path = path, .data = data[start..end] }) catch return error.OutOfMemory;
    }

    return .{ .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory, .owned = owned };
}

/// Decompresses a whole gzip stream; the caller owns the result.
///
/// std's flate decoder panics (not catchable) on *truncated* gzip
/// streams: its bit-reader asserts seek <= end and its end-of-input bit
/// count underflows, both when the decoder runs out of input mid-block.
/// Feeding it an input that yields the real bytes and then 0xFF forever
/// avoids both panics: the decoder consumes the padding as literal 0xFF
/// tokens with no end-of-block marker, so output grows until the limit
/// below trips and a clean error is returned. Valid streams stop at the
/// end-of-stream marker and never touch the padding, so their output is
/// unaffected.
fn gzipDecompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var src = EndlessFFReader{
        .data = data,
        .data_pos = 0,
        .buffer = try allocator.alloc(u8, 1 << 16),
    };
    defer allocator.free(src.buffer);
    const input = src.view();
    const buffer = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(buffer);
    var decomp = std.compress.flate.Decompress.init(input, .gzip, buffer);
    // The endless 0xFF padding makes truncated streams emit literal-0xFF
    // output until a limit trips, so cap the output at a generous ratio
    // of the input (real Unity webfiles compress far less than 128:1).
    const out = try decomp.reader.allocRemaining(allocator, .limited(@max(@as(usize, 8 << 20), data.len *| 128)));
    errdefer allocator.free(out);
    // std's flate reads but never verifies the gzip trailer, so a
    // truncated stream that happens to decode "successfully" (its trailer
    // read from the padding) would pass silently; check CRC and ISIZE
    // ourselves to reject it.
    switch (decomp.container_metadata) {
        .gzip => |g| {
            if (g.crc != std.hash.Crc32.hash(out) or g.count != @as(u32, @truncate(out.len)))
                return error.DecompressFailed;
        },
        else => {},
    }
    return out;
}

/// A reader that serves `data` and then 0xFF bytes without ever reporting
/// end of stream; see `gzipDecompress`.
const EndlessFFReader = struct {
    data: []const u8,
    data_pos: usize,
    buffer: []u8,
    reader: std.Io.Reader = undefined,

    fn view(self: *EndlessFFReader) *std.Io.Reader {
        self.reader = .{
            .vtable = &.{
                .stream = stream,
                .discard = discard,
                .readVec = readVec,
            },
            .buffer = self.buffer,
            .seek = 0,
            .end = 0,
        };
        return &self.reader;
    }

    /// Refills the window: unconsumed bytes, then the next real bytes,
    /// then 0xFF padding up to capacity.
    fn fillWindow(self: *EndlessFFReader, r: *std.Io.Reader) void {
        const keep = r.buffer[r.seek..r.end];
        const keep_n = keep.len;
        @memmove(r.buffer[0..keep_n], keep);
        const remaining = self.data[self.data_pos..];
        const n = @min(remaining.len, r.buffer.len - keep_n);
        @memcpy(r.buffer[keep_n .. keep_n + n], remaining[0..n]);
        self.data_pos += n;
        // padding: 0xFF with a NUL every 64 bytes. The 0xFF runs make
        // truncated deflate streams hit invalid block headers or emit
        // literal output (bounded by the caller's limit); the periodic
        // NUL lets gzip header delimiter scans (FLG name/comment) and the
        // end-of-block code terminate instead of scanning forever.
        const pad = r.buffer[keep_n + n ..];
        var idx: usize = 0;
        while (idx < pad.len) : (idx += 1) {
            pad[idx] = if (idx % 64 == 63) 0x00 else 0xff;
        }
        r.seek = 0;
        r.end = r.buffer.len;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *EndlessFFReader = @alignCast(@fieldParentPtr("reader", r));
        self.fillWindow(r);
        const lim = limit.toInt() orelse (r.end - r.seek);
        const n = @min(lim, r.end - r.seek);
        try w.writeAll(r.buffer[r.seek .. r.seek + n]);
        r.seek += n;
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *EndlessFFReader = @alignCast(@fieldParentPtr("reader", r));
        self.fillWindow(r);
        const lim = limit.toInt() orelse (r.end - r.seek);
        const n = @min(lim, r.end - r.seek);
        r.seek += n;
        return n;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data;
        const self: *EndlessFFReader = @alignCast(@fieldParentPtr("reader", r));
        self.fillWindow(r);
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const FileSpec = struct { path: []const u8, data: []const u8 };

fn buildFixture(a: std.mem.Allocator, files: []const FileSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, container.webfile_magic);
    try out.appendSlice(a, &[_]u8{ 0, 0, 0, 0 }); // head_size placeholder
    // the data begins right after the header table
    var offset: u64 = container.webfile_magic.len + 4;
    for (files) |f| offset += 12 + f.path.len;
    for (files) |f| {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], @intCast(offset), .little);
        std.mem.writeInt(u32, buf[4..8], @intCast(f.data.len), .little);
        std.mem.writeInt(u32, buf[8..12], @intCast(f.path.len), .little);
        try out.appendSlice(a, &buf);
        try out.appendSlice(a, f.path);
        offset += f.data.len;
    }
    std.mem.writeInt(u32, out.items[container.webfile_magic.len..][0..4], @intCast(out.items.len), .little);
    for (files) |f| try out.appendSlice(a, f.data);
    return out.toOwnedSlice(a);
}

test "parse a real-format webfile" {
    const a = std.testing.allocator;
    const bytes = try buildFixture(a, &.{
        .{ .path = "CAB-one", .data = "DATA1" },
        .{ .path = "CAB-two", .data = "DATA2LONGER" },
    });
    defer a.free(bytes);

    var wf = try parse(a, bytes);
    defer wf.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), wf.entries.len);
    try std.testing.expectEqualStrings("CAB-one", wf.entries[0].path);
    try std.testing.expectEqualStrings("DATA1", wf.entries[0].data);
    try std.testing.expectEqualStrings("CAB-two", wf.entries[1].path);
    try std.testing.expectEqualStrings("DATA2LONGER", wf.entries[1].data);
}

test "rebuild keeps a gzip-wrapped source gzip-wrapped" {
    const a = std.testing.allocator;
    const big = "DATA1" ** 200;
    const plain = try buildFixture(a, &.{
        .{ .path = "CAB-one", .data = big },
        .{ .path = "CAB-two", .data = "DATA2" },
    });
    defer a.free(plain);
    const gz = try gzipCompress(a, plain);
    defer a.free(gz);

    var wf = try parse(a, gz);
    defer wf.deinit(a);
    try std.testing.expect(wf.owned != null); // parser had to decompress

    // an edited rebuild stays a gzip stream and parses back identically
    const rebuilt = try rebuild(a, &wf, &.{.{ .path = "CAB-one", .data = "EDITED" }});
    defer a.free(rebuilt);
    try std.testing.expect(rebuilt.len >= 2 and rebuilt[0] == 0x1f and rebuilt[1] == 0x8b);
    try std.testing.expect(rebuilt.len < plain.len); // actually compressed
    var wf2 = try parse(a, rebuilt);
    defer wf2.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), wf2.entries.len);
    try std.testing.expectEqualStrings("EDITED", wf2.entries[0].data);
    try std.testing.expectEqualStrings("DATA2", wf2.entries[1].data);
    // the untouched gzip rebuild round-trips byte-for-byte
    const rebuilt2 = try rebuild(a, &wf, &.{});
    defer a.free(rebuilt2);
    var wf3 = try parse(a, rebuilt2);
    defer wf3.deinit(a);
    try std.testing.expectEqualStrings(big, wf3.entries[0].data);
    try std.testing.expectEqualStrings("DATA2", wf3.entries[1].data);
}

test "rebuild replaces an entry and stays parseable" {
    const a = std.testing.allocator;
    const bytes = try buildFixture(a, &.{
        .{ .path = "CAB-one", .data = "DATA1" },
        .{ .path = "CAB-two", .data = "DATA2" },
    });
    defer a.free(bytes);

    var wf = try parse(a, bytes);
    defer wf.deinit(a);

    const rebuilt = try rebuild(a, &wf, &.{.{ .path = "CAB-two", .data = "NEWDATA" }});
    defer a.free(rebuilt);

    var wf2 = try parse(a, rebuilt);
    defer wf2.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), wf2.entries.len);
    try std.testing.expectEqualStrings("NEWDATA", wf2.entries[1].data);
    try std.testing.expectEqualStrings("DATA1", wf2.entries[0].data);
    // untouched rebuild round-trips byte-for-byte
    const rebuilt2 = try rebuild(a, &wf, &.{});
    defer a.free(rebuilt2);
    try std.testing.expectEqualSlices(u8, bytes, rebuilt2);
}

test "parse rejects bad signature and corrupt gzip" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadSignature, parse(a, "not a webfile"));
    // a gzip magic with garbage after it fails decompression, not a crash
    try std.testing.expectError(error.DecompressFailed, parse(a, &[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0 }));
}

/// Gzips `payload` with a single stored (uncompressed) deflate block.
fn gzipStored(a: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03 });
    try out.append(a, 0x01); // BFINAL=1, BTYPE=00 (stored)
    const len = payload.len;
    try out.append(a, @truncate(len));
    try out.append(a, @truncate(len >> 8));
    try out.append(a, @truncate(~len));
    try out.append(a, @truncate(~len >> 8));
    try out.appendSlice(a, payload);
    // trailer: CRC32 + ISIZE
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, buf[4..8], @truncate(payload.len), .little);
    try out.appendSlice(a, &buf);
    return out.toOwnedSlice(a);
}

test "truncated gzip errors cleanly instead of panicking" {
    const a = std.testing.allocator;
    const wf = try buildFixture(a, &.{.{ .path = "a.bin", .data = "hello" }});
    defer a.free(wf);
    const gz = try gzipStored(a, wf);
    defer a.free(gz);
    // the complete stream parses
    var parsed = try parse(a, gz);
    defer parsed.deinit(a);
    // header(10) + block header(1) + LEN/NLEN(4) + payload
    const payload_end = 10 + 1 + 4 + wf.len;
    var n: usize = 2; // below the 2-byte gzip magic parse rejects the signature
    while (n < payload_end) : (n += 1) {
        // cutting the payload must fail cleanly, never panic (std's
        // flate would assert/underflow on these; the endless 0xFF
        // reader turns them into clean errors)
        try std.testing.expectError(error.DecompressFailed, parse(a, gz[0..n]));
    }
    // cutting only the trailer leaves the payload intact, but the CRC/ISIZE
    // check rejects the incomplete stream all the same
    try std.testing.expectError(error.DecompressFailed, parse(a, gz[0..payload_end]));
}

test "gzip round-trip fuzz: compress, parse, entries survive" {
    // The gzip path (compress -> parse) must be a lossless round-trip for
    // varied payloads: noise, runs, repeated chunks, empty entries.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x9a7a);
    const rnd = prng.random();

    var iter: usize = 0;
    while (iter < 300) : (iter += 1) {
        const mode = rnd.int(u8) % 3;
        const len: usize = @intCast(rnd.intRangeAtMost(u32, 0, 30000));
        var buf: [30000]u8 = undefined;
        switch (mode) {
            0 => rnd.bytes(buf[0..len]),
            1 => @memset(buf[0..len], rnd.int(u8)),
            else => {
                const chunk = rnd.intRangeAtMost(u32, 1, 64);
                var seed: [64]u8 = undefined;
                rnd.bytes(seed[0..chunk]);
                var p: usize = 0;
                while (p < len) {
                    const take = @min(len - p, @as(usize, chunk));
                    @memcpy(buf[p .. p + take], seed[0..take]);
                    p += take;
                }
            },
        }
        const files = [_]FileSpec{
            .{ .path = "CAB-a", .data = buf[0..len] },
            .{ .path = "CAB-b", .data = if (iter % 2 == 0) "" else "small" },
        };
        const plain = try buildFixture(a, &files);
        const gz = try gzipCompress(a, plain);
        var wf = try parse(a, gz);
        defer wf.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), wf.entries.len);
        try std.testing.expectEqualSlices(u8, buf[0..len], wf.entries[0].data);
        try std.testing.expectEqualStrings(if (iter % 2 == 0) "" else "small", wf.entries[1].data);
    }
}
