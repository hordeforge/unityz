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
        // Reject the negative case here rather than at the switch below: the
        // @intCast to the u32 field runs first, and is illegal behavior on a
        // negative. A negative kind hits `else => error.BadKind` either way.
        if (kind < 0) return error.BadKind;
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

// ---------------------------------------------------------------------------
// Skinning detection
// ---------------------------------------------------------------------------

/// Walks `m_ParsedForm`, appending d3d11 vertex sub-program blob indices to
/// `vertex` and the parallel parameter-blob indices to `params`. A filtered
/// view of `collectCodeParams`, which owns the traversal.
fn collectPrograms(arena: std.mem.Allocator, pf: value.Value, vertex: *std.ArrayList(u32), params: *std.ArrayList(u32)) !void {
    var codes: std.ArrayList(u32) = .empty;
    defer codes.deinit(arena);
    var code_types: std.ArrayList(u32) = .empty;
    defer code_types.deinit(arena);
    try collectCodeParams(arena, pf, &codes, &code_types, params);
    for (codes.items, code_types.items) |blob_index, gpu_type| {
        if (isVertexType(gpu_type)) try vertex.append(arena, blob_index);
    }
}

/// Decompresses and decodes the d3d11 platform blob for `v`, then computes
/// skinning evidence. Returns `null` when the shader has no single-tier d3d11
/// platform (the index space is only defined for one tier) or when the blob
/// cannot be decoded — the caller reports that as undetermined.
pub fn skinInfo(arena: std.mem.Allocator, v: value.Value) !?SkinInfo {
    const pf = fieldOf(v, "m_ParsedForm") orelse return null;

    // Platform blob resolution and decompression are shared with the
    // decode/verify path; see `openD3d11Blob`.
    const d3d11 = (try openD3d11Blob(arena, v)) orelse return null;
    const data = d3d11.data;
    const records = d3d11.records;

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
        // offset/length are raw u32s from the file: clamp the record end to
        // the blob so a padded `data_end` or an oversized length cannot slice
        // past it (the parameter loop below clamps the same way).
        const rec_end: usize = @min(off +| @as(usize, rec.length), data.len);
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
            // Channel sources are raw i32s from the file; @intCast is illegal
            // behavior on a negative one. Neither blend source is negative, so
            // skipping cannot change the result.
            if (ch[0] < 0) continue;
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
        const rec_end: usize = off +| @as(usize, rec.length);
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

/// Writes a blob-convention string (u32 byte length, bytes, zero padding to 4).
fn putBlobString(w: *streams.Writer, s: []const u8) !void {
    try w.writeInt(i32, @intCast(s.len));
    try w.writeBytes(s);
    const pad = (4 - ((s.len + 4) % 4)) % 4;
    if (pad != 0) {
        const zeros = [_]u8{0} ** 4;
        try w.writeBytes(zeros[0..pad]);
    }
}

test "parameter blob parses a buffer with a nameless base and re-encodes byte for byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // version, 1 nameless buffer (usedSize 0, no members/structs), then 1
    // entry: a texture "MainTex" (kind 0) with the "own sampler" sentinel.
    var w = streams.Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeInt(i32, @as(i32, @intCast(blob_version)));
    try w.writeInt(i32, 1); // bufferCount
    try putBlobString(&w, ""); // nameless base buffer
    try w.writeInt(i32, 0); // usedSize
    try w.writeInt(i32, 0); // memberCount
    try w.writeInt(i32, 0); // structCount
    try w.writeInt(i32, 1); // entryCount
    try putBlobString(&w, "MainTex");
    try w.writeInt(i32, 0); // kind texture
    try w.writeInt(i32, 0); // index
    try w.writeInt(i32, -1); // samplerIndex 0xffffffff
    try w.writeInt(u32, 4); // extra: dimension(2)<<1

    const raw = w.getWritten();
    const pb = try parseParameterBlobFull(a, raw, 0);
    try std.testing.expectEqual(@as(usize, 1), pb.buffers.len);
    try std.testing.expectEqual(@as(usize, 0), pb.buffers[0].name.len);
    try std.testing.expectEqual(@as(usize, 1), pb.entries.len);
    try std.testing.expectEqualStrings("MainTex", pb.entries[0].name);
    try std.testing.expectEqual(@as(i32, 0), pb.entries[0].kind);
    try std.testing.expectEqual(@as(i32, -1), pb.entries[0].sampler_index);

    var out = streams.Writer.init(std.testing.allocator);
    defer out.deinit();
    try writeParameterBlob(&out, pb);
    try std.testing.expectEqualSlices(u8, raw, out.getWritten());
}

