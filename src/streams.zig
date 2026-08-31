//! Endian-aware binary reader and writer over contiguous byte slices.
//!
//! Unity asset formats mix big-endian (older WebFile headers, some bundle
//! fields) and little-endian (most serialized data) fields, sometimes in
//! the same file. Every read/write primitive here is endian-explicit; a
//! `Reader` or `Writer` carries a default endianness that callers can flip
//! per call.
//!
//! All reads are bounds-checked and return `error.OutOfBounds` on a short
//! read. Slice-returning readers borrow from the underlying buffer; callers
//! that need an owned copy must allocate themselves. String readers that
//! must own their memory take an allocator.

const std = @import("std");

pub const Endian = std.builtin.Endian;

pub const ReadError = error{ OutOfBounds };

/// Bounds-checked cursor over a `[]const u8` buffer.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    endian: Endian = .little,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn at(self: *const Reader, data: []const u8, pos: usize) Reader {
        return .{ .data = data, .pos = pos, .endian = self.endian };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.data.len -| self.pos;
    }

    pub fn eof(self: *const Reader) bool {
        return self.pos >= self.data.len;
    }

    pub fn position(self: *const Reader) usize {
        return self.pos;
    }

    pub fn seek(self: *Reader, pos: usize) ReadError!void {
        if (pos > self.data.len) return error.OutOfBounds;
        self.pos = pos;
    }

    pub fn seekToEnd(self: *Reader) void {
        self.pos = self.data.len;
    }

    pub fn skip(self: *Reader, n: usize) ReadError!void {
        const new_pos = self.pos + n;
        if (new_pos > self.data.len) return error.OutOfBounds;
        self.pos = new_pos;
    }

    /// Advances to the next 4-byte boundary (used by aligned i64 fields in
    /// serialized files).
    pub fn alignTo4(self: *Reader) ReadError!void {
        const pad = (4 - (self.pos % 4)) % 4;
        try self.skip(pad);
    }

    /// Returns a borrowed slice of `n` bytes and advances the cursor.
    pub fn readSlice(self: *Reader, n: usize) ReadError![]const u8 {
        const new_pos = self.pos + n;
        if (new_pos > self.data.len) return error.OutOfBounds;
        const out = self.data[self.pos..new_pos];
        self.pos = new_pos;
        return out;
    }

    /// Returns the whole remaining buffer and consumes the reader.
    pub fn rest(self: *Reader) []const u8 {
        const out = self.data[self.pos..];
        self.pos = self.data.len;
        return out;
    }

    pub fn readByte(self: *Reader) ReadError!u8 {
        const slice = try self.readSlice(1);
        return slice[0];
    }

    /// Reads `comptime n` bytes into a fixed-size array.
    pub fn readBytes(self: *Reader, comptime n: usize) ReadError![n]u8 {
        const slice = try self.readSlice(n);
        var out: [n]u8 = undefined;
        @memcpy(&out, slice);
        return out;
    }

    pub fn readInt(self: *Reader, comptime T: type) ReadError!T {
        const bytes = try self.readBytes(@sizeOf(T));
        return std.mem.readInt(T, &bytes, self.endian);
    }

    pub fn readIntWith(self: *Reader, comptime T: type, endian: Endian) ReadError!T {
        const bytes = try self.readBytes(@sizeOf(T));
        return std.mem.readInt(T, &bytes, endian);
    }

    pub fn readFloat(self: *Reader, comptime T: type) ReadError!T {
        const bytes = try self.readBytes(@sizeOf(T));
        return @bitCast(std.mem.readInt(std.meta.Int(.unsigned, @sizeOf(T) * 8), &bytes, self.endian));
    }

    pub fn readFloatWith(self: *Reader, comptime T: type, endian: Endian) ReadError!T {
        const bytes = try self.readBytes(@sizeOf(T));
        return @bitCast(std.mem.readInt(std.meta.Int(.unsigned, @sizeOf(T) * 8), &bytes, endian));
    }

    /// Reads a 4-byte-aligned string: u32 length, `length` bytes, then
    /// zero padding to a 4-byte boundary. Returns an owned copy without the
    /// padding. The content itself is returned verbatim — Unity files often
    /// include a trailing NUL *inside* `length`; callers trim as needed.
    pub fn readAlignedString(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        const len = try self.readInt(u32);
        const raw = try self.readSlice(len);
        const pad = (4 - (len % 4)) % 4;
        try self.skip(pad);
        return try allocator.dupe(u8, raw);
    }

    /// Reads a NUL-terminated string and returns a borrowed slice excluding
    /// the terminator. `error.OutOfBounds` if the buffer ends first.
    pub fn readStringToNull(self: *Reader) ReadError![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len) : (self.pos += 1) {
            if (self.data[self.pos] == 0) {
                const out = self.data[start..self.pos];
                self.pos += 1; // consume the NUL
                return out;
            }
        }
        return error.OutOfBounds;
    }

    /// Reads a fixed-size 4-byte-aligned string field as used by Unity's
    /// class names: u32 length (including NUL), bytes, padding to 4.
    /// Returns a borrowed slice of `length` bytes.
    pub fn readAlignedStringBorrow(self: *Reader) ReadError![]const u8 {
        const len = try self.readInt(u32);
        const raw = try self.readSlice(len);
        const pad = (4 - (len % 4)) % 4;
        try self.skip(pad);
        return raw;
    }

    /// Reads `n` bytes, returning `null` (without advancing) when fewer
    /// than `n` remain.
    pub fn tryReadSlice(self: *Reader, n: usize) ?[]const u8 {
        const new_pos = self.pos + n;
        if (new_pos > self.data.len) return null;
        const out = self.data[self.pos..new_pos];
        self.pos = new_pos;
        return out;
    }

    /// Peeks at the next `n` bytes without advancing.
    pub fn peek(self: *const Reader, n: usize) ReadError![]const u8 {
        const new_pos = self.pos + n;
        if (new_pos > self.data.len) return error.OutOfBounds;
        return self.data[self.pos..new_pos];
    }

    pub fn peekByte(self: *const Reader) ReadError!u8 {
        return (try self.peek(1))[0];
    }
};

