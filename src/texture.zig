//! Texture decoding: Unity `TextureFormat` → RGBA8.
//!
//! Implemented from the public format descriptions: the uncompressed
//! RGB/RGBA family (RGB24, RGBA32, ARGB32, BGRA32, BGR24, 16-bit R16/RG16,
//! half-float RHalf/RGHalf/RGBAHalf, float RFloat/RGFloat/RGBAFloat/
//! ARGBFloat/RG32, shared-exponent RGB9e5Float, 48/64-bit RGB48/RGBA64,
//! and the signed variants 75-82), the S3TC/DXT block formats (BC1/BC2/
//! BC3), BC4/BC5, BC7 (all eight modes plus the reserved mode), ETC1/ETC2
//! (including the T/H/planar alternate modes and EAC alpha), and ASTC
//! (4x4 through 12x12, including void-extent and error blocks). The
//! compressed paths were cross-validated byte-exact against UnityPy's
//! texture2ddecoder
//! (900/900 ETC blocks, 2160/2160 BC7 blocks, 600/600 ASTC blocks), so
//! output matches UnityPy pixel-for-pixel — including its wrap behavior
//! for out-of-range ETC differential sums and its transparent-black
//! reserved-BC7-mode output. Format numbers follow Unity's TextureFormat
//! enum. ASTC HDR (66-71) decodes through the shared-exponent endpoint
//! schemes (luminance, RGB, RGB-scale, RGBA, RGB+LDR-alpha) and is
//! validated against ARM's astcenc reference decoder rather than
//! UnityPy, whose decoder rejects HDR blocks; HDR values clamp to
//! [0,1] for the 8-bit output. The raw half/float/16-bit family uses
//! standard documented conversions (clamp+truncate for float, high byte
//! for 16-bit integer, bias for signed); UnityPy's own converters are
//! lossy on these (half truncates x*256 and crashes above 1.0, and its
//! RG32 path reads 16-bit samples). The crunched block family covers the
//! Unity crunch variants: ETC_RGB4Crunched (64), ETC2_RGBA8Crunched (65),
//! DXT1Crunched (28), and DXT5Crunched (29), all routed through the
//! vendored unitycrunch decompressor to raw ETC1/ETC2/DXT1/DXT5 blocks
//! and then decoded by the corresponding block decoder. Crunched streams
//! are validated against UnityPy's texture2ddecoder on real Unity crunch
//! fixtures (the UNITYCRUNCH_*.crn test streams). PVRTC/ATC/EAC/3DS
//! remain unsupported.
//!
//! Block formats are 4x4 pixels, row-major in the data: block (bx, by)
//! sits at index `by * (width/4) + bx`. Within a block, pixel (x, y) is
//! the `y*4 + x`-th pixel.

const std = @import("std");

// Vendored Unity crunch decompressor (src/vendor/unitycrunch, ZLIB
// license): decompresses one mip level of a crunched texture into raw
// ETC1/ETC2/DXT blocks. Defined in the C++ shim linked via build.zig.
extern "c" fn unitycrunch_unpack(data: [*]const u8, data_size: u32, level: u32, ret: *?*anyopaque, ret_size: *u32) c_int;
extern "c" fn unitycrunch_free(p: ?*anyopaque) void;

pub const Error = error{ UnsupportedFormat, BadSize, OutOfMemory };

pub const format = struct {
    // Values match Unity's TextureFormat enum (as used in .assets files).
    pub const alpha8: i32 = 1;
    pub const argb4444: i32 = 2;
    pub const rgb24: i32 = 3;
    pub const rgba32: i32 = 4;
    pub const argb32: i32 = 5;
    pub const rgb565: i32 = 7;
    pub const rgba4444: i32 = 13;
    pub const bgra32: i32 = 14;
    pub const rgba_float: i32 = 20;
    pub const dxt1: i32 = 10;
    pub const dxt3: i32 = 11;
    pub const dxt5: i32 = 12;
    pub const bc4: i32 = 26;
    pub const bc5: i32 = 27;
    pub const bc7: i32 = 25;
    pub const bc6h: i32 = 24;
    pub const etc_rgb4: i32 = 34;
    pub const etc2_rgb: i32 = 45;
    pub const etc2_rgba1: i32 = 46;
    pub const etc2_rgba8: i32 = 47;
    pub const dxt1_crunched: i32 = 28;
    pub const dxt5_crunched: i32 = 29;
    pub const etc_rgb4_crunched: i32 = 64;
    pub const etc2_rgba8_crunched: i32 = 65;
    pub const r8: i32 = 63;
    pub const argb_float: i32 = 6;
    pub const bgr24: i32 = 8;
    pub const r16: i32 = 9;
    pub const r_half: i32 = 15;
    pub const rg_half: i32 = 16;
    pub const rgba_half: i32 = 17;
    pub const r_float: i32 = 18;
    pub const rg_float: i32 = 19;
    pub const rgb9e5: i32 = 22;
    pub const rg16: i32 = 62;
    pub const rg32: i32 = 72;
    pub const rgb48: i32 = 73;
    pub const rgba64: i32 = 74;
    pub const r8_signed: i32 = 75;
    pub const rg16_signed: i32 = 76;
    pub const rgb24_signed: i32 = 77;
    pub const rgba32_signed: i32 = 78;
    pub const r16_signed: i32 = 79;
    pub const rg32_signed: i32 = 80;
    pub const rgb48_signed: i32 = 81;
    pub const rgba64_signed: i32 = 82;
    pub const astc_rgb_4x4: i32 = 48;
    pub const astc_rgb_5x5: i32 = 49;
    pub const astc_rgb_6x6: i32 = 50;
    pub const astc_rgb_8x8: i32 = 51;
    pub const astc_rgb_10x10: i32 = 52;
    pub const astc_rgb_12x12: i32 = 53;
    pub const astc_rgba_4x4: i32 = 54;
    pub const astc_rgba_5x5: i32 = 55;
    pub const astc_rgba_6x6: i32 = 56;
    pub const astc_rgba_8x8: i32 = 57;
    pub const astc_rgba_10x10: i32 = 58;
    pub const astc_rgba_12x12: i32 = 59;
    pub const astc_hdr_4x4: i32 = 66;
    pub const astc_hdr_5x5: i32 = 67;
    pub const astc_hdr_6x6: i32 = 68;
    pub const astc_hdr_8x8: i32 = 69;
    pub const astc_hdr_10x10: i32 = 70;
    pub const astc_hdr_12x12: i32 = 71;

    pub fn name(f: i32) []const u8 {
        return switch (f) {
            1 => "Alpha8",
            2 => "ARGB4444",
            3 => "RGB24",
            4 => "RGBA32",
            5 => "ARGB32",
            7 => "RGB565",
            13 => "RGBA4444",
            14 => "BGRA32",
            20 => "RGBAFloat",
            10 => "DXT1",
            11 => "DXT3",
            12 => "DXT5",
            24 => "BC6H",
            25 => "BC7",
            26 => "BC4",
            27 => "BC5",
            34 => "ETC_RGB4",
            45 => "ETC2_RGB",
            46 => "ETC2_RGBA1",
            47 => "ETC2_RGBA8",
            28 => "DXT1Crunched",
            29 => "DXT5Crunched",
            64 => "ETC_RGB4Crunched",
            65 => "ETC2_RGBA8Crunched",
            63 => "R8",
            6 => "ARGBFloat",
            8 => "BGR24",
            9 => "R16",
            15 => "RHalf",
            16 => "RGHalf",
            17 => "RGBAHalf",
            18 => "RFloat",
            19 => "RGFloat",
            22 => "RGB9e5Float",
            62 => "RG16",
            72 => "RG32",
            73 => "RGB48",
            74 => "RGBA64",
            75 => "R8_SIGNED",
            76 => "RG16_SIGNED",
            77 => "RGB24_SIGNED",
            78 => "RGBA32_SIGNED",
            79 => "R16_SIGNED",
            80 => "RG32_SIGNED",
            81 => "RGB48_SIGNED",
            82 => "RGBA64_SIGNED",
            48 => "ASTC_RGB_4x4",
            49 => "ASTC_RGB_5x5",
            50 => "ASTC_RGB_6x6",
            51 => "ASTC_RGB_8x8",
            52 => "ASTC_RGB_10x10",
            53 => "ASTC_RGB_12x12",
            54 => "ASTC_RGBA_4x4",
            55 => "ASTC_RGBA_5x5",
            56 => "ASTC_RGBA_6x6",
            57 => "ASTC_RGBA_8x8",
            58 => "ASTC_RGBA_10x10",
            59 => "ASTC_RGBA_12x12",
            66 => "ASTC_HDR_4x4",
            67 => "ASTC_HDR_5x5",
            68 => "ASTC_HDR_6x6",
            69 => "ASTC_HDR_8x8",
            70 => "ASTC_HDR_10x10",
            71 => "ASTC_HDR_12x12",
            else => "Unknown",
        };
    }
};

/// Decodes `data` (width×height in `tex_format`) to RGBA8 (width*height*4
/// bytes, row-major). The caller owns the result.
pub fn decode(allocator: std.mem.Allocator, tex_format: i32, width: u32, height: u32, data: []const u8) Error![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    // Dimensions come from the file. Bound the pixel count so neither the
    // RGBA8 output size nor the largest `expectedSize` stride (16 bytes per
    // pixel) can overflow into a short allocation.
    const pixels = std.math.mul(usize, w, h) catch return error.BadSize;
    if (pixels > std.math.maxInt(usize) / 16) return error.BadSize;
    const out = try allocator.alloc(u8, pixels * 4);
    errdefer allocator.free(out);
    const expected = expectedSize(tex_format, width, height) orelse return error.UnsupportedFormat;
    if (data.len < expected) return error.BadSize;

    switch (tex_format) {
        format.alpha8 => copyPixels(out, data, w, h, 1, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = 0;
                dst[1] = 0;
                dst[2] = 0;
                dst[3] = pixel[0];
            }
        }.convert),
        format.rgb24 => copyPixels(out, data, w, h, 3, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[0];
                dst[1] = pixel[1];
                dst[2] = pixel[2];
                dst[3] = 255;
            }
        }.convert),
        format.rgba32 => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[0];
                dst[1] = pixel[1];
                dst[2] = pixel[2];
                dst[3] = pixel[3];
            }
        }.convert),
        format.argb32 => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[1];
                dst[1] = pixel[2];
                dst[2] = pixel[3];
                dst[3] = pixel[0];
            }
        }.convert),
        format.bgra32 => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[2];
                dst[1] = pixel[1];
                dst[2] = pixel[0];
                dst[3] = pixel[3];
            }
        }.convert),
        format.rgb565 => copyPixels(out, data, w, h, 2, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const v = std.mem.readInt(u16, pixel[0..2], .little);
                dst[0] = @intCast((v >> 11) * 255 / 31);
                dst[1] = @intCast(((v >> 5) & 0x3f) * 255 / 63);
                dst[2] = @intCast((v & 0x1f) * 255 / 31);
                dst[3] = 255;
            }
        }.convert),
        format.rgba4444 => copyPixels(out, data, w, h, 2, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const v = std.mem.readInt(u16, pixel[0..2], .little);
                dst[0] = @intCast((v >> 12) * 255 / 15);
                dst[1] = @intCast(((v >> 8) & 0xf) * 255 / 15);
                dst[2] = @intCast(((v >> 4) & 0xf) * 255 / 15);
                dst[3] = @intCast((v & 0xf) * 255 / 15);
            }
        }.convert),
        format.argb4444 => copyPixels(out, data, w, h, 2, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const v = std.mem.readInt(u16, pixel[0..2], .little);
                dst[0] = @intCast(((v >> 8) & 0xf) * 255 / 15);
                dst[1] = @intCast(((v >> 4) & 0xf) * 255 / 15);
                dst[2] = @intCast((v & 0xf) * 255 / 15);
                dst[3] = @intCast((v >> 12) * 255 / 15);
            }
        }.convert),
        format.r8 => copyPixels(out, data, w, h, 1, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[0];
                dst[1] = pixel[0];
                dst[2] = pixel[0];
                dst[3] = 255;
            }
        }.convert),
        format.rgba_float => copyPixels(out, data, w, h, 16, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const r: f32 = @bitCast(std.mem.readInt(u32, pixel[0..4], .little));
                const g: f32 = @bitCast(std.mem.readInt(u32, pixel[4..8], .little));
                const b: f32 = @bitCast(std.mem.readInt(u32, pixel[8..12], .little));
                const a: f32 = @bitCast(std.mem.readInt(u32, pixel[12..16], .little));
                dst[0] = floatToByte(r);
                dst[1] = floatToByte(g);
                dst[2] = floatToByte(b);
                dst[3] = floatToByte(a);
            }
        }.convert),
        format.argb_float => copyPixels(out, data, w, h, 16, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const a: f32 = @bitCast(std.mem.readInt(u32, pixel[0..4], .little));
                const r: f32 = @bitCast(std.mem.readInt(u32, pixel[4..8], .little));
                const g: f32 = @bitCast(std.mem.readInt(u32, pixel[8..12], .little));
                const b: f32 = @bitCast(std.mem.readInt(u32, pixel[12..16], .little));
                dst[0] = floatToByte(r);
                dst[1] = floatToByte(g);
                dst[2] = floatToByte(b);
                dst[3] = floatToByte(a);
            }
        }.convert),
        format.bgr24 => copyPixels(out, data, w, h, 3, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[2];
                dst[1] = pixel[1];
                dst[2] = pixel[0];
                dst[3] = 255;
            }
        }.convert),
        format.r16 => copyPixels(out, data, w, h, 2, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const v: u16 = std.mem.readInt(u16, pixel[0..2], .little);
                const c: u8 = @intCast(v >> 8); // high byte
                dst[0] = c;
                dst[1] = c;
                dst[2] = c;
                dst[3] = 255;
            }
        }.convert),
        format.r_half => copyPixels(out, data, w, h, 2, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const c: u8 = f16ToByte(pixel);
                dst[0] = c;
                dst[1] = c;
                dst[2] = c;
                dst[3] = 255;
            }
        }.convert),
        format.rg_half => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = f16ToByte(pixel);
                dst[1] = f16ToByte(pixel[2..]);
                dst[2] = 0;
                dst[3] = 255;
            }
        }.convert),
        format.rgba_half => copyPixels(out, data, w, h, 8, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = f16ToByte(pixel);
                dst[1] = f16ToByte(pixel[2..]);
                dst[2] = f16ToByte(pixel[4..]);
                dst[3] = f16ToByte(pixel[6..]);
            }
        }.convert),
        format.r_float => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const c: u8 = f32ToByte(pixel);
                dst[0] = c;
                dst[1] = c;
                dst[2] = c;
                dst[3] = 255;
            }
        }.convert),
        format.rg_float => copyPixels(out, data, w, h, 8, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = f32ToByte(pixel);
                dst[1] = f32ToByte(pixel[4..]);
                dst[2] = 0;
                dst[3] = 255;
            }
        }.convert),
        format.rgb9e5 => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const n: u32 = std.mem.readInt(u32, pixel[0..4], .little);
                const scale: i32 = @intCast((n >> 27) & 0x1f);
                const scale_f: f32 = std.math.pow(f32, 2.0, @floatFromInt(scale - 24));
                const mants = [_]u32{ n & 0x1ff, (n >> 9) & 0x1ff, (n >> 18) & 0x1ff };
                for (mants, 0..) |m, i| {
                    dst[i] = floatToByte(@as(f32, @floatFromInt(m)) * scale_f);
                }
                dst[3] = 255;
            }
        }.convert),
        format.rg16 => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = @intCast(std.mem.readInt(u16, pixel[0..2], .little) >> 8);
                dst[1] = @intCast(std.mem.readInt(u16, pixel[2..4], .little) >> 8);
                dst[2] = 0;
                dst[3] = 255;
            }
        }.convert),
        format.rg32 => copyPixels(out, data, w, h, 8, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = f32ToByte(pixel);
                dst[1] = f32ToByte(pixel[4..]);
                dst[2] = 0;
                dst[3] = 255;
            }
        }.convert),
        format.rgb48 => copyPixels(out, data, w, h, 6, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = @intCast(std.mem.readInt(u16, pixel[0..2], .little) >> 8);
                dst[1] = @intCast(std.mem.readInt(u16, pixel[2..4], .little) >> 8);
                dst[2] = @intCast(std.mem.readInt(u16, pixel[4..6], .little) >> 8);
                dst[3] = 255;
            }
        }.convert),
        format.rgba64 => copyPixels(out, data, w, h, 8, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = @intCast(std.mem.readInt(u16, pixel[0..2], .little) >> 8);
                dst[1] = @intCast(std.mem.readInt(u16, pixel[2..4], .little) >> 8);
                dst[2] = @intCast(std.mem.readInt(u16, pixel[4..6], .little) >> 8);
                dst[3] = @intCast(std.mem.readInt(u16, pixel[6..8], .little) >> 8);
            }
        }.convert),
        format.r8_signed => copyPixels(out, data, w, h, 1, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const c: u8 = pixel[0] +% 128;
                dst[0] = c;
                dst[1] = c;
                dst[2] = c;
                dst[3] = 255;
            }
        }.convert),
        format.rgba32_signed => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[0] +% 128;
                dst[1] = pixel[1] +% 128;
                dst[2] = pixel[2] +% 128;
                dst[3] = pixel[3] +% 128;
            }
        }.convert),
        format.rgb24_signed => copyPixels(out, data, w, h, 3, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = pixel[0] +% 128;
                dst[1] = pixel[1] +% 128;
                dst[2] = pixel[2] +% 128;
                dst[3] = 255;
            }
        }.convert),
        format.r16_signed => copyPixels(out, data, w, h, 2, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                const v: i16 = @bitCast(std.mem.readInt(u16, pixel[0..2], .little));
                const c: u8 = @intCast((@as(u32, @bitCast(@as(i32, v) + 32768))) >> 8);
                dst[0] = c;
                dst[1] = c;
                dst[2] = c;
                dst[3] = 255;
            }
        }.convert),
        format.rg16_signed => copyPixels(out, data, w, h, 4, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = i16BiasedByte(pixel);
                dst[1] = i16BiasedByte(pixel[2..]);
                dst[2] = 0;
                dst[3] = 255;
            }
        }.convert),
        format.rgb48_signed => copyPixels(out, data, w, h, 6, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = i16BiasedByte(pixel);
                dst[1] = i16BiasedByte(pixel[2..]);
                dst[2] = i16BiasedByte(pixel[4..]);
                dst[3] = 255;
            }
        }.convert),
        format.rgba64_signed => copyPixels(out, data, w, h, 8, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = i16BiasedByte(pixel);
                dst[1] = i16BiasedByte(pixel[2..]);
                dst[2] = i16BiasedByte(pixel[4..]);
                dst[3] = i16BiasedByte(pixel[6..]);
            }
        }.convert),
        format.rg32_signed => copyPixels(out, data, w, h, 8, struct {
            fn convert(pixel: []const u8, dst: []u8) void {
                dst[0] = @intCast((std.mem.readInt(u32, pixel[0..4], .little) +% 0x80000000) >> 24);
                dst[1] = @intCast((std.mem.readInt(u32, pixel[4..8], .little) +% 0x80000000) >> 24);
                dst[2] = 0;
                dst[3] = 255;
            }
        }.convert),
        format.dxt1 => try decodeDxt1(out, w, h, data),
        format.dxt3 => try decodeDxt3(out, w, h, data),
        format.dxt5 => try decodeDxt5(out, w, h, data),
        format.bc4 => try decodeBc4(out, w, h, data),
        format.bc5 => try decodeBc5(out, w, h, data),
        format.bc7 => try decodeBc7(out, w, h, data),
        format.etc_rgb4 => try decodeEtc(out, w, h, data, .etc1),
        format.etc2_rgb => try decodeEtc(out, w, h, data, .etc2),
        format.etc2_rgba8 => try decodeEtc2Rgba8(out, w, h, data),
        format.etc_rgb4_crunched, format.etc2_rgba8_crunched, format.dxt1_crunched, format.dxt5_crunched => {
            // decompress the crunch stream to raw blocks (ETC1/ETC2/DXT1/DXT5),
            // then decode those blocks with the corresponding block decoder
            var out_ptr: ?*anyopaque = null;
            var out_size: u32 = 0;
            if (unitycrunch_unpack(data.ptr, @intCast(data.len), 0, &out_ptr, &out_size) == 0 or out_ptr == null)
                return error.UnsupportedFormat;
            defer unitycrunch_free(out_ptr);
            const blocks: []const u8 = @as([*]const u8, @ptrCast(out_ptr.?))[0..out_size];
            // The crunch stream names the block format, not the Unity texture
            // format; map the crunched format number back to its raw blocks.
            const fmt: i32 = switch (tex_format) {
                format.etc_rgb4_crunched => format.etc_rgb4,
                format.etc2_rgba8_crunched => format.etc2_rgba8,
                format.dxt1_crunched => format.dxt1,
                format.dxt5_crunched => format.dxt5,
                else => return error.UnsupportedFormat,
            };
            return decode(allocator, fmt, width, height, blocks);
        },
        else => blk: {
            if (astcBlockSize(tex_format)) |bs| {
                break :blk try decodeAstc(out, w, h, data, bs.bw, bs.bh);
            }
            return error.UnsupportedFormat;
        },
    }
    return out;
}

