//! Shader (class 48) sub-program blob parsing and skinning detection.
//!
//! A `Shader` object carries its compiled sub-programs out-of-line from the
//! parsed form: `platforms`, `offsets`, `compressedLengths`,
//! `decompressedLengths` and `compressedBlob` describe an LZ4-block-compressed
//! per-platform blob, whose records are either parameter blobs (the binding
//! table a stripped `RDEF` chunk would hold) or code blobs (the compiled
//! programs, each closing with a `ParserBindChannels` block). The byte layout
//! is documented in `hordeforge/7dtd-engine-research`
//! `docs/shader-subprogram-blob.md` and cross-checked against USCSandbox and
//! UnityPy.
//!
//! This module decodes that blob and answers whether a shader's vertex stage
//! skins: a program skins when it binds per-vertex bone indices/weights
//! (`BLENDINDICES`/`BLENDWEIGHT`, mesh-channel sources 9 and 8) **and** binds
//! the per-mesh bone matrices (`unity_SkinnedMeshBoneMatrix` or an equivalent
//! per-mesh texture/cbuffer) in the parameter blob. A plain
//! `mul(unity_ObjectToWorld, input.vertex)` program (the `Shamway/Unlit`
//! shape) has neither and does not skin — it draws a `MeshRenderer` but
//! nothing on a `SkinnedMeshRenderer`.

const std = @import("std");
const value = @import("value.zig");
const streams = @import("streams.zig");
const lz4 = @import("lz4.zig");

/// `ShaderCompilerPlatform.d3d11` (the platform the game ships for).
pub const platform_d3d11: u32 = 4;
/// Blob version tag common to code and parameter records (Unity 2021.2+).
pub const blob_version: u32 = 202012090;
/// `ShaderGpuProgramType` range that is a d3d11 program of some stage.
pub const gpu_d3d11_min: u32 = 13;
pub const gpu_d3d11_max: u32 = 22;
/// Vertex-stage d3d11 `ShaderGpuProgramType` values.
pub const gpu_vertex_types = [_]u32{ 13, 15, 16 };

/// Mesh channel sources that carry per-vertex bone data.
pub const blend_weight_source: u32 = 8;
pub const blend_indices_source: u32 = 9;

/// One record in a platform blob's record table.
pub const Record = struct {
    offset: u32,
    length: u32,
    segment: u32,
};

/// The decoded sub-program header shared by a code blob record.
pub const SubProgram = struct {
    program_type: u32,
    /// Offset in the platform blob where the program data begins.
    data_offset: usize,
    size: u32,
    /// The raw compiled program data (the 38-byte header + DXBC container for
    /// d3d11, or the equivalent for other driver bytecode).
    data: []const u8,
};

/// The closing `ParserBindChannels` block of a code-blob record.
pub const BindChannels = struct {
    source_map: i32,
    /// `(source, target)` per bound channel; `source` is the mesh channel the
    /// engine reads, `target` the shader input it feeds.
    channels: []const [2]i32,
};

/// A named binding discovered in a parameter blob.
pub const Binding = struct {
    name: []const u8,
    kind: u32,
};

/// The decoded parameter blob (binding table).
pub const ParameterBlob = struct {
    version: u32,
    /// Top-level resource bindings (`kind` 0 texture, 1 cbuffer, 2 buffer,
    /// 3 UAV, 4 sampler).
    bindings: []const Binding,
    /// Constant-buffer names and their member names (bone matrices often live
    /// as a member here rather than as a top-level binding).
    cbuffer_names: []const []const u8,
    members: []const Binding,
};

/// Skinning evidence for one Shader, as computed by [`skinInfo`].
pub const SkinInfo = struct {
    /// True when a vertex sub-program binds `BLENDINDICES`/`BLENDWEIGHT`.
    blend_channels: bool,
    /// The bone-input channel sources actually bound (8 = BLENDWEIGHT,
    /// 9 = BLENDINDICES), deduplicated and ascending.
    blend_sources: []const u32,
    /// Bone-matrix binding names found in the parameter blobs.
    bone_bindings: []const []const u8,
    /// How many d3d11 vertex sub-programs and parameter blobs were examined.
    vertex_programs: usize,
    parameter_blobs: usize,
    /// True when a vertex program skins (bone inputs AND bone matrices bound).
    skins: bool,
    /// False when the blob could not be decoded (e.g. multi-tier or a
    /// non-d3d11 shader), so the answer is unknown rather than "does not skin".
    determined: bool,
};

