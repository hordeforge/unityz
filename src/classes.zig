//! Typed views over the generic value tree for the common Unity classes.
//!
//! UnityPy exposes a typed class per Unity class ID; here we provide the
//! subset needed by extraction and editing, as accessors over
//! [`value.Value`]. Fields are read by name, so files with stripped or
//! renamed fields degrade to defaults instead of failing.

const std = @import("std");
const value = @import("value.zig");

/// Finds a named field in a `.obj` value, or null.
pub fn fieldOf(v: value.Value, name: []const u8) ?value.Value {
    return switch (v) {
        .obj => |fields| blk: {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk f.value;
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn intField(v: value.Value, name: []const u8) ?i64 {
    const f = fieldOf(v, name) orelse return null;
    return f.asInt();
}

pub fn boolField(v: value.Value, name: []const u8) ?bool {
    return switch (fieldOf(v, name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn stringField(v: value.Value, name: []const u8) ?[]const u8 {
    return switch (fieldOf(v, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn floatField(v: value.Value, name: []const u8) ?f64 {
    return switch (fieldOf(v, name) orelse return null) {
        .float => |f| f,
        else => null,
    };
}

pub fn bytesField(v: value.Value, name: []const u8) ?[]const u8 {
    return switch (fieldOf(v, name) orelse return null) {
        .bytes => |b| b,
        else => null,
    };
}

pub fn pptrField(v: value.Value, name: []const u8) ?value.PPtr {
    return switch (fieldOf(v, name) orelse return null) {
        .pptr => |p| p,
        .obj => |fields| blk: {
            // PPtrs with extra fields were read as objects.
            const file = intField(.{ .obj = fields }, "m_FileID") orelse break :blk null;
            const path = intField(.{ .obj = fields }, "m_PathID") orelse break :blk null;
            break :blk .{ .file_id = @intCast(file), .path_id = path };
        },
        else => null,
    };
}

/// A `Vector3f`/`Quaternionf`-style struct of floats.
pub fn vec3Field(v: value.Value, name: []const u8) ?[3]f32 {
    const f = fieldOf(v, name) orelse return null;
    var out: [3]f32 = .{ 0, 0, 0 };
    const comps = [_][]const u8{ "x", "y", "z" };
    for (0..3) |i| {
        const comp = comps[i];
        const c = fieldOf(f, comp) orelse continue;
        if (c != .float) return null;
        out[i] = @floatCast(c.float);
    }
    return out;
}

/// Reference to a streamed byte range, `StreamingInfo` in the tree:
/// `offset` (u32), `size` (u32), `path` (string).
pub const StreamingInfo = struct {
    offset: u32 = 0,
    size: u32 = 0,
    path: []const u8 = "",

    pub fn fromValue(v: value.Value) StreamingInfo {
        const f = fieldOf(v, "m_StreamData") orelse return .{};
        return .{
            .offset = @intCast(intField(f, "offset") orelse intField(f, "m_Offset") orelse 0),
            .size = @intCast(intField(f, "size") orelse intField(f, "m_Size") orelse 0),
            .path = stringField(f, "path") orelse stringField(f, "m_Path") orelse "",
        };
    }
};

pub const Texture2D = struct {
    width: u32 = 0,
    height: u32 = 0,
    format: i32 = 0,
    mip_count: u32 = 0,
    image_count: u32 = 0,
    complete_image_size: u32 = 0,
    is_readable: bool = false,
    /// Embedded pixel data (`m_ImageData`).
    image_data: []const u8 = &.{},
    /// Streamed pixel data range (`m_StreamData`); when `path` is empty the
    /// data lives in this serialized file at `data_offset + offset`.
    stream: StreamingInfo = .{},

    pub fn fromValue(v: value.Value) Texture2D {
        return .{
            .width = @intCast(intField(v, "m_Width") orelse 0),
            .height = @intCast(intField(v, "m_Height") orelse 0),
            .format = @intCast(intField(v, "m_TextureFormat") orelse 0),
            .mip_count = @intCast(intField(v, "m_MipCount") orelse 1),
            .image_count = @intCast(intField(v, "m_ImageCount") orelse 1),
            .complete_image_size = @intCast(intField(v, "m_CompleteImageSize") orelse 0),
            .is_readable = boolField(v, "m_IsReadable") orelse false,
            // The pixel payload is named "image data" in modern type trees
            // (2021.2+) and "m_ImageData" in older ones; accept both.
            .image_data = bytesField(v, "image data") orelse bytesField(v, "m_ImageData") orelse &.{},
            .stream = StreamingInfo.fromValue(v),
        };
    }
};

pub const TextAsset = struct {
    name: []const u8 = "",
    script: []const u8 = &.{},

    pub fn fromValue(v: value.Value) TextAsset {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .script = bytesField(v, "m_Script") orelse &.{},
        };
    }
};

/// Unity AudioClip: metadata plus streamed audio data. When
/// `resource.path` is set the bytes live in a sibling `.resS`/`.resource`
/// sidecar (often an FSB5 bank); otherwise `audio_data` holds them.
pub const AudioClip = struct {
    name: []const u8 = "",
    channels: u32 = 0,
    frequency: u32 = 0,
    bits_per_sample: u32 = 0,
    compression_format: i32 = 0,
    audio_data: []const u8 = &.{},
    /// Streamed data range (`m_Resource`): `path` is the sidecar source,
    /// `offset`/`size` the clip's slice within it.
    resource: StreamingInfo = .{},

    pub fn fromValue(v: value.Value) AudioClip {
        const f = fieldOf(v, "m_Resource") orelse return .{};
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .channels = @intCast(intField(v, "m_Channels") orelse 0),
            .frequency = @intCast(intField(v, "m_Frequency") orelse 0),
            .bits_per_sample = @intCast(intField(v, "m_BitsPerSample") orelse 0),
            .compression_format = @intCast(intField(v, "m_CompressionFormat") orelse 0),
            .audio_data = bytesField(v, "m_AudioData") orelse &.{},
            .resource = .{
                .offset = @intCast(intField(f, "m_Offset") orelse 0),
                .size = @intCast(intField(f, "m_Size") orelse 0),
                .path = stringField(f, "m_Source") orelse "",
            },
        };
    }
};

pub const GameObject = struct {
    name: []const u8 = "",
    layer: i64 = 0,
    is_active: bool = true,
    tag: []const u8 = "",
    /// PPtrs to Component objects.
    components: []const value.PPtr = &.{},

    pub fn fromValue(v: value.Value) GameObject {
        var self = GameObject{
            .name = stringField(v, "m_Name") orelse "",
            .layer = intField(v, "m_Layer") orelse 0,
            .is_active = boolField(v, "m_IsActive") orelse true,
            .tag = stringField(v, "m_TagString") orelse "",
        };
        const comps = fieldOf(v, "m_Components") orelse return self;
        const arr = switch (comps) {
            .array => |a| a,
            else => return self,
        };
        var list: std.ArrayList(value.PPtr) = .empty;
        for (arr) |item| {
            if (pptrField(.{ .obj = &.{.{ .name = "x", .value = item } } }, "x")) |p| {
                list.append(std.heap.page_allocator, p) catch {};
            }
        }
        self.components = list.toOwnedSlice(std.heap.page_allocator) catch &.{};
        return self;
    }
};

pub const Transform = struct {
    local_position: [3]f32 = .{ 0, 0, 0 },
    local_rotation: [4]f32 = .{ 0, 0, 0, 1 },
    local_scale: [3]f32 = .{ 1, 1, 1 },
    game_object: ?value.PPtr = null,
    father: ?value.PPtr = null,

    pub fn fromValue(v: value.Value) Transform {
        var self = Transform{};
        if (vec3Field(v, "m_LocalPosition")) |p| self.local_position = p;
        if (vec3Field(v, "m_LocalScale")) |s| self.local_scale = s;
        if (fieldOf(v, "m_LocalRotation")) |q| {
            if (q == .obj) {
                const comps = [_][]const u8{ "x", "y", "z", "w" };
                for (comps, 0..) |c, i| {
                    if (fieldOf(q, c)) |f| {
                        if (f == .float) self.local_rotation[i] = @floatCast(f.float);
                    }
                }
            }
        }
        self.game_object = pptrField(v, "m_GameObject");
        self.father = pptrField(v, "m_Father");
        return self;
    }
};

pub const Sprite = struct {
    name: []const u8 = "",
    texture: ?value.PPtr = null,
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    pixels_to_units: f32 = 100,
    width: u32 = 0,
    height: u32 = 0,

    /// Fills `out[4]` with x/y/width/height from a Rectf-shaped value.
    fn readRect(r: value.Value, out: *[4]f32) void {
        if (r != .obj) return;
        const comps = [_][]const u8{ "x", "y", "width", "height" };
        for (comps, 0..) |c, i| {
            if (fieldOf(r, c)) |f| {
                if (f == .float) out[i] = @floatCast(f.float);
            }
        }
    }

    pub fn fromValue(v: value.Value) Sprite {
        const ptu: f32 = blk: {
            const f = fieldOf(v, "m_PixelsToUnits") orelse break :blk 100;
            break :blk @floatCast(f.asFloat() orelse 100);
        };
        var self = Sprite{
            .name = stringField(v, "m_Name") orelse "",
            .texture = pptrField(v, "m_Texture"),
            .pixels_to_units = ptu,
        };
        if (intField(v, "m_Width")) |w| self.width = @intCast(w);
        if (intField(v, "m_Height")) |h| self.height = @intCast(h);
        if (fieldOf(v, "m_Rect")) |r| readRect(r, &self.rect);
        // Modern sprites carry the render data in m_RD (texture + rect);
        // it takes precedence over the legacy top-level fields.
        if (fieldOf(v, "m_RD")) |rd| {
            if (pptrField(rd, "texture")) |t| self.texture = t;
            if (fieldOf(rd, "textureRect")) |r| readRect(r, &self.rect);
        }
        return self;
    }

    /// Crops the sprite's rect out of a decoded RGBA texture and flips it
    /// vertically, matching UnityPy's sprite export (the rect's y is
    /// measured from the texture's top; Unity displays it bottom-up).
    /// Returns RGBA8 pixels of size `width x height`.
    pub fn spriteRgba(
        self: *const Sprite,
        allocator: std.mem.Allocator,
        tex_rgba: []const u8,
        tex_w: u32,
        tex_h: u32,
    ) ![]u8 {
        return spriteRgbaRect(allocator, self.rect, tex_rgba, tex_w, tex_h);
    }

    /// Crops an arbitrary rect (e.g. the atlas's copy for packed sprites)
    /// out of a decoded RGBA texture. Rounds the box the way Pillow's
    /// Image.crop does - floor on x/y, ceil on x+w/y+h - so sprite sizes
    /// match UnityPy byte-for-byte, and clamps to the texture bounds.
    pub fn spriteRgbaRect(
        allocator: std.mem.Allocator,
        rect: [4]f32,
        tex_rgba: []const u8,
        tex_w: u32,
        tex_h: u32,
    ) ![]u8 {
        const tw: usize = tex_w;
        const th: usize = tex_h;
        const rx_f = @floor(rect[0]);
        const ry_f = @floor(rect[1]);
        const r1_f = @ceil(rect[0] + rect[2]);
        const r2_f = @ceil(rect[1] + rect[3]);
        if (rx_f < 0 or ry_f < 0 or r1_f <= rx_f or r2_f <= ry_f) return error.RectOutsideTexture;
        const rx: usize = @intFromFloat(rx_f);
        const ry: usize = @intFromFloat(ry_f);
        var rw: usize = @as(usize, @intFromFloat(r1_f)) - rx;
        var rh: usize = @as(usize, @intFromFloat(r2_f)) - ry;
        if (rx >= tw or ry >= th) return error.RectOutsideTexture;
        rw = @min(rw, tw - rx); // PIL clamps to the image bounds
        rh = @min(rh, th - ry);
        if (tex_rgba.len < tw * th * 4) return error.SizeMismatch;

        const out = try allocator.alloc(u8, rw * rh * 4);
        for (0..rh) |row| {
            // UnityPy crops top-origin then flips the result vertically, so
            // output row r is texture row (ry + rh - 1 - r).
            const src_row = ry + rh - 1 - row;
            const src = tex_rgba[(src_row * tw + rx) * 4 ..][0 .. rw * 4];
            @memcpy(out[row * rw * 4 ..][0 .. rw * 4], src);
        }
        return out;
    }
};

pub const Material = struct {
    name: []const u8 = "",
    shader: ?value.PPtr = null,

    pub fn fromValue(v: value.Value) Material {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .shader = pptrField(v, "m_Shader"),
        };
    }
};

pub const MonoBehaviour = struct {
    name: []const u8 = "",
    enabled: bool = true,
    script: ?value.PPtr = null,
    game_object: ?value.PPtr = null,
    /// Raw serialized script payload (the managed object graph) after the
    /// type-tree-described fields; exposed as bytes, not yet parsed.
    script_data: []const u8 = &.{},
    /// Resolved MonoScript identity when the caller supplies it.
    script_name: []const u8 = "",
    script_namespace: []const u8 = "",
    script_assembly: []const u8 = "",

    pub fn fromValue(v: value.Value) MonoBehaviour {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .enabled = boolField(v, "m_Enabled") orelse true,
            .script = pptrField(v, "m_Script"),
            .game_object = pptrField(v, "m_GameObject"),
        };
    }
};

/// MonoScript identity fields (class 115).
pub const MonoScript = struct {
    name: []const u8 = "",
    class_name: []const u8 = "",
    namespace: []const u8 = "",
    assembly: []const u8 = "",

    pub fn fromValue(v: value.Value) MonoScript {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .class_name = stringField(v, "m_ClassName") orelse "",
            .namespace = stringField(v, "m_Namespace") orelse "",
            .assembly = stringField(v, "m_AssemblyName") orelse "",
        };
    }

    /// Best available script name (`Namespace` when set, else the class
    /// name), with the trailing NUL Unity's string fields carry trimmed.
    pub fn fullName(self: MonoScript) []const u8 {
        const ns = std.mem.trimEnd(u8, self.namespace, "\x00");
        const cn = std.mem.trimEnd(u8, self.class_name, "\x00");
        return if (ns.len != 0) ns else cn;
    }
};

pub const AssetBundle = struct {
    name: []const u8 = "",

    pub fn fromValue(v: value.Value) AssetBundle {
        return .{ .name = stringField(v, "m_Name") orelse "" };
    }
};

/// One vertex channel layout entry (`Mesh.m_VertexData.m_Channels`).
pub const MeshChannel = struct {
    stream: u32 = 0,
    offset: u32 = 0,
    format: i32 = 0,
    dimension: u32 = 0,
};

/// Typed view over a Mesh object's serialized form.
///
/// The geometry lives in two opaque byte buffers decoded by `m_Channels`:
/// `vertex_data` holds `vertex_count` interleaved vertices (each channel at
/// `offset` with `format`/`dimension` components), and `index_buffer` holds
/// `m_IndexFormat`-sized indices. Channel formats follow Unity's
/// `VertexChannelFormat` enum (0 = Float32 ... 10 = UInt32Normalized).
pub const Mesh = struct {
    name: []const u8 = "",
    vertex_count: u32 = 0,
    index_format: i32 = 0,
    vertex_data: []const u8 = "",
    index_buffer: []const u8 = "",
    /// Fixed-size channel table (Unity writes at most 14); `channel_count`
    /// is the populated length.
    channels: [14]MeshChannel = [_]MeshChannel{.{}} ** 14,
    channel_count: usize = 0,

    pub fn channelSlice(self: *const Mesh) []const MeshChannel {
        return self.channels[0..self.channel_count];
    }

    /// The channel's layout, or null when absent (dimension 0) or when the
    /// data is not all in stream 0 (multi-stream layouts are rare and
    /// unsupported for export).
    pub fn channel(self: *const Mesh, index: usize) ?MeshChannel {
        if (index >= self.channel_count) return null;
        const c = self.channels[index];
        if (c.dimension == 0 or c.stream != 0) return null;
        return c;
    }

    /// Size in bytes of one component for a `VertexChannelFormat` value.
    pub fn formatSize(format: i32) ?usize {
        return switch (format) {
            0, 2, 4, 5, 10, 11 => 4,
            1, 6, 7, 9 => 2,
            3, 8 => 1,
            else => null,
        };
    }

    /// The interleaved vertex stride: the furthest byte any channel
    /// occupies, rounded up to 4.
    pub fn stride(self: *const Mesh) ?usize {
        var max_end: usize = 0;
        for (self.channelSlice()) |c| {
            if (c.dimension == 0) continue;
            if (c.stream != 0) return null;
            const fs = formatSize(c.format) orelse return null;
            max_end = @max(max_end, c.offset + fs * c.dimension);
        }
        return (max_end + 3) / 4 * 4;
    }

    pub fn fromValue(v: value.Value) Mesh {
        var m = Mesh{ .name = stringField(v, "m_Name") orelse "" };
        if (intField(v, "m_IndexFormat")) |f| m.index_format = @intCast(f);
        m.index_buffer = bytesField(v, "m_IndexBuffer") orelse "";

        const vd = fieldOf(v, "m_VertexData") orelse return m;
        if (intField(vd, "m_VertexCount")) |n| m.vertex_count = @intCast(n);
        m.vertex_data = bytesField(vd, "m_DataSize") orelse "";

        if (fieldOf(vd, "m_Channels")) |chans| {
            if (chans == .array) {
                const arr = chans.array;
                const n = @min(arr.len, m.channels.len);
                for (arr[0..n], 0..) |c, i| {
                    m.channels[i] = .{
                        .stream = @intCast(intField(c, "stream") orelse 0),
                        .offset = @intCast(intField(c, "offset") orelse 0),
                        .format = @intCast(intField(c, "format") orelse 0),
                        .dimension = @intCast(intField(c, "dimension") orelse 0),
                    };
                }
                m.channel_count = n;
            }
        }
        return m;
    }
};

test "monoscript full name trims the trailing nul" {
    const ms = MonoScript{
        .namespace = "MyGame\x00",
        .class_name = "TestClass\x00",
        .assembly = "Assembly-CSharp\x00",
    };
    try std.testing.expectEqualStrings("MyGame", ms.fullName());
    const ms2 = MonoScript{ .class_name = "Plain\x00" };
    try std.testing.expectEqualStrings("Plain", ms2.fullName());
    const ms3 = MonoScript{};
    try std.testing.expectEqualStrings("", ms3.fullName());
}

test "typed views extract fields from a generic value" {
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Width", .value = .{ .int = 64 } },
        .{ .name = "m_Height", .value = .{ .int = 32 } },
        .{ .name = "m_TextureFormat", .value = .{ .int = 20 } },
        .{ .name = "m_MipCount", .value = .{ .int = 1 } },
        .{ .name = "m_ImageData", .value = .{ .bytes = "PIXELS" } },
        .{ .name = "m_StreamData", .value = .{ .obj = &[_]value.Field{
            .{ .name = "offset", .value = .{ .uint = 512 } },
            .{ .name = "size", .value = .{ .uint = 6 } },
            .{ .name = "path", .value = .{ .string = "tex.resS" } },
        } } },
    } };
    const t = Texture2D.fromValue(v);
    try std.testing.expectEqual(@as(u32, 64), t.width);
    try std.testing.expectEqual(@as(u32, 32), t.height);
    try std.testing.expectEqual(@as(i32, 20), t.format);
    try std.testing.expectEqualStrings("PIXELS", t.image_data);
    try std.testing.expectEqual(@as(u32, 512), t.stream.offset);
    try std.testing.expectEqualStrings("tex.resS", t.stream.path);

    const g = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Player" } },
        .{ .name = "m_IsActive", .value = .{ .bool = false } },
        .{ .name = "m_Components", .value = .{ .array = &[_]value.Value{
            .{ .pptr = .{ .file_id = 0, .path_id = 5 } },
            .{ .pptr = .{ .file_id = 0, .path_id = 9 } },
        } } },
    } };
    const go = GameObject.fromValue(g);
    try std.testing.expectEqualStrings("Player", go.name);
    try std.testing.expect(!go.is_active);
    try std.testing.expectEqual(@as(usize, 2), go.components.len);
    try std.testing.expectEqual(@as(i64, 9), go.components[1].path_id);
}