/// Copies `stride`-byte pixels through a converter.
fn floatToByte(f: f32) u8 {
    // Written as `!(f > 0)` so a NaN pixel - float-format textures really do
    // carry them - takes the 0 branch instead of reaching @intFromFloat,
    // which is illegal behavior on a non-finite value.
    if (!(f > 0)) return 0;
    if (f >= 1) return 255;
    return @intFromFloat(f * 255);
}

/// Half-float pixel to 8-bit (clamped like floatToByte).
fn f16ToByte(ptr: []const u8) u8 {
    const h: u16 = std.mem.readInt(u16, ptr[0..2], .little);
    const f: f32 = @floatCast(@as(f16, @bitCast(h)));
    return floatToByte(f);
}

/// Float32 pixel to 8-bit (clamped like floatToByte).
fn f32ToByte(ptr: []const u8) u8 {
    const f: f32 = @bitCast(std.mem.readInt(u32, ptr[0..4], .little));
    return floatToByte(f);
}

/// Signed 16-bit pixel to 8-bit: bias by 32768, take the high byte.
fn i16BiasedByte(ptr: []const u8) u8 {
    const v: i16 = @bitCast(std.mem.readInt(u16, ptr[0..2], .little));
    return @intCast((@as(u32, @bitCast(@as(i32, v) + 32768))) >> 8);
}

/// Returns a vertically flipped copy of an RGBA8 image: Unity stores
/// texture rows bottom-up (row 0 is the bottom), while PNG row 0 is the
/// top, so exported images are flipped to display upright (UnityPy's
/// texture export does the same).
pub fn flipVertical(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) Error![]u8 {
    const w: usize = width;
    const h: usize = height;
    if (rgba.len < w * h * 4) return error.BadSize;
    const stride = w * 4;
    const out = try allocator.alloc(u8, w * h * 4);
    for (0..h) |row| {
        const src = rgba[(h - 1 - row) * stride ..][0..stride];
        @memcpy(out[row * stride ..][0..stride], src);
    }
    return out;
}

/// Copies `stride`-byte pixels through a converter.
fn copyPixels(out: []u8, data: []const u8, w: usize, h: usize, stride: usize, comptime convert: fn ([]const u8, []u8) void) void {
    var i: usize = 0;
    var src: usize = 0;
    while (i < w * h) : (i += 1) {
        convert(data[src .. src + stride], out[i * 4 ..][0..4]);
        src += stride;
    }
}

fn expectedSize(tex_format: i32, width: u32, height: u32) ?usize {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    return switch (tex_format) {
        format.alpha8, format.r8 => w * h,
        format.rgb24 => w * h * 3,
        format.rgba32, format.argb32, format.bgra32 => w * h * 4,
        format.rgb565, format.rgba4444, format.argb4444 => w * h * 2,
        format.rgba_float => w * h * 16,
        format.bgr24, format.rgb24_signed => w * h * 3,
        format.argb_float => w * h * 16,
        format.r16, format.r_half, format.r_float, format.r16_signed => w * h * 2,
        format.rg_half, format.rg_float, format.rg16, format.rg16_signed => w * h * 4,
        format.rgba_half => w * h * 8,
        format.rgb9e5 => w * h * 4,
        format.rg32, format.rg32_signed => w * h * 8,
        format.rgb48, format.rgb48_signed => w * h * 6,
        format.rgba64, format.rgba64_signed => w * h * 8,
        format.r8_signed => w * h * 1,
        format.rgba32_signed => w * h * 4,
        format.dxt1, format.dxt3, format.dxt5, format.bc4, format.bc5, format.bc7 => blk: {
            // dimensions are padded up to multiples of 4
            const bw = (w + 3) / 4;
            const bh = (h + 3) / 4;
            const per_block: usize = if (tex_format == format.dxt1 or tex_format == format.bc4) 8 else 16;
            break :blk bw * bh * per_block;
        },
        format.etc_rgb4, format.etc2_rgb => blk: {
            const bw = (w + 3) / 4;
            const bh = (h + 3) / 4;
            break :blk bw * bh * 8;
        },
        format.etc2_rgba8 => blk: {
            const bw = (w + 3) / 4;
            const bh = (h + 3) / 4;
            break :blk bw * bh * 16;
        },
        // crunched streams are arbitrary size; the crunch decompressor validates them
        format.etc_rgb4_crunched, format.etc2_rgba8_crunched, format.dxt1_crunched, format.dxt5_crunched => 0,
        else => blk: {
            const bs = astcBlockSize(tex_format) orelse return null;
            const nbx = (w + bs.bw - 1) / bs.bw;
            const nby = (h + bs.bh - 1) / bs.bh;
            break :blk nbx * nby * 16;
        },
    };
}

// --- DXT / BC1-3 ---

/// Weighted alpha interpolation, `(na*a + nb*b) / 7` in u16 math.
fn interp7(a: u8, b: u8, na: u8, nb: u8) u8 {
    return @intCast((@as(u16, na) * a + @as(u16, nb) * b) / 7);
}

/// Weighted alpha interpolation, `(na*a + nb*b) / 5` in u16 math.
fn interp5(a: u8, b: u8, na: u8, nb: u8) u8 {
    return @intCast((@as(u16, na) * a + @as(u16, nb) * b) / 5);
}

fn expand565(v: u16) [3]u8 {
    // BCn 565→888 expansion: replicate the high bits, not `v*255/31`
    // (which truncates and is off-by-one from the spec's bit replication).
    const r5 = (v >> 11) & 0x1f;
    const g6 = (v >> 5) & 0x3f;
    const b5 = v & 0x1f;
    return .{
        @intCast((r5 << 3) | (r5 >> 2)),
        @intCast((g6 << 2) | (g6 >> 4)),
        @intCast((b5 << 3) | (b5 >> 2)),
    };
}

/// Writes the 4x4 color block of a BC1 block (colors already resolved).
/// `indices` holds 16 two-bit indices; `palette` has 4 entries. Pixels
/// past the image edge (blocks are padded up to multiples of 4) are
/// skipped.
fn putColorBlock(out: []u8, block_x: usize, block_y: usize, w: usize, h: usize, indices: u32, palette: [4][4]u8, alpha_from_palette: bool) void {
    for (0..4) |y| {
        for (0..4) |x| {
            const idx = (indices >> @as(u5, @intCast(2 * (y * 4 + x)))) & 0x3;
            const px = block_x * 4 + x;
            const py = block_y * 4 + y;
            if (px >= w or py >= h) continue;
            const dst = out[(py * w + px) * 4 ..][0..4];
            if (alpha_from_palette and idx == 3) {
                dst[0] = 0;
                dst[1] = 0;
                dst[2] = 0;
                dst[3] = 0;
            } else {
                dst[0] = palette[idx][0];
                dst[1] = palette[idx][1];
                dst[2] = palette[idx][2];
                dst[3] = palette[idx][3];
            }
        }
    }
}

fn decodeDxt1(out: []u8, w: usize, h: usize, data: []const u8) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = data[(by * bw + bx) * 8 ..][0..8];
            const c0 = std.mem.readInt(u16, block[0..2], .little);
            const c1 = std.mem.readInt(u16, block[2..4], .little);
            const indices = std.mem.readInt(u32, block[4..8], .little);
            const rgb0 = expand565(c0);
            const rgb1 = expand565(c1);
            var palette: [4][4]u8 = undefined;
            var alpha_from_palette = false;
            if (c0 > c1) {
                palette[0] = .{ rgb0[0], rgb0[1], rgb0[2], 255 };
                palette[1] = .{ rgb1[0], rgb1[1], rgb1[2], 255 };
                palette[2] = .{ @intCast((@as(u16, 2) * rgb0[0] + rgb1[0]) / 3), @intCast((@as(u16, 2) * rgb0[1] + rgb1[1]) / 3), @intCast((@as(u16, 2) * rgb0[2] + rgb1[2]) / 3), 255 };
                palette[3] = .{ @intCast((@as(u16, rgb0[0]) + @as(u16, 2) * rgb1[0]) / 3), @intCast((@as(u16, rgb0[1]) + @as(u16, 2) * rgb1[1]) / 3), @intCast((@as(u16, rgb0[2]) + @as(u16, 2) * rgb1[2]) / 3), 255 };
            } else {
                palette[0] = .{ rgb0[0], rgb0[1], rgb0[2], 255 };
                palette[1] = .{ rgb1[0], rgb1[1], rgb1[2], 255 };
                palette[2] = .{ @intCast((@as(u16, rgb0[0]) + rgb1[0]) / 2), @intCast((@as(u16, rgb0[1]) + rgb1[1]) / 2), @intCast((@as(u16, rgb0[2]) + rgb1[2]) / 2), 255 };
                palette[3] = .{ 0, 0, 0, 0 };
                alpha_from_palette = true;
            }
            putColorBlock(out, bx, by, w, h, indices, palette, alpha_from_palette);
        }
    }
}

fn decodeDxt3(out: []u8, w: usize, h: usize, data: []const u8) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = data[(by * bw + bx) * 16 ..][0..16];
            // alpha nibbles: pixel i in the high nibble of byte i/2
            const c0 = std.mem.readInt(u16, block[8..10], .little);
            const c1 = std.mem.readInt(u16, block[10..12], .little);
            const indices = std.mem.readInt(u32, block[12..16], .little);
            const rgb0 = expand565(c0);
            const rgb1 = expand565(c1);
            var palette: [4][4]u8 = undefined;
            palette[0] = .{ rgb0[0], rgb0[1], rgb0[2], 255 };
            palette[1] = .{ rgb1[0], rgb1[1], rgb1[2], 255 };
            palette[2] = .{ @intCast((@as(u16, 2) * rgb0[0] + rgb1[0]) / 3), @intCast((@as(u16, 2) * rgb0[1] + rgb1[1]) / 3), @intCast((@as(u16, 2) * rgb0[2] + rgb1[2]) / 3), 255 };
            palette[3] = .{ @intCast((@as(u16, rgb0[0]) + @as(u16, 2) * rgb1[0]) / 3), @intCast((@as(u16, rgb0[1]) + @as(u16, 2) * rgb1[1]) / 3), @intCast((@as(u16, rgb0[2]) + @as(u16, 2) * rgb1[2]) / 3), 255 };
            for (0..4) |y| {
                for (0..4) |x| {
                    const px = bx * 4 + x;
                    const py = by * 4 + y;
                    if (px >= w or py >= h) continue;
                    const dst = out[(py * w + px) * 4 ..][0..4];
                    const i = y * 4 + x;
                    const alpha_nib = (block[i / 2] >> @as(u3, @intCast(4 * (1 - (i % 2))))) & 0xf;
                    const idx = (indices >> @as(u5, @intCast(2 * i))) & 0x3;
                    dst[0] = palette[idx][0];
                    dst[1] = palette[idx][1];
                    dst[2] = palette[idx][2];
                    dst[3] = @intCast(@as(u16, alpha_nib) * 255 / 15);
                }
            }
        }
    }
}

fn decodeDxt5(out: []u8, w: usize, h: usize, data: []const u8) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = data[(by * bw + bx) * 16 ..][0..16];
            const a0 = block[0];
            const a1 = block[1];
            // 48 bits of 3-bit alpha indices, LSB-first per pixel
            const a_bits = std.mem.readInt(u48, block[2..8], .little);
            const c0 = std.mem.readInt(u16, block[8..10], .little);
            const c1 = std.mem.readInt(u16, block[10..12], .little);
            const indices = std.mem.readInt(u32, block[12..16], .little);
            const rgb0 = expand565(c0);
            const rgb1 = expand565(c1);
            var palette: [4][4]u8 = undefined;
            palette[0] = .{ rgb0[0], rgb0[1], rgb0[2], 255 };
            palette[1] = .{ rgb1[0], rgb1[1], rgb1[2], 255 };
            palette[2] = .{ @intCast((@as(u16, 2) * rgb0[0] + rgb1[0]) / 3), @intCast((@as(u16, 2) * rgb0[1] + rgb1[1]) / 3), @intCast((@as(u16, 2) * rgb0[2] + rgb1[2]) / 3), 255 };
            palette[3] = .{ @intCast((@as(u16, rgb0[0]) + @as(u16, 2) * rgb1[0]) / 3), @intCast((@as(u16, rgb0[1]) + @as(u16, 2) * rgb1[1]) / 3), @intCast((@as(u16, rgb0[2]) + @as(u16, 2) * rgb1[2]) / 3), 255 };
            for (0..4) |y| {
                for (0..4) |x| {
                    const px = bx * 4 + x;
                    const py = by * 4 + y;
                    if (px >= w or py >= h) continue;
                    const dst = out[(py * w + px) * 4 ..][0..4];
                    const i = y * 4 + x;
                    const aidx = (a_bits >> @as(u6, @intCast(3 * i))) & 0x7;
                    const alpha: u8 = if (a0 > a1)
                        switch (aidx) {
                            0 => a0,
                            1 => a1,
                            2 => interp7(a0, a1, 6, 1),
                            3 => interp7(a0, a1, 5, 2),
                            4 => interp7(a0, a1, 4, 3),
                            5 => interp7(a0, a1, 3, 4),
                            6 => interp7(a0, a1, 2, 5),
                            else => interp7(a0, a1, 1, 6),
                        }
                    else
                        switch (aidx) {
                            0 => a0,
                            1 => a1,
                            2 => interp5(a0, a1, 4, 1),
                            3 => interp5(a0, a1, 3, 2),
                            4 => interp5(a0, a1, 2, 3),
                            5 => interp5(a0, a1, 1, 4),
                            6 => 0,
                            else => 255,
                        };
                    const idx = (indices >> @as(u5, @intCast(2 * i))) & 0x3;
                    dst[0] = palette[idx][0];
                    dst[1] = palette[idx][1];
                    dst[2] = palette[idx][2];
                    dst[3] = alpha;
                }
            }
        }
    }
}

test "rgb24 and rgba32 round trip" {
    const a = std.testing.allocator;
    const pixels = [_]u8{ 10, 20, 30, 40, 50, 60 };
    const out = try decode(a, format.rgb24, 2, 1, &pixels);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 255, 40, 50, 60, 255 }, out);

    const out2 = try decode(a, format.rgba32, 1, 1, &[_]u8{ 1, 2, 3, 4 });
    defer a.free(out2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, out2);
}

test "rgb565 and rgba4444" {
    const a = std.testing.allocator;
    // red in 565: r=31, g=0, b=0 → 0xF800
    const out = try decode(a, format.rgb565, 1, 1, &[_]u8{ 0x00, 0xF8 });
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, out);

    // rgba4444: r=15, g=0, b=0, a=15 → 0xF00F little-endian
    const out2 = try decode(a, format.rgba4444, 1, 1, &[_]u8{ 0x0F, 0xF0 });
    defer a.free(out2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, out2);
}

test "dxt1 four color mode" {
    const a = std.testing.allocator;
    // 4x4, c0 = red (0xF800), c1 = green (0x07E0), all indices 0
    var block: [8]u8 = undefined;
    std.mem.writeInt(u16, block[0..2], 0xF800, .little);
    std.mem.writeInt(u16, block[2..4], 0x07E0, .little);
    std.mem.writeInt(u32, block[4..8], 0, .little);
    const out = try decode(a, format.dxt1, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, out[15 * 4 ..][0..4]);
}

test "dxt1 three color mode with transparent index" {
    const a = std.testing.allocator;
    // c0 == c1 (red) → 3-color mode; pixel 0 → index 0 (red),
    // pixel 1 → index 3 (transparent).
    var block: [8]u8 = undefined;
    std.mem.writeInt(u16, block[0..2], 0xF800, .little);
    std.mem.writeInt(u16, block[2..4], 0xF800, .little);
    std.mem.writeInt(u32, block[4..8], (3 << 2) | 0, .little); // pixel0=0, pixel1=3
    const out = try decode(a, format.dxt1, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, out[4..8]);
}

test "dxt3 alpha nibbles" {
    const a = std.testing.allocator;
    // 4x4 block: alpha nibble for pixel 0 = 0xF (opaque), pixel 1 = 0x0
    var block: [16]u8 = undefined;
    @memset(&block, 0);
    block[0] = 0xF0; // pixel0 alpha high nibble = 0xF
    std.mem.writeInt(u16, block[8..10], 0xF800, .little); // c0 red
    std.mem.writeInt(u16, block[10..12], 0x07E0, .little); // c1 green
    std.mem.writeInt(u32, block[12..16], 0, .little); // indices all 0
    const out = try decode(a, format.dxt3, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 0 }, out[4..8]);
}

test "dxt5 alpha interpolation" {
    const a = std.testing.allocator;
    // a0=255, a1=0 → 8-level interpolation; pixel 0 index 0 → 255,
    // pixel 1 index 6 → 2*255/7 ≈ 72.
    var block: [16]u8 = undefined;
    @memset(&block, 0);
    block[0] = 255;
    block[1] = 0;
    // pixel0 → idx 0 (bits 0-2), pixel1 → idx 6 (bits 3-5)
    const a_bits: u48 = 6 << 3;
    std.mem.writeInt(u48, block[2..8], a_bits, .little);
    std.mem.writeInt(u16, block[8..10], 0xF800, .little);
    std.mem.writeInt(u16, block[10..12], 0x07E0, .little);
    std.mem.writeInt(u32, block[12..16], 0, .little);
    const out = try decode(a, format.dxt5, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 72 }, out[4..8]);
}

test "bc7 mode 0 block" {
    const a = std.testing.allocator;
    // mode 0 (3 subsets, 4-bit RGB, endpoint pbits), values cross-checked
    // against UnityPy's texture2ddecoder.
    var block = [_]u8{ 0x01, 0xee, 0xe7, 0x61, 0x5e, 0xf3, 0x5f, 0x30, 0xe4, 0x9b, 0x48, 0x2e, 0x15, 0xca, 0xe7, 0x50 };
    const out = try decode(a, format.bc7, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x10, 0x4d, 0x2f, 0xff }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xd4, 0xf7, 0xf2, 0xff }, out[15 * 4 ..][0..4]);
}

test "bc7 mode 5 block with alpha rotation" {
    const a = std.testing.allocator;
    // mode 5 (single subset, 7-bit RGB + 8-bit alpha, index selection and
    // channel rotation), cross-checked against UnityPy's decoder.
    var block = [_]u8{ 0x20, 0x20, 0x1e, 0x12, 0x61, 0x7b, 0x0f, 0xed, 0xa7, 0xe1, 0x64, 0x77, 0x96, 0xff, 0x02, 0x2b };
    const out = try decode(a, format.bc7, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x52, 0x67, 0x92, 0x7f }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x40, 0x91, 0x6c, 0x43 }, out[15 * 4 ..][0..4]);
}

test "bc7 reserved mode 8 is transparent black" {
    const a = std.testing.allocator;
    // reserved mode (eight leading zero bits): UnityPy emits transparent black.
    var block = [_]u8{ 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80 };
    const out = try decode(a, format.bc7, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, out[15 * 4 ..][0..4]);
}

test "bc7 mode 7 block with alpha" {
    const a = std.testing.allocator;
    // mode 7 (2 subsets, 5-bit RGBA + endpoint pbits), cross-checked
    // against UnityPy's decoder.
    var block = [_]u8{ 0x01, 0x00, 0x6d, 0x6b, 0x1a, 0xf0, 0xc0, 0xcb, 0xd6, 0x25, 0x65, 0x8a, 0xac, 0x2c, 0x9f, 0xaa };
    const out = try decode(a, format.bc7, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x39, 0xef, 0xff }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x9b, 0x55, 0xb2, 0xff }, out[15 * 4 ..][0..4]);
}

// --- ASTC ---

const AstcBlockData = struct {
    bw: usize,
    bh: usize,
    width: usize,
    height: usize,
    part_num: usize,
    dual_plane: bool,
    plane_selector: usize,
    weight_range: usize,
    weight_num: usize,
    cem: [4]usize,
    cem_range: usize,
    endpoint_value_num: usize,
    endpoints: [4][8]i32,
    weights: [144][2]i32,
    partition: [144]usize,
};

const AstcIntSeqData = struct { bits: u64, nonbits: u64 };

