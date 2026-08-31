//! Minimal PNG encoder for RGBA8 images (8-bit, color type 6).
//!
//! Produces a valid PNG: signature, IHDR, one IDAT (zlib-compressed
//! scanlines with per-row adaptive filtering - Sub/Up/Average/Paeth, the
//! minimum-sum-of-absolute-values heuristic), IEND. Compression uses std's
//! flate (deflate) with the zlib container; chunk CRCs use std's CRC32.
//! Filtering wins big on structured content (a smooth gradient encodes
//! ~99% smaller) at a few percent cost on high-frequency noise like
//! crunched texture artifacts, mirroring libpng's default.
//!
//! This is the output side of texture extraction; decoding PNG is out of
//! scope (tests round-trip through std's zlib decompressor instead).

const std = @import("std");

pub const Error = error{
    SizeMismatch,
    OutOfMemory,
    CompressFailed,
};

const signature = "\x89PNG\r\n\x1a\n";

/// Encodes `rgba` (width*height*4 bytes, row-major) as a PNG file.
pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) Error![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (rgba.len != w * h * 4) return error.SizeMismatch;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, signature);

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(allocator, &out, "IHDR", &ihdr);

    // IDAT: zlib-compressed scanlines, each prefixed with the filter that
    // minimizes the sum of absolute differences of the filtered bytes.
    const stride = w * 4;
    var scanlines: std.ArrayList(u8) = .empty;
    defer scanlines.deinit(allocator);
    try scanlines.ensureTotalCapacityPrecise(allocator, h * (stride + 1));
    const scratch = try allocator.alloc(u8, stride);
    defer allocator.free(scratch);
    var prev_row: []const u8 = &.{};
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const cur = rgba[row * stride .. (row + 1) * stride];
        const filter = bestFilter(cur, prev_row, scratch);
        try scanlines.append(allocator, filter);
        filterRow(filter, cur, prev_row, scratch);
        try scanlines.appendSlice(allocator, scratch[0..stride]);
        prev_row = cur;
    }

    const idat = try zlibCompress(allocator, scanlines.items);
    defer allocator.free(idat);
    try writeChunk(allocator, &out, "IDAT", idat);

    try writeChunk(allocator, &out, "IEND", &.{});
    return out.toOwnedSlice(allocator);
}

fn writeChunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime kind: []const u8, data: []const u8) !void {
    std.debug.assert(kind.len == 4);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(allocator, &crc_buf);
}

/// Applies PNG filter `f` to one scanline of `stride` bytes (4 bytes per
/// pixel), using `prev` (empty for the first row). Writes to `out[0..stride]`.
fn filterRow(f: u8, cur: []const u8, prev: []const u8, out: []u8) void {
    const stride = cur.len;
    std.debug.assert(out.len >= stride);
    var i: usize = 0;
    while (i < stride) : (i += 1) {
        const x = cur[i];
        const a: i32 = if (i >= 4) cur[i - 4] else 0; // left
        const b: i32 = if (prev.len != 0) prev[i] else 0; // above
        const c: i32 = if (prev.len != 0 and i >= 4) prev[i - 4] else 0; // upper-left
        const pred: i32 = switch (f) {
            1 => a, // Sub
            2 => b, // Up
            3 => @divTrunc(a + b, 2), // Average
            4 => paeth(a, b, c), // Paeth
            else => 0,
        };
        out[i] = x -% @as(u8, @truncate(@as(u32, @bitCast(pred))));
    }
}

/// Reverses PNG filter `f` on one scanline in place, using the
/// already-reconstructed previous row.
fn unfilterRow(f: u8, row: []u8, prev: []const u8) void {
    const stride = row.len;
    var i: usize = 0;
    while (i < stride) : (i += 1) {
        const a: i32 = if (i >= 4) row[i - 4] else 0; // left (reconstructed)
        const b: i32 = if (prev.len != 0) prev[i] else 0; // above
        const c: i32 = if (prev.len != 0 and i >= 4) prev[i - 4] else 0; // upper-left
        const pred: i32 = switch (f) {
            1 => a,
            2 => b,
            3 => @divTrunc(a + b, 2),
            4 => paeth(a, b, c),
            else => 0,
        };
        row[i] = row[i] +% @as(u8, @truncate(@as(u32, @bitCast(pred))));
    }
}

fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Picks the filter (0-4) with the smallest sum of absolute differences.
fn bestFilter(cur: []const u8, prev: []const u8, scratch: []u8) u8 {
    var best: u8 = 0;
    var best_sum: u64 = std.math.maxInt(u64);
    var f: u8 = 0;
    while (f < 5) : (f += 1) {
        filterRow(f, cur, prev, scratch);
        // libpng's heuristic: prefer the filter whose bytes are smallest
        // in absolute value (they deflate best)
        var sum: u64 = 0;
        for (scratch[0..cur.len]) |b| sum += @abs(@as(i32, b));
        if (sum < best_sum) {
            best_sum = sum;
            best = f;
        }
    }
    return best;
}

fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    const flate = std.compress.flate;
    var out = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    var buffer: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(&out.writer, &buffer, .zlib, .default) catch return error.CompressFailed;
    comp.writer.writeAll(data) catch return error.CompressFailed;
    comp.finish() catch return error.CompressFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

test "encode produces a decodable png" {
    const a = std.testing.allocator;
    // 2x2 image with distinct pixels.
    const rgba = [_]u8{
        255, 0,   0,   255, // red
        0,   255, 0,   255, // green
        0,   0,   255, 255, // blue
        255, 255, 255, 255, // white
    };
    const png = try encode(a, 2, 2, &rgba);
    defer a.free(png);

    // signature
    try std.testing.expectEqualStrings(signature, png[0..8]);

    // decode: parse chunks, decompress IDAT, strip filter bytes
    const decoded = try decodePng(a, png);
    defer a.free(decoded);
    try std.testing.expectEqualSlices(u8, &rgba, decoded);
}

test "encode rejects size mismatch" {
    try std.testing.expectError(error.SizeMismatch, encode(std.testing.allocator, 2, 2, "short"));
}

/// Test-only PNG reader: returns the raw RGBA8 pixels.
fn decodePng(allocator: std.mem.Allocator, png: []const u8) ![]u8 {
    var pos: usize = 8; // skip signature
    var width: u32 = 0;
    var height: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);

    while (pos + 8 <= png.len) {
        const len: usize = @intCast(std.mem.readInt(u32, png[pos..][0..4], .big));
        const kind = png[pos + 4 .. pos + 8];
        const data = png[pos + 8 .. pos + 8 + len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(allocator, data);
        }
        pos += 12 + len;
    }

    // zlib-decompress
    var input = std.Io.Reader.fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&input, .zlib, &window);
    const raw_len: usize = @intCast(height * (width * 4 + 1));
    const raw = try decomp.reader.readAlloc(allocator, raw_len);
    defer allocator.free(raw);

    // strip filter bytes and reverse the per-row filter
    const stride: usize = @intCast(width * 4);
    const out = try allocator.alloc(u8, @intCast(width * height * 4));
    var prev_row: []const u8 = &.{};
    for (0..height) |row| {
        const src_start = row * (stride + 1);
        const f = raw[src_start];
        const dst = out[row * stride ..][0..stride];
        @memcpy(dst, raw[src_start + 1 .. src_start + 1 + stride]);
        unfilterRow(f, dst, prev_row);
        prev_row = dst;
    }
    return out;
}
