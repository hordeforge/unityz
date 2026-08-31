//! FSB5 audio sample decoding to 16-bit PCM, in pure Zig.
//!
//! Covers the codecs that do not need a full transform decoder: PCM8 (1),
//! PCM16 (2), PCM24 (3), PCM32 (4), PCMFLOAT (5), GCADPCM (6, the GC
//! DSP framing FSB5 uses - 8-byte blocks, 14 signed nibbles each, with
//! the 8 coefficient pairs from the DSPCOEFS chunk), and IMA ADPCM (7,
//! the XBOX IMA framing FSB5 uses for 1-2 channels - 36-byte
//! per-channel blocks, header sample + 63 nibble samples, state reset
//! per block). The framing follows vgmstream's fsb5.c, ima_decoder.c
//! and ngc_dsp_decoder.c.
//!
//! Vorbis banks (mode 15) are NOT decoded here: they carry no codec
//! headers and need a full transform codec. UnityPy shells out to ffmpeg
//! for every FSB5 conversion; this module removes that dependency for the
//! modes above. (ffmpeg's own FSB5 demuxer only handles FSB v3/v4, so it
//! cannot even read these banks.)

const std = @import("std");
const fsb5 = @import("fsb5.zig");

pub const Error = error{
    UnsupportedMode,
    UnsupportedChannels,
    Corrupt,
    OutOfMemory,
};

/// True when `decodeSample` can convert the mode to PCM16.
pub fn decodable(mode: u32) bool {
    return mode >= 1 and mode <= 5 or mode == 6 or mode == 7;
}

/// Short codec name for reporting.
pub fn modeName(mode: u32) []const u8 {
    return switch (mode) {
        1 => "PCM8",
        2 => "PCM16",
        3 => "PCM24",
        4 => "PCM32",
        5 => "PCMFLOAT",
        6 => "GCADPCM",
        7 => "IMA ADPCM",
        else => "unknown",
    };
}

const ima_index_table = [_]i16{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };
const ima_step_table = [_]i16{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,    19,    21,
    23,    25,    28,    31,    34,    37,    41,    45,    50,    55,    60,    66,
    73,    80,    88,    97,    107,   118,   130,   143,   157,   173,   190,   209,
    230,   253,   279,   307,   337,   371,   408,   449,   494,   544,   598,   658,
    724,   796,   876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
    2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,  5894,  6484,
    7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
    22385, 24623, 27086, 29794, 32767,
};

/// Decodes one sample's data to interleaved 16-bit PCM. `data_start` is
/// the bank's sample-data section offset (see `fsb5.Bank.data_start`);
/// the sample's bytes live at `data_start + sample.data_offset`.
pub fn decodeSample(allocator: std.mem.Allocator, raw: []const u8, data_start: u32, sample: fsb5.Sample, mode: u32) Error![]i16 {
    if (!decodable(mode)) return error.UnsupportedMode;
    const channels: usize = @intCast(sample.channels);
    if (channels == 0 or channels > 2 and mode == 7) return error.UnsupportedChannels;
    const start: usize = @intCast(data_start + sample.data_offset);
    const total: usize = @as(usize, sample.sample_count) * channels;
    if (start > raw.len) return error.Corrupt;
    const data = raw[start..];
    const out = allocator.alloc(i16, total) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    switch (mode) {
        1 => { // PCM8: unsigned bytes, interleaved
            if (data.len < total) return error.Corrupt;
            for (0..total) |i| out[i] = @as(i16, data[i]) -% 128 << 8;
        },
        2 => { // PCM16: signed little-endian, interleaved
            if (data.len < total * 2) return error.Corrupt;
            for (0..total) |i| out[i] = std.mem.readInt(i16, data[i * 2 ..][0..2], .little);
        },
        3 => { // PCM24: sign-extended little-endian, truncated to 16 bits
            if (data.len < total * 3) return error.Corrupt;
            for (0..total) |i| {
                const b0: u32 = data[i * 3];
                const b1: u32 = data[i * 3 + 1];
                const b2: u32 = data[i * 3 + 2];
                var v: i32 = @bitCast((b2 << 24) | (b1 << 16) | (b0 << 8));
                v >>= 16; // arithmetic shift sign-extends and keeps the top 16 bits
                out[i] = @intCast(v);
            }
        },
        4 => { // PCM32: signed little-endian, truncated to 16 bits
            if (data.len < total * 4) return error.Corrupt;
            for (0..total) |i| {
                const v = std.mem.readInt(i32, data[i * 4 ..][0..4], .little);
                out[i] = @intCast(v >> 16);
            }
        },
        5 => { // PCMFLOAT: f32 little-endian in [-1, 1]
            if (data.len < total * 4) return error.Corrupt;
            for (0..total) |i| {
                const f = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
                const v: f32 = @bitCast(f);
                const clamped = std.math.clamp(v, -1.0, 1.0);
                // Compute in f64: doing the multiply in f32 rounds the
                // product, and the resulting 1-LSB error is visible after
                // truncation to i16 (e.g. 0.9929... vs 0.9928...).
                out[i] = @intFromFloat(@as(f64, clamped) * 32767.0);
            }
        },
        6 => return decodeGcadpcm(out, data, channels, sample.sample_count, sample.dsp_coefs),
        7 => return decodeXboxIma(out, data, channels, sample.sample_count),
        else => unreachable,
    }
    return out;
}