/// Parses the record table at the head of a decompressed platform blob.
pub fn parseRecords(arena: std.mem.Allocator, data: []const u8) ![]const Record {
    if (data.len < 4) return error.Truncated;
    const count = std.mem.readInt(u32, data[0..4], .little);
    const table_bytes = @as(usize, count) * 12;
    if (table_bytes > data.len - 4) return error.Truncated;
    const records = try arena.alloc(Record, count);
    var r: usize = 4;
    for (records) |*rec| {
        rec.offset = std.mem.readInt(u32, data[r..][0..4], .little);
        rec.length = std.mem.readInt(u32, data[r + 4 ..][0..4], .little);
        rec.segment = std.mem.readInt(u32, data[r + 8 ..][0..4], .little);
        r += 12;
    }
    return records;
}

/// Decodes a code-blob record at `offset` within the platform blob.
pub fn parseSubProgram(data: []const u8, offset: usize) !SubProgram {
    var r = streams.Reader.init(data);
    r.pos = offset;
    const version = try r.readInt(u32);
    if (version != blob_version) return error.BadVersion;
    const program_type = try r.readInt(u32);
    _ = try r.readInt(u32); // statsALU
    _ = try r.readInt(u32); // statsTEX
    _ = try r.readInt(u32); // statsFlow
    _ = try r.readInt(u32); // statsTempRegister
    const keyword_count = try r.readInt(u32);
    for (0..keyword_count) |_| {
        _ = try r.readAlignedStringBorrow(); // keyword, padded to 4
    }
    const size = try r.readInt(u32);
    const data_offset: usize = r.pos;
    if (@as(u64, data_offset) + @as(u64, size) > data.len) return error.Truncated;
    const size_us: usize = size;
    return .{
        .program_type = program_type,
        .data_offset = data_offset,
        .size = size,
        .data = data[data_offset .. data_offset + size_us],
    };
}

/// Parses the `ParserBindChannels` block that closes a code-blob record.
pub fn parseBindChannels(arena: std.mem.Allocator, raw: []const u8) !BindChannels {
    if (raw.len < 8) return error.Truncated;
    var r = streams.Reader.init(raw);
    const source_map = try r.readInt(i32);
    const count = try r.readInt(i32);
    if (count < 0) return error.Truncated;
    const n: usize = @intCast(count);
    if (n > (raw.len - 8) / 8) return error.Truncated;
    const channels = try arena.alloc([2]i32, n);
    for (channels) |*ch| {
        ch[0] = try r.readInt(i32);
        ch[1] = try r.readInt(i32);
    }
    return .{ .source_map = source_map, .channels = channels };
}