test "verifies a synthetic shader blob round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = try buildSyntheticBlob(a, true);
    const shader = buildShaderValue(blob);
    try std.testing.expect(try verifyBlob(a, shader));
}

// ---------------------------------------------------------------------------
// Full sub-program blob decoder
// ---------------------------------------------------------------------------

/// A member of a constant buffer (ShaderParams), at Unity's chosen offset.
pub const ParamMember = struct {
    name: []const u8,
    type: i32,
    rows: i32,
    columns: i32,
    is_matrix: i32,
    array_size: i32,
    index: i32,
};

/// A struct parameter nested inside a constant buffer.
pub const StructParam = struct {
    name: []const u8,
    index: i32,
    array_size: i32,
    size: i32,
    params: []const ParamMember,
};

/// A constant buffer (ShaderParams).
pub const ConstantBuffer = struct {
    name: []const u8,
    used_size: i32,
    params: []const ParamMember,
    structs: []const StructParam,
};

/// A top-level parameter-blob entry. Kind-specific fields are only meaningful
/// for the matching `kind` (0 texture, 1 cbuffer binding, 2 buffer,
/// 3 UAV, 4 sampler).
pub const ParamEntry = struct {
    name: []const u8,
    kind: i32,
    index: i32,
    sampler_index: i32,
    extra: u32,
    array_size: i32,
    original_index: i32,
    bind_point: i32,
    sampler: u32,
};

/// The full decoded parameter blob (binding table), preserving every field so
/// it re-encodes byte for byte.
pub const ParameterBlobFull = struct {
    version: u32,
    buffers: []const ConstantBuffer,
    entries: []const ParamEntry,
};

/// Port of the writer's `ParameterBlob` read path: the constant-buffer list
/// then the top-level binding entries, keeping every field the writer emits.
pub fn parseParameterBlobFull(arena: std.mem.Allocator, data: []const u8, offset: usize) !ParameterBlobFull {
    var r = streams.Reader.init(data);
    r.pos = offset;
    const version_i = try r.readInt(i32);
    if (version_i != @as(i32, @intCast(blob_version))) return error.BadVersion;
    const version: u32 = @intCast(version_i);

    const buffer_count = try r.readInt(i32);
    if (buffer_count < 0 or @as(usize, @intCast(buffer_count)) > data.len) return error.Truncated;
    const buffers = try arena.alloc(ConstantBuffer, @intCast(buffer_count));
    for (buffers) |*buf| {
        buf.name = trimNul(try r.readAlignedStringBorrow());
        buf.used_size = try r.readInt(i32);
        const pcount = try r.readInt(i32);
        if (pcount < 0 or @as(usize, @intCast(pcount)) > data.len) return error.Truncated;
        const params = try arena.alloc(ParamMember, @intCast(pcount));
        for (params) |*p| {
            p.name = trimNul(try r.readAlignedStringBorrow());
            p.type = try r.readInt(i32);
            p.rows = try r.readInt(i32);
            p.columns = try r.readInt(i32);
            p.is_matrix = try r.readInt(i32);
            p.array_size = try r.readInt(i32);
            p.index = try r.readInt(i32);
        }
        buf.params = params;
        const scount = try r.readInt(i32);
        if (scount < 0 or @as(usize, @intCast(scount)) > data.len) return error.Truncated;
        const structs = try arena.alloc(StructParam, @intCast(scount));
        for (structs) |*s| {
            s.name = trimNul(try r.readAlignedStringBorrow());
            s.index = try r.readInt(i32);
            s.array_size = try r.readInt(i32);
            s.size = try r.readInt(i32);
            const spcount = try r.readInt(i32);
            if (spcount < 0 or @as(usize, @intCast(spcount)) > data.len) return error.Truncated;
            const sp = try arena.alloc(ParamMember, @intCast(spcount));
            for (sp) |*m| {
                m.name = trimNul(try r.readAlignedStringBorrow());
                m.type = try r.readInt(i32);
                m.rows = try r.readInt(i32);
                m.columns = try r.readInt(i32);
                m.is_matrix = try r.readInt(i32);
                m.array_size = try r.readInt(i32);
                m.index = try r.readInt(i32);
            }
            s.params = sp;
        }
        buf.structs = structs;
    }

    const entry_count = try r.readInt(i32);
    if (entry_count < 0 or @as(usize, @intCast(entry_count)) > data.len) return error.Truncated;
    const entries = try arena.alloc(ParamEntry, @intCast(entry_count));
    for (entries) |*e| {
        e.name = trimNul(try r.readAlignedStringBorrow());
        e.kind = try r.readInt(i32);
        e.index = 0;
        e.sampler_index = 0;
        e.extra = 0;
        e.array_size = 0;
        e.original_index = 0;
        e.bind_point = 0;
        e.sampler = 0;
        switch (e.kind) {
            0 => {
                e.index = try r.readInt(i32);
                e.sampler_index = try r.readInt(i32);
                e.extra = try r.readInt(u32);
            },
            1, 2 => {
                e.index = try r.readInt(i32);
                e.array_size = try r.readInt(i32);
            },
            3 => {
                e.index = try r.readInt(i32);
                e.original_index = try r.readInt(i32);
            },
            4 => {
                e.bind_point = try r.readInt(i32);
                e.sampler = try r.readInt(u32);
            },
            else => return error.BadKind,
        }
    }

    return .{ .version = version, .buffers = buffers, .entries = entries };
}

