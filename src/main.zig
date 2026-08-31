const std = @import("std");
const Io = std.Io;

const unityz = @import("unityz");

/// Unity class-ID to class-name lookup, owned by the library.
const className = unityz.classes.className;

/// Sprite render-data triangle-index reader, owned by the library.
const readSpriteTriangles = unityz.classes.readSpriteTriangles;

const usage =
    \\unityz — read, extract, and edit Unity assets
    \\
    \\Usage:
    \\  unityz <command> <path>
    \\  unityz --help | --version
    \\
    \\Commands:
    \\  info <path>     Print what unityz can read from a Unity asset file
    \\                 (add --objects for the object table, --dump for JSON,
    \\                  --json for a machine-readable summary; --objects
    \\                  also adds the object table to --json output)
    \\  extract <path>  Extract embedded assets from a Unity asset file
    \\                 (--raw raw bytes; --json value trees as JSON, plus
    \\                  a manifest.json index; --class N / --path-id N
    \\                  filters, N may be node:path-id; --name <substring>
    \\                  name filter; --recursive for bundles/webfiles;
    \\                  --format png|tga|bmp|raw image output (default
    \\                  png); --outdir <dir> to write into, created if
    \\                  missing)
    \\  edit <path>     Apply edits to a Unity asset file
    \\                 (bundles: finds and edits the embedded node, then
    \\                  rebuilds the bundle)
    \\  verify <path>   Verify every object round-trips byte-exactly
    \\                 (--class N / --path-id N to check a subset,
    \\                  N may be node:path-id; --json for a machine-readable
    \\                  report)
    \\  stats <path>    Per-class sizes + duplicate-object detection
    \\                 (--json for a machine-readable summary;
    \\                  --class <id> to filter; --dups for only the
    \\                  duplicate report)
    \\  find <path> <s>  Find objects whose name contains <s>
    \\                 (--class <id> to filter by class;
    \\                  --exact for a case-sensitive whole-name match;
    \\                  --json for a machine-readable array)
    \\  show <path> <id> Print one object as JSON
    \\                 (--raw for a hex dump of its serialized bytes;
    \\                  <id> may be node:path-id to target a container entry;
    \\                  a Shader object also carries a decoded "shaderBlob")
    \\  shader <path> <id>  Print a Shader's decoded sub-program blob table
    \\                 (same as `show` on a Shader; <id> may be node:path-id)
    \\  diff <a> <b>     Compare two files' objects by content hash;
    \\                 directories compare the two trees file-by-file
    \\                 (--json for a machine-readable diff;
    \\                  --class <id> to compare one class;
    \\                  --pixels to decode matched Texture2D/Sprite images
    \\                  and report pixel diffs; --audio to compare matched
    \\                  AudioClip streams)
    \\  hash <path>      Print per-object content fingerprints
    \\                 (--json for a machine-readable array;
    \\                  --class <id> / --path-id <id> filters,
    \\                  <id> may be node:path-id)
    \\  skin <path>      Report whether every Shader (class 48) skins
    \\                 (exits non-zero when a SkinnedMeshRenderer references
    \\                  a shader that does not skin; --json for a
    \\                  machine-readable report)
    \\
    \\Edit usage: unityz edit <file> <path_id> <field> <json-value> [<field> <json-value> ...]
    \\  <field> may be dotted and indexed, e.g. m_Container[0][1].preloadSize
    \\  <path_id> may be node:path-id to target a specific container entry
    \\  (add --out <file> to write elsewhere instead of in place;
    \\   or --patch <file> with a JSON patch of path-id -> field -> value;
    \\   --verify round-trip-checks the result and refuses to write on failure)
;

/// Flushes stdout, exiting like SIGPIPE would (141) when the consumer
/// closed the pipe early (e.g. `| head`). Zig does not die on SIGPIPE,
/// so without this the drain error surfaces as an ugly WriteFailed trace.
fn finalFlush(stdout: *Io.Writer) void {
    stdout.flush() catch std.process.exit(141);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    io_global.io = io;
    // The args slice includes argv[0]; drop it.
    const args = (try init.minimal.args.toSlice(arena))[1..];

    var out_buffer: [1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    const stdout = &out_writer.interface;

    var err_buffer: [1024]u8 = undefined;
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buffer);
    const stderr = &err_writer.interface;

    if (args.len == 0) {
        try stderr.print("{s}\n", .{usage});
        try stderr.flush();
        std.process.exit(2);
    }

    const arg0 = args[0];
    if (std.mem.eql(u8, arg0, "--help") or std.mem.eql(u8, arg0, "-h")) {
        try stdout.print("{s}\n", .{usage});
        finalFlush(stdout);
        return;
    }

    if (std.mem.eql(u8, arg0, "--version") or std.mem.eql(u8, arg0, "-V")) {
        const v = unityz.version;
        try stdout.print("unityz {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });
        finalFlush(stdout);
        return;
    }

    const command = parseCommand(arg0) orelse {
        try stderr.print("unityz: unknown command '{s}'\n\n{s}\n", .{ arg0, usage });
        try stderr.flush();
        std.process.exit(2);
    };

    if (args.len < 2) {
        try stderr.print("unityz: '{s}' needs a path argument\n\n{s}\n", .{ arg0, usage });
        try stderr.flush();
        std.process.exit(2);
    }

    // Read the whole file once; the parsers borrow from the buffer. A
    // directory argument processes every file in it (batch mode).
    const path = args[1];
    const rest = args[2..];

    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        try stderr.print("unityz: {s}: {s}\n", .{ path, @errorName(error.FileNotFound) });
        try stderr.flush();
        std.process.exit(1);
    };
    // `diff` consumes directories itself (tree comparison); every other
    // command batch-expands a directory argument over its files.
    if (stat.kind == .directory and command == .diff) {
        cmdDiff(path, rest, &.{}, stdout) catch |err| {
            if (err == error.WriteFailed) std.process.exit(141);
            try stderr.print("unityz: {s}: {s}\n", .{ path, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
        finalFlush(stdout);
        if (verify_failed_flag) std.process.exit(1);
        return;
    }
    if (stat.kind == .directory and command != .diff) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            try stderr.print("unityz: {s}: {s}\n", .{ path, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, entry.name });
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch |err| {
                try stderr.print("unityz: {s}: {s}\n", .{ full, @errorName(err) });
                try stderr.flush();
                continue;
            };
            runCommand(command, full, rest, bytes, stdout) catch |err| {
                if (err == error.WriteFailed) std.process.exit(141);
                try stderr.print("unityz: {s}: {s}\n", .{ full, @errorName(err) });
                try stderr.flush();
            };
        }
        finalFlush(stdout);
        if (verify_failed_flag) std.process.exit(1);
        return;
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        try stderr.print("unityz: {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };

    runCommand(command, path, rest, bytes, stdout) catch |err| {
        if (err == error.WriteFailed) std.process.exit(141);
        try stderr.print("unityz: {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };
    finalFlush(stdout);
    if (verify_failed_flag) std.process.exit(1);
}

const Command = enum { info, extract, edit, verify, stats, find, show, diff, hash, skin, shader };

fn parseCommand(arg: []const u8) ?Command {
    inline for (std.meta.fields(Command)) |field| {
        if (std.mem.eql(u8, arg, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn runCommand(command: Command, path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    switch (command) {
        .info => {
            var dump = false;
            var objects = false;
            var json = false;
            for (rest) |arg| {
                if (std.mem.eql(u8, arg, "--dump")) {
                    dump = true;
                } else if (std.mem.eql(u8, arg, "--objects")) {
                    objects = true;
                } else if (std.mem.eql(u8, arg, "--json")) {
                    json = true;
                } else {
                    try stdout.print("unityz: unknown info option '{s}'\n", .{arg});
                    return;
                }
            }
            return cmdInfo(path, bytes, dump, objects, json, stdout);
        },
        .extract => return cmdExtract(path, rest, bytes, stdout),
        .edit => return cmdEdit(path, rest, bytes, stdout),
        .verify => return cmdVerify(path, rest, bytes, stdout),
        .stats => return cmdStats(path, rest, bytes, stdout),
        .find => return cmdFind(path, rest, bytes, stdout),
        .show => return cmdShow(path, rest, bytes, stdout, false),
        .shader => return cmdShow(path, rest, bytes, stdout, true),
        .diff => return cmdDiff(path, rest, bytes, stdout),
        .hash => return cmdHash(path, rest, bytes, stdout),
        .skin => return cmdSkin(path, rest, bytes, stdout),
    }
}

const io_global = struct {
    var io: std.Io = undefined;
};

/// Set by `cmdVerify` when any object fails; main() exits non-zero on it
/// so batch runs keep going and still report failure at the end.
var verify_failed_flag: bool = false;

/// Output directory for extracted files (`extract --outdir <dir>`);
/// created when missing.
var extract_outdir: ?[]const u8 = null;

/// `extract <path> [--raw] [--json]` — write embedded assets (to the
/// current directory or `--outdir <dir>`): bundle/webfile nodes as files,
/// serialized-file textures as PNG, meshes as OBJ, text assets, sprites,
/// materials, shaders, and MonoBehaviour payloads (raw `.bin` plus a decoded
/// `.json` of the managed .NET object graph). With `--raw`, every
/// object's serialized bytes are written as-is; with `--json`, every
/// object with a type tree is exported as its value tree JSON instead.
/// `--outdir` is created if missing.
/// Image output format for `extract` textures and sprites. UnityPy only
/// writes PNG; TGA and BMP cover legacy pipelines, and `raw` dumps the
/// RGBA8 bytes for external tools.
const ExtractFormat = enum { png, tga, bmp, raw };

fn parseFormat(s: []const u8) !ExtractFormat {
    if (std.mem.eql(u8, s, "png")) return .png;
    if (std.mem.eql(u8, s, "tga")) return .tga;
    if (std.mem.eql(u8, s, "bmp")) return .bmp;
    if (std.mem.eql(u8, s, "raw")) return .raw;
    return error.UnknownFormat;
}

fn formatExtension(format: ExtractFormat) []const u8 {
    return switch (format) {
        .png => "png",
        .tga => "tga",
        .bmp => "bmp",
        .raw => "rgba",
    };
}

/// Encodes `rgba` in the requested format; raw passes the bytes through.
fn encodeImage(arena: std.mem.Allocator, format: ExtractFormat, w: u32, h: u32, rgba: []const u8) ![]const u8 {
    return switch (format) {
        .png => try unityz.png.encode(arena, w, h, rgba),
        .tga => try unityz.tga.encode(arena, w, h, rgba),
        .bmp => try unityz.bmp.encode(arena, w, h, rgba),
        .raw => rgba,
    };
}

fn cmdExtract(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var raw = false;
    var recursive = false;
    var json_mode = false;
    var class_filter: ?i32 = null;
    var path_filter: ?Selector = null;
    var name_filter: ?[]const u8 = null;
    var format: ExtractFormat = .png;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--raw")) {
            raw = true;
        } else if (std.mem.eql(u8, arg, "--recursive")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--class") and i + 1 < rest.len) {
            class_filter = std.fmt.parseInt(i32, rest[i + 1], 10) catch {
                try stdout.print("unityz: invalid class id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--outdir") and i + 1 < rest.len) {
            extract_outdir = rest[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--path-id") and i + 1 < rest.len) {
            path_filter = parseSelector(rest[i + 1]) catch {
                try stdout.print("unityz: invalid path id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < rest.len) {
            name_filter = rest[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < rest.len) {
            format = parseFormat(rest[i + 1]) catch {
                try stdout.print("unityz: unknown extract format '{s}' (png|tga|bmp|raw)\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else {
            try stdout.print("unityz: unknown extract option '{s}'\n", .{arg});
            return;
        }
    }
    if (raw and json_mode) {
        try stdout.print("unityz: --raw and --json are mutually exclusive\n", .{});
        return;
    }
    if (extract_outdir) |d| {
        const io = io_global.io;
        ensureDirPath(io, d) catch |err| {
            try stdout.print("unityz: {s}: {s}\n", .{ d, @errorName(err) });
            return;
        };
    }
    const sniff = unityz.container.sniff(bytes);
    switch (sniff.container) {
        .webfile => {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var manifest: std.ArrayList(ManifestEntry) = .empty;
            var sidecars: std.ArrayList(Sidecar) = .empty;
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("unityz: {s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container == .serialized) continue;
                try sidecars.append(arena, .{ .path = e.path, .data = e.data });
            }
            for (wf.entries) |e| {
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, e.path, sn)) continue;
                    }
                }
                try writeFileToCwd(basename(e.path), e.data);
                try stdout.print("extracted {s} ({d} bytes)\n", .{ basename(e.path), e.data.len });
                if (recursive and unityz.container.sniff(e.data).container == .serialized) {
                    try extractSerialized(arena, e.path, e.data, raw, json_mode, class_filter, if (path_filter) |pf| pf.path_id else null, try std.fmt.allocPrint(arena, "objects/{s}", .{basename(e.path)}), sidecars.items, &manifest, format, name_filter, stdout);
                }
            }
            if (json_mode) try writeManifest(arena, manifest.items, stdout);
        },
        .bundle => {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var manifest: std.ArrayList(ManifestEntry) = .empty;
            var sidecars: std.ArrayList(Sidecar) = .empty;
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("unityz: {s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container == .serialized) continue;
                try sidecars.append(arena, .{ .path = n.path, .data = n.data });
            }
            for (b.nodes) |n| {
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, n.path, sn)) continue;
                    }
                }
                try writeFileToCwd(basename(n.path), n.data);
                try stdout.print("extracted {s} ({d} bytes)\n", .{ basename(n.path), n.data.len });
                if (recursive and unityz.container.sniff(n.data).container == .serialized) {
                    try extractSerialized(arena, n.path, n.data, raw, json_mode, class_filter, if (path_filter) |pf| pf.path_id else null, try std.fmt.allocPrint(arena, "objects/{s}", .{basename(n.path)}), sidecars.items, &manifest, format, name_filter, stdout);
                }
            }
            if (json_mode) try writeManifest(arena, manifest.items, stdout);
        },
        .serialized => {
            if (path_filter) |pf| {
                if (pf.node != null) {
                    try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                    return;
                }
            }
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var manifest: std.ArrayList(ManifestEntry) = .empty;
            try extractSerialized(arena, path, bytes, raw, json_mode, class_filter, if (path_filter) |pf| pf.path_id else null, null, &.{}, &manifest, format, name_filter, stdout);
            if (json_mode) try writeManifest(arena, manifest.items, stdout);
        },
        else => {
            try stdout.print("unityz: {s}: nothing to extract from this file type\n", .{path});
        },
    }
}

/// A container node holding streamed data referenced by objects via
/// m_StreamData paths (`.resS` / `.resource` sidecars).
const Sidecar = struct { path: []const u8, data: []const u8 };

/// One `extract --json` manifest entry; `subdir` is the container node
/// the object came from (objects are written into a per-node subdirectory
/// so identical path ids in different nodes do not collide).
const ManifestEntry = struct { path_id: i64, class_id: i32, name: []const u8, subdir: ?[]const u8 = null };

/// Writes `manifest.json` next to the exported value trees, listing every
/// object: path id, class, the file it was written to, and its m_Name.
fn writeManifest(arena: std.mem.Allocator, entries: []const ManifestEntry, stdout: *Io.Writer) !void {
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const w = &aw.writer;
    try w.print("{{\"objects\":[", .{});
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"path_id\":{d},\"class\":{d},\"file\":", .{ e.path_id, e.class_id });
        var name_buf: [64]u8 = undefined;
        const fname = try std.fmt.bufPrint(&name_buf, "object_{d}_class{d}.json", .{ e.path_id, e.class_id });
        if (e.subdir) |sd| {
            var full_buf: [160]u8 = undefined;
            const full_name = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ sd, fname });
            try writeJsonString(w, full_name);
        } else {
            try writeJsonString(w, fname);
        }
        try w.print(",\"name\":", .{});
        try writeJsonString(w, std.mem.trimEnd(u8, e.name, "\x00"));
        try w.print("}}", .{});
    }
    try w.print("]}}\n", .{});
    const out = aw.toArrayList();
    try writeFileToCwd("manifest.json", out.items);
    try stdout.print("extracted manifest.json ({d} object(s))\n", .{entries.len});
}

/// Writes an extracted file, placing it under `subdir` when the object
/// came from a container node (see extractSerialized); the subdirectory
/// is created under the output directory when missing.
fn extractFile(subdir: ?[]const u8, name: []const u8, contents: []const u8) !void {
    if (subdir) |sd| {
        const base_owned = extract_outdir != null;
        const base = if (extract_outdir) |d|
            try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ d, sd })
        else
            sd;
        defer if (base_owned) std.heap.page_allocator.free(base);
        // Propagate a failed mkdir: swallowing it turns "cannot create
        // <dir>: AccessDenied" into a bare FileNotFound on the write.
        try ensureDirPath(io_global.io, base);
        const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ sd, name });
        defer std.heap.page_allocator.free(full);
        try writeFileToCwd(full, contents);
    } else {
        try writeFileToCwd(name, contents);
    }
}

/// Returns the `size` bytes at `offset` of the sidecar whose basename
/// matches `stream_path` (e.g. "archive:/CAB-x/CAB-x.resS" resolves to
/// the node "CAB-x.resS"), or an empty slice when absent.
fn resolveSidecar(sidecars: []const Sidecar, stream_path: []const u8, offset: u64, size: u64) []const u8 {
    const base = basename(stream_path);
    for (sidecars) |sc| {
        if (!std.mem.eql(u8, basename(sc.path), base)) continue;
        const start: usize = @intCast(offset);
        const end = start + @as(usize, @intCast(size));
        if (end <= sc.data.len) return sc.data[start..end];
        return &.{};
    }
    return &.{};
}

/// One hit from a SpriteAtlas lookup: the texture the sprite was packed
/// into, plus the atlas's textureRect, alphaTexture and settingsRaw for it
/// (mirrors UnityPy, which crops the atlas's rect rather than the sprite's
/// own copy).
const AtlasHit = struct {
    texture: unityz.value.PPtr,
    rect: [4]f32,
    alpha_texture: ?unityz.value.PPtr = null,
    settings_raw: u32 = 0,
};

/// Compares two m_RenderDataKey values: `[Hash128, int]` where Hash128 is
/// an object with `data[0..3]` u32 fields.
fn renderDataKeyEq(a: unityz.value.Value, b: unityz.value.Value) bool {
    if (a != .array or b != .array) return false;
    if (a.array.len != 2 or b.array.len != 2) return false;
    const ha = a.array[0];
    const hb = b.array[0];
    if (ha != .obj or hb != .obj) return false;
    var buf: [16]u8 = undefined;
    for (0..4) |i| {
        const fname = std.fmt.bufPrint(&buf, "data[{d}]", .{i}) catch return false;
        const fa = unityz.classes.fieldOf(ha, fname) orelse return false;
        const fb = unityz.classes.fieldOf(hb, fname) orelse return false;
        if (fa.asInt() != fb.asInt()) return false;
    }
    const ia = a.array[1];
    const ib = b.array[1];
    return ia.asInt() == ib.asInt();
}

/// Reads the `texture` PPtr (and its textureRect) out of one
/// m_RenderDataMap entry of the form `[key, SpriteAtlasData]`.
fn atlasEntryHit(entry: unityz.value.Value) ?AtlasHit {
    if (entry != .array or entry.array.len < 2) return null;
    const val = entry.array[1];
    if (val != .obj) return null;
    var hit = AtlasHit{ .texture = undefined, .rect = .{ 0, 0, 0, 0 } };
    for (val.obj) |f| {
        if (f.value == .pptr and std.mem.eql(u8, f.name, "texture")) hit.texture = f.value.pptr;
        if (f.value == .pptr and std.mem.eql(u8, f.name, "alphaTexture")) hit.alpha_texture = f.value.pptr;
        if (f.value == .obj and std.mem.eql(u8, f.name, "textureRect")) {
            const comps = [_][]const u8{ "x", "y", "width", "height" };
            for (comps, 0..) |c, i| {
                const cf = unityz.classes.fieldOf(f.value, c) orelse continue;
                if (cf.asFloat()) |fv| hit.rect[i] = @floatCast(fv);
            }
        }
        if (f.value.asInt() != null and std.mem.eql(u8, f.name, "settingsRaw")) {
            const sr = f.value.asInt().?;
            hit.settings_raw = @truncate(@as(u64, @bitCast(sr)));
        }
    }
    if (hit.texture.path_id == 0) return null;
    return hit;
}

/// Finds the texture PPtr for a Sprite that has none of its own by
/// scanning the file's SpriteAtlas objects. Matches m_RenderDataKey the
/// way UnityPy does; when the key is absent, falls back to aligning
/// m_PackedSprites with m_RenderDataMap by position.
fn atlasTextureFor(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, sprite_value: unityz.value.Value, sprite_path_id: i64) ?AtlasHit {
    const sprite_key = unityz.classes.fieldOf(sprite_value, "m_RenderDataKey");
    for (sf.objects) |*o| {
        if (o.class_id != 687078895) continue; // SpriteAtlas
        const ti = o.type_index orelse continue;
        if (ti >= sf.types.len) continue;
        const tree = sf.types[ti].type_tree;
        if (tree.roots.len == 0) continue;
        const data = sf.objectData(o) orelse continue;
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch continue;
        const rdm = unityz.classes.fieldOf(v, "m_RenderDataMap") orelse continue;
        if (rdm != .array) continue;
        if (sprite_key) |sk| {
            for (rdm.array) |entry| {
                if (entry != .array or entry.array.len < 2) continue;
                if (renderDataKeyEq(sk, entry.array[0])) return atlasEntryHit(entry);
            }
        }
        // key mismatch or absent: fall back to positional alignment
        const packed_sprites = unityz.classes.fieldOf(v, "m_PackedSprites") orelse continue;
        if (packed_sprites != .array or packed_sprites.array.len != rdm.array.len) continue;
        for (packed_sprites.array, 0..) |item, i| {
            if (item != .pptr or item.pptr.path_id != sprite_path_id) continue;
            return atlasEntryHit(rdm.array[i]);
        }
    }
    return null;
}

/// Wraps interleaved little-endian PCM in a WAV container. `bits` is the
/// source sample width (16 for decoded FSB5 samples; the raw AudioClip
/// path passes its own width).
fn wavPcm16(arena: std.mem.Allocator, pcm: []const u8, channels: u16, rate: u32, bits: u16) ![]u8 {
    var wav_buf: std.ArrayList(u8) = .empty;
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], @as(u32, @intCast(36 + pcm.len)), .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], channels, .little);
    std.mem.writeInt(u32, hdr[24..28], rate, .little);
    std.mem.writeInt(u32, hdr[28..32], rate * @as(u32, channels) * @as(u32, bits) / 8, .little);
    std.mem.writeInt(u16, hdr[32..34], @intCast(@as(u32, channels) * @as(u32, bits) / 8), .little);
    std.mem.writeInt(u16, hdr[34..36], bits, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], @as(u32, @intCast(pcm.len)), .little);
    try wav_buf.appendSlice(arena, &hdr);
    try wav_buf.appendSlice(arena, pcm);
    return wav_buf.items;
}