/// Growable endian-aware writer backed by an allocator.
///
/// Zig 0.16's `std.ArrayList` takes the allocator per operation, so the
/// writer keeps its own copy.
pub const Writer = struct {
    endian: Endian = .little,
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator, .buf = .empty };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn getWritten(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    pub fn reset(self: *Writer) void {
        self.buf.items.len = 0;
    }

    pub fn writeByte(self: *Writer, b: u8) !void {
        try self.buf.append(self.allocator, b);
    }

    pub fn writeBytes(self: *Writer, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// Formats `args` per `fmt` and appends the result.
    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.writeBytes(s);
    }

    pub fn writeInt(self: *Writer, comptime T: type, value: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, self.endian);
        try self.writeBytes(&tmp);
    }

    pub fn writeIntWith(self: *Writer, comptime T: type, value: T, endian: Endian) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, endian);
        try self.writeBytes(&tmp);
    }

    pub fn writeFloat(self: *Writer, comptime T: type, value: T) !void {
        const bits: std.meta.Int(.unsigned, @sizeOf(T) * 8) = @bitCast(value);
        try self.writeInt(std.meta.Int(.unsigned, @sizeOf(T) * 8), bits);
    }

    /// Writes a 4-byte-aligned string: u32 length, bytes, NUL, padding.
    /// `s` is the content; a NUL terminator is appended and counted in the
    /// length, matching Unity's aligned string convention.
    pub fn writeAlignedString(self: *Writer, s: []const u8) !void {
        const len = @as(u32, @intCast(s.len + 1)); // include NUL, like Unity writes it
        try self.writeInt(u32, len);
        try self.writeBytes(s);
        try self.writeByte(0);
        const pad = (4 - (len % 4)) % 4;
        const zeros = [_]u8{0} ** 4;
        try self.writeBytes(zeros[0..pad]);
    }

    /// Writes a NUL-terminated string without alignment.
    pub fn writeStringToNull(self: *Writer, s: []const u8) !void {
        try self.writeBytes(s);
        try self.writeByte(0);
    }

    /// Pads with zero bytes until the total length is a multiple of 4.
    pub fn alignTo4(self: *Writer) !void {
        const pad = (4 - (self.buf.items.len % 4)) % 4;
        const zeros = [_]u8{0} ** 4;
        try self.writeBytes(zeros[0..pad]);
    }

    /// Pads with zero bytes until the total length is a multiple of `n`.
    pub fn alignTo(self: *Writer, comptime n: usize) !void {
        const pad = (n - (self.buf.items.len % n)) % n;
        const zeros = [_]u8{0} ** n;
        try self.writeBytes(zeros[0..pad]);
    }
};