/// Parses a parameter-blob record at `offset` within the platform blob,
/// collecting the binding names a skinning detector needs.
pub fn parseParameterBlob(arena: std.mem.Allocator, data: []const u8, offset: usize) !ParameterBlob {
    var r = streams.Reader.init(data);
    r.pos = offset;
    const version = try r.readInt(i32);
    if (version != @as(i32, @intCast(blob_version))) return error.BadVersion;

    var bindings: std.ArrayList(Binding) = .empty;
    errdefer bindings.deinit(arena);
    var cbuffers: std.ArrayList([]const u8) = .empty;
    errdefer cbuffers.deinit(arena);
    var members: std.ArrayList(Binding) = .empty;
    errdefer members.deinit(arena);

    const buffer_count = try r.readInt(i32);
    if (buffer_count < 0) return error.Truncated;
    for (0..@as(usize, @intCast(buffer_count))) |_| {
        const name = trimNul(try r.readAlignedStringBorrow());
        _ = try r.readInt(i32); // usedSize
        try cbuffers.append(arena, name);

        const param_count = try r.readInt(i32);
        if (param_count < 0) return error.Truncated;
        for (0..@as(usize, @intCast(param_count))) |_| {
            const member_name = trimNul(try r.readAlignedStringBorrow());
            _ = try r.readInt(i32); // type
            _ = try r.readInt(i32); // rows
            _ = try r.readInt(i32); // columns
            _ = try r.readInt(i32); // isMatrix
            _ = try r.readInt(i32); // arraySize
            _ = try r.readInt(i32); // index
            try members.append(arena, .{ .name = member_name, .kind = 1 });
        }

        const struct_count = try r.readInt(i32);
        if (struct_count < 0) return error.Truncated;
        for (0..@as(usize, @intCast(struct_count))) |_| {
            const struct_name = trimNul(try r.readAlignedStringBorrow());
            _ = try r.readInt(i32); // index
            _ = try r.readInt(i32); // arraySize
            _ = try r.readInt(i32); // size
            try members.append(arena, .{ .name = struct_name, .kind = 1 });
            const s_param_count = try r.readInt(i32);
            if (s_param_count < 0) return error.Truncated;
            for (0..@as(usize, @intCast(s_param_count))) |_| {
                const m = trimNul(try r.readAlignedStringBorrow());
                _ = try r.readInt(i32); // type
                _ = try r.readInt(i32); // rows
                _ = try r.readInt(i32); // columns
                _ = try r.readInt(i32); // isMatrix
                _ = try r.readInt(i32); // arraySize
                _ = try r.readInt(i32); // index
                try members.append(arena, .{ .name = m, .kind = 1 });
            }
        }
    }

    const entry_count = try r.readInt(i32);
    if (entry_count < 0) return error.Truncated;
    for (0..@as(usize, @intCast(entry_count))) |_| {
        const name = trimNul(try r.readAlignedStringBorrow());
        const kind = try r.readInt(i32);
        try bindings.append(arena, .{ .name = name, .kind = @intCast(kind) });
        switch (kind) {
            0 => { // texture
                _ = try r.readInt(i32); // index
                _ = try r.readInt(i32); // samplerIndex
                _ = try r.readInt(u32); // extra
            },
            1, 2 => { // cbuffer / buffer binding
                _ = try r.readInt(i32); // index
                _ = try r.readInt(i32); // arraySize
            },
            3 => { // UAV
                _ = try r.readInt(i32); // index
                _ = try r.readInt(i32); // originalIndex
            },
            4 => { // sampler
                _ = try r.readInt(i32); // bindPoint
                _ = try r.readInt(u32); // sampler
            },
            else => return error.BadKind,
        }
    }

    return .{
        .version = @intCast(version),
        .bindings = try bindings.toOwnedSlice(arena),
        .cbuffer_names = try cbuffers.toOwnedSlice(arena),
        .members = try members.toOwnedSlice(arena),
    };
}

/// True when a `ShaderGpuProgramType` is a d3d11 program of some stage.
pub fn isD3d11Type(gpu_type: u32) bool {
    return gpu_type >= gpu_d3d11_min and gpu_type <= gpu_d3d11_max;
}

/// True when a `ShaderGpuProgramType` is a d3d11 vertex program.
pub fn isVertexType(gpu_type: u32) bool {
    for (gpu_vertex_types) |v| {
        if (gpu_type == v) return true;
    }
    return false;
}

/// True when a parameter name looks like a per-mesh bone-matrix binding.
/// Covers Unity's `unity_SkinnedMeshBoneMatrix` and `unity_BoneMatrices` and
/// common per-mesh texture/cbuffer variants.
pub fn isBoneMatrixName(name: []const u8) bool {
    const lower: []const u8 = name;
    // Unity name is ascii and matched case-sensitively below; compare
    // case-insensitively to be safe against authoring variations.
    return containsIgnoreCase(lower, "bonematrix") or
        containsIgnoreCase(lower, "bone_matrix") or
        containsIgnoreCase(lower, "skinnedmeshbone") or
        containsIgnoreCase(lower, "unity_skinnedmesh") or
        containsIgnoreCase(lower, "unity_bonematrices") or
        containsIgnoreCase(lower, "skinmatrix") or
        containsIgnoreCase(lower, "blendmatrix");
}