/// FSB5 bank metadata as a JSON document, or null when the data is not a
/// well-formed FSB5 bank. Beyond UnityPy: its export converts the audio
/// but never reports loop points or the header fields.
fn fsb5MetadataJson(arena: std.mem.Allocator, audio: []const u8) !?[]u8 {
    const bank = try unityz.fsb5.parse(arena, audio) orelse return null;
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"version\":", .{});
    try w.print("{d},\"mode\":{d},\"samples\":[", .{ bank.version, bank.mode });
    for (bank.samples, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        const dur_ms: u64 = if (s.frequency != 0) @as(u64, s.sample_count) * 1000 / s.frequency else 0;
        try w.print("{{\"name\":\"{s}\",\"frequency\":{d},\"channels\":{d},\"dataOffset\":{d},\"samples\":{d},\"durationMs\":{d}",
            .{ s.name, s.frequency, s.channels, s.data_offset, s.sample_count, dur_ms });
        if (s.loop_start) |ls| {
            try w.print(",\"loopStart\":{d},\"loopEnd\":{d}", .{ ls, s.loop_end orelse 0 });
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    var list = aw.toArrayList();
    return try list.toOwnedSlice(arena);
}


fn extractSerialized(arena: std.mem.Allocator, path: []const u8, bytes: []const u8, raw: bool, json_mode: bool, class_filter: ?i32, path_filter: ?i64, subdir: ?[]const u8, sidecars: []const Sidecar, manifest: *std.ArrayList(ManifestEntry), format: ExtractFormat, name_filter: ?[]const u8, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("unityz: {s}: serialized file parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };

    var extracted: usize = 0;
    var skipped: usize = 0;
    for (sf.objects) |*o| {
        if (class_filter) |cf| {
            if (o.class_id != cf) continue;
        }
        if (path_filter) |pf| {
            if (o.path_id != pf) continue;
        }
        const data = sf.objectData(o) orelse continue;
        if (raw) {
            // raw mode: dump every object's serialized bytes as-is
            var name_buf: [128]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "object_{d}_class{d}.bin", .{ o.path_id, o.class_id });
            try extractFile(subdir, name, data);
            try stdout.print("extracted {s} ({d} bytes)\n", .{ name, data.len });
            extracted += 1;
            continue;
        }
        const type_index = o.type_index orelse continue;
        if (type_index >= sf.types.len) continue;
        const tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) continue;

        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch |err| {
            try stdout.print("  object {d} (class {d}): decode failed: {s}\n", .{ o.path_id, o.class_id, @errorName(err) });
            skipped += 1;
            continue;
        };

        if (name_filter) |nf| {
            const nm = unityz.classes.stringField(v, "m_Name") orelse "";
            if (std.ascii.indexOfIgnoreCase(nm, nf) == null) continue;
        }

        if (json_mode) {
            // JSON mode: export the object's value tree, not a decoded asset
            var buf: std.ArrayList(u8) = .empty;
            var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
            try unityz.value.jsonWrite(v, &aw.writer);
            const out = aw.toArrayList();
            var name_buf: [96]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "object_{d}_class{d}.json", .{ o.path_id, o.class_id });
            try extractFile(subdir, name, out.items);
            try stdout.print("extracted {s} ({d} bytes)\n", .{ name, out.items.len });
            try manifest.append(arena, .{
                .path_id = o.path_id,
                .class_id = o.class_id,
                .name = unityz.classes.stringField(v, "m_Name") orelse "",
                .subdir = subdir,
            });
            extracted += 1;
            continue;
        }

        switch (o.class_id) {
            28 => { // Texture2D
                const t = unityz.classes.Texture2D.fromValue(v);
                if (t.width == 0 or t.height == 0) continue;
                // embedded pixels: m_ImageData, or streamed range in this file
                var pixels: []const u8 = t.image_data;
                if (pixels.len == 0 and t.stream.size > 0 and t.stream.path.len == 0) {
                    const start: usize = @intCast(sf.data_offset + t.stream.offset);
                    const end = start + t.stream.size;
                    if (end <= sf.source.len) pixels = sf.source[start..end];
                }
                if (pixels.len == 0 and t.stream.size > 0 and t.stream.path.len != 0) {
                    // streamed from a sibling .resS/.resource node
                    pixels = resolveSidecar(sidecars, t.stream.path, t.stream.offset, t.stream.size);
                }
                if (pixels.len == 0) continue;
                const rgba = unityz.texture.decode(arena, t.format, t.width, t.height, pixels) catch |err| {
                    try stdout.print("  texture {d}: {s} ({s}) unsupported\n", .{ o.path_id, unityz.texture.format.name(t.format), @errorName(err) });
                    skipped += 1;
                    continue;
                };
                // Unity stores texture rows bottom-up; PNGs are top-down, so
                // flip to match on-screen appearance (and UnityPy's export).
                const flipped = unityz.texture.flipVertical(arena, rgba, t.width, t.height) catch |err| {
                    try stdout.print("  texture {d}: flip failed: {s}\n", .{ o.path_id, @errorName(err) });
                    skipped += 1;
                    continue;
                };
                const image = encodeImage(arena, format, t.width, t.height, flipped) catch |err| {
                    try stdout.print("  texture {d}: image encode failed: {s}\n", .{ o.path_id, @errorName(err) });
                    skipped += 1;
                    continue;
                };
                var name_buf: [96]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "texture_{d}_{d}x{d}.{s}", .{ o.path_id, t.width, t.height, formatExtension(format) });
                try extractFile(subdir, name, image);
                try stdout.print("extracted {s} ({s})\n", .{ name, unityz.texture.format.name(t.format) });
                extracted += 1;
            },
            49 => { // TextAsset
                const ta = unityz.classes.TextAsset.fromValue(v);
                var name_buf: [64]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "text_{d}.txt", .{o.path_id});
                try extractFile(subdir, name, ta.script);
                try stdout.print("extracted {s} ({d} bytes)\n", .{ name, ta.script.len });
                extracted += 1;
            },
            83 => { // AudioClip
                const ac = unityz.classes.AudioClip.fromValue(v);
                var audio: []const u8 = ac.audio_data;
                if (audio.len == 0 and ac.resource.size > 0 and ac.resource.path.len != 0) {
                    // streamed from a sibling .resS/.resource sidecar
                    audio = resolveSidecar(sidecars, ac.resource.path, ac.resource.offset, ac.resource.size);
                }
                if (audio.len == 0) continue;
                var ext: []const u8 = "bin";
                if (std.mem.startsWith(u8, audio, "OggS")) {
                    ext = "ogg";
                } else if (std.mem.startsWith(u8, audio, "FSB5")) {
                    ext = "fsb";
                } else if (ac.compression_format == 3) {
                    ext = "mp3";
                }
                var wav_buf: std.ArrayList(u8) = .empty;
                if (std.mem.eql(u8, ext, "bin") and ac.compression_format == 0) {
                    // wrap raw PCM in a WAV container
                    const bits: u16 = @intCast(if (ac.bits_per_sample == 0) 16 else ac.bits_per_sample);
                    const ch: u16 = @intCast(if (ac.channels == 0) 1 else ac.channels);
                    wav_buf.appendSlice(arena, wavPcm16(arena, audio, ch, ac.frequency, bits) catch continue) catch continue;
                    ext = "wav";
                    audio = wav_buf.items;
                }
                var name_buf: [128]u8 = undefined;
                const base_name = std.mem.trimEnd(u8, ac.name, "\x00");
                const name = sanitizeComponent(if (base_name.len != 0)
                    try std.fmt.bufPrint(&name_buf, "audio_{d}_{s}.{s}", .{ o.path_id, base_name, ext })
                else
                    try std.fmt.bufPrint(&name_buf, "audio_{d}.{s}", .{ o.path_id, ext }));
                try extractFile(subdir, name, audio);
                // FSB5 banks get a metadata sidecar: sample rate, channels,
                // loop points, and format - UnityPy's export never surfaces
                // this (it only converts the audio itself).
                if (std.mem.startsWith(u8, audio, "FSB5")) {
                    if (try fsb5MetadataJson(arena, audio)) |meta| {
                        var meta_name_buf: [160]u8 = undefined;
                        const meta_name = try std.fmt.bufPrint(&meta_name_buf, "{s}.json", .{name});
                        try extractFile(subdir, meta_name, meta);
                    }
                    // Codecs that decode in pure Zig (PCM8/16/24/32/FLOAT,
                    // IMA ADPCM) also export as a playable WAV, no external
                    // tools needed. Vorbis banks (mode 15) need a transform
                    // codec and stay as .fsb - UnityPy shells out to ffmpeg
                    // for every conversion, so this is beyond-parity.
                    if (try unityz.fsb5.parse(arena, audio)) |bank| {
                        if (unityz.audio.decodable(bank.mode)) {
                            for (bank.samples, 0..) |s, si| {
                                const pcm = unityz.audio.decodeSample(arena, audio, bank.data_start, s, bank.mode) catch |err| {
                                    try stdout.print("  audio {d}: FSB5 decode failed: {s}\n", .{ o.path_id, @errorName(err) });
                                    skipped += 1;
                                    continue;
                                };
                                const wav = wavPcm16(arena, std.mem.sliceAsBytes(pcm), @intCast(s.channels), s.frequency, 16) catch continue;
                                var wav_name_buf: [160]u8 = undefined;
                                const wav_name = if (bank.samples.len == 1)
                                    try std.fmt.bufPrint(&wav_name_buf, "audio_{d}_{s}.wav", .{ o.path_id, base_name })
                                else
                                    try std.fmt.bufPrint(&wav_name_buf, "audio_{d}_{s}_s{d}.wav", .{ o.path_id, base_name, si });
                                try extractFile(subdir, sanitizeComponent(wav_name), wav);
                                try stdout.print("extracted {s} ({d} samples, {s})\n", .{ wav_name, s.sample_count, unityz.audio.modeName(bank.mode) });
                                extracted += 1;
                            }
                        }
                    }
                }
                try stdout.print("extracted {s} ({d} bytes, {s})\n", .{ name, audio.len, ext });
                extracted += 1;
            },
            43 => { // Mesh -> Wavefront OBJ
                const mesh = unityz.classes.Mesh.fromValue(v);
                const obj = writeMeshObj(arena, &sf, v, &mesh) catch |err| {
                    try stdout.print("  mesh {d}: OBJ conversion failed: {s}\n", .{ o.path_id, @errorName(err) });
                    skipped += 1;
                    continue;
                };
                if (obj.len == 0) continue; // unsupported layout, nothing written
                var name_buf: [160]u8 = undefined;
                const mesh_name = std.mem.trimEnd(u8, mesh.name, "\x00");
                const name = sanitizeComponent(if (mesh_name.len != 0)
                    try std.fmt.bufPrint(&name_buf, "mesh_{d}_{s}.obj", .{ o.path_id, mesh_name })
                else
                    try std.fmt.bufPrint(&name_buf, "mesh_{d}.obj", .{o.path_id}));
                try extractFile(subdir, name, obj);
                try stdout.print("extracted {s} ({d} vertices, {d} indices)\n", .{ name, mesh.vertex_count, mesh.index_buffer.len / @as(usize, if (mesh.index_format == 1) 4 else 2) });
                extracted += 1;
            },
            21 => { // Material -> readable text
                const mat = try writeMaterialText(arena, v);
                var name_buf: [160]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "material_{d}.txt", .{o.path_id});
                try extractFile(subdir, name, mat);
                try stdout.print("extracted {s} ({d} bytes)\n", .{ name, mat.len });
                extracted += 1;
            },
            48 => { // Shader -> readable text
                const shd = try writeShaderText(arena, v);
                if (shd.len == 0) continue;
                var name_buf: [160]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "shader_{d}.txt", .{o.path_id});
                try extractFile(subdir, name, shd);
                try stdout.print("extracted {s} ({d} bytes)\n", .{ name, shd.len });
                extracted += 1;
            },
            213 => { // Sprite -> cropped / mesh-rendered image
                const rr = renderSprite(arena, &sf, sidecars, v, o.path_id) orelse continue;
                const image = encodeImage(arena, format, rr.w, rr.h, rr.data) catch |err| {
                    try stdout.print("  sprite {d}: image encode failed: {s}\n", .{ o.path_id, @errorName(err) });
                    skipped += 1;
                    continue;
                };
                const sprite = unityz.classes.Sprite.fromValue(v);
                var name_buf: [192]u8 = undefined;
                const sprite_name = std.mem.trimEnd(u8, sprite.name, "\x00");
                // raw RGBA has no header, so the name carries the dimensions
                const name = sanitizeComponent(if (format == .raw)
                    if (sprite_name.len != 0)
                        try std.fmt.bufPrint(&name_buf, "sprite_{d}_{d}x{d}_{s}.{s}", .{ o.path_id, rr.w, rr.h, sprite_name, formatExtension(format) })
                    else
                        try std.fmt.bufPrint(&name_buf, "sprite_{d}_{d}x{d}.{s}", .{ o.path_id, rr.w, rr.h, formatExtension(format) })
                else if (sprite_name.len != 0)
                    try std.fmt.bufPrint(&name_buf, "sprite_{d}_{s}.{s}", .{ o.path_id, sprite_name, formatExtension(format) })
                else
                    try std.fmt.bufPrint(&name_buf, "sprite_{d}.{s}", .{ o.path_id, formatExtension(format) }));
                try extractFile(subdir, name, image);
                try stdout.print("extracted {s} ({d}x{d})\n", .{ name, rr.w, rr.h });
                extracted += 1;
            },
            687078895 => { // SpriteAtlas -> packed-sprite mapping JSON
                const atlas_name = std.mem.trimEnd(u8, unityz.classes.stringField(v, "m_Name") orelse "", "\x00");
                const packed_sprites = unityz.classes.fieldOf(v, "m_PackedSprites") orelse continue;
                const names = unityz.classes.fieldOf(v, "m_PackedSpriteNamesToIndex") orelse continue;
                if (packed_sprites != .array or names != .array or packed_sprites.array.len != names.array.len) continue;
                var buf: std.ArrayList(u8) = .empty;
                var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
                const w = &aw.writer;
                try w.writeAll("{\"name\":");
                try writeJsonString(w, atlas_name);
                try w.writeAll(",\"sprites\":[");
                for (packed_sprites.array, 0..) |sp, i| {
                    if (i != 0) try w.writeByte(',');
                    try w.writeAll("{\"path_id\":");
                    try w.print("{d},\"name\":", .{pptrPathId(sp) orelse 0});
                    try writeJsonString(w, switch (names.array[i]) {
                        .string => |s| s,
                        else => "",
                    });
                    try w.writeByte('}');
                }
                try w.writeAll("]}\n");
                const out = aw.toArrayList();
                // sanitizeComponent needs a mutable buffer; copy the
                // file-owned name first so it cannot steer the output path.
                var clean_buf: [192]u8 = undefined;
                const clean_name = if (atlas_name.len != 0)
                    sanitizeComponent(try std.fmt.bufPrint(&clean_buf, "{s}", .{atlas_name}))
                else
                    "";
                var name_buf: [192]u8 = undefined;
                const fname = try std.fmt.bufPrint(&name_buf, "atlas_{d}_{s}.json", .{ o.path_id, if (clean_name.len != 0) clean_name else "unnamed" });
                try extractFile(subdir, fname, out.items);
                try stdout.print("extracted {s} ({d} packed sprites)\n", .{ fname, packed_sprites.array.len });
                try manifest.append(arena, .{ .path_id = o.path_id, .class_id = o.class_id, .name = atlas_name, .subdir = subdir });
                extracted += 1;
            },
            142 => { // AssetBundle -> asset manifest JSON
                const ab_name = std.mem.trimEnd(u8, unityz.classes.stringField(v, "m_Name") orelse "", "\x00");
                const container = unityz.classes.fieldOf(v, "m_Container") orelse continue;
                if (container != .array) continue;
                var buf: std.ArrayList(u8) = .empty;
                var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
                const w = &aw.writer;
                try w.writeAll("{\"name\":");
                try writeJsonString(w, ab_name);
                const main_id = if (unityz.classes.fieldOf(v, "m_MainAsset")) |m| blk: {
                    if (unityz.classes.fieldOf(m, "asset")) |a| break :blk pptrPathId(a) orelse 0;
                    break :blk 0;
                } else 0;
                try w.print(",\"main_asset\":{d},\"assets\":[", .{main_id});
                // m_Container is a map rendered as [name, AssetInfo] pairs
                var count: usize = 0;
                for (container.array) |pair| {
                    if (pair != .array or pair.array.len < 2) continue;
                    const asset_name = switch (pair.array[0]) {
                        .string => |s| s,
                        else => continue,
                    };
                    const path_id = if (unityz.classes.fieldOf(pair.array[1], "asset")) |a|
                        pptrPathId(a) orelse 0
                    else
                        0;
                    if (count != 0) try w.writeByte(',');
                    try w.writeAll("{\"path\":");
                    try writeJsonString(w, asset_name);
                    try w.print(",\"path_id\":{d}}}", .{path_id});
                    count += 1;
                }
                try w.writeAll("]}\n");
                const out = aw.toArrayList();
                var clean_buf: [192]u8 = undefined;
                const clean_name = if (ab_name.len != 0)
                    sanitizeComponent(try std.fmt.bufPrint(&clean_buf, "{s}", .{ab_name}))
                else
                    "";
                var name_buf: [192]u8 = undefined;
                const fname = try std.fmt.bufPrint(&name_buf, "assetbundle_{d}_{s}.json", .{ o.path_id, if (clean_name.len != 0) clean_name else "unnamed" });
                try extractFile(subdir, fname, out.items);
                try stdout.print("extracted {s} ({d} assets)\n", .{ fname, count });
                try manifest.append(arena, .{ .path_id = o.path_id, .class_id = o.class_id, .name = ab_name, .subdir = subdir });
                extracted += 1;
            },
            114 => { // MonoBehaviour
                const mb = unityz.classes.MonoBehaviour.fromValue(v);
                // the raw serialized script graph follows the type tree
                const payload = data[r.position()..];
                var ms = unityz.classes.MonoScript{};
                if (mb.script) |p| {
                    if (p.file_id == 0) {
                        for (sf.objects) |*other| {
                            if (other.path_id == p.path_id) {
                                if (other.type_index) |ti| {
                                    if (ti < sf.types.len and sf.types[ti].type_tree.roots.len != 0) {
                                        const od = sf.objectData(other) orelse break;
                                        var r2 = unityz.streams.Reader.init(od);
                                        r2.endian = sf.endian;
                                        const v2 = unityz.object_reader.readObject(arena, &r2, &sf.types[ti].type_tree.roots[0]) catch break;
                                        ms = unityz.classes.MonoScript.fromValue(v2);
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
                // filename uses the qualified name (namespace.class) so
                // scripts sharing a namespace do not collide; the label
                // adds the assembly
                const ms_ns = std.mem.trimEnd(u8, ms.namespace, "\x00");
                const ms_cn = std.mem.trimEnd(u8, ms.class_name, "\x00");
                var qual_buf: [192]u8 = undefined;
                const qual = if (ms_ns.len != 0)
                    try std.fmt.bufPrint(&qual_buf, "{s}.{s}", .{ ms_ns, ms_cn })
                else
                    try std.fmt.bufPrint(&qual_buf, "{s}", .{ms_cn});
                // The name comes from the file: keep it one path component
                // so it cannot steer the output path out of the extract dir.
                _ = sanitizeComponent(qual);
                var fname_buf: [192]u8 = undefined;
                const fname = try std.fmt.bufPrint(&fname_buf, "script_{d}_{s}.bin", .{ o.path_id, if (qual.len != 0) qual else "unnamed" });
                try extractFile(subdir, fname, payload);
                var label_buf: [192]u8 = undefined;
                const label = try std.fmt.bufPrint(&label_buf, "{s} ({s})", .{
                    qual,
                    std.mem.trimEnd(u8, ms.assembly, "\x00"),
                });
                try stdout.print("extracted {s} ({d} bytes) [{s}]\n", .{ fname, payload.len, label });
                // The decoded managed object graph (the type-tree fields plus
                // the serialized .NET fields) is already in `v`; write it as a
                // JSON sidecar so the graph, not just the raw `m_Script` blob,
                // is a first-class extract output.
                var graph_buf: [192]u8 = undefined;
                const graph_name = try std.fmt.bufPrint(&graph_buf, "script_{d}_{s}.json", .{ o.path_id, if (qual.len != 0) qual else "unnamed" });
                try extractFile(subdir, graph_name, try writeValueJson(arena, v));
                extracted += 1;
            },
            else => {},
        }
    }
    try stdout.print("{d} assets extracted, {d} skipped\n", .{ extracted, skipped });
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i| return path[i + 1 ..];
    return path;
}

/// Forces a file-supplied name to stay one path component: an asset's
/// `m_Name` reaches the output filename, so a name like "../../evil" would
/// otherwise steer the write outside the extract directory. Separators and
/// NUL (which truncates the path at the syscall) become '_'. Rewrites in
/// place and returns the same slice for use as a filename.
fn sanitizeComponent(name: []u8) []u8 {
    for (name) |*c| switch (c.*) {
        '/', '\\', 0 => c.* = '_',
        else => {},
    };
    return name;
}

/// Creates a directory and any missing parents, tolerating an existing
/// directory. Walks the path one component at a time with single-level
/// `createDir` instead of std's `createDirPath`, which hangs on special
/// filesystems such as /proc.
fn ensureDirPath(io: std.Io, dir_path: []const u8) !void {
    if (dir_path.len == 0) return;
    if (std.Io.Dir.cwd().statFile(io, dir_path, .{})) |st| {
        if (st.kind == .directory) return;
    } else |_| {}
    var start: usize = 0;
    while (start < dir_path.len) {
        const end = std.mem.indexOfScalarPos(u8, dir_path, start, '/') orelse dir_path.len;
        if (end > start) {
            const prefix = dir_path[0..end];
            // skip only the leading "/" of an absolute path
            if (!(prefix.len == 1 and prefix[0] == '/')) {
                std.Io.Dir.cwd().createDir(io, prefix, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }
        }
        start = end + 1;
    }
}

fn writeFileToCwd(name: []const u8, contents: []const u8) !void {
    const io = io_global.io;
    const dir = std.Io.Dir.cwd();
    const full = if (extract_outdir) |d|
        try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ d, name })
    else
        name;
    const file = try dir.createFile(io, full, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

/// Reads and type-tree-decodes another object of the same file, or null.
fn readObjectValue(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    path_id: i64,
) ?unityz.value.Value {
    for (sf.objects) |*other| {
        if (other.path_id != path_id) continue;
        const ti = other.type_index orelse return null;
        if (ti >= sf.types.len) return null;
        const tree = sf.types[ti].type_tree;
        if (tree.roots.len == 0) return null;
        const od = sf.objectData(other) orelse return null;
        var r2 = unityz.streams.Reader.init(od);
        r2.endian = sf.endian;
        return unityz.object_reader.readObject(arena, &r2, &tree.roots[0]) catch null;
    }
    return null;
}

/// A decoded RGBA texture plus its dimensions.
const DecodedTexture = struct { rgba: []const u8, w: u32, h: u32 };

/// Resolves a Texture2D's pixel bytes: inline `m_ImageData`, the streamed
/// range inside this same serialized file, or a sidecar `.resS`. Empty when
/// none of the three yields data.
fn texturePixels(sf: *const unityz.serialized.SerializedFile, sidecars: []const Sidecar, t: unityz.classes.Texture2D) []const u8 {
    if (t.image_data.len != 0) return t.image_data;
    if (t.stream.size == 0) return &.{};
    if (t.stream.path.len == 0) {
        const start: usize = @intCast(sf.data_offset + t.stream.offset);
        const end = start + t.stream.size;
        return if (end <= sf.source.len) sf.source[start..end] else &.{};
    }
    return resolveSidecar(sidecars, t.stream.path, t.stream.offset, t.stream.size);
}

/// Decodes a file-local (file_id 0) Texture2D at `path_id` to RGBA, reading
/// embedded image data, the in-file stream, or a sibling .resS sidecar.
fn decodeSpriteTexture(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    sidecars: []const Sidecar,
    path_id: i64,
) ?DecodedTexture {
    const tex_value = readObjectValue(arena, sf, path_id) orelse return null;
    const t = unityz.classes.Texture2D.fromValue(tex_value);
    if (t.width == 0 or t.height == 0) return null;
    const pixels = texturePixels(sf, sidecars, t);
    if (pixels.len == 0) return null;
    const rgba = unityz.texture.decode(arena, t.format, t.width, t.height, pixels) catch return null;
    return .{ .rgba = rgba, .w = t.width, .h = t.height };
}

/// Reads the m_VertexData (channel-packed) style sprite mesh: positions from
/// channel 0, UV0 from the version-dependent channel, using the same layout
/// rules as a Mesh object.
const ChannelMesh = struct { positions: []const [3]f32, uvs: []const [2]f32 };

fn readChannelMesh(
    arena: std.mem.Allocator,
    vd: unityz.value.Value,
    sf: *const unityz.serialized.SerializedFile,
) ?ChannelMesh {
    var m = unityz.classes.Mesh{};
    m.vertex_count = @intCast(unityz.classes.intField(vd, "m_VertexCount") orelse 0);
    m.vertex_data = unityz.classes.bytesField(vd, "m_DataSize") orelse "";
    if (unityz.classes.fieldOf(vd, "m_Channels")) |chans| {
        if (chans == .array) {
            const n = @min(chans.array.len, m.channels.len);
            for (chans.array[0..n], 0..) |c, i| {
                m.channels[i] = .{
                    .stream = @intCast(unityz.classes.intField(c, "stream") orelse 0),
                    .offset = @intCast(unityz.classes.intField(c, "offset") orelse 0),
                    .format = @intCast(unityz.classes.intField(c, "format") orelse 0),
                    .dimension = @intCast(unityz.classes.intField(c, "dimension") orelse 0),
                };
            }
            m.channel_count = n;
        }
    }
    const pos = m.channel(0) orelse return null;
    if (pos.format != 0 or pos.dimension < 3) return null;
    const stride = m.stride() orelse return null;
    const vcount: usize = m.vertex_count;
    if (m.vertex_data.len < stride *| vcount) return null;
    const ps = arena.alloc([3]f32, vcount) catch return null;
    for (0..vcount) |i| {
        const base = i * stride;
        ps[i] = .{
            readF32(m.vertex_data, base + pos.offset, sf.endian),
            readF32(m.vertex_data, base + pos.offset + 4, sf.endian),
            readF32(m.vertex_data, base + pos.offset + 8, sf.endian),
        };
    }
    const uv_major = unityMajor(sf.unity_version);
    const uv = m.channel(if (uv_major >= 2018) 4 else 3);
    var uvs: []const [2]f32 = &.{};
    if (uv) |t| {
        if (t.format == 0 and t.dimension >= 2) {
            const us = arena.alloc([2]f32, vcount) catch return null;
            for (0..vcount) |i| {
                const base = i * stride;
                us[i] = .{
                    readF32(m.vertex_data, base + t.offset, sf.endian),
                    readF32(m.vertex_data, base + t.offset + 4, sf.endian),
                };
            }
            uvs = us;
        }
    }
    return .{ .positions = ps, .uvs = uvs };
}

/// Reads a Sprite's tight/polygon mesh out of its own m_RD (positions, UVs,
/// triangle indices), mirroring UnityPy's MeshHandler over SpriteRenderData.
/// Returns null when the render data has no parseable mesh.
fn spriteMeshFromValue(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    v: unityz.value.Value,
) ?unityz.classes.SpriteMesh {
    const rd = unityz.classes.fieldOf(v, "m_RD") orelse return null;
    var positions: []const [3]f32 = &.{};
    var uvs: []const [2]f32 = &.{};
    if (unityz.classes.fieldOf(rd, "m_VertexData")) |vd| {
        const cm = readChannelMesh(arena, vd, sf) orelse return null;
        positions = cm.positions;
        uvs = cm.uvs;
    } else if (unityz.classes.fieldOf(rd, "vertices")) |verts| {
        if (verts == .array and verts.array.len > 0) {
            const n = verts.array.len;
            const ps = arena.alloc([3]f32, n) catch return null;
            const us = arena.alloc([2]f32, n) catch return null;
            @memset(us, .{ 0, 0 });
            for (verts.array, 0..) |ev, i| {
                if (unityz.classes.vec3Field(ev, "pos")) |p| ps[i] = p;
                if (unityz.classes.fieldOf(ev, "uv")) |uvf| {
                    if (unityz.classes.floatField(uvf, "x")) |x| us[i][0] = @floatCast(x);
                    if (unityz.classes.floatField(uvf, "y")) |y| us[i][1] = @floatCast(y);
                }
            }
            positions = ps;
            uvs = us;
        }
    }
    const triangles = readSpriteTriangles(arena, rd) orelse return null;
    if (positions.len == 0 or triangles.len == 0) return null;
    return .{ .positions = positions, .uvs = uvs, .triangles = triangles };
}

/// The final (vertically flipped) RGBA sprite image and its dimensions.
const RenderResult = struct { data: []const u8, w: u32, h: u32 };

/// Produces the final flipped RGBA sprite image, following UnityPy's
/// get_image_from_sprite: resolve the texture (and alpha texture), crop the
/// rect, apply the packed rotation, then either mask the tight polygon or
/// render the mesh; rows are always flipped last.
fn renderSprite(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    sidecars: []const Sidecar,
    v: unityz.value.Value,
    sprite_path_id: i64,
) ?RenderResult {
    const sprite = unityz.classes.Sprite.fromValue(v);
    // A {0,0} PPtr is the null reference: atlas-packed sprites leave
    // m_RD.texture empty and name the atlas texture instead.
    const hit = if (sprite.texture) |t| blk: {
        if (t.path_id != 0) break :blk AtlasHit{
            .texture = t, .rect = sprite.rect,
            .alpha_texture = sprite.alpha_texture,
            .settings_raw = sprite.settings_raw,
        };
        break :blk (atlasTextureFor(arena, sf, v, sprite_path_id) orelse return null);
    } else (atlasTextureFor(arena, sf, v, sprite_path_id) orelse return null);
    if (hit.texture.file_id != 0) return null; // external file not resolvable here

    const tex = decodeSpriteTexture(arena, sf, sidecars, hit.texture.path_id) orelse return null;
    var rgba: []const u8 = tex.rgba;
    // Merge a separate alpha texture if present (packed sprites).
    if (hit.alpha_texture) |at| {
        if (at.path_id != 0 and at.file_id == 0) {
            if (decodeSpriteTexture(arena, sf, sidecars, at.path_id)) |alpha_tex| {
                if (alpha_tex.w == tex.w and alpha_tex.h == tex.h) {
                    rgba = unityz.classes.mergeAlphaTexture(arena, rgba, alpha_tex.rgba, tex.w, tex.h) catch return null;
                }
            }
        }
    }

    // Crop the rect (top-origin), then apply the packed rotation, matching
    // UnityPy's order.
    var crop = unityz.classes.Sprite.cropRectNoFlip(arena, hit.rect, rgba, tex.w, tex.h) catch return null;
    if (sprite.isPacked()) {
        const rot = unityz.classes.rotateSprite(arena, crop.data, @intCast(crop.w), @intCast(crop.h), sprite.packingRotation()) catch return null;
        crop = .{ .data = rot.data, .w = rot.w, .h = rot.h };
    }

    var data: []const u8 = crop.data;
    var w: u32 = @intCast(crop.w);
    var h: u32 = @intCast(crop.h);

    if (sprite.isTight()) {
        // Fall back to the plain crop when the mesh is unparseable, so a
        // tight sprite at least emits something rather than being dropped.
        if (spriteMeshFromValue(arena, sf, v)) |mesh| {
            var has_nonzero_uv = false;
            if (mesh.uvs.len == mesh.positions.len and mesh.uvs.len > 0) {
                for (mesh.uvs) |u| {
                    if (u[0] != 0 or u[1] != 0) {
                        has_nonzero_uv = true;
                        break;
                    }
                }
            }
            if (has_nonzero_uv) {
                // texture-mapped mesh produces its own tightly-cropped image
                const rendered = unityz.classes.renderSpriteMesh(arena, mesh, sprite.pixels_to_units, rgba, tex.w, tex.h) catch return null;
                data = rendered.data;
                w = rendered.w;
                h = rendered.h;
            } else {
                // polygon mask applied to the (rotated) crop
                const masked = unityz.classes.maskSprite(arena, mesh, sprite.pixels_to_units, crop.data, @intCast(crop.w), @intCast(crop.h)) catch return null;
                data = masked;
                w = @intCast(crop.w);
                h = @intCast(crop.h);
            }
        }
    }

    const flipped = unityz.texture.flipVertical(arena, data, w, h) catch return null;
    return .{ .data = flipped, .w = w, .h = h };
}

/// Little-endian f32 at `data[pos..pos+4]` (the vertex data is packed in
/// the file's own endianness; the real files are little-endian).
fn readF32(data: []const u8, pos: usize, endian: std.builtin.Endian) f32 {
    const bits = std.mem.readInt(u32, data[pos..][0..4], endian);
    return @bitCast(bits);
}

/// Reads component `comp` of vertex channel `channel_index` for `vertex` as a
/// float32, honoring the mesh's per-stream layout. Null when the channel is
/// absent, non-float32, or the read would run past the vertex buffer.
fn meshF32(
    mesh: *const unityz.classes.Mesh,
    channel_index: usize,
    vertex: usize,
    comp: usize,
    endian: std.builtin.Endian,
) ?f32 {
    const c = mesh.channel(channel_index) orelse return null;
    if (c.format != 0 or comp >= c.dimension) return null;
    const off = mesh.channelByteOffset(channel_index, vertex) orelse return null;
    if (off + (comp + 1) * 4 > mesh.vertex_data.len) return null;
    return readF32(mesh.vertex_data, off + comp * 4, endian);
}

fn fieldStr(v: unityz.value.Value, name: []const u8) []const u8 {
    return unityz.classes.stringField(v, name) orelse "";
}

/// The target path id of a PPtr-typed value: the `.pptr` variant directly,
/// or an object carrying `m_FileID`/`m_PathID` fields. Null when neither.
fn pptrPathId(v: unityz.value.Value) ?i64 {
    return switch (v) {
        .pptr => |p| p.path_id,
        .obj => blk: {
            if (unityz.classes.fieldOf(v, "m_PathID")) |pv| {
                if (pv.asInt()) |id| break :blk id;
            }
            break :blk null;
        },
        else => null,
    };
}

/// Adapter so `value.jsonWrite` (which expects `writeAll`/`writeByte`/`print`)
/// can emit a value into an arena-backed `streams.Writer`.
const JsonWriterAdapter = struct {
    inner: unityz.streams.Writer,

    pub fn init(arena: std.mem.Allocator) JsonWriterAdapter {
        return .{ .inner = unityz.streams.Writer.init(arena) };
    }
    pub fn writeByte(self: *JsonWriterAdapter, b: u8) !void {
        try self.inner.writeByte(b);
    }
    pub fn writeAll(self: *JsonWriterAdapter, bytes: []const u8) !void {
        try self.inner.writeBytes(bytes);
    }
    pub fn print(self: *JsonWriterAdapter, comptime fmt: []const u8, args: anytype) !void {
        try self.inner.print(fmt, args);
    }
    fn get(self: *JsonWriterAdapter) []const u8 {
        return self.inner.getWritten();
    }
};

/// Serializes a value tree to compact JSON in the arena.
fn writeValueJson(arena: std.mem.Allocator, v: unityz.value.Value) ![]const u8 {
    var ad = JsonWriterAdapter.init(arena);
    try unityz.value.jsonWrite(v, &ad);
    return arena.dupe(u8, ad.get());
}

/// Major component of a Unity version string like "2022.3.62f2".
fn unityMajor(version: []const u8) u32 {
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return 0;
    return std.fmt.parseInt(u32, version[0..dot], 10) catch 0;
}

/// Wavefront OBJ export for a Mesh: vertices, normals, UVs, and triangle
/// faces from the index buffer. Handles multi-stream vertex layouts (each
/// channel read from its own stream's stride/offset). Returns an empty slice
/// when the layout is unsupported (compressed mesh, non-float32 channel).
fn writeMeshObj(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    v: unityz.value.Value,
    mesh: *const unityz.classes.Mesh,
) ![]const u8 {
    if (unityz.classes.intField(v, "m_MeshCompression") orelse 0 != 0) return &.{};
    const vch = mesh.channel(0) orelse return &.{};
    if (vch.format != 0 or vch.dimension < 3) return &.{};
    const vcount: usize = mesh.vertex_count;
    // Bounds are checked per read in meshF32; the index buffer is bounded below.
    const idx_bytes: usize = if (mesh.index_format == 1) 4 else 2;
    if (mesh.index_format != 0 and mesh.index_format != 1) return &.{};
    if (mesh.index_buffer.len < idx_bytes * 3) return &.{};

    const nrm = mesh.channel(1);
    // UV0 sits at channel 3 before Unity 2018, channel 4 from 2018 on
    // (UnityPy's kShaderChannel mapping); the layout is visible in the
    // real file: the vertex data's first 2-float channel past normals.
    const uv_major = unityMajor(sf.unity_version);
    const uv_index: usize = if (uv_major >= 2018) 4 else 3;
    const uv = mesh.channel(uv_index);

    // The arena owns the buffer; never deinit an arena-backed Writer and
    // then hand out its slice (Zig 0.16's ArenaAllocator.free reclaims the
    // most recent allocation, invalidating it). Dupe into the arena so the
    // result outlives the function.
    var w: unityz.streams.Writer = .init(arena);
    try w.print("o {s}\n", .{std.mem.trimEnd(u8, mesh.name, "\x00")});
    for (0..vcount) |i| {
        const x = meshF32(mesh, 0, i, 0, sf.endian) orelse return &.{};
        const y = meshF32(mesh, 0, i, 1, sf.endian) orelse return &.{};
        const z = meshF32(mesh, 0, i, 2, sf.endian) orelse return &.{};
        // Unity is left-handed; OBJ convention is right-handed, so mirror X
        // (UnityPy's exporter does the same, negating vertices and normals).
        try w.print("v {d} {d} {d}\n", .{ -x, y, z });
    }
    if (nrm) |n| {
        if (n.format == 0 and n.dimension >= 3 and meshF32(mesh, 1, 0, 0, sf.endian) != null) {
            for (0..vcount) |i| {
                try w.print("vn {d} {d} {d}\n", .{
                    -(meshF32(mesh, 1, i, 0, sf.endian) orelse 0),
                    meshF32(mesh, 1, i, 1, sf.endian) orelse 0,
                    meshF32(mesh, 1, i, 2, sf.endian) orelse 0,
                });
            }
        }
    }
    if (uv) |t| {
        if (t.format == 0 and t.dimension >= 2 and meshF32(mesh, uv_index, 0, 0, sf.endian) != null) {
            for (0..vcount) |i| {
                try w.print("vt {d} {d}\n", .{
                    meshF32(mesh, uv_index, i, 0, sf.endian) orelse 0,
                    meshF32(mesh, uv_index, i, 1, sf.endian) orelse 0,
                });
            }
        }
    }

    // faces, grouped by submesh (triangles and quads)
    const has_n = nrm != null and nrm.?.format == 0 and nrm.?.dimension >= 3;
    const has_t = uv != null and uv.?.format == 0 and uv.?.dimension >= 2;
    var index_cursor: usize = 0;
    if (unityz.classes.fieldOf(v, "m_SubMeshes")) |subs| {
        if (subs == .array) {
            for (subs.array) |sub| {
                const topology = unityz.classes.intField(sub, "topology") orelse 0;

                const index_count = unityz.classes.intField(sub, "indexCount") orelse 0;
                const start = index_cursor;
                // `indexCount` is file-supplied and need not match the index
                // buffer: clamp it to the slots that actually exist, or
                // `start + count` overflows usize (and the face loop spins
                // over billions of slots writeFace would skip anyway).
                const index_slots = mesh.index_buffer.len / idx_bytes;
                if (start >= index_slots) break;
                const want: usize = @intCast(@max(index_count, 0));
                const end = start + @min(want, index_slots - start);
                index_cursor = end;
                const per_face: usize = switch (topology) {
                    0 => 3, // triangles
                    2 => 4, // quads
                    else => continue,
                };
                const faces = (end - start) / per_face;
                for (0..faces) |f| {
                    const face_start = start + f * per_face;
                    try writeFace(&w, mesh.index_buffer, idx_bytes, face_start, per_face, has_n, has_t, sf.endian);
                }
            }
        }
    }
    // no submeshes: treat the whole buffer as triangles
    if (index_cursor == 0) {
        const faces = mesh.index_buffer.len / (idx_bytes * 3);
        for (0..faces) |f| {
            try writeFace(&w, mesh.index_buffer, idx_bytes, f * 3, 3, has_n, has_t, sf.endian);
        }
    }
    return arena.dupe(u8, w.getWritten());
}

/// Writes one face as an `f` line: `per_face` vertex references starting at
/// index slot. Quads become two triangles (0,1,2) and (0,2,3).
fn writeFace(
    w: *unityz.streams.Writer,
    index_buffer: []const u8,
    idx_bytes: usize,
    slot: usize,
    per_face: usize,
    has_n: bool,
    has_t: bool,
    endian: std.builtin.Endian,
) !void {
    if ((slot + per_face) * idx_bytes > index_buffer.len) return;
    var refs: [4]u64 = undefined;
    for (0..per_face) |k| {
        const idx: u64 = if (idx_bytes == 4)
            std.mem.readInt(u32, index_buffer[(slot + k) * 4 ..][0..4], endian)
        else
            std.mem.readInt(u16, index_buffer[(slot + k) * 2 ..][0..2], endian);
        refs[k] = idx + 1; // OBJ is 1-based
    }
    if (per_face == 4) {
        // quads become two triangles; winding reversed for the X mirror
        try writeFaceLine(w, &[_]u64{ refs[2], refs[1], refs[0] }, has_n, has_t);
        try writeFaceLine(w, &[_]u64{ refs[3], refs[2], refs[0] }, has_n, has_t);
        return;
    }
    // reverse the winding to keep front faces front after the X mirror
    var reversed: [3]u64 = undefined;
    for (0..per_face) |k| reversed[k] = refs[per_face - 1 - k];
    try writeFaceLine(w, reversed[0..per_face], has_n, has_t);
}

fn writeFaceLine(w: *unityz.streams.Writer, refs: []const u64, has_n: bool, has_t: bool) !void {
    try w.print("f", .{});
    for (refs) |i| {
        if (has_n and has_t) {
            try w.print(" {d}/{d}/{d}", .{ i, i, i });
        } else if (has_n) {
            try w.print(" {d}//{d}", .{ i, i });
        } else if (has_t) {
            try w.print(" {d}/{d}", .{ i, i });
        } else {
            try w.print(" {d}", .{i});
        }
    }
    try w.print("\n", .{});
}

/// Readable text summary of a Material (name, shader, saved properties).
fn writeMaterialText(arena: std.mem.Allocator, v: unityz.value.Value) ![]const u8 {
    // arena-owned buffer; see writeMeshObj for why it is never deinit'd
    var w: unityz.streams.Writer = .init(arena);
    try w.print("name: {s}\n", .{fieldStr(v, "m_Name")});
    if (unityz.classes.pptrField(v, "m_Shader")) |p| {
        try w.print("shader: file {d} path {d}\n", .{ p.file_id, p.path_id });
    }
    const props = unityz.classes.fieldOf(v, "m_SavedProperties") orelse return w.getWritten();
    for ([_][]const u8{ "m_TexEnvs", "m_Floats", "m_Colors", "m_Ints" }) |list_name| {
        const list = unityz.classes.fieldOf(props, list_name) orelse continue;
        if (list != .array) continue;
        for (list.array) |entry| {
            if (entry != .array or entry.array.len < 2) continue;
            const prop_name = switch (entry.array[0]) {
                .string => |s| s,
                else => "",
            };
            const val = entry.array[1];
            try w.print("{s} {s}: ", .{ list_name, prop_name });
            if (std.mem.eql(u8, list_name, "m_TexEnvs")) {
                if (unityz.classes.pptrField(val, "m_Texture")) |tex| {
                    try w.print("texture file {d} path {d}\n", .{ tex.file_id, tex.path_id });
                } else {
                    try w.print("\n", .{});
                }
            } else if (std.mem.eql(u8, list_name, "m_Floats")) {
                try w.print("{d}\n", .{val.asFloat() orelse 0});
            } else if (std.mem.eql(u8, list_name, "m_Ints")) {
                try w.print("{d}\n", .{val.asInt() orelse 0});
            } else {
                // colors: vec4
                try w.print("{d} {d} {d} {d}\n", .{
                    unityz.classes.floatField(val, "r") orelse 0,
                    unityz.classes.floatField(val, "g") orelse 0,
                    unityz.classes.floatField(val, "b") orelse 0,
                    unityz.classes.floatField(val, "a") orelse 1,
                });
            }
        }
    }
    return arena.dupe(u8, w.getWritten());
}

/// Readable text summary of a Shader (name, properties, pass names).
fn writeShaderText(arena: std.mem.Allocator, v: unityz.value.Value) ![]const u8 {
    // arena-owned buffer; see writeMeshObj for why it is never deinit'd
    var w: unityz.streams.Writer = .init(arena);
    try w.print("name: {s}\n", .{fieldStr(v, "m_Name")});
    if (unityz.classes.fieldOf(v, "m_ParsedForm")) |pf| {
        if (unityz.classes.fieldOf(pf, "m_PropInfo")) |pi| {
            if (unityz.classes.fieldOf(pi, "m_Props")) |props| {
                if (props == .array) {
                    for (props.array) |prop| {
                        try w.print("property: {s} (type {d})\n", .{ fieldStr(prop, "m_Name"), unityz.classes.intField(prop, "m_Type") orelse 0 });
                    }
                }
            }
        }
        if (unityz.classes.fieldOf(pf, "m_SubShaders")) |subs| {
            if (subs == .array) {
                for (subs.array) |sub| {
                    if (unityz.classes.fieldOf(sub, "m_Passes")) |passes| {
                        if (passes == .array) {
                            for (passes.array) |pass| {
                                const state = unityz.classes.fieldOf(pass, "m_State");
                                const pname = if (state) |s| fieldStr(s, "m_Name") else "";
                                try w.print("pass: {s} (type {d})\n", .{ pname, unityz.classes.intField(pass, "m_Type") orelse 0 });
                            }
                        }
                    }
                }
            }
        }
    }
    return arena.dupe(u8, w.getWritten());
}

/// `info <path> [--dump]` — sniff the container and print a summary;
/// `--dump` additionally prints every object of a serialized file as JSON.
fn cmdInfo(path: []const u8, bytes: []const u8, dump: bool, objects: bool, json: bool, stdout: *Io.Writer) !void {
    const sniff = unityz.container.sniff(bytes);
    switch (sniff.container) {
        .webfile => return printWebFile(path, bytes, dump, objects, json, stdout),
        .bundle => return printBundle(path, bytes, dump, objects, json, stdout),
        .serialized => return printSerialized(path, bytes, dump, objects, json, stdout),
        .archive => {
            try stdout.print("{s}: UnityArchive files are not supported yet\n", .{path});
        },
        .unknown => {
            try stdout.print("{s}: not a recognized Unity asset file\n", .{path});
        },
    }
}

/// Parses serialized bytes and prints every object as JSON, one per line.
/// Used for the recursive bundle/webfile dumps.
fn dumpSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  (node parse failed: {s})\n", .{@errorName(err)});
        return;
    };
    try dumpObjects(&sf, stdout);
}

fn printWebFile(path: []const u8, bytes: []const u8, dump: bool, objects: bool, json: bool, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wf = unityz.webfile.parse(arena, bytes) catch |err| {
        try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };
    if (json) {
        try stdout.print("{{\"type\":\"WebFile\",\"files\":{d},\"entries\":[", .{wf.entries.len});
        for (wf.entries, 0..) |e, i| {
            if (i != 0) try stdout.print(",", .{});
            try stdout.print("{{\"path\":\"{s}\",\"size\":{d}}}", .{ e.path, e.data.len });
        }
        try stdout.print("]", .{});
        if (objects) {
            try stdout.print(",\"object_list\":[", .{});
            var first = true;
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (!first) try stdout.writeByte(',');
                first = false;
                try dumpObjectTableJson(arena, e.data, e.path, stdout);
            }
            try stdout.print("]", .{});
        }
        try emitShadersJson(arena, wf.entries, stdout);
        try stdout.print("}}\n", .{});
        return;
    }
    try stdout.print("type:       WebFile (Unity web bundle)\n", .{});
    try stdout.print("files:      {d}\n", .{wf.entries.len});
    for (wf.entries) |e| {
        try stdout.print("  {s}  ({d} bytes)\n", .{ e.path, e.data.len });
    }
    if (objects) {
        for (wf.entries) |e| {
            if (unityz.container.sniff(e.data).container != .serialized) continue;
            try stdout.print("entry {s}:\n", .{e.path});
            try dumpObjectTable(arena, e.data, stdout);
        }
    }
    if (dump) {
        for (wf.entries) |e| {
            if (unityz.container.sniff(e.data).container != .serialized) continue;
            try stdout.print("entry {s}:\n", .{e.path});
            try dumpSerializedBytes(arena, e.data, stdout);
        }
    }
}

/// A Shader's display name: `m_ParsedForm.m_Name` (its authored name),
/// trimmed of the trailing NUL, falling back to the top-level `m_Name`.
fn shaderDisplayName(v: unityz.value.Value) []const u8 {
    if (unityz.classes.fieldOf(v, "m_ParsedForm")) |pf| {
        if (unityz.classes.stringField(pf, "m_Name")) |n| {
            return std.mem.trimEnd(u8, n, "\x00");
        }
    }
    return unityz.classes.stringField(v, "m_Name") orelse "";
}

/// Appends `{"name":...,"skins":...}` per Shader object of `sf` to the
/// current JSON field, threading the `first` flag cumulatively. `--json`
/// `info` uses this to report whether each shader skins. Entries are printed
/// one per object; undetermined shaders (no d3d11 blob or multi-tier) report
/// `skins:null`.
fn emitShaderSkinsJson(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, stdout: *Io.Writer, first: *bool) !void {
    for (sf.objects) |*o| {
        if (o.class_id != 48) continue;
        const ti = o.type_index orelse continue;
        if (ti >= sf.types.len) continue;
        const tree = sf.types[ti].type_tree;
        if (tree.roots.len == 0) continue;
        const data = sf.objectData(o) orelse continue;
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch continue;
        const name = shaderDisplayName(v);
        if (!first.*) try stdout.writeByte(',');
        first.* = false;

        const info = (try unityz.shader.skinInfo(arena, v)) orelse {
            try stdout.print("{{\"name\":", .{});
            try writeJsonString(stdout, name);
            try stdout.print(",\"skins\":null,\"determined\":false}}", .{});
            continue;
        };
        try stdout.print("{{\"name\":", .{});
        try writeJsonString(stdout, name);
        try stdout.print(",\"skins\":{s},\"determined\":true,\"blend_channels\":{s},\"blend_sources\":[", .{
            if (info.skins) "true" else "false",
            if (info.blend_channels) "true" else "false",
        });
        for (info.blend_sources, 0..) |s, i| {
            if (i != 0) try stdout.writeByte(',');
            try stdout.print("{d}", .{s});
        }
        try stdout.print("],\"bone_bindings\":[", .{});
        for (info.bone_bindings, 0..) |b, i| {
            if (i != 0) try stdout.writeByte(',');
            try writeJsonString(stdout, b);
        }
        try stdout.print("],\"vertex_programs\":{d},\"parameter_blobs\":{d}}}", .{ info.vertex_programs, info.parameter_blobs });
    }
}

/// Emits the `,"shaders":[...]` field for the serialized nodes of a
/// bundle/webfile (any slice whose elements expose a `data` byte range). The
/// caller manages the surrounding JSON.
fn emitShadersJson(arena: std.mem.Allocator, nodes: anytype, stdout: *Io.Writer) !void {
    try stdout.print(",\"shaders\":[", .{});
    var first = true;
    for (nodes) |n| {
        if (unityz.container.sniff(n.data).container != .serialized) continue;
        const ns = unityz.serialized.parse(arena, n.data) catch continue;
        try emitShaderSkinsJson(arena, &ns, stdout, &first);
    }
    try stdout.print("]", .{});
}

fn printBundle(path: []const u8, bytes: []const u8, dump: bool, objects: bool, json: bool, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = unityz.bundle.parse(arena, bytes) catch |err| {
        try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };
    if (json) {
        try stdout.print("{{\"type\":\"UnityFS\",\"version\":{d},\"unity\":\"{s}\",\"nodes\":{d},\"blocks\":{d},\"nodes_list\":[", .{ b.version, b.unity_version, b.nodes.len, b.blocks.len });
        for (b.nodes, 0..) |n, i| {
            if (i != 0) try stdout.print(",", .{});
            try stdout.print("{{\"path\":\"{s}\",\"size\":{d}}}", .{ n.path, n.data.len });
        }
        try stdout.print("]", .{});
        if (objects) {
            try stdout.print(",\"object_list\":[", .{});
            var first = true;
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (!first) try stdout.writeByte(',');
                first = false;
                try dumpObjectTableJson(arena, n.data, n.path, stdout);
            }
            try stdout.print("]", .{});
        }
        try emitShadersJson(arena, b.nodes, stdout);
        try stdout.print("}}\n", .{});
        return;
    }
    try stdout.print("type:       UnityFS bundle\n", .{});
    try stdout.print("version:    {d}\n", .{b.version});
    try stdout.print("unity:      {s} ({s})\n", .{ b.unity_version, b.unity_revision });
    try stdout.print("flags:      0x{x}\n", .{b.flags});
    try stdout.print("blocks:     {d}\n", .{b.blocks.len});
    try stdout.print("nodes:      {d}\n", .{b.nodes.len});
    for (b.nodes) |n| {
        try stdout.print("  {s}  ({d} bytes)\n", .{ n.path, n.data.len });
    }
    if (objects) {
        for (b.nodes) |n| {
            if (unityz.container.sniff(n.data).container != .serialized) continue;
            try stdout.print("node {s}:\n", .{n.path});
            try dumpObjectTable(arena, n.data, stdout);
        }
    }
    if (dump) {
        for (b.nodes) |n| {
            if (unityz.container.sniff(n.data).container != .serialized) continue;
            try stdout.print("node {s}:\n", .{n.path});
            try dumpSerializedBytes(arena, n.data, stdout);
        }
    }
}

