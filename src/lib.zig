//! unityz — a Zig library for reading, extracting, and editing Unity assets.
//!
//! Status: scaffolding. Unity's asset formats (SerializedFile `.assets`,
//! asset bundles, `.resources`) are not parsed yet; this module will grow
//! parsers for them milestone by milestone.

const std = @import("std");

/// unityz version, kept in sync with `build.zig.zon`.
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

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