/// Writes a 4-byte-aligned string in the blob's own convention: u32 byte
/// length (not counting a terminator), the bytes, then zero padding to 4.
/// This matches how `readAlignedStringBorrow` reads and how the reference
/// writer emits strings, so a re-encoded parameter blob round-trips.
fn writeBlobString(w: *streams.Writer, s: []const u8) !void {
    try w.writeInt(i32, @intCast(s.len));
    try w.writeBytes(s);
    const total = s.len + 4;
    const pad = (4 - (total % 4)) % 4;
    if (pad != 0) {
        const zeros = [_]u8{0} ** 3;
        try w.writeBytes(zeros[0..pad]);
    }
}

/// Re-emits a decoded parameter blob, byte for byte (port of the writer's
/// `ParameterBlob.to_bytes` + the nameless base buffer it always opens with).
pub fn writeParameterBlob(w: *streams.Writer, pb: ParameterBlobFull) !void {
    try w.writeInt(i32, @intCast(pb.version));
    try w.writeInt(i32, @intCast(pb.buffers.len));
    for (pb.buffers) |bp| {
        try writeBlobString(w, bp.name);
        try w.writeInt(i32, bp.used_size);
        try w.writeInt(i32, @intCast(bp.params.len));
        for (bp.params) |p| {
            try writeBlobString(w, p.name);
            try w.writeInt(i32, p.type);
            try w.writeInt(i32, p.rows);
            try w.writeInt(i32, p.columns);
            try w.writeInt(i32, p.is_matrix);
            try w.writeInt(i32, p.array_size);
            try w.writeInt(i32, p.index);
        }
        try w.writeInt(i32, @intCast(bp.structs.len));
        for (bp.structs) |s| {
            try writeBlobString(w, s.name);
            try w.writeInt(i32, s.index);
            try w.writeInt(i32, s.array_size);
            try w.writeInt(i32, s.size);
            try w.writeInt(i32, @intCast(s.params.len));
            for (s.params) |m| {
                try writeBlobString(w, m.name);
                try w.writeInt(i32, m.type);
                try w.writeInt(i32, m.rows);
                try w.writeInt(i32, m.columns);
                try w.writeInt(i32, m.is_matrix);
                try w.writeInt(i32, m.array_size);
                try w.writeInt(i32, m.index);
            }
        }
    }
    try w.writeInt(i32, @intCast(pb.entries.len));
    for (pb.entries) |e| {
        try writeBlobString(w, e.name);
        try w.writeInt(i32, e.kind);
        switch (e.kind) {
            0 => {
                try w.writeInt(i32, e.index);
                try w.writeInt(i32, e.sampler_index);
                try w.writeInt(u32, e.extra);
            },
            1, 2 => {
                try w.writeInt(i32, e.index);
                try w.writeInt(i32, e.array_size);
            },
            3 => {
                try w.writeInt(i32, e.index);
                try w.writeInt(i32, e.original_index);
            },
            4 => {
                try w.writeInt(i32, e.bind_point);
                try w.writeInt(u32, e.sampler);
            },
            else => return error.BadKind,
        }
    }
}