fn printSerialized(path: []const u8, bytes: []const u8, dump: bool, objects: bool, json: bool, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("{s}: serialized file parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };
    if (json) {
        try stdout.print("{{\"type\":\"SerializedFile\",\"version\":{d},\"unity\":\"{s}\",\"platform\":{d},\"endian\":\"{s}\",\"type_tree\":{s},\"types\":{d},\"objects\":{d},\"externals\":{d}", .{
            sf.version,                                    sf.unity_version,                             sf.target_platform,
            if (sf.endian == .little) "little" else "big", if (sf.enable_type_tree) "true" else "false", sf.types.len,
            sf.objects.len,                                sf.externals.len,
        });
        if (objects) {
            try stdout.print(",\"object_list\":[", .{});
            try dumpObjectTableJson(arena, bytes, null, stdout);
            try stdout.print("]", .{});
        }
        try stdout.print(",\"externals_list\":[", .{});
        for (sf.externals, 0..) |e, i| {
            if (i != 0) try stdout.writeByte(',');
            try stdout.print("{{\"path\":", .{});
            try writeJsonString(stdout, e.path);
            try stdout.print(",\"guid\":\"", .{});
            for (e.guid) |b| try stdout.print("{x:0>2}", .{b});
            try stdout.print("\",\"type\":{d}}}", .{e.type_});
        }
        try stdout.print("]", .{});
        try stdout.print(",\"shaders\":[", .{});
        var first_shader = true;
        try emitShaderSkinsJson(arena, &sf, stdout, &first_shader);
        try stdout.print("]}}\n", .{});
        return;
    }
    try stdout.print("type:       SerializedFile\n", .{});
    try stdout.print("version:    {d}\n", .{sf.version});
    try stdout.print("unity:      {s}\n", .{sf.unity_version});
    try stdout.print("platform:   {d}\n", .{sf.target_platform});
    try stdout.print("endian:     {s}\n", .{if (sf.endian == .little) "little" else "big"});
    try stdout.print("type tree:  {s}\n", .{if (sf.enable_type_tree) "yes" else "no"});
    try stdout.print("types:      {d}\n", .{sf.types.len});
    try stdout.print("objects:    {d}\n", .{sf.objects.len});
    try stdout.print("externals:  {d}\n", .{sf.externals.len});
    for (sf.externals) |e| {
        // sidecar dependencies (e.g. .resS streams) this file references
        try stdout.print("  external:  {s}  guid ", .{e.path});
        for (e.guid) |b| try stdout.print("{x:0>2}", .{b});
        try stdout.print(" type {d}\n", .{e.type_});
    }
    if (sf.script_types.len != 0) try stdout.print("script types: {d}\n", .{sf.script_types.len});
    if (sf.ref_types.len != 0) try stdout.print("ref types:    {d}\n", .{sf.ref_types.len});

    // Per-class object counts, most numerous first.
    const ClassCount = struct { class_id: i32, count: u32 };
    var counts: std.ArrayList(ClassCount) = .empty;
    defer counts.deinit(arena);
    for (sf.objects) |*o| {
        var found = false;
        for (counts.items) |*c| {
            if (c.class_id == o.class_id) {
                c.count += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            try counts.append(arena, .{ .class_id = o.class_id, .count = 1 });
        }
    }
    std.mem.sort(ClassCount, counts.items, {}, struct {
        fn lessThan(_: void, a: ClassCount, b: ClassCount) bool {
            return a.count > b.count;
        }
    }.lessThan);

    try stdout.print("objects by class:\n", .{});
    for (counts.items) |c| {
        const name = className(c.class_id) orelse "Class";
        try stdout.print("  {d}  {s} (class {d})\n", .{ c.count, name, c.class_id });
    }

    if (objects) try dumpObjectTable(arena, bytes, stdout);
    if (dump) try dumpObjects(&sf, stdout);
}

/// Prints the object table (path id, class, byte start, size) of a
/// serialized file.
fn dumpObjectTable(arena: std.mem.Allocator, bytes: []const u8, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    try stdout.print("objects by id:\n", .{});
    for (sf.objects) |*o| {
        const name = className(o.class_id) orelse "Class";
        try stdout.print("  {d}  {s} (class {d})  start {d}  size {d}\n", .{ o.path_id, name, o.class_id, o.byte_start, o.byte_size });
    }
}

/// Emits the object table as JSON array entries (no brackets); `node`
/// tags each entry with its container path when inside a bundle/webfile.
fn dumpObjectTableJson(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch return;
    for (sf.objects, 0..) |*o, i| {
        if (i != 0) try stdout.writeByte(',');
        try stdout.writeByte('{');
        if (node) |n| {
            try stdout.print("\"node\":", .{});
            try writeJsonString(stdout, n);
            try stdout.writeByte(',');
        }
        try stdout.print("\"path_id\":{d},\"class\":{d},\"offset\":{d},\"size\":{d}", .{ o.path_id, o.class_id, o.byte_start, o.byte_size });
        try stdout.writeByte('}');
    }
}

/// Reads every object through its type tree and prints it as JSON, one
/// object per line. Objects without a usable type tree are skipped.
fn dumpObjects(sf: *const unityz.serialized.SerializedFile, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (sf.objects) |*o| {
        const type_index = o.type_index orelse continue;
        if (type_index >= sf.types.len) continue;
        const tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) continue;
        const data = sf.objectData(o) orelse continue;

        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch |err| {
            try stdout.print("{{\"path_id\":{d},\"error\":\"{s}\"}}\n", .{ o.path_id, @errorName(err) });
            continue;
        };
        try stdout.print("{{\"path_id\":{d},\"data\":", .{o.path_id});
        try unityz.value.jsonWrite(v, stdout);
        try stdout.print("}}\n", .{});
    }
}

/// One `verify --json` failure record.
const VerifyFailure = struct { path_id: i64, message: []const u8, node: ?[]const u8 = null };

/// Accumulated verification result; printed as JSON with `--json`.
const VerifyReport = struct {
    checked: usize = 0,
    failed: usize = 0,
    failures: std.ArrayList(VerifyFailure) = .empty,
};

/// Appends one failure to a verify report (message formatted from the
/// arena so it outlives the call); `node` names the container entry the
/// failure came from, when inside a bundle/webfile.
fn recordFailure(report: *VerifyReport, arena: std.mem.Allocator, node: ?[]const u8, path_id: i64, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(arena, fmt, args);
    try report.failures.append(std.heap.page_allocator, .{ .path_id = path_id, .message = msg, .node = node });
    report.failed += 1;
}

/// Prints a verify report as one JSON object when `--json` is set.
fn emitVerifyReport(json: bool, report: *const VerifyReport, stdout: *Io.Writer) !void {
    if (!json) return;
    try stdout.print("{{\"checked\":{d},\"failed\":{d},\"failures\":", .{ report.checked, report.failed });
    try stdout.writeByte('[');
    for (report.failures.items, 0..) |f, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try stdout.writeByte('{');
        if (f.node) |n| {
            try stdout.print("\"node\":", .{});
            try writeJsonString(stdout, n);
            try stdout.writeByte(',');
        }
        try stdout.print("\"path_id\":{d},\"error\":", .{f.path_id});
        try writeJsonString(stdout, f.message);
        try stdout.print("}}", .{});
    }
    try stdout.writeByte(']');
    try stdout.print("}}\n", .{});
}

