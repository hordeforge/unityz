//! Minimal BMP encoder for RGBA8 images (32bpp, BI_BITFIELDS, top-down).
//!
//! Writes a 14-byte BITMAPFILEHEADER and a 56-byte BITMAPINFOHEADER with
//! BI_BITFIELDS compression and an RGBA mask set, so the alpha channel
//! survives - plain BI_RGB 32bpp BMPs carry no alpha and decoders force
//! it to 255. The height is negative (top-down DIB), so the caller passes
//! the image as it should appear - no extra flip. 32bpp rows are naturally
//! 4-byte aligned, so no row padding is needed. Alpha is honored by
//! Pillow and most modern readers; legacy tools may still drop it (TGA is
//! the safer alpha-carrying legacy format). Offered alongside PNG for
//! pipelines that need the legacy format. This is the output side of
//! texture extraction; decoding is out of scope (tests round-trip through
//! a small test-only reader).

const std = @import("std");

pub const Error = error{
    SizeMismatch,
    OutOfMemory,
};

const file_header_len = 14;
const info_header_len = 56; // core 40 + 4x 32-bit channel masks
const data_offset = file_header_len + info_header_len;
const max_dim: i64 = 0x7fffffff; // i32 header fields

/// Encodes `rgba` (width*height*4 bytes, row-major, display order) as a
/// BMP file.
pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) Error![]u8 {
    if (width == 0 or height == 0) return error.SizeMismatch;
    if (@as(i64, width) > max_dim or @as(i64, height) > max_dim) return error.SizeMismatch;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (rgba.len != w * h * 4) return error.SizeMismatch;

    var out: std.ArrayList(u8) = .empty;
    const pixel_bytes: u32 = @intCast(rgba.len);
    var fh: [file_header_len]u8 = undefined;
    fh[0] = 'B';
    fh[1] = 'M';
    std.mem.writeInt(u32, fh[2..6], data_offset + pixel_bytes, .little);
    std.mem.writeInt(u32, fh[6..10], 0, .little); // reserved
    std.mem.writeInt(u32, fh[10..14], data_offset, .little);
    var ih: [info_header_len]u8 = undefined;
    std.mem.writeInt(u32, ih[0..4], info_header_len, .little);
    std.mem.writeInt(i32, ih[4..8], @intCast(width), .little);
    // negative height: top-down row order, matching the display-oriented input
    std.mem.writeInt(i32, ih[8..12], -@as(i32, @intCast(height)), .little);
    std.mem.writeInt(u16, ih[12..14], 1, .little); // planes
    std.mem.writeInt(u16, ih[14..16], 32, .little); // bits per pixel
    std.mem.writeInt(u32, ih[16..20], 3, .little); // BI_BITFIELDS
    std.mem.writeInt(u32, ih[20..24], pixel_bytes, .little);
    @memset(ih[24..40], 0); // resolution, colors, important colors
    // channel masks: R, G, B, A
    std.mem.writeInt(u32, ih[40..44], 0x00ff0000, .little);
    std.mem.writeInt(u32, ih[44..48], 0x0000ff00, .little);
    std.mem.writeInt(u32, ih[48..52], 0x000000ff, .little);
    std.mem.writeInt(u32, ih[52..56], 0xff000000, .little);

    // BMP stores BGR(A); flip each pixel's channels.
    const px = allocator.alloc(u8, rgba.len) catch return error.OutOfMemory;
    defer allocator.free(px);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        px[i + 0] = rgba[i + 2];
        px[i + 1] = rgba[i + 1];
        px[i + 2] = rgba[i + 0];
        px[i + 3] = rgba[i + 3];
    }
    out.appendSlice(allocator, &fh) catch return error.OutOfMemory;
    out.appendSlice(allocator, &ih) catch return error.OutOfMemory;
    out.appendSlice(allocator, px) catch return error.OutOfMemory;
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Test-only reader: reverses the encoder so tests can round-trip.

fn decodeTest(allocator: std.mem.Allocator, bytes: []const u8) !struct { rgba: []u8, width: u32, height: u32 } {
    if (bytes.len < data_offset) return error.SizeMismatch;
    if (bytes[0] != 'B' or bytes[1] != 'M') return error.SizeMismatch;
    const ih_len = std.mem.readInt(u32, bytes[14..18], .little);
    if (ih_len < 40 or bytes.len < 14 + ih_len) return error.SizeMismatch;
    const width = std.mem.readInt(i32, bytes[18..22], .little);
    const height = std.mem.readInt(i32, bytes[22..26], .little);
    const bpp = std.mem.readInt(u16, bytes[28..30], .little);
    if (width <= 0 or height == 0 or bpp != 32) return error.SizeMismatch;
    const top_down = height < 0;
    const h_abs: usize = @intCast(@abs(height));
    const w: usize = @intCast(width);
    const pixel_offset: usize = @intCast(std.mem.readInt(u32, bytes[10..14], .little));
    if (bytes.len != pixel_offset + w * h_abs * 4) return error.SizeMismatch;
    const rgba = try allocator.alloc(u8, w * h_abs * 4);
    var row: usize = 0;
    while (row < h_abs) : (row += 1) {
        const src_row = if (top_down) row else h_abs - 1 - row;
        var col: usize = 0;
        while (col < w) : (col += 1) {
            const src = pixel_offset + (src_row * w + col) * 4;
            const dst = (row * w + col) * 4;
            rgba[dst + 0] = bytes[src + 2];
            rgba[dst + 1] = bytes[src + 1];
            rgba[dst + 2] = bytes[src + 0];
            rgba[dst + 3] = bytes[src + 3];
        }
    }
    return .{ .rgba = rgba, .width = @intCast(width), .height = @intCast(h_abs) };
}

test "BMP encode round-trips a known image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rgba = [_]u8{
        255, 0, 0,   255, 0,   255, 0,  255,
        0,   0, 255, 255, 128, 64,  32, 16,
    };
    const bmp = try encode(a, 2, 2, &rgba);
    try std.testing.expectEqual(@as(usize, 70 + 16), bmp.len);
    try std.testing.expectEqualSlices(u8, "BM", bmp[0..2]);
    try std.testing.expectEqual(@as(u32, 70 + 16), std.mem.readInt(u32, bmp[2..6], .little));
    try std.testing.expectEqual(@as(u32, 70), std.mem.readInt(u32, bmp[10..14], .little));
    try std.testing.expectEqual(@as(u32, 56), std.mem.readInt(u32, bmp[14..18], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, bmp[18..22], .little));
    // top-down (negative height)
    try std.testing.expectEqual(@as(i32, -2), std.mem.readInt(i32, bmp[22..26], .little));
    try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, bmp[28..30], .little));
    // BI_BITFIELDS with the RGBA masks (infoheader-relative offsets 40-55)
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bmp[30..34], .little));
    try std.testing.expectEqual(@as(u32, 0x00ff0000), std.mem.readInt(u32, bmp[54..58], .little));
    try std.testing.expectEqual(@as(u32, 0xff000000), std.mem.readInt(u32, bmp[66..70], .little));
    // BGR(A) order in the payload
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 32, 64, 128, 16 }, bmp[70..86]);

    const dec = try decodeTest(a, bmp);
    try std.testing.expectEqual(@as(u32, 2), dec.width);
    try std.testing.expectEqual(@as(u32, 2), dec.height);
    try std.testing.expectEqualSlices(u8, &rgba, dec.rgba);
}

test "BMP encode rejects mismatched input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.SizeMismatch, encode(a, 2, 2, &[_]u8{0} ** 15));
    try std.testing.expectError(error.SizeMismatch, encode(a, 0, 0, &.{}));
}