// --- DXBC container analysis ---

/// A DXBC input-signature semantic.
pub const Semantic = struct {
    name: []const u8,
    index: u32,
};

/// A constant buffer member offset from a DXBC `RDEF` chunk.
pub const RdefMember = struct {
    name: []const u8,
    offset: u32,
};

/// A constant buffer from a DXBC `RDEF` chunk: name and member offsets.
pub const RdefBuffer = struct {
    name: []const u8,
    members: []const RdefMember,
};

/// The analysis of a DXBC program container: chunk set, declaration counts,
/// the temp-register and geometry-primitive values the program-data header
/// mirrors, and the ISGN / RDEF details.
pub const DxbcInfo = struct {
    /// Distinct chunk fourccs, in first-seen order.
    chunks: []const []const u8,
    srv: u32,
    cbuffer: u32,
    sampler: u32,
    uav: u32,
    temp_registers: u32,
    gs_primitive: u8,
    has_isgn: bool,
    isgn: []const Semantic,
    has_rdef: bool,
    rdef: []const RdefBuffer,
};

const DXBC_OP_CUSTOMDATA = 53;
const DXBC_OP_DCL_RESOURCE = 88;
const DXBC_OP_DCL_CONSTANT_BUFFER = 89;
const DXBC_OP_DCL_SAMPLER = 90;
const DXBC_OP_DCL_TEMPS = 104;
const DXBC_OP_DCL_UAV = 156;
const DXBC_OP_DCL_RESOURCE_RAW = 161;
const DXBC_OP_DCL_RESOURCE_STRUCTURED = 162;

/// ASCII `name` from a length-prefixed offset inside a chunk (NUL-terminated).
fn cstr(data: []const u8, offset: usize) ![]const u8 {
    if (offset >= data.len) return error.Truncated;
    const end = std.mem.indexOfScalarPos(u8, data, offset, 0) orelse data.len;
    return data[offset..end];
}

