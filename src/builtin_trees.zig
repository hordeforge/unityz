//! Built-in engine-class type trees, indexed by Unity release.
//!
//! A player build strips the type trees from its serialized files, and a
//! brand-new object has no file to borrow a tree from. Unity's own class
//! layouts for a release are public through the AssetRipper TypeTreeDumps
//! project; `scripts/structsdump-to-builtin.py` packs one release's dump
//! into `builtin_trees/<release>.bin` (layout documented there), and this
//! module embeds those files and serves a class tree for an exact
//! `(release, class id)` pair.
//!
//! Matching is exact by release string ("2022.3.62f2"). There is no
//! nearest-version guessing: a tree from a neighbouring release can differ
//! in a field and decode garbage silently, so an unknown release is an
//! error the caller can report with the shipped list from `releases`.
//!
//! MonoBehaviour (class 114) resolves to the plain header only; script
//! fields come from managed assemblies (`managed_trees`), not from here.

const std = @import("std");
const typetree = @import("typetree.zig");

const Release = struct { name: []const u8, data: []const u8 };

/// Every shipped release. Add a line here after packing a new dump.
const table = [_]Release{
    .{ .name = "2022.3.62f2", .data = @embedFile("builtin_trees/2022.3.62f2.bin") },
};

pub const Error = error{ UnknownRevision, UnknownClass, Corrupt, OutOfMemory };

const magic = "UZBT";
const format: u8 = 1;
const class_entry_len = 4 + 2 + 4 + 4;
const node_entry_len = 1 + 1 + 2 + 4 + 4 + 2 + 2;

/// The shipped release names, in table order.
pub fn releases() []const []const u8 {
    const names = comptime blk: {
        var n: [table.len][]const u8 = undefined;
        for (table, 0..) |r, i| n[i] = r.name;
        break :blk n;
    };
    return &names;
}

pub const ClassEntry = struct { class_id: i32, name: []const u8, first_node: u32, node_count: u32 };

/// One release's decoded table: string table and class index borrow from
/// the embedded bytes; only the small string/class arrays are allocated.
pub const Db = struct {
    release: []const u8,
    strings: []const []const u8,
    classes: []const ClassEntry,
    nodes: []const u8,

    /// The built-in tree for `class_id`, or `error.UnknownClass`.
    pub fn tree(self: *const Db, allocator: std.mem.Allocator, class_id: i32) Error!typetree.TypeTree {
        const c = self.class(class_id) orelse return error.UnknownClass;
        const flat = allocator.alloc(typetree.Node, c.node_count) catch return error.OutOfMemory;
        defer allocator.free(flat);
        for (flat, 0..) |*n, i| {
            const off = (c.first_node + i) * node_entry_len;
            const e = self.nodes[off..][0..node_entry_len];
            n.* = .{
                .level = e[0],
                .type_flags = e[1],
                .version = std.mem.readInt(i16, e[2..4], .little),
                .byte_size = std.mem.readInt(i32, e[4..8], .little),
                .meta_flags = @bitCast(std.mem.readInt(u32, e[8..12], .little)),
                .type_name = try self.string(std.mem.readInt(u16, e[12..14], .little)),
                .name = try self.string(std.mem.readInt(u16, e[14..16], .little)),
                .index = @intCast(i),
            };
        }
        return typetree.fromFlatNodes(allocator, flat) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Corrupt,
        };
    }

    pub fn class(self: *const Db, class_id: i32) ?*const ClassEntry {
        for (self.classes) |*c| if (c.class_id == class_id) return c;
        return null;
    }

    /// Frees the two arrays `decode` allocated (a no-op under an arena).
    pub fn deinit(self: *Db, allocator: std.mem.Allocator) void {
        allocator.free(self.strings);
        allocator.free(self.classes);
        self.* = undefined;
    }

    fn string(self: *const Db, idx: u16) Error![]const u8 {
        if (idx >= self.strings.len) return error.Corrupt;
        return self.strings[idx];
    }
};

