//! Container detection: identify the top-level Unity file format from its
//! leading bytes.
//!
//! Unity ships assets in a handful of container formats, each with its own
//! framing:
//!
//! - **WebFile** — web-player bundles, magic `UnityWebData1.0\0`.
//! - **UnityFS bundle** — the modern bundle, magic `UnityFS\0`.
//! - **Legacy bundles** — magic `UnityWeb\0` (web) or `UnityRaw\0`
//!   (standalone), used by Unity 2.x–4.x era.
//! - **ArchiveFile** — magic `UnityArchive\0`, rare.
//! - **SerializedFile** — `.assets`/`.resources`/`level*`/...
//!   no magic; the file starts with a u32 metadata size followed by the
//!   format version. Detection is a bounded heuristic, not a signature.
//!
//! Bundles contain serialized files; serialized files contain objects.
//! `sniff` only says which frame we are in — parsing is the job of the
//! per-format modules.

const std = @import("std");
const streams = @import("streams.zig");

pub const ContainerType = enum {
    /// Modern or legacy asset bundle (`UnityFS`/`UnityWeb`/`UnityRaw`).
    bundle,
    /// Web-player bundle (`UnityWebData1.0`).
    webfile,
    /// Rare `UnityArchive` container.
    archive,
    /// SerializedFile (`.assets` and friends), no magic.
    serialized,
    /// Nothing we recognize.
    unknown,
};

pub const BundleVariant = enum { none, fs, web, raw };

pub const SniffResult = struct {
    container: ContainerType = .unknown,
    bundle_variant: BundleVariant = .none,
    /// For serialized files: the format version read from the header.
    serialized_version: ?u32 = null,

    pub fn isBundle(self: SniffResult) bool {
        return self.container == .bundle;
    }
};

pub const webfile_magic = "UnityWebData1.0\x00";
pub const unityfs_magic = "UnityFS\x00";
pub const unityweb_magic = "UnityWeb\x00";
pub const unityraw_magic = "UnityRaw\x00";
pub const archive_magic = "UnityArchive\x00";

/// Sanity bound for a serialized-file metadata size: must leave room for
/// the rest of the file and stay far below any real-world metadata block.
const max_metadata_size: u32 = 64 * 1024 * 1024;

/// Identifies the container framing of `data` from its leading bytes.
///
/// A recognized container is not always a parseable one: a
/// `serialized_version` outside `serialized.supportedVersion` is never
/// reported (such files come back `.unknown`). Callers must still handle
/// the per-format parser's errors.
///
/// Gzip magic is reported as `.webfile`, since `webfile.parse` is the
/// only entry point that decompresses; the plaintext inside is
/// re-validated there.
///
/// Serialized files of every supported version (2-22, including the
/// legacy version 4 with its trailing-metadata layout) sniff as
/// `.serialized`, so bare v4 files are reachable from the CLI.
pub fn sniff(data: []const u8) SniffResult {
    if (std.mem.startsWith(u8, data, webfile_magic)) {
        return .{ .container = .webfile };
    }
    // gzip-wrapped webfiles start with gzip magic; route them to the
    // webfile parser, which decompresses and re-validates the signature
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) {
        return .{ .container = .webfile };
    }
    if (std.mem.startsWith(u8, data, unityfs_magic)) {
        return .{ .container = .bundle, .bundle_variant = .fs };
    }
    if (std.mem.startsWith(u8, data, unityweb_magic)) {
        return .{ .container = .bundle, .bundle_variant = .web };
    }
    if (std.mem.startsWith(u8, data, unityraw_magic)) {
        return .{ .container = .bundle, .bundle_variant = .raw };
    }
    if (std.mem.startsWith(u8, data, archive_magic)) {
        return .{ .container = .archive };
    }

    // SerializedFile: parse the fixed header (always big endian) and check
    // the fields are plausible. In v22 the 64-bit extension carries the
    // real metadata size; the base-header values are placeholders there.
    if (data.len >= 16) {
        const meta0 = std.mem.readInt(u32, data[0..4], .big);
        const file_size = std.mem.readInt(u32, data[4..8], .big);
        const version = std.mem.readInt(u32, data[8..12], .big);

        // All supported serialized versions, including 4: the parser reads
        // 2-22, and version 4 uses the same 16-byte legacy header as 2/3.
        if (version >= 2 and version <= 22) {
            var meta_size = meta0;
            const header_size: usize = if (version <= 8)
                16
            else if (version <= 21)
                20
            else
                48;

            if (version >= 22) {
                // real metadata size is re-read at offset 20 (big endian)
                if (data.len < 24) return .{ .container = .unknown };
                meta_size = std.mem.readInt(u32, data[20..24], .big);
            } else if (version <= 8) {
                // legacy: the endianness byte opens the trailing metadata
                if (meta_size == 0 or meta_size > file_size) return .{ .container = .unknown };
            }

            if (meta_size > 0 and
                meta_size <= max_metadata_size and
                meta_size + header_size <= data.len)
            {
                return .{ .container = .serialized, .serialized_version = version };
            }
        }
    }

    return .{ .container = .unknown };
}