const astcBitReverseTable = [_]u8{
    0, 128, 64, 192, 32, 160, 96, 224, 16, 144, 80, 208, 48, 176, 112, 240,
    8, 136, 72, 200, 40, 168, 104, 232, 24, 152, 88, 216, 56, 184, 120, 248,
    4, 132, 68, 196, 36, 164, 100, 228, 20, 148, 84, 212, 52, 180, 116, 244,
    12, 140, 76, 204, 44, 172, 108, 236, 28, 156, 92, 220, 60, 188, 124, 252,
    2, 130, 66, 194, 34, 162, 98, 226, 18, 146, 82, 210, 50, 178, 114, 242,
    10, 138, 74, 202, 42, 170, 106, 234, 26, 154, 90, 218, 58, 186, 122, 250,
    6, 134, 70, 198, 38, 166, 102, 230, 22, 150, 86, 214, 54, 182, 118, 246,
    14, 142, 78, 206, 46, 174, 110, 238, 30, 158, 94, 222, 62, 190, 126, 254,
    1, 129, 65, 193, 33, 161, 97, 225, 17, 145, 81, 209, 49, 177, 113, 241,
    9, 137, 73, 201, 41, 169, 105, 233, 25, 153, 89, 217, 57, 185, 121, 249,
    5, 133, 69, 197, 37, 165, 101, 229, 21, 149, 85, 213, 53, 181, 117, 245,
    13, 141, 77, 205, 45, 173, 109, 237, 29, 157, 93, 221, 61, 189, 125, 253,
    3, 131, 67, 195, 35, 163, 99, 227, 19, 147, 83, 211, 51, 179, 115, 243,
    11, 139, 75, 203, 43, 171, 107, 235, 27, 155, 91, 219, 59, 187, 123, 251,
    7, 135, 71, 199, 39, 167, 103, 231, 23, 151, 87, 215, 55, 183, 119, 247,
    15, 143, 79, 207, 47, 175, 111, 239, 31, 159, 95, 223, 63, 191, 127, 255,
};

/// Reverses the low `bits` bits of an 8-bit value.
fn astcBitReverseU8(c: u8, bits: u8) u8 {
    if (bits >= 8) return astcBitReverseTable[c];
    return astcBitReverseTable[c] >> @intCast(8 -% bits);
}

/// Reverses the low `bits` bits of a 64-bit value.
fn astcBitReverseU64(d: u64, bits: usize) u64 {
    const ret = (std.math.shl(u64, @as(u64, astcBitReverseTable[d & 0xff]), 56)) |
        (@as(u64, astcBitReverseTable[(d >> 8) & 0xff]) << 48) |
        (@as(u64, astcBitReverseTable[(d >> 16) & 0xff]) << 40) |
        (@as(u64, astcBitReverseTable[(d >> 24) & 0xff]) << 32) |
        (@as(u64, astcBitReverseTable[(d >> 32) & 0xff]) << 24) |
        (@as(u64, astcBitReverseTable[(d >> 40) & 0xff]) << 16) |
        (@as(u64, astcBitReverseTable[(d >> 48) & 0xff]) << 8) |
        @as(u64, astcBitReverseTable[(d >> 56) & 0xff]);
    return ret >> @intCast(64 -% bits);
}

/// Reads `num` bits (LSB first) at absolute bit position `bit`, up to 32
/// bits. Out-of-range bytes read as zero.
fn astcGetBits(buf: []const u8, bit: usize, num: usize) i32 {
    const shift = bit % 8;
    const byte = bit / 8;
    var raw: u32 = 0;
    var i: usize = 0;
    while (i < 4 and byte +% i < buf.len) : (i += 1) {
        raw |= @as(u32, buf[byte +% i]) << @intCast(8 *% i);
    }
    if (num == 0) return 0;
    return @intCast((raw >> @intCast(shift)) & ((@as(u32, 1) << @intCast(num)) -% 1));
}

/// Reads up to 64 bits at bit position `bit` (may be negative or past 64).
fn astcGetBits64(buf: []const u8, bit: i64, len: usize) u64 {
    const mask: u64 = if (len == 64) 0xffffffffffffffff else (@as(u64, 1) << @intCast(len)) -% 1;
    if (len == 0) return 0;
    var lo: u64 = 0;
    var hi: u64 = 0;
    if (buf.len >= 8) {
        lo = std.mem.readInt(u64, buf[0..8], .little);
    }
    if (buf.len >= 16) {
        hi = std.mem.readInt(u64, buf[8..16], .little);
    }
    // clamp only the shift amounts (0..63) so corrupt offsets cannot
    // panic; negative offsets are legal in the HDR endpoint decode
    if (bit >= 64) {
        return (hi >> @intCast(@min(bit -% 64, 63))) & mask;
    } else if (bit <= 0) {
        const sh: u6 = @intCast(@min(@max(-% bit, 0), 63));
        return (lo << sh) & mask;
    } else if (bit + @as(i64, @intCast(len)) <= 64) {
        return (lo >> @intCast(bit)) & mask;
    } else {
        return ((lo >> @intCast(bit)) | (hi << @intCast(@min(64 -% bit, 63)))) & mask;
    }
}

const astcWeightPrecA = [_]i32{ 0, 0, 0, 3, 0, 5, 3, 0, 0, 0, 5, 3, 0, 5, 3, 0 };
const astcWeightPrecB = [_]i32{ 0, 0, 1, 0, 2, 0, 1, 3, 0, 0, 1, 2, 4, 2, 3, 5 };
const astcCemA = [_]usize{ 0, 3, 5, 0, 3, 5, 0, 3, 5, 0, 3, 5, 0, 3, 5, 0, 3, 0, 0 };
const astcCemB = [_]usize{ 8, 6, 5, 7, 5, 4, 6, 4, 3, 5, 3, 2, 4, 2, 1, 3, 1, 2, 1 };

const astcTritsTable = [_][256]u64{
    .{ 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 1, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 1, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 0, 0, 1, 2, 1, 0, 1, 2, 2, 0, 1, 2, 2 },
    .{ 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 2, 2, 2, 0, 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 2, 2, 2, 0, 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 2, 2, 2, 1, 0, 0, 0, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 1, 2, 2, 2, 1 },
    .{ 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 2, 2, 2, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 2, 2, 2, 2 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 },
};

const astcQuintsTable = [_][128]u64{
    .{ 0, 1, 2, 3, 4, 0, 4, 4, 0, 1, 2, 3, 4, 1, 4, 4, 0, 1, 2, 3, 4, 2, 4, 4, 0, 1, 2, 3, 4, 3, 4, 4, 0, 1, 2, 3, 4, 0, 4, 0, 0, 1, 2, 3, 4, 1, 4, 1, 0, 1, 2, 3, 4, 2, 4, 2, 0, 1, 2, 3, 4, 3, 4, 3, 0, 1, 2, 3, 4, 0, 2, 3, 0, 1, 2, 3, 4, 1, 2, 3, 0, 1, 2, 3, 4, 2, 2, 3, 0, 1, 2, 3, 4, 3, 2, 3, 0, 1, 2, 3, 4, 0, 0, 1, 0, 1, 2, 3, 4, 1, 0, 1, 0, 1, 2, 3, 4, 2, 0, 1, 0, 1, 2, 3, 4, 3, 0, 1 },
    .{ 0, 0, 0, 0, 0, 4, 4, 4, 1, 1, 1, 1, 1, 4, 4, 4, 2, 2, 2, 2, 2, 4, 4, 4, 3, 3, 3, 3, 3, 4, 4, 4, 0, 0, 0, 0, 0, 4, 0, 4, 1, 1, 1, 1, 1, 4, 1, 4, 2, 2, 2, 2, 2, 4, 2, 4, 3, 3, 3, 3, 3, 4, 3, 4, 0, 0, 0, 0, 0, 4, 0, 0, 1, 1, 1, 1, 1, 4, 1, 1, 2, 2, 2, 2, 2, 4, 2, 2, 3, 3, 3, 3, 3, 4, 3, 3, 0, 0, 0, 0, 0, 4, 0, 0, 1, 1, 1, 1, 1, 4, 1, 1, 2, 2, 2, 2, 2, 4, 2, 2, 3, 3, 3, 3, 3, 4, 3, 3 },
    .{ 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 1, 4, 0, 0, 0, 0, 0, 0, 2, 4, 0, 0, 0, 0, 0, 0, 3, 4, 1, 1, 1, 1, 1, 1, 4, 4, 1, 1, 1, 1, 1, 1, 4, 4, 1, 1, 1, 1, 1, 1, 4, 4, 1, 1, 1, 1, 1, 1, 4, 4, 2, 2, 2, 2, 2, 2, 4, 4, 2, 2, 2, 2, 2, 2, 4, 4, 2, 2, 2, 2, 2, 2, 4, 4, 2, 2, 2, 2, 2, 2, 4, 4, 3, 3, 3, 3, 3, 3, 4, 4, 3, 3, 3, 3, 3, 3, 4, 4, 3, 3, 3, 3, 3, 3, 4, 4, 3, 3, 3, 3, 3, 3, 4, 4 },
};

/// Decodes an integer sequence (trit/quint/binary) into `out`.
fn astcDecodeIntseq(
    buf: []const u8,
    offset: usize,
    a: usize,
    b: usize,
    count_in: usize,
    reverse: bool,
    out: []AstcIntSeqData,
) void {
    const mt = [_]usize{ 0, 2, 4, 5, 7 };
    const mq = [_]usize{ 0, 3, 5 };
    if (count_in == 0) return;
    const count = @min(count_in, out.len);

    var n: usize = 0;
    var p: i64 = @intCast(offset);
    switch (a) {
        3 => {
            const mask: u64 = (@as(u64, 1) << @intCast(b)) -% 1;
            const block_count = (count +% 4) / 5;
            const last_block_count = (count +% 4) % 5 +% 1;
            const block_size: i64 = 8 +% 5 * @as(i64, @intCast(b));
            const last_block_size: i64 = @divTrunc(block_size * @as(i64, @intCast(last_block_count)) +% 4, 5);

            if (reverse) {
                for (0..block_count) |i| {
                    const now_size: i64 = if (i < block_count -% 1) block_size else last_block_size;
                    const d = astcBitReverseU64(astcGetBits64(buf, p -% now_size, @intCast(now_size)), @intCast(now_size));
                    const x: usize = @intCast((d >> @intCast(b) & 3) |
                        (d >> @intCast(b *% 2) & 0xc) |
                        (d >> @intCast(b *% 3) & 0x10) |
                        (d >> @intCast(b *% 4) & 0x60) |
                        (d >> @intCast(b *% 5) & 0x80));
                    for (0..5) |j| {
                        if (n < count) {
                            out[n] = .{
                                .bits = (d >> @intCast(mt[j] +% b * j)) & mask,
                                .nonbits = astcTritsTable[j][x],
                            };
                            n += 1;
                        }
                    }
                    p -%=  block_size;
                }
            } else {
                for (0..block_count) |i| {
                    const now_size: i64 = if (i < block_count -% 1) block_size else last_block_size;
                    const d = astcGetBits64(buf, p, @intCast(now_size));
                    const x: usize = @intCast((d >> @intCast(b) & 3) |
                        (d >> @intCast(b *% 2) & 0xc) |
                        (d >> @intCast(b *% 3) & 0x10) |
                        (d >> @intCast(b *% 4) & 0x60) |
                        (d >> @intCast(b *% 5) & 0x80));
                    for (0..5) |j| {
                        if (n < count) {
                            out[n] = .{
                                .bits = (d >> @intCast(mt[j] +% b * j)) & mask,
                                .nonbits = astcTritsTable[j][x],
                            };
                            n += 1;
                        }
                    }
                    p += block_size;
                }
            }
        },
        5 => {
            const mask: u64 = (@as(u64, 1) << @intCast(b)) -% 1;
            const block_count = (count +% 2) / 3;
            const last_block_count = (count +% 2) % 3 +% 1;
            const block_size: i64 = 7 +% 3 * @as(i64, @intCast(b));
            const last_block_size: i64 = @divTrunc(block_size * @as(i64, @intCast(last_block_count)) +% 2, 3);

            if (reverse) {
                for (0..block_count) |i| {
                    const now_size: i64 = if (i < block_count -% 1) block_size else last_block_size;
                    const d = astcBitReverseU64(astcGetBits64(buf, p -% now_size, @intCast(now_size)), @intCast(now_size));
                    const x: usize = @intCast((d >> @intCast(b) & 7) |
                        (d >> @intCast(b *% 2) & 0x18) |
                        (d >> @intCast(b *% 3) & 0x60));
                    for (0..3) |j| {
                        if (n < count) {
                            out[n] = .{
                                .bits = (d >> @intCast(mq[j] +% b * j)) & mask,
                                .nonbits = astcQuintsTable[j][x],
                            };
                            n += 1;
                        }
                    }
                    p -%=  block_size;
                }
            } else {
                for (0..block_count) |i| {
                    const now_size: i64 = if (i < block_count -% 1) block_size else last_block_size;
                    const d = astcGetBits64(buf, p, @intCast(now_size));
                    const x: usize = @intCast((d >> @intCast(b) & 7) |
                        (d >> @intCast(b *% 2) & 0x18) |
                        (d >> @intCast(b *% 3) & 0x60));
                    for (0..3) |j| {
                        if (n < count) {
                            out[n] = .{
                                .bits = (d >> @intCast(mq[j] +% b * j)) & mask,
                                .nonbits = astcQuintsTable[j][x],
                            };
                            n += 1;
                        }
                    }
                    p += block_size;
                }
            }
        },
        else => {
            if (reverse) {
                p -%=  @as(i64, @intCast(b));
                while (n < count) : (n += 1) {
                    out[n] = .{
                        .bits = astcBitReverseU8(@intCast(astcGetBits(buf, @intCast(std.math.clamp(p, 0, 128)), @min(b, 8))), @intCast(@min(b, 8))),
                        .nonbits = 0,
                    };
                    p -%=  @as(i64, @intCast(b));
                }
            } else {
                while (n < count) : (n += 1) {
                    out[n] = .{
                        .bits = @intCast(astcGetBits(buf, @intCast(p), b)),
                        .nonbits = 0,
                    };
                    p += @as(i64, @intCast(b));
                }
            }
        },
    }
}

fn astcDecodeBlockParams(buf: []const u8, data: *AstcBlockData) void {
    data.dual_plane = (buf[1] & 4) != 0;
    data.weight_range = @intCast(((buf[0] >> 4) & 1) | ((buf[1] << @intCast(2)) & 8));
    const u16v = std.mem.readInt(u16, buf[0..2], .little);

    if (buf[0] & 3 != 0) {
        data.weight_range |= @intCast((buf[0] << @intCast(1)) & 6);
        switch (buf[0] & 0xc) {
            0 => {
                data.width = @intCast(((u16v >> 7) & 3) +% 4);
                data.height = @intCast(((buf[0] >> 5) & 3) +% 2);
            },
            4 => {
                data.width = @intCast(((u16v >> 7) & 3) +% 8);
                data.height = @intCast(((buf[0] >> 5) & 3) +% 2);
            },
            8 => {
                data.width = @intCast(((buf[0] >> 5) & 3) +% 2);
                data.height = @intCast(((u16v >> 7) & 3) +% 8);
            },
            12 => {
                if (buf[1] & 1 != 0) {
                    data.width = @intCast(((buf[0] >> 7) & 1) +% 2);
                    data.height = @intCast(((buf[0] >> 5) & 3) +% 2);
                } else {
                    data.width = @intCast(((buf[0] >> 5) & 3) +% 2);
                    data.height = @intCast(((buf[0] >> 7) & 1) +% 6);
                }
            },
            else => {},
        }
    } else {
        data.weight_range |= @intCast((buf[0] >> 1) & 6);
        switch (u16v & 0x180) {
            0 => {
                data.width = 12;
                data.height = @intCast(((buf[0] >> 5) & 3) +% 2);
            },
            0x80 => {
                data.width = @intCast(((buf[0] >> 5) & 3) +% 2);
                data.height = 12;
            },
            0x100 => {
                data.width = @intCast(((buf[0] >> 5) & 3) +% 6);
                data.height = @intCast(((buf[1] >> 1) & 3) +% 6);
                data.dual_plane = false;
                data.weight_range &= 7;
            },
            0x180 => {
                data.width = if (buf[0] & 0x20 != 0) 10 else 6;
                data.height = if (buf[0] & 0x20 != 0) 6 else 10;
            },
            else => {},
        }
    }

    data.part_num = @intCast(((buf[1] >> 3) & 3) +% 1);
    data.weight_num = data.width *% data.height;
    if (data.dual_plane) data.weight_num *%=  2;

    const weight_bits: i64 = switch (astcWeightPrecA[data.weight_range]) {
        3 => @as(i64, @intCast(data.weight_num)) *% astcWeightPrecB[data.weight_range] +
            @divTrunc(@as(i64, @intCast(data.weight_num)) *% 8 + 4, 5),
        5 => @as(i64, @intCast(data.weight_num)) *% astcWeightPrecB[data.weight_range] +
            @divTrunc(@as(i64, @intCast(data.weight_num)) *% 7 + 2, 3),
        else => @as(i64, @intCast(data.weight_num)) *% astcWeightPrecB[data.weight_range],
    };

    var cem_base: usize = 0;
    if (data.part_num == 1) {
        data.cem[0] = @intCast((std.mem.readInt(u16, buf[1..3], .little) >> 5) & 0xf);
    } else {
        cem_base = @intCast((std.mem.readInt(u16, buf[2..4], .little) >> 7) & 3);
        if (cem_base == 0) {
            const cem: usize = @intCast((buf[3] >> 1) & 0xf);
            for (0..data.part_num) |i| data.cem[i] = cem;
        } else {
            for (0..data.part_num) |i| {
                data.cem[i] = (((buf[3] >> @intCast(i +% 1)) & 1) +% cem_base -% 1) << 2;
            }
            switch (data.part_num) {
                2 => {
                    data.cem[0] |= @intCast((buf[3] >> 3) & 3);
                    data.cem[1] |= @intCast(astcGetBits(buf, 126 -% @as(usize, @intCast(weight_bits)), 2));
                },
                3 => {
                    data.cem[0] |= @intCast((buf[3] >> 4) & 1);
                    data.cem[0] |= @intCast(astcGetBits(buf, 122 -% @as(usize, @intCast(weight_bits)), 2) & 2);
                    data.cem[1] |= @intCast(astcGetBits(buf, 124 -% @as(usize, @intCast(weight_bits)), 2));
                    data.cem[2] |= @intCast(astcGetBits(buf, 126 -% @as(usize, @intCast(weight_bits)), 2));
                },
                4 => {
                    for (0..4) |i| {
                        data.cem[i] |= @intCast(astcGetBits(buf, 120 +% i * 2 -% @as(usize, @intCast(weight_bits)), 2));
                    }
                },
                else => {},
            }
        }
    }

    // total config bits (incl. dual-plane selector) to know where
    // endpoints start
    var config_bits: usize = if (data.part_num == 1) 17 else (if (cem_base == 0) 29 else 25 +% data.part_num *% 3);
    if (data.dual_plane) {
        config_bits += 2;
        data.plane_selector = @intCast(astcGetBits(
            buf,
            if (cem_base != 0)
                130 -% @as(usize, @intCast(weight_bits)) -% data.part_num *% 3
            else
                126 -% @as(usize, @intCast(weight_bits)),
            2,
        ));
    }

    const remain_bits = 128 -% config_bits -% @as(usize, @intCast(weight_bits));
    if (remain_bits > 128) return; // corrupt block: config +% weight bits exceed 128
    data.endpoint_value_num = 0;
    for (0..data.part_num) |i| {
        data.endpoint_value_num += ((data.cem[i] >> 1) & 6) +% 2;
    }

    for (0..astcCemA.len) |i| {
        const endpoint_bits: i64 = switch (astcCemA[i]) {
            3 => @as(i64, @intCast(data.endpoint_value_num)) * @as(i64, @intCast(astcCemB[i])) +
                @divTrunc(@as(i64, @intCast(data.endpoint_value_num)) *% 8 + 4, 5),
            5 => @as(i64, @intCast(data.endpoint_value_num)) * @as(i64, @intCast(astcCemB[i])) +
                @divTrunc(@as(i64, @intCast(data.endpoint_value_num)) *% 7 + 2, 3),
            else => @as(i64, @intCast(data.endpoint_value_num)) * @as(i64, @intCast(astcCemB[i])),
        };
        if (endpoint_bits <= @as(i64, @intCast(remain_bits))) {
            data.cem_range = i;
            break;
        }
    }
}

/// Clamps endpoint values into [0, 0xfff] (HDR endpoint range).
fn astcSetEndpointHdrClamp(e: *[8]i32, r1: i32, g1: i32, b1: i32, a1: i32, r2: i32, g2: i32, b2: i32, a2: i32) void {
    e[0] = std.math.clamp(r1, 0, 0xfff);
    e[1] = std.math.clamp(g1, 0, 0xfff);
    e[2] = std.math.clamp(b1, 0, 0xfff);
    e[3] = std.math.clamp(a1, 0, 0xfff);
    e[4] = std.math.clamp(r2, 0, 0xfff);
    e[5] = std.math.clamp(g2, 0, 0xfff);
    e[6] = std.math.clamp(b2, 0, 0xfff);
    e[7] = std.math.clamp(a2, 0, 0xfff);
}