/// Opens the shipped database for `release`, or `error.UnknownRevision`.
pub fn open(allocator: std.mem.Allocator, release: []const u8) Error!Db {
    for (table) |r| {
        if (std.mem.eql(u8, r.name, release)) return decode(allocator, r.data);
    }
    return error.UnknownRevision;
}

/// Looks up one class tree; arena-style allocation like `typetree.parse`.
pub fn lookup(allocator: std.mem.Allocator, release: []const u8, class_id: i32) Error!typetree.TypeTree {
    var db = try open(allocator, release);
    defer db.deinit(allocator);
    return db.tree(allocator, class_id);
}

fn decode(allocator: std.mem.Allocator, data: []const u8) Error!Db {
    var pos: usize = 0;
    if (data.len < 6 or !std.mem.eql(u8, data[0..4], magic) or data[4] != format) return error.Corrupt;
    const rel_len = data[5];
    pos = 6;
    const release = try slice(data, &pos, rel_len);

    const string_count = try readU32(data, &pos);
    if (string_count > 0xFFFF) return error.Corrupt;
    const strings = allocator.alloc([]const u8, string_count) catch return error.OutOfMemory;
    errdefer allocator.free(strings);
    for (strings) |*s| {
        const len = try readU16(data, &pos);
        s.* = try slice(data, &pos, len);
    }

    const class_count = try readU32(data, &pos);
    if (class_count > data.len / class_entry_len) return error.Corrupt;
    const classes = allocator.alloc(ClassEntry, class_count) catch return error.OutOfMemory;
    errdefer allocator.free(classes);
    for (classes) |*c| {
        const e = try slice(data, &pos, class_entry_len);
        const name_idx = std.mem.readInt(u16, e[4..6], .little);
        if (name_idx >= strings.len) return error.Corrupt;
        c.* = .{
            .class_id = std.mem.readInt(i32, e[0..4], .little),
            .name = strings[name_idx],
            .first_node = std.mem.readInt(u32, e[6..10], .little),
            .node_count = std.mem.readInt(u32, e[10..14], .little),
        };
    }

    const node_count = try readU32(data, &pos);
    if (node_count > data.len / node_entry_len) return error.Corrupt;
    const nodes = try slice(data, &pos, node_count * node_entry_len);
    if (pos != data.len) return error.Corrupt;
    for (classes) |c| {
        if (c.node_count == 0 or c.first_node > node_count or c.node_count > node_count - c.first_node) return error.Corrupt;
    }
    return .{ .release = release, .strings = strings, .classes = classes, .nodes = nodes };
}

fn slice(data: []const u8, pos: *usize, len: usize) Error![]const u8 {
    if (len > data.len - pos.*) return error.Corrupt;
    const s = data[pos.*..][0..len];
    pos.* += len;
    return s;
}

fn readU16(data: []const u8, pos: *usize) Error!u16 {
    const s = try slice(data, pos, 2);
    return std.mem.readInt(u16, s[0..2], .little);
}

fn readU32(data: []const u8, pos: *usize) Error!u32 {
    const s = try slice(data, pos, 4);
    return std.mem.readInt(u32, s[0..4], .little);
}

test "shipped releases decode and their header names match the table" {
    for (table) |r| {
        var db = try decode(std.testing.allocator, r.data);
        defer db.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(r.name, db.release);
        try std.testing.expect(db.classes.len > 100);
        // every class tree links into one well-formed tree rooted at Base
        // (a few classes reuse a base layout, so the root type may differ
        // from the class name: ShaderInclude serializes as TextAsset)
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        for (db.classes) |c| {
            const t = try db.tree(arena.allocator(), c.class_id);
            try std.testing.expectEqual(@as(usize, 1), t.roots.len);
            try std.testing.expectEqualStrings("Base", t.roots[0].name);
        }
    }
}