/// Strips the trailing NUL Unity's 4-byte-aligned strings carry.
fn trimNul(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\x00");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Value-tree access
// ---------------------------------------------------------------------------

fn fieldOf(v: value.Value, name: []const u8) ?value.Value {
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

fn intField(v: value.Value, name: []const u8) ?i64 {
    return (fieldOf(v, name) orelse return null).asInt();
}

fn asArray(v: value.Value) ?[]const value.Value {
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

fn asString(v: value.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Skinning detection
// ---------------------------------------------------------------------------

/// Walks `m_ParsedForm`, appending d3d11 vertex sub-program blob indices to
/// `vertex` and the parallel parameter-blob indices to `params`.
fn collectPrograms(arena: std.mem.Allocator, pf: value.Value, vertex: *std.ArrayList(u32), params: *std.ArrayList(u32)) !void {
    const sub_shaders = asArray(fieldOf(pf, "m_SubShaders") orelse return) orelse return;
    for (sub_shaders) |sub| {
        const passes = asArray(fieldOf(sub, "m_Passes") orelse continue) orelse continue;
        for (passes) |pass| {
            if (pass != .obj) continue;
            for (pass.obj) |f| {
                if (f.value != .obj) continue;
                const prog = f.value;
                if (fieldOf(prog, "m_PlayerSubPrograms") == null) continue;
                const groups = asArray(fieldOf(prog, "m_PlayerSubPrograms").?) orelse continue;
                const pgroups = if (fieldOf(prog, "m_ParameterBlobIndices")) |pi|
                    (asArray(pi) orelse &.{})
                else
                    &.{};
                for (groups, 0..) |group, gi| {
                    const subs = asArray(group) orelse continue;
                    const parr = if (gi < pgroups.len) (asArray(pgroups[gi]) orelse &.{}) else &.{};
                    for (subs, 0..) |sub_obj, k| {
                        const gpu = intField(sub_obj, "m_GpuProgramType") orelse continue;
                        const gpu_u: u32 = @intCast(gpu);
                        if (!isD3d11Type(gpu_u)) continue;
                        if (isVertexType(gpu_u)) {
                            if (intField(sub_obj, "m_BlobIndex")) |bi| {
                                try vertex.append(arena, @intCast(bi));
                            }
                        }
                        // parameter-blob index parallel to this position
                        if (k < parr.len) {
                            if (parr[k].asInt()) |pi| {
                                try params.append(arena, @intCast(pi));
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Decompresses and decodes the d3d11 platform blob for `v`, then computes
/// skinning evidence. Returns `null` when the shader has no single-tier d3d11
/// platform (the index space is only defined for one tier) or when the blob
/// cannot be decoded — the caller reports that as undetermined.
pub fn skinInfo(arena: std.mem.Allocator, v: value.Value) !?SkinInfo {
    const pf = fieldOf(v, "m_ParsedForm") orelse return null;

    // --- platform metadata ---
    const platforms = asArray((fieldOf(v, "platforms") orelse fieldOf(v, "m_Platforms")) orelse return null) orelse return null;
    var plat_index: ?usize = null;
    for (platforms, 0..) |p, i| {
        if (p.asInt()) |pi| {
            if (pi == platform_d3d11) {
                plat_index = i;
                break;
            }
        }
    }
    const idx = plat_index orelse return null;

    const offsets = asArray((fieldOf(v, "offsets") orelse fieldOf(v, "m_Offsets")) orelse return null) orelse return null;
    const comp_lens = asArray((fieldOf(v, "compressedLengths") orelse fieldOf(v, "m_CompressedLengths")) orelse return null) orelse return null;
    const decomp_lens = asArray((fieldOf(v, "decompressedLengths") orelse fieldOf(v, "m_DecompressedLengths")) orelse return null) orelse return null;
    const blob = switch ((fieldOf(v, "compressedBlob") orelse fieldOf(v, "m_CompressedBlob") orelse fieldOf(v, "m_Script")) orelse return null) {
        .bytes => |b| b,
        else => return null,
    };
    if (idx >= offsets.len or idx >= comp_lens.len or idx >= decomp_lens.len) return null;

    const off_tiers = asArray(offsets[idx]) orelse return null;
    const comp_tiers = asArray(comp_lens[idx]) orelse return null;
    const decomp_tiers = asArray(decomp_lens[idx]) orelse return null;
    // Blob indices are per hardware tier; the parsed form does not say which
    // tier a sub-program's index belongs to, so only a single tier is defined.
    if (off_tiers.len != 1 or comp_tiers.len != 1 or decomp_tiers.len != 1) return null;
    const off0 = off_tiers[0].asInt() orelse return null;
    const comp0 = comp_tiers[0].asInt() orelse return null;
    const decomp0 = decomp_tiers[0].asInt() orelse return null;
    if (off0 < 0 or comp0 < 0 or decomp0 < 0) return null;
    const start: usize = @intCast(off0);
    const comp_len: usize = @intCast(comp0);
    if (start + comp_len > blob.len) return null;

    // --- decompress the d3d11 platform blob ---
    const needs_lz4 = comp_len != @as(usize, @intCast(decomp0));
    const data = if (needs_lz4)
        try lz4.decompress(arena, blob[start .. start + comp_len], @intCast(decomp0))
    else
        blob[start .. start + comp_len];

    // --- record table ---
    const records = try parseRecords(arena, data);

    // --- gather vertex program + parameter blob indices ---
    var vertex: std.ArrayList(u32) = .empty;
    defer vertex.deinit(arena);
    var params: std.ArrayList(u32) = .empty;
    defer params.deinit(arena);
    try collectPrograms(arena, pf, &vertex, &params);

    // --- classify ---
    var blend_sources: std.ArrayList(u32) = .empty;
    defer blend_sources.deinit(arena);
    var bone_bindings: std.ArrayList([]const u8) = .empty;
    defer bone_bindings.deinit(arena);
    var vertex_programs: usize = 0;

    for (vertex.items) |bi| {
        if (bi >= records.len) continue;
        const rec = records[bi];
        const off: usize = rec.offset;
        const rec_end: usize = off + @as(usize, rec.length);
        if (off + 32 > data.len) continue;
        const sp = parseSubProgram(data, off) catch continue;
        if (!isVertexType(sp.program_type)) continue;
        vertex_programs += 1;
        // the code blob closes with the bind-channel block
        const data_end = (sp.data_offset + sp.size + 3) & ~@as(usize, 3);
        if (data_end + 8 > rec_end) continue;
        const trailing = data[data_end..rec_end];
        const bc = parseBindChannels(arena, trailing) catch continue;
        for (bc.channels) |ch| {
            const src: u32 = @intCast(ch[0]);
            if (src == blend_weight_source or src == blend_indices_source) {
                var found = false;
                for (blend_sources.items) |b| {
                    if (b == src) {
                        found = true;
                        break;
                    }
                }
                if (!found) try blend_sources.append(arena, src);
            }
        }
    }

    for (params.items) |pi| {
        if (pi >= records.len) continue;
        const rec = records[pi];
        const off: usize = rec.offset;
        const rec_end: usize = off + @as(usize, rec.length);
        const raw = if (off <= data.len) data[off..@min(rec_end, data.len)] else continue;
        if (raw.len < 8) continue;
        const param_blob = parseParameterBlob(arena, data, off) catch continue;
        // top-level bindings first
        for (param_blob.bindings) |b| {
            if (isBoneMatrixName(b.name)) appendUniqueStr(arena, &bone_bindings, b.name) catch {};
        }
        for (param_blob.cbuffer_names) |cb| {
            if (isBoneMatrixName(cb)) appendUniqueStr(arena, &bone_bindings, cb) catch {};
        }
        for (param_blob.members) |m| {
            if (isBoneMatrixName(m.name)) appendUniqueStr(arena, &bone_bindings, m.name) catch {};
        }
    }

    const blend_channels = blend_sources.items.len != 0;
    const skins = blend_channels and bone_bindings.items.len != 0;
    return SkinInfo{
        .blend_channels = blend_channels,
        .blend_sources = try blend_sources.toOwnedSlice(arena),
        .bone_bindings = try bone_bindings.toOwnedSlice(arena),
        .vertex_programs = vertex_programs,
        .parameter_blobs = params.items.len,
        .skins = skins,
        .determined = true,
    };
}

fn appendUniqueStr(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, s)) return;
    }
    try list.append(arena, s);
}

test "parseRecords reads the 12-byte record table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // count 2, two 12-byte records tiling the payload
    const buf = [_]u8{
        2, 0, 0, 0, // count
        28, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, // record 0
        38, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, // record 1
    };
    const records = try parseRecords(a, &buf);
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(@as(u32, 28), records[0].offset);
    try std.testing.expectEqual(@as(u32, 10), records[0].length);
    try std.testing.expectEqual(@as(u32, 38), records[1].offset);
}

test "bind channels parse and report blend sources" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // sourceMap, count=3, (0,0),(8,9),(9,6)
    const buf = [_]u8{
        1, 0, 0, 0, 3, 0, 0, 0, // sourceMap, count
        0, 0, 0, 0, 0, 0, 0, 0, // (0,0)
        8, 0, 0, 0, 9, 0, 0, 0, // (8,9)
        9, 0, 0, 0, 6, 0, 0, 0, // (9,6)
    };
    const bc = try parseBindChannels(a, &buf);
    try std.testing.expectEqual(@as(i32, 1), bc.source_map);
    try std.testing.expectEqual(@as(usize, 3), bc.channels.len);
    var has8 = false;
    var has9 = false;
    for (bc.channels) |ch| {
        if (ch[0] == 8) has8 = true;
        if (ch[0] == 9) has9 = true;
    }
    try std.testing.expect(has8);
    try std.testing.expect(has9);
}

test "isBoneMatrixName matches unity's skinned bone matrix" {
    try std.testing.expect(isBoneMatrixName("unity_SkinnedMeshBoneMatrix"));
    try std.testing.expect(isBoneMatrixName("unity_BoneMatrices"));
    try std.testing.expect(isBoneMatrixName("_BoneMatrix"));
    try std.testing.expect(!isBoneMatrixName("_MainTex"));
    try std.testing.expect(!isBoneMatrixName("UnityPerDraw"));
}

/// Builds a synthetic platform blob: record 0 = a vertex code blob that binds
/// BLENDWEIGHT/BLENDINDICES (sources 8/9), record 1 = a parameter blob whose
/// sole binding is `unity_SkinnedMeshBoneMatrix` when `bone_binding`, else an
/// unrelated `UnityPerDraw`. Returns the bytes.
fn buildSyntheticBlob(a: std.mem.Allocator, bone_binding: bool) ![]const u8 {
    var w = streams.Writer.init(a);
    try w.writeInt(i32, 2); // record count

    // record 0 = code blob (index 0)
    const code_off: usize = 4 + 2 * 12;
    // code payload: version, program_type, stats, keywordCount, size, data, bind channels
    var code = streams.Writer.init(a);
    try code.writeInt(i32, @as(i32, @intCast(blob_version)));
    try code.writeInt(i32, 15); // DX11VertexSM40
    for ([_]i32{ 0, 0, 0, 0 }) |s| try code.writeInt(i32, s); // alu,tex,flow,temp
    try code.writeInt(i32, 0); // keywordCount
    try code.writeInt(i32, 16); // size -> 16 bytes of program data
    for (0..16) |_| try code.writeByte(0);
    // trailing ParserBindChannels: sourceMap, count=2, (8,9)=BLENDWEIGHT, (9,6)=BLENDINDICES
    try code.writeInt(i32, 1); // sourceMap
    try code.writeInt(i32, 2); // count
    for ([_]i32{ 8, 9, 9, 6 }) |x| try code.writeInt(i32, x);
    const code_len = code.getWritten().len;
    try w.writeInt(u32, @intCast(code_off));
    try w.writeInt(u32, @intCast(code_len));
    try w.writeInt(u32, 0); // segment

    // record 1 = parameter blob (index 1)
    const param_off = code_off + code_len;
    var par = streams.Writer.init(a);
    try par.writeInt(i32, @as(i32, @intCast(blob_version)));
    try par.writeInt(i32, 0); // bufferCount
    try par.writeInt(i32, 1); // entryCount
    if (bone_binding) try par.writeAlignedString("unity_SkinnedMeshBoneMatrix") else try par.writeAlignedString("UnityPerDraw");
    try par.writeInt(i32, 1); // kind = cbuffer binding
    try par.writeInt(i32, 0); // index
    try par.writeInt(i32, 1); // arraySize
    const param_len = par.getWritten().len;
    try w.writeInt(u32, @intCast(param_off));
    try w.writeInt(u32, @intCast(param_len));
    try w.writeInt(u32, 0); // segment

    // payload concat
    try w.writeBytes(code.getWritten());
    try w.writeBytes(par.getWritten());
    return w.getWritten();
}

/// Builds a Shader value tree referencing one vertex sub-program (blob index
/// 0) and one parameter blob (index 1) in the d3d11 platform blob `blob`.
fn buildShaderValue(blob: []const u8) value.Value {
    const sub = [_]value.Value{.{ .obj = &[_]value.Field{ .{ .name = "m_BlobIndex", .value = .{ .int = 0 } }, .{
        .name = "m_GpuProgramType",
        .value = .{ .int = 15 },
    } } }};
    const empty = [_]value.Value{};
    const player_groups = [_]value.Value{
        .{ .array = &empty },
        .{ .array = &empty },
        .{ .array = &empty },
        .{ .array = &sub },
    };
    const param_groups = [_]value.Value{
        .{ .array = &empty },
        .{ .array = &empty },
        .{ .array = &empty },
        .{ .array = &[_]value.Value{.{ .int = 1 }} },
    };
    const program = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_PlayerSubPrograms", .value = .{ .array = &player_groups } },
        .{ .name = "m_ParameterBlobIndices", .value = .{ .array = &param_groups } },
    } };
    const pass = value.Value{ .obj = &[_]value.Field{
        .{ .name = "progVertex", .value = program },
    } };
    const subshader = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Passes", .value = .{ .array = &[_]value.Value{pass} } },
    } };
    const pf = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Test/Skinned\x00" } },
        .{ .name = "m_SubShaders", .value = .{ .array = &[_]value.Value{subshader} } },
    } };
    return value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "" } },
        .{ .name = "m_ParsedForm", .value = pf },
        .{ .name = "platforms", .value = .{ .array = &[_]value.Value{.{ .int = 4 }} } },
        .{ .name = "offsets", .value = .{ .array = &[_]value.Value{.{ .array = &[_]value.Value{.{ .uint = 0 }} }} } },
        .{ .name = "compressedLengths", .value = .{ .array = &[_]value.Value{.{ .array = &[_]value.Value{.{ .uint = blob.len }} }} } },
        .{ .name = "decompressedLengths", .value = .{ .array = &[_]value.Value{.{ .array = &[_]value.Value{.{ .uint = blob.len }} }} } },
        .{ .name = "compressedBlob", .value = .{ .bytes = blob } },
    } };
}

