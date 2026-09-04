//! FSB5 Vorbis (mode 15) to playable Ogg reconstruction, in pure Zig.
//!
//! FSB5 stores Vorbis audio as a raw packet stream - [u16 LE size][packet]
//! pairs, terminated by size 0 or 0xFFFF. The Vorbis identification and
//! comment headers are synthesized, and the setup header (codebooks +
//! modes) comes from a CRC-keyed table of FMOD encoder configurations:
//! the bank's VORBISDATA metadata chunk carries the CRC that identifies
//! which setup packet the audio was encoded with. The result is a
//! standard Ogg/Vorbis stream playable by any decoder.
//!
//! UnityPy shells out to ffmpeg for every FSB5 conversion; this module
//! removes that dependency for Vorbis banks too. The framing (packet
//! reading, granule tracking, page-out rules, header synthesis) mirrors
//! Fmod5Sharp's FmodVorbisRebuilder + OggVorbisEncoder, and the setup
//! header table is generated from Fmod5Sharp's (MIT).

const std = @import("std");
const fsb5 = @import("fsb5.zig");
const headers = @import("vorbis_headers_index.zig");
const blob = @embedFile("vorbis_headers.bin");

pub const Error = error{ OutOfMemory, Corrupt, UnknownSetup };

const ogg_crc_table = blk: {
    @setEvalBranchQuota(100000);
    // Standard Ogg CRC-32 (polynomial 0x04c11db7, no reflection).
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var r: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            r = if (r & 0x80000000 != 0) (r << 1) ^ 0x04c11db7 else r << 1;
        }
        table[i] = r;
    }
    break :blk table;
};

/// Looks up the setup header + mode-section bit offset for `crc`.
fn setupFor(crc: u32) ?struct { header: []const u8, seek_bit: u32 } {
    // binary search the sorted crc index
    var lo: usize = 0;
    var hi: usize = headers.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (headers.crcs[mid] < crc) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= headers.count or headers.crcs[lo] != crc) return null;
    const off = headers.offsets[lo];
    if (off + 12 > blob.len) return null;
    const stored = std.mem.readInt(u32, blob[off..][0..4], .little);
    if (stored != crc) return null;
    const seek_bit = std.mem.readInt(u32, blob[off + 4 ..][0..4], .little);
    const len: usize = std.mem.readInt(u32, blob[off + 8 ..][0..4], .little);
    if (off + 12 + len > blob.len) return null;
    return .{ .header = blob[off + 12 ..][0..len], .seek_bit = seek_bit };
}

/// Whether the embedded FMOD setup-header table can reconstruct `crc`.
pub fn setupKnown(crc: u32) bool {
    return setupFor(crc) != null;
}

test "setupKnown distinguishes catalogued setup headers" {
    try std.testing.expect(setupKnown(headers.crcs[0]));
    try std.testing.expect(!setupKnown(0));
}

/// MSB-first bit reader over a byte slice.
const BitReader = struct {
    data: []const u8,
    bit: usize = 0,

    fn readBit(self: *BitReader) u1 {
        if (self.bit >= self.data.len * 8) return 0;
        const byte = self.data[self.bit / 8];
        const shift: u3 = @intCast(self.bit % 8);
        self.bit += 1;
        return @intCast((byte >> shift) & 1);
    }

    fn readBits(self: *BitReader, count: usize) u32 {
        var v: u32 = 0;
        for (0..count) |i| v |= @as(u32, self.readBit()) << @intCast(i);
        return v;
    }

    fn seek(self: *BitReader, bit: usize) void {
        self.bit = bit;
    }
};

