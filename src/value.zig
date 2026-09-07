//! Generic Unity object value model.
//!
//! The type-tree-driven object reader produces these values; typed classes
//! and the JSON dump consume them. All slices/arrays are allocated from the
//! caller's allocator (an arena is the intended usage); `bytes`/`string`
//! borrow from the object's source bytes.

const std = @import("std");

/// A reference to another object (`PPtr<T>`): a file index plus a path ID.
pub const PPtr = struct {
    /// 0 = same file, > 0 a 1-based index into the externals table.
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

/// Finds a named field in a `.obj` value, or null.
pub fn fieldOf(v: Value, name: []const u8) ?Value {
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

/// Typed accessors for a named field of a `.obj` value. Each yields null
/// when the field is missing or holds a different variant, so a caller can
/// fall back without walking the tree itself. They live here, next to
/// `Value`, rather than in one of the parsers, so every module that reads a
/// value tree shares one implementation.
pub fn intField(v: Value, name: []const u8) ?i64 {
    return (fieldOf(v, name) orelse return null).asInt();
}

pub fn boolField(v: Value, name: []const u8) ?bool {
    return switch (fieldOf(v, name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn stringField(v: Value, name: []const u8) ?[]const u8 {
    return switch (fieldOf(v, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn floatField(v: Value, name: []const u8) ?f64 {
    return switch (fieldOf(v, name) orelse return null) {
        .float => |f| f,
        else => null,
    };
}

pub fn bytesField(v: Value, name: []const u8) ?[]const u8 {
    return switch (fieldOf(v, name) orelse return null) {
        .bytes => |b| b,
        else => null,
    };
}

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

/// Nesting limit for `jsonParse`. The parser recurses once per
/// `[`/`{`, so without a bound a deeply nested literal overflows the stack
/// instead of reporting a bad patch. Mirrors `typetree.max_depth`.
const max_json_depth: u32 = 512;

/// Parses JSON text into a value tree: the inverse of `jsonWrite`, so an
/// exported object can be read back and re-serialized. Ints, floats,
/// bools, null, quoted strings (escapes decoded, including surrogate
/// pairs) and nested arrays/objects; `.bytes` and `.pptr` come back as
/// their JSON shapes (a base64 string, an object), since JSON does not
/// carry the distinction.
///
/// Everything is allocated from `allocator` (an arena is the intended
/// usage, as elsewhere in the library) and borrows nothing from `text`.
pub fn jsonParse(allocator: std.mem.Allocator, text: []const u8) !Value {
    var pos: usize = 0;
    const v = try jsonParseValue(text, &pos, 0, allocator);
    skipWs(text, &pos);
    if (pos != text.len) return error.TrailingInput;
    return v;
}

/// Reads the four hex digits of a `\uXXXX` escape. `pos` points at the `u`
/// on entry and at the last hex digit on return, so the caller's single
/// `pos += 1` steps past the whole escape.
fn readHex4(text: []const u8, pos: *usize) !u16 {
    if (pos.* + 5 > text.len) return error.BadEscape;
    var v: u16 = 0;
    for (text[pos.* + 1 ..][0..4]) |ch| {
        const d = std.fmt.charToDigit(ch, 16) catch return error.BadEscape;
        v = (v << 4) | d;
    }
    pos.* += 4;
    return v;
}

fn jsonParseValue(text: []const u8, pos: *usize, depth: u32, allocator: std.mem.Allocator) !Value {
    if (depth > max_json_depth) return error.TooDeep;
    skipWs(text, pos);
    if (pos.* >= text.len) return error.UnexpectedEnd;
    const c = text[pos.*];
    if (c == '"') {
        pos.* += 1;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        while (pos.* < text.len and text[pos.*] != '"') {
            if (text[pos.*] == '\\') {
                pos.* += 1;
                if (pos.* >= text.len) return error.BadEscape;
                // Decode the escape rather than keeping the escaped byte:
                // `jsonString` above writes \n/\r/\t and \uXXXX for the C0
                // controls (Unity strings carry trailing NULs), so an
                // `extract --json` export fed back through `edit --patch`
                // has to decode them to round-trip byte-exactly.
                switch (text[pos.*]) {
                    '"' => try out.append(allocator, '"'),
                    '\\' => try out.append(allocator, '\\'),
                    '/' => try out.append(allocator, '/'),
                    'b' => try out.append(allocator, 0x08),
                    'f' => try out.append(allocator, 0x0c),
                    'n' => try out.append(allocator, '\n'),
                    'r' => try out.append(allocator, '\r'),
                    't' => try out.append(allocator, '\t'),
                    'u' => {
                        var cp: u21 = try readHex4(text, pos);
                        if (cp >= 0xd800 and cp <= 0xdbff) {
                            // high surrogate: pair it with the low one
                            if (pos.* + 2 >= text.len or text[pos.* + 1] != '\\' or text[pos.* + 2] != 'u') return error.BadEscape;
                            pos.* += 2;
                            const lo: u21 = try readHex4(text, pos);
                            if (lo < 0xdc00 or lo > 0xdfff) return error.BadEscape;
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        } else if (cp >= 0xdc00 and cp <= 0xdfff) {
                            return error.BadEscape;
                        }
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadEscape;
                        try out.appendSlice(allocator, buf[0..n]);
                    },
                    else => return error.BadEscape,
                }
            } else {
                try out.append(allocator, text[pos.*]);
            }
            pos.* += 1;
        }
        if (pos.* >= text.len) return error.UnterminatedString;
        pos.* += 1;
        return .{ .string = try out.toOwnedSlice(allocator) };
    }
    if (c == '[') {
        pos.* += 1;
        var list: std.ArrayList(Value) = .empty;
        defer list.deinit(allocator);
        skipWs(text, pos);
        if (pos.* < text.len and text[pos.*] == ']') {
            pos.* += 1;
            return .{ .array = try list.toOwnedSlice(allocator) };
        }
        while (true) {
            try list.append(allocator, try jsonParseValue(text, pos, depth + 1, allocator));
            skipWs(text, pos);
            if (pos.* >= text.len) return error.UnterminatedArray;
            if (text[pos.*] == ',') {
                pos.* += 1;
                continue;
            }
            if (text[pos.*] == ']') {
                pos.* += 1;
                break;
            }
            return error.BadArray;
        }
        return .{ .array = try list.toOwnedSlice(allocator) };
    }
    if (c == '{') {
        pos.* += 1;
        var list: std.ArrayList(Field) = .empty;
        defer list.deinit(allocator);
        skipWs(text, pos);
        if (pos.* < text.len and text[pos.*] == '}') {
            pos.* += 1;
            return .{ .obj = try list.toOwnedSlice(allocator) };
        }
        while (true) {
            skipWs(text, pos);
            if (pos.* >= text.len or text[pos.*] != '"') return error.BadObject;
            const key = try jsonParseValue(text, pos, depth + 1, allocator);
            skipWs(text, pos);
            if (pos.* >= text.len or text[pos.*] != ':') return error.BadObject;
            pos.* += 1;
            const val = try jsonParseValue(text, pos, depth + 1, allocator);
            try list.append(allocator, .{ .name = key.string, .value = val });
            skipWs(text, pos);
            if (pos.* >= text.len) return error.UnterminatedObject;
            if (text[pos.*] == ',') {
                pos.* += 1;
                continue;
            }
            if (text[pos.*] == '}') {
                pos.* += 1;
                break;
            }
            return error.BadObject;
        }
        return .{ .obj = try list.toOwnedSlice(allocator) };
    }
    // number or keyword
    const start = pos.*;
    while (pos.* < text.len) : (pos.* += 1) {
        const ch = text[pos.*];
        if (ch == ',' or ch == ']' or ch == '}' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') break;
    }
    const token = text[start..pos.*];
    if (std.mem.eql(u8, token, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, token, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, token, "null")) return .null;
    if (std.mem.indexOfAny(u8, token, ".eE") != null) {
        return .{ .float = try std.fmt.parseFloat(f64, token) };
    }
    // `-0` only exists as a float (Unity exports negative-zero rotations
    // and positions); an integer parse would drop the sign.
    if (std.mem.eql(u8, token, "-0")) return .{ .float = -0.0 };
    // `.uint` spans the whole u64 range and `jsonWrite` emits it in full, so
    // an i64-only parse cannot read back what this module writes: a UInt64
    // field above maxInt(i64) came out of `extract --json` as a plain decimal
    // and returned as `error.Overflow` from `edit --patch`. Fall back to the
    // unsigned variant for exactly that range, keeping `.int` for everything
    // an i64 holds so the common case is unchanged.
    const signed = std.fmt.parseInt(i64, token, 10) catch |err| switch (err) {
        error.Overflow => return .{ .uint = try std.fmt.parseInt(u64, token, 10) },
        else => return err,
    };
    return .{ .int = signed };
}

fn skipWs(text: []const u8, pos: *usize) void {
    while (pos.* < text.len) : (pos.* += 1) {
        const c = text[pos.*];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
    }
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

test "jsonParse round-trips jsonWrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"m_Enabled":true,"m_Name":"a\\u0000b","n":-0,"i":7,"f":1.5,"a":[1,null,{}],"e":[],"u":18446744073709551615}
    ;
    const v = try jsonParse(arena.allocator(), text);
    // A UInt64 field past maxInt(i64) has to come back as `.uint`, not fail:
    // `jsonWrite` emits the full u64 range.
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), fieldOf(v, "u").?.uint);
    try std.testing.expectEqual(@as(i64, 7), fieldOf(v, "i").?.int);

    var buf: [512]u8 = undefined;
    var bw = std.Io.Writer.fixed(&buf);
    try jsonWrite(v, &bw);
    try std.testing.expectEqualStrings(text, bw.buffered());
}

test "jsonParse rejects malformed input" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.TrailingInput, jsonParse(a, "1 2"));
    try std.testing.expectError(error.UnexpectedEnd, jsonParse(a, "  "));
    try std.testing.expectError(error.UnterminatedString, jsonParse(a, "\"abc"));
    try std.testing.expectError(error.BadObject, jsonParse(a, "{1:2}"));
    try std.testing.expectError(error.UnterminatedArray, jsonParse(a, "[1"));
    try std.testing.expectError(error.BadEscape, jsonParse(a, "\"\\ud800\""));
    // lone low surrogate, and a high surrogate whose partner is not one
    try std.testing.expectError(error.BadEscape, jsonParse(a, "\"\\udc00\""));
    try std.testing.expectError(error.BadEscape, jsonParse(a, "\"\\ud800\\u0041\""));
    // a truncated \uXXXX escape must not read past the end of the text
    try std.testing.expectError(error.BadEscape, jsonParse(a, "\"\\u12\""));
    try std.testing.expectError(error.BadEscape, jsonParse(a, "\"\\uzzzz\""));
    try std.testing.expectError(error.BadEscape, jsonParse(a, "\"\\q\""));
}

test "jsonParse decodes surrogate pairs and bounds nesting depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A patch file is untrusted text, so the pair has to decode rather than
    // land in the tree as two escapes: U+1F600 as the pair d83d/de00.
    const pair = try jsonParse(a, "\"a\\ud83d\\ude00b\"");
    try std.testing.expectEqualStrings("a\u{1f600}b", pair.string);
    // A BMP escape decodes to its UTF-8 bytes, not to the literal escape.
    const bmp = try jsonParse(a, "\"\\u00e9\\u0000\"");
    try std.testing.expectEqualSlices(u8, "\xc3\xa9\x00", bmp.string);

    // `jsonParseValue` recurses once per `[`/`{`, so the depth bound is what
    // keeps a hostile patch from overflowing the stack instead of reporting
    // a bad patch. Well inside the bound still parses.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const ok_depth = max_json_depth / 2;
    try buf.appendNTimes(a, '[', ok_depth);
    try buf.appendNTimes(a, ']', ok_depth);
    var deep = try jsonParse(a, buf.items);
    var levels: u32 = 1;
    while (deep.array.len == 1) : (levels += 1) deep = deep.array[0];
    try std.testing.expectEqual(ok_depth, levels);

    // Past it, the parser reports TooDeep rather than recursing.
    buf.clearRetainingCapacity();
    const bad_depth = max_json_depth + 2;
    try buf.appendNTimes(a, '[', bad_depth);
    try buf.appendNTimes(a, ']', bad_depth);
    try std.testing.expectError(error.TooDeep, jsonParse(a, buf.items));
    // Objects recurse through the same counter.
    buf.clearRetainingCapacity();
    for (0..bad_depth) |_| try buf.appendSlice(a, "{\"a\":");
    try buf.appendSlice(a, "1");
    try buf.appendNTimes(a, '}', bad_depth);
    try std.testing.expectError(error.TooDeep, jsonParse(a, buf.items));
}