/// `verify <path>` — a self-integrity check UnityPy does not offer: every
/// object with a type tree is read through it, written back, and the bytes
/// compared. Reports read errors, write errors, and byte mismatches; exits
/// non-zero when anything fails. Bundles and webfiles verify each embedded
/// serialized node.
fn cmdVerify(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var class_filter: ?i32 = null;
    var path_filter: ?Selector = null;
    var json = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--class") and i + 1 < rest.len) {
            class_filter = std.fmt.parseInt(i32, rest[i + 1], 10) catch {
                try stdout.print("unityz: invalid class id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--path-id") and i + 1 < rest.len) {
            path_filter = parseSelector(rest[i + 1]) catch {
                try stdout.print("unityz: invalid path id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--json")) {
            json = true;
        } else {
            try stdout.print("unityz: unknown verify option '{s}'\n", .{rest[i]});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var report: VerifyReport = .{};
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                if (json) {
                    try recordFailure(&report, arena, null, -1, "bundle parse failed: {s}", .{@errorName(err)});
                    try emitVerifyReport(json, &report, stdout);
                } else {
                    try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                }
                verify_failed_flag = true;
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, n.path, sn)) continue;
                    }
                }
                if (!json) try stdout.print("node {s}:\n", .{n.path});
                _ = try verifySerializedBytes(arena, n.data, n.path, class_filter, if (path_filter) |pf| pf.path_id else null, json, &report, stdout);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                if (json) {
                    try recordFailure(&report, arena, null, -1, "webfile parse failed: {s}", .{@errorName(err)});
                    try emitVerifyReport(json, &report, stdout);
                } else {
                    try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                }
                verify_failed_flag = true;
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, e.path, sn)) continue;
                    }
                }
                if (!json) try stdout.print("entry {s}:\n", .{e.path});
                _ = try verifySerializedBytes(arena, e.data, e.path, class_filter, if (path_filter) |pf| pf.path_id else null, json, &report, stdout);
            }
        },
        .serialized => {
            if (path_filter) |pf| {
                if (pf.node != null) {
                    try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                    return;
                }
            }
            _ = try verifySerializedBytes(arena, bytes, null, class_filter, if (path_filter) |pf| pf.path_id else null, json, &report, stdout);
        },
        .archive => {
            if (json) {
                try recordFailure(&report, arena, null, -1, "UnityArchive files are not supported yet", .{});
                try emitVerifyReport(json, &report, stdout);
            } else {
                try stdout.print("{s}: UnityArchive files are not supported yet\n", .{path});
            }
            verify_failed_flag = true;
            return;
        },
        .unknown => {
            if (json) {
                try recordFailure(&report, arena, null, -1, "not a recognized Unity asset file", .{});
                try emitVerifyReport(json, &report, stdout);
            } else {
                try stdout.print("{s}: not a recognized Unity asset file\n", .{path});
            }
            verify_failed_flag = true;
            return;
        },
    }
    // The exit code is part of the contract in both modes: `--json` is the
    // scripting mode, so it must fail the same way the text mode does.
    if (report.failed != 0) verify_failed_flag = true;
    if (json) {
        try emitVerifyReport(json, &report, stdout);
    } else if (report.failed != 0) {
        try stdout.print("{d} object(s) failed verification\n", .{report.failed});
    } else {
        try stdout.print("all objects verified\n", .{});
    }
}

/// Reads every object of a serialized file through its type tree, writes
/// it back, and compares bytes. Text mode prints per-object failures and
/// a per-node summary; JSON mode records failures in the report instead.
fn verifySerializedBytes(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, class_filter: ?i32, path_filter: ?i64, json: bool, report: *VerifyReport, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        if (json) {
            try recordFailure(report, arena, node, -1, "serialized parse failed: {s}", .{@errorName(err)});
        } else {
            try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
            report.failed += 1;
        }
        return;
    };
    var checked: usize = 0;
    var failed: usize = 0;
    for (sf.objects) |*o| {
        if (class_filter) |cf| {
            if (o.class_id != cf) continue;
        }
        if (path_filter) |pf| {
            if (o.path_id != pf) continue;
        }
        const type_index = o.type_index orelse continue;
        if (type_index >= sf.types.len) continue;
        const tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) continue;
        const data = sf.objectData(o) orelse continue;
        checked += 1;
        report.checked += 1;

        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch |err| {
            if (json) {
                try recordFailure(report, arena, node, o.path_id, "read failed: {s}", .{@errorName(err)});
            } else {
                try stdout.print("  object {d}: read failed: {s}\n", .{ o.path_id, @errorName(err) });
                report.failed += 1;
            }
            failed += 1;
            continue;
        };
        var w: unityz.streams.Writer = .init(arena);
        // preserve the bytes after the tree fields (MonoBehaviour payloads)
        unityz.object_writer.writeObject(&w, &tree.roots[0], v, data[r.position()..]) catch |err| {
            if (json) {
                try recordFailure(report, arena, node, o.path_id, "write failed: {s}", .{@errorName(err)});
            } else {
                try stdout.print("  object {d}: write failed: {s}\n", .{ o.path_id, @errorName(err) });
                report.failed += 1;
            }
            failed += 1;
            continue;
        };
        if (!std.mem.eql(u8, w.getWritten(), data)) {
            if (json) {
                try recordFailure(report, arena, node, o.path_id, "bytes differ (wrote {d}, orig {d})", .{ w.getWritten().len, data.len });
            } else {
                try stdout.print("  object {d}: bytes differ (wrote {d}, orig {d})\n", .{ o.path_id, w.getWritten().len, data.len });
                report.failed += 1;
            }
            failed += 1;
        } else if (o.class_id == 48) {
            // Extra Shader check: the sub-program blob must decode and
            // re-encode byte for byte (parameter records round-trip exactly).
            if (!(try unityz.shader.verifyBlob(arena, v))) {
                if (json) {
                    try recordFailure(report, arena, node, o.path_id, "shader sub-program blob does not round-trip", .{});
                } else {
                    try stdout.print("  object {d}: shader sub-program blob does not round-trip\n", .{o.path_id});
                    report.failed += 1;
                }
                failed += 1;
            }
        }
    }
    if (!json) try stdout.print("  {d} object(s) checked, {d} failed\n", .{ checked, failed });
}

/// One Shader's skinning summary, as reported by `skin <path>`.
const ShaderSummary = struct {
    node: ?[]const u8,
    path_id: i64,
    name: []const u8,
    skins: bool,
    blend_channels: bool,
    determined: bool,
    blend_sources: []const u32,
    bone_bindings: []const []const u8,
};

/// A `SkinnedMeshRenderer` referencing a shader that does not skin — the
/// reason `skin <path>` exits non-zero.
const SkinFailure = struct {
    node: ?[]const u8,
    path_id: i64,
    shader_name: []const u8,
    renderer_path_id: i64,
};

/// Interpret a value as a `PPtr`, accepting both the native `.pptr` form and
/// an object with extra fields that the reader produced as an `.obj`.
fn asPPtr(v: unityz.value.Value) ?unityz.value.PPtr {
    return switch (v) {
        .pptr => |p| p,
        .obj => |fields| blk: {
            var file: i32 = 0;
            var path: i64 = 0;
            var seen = false;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "m_FileID")) {
                    file = @intCast(f.value.asInt() orelse 0);
                    seen = true;
                } else if (std.mem.eql(u8, f.name, "m_PathID")) {
                    path = f.value.asInt() orelse 0;
                    seen = true;
                }
            }
            if (!seen) break :blk null;
            break :blk .{ .file_id = file, .path_id = path };
        },
        else => null,
    };
}