test "reader out of bounds" {
    var r = Reader.init("ab");
    try std.testing.expectEqual(@as(u8, 'a'), try r.readByte());
    try std.testing.expectEqual(@as(u8, 'b'), try r.readByte());
    try std.testing.expectError(error.OutOfBounds, r.readByte());
    try std.testing.expectError(error.OutOfBounds, r.readSlice(1));
    try std.testing.expect(r.eof());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "reader little endian integers" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e };
    var r = Reader.init(&bytes);
    try std.testing.expectEqual(@as(u16, 0x0201), try r.readInt(u16));
    try std.testing.expectEqual(@as(u32, 0x06050403), try r.readInt(u32));
    try std.testing.expectEqual(@as(u64, 0x0e0d0c0b0a090807), try r.readInt(u64));
    try std.testing.expect(r.eof());
}

test "reader big endian integers" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var r = Reader.init(&bytes);
    r.endian = .big;
    try std.testing.expectEqual(@as(u32, 0x01020304), try r.readInt(u32));
}

test "reader floats" {
    const bytes = [_]u8{ 0x00, 0x00, 0x80, 0x3f };
    var r = Reader.init(&bytes);
    try std.testing.expectEqual(@as(f32, 1.0), try r.readFloat(f32));
}

test "reader aligned string" {
    // "abc\0" + 0 padding: len=4, then abc\0
    var r = Reader.init("\x04\x00\x00\x00abc\x00");
    const s = try r.readAlignedString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("abc\x00", s);
    try std.testing.expect(r.eof());

    // "abcdefgh" + NUL: len=9, 9 bytes, 3 bytes padding
    var r2 = Reader.init("\x09\x00\x00\x00abcdefgh\x00\x00\x00\x00");
    const s2 = try r2.readAlignedString(std.testing.allocator);
    defer std.testing.allocator.free(s2);
    try std.testing.expectEqualStrings("abcdefgh\x00", s2);
    try std.testing.expect(r2.eof());
}

test "reader string to null" {
    var r = Reader.init("hello\x00world\x00");
    try std.testing.expectEqualStrings("hello", try r.readStringToNull());
    try std.testing.expectEqualStrings("world", try r.readStringToNull());
    try std.testing.expect(r.eof());
}

test "reader seek skip peek" {
    var r = Reader.init("abcdef");
    try r.skip(2);
    try std.testing.expectEqual(@as(usize, 2), r.pos);
    try std.testing.expectEqualStrings("cd", try r.peek(2));
    try std.testing.expectEqual(@as(usize, 2), r.pos);
    try std.testing.expectEqual(@as(u8, 'c'), try r.readByte());
    try r.seek(0);
    try std.testing.expectEqual(@as(u8, 'a'), try r.readByte());
}

test "writer round trip little endian" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeInt(u16, 0x0201);
    try w.writeInt(u32, 0x06050403);
    try w.writeFloat(f32, 1.0);
    try w.writeByte(0xff);
    try w.writeAlignedString("hi");
    try w.writeStringToNull("z");

    var r = Reader.init(w.getWritten());
    try std.testing.expectEqual(@as(u16, 0x0201), try r.readInt(u16));
    try std.testing.expectEqual(@as(u32, 0x06050403), try r.readInt(u32));
    try std.testing.expectEqual(@as(f32, 1.0), try r.readFloat(f32));
    try std.testing.expectEqual(@as(u8, 0xff), try r.readByte());
    const s = try r.readAlignedString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hi\x00", s);
    try std.testing.expectEqualStrings("z", try r.readStringToNull());
    try std.testing.expect(r.eof());
}

test "writer big endian" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    w.endian = .big;
    try w.writeInt(u32, 0x01020304);
    var r = Reader.init(w.getWritten());
    r.endian = .big;
    try std.testing.expectEqual(@as(u32, 0x01020304), try r.readInt(u32));
}