/// GC ADPCM, the FSB5 framing for mode 6 (FMOD_SOUND_FORMAT_GCADPCM):
/// fixed 8-byte blocks, 14 samples each. Block byte 0 packs the
/// predictor index in the high nibble and the scale exponent in the
/// low nibble; the next 7 bytes hold 14 signed nibbles, high nibble
/// first, one nibble unused. The 8 coefficient pairs come from the
/// bank's DSPCOEFS metadata chunk (big-endian s16). Mirrors vgmstream's
/// ngc_dsp_decoder.c and Fmod5Sharp's FmodGcadPcmRebuilder.
///
/// Mono only: vgmstream decodes multi-channel GCADPCM with its
/// subframe-interleave framing (2-byte interleave), a different layout
/// with no sample available to verify against - report the channel
/// count unsupported rather than guess.
fn decodeGcadpcm(out: []i16, data: []const u8, channels: usize, sample_count: u32, coefs: []const i16) Error![]i16 {
    if (channels != 1) return error.UnsupportedChannels;
    if (coefs.len < 16) return error.Corrupt;
    const block_samples: usize = 14;
    const block_size: usize = 8;
    var produced: usize = 0;
    var hist1: i32 = 0;
    var hist2: i32 = 0;
    var block: usize = 0;
    while (produced < sample_count) : (block += 1) {
        const boff = block * block_size;
        if (boff + block_size > data.len) return error.Corrupt;
        const scale: i32 = @as(i32, 1) << @intCast(data[boff] & 0xf);
        var coef_index: usize = (data[boff] >> 4) & 0xf;
        if (coef_index > 7) coef_index = 7; // vgmstream clamps; FMOD may not
        const c1: i32 = coefs[coef_index * 2 + 0];
        const c2: i32 = coefs[coef_index * 2 + 1];
        var i: usize = 0;
        while (i < block_samples and produced + i < sample_count) : (i += 1) {
            const nibbles = data[boff + 1 + i / 2];
            var nib: i8 = if (i & 1 == 0) @as(i8, @bitCast(nibbles >> 4)) else @as(i8, @bitCast(nibbles & 0xf));
            nib = (nib << 4) >> 4; // sign-extend the 4-bit nibble
            var v: i32 = @as(i32, nib) * scale << 11;
            v = (v + 1024 + c1 * hist1 + c2 * hist2) >> 11;
            const clamped = std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16));
            hist2 = hist1;
            hist1 = clamped;
            out[produced + i] = @intCast(clamped);
        }
        produced += block_samples;
    }
    return out;
}