/// Reads a Shader object's value tree (borrowing from `sf`), returning null
/// when the object has no decodable type tree.
fn shaderObjectValue(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, o: *const unityz.serialized.ObjectInfo) ?unityz.value.Value {
    const ti = o.type_index orelse return null;
    if (ti >= sf.types.len) return null;
    const tree = sf.types[ti].type_tree;
    if (tree.roots.len == 0) return null;
    const od = sf.objectData(o) orelse return null;
    var r = unityz.streams.Reader.init(od);
    r.endian = sf.endian;
    return unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch null;
}

/// A minimal append-only writer exposing the interface `value.jsonWrite`
/// needs, backed by an arena ArrayList, so the merged base JSON can be
/// captured and extended with a derived field.
/// The shader stage a d3d11 `ShaderGpuProgramType` names.
fn shaderStageName(gpu_type: u32) []const u8 {
    return switch (gpu_type) {
        13 => "vertex",
        14 => "fragment",
        15 => "vertex",
        16 => "vertex",
        17 => "fragment",
        18 => "fragment",
        19 => "geometry",
        20 => "geometry",
        21 => "hull",
        22 => "domain",
        else => "other",
    };
}

/// Writes one decoded shader record as a JSON object.
fn writeShaderRecordJson(rec: unityz.shader.DecodedRecord, stdout: *Io.Writer) !void {
    try stdout.print("{{\"index\":{d},\"offset\":{d},\"length\":{d},\"segment\":{d},\"kind\":", .{ rec.index, rec.offset, rec.length, rec.segment });
    switch (rec.kind) {
        .code => try stdout.writeAll("\"code\""),
        .param => try stdout.writeAll("\"param\""),
        .unknown => try stdout.writeAll("\"unknown\""),
    }
    if (rec.kind == .code) {
        try stdout.print(",\"programType\":{d},\"stage\":", .{rec.program_type});
        try writeJsonString(stdout, shaderStageName(rec.program_type));
        try stdout.print(",\"dataBytes\":{d}", .{rec.size});
        if (rec.header.len >= 6) {
            try stdout.print(",\"header\":{{\"version\":{d},\"srv\":{d},\"cbuffer\":{d},\"sampler\":{d},\"uav\":{d},\"gsPrimitive\":{d}}}", .{ rec.header[0], rec.header[1], rec.header[2], rec.header[3], rec.header[4], rec.header[5] });
        }
        if (rec.dxbc) |dx| {
            try stdout.writeAll(",\"dxbc\":{\"chunks\":[");
            for (dx.chunks, 0..) |c, i| {
                if (i != 0) try stdout.writeAll(",");
                try writeJsonString(stdout, c);
            }
            try stdout.print("],\"srv\":{d},\"cbuffer\":{d},\"sampler\":{d},\"uav\":{d},\"temp\":{d},\"gsPrimitive\":{d},\"isgn\":[", .{ dx.srv, dx.cbuffer, dx.sampler, dx.uav, dx.temp_registers, dx.gs_primitive });
            for (dx.isgn, 0..) |s, i| {
                if (i != 0) try stdout.writeAll(",");
                try stdout.print("{{\"name\":", .{});
                try writeJsonString(stdout, s.name);
                try stdout.print(",\"index\":{d}}}", .{s.index});
            }
            try stdout.writeAll("],\"rdef\":[");
            for (dx.rdef, 0..) |b, i| {
                if (i != 0) try stdout.writeAll(",");
                try stdout.print("{{\"name\":", .{});
                try writeJsonString(stdout, b.name);
                try stdout.writeAll(",\"members\":[");
                for (b.members, 0..) |m, j| {
                    if (j != 0) try stdout.writeAll(",");
                    try stdout.print("{{\"name\":", .{});
                    try writeJsonString(stdout, m.name);
                    try stdout.print(",\"offset\":{d}}}", .{m.offset});
                }
                try stdout.writeAll("]}");
            }
            try stdout.writeAll("]}");
        }
        if (rec.bind_channels) |bc| {
            try stdout.print(",\"bindChannels\":{{\"sourceMap\":{d},\"channels\":[", .{bc.source_map});
            for (bc.channels, 0..) |ch, i| {
                if (i != 0) try stdout.writeAll(",");
                try stdout.print("[{d},{d}]", .{ ch[0], ch[1] });
            }
            try stdout.writeAll("]}");
        }
    } else if (rec.kind == .param) {
        if (rec.param) |pb| {
            try stdout.print(",\"param\":{{\"version\":{d},\"buffers\":[", .{pb.version});
            for (pb.buffers, 0..) |bp, i| {
                if (i != 0) try stdout.writeAll(",");
                try stdout.print("{{\"name\":", .{});
                try writeJsonString(stdout, bp.name);
                try stdout.print(",\"usedSize\":{d},\"members\":[", .{bp.used_size});
                for (bp.params, 0..) |p, j| {
                    if (j != 0) try stdout.writeAll(",");
                    try stdout.print("{{\"name\":", .{});
                    try writeJsonString(stdout, p.name);
                    try stdout.print(",\"type\":{d},\"rows\":{d},\"columns\":{d},\"isMatrix\":{d},\"arraySize\":{d},\"index\":{d}}}", .{ p.type, p.rows, p.columns, p.is_matrix, p.array_size, p.index });
                }
                try stdout.writeAll("],\"structs\":[");
                for (bp.structs, 0..) |s, j| {
                    if (j != 0) try stdout.writeAll(",");
                    try stdout.print("{{\"name\":", .{});
                    try writeJsonString(stdout, s.name);
                    try stdout.print(",\"index\":{d},\"arraySize\":{d},\"size\":{d},\"members\":[", .{ s.index, s.array_size, s.size });
                    for (s.params, 0..) |m, k| {
                        if (k != 0) try stdout.writeAll(",");
                        try stdout.print("{{\"name\":", .{});
                        try writeJsonString(stdout, m.name);
                        try stdout.print(",\"type\":{d},\"rows\":{d},\"columns\":{d},\"isMatrix\":{d},\"arraySize\":{d},\"index\":{d}}}", .{ m.type, m.rows, m.columns, m.is_matrix, m.array_size, m.index });
                    }
                    try stdout.writeAll("]}");
                }
                try stdout.writeAll("]}");
            }
            try stdout.writeAll("],\"entries\":[");
            for (pb.entries, 0..) |e, i| {
                if (i != 0) try stdout.writeAll(",");
                try stdout.print("{{\"name\":", .{});
                try writeJsonString(stdout, e.name);
                try stdout.print(",\"kind\":{d}", .{e.kind});
                switch (e.kind) {
                    0 => try stdout.print(",\"index\":{d},\"samplerIndex\":{d},\"extra\":{d}", .{ e.index, e.sampler_index, e.extra }),
                    1, 2 => try stdout.print(",\"index\":{d},\"arraySize\":{d}", .{ e.index, e.array_size }),
                    3 => try stdout.print(",\"index\":{d},\"originalIndex\":{d}", .{ e.index, e.original_index }),
                    4 => try stdout.print(",\"bindPoint\":{d},\"sampler\":{d}", .{ e.bind_point, e.sampler }),
                    else => {},
                }
                try stdout.writeAll("}");
            }
            try stdout.writeAll("]}");
        }
    }
    try stdout.writeAll("}");
}

/// Writes the decoded sub-program blob of a Shader as a JSON object.
fn writeShaderBlobJson(sb: unityz.shader.ShaderBlob, stdout: *Io.Writer) !void {
    try stdout.print("{{\"name\":", .{});
    try writeJsonString(stdout, sb.name);
    try stdout.print(",\"platform\":{d},\"records\":[", .{sb.platform});
    for (sb.records, 0..) |rec, i| {
        if (i != 0) try stdout.writeAll(",");
        try writeShaderRecordJson(rec, stdout);
    }
    try stdout.writeAll("],\"codeIndices\":[");
    for (sb.code_indices, 0..) |c, i| {
        if (i != 0) try stdout.writeAll(",");
        try stdout.print("{d}", .{c});
    }
    try stdout.writeAll("],\"paramIndices\":[");
    for (sb.param_indices, 0..) |c, i| {
        if (i != 0) try stdout.writeAll(",");
        try stdout.print("{d}", .{c});
    }
    try stdout.writeAll("]}");
}

/// Collects skinning summaries for every Shader of `bytes`, and records a
/// failure for any `SkinnedMeshRenderer` whose material's shader does not
/// skin. `shaders`/`failures` are appended to across nodes.
fn skinSerializedBytes(
    arena: std.mem.Allocator,
    bytes: []const u8,
    node: ?[]const u8,
    shaders: *std.ArrayList(ShaderSummary),
    failures: *std.ArrayList(SkinFailure),
) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch return;

    // Per-shader skinning summary.
    for (sf.objects) |*o| {
        if (o.class_id != 48) continue;
        const v = shaderObjectValue(arena, &sf, o) orelse continue;
        const name = shaderDisplayName(v);
        const info = try unityz.shader.skinInfo(arena, v);
        if (info) |inf| {
            try shaders.append(arena, .{
                .node = node,
                .path_id = o.path_id,
                .name = name,
                .skins = inf.skins,
                .blend_channels = inf.blend_channels,
                .determined = inf.determined,
                .blend_sources = inf.blend_sources,
                .bone_bindings = inf.bone_bindings,
            });
        } else {
            // blob not decodable (no d3d11 platform, or multi-tier): unknown.
            try shaders.append(arena, .{
                .node = node,
                .path_id = o.path_id,
                .name = name,
                .skins = false,
                .blend_channels = false,
                .determined = false,
                .blend_sources = &[_]u32{},
                .bone_bindings = &[_][]const u8{},
            });
        }
    }

    // A SkinnedMeshRenderer only renders if its shader skins. Resolve
    // renderer -> materials -> shader (same-file references only) and flag a
    // shader that is deterministically non-skinning.
    for (sf.objects) |*o| {
        if (o.class_id != 137) continue;
        const rv = shaderObjectValue(arena, &sf, o) orelse continue;
        const mats = unityz.classes.fieldOf(rv, "m_Materials") orelse continue;
        const arr = switch (mats) {
            .array => |a| a,
            else => continue,
        };
        for (arr) |mat_ref| {
            const mp = asPPtr(mat_ref) orelse continue;
            if (mp.file_id != 0 or mp.path_id == 0) continue; // external or null
            const mv = readObjectValue(arena, &sf, mp.path_id) orelse continue;
            const sp = unityz.classes.pptrField(mv, "m_Shader") orelse continue;
            if (sp.file_id != 0 or sp.path_id == 0) continue;
            const sv = readObjectValue(arena, &sf, sp.path_id) orelse continue;
            const sname = shaderDisplayName(sv);
            const info = (try unityz.shader.skinInfo(arena, sv)) orelse continue; // unknown -> no verdict
            if (!info.skins) {
                try failures.append(arena, .{
                    .node = node,
                    .path_id = sp.path_id,
                    .shader_name = sname,
                    .renderer_path_id = o.path_id,
                });
            }
        }
    }
}

/// `skin <path> [--json]` — report whether each Shader (class 48) skins, and
/// exit non-zero when a `SkinnedMeshRenderer` references a shader that does
/// not skin. Recurse into bundle/webfile serialized nodes.
fn cmdSkin(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var json = false;
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            try stdout.print("unityz: unknown skin option '{s}'\n", .{arg});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var shaders: std.ArrayList(ShaderSummary) = .empty;
    defer shaders.deinit(arena);
    var failures: std.ArrayList(SkinFailure) = .empty;
    defer failures.deinit(arena);

    switch (unityz.container.sniff(bytes).container) {
        .serialized => try skinSerializedBytes(arena, bytes, null, &shaders, &failures),
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try skinSerializedBytes(arena, n.data, n.path, &shaders, &failures);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try skinSerializedBytes(arena, e.data, e.path, &shaders, &failures);
            }
        },
        .archive => {
            try stdout.print("{s}: UnityArchive files are not supported yet\n", .{path});
            return;
        },
        .unknown => {
            try stdout.print("{s}: not a recognized Unity asset file\n", .{path});
            return;
        },
    }

    if (json) {
        try stdout.print("{{\"shaders\":[", .{});
        for (shaders.items, 0..) |s, i| {
            if (i != 0) try stdout.writeByte(',');
            try stdout.print("{{\"path_id\":{d},\"name\":", .{s.path_id});
            try writeJsonString(stdout, s.name);
            try stdout.print(",\"skins\":{s},\"determined\":{s},\"blend_channels\":{s},\"blend_sources\":[", .{
                if (s.skins) "true" else "false",
                if (s.determined) "true" else "false",
                if (s.blend_channels) "true" else "false",
            });
            for (s.blend_sources, 0..) |src, si| {
                if (si != 0) try stdout.writeByte(',');
                try stdout.print("{d}", .{src});
            }
            try stdout.print("],\"bone_bindings\":[", .{});
            for (s.bone_bindings, 0..) |b, bi| {
                if (bi != 0) try stdout.writeByte(',');
                try writeJsonString(stdout, b);
            }
            try stdout.print("]}}", .{});
        }
        try stdout.print("],\"failures\":[", .{});
        for (failures.items, 0..) |f, i| {
            if (i != 0) try stdout.writeByte(',');
            try stdout.print("{{\"path_id\":{d},\"renderer_path_id\":{d},\"shader\":", .{ f.path_id, f.renderer_path_id });
            try writeJsonString(stdout, f.shader_name);
            try stdout.print("}}", .{});
        }
        try stdout.print("]}}\n", .{});
    } else {
        for (shaders.items) |s| {
            if (s.node) |n| try stdout.print("{s}:", .{n});
            try stdout.print(" object {d} {s}: skins {s}", .{
                s.path_id,
                s.name,
                if (!s.determined) "unknown" else if (s.skins) "true" else "false",
            });
            if (s.determined) {
                try stdout.print(" (blend channels:", .{});
                for (s.blend_sources, 0..) |src, i| {
                    if (i != 0) try stdout.writeByte(',');
                    try stdout.print("{d}", .{src});
                }
                try stdout.print("; bone bindings:", .{});
                for (s.bone_bindings, 0..) |b, i| {
                    if (i != 0) try stdout.writeByte(',');
                    try stdout.print(" {s}", .{b});
                }
                try stdout.print(")", .{});
            }
            try stdout.print("\n", .{});
        }
        if (failures.items.len != 0) {
            for (failures.items) |f| {
                if (f.node) |n| try stdout.print("{s}:", .{n});
                try stdout.print(" object {d} (renderer {d}): shader {s} does not skin\n", .{ f.path_id, f.renderer_path_id, f.shader_name });
            }
            try stdout.print("{d} skinned-mesh shader(s) do not skin\n", .{failures.items.len});
        } else {
            try stdout.print("all skinned-mesh shaders skin\n", .{});
        }
    }

    if (failures.items.len != 0) verify_failed_flag = true;
}

/// Reports a per-file failure on stderr, keeping it out of the stdout
/// stream that carries the command's (possibly JSON) result.
fn warnToStderr(path: []const u8, err: anyerror) void {
    var buf: [512]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io_global.io, &buf);
    w.interface.print("unityz: {s}: {s}\n", .{ path, @errorName(err) }) catch return;
    w.interface.flush() catch {};
}

/// Compares two directories file-by-file by content hash, reporting
/// unchanged/changed/new/deleted files and totals. UnityPy has no tree
/// comparison.
fn diffDirectories(io: std.Io, dir_a: []const u8, dir_b: []const u8, json: bool, pixels: bool, audio: bool, class_filter: ?i32, stdout: *Io.Writer) !void {
    const DirFile = struct { name: []const u8, hash: u64, size: u64 };
    var files_a: std.ArrayList(DirFile) = .empty;
    var files_b: std.ArrayList(DirFile) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, dir_a, .{ .iterate = true }) catch |err| {
        try stdout.print("unityz: {s}: {s}\n", .{ dir_a, @errorName(err) });
        return;
    };
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_a, entry.name });
        const data = std.Io.Dir.cwd().readFileAlloc(io, full, std.heap.page_allocator, .unlimited) catch |err| {
            // Dropping it silently would report the file as "only in" the
            // other directory, which reads as a real difference.
            warnToStderr(full, err);
            continue;
        };
        try files_a.append(std.heap.page_allocator, .{ .name = entry.name, .hash = std.hash.Wyhash.hash(0, data), .size = data.len });
    }

    var dir2 = std.Io.Dir.cwd().openDir(io, dir_b, .{ .iterate = true }) catch |err| {
        try stdout.print("unityz: {s}: {s}\n", .{ dir_b, @errorName(err) });
        return;
    };
    var it2 = dir2.iterate();
    while (try it2.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_b, entry.name });
        const data = std.Io.Dir.cwd().readFileAlloc(io, full, std.heap.page_allocator, .unlimited) catch |err| {
            warnToStderr(full, err);
            continue;
        };
        try files_b.append(std.heap.page_allocator, .{ .name = entry.name, .hash = std.hash.Wyhash.hash(0, data), .size = data.len });
    }

    var unchanged: usize = 0;
    var changed: usize = 0;
    var only_a: usize = 0;
    var only_b: usize = 0;
    var reported: usize = 0;
    var changed_names: std.ArrayList([]const u8) = .empty;
    var only_a_names: std.ArrayList([]const u8) = .empty;
    var only_b_names: std.ArrayList([]const u8) = .empty;
    for (files_a.items) |fa| {
        var matched = false;
        for (files_b.items) |fb| {
            if (!std.mem.eql(u8, fa.name, fb.name)) continue;
            matched = true;
            if (fa.hash != fb.hash or fa.size != fb.size) {
                changed += 1;
                try changed_names.append(std.heap.page_allocator, fa.name);
                if (!json and reported < 10) {
                    try stdout.print("  changed: {s}\n", .{fa.name});
                    reported += 1;
                }
            } else {
                unchanged += 1;
            }
            // The pixel/audio passes run on every matched pair, not only
            // changed files: streamed pixels/audio live outside the file's
            // serialized bytes, so the file hash cannot see .resS edits.
            if (pixels or audio) {
                const pa = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_a, fa.name });
                defer std.heap.page_allocator.free(pa);
                const pb = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_b, fb.name });
                defer std.heap.page_allocator.free(pb);
                const data_a = std.Io.Dir.cwd().readFileAlloc(io, pa, std.heap.page_allocator, .unlimited) catch continue;
                const data_b = std.Io.Dir.cwd().readFileAlloc(io, pb, std.heap.page_allocator, .unlimited) catch continue;
                defer std.heap.page_allocator.free(data_a);
                defer std.heap.page_allocator.free(data_b);
                const ka = unityz.container.sniff(data_a).container;
                const kb = unityz.container.sniff(data_b).container;
                if (ka == kb and (ka == .serialized or ka == .bundle or ka == .webfile)) {
                    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer arena_state.deinit();
                    if (pixels) {
                        try stdout.print("  pixels in {s}:\n", .{fa.name});
                        try pixelPass(arena_state.allocator(), data_a, data_b, class_filter, stdout);
                    }
                    if (audio) {
                        try stdout.print("  audio in {s}:\n", .{fa.name});
                        try audioPass(arena_state.allocator(), data_a, data_b, class_filter, stdout);
                    }
                }
            }
            break;
        }
        if (!matched) {
            only_a += 1;
            try only_a_names.append(std.heap.page_allocator, fa.name);
            if (!json and reported < 10) {
                try stdout.print("  only in {s}: {s}\n", .{ dir_a, fa.name });
                reported += 1;
            }
        }
    }
    for (files_b.items) |fb| {
        var matched = false;
        for (files_a.items) |fa| {
            if (std.mem.eql(u8, fa.name, fb.name)) {
                matched = true;
                break;
            }
        }
        if (!matched) {
            only_b += 1;
            try only_b_names.append(std.heap.page_allocator, fb.name);
            if (!json and reported < 10) {
                try stdout.print("  only in {s}: {s}\n", .{ dir_b, fb.name });
                reported += 1;
            }
        }
    }
    if (json) {
        try stdout.print("{{\"a\":", .{});
        try writeJsonString(stdout, dir_a);
        try stdout.print(",\"b\":", .{});
        try writeJsonString(stdout, dir_b);
        try stdout.print(",\"unchanged\":{d},\"changed\":{d},\"only_a\":{d},\"only_b\":{d},\"changed_objects\":", .{ unchanged, changed, only_a, only_b });
        try writeJsonStringList(stdout, changed_names.items);
        try stdout.print(",\"only_a_objects\":", .{});
        try writeJsonStringList(stdout, only_a_names.items);
        try stdout.print(",\"only_b_objects\":", .{});
        try writeJsonStringList(stdout, only_b_names.items);
        try stdout.print("}}\n", .{});
    } else {
        try stdout.print("{d} unchanged, {d} changed, {d} only in {s}, {d} only in {s}\n", .{ unchanged, changed, only_a, dir_a, only_b, dir_b });
    }
}

/// Prints `s` as a JSON string literal (quoted, escaped).
fn writeJsonString(stdout: *Io.Writer, s: []const u8) !void {
    try stdout.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try stdout.writeAll("\\\""),
            '\\' => try stdout.writeAll("\\\\"),
            '\n' => try stdout.writeAll("\\n"),
            '\r' => try stdout.writeAll("\\r"),
            '\t' => try stdout.writeAll("\\t"),
            else => {
                if (c < 0x20) try stdout.print("\\u{x:0>4}", .{c}) else try stdout.writeByte(c);
            },
        }
    }
    try stdout.writeByte('"');
}

/// Prints a JSON array of string literals.
fn writeJsonStringList(stdout: *Io.Writer, items: []const []const u8) !void {
    try stdout.writeByte('[');
    for (items, 0..) |it, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try writeJsonString(stdout, it);
    }
    try stdout.writeByte(']');
}

/// One object's content fingerprint for `diff`.
const Fp = struct { path_id: i64, class_id: i32, hash: u64, size: u32, node: ?[]const u8 = null };

