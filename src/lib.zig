//! unityz — a Zig library for reading, extracting, and editing Unity assets.
//!
//! Containers: WebFile, UnityFS and legacy UnityWeb/UnityRaw bundles (LZ4,
//! LZMA, LZHAM blocks), and SerializedFiles of formats 2-22 parse, rewrite
//! byte-exactly, and can be created from scratch (`bundle.create`,
//! `serialized_writer.create`). Objects decode through their type trees into
//! a JSON-serializable value model (`object_reader`, `value`) and serialize
//! back (`object_writer`); `classes` gives typed views over that model.
//! Trees come from the file itself, from a caller-supplied table, from the
//! built-in per-release database (`builtin_trees`), or from a Mono game's
//! assemblies (`dotnet`, `managed_trees`). Textures decode to RGBA8
//! (`texture`, with PNG/TGA/BMP encoders), FSB5 audio to PCM or Ogg
//! (`fsb5`, `audio`, `vorbis`), and Shader blobs to their record tables
//! (`shader`). Every parser allocates from the caller's allocator, prints
//! nothing, and returns errors instead of panicking; an arena is the
//! intended usage.

const std = @import("std");

/// unityz version, parsed from `build.zig.zon` at build time.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(@import("build_options").version) catch unreachable;

/// Endian-aware binary reader/writer primitives.
pub const streams = @import("streams.zig");

/// Top-level container detection (bundle vs webfile vs serialized, ...).
pub const container = @import("container.zig");

/// WebFile container (`UnityWebData1.0`) parser.
pub const webfile = @import("webfile.zig");

/// UnityFS bundle parser.
pub const bundle = @import("bundle.zig");

/// LZ4 block decompression and compression, as used by UnityFS bundle blocks.
pub const lz4 = @import("lz4.zig");

/// TypeTree parsing (class layout metadata).
pub const typetree = @import("typetree.zig");

/// Built-in engine-class type trees, indexed by exact Unity release.
pub const builtin_trees = @import("builtin_trees.zig");

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

/// .NET assembly metadata reader (MonoBehaviour script field layouts).
pub const dotnet = @import("dotnet.zig");

/// MonoBehaviour type trees built from those assemblies plus the game's
/// MonoScript objects (`managed --trees`), in the `--trees` JSON shape.
pub const managed_trees = @import("managed_trees.zig");

/// File extensions of Unity asset files this project intends to support.
/// Note that some serialized files (e.g. `globalgamemanagers`, `level0`)
/// carry no extension at all; extension-based detection is a first
/// heuristic, not the whole story.
pub const asset_extensions = [_][]const u8{
    ".assets",
    ".bundle",
    ".unity3d",
    ".resources",
    ".resource",
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
    try std.testing.expect(isAssetFileName("sharedassets0.resource"));
    try std.testing.expect(!isAssetFileName("level0.txt"));
    try std.testing.expect(!isAssetFileName("sharedassets0.assets.bak"));
    try std.testing.expect(!isAssetFileName(""));
}