test "skinInfo skins a vertex program with blend inputs and bone matrices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const blob = try buildSyntheticBlob(a, true);
    const shader = buildShaderValue(blob);
    const info = (try skinInfo(a, shader)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(info.determined);
    try std.testing.expect(info.skins);
    try std.testing.expect(info.blend_channels);
    try std.testing.expectEqual(@as(usize, 2), info.blend_sources.len);
    try std.testing.expectEqual(@as(u32, 8), info.blend_sources[0]);
    try std.testing.expectEqual(@as(u32, 9), info.blend_sources[1]);
    try std.testing.expectEqual(@as(usize, 1), info.bone_bindings.len);
    try std.testing.expectEqualStrings("unity_SkinnedMeshBoneMatrix", info.bone_bindings[0]);
}

test "skinInfo does not skin a program with blend inputs but no bone matrices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The same blob minus the bone-matrix binding: bind channels 8/9 stay, so
    // blend_channels is true, but no bone binding means it does not skin.
    const blob = try buildSyntheticBlob(a, false);
    const no_bone = buildShaderValue(blob);
    const info = (try skinInfo(a, no_bone)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(info.determined);
    try std.testing.expect(info.blend_channels);
    try std.testing.expectEqual(@as(usize, 0), info.bone_bindings.len);
    try std.testing.expect(!info.skins); // blend inputs alone are not skinning
}

test "parameter blob parses a bone-matrix member" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // version, 1 buffer named "myBones", usedSize, 1 param "unity_SkinnedMeshBoneMatrix",
    // structCount 0, then entryCount 0, closing the record.
    var w = streams.Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeInt(i32, @as(i32, @intCast(blob_version)));
    try w.writeInt(i32, 1); // bufferCount
    try w.writeAlignedString("myBones");
    try w.writeInt(i32, 64); // usedSize
    try w.writeInt(i32, 1); // paramCount
    try w.writeAlignedString("unity_SkinnedMeshBoneMatrix");
    for ([_]i32{ 5, 4, 4, 1, 1, 0 }) |x| try w.writeInt(i32, x); // type,rows,cols,isMatrix,arraySize,index
    try w.writeInt(i32, 0); // structCount
    try w.writeInt(i32, 0); // entryCount

    const pb = try parseParameterBlob(a, w.getWritten(), 0);
    try std.testing.expectEqual(@as(usize, 1), pb.cbuffer_names.len);
    try std.testing.expectEqualStrings("myBones", pb.cbuffer_names[0]);
    try std.testing.expect(isBoneMatrixName(pb.members[0].name));
}
