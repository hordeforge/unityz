//! unityz — a Zig library for reading, extracting, and editing Unity assets.
//!
//! Status: read and write paths are both functional for the modern
//! formats. WebFiles, UnityFS bundles (LZ4/LZMA blocks), and
//! SerializedFiles (formats 2-22) parse; objects decode through
//! their type trees into a JSON-serializable value model and serialize back;
//! Texture2D/TextAsset objects extract to PNG/files (RGB/RGBA, DXT1/3/5,
//! BC4/5, BC7, ETC1/ETC2/ETC2-RGBA8, and the crunch variants
//! ETC_RGB4Crunched/ETC2_RGBA8Crunched/DXT1Crunched/DXT5Crunched, ASTC
//! incl. HDR; packed sprites merge their separate alpha texture and render
//! tight/polygon meshes); MonoBehaviours resolve their
//! MonoScript identity and export the raw serialized script payload;
//! managed-reference registries decode through their type trees. Shader
//! (class 48) sub-program blobs decode: per-record parameter blobs (constant
//! buffers + texture/cbuffer/UAV/sampler entries) and code blobs (38-byte
//! program-data header, DXBC chunk analysis incl. ISGN/RDEF, ParserBindChannels),
//! surfaced via `show`/`shader` and round-trip checked by `verify`. Objects
//! can be edited in place across all supported serialized formats
//! (2-22).

const std = @import("std");

/// unityz version, kept in sync with `build.zig.zon`.
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

/// Endian-aware binary reader/writer primitives.
pub const streams = @import("streams.zig");

/// Top-level container detection (bundle vs webfile vs serialized, ...).
pub const container = @import("container.zig");

/// WebFile container (`UnityWebData1.0`) parser.
pub const webfile = @import("webfile.zig");

/// UnityFS bundle parser.
pub const bundle = @import("bundle.zig");

/// LZ4 block decompression, as used by UnityFS bundle blocks.
pub const lz4 = @import("lz4.zig");

/// TypeTree parsing (class layout metadata).
pub const typetree = @import("typetree.zig");

/// SerializedFile parser (`.assets` and friends).
pub const serialized = @import("serialized.zig");

/// Generic object value model + JSON output.
pub const value = @import("value.zig");

/// TypeTree-driven object reader.
pub const object_reader = @import("object_reader.zig");

/// Typed views over the value tree for the common classes.
pub const classes = @import("classes.zig");

/// Shader (class 48) sub-program blob parsing and skinning detection.
pub const shader = @import("shader.zig");

/// Texture format decoding to RGBA8.
pub const texture = @import("texture.zig");

/// Minimal PNG encoder.
pub const png = @import("png.zig");

/// Minimal TGA encoder (uncompressed 32bpp, top-left origin).
pub const tga = @import("tga.zig");

/// Minimal BMP encoder (32bpp BI_RGB, top-down).
pub const bmp = @import("bmp.zig");

/// FSB5 audio bank metadata parser (sample rate, channels, loop points).
pub const fsb5 = @import("fsb5.zig");

/// FSB5 audio sample decoding to 16-bit PCM (PCM8/16/24/32/FLOAT, IMA
/// ADPCM) - no external tools needed.
pub const audio = @import("audio.zig");

/// FSB5 Vorbis (mode 15) to playable Ogg reconstruction - headers
/// synthesized, setup header from the crc-keyed table, no external tools.
pub const vorbis = @import("vorbis.zig");

/// TypeTree-driven object serializer (inverse of the reader).
pub const object_writer = @import("object_writer.zig");

/// SerializedFile rewrite (edited objects written back).
pub const serialized_writer = @import("serialized_writer.zig");
pub const dotnet = @import("dotnet.zig");

/// File extensions of Unity asset files this project intends to support.
/// Note that some serialized files (e.g. `globalgamemanagers`, `level0`)
/// carry no extension at all; extension-based detection is a first
/// heuristic, not the whole story.
pub const asset_extensions = [_][]const u8{
    ".assets",
    ".bundle",
    ".unity3d",
    ".resources",
    ".resS",
};

/// Returns true when `name` ends in a known Unity asset extension.
pub fn isAssetFileName(name: []const u8) bool {
    for (asset_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

test "isAssetFileName recognizes known extensions" {
    try std.testing.expect(isAssetFileName("sharedassets0.assets"));
    try std.testing.expect(isAssetFileName("level0.unity3d"));
    try std.testing.expect(isAssetFileName("textures.resS"));
    try std.testing.expect(!isAssetFileName("level0.txt"));
    try std.testing.expect(!isAssetFileName("sharedassets0.assets.bak"));
    try std.testing.expect(!isAssetFileName(""));
}