/// Returns true when `data` is a serialized file with a version-newer
/// header that requires a type tree (version >= 13, per the format docs;
/// older files have no type tree).
pub fn serializedHasTypeTree(version: u32) bool {
    return version >= 13;
}

test "sniff webfile magic" {
    const data = webfile_magic ++ "rest";
    try std.testing.expectEqual(ContainerType.webfile, sniff(data).container);
}

test "sniff unityfs bundle" {
    const data = unityfs_magic ++ "\x06\x00\x00\x00";
    const r = sniff(data);
    try std.testing.expectEqual(ContainerType.bundle, r.container);
    try std.testing.expectEqual(BundleVariant.fs, r.bundle_variant);
    try std.testing.expect(r.isBundle());
}

test "sniff legacy bundles" {
    const web = sniff(unityweb_magic);
    try std.testing.expectEqual(ContainerType.bundle, web.container);
    try std.testing.expectEqual(BundleVariant.web, web.bundle_variant);

    const raw = sniff(unityraw_magic);
    try std.testing.expectEqual(ContainerType.bundle, raw.container);
    try std.testing.expectEqual(BundleVariant.raw, raw.bundle_variant);
}

test "sniff archive" {
    try std.testing.expectEqual(ContainerType.archive, sniff(archive_magic).container);
}

test "sniff serialized file by header heuristic" {
    // Standard20 (v19): metadata_size = 100, version = 19, big endian.
    var buf: [120]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 100, .big);
    std.mem.writeInt(u32, buf[4..8], 100 + 20, .big); // file_size
    std.mem.writeInt(u32, buf[8..12], 19, .big);
    const r = sniff(&buf);
    try std.testing.expectEqual(ContainerType.serialized, r.container);
    try std.testing.expectEqual(@as(u32, 19), r.serialized_version.?);
}

test "sniff v22 serialized file via the 64-bit extension" {
    // v22: base header fields are placeholders; the real metadata size is
    // re-read at offset 20.
    var buf: [100]u8 = undefined;
    std.mem.writeInt(u32, buf[8..12], 22, .big); // version
    std.mem.writeInt(u32, buf[20..24], 40, .big); // extension metadata_size
    const r = sniff(&buf);
    try std.testing.expectEqual(ContainerType.serialized, r.container);
    try std.testing.expectEqual(@as(u32, 22), r.serialized_version.?);
}

test "sniff rejects implausible serialized headers" {
    // metadata size larger than the file
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 100, .big);
    std.mem.writeInt(u32, buf[4..8], 19, .big);
    try std.testing.expectEqual(ContainerType.unknown, sniff(&buf).container);

    // absurd version
    var buf2: [16]u8 = undefined;
    std.mem.writeInt(u32, buf2[0..4], 8, .big);
    std.mem.writeInt(u32, buf2[4..8], 0xffffffff, .big);
    try std.testing.expectEqual(ContainerType.unknown, sniff(&buf2).container);

    // zero metadata size
    var buf3: [16]u8 = undefined;
    std.mem.writeInt(u32, buf3[0..4], 0, .big);
    std.mem.writeInt(u32, buf3[4..8], 19, .big);
    try std.testing.expectEqual(ContainerType.unknown, sniff(&buf3).container);

    // legacy version 4 sniffs as serialized like every supported version
    var buf4: [40]u8 = undefined;
    std.mem.writeInt(u32, buf4[0..4], 8, .big);
    std.mem.writeInt(u32, buf4[4..8], 28, .big);
    std.mem.writeInt(u32, buf4[8..12], 4, .big);
    const r4 = sniff(&buf4);
    try std.testing.expectEqual(ContainerType.serialized, r4.container);
    try std.testing.expectEqual(@as(?u32, 4), r4.serialized_version);

    // ...but an implausible v4 header is still rejected
    var buf5: [40]u8 = undefined;
    std.mem.writeInt(u32, buf5[0..4], 8, .big); // metadata larger than the file
    std.mem.writeInt(u32, buf5[4..8], 4, .big);
    std.mem.writeInt(u32, buf5[8..12], 4, .big);
    try std.testing.expectEqual(ContainerType.unknown, sniff(&buf5).container);
}

test "sniff empty and garbage" {
    try std.testing.expectEqual(ContainerType.unknown, sniff("").container);
    try std.testing.expectEqual(ContainerType.unknown, sniff("not unity data").container);
}

test "serializedHasTypeTree threshold" {
    try std.testing.expect(!serializedHasTypeTree(12));
    try std.testing.expect(serializedHasTypeTree(13));
    try std.testing.expect(serializedHasTypeTree(22));
}

test "sniff result defaults" {
    const r = sniff("");
    try std.testing.expectEqual(ContainerType.unknown, r.container);
    try std.testing.expectEqual(BundleVariant.none, r.bundle_variant);
    try std.testing.expectEqual(@as(?u32, null), r.serialized_version);
}