test "lookup returns the exact 2022.3.62f2 layouts the pipeline writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tex = try lookup(a, "2022.3.62f2", 28);
    const root = root_check: {
        try std.testing.expectEqualStrings("Texture2D", tex.roots[0].type_name);
        break :root_check tex.roots[0];
    };
    try std.testing.expectEqualStrings("m_Name", root.children[0].name);
    try std.testing.expectEqualStrings("string", root.children[0].type_name);
    try std.testing.expect(hasChild(root, "m_Width"));
    try std.testing.expect(hasChild(root, "m_TextureFormat"));
    try std.testing.expect(hasChild(root, "m_StreamData"));
    try std.testing.expectEqual(@as(i32, 2), root.version); // Texture2D serializedVersion 2 in 2022.3
    try std.testing.expectEqual(@as(i32, 4), root.children[0].children[0].children[0].byte_size); // m_Name Array size int

    const go = try lookup(a, "2022.3.62f2", 1);
    try std.testing.expectEqualStrings("GameObject", go.roots[0].type_name);
    try std.testing.expectEqualStrings("m_Component", go.roots[0].children[0].name);
    try std.testing.expectEqual(@as(i32, 1), go.roots[0].children[0].children[0].type_flags); // Array node flagged
    try std.testing.expect(hasChild(go.roots[0], "m_Layer"));
    try std.testing.expect(hasChild(go.roots[0], "m_IsActive"));

    const tr = try lookup(a, "2022.3.62f2", 4);
    try std.testing.expectEqualStrings("Transform", tr.roots[0].type_name);
    try std.testing.expect(hasChild(tr.roots[0], "m_LocalRotation"));
    try std.testing.expect(hasChild(tr.roots[0], "m_Father"));

    const ab = try lookup(a, "2022.3.62f2", 142);
    try std.testing.expectEqualStrings("AssetBundle", ab.roots[0].type_name);
    try std.testing.expect(hasChild(ab.roots[0], "m_Container"));
    try std.testing.expect(hasChild(ab.roots[0], "m_PreloadTable"));
}

test "lookup rejects an unknown revision and an unavailable class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UnknownRevision, lookup(a, "2021.3.45f2", 28));
    try std.testing.expectError(error.UnknownRevision, lookup(a, "", 28));
    // class 0 (Object) is abstract and has no tree; 999999 does not exist
    try std.testing.expectError(error.UnknownClass, lookup(a, "2022.3.62f2", 0));
    try std.testing.expectError(error.UnknownClass, lookup(a, "2022.3.62f2", 999999));
    try std.testing.expectEqual(@as(usize, 1), releases().len);
    try std.testing.expectEqualStrings("2022.3.62f2", releases()[0]);
}

test "decode rejects a corrupt database" {
    const a = std.testing.allocator;
    const good = table[0].data;
    try std.testing.expectError(error.Corrupt, decode(a, good[0..5]));
    try std.testing.expectError(error.Corrupt, decode(a, good[0 .. good.len - 1])); // truncated nodes
    var bad = try a.dupe(u8, good);
    defer a.free(bad);
    bad[4] = 2; // unknown format
    try std.testing.expectError(error.Corrupt, decode(a, bad));
    bad[4] = 1;
    bad[0] = 'X';
    try std.testing.expectError(error.Corrupt, decode(a, bad));
    // a node whose string index points past the table
    bad[0] = 'U';
    var db = try decode(a, bad);
    defer db.deinit(a);
    const c = db.class(28).?;
    const first = c.first_node * node_entry_len;
    const nodes_off = @intFromPtr(db.nodes.ptr) - @intFromPtr(bad.ptr);
    std.mem.writeInt(u16, bad[nodes_off + first + 12 ..][0..2], 0xFFFF, .little);
    try std.testing.expectError(error.Corrupt, db.tree(a, 28));
}

fn hasChild(node: typetree.Node, name: []const u8) bool {
    for (node.children) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}