fn astcSetEndpointHdr(e: *[8]i32, r1: i32, g1: i32, b1: i32, a1: i32, r2: i32, g2: i32, b2: i32, a2: i32) void {
    e[0] = r1;
    e[1] = g1;
    e[2] = b1;
    e[3] = a1;
    e[4] = r2;
    e[5] = g2;
    e[6] = b2;
    e[7] = a2;
}

fn astcSetEndpoint(e: *[8]i32, r1: i32, g1: i32, b1: i32, a1: i32, r2: i32, g2: i32, b2: i32, a2: i32) void {
    e[0] = r1;
    e[1] = g1;
    e[2] = b1;
    e[3] = a1;
    e[4] = r2;
    e[5] = g2;
    e[6] = b2;
    e[7] = a2;
}

fn astcSetEndpointClamp(e: *[8]i32, r1: i32, g1: i32, b1: i32, a1: i32, r2: i32, g2: i32, b2: i32, a2: i32) void {
    e[0] = std.math.clamp(r1, 0, 255);
    e[1] = std.math.clamp(g1, 0, 255);
    e[2] = std.math.clamp(b1, 0, 255);
    e[3] = std.math.clamp(a1, 0, 255);
    e[4] = std.math.clamp(r2, 0, 255);
    e[5] = std.math.clamp(g2, 0, 255);
    e[6] = std.math.clamp(b2, 0, 255);
    e[7] = std.math.clamp(a2, 0, 255);
}

fn astcSetEndpointBlue(e: *[8]i32, r1: i32, g1: i32, b1: i32, a1: i32, r2: i32, g2: i32, b2: i32, a2: i32) void {
    e[0] = (r1 +% b1) >> 1;
    e[1] = (g1 +% b1) >> 1;
    e[2] = b1;
    e[3] = a1;
    e[4] = (r2 +% b2) >> 1;
    e[5] = (g2 +% b2) >> 1;
    e[6] = b2;
    e[7] = a2;
}

fn astcSetEndpointBlueClamp(e: *[8]i32, r1: i32, g1: i32, b1: i32, a1: i32, r2: i32, g2: i32, b2: i32, a2: i32) void {
    e[0] = std.math.clamp((r1 +% b1) >> 1, 0, 255);
    e[1] = std.math.clamp((g1 +% b1) >> 1, 0, 255);
    e[2] = std.math.clamp(b1, 0, 255);
    e[3] = std.math.clamp(a1, 0, 255);
    e[4] = std.math.clamp((r2 +% b2) >> 1, 0, 255);
    e[5] = std.math.clamp((g2 +% b2) >> 1, 0, 255);
    e[6] = std.math.clamp(b2, 0, 255);
    e[7] = std.math.clamp(a2, 0, 255);
}

/// LDR endpoint interpolation: (v0*257*(64-w) +% v1*257*w +% 32) >> 6, then
/// scaled to 0..255.
fn astcSelectColor(v0: i32, v1: i32, weight: i32) u8 {
    const t: i32 = ((std.math.shl(@TypeOf(v0), v0, 8) | v0) *% (64 -% weight) +% (std.math.shl(@TypeOf(v1), v1, 8) | v1) *% weight +% 32) >> 6;
    return @truncate(@as(u32, @bitCast(@divTrunc(t *% 255 +% 32768, 65536))));
}

/// HDR endpoint interpolation with an fp16 intermediate.
/// Corrupt weight grids can yield weights outside 0..64; clamp the weight
/// and truncate the sum so garbage input degrades instead of panicking
/// (same hardening the LDR path received).
fn astcSelectColorHdr(v0: i32, v1: i32, weight: i32) u8 {
    const w: i32 = std.math.clamp(weight, 0, 64);
    const c: u16 = @truncate(@as(u32, @bitCast(((std.math.shl(@TypeOf(v0), v0, 4)) *% (64 -% w) +% (std.math.shl(@TypeOf(v1), v1, 4)) *% w +% 32) >> 6)));
    var m: u32 = c & 0x7ff;
    if (m < 512) {
        m *%= 3;
    } else if (m < 1536) {
        m = 4 *% m -% 512;
    } else {
        m = m *% 5 -% 2048;
    }
    const half: u16 = @intCast(((c >> 1) & 0x7c00) | (m >> 3));
    const f: f32 = @floatCast(@as(f16, @bitCast(half)));
    if (std.math.isFinite(f)) {
        return @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(f * 255.0))), 0, 255));
    } else {
        return 255;
    }
}

fn astcF32ToU8(f: f32) u8 {
    // Clamp before the conversion, not after: HDR void-extent blocks carry
    // raw f16s from the file, and @intFromFloat on an Inf (half bits 0x7c00)
    // or a NaN is illegal behavior rather than a clamp. Same positive-form
    // guard as floatToByte, so a NaN takes the 0 branch.
    if (!(f > 0)) return 0;
    if (f >= 1) return 255;
    return @intFromFloat(@round(f * 255.0));
}

fn astcF16PtrToU8(ptr: []const u8) u8 {
    const h: u16 = std.mem.readInt(u16, ptr[0..2], .little);
    const f: f32 = @floatCast(@as(f16, @bitCast(h)));
    return astcF32ToU8(f);
}

/// Moves the low bit of `v[a]` into the top of `v[b]` and sign-extends
/// the remaining bits of `v[a]`.
fn astcBitTransferSigned(v: []i32, a: usize, b: usize) void {
    v[b] = (v[b] >> 1) | (v[a] & 0x80);
    v[a] = (v[a] >> 1) & 0x3f;
    if (v[a] & 0x20 != 0) v[a] -= 0x40;
}

fn astcDecodeEndpointsHdr7(endpoints: *[8]i32, v: []i32) void {
    const modeval = (v[2] >> 4 & 0x8) | (v[1] >> 5 & 0x4) | (v[0] >> 6);
    var major_component: i32 = undefined;
    var mode: i32 = undefined;
    if ((modeval & 0xc) != 0xc) {
        major_component = modeval >> 2;
        mode = modeval & 3;
    } else if (modeval != 0xf) {
        major_component = modeval & 3;
        mode = 4;
    } else {
        major_component = 0;
        mode = 5;
    }
    var c = [4]i32{ v[0] & 0x3f, v[1] & 0x1f, v[2] & 0x1f, v[3] & 0x1f };

    switch (mode) {
        0 => {
            c[3] |= v[3] & 0x60;
            c[0] |= (v[3] >> 1) & 0x40;
            c[0] |= (v[2] << 1) & 0x80;
            c[0] |= (v[1] << 3) & 0x300;
            c[0] |= (v[2] << 5) & 0x400;
        },
        1 => {
            c[1] |= v[1] & 0x20;
            c[2] |= v[2] & 0x20;
            c[0] |= (v[3] >> 1) & 0x40;
            c[0] |= (v[2] << 1) & 0x80;
            c[0] |= (v[1] << 2) & 0x100;
            c[0] |= (v[3] << 4) & 0x600;
        },
        2 => {
            c[3] |= v[3] & 0xe0;
            c[0] |= (v[2] << 1) & 0xc0;
            c[0] |= (v[1] << 3) & 0x300;
        },
        3 => {
            c[1] |= v[1] & 0x20;
            c[2] |= v[2] & 0x20;
            c[3] |= v[3] & 0x60;
            c[0] |= (v[3] >> 1) & 0x40;
            c[0] |= (v[2] << 1) & 0x80;
            c[0] |= (v[1] << 2) & 0x100;
        },
        4 => {
            c[1] |= v[1] & 0x60;
            c[2] |= v[2] & 0x60;
            c[3] |= v[3] & 0x20;
            c[0] |= (v[3] >> 1) & 0x40;
            c[0] |= (v[3] << 1) & 0x80;
        },
        5 => {
            c[1] |= v[1] & 0x60;
            c[2] |= v[2] & 0x60;
            c[3] |= v[3] & 0x60;
            c[0] |= (v[3] >> 1) & 0x40;
        },
        else => {},
    }
    // per-mode left shift: 1,1,2,3,4,5 (mode 0 and 1 both shift by one)
    const shift: u3 = switch (mode) {
        0, 1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        else => 5,
    };
    c[0] <<= shift;
    c[1] <<= shift;
    c[2] <<= shift;
    c[3] <<= shift;
    if (mode != 5) {
        c[1] = c[0] -% c[1];
        c[2] = c[0] -% c[2];
    }
    switch (major_component) {
        1 => astcSetEndpointHdrClamp(endpoints, c[1] -% c[3], c[0] -% c[3], c[2] -% c[3], 0x780, c[1], c[0], c[2], 0x780),
        2 => astcSetEndpointHdrClamp(endpoints, c[2] -% c[3], c[1] -% c[3], c[0] -% c[3], 0x780, c[2], c[1], c[0], 0x780),
        else => astcSetEndpointHdrClamp(endpoints, c[0] -% c[3], c[1] -% c[3], c[2] -% c[3], 0x780, c[0], c[1], c[2], 0x780),
    }
}

fn astcDecodeEndpointsHdr11(endpoints: *[8]i32, v: []i32, alpha1: i32, alpha2: i32) void {
    const major_component = (v[4] >> 7) | ((v[5] >> 6) & 2);
    if (major_component == 3) {
        astcSetEndpointHdr(
            endpoints,
            v[0] << 4,
            v[2] << 4,
            (v[4] << 5) & 0xfe0,
            alpha1,
            v[1] << 4,
            v[3] << 4,
            (v[5] << 5) & 0xfe0,
            alpha2,
        );
        return;
    }
    const mode = (v[1] >> 7) | ((v[2] >> 6) & 2) | ((v[3] >> 5) & 4);
    var va = v[0] | ((v[1] << 2) & 0x100);
    var vb0 = v[2] & 0x3f;
    var vb1 = v[3] & 0x3f;
    var vc = v[1] & 0x3f;
    var vd0: i32 = undefined;
    var vd1: i32 = undefined;

    switch (mode) {
        0, 2 => {
            vd0 = v[4] & 0x7f;
            if (vd0 & 0x40 != 0) vd0 |= -128;
            vd1 = v[5] & 0x7f;
            if (vd1 & 0x40 != 0) vd1 |= -128;
        },
        1, 3, 5, 7 => {
            vd0 = v[4] & 0x3f;
            if (vd0 & 0x20 != 0) vd0 |= -64;
            vd1 = v[5] & 0x3f;
            if (vd1 & 0x20 != 0) vd1 |= -64;
        },
        else => {
            vd0 = v[4] & 0x1f;
            if (vd0 & 0x10 != 0) vd0 |= -32;
            vd1 = v[5] & 0x1f;
            if (vd1 & 0x10 != 0) vd1 |= -32;
        },
    }

    switch (mode) {
        0 => {
            vb0 |= v[2] & 0x40;
            vb1 |= v[3] & 0x40;
        },
        1 => {
            vb0 |= v[2] & 0x40;
            vb1 |= v[3] & 0x40;
            vb0 |= (v[4] << 1) & 0x80;
            vb1 |= (v[5] << 1) & 0x80;
        },
        2 => {
            va |= (v[2] << 3) & 0x200;
            vc |= v[3] & 0x40;
        },
        3 => {
            va |= (v[4] << 3) & 0x200;
            vc |= v[5] & 0x40;
            vb0 |= v[2] & 0x40;
            vb1 |= v[3] & 0x40;
        },
        4 => {
            va |= (v[4] << 4) & 0x200;
            va |= (v[5] << 5) & 0x400;
            vb0 |= v[2] & 0x40;
            vb1 |= v[3] & 0x40;
            vb0 |= (v[4] << 1) & 0x80;
            vb1 |= (v[5] << 1) & 0x80;
        },
        5 => {
            va |= (v[2] << 3) & 0x200;
            va |= (v[3] << 4) & 0x400;
            vc |= v[5] & 0x40;
            vc |= (v[4] << 1) & 0x80;
        },
        6 => {
            va |= (v[4] << 4) & 0x200;
            va |= (v[5] << 5) & 0x400;
            va |= (v[4] << 5) & 0x800;
            vc |= v[5] & 0x40;
            vb0 |= v[2] & 0x40;
            vb1 |= v[3] & 0x40;
        },
        7 => {
            va |= (v[2] << 3) & 0x200;
            va |= (v[3] << 4) & 0x400;
            va |= (v[4] << 5) & 0x800;
            vc |= v[5] & 0x40;
        },
        else => {},
    }

    const shamt = (mode >> 1) ^ 3;
    const mult: i32 = std.math.shl(i32, 1, shamt);
    va = std.math.shl(@TypeOf(va), va, shamt);
    vb0 = std.math.shl(@TypeOf(vb0), vb0, shamt);
    vb1 = std.math.shl(@TypeOf(vb1), vb1, shamt);
    vc = std.math.shl(@TypeOf(vc), vc, shamt);
    vd0 *%=  mult;
    vd1 *%=  mult;

    switch (major_component) {
        1 => astcSetEndpointHdrClamp(endpoints, va -% vb0 -% vc -% vd0, va -% vc, va -% vb1 -% vc -% vd1, alpha1, va -% vb0, va, va -% vb1, alpha2),
        2 => astcSetEndpointHdrClamp(endpoints, va -% vb1 -% vc -% vd1, va -% vb0 -% vc -% vd0, va -% vc, alpha1, va -% vb1, va -% vb0, va, alpha2),
        else => astcSetEndpointHdrClamp(endpoints, va -% vc, va -% vb0 -% vc -% vd0, va -% vb1 -% vc -% vd1, alpha1, va, va -% vb0, va -% vb1, alpha2),
    }
}

fn astcDecodeEndpoints(buf: []const u8, data: *AstcBlockData) void {
    const trits_table = [_]usize{ 0, 204, 93, 44, 22, 11, 5 };
    const quints_table = [_]usize{ 0, 113, 54, 26, 13, 6 };
    var seq: [32]AstcIntSeqData = undefined;
    var ev: [32]i32 = undefined;
    astcDecodeIntseq(
        buf,
        if (data.part_num == 1) 17 else 29,
        astcCemA[data.cem_range],
        astcCemB[data.cem_range],
        data.endpoint_value_num,
        false,
        &seq,
    );

    switch (astcCemA[data.cem_range]) {
        3 => {
            var b: u64 = 0;
            const c = trits_table[astcCemB[data.cem_range]];
            for (0..data.endpoint_value_num) |i| {
                const a = (seq[i].bits & 1) *% 0x1ff;
                const x = seq[i].bits >> 1;
                switch (astcCemB[data.cem_range]) {
                    1 => b = 0,
                    2 => b = 0b100010110 *% x,
                    3 => b = (std.math.shl(@TypeOf(x), x, 7)) | (std.math.shl(@TypeOf(x), x, 2)) | x,
                    4 => b = (std.math.shl(@TypeOf(x), x, 6)) | x,
                    5 => b = (std.math.shl(@TypeOf(x), x, 5)) | (x >> 2),
                    6 => b = (std.math.shl(@TypeOf(x), x, 4)) | (x >> 4),
                    else => {},
                }
                ev[i] = @intCast((a & 0x80) | (((seq[i].nonbits * @as(u64, c) +% b) ^ a) >> 2));
            }
        },
        5 => {
            var b: u64 = 0;
            const c = quints_table[astcCemB[data.cem_range]];
            for (0..data.endpoint_value_num) |i| {
                const a = (seq[i].bits & 1) *% 0x1ff;
                const x = seq[i].bits >> 1;
                switch (astcCemB[data.cem_range]) {
                    1 => b = 0,
                    2 => b = 0b100001100 *% x,
                    3 => b = (std.math.shl(@TypeOf(x), x, 7)) | (std.math.shl(@TypeOf(x), x, 1)) | (x >> 1),
                    4 => b = (std.math.shl(@TypeOf(x), x, 6)) | (x >> 1),
                    5 => b = (std.math.shl(@TypeOf(x), x, 5)) | (x >> 3),
                    else => {},
                }
                ev[i] = @intCast((a & 0x80) | (((seq[i].nonbits * @as(u64, c) +% b) ^ a) >> 2));
            }
        },
        else => switch (astcCemB[data.cem_range]) {
            1 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast(seq[i].bits *% 0xff);
            },
            2 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast(seq[i].bits *% 0x55);
            },
            3 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 5)) | (std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 2)) | (seq[i].bits >> 1));
            },
            4 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 4)) | seq[i].bits);
            },
            5 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 3)) | (seq[i].bits >> 2));
            },
            6 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 2)) | (seq[i].bits >> 4));
            },
            7 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 1)) | (seq[i].bits >> 6));
            },
            8 => for (0..data.endpoint_value_num) |i| {
                ev[i] = @intCast(seq[i].bits);
            },
            else => {},
        },
    }

    var v: []i32 = &ev;
    var offset: usize = 0;
    for (0..data.part_num) |cem_i| {
        const cem = data.cem[cem_i];
        const vv = v[offset..][0..8];
        switch (cem) {
            0 => astcSetEndpoint(&data.endpoints[cem_i], vv[0], vv[0], vv[0], 255, vv[1], vv[1], vv[1], 255),
            1 => {
                const l0 = (vv[0] >> 2) | (vv[1] & 0xc0);
                const l1 = std.math.clamp(l0 +% (vv[1] & 0x3f), 0, 255);
                astcSetEndpoint(&data.endpoints[cem_i], l0, l0, l0, 255, l1, l1, l1, 255);
            },
            2 => {
                const y0: i32 = if (vv[0] <= vv[1]) vv[0] << 4 else (vv[1] << 4) +% 8;
                const y1: i32 = if (vv[0] <= vv[1]) vv[1] << 4 else (vv[0] << 4) -% 8;
                astcSetEndpointHdr(&data.endpoints[cem_i], y0, y0, y0, 0x780, y1, y1, y1, 0x780);
            },
            3 => {
                const y0: i32 = if (vv[0] & 0x80 != 0)
                    ((vv[1] & 0xe0) << 4) | ((vv[0] & 0x7f) << 2)
                else
                    ((vv[1] & 0xf0) << 4) | ((vv[0] & 0x7f) << 1);
                const d: i32 = if (vv[0] & 0x80 != 0) (vv[1] & 0x1f) << 2 else (vv[1] & 0x0f) << 1;
                const y1 = std.math.clamp(y0 +% d, 0, 0xfff);
                astcSetEndpointHdr(&data.endpoints[cem_i], y0, y0, y0, 0x780, y1, y1, y1, 0x780);
            },
            4 => astcSetEndpoint(&data.endpoints[cem_i], vv[0], vv[0], vv[0], vv[2], vv[1], vv[1], vv[1], vv[3]),
            5 => {
                astcBitTransferSigned(v, offset +% 1, offset +% 0);
                astcBitTransferSigned(v, offset +% 3, offset +% 2);
                v[offset +% 1] += v[offset +% 0];
                astcSetEndpointClamp(&data.endpoints[cem_i], v[offset +% 0], v[offset +% 0], v[offset +% 0], v[offset +% 2], v[offset +% 1], v[offset +% 1], v[offset +% 1], v[offset +% 2] +% v[offset +% 3]);
            },
            6 => astcSetEndpoint(&data.endpoints[cem_i], (vv[0] *% vv[3]) >> 8, (vv[1] *% vv[3]) >> 8, (vv[2] *% vv[3]) >> 8, 255, vv[0], vv[1], vv[2], 255),
            7 => astcDecodeEndpointsHdr7(&data.endpoints[cem_i], v[offset..]),
            8 => {
                if (vv[0] +% vv[2] +% vv[4] <= vv[1] +% vv[3] +% vv[5]) {
                    astcSetEndpoint(&data.endpoints[cem_i], vv[0], vv[2], vv[4], 255, vv[1], vv[3], vv[5], 255);
                } else {
                    astcSetEndpointBlue(&data.endpoints[cem_i], vv[1], vv[3], vv[5], 255, vv[0], vv[2], vv[4], 255);
                }
            },
            9 => {
                astcBitTransferSigned(v, offset +% 1, offset +% 0);
                astcBitTransferSigned(v, offset +% 3, offset +% 2);
                astcBitTransferSigned(v, offset +% 5, offset +% 4);
                if (v[offset +% 1] +% v[offset +% 3] +% v[offset +% 5] >= 0) {
                    astcSetEndpointClamp(&data.endpoints[cem_i], v[offset +% 0], v[offset +% 2], v[offset +% 4], 255, v[offset +% 0] +% v[offset +% 1], v[offset +% 2] +% v[offset +% 3], v[offset +% 4] +% v[offset +% 5], 255);
                } else {
                    astcSetEndpointBlueClamp(&data.endpoints[cem_i], v[offset +% 0] +% v[offset +% 1], v[offset +% 2] +% v[offset +% 3], v[offset +% 4] +% v[offset +% 5], 255, v[offset +% 0], v[offset +% 2], v[offset +% 4], 255);
                }
            },
            10 => astcSetEndpoint(&data.endpoints[cem_i], (vv[0] *% vv[3]) >> 8, (vv[1] *% vv[3]) >> 8, (vv[2] *% vv[3]) >> 8, vv[4], vv[0], vv[1], vv[2], vv[5]),
            11 => astcDecodeEndpointsHdr11(&data.endpoints[cem_i], v[offset..], 0x780, 0x780),
            12 => {
                if (vv[0] +% vv[2] +% vv[4] <= vv[1] +% vv[3] +% vv[5]) {
                    astcSetEndpoint(&data.endpoints[cem_i], vv[0], vv[2], vv[4], vv[6], vv[1], vv[3], vv[5], vv[7]);
                } else {
                    astcSetEndpointBlue(&data.endpoints[cem_i], vv[1], vv[3], vv[5], vv[7], vv[0], vv[2], vv[4], vv[6]);
                }
            },
            13 => {
                astcBitTransferSigned(v, offset +% 1, offset +% 0);
                astcBitTransferSigned(v, offset +% 3, offset +% 2);
                astcBitTransferSigned(v, offset +% 5, offset +% 4);
                astcBitTransferSigned(v, offset +% 7, offset +% 6);
                if (v[offset +% 1] +% v[offset +% 3] +% v[offset +% 5] >= 0) {
                    astcSetEndpointClamp(&data.endpoints[cem_i], v[offset +% 0], v[offset +% 2], v[offset +% 4], v[offset +% 6], v[offset +% 0] +% v[offset +% 1], v[offset +% 2] +% v[offset +% 3], v[offset +% 4] +% v[offset +% 5], v[offset +% 6] +% v[offset +% 7]);
                } else {
                    astcSetEndpointBlueClamp(&data.endpoints[cem_i], v[offset +% 0] +% v[offset +% 1], v[offset +% 2] +% v[offset +% 3], v[offset +% 4] +% v[offset +% 5], v[offset +% 6] +% v[offset +% 7], v[offset +% 0], v[offset +% 2], v[offset +% 4], v[offset +% 6]);
                }
            },
            14 => astcDecodeEndpointsHdr11(&data.endpoints[cem_i], v[offset..], vv[6], vv[7]),
            15 => {
                const mode = (vv[6] >> 7 & 1) | (vv[7] >> 6 & 2);
                v[offset +% 6] &= 0x7f;
                v[offset +% 7] &= 0x7f;
                if (mode == 3) {
                    astcDecodeEndpointsHdr11(&data.endpoints[cem_i], v[offset..], v[offset +% 6] << 5, v[offset +% 7] << 5);
                } else {
                    v[offset +% 6] |= (v[offset +% 7] << @intCast(mode +% 1)) & 0x780;
                    v[offset +% 7] = ((v[offset +% 7] & (@as(i32, 0x3f) >> @intCast(mode))) ^ (@as(i32, 0x20) >> @intCast(mode))) -% (@as(i32, 0x20) >> @intCast(mode));
                    v[offset +% 6] <<= @intCast(4 -% mode);
                    v[offset +% 7] <<= @intCast(4 -% mode);
                    astcDecodeEndpointsHdr11(&data.endpoints[cem_i], v[offset..], v[offset +% 6], std.math.clamp(v[offset +% 6] +% v[offset +% 7], 0, 0xfff));
                }
            },
            else => unreachable,
        }
        offset += (cem / 4 +% 1) *% 2;
    }
}

