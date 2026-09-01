//! FSB5 audio bank metadata parsing.
//!
//! FSB5 is FMOD's sound bank format. This module reads only the header
//! metadata (no audio decoding): the 60-byte header (64 when the version
//! field is 0), the variable chunked per-sample headers, and the name
//! table. Loop points come from each sample's LOOP metadata chunk. The
//! layout follows the fsb5 Python package (UnityPy's own dependency), so
//! the fields cross-check against it; UnityPy's export never surfaces
//! this metadata, so emitting it is beyond-parity.

const std = @import("std");

pub const Sample = struct {
    name: []const u8 = "",
    frequency: u32 = 0,
    channels: u32 = 0,
    data_offset: u32 = 0,
    sample_count: u32 = 0,
    /// Loop points from the LOOP metadata chunk, if present.
    loop_start: ?u32 = null,
    loop_end: ?u32 = null,
    /// GCADPCM (mode 6) coefficient pairs from the DSPCOEFS chunk:
    /// 16 big-endian s16 per channel (8 pairs), followed by 14 bytes of
    /// per-channel header data that FMOD writes but decoders skip.
    dsp_coefs: []const i16 = &.{},
    /// Vorbis (mode 15) setup-header CRC from the VORBISDATA chunk; the
    /// CRC identifies the encoder's setup packet (codebooks + modes) in
    /// the vorbis_headers table, which the Ogg reconstruction needs.
    vorbis_crc: ?u32 = null,
};

pub const Bank = struct {
    version: u32,
    num_samples: u32,
    mode: u32,
    samples: []Sample,
    /// Absolute offset of the sample-data section (header + sample
    /// headers + name table); sample data lives at `data_start +
    /// sample.data_offset`.
    data_start: u32,
};

/// FSB5 sample-rate codes (FMOD's frequency nibble). Code 0 is 4000 Hz,
/// not "unknown"; code 10 is 96000. A bank with a non-standard rate
/// carries a FREQUENCY metadata chunk that overrides this table.
/// Mirrors vgmstream's fsb5.c and Fmod5Sharp's FsbLoader.Frequencies
/// (which both map 0 -> 4000, 10 -> 96000); fsb5.py lacks both entries.
const FREQUENCY_VALUES = [_]u32{ 4000, 8000, 11000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 96000 };