/// `hash <path> [--path-id N]` — print each object's content fingerprint
/// (Wyhash of its raw bytes) with class and size, so builds can be
/// fingerprinted and tracked externally (`diff` is the pairwise
/// comparison; this is the raw material). Recurses into bundle/webfile
/// nodes.
fn cmdHash(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var path_filter: ?Selector = null;
    var class_filter: ?i32 = null;
    var json = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--path-id") and i + 1 < rest.len) {
            path_filter = parseSelector(rest[i + 1]) catch {
                try stdout.print("unityz: invalid path id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--class") and i + 1 < rest.len) {
            class_filter = std.fmt.parseInt(i32, rest[i + 1], 10) catch {
                try stdout.print("unityz: invalid class id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--json")) {
            json = true;
        } else {
            try stdout.print("unityz: unknown hash option '{s}'\n", .{rest[i]});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayList(Fp) = .empty;

    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, n.path, sn)) continue;
                    }
                }
                try hashSerializedBytes(arena, n.data, n.path, if (path_filter) |pf| pf.path_id else null, class_filter, json, &entries, stdout);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, e.path, sn)) continue;
                    }
                }
                try hashSerializedBytes(arena, e.data, e.path, if (path_filter) |pf| pf.path_id else null, class_filter, json, &entries, stdout);
            }
        },
        .serialized => {
            if (path_filter) |pf| {
                if (pf.node != null) {
                    try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                    return;
                }
            }
            try hashSerializedBytes(arena, bytes, null, if (path_filter) |pf| pf.path_id else null, class_filter, json, &entries, stdout);
        },
        else => {
            try stdout.print("{s}: hash requires a serialized file, bundle, or webfile\n", .{path});
        },
    }
    if (json) {
        // one array across all nodes/entries (per-node arrays were not
        // parseable as a single JSON document)
        try stdout.print("[", .{});
        for (entries.items, 0..) |fp, idx| {
            if (idx != 0) try stdout.writeByte(',');
            try stdout.writeByte('{');
            if (fp.node) |n| {
                try stdout.print("\"node\":", .{});
                try writeJsonString(stdout, n);
                try stdout.writeByte(',');
            }
            try stdout.print("\"path_id\":{d},\"hash\":\"{x:0>16}\",\"class\":{d},\"size\":{d}}}", .{ fp.path_id, fp.hash, fp.class_id, fp.size });
        }
        try stdout.print("]\n", .{});
    }
}

fn hashSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, path_filter: ?i64, class_filter: ?i32, json: bool, entries: *std.ArrayList(Fp), stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    for (sf.objects) |*o| {
        if (path_filter) |pf| {
            if (o.path_id != pf) continue;
        }
        if (class_filter) |cf| {
            if (o.class_id != cf) continue;
        }
        const data = sf.objectData(o) orelse continue;
        const h = std.hash.Wyhash.hash(0, data);
        if (json) {
            try entries.append(arena, .{
                .path_id = o.path_id,
                .class_id = o.class_id,
                .hash = h,
                .size = @intCast(data.len),
                .node = node,
            });
        } else {
            try stdout.print("{d}\t{x:0>16}\t{s} (class {d})\t{d} bytes\n", .{
                o.path_id, h, className(o.class_id) orelse "Class", o.class_id, data.len,
            });
        }
    }
}

/// `diff --pixels` core: runs the per-object pixel comparison for every
/// matched Texture2D and Sprite in two files (same node + path id). Shared
/// by file diffs and per-pair directory diffs. The pass covers matched
/// objects, not only changed ones: streamed pixels live outside the
/// serialized payload, so an edited .resS byte changes no object hash.
fn pixelPass(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, class_filter: ?i32, stdout: *Io.Writer) !void {
    var a_list: std.ArrayList(Fp) = .empty;
    var b_list: std.ArrayList(Fp) = .empty;
    try collectFingerprints(arena, a_bytes, class_filter, null, &a_list);
    try collectFingerprints(arena, b_bytes, class_filter, null, &b_list);
    for (a_list.items) |fa| {
        for (b_list.items) |fb| {
            if (fb.path_id != fa.path_id or !sameNode(fb.node, fa.node)) continue;
            switch (fa.class_id) {
                28 => try diffTexturePixels(arena, a_bytes, b_bytes, fa, stdout),
                213 => try diffSpritePixels(arena, a_bytes, b_bytes, fa, stdout),
                else => {},
            }
            break;
        }
    }
}

/// `diff --audio`: compares the resolved stream data of every matched
/// AudioClip in two files (embedded or streamed from a sibling
/// `.resource` sidecar). Stream bytes live outside the serialized
/// payload, so an edited stream byte changes no object hash - only this
/// pass sees it.
fn audioPass(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, class_filter: ?i32, stdout: *Io.Writer) !void {
    var a_list: std.ArrayList(Fp) = .empty;
    var b_list: std.ArrayList(Fp) = .empty;
    try collectFingerprints(arena, a_bytes, class_filter, null, &a_list);
    try collectFingerprints(arena, b_bytes, class_filter, null, &b_list);
    var compared: usize = 0;
    var differ: usize = 0;
    for (a_list.items) |fa| {
        if (fa.class_id != 83) continue;
        for (b_list.items) |fb| {
            if (fb.path_id != fa.path_id or !sameNode(fb.node, fa.node)) continue;
            compared += 1;
            const sa = try findObjectStream(arena, a_bytes, fa);
            const sb = try findObjectStream(arena, b_bytes, fa);
            if (sa == null or sb == null) {
                try stdout.print("    (audio: object {d} (AudioClip) could not be resolved in one or both files)\n", .{fa.path_id});
                differ += 1;
            } else if (sa.?.len != sb.?.len) {
                try stdout.print("    (audio: object {d} (AudioClip) size differs {d} vs {d})\n", .{ fa.path_id, sa.?.len, sb.?.len });
                differ += 1;
            } else if (!std.mem.eql(u8, sa.?, sb.?)) {
                var first: usize = sa.?.len;
                for (sa.?, 0..) |c, i| {
                    if (c != sb.?[i]) {
                        first = i;
                        break;
                    }
                }
                try stdout.print("    (audio: object {d} (AudioClip) {d} bytes, first difference at offset {d})\n", .{ fa.path_id, sa.?.len, first });
                differ += 1;
            }
            break;
        }
    }
    try stdout.print("    (audio: {d} clips compared, {d} differ)\n", .{ compared, differ });
}

/// Resolves an AudioClip object's stream data from a file (container-aware,
/// resolving `.resource` sidecar nodes inside the same container), or null
/// when absent or unresolvable.
fn findObjectStream(arena: std.mem.Allocator, bytes: []const u8, fa: Fp) !?[]const u8 {
    var out: ?[]const u8 = null;
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = try unityz.bundle.parse(arena, bytes);
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = n.path, .data = n.data });
                }
            }
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (fa.node) |sn| {
                    if (!std.mem.eql(u8, n.path, sn)) continue;
                }
                out = try findAudioStreamInSerialized(arena, n.data, fa.path_id, sidecars.items);
                if (out != null) return out;
            }
        },
        .webfile => {
            const wf = try unityz.webfile.parse(arena, bytes);
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = e.path, .data = e.data });
                }
            }
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (fa.node) |sn| {
                    if (!std.mem.eql(u8, e.path, sn)) continue;
                }
                out = try findAudioStreamInSerialized(arena, e.data, fa.path_id, sidecars.items);
                if (out != null) return out;
            }
        },
        .serialized => {
            if (fa.node != null) return null;
            out = try findAudioStreamInSerialized(arena, bytes, fa.path_id, &.{});
        },
        else => {},
    }
    return out;
}

fn findAudioStreamInSerialized(arena: std.mem.Allocator, bytes: []const u8, path_id: i64, sidecars: []const Sidecar) !?[]const u8 {
    const sf = unityz.serialized.parse(arena, bytes) catch return null;
    const o = for (sf.objects) |*oo| {
        if (oo.class_id == 83 and oo.path_id == path_id) break oo;
    } else return null;
    const data = sf.objectData(o) orelse return null;
    const ti = o.type_index orelse return null;
    if (ti >= sf.types.len) return null;
    const tree = sf.types[ti].type_tree;
    if (tree.roots.len == 0) return null;
    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch return null;
    const ac = unityz.classes.AudioClip.fromValue(v);
    if (ac.audio_data.len != 0) return ac.audio_data;
    if (ac.resource.size != 0 and ac.resource.path.len != 0) {
        const slice = resolveSidecar(sidecars, ac.resource.path, ac.resource.offset, ac.resource.size);
        if (slice.len != 0) return slice;
    }
    return null;
}

/// `diff --pixels`: decodes a Texture2D object in both files and reports
/// pixel-level differences (per-channel differing-byte counts and the
/// maximum per-channel delta). Node-aware: `fa.node` selects the container
/// entry. Pixels may be embedded in the object, streamed inside the same
/// serialized file, or streamed from a sibling `.resS` / `.resource`
/// sidecar node inside the same container, all resolved here.
fn diffTexturePixels(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, fa: Fp, stdout: *Io.Writer) !void {
    const rgba_a = try findObjectRgba(arena, a_bytes, fa, .texture);
    const rgba_b = try findObjectRgba(arena, b_bytes, fa, .texture);
    if (rgba_a == null or rgba_b == null) {
        try stdout.print("    (pixels: object {d} texture could not be decoded in one or both files)\n", .{fa.path_id});
        return;
    }
    const a = rgba_a.?;
    const b = rgba_b.?;
    if (a.w != b.w or a.h != b.h) {
        try stdout.print("    (pixels: object {d} size differs {d}x{d} vs {d}x{d})\n", .{ fa.path_id, a.w, a.h, b.w, b.h });
        return;
    }
    try diffRgbaPixels(fa, a.data, b.data, a.w, a.h, stdout);
}

/// `diff --pixels` for a Sprite: renders both sprites (crop rect, packed
/// rotation, alpha-texture merge, tight/polygon mesh) and compares the
/// RGBA. Object bytes are unchanged when only the streamed atlas pixels
/// change, so this is the only diff signal that sees those edits.
fn diffSpritePixels(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, fa: Fp, stdout: *Io.Writer) !void {
    const rgba_a = try findObjectRgba(arena, a_bytes, fa, .sprite);
    const rgba_b = try findObjectRgba(arena, b_bytes, fa, .sprite);
    if (rgba_a == null or rgba_b == null) {
        try stdout.print("    (pixels: object {d} sprite could not be rendered in one or both files)\n", .{fa.path_id});
        return;
    }
    const a = rgba_a.?;
    const b = rgba_b.?;
    if (a.w != b.w or a.h != b.h) {
        try stdout.print("    (pixels: object {d} size differs {d}x{d} vs {d}x{d})\n", .{ fa.path_id, a.w, a.h, b.w, b.h });
        return;
    }
    try diffRgbaPixels(fa, a.data, b.data, a.w, a.h, stdout);
}

/// Shared per-channel RGBA comparison; `width`/`height` describe both
/// buffers (they must have the same length).
fn diffRgbaPixels(fa: Fp, a: []const u8, b: []const u8, width: u32, height: u32, stdout: *Io.Writer) !void {
    var per_channel = [_]usize{ 0, 0, 0, 0 };
    var max_delta = [_]u32{ 0, 0, 0, 0 };
    var diff_pixels: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 4) {
        var any = false;
        for (0..4) |c| {
            const d: u32 = @abs(@as(i32, a[i + c]) - @as(i32, b[i + c]));
            if (d != 0) {
                per_channel[c] += 1;
                any = true;
            }
            max_delta[c] = @max(max_delta[c], d);
        }
        if (any) diff_pixels += 1;
    }
    const name = className(fa.class_id) orelse "Class";
    try stdout.print("    (pixels: object {d} ({s}) {d}x{d}, {d} pixels differ; max delta R{d} G{d} B{d} A{d})\n", .{ fa.path_id, name, width, height, diff_pixels, max_delta[0], max_delta[1], max_delta[2], max_delta[3] });
}

test "diffRgbaPixels counts per-channel diffs and max deltas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const a = [_]u8{ 10, 20, 30, 40, 255, 255, 255, 255 };
    const b = [_]u8{ 12, 20, 35, 44, 250, 245, 255, 255 };
    try diffRgbaPixels(.{ .path_id = 7, .class_id = 28, .hash = 0, .size = 0 }, &a, &b, 2, 1, &aw.writer);
    try std.testing.expectEqualStrings("    (pixels: object 7 (Texture2D) 2x1, 2 pixels differ; max delta R5 G10 B5 A4)\n", aw.toArrayList().items);
}

/// RGBA8 pixels plus dimensions, from a decoded Texture2D or a rendered
/// Sprite.
const Rgba = struct { data: []const u8, w: u32, h: u32 };

const RgbaKind = enum { texture, sprite };

/// Decodes a Texture2D (28) or renders a Sprite (213) object's pixels from
/// a file, container-aware: `.resS` / `.resource` sidecar nodes inside the
/// same bundle/webfile are resolved, and `fa.node` selects the container
/// entry. Returns null when the object is absent or cannot be decoded.
fn findObjectRgba(arena: std.mem.Allocator, bytes: []const u8, fa: Fp, kind: RgbaKind) !?Rgba {
    var out: ?Rgba = null;
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = try unityz.bundle.parse(arena, bytes);
            // collect sidecars first: the serialized node usually precedes
            // its .resS node in the container
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = n.path, .data = n.data });
                }
            }
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (fa.node) |sn| {
                    if (!std.mem.eql(u8, n.path, sn)) continue;
                }
                out = try findObjectRgbaInSerialized(arena, n.data, fa.path_id, sidecars.items, kind);
                if (out != null) return out;
            }
        },
        .webfile => {
            const wf = try unityz.webfile.parse(arena, bytes);
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = e.path, .data = e.data });
                }
            }
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (fa.node) |sn| {
                    if (!std.mem.eql(u8, e.path, sn)) continue;
                }
                out = try findObjectRgbaInSerialized(arena, e.data, fa.path_id, sidecars.items, kind);
                if (out != null) return out;
            }
        },
        .serialized => {
            if (fa.node != null) return null;
            out = try findObjectRgbaInSerialized(arena, bytes, fa.path_id, &.{}, kind);
        },
        else => {},
    }
    return out;
}

fn findObjectRgbaInSerialized(arena: std.mem.Allocator, bytes: []const u8, path_id: i64, sidecars: []const Sidecar, kind: RgbaKind) !?Rgba {
    const sf = unityz.serialized.parse(arena, bytes) catch return null;
    const want: i32 = switch (kind) {
        .texture => 28,
        .sprite => 213,
    };
    const o = for (sf.objects) |*oo| {
        if (oo.class_id == want and oo.path_id == path_id) break oo;
    } else return null;
    const data = sf.objectData(o) orelse return null;
    const ti = o.type_index orelse return null;
    if (ti >= sf.types.len) return null;
    const tree = sf.types[ti].type_tree;
    if (tree.roots.len == 0) return null;
    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch return null;
    switch (kind) {
        .texture => {
            const t = unityz.classes.Texture2D.fromValue(v);
            if (t.width == 0 or t.height == 0) return null;
            const pixels = texturePixels(&sf, sidecars, t);
            if (pixels.len == 0) return null;
            const rgba = unityz.texture.decode(arena, t.format, t.width, t.height, pixels) catch return null;
            return .{ .data = rgba, .w = t.width, .h = t.height };
        },
        .sprite => {
            const rr = renderSprite(arena, &sf, sidecars, v, path_id) orelse return null;
            return .{ .data = rr.data, .w = rr.w, .h = rr.h };
        },
    }
}


/// `diff <file1> <file2>` — compare two files' objects by content hash:
/// reports objects only in one file, objects whose bytes changed between
/// them (same path id, different hash), and the unchanged count. Useful
/// for spotting what changed between two builds; UnityPy has no such
/// comparison. Both files must be the same container kind.
fn cmdDiff(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    if (rest.len < 1) {
        try stdout.print("unityz: diff needs: <file2>\n", .{});
        return;
    }
    var json = false;
    var pixels = false;
    var audio = false;
    var class_filter: ?i32 = null;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, rest[i], "--pixels")) {
            pixels = true;
        } else if (std.mem.eql(u8, rest[i], "--audio")) {
            audio = true;
        } else if (std.mem.eql(u8, rest[i], "--class") and i + 1 < rest.len) {
            class_filter = std.fmt.parseInt(i32, rest[i + 1], 10) catch {
                try stdout.print("unityz: invalid class id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else {
            try stdout.print("unityz: unknown diff option '{s}'\n", .{rest[i]});
            return;
        }
    }
    const io = io_global.io;
    // directory arguments compare the two trees file-by-file
    const stat_a = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        try stdout.print("unityz: {s}: FileNotFound\n", .{path});
        return;
    };
    const stat_b = std.Io.Dir.cwd().statFile(io, rest[0], .{}) catch {
        try stdout.print("unityz: {s}: FileNotFound\n", .{rest[0]});
        return;
    };
    if (stat_a.kind == .directory or stat_b.kind == .directory) {
        return diffDirectories(io, path, rest[0], json, pixels, audio, class_filter, stdout);
    }
    const other_bytes = std.Io.Dir.cwd().readFileAlloc(io, rest[0], std.heap.page_allocator, .unlimited) catch |err| {
        try stdout.print("unityz: {s}: {s}\n", .{ rest[0], @errorName(err) });
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const kind_a = unityz.container.sniff(bytes).container;
    const kind_b = unityz.container.sniff(other_bytes).container;
    if (kind_a != kind_b or (kind_a != .serialized and kind_a != .bundle and kind_a != .webfile)) {
        try stdout.print("unityz: diff needs two serialized files, bundles, or webfiles of the same kind\n", .{});
        return;
    }

    var a_list: std.ArrayList(Fp) = .empty;
    var b_list: std.ArrayList(Fp) = .empty;
    try collectFingerprints(arena, bytes, class_filter, null, &a_list);
    try collectFingerprints(arena, other_bytes, class_filter, null, &b_list);

    var only_a: usize = 0;
    var only_b: usize = 0;
    var changed: usize = 0;
    var unchanged: usize = 0;
    var reported: usize = 0;
    var changed_objs: std.ArrayList(Fp) = .empty;
    var only_a_objs: std.ArrayList(Fp) = .empty;
    var only_b_objs: std.ArrayList(Fp) = .empty;
    for (a_list.items) |fa| {
        var matched = false;
        for (b_list.items) |fb| {
            if (fb.path_id != fa.path_id or !sameNode(fb.node, fa.node)) continue;
            matched = true;
            if (fb.hash != fa.hash or fb.size != fa.size) {
                changed += 1;
                try changed_objs.append(std.heap.page_allocator, fa);
                if (!json and reported < 10) {
                    const name = className(fa.class_id) orelse "Class";
                    if (fa.node) |n| {
                        try stdout.print("  changed: object {d} ({s}) in {s}\n", .{ fa.path_id, name, n });
                    } else {
                        try stdout.print("  changed: object {d} ({s})\n", .{ fa.path_id, name });
                    }
                    reported += 1;
                }
            } else {
                unchanged += 1;
            }
            break;
        }
        if (!matched) {
            only_a += 1;
            try only_a_objs.append(std.heap.page_allocator, fa);
            if (!json and reported < 10) {
                const name = className(fa.class_id) orelse "Class";
                if (fa.node) |n| {
                    try stdout.print("  only in {s}: object {d} ({s}) in {s}\n", .{ path, fa.path_id, name, n });
                } else {
                    try stdout.print("  only in {s}: object {d} ({s})\n", .{ path, fa.path_id, name });
                }
                reported += 1;
            }
        }
    }
    for (b_list.items) |fb| {
        var matched = false;
        for (a_list.items) |fa| {
            if (fa.path_id == fb.path_id and sameNode(fa.node, fb.node)) {
                matched = true;
                break;
            }
        }
        if (!matched) {
            only_b += 1;
            try only_b_objs.append(std.heap.page_allocator, fb);
            if (!json and reported < 10) {
                const name = className(fb.class_id) orelse "Class";
                if (fb.node) |n| {
                    try stdout.print("  only in {s}: object {d} ({s}) in {s}\n", .{ rest[0], fb.path_id, name, n });
                } else {
                    try stdout.print("  only in {s}: object {d} ({s})\n", .{ rest[0], fb.path_id, name });
                }
                reported += 1;
            }
        }
    }
    if (pixels) try pixelPass(arena, bytes, other_bytes, class_filter, stdout);
    if (audio) try audioPass(arena, bytes, other_bytes, class_filter, stdout);
    if (json) {
        try stdout.print("{{\"a\":", .{});
        try writeJsonString(stdout, path);
        try stdout.print(",\"b\":", .{});
        try writeJsonString(stdout, rest[0]);
        try stdout.print(",\"unchanged\":{d},\"changed\":{d},\"only_a\":{d},\"only_b\":{d},\"changed_objects\":", .{ unchanged, changed, only_a, only_b });
        try writeObjList(stdout, changed_objs.items);
        try stdout.print(",\"only_a_objects\":", .{});
        try writeObjList(stdout, only_a_objs.items);
        try stdout.print(",\"only_b_objects\":", .{});
        try writeObjList(stdout, only_b_objs.items);
        try stdout.print("}}\n", .{});
    } else {
        try stdout.print("{d} unchanged, {d} changed, {d} only in {s}, {d} only in {s}\n", .{ unchanged, changed, only_a, path, only_b, rest[0] });
    }
}

/// Prints a JSON array of `{"path_id":N,"class":N}` objects.
/// Two objects match only when they come from the same container node
/// (both unqualified, or the same node path).
fn sameNode(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |na| {
        if (b) |nb| return std.mem.eql(u8, na, nb);
        return false;
    }
    return b == null;
}

fn writeObjList(stdout: *Io.Writer, items: []const Fp) !void {
    try stdout.writeByte('[');
    for (items, 0..) |it, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try stdout.writeByte('{');
        if (it.node) |n| {
            try stdout.print("\"node\":", .{});
            try writeJsonString(stdout, n);
            try stdout.writeByte(',');
        }
        try stdout.print("\"path_id\":{d},\"class\":{d}}}", .{ it.path_id, it.class_id });
    }
    try stdout.writeByte(']');
}

/// Collects (node, path_id, class, content hash, size) for every object of
/// a serialized file (or the serialized nodes of a bundle/webfile).
/// `node` tags the container path the objects come from, so identical
/// path ids in different nodes are not conflated.
fn collectFingerprints(arena: std.mem.Allocator, bytes: []const u8, class_filter: ?i32, node: ?[]const u8, out: *std.ArrayList(Fp)) !void {
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = try unityz.bundle.parse(arena, bytes);
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try collectFingerprints(arena, n.data, class_filter, n.path, out);
            }
        },
        .webfile => {
            const wf = try unityz.webfile.parse(arena, bytes);
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try collectFingerprints(arena, e.data, class_filter, e.path, out);
            }
        },
        .serialized => {
            const sf = try unityz.serialized.parse(arena, bytes);
            for (sf.objects) |*o| {
                if (class_filter) |cf| {
                    if (o.class_id != cf) continue;
                }
                const data = sf.objectData(o) orelse continue;
                try out.append(arena, .{
                    .path_id = o.path_id,
                    .class_id = o.class_id,
                    .hash = std.hash.Wyhash.hash(0, data),
                    .size = @intCast(data.len),
                    .node = node,
                });
            }
        },
        else => {},
    }
}

/// A `node:path-id` object selector; `node` is null for a bare path id.
/// The node names a container entry (bundle node / webfile entry path),
/// so colliding path ids in different nodes can be targeted individually.
const Selector = struct { node: ?[]const u8, path_id: i64 };

fn parseSelector(text: []const u8) !Selector {
    if (std.mem.indexOfScalar(u8, text, ':')) |i| {
        const node = text[0..i];
        const id_text = text[i + 1 ..];
        const path_id = std.fmt.parseInt(i64, id_text, 10) catch return error.BadSelector;
        return .{ .node = node, .path_id = path_id };
    }
    return .{ .node = null, .path_id = try std.fmt.parseInt(i64, text, 10) };
}