/// Per-mode block flags parsed from the setup header's mode section.
const BlockFlags = struct {
    flags: []bool,

    /// Parses the mode list out of the setup packet. Returns null when the
    /// header is not a vorbis setup packet.
    fn parse(allocator: std.mem.Allocator, setup: []const u8, seek_bit: u32) Error!?BlockFlags {
        // Bit order follows Fmod5Sharp's BitStream (LSB-first by default);
        // its rebuilt oggs are the byte-exact reference for this module.
        var br = BitReader{ .data = setup };
        if (br.readBits(8) != 5) return null; // packing type 5 = books
        var magic: [6]u8 = undefined;
        for (&magic) |*b| b.* = @intCast(br.readBits(8));
        if (!std.mem.eql(u8, &magic, "vorbis")) return null;
        br.seek(seek_bit);
        const num_modes: usize = @intCast(br.readBits(6) + 1);
        const flags = try allocator.alloc(bool, num_modes);
        for (flags) |*f| {
            f.* = br.readBit() != 0;
            _ = br.readBits(16); // window type
            _ = br.readBits(16); // transform type
            _ = br.readBits(8); // mapping
        }
        return .{ .flags = flags };
    }

    /// The number of mode bits in an audio packet's header.
    fn modeBits(self: BlockFlags) usize {
        // Fmod5Sharp reads `num_modes - 1` bits; matches the spec's
        // ceil(log2(num_modes)) for the 1-3 mode configs FMOD uses, and
        // keeps byte parity with its output.
        return self.flags.len - 1;
    }

    fn blockSize(self: BlockFlags, packet: []const u8) u32 {
        var br = BitReader{ .data = packet };
        if (br.readBit() != 0) return 0; // reserved/continuation packet
        var mode: usize = 0;
        if (self.flags.len > 1) mode = @intCast(br.readBits(self.modeBits()));
        if (mode >= self.flags.len) return 0;
        return if (self.flags[mode]) 2048 else 256;
    }
};