fn astcDecodeWeights(buf: []const u8, data: *AstcBlockData) void {
    var seq: [128]AstcIntSeqData = undefined;
    var wv: [128]i32 = undefined;
    astcDecodeIntseq(
        buf,
        128,
        @intCast(astcWeightPrecA[data.weight_range]),
        @intCast(astcWeightPrecB[data.weight_range]),
        data.weight_num,
        true,
        &seq,
    );

    if (astcWeightPrecA[data.weight_range] == 0) {
        switch (astcWeightPrecB[data.weight_range]) {
            1 => for (0..data.weight_num) |i| {
                wv[i] = if (seq[i].bits != 0) 63 else 0;
            },
            2 => for (0..data.weight_num) |i| {
                wv[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 4)) | (std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 2)) | seq[i].bits);
            },
            3 => for (0..data.weight_num) |i| {
                wv[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 3)) | seq[i].bits);
            },
            4 => for (0..data.weight_num) |i| {
                wv[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 2)) | (seq[i].bits >> 2));
            },
            5 => for (0..data.weight_num) |i| {
                wv[i] = @intCast((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 1)) | (seq[i].bits >> 4));
            },
            else => unreachable,
        }
        for (0..data.weight_num) |i| {
            if (wv[i] > 32) wv[i] += 1;
        }
    } else if (astcWeightPrecB[data.weight_range] == 0) {
        const s: i32 = if (astcWeightPrecA[data.weight_range] == 3) 32 else 16;
        for (0..data.weight_num) |i| wv[i] = @intCast(seq[i].nonbits * @as(u64, @intCast(s)));
    } else {
        if (astcWeightPrecA[data.weight_range] == 3) {
            switch (astcWeightPrecB[data.weight_range]) {
                1 => for (0..data.weight_num) |i| {
                    wv[i] = @intCast(seq[i].nonbits *% 50);
                },
                2 => for (0..data.weight_num) |i| {
                    wv[i] = @intCast(seq[i].nonbits *% 23);
                    if (seq[i].bits & 2 != 0) wv[i] += 0b1000101;
                },
                3 => for (0..data.weight_num) |i| {
                    wv[i] = @intCast(seq[i].nonbits *% 11 +% (((std.math.shl(@TypeOf(seq[i].bits), seq[i].bits, 4)) | (seq[i].bits >> 1)) & 0b1100011));
                },
                else => unreachable,
            }
        } else if (astcWeightPrecA[data.weight_range] == 5) {
            switch (astcWeightPrecB[data.weight_range]) {
                1 => for (0..data.weight_num) |i| {
                    wv[i] = @intCast(seq[i].nonbits *% 28);
                },
                2 => for (0..data.weight_num) |i| {
                    wv[i] = @intCast(seq[i].nonbits *% 13);
                    if (seq[i].bits & 2 != 0) wv[i] += 0b1000010;
                },
                else => unreachable,
            }
        }
        for (0..data.weight_num) |i| {
            const a = (seq[i].bits & 1) *% 0x7f;
            wv[i] = @intCast(((a & 0x20) | ((@as(u64, @intCast(wv[i])) ^ a) >> 2)));
            if (wv[i] > 32) wv[i] += 1;
        }
    }

    const ds = (1024 +% data.bw / 2) / (data.bw -% 1);
    const dt = (1024 +% data.bh / 2) / (data.bh -% 1);
    const pn: usize = if (data.dual_plane) 2 else 1;

    var i: usize = 0;
    for (0..data.bh) |t| {
        for (0..data.bw) |s| {
            const gs = (ds *% s * (data.width -% 1) +% 32) >> 6;
            const gt = (dt *% t * (data.height -% 1) +% 32) >> 6;
            const fs = gs & 0xf;
            const ft = gt & 0xf;
            const v = (gs >> 4) +% (gt >> 4) *% data.width;
            const w11: i32 = @intCast((fs *% ft +% 8) >> 4);
            const w10: i32 = @as(i32, @intCast(ft)) -% w11;
            const w01: i32 = @as(i32, @intCast(fs)) -% w11;
            const w00: i32 = 16 - @as(i32, @intCast(fs)) - @as(i32, @intCast(ft)) +% w11;

            for (0..pn) |p| {
                const p00 = wv[@min(v *% pn +% p, 127)];
                const p01 = wv[@min((v +% 1) *% pn +% p, 127)];
                const p10 = wv[@min((v +% data.width) *% pn +% p, 127)];
                const p11 = wv[@min((v +% data.width +% 1) *% pn +% p, 127)];
                data.weights[i][p] = (p00 *% w00 +% p01 *% w01 +% p10 *% w10 +% p11 *% w11 +% 8) >> 4;
            }
            i += 1;
        }
    }
}

fn astcSelectPartition(buf: []const u8, data: *AstcBlockData) void {
    const small_block = data.bw *% data.bh < 31;
    const seed: i32 = @as(i32, @bitCast((std.mem.readInt(u32, buf[0..4], .little) >> 13) & 0x3ff)) |
        @as(i32, @intCast(data.part_num -% 1)) << 10;

    var rnum: u32 = @as(u32, @bitCast(seed));
    rnum ^= rnum >> 15;
    rnum -%= std.math.shl(@TypeOf(rnum), rnum, 17);
    rnum +%= std.math.shl(@TypeOf(rnum), rnum, 7);
    rnum +%= std.math.shl(@TypeOf(rnum), rnum, 4);
    rnum ^= rnum >> 5;
    rnum +%= std.math.shl(@TypeOf(rnum), rnum, 16);
    rnum ^= rnum >> 7;
    rnum ^= rnum >> 3;
    rnum ^= std.math.shl(@TypeOf(rnum), rnum, 6);
    rnum ^= rnum >> 17;

    var seeds: [8]i32 = undefined;
    for (0..8) |i| {
        const v = (rnum >> @intCast(i *% 4)) & 0xf;
        seeds[i] = @as(i32, @intCast(v *% v));
    }
    const sh = [2]i32{ if (seed & 2 != 0) 4 else 5, if (data.part_num == 3) 6 else 5 };

    if (seed & 1 != 0) {
        for (0..8) |i| seeds[i] >>= @intCast(sh[i % 2]);
    } else {
        for (0..8) |i| seeds[i] >>= @intCast(sh[1 -% i % 2]);
    }

    var i: usize = 0;
    if (small_block) {
        for (0..data.bh) |t| {
            for (0..data.bw) |s| {
                const x: i32 = @intCast(std.math.shl(@TypeOf(s), s, 1));
                const y: i32 = @intCast(std.math.shl(@TypeOf(t), t, 1));
                const a = (seeds[0] *% x + seeds[1] *% y + @as(i32, @intCast(rnum >> 14))) & 0x3f;
                const b = (seeds[2] *% x + seeds[3] *% y + @as(i32, @intCast(rnum >> 10))) & 0x3f;
                const c: i32 = if (data.part_num < 3) 0 else (seeds[4] *% x + seeds[5] *% y + @as(i32, @intCast(rnum >> 6))) & 0x3f;
                const d: i32 = if (data.part_num < 4) 0 else (seeds[6] *% x + seeds[7] *% y + @as(i32, @intCast(rnum >> 2))) & 0x3f;
                data.partition[i] = partitionFromScores(a, b, c, d);
                i += 1;
            }
        }
    } else {
        for (0..data.bh) |y| {
            for (0..data.bw) |x| {
                const xi: i32 = @intCast(x);
                const yi: i32 = @intCast(y);
                const a = (seeds[0] *% xi +% seeds[1] *% yi + @as(i32, @intCast(rnum >> 14))) & 0x3f;
                const b = (seeds[2] *% xi +% seeds[3] *% yi + @as(i32, @intCast(rnum >> 10))) & 0x3f;
                const c: i32 = if (data.part_num < 3) 0 else (seeds[4] *% xi +% seeds[5] *% yi + @as(i32, @intCast(rnum >> 6))) & 0x3f;
                const d: i32 = if (data.part_num < 4) 0 else (seeds[6] *% xi +% seeds[7] *% yi + @as(i32, @intCast(rnum >> 2))) & 0x3f;
                data.partition[i] = partitionFromScores(a, b, c, d);
                i += 1;
            }
        }
    }
}

fn partitionFromScores(a: i32, b: i32, c: i32, d: i32) usize {
    if (a >= b and a >= c and a >= d) return 0;
    if (b >= c and b >= d) return 1;
    if (c >= d) return 2;
    return 3;
}

/// Applies endpoint interpolation per pixel and writes the block into the
/// output image (with edge clipping).
fn astcApplicateColor(data: *AstcBlockData, out: []u8, w: usize, h: usize, bx: usize, by: usize) void {
    // per-CEM color/alpha interpolation kind (LDR or HDR)
    const func_c = [16]bool{ false, false, true, true, false, false, false, true, false, false, false, true, false, false, true, true };
    const func_a = [16]bool{ false, false, true, true, false, false, false, true, false, false, false, true, false, false, false, true };

    for (0..data.bw *% data.bh) |i| {
        const s = i % data.bw;
        const t = i / data.bw;
        const p = if (data.part_num > 1) data.partition[i] else 0;
        const w0: i32 = data.weights[i][0];
        const w1: i32 = if (data.dual_plane) data.weights[i][1] else data.weights[i][0];
        const wr: i32 = if (data.dual_plane and data.plane_selector == 0) w1 else w0;
        const wg: i32 = if (data.dual_plane and data.plane_selector == 1) w1 else w0;
        const wb: i32 = if (data.dual_plane and data.plane_selector == 2) w1 else w0;
        const wa: i32 = if (data.dual_plane and data.plane_selector == 3) w1 else w0;

        const rr: u8 = if (func_c[data.cem[p]])
            astcSelectColorHdr(data.endpoints[p][0], data.endpoints[p][4], wr)
        else
            astcSelectColor(data.endpoints[p][0], data.endpoints[p][4], wr);
        const gg: u8 = if (func_c[data.cem[p]])
            astcSelectColorHdr(data.endpoints[p][1], data.endpoints[p][5], wg)
        else
            astcSelectColor(data.endpoints[p][1], data.endpoints[p][5], wg);
        const bb: u8 = if (func_c[data.cem[p]])
            astcSelectColorHdr(data.endpoints[p][2], data.endpoints[p][6], wb)
        else
            astcSelectColor(data.endpoints[p][2], data.endpoints[p][6], wb);
        const aa: u8 = if (func_a[data.cem[p]])
            astcSelectColorHdr(data.endpoints[p][3], data.endpoints[p][7], wa)
        else
            astcSelectColor(data.endpoints[p][3], data.endpoints[p][7], wa);

        const px = bx *% data.bw +% s;
        const py = by *% data.bh +% t;
        if (px >= w or py >= h) continue;
        const dst = out[(py *% w + px) *% 4 ..][0..4];
        dst[0] = rr;
        dst[1] = gg;
        dst[2] = bb;
        dst[3] = aa;
    }
}

fn astcFillBlock(out: []u8, w: usize, h: usize, bx: usize, by: usize, bw: usize, bh: usize, c: [4]u8) void {
    for (0..bh) |t| {
        for (0..bw) |s| {
            const px = bx *% bw +% s;
            const py = by *% bh +% t;
            if (px >= w or py >= h) continue;
            const dst = out[(py *% w + px) *% 4 ..][0..4];
            dst[0] = c[0];
            dst[1] = c[1];
            dst[2] = c[2];
            dst[3] = c[3];
        }
    }
}

fn astcDecodeBlock(out: []u8, w: usize, h: usize, bx: usize, by: usize, block: []const u8, bw: usize, bh: usize) void {
    if (block[0] == 0xfc and (block[1] & 1) == 1) {
        // void-extent block: a single constant color
        const c: [4]u8 = if (block[1] & 2 != 0)
            .{ astcF16PtrToU8(block[8..]), astcF16PtrToU8(block[10..]), astcF16PtrToU8(block[12..]), astcF16PtrToU8(block[14..]) }
        else
            .{ block[9], block[11], block[13], block[15] };
        astcFillBlock(out, w, h, bx, by, bw, bh, c);
        return;
    }
    if (((block[0] & 0xc3) == 0xc0 and (block[1] & 1) == 1) or (block[0] & 0xf) == 0) {
        // error block: magenta
        astcFillBlock(out, w, h, bx, by, bw, bh, .{ 255, 0, 255, 255 });
        return;
    }

    var data = AstcBlockData{
        .bw = bw,
        .bh = bh,
        .width = 0,
        .height = 0,
        .part_num = 0,
        .dual_plane = false,
        .plane_selector = 0,
        .weight_range = 0,
        .weight_num = 0,
        .cem = .{ 0, 0, 0, 0 },
        .cem_range = 0,
        .endpoint_value_num = 0,
        .endpoints = .{ .{0} ** 8, .{0} ** 8, .{0} ** 8, .{0} ** 8 },
        .weights = .{.{ 0, 0 }} ** 144,
        .partition = .{0} ** 144,
    };
    astcDecodeBlockParams(block, &data);
    astcDecodeEndpoints(block, &data);
    astcDecodeWeights(block, &data);
    if (data.part_num > 1) astcSelectPartition(block, &data);
    astcApplicateColor(&data, out, w, h, bx, by);
}

/// ASTC block size for a Unity ASTC format (48-59, 66-71), or null.
fn astcBlockSize(tex_format: i32) ?struct { bw: usize, bh: usize } {
    return switch (tex_format) {
        format.astc_rgb_4x4, format.astc_rgba_4x4, format.astc_hdr_4x4 => .{ .bw = 4, .bh = 4 },
        format.astc_rgb_5x5, format.astc_rgba_5x5, format.astc_hdr_5x5 => .{ .bw = 5, .bh = 5 },
        format.astc_rgb_6x6, format.astc_rgba_6x6, format.astc_hdr_6x6 => .{ .bw = 6, .bh = 6 },
        format.astc_rgb_8x8, format.astc_rgba_8x8, format.astc_hdr_8x8 => .{ .bw = 8, .bh = 8 },
        format.astc_rgb_10x10, format.astc_rgba_10x10, format.astc_hdr_10x10 => .{ .bw = 10, .bh = 10 },
        format.astc_rgb_12x12, format.astc_rgba_12x12, format.astc_hdr_12x12 => .{ .bw = 12, .bh = 12 },
        else => null,
    };
}

fn decodeAstc(out: []u8, w: usize, h: usize, data: []const u8, bw: usize, bh: usize) Error!void {
    const nbx = (w + bw - 1) / bw;
    const nby = (h + bh - 1) / bh;
    for (0..nby) |by| {
        for (0..nbx) |bx| {
            const block = data[(by * nbx + bx) * 16 ..][0..16];
            astcDecodeBlock(out, w, h, bx, by, block, bw, bh);
        }
    }
}

test "astc 4x4 block" {
    const a = std.testing.allocator;
    // random block, output cross-checked against UnityPy's C++ decoder
    var block = [_]u8{ 0x84, 0x94, 0x5f, 0x76, 0x4b, 0x73, 0x5f, 0x42, 0x24, 0x6d, 0x96, 0x0f, 0xdc, 0x40, 0x07, 0x8d };
    const out = try decode(a, format.astc_rgb_4x4, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 130, 255, 255 }, out[15 * 4 ..][0..4]);
}

test "astc 6x6 block" {
    const a = std.testing.allocator;
    // random block, output cross-checked against UnityPy's C++ decoder
    var block = [_]u8{ 0xc5, 0x28, 0xcf, 0x08, 0x9e, 0x9f, 0x62, 0x87, 0x12, 0xce, 0xd7, 0x90, 0x1e, 0xe0, 0xb1, 0xc7 };
    const out = try decode(a, format.astc_rgb_6x6, 6, 6, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 59, 59, 59, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 59, 59, 59, 255 }, out[35 * 4 ..][0..4]);
}

test "astc void-extent and error blocks" {
    const a = std.testing.allocator;
    // void-extent with 8-bit color: constant color from bytes 9,11,13,15
    var ve = [_]u8{ 0xfc, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x12, 0, 0x34, 0, 0x56, 0, 0x78 };
    const out1 = try decode(a, format.astc_rgb_4x4, 4, 4, &ve);
    defer a.free(out1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0x78 }, out1[0..4]);
    // error block: magenta
    var err = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const out2 = try decode(a, format.astc_rgb_4x4, 4, 4, &err);
    defer a.free(out2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 255, 255 }, out2[0..4]);
}