test "sprite crop flips vertically like UnityPy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 4x4 texture; pixel (x, y) = (x*64, y*64, 128, 255), row 0 first.
    const tex_w: u32 = 4;
    const tex_h: u32 = 4;
    const rgba = try a.alloc(u8, tex_w * tex_h * 4);
    for (0..4) |y| {
        for (0..4) |x| {
            const p = (y * 4 + x) * 4;
            rgba[p] = @intCast(x * 64);
            rgba[p + 1] = @intCast(y * 64);
            rgba[p + 2] = 128;
            rgba[p + 3] = 255;
        }
    }

    // sprite rect (1, 1, 2, 2) via the value tree, as a real parse yields
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "spr" } },
        .{ .name = "m_Rect", .value = .{ .obj = &[_]value.Field{
            .{ .name = "x", .value = .{ .float = 1 } },
            .{ .name = "y", .value = .{ .float = 1 } },
            .{ .name = "width", .value = .{ .float = 2 } },
            .{ .name = "height", .value = .{ .float = 2 } },
        } } },
        .{ .name = "m_PixelsToUnits", .value = .{ .float = 100 } },
    } };
    const sprite = Sprite.fromValue(v);
    const out = try sprite.spriteRgba(a, rgba, tex_w, tex_h);

    // UnityPy: crop top-origin (rows 1-2) then flip vertically, so
    // output row 0 = texture row 2, output row 1 = texture row 1.
    const expected = [_][4]u8{
        .{ 64, 128, 128, 255 }, // texture (1,2)
        .{ 128, 128, 128, 255 }, // texture (2,2)
        .{ 64, 64, 128, 255 }, // texture (1,1)
        .{ 128, 64, 128, 255 }, // texture (2,1)
    };
    try std.testing.expectEqual(@as(usize, 16), out.len);
    for (expected, 0..) |px, i| {
        try std.testing.expectEqualSlices(u8, &px, out[i * 4 ..][0..4]);
    }

    // a rect fully outside the texture is rejected
    const bad = Sprite{ .rect = .{ 4, 4, 2, 2 } };
    try std.testing.expectError(error.RectOutsideTexture, bad.spriteRgba(a, rgba, tex_w, tex_h));

    // a rect that overruns the edge clamps to the texture bounds, like
    // Pillow's crop: {3,3,4,4} on a 4x4 texture yields a 1x1 tile
    const clamped = Sprite{ .rect = .{ 3, 3, 4, 4 } };
    const out_clamped = try clamped.spriteRgba(a, rgba, tex_w, tex_h);
    try std.testing.expectEqual(@as(usize, 4), out_clamped.len);
    try std.testing.expectEqualSlices(u8, &.{ 192, 192, 128, 255 }, out_clamped);
}