/// Ogg logical stream: buffers packets into pages with the standard
/// page-out rules (BOS page holds the first packet; pages flush when the
/// body exceeds 4096 bytes with >= 4 completed packets, at 255 segments,
/// or when forced).
const OggStream = struct {
    serial: u32,
    body: std.ArrayList(u8),
    lacing: std.ArrayList(i32),
    granule_values: std.ArrayList(i64),
    granule_position: i64 = 0,
    page_number: i32 = 0,
    writes_started: bool = false,
    finished: bool = false,
    body_returned: usize = 0,

    fn init(allocator: std.mem.Allocator, serial: u32) OggStream {
        _ = allocator;
        return .{
            .serial = serial,
            .body = std.ArrayList(u8).empty,
            .lacing = std.ArrayList(i32).empty,
            .granule_values = std.ArrayList(i64).empty,
        };
    }

    fn deinit(self: *OggStream, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
        self.lacing.deinit(allocator);
        self.granule_values.deinit(allocator);
    }

    fn packetIn(self: *OggStream, allocator: std.mem.Allocator, data: []const u8, granule: i64, eos: bool) Error!void {
        self.clearReturnedBody();
        const lacing_count = data.len / 255 + 1;
        try self.body.appendSlice(allocator, data);
        var i: usize = 0;
        while (i + 1 < lacing_count) : (i += 1) {
            try self.lacing.append(allocator, 255);
            try self.granule_values.append(allocator, self.granule_position);
        }
        try self.lacing.append(allocator, @intCast(data.len % 255));
        self.granule_position = granule;
        try self.granule_values.append(allocator, granule);
        // flag the first segment as the start of a packet
        self.lacing.items[self.lacing.items.len - lacing_count] |= 0x100;
        if (eos) self.finished = true;
    }

    fn clearReturnedBody(self: *OggStream) void {
        if (self.body_returned != 0) {
            std.mem.copyForwards(u8, self.body.items, self.body.items[self.body_returned..]);
            self.body.shrinkRetainingCapacity(self.body.items.len - self.body_returned);
            self.body_returned = 0;
        }
    }

    /// Returns the next page (header + body), or null when no page is due.
    fn pageOut(self: *OggStream, allocator: std.mem.Allocator, force: bool) Error!?[]u8 {
        const max_values = @min(self.lacing.items.len, 255);
        if (max_values == 0) return null;

        var acc: usize = 0;
        var granule_position: i64 = -1;
        var vals: usize = 0;

        if (!self.writes_started) {
            // BOS page: only the first packet
            granule_position = 0;
            while (vals < max_values) : (vals += 1) {
                if ((self.lacing.items[vals] & 0xff) < 255) {
                    vals += 1;
                    break;
                }
            }
        } else {
            var packets_done: usize = 0;
            var packets_just_done: usize = 0;
            var force_now = force;
            while (vals < max_values) : (vals += 1) {
                if (acc > 4096 and packets_just_done >= 4) {
                    force_now = true;
                    break;
                }
                acc += @intCast(self.lacing.items[vals] & 0xff);
                if ((self.lacing.items[vals] & 0xff) < 255) {
                    granule_position = self.granule_values.items[vals];
                    packets_just_done = packets_done + 1;
                    packets_done += 1;
                } else {
                    packets_just_done = 0;
                }
            }
            if (vals == 255) force_now = true;
            if (!force_now) return null;
        }

        // segment table + body size
        var bytes: usize = 0;
        var seg: [255]u8 = undefined;
        for (0..vals) |i| {
            seg[i] = @intCast(self.lacing.items[i] & 0xff);
            bytes += seg[i];
        }

        var header: [27 + 255]u8 = undefined;
        @memcpy(header[0..4], "OggS");
        header[4] = 0;
        header[5] = 0;
        if ((self.lacing.items[0] & 0x100) == 0) header[5] |= 0x01;
        if (!self.writes_started) header[5] |= 0x02;
        if (self.finished and self.lacing.items.len == vals) header[5] |= 0x04;
        self.writes_started = true;

        std.mem.writeInt(i64, header[6..14], granule_position, .little);
        std.mem.writeInt(u32, header[14..18], self.serial, .little);
        std.mem.writeInt(u32, header[18..22], @bitCast(self.page_number), .little);
        self.page_number +%= 1;
        std.mem.writeInt(u32, header[22..26], 0, .little); // crc, filled below
        header[26] = @intCast(vals);
        @memcpy(header[27 .. 27 + vals], seg[0..vals]);

        // CRC over header + body
        var crc_reg: u32 = 0;
        for (header[0 .. 27 + vals]) |b| {
            crc_reg = (crc_reg << 8) ^ ogg_crc_table[((crc_reg >> 24) & 0xff) ^ b];
        }
        const body = self.body.items[self.body_returned .. self.body_returned + bytes];
        for (body) |b| {
            crc_reg = (crc_reg << 8) ^ ogg_crc_table[((crc_reg >> 24) & 0xff) ^ b];
        }
        std.mem.writeInt(u32, header[22..26], crc_reg, .little);

        const page = try allocator.alloc(u8, 27 + vals + bytes);
        @memcpy(page[0 .. 27 + vals], header[0 .. 27 + vals]);
        @memcpy(page[27 + vals ..], body);

        // advance
        std.mem.copyForwards(i32, self.lacing.items, self.lacing.items[vals..]);
        self.lacing.shrinkRetainingCapacity(self.lacing.items.len - vals);
        std.mem.copyForwards(i64, self.granule_values.items, self.granule_values.items[vals..]);
        self.granule_values.shrinkRetainingCapacity(self.granule_values.items.len - vals);
        self.body_returned += bytes;
        return page;
    }
};

fn buildInfoPacket(channels: u8, frequency: u32) [30]u8 {
    var p: [30]u8 = undefined;
    p[0] = 1; // packet type: identification
    @memcpy(p[1..7], "vorbis");
    std.mem.writeInt(u32, p[7..11], 0, .little); // version
    p[11] = channels;
    std.mem.writeInt(u32, p[12..16], frequency, .little);
    std.mem.writeInt(u32, p[16..20], 0, .little); // max bitrate
    std.mem.writeInt(u32, p[20..24], 0, .little); // nominal
    std.mem.writeInt(u32, p[24..28], 0, .little); // min
    p[28] = 0b1011_1000; // short 256 / long 2048
    p[29] = 1; // framing
    return p;
}