test "raw format rgba half" {
    const a = std.testing.allocator;
    // synthesized pixels; expected computed independently (clamp+truncate
    // for float/half, high byte for 16-bit, bias for signed)
    const data = [_]u8{
    0x38, 0x3c, 0xb8, 0x3a, 0xd4, 0xb4, 0x97, 0x32, 0x60, 0x3c, 0x20, 0xb6, 0x15, 0x3c, 0xe7, 0x3c, 
    0x56, 0x38, 0x7b, 0x35, 0x70, 0xab, 0xa9, 0xb3, 0xea, 0x37, 0x0a, 0x33, 0x8e, 0x3b, 0x4c, 0x36, 
    0x7a, 0x35, 0xcf, 0x3d, 0xd0, 0x39, 0x17, 0x3b, 0x76, 0x37, 0x38, 0x3d, 0x99, 0x38, 0x02, 0x3d, 
    0x2f, 0x32, 0x78, 0xa9, 0x9a, 0xb7, 0x72, 0x3d, 0xd9, 0x3c, 0x67, 0x3c, 0x80, 0x39, 0x19, 0x3d, 
    0x51, 0x38, 0xab, 0x3d, 0xc7, 0x31, 0x55, 0x3b, 0x78, 0xb0, 0x98, 0x37, 0x84, 0xb5, 0x5c, 0x38, 
    0xbc, 0x3a, 0xda, 0x3c, 0x2f, 0x9e, 0x57, 0xb5, 0x7c, 0x33, 0x04, 0xb7, 0xa4, 0xb0, 0x26, 0x36, 
};
    const out = try decode(a, format.rgba_half, 4, 3, &data);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{
    0xff, 0xd6, 0x00, 0x34, 0xff, 0x00, 0xff, 0xff, 0x8a, 0x57, 0x00, 0x00, 0x7e, 0x38, 0xf0, 0x64, 
    0x57, 0xff, 0xb9, 0xe1, 0x76, 0xff, 0x92, 0xff, 0x31, 0x00, 0x00, 0xff, 0xff, 0xff, 0xaf, 0xff, 
    0x89, 0xff, 0x2e, 0xe9, 0x00, 0x79, 0x00, 0x8a, 0xd6, 0xff, 0x00, 0x00, 0x3b, 0x00, 0x00, 0x61, 
}, out);
}

test "raw format rgb9e5" {
    const a = std.testing.allocator;
    // synthesized pixels; expected computed independently (clamp+truncate
    // for float/half, high byte for 16-bit, bias for signed)
    const data = [_]u8{
    0x65, 0x26, 0xa7, 0xdd, 0xca, 0xba, 0x08, 0x1e, 0xe2, 0x26, 0x15, 0xd2, 0x70, 0xc5, 0x69, 0xff, 
    0x6c, 0x80, 0x59, 0xd3, 0x98, 0x49, 0xcf, 0xf4, 0x39, 0xd4, 0x19, 0xb7, 0xb2, 0x7c, 0xd6, 0x12, 
    0x5c, 0xa5, 0xa0, 0xe1, 0x0c, 0xe6, 0x3f, 0x59, 0x55, 0x48, 0xf3, 0x7e, 0x03, 0x3f, 0xa0, 0xbe, 
};
    const out = try decode(a, format.rgb9e5, 4, 3, &data);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 
    0xff, 0xff, 0xff, 0xff, 0x00, 0x0f, 0x02, 0xff, 0x2a, 0xd1, 0xdd, 0xff, 0xff, 0xff, 0xff, 0xff, 
}, out);
}

test "raw format rgba64" {
    const a = std.testing.allocator;
    // synthesized pixels; expected computed independently (clamp+truncate
    // for float/half, high byte for 16-bit, bias for signed)
    const data = [_]u8{
    0xa2, 0xdb, 0xc2, 0x32, 0x87, 0xc9, 0xb8, 0xb4, 0x04, 0x1e, 0x64, 0x65, 0xbb, 0x2e, 0x2e, 0xc1, 
    0xae, 0xd7, 0x1f, 0x71, 0xa0, 0x49, 0xbb, 0x42, 0xa3, 0xfe, 0x50, 0xb8, 0x63, 0x71, 0x21, 0xed, 
    0x9d, 0xd7, 0x71, 0x36, 0x28, 0x60, 0x54, 0x6b, 0x5a, 0xf7, 0x5c, 0xcc, 0x33, 0xd2, 0xd2, 0x99, 
    0x78, 0xb1, 0x97, 0x1c, 0x10, 0x75, 0x30, 0xe3, 0x7f, 0x10, 0x1b, 0x59, 0x61, 0x9f, 0xcb, 0x5a, 
    0xe4, 0xe3, 0x3b, 0xae, 0x6c, 0x29, 0x75, 0x34, 0x42, 0x5c, 0x18, 0x06, 0x87, 0xf9, 0xba, 0x27, 
    0x74, 0x7e, 0x96, 0x2a, 0x49, 0xd2, 0x55, 0xde, 0xdd, 0xbb, 0xd9, 0x81, 0xc0, 0x0f, 0x11, 0xd4, 
};
    const out = try decode(a, format.rgba64, 4, 3, &data);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{
    0xdb, 0x32, 0xc9, 0xb4, 0x1e, 0x65, 0x2e, 0xc1, 0xd7, 0x71, 0x49, 0x42, 0xfe, 0xb8, 0x71, 0xed, 
    0xd7, 0x36, 0x60, 0x6b, 0xf7, 0xcc, 0xd2, 0x99, 0xb1, 0x1c, 0x75, 0xe3, 0x10, 0x59, 0x9f, 0x5a, 
    0xe3, 0xae, 0x29, 0x34, 0x5c, 0x06, 0xf9, 0x27, 0x7e, 0x2a, 0xd2, 0xde, 0xbb, 0x81, 0x0f, 0xd4, 
}, out);
}

test "raw format r16 signed" {
    const a = std.testing.allocator;
    // synthesized pixels; expected computed independently (clamp+truncate
    // for float/half, high byte for 16-bit, bias for signed)
    const data = [_]u8{
    0xa2, 0x5b, 0x04, 0x9e, 0xae, 0x57, 0xa3, 0x7e, 0x9d, 0x57, 0x5a, 0x77, 0x78, 0x31, 0x7f, 0x90, 
    0xe4, 0x63, 0x42, 0xdc, 0x74, 0xfe, 0xdd, 0x3b, 
};
    const out = try decode(a, format.r16_signed, 4, 3, &data);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{
    0xdb, 0xdb, 0xdb, 0xff, 0x1e, 0x1e, 0x1e, 0xff, 0xd7, 0xd7, 0xd7, 0xff, 0xfe, 0xfe, 0xfe, 0xff, 
    0xd7, 0xd7, 0xd7, 0xff, 0xf7, 0xf7, 0xf7, 0xff, 0xb1, 0xb1, 0xb1, 0xff, 0x10, 0x10, 0x10, 0xff, 
    0xe3, 0xe3, 0xe3, 0xff, 0x5c, 0x5c, 0x5c, 0xff, 0x7e, 0x7e, 0x7e, 0xff, 0xbb, 0xbb, 0xbb, 0xff, 
}, out);
}

test "raw format argb float" {
    const a = std.testing.allocator;
    // synthesized pixels; expected computed independently (clamp+truncate
    // for float/half, high byte for 16-bit, bias for signed)
    const data = [_]u8{
    0xd8, 0x00, 0x87, 0x3f, 0x60, 0xf3, 0x56, 0x3f, 0x26, 0x7b, 0x9a, 0xbe, 0x34, 0xe2, 0x52, 0x3e, 
    0x51, 0xf1, 0x8b, 0x3f, 0x7c, 0xf7, 0xc3, 0xbe, 0x13, 0x9f, 0x82, 0x3f, 0x27, 0xda, 0x9c, 0x3f, 
    0xc0, 0xb9, 0x0a, 0x3f, 0x36, 0x5c, 0xaf, 0x3e, 0x63, 0x04, 0x6e, 0xbd, 0xd5, 0x11, 0x75, 0xbe, 
    0x12, 0x47, 0xfd, 0x3e, 0xad, 0x42, 0x61, 0x3e, 0x14, 0xb2, 0x71, 0x3f, 0x4d, 0x71, 0xc9, 0x3e, 
    0x5e, 0x3b, 0xaf, 0x3e, 0x2c, 0xe2, 0xb9, 0x3f, 0xd7, 0xff, 0x39, 0x3f, 0x72, 0xd6, 0x62, 0x3f, 
    0x7e, 0xb4, 0xee, 0x3e, 0x77, 0xf5, 0xa6, 0x3f, 0x97, 0x2d, 0x13, 0x3f, 0x53, 0x4a, 0xa0, 0x3f, 
    0xaf, 0xe0, 0x45, 0x3e, 0xde, 0xf8, 0x2e, 0xbd, 0x63, 0x4f, 0xf3, 0xbe, 0xae, 0x4a, 0xae, 0x3f, 
    0xd8, 0x1e, 0x9b, 0x3f, 0x84, 0xec, 0x8c, 0x3f, 0x3c, 0x0c, 0x30, 0x3f, 0x0b, 0x13, 0xa3, 0x3f, 
    0x59, 0x26, 0x0a, 0x3f, 0xa1, 0x59, 0xb5, 0x3f, 0xeb, 0xec, 0x38, 0x3e, 0x39, 0x97, 0x6a, 0x3f, 
    0x47, 0xf7, 0x0e, 0xbe, 0x18, 0x0f, 0xf3, 0x3e, 0xcd, 0x8b, 0xb0, 0xbe, 0xde, 0x8d, 0x0b, 0x3f, 
    0x08, 0x8e, 0x57, 0x3f, 0x18, 0x47, 0x9b, 0x3f, 0x6f, 0xd6, 0xc5, 0xbb, 0xf0, 0xd3, 0xaa, 0xbe, 
    0x29, 0x74, 0x6f, 0x3e, 0x4c, 0x7e, 0xe0, 0xbe, 0x75, 0x86, 0x14, 0xbe, 0x5e, 0xbc, 0xc4, 0x3e, 
};
    const out = try decode(a, format.argb_float, 4, 3, &data);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{
    0xd6, 0x00, 0x34, 0xff, 0x00, 0xff, 0xff, 0xff, 0x57, 0x00, 0x00, 0x8a, 0x38, 0xf0, 0x64, 0x7e, 
    0xff, 0xb9, 0xe1, 0x57, 0xff, 0x92, 0xff, 0x76, 0x00, 0x00, 0xff, 0x31, 0xff, 0xaf, 0xff, 0xff, 
    0xff, 0x2e, 0xe9, 0x89, 0x79, 0x00, 0x8b, 0x00, 0xff, 0x00, 0x00, 0xd6, 0x00, 0x00, 0x61, 0x3b, 
}, out);
}

test "astc hdr 4x4 block (HDR RGBA)" {
    const a = std.testing.allocator;
    // Real HDR ASTC texture (11x11, 4x4 blocks) with HDR alpha, encoded by
    // ARM astcenc; expected output is the astcenc reference decode clamped
    // to 8-bit. UnityPy's decoder rejects HDR blocks, so HDR is verified
    // against astcenc rather than UnityPy.
    const data = [_]u8{
    0x42, 0xe4, 0x01, 0xcf, 0xf9, 0x29, 0x5d, 0xd2, 0xff, 0x3f, 0xff, 0x3f, 0xdd, 0x1d, 0xcc, 0x0c, 
    0x42, 0xe4, 0x85, 0xc3, 0x60, 0xc6, 0x58, 0x12, 0xdf, 0xce, 0xdf, 0xce, 0x57, 0x46, 0x13, 0x02, 
    0x41, 0xe2, 0x17, 0xe0, 0x8d, 0x09, 0xf0, 0xf9, 0x5e, 0x01, 0x00, 0x12, 0x69, 0xb6, 0x21, 0x89, 
    0x41, 0xe2, 0x1f, 0xe0, 0x8f, 0x0a, 0xf0, 0xf9, 0x5e, 0x01, 0x00, 0x12, 0x69, 0xb6, 0x21, 0x89, 
    0x33, 0xe2, 0xa1, 0x8e, 0xe3, 0x4f, 0x32, 0xa8, 0xfb, 0xdf, 0x01, 0xff, 0x1d, 0xf0, 0xdf, 0x01, 
    0x42, 0xe4, 0x85, 0xc3, 0x60, 0xc6, 0xf8, 0x11, 0xdf, 0xce, 0x57, 0x46, 0x9b, 0x8a, 0x13, 0x02, 
    0x42, 0xe4, 0xe5, 0xd3, 0x2a, 0xd6, 0xfa, 0xd1, 0xb7, 0x3b, 0x95, 0x19, 0xa6, 0x2a, 0x84, 0x08, 
    0x42, 0xe0, 0x3b, 0x80, 0x7b, 0xa4, 0x00, 0x00, 0x20, 0xa7, 0x00, 0x00, 0x00, 0xaa, 0x55, 0xff, 
    0x33, 0xe2, 0xa1, 0x8e, 0xe3, 0x4f, 0x32, 0xea, 0xfd, 0xdf, 0x01, 0xff, 0x1d, 0xf0, 0xdf, 0x01, 
};
    const out = try decode(a, format.astc_hdr_4x4, 11, 11, &data);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{
    0x00, 0x8b, 0x36, 0x17, 0xeb, 0x8b, 0x36, 0x17, 0xeb, 0x8b, 0x36, 0x17, 0xeb, 0x8b, 0x36, 0x17, 
    0xff, 0x85, 0x34, 0x17, 0xff, 0x85, 0x34, 0x17, 0xff, 0x85, 0x34, 0x17, 0xff, 0x85, 0x34, 0x17, 
    0xff, 0x80, 0x32, 0x1b, 0xff, 0x80, 0x32, 0x1b, 0xff, 0x80, 0x32, 0x1b, 0x00, 0x8b, 0x36, 0x91, 
    0xeb, 0x8b, 0x36, 0x91, 0xeb, 0x8b, 0x36, 0x91, 0xeb, 0x8b, 0x36, 0x91, 0xff, 0x81, 0x32, 0x91, 
    0xff, 0x81, 0x32, 0x91, 0xff, 0x81, 0x32, 0x91, 0xff, 0x81, 0x32, 0x91, 0xff, 0x7c, 0x33, 0xaf, 
    0xff, 0x7c, 0x33, 0xaf, 0xff, 0x7c, 0x33, 0xaf, 0x00, 0x8b, 0x36, 0xff, 0xeb, 0x8b, 0x36, 0xff, 
    0xeb, 0x8b, 0x36, 0xff, 0xeb, 0x8b, 0x36, 0xff, 0xff, 0x80, 0x32, 0xff, 0xff, 0x80, 0x32, 0xff, 
    0xff, 0x80, 0x32, 0xff, 0xff, 0x80, 0x32, 0xff, 0xff, 0x7b, 0x34, 0xff, 0xff, 0x7b, 0x34, 0xff, 
    0xff, 0x7b, 0x34, 0xff, 0x00, 0x8b, 0x36, 0xff, 0xeb, 0x8b, 0x36, 0xff, 0xeb, 0x8b, 0x36, 0xff, 
    0xeb, 0x8b, 0x36, 0xff, 0xff, 0x80, 0x32, 0xff, 0xff, 0x80, 0x32, 0xff, 0xff, 0x80, 0x32, 0xff, 
    0xff, 0x80, 0x32, 0xff, 0xff, 0x7b, 0x34, 0xff, 0xff, 0x7b, 0x34, 0xff, 0xff, 0x7b, 0x34, 0xff, 
    0xff, 0x80, 0x32, 0x1b, 0xff, 0x80, 0x32, 0x1b, 0xff, 0x80, 0x32, 0x1b, 0xff, 0x80, 0x32, 0x1b, 
    0x00, 0x80, 0x2e, 0xff, 0x8f, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 
    0xff, 0x85, 0x34, 0xff, 0xff, 0x85, 0x34, 0xff, 0xff, 0x85, 0x34, 0xff, 0xff, 0x7c, 0x33, 0xaf, 
    0xff, 0x7c, 0x33, 0xaf, 0xff, 0x7c, 0x33, 0xaf, 0xff, 0x7c, 0x33, 0xaf, 0x00, 0x80, 0x2e, 0xff, 
    0x8f, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 0xff, 0x83, 0x33, 0xff, 
    0xff, 0x83, 0x33, 0xff, 0xff, 0x83, 0x33, 0xff, 0xff, 0x7b, 0x34, 0xff, 0xff, 0x7b, 0x34, 0xff, 
    0xff, 0x7b, 0x34, 0xff, 0xff, 0x7b, 0x34, 0xff, 0x00, 0x80, 0x2e, 0xff, 0x8f, 0x80, 0x2e, 0xff, 
    0xff, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 0xff, 0x81, 0x32, 0xff, 0xff, 0x81, 0x32, 0xff, 
    0xff, 0x81, 0x32, 0xff, 0xff, 0x7b, 0x34, 0xff, 0xff, 0x7b, 0x34, 0xff, 0xff, 0x7b, 0x34, 0xff, 
    0xff, 0x7b, 0x34, 0xff, 0x00, 0x80, 0x2e, 0xff, 0x8f, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 
    0xff, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x32, 0xff, 0xff, 0x80, 0x32, 0xff, 0xff, 0x80, 0x32, 0xff, 
    0xff, 0x85, 0x34, 0xff, 0xff, 0x83, 0x33, 0xff, 0xff, 0x83, 0x33, 0xff, 0xff, 0x81, 0x32, 0xff, 
    0xff, 0x80, 0x34, 0xff, 0xff, 0x80, 0x34, 0xff, 0xff, 0x80, 0x34, 0xff, 0xff, 0x80, 0x34, 0xff, 
    0x00, 0x80, 0x2e, 0xff, 0x8f, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 0xff, 0x85, 0x34, 0xff, 
    0xff, 0x83, 0x33, 0xff, 0xff, 0x83, 0x33, 0xff, 0xff, 0x81, 0x32, 0xff, 0xff, 0x80, 0x34, 0xff, 
    0xff, 0x80, 0x34, 0xff, 0xff, 0x80, 0x34, 0xff, 0xff, 0x80, 0x34, 0xff, 0x00, 0x80, 0x2e, 0xff, 
    0x8f, 0x80, 0x2e, 0xff, 0xff, 0x80, 0x2e, 0xff, 0xff, 0x85, 0x34, 0xff, 0xff, 0x83, 0x33, 0xff, 
    0xff, 0x83, 0x33, 0xff, 0xff, 0x81, 0x32, 0xff, 0xff, 0x80, 0x34, 0xff, 0xff, 0x80, 0x34, 0xff, 
    0xff, 0x80, 0x34, 0xff, 0xff, 0x80, 0x34, 0xff, 0x00, 0x80, 0x2e, 0xff, 0x8f, 0x80, 0x2e, 0xff, 
    0xff, 0x80, 0x2e, 0xff, 
}, out);
}



test "unsupported format and bad size" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFormat, decode(a, 32, 4, 4, "abcdefgh")); // BC6H
    try std.testing.expectError(error.BadSize, decode(a, format.rgba32, 2, 2, "short"));
    try std.testing.expectError(error.BadSize, decode(a, format.bc7, 4, 4, "short"));
}

// --- BC4 / BC5 (RGTC) ---

/// Decodes a BC4/BC5-style 2-reference channel block (like the DXT5 alpha
/// block): two 8-bit references, then 16 3-bit indices, LSB-first per
/// pixel in row-major order.
fn bcChannelBlock(block: []const u8, pixel: usize) u8 {
    const ref0 = block[0];
    const ref1 = block[1];
    const bits = std.mem.readInt(u48, block[2..8], .little);
    const idx = (bits >> @as(u6, @intCast(3 * pixel))) & 0x7;
    return if (ref0 > ref1)
        switch (idx) {
            0 => ref0,
            1 => ref1,
            2 => interp7(ref0, ref1, 6, 1),
            3 => interp7(ref0, ref1, 5, 2),
            4 => interp7(ref0, ref1, 4, 3),
            5 => interp7(ref0, ref1, 3, 4),
            6 => interp7(ref0, ref1, 2, 5),
            else => interp7(ref0, ref1, 1, 6),
        }
    else
        switch (idx) {
            0 => ref0,
            1 => ref1,
            2 => interp5(ref0, ref1, 4, 1),
            3 => interp5(ref0, ref1, 3, 2),
            4 => interp5(ref0, ref1, 2, 3),
            5 => interp5(ref0, ref1, 1, 4),
            6 => 0,
            else => 255,
        };
}

fn decodeBc4(out: []u8, w: usize, h: usize, data: []const u8) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = data[(by * bw + bx) * 8 ..][0..8];
            for (0..4) |y| {
                for (0..4) |x| {
                    const px = bx * 4 + x;
                    const py = by * 4 + y;
                    if (px >= w or py >= h) continue;
                    const v = bcChannelBlock(block, y * 4 + x);
                    const dst = out[(py * w + px) * 4 ..][0..4];
                    dst[0] = v;
                    dst[1] = v;
                    dst[2] = v;
                    dst[3] = 255;
                }
            }
        }
    }
}

fn decodeBc5(out: []u8, w: usize, h: usize, data: []const u8) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = data[(by * bw + bx) * 16 ..][0..16];
            for (0..4) |y| {
                for (0..4) |x| {
                    const px = bx * 4 + x;
                    const py = by * 4 + y;
                    if (px >= w or py >= h) continue;
                    const dst = out[(py * w + px) * 4 ..][0..4];
                    dst[0] = bcChannelBlock(block[0..8], y * 4 + x);
                    dst[1] = bcChannelBlock(block[8..16], y * 4 + x);
                    dst[2] = 0;
                    dst[3] = 255;
                }
            }
        }
    }
}

// --- ETC1 / ETC2 ---

