//! Minimal TGA encoder for RGBA8 images (uncompressed true-color, 32bpp).
//!
//! Writes an 18-byte TGA 2.0 header (image type 2, top-left origin) and
//! BGR(A) pixel rows in display order, so the caller passes the image as
//! it should appear - no extra flip. The format is offered alongside PNG
//! for pipelines whose tools predate PNG or need the raw pixel layout.
//! This is the output side of texture extraction; decoding is out of
//! scope (tests round-trip through a small test-only reader).

const std = @import("std");

pub const Error = error{
    SizeMismatch,
    OutOfMemory,
    DimensionsTooLarge,
};

const header_len = 18;
const max_dim: u32 = 0xffff; // u16 header fields

/// Encodes `rgba` (width*height*4 bytes, row-major, display order) as a
/// TGA file.
pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) Error![]u8 {
    if (width == 0 or height == 0) return error.SizeMismatch;
    if (width > max_dim or height > max_dim) return error.DimensionsTooLarge;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (rgba.len != w * h * 4) return error.SizeMismatch;

    var out: std.ArrayList(u8) = .empty;
    var hdr: [header_len]u8 = undefined;
    hdr[0] = 0; // id length
    hdr[1] = 0; // color map type
    hdr[2] = 2; // image type: uncompressed true-color
    @memset(hdr[3..8], 0); // color map spec
    std.mem.writeInt(u16, hdr[8..10], 0, .little); // x origin
    std.mem.writeInt(u16, hdr[10..12], 0, .little); // y origin
    std.mem.writeInt(u16, hdr[12..14], @intCast(width), .little);
    std.mem.writeInt(u16, hdr[14..16], @intCast(height), .little);
    hdr[16] = 32; // bits per pixel
    hdr[17] = 0x28; // top-left origin + 8 alpha bits

    // TGA stores BGR(A); flip each pixel's channels.
    const px = allocator.alloc(u8, rgba.len) catch return error.OutOfMemory;
    defer allocator.free(px);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        px[i + 0] = rgba[i + 2];
        px[i + 1] = rgba[i + 1];
        px[i + 2] = rgba[i + 0];
        px[i + 3] = rgba[i + 3];
    }
    out.appendSlice(allocator, &hdr) catch return error.OutOfMemory;
    out.appendSlice(allocator, px) catch return error.OutOfMemory;
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Test-only reader: reverses the encoder so tests can round-trip.

fn decodeTest(allocator: std.mem.Allocator, bytes: []const u8) !struct { rgba: []u8, width: u32, height: u32 } {
    if (bytes.len < header_len) return error.SizeMismatch;
    const image_type = bytes[2];
    if (image_type != 2) return error.SizeMismatch;
    const width = std.mem.readInt(u16, bytes[12..14], .little);
    const height = std.mem.readInt(u16, bytes[14..16], .little);
    const depth = bytes[16];
    if (depth != 32) return error.SizeMismatch;
    const w: usize = width;
    const h: usize = height;
    if (bytes.len != header_len + w * h * 4) return error.SizeMismatch;
    const rgba = try allocator.alloc(u8, w * h * 4);
    var i: usize = 0;
    while (i < w * h * 4) : (i += 4) {
        rgba[i + 0] = bytes[header_len + i + 2];
        rgba[i + 1] = bytes[header_len + i + 1];
        rgba[i + 2] = bytes[header_len + i + 0];
        rgba[i + 3] = bytes[header_len + i + 3];
    }
    return .{ .rgba = rgba, .width = width, .height = height };
}

test "TGA encode round-trips a known image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rgba = [_]u8{
        255, 0, 0,   255, 0,   255, 0,  255,
        0,   0, 255, 255, 128, 64,  32, 16,
    };
    const tga = try encode(a, 2, 2, &rgba);
    try std.testing.expectEqual(@as(usize, 18 + 16), tga.len);
    // header fields
    try std.testing.expectEqual(@as(u8, 2), tga[2]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, tga[12..14], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, tga[14..16], .little));
    try std.testing.expectEqual(@as(u8, 32), tga[16]);
    try std.testing.expectEqual(@as(u8, 0x28), tga[17]);
    // BGR(A) order in the payload
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 32, 64, 128, 16 }, tga[18..34]);

    const dec = try decodeTest(a, tga);
    try std.testing.expectEqual(@as(u32, 2), dec.width);
    try std.testing.expectEqual(@as(u32, 2), dec.height);
    try std.testing.expectEqualSlices(u8, &rgba, dec.rgba);
}

test "TGA encode rejects oversized and mismatched input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.SizeMismatch, encode(a, 2, 2, &[_]u8{0} ** 15));
    try std.testing.expectError(error.DimensionsTooLarge, encode(a, 0x10000, 1, &[_]u8{0} ** (0x10000 * 4)));
    try std.testing.expectError(error.SizeMismatch, encode(a, 0, 0, &.{}));
}