fn buildCommentPacket() [38]u8 {
    // Vendor string mirrors Fmod5Sharp's, so the rebuilt stream is
    // byte-identical to its output (and documents the reconstruction).
    const vendor = "Fmod5Sharp (Samboy063)";
    var p: [38]u8 = undefined;
    p[0] = 3; // packet type: comment
    @memcpy(p[1..7], "vorbis");
    std.mem.writeInt(u32, p[7..11], vendor.len, .little);
    @memcpy(p[11 .. 11 + vendor.len], vendor);
    const off: usize = 11 + vendor.len;
    std.mem.writeInt(u32, p[off..][0..4], 0, .little); // 0 comments
    p[off + 4] = 1; // framing
    return p;
}

/// Rebuilds a playable Ogg stream from an FSB5 Vorbis bank. Returns null
/// when the bank's setup CRC is not in the known-headers table.
pub fn rebuildOgg(
    allocator: std.mem.Allocator,
    raw: []const u8,
    data_start: u32,
    sample: fsb5.Sample,
) Error!?[]u8 {
    const crc = sample.vorbis_crc orelse return null;
    const setup = setupFor(crc) orelse return null;
    const flags = (try BlockFlags.parse(allocator, setup.header, setup.seek_bit)) orelse return error.Corrupt;
    defer allocator.free(flags.flags);

    const start: usize = @intCast(data_start + sample.data_offset);
    if (start > raw.len) return error.Corrupt;
    const data = raw[start..];

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var stream = OggStream.init(allocator, 1);
    defer stream.deinit(allocator);

    // header packets: BOS page (info) then comment + setup
    try stream.packetIn(allocator, &buildInfoPacket(@intCast(sample.channels), sample.frequency), 0, false);
    if (try stream.pageOut(allocator, true)) |p| try out.appendSlice(allocator, p);
    try stream.packetIn(allocator, &buildCommentPacket(), 0, false);
    try stream.packetIn(allocator, setup.header, 0, false);
    if (try stream.pageOut(allocator, true)) |p| try out.appendSlice(allocator, p);

    // audio packets: [u16 size][packet] until size 0/0xFFFF, the sample's
    // declared sample_count is reached, or the data ends. FMOD does not
    // always write an EOS marker for the last samples of a bank - their
    // data region runs to the end of the (possibly padded) data section,
    // so trailing bytes would otherwise be read as packet sizes and
    // corrupt the stream. The granule accounting mirrors the emit loop
    // below; reaching sample_count is the normal end of the sample.
    var packets = std.ArrayList([]const u8).empty;
    defer packets.deinit(allocator);
    var pos: usize = 0;
    var collect_granule: i64 = 0;
    var collect_prev_block: u32 = 0;
    while (pos + 2 <= data.len) {
        const size: usize = std.mem.readInt(u16, data[pos..][0..2], .little);
        if (size == 0 or size == 0xFFFF) break; // EOS marker
        pos += 2;
        if (pos + size > data.len) return error.Corrupt;
        const packet = data[pos .. pos + size];
        pos += size;
        try packets.append(allocator, packet);

        const block_size = flags.blockSize(packet);
        if (collect_prev_block == 0) {
            collect_granule = 0;
        } else {
            collect_granule += @divTrunc(@as(i64, block_size) + collect_prev_block, 4);
        }
        if (collect_granule > sample.sample_count) collect_granule = sample.sample_count;
        if (collect_granule == sample.sample_count) break;
        collect_prev_block = block_size;
    }

    var granule_pos: i64 = 0;
    var previous_block_size: u32 = 0;
    for (packets.items, 0..) |packet, i| {
        const is_last = i + 1 == packets.items.len;
        const block_size = flags.blockSize(packet);
        if (previous_block_size == 0) {
            granule_pos = 0;
        } else {
            granule_pos += @divTrunc(@as(i64, block_size) + previous_block_size, 4);
        }
        if (granule_pos > sample.sample_count) granule_pos = sample.sample_count;
        previous_block_size = block_size;

        try stream.packetIn(allocator, packet, granule_pos, is_last);
        if (try stream.pageOut(allocator, is_last)) |p| try out.appendSlice(allocator, p);
        if (granule_pos == sample.sample_count) break;
    }
    if (try stream.pageOut(allocator, true)) |p| try out.appendSlice(allocator, p);
    return try out.toOwnedSlice(allocator);
}

