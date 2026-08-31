//! FSB5 audio bank metadata parsing.
//!
//! FSB5 is FMOD's sound bank format. This module reads only the header
//! metadata (no audio decoding): the fixed 48-byte header, the variable
//! chunked per-sample headers, and the name table. Loop points come from
//! each sample's LOOP metadata chunk. The layout follows the fsb5
//! Python package (UnityPy's own dependency), so the fields cross-check
//! against it; UnityPy's export never surfaces this metadata, so
//! emitting it is beyond-parity.

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
};

pub const Bank = struct {
    version: u32,
    num_samples: u32,
    mode: u32,
    samples: []Sample,
};

const FREQUENCY_VALUES = [_]u32{ 0, 8000, 11000, 11025, 16000, 22050, 24000, 32000, 44100, 48000 };

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
        var frequency: u32 = FREQUENCY_VALUES[@intCast((raw >> 1) & 0xf)];
        const channels: u32 = @intCast(((raw >> 5) & 1) + 1);
        const data_offset: u32 = @intCast(((raw >> 6) & 0x0fffffff) * 16);
        const sample_count: u32 = @intCast((raw >> 34) & 0x3fffffff);

        var loop_start: ?u32 = null;
        var loop_end: ?u32 = null;
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
                else => {}, // other chunks (VORBISDATA etc.) are data, not metadata
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
