//! LZ4 block decompressor, implemented from the public LZ4 block format
//! specification.
//!
//! Unity's LZ4-compressed bundle blocks are plain LZ4 blocks: a sequence of
//! tokens, each carrying a literal run and an optional match referencing an
//! offset in the already-decompressed output. There is no frame header, no
//! block-size field, and no checksum — the uncompressed size comes from the
//! Unity bundle block table.
//!
//! Sequence layout (per token):
//!
//! ```text
//! token:           u8        high nibble = literal length (15 = extended),
//!                            low nibble  = match length - 4 (15 = extended)
//! literals:        token>>>4 bytes, plus 255-extension bytes when 15
//! offset:          u16 LE    1-based distance back into the output
//! match length:    low nibble + 4, plus 255-extension bytes when 15
//! ```
//!
//! The final sequence consists of literals only (no offset/match). Overlap
//! between a match and its source is legal (that is how runs like
//! `aaaaaa` are encoded), so matches are copied byte by byte.

const std = @import("std");

pub const Error = error{
    TruncatedInput,
    OutputOverflow,
    InvalidMatch,
    CorruptInput,
};

/// Decompresses an LZ4 block into a fresh `expected_size`-byte buffer.
pub fn decompress(allocator: std.mem.Allocator, src: []const u8, expected_size: usize) Error![]u8 {
    const out = allocator.alloc(u8, expected_size) catch return error.OutputOverflow;
    errdefer allocator.free(out);

    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (true) {
        // A block ends either when the final sequence was literals-only
        // (the `in_pos == src.len` check after the literal copy) or when a
        // match consumed the last of the input.
        if (in_pos > src.len) return error.TruncatedInput;
        if (in_pos == src.len) break;
        const token = src[in_pos];
        in_pos += 1;

        // --- literal run ---
        var lit_len: usize = token >> 4;
        if (lit_len == 15) {
            lit_len += try readExtension(&in_pos, src);
        }
        if (lit_len > expected_size -| out_pos) return error.OutputOverflow;
        if (in_pos + lit_len > src.len) return error.TruncatedInput;
        @memcpy(out[out_pos .. out_pos + lit_len], src[in_pos .. in_pos + lit_len]);
        in_pos += lit_len;
        out_pos += lit_len;

        // End of block: the last sequence never carries a match.
        if (in_pos == src.len) break;

        // --- match ---
        if (in_pos + 2 > src.len) return error.TruncatedInput;
        const offset: usize = @as(usize, src[in_pos]) | (@as(usize, src[in_pos + 1]) << 8);
        in_pos += 2;
        if (offset == 0 or offset > out_pos) return error.InvalidMatch;

        var match_len: usize = token & 0x0f;
        if (match_len == 15) {
            match_len += try readExtension(&in_pos, src);
        }
        match_len += 4;
        if (match_len > expected_size -| out_pos) return error.OutputOverflow;

        // Copy byte by byte so an overlapping match works (LZ4's run idiom).
        for (0..match_len) |_| {
            out[out_pos] = out[out_pos - offset];
            out_pos += 1;
        }
    }

    if (out_pos != expected_size) return error.OutputOverflow;
    return out;
}

/// Reads the 255-extension of a length field. Returns the accumulated extra
/// length beyond the first 15.
fn readExtension(in_pos: *usize, src: []const u8) Error!usize {
    var extra: usize = 0;
    while (true) {
        if (in_pos.* >= src.len) return error.TruncatedInput;
        const b = src[in_pos.*];
        in_pos.* += 1;
        extra += b;
        if (b != 255) break;
    }
    return extra;
}

test "decompress literals only" {
    const a = std.testing.allocator;
    // token 0x40 = 4 literals, no match; then "abcd"
    const out = try decompress(a, "\x40abcd", 4);
    defer a.free(out);
    try std.testing.expectEqualStrings("abcd", out);
}

test "decompress literals then end" {
    const a = std.testing.allocator;
    // empty input decodes to zero bytes
    const out = try decompress(a, "\x00", 0);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "decompress single match" {
    const a = std.testing.allocator;
    // "ab" + match len 6 (2<<... ) at offset 2 → "abababab"
    // token 0x22 = 2 literals, match length 6 (low nibble 2 + 4)
    const out = try decompress(a, "\x22ab\x02\x00", 8);
    defer a.free(out);
    try std.testing.expectEqualStrings("abababab", out);
}

test "decompress run with overlapping match" {
    const a = std.testing.allocator;
    // literal 'x', then match length 9 at offset 1 → 'x' + 9 'x's
    // token 0x15 = 1 literal, match length 5+4=9; offset 1
    const out = try decompress(a, "\x15x\x01\x00", 10);
    defer a.free(out);
    try std.testing.expectEqualStrings("xxxxxxxxxx", out);
}

test "decompress extended literal length" {
    const a = std.testing.allocator;
    // 20 literals: token 0xF0 (15<<4), extension byte 5, then 20 bytes
    const payload = "abcdefghijklmnopqrst"; // 20 bytes
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.append(a, 0xF0);
    try src.append(a, 5);
    try src.appendSlice(a, payload);
    const out = try decompress(a, src.items, 20);
    defer a.free(out);
    try std.testing.expectEqualStrings(payload, out);
}

test "decompress extended match length" {
    const a = std.testing.allocator;
    // literal 'a', match len 4+15+3=22 at offset 1
    // token 0x1F = 1 literal, match nibble 15 → extension 3
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.append(a, 0x1F);
    try src.append(a, 'a');
    try src.appendSlice(a, &.{ 0x01, 0x00 });
    try src.append(a, 3); // match extension
    const out = try decompress(a, src.items, 23);
    defer a.free(out);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaa", out);
}

test "decompress errors" {
    const a = std.testing.allocator;
    // offset 0 is invalid
    try std.testing.expectError(error.InvalidMatch, decompress(a, "\x11a\x00\x00", 5));
    // offset beyond output start is invalid
    try std.testing.expectError(error.InvalidMatch, decompress(a, "\x11a\x05\x00", 5));
    // truncated input
    try std.testing.expectError(error.TruncatedInput, decompress(a, "\x22ab\x02", 8));
    // output size mismatch (decode yields fewer bytes than declared)
    try std.testing.expectError(error.OutputOverflow, decompress(a, "\x40abcd", 5));
}