const EtcKind = enum { etc1, etc2 };

/// ETC1/ETC2 RGB decode. `etc1` treats the differential bit as always
/// differential (no T/H/planar); `etc2` applies the full ETC2 mode
/// selection.
fn decodeEtc(out: []u8, w: usize, h: usize, data: []const u8, kind: EtcKind) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = data[(by * bw + bx) * 8 ..][0..8];
            const bits = std.mem.readInt(u64, block[0..8], .big);
            decodeEtcBlock(out, w, h, bx, by, bits, kind);
        }
    }
}

fn decodeEtc2Rgba8(out: []u8, w: usize, h: usize, data: []const u8) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = data[(by * bw + bx) * 16 ..][0..16];
            const alpha_bits = std.mem.readInt(u64, block[0..8], .big);
            const color_bits = std.mem.readInt(u64, block[8..16], .big);
            // decode alpha first so decodeEtcBlock keeps RGB and we add A
            decodeEtcBlock(out, w, h, bx, by, color_bits, .etc2);
            for (0..4) |y| {
                for (0..4) |x| {
                    const px = bx * 4 + x;
                    const py = by * 4 + y;
                    if (px >= w or py >= h) continue;
                    const letter = x * 4 + y;
                    const idx: u6 = @intCast((alpha_bits >> @as(u6, @intCast(45 - 3 * letter))) & 0x7);
                    const a = eacAlpha(alpha_bits, idx);
                    out[(py * w + px) * 4 + 3] = a;
                }
            }
        }
    }
}

/// EAC alpha channel value for a pixel index (ETC2 RGBA8 alpha block).
fn eacAlpha(bits: u64, idx: u6) u8 {
    const base: i32 = @intCast((bits >> 56) & 0xff);
    const mult: i32 = @intCast((bits >> 52) & 0xf);
    const table_idx: u4 = @intCast((bits >> 48) & 0xf);
    const mod: i32 = etcAlphaTables[table_idx][idx];
    const v = base + mod * mult;
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Decodes one 4x4 ETC1/ETC2 block. `bits` is the block read as a
/// big-endian u64 (spec layout: byte 0 holds bits 63..56); `d[i]` is byte
/// i of the block, matching the reference decoder's `data` indexing. The
/// extraction formulas are transcribed from UnityPy's texture2ddecoder so
/// output matches UnityPy pixel-for-pixel; ETC2 alternate modes (T/H/
/// planar) are decoded per the Khronos ETC2 spec.
fn decodeEtcBlock(out: []u8, w: usize, h: usize, bx: usize, by: usize, bits: u64, kind: EtcKind) void {
    const d = [8]u8{
        @truncate(bits >> 56), @truncate(bits >> 48), @truncate(bits >> 40), @truncate(bits >> 32),
        @truncate(bits >> 24), @truncate(bits >> 16), @truncate(bits >> 8), @truncate(bits),
    };
    const flip = d[3] & 1;
    if ((d[3] & 2) == 0) {
        // individual mode: two 4-bit colors, replicated to 8 bits
        const c1 = [3]u8{
            (d[0] & 0xf0) | d[0] >> 4,
            (d[1] & 0xf0) | d[1] >> 4,
            (d[2] & 0xf0) | d[2] >> 4,
        };
        const c2 = [3]u8{
            (d[0] & 0x0f) | d[0] << 4,
            (d[1] & 0x0f) | d[1] << 4,
            (d[2] & 0x0f) | d[2] << 4,
        };
        paintSubblocks(out, w, h, bx, by, bits, flip, c1, c2, @intCast(d[3] >> 5), @intCast((d[3] >> 2) & 7));
        return;
    }

    // differential: 5-bit base colors and signed 3-bit deltas, computed
    // in the base*8 domain like the reference
    const r: i32 = d[0] & 0xf8;
    const dr: i32 = @as(i32, (d[0] << 3) & 0x18) - @as(i32, (d[0] << 3) & 0x20);
    const g: i32 = d[1] & 0xf8;
    const dg: i32 = @as(i32, (d[1] << 3) & 0x18) - @as(i32, (d[1] << 3) & 0x20);
    const b: i32 = d[2] & 0xf8;
    const db: i32 = @as(i32, (d[2] << 3) & 0x18) - @as(i32, (d[2] << 3) & 0x20);

    if (kind == .etc2) {
        // ETC2 mode selection: the first sum outside [0,31] picks the mode
        if (r + dr < 0 or r + dr > 255) {
            decodeEtcT(out, w, h, bx, by, bits, d);
            return;
        }
        if (g + dg < 0 or g + dg > 255) {
            decodeEtcH(out, w, h, bx, by, bits, d);
            return;
        }
        if (b + db < 0 or b + db > 255) {
            decodeEtcPlanar(out, w, h, bx, by, d);
            return;
        }
    }

    // differential mode. The spec leaves out-of-range sums undefined; the
    // reference wraps them in u8 and extends, so do the same.
    const c1 = [3]u8{
        @as(u8, @intCast(r)) | @as(u8, @intCast(r >> 5)),
        @as(u8, @intCast(g)) | @as(u8, @intCast(g >> 5)),
        @as(u8, @intCast(b)) | @as(u8, @intCast(b >> 5)),
    };
    var c2r: u8 = @intCast(@mod(r + dr, 256));
    var c2g: u8 = @intCast(@mod(g + dg, 256));
    var c2b: u8 = @intCast(@mod(b + db, 256));
    c2r |= c2r >> 5;
    c2g |= c2g >> 5;
    c2b |= c2b >> 5;
    const c2 = [3]u8{ c2r, c2g, c2b };
    paintSubblocks(out, w, h, bx, by, bits, flip, c1, c2, @intCast(d[3] >> 5), @intCast((d[3] >> 2) & 7));
}

/// ETC1/ETC2 modifier tables, ordered [-b, -a, +a, +b] per table codeword.
const etcModifierTables = [_][4]i16{
    .{ -8, -2, 2, 8 },
    .{ -17, -5, 5, 17 },
    .{ -29, -9, 9, 29 },
    .{ -42, -13, 13, 42 },
    .{ -60, -18, 18, 60 },
    .{ -80, -24, 24, 80 },
    .{ -106, -33, 33, 106 },
    .{ -183, -47, 47, 183 },
};

/// Distance table for ETC2 T/H modes.
const etcDistanceTable = [_]u8{ 3, 6, 11, 16, 23, 32, 41, 64 };

/// Modifier tables for EAC (ETC2 RGBA8 alpha).
const etcAlphaTables = [_][8]i16{
    .{ -3, -6, -9, -15, 2, 5, 8, 14 },
    .{ -3, -7, -10, -13, 2, 6, 9, 12 },
    .{ -2, -5, -8, -13, 1, 4, 7, 12 },
    .{ -2, -4, -6, -13, 1, 3, 5, 12 },
    .{ -3, -6, -8, -12, 2, 5, 7, 11 },
    .{ -3, -7, -9, -11, 2, 6, 8, 10 },
    .{ -4, -7, -8, -11, 3, 6, 7, 10 },
    .{ -3, -5, -8, -11, 2, 4, 7, 10 },
    .{ -2, -6, -8, -10, 1, 5, 7, 9 },
    .{ -2, -5, -8, -10, 1, 4, 7, 9 },
    .{ -2, -4, -8, -10, 1, 3, 7, 9 },
    .{ -2, -5, -7, -10, 1, 4, 6, 9 },
    .{ -3, -4, -7, -10, 2, 3, 6, 9 },
    .{ -1, -2, -3, -10, 0, 1, 2, 9 },
    .{ -4, -6, -8, -9, 3, 5, 7, 8 },
    .{ -3, -5, -7, -9, 2, 4, 6, 8 },
};

fn clampByte(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Paints a pixel using its ETC index bits: LSB at bit `letter`, MSB at
/// bit 16+letter, letter = x*4 + y (the spec's split index layout: the
/// 16 LSBs hold one bit per pixel, the next 16 hold the second bit).
fn paintIndex(bits: u64, letter: usize) u2 {
    const lsb = (bits >> @as(u5, @intCast(letter))) & 1;
    const msb = (bits >> @as(u5, @intCast(16 + letter))) & 1;
    return @intCast((msb << 1) | lsb);
}

/// Paints both sub-blocks of an individual/differential block: sub-block 1
/// is the top half (flip=1) or left half (flip=0), matching the reference's
/// sub-block table and column-major letter order.
fn paintSubblocks(
    out: []u8,
    w: usize,
    h: usize,
    bx: usize,
    by: usize,
    bits: u64,
    flip: u64,
    c1: [3]u8,
    c2: [3]u8,
    t1: u3,
    t2: u3,
) void {
    for (0..4) |y| {
        for (0..4) |x| {
            const letter = x * 4 + y;
            const idx = paintIndex(bits, letter);
            // subblock 1: top half (flip=1) or left half (flip=0)
            const in_sub1 = if (flip != 0) y < 2 else x < 2;
            const color = if (in_sub1) c1 else c2;
            const table = if (in_sub1) t1 else t2;
            const mod = etcModifier(table, idx);
            const px = bx * 4 + x;
            const py = by * 4 + y;
            if (px >= w or py >= h) continue;
            const dst = out[(py * w + px) * 4 ..][0..4];
            dst[0] = clampByte(@as(i32, color[0]) + mod);
            dst[1] = clampByte(@as(i32, color[1]) + mod);
            dst[2] = clampByte(@as(i32, color[2]) + mod);
            dst[3] = 255;
        }
    }
}

fn etcModifier(table: u3, idx: u2) i32 {
    const t = etcModifierTables[table];
    // index bits: 00 -> +a, 01 -> +b, 10 -> -a, 11 -> -b
    return switch (idx) {
        0 => t[2],
        1 => t[3],
        2 => t[1],
        else => t[0],
    };
}

/// ETC2 T-mode: one base color plus a second base color offset by a
/// luminance distance. Base colors are 4-bit per channel, stored
/// non-sequentially; the distance index uses the low two table bits and
/// the flip-bit position.
fn decodeEtcT(out: []u8, w: usize, h: usize, bx: usize, by: usize, bits: u64, d: [8]u8) void {
    const c1 = [3]u8{
        (d[0] << 3 & 0xc0) | (d[0] << 4 & 0x30) | (d[0] >> 1 & 0xc) | (d[0] & 3),
        (d[1] & 0xf0) | d[1] >> 4,
        (d[1] & 0x0f) | d[1] << 4,
    };
    const c2 = [3]u8{
        (d[2] & 0xf0) | d[2] >> 4,
        (d[2] & 0x0f) | d[2] << 4,
        (d[3] & 0xf0) | d[3] >> 4,
    };
    const dist: usize = (d[3] >> 1 & 6) | (d[3] & 1);
    const dd: i32 = etcDistanceTable[dist];
    const paints = [4][3]u8{
        c1,
        .{ clampByte(@as(i32, c2[0]) + dd), clampByte(@as(i32, c2[1]) + dd), clampByte(@as(i32, c2[2]) + dd) },
        c2,
        .{ clampByte(@as(i32, c2[0]) - dd), clampByte(@as(i32, c2[1]) - dd), clampByte(@as(i32, c2[2]) - dd) },
    };
    paintFour(out, w, h, bx, by, bits, &paints);
}

/// ETC2 H-mode: two base colors with 4-bit channels in a scattered
/// layout; the distance index is (da, db) plus a comparison bit.
fn decodeEtcH(out: []u8, w: usize, h: usize, bx: usize, by: usize, bits: u64, d: [8]u8) void {
    const c1r = (d[0] << 1 & 0xf0) | (d[0] >> 3 & 0xf);
    var c1g = (d[0] << 5 & 0xe0) | (d[1] & 0x10);
    c1g |= c1g >> 4;
    var c1b = (d[1] & 8) | (d[1] << 1 & 6) | d[2] >> 7;
    c1b |= c1b << 4;
    const c2r = (d[2] << 1 & 0xf0) | (d[2] >> 3 & 0xf);
    var c2g = (d[2] << 5 & 0xe0) | (d[3] >> 3 & 0x10);
    c2g |= c2g >> 4;
    const c2b = (d[3] << 1 & 0xf0) | (d[3] >> 3 & 0xf);
    var di: u8 = (d[3] & 4) | (d[3] << 1 & 2);
    // the LSB of the distance index: base color 1 >= base color 2
    // (compared as (R<<16)|(G<<8)|B, i.e. lexicographic R,G,B)
    if (c1r > c2r or (c1r == c2r and (c1g > c2g or (c1g == c2g and c1b >= c2b)))) di += 1;
    const dd: i32 = etcDistanceTable[di];
    const paints = [4][3]u8{
        .{ clampByte(@as(i32, c1r) + dd), clampByte(@as(i32, c1g) + dd), clampByte(@as(i32, c1b) + dd) },
        .{ clampByte(@as(i32, c1r) - dd), clampByte(@as(i32, c1g) - dd), clampByte(@as(i32, c1b) - dd) },
        .{ clampByte(@as(i32, c2r) + dd), clampByte(@as(i32, c2g) + dd), clampByte(@as(i32, c2b) + dd) },
        .{ clampByte(@as(i32, c2r) - dd), clampByte(@as(i32, c2g) - dd), clampByte(@as(i32, c2b) - dd) },
    };
    paintFour(out, w, h, bx, by, bits, &paints);
}

fn paintFour(out: []u8, w: usize, h: usize, bx: usize, by: usize, bits: u64, paints: *const [4][3]u8) void {
    for (0..4) |y| {
        for (0..4) |x| {
            const letter = x * 4 + y;
            const idx = paintIndex(bits, letter);
            const px = bx * 4 + x;
            const py = by * 4 + y;
            if (px >= w or py >= h) continue;
            const dst = out[(py * w + px) * 4 ..][0..4];
            dst[0] = paints[idx][0];
            dst[1] = paints[idx][1];
            dst[2] = paints[idx][2];
            dst[3] = 255;
        }
    }
}

/// ETC2 planar mode: three corner colors (origin, horizontal, vertical)
/// form a plane; pixel (x,y) is a rounded bilinear sample of it.
fn decodeEtcPlanar(out: []u8, w: usize, h: usize, bx: usize, by: usize, d: [8]u8) void {
    const o_r = (d[0] << 1 & 0xfc) | (d[0] >> 5 & 3);
    const o_g = (d[0] << 7 & 0x80) | (d[1] & 0x7e) | (d[0] & 1);
    var o_b = (d[1] << 7 & 0x80) | (d[2] << 2 & 0x60) | (d[2] << 3 & 0x18) | (d[3] >> 5 & 4);
    o_b |= o_b >> 6;
    const h_r = (d[3] << 1 & 0xf8) | (d[3] << 2 & 4) | (d[3] >> 5 & 3);
    const h_g = (d[4] & 0xfe) | d[4] >> 7;
    var h_b = (d[4] << 7 & 0x80) | (d[5] >> 1 & 0x7c);
    h_b |= h_b >> 6;
    const v_r = (d[5] << 5 & 0xe0) | (d[6] >> 3 & 0x1c) | (d[5] >> 1 & 3);
    const v_g = (d[6] << 3 & 0xf8) | (d[7] >> 5 & 0x6) | (d[6] >> 4 & 1);
    const v_b = d[7] << 2 | (d[7] >> 4 & 3);

    for (0..4) |y| {
        for (0..4) |x| {
            const px = bx * 4 + x;
            const py = by * 4 + y;
            if (px >= w or py >= h) continue;
            const dst = out[(py * w + px) * 4 ..][0..4];
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            dst[0] = clampByte((xi * (@as(i32, h_r) - @as(i32, o_r)) + yi * (@as(i32, v_r) - @as(i32, o_r)) + 4 * @as(i32, o_r) + 2) >> 2);
            dst[1] = clampByte((xi * (@as(i32, h_g) - @as(i32, o_g)) + yi * (@as(i32, v_g) - @as(i32, o_g)) + 4 * @as(i32, o_g) + 2) >> 2);
            dst[2] = clampByte((xi * (@as(i32, h_b) - @as(i32, o_b)) + yi * (@as(i32, v_b) - @as(i32, o_b)) + 4 * @as(i32, o_b) + 2) >> 2);
            dst[3] = 255;
        }
    }
}

// --- BC7 (BPTC) ---

const Bc7ModeInfo = struct {
    num_subsets: usize,
    partition_bits: usize,
    rotation_bits: usize,
    index_selection_bits: usize,
    color_bits: usize,
    alpha_bits: usize,
    endpoint_pbits: usize,
    shared_pbits: usize,
    index_bits: [2]usize,
};

/// Per-mode layout: subsets, partition/rotation/index-selection bit
/// counts, color/alpha bits per endpoint, endpoint/shared P-bits, and the
/// two index widths (second is 0 when unused).
const bc7ModeInfo = [_]Bc7ModeInfo{
    .{ .num_subsets = 3, .partition_bits = 4, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 4, .alpha_bits = 0, .endpoint_pbits = 1, .shared_pbits = 0, .index_bits = .{ 3, 0 } },
    .{ .num_subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 6, .alpha_bits = 0, .endpoint_pbits = 0, .shared_pbits = 1, .index_bits = .{ 3, 0 } },
    .{ .num_subsets = 3, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 5, .alpha_bits = 0, .endpoint_pbits = 0, .shared_pbits = 0, .index_bits = .{ 2, 0 } },
    .{ .num_subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 7, .alpha_bits = 0, .endpoint_pbits = 1, .shared_pbits = 0, .index_bits = .{ 2, 0 } },
    .{ .num_subsets = 1, .partition_bits = 0, .rotation_bits = 2, .index_selection_bits = 1, .color_bits = 5, .alpha_bits = 6, .endpoint_pbits = 0, .shared_pbits = 0, .index_bits = .{ 2, 3 } },
    .{ .num_subsets = 1, .partition_bits = 0, .rotation_bits = 2, .index_selection_bits = 0, .color_bits = 7, .alpha_bits = 8, .endpoint_pbits = 0, .shared_pbits = 0, .index_bits = .{ 2, 2 } },
    .{ .num_subsets = 1, .partition_bits = 0, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 7, .alpha_bits = 7, .endpoint_pbits = 1, .shared_pbits = 0, .index_bits = .{ 4, 0 } },
    .{ .num_subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 5, .alpha_bits = 5, .endpoint_pbits = 1, .shared_pbits = 0, .index_bits = .{ 2, 0 } },
};

/// BC7 2-subset partition table: bit `i` is the subset of pixel `i`.
const bc7Partition2 = [_]u16{
    0xcccc, 0x8888, 0xeeee, 0xecc8, 0xc880, 0xfeec, 0xfec8, 0xec80,
    0xc800, 0xffec, 0xfe80, 0xe800, 0xffe8, 0xff00, 0xfff0, 0xf000,
    0xf710, 0x008e, 0x7100, 0x08ce, 0x008c, 0x7310, 0x3100, 0x8cce,
    0x088c, 0x3110, 0x6666, 0x366c, 0x17e8, 0x0ff0, 0x718e, 0x399c,
    0xaaaa, 0xf0f0, 0x5a5a, 0x33cc, 0x3c3c, 0x55aa, 0x9696, 0xa55a,
    0x73ce, 0x13c8, 0x324c, 0x3bdc, 0x6996, 0xc33c, 0x9966, 0x0660,
    0x0272, 0x04e4, 0x4e40, 0x2720, 0xc936, 0x936c, 0x39c6, 0x639c,
    0x9336, 0x9cc6, 0x817e, 0xe718, 0xccf0, 0x0fcc, 0x7744, 0xee22,
};

/// BC7 3-subset partition table: bits `2i+1..2i` are the subset of pixel `i`.
const bc7Partition3 = [_]u32{
    0xaa685050, 0x6a5a5040, 0x5a5a4200, 0x5450a0a8, 0xa5a50000, 0xa0a05050, 0x5555a0a0, 0x5a5a5050,
    0xaa550000, 0xaa555500, 0xaaaa5500, 0x90909090, 0x94949494, 0xa4a4a4a4, 0xa9a59450, 0x2a0a4250,
    0xa5945040, 0x0a425054, 0xa5a5a500, 0x55a0a0a0, 0xa8a85454, 0x6a6a4040, 0xa4a45000, 0x1a1a0500,
    0x0050a4a4, 0xaaa59090, 0x14696914, 0x69691400, 0xa08585a0, 0xaa821414, 0x50a4a450, 0x6a5a0200,
    0xa9a58000, 0x5090a0a8, 0xa8a09050, 0x24242424, 0x00aa5500, 0x24924924, 0x24499224, 0x50a50a50,
    0x500aa550, 0xaaaa4444, 0x66660000, 0xa5a0a5a0, 0x50a050a0, 0x69286928, 0x44aaaa44, 0x66666600,
    0xaa444444, 0x54a854a8, 0x95809580, 0x96969600, 0xa85454a8, 0x80959580, 0xaa141414, 0x96960000,
    0xaaaa1414, 0xa05050a0, 0xa0a5a5a0, 0x96000000, 0x40804080, 0xa9a8a9a8, 0xaaaaaa44, 0x2a4a5254,
};

/// Anchor pixel (the one with one fewer index bit) of the second subset.
const bc7Anchor2 = [_]u8{
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
    6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
};

/// Anchor pixels of the second and third subsets (3-subset partitions).
const bc7Anchor3 = [_][64]u8{
    .{
        3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3,
        3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
        8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15,
        3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
    },
    .{
        15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8,
        15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
        15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8,
        15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
    },
};

/// Index interpolation weights for 2-, 3- and 4-bit indices.
const bc7Factors = [_][16]u8{
    .{ 0, 21, 43, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 9, 18, 27, 37, 46, 55, 64, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 },
};

/// Reads `num` bits (LSB first) at absolute bit position `bit_pos`.
fn bc7Peek(data: []const u8, bit_pos: usize, num: usize) u16 {
    const shift: u5 = @intCast(bit_pos % 8);
    const byte = bit_pos / 8;
    var raw: u32 = 0;
    var i: usize = 0;
    while (i < 3 and byte + i < data.len) : (i += 1) {
        raw |= @as(u32, data[byte + i]) << @intCast(8 * i);
    }
    return @intCast((raw >> shift) & ((@as(u32, 1) << @intCast(num)) - 1));
}

/// Replicates the top bits of a `bits`-wide value to fill 8 bits.
fn bc7Expand(v: u8, bits: usize) u8 {
    if (bits >= 8) return v;
    const s: u8 = v << @intCast(8 - bits);
    return s | s >> @intCast(bits);
}

/// BC7 block decode: 16 bytes per 4x4 block, MSB-first mode bits at bit 0.
fn decodeBc7(out: []u8, w: usize, h: usize, data: []const u8) Error!void {
    const bw = (w + 3) / 4;
    const bh = (h + 3) / 4;
    for (0..bh) |by| {
        for (0..bw) |bx| {
            decodeBc7Block(out, w, h, bx, by, data[(by * bw + bx) * 16 ..][0..16]);
        }
    }
}

fn decodeBc7Block(out: []u8, w: usize, h: usize, bx: usize, by: usize, block: []const u8) void {
    var bit_pos: usize = 0;
    // mode: leading zero bits, then a one bit; eight zeros = reserved
    var mode: usize = 0;
    while (bc7Peek(block, bit_pos, 1) == 0 and mode < 8) : (mode += 1) bit_pos += 1;
    bit_pos += 1;

    if (mode == 8) {
        // reserved mode: undefined; the reference emits transparent black
        for (0..4) |y| {
            for (0..4) |x| {
                const px = bx * 4 + x;
                const py = by * 4 + y;
                if (px >= w or py >= h) continue;
                @memset(out[(py * w + px) * 4 ..][0..4], 0);
            }
        }
        return;
    }

    const mi = bc7ModeInfo[mode];
    const mode_pbits: usize = if (mi.endpoint_pbits != 0) mi.endpoint_pbits else mi.shared_pbits;

    const partition_set_idx = bc7Peek(block, bit_pos, mi.partition_bits);
    bit_pos += mi.partition_bits;
    const rotation_mode = bc7Peek(block, bit_pos, mi.rotation_bits);
    bit_pos += mi.rotation_bits;
    const index_selection_mode = bc7Peek(block, bit_pos, mi.index_selection_bits);
    bit_pos += mi.index_selection_bits;

    var ep_r = [_]u8{0} ** 6;
    var ep_g = [_]u8{0} ** 6;
    var ep_b = [_]u8{0} ** 6;
    var ep_a = [_]u8{0xff} ** 6;

    for (0..mi.num_subsets) |ii| {
        ep_r[ii * 2] = @intCast(bc7Peek(block, bit_pos, mi.color_bits) << @intCast(mode_pbits));
        ep_r[ii * 2 + 1] = @intCast(bc7Peek(block, bit_pos + mi.color_bits, mi.color_bits) << @intCast(mode_pbits));
        bit_pos += 2 * mi.color_bits;
    }
    for (0..mi.num_subsets) |ii| {
        ep_g[ii * 2] = @intCast(bc7Peek(block, bit_pos, mi.color_bits) << @intCast(mode_pbits));
        ep_g[ii * 2 + 1] = @intCast(bc7Peek(block, bit_pos + mi.color_bits, mi.color_bits) << @intCast(mode_pbits));
        bit_pos += 2 * mi.color_bits;
    }
    for (0..mi.num_subsets) |ii| {
        ep_b[ii * 2] = @intCast(bc7Peek(block, bit_pos, mi.color_bits) << @intCast(mode_pbits));
        ep_b[ii * 2 + 1] = @intCast(bc7Peek(block, bit_pos + mi.color_bits, mi.color_bits) << @intCast(mode_pbits));
        bit_pos += 2 * mi.color_bits;
    }
    if (mi.alpha_bits > 0) {
        for (0..mi.num_subsets) |ii| {
            ep_a[ii * 2] = @intCast(bc7Peek(block, bit_pos, mi.alpha_bits) << @intCast(mode_pbits));
            ep_a[ii * 2 + 1] = @intCast(bc7Peek(block, bit_pos + mi.alpha_bits, mi.alpha_bits) << @intCast(mode_pbits));
            bit_pos += 2 * mi.alpha_bits;
        }
    }

    if (mode_pbits != 0) {
        for (0..mi.num_subsets) |ii| {
            const pda: u8 = @intCast(bc7Peek(block, bit_pos, mode_pbits));
            const pdb: u8 = if (mi.shared_pbits == 0) @intCast(bc7Peek(block, bit_pos + mode_pbits, mode_pbits)) else pda;
            // shared P-bit: only one bit is stored for both endpoints
            bit_pos += mode_pbits * (if (mi.shared_pbits == 0) @as(usize, 2) else 1);
            ep_r[ii * 2] |= pda;
            ep_r[ii * 2 + 1] |= pdb;
            ep_g[ii * 2] |= pda;
            ep_g[ii * 2 + 1] |= pdb;
            ep_b[ii * 2] |= pda;
            ep_b[ii * 2 + 1] |= pdb;
            ep_a[ii * 2] |= pda;
            ep_a[ii * 2 + 1] |= pdb;
        }
    }

    const color_bits: usize = mi.color_bits + mode_pbits;
    for (0..mi.num_subsets) |ii| {
        ep_r[ii * 2] = bc7Expand(ep_r[ii * 2], color_bits);
        ep_r[ii * 2 + 1] = bc7Expand(ep_r[ii * 2 + 1], color_bits);
        ep_g[ii * 2] = bc7Expand(ep_g[ii * 2], color_bits);
        ep_g[ii * 2 + 1] = bc7Expand(ep_g[ii * 2 + 1], color_bits);
        ep_b[ii * 2] = bc7Expand(ep_b[ii * 2], color_bits);
        ep_b[ii * 2 + 1] = bc7Expand(ep_b[ii * 2 + 1], color_bits);
    }
    if (mi.alpha_bits > 0) {
        const alpha_bits: usize = mi.alpha_bits + mode_pbits;
        for (0..mi.num_subsets) |ii| {
            ep_a[ii * 2] = bc7Expand(ep_a[ii * 2], alpha_bits);
            ep_a[ii * 2 + 1] = bc7Expand(ep_a[ii * 2 + 1], alpha_bits);
        }
    }

    const has_index_bits1 = mi.index_bits[1] != 0;
    const factors = [2][]const u8{
        bc7Factors[mi.index_bits[0] - 2][0..],
        if (has_index_bits1) bc7Factors[mi.index_bits[1] - 2][0..] else bc7Factors[mi.index_bits[0] - 2][0..],
    };

    var offset = [2]usize{ 0, mi.num_subsets * (16 * mi.index_bits[0] - 1) };

    for (0..4) |yy| {
        for (0..4) |xx| {
            const idx = yy * 4 + xx;

            var subset_index: usize = 0;
            var index_anchor: usize = 0;
            switch (mi.num_subsets) {
                2 => {
                    subset_index = (bc7Partition2[partition_set_idx] >> @as(u4, @intCast(idx))) & 1;
                    index_anchor = if (subset_index != 0) bc7Anchor2[partition_set_idx] else 0;
                },
                3 => {
                    subset_index = (bc7Partition3[partition_set_idx] >> @as(u5, @intCast(2 * idx))) & 3;
                    index_anchor = if (subset_index != 0) bc7Anchor3[subset_index - 1][partition_set_idx] else 0;
                },
                else => {},
            }

            const anchor = idx == index_anchor;
            const num = [2]usize{
                mi.index_bits[0] - @intFromBool(anchor),
                if (has_index_bits1) mi.index_bits[1] - @intFromBool(anchor) else 0,
            };

            const index0: usize = bc7Peek(block, bit_pos + offset[0], num[0]);
            const index1: usize = if (has_index_bits1) bc7Peek(block, bit_pos + offset[1], num[1]) else index0;
            const index = [2]usize{ index0, index1 };

            offset[0] += num[0];
            offset[1] += num[1];

            const fc: u16 = factors[index_selection_mode][index[index_selection_mode]];
            const fa: u16 = factors[1 - index_selection_mode][index[1 - index_selection_mode]];

            subset_index *= 2;
            var rr: u8 = @intCast((@as(u16, ep_r[subset_index]) * (64 - fc) + @as(u16, ep_r[subset_index + 1]) * fc + 32) >> 6);
            var gg: u8 = @intCast((@as(u16, ep_g[subset_index]) * (64 - fc) + @as(u16, ep_g[subset_index + 1]) * fc + 32) >> 6);
            var bb: u8 = @intCast((@as(u16, ep_b[subset_index]) * (64 - fc) + @as(u16, ep_b[subset_index + 1]) * fc + 32) >> 6);
            var aa: u8 = @intCast((@as(u16, ep_a[subset_index]) * (64 - fa) + @as(u16, ep_a[subset_index + 1]) * fa + 32) >> 6);

            switch (rotation_mode) {
                1 => std.mem.swap(u8, &aa, &rr),
                2 => std.mem.swap(u8, &aa, &gg),
                3 => std.mem.swap(u8, &aa, &bb),
                else => {},
            }

            const px = bx * 4 + xx;
            const py = by * 4 + yy;
            if (px >= w or py >= h) continue;
            const dst = out[(py * w + px) * 4 ..][0..4];
            dst[0] = rr;
            dst[1] = gg;
            dst[2] = bb;
            dst[3] = aa;
        }
    }
}

test "etc1 individual mode flat color" {
    const a = std.testing.allocator;
    // individual: R1=15, R2=G=B=0, tables 0, flip 0, all index bits 0.
    // Sub-block 1 (x<2): c1 + 2 = (255, 2, 2); sub-block 2: c2 + 2 = (2, 2, 2).
    var block = [_]u8{ 0xF0, 0, 0, 0, 0, 0, 0, 0 };
    const out = try decode(a, format.etc_rgb4, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 2, 2, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 2, 2, 255 }, out[15 * 4 ..][0..4]);
}

test "etc2 differential mode" {
    const a = std.testing.allocator;
    // differential: R=G=B=31 (white), deltas 0, tables 0, idx 0:
    // base + 2 clamps to white everywhere.
    var block = [_]u8{ 0xF8, 0xF8, 0xF8, 0x02, 0, 0, 0, 0 };
    const out = try decode(a, format.etc2_rgb, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, out[15 * 4 ..][0..4]);
}

test "etc2 T-mode spec example" {
    const a = std.testing.allocator;
    // Khronos ETC2 spec T-mode example: base colors (13,1,8) and (4,12,13),
    // distance index 5 (d=32). All indices 0 -> paint color 0 = (221,17,136).
    var block = [_]u8{ 0xF9, 0x18, 0x4C, 0xDB, 0, 0, 0, 0 };
    const out = try decode(a, format.etc2_rgb, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 221, 17, 136, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 221, 17, 136, 255 }, out[15 * 4 ..][0..4]);
}