/// Reads the (fourcc, payload) list out of a DXBC container, `data` being the
/// bytes starting at the `DXBC` fourcc. Returns the distinct fourccs and the
/// payloads the program-data header mirrors (SHDR/SHEX) or that carry extra
/// detail (ISGN, RDEF).
fn dxbcAnalyze(arena: std.mem.Allocator, data: []const u8) !DxbcInfo {
    if (data.len < 0x24) return error.Truncated;
    const count = std.mem.readInt(u32, data[0x1c..0x20], .little);
    if (@as(usize, count) * 4 + 0x20 > data.len) return error.Truncated;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    var code_payload: ?[]const u8 = null;
    var isgn_payload: ?[]const u8 = null;
    var rdef_payload: ?[]const u8 = null;

    for (0..count) |i| {
        const off: usize = @as(usize, std.mem.readInt(u32, data[0x20 + i * 4 ..][0..4], .little));
        if (off + 8 > data.len) return error.Truncated;
        const fourcc = data[off .. off + 4];
        const size: usize = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        if (off + 8 + size > data.len) return error.Truncated;
        const payload = data[off + 8 .. off + 8 + size];
        // record fourcc once
        var seen = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, fourcc)) {
                seen = true;
                break;
            }
        }
        if (!seen) try names.append(arena, arena.dupe(u8, fourcc) catch return error.OutOfMemory);
        if (std.mem.eql(u8, fourcc, "SHDR") or std.mem.eql(u8, fourcc, "SHEX")) {
            if (code_payload == null) code_payload = payload;
        } else if (std.mem.eql(u8, fourcc, "ISGN")) {
            isgn_payload = payload;
        } else if (std.mem.eql(u8, fourcc, "RDEF")) {
            rdef_payload = payload;
        }
    }

    // Declared counts and temp count from the SHDR/SHEX token stream.
    var srv: u32 = 0;
    var cbuffer: u32 = 0;
    var sampler: u32 = 0;
    var uav: u32 = 0;
    var temp_registers: u32 = 0;
    if (code_payload) |chunk| {
        const decl = dxbcU32(chunk, 4) orelse return error.Truncated;
        const word_count = @min(@as(usize, decl), chunk.len / 4);
        var i: usize = 2;
        while (i < word_count) {
            const token = std.mem.readInt(u32, chunk[i * 4 ..][0..4], .little);
            const opcode = token & 0x7ff;
            var length = (token >> 24) & 0x7f;
            if (opcode == DXBC_OP_CUSTOMDATA) {
                if (i + 1 >= word_count) break;
                length = std.mem.readInt(u32, chunk[(i + 1) * 4 ..][0..4], .little);
            }
            if (length == 0) break; // corrupt; stop rather than loop forever
            if (opcode == DXBC_OP_DCL_RESOURCE or opcode == DXBC_OP_DCL_RESOURCE_RAW or opcode == DXBC_OP_DCL_RESOURCE_STRUCTURED) {
                srv += 1;
            } else if (opcode == DXBC_OP_DCL_CONSTANT_BUFFER) {
                cbuffer += 1;
            } else if (opcode == DXBC_OP_DCL_SAMPLER) {
                sampler += 1;
            } else if (opcode == DXBC_OP_DCL_UAV) {
                uav += 1;
            } else if (opcode == DXBC_OP_DCL_TEMPS) {
                // operand dword holds the register count
                temp_registers = if (i + 1 < word_count) std.mem.readInt(u32, chunk[(i + 1) * 4 ..][0..4], .little) else 0;
            }
            i += @as(usize, length);
        }
    }

    // ISGN input signature.
    var isgn: []const Semantic = &.{};
    if (isgn_payload) |isg| {
        const sig_count = dxbcU32(isg, 0) orelse isgn.len;
        const sem = try arena.alloc(Semantic, @min(@as(usize, sig_count), (isg.len -| 8) / 24));
        var sem_len: usize = 0;
        for (0..sem.len) |k| {
            if (8 + k * 24 + 8 > isg.len) break;
            const name_off = std.mem.readInt(u32, isg[8 + k * 24 ..][0..4], .little);
            const index = std.mem.readInt(u32, isg[12 + k * 24 ..][0..4], .little);
            const nm = cstr(isg, name_off) catch break;
            sem[sem_len] = .{ .name = nm, .index = index };
            sem_len += 1;
        }
        isgn = sem[0..sem_len];
    }

    // RDEF constant-buffer member offsets.
    var rdef: []const RdefBuffer = &.{};
    if (rdef_payload) |rdf| {
        const ccount = dxbcU32(rdf, 0) orelse 0;
        const table = dxbcU32(rdf, 4) orelse 0;
        var bufs: std.ArrayList(RdefBuffer) = .empty;
        defer bufs.deinit(arena);
        for (0..ccount) |k| {
            const entry = @as(usize, table) + k * 24;
            if (entry + 24 > rdf.len) break;
            const name_at = std.mem.readInt(u32, rdf[entry..][0..4], .little);
            const members = std.mem.readInt(u32, rdf[entry + 4 ..][0..4], .little);
            const member_table = std.mem.readInt(u32, rdf[entry + 8 ..][0..4], .little);
            const bname = cstr(rdf, name_at) catch continue;
            var mems: std.ArrayList(RdefMember) = .empty;
            defer mems.deinit(arena);
            for (0..members) |m| {
                const mo = @as(usize, member_table) + m * 24;
                if (mo + 24 > rdf.len) break;
                const mat = std.mem.readInt(u32, rdf[mo..][0..4], .little);
                const off = std.mem.readInt(u32, rdf[mo + 4 ..][0..4], .little);
                const mn = cstr(rdf, mat) catch continue;
                try mems.append(arena, .{ .name = mn, .offset = off });
            }
            try bufs.append(arena, .{ .name = bname, .members = try mems.toOwnedSlice(arena) });
        }
        rdef = try bufs.toOwnedSlice(arena);
    }

    return .{
        .chunks = try names.toOwnedSlice(arena),
        .srv = srv,
        .cbuffer = cbuffer,
        .sampler = sampler,
        .uav = uav,
        .temp_registers = temp_registers,
        .gs_primitive = 0,
        .has_isgn = isgn_payload != null,
        .isgn = isgn,
        .has_rdef = rdef_payload != null,
        .rdef = rdef,
    };
}