/// `show <path> <path-id> [--raw]` — print one object's JSON (its value
/// tree), or a hex dump of its serialized bytes with `--raw` (works even
/// without a type tree). Complementing `find` and `edit`; recurses into
/// bundle/webfile nodes. `<path-id>` may be `node:path-id` to target a
/// specific container entry.
fn cmdShow(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer, shader_only: bool) !void {
    if (rest.len < 1) {
        try stdout.print("unityz: show needs: <path-id>\n", .{});
        return;
    }
    const sel = parseSelector(rest[0]) catch {
        try stdout.print("unityz: invalid path id '{s}'\n", .{rest[0]});
        return;
    };
    var raw = false;
    for (rest[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--raw")) {
            raw = true;
        } else {
            try stdout.print("unityz: unknown show option '{s}'\n", .{arg});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var found = false;
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (sel.node) |sn| {
                    if (!std.mem.eql(u8, n.path, sn)) continue;
                }
                if (try showSerializedBytes(arena, n.data, sel.path_id, raw, shader_only, stdout)) found = true;
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (sel.node) |sn| {
                    if (!std.mem.eql(u8, e.path, sn)) continue;
                }
                if (try showSerializedBytes(arena, e.data, sel.path_id, raw, shader_only, stdout)) found = true;
            }
        },
        .serialized => {
            if (sel.node != null) {
                try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                return;
            }
            found = try showSerializedBytes(arena, bytes, sel.path_id, raw, shader_only, stdout);
        },
        else => {
            try stdout.print("{s}: show requires a serialized file, bundle, or webfile\n", .{path});
        },
    }
    if (!found) try stdout.print("object {d} not found\n", .{sel.path_id});
}

/// Prints the object with the given path id as JSON, or as a hex dump
/// with `raw`; true when found. A Shader (class 48) object additionally
/// carries a decoded `shaderBlob` field describing its sub-program records;
/// with `shader_only`, non-Shader objects are reported as not found.
fn showSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, path_id: i64, raw: bool, shader_only: bool, stdout: *Io.Writer) !bool {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
        return false;
    };
    for (sf.objects) |*o| {
        if (o.path_id != path_id) continue;
        if (raw) {
            const data = sf.objectData(o) orelse return false;
            try stdout.print("object {d}: {d} bytes\n", .{ o.path_id, data.len });
            try dumpHex(data, stdout);
            return true;
        }
        if (shader_only and o.class_id != 48) return false;
        const type_index = o.type_index orelse return false;
        if (type_index >= sf.types.len) return false;
        const tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) return false;
        const data = sf.objectData(o) orelse return false;
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch |err| {
            try stdout.print("object {d}: read failed: {s}\n", .{ o.path_id, @errorName(err) });
            return true;
        };
        if (o.class_id == 48) {
            if (try unityz.shader.decodeShader(arena, v)) |sb| {
                // Merge the decoded sub-program blob into the Shader JSON.
                var buf: std.ArrayList(u8) = .empty;
                var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
                try unityz.value.jsonWrite(v, &aw.writer);
                const base = aw.toArrayList().items;
                if (base.len > 0 and base[base.len - 1] == '}') {
                    try stdout.writeAll(base[0 .. base.len - 1]);
                    try stdout.writeAll(",\"shaderBlob\":");
                    try writeShaderBlobJson(sb, stdout);
                    try stdout.writeAll("}\n");
                } else {
                    try stdout.writeAll(base);
                    try stdout.print("\n", .{});
                }
                return true;
            }
        }
        try unityz.value.jsonWrite(v, stdout);
        try stdout.print("\n", .{});
        return true;
    }
    return false;
}

/// Prints `data` as a 16-byte-per-line hex dump with an ASCII gutter.
fn dumpHex(data: []const u8, stdout: *Io.Writer) !void {
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        try stdout.print("{x:0>8}  ", .{off});
        const n = @min(@as(usize, 16), data.len - off);
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (i < n) {
                try stdout.print("{x:0>2} ", .{data[off + i]});
            } else {
                try stdout.writeAll("   ");
            }
            if (i == 7) try stdout.writeByte(' ');
        }
        try stdout.writeAll(" |");
        i = 0;
        while (i < n) : (i += 1) {
            const c = data[off + i];
            try stdout.writeByte(if (c >= 0x20 and c < 0x7f) c else '.');
        }
        try stdout.writeAll("|\n");
    }
}

/// `find <path> <substring> [--class N]` — locate objects whose name
/// contains `substring` (case-insensitive) or whose class matches. Reads
/// each object through its type tree, so only objects with an `m_Name`
/// field match by name. Recurses into bundle/webfile nodes. UnityPy's CLI
/// has no search.
fn cmdFind(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    if (rest.len < 1) {
        try stdout.print("unityz: find needs: <substring> [--class <id>] [--json] [--exact]\n", .{});
        return;
    }
    const needle = rest[0];
    var class_filter: ?i32 = null;
    var json = false;
    var exact = false;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--class") and i + 1 < rest.len) {
            class_filter = std.fmt.parseInt(i32, rest[i + 1], 10) catch {
                try stdout.print("unityz: invalid class id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, rest[i], "--exact")) {
            exact = true;
        } else {
            try stdout.print("unityz: unknown find option '{s}'\n", .{rest[i]});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var found: std.ArrayList(FindMatch) = .empty;

    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try findSerializedBytes(arena, n.data, n.path, needle, class_filter, exact, json, &found, stdout);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try findSerializedBytes(arena, e.data, e.path, needle, class_filter, exact, json, &found, stdout);
            }
        },
        .serialized => try findSerializedBytes(arena, bytes, null, needle, class_filter, exact, json, &found, stdout),
        else => {
            try stdout.print("{s}: find requires a serialized file, bundle, or webfile\n", .{path});
        },
    }
    if (json) {
        try stdout.print("[", .{});
        for (found.items, 0..) |m, idx| {
            if (idx != 0) try stdout.writeByte(',');
            try stdout.writeByte('{');
            if (m.node) |n| {
                try stdout.print("\"node\":", .{});
                try writeJsonString(stdout, n);
                try stdout.writeByte(',');
            }
            try stdout.print("\"path_id\":{d},\"class\":{d},\"name\":", .{ m.path_id, m.class_id });
            try writeJsonString(stdout, std.mem.trimEnd(u8, m.name, "\x00"));
            try stdout.print("}}", .{});
        }
        try stdout.print("]\n", .{});
    }
}

/// One `find --json` match.
const FindMatch = struct { path_id: i64, class_id: i32, name: []const u8, node: ?[]const u8 = null };

fn findSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, needle: []const u8, class_filter: ?i32, exact: bool, json: bool, found: *std.ArrayList(FindMatch), stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    var matches: usize = 0;
    for (sf.objects) |*o| {
        if (class_filter) |cf| {
            if (o.class_id != cf) continue;
        }
        const type_index = o.type_index orelse continue;
        if (type_index >= sf.types.len) continue;
        const tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) continue;
        const data = sf.objectData(o) orelse continue;
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch continue;
        const name = unityz.classes.stringField(v, "m_Name") orelse "";
        if (needle.len != 0) {
            if (exact) {
                // exact, case-sensitive whole-name match (names may carry
                // trailing NULs)
                if (!std.mem.eql(u8, std.mem.trimEnd(u8, name, "\x00"), needle)) continue;
            } else {
                if (std.ascii.indexOfIgnoreCase(name, needle) == null) continue;
            }
        }
        if (json) {
            try found.append(std.heap.page_allocator, .{ .path_id = o.path_id, .class_id = o.class_id, .name = name, .node = node });
        } else {
            const cname = className(o.class_id) orelse "Class";
            if (node) |nd| {
                try stdout.print("  object {d}  {s} (class {d})  \"{s}\"  in {s}\n", .{ o.path_id, cname, o.class_id, std.mem.trimEnd(u8, name, "\x00"), nd });
            } else {
                try stdout.print("  object {d}  {s} (class {d})  \"{s}\"\n", .{ o.path_id, cname, o.class_id, std.mem.trimEnd(u8, name, "\x00") });
            }
        }
        matches += 1;
    }
    if (!json) try stdout.print("  {d} match(es)\n", .{matches});
}

/// `stats <path> [--json] [--class <id>]` — per-class object counts and
/// byte totals plus duplicate-object detection (objects with identical
/// serialized bytes across path IDs, a common source of wasted space).
/// UnityPy offers no size analysis or dedup. Bundles and webfiles report
/// per node; `--class` narrows to one class.
fn cmdStats(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var class_filter: ?i32 = null;
    var json = false;
    var dups_only = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--class") and i + 1 < rest.len) {
            class_filter = std.fmt.parseInt(i32, rest[i + 1], 10) catch {
                try stdout.print("unityz: invalid class id '{s}'\n", .{rest[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, rest[i], "--dups")) {
            dups_only = true;
        } else {
            try stdout.print("unityz: unknown stats option '{s}'\n", .{rest[i]});
            return;
        }
    }
    if (json and dups_only) {
        try stdout.print("unityz: --dups applies to text output only\n", .{});
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (json) {
        try statsJson(arena, bytes, class_filter, stdout);
        return;
    }
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (!dups_only) try stdout.print("node {s}:\n", .{n.path});
                try statsSerializedBytes(arena, n.data, class_filter, dups_only, stdout);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (!dups_only) try stdout.print("entry {s}:\n", .{e.path});
                try statsSerializedBytes(arena, e.data, class_filter, dups_only, stdout);
            }
        },
        .serialized => try statsSerializedBytes(arena, bytes, class_filter, dups_only, stdout),
        else => {
            try stdout.print("{s}: stats requires a serialized file, bundle, or webfile\n", .{path});
        },
    }
}

/// Per-class totals for `stats`.
const ClassStat = struct { class_id: i32, count: u32, bytes: u64 };

/// JSON stats over a serialized file or the serialized nodes of a
/// bundle/webfile: `{"objects":N,"bytes":B,"classes":{...}}`.
fn statsJson(arena: std.mem.Allocator, bytes: []const u8, class_filter: ?i32, stdout: *Io.Writer) !void {
    var classes: std.ArrayList(ClassStat) = .empty;
    var entries: std.ArrayList(StatEntry) = .empty;
    var total_objects: usize = 0;
    var total_bytes: u64 = 0;
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("  bundle parse failed: {s}\n", .{@errorName(err)});
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try collectStats(arena, n.data, class_filter, &classes, &total_objects, &total_bytes, &entries);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("  webfile parse failed: {s}\n", .{@errorName(err)});
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try collectStats(arena, e.data, class_filter, &classes, &total_objects, &total_bytes, &entries);
            }
        },
        .serialized => try collectStats(arena, bytes, class_filter, &classes, &total_objects, &total_bytes, &entries),
        else => {},
    }

    // duplicate detection: sort by (class, hash, size) and group identical
    // runs; every extra copy beyond the first is one duplicate.
    std.mem.sort(StatEntry, entries.items, {}, struct {
        fn lt(_: void, a: StatEntry, b: StatEntry) bool {
            if (a.class_id != b.class_id) return a.class_id < b.class_id;
            if (a.hash != b.hash) return a.hash < b.hash;
            if (a.size != b.size) return a.size < b.size;
            return a.path_id < b.path_id;
        }
    }.lt);
    var dup_count: usize = 0;
    var dup_bytes: u64 = 0;
    var groups: std.ArrayList(DupGroup) = .empty;
    var i: usize = 0;
    while (i < entries.items.len) {
        var j = i + 1;
        while (j < entries.items.len and
            entries.items[j].class_id == entries.items[i].class_id and
            entries.items[j].hash == entries.items[i].hash and
            entries.items[j].size == entries.items[i].size) : (j += 1)
        {}
        if (j - i > 1) {
            const n = j - i;
            dup_count += n - 1;
            dup_bytes += @as(u64, entries.items[i].size) * @as(u64, n - 1);
            var ids: std.ArrayList(i64) = .empty;
            var k = i;
            while (k < j) : (k += 1) try ids.append(arena, entries.items[k].path_id);
            try groups.append(arena, .{
                .class_id = entries.items[i].class_id,
                .hash = entries.items[i].hash,
                .size = entries.items[i].size,
                .path_ids = try ids.toOwnedSlice(arena),
            });
        }
        i = j;
    }

    try stdout.print("{{\"objects\":{d},\"bytes\":{d},\"duplicates\":{d},\"duplicate_bytes\":{d},\"classes\":{{", .{ total_objects, total_bytes, dup_count, dup_bytes });
    for (classes.items, 0..) |c, ci| {
        if (ci != 0) try stdout.print(",", .{});
        try stdout.print("\"{d}\":{{\"count\":{d},\"bytes\":{d}}}", .{ c.class_id, c.count, c.bytes });
    }
    try stdout.print("}},\"duplicate_groups\":[", .{});
    for (groups.items, 0..) |g, gi| {
        if (gi != 0) try stdout.writeByte(',');
        try stdout.print("{{\"class\":{d},\"hash\":\"{x:0>16}\",\"size\":{d},\"path_ids\":[", .{ g.class_id, g.hash, g.size });
        for (g.path_ids, 0..) |pid, pi| {
            if (pi != 0) try stdout.writeByte(',');
            try stdout.print("{d}", .{pid});
        }
        try stdout.print("]}}", .{});
    }
    try stdout.print("]}}\n", .{});
}

/// One duplicate group in `stats --json`: objects sharing identical
/// serialized bytes, listed by path id.
const DupGroup = struct { class_id: i32, hash: u64, size: u32, path_ids: []const i64 };

/// Accumulates one serialized file's per-class totals and per-object
/// entries (the latter feed duplicate detection).
fn collectStats(arena: std.mem.Allocator, bytes: []const u8, class_filter: ?i32, classes: *std.ArrayList(ClassStat), total_objects: *usize, total_bytes: *u64, entries: *std.ArrayList(StatEntry)) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch return;
    try accumulateStats(arena, &sf, class_filter, classes, total_objects, total_bytes, entries);
}

/// Accumulates a parsed serialized file's per-class totals and per-object
/// entries into the running tallies.
fn accumulateStats(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, class_filter: ?i32, classes: *std.ArrayList(ClassStat), total_objects: *usize, total_bytes: *u64, entries: *std.ArrayList(StatEntry)) !void {
    for (sf.objects) |*o| {
        if (class_filter) |cf| {
            if (o.class_id != cf) continue;
        }
        const data = sf.objectData(o) orelse continue;
        total_objects.* += 1;
        total_bytes.* += data.len;
        var found = false;
        for (classes.items) |*c| {
            if (c.class_id == o.class_id) {
                c.count += 1;
                c.bytes += data.len;
                found = true;
                break;
            }
        }
        if (!found) try classes.append(arena, .{ .class_id = o.class_id, .count = 1, .bytes = data.len });
        try entries.append(arena, .{
            .path_id = o.path_id,
            .class_id = o.class_id,
            .hash = std.hash.Wyhash.hash(0, data),
            .size = @intCast(data.len),
        });
    }
}

const StatEntry = struct {
    path_id: i64,
    class_id: i32,
    hash: u64,
    size: u32,
};

fn statsSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, class_filter: ?i32, dups_only: bool, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
        return;
    };

    // per-class totals
    var classes: std.ArrayList(ClassStat) = .empty;
    var entries: std.ArrayList(StatEntry) = .empty;
    var total_objects: usize = 0;
    var total_bytes: u64 = 0;
    try accumulateStats(arena, &sf, class_filter, &classes, &total_objects, &total_bytes, &entries);

    if (!dups_only) {
        try stdout.print("objects by class (bytes):\n", .{});
        std.mem.sort(ClassStat, classes.items, {}, struct {
            fn lt(_: void, a: ClassStat, b: ClassStat) bool {
                return a.bytes > b.bytes;
            }
        }.lt);
        for (classes.items) |c| {
            const name = className(c.class_id) orelse "Class";
            try stdout.print("  {d}  {s} (class {d})  {d} bytes\n", .{ c.count, name, c.class_id, c.bytes });
        }
        try stdout.print("total: {d} objects, {d} bytes\n", .{ total_objects, total_bytes });
    }

    // duplicate detection: sort by (class, hash), scan adjacent pairs
    std.mem.sort(StatEntry, entries.items, {}, struct {
        fn lt(_: void, a: StatEntry, b: StatEntry) bool {
            if (a.class_id != b.class_id) return a.class_id < b.class_id;
            if (a.hash != b.hash) return a.hash < b.hash;
            return a.path_id < b.path_id;
        }
    }.lt);
    var dup_bytes: u64 = 0;
    var dup_count: usize = 0;
    var reported: usize = 0;
    var i: usize = 1;
    while (i < entries.items.len) : (i += 1) {
        const prev = entries.items[i - 1];
        const cur = entries.items[i];
        if (prev.class_id == cur.class_id and prev.hash == cur.hash and prev.size == cur.size) {
            dup_bytes += cur.size;
            dup_count += 1;
            if (reported < 10) {
                const name = className(cur.class_id) orelse "Class";
                try stdout.print("  duplicate: object {d} ({s}) == object {d}\n", .{ cur.path_id, name, prev.path_id });
                reported += 1;
            }
        }
    }
    if (dup_count != 0) {
        try stdout.print("{d} duplicate object(s), {d} bytes could be deduplicated\n", .{ dup_count, dup_bytes });
    } else {
        try stdout.print("no duplicate objects\n", .{});
    }
}

/// Edits one object inside a WebFile: finds the serialized entry that
/// contains the path id, edits it, and rebuilds the webfile with a
/// stored-deflate (uncompressed) payload.
fn cmdEditWebFile(path: []const u8, out_path: ?[]const u8, sel: Selector, pairs: []const []const u8, verify: bool, bytes: []const u8, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wf = unityz.webfile.parse(arena, bytes) catch |err| {
        try stdout.print("unityz: {s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };
    for (wf.entries) |e| {
        if (unityz.container.sniff(e.data).container != .serialized) continue;
        if (sel.node) |sn| {
            if (!std.mem.eql(u8, e.path, sn)) continue;
        }
        const edited = editSerializedObject(arena, e.data, sel.path_id, pairs) catch |err| {
            if (err == error.ObjectNotFound) continue;
            try stdout.print("unityz: {s}: edit failed: {s}\n", .{ e.path, @errorName(err) });
            return;
        };
        const rebuilt = unityz.webfile.rebuild(arena, &wf, &.{.{ .path = e.path, .data = edited }}) catch |err| {
            try stdout.print("unityz: webfile rebuild failed: {s}\n", .{@errorName(err)});
            return;
        };
        if (!try writeEditOutput(arena, path, out_path, rebuilt, verify, stdout)) return;
        try stdout.print("object {d} in entry {s}: {d} field(s) edited\n", .{ sel.path_id, e.path, pairs.len / 2 });
        return;
    }
    try stdout.print("unityz: object {d} not found in webfile\n", .{sel.path_id});
}

/// Edits one object inside a bundle: finds the serialized node that
/// contains the path id, edits it, and rebuilds the bundle with the node
/// replaced (uncompressed blocks).
fn cmdEditBundle(path: []const u8, out_path: ?[]const u8, sel: Selector, pairs: []const []const u8, verify: bool, bytes: []const u8, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = unityz.bundle.parse(arena, bytes) catch |err| {
        try stdout.print("unityz: {s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };
    for (b.nodes) |n| {
        if (unityz.container.sniff(n.data).container != .serialized) continue;
        if (sel.node) |sn| {
            if (!std.mem.eql(u8, n.path, sn)) continue;
        }
        const edited = editSerializedObject(arena, n.data, sel.path_id, pairs) catch |err| {
            if (err == error.ObjectNotFound) continue;
            try stdout.print("unityz: {s}: edit failed: {s}\n", .{ n.path, @errorName(err) });
            return;
        };
        const rebuilt = unityz.bundle.rebuild(arena, &b, &.{.{ .path = n.path, .data = edited }}) catch |err| {
            try stdout.print("unityz: bundle rebuild failed: {s}\n", .{@errorName(err)});
            return;
        };
        if (!try writeEditOutput(arena, path, out_path, rebuilt, verify, stdout)) return;
        try stdout.print("object {d} in node {s}: {d} field(s) edited\n", .{ sel.path_id, n.path, pairs.len / 2 });
        return;
    }
    try stdout.print("unityz: object {d} not found in bundle\n", .{sel.path_id});
}

/// Edits one object of a serialized file, returning the rewritten file
/// bytes. `error.ObjectNotFound` when the path id is absent.
fn editSerializedObject(arena: std.mem.Allocator, bytes: []const u8, path_id: i64, pairs: []const []const u8) ![]u8 {
    const sf = try unityz.serialized.parse(arena, bytes);
    const o = sf.findObject(path_id) orelse return error.ObjectNotFound;
    const type_index = o.type_index orelse return error.MissingTypeIndex;
    if (type_index >= sf.types.len) return error.MissingTypeIndex;
    const tree = sf.types[type_index].type_tree;
    if (tree.roots.len == 0) return error.MissingTypeIndex;
    const data = sf.objectData(o) orelse return error.OutOfMemory;
    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    const root = &tree.roots[0];
    var edited = try unityz.object_reader.readObject(arena, &r, root);

    var pair: usize = 0;
    while (pair + 1 < pairs.len) : (pair += 2) {
        const new_value = try parseJsonLiteral(pairs[pair + 1]);
        const segs = try parseFieldPath(pairs[pair]);
        edited = setFieldPath(edited, segs, 0, new_value) catch |err| {
            std.heap.page_allocator.free(segs);
            return err;
        };
        std.heap.page_allocator.free(segs);
    }

    var out: unityz.streams.Writer = .init(arena);
    out.endian = sf.endian;
    try unityz.object_writer.writeObject(&out, root, edited, data[r.position()..]);
    return unityz.serialized_writer.rewrite(arena, &sf, &.{.{ .path_id = path_id, .data = out.getWritten() }});
}

/// Applies a JSON patch file: `{"<path_id>": {"<field>": <value>, ...}, ...}`.
/// Every target object is read, edited, and serialized, then the file is
/// rewritten once with all replacements. Field paths may be dotted and
/// indexed like the single-object edit.
fn cmdEditPatch(path: []const u8, out_path: ?[]const u8, patch_text: []const u8, verify: bool, bytes: []const u8, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const patch = parseJsonLiteral(patch_text) catch |err| {
        try stdout.print("unityz: bad patch: {s}\n", .{@errorName(err)});
        return;
    };
    const entries = switch (patch) {
        .obj => |f| f,
        else => {
            try stdout.print("unityz: patch must be an object of path-id -> fields\n", .{});
            return;
        },
    };
    // dispatch on the container kind
    var rewritten: []const u8 = undefined;
    var edited_count: usize = 0;
    switch (unityz.container.sniff(bytes).container) {
        .serialized => {
            for (entries) |entry| {
                const sel = parseSelector(entry.name) catch {
                    try stdout.print("unityz: bad patch entry '{s}'\n", .{entry.name});
                    return;
                };
                if (sel.node != null) {
                    try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                    return;
                }
            }
            rewritten = try editSerializedPatches(arena, bytes, entries);
            edited_count = entries.len;
        },
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("unityz: {s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            // A selector that will not parse must stop the edit before
            // anything is written: the serialized branch already rejects
            // it up front, and silently skipping one here would rewrite
            // the file having applied only part of the patch.
            for (entries) |entry| {
                _ = parseSelector(entry.name) catch {
                    try stdout.print("unityz: bad patch entry '{s}'\n", .{entry.name});
                    return;
                };
            }
            var replacements: std.ArrayList(unityz.bundle.NodeReplacement) = .empty;
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                // collect the patch entries this node contains
                const node_sf = unityz.serialized.parse(arena, n.data) catch continue;
                var node_entries: std.ArrayList(unityz.value.Field) = .empty;
                for (entries) |entry| {
                    const sel = parseSelector(entry.name) catch continue;
                    if (sel.node) |sn| {
                        if (!std.mem.eql(u8, n.path, sn)) continue;
                    }
                    if (node_sf.findObject(sel.path_id) != null) try node_entries.append(arena, entry);
                }
                if (node_entries.items.len == 0) continue;
                const edited_node = try editSerializedPatches(arena, n.data, node_entries.items);
                try replacements.append(arena, .{ .path = n.path, .data = edited_node });
                edited_count += node_entries.items.len;
            }
            if (replacements.items.len == 0) {
                try stdout.print("unityz: no patch entries found in the bundle\n", .{});
                return;
            }
            rewritten = try unityz.bundle.rebuild(arena, &b, replacements.items);
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("unityz: {s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            // A selector that will not parse must stop the edit before
            // anything is written: the serialized branch already rejects
            // it up front, and silently skipping one here would rewrite
            // the file having applied only part of the patch.
            for (entries) |entry| {
                _ = parseSelector(entry.name) catch {
                    try stdout.print("unityz: bad patch entry '{s}'\n", .{entry.name});
                    return;
                };
            }
            var replacements: std.ArrayList(unityz.webfile.EntryReplacement) = .empty;
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                const entry_sf = unityz.serialized.parse(arena, e.data) catch continue;
                var entry_entries: std.ArrayList(unityz.value.Field) = .empty;
                for (entries) |entry| {
                    const sel = parseSelector(entry.name) catch continue;
                    if (sel.node) |sn| {
                        if (!std.mem.eql(u8, e.path, sn)) continue;
                    }
                    if (entry_sf.findObject(sel.path_id) != null) try entry_entries.append(arena, entry);
                }
                if (entry_entries.items.len == 0) continue;
                const edited_entry = try editSerializedPatches(arena, e.data, entry_entries.items);
                try replacements.append(arena, .{ .path = e.path, .data = edited_entry });
                edited_count += entry_entries.items.len;
            }
            if (replacements.items.len == 0) {
                try stdout.print("unityz: no patch entries found in the webfile\n", .{});
                return;
            }
            rewritten = try unityz.webfile.rebuild(arena, &wf, replacements.items);
        },
        else => {
            try stdout.print("unityz: {s}: edit requires a serialized file, bundle, or webfile\n", .{path});
            return;
        },
    }

    if (!try writeEditOutput(arena, path, out_path, rewritten, verify, stdout)) return;
    try stdout.print("{d} object(s) patched\n", .{edited_count});
}

/// Verifies (when asked) and writes edit output to `out_path` or, without
/// one, over the input. Returns whether the bytes reached disk; failures
/// are reported to `stdout` by this function.
fn writeEditOutput(arena: std.mem.Allocator, path: []const u8, out_path: ?[]const u8, bytes: []const u8, verify: bool, stdout: *Io.Writer) !bool {
    if (verify) {
        if (!try verifyEditResult(arena, bytes, stdout)) {
            verify_failed_flag = true;
            return false;
        }
    }
    const io = io_global.io;
    const write_path = out_path orelse path;
    // Write a sibling temp file and rename it into place. Without an
    // out-path `edit` rewrites its own input, and a direct write that
    // fails partway (full disk, I/O error) would leave the asset
    // truncated with the original bytes already gone.
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.unityz-tmp", .{write_path});
    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, tmp_path, .{}) catch |err| {
        try stdout.print("unityz: {s}: cannot create temp file '{s}': {s}\n", .{ write_path, tmp_path, @errorName(err) });
        return false;
    };
    file.writeStreamingAll(io, bytes) catch |err| {
        file.close(io);
        cwd.deleteFile(io, tmp_path) catch {};
        try stdout.print("unityz: {s}: write failed: {s}\n", .{ write_path, @errorName(err) });
        return false;
    };
    file.close(io);
    cwd.rename(tmp_path, cwd, write_path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        try stdout.print("unityz: {s}: rename failed: {s}\n", .{ write_path, @errorName(err) });
        return false;
    };
    return true;
}

/// Runs the byte-exact round-trip check over rewritten edit output
/// (serialized, bundle, or webfile), printing a summary and up to three
/// failing objects. Returns whether every object verified clean.
fn verifyEditResult(arena: std.mem.Allocator, bytes: []const u8, stdout: *Io.Writer) !bool {
    var report: VerifyReport = .{};
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("verify failed: bundle parse error: {s}\n", .{@errorName(err)});
                return false;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try verifySerializedBytes(arena, n.data, null, null, null, true, &report, stdout);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("verify failed: webfile parse error: {s}\n", .{@errorName(err)});
                return false;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try verifySerializedBytes(arena, e.data, null, null, null, true, &report, stdout);
            }
        },
        .serialized => try verifySerializedBytes(arena, bytes, null, null, null, true, &report, stdout),
        else => {
            try stdout.print("verify failed: result is not a recognized asset file\n", .{});
            return false;
        },
    }
    if (report.failed != 0) {
        var shown: usize = 0;
        for (report.failures.items) |f| {
            if (shown >= 3) break;
            try stdout.print("  object {d}: {s}\n", .{ f.path_id, f.message });
            shown += 1;
        }
        try stdout.print("verify failed: {d} object(s) fail round-trip; not written\n", .{report.failed});
        return false;
    }
    try stdout.print("verify: {d} object(s) round-trip clean\n", .{report.checked});
    return true;
}