/// Parses FSB5 metadata from `data`. Returns null when the data is not a
/// well-formed FSB5 bank (bad magic, truncated, or inconsistent).
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !?Bank {
    if (data.len < 60 or !std.mem.eql(u8, data[0..4], "FSB5")) return null;
    const version = std.mem.readInt(u32, data[4..8], .little);
    const num_samples = std.mem.readInt(u32, data[8..12], .little);
    const sample_headers_size = std.mem.readInt(u32, data[12..16], .little);
    const name_table_size = std.mem.readInt(u32, data[16..20], .little);
    const mode = std.mem.readInt(u32, data[24..28], .little);

    if (num_samples > 4096) return null; // sanity: banks have few samples
    // 60-byte header: magic, 6 u32s, 8 zero, 16 hash, 8 dummy
    var header_size: usize = 60;
    if (version == 0) header_size += 4;

    const samples = try allocator.alloc(Sample, num_samples);
    errdefer allocator.free(samples);
    @memset(samples, Sample{});

    var pos = header_size;
    const headers_end = header_size + sample_headers_size;
    if (headers_end > data.len) return null;

    var i: usize = 0;
    while (i < num_samples) : (i += 1) {
        if (pos + 8 > headers_end) return null;
        const raw = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        var next_chunk = raw & 1 != 0;
        // The code is 4 bits (0-15); 0-10 name standard rates (see
        // FREQUENCY_VALUES). Codes 11-15 are rejected by FMOD, so an
        // out-of-range code must not index the table - report 0
        // (unknown) rather than guessing. A FREQUENCY chunk below is
        // what carries a non-standard rate, and it overrides this.
        const freq_code: usize = @intCast((raw >> 1) & 0xf);
        var frequency: u32 = if (freq_code < FREQUENCY_VALUES.len) FREQUENCY_VALUES[freq_code] else 0;
        const channels: u32 = @intCast(((raw >> 5) & 1) + 1);
        const data_offset: u32 = @intCast(((raw >> 6) & 0x0fffffff) * 16);
        const sample_count: u32 = @intCast((raw >> 34) & 0x3fffffff);

        var loop_start: ?u32 = null;
        var loop_end: ?u32 = null;
        var dsp_coefs: []const i16 = &.{};
        var vorbis_crc: ?u32 = null;
        while (next_chunk) {
            if (pos + 4 > headers_end) return null;
            const chunk = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            next_chunk = chunk & 1 != 0;
            const chunk_size: usize = @intCast((chunk >> 1) & 0xffffff);
            const chunk_type: u8 = @intCast((chunk >> 25) & 0x7f);
            if (pos + chunk_size > headers_end) return null;
            switch (chunk_type) {
                2 => { // FREQUENCY: u32 override
                    if (chunk_size >= 4) frequency = std.mem.readInt(u32, data[pos..][0..4], .little);
                },
                3 => { // LOOP: u32 start, u32 end
                    if (chunk_size >= 8) {
                        loop_start = std.mem.readInt(u32, data[pos..][0..4], .little);
                        loop_end = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
                    }
                },
                7 => { // DSPCOEFS: GCADPCM coefficients, 46 bytes per channel
                    // (16 big-endian s16 + 14 bytes FMOD writes, skipped)
                    const per_channel: usize = 46;
                    if (chunk_size >= per_channel * channels) {
                        const coefs = try allocator.alloc(i16, 16 * channels);
                        errdefer allocator.free(coefs);
                        for (0..channels) |ch| {
                            const base = pos + per_channel * ch;
                            for (0..16) |k| {
                                coefs[ch * 16 + k] = std.mem.readInt(i16, data[base + 2 * k ..][0..2], .big);
                            }
                        }
                        dsp_coefs = coefs;
                    }
                },
                11 => { // VORBISDATA: u32 setup-header CRC + seek table
                    if (chunk_size >= 4) vorbis_crc = std.mem.readInt(u32, data[pos..][0..4], .little);
                },
                else => {}, // other chunks are data, not metadata
            }
            pos += chunk_size;
        }

        samples[i] = .{
            .frequency = frequency,
            .channels = channels,
            .data_offset = data_offset,
            .sample_count = sample_count,
            .loop_start = loop_start,
            .loop_end = loop_end,
            .dsp_coefs = dsp_coefs,
            .vorbis_crc = vorbis_crc,
        };
    }

    // name table: num_samples u32 offsets into the table, then strings
    if (name_table_size != 0) {
        const table_start = headers_end;
        if (table_start + name_table_size > data.len) return null;
        var name_pos = table_start;
        for (0..num_samples) |si| {
            if (name_pos + 4 > table_start + name_table_size) break;
            const off = std.mem.readInt(u32, data[name_pos..][0..4], .little);
            name_pos += 4;
            const str_start = table_start + off;
            if (str_start >= data.len) continue;
            var end = str_start;
            while (end < data.len and end < str_start + name_table_size and data[end] != 0) : (end += 1) {}
            samples[si].name = try allocator.dupe(u8, data[str_start..end]);
        }
    }

    return Bank{
        .version = version,
        .num_samples = num_samples,
        .mode = mode,
        .samples = samples,
        .data_start = @intCast(headers_end + name_table_size),
    };
}

test "fsb5 metadata parse round trip" {
    const a = std.testing.allocator;
    // hand-built bank: header + one sample with a LOOP chunk + name table
    const blob = [_]u8{
        0x46, 0x53, 0x42, 0x35, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
        0x0d, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00,
        0xa0, 0x0f, 0x00, 0x00, 0x10, 0x00, 0x00, 0x06, 0x64, 0x00, 0x00, 0x00, 0x84, 0x03, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x6c, 0x6f, 0x6f, 0x70, 0x63, 0x6c, 0x69, 0x70, 0x00,
    };
    const bank = (try parse(a, &blob)).?;
    defer a.free(bank.samples);
    defer a.free(bank.samples[0].name);
    try std.testing.expectEqual(@as(u32, 15), bank.mode);
    try std.testing.expectEqual(@as(u32, 1), bank.num_samples);
    try std.testing.expectEqual(@as(u32, 44100), bank.samples[0].frequency);
    try std.testing.expectEqual(@as(u32, 1), bank.samples[0].channels);
    try std.testing.expectEqual(@as(u32, 1000), bank.samples[0].sample_count);
    try std.testing.expectEqual(@as(u32, 100), bank.samples[0].loop_start.?);
    try std.testing.expectEqual(@as(u32, 900), bank.samples[0].loop_end.?);
    try std.testing.expectEqualStrings("loopclip", bank.samples[0].name);
}