test "etc2 H-mode" {
    const a = std.testing.allocator;
    // H-mode block (values cross-checked against UnityPy's decoder):
    // base1 = (13,1,8), base2 = (4,12,13), da=1, db=0, cmp=1 (base1 > base2)
    // -> distance index 5, d = 32. All indices 0 -> paint color 0 = base1 + d.
    var bb = [_]u1{0} ** 64;
    putBits(&bb, 62, 59, 13, 4);
    putBits(&bb, 58, 56, 0, 3);
    putBits(&bb, 55, 53, 0b111, 3); // free bits -> G+dG out of range
    bb[52] = 1; // G0
    bb[51] = 1; // B3
    putBits(&bb, 50, 49, 0, 2);
    bb[48] = 1; // B1 (B2..0 = bits 49,48,47 in the reference layout)
    bb[47] = 0; // B0
    putBits(&bb, 46, 43, 4, 4); // R2
    putBits(&bb, 42, 40, 0b110, 3); // G2 3..1
    bb[39] = 0; // G2 0
    putBits(&bb, 38, 35, 13, 4); // B2
    bb[34] = 1; // da
    bb[33] = 1; // D bit
    bb[32] = 0; // db
    var hi: u64 = 0;
    for (0..32) |i| hi = (hi << 1) | bb[63 - i];
    var block: [8]u8 = undefined;
    std.mem.writeInt(u64, &block, hi << 32, .big);
    const out = try decode(a, format.etc2_rgb, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 253, 49, 202, 255 }, out[0..4]);
}

test "etc2 planar mode" {
    const a = std.testing.allocator;
    // Planar block with origin (12,64,62), horizontal (50,5,37), vertical
    // (40,112,45) in the reference bit layout; expected texels below are
    // cross-checked against UnityPy's decoder.
    var bb = [_]u1{0} ** 64;
    putBits(&bb, 62, 57, 12, 6);
    bb[56] = 1;
    putBits(&bb, 54, 49, 0, 6);
    bb[48] = 1;
    putBits(&bb, 44, 43, 0b11, 2);
    putBits(&bb, 41, 40, 0b11, 2);
    bb[39] = 0;
    bb[47] = 1; // free bits -> B+dB out of range (planar trigger)
    bb[46] = 1;
    bb[45] = 1;
    bb[42] = 0;
    putBits(&bb, 39, 35, 25, 5); // Rh5..1 = 50 >> 1
    bb[34] = 1; // D bit
    bb[32] = 0; // Rh0
    putBits(&bb, 31, 26, 5, 6);
    putBits(&bb, 24, 19, 37, 6);
    putBits(&bb, 19, 14, 40, 6);
    putBits(&bb, 13, 8, 112, 6);
    putBits(&bb, 5, 0, 45, 6);
    var hi: u64 = 0;
    var lo: u64 = 0;
    for (0..32) |i| hi = (hi << 1) | bb[63 - i];
    for (0..32) |i| lo = (lo << 1) | bb[31 - i];
    var block: [8]u8 = undefined;
    std.mem.writeInt(u64, &block, (hi << 32) | lo, .big);
    const out = try decode(a, format.etc2_rgb, 4, 4, &block);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 123, 106, 255, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 166, 30, 200, 255 }, out[15 * 4 ..][0..4]);
}

test "etc2a8 alpha block" {
    const a = std.testing.allocator;
    // EAC alpha: base=200, multiplier=5, table 0; indices 0..7,7..0 for
    // letters a..p; color block is plain white. Expected alpha values
    // cross-checked against UnityPy's decoder.
    var bits: u64 = 0;
    for (0..16) |letter| {
        const v: u6 = @intCast(if (letter < 8) letter else 15 - letter);
        bits |= @as(u64, v) << @intCast(45 - 3 * letter);
    }
    var block: [16]u8 = undefined;
    std.mem.writeInt(u64, block[0..8], (200 << 56) | (0x5 << 52) | bits, .big);
    std.mem.writeInt(u64, block[8..16], 0, .big);
    // color block: etc2 differential white
    std.mem.writeInt(u64, block[8..16], (31 << 59) | (31 << 51) | (31 << 43) | (1 << 33), .big);
    const out = try decode(a, format.etc2_rgba8, 4, 4, &block);
    defer a.free(out);
    const expected = [_]u8{ 185, 210, 255, 125, 170, 225, 240, 155, 155, 240, 225, 170, 125, 255, 210, 185 };
    for (0..16) |i| {
        try std.testing.expectEqual(expected[i], out[i * 4 + 3]);
        try std.testing.expectEqual(@as(u8, 255), out[i * 4]);
    }
}

test "bc4 single channel block" {
    const a = std.testing.allocator;
    // endpoints 0x10/0x20, indices 0..7 repeating; values in R channel,
    // replicated to gray. Cross-checked against UnityPy's decoder.
    var ind: u64 = 0;
    for (0..16) |i| ind |= @as(u64, i % 8) << @intCast(3 * i);
    var block: [8]u8 = undefined;
    std.mem.writeInt(u64, &block, (0x10 << 56) | (0x20 << 48) | ind, .big);
    const out = try decode(a, format.bc4, 4, 4, &block);
    defer a.free(out);
    const expected = [_]u8{ 19, 255, 22, 22, 25, 32, 19, 25, 19, 255, 22, 22, 25, 32, 19, 25 };
    for (0..16) |i| {
        try std.testing.expectEqual(expected[i], out[i * 4]);
        try std.testing.expectEqual(expected[i], out[i * 4 + 1]);
        try std.testing.expectEqual(expected[i], out[i * 4 + 2]);
    }
}

test "bc5 two channel block" {
    const a = std.testing.allocator;
    // two BC4-style channels: (0x10,0x20) and (0x30,0x38), same indices.
    var ind: u64 = 0;
    for (0..16) |i| ind |= @as(u64, i % 8) << @intCast(3 * i);
    var block: [16]u8 = undefined;
    std.mem.writeInt(u64, block[0..8], (0x10 << 56) | (0x20 << 48) | ind, .big);
    std.mem.writeInt(u64, block[8..16], (0x30 << 56) | (0x38 << 48) | ind, .big);
    const out = try decode(a, format.bc5, 4, 4, &block);
    defer a.free(out);
    const ch0 = [_]u8{ 19, 255, 22, 22, 25, 32, 19, 25, 19, 255, 22, 22, 25, 32, 19, 25 };
    const ch1 = [_]u8{ 49, 255, 51, 51, 52, 56, 49, 52, 49, 255, 51, 51, 52, 56, 49, 52 };
    for (0..16) |i| {
        try std.testing.expectEqual(ch0[i], out[i * 4]);
        try std.testing.expectEqual(ch1[i], out[i * 4 + 1]);
    }
}

/// Sets `n` bits of a bit array, MSB first, ending at `lo`.
fn putBits(bb: *[64]u1, hi: usize, lo: usize, val: u8, n: usize) void {
    _ = lo;
    for (0..n) |i| {
        bb[hi - i] = @intCast((val >> @intCast(n - 1 - i)) & 1);
    }
}

test "flipVertical mirrors rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 3 rows x 2 px, each pixel carries its row index in the R channel
    const rgba = try a.alloc(u8, 3 * 2 * 4);
    for (0..3) |row| {
        for (0..2) |x| {
            const p = (row * 2 + x) * 4;
            rgba[p] = @intCast(row);
            rgba[p + 1] = 0;
            rgba[p + 2] = 0;
            rgba[p + 3] = 255;
        }
    }
    const flipped = try flipVertical(a, rgba, 2, 3);
    try std.testing.expectEqual(@as(u8, 2), flipped[0]); // row 0 = old row 2
    try std.testing.expectEqual(@as(u8, 1), flipped[8]); // row 1 = old row 1
    try std.testing.expectEqual(@as(u8, 0), flipped[16]); // row 2 = old row 0
    try std.testing.expectError(error.BadSize, flipVertical(a, rgba, 2, 4));
}

test "dxt1/5 crunched route to the crash-stable decompressor" {
    // Format numbers 28/29 are Unity's DXT1Crunched / DXT5Crunched; the
    // crunched stream is variable-length so expectedSize reports "unknown"
    // (0), and a non-crunch payload must fail gracefully rather than panic.
    try std.testing.expectEqualStrings("DXT1Crunched", format.name(format.dxt1_crunched));
    try std.testing.expectEqualStrings("DXT5Crunched", format.name(format.dxt5_crunched));
    try std.testing.expectEqual(@as(?usize, 0), expectedSize(format.dxt1_crunched, 512, 512));
    try std.testing.expectEqual(@as(?usize, 0), expectedSize(format.dxt5_crunched, 512, 512));

    // A non-crunch byte stream (not a valid CRN header) must be rejected.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const garbage = try a.dupe(u8, "not a crunch stream, 8 bytes!");
    try std.testing.expectError(error.UnsupportedFormat, decode(a, format.dxt1_crunched, 4, 4, garbage));
    try std.testing.expectError(error.UnsupportedFormat, decode(a, format.dxt5_crunched, 4, 4, garbage));
}