/// Applies a list of patch entries (path-id -> fields) to one serialized
/// file and returns the rewritten bytes. All objects are read, edited, and
/// serialized, then the file is rewritten once.
fn editSerializedPatches(arena: std.mem.Allocator, bytes: []const u8, entries: []const unityz.value.Field) ![]u8 {
    const sf = try unityz.serialized.parse(arena, bytes);
    var replacements: std.ArrayList(unityz.serialized_writer.Replacement) = .empty;
    for (entries) |entry| {
        const sel = parseSelector(entry.name) catch return error.BadPath;
        const path_id = sel.path_id;
        const fields = switch (entry.value) {
            .obj => |f| f,
            else => return error.BadPath,
        };
        const o = sf.findObject(path_id) orelse return error.ObjectNotFound;
        const type_index = o.type_index orelse return error.MissingTypeIndex;
        if (type_index >= sf.types.len) return error.MissingTypeIndex;
        const root = &sf.types[type_index].type_tree.roots[0];
        if (root.children.len == 0 and root.byte_size < 0) return error.MissingTypeIndex;
        const data = sf.objectData(o) orelse return error.OutOfMemory;
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        var edited = try unityz.object_reader.readObject(arena, &r, root);
        for (fields) |f| {
            const segs = try parseFieldPath(f.name);
            edited = setFieldPath(edited, segs, 0, f.value) catch |err| {
                std.heap.page_allocator.free(segs);
                return err;
            };
            std.heap.page_allocator.free(segs);
        }
        var out: unityz.streams.Writer = .init(arena);
        try unityz.object_writer.writeObject(&out, root, edited, data[r.position()..]);
        try replacements.append(arena, .{ .path_id = path_id, .data = out.getWritten() });
    }
    return unityz.serialized_writer.rewrite(arena, &sf, replacements.items);
}

/// `edit <file> <path_id> <field> <json-value> [<field> <json-value> ...]`
/// — set one or more fields on an object and write the file back in place.
fn cmdEdit(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `--patch <file>` applies a JSON patch (path_id -> field -> value)
    // to several objects in one rewrite; `--out <file>` writes elsewhere
    var patch_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var verify = false;
    var pairs: std.ArrayList([]const u8) = .empty;
    // rest[0] is the path id in the single-object form; in the --patch form
    // it is an option, so options are scanned from index 0 or 1 accordingly
    const single_form = rest.len > 0 and !std.mem.startsWith(u8, rest[0], "--");
    var i: usize = if (single_form) 1 else 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--out") and i + 1 < rest.len) {
            out_path = rest[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--patch") and i + 1 < rest.len) {
            patch_path = rest[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, rest[i], "--verify")) {
            verify = true;
        } else {
            try pairs.append(arena, rest[i]);
        }
    }
    if (patch_path) |pp| {
        const io = io_global.io;
        const patch_text = std.Io.Dir.cwd().readFileAlloc(io, pp, arena, .unlimited) catch |err| {
            try stdout.print("unityz: {s}: {s}\n", .{ pp, @errorName(err) });
            return;
        };
        return cmdEditPatch(path, out_path, patch_text, verify, bytes, stdout);
    }
    if (pairs.items.len < 2 or pairs.items.len % 2 != 0) {
        try stdout.print("unityz: edit needs: <path_id> <field> <json-value> [<field> <json-value> ...]\n", .{});
        return;
    }
    const sel = parseSelector(rest[0]) catch {
        try stdout.print("unityz: invalid path id '{s}'\n", .{rest[0]});
        return;
    };

    switch (unityz.container.sniff(bytes).container) {
        .bundle => return cmdEditBundle(path, out_path, sel, pairs.items, verify, bytes, stdout),
        .webfile => return cmdEditWebFile(path, out_path, sel, pairs.items, verify, bytes, stdout),
        .serialized => {
            if (sel.node != null) {
                try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                return;
            }
        },
        else => {
            try stdout.print("unityz: {s}: edit requires a serialized file, bundle, or webfile\n", .{path});
            return;
        },
    }

    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("unityz: {s}: parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };
    const o = sf.findObject(sel.path_id) orelse {
        try stdout.print("unityz: object {d} not found\n", .{sel.path_id});
        return;
    };
    const type_index = o.type_index orelse {
        try stdout.print("unityz: object {d} has no type index\n", .{sel.path_id});
        return;
    };
    if (type_index >= sf.types.len or sf.types[type_index].type_tree.roots.len == 0) {
        try stdout.print("unityz: object {d} has no type tree\n", .{sel.path_id});
        return;
    }
    const data = sf.objectData(o) orelse {
        try stdout.print("unityz: object {d} has no data\n", .{sel.path_id});
        return;
    };

    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    const root = &sf.types[type_index].type_tree.roots[0];
    var edited = unityz.object_reader.readObject(arena, &r, root) catch |err| {
        try stdout.print("unityz: object read failed: {s}\n", .{@errorName(err)});
        return;
    };

    // apply each `field value` pair to the running value tree; paths may be
    // dotted and indexed, e.g. `m_Container[0][1].preloadSize`
    var pair: usize = 0;
    while (pair + 1 < pairs.items.len) : (pair += 2) {
        const field = pairs.items[pair];
        const value_text = pairs.items[pair + 1];
        const new_value = parseJsonLiteral(value_text) catch |err| {
            try stdout.print("unityz: bad value '{s}': {s}\n", .{ value_text, @errorName(err) });
            return;
        };
        const segs = parseFieldPath(field) catch {
            try stdout.print("unityz: bad field path '{s}'\n", .{field});
            return;
        };
        edited = setFieldPath(edited, segs, 0, new_value) catch {
            std.heap.page_allocator.free(segs);
            try stdout.print("unityz: object {d} has no field '{s}'\n", .{ sel.path_id, field });
            return;
        };
        std.heap.page_allocator.free(segs);
    }

    var out: unityz.streams.Writer = .init(arena);
    defer out.deinit();
    out.endian = sf.endian;
    // preserve the bytes that follow the tree fields (a MonoBehaviour's
    // raw serialized script graph), like UnityPy does
    unityz.object_writer.writeObject(&out, root, edited, data[r.position()..]) catch |err| {
        try stdout.print("unityz: serialize failed: {s}\n", .{@errorName(err)});
        return;
    };

    const rewritten = unityz.serialized_writer.rewrite(arena, &sf, &.{.{ .path_id = sel.path_id, .data = out.getWritten() }}) catch |err| {
        try stdout.print("unityz: rewrite failed: {s}\n", .{@errorName(err)});
        return;
    };
    if (!try writeEditOutput(arena, path, out_path, rewritten, verify, stdout)) return;
    try stdout.print("object {d}: {d} field(s) edited\n", .{ sel.path_id, pairs.items.len / 2 });
}

/// One segment of an edit path: either a named field (`m_LocalPosition`),
/// an array index (`[0]`), or both (`m_Container[0]`).
const PathSeg = struct {
    name: []const u8 = "",
    index: ?usize = null,
};

/// Splits a dotted edit path into segments; each segment may carry any
/// number of `[N]` index groups. `m_Container[0][1].preloadSize` becomes
/// [{m_Container}, {index 0}, {index 1}, {preloadSize}].
fn parseFieldPath(text: []const u8) ![]const PathSeg {
    const allocator = std.heap.page_allocator;
    var segs: std.ArrayList(PathSeg) = .empty;
    defer segs.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |raw| {
        if (raw.len == 0) return error.BadPath;
        var rest = raw;
        // leading index groups: "[0]" or "[0][1]"
        while (rest.len > 0 and rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.BadPath;
            if (close == 1) return error.BadPath;
            try segs.append(allocator, .{ .index = try std.fmt.parseInt(usize, rest[1..close], 10) });
            rest = rest[close + 1 ..];
        }
        if (rest.len == 0) continue;
        // a name, optionally followed by index groups
        if (std.mem.indexOfScalar(u8, rest, '[')) |open| {
            if (open == 0) return error.BadPath;
            try segs.append(allocator, .{ .name = rest[0..open] });
            rest = rest[open..];
            while (rest.len > 0 and rest[0] == '[') {
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.BadPath;
                if (close == 1) return error.BadPath;
                try segs.append(allocator, .{ .index = try std.fmt.parseInt(usize, rest[1..close], 10) });
                rest = rest[close + 1 ..];
            }
            if (rest.len != 0) return error.BadPath;
        } else {
            try segs.append(allocator, .{ .name = rest });
        }
    }
    if (segs.items.len == 0) return error.BadPath;
    return segs.toOwnedSlice(allocator);
}

/// Rebuilds an `.obj` value with one named field replaced (or appended when
/// `append` is set); field order is preserved.
fn replaceObjField(fields: []const unityz.value.Field, name: []const u8, new_value: unityz.value.Value, append: bool) !unityz.value.Value {
    const allocator = std.heap.page_allocator;
    var list: std.ArrayList(unityz.value.Field) = .empty;
    defer list.deinit(allocator);
    var replaced = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            try list.append(allocator, .{ .name = f.name, .value = new_value });
            replaced = true;
        } else {
            try list.append(allocator, f);
        }
    }
    if (!replaced and append) try list.append(allocator, .{ .name = name, .value = new_value });
    return .{ .obj = try list.toOwnedSlice(allocator) };
}

/// Rebuilds an `.array` value with one element replaced.
fn replaceArrayIndex(arr: []const unityz.value.Value, index: usize, new_value: unityz.value.Value) !unityz.value.Value {
    const allocator = std.heap.page_allocator;
    var list: std.ArrayList(unityz.value.Value) = .empty;
    defer list.deinit(allocator);
    for (arr, 0..) |item, i| {
        try list.append(allocator, if (i == index) new_value else item);
    }
    return .{ .array = try list.toOwnedSlice(allocator) };
}

/// Walks the edit path, rebuilding the tree copy-on-write, and replaces the
/// leaf. `error.BadPath` means a segment did not exist.
fn setFieldPath(v: unityz.value.Value, segs: []const PathSeg, i: usize, new_value: unityz.value.Value) !unityz.value.Value {
    const seg = segs[i];
    const is_last = i + 1 == segs.len;
    if (seg.name.len != 0) {
        // PPtrs are stored compactly but expose m_FileID / m_PathID for
        // path descent (the writer serializes those same two children).
        if (v == .pptr) {
            if (!is_last) return error.BadPath;
            const p = v.pptr;
            if (std.mem.eql(u8, seg.name, "m_FileID")) {
                const iv = new_value.asInt() orelse return error.BadPath;
                return .{ .pptr = .{ .file_id = @intCast(iv), .path_id = p.path_id } };
            }
            if (std.mem.eql(u8, seg.name, "m_PathID")) {
                const iv = new_value.asInt() orelse return error.BadPath;
                return .{ .pptr = .{ .file_id = p.file_id, .path_id = iv } };
            }
            return error.BadPath;
        }
        const fields = switch (v) {
            .obj => |f| f,
            else => return error.BadPath,
        };
        const child = blk: {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, seg.name)) break :blk f.value;
            }
            break :blk null;
        } orelse return error.BadPath;
        const new_child = if (is_last) new_value else try setFieldPath(child, segs, i + 1, new_value);
        return replaceObjField(fields, seg.name, new_child, is_last);
    }
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadPath,
    };
    const idx = seg.index orelse return error.BadPath;
    if (idx >= arr.len) return error.BadPath;
    const new_child = if (is_last) new_value else try setFieldPath(arr[idx], segs, i + 1, new_value);
    return replaceArrayIndex(arr, idx, new_child);
}

/// Nesting limit for `parseJsonLiteral`. The parser recurses once per
/// `[`/`{`, so without a bound a deeply nested literal overflows the stack
/// instead of reporting a bad patch. Mirrors `typetree.max_depth`.
const max_json_depth: u32 = 512;

/// Minimal JSON literal parser: ints, floats, bools, null, quoted strings,
/// and nested arrays/objects. Enough for `edit`.
fn parseJsonLiteral(text: []const u8) !unityz.value.Value {
    var pos: usize = 0;
    const v = try parseJsonValue(text, &pos, 0);
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

fn parseJsonValue(text: []const u8, pos: *usize, depth: u32) !unityz.value.Value {
    if (depth > max_json_depth) return error.TooDeep;
    skipWs(text, pos);
    if (pos.* >= text.len) return error.UnexpectedEnd;
    const c = text[pos.*];
    if (c == '"') {
        pos.* += 1;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.heap.page_allocator);
        while (pos.* < text.len and text[pos.*] != '"') {
            if (text[pos.*] == '\\') {
                pos.* += 1;
                if (pos.* >= text.len) return error.BadEscape;
                // Decode the escape rather than keeping the escaped byte:
                // `value.jsonString` writes \n/\r/\t and \uXXXX for the C0
                // controls (Unity strings carry trailing NULs), so an
                // `extract --json` export fed back through `edit --patch`
                // has to decode them to round-trip byte-exactly.
                switch (text[pos.*]) {
                    '"' => try out.append(std.heap.page_allocator, '"'),
                    '\\' => try out.append(std.heap.page_allocator, '\\'),
                    '/' => try out.append(std.heap.page_allocator, '/'),
                    'b' => try out.append(std.heap.page_allocator, 0x08),
                    'f' => try out.append(std.heap.page_allocator, 0x0c),
                    'n' => try out.append(std.heap.page_allocator, '\n'),
                    'r' => try out.append(std.heap.page_allocator, '\r'),
                    't' => try out.append(std.heap.page_allocator, '\t'),
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
                        try out.appendSlice(std.heap.page_allocator, buf[0..n]);
                    },
                    else => return error.BadEscape,
                }
            } else {
                try out.append(std.heap.page_allocator, text[pos.*]);
            }
            pos.* += 1;
        }
        if (pos.* >= text.len) return error.UnterminatedString;
        pos.* += 1;
        return .{ .string = try out.toOwnedSlice(std.heap.page_allocator) };
    }
    if (c == '[') {
        pos.* += 1;
        var list: std.ArrayList(unityz.value.Value) = .empty;
        defer list.deinit(std.heap.page_allocator);
        skipWs(text, pos);
        if (pos.* < text.len and text[pos.*] == ']') {
            pos.* += 1;
            return .{ .array = try list.toOwnedSlice(std.heap.page_allocator) };
        }
        while (true) {
            try list.append(std.heap.page_allocator, try parseJsonValue(text, pos, depth + 1));
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
        return .{ .array = try list.toOwnedSlice(std.heap.page_allocator) };
    }
    if (c == '{') {
        pos.* += 1;
        var list: std.ArrayList(unityz.value.Field) = .empty;
        defer list.deinit(std.heap.page_allocator);
        skipWs(text, pos);
        if (pos.* < text.len and text[pos.*] == '}') {
            pos.* += 1;
            return .{ .obj = try list.toOwnedSlice(std.heap.page_allocator) };
        }
        while (true) {
            skipWs(text, pos);
            if (pos.* >= text.len or text[pos.*] != '"') return error.BadObject;
            const key = try parseJsonValue(text, pos, depth + 1);
            skipWs(text, pos);
            if (pos.* >= text.len or text[pos.*] != ':') return error.BadObject;
            pos.* += 1;
            const val = try parseJsonValue(text, pos, depth + 1);
            try list.append(std.heap.page_allocator, .{ .name = key.string, .value = val });
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
        return .{ .obj = try list.toOwnedSlice(std.heap.page_allocator) };
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
    return .{ .int = try std.fmt.parseInt(i64, token, 10) };
}

fn skipWs(text: []const u8, pos: *usize) void {
    while (pos.* < text.len) : (pos.* += 1) {
        const c = text[pos.*];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
    }
}

test "parseCommand recognizes known subcommands" {
    try std.testing.expectEqual(Command.info, parseCommand("info"));
    try std.testing.expectEqual(Command.extract, parseCommand("extract"));
    try std.testing.expectEqual(Command.edit, parseCommand("edit"));
    try std.testing.expectEqual(Command.verify, parseCommand("verify"));
    try std.testing.expectEqual(Command.stats, parseCommand("stats"));
    try std.testing.expectEqual(Command.find, parseCommand("find"));
    try std.testing.expectEqual(Command.show, parseCommand("show"));
    try std.testing.expectEqual(Command.diff, parseCommand("diff"));
    try std.testing.expectEqual(Command.hash, parseCommand("hash"));
    try std.testing.expect(parseCommand("bogus") == null);
    try std.testing.expect(parseCommand("--version") == null);
}

test "parseFieldPath splits dotted and indexed paths" {
    const p1 = try parseFieldPath("m_Name");
    try std.testing.expectEqual(@as(usize, 1), p1.len);
    try std.testing.expectEqualStrings("m_Name", p1[0].name);
    try std.testing.expect(p1[0].index == null);

    const p2 = try parseFieldPath("m_Container[0][1].preloadSize");
    try std.testing.expectEqual(@as(usize, 4), p2.len);
    try std.testing.expectEqualStrings("m_Container", p2[0].name);
    try std.testing.expectEqual(@as(usize, 0), p2[1].index.?);
    try std.testing.expectEqual(@as(usize, 1), p2[2].index.?);
    try std.testing.expectEqualStrings("preloadSize", p2[3].name);

    const p3 = try parseFieldPath("[2].asset.m_PathID");
    try std.testing.expectEqual(@as(usize, 3), p3.len);
    try std.testing.expectEqual(@as(usize, 2), p3[0].index.?);

    try std.testing.expectError(error.BadPath, parseFieldPath("a..b"));
    try std.testing.expectError(error.BadPath, parseFieldPath("a["));
    try std.testing.expectError(error.BadPath, parseFieldPath("[]"));
}