test "fsb5 frequency codes 0 and 10" {
    const a = std.testing.allocator;
    // minimal banks with no metadata chunks: 60-byte header + one
    // 8-byte sample header (next_chunk=0, mono, 1000 samples). Codes
    // 0 and 10 name real rates (4000 / 96000); fsb5.py rejects both.
    for ([_]u32{ 0, 10 }) |code| {
        var blob: [68]u8 = [_]u8{0} ** 68;
        @memcpy(blob[0..4], "FSB5");
        std.mem.writeInt(u32, blob[4..8], 1, .little); // version
        std.mem.writeInt(u32, blob[8..12], 1, .little); // num_samples
        std.mem.writeInt(u32, blob[12..16], 8, .little); // hdr_size
        std.mem.writeInt(u32, blob[24..28], 2, .little); // mode
        const raw = (@as(u64, code) << 1) | (@as(u64, 1000) << 34);
        std.mem.writeInt(u64, blob[60..68], raw, .little);
        const bank = (try parse(a, &blob)).?;
        defer a.free(bank.samples);
        try std.testing.expectEqual(@as(u32, 1000), bank.samples[0].sample_count);
        try std.testing.expectEqual(if (code == 0) @as(u32, 4000) else 96000, bank.samples[0].frequency);
    }
}

test "fsb5 DSPCOEFS chunk parse" {
    const a = std.testing.allocator;
    // header + one sample with a DSPCOEFS chunk (46 bytes: 32 big-endian
    // s16 coefficient pairs + 14 bytes of per-channel data FMOD writes)
    var blob: [60 + 8 + 4 + 46]u8 = [_]u8{0} ** (60 + 8 + 4 + 46);
    @memcpy(blob[0..4], "FSB5");
    std.mem.writeInt(u32, blob[4..8], 1, .little); // version
    std.mem.writeInt(u32, blob[8..12], 1, .little); // num_samples
    std.mem.writeInt(u32, blob[12..16], 58, .little); // hdr_size
    std.mem.writeInt(u32, blob[24..28], 6, .little); // mode GCADPCM
    const raw = (@as(u64, 3) << 1) | (@as(u64, 1000) << 34) | 1; // freq 11025, next_chunk
    std.mem.writeInt(u64, blob[60..68], raw, .little);
    std.mem.writeInt(u32, blob[68..72], (@as(u32, 7) << 25) | (46 << 1), .little); // DSPCOEFS, last chunk
    for (0..16) |k| {
        const v: i16 = @intCast(@as(i32, @intCast(k)) * 100 - 500);
        std.mem.writeInt(i16, blob[72 + 2 * k ..][0..2], v, .big);
    }
    const bank = (try parse(a, &blob)).?;
    defer a.free(bank.samples);
    defer a.free(bank.samples[0].dsp_coefs);
    try std.testing.expectEqual(@as(u32, 6), bank.mode);
    try std.testing.expectEqual(@as(u32, 11025), bank.samples[0].frequency);
    try std.testing.expectEqual(@as(usize, 16), bank.samples[0].dsp_coefs.len);
    for (0..16) |k| {
        const want: i16 = @intCast(@as(i32, @intCast(k)) * 100 - 500);
        try std.testing.expectEqual(want, bank.samples[0].dsp_coefs[k]);
    }
}

test "fsb5 parser survives mutated and truncated banks" {
    // Hostile bank data must never crash the metadata parser: mutations
    // and truncations of the hand-built bank (header, sample table, chunk
    // chain) must parse cleanly or fail with an error - never panic.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const blob = [_]u8{
        0x46, 0x53, 0x42, 0x35, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
        0x0d, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00,
        0xa0, 0x0f, 0x00, 0x00, 0x10, 0x00, 0x00, 0x06, 0x64, 0x00, 0x00, 0x00, 0x84, 0x03, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x6c, 0x6f, 0x6f, 0x70, 0x63, 0x6c, 0x69, 0x70, 0x00,
    };

    var prng = std.Random.DefaultPrng.init(0xf5b5);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        const mode = rnd.int(u8) % 3;
        const blen = switch (mode) {
            0 => rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(blob.len))), // truncate
            1 => blob.len, // mutate
            else => rnd.intRangeAtMost(u32, 0, 128), // random
        };
        @memcpy(buf[0..blob.len], &blob);
        if (mode == 1) {
            const m = rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(blob.len - 1)));
            buf[m] ^= @intCast(rnd.int(u8) | 1);
        } else if (mode == 2 and blen > 0) {
            rnd.bytes(buf[0..blen]);
        }
        const bank = try parse(a, buf[0..blen]);
        if (bank) |bk| {
            // a parsed bank's sample table must be reachable
            for (bk.samples) |s| _ = s.name;
        }
    }
}