test "block flags parse a synthetic setup header" {
    const a = std.testing.allocator;
    // minimal setup packet: type 5, "vorbis", then a mode section at bit
    // 96 with 2 modes (flags 0 and 1), each followed by 40 skipped bits.
    var setup: [96 + 82]u8 = [_]u8{0} ** (96 + 82);
    setup[0] = 5;
    @memcpy(setup[1..7], "vorbis");
    const seek_bit: u32 = 96;
    // num_modes-1 = 1 at bits 96..101 (LSB-first)
    setup[seek_bit / 8] |= 1 << @intCast(seek_bit % 8);
    // mode 0 flag at bit 102 = 0 (already 0); mode 1 flag at bit 143 = 1
    const flag1_bit: usize = seek_bit + 6 + 1 + 40;
    setup[flag1_bit / 8] |= 1 << @intCast(flag1_bit % 8);

    const f = (try BlockFlags.parse(a, &setup, seek_bit)).?;
    defer a.free(f.flags);
    try std.testing.expectEqual(@as(usize, 2), f.flags.len);
    try std.testing.expect(!f.flags[0]);
    try std.testing.expect(f.flags[1]);
    // packet with LSB 0, mode bit 0 -> block size 256
    const p0 = [_]u8{ 0x00, 0xff, 0xff, 0xff };
    try std.testing.expectEqual(@as(u32, 256), f.blockSize(&p0));
    // packet with LSB 0, mode bit 1 -> block size 2048
    const p1 = [_]u8{ 0x02, 0xff, 0xff, 0xff };
    try std.testing.expectEqual(@as(u32, 2048), f.blockSize(&p1));
    // packet with LSB 1 -> flagged, size 0
    const p2 = [_]u8{ 0x01, 0xff, 0xff, 0xff };
    try std.testing.expectEqual(@as(u32, 0), f.blockSize(&p2));
}

test "ogg stream page framing" {
    const a = std.testing.allocator;
    var s = OggStream.init(a, 7);
    defer s.deinit(a);
    try s.packetIn(a, &buildInfoPacket(2, 44100), 0, false);
    const p0 = (try s.pageOut(a, true)).?; // BOS page with the info packet
    defer a.free(p0);
    try std.testing.expectEqualStrings("OggS", p0[0..4]);
    try std.testing.expectEqual(@as(u8, 0x02), p0[5]); // BOS
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, p0[14..18], .little));
    // recompute the CRC with the stored field zeroed: must match the stored value
    var check: [128]u8 = undefined;
    @memcpy(check[0..p0.len], p0);
    @memset(check[22..26], 0);
    var crc_reg: u32 = 0;
    for (check[0..p0.len]) |b| crc_reg = (crc_reg << 8) ^ ogg_crc_table[((crc_reg >> 24) & 0xff) ^ b];
    try std.testing.expectEqual(std.mem.readInt(u32, p0[22..26], .little), crc_reg);
    // more packets, then a forced page
    const d1 = [_]u8{ 1, 2, 3 };
    const d2 = [_]u8{ 4, 5, 6, 7, 8 };
    try s.packetIn(a, &d1, 100, false);
    try s.packetIn(a, &d2, 200, true);
    const p1 = (try s.pageOut(a, true)).?;
    defer a.free(p1);
    try std.testing.expectEqual(@as(u8, 0x04), p1[5]); // EOS
    try std.testing.expectEqual(@as(i64, 200), std.mem.readInt(i64, p1[6..14], .little));
}