/// XBOX IMA ADPCM, the framing FSB5 uses for 1-2 channel banks: fixed
/// 36-byte blocks per channel (4-byte header: s16 predictor, s8 step
/// index, 1 reserved; then 32 bytes of nibbles), 64 samples per block
/// with the state reset at each block, low nibble first, one nibble per
/// block unused. Mirrors vgmstream's decode_xbox_ima.
fn decodeXboxIma(out: []i16, data: []const u8, channels: usize, sample_count: u32) Error![]i16 {
    const block_samples: usize = 64;
    const frame_size: usize = 36 * channels;
    var frame: usize = 0;
    var produced: usize = 0;
    while (produced < sample_count) : (frame += 1) {
        const frame_off = frame * frame_size;
        for (0..channels) |ch| {
            // per-channel block header
            const header_off = frame_off + 4 * ch;
            if (header_off + 4 > data.len) return error.Corrupt;
            var hist1: i32 = std.mem.readInt(i16, data[header_off..][0..2], .little);
            var step_index: i32 = data[header_off + 2];
            if (step_index < 0) step_index = 0;
            if (step_index > 88) step_index = 88;
            var i: usize = 0;
            while (i < block_samples and produced + i < sample_count) : (i += 1) {
                if (i != 0) {
                    // nibble byte: mono straight, stereo 4 bytes per channel
                    const nib_off = if (channels == 2)
                        frame_off + 8 + 4 * ch + 8 * ((i - 1) / 8) + ((i - 1) % 8) / 2
                    else
                        frame_off + 4 + (i - 1) / 2;
                    if (nib_off >= data.len) return error.Corrupt;
                    const shift: u3 = if ((i - 1) & 1 == 0) 0 else 4; // low nibble first
                    const code: i32 = (data[nib_off] >> shift) & 0xf;
                    const step: i32 = ima_step_table[@intCast(step_index)];
                    var delta: i32 = step >> 3;
                    if (code & 1 != 0) delta += step >> 2;
                    if (code & 2 != 0) delta += step >> 1;
                    if (code & 4 != 0) delta += step;
                    if (code & 8 != 0) delta = -delta;
                    hist1 += delta;
                    hist1 = std.math.clamp(hist1, std.math.minInt(i16), std.math.maxInt(i16));
                    step_index += ima_index_table[@intCast(code)];
                    if (step_index < 0) step_index = 0;
                    if (step_index > 88) step_index = 88;
                }
                out[(produced + i) * channels + ch] = @intCast(hist1);
            }
        }
        produced += block_samples;
    }
    return out;
}

test "PCM16 decode" {
    const a = std.testing.allocator;
    const raw = [_]u8{ 0x00, 0x00, 0x34, 0x12, 0xcd, 0xab, 0x01, 0x80 };
    const s = fsb5.Sample{ .data_offset = 0, .sample_count = 4, .channels = 1, .frequency = 8000 };
    const pcm = try decodeSample(a, &raw, 0, s, 2);
    defer a.free(pcm);
    try std.testing.expectEqualSlices(i16, &.{ 0, 0x1234, -0x5433, -0x7fff }, pcm);
}

test "PCMFLOAT decode promotes to f64 before truncation" {
    const a = std.testing.allocator;
    // 0x3f731e23 as f32; f32(f32*f32(32767)) truncates to 31121, but the
    // exact (f64) product truncates to 31120 — the reference fsb5.py
    // computes in f64, so we must too.
    const raw = [_]u8{ 0xe6, 0x23, 0x73, 0x3f };
    const s = fsb5.Sample{ .data_offset = 0, .sample_count = 1, .channels = 1, .frequency = 8000 };
    const pcm = try decodeSample(a, &raw, 0, s, 5);
    defer a.free(pcm);
    try std.testing.expectEqual(@as(i16, 31120), pcm[0]);
}

test "IMA decode matches a hand-computed block" {
    const a = std.testing.allocator;
    // mono block: predictor 1000, step index 5, then nibbles for
    // samples 1..2 (codes 4 then 8) and zeros for the rest
    var data: [36]u8 = [_]u8{0} ** 36;
    std.mem.writeInt(i16, data[0..2], 1000, .little);
    data[2] = 5;
    data[4] = 0x84; // low nibble = 4, high nibble = 8
    const s = fsb5.Sample{ .data_offset = 0, .sample_count = 3, .channels = 1, .frequency = 8000 };
    const pcm = try decodeSample(a, &data, 0, s, 7);
    defer a.free(pcm);
    // step table[5] = 12; code 4 -> delta = 12>>3 + 12 = 13; the index
    // then moves to 7 (step 14), code 8 -> delta = -(14>>3) = -1
    try std.testing.expectEqual(@as(i16, 1000), pcm[0]);
    try std.testing.expectEqual(@as(i16, 1013), pcm[1]);
    try std.testing.expectEqual(@as(i16, 1012), pcm[2]);
}

test "GCADPCM decode matches a hand-computed block" {
    const a = std.testing.allocator;
    // 8-byte block: predictor 0, scale exponent 0; nibbles +1,-1,+2,-2,
    // +1, then zeros. With coefficient pair (0,0) the filter is the
    // identity: out == nibble (nibbles are signed 4-bit, high nibble
    // first).
    const data = [_]u8{ 0x00, 0x1f, 0x2e, 0x10, 0x00, 0x00, 0x00, 0x00 };
    const coefs = [_]i16{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const s = fsb5.Sample{ .data_offset = 0, .sample_count = 14, .channels = 1, .frequency = 8000, .dsp_coefs = &coefs };
    const pcm = try decodeSample(a, &data, 0, s, 6);
    defer a.free(pcm);
    try std.testing.expectEqualSlices(i16, &.{ 1, -1, 2, -2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, pcm);
}
