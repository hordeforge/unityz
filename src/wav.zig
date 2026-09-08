//! Minimal WAV encoder for interleaved integer PCM.
//!
//! Writes the canonical 44-byte RIFF/WAVE header (format tag 1, linear
//! PCM) followed by the sample bytes as given. This is the output side of
//! audio extraction, mirroring what `png`/`tga`/`bmp` are to `texture`:
//! `audio` decodes FSB5 samples to PCM and `vorbis` rebuilds Ogg streams,
//! and the playable container the PCM path needs is written here rather
//! than in whichever tool happens to call it. Decoding WAV is out of
//! scope.

const std = @import("std");

pub const Error = error{OutOfMemory};

const header_len = 44;

/// Serializes decoded 16-bit samples as the little-endian bytes a WAV
/// `data` chunk requires. `sliceAsBytes` over the `[]i16` would emit host
/// order, which silently byte-swaps every sample on a big-endian host while
/// the header it pairs with is written little-endian throughout.
pub fn pcm16LeBytes(allocator: std.mem.Allocator, pcm: []const i16) Error![]u8 {
    const out = try allocator.alloc(u8, pcm.len * 2);
    for (pcm, 0..) |s, i| std.mem.writeInt(i16, out[i * 2 ..][0..2], s, .little);
    return out;
}

/// Wraps interleaved little-endian PCM in a WAV container. `bits` is the
/// source sample width (16 for decoded FSB5 samples; the raw AudioClip
/// path passes its own width).
///
/// Every header field this writes is a fixed-width RIFF field, so the
/// caller owes it arguments whose derived products still fit: `36 +
/// pcm.len` and the byte rate in u32, the block align in u16. Those are
/// clip-supplied values upstream, and the caller that reads them from a
/// file (`wavPcm16` in the CLI) rejects the out-of-range ones as an
/// operating error. Reaching here with one is therefore a caller bug, and
/// the products are computed in u64 and asserted rather than left to wrap
/// a u32 into a plausible-looking but wrong header.
pub fn encode(allocator: std.mem.Allocator, pcm: []const u8, channels: u16, rate: u32, bits: u16) Error![]u8 {
    const riff_size = 36 + @as(u64, pcm.len);
    const byte_rate = @as(u64, rate) * channels * bits / 8;
    const block_align = @as(u64, channels) * bits / 8;
    std.debug.assert(riff_size <= std.math.maxInt(u32));
    std.debug.assert(byte_rate <= std.math.maxInt(u32));
    std.debug.assert(block_align <= std.math.maxInt(u16));

    var hdr: [header_len]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], @intCast(riff_size), .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], channels, .little);
    std.mem.writeInt(u32, hdr[24..28], rate, .little);
    std.mem.writeInt(u32, hdr[28..32], @intCast(byte_rate), .little);
    std.mem.writeInt(u16, hdr[32..34], @intCast(block_align), .little);
    std.mem.writeInt(u16, hdr[34..36], bits, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], @intCast(pcm.len), .little);

    var wav_buf: std.ArrayList(u8) = .empty;
    try wav_buf.appendSlice(allocator, &hdr);
    try wav_buf.appendSlice(allocator, pcm);
    return wav_buf.items;
}

test "pcm16LeBytes writes little-endian samples" {
    const a = std.testing.allocator;
    const out = try pcm16LeBytes(a, &[_]i16{ 1, -2, 0x1234 });
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0xfe, 0xff, 0x34, 0x12 }, out);
}

test "encode writes a canonical 44-byte PCM header" {
    // `encode` returns the ArrayList's `items`, whose backing allocation is
    // the (larger) capacity: an arena, the intended usage, releases it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pcm = [_]u8{ 0x01, 0x00, 0xff, 0x7f };
    const out = try encode(arena.allocator(), &pcm, 2, 44100, 16);

    try std.testing.expectEqual(header_len + pcm.len, out.len);
    try std.testing.expectEqualSlices(u8, "RIFF", out[0..4]);
    try std.testing.expectEqual(@as(u32, 36 + pcm.len), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqualSlices(u8, "WAVE", out[8..12]);
    try std.testing.expectEqualSlices(u8, "fmt ", out[12..16]);
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, out[16..20], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[20..22], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[22..24], .little));
    try std.testing.expectEqual(@as(u32, 44100), std.mem.readInt(u32, out[24..28], .little));
    // byte rate = rate * channels * bits/8, block align = channels * bits/8
    try std.testing.expectEqual(@as(u32, 44100 * 4), std.mem.readInt(u32, out[28..32], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, out[32..34], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, out[34..36], .little));
    try std.testing.expectEqualSlices(u8, "data", out[36..40]);
    try std.testing.expectEqual(@as(u32, pcm.len), std.mem.readInt(u32, out[40..44], .little));
    try std.testing.expectEqualSlices(u8, &pcm, out[header_len..]);
}
