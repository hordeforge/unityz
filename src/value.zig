//! Generic Unity object value model.
//!
//! The type-tree-driven object reader produces these values; typed classes
//! and the JSON dump consume them. All slices/arrays are allocated from the
//! caller's allocator (an arena is the intended usage); `bytes`/`string`
//! borrow from the object's source bytes.

const std = @import("std");

/// A reference to another object (`PPtr<T>`): a file index plus a path ID.
pub const PPtr = struct {
    /// 0 = same file, > 0 = index into the externals table.
    file_id: i32,
    path_id: i64,

    pub fn isNull(self: PPtr) bool {
        return self.path_id == 0;
    }
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
    array: []const Value,
    /// Ordered named fields.
    obj: []const Field,
    pptr: PPtr,

    /// Number of direct children, for tree-walking callers.
    pub fn childCount(self: Value) usize {
        return switch (self) {
            .array => |a| a.len,
            .obj => |o| o.len,
            else => 0,
        };
    }

    /// Accessor for callers that want a scalar-ish view: ints and uints
    /// both report as int64 when they fit.
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |v| v,
            .uint => |v| if (v <= std.math.maxInt(i64)) @intCast(v) else null,
            .bool => |b| @intFromBool(b),
            else => null,
        };
    }

    /// Float view of a scalar: floats directly, ints/uints widened.
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            .uint => |u| @floatFromInt(u),
            else => null,
        };
    }
};

/// Writes `v` as compact JSON to `writer` (any type with writeByte /
/// writeAll / print). Bytes are rendered as base64; PPtrs as small objects.
pub fn jsonWrite(v: Value, writer: anytype) !void {
    switch (v) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .uint => |u| try writer.print("{d}", .{u}),
        // JSON has no NaN/Infinity literal, and "{d}" would emit the bare
        // words `nan`/`inf`, which no conforming parser accepts. Float
        // fields are bit-cast straight from the file, so any bit pattern
        // reaches here. Emit null, as JSON.stringify does.
        .float => |f| if (std.math.isFinite(f))
            try writer.print("{d}", .{f})
        else
            try writer.writeAll("null"),
        .string => |s| try jsonString(s, writer),
        .bytes => |b| {
            try writer.writeAll("\"");
            try writer.print("{b64}", .{b});
            try writer.writeAll("\"");
        },
        .array => |a| {
            try writer.writeAll("[");
            for (a, 0..) |item, i| {
                if (i != 0) try writer.writeAll(",");
                try jsonWrite(item, writer);
            }
            try writer.writeAll("]");
        },
        .obj => |o| {
            try writer.writeAll("{");
            for (o, 0..) |f, i| {
                if (i != 0) try writer.writeAll(",");
                try jsonString(f.name, writer);
                try writer.writeAll(":");
                try jsonWrite(f.value, writer);
            }
            try writer.writeAll("}");
        },
        .pptr => |p| try writer.print("{{\"m_FileID\":{d},\"m_PathID\":{d}}}", .{ p.file_id, p.path_id }),
    }
}

fn jsonString(s: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // remaining C0 controls and DEL: \uXXXX (Unity strings often
            // carry trailing NULs, e.g. MonoScript class names)
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                var buf: [8]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try writer.writeAll(hex);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "value json" {
    const v = Value{ .obj = &[_]Field{
        .{ .name = "m_Enabled", .value = .{ .bool = true } },
        .{ .name = "m_Script", .value = .{ .pptr = .{ .file_id = 0, .path_id = 123 } } },
        .{ .name = "m_Name", .value = .{ .string = "Player\"X" } },
        .{ .name = "count", .value = .{ .int = 7 } },
    } };
    var buf: [512]u8 = undefined;
    var bw = std.Io.Writer.fixed(&buf);
    try jsonWrite(v, &bw);
    try std.testing.expectEqualStrings(
        "{\"m_Enabled\":true,\"m_Script\":{\"m_FileID\":0,\"m_PathID\":123},\"m_Name\":\"Player\\\"X\",\"count\":7}",
        bw.buffered(),
    );
}

test "value json escapes control characters" {
    const v = Value{ .obj = &[_]Field{
        .{ .name = "m_ClassName", .value = .{ .string = "MyGame\x00" } },
        .{ .name = "m_Tab", .value = .{ .string = "a\x01b" } },
        .{ .name = "m_Del", .value = .{ .string = "c\x7f" } },
    } };
    var buf: [512]u8 = undefined;
    var bw = std.Io.Writer.fixed(&buf);
    try jsonWrite(v, &bw);
    try std.testing.expectEqualStrings(
        "{\"m_ClassName\":\"MyGame\\u0000\",\"m_Tab\":\"a\\u0001b\",\"m_Del\":\"c\\u007f\"}",
        bw.buffered(),
    );
}

test "value accessors" {
    try std.testing.expectEqual(@as(?i64, 5), (Value{ .int = 5 }).asInt());
    try std.testing.expectEqual(@as(?i64, 1), (Value{ .bool = true }).asInt());
    try std.testing.expect((Value{ .uint = std.math.maxInt(u64) }).asInt() == null);
    const null_value: Value = .null;
    try std.testing.expectEqual(@as(usize, 0), null_value.childCount());
    const v = Value{ .array = &[_]Value{ .{ .int = 1 }, .{ .int = 2 } } };
    try std.testing.expectEqual(@as(usize, 2), v.childCount());
}