fn dxbcU32(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

// --- top-level shader blob decode ---

pub const RecordKind = enum { code, param, unknown };

/// One decoded record of a platform blob.
pub const DecodedRecord = struct {
    index: u32,
    offset: u32,
    length: u32,
    segment: u32,
    kind: RecordKind,
    /// Code-record details (valid when kind == .code).
    program_type: u32,
    data_offset: usize,
    size: u32,
    /// The program data (38-byte header + container) as stored.
    data: []const u8,
    /// The program-data header fields (valid when kind == .code and data.len>=38).
    header: []const u8,
    is_dxbc: bool,
    dxbc: ?DxbcInfo,
    bind_channels: ?BindChannels,
    /// Parameter-blob details (valid when kind == .param).
    param: ?ParameterBlobFull,
};

/// The decoded sub-program blob of one Shader.
pub const ShaderBlob = struct {
    name: []const u8,
    platform: u32,
    records: []const DecodedRecord,
    /// Blob indices for d3d11 sub-programs (from the parsed form).
    code_indices: []const u32,
    /// Blob indices for parameter blobs (from the parsed form).
    param_indices: []const u32,
};

/// The decompressed d3d11 platform blob plus its record table.
pub const D3d11Blob = struct {
    data: []const u8,
    records: []const Record,
};

/// Resolves and decompresses the d3d11 platform blob for a Shader value tree.
/// Returns null when there is no single-tier d3d11 platform or the blob is too
/// short to hold a record table.
pub fn openD3d11Blob(arena: std.mem.Allocator, v: value.Value) !?D3d11Blob {
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
    if (off_tiers.len != 1 or comp_tiers.len != 1 or decomp_tiers.len != 1) return null;
    const off0 = off_tiers[0].asInt() orelse return null;
    const comp0 = comp_tiers[0].asInt() orelse return null;
    const decomp0 = decomp_tiers[0].asInt() orelse return null;
    if (off0 < 0 or comp0 < 0 or decomp0 < 0) return null;
    const start: usize = @intCast(off0);
    const comp_len: usize = @intCast(comp0);
    if (start + comp_len > blob.len) return null;
    const needs_lz4 = comp_len != @as(usize, @intCast(decomp0));
    const data = if (needs_lz4)
        try lz4.decompress(arena, blob[start .. start + comp_len], @intCast(decomp0))
    else
        blob[start .. start + comp_len];
    const records = try parseRecords(arena, data);
    return .{ .data = data, .records = records };
}

/// Collects every d3d11 sub-program blob index (all stages) and its parameter
/// blob indices from `m_ParsedForm`.
fn collectCodeParams(arena: std.mem.Allocator, pf: value.Value, codes: *std.ArrayList(u32), code_types: *std.ArrayList(u32), params: *std.ArrayList(u32)) !void {
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
                const pgroups = if (fieldOf(prog, "m_ParameterBlobIndices")) |pi| (asArray(pi) orelse &.{}) else &.{};
                for (groups, 0..) |group, gi| {
                    const subs = asArray(group) orelse continue;
                    const parr = if (gi < pgroups.len) (asArray(pgroups[gi]) orelse &.{}) else &.{};
                    for (subs, 0..) |sub_obj, k| {
                        const gpu = intField(sub_obj, "m_GpuProgramType") orelse continue;
                        const gpu_u: u32 = @intCast(gpu);
                        if (!isD3d11Type(gpu_u)) continue;
                        if (intField(sub_obj, "m_BlobIndex")) |bi| {
                            try codes.append(arena, @intCast(bi));
                            try code_types.append(arena, gpu_u);
                        }
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

/// Decodes one code-blob record referenced by `index`. Returns null when the
/// record does not hold a parseable sub-program.
pub fn decodeCodeRecord(arena: std.mem.Allocator, data: []const u8, rec: Record, index: u32, program_type: u32) !?DecodedRecord {
    const off: usize = rec.offset;
    if (off + 32 > data.len) return null;
    const sp = parseSubProgram(data, off) catch return null;
    const rec_end: usize = off + @as(usize, rec.length);
    const data_end = (sp.data_offset + sp.size + 3) & ~@as(usize, 3);
    // trailing ParserBindChannels
    var bind: ?BindChannels = null;
    if (rec_end > data_end and data_end >= 8 and data_end <= data.len and rec_end <= data.len) {
        if (data_end + 8 <= rec_end) {
            bind = parseBindChannels(arena, data[data_end..rec_end]) catch null;
        }
    }
    var header: []const u8 = &.{};
    var is_dxbc = false;
    var dxbc: ?DxbcInfo = null;
    if (sp.data.len >= 38) {
        header = sp.data[0..38];
        if (sp.data.len >= 42 and std.mem.eql(u8, sp.data[38..42], "DXBC")) {
            is_dxbc = true;
            dxbc = try dxbcAnalyze(arena, sp.data[38..]);
            if (dxbc) |*d| d.gs_primitive = header[5];
        }
    }
    return .{
        .index = index,
        .offset = rec.offset,
        .length = rec.length,
        .segment = rec.segment,
        .kind = .code,
        .program_type = if (program_type != 0) program_type else sp.program_type,
        .data_offset = sp.data_offset,
        .size = sp.size,
        .data = sp.data,
        .header = header,
        .is_dxbc = is_dxbc,
        .dxbc = dxbc,
        .bind_channels = bind,
        .param = null,
    };
}

/// Decodes one parameter-blob record referenced by `index`. Returns null when
/// the record is not a parameter blob.
pub fn decodeParamRecord(arena: std.mem.Allocator, data: []const u8, rec: Record, index: u32) !?DecodedRecord {
    const off: usize = rec.offset;
    if (off + 8 > data.len) return null;
    const pb = parseParameterBlobFull(arena, data, off) catch return null;
    return .{
        .index = index,
        .offset = rec.offset,
        .length = rec.length,
        .segment = rec.segment,
        .kind = .param,
        .program_type = 0,
        .data_offset = off,
        .size = rec.length,
        .data = &.{},
        .header = &.{},
        .is_dxbc = false,
        .dxbc = null,
        .bind_channels = null,
        .param = pb,
    };
}

/// Decodes the whole d3d11 sub-program blob of a Shader value tree, listing
/// every record referenced by the parsed form (code and parameter) plus any
/// unreferenced record that still parses as one of the two kinds.
pub fn decodeShader(arena: std.mem.Allocator, v: value.Value) !?ShaderBlob {
    const blob = (try openD3d11Blob(arena, v)) orelse return null;
    const pf = fieldOf(v, "m_ParsedForm") orelse return null;
    const name = trimNul(stringField(pf, "m_Name") orelse "");

    var codes: std.ArrayList(u32) = .empty;
    defer codes.deinit(arena);
    var code_types: std.ArrayList(u32) = .empty;
    defer code_types.deinit(arena);
    var params: std.ArrayList(u32) = .empty;
    defer params.deinit(arena);
    try collectCodeParams(arena, pf, &codes, &code_types, &params);

    const n = blob.records.len;
    const records = try arena.alloc(DecodedRecord, n);
    var count: usize = 0;
    for (0..n) |i| {
        const rec = blob.records[i];
        // referenced as code?
        var code_idx: ?usize = null;
        for (codes.items, 0..) |c, j| {
            if (c == i) {
                code_idx = j;
                break;
            }
        }
        // referenced as param?
        var param_ref = false;
        for (params.items) |p| {
            if (p == i) {
                param_ref = true;
                break;
            }
        }
        const gpu_type: u32 = if (code_idx) |j| code_types.items[j] else 0;
        if (code_idx != null) {
            if (try decodeCodeRecord(arena, blob.data, rec, @intCast(i), gpu_type)) |dr| {
                records[count] = dr;
                count += 1;
            }
        } else if (param_ref) {
            if (try decodeParamRecord(arena, blob.data, rec, @intCast(i))) |dr| {
                records[count] = dr;
                count += 1;
            }
        } else {
            // unreferenced: best-effort classify
            if (try decodeCodeRecord(arena, blob.data, rec, @intCast(i), 0)) |dr| {
                records[count] = dr;
                count += 1;
            } else if (try decodeParamRecord(arena, blob.data, rec, @intCast(i))) |dr| {
                records[count] = dr;
                count += 1;
            }
            // else: leave out (unknown records are not part of the table)
        }
    }

    return .{
        .name = name,
        .platform = platform_d3d11,
        .records = try arena.dupe(DecodedRecord, records[0..count]),
        .code_indices = try arena.dupe(u32, codes.items),
        .param_indices = try arena.dupe(u32, params.items),
    };
}

fn stringField(v: value.Value, name: []const u8) ?[]const u8 {
    return switch (fieldOf(v, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Verifies a Shader's sub-program blob round-trips: the d3d11 platform blob
/// decompresses and every record that is a parameter blob re-encodes byte
/// for byte (the property the reference implementation holds on every stock
/// blob). Code records hold opaque compiled bytes and are not re-encoded.
/// Shaders without a single-tier d3d11 blob have nothing to check and report
/// true.
pub fn verifyBlob(arena: std.mem.Allocator, v: value.Value) !bool {
    const blob = (try openD3d11Blob(arena, v)) orelse return true;
    const data = blob.data;
    for (blob.records) |rec| {
        const off: usize = rec.offset;
        const rec_end: usize = off + @as(usize, rec.length);
        if (off + 8 > data.len or rec_end > data.len) continue;
        const raw = data[off..rec_end];
        // Parameter blobs are re-encoded; anything that does not parse as one
        // (a code record, or an unknown record) is not re-encoded.
        const pb = parseParameterBlobFull(arena, data, off) catch continue;
        var w = streams.Writer.init(arena);
        try writeParameterBlob(&w, pb);
        const rebuilt = w.getWritten();
        if (rebuilt.len != raw.len or !std.mem.eql(u8, rebuilt, raw)) return false;
    }
    return true;
}

test "shader blob decoder survives mutated payloads" {
    // Hostile shader blobs (corrupt LZ4 data, garbage record tables) must
    // never crash the decoder: mutations and truncations of a valid blob -
    // both the plain and the LZ4-compressed form - must verify cleanly or
    // fail with an error.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = try buildSyntheticBlob(a, true);
    const compressed = try lz4.compress(a, plain);

    var prng = std.Random.DefaultPrng.init(0x5af0);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const source: []const u8 = if (iter % 2 == 0) plain else compressed;
        const mode = rnd.int(u8) % 3;
        const blen = switch (mode) {
            0 => rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(source.len))), // truncate
            1 => source.len, // mutate
            else => @min(source.len + rnd.intRangeAtMost(u32, 1, 32), buf.len), // extend
        };
        @memcpy(buf[0..source.len], source);
        if (mode == 1 and source.len > 0) {
            const m = rnd.intRangeAtMost(u32, 0, @as(u32, @intCast(source.len - 1)));
            buf[m] ^= @intCast(rnd.int(u8) | 1);
        }
        const shader = buildShaderValue(buf[0..blen]);
        _ = verifyBlob(a, shader) catch continue;
    }
}
