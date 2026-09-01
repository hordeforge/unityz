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
    \\                  missing; --trees <file.json> supplies the class
    \\                  trees Mono builds omit, making typeless files
    \\                  decodable; --summary dry-run per-class report
    \\                  without writing anything; MonoScripts consolidate
    \\                  into one scripts.json)
    \\  edit <path>     Apply edits to a Unity asset file
    \\                 (bundles: finds and edits the embedded node, then
    \\                  rebuilds the bundle)
    \\  verify <path>   Verify every object round-trips byte-exactly
    \\                 (--class N / --path-id N to check a subset,
    \\                  N may be node:path-id; --json for a machine-readable
    \\                  report; --trees <file.json> for typeless Mono files,
    \\                  as in extract)
    \\  stats <path>    Per-class sizes + duplicate-object detection
    \\                 (--json for a machine-readable summary;
    \\                  --class <id> to filter; --dups for only the
    \\                  duplicate report)
    \\  find <path> <s>  Find objects whose name contains <s>,
    \\                 case-insensitively
    \\                 (--class <id> to filter by class;
    \\                  --exact for a case-sensitive whole-name match;
    \\                  --any to match any string field, not just m_Name;
    \\                  --json for a machine-readable array)
    \\  fsb <path>     Decode a raw FSB5 audio bank (as carved from FMOD
    \\                 .bank files) to playable WAV/OGG per sample, plus a
    \\                 bank.json metadata sidecar (--outdir <dir> to write
    \\                 into; pure-Zig decode, no external tools)
    \\  show <path> <id> Print one object as JSON
    \\                 (--raw for a hex dump of its serialized bytes;
    \\                  <id> may be node:path-id to target a container entry;
    \\                  a Shader object also carries a decoded "shaderBlob";
    \\                  --trees <file.json> for typeless Mono files,
    \\                  as in extract)
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
    \\  hierarchy <path> Print the GameObject/Transform tree of a scene
    \\                 (root transforms first, names, component classes,
    \\                  local positions, bones of any SkinnedMeshRenderer
    \\                  marked (bone); --json for nested objects)
    \\  managed <dir>  Read a game's managed assemblies (the Data/Managed
    \\                 folder of a Mono build) and list every MonoBehaviour
    \\                 script class with its serialized field layout — the
    \\                 layout Unity's serializer uses for those objects,
    \\                 which no other extractor reads without loading a
    \\                 whole .NET runtime (--json for machine-readable;
    \\                 also accepts a single .dll path)
    \\
    \\Edit usage: unityz edit <file> <path_id> <field> <json-value> [<field> <json-value> ...]
    \\  <field> may be dotted and indexed, e.g. m_Container[0][1].preloadSize
    \\  <path_id> may be node:path-id to target a specific container entry
    \\  (add --out <file> to write elsewhere instead of in place;
    \\   --verify round-trip-checks the result and refuses to write on failure;
    \\   --trees <file.json> supplies the class trees typeless Mono files
    \\   omit, making them editable in both forms;
    \\   a base64 string value patches a byte-array field, e.g.
    \\   edit f.unity3d CAB-..:44 m_IndexBuffer '"AwD/AA=="' replaces raw
    \\   bytes; inside a replaced subtree the same rule applies, so an
    \\   extract --json export round-trips back through edit --patch)
    \\
    \\Patch example: {"2": {"m_Name": "renamed"}, "7": {"m_LocalPosition.y": 1.25}}
    \\  (edit --patch <file> applies every entry in one atomic rewrite;
    \\   fields may be dotted and indexed like the single-edit form;
    \\   a raw-node key patches a sidecar's bytes at an offset:
    \\   {"CAB-..resS": {"offset": 4096, "bytes": "<base64>"}} replaces
    \\   the decoded bytes at that offset of the node's data)
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
    if (stat.kind == .directory and (command == .diff or command == .managed)) {
        if (command == .managed) {
            cmdManaged(path, rest, &.{}, stdout) catch |err| {
                if (err == error.WriteFailed) std.process.exit(141);
                try stderr.print("unityz: {s}: {s}\n", .{ path, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            finalFlush(stdout);
            return;
        }
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
        defer dir.close(io);
        // Batch mode reads one file per iteration and nothing survives the
        // `runCommand` call, so the bytes go in an arena that is reset each
        // time. The process arena never frees, so reading into it would hold
        // every file of the directory at once — peak memory would track the
        // whole tree instead of its largest single file.
        var batch_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer batch_arena_state.deinit();
        const batch_arena = batch_arena_state.allocator();
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            defer _ = batch_arena_state.reset(.retain_capacity);
            if (entry.kind != .file) continue;
            const full = try std.fmt.allocPrint(batch_arena, "{s}/{s}", .{ path, entry.name });
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, batch_arena, .unlimited) catch |err| {
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

const Command = enum { info, extract, edit, verify, stats, find, fsb, show, diff, hash, skin, shader, hierarchy, managed };

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
        .fsb => return cmdFsb(path, rest, bytes, stdout),
        .show => return cmdShow(path, rest, bytes, stdout, false),
        .shader => return cmdShow(path, rest, bytes, stdout, true),
        .diff => return cmdDiff(path, rest, bytes, stdout),
        .hash => return cmdHash(path, rest, bytes, stdout),
        .skin => return cmdSkin(path, rest, bytes, stdout),
        .hierarchy => return cmdHierarchy(path, rest, bytes, stdout),
        .managed => return cmdManaged(path, rest, bytes, stdout),
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

/// External typetree table (`--trees <file.json>`): the class trees Mono
/// serialized files omit. Unity strips the trees from Mono builds, so this
/// is what makes typeless `.assets` files decodable at all.
///
/// The JSON shape is the one `TypeTreeGeneratorAPI.get_nodes_as_json()`
/// emits (plus three meta keys):
///
/// ```json
/// {
///   "__meta__": { "unity": "2021.3.45f2", ... },
///   "__class_ids__": { "Texture2D": 28, "MonoBehaviour": 114, ... },
///   "__monoscripts__": [ { "file": "globalgamemanagers.assets",
///                          "path_id": 128, "class": "Item_Base" }, ... ],
///   "Item_Base": [ { "m_Type": "Item_Base", "m_Name": "Base",
///                    "m_Level": 0, "m_MetaFlag": 0 }, ... ],
///   "Texture2D": [ ... ]
/// }
/// ```
///
/// Built-in classes resolve by class name (via `__class_ids__`);
/// MonoBehaviours resolve by their script: the object's `m_Script` PPtr is
/// matched against `__monoscripts__` (keyed "basename:path_id", where the
/// basename is the file the script object lives in, e.g.
/// `globalgamemanagers.assets`), yielding the script class name whose full
/// tree (standard MonoBehaviour header + serialized .NET fields) decodes
/// the object.
const InjectedTrees = struct {
    trees: std.StringHashMapUnmanaged(*const unityz.typetree.TypeTree) = .empty,
    /// MonoBehaviour script trees (`__script_trees__`), keyed by script
    /// class name. Kept separate from built-in class trees: a script can
    /// share its name with a built-in class (e.g. AnimatorController is
    /// both Unity class 91 and a MonoBehaviour script).
    script_trees: std.StringHashMapUnmanaged(*const unityz.typetree.TypeTree) = .empty,
    class_ids: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    monoscripts: std.StringHashMapUnmanaged([]const u8) = .empty,
    mono_header: ?*const unityz.typetree.TypeTree = null,
};

/// Reads and parses a `--trees` file into an InjectedTrees table (arena
/// owned). Prints a diagnostic and returns null when the file is unreadable
/// or contains no class trees.
fn parseInjectedTrees(arena: std.mem.Allocator, path: []const u8, stdout: *Io.Writer) !?*const InjectedTrees {
    const io = io_global.io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        try stdout.print("unityz: cannot read trees file: {s}\n", .{@errorName(err)});
        return null;
    };
    const v = parseJsonLiteral(text) catch |err| {
        try stdout.print("unityz: bad trees JSON: {s}\n", .{@errorName(err)});
        return null;
    };
    const fields = switch (v) {
        .obj => |f| f,
        else => {
            try stdout.print("unityz: trees file must be a JSON object\n", .{});
            return null;
        },
    };
    const out = try buildInjectedTrees(arena, fields, stdout);
    if (out.trees.count() == 0 and out.script_trees.count() == 0) {
        try stdout.print("unityz: trees file has no class trees\n", .{});
        return null;
    }
    const tp = try arena.create(InjectedTrees);
    tp.* = out;
    return tp;
}

/// Turns the `--trees` JSON fields into an InjectedTrees table: built-in
/// class trees by name, MonoBehaviour script trees (`__script_trees__`), and
/// the class-name / mono-script lookup maps. Shared with the test suite.
fn buildInjectedTrees(arena: std.mem.Allocator, fields: []const unityz.value.Field, stdout: *Io.Writer) !InjectedTrees {
    var out: InjectedTrees = .{};
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "__meta__")) continue;
        if (std.mem.eql(u8, f.name, "__class_ids__")) {
            const ids = switch (f.value) {
                .obj => |ff| ff,
                else => continue,
            };
            for (ids) |idf| {
                const cid = idf.value.asInt() orelse continue;
                if (cid >= 0 and cid <= std.math.maxInt(i32)) {
                    try out.class_ids.put(arena, @intCast(cid), idf.name);
                }
            }
        } else if (std.mem.eql(u8, f.name, "__monoscripts__")) {
            const arr = switch (f.value) {
                .array => |a| a,
                else => continue,
            };
            for (arr) |e| {
                const ef = switch (e) {
                    .obj => |ff| ff,
                    else => continue,
                };
                var file: []const u8 = "";
                var pid: i64 = 0;
                var cls: []const u8 = "";
                for (ef) |ff| {
                    if (std.mem.eql(u8, ff.name, "file")) {
                        if (ff.value == .string) file = ff.value.string;
                    } else if (std.mem.eql(u8, ff.name, "path_id")) {
                        pid = ff.value.asInt() orelse 0;
                    } else if (std.mem.eql(u8, ff.name, "class")) {
                        if (ff.value == .string) cls = ff.value.string;
                    }
                }
                if (file.len == 0 or cls.len == 0 or pid == 0) continue;
                var key_buf: [1024]u8 = undefined;
                const key = try arena.dupe(u8, try std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ file, pid }));
                try out.monoscripts.put(arena, key, cls);
            }
        } else if (std.mem.eql(u8, f.name, "__script_trees__")) {
            const map = switch (f.value) {
                .obj => |ff| ff,
                else => continue,
            };
            for (map) |sf| {
                if (try buildInjectedTree(arena, sf.name, sf.value, stdout)) |tp| {
                    try out.script_trees.put(arena, sf.name, tp);
                }
            }
        } else {
            // A class tree: flat wire-style node list.
            if (try buildInjectedTree(arena, f.name, f.value, stdout)) |tp| {
                try out.trees.put(arena, f.name, tp);
                if (std.mem.eql(u8, f.name, "MonoBehaviour")) out.mono_header = tp;
            }
        }
    }
    return out;
}

/// Parses one flat wire-style node list (`{m_Type,m_Name,m_Level,m_MetaFlag}
/// entries) into a TypeTree, or prints a diagnostic and returns null on
/// invalid input.
fn buildInjectedTree(arena: std.mem.Allocator, name: []const u8, value: unityz.value.Value, stdout: *Io.Writer) !?*const unityz.typetree.TypeTree {
    const arr = switch (value) {
        .array => |a| a,
        else => return null,
    };
    const nodes = try arena.alloc(unityz.typetree.Node, arr.len);
    for (arr, 0..) |e, i| {
        var node = unityz.typetree.Node{ .level = 0 };
        const ef = switch (e) {
            .obj => |ff| ff,
            else => continue,
        };
        for (ef) |ff| {
            if (std.mem.eql(u8, ff.name, "m_Type")) {
                if (ff.value == .string) node.type_name = ff.value.string;
            } else if (std.mem.eql(u8, ff.name, "m_Name")) {
                if (ff.value == .string) node.name = ff.value.string;
            } else if (std.mem.eql(u8, ff.name, "m_Level")) {
                const lv = ff.value.asInt() orelse continue;
                if (lv < 0 or lv > unityz.typetree.max_depth) continue;
                node.level = @intCast(lv);
            } else if (std.mem.eql(u8, ff.name, "m_MetaFlag")) {
                const mf = ff.value.asInt() orelse continue;
                if (mf >= std.math.minInt(i32) and mf <= std.math.maxInt(i32)) {
                    node.meta_flags = @intCast(mf);
                }
            }
        }
        nodes[i] = node;
    }
    const tree = unityz.typetree.fromFlatNodes(arena, nodes) catch |err| {
        try stdout.print("unityz: trees entry '{s}': {s}\n", .{ name, @errorName(err) });
        return null;
    };
    const tp = try arena.create(unityz.typetree.TypeTree);
    tp.* = tree;
    return tp;
}

/// Resolves `path_id` against the injected mono-script table. The key is
/// "basename:path_id", where the basename is the file the MonoScript object
/// lives in: the external named by `m_Script.m_FileID` (via `sf.externals`),
/// or the file being decoded when `m_FileID == 0`.
fn injectedScriptClass(
    inj: *const InjectedTrees,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    ptr: unityz.value.PPtr,
) ?[]const u8 {
    if (ptr.path_id == 0) return null;
    var fname: []const u8 = undefined;
    if (ptr.file_id == 0) {
        fname = own_basename;
    } else if (ptr.file_id > 0) {
        const idx: usize = @intCast(ptr.file_id - 1);
        if (idx >= sf.externals.len) return null;
        fname = basename(sf.externals[idx].path);
    } else {
        return null;
    }
    var key_buf: [1024]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ fname, ptr.path_id }) catch return null;
    return inj.monoscripts.get(key);
}

/// Picks the injected tree for a typeless file's object. MonoBehaviours
/// (class 114) resolve their script's full tree via the `m_Script` header
/// PPtr; every other class resolves by built-in class name. `data` is the
/// object's raw bytes; the header-only decode uses the standard
/// "MonoBehaviour" tree so alignment matches the real object reader.
fn injectedTreeFor(
    arena: std.mem.Allocator,
    inj: *const InjectedTrees,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    class_id: i32,
    data: []const u8,
) ?*const unityz.typetree.TypeTree {
    if (class_id == 114) {
        const hdr = inj.mono_header orelse return null;
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &hdr.roots[0]) catch return null;
        const script = unityz.classes.pptrField(v, "m_Script") orelse return null;
        const cls = injectedScriptClass(inj, sf, own_basename, script) orelse return null;
        return inj.script_trees.get(cls);
    }
    const name = inj.class_ids.get(class_id) orelse return null;
    return inj.trees.get(name);
}

fn cmdExtract(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var raw = false;
    var recursive = false;
    var json_mode = false;
    var summary_mode = false;
    var class_filter: ?i32 = null;
    var path_filter: ?Selector = null;
    var name_filter: ?[]const u8 = null;
    var format: ExtractFormat = .png;
    var trees_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--raw")) {
            raw = true;
        } else if (std.mem.eql(u8, arg, "--recursive")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_mode = true;
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
        } else if (std.mem.eql(u8, arg, "--trees") and i + 1 < rest.len) {
            trees_path = rest[i + 1];
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
    if (raw and summary_mode) {
        try stdout.print("unityz: --raw and --summary are mutually exclusive\n", .{});
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
            var summary: ExtractSummary = .{};
            var scripts: std.ArrayList(ScriptEntry) = .empty;
            const summary_ptr: ?*ExtractSummary = if (summary_mode) &summary else null;
            var sidecars: std.ArrayList(Sidecar) = .empty;
            const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("unityz: {s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container == .serialized) continue;
                try sidecars.append(arena, .{ .path = e.path, .data = e.data });
            }
            for (try diskSidecars(arena, path)) |sc| try sidecars.append(arena, sc);
            for (wf.entries) |e| {
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, e.path, sn)) continue;
                    }
                }
                // Entry paths are file-supplied; confine the written name to
                // one component so a crafted path cannot steer the write
                // outside the extract directory.
                const base_name = sanitizeComponent(try arena.dupe(u8, basename(e.path)));
                if (!summary_mode) {
                    try writeFileToCwd(base_name, e.data);
                    try stdout.print("extracted {s} ({d} bytes)\n", .{ base_name, e.data.len });
                }
                if ((recursive or summary_mode) and unityz.container.sniff(e.data).container == .serialized) {
                    try extractSerialized(arena, e.path, e.data, raw, json_mode, class_filter, if (path_filter) |pf| pf.path_id else null, try std.fmt.allocPrint(arena, "objects/{s}", .{base_name}), sidecars.items, &manifest, format, name_filter, injected, summary_ptr, &scripts, stdout);
                }
            }
            if (summary_mode) {
                try printExtractSummary(arena, &summary, json_mode, stdout);
            } else {
                if (scripts.items.len != 0) try writeScriptsJson(arena, scripts.items, stdout);
                if (json_mode) try writeManifest(arena, manifest.items, stdout);
            }
        },
        .bundle => {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var manifest: std.ArrayList(ManifestEntry) = .empty;
            var summary: ExtractSummary = .{};
            var scripts: std.ArrayList(ScriptEntry) = .empty;
            const summary_ptr: ?*ExtractSummary = if (summary_mode) &summary else null;
            var sidecars: std.ArrayList(Sidecar) = .empty;
            const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("unityz: {s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container == .serialized) continue;
                try sidecars.append(arena, .{ .path = n.path, .data = n.data });
            }
            for (try diskSidecars(arena, path)) |sc| try sidecars.append(arena, sc);
            for (b.nodes) |n| {
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, n.path, sn)) continue;
                    }
                }
                // Node paths are file-supplied; confine the written name to
                // one component so a crafted path cannot steer the write
                // outside the extract directory.
                const base_name = sanitizeComponent(try arena.dupe(u8, basename(n.path)));
                if (!summary_mode) {
                    try writeFileToCwd(base_name, n.data);
                    try stdout.print("extracted {s} ({d} bytes)\n", .{ base_name, n.data.len });
                }
                if ((recursive or summary_mode) and unityz.container.sniff(n.data).container == .serialized) {
                    try extractSerialized(arena, n.path, n.data, raw, json_mode, class_filter, if (path_filter) |pf| pf.path_id else null, try std.fmt.allocPrint(arena, "objects/{s}", .{base_name}), sidecars.items, &manifest, format, name_filter, injected, summary_ptr, &scripts, stdout);
                }
            }
            if (summary_mode) {
                try printExtractSummary(arena, &summary, json_mode, stdout);
            } else {
                if (scripts.items.len != 0) try writeScriptsJson(arena, scripts.items, stdout);
                if (json_mode) try writeManifest(arena, manifest.items, stdout);
            }
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
            var summary: ExtractSummary = .{};
            var scripts: std.ArrayList(ScriptEntry) = .empty;
            const summary_ptr: ?*ExtractSummary = if (summary_mode) &summary else null;
            const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;
            // Streamed textures/audio point at sibling `.resS` files; load
            // them so those references resolve for a bare serialized file.
            const sidecars = try diskSidecars(arena, path);
            try extractSerialized(arena, path, bytes, raw, json_mode, class_filter, if (path_filter) |pf| pf.path_id else null, null, sidecars, &manifest, format, name_filter, injected, summary_ptr, &scripts, stdout);
            if (summary_mode) {
                try printExtractSummary(arena, &summary, json_mode, stdout);
            } else {
                if (scripts.items.len != 0) try writeScriptsJson(arena, scripts.items, stdout);
                if (json_mode) try writeManifest(arena, manifest.items, stdout);
            }
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

/// One consolidated MonoScript registry entry (`scripts.json`): the script
/// metadata plus the payload reference. Replaces one file per script, which
/// a large game (7DTD alone ships 6,500) turns into thousands of tiny JSON
/// files.
const ScriptEntry = struct {
    path_id: i64,
    name: []const u8,
    execution_order: i64,
    properties_hash: []const u8, // 16 bytes
    class_name: []const u8,
    namespace: []const u8,
    assembly: []const u8,
    script: ?unityz.value.PPtr,
    node: ?[]const u8,
};

/// Per-class tally for `extract --summary`, a dry run: what would be
/// extracted per class, without writing anything.
const SummaryClassStat = struct { count: usize = 0, bytes: usize = 0 };
const ExtractSummary = struct {
    classes: std.AutoHashMapUnmanaged(i32, SummaryClassStat) = .empty,
    skipped: usize = 0,
    typeless: usize = 0,
};

/// Writes the consolidated script registry as one `scripts.json` array.
fn writeScriptsJson(arena: std.mem.Allocator, entries: []const ScriptEntry, stdout: *Io.Writer) !void {
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const w = &aw.writer;
    try w.writeAll("[");
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"path_id\":{d},\"name\":", .{e.path_id});
        try writeJsonString(w, std.mem.trimEnd(u8, e.name, "\x00"));
        try w.print(",\"execution_order\":{d},\"properties_hash\":\"", .{e.execution_order});
        for (e.properties_hash) |b| try w.print("{x:0>2}", .{b});
        try w.writeAll("\",\"class\":");
        try writeJsonString(w, std.mem.trimEnd(u8, e.class_name, "\x00"));
        try w.writeAll(",\"namespace\":");
        try writeJsonString(w, std.mem.trimEnd(u8, e.namespace, "\x00"));
        try w.writeAll(",\"assembly\":");
        try writeJsonString(w, std.mem.trimEnd(u8, e.assembly, "\x00"));
        if (e.script) |sp| {
            try w.print(",\"script\":{{\"file_id\":{d},\"path_id\":{d}}}", .{ sp.file_id, sp.path_id });
        }
        if (e.node) |n| {
            try w.writeAll(",\"node\":");
            try writeJsonString(w, n);
        }
        try w.writeByte('}');
    }
    try w.writeAll("]\n");
    const out = aw.toArrayList();
    try writeFileToCwd("scripts.json", out.items);
    try stdout.print("extracted scripts.json ({d} script(s))\n", .{entries.len});
}

/// Appends one consolidated script registry entry from a decoded MonoScript
/// value. The properties hash (Hash128, `bytes[0..15]` children in the value
/// tree) is flattened to raw bytes; `writeScriptsJson` hex-encodes it.
fn appendScriptEntry(arena: std.mem.Allocator, scripts: *std.ArrayList(ScriptEntry), v: unityz.value.Value, path_id: i64, subdir: ?[]const u8) !void {
    const ms = unityz.classes.MonoScript.fromValue(v);
    var hash_bytes: [16]u8 = [_]u8{0} ** 16;
    var hash_len: usize = 0;
    if (unityz.classes.fieldOf(v, "m_PropertiesHash")) |hv| {
        if (hv == .obj) {
            var i: usize = 0;
            while (i < 16 and i < hv.obj.len) : (i += 1) {
                hash_bytes[i] = @intCast((hv.obj[i].value.asInt() orelse 0) & 0xff);
            }
            hash_len = i;
        }
    }
    try scripts.append(arena, .{
        .path_id = path_id,
        .name = ms.name,
        .execution_order = unityz.classes.intField(v, "m_ExecutionOrder") orelse 0,
        .properties_hash = try arena.dupe(u8, hash_bytes[0..hash_len]),
        .class_name = ms.class_name,
        .namespace = ms.namespace,
        .assembly = ms.assembly,
        .script = ms.script,
        .node = subdir,
    });
}

/// Adds one decodable object to a `--summary` dry-run tally.
fn tallySummary(arena: std.mem.Allocator, s: *ExtractSummary, class_id: i32, bytes: []const u8) !void {
    const gop = try s.classes.getOrPut(arena, class_id);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.count += 1;
    gop.value_ptr.bytes += bytes.len;
}

/// Prints an `extract --summary` dry-run report: one aligned line per class
/// (objects + bytes, largest first), then totals. With `--json` the same
/// data is emitted machine-readable instead.
fn printExtractSummary(arena: std.mem.Allocator, s: *const ExtractSummary, json: bool, stdout: *Io.Writer) !void {
    if (json) {
        try stdout.writeAll("{\"objects\":");
        var total: usize = 0;
        var bytes_total: usize = 0;
        var it = s.classes.iterator();
        while (it.next()) |e| {
            total += e.value_ptr.count;
            bytes_total += e.value_ptr.bytes;
        }
        try stdout.print("{d},\"bytes\":{d},\"classes\":{{", .{ total, bytes_total });
        var first = true;
        var it2 = s.classes.iterator();
        while (it2.next()) |e| {
            if (!first) try stdout.writeByte(',');
            first = false;
            try stdout.print("\"{d}\":{{\"count\":{d},\"bytes\":{d}}}", .{ e.key_ptr.*, e.value_ptr.count, e.value_ptr.bytes });
        }
        try stdout.print("}}}}\n", .{});
        return;
    }
    const Entry = struct { class_id: i32, count: usize, bytes: usize };
    var list: std.ArrayList(Entry) = .empty;
    var total: usize = 0;
    var bytes_total: usize = 0;
    var it = s.classes.iterator();
    while (it.next()) |e| {
        total += e.value_ptr.count;
        bytes_total += e.value_ptr.bytes;
        try list.append(arena, .{ .class_id = e.key_ptr.*, .count = e.value_ptr.count, .bytes = e.value_ptr.bytes });
    }
    std.sort.insertion(Entry, list.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.bytes != b.bytes) return a.bytes > b.bytes;
            return a.class_id < b.class_id;
        }
    }.lessThan);
    try stdout.print("summary: {d} object(s), {d} byte(s)\n", .{ total, bytes_total });
    for (list.items) |e| {
        const name = unityz.classes.className(e.class_id) orelse "Unknown";
        try stdout.print("  {d}  {s} (class {d})  {d} byte(s)\n", .{ e.count, name, e.class_id, e.bytes });
    }
    if (s.typeless != 0) {
        try stdout.print("  {d} object(s) skipped: no type trees (pass --trees <file.json>)\n", .{s.typeless});
    }
    if (s.skipped != 0) {
        try stdout.print("  {d} object(s) skipped: decode failed\n", .{s.skipped});
    }
}

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

/// Loads the sibling `.resS`/`.resource` files next to a bare serialized
/// file, so streamed references (`m_StreamData`/`m_Resource` pointing at
/// `<name>.resS`) resolve during extract/verify. Empty when none exist.
fn diskSidecars(arena: std.mem.Allocator, path: []const u8) ![]const Sidecar {
    const io = io_global.io;
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var list: std.ArrayList(Sidecar) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".resS") and
            !std.mem.endsWith(u8, entry.name, ".resource")) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
        const data = std.Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch continue;
        // entry.name borrows the iterator's reused buffer; copy it.
        try list.append(arena, .{ .path = try arena.dupe(u8, entry.name), .data = data });
    }
    return list.items;
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
    // This runs once per m_RenderDataMap entry per sprite, so the field
    // names are spelled out rather than formatted on each comparison.
    const data_fields = [_][]const u8{ "data[0]", "data[1]", "data[2]", "data[3]" };
    for (data_fields) |fname| {
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

/// Per-file memoization for sprite rendering. Every sprite in an atlas
/// names the same sheet texture and is resolved against the same
/// SpriteAtlas objects, so without this an N-sprite atlas re-parsed each
/// atlas object N times and re-decoded (and re-allocated) the shared
/// texture N times.
const SpriteCache = struct {
    textures: std.AutoHashMapUnmanaged(i64, ?DecodedTexture) = .empty,
    atlases: ?[]const unityz.value.Value = null,
};

/// Parses the file's SpriteAtlas objects once, memoized in `cache`.
fn atlasValues(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, cache: *SpriteCache) []const unityz.value.Value {
    if (cache.atlases) |a| return a;
    var list: std.ArrayList(unityz.value.Value) = .empty;
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
        list.append(arena, v) catch break;
    }
    cache.atlases = list.items;
    return list.items;
}

/// Finds the texture PPtr for a Sprite that has none of its own by
/// scanning the file's SpriteAtlas objects. Matches m_RenderDataKey the
/// way UnityPy does; when the key is absent, falls back to aligning
/// m_PackedSprites with m_RenderDataMap by position.
fn atlasTextureFor(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, cache: *SpriteCache, sprite_value: unityz.value.Value, sprite_path_id: i64) ?AtlasHit {
    const sprite_key = unityz.classes.fieldOf(sprite_value, "m_RenderDataKey");
    for (atlasValues(arena, sf, cache)) |v| {
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
    try w.print("{d},\"mode\":{d},\"codec\":\"{s}\",\"samples\":[", .{ bank.version, bank.mode, unityz.audio.modeName(bank.mode) });
    for (bank.samples, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        const dur_ms: u64 = if (s.frequency != 0) @as(u64, s.sample_count) * 1000 / s.frequency else 0;
        try w.print("{{\"name\":\"{s}\",\"frequency\":{d},\"channels\":{d},\"dataOffset\":{d},\"samples\":{d},\"durationMs\":{d}", .{ s.name, s.frequency, s.channels, s.data_offset, s.sample_count, dur_ms });
        if (s.loop_start) |ls| {
            try w.print(",\"loopStart\":{d},\"loopEnd\":{d}", .{ ls, s.loop_end orelse 0 });
        }
        if (s.vorbis_crc) |crc| {
            try w.print(",\"setupCrc\":{d}", .{crc});
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    var list = aw.toArrayList();
    return try list.toOwnedSlice(arena);
}

/// `fsb <path> [--outdir <dir>]` — decode a raw FSB5 audio bank (as found
/// inside FMOD `.bank` files) to playable WAV/OGG per sample, plus a
/// metadata JSON. No external tools: PCM8/16/24/32/FLOAT and the ADPCM
/// codecs decode in pure Zig; Vorbis banks (mode 15) are remuxed to Ogg
/// from the crc-keyed setup-header table.
fn cmdFsb(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var outdir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--outdir") and i + 1 < rest.len) {
            outdir = rest[i + 1];
            i += 1;
        } else {
            try stdout.print("unityz: unknown fsb option '{s}'\n", .{rest[i]});
            return;
        }
    }
    if (outdir) |d| {
        const io = io_global.io;
        ensureDirPath(io, d) catch |err| {
            try stdout.print("unityz: {s}: {s}\n", .{ d, @errorName(err) });
            return;
        };
    }
    extract_outdir = outdir;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bank = unityz.fsb5.parse(arena, bytes) catch |err| {
        try stdout.print("unityz: {s}: FSB5 parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    } orelse {
        try stdout.print("unityz: {s}: not an FSB5 bank\n", .{path});
        return;
    };
    try stdout.print("{s}: FSB5 v{d}, {d} sample(s), {s}\n", .{ path, bank.version, bank.num_samples, unityz.audio.modeName(bank.mode) });

    if (try fsb5MetadataJson(arena, bytes)) |meta| {
        try extractFile(null, "bank.json", meta);
        try stdout.print("extracted bank.json (metadata)\n", .{});
    }

    if (unityz.audio.decodable(bank.mode)) {
        var decoded: usize = 0;
        for (bank.samples, 0..) |s, si| {
            const pcm = unityz.audio.decodeSample(arena, bytes, bank.data_start, s, bank.mode) catch |err| {
                try stdout.print("  sample {d} ({s}): decode failed: {s}\n", .{ si, s.name, @errorName(err) });
                continue;
            };
            const wav = wavPcm16(arena, std.mem.sliceAsBytes(pcm), @intCast(s.channels), s.frequency, 16) catch continue;
            var name_buf: [192]u8 = undefined;
            const name = if (bank.samples.len == 1)
                try std.fmt.bufPrint(&name_buf, "audio_{s}.wav", .{if (s.name.len != 0) sanitizeComponent(try arena.dupe(u8, s.name)) else "sample"})
            else
                try std.fmt.bufPrint(&name_buf, "audio_{d:0>4}_{s}.wav", .{ si, if (s.name.len != 0) sanitizeComponent(try arena.dupe(u8, s.name)) else "sample" });
            try extractFile(null, name, wav);
            decoded += 1;
        }
        try stdout.print("extracted {d} wav sample(s)\n", .{decoded});
    } else if (bank.mode == 15) {
        var oggd: usize = 0;
        for (bank.samples, 0..) |s, si| {
            const ogg = unityz.vorbis.rebuildOgg(arena, bytes, bank.data_start, s) catch null orelse {
                if (s.vorbis_crc != null) {
                    try stdout.print("  sample {d} ({s}): vorbis setup CRC not in the known-headers table, kept as bank data\n", .{ si, s.name });
                }
                continue;
            };
            var name_buf: [192]u8 = undefined;
            const name = if (bank.samples.len == 1)
                try std.fmt.bufPrint(&name_buf, "audio_{s}.ogg", .{if (s.name.len != 0) sanitizeComponent(try arena.dupe(u8, s.name)) else "sample"})
            else
                try std.fmt.bufPrint(&name_buf, "audio_{d:0>4}_{s}.ogg", .{ si, if (s.name.len != 0) sanitizeComponent(try arena.dupe(u8, s.name)) else "sample" });
            try extractFile(null, name, ogg);
            oggd += 1;
        }
        try stdout.print("extracted {d} ogg sample(s)\n", .{oggd});
    } else {
        try stdout.print("bank codec {s} is not decodable in pure Zig; kept as .fsb\n", .{unityz.audio.modeName(bank.mode)});
        try extractFile(null, "bank.fsb", bytes);
    }
}

/// Writes a Font's embedded TTF/OTF plus a metadata descriptor JSON. The
/// font bytes always sit inline in the object in release binaries, so the
/// extension comes from the sfnt magic ("OTTO" = OpenType/CFF, 0x00010000
/// = TrueType). Fonts without embedded data (e.g. the engine's
/// LegacyRuntime stub) still get the descriptor.
fn writeFontFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    class_id: i32,
    f: unityz.classes.Font,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var ext: []const u8 = "ttf";
    if (f.font_data.len >= 4 and std.mem.eql(u8, f.font_data[0..4], "OTTO")) ext = "otf";
    const base_name = std.mem.trimEnd(u8, f.name, "\x00");
    var name_buf: [160]u8 = undefined;
    const name = sanitizeComponent(if (base_name.len != 0)
        try std.fmt.bufPrint(&name_buf, "font_{d}_{s}.{s}", .{ path_id, base_name, ext })
    else
        try std.fmt.bufPrint(&name_buf, "font_{d}.{s}", .{ path_id, ext }));
    if (f.font_data.len != 0) {
        try extractFile(subdir, name, f.font_data);
        try stdout.print("extracted {s} ({d} bytes, {s})\n", .{ name, f.font_data.len, ext });
        extracted.* += 1;
    } else {
        try stdout.print("  font {d} ({s}): no embedded font data, metrics only\n", .{ path_id, f.name });
    }
    if (try fontMetadataJson(arena, path_id, class_id, f)) |meta| {
        var meta_name_buf: [192]u8 = undefined;
        const meta_name = try std.fmt.bufPrint(&meta_name_buf, "{s}.json", .{name});
        try extractFile(subdir, meta_name, meta);
    }
    try manifest.append(arena, .{ .path_id = path_id, .class_id = class_id, .name = f.name, .subdir = subdir });
}

/// Font descriptor JSON: name list, metrics, kerning/rect counts, fallback
/// pointers, and the embedded data size. UnityPy has no font export at
/// all, so this metadata is a unityz addition.
fn fontMetadataJson(arena: std.mem.Allocator, path_id: i64, class_id: i32, f: unityz.classes.Font) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"class\":{d},\"name\":\"{s}\",\"font_names\":[", .{ path_id, class_id, f.name });
    for (f.font_names, 0..) |n, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{n});
    }
    try w.print("],\"font_size\":{d},\"line_spacing\":{d},\"tracking\":{d},\"pixel_scale\":{d}", .{ f.font_size, f.line_spacing, f.tracking, f.pixel_scale });
    try w.print(",\"ascent\":{d},\"descent\":{d},\"ascii_start_offset\":{d},\"character_spacing\":{d},\"character_padding\":{d},\"convert_case\":{d}", .{ f.ascent, f.descent, f.ascii_start_offset, f.character_spacing, f.character_padding, f.convert_case });
    try w.print(",\"default_style\":{d},\"font_rendering_mode\":{d},\"use_legacy_bounds_calculation\":{},\"should_round_advance_value\":{}", .{ f.default_style, f.font_rendering_mode, f.use_legacy_bounds_calculation, f.should_round_advance_value });
    try w.print(",\"character_rects\":{d},\"kerning_values\":{d},\"font_data_size\":{d}", .{ f.character_rects, f.kerning_values, f.font_data.len });
    if (f.default_material) |m| try w.print(",\"default_material\":{{\"file_id\":{d},\"path_id\":{d}}}", .{ m.file_id, m.path_id });
    if (f.texture) |t| try w.print(",\"texture\":{{\"file_id\":{d},\"path_id\":{d}}}", .{ t.file_id, t.path_id });
    if (f.fallback_fonts.len != 0) {
        try w.writeAll(",\"fallback_fonts\":[");
        for (f.fallback_fonts, 0..) |p, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{{\"file_id\":{d},\"path_id\":{d}}}", .{ p.file_id, p.path_id });
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
    var list = aw.toArrayList();
    return try list.toOwnedSlice(arena);
}

/// Extension for a ComputeShader kernel payload, from its magic: DXBC
/// (D3D11/12), SPIR-V (Vulkan), or the `#version`-prefixed GLSL source.
fn computeCodeExt(code: []const u8) []const u8 {
    if (code.len >= 4 and std.mem.eql(u8, code[0..4], "DXBC")) return "dxbc";
    if (code.len >= 4 and std.mem.eql(u8, code[0..4], "\x03\x02\x23\x07")) return "spirv";
    if (code.len >= 8 and std.mem.startsWith(u8, code, "#version")) return "glsl";
    return "bin";
}

/// Writes a ComputeShader's kernel payloads (one file per platform variant
/// and kernel, extension from the code magic) plus a descriptor JSON. The
/// per-kernel `code` blobs are DXBC / SPIR-V / GLSL source, so this also
/// recovers human-readable compute shaders. UnityPy has no ComputeShader
/// export at all.
fn writeComputeShaderFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    cs: unityz.classes.ComputeShader,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    const base_name = std.mem.trimEnd(u8, cs.name, "\x00");
    var cs_name_buf: [160]u8 = undefined;
    const cs_base = if (base_name.len != 0)
        try std.fmt.bufPrint(&cs_name_buf, "compute_{d}_{s}", .{ path_id, base_name })
    else
        try std.fmt.bufPrint(&cs_name_buf, "compute_{d}", .{path_id});

    for (cs.variants, 0..) |v, vi| {
        for (v.kernels) |k| {
            if (k.code.len == 0) continue;
            var name_buf: [192]u8 = undefined;
            const name = sanitizeComponent(try std.fmt.bufPrint(&name_buf, "{s}_{s}_v{d}.{s}", .{ cs_base, k.name, vi, computeCodeExt(k.code) }));
            try extractFile(subdir, name, k.code);
            try stdout.print("extracted {s} ({d} bytes, {s})\n", .{ name, k.code.len, computeCodeExt(k.code) });
            extracted.* += 1;
        }
    }
    if (try computeShaderJson(arena, path_id, cs)) |meta| {
        var meta_name_buf: [192]u8 = undefined;
        const meta_name = try std.fmt.bufPrint(&meta_name_buf, "{s}.compute.json", .{cs_base});
        try extractFile(subdir, sanitizeComponent(meta_name), meta);
    }
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 72, .name = cs.name, .subdir = subdir });
}

/// ComputeShader descriptor JSON: platform variants with per-kernel
/// thread-group sizes, payload format/size, resource binding counts, and
/// the constant-buffer layouts.
fn computeShaderJson(arena: std.mem.Allocator, path_id: i64, cs: unityz.classes.ComputeShader) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"class\":72,\"name\":\"{s}\",\"variants\":[", .{ path_id, cs.name });
    for (cs.variants, 0..) |v, vi| {
        if (vi != 0) try w.writeByte(',');
        try w.print("{{\"renderer\":{d},\"level\":{d},\"format\":\"{s}\",\"resourcesResolved\":{},\"kernels\":[", .{ v.target_renderer, v.target_level, if (v.kernels.len != 0 and v.kernels[0].code.len != 0) computeCodeExt(v.kernels[0].code) else "none", v.resources_resolved });
        for (v.kernels, 0..) |k, ki| {
            if (ki != 0) try w.writeByte(',');
            try w.print("{{\"name\":\"{s}\",\"threadGroupSize\":[", .{k.name});
            for (k.thread_group_size, 0..) |t, ti| {
                if (ti != 0) try w.writeByte(',');
                try w.print("{d}", .{t});
            }
            try w.print("],\"uniqueVariants\":{d},\"codeSize\":{d},\"codeFile\":\"{s}_{s}_v{d}.{s}\",\"cbs\":{d},\"textures\":{d},\"inBuffers\":{d},\"outBuffers\":{d}", .{
                k.unique_variants,
                k.code.len,
                std.mem.trimEnd(u8, cs.name, "\x00"),
                k.name,
                vi,
                computeCodeExt(k.code),
                k.cb_count,
                k.texture_count,
                k.in_buffer_count,
                k.out_buffer_count,
            });
            try w.writeByte('}');
        }
        try w.writeByte(']');
        if (v.constant_buffers.len != 0) {
            try w.writeAll(",\"constantBuffers\":[");
            for (v.constant_buffers, 0..) |cb, ci| {
                if (ci != 0) try w.writeByte(',');
                try w.print("{{\"name\":\"{s}\",\"byteSize\":{d},\"params\":[", .{ cb.name, cb.byte_size });
                for (cb.params, 0..) |p, pi| {
                    if (pi != 0) try w.writeByte(',');
                    try w.print("{{\"name\":\"{s}\",\"type\":{d},\"offset\":{d},\"arraySize\":{d},\"rowCount\":{d},\"colCount\":{d}}}", .{ p.name, p.type, p.offset, p.array_size, p.row_count, p.col_count });
                }
                try w.writeByte(']');
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    var list = aw.toArrayList();
    return try list.toOwnedSlice(arena);
}

fn extractSerialized(arena: std.mem.Allocator, path: []const u8, bytes: []const u8, raw: bool, json_mode: bool, class_filter: ?i32, path_filter: ?i64, subdir: ?[]const u8, sidecars: []const Sidecar, manifest: *std.ArrayList(ManifestEntry), format: ExtractFormat, name_filter: ?[]const u8, injected: ?*const InjectedTrees, summary: ?*ExtractSummary, scripts: *std.ArrayList(ScriptEntry), stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("unityz: {s}: serialized file parse failed: {s}\n", .{ path, @errorName(err) });
        return;
    };

    var extracted: usize = 0;
    var skipped: usize = 0;
    // Objects skipped because the file carries no type trees (Mono builds
    // strip them) and no injected trees were supplied.
    var typeless_skipped: usize = 0;
    var sprite_cache: SpriteCache = .{};
    // Every MonoBehaviour of the same component type points at one shared
    // MonoScript; without memoizing, that object was located and fully
    // deserialized once per behaviour.
    var script_cache: MonoScriptCache = .empty;
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
        var tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) {
            if (o.class_id == 128 or o.class_id == 72) {
                // Fonts and ComputeShaders self-describe their serialized
                // layout, so typeless files (Mono builds strip type trees)
                // decode from the raw layout with no tree.
                if (o.class_id == 128) {
                    const f = unityz.classes.Font.fromRaw(data, sf.endian, sf.unity_version) catch |err| {
                        try stdout.print("  object {d} (class 128 Font): decode failed: {s}\n", .{ o.path_id, @errorName(err) });
                        if (summary) |s| s.skipped += 1;
                        skipped += 1;
                        continue;
                    };
                    if (name_filter) |nf| {
                        if (std.ascii.indexOfIgnoreCase(f.name, nf) == null) continue;
                    }
                    if (summary) |s| {
                        try tallySummary(arena, s, 128, data);
                        continue;
                    }
                    try writeFontFiles(arena, subdir, o.path_id, o.class_id, f, manifest, &extracted, stdout);
                    continue;
                }
                const cs = unityz.classes.ComputeShader.fromRaw(data, sf.endian, sf.unity_version) catch |err| {
                    try stdout.print("  object {d} (class 72 ComputeShader): decode failed: {s}\n", .{ o.path_id, @errorName(err) });
                    if (summary) |s| s.skipped += 1;
                    skipped += 1;
                    continue;
                };
                if (name_filter) |nf| {
                    if (std.ascii.indexOfIgnoreCase(cs.name, nf) == null) continue;
                }
                if (summary) |s| {
                    try tallySummary(arena, s, 72, data);
                    continue;
                }
                try writeComputeShaderFiles(arena, subdir, o.path_id, cs, manifest, &extracted, stdout);
                continue;
            }
            // Mono builds ship no embedded trees; decode from the injected
            // table when one was supplied (`--trees`).
            if (injected) |inj| {
                if (injectedTreeFor(arena, inj, &sf, basename(path), o.class_id, data)) |it| {
                    tree = it.*;
                } else {
                    if (summary) |s| s.typeless += 1;
                    typeless_skipped += 1;
                    continue;
                }
            } else {
                if (summary) |s| s.typeless += 1;
                typeless_skipped += 1;
                continue;
            }
        }

        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch |err| {
            try stdout.print("  object {d} (class {d}): decode failed: {s}\n", .{ o.path_id, o.class_id, @errorName(err) });
            if (summary) |s| s.skipped += 1;
            skipped += 1;
            continue;
        };

        if (name_filter) |nf| {
            const nm = unityz.classes.stringField(v, "m_Name") orelse "";
            if (std.ascii.indexOfIgnoreCase(nm, nf) == null) continue;
        }

        if (summary) |s| {
            try tallySummary(arena, s, o.class_id, data);
            continue;
        }

        if (json_mode) {
            if (o.class_id == 115) {
                // MonoScripts consolidate into one scripts.json instead of
                // one file per script (a large game ships thousands).
                try appendScriptEntry(arena, scripts, v, o.path_id, subdir);
                try manifest.append(arena, .{
                    .path_id = o.path_id,
                    .class_id = 115,
                    .name = unityz.classes.stringField(v, "m_Name") orelse "",
                    .subdir = subdir,
                });
                extracted += 1;
                continue;
            }
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
                // The decoded, flipped and encoded buffers are dead once the
                // PNG is written, and each is on the order of the texture's
                // pixel count. The extraction arena lives until the whole
                // file is done, so taking them from it would make peak
                // memory the sum of every texture in the file rather than
                // the largest one.
                var tex_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                defer tex_arena_state.deinit();
                const tex_arena = tex_arena_state.allocator();
                const rgba = unityz.texture.decode(tex_arena, t.format, t.width, t.height, pixels) catch |err| {
                    try stdout.print("  texture {d}: {s} ({s}) unsupported\n", .{ o.path_id, unityz.texture.format.name(t.format), @errorName(err) });
                    skipped += 1;
                    continue;
                };
                // Unity stores texture rows bottom-up; PNGs are top-down, so
                // flip to match on-screen appearance (and UnityPy's export).
                const flipped = unityz.texture.flipVertical(tex_arena, rgba, t.width, t.height) catch |err| {
                    try stdout.print("  texture {d}: flip failed: {s}\n", .{ o.path_id, @errorName(err) });
                    skipped += 1;
                    continue;
                };
                const image = encodeImage(tex_arena, format, t.width, t.height, flipped) catch |err| {
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
            329 => { // VideoClip -> streamed video file + metadata JSON
                const clip_name = std.mem.trimEnd(u8, unityz.classes.stringField(v, "m_Name") orelse "", "\x00");
                const orig_path = unityz.classes.stringField(v, "m_OriginalPath") orelse "";
                var stream_path: []const u8 = "";
                var stream_offset: i64 = 0;
                var stream_size: i64 = 0;
                if (unityz.classes.fieldOf(v, "m_ExternalResources")) |er| {
                    stream_path = unityz.classes.stringField(er, "m_Source") orelse "";
                    stream_offset = unityz.classes.intField(er, "m_Offset") orelse 0;
                    stream_size = unityz.classes.intField(er, "m_Size") orelse 0;
                }
                var video: []const u8 = &.{};
                if (stream_size > 0 and stream_path.len != 0) {
                    video = resolveSidecar(sidecars, stream_path, @intCast(stream_offset), @intCast(stream_size));
                }
                if (video.len == 0) continue; // no stream data (embedded or absent)
                var ext: []const u8 = "mp4";
                if (std.mem.startsWith(u8, video, "\x1aE\xdf\xa3")) {
                    ext = "webm"; // EBML
                } else if (std.mem.startsWith(u8, video, "OggS")) {
                    ext = "ogv";
                } else if (std.mem.startsWith(u8, video, "RIFF")) {
                    ext = "avi";
                }
                var name_buf: [192]u8 = undefined;
                const base_name = if (clip_name.len != 0)
                    try std.fmt.bufPrint(&name_buf, "video_{d}_{s}.{s}", .{ o.path_id, clip_name, ext })
                else
                    try std.fmt.bufPrint(&name_buf, "video_{d}.{s}", .{ o.path_id, ext });
                const fname = sanitizeComponent(base_name);
                try extractFile(subdir, fname, video);
                try stdout.print("extracted {s} ({d} bytes, {s})\n", .{ fname, video.len, ext });
                extracted += 1;
                // metadata sidecar: what the type tree says about the clip
                var mbuf: std.ArrayList(u8) = .empty;
                var maw = std.Io.Writer.Allocating.fromArrayList(arena, &mbuf);
                const mw = &maw.writer;
                try mw.writeAll("{\"name\":");
                try writeJsonString(mw, clip_name);
                try mw.writeAll(",\"originalPath\":");
                try writeJsonString(mw, orig_path);
                try mw.print(",\"width\":{d},\"height\":{d},\"frameRate\":{d},\"frameCount\":{d},\"format\":{d}", .{
                    unityz.classes.intField(v, "Width") orelse unityz.classes.intField(v, "m_ProxyWidth") orelse 0,
                    unityz.classes.intField(v, "Height") orelse unityz.classes.intField(v, "m_ProxyHeight") orelse 0,
                    unityz.classes.intField(v, "m_FrameRate") orelse 0,
                    unityz.classes.intField(v, "m_FrameCount") orelse 0,
                    unityz.classes.intField(v, "m_Format") orelse 0,
                });
                try mw.print(",\"stream\":{{\"source\":", .{});
                try writeJsonString(mw, stream_path);
                try mw.print(",\"offset\":{d},\"size\":{d}}}}}", .{ stream_offset, stream_size });
                var mname_buf: [128]u8 = undefined;
                const mname = try std.fmt.bufPrint(&mname_buf, "{s}.json", .{fname});
                try extractFile(subdir, mname, maw.toArrayList().items);
                try stdout.print("extracted {s} (clip metadata)\n", .{mname});
                extracted += 1;
            },
            156 => { // TerrainData -> normalized heightmap PGM + metadata JSON
                const td_name = std.mem.trimEnd(u8, unityz.classes.stringField(v, "m_Name") orelse "", "\x00");
                const hm = unityz.classes.fieldOf(v, "m_Heightmap") orelse continue;
                const hv = unityz.classes.fieldOf(hm, "m_Heights") orelse continue;
                if (hv != .array or hv.array.len == 0) continue;
                const resolution = unityz.classes.intField(hm, "m_Resolution") orelse 0;
                if (resolution < 2) continue;
                // heights are (res+1)^2 SInt16 samples; the image is a square
                // of the square root's side
                const side_u = isqrt(hv.array.len);
                if (side_u < 2) continue;
                const side: u32 = @intCast(side_u);
                var min_h: i64 = std.math.maxInt(i64);
                var max_h: i64 = std.math.minInt(i64);
                for (hv.array) |h| {
                    const hv_i = h.asInt() orelse 0;
                    min_h = @min(min_h, hv_i);
                    max_h = @max(max_h, hv_i);
                }
                const range = max_h - min_h;
                var hbuf: std.ArrayList(u8) = .empty;
                var haw = std.Io.Writer.Allocating.fromArrayList(arena, &hbuf);
                const hw = &haw.writer;
                try hw.print("P5\n{d} {d}\n65535\n", .{ side, side });
                for (hv.array) |h| {
                    const hv_i = h.asInt() orelse 0;
                    const v16: u16 = if (range == 0) 0 else @intCast(@divTrunc((hv_i - min_h) * 65535, range));
                    try hw.writeByte(@intCast(v16 >> 8));
                    try hw.writeByte(@intCast(v16 & 0xff));
                }
                var name_buf: [192]u8 = undefined;
                const base_name = if (td_name.len != 0)
                    try std.fmt.bufPrint(&name_buf, "terrain_{d}_{s}.pgm", .{ o.path_id, td_name })
                else
                    try std.fmt.bufPrint(&name_buf, "terrain_{d}.pgm", .{o.path_id});
                const fname = sanitizeComponent(base_name);
                try extractFile(subdir, fname, haw.toArrayList().items);
                try stdout.print("extracted {s} ({d}x{d} heightmap, {d} samples)\n", .{ fname, side, side, hv.array.len });
                extracted += 1;
                // metadata sidecar: resolution, scale, height range
                var mbuf: std.ArrayList(u8) = .empty;
                var maw = std.Io.Writer.Allocating.fromArrayList(arena, &mbuf);
                const mw = &maw.writer;
                try mw.writeAll("{\"name\":");
                try writeJsonString(mw, td_name);
                try mw.print(",\"resolution\":{d},\"samples\":{d},\"heightMin\":{d},\"heightMax\":{d}", .{ resolution, hv.array.len, min_h, max_h });
                if (unityz.classes.fieldOf(hm, "m_Scale")) |sc| {
                    try mw.print(",\"scale\":{{\"x\":{d},\"y\":{d},\"z\":{d}}}", .{
                        unityz.classes.floatField(sc, "x") orelse 0,
                        unityz.classes.floatField(sc, "y") orelse 0,
                        unityz.classes.floatField(sc, "z") orelse 0,
                    });
                }
                try mw.writeByte('}');
                var mname_buf: [128]u8 = undefined;
                const mname = try std.fmt.bufPrint(&mname_buf, "{s}.json", .{fname});
                try extractFile(subdir, mname, maw.toArrayList().items);
                try stdout.print("extracted {s} (heightmap metadata)\n", .{mname});
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
                    // tools needed. Vorbis banks (mode 15) are remuxed to a
                    // playable Ogg (headers synthesized, setup header from
                    // the crc-keyed table) - UnityPy shells out to ffmpeg
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
                        } else if (bank.mode == 15) {
                            // Vorbis: remux the raw packet stream into a
                            // playable Ogg. Unknown setup CRCs stay .fsb.
                            for (bank.samples, 0..) |s, si| {
                                const ogg = unityz.vorbis.rebuildOgg(arena, audio, bank.data_start, s) catch null orelse {
                                    if (s.vorbis_crc != null) {
                                        try stdout.print("  audio {d}: FSB5 vorbis: setup CRC not in the known-headers table, kept .fsb\n", .{o.path_id});
                                    }
                                    continue;
                                };
                                var ogg_name_buf: [160]u8 = undefined;
                                const ogg_name = if (bank.samples.len == 1)
                                    try std.fmt.bufPrint(&ogg_name_buf, "audio_{d}_{s}.ogg", .{ o.path_id, base_name })
                                else
                                    try std.fmt.bufPrint(&ogg_name_buf, "audio_{d}_{s}_s{d}.ogg", .{ o.path_id, base_name, si });
                                try extractFile(subdir, sanitizeComponent(ogg_name), ogg);
                                try stdout.print("extracted {s} ({d} samples, {s})\n", .{ ogg_name, s.sample_count, unityz.audio.modeName(bank.mode) });
                                extracted += 1;
                            }
                        }
                    }
                }
                try stdout.print("extracted {s} ({d} bytes, {s})\n", .{ name, audio.len, ext });
                extracted += 1;
            },
            128 => { // Font
                const f = unityz.classes.Font.fromValue(v);
                try writeFontFiles(arena, subdir, o.path_id, o.class_id, f, manifest, &extracted, stdout);
            },
            72 => { // ComputeShader
                const cs = unityz.classes.ComputeShader.fromValue(v);
                try writeComputeShaderFiles(arena, subdir, o.path_id, cs, manifest, &extracted, stdout);
            },
            89 => { // Cubemap: six faces, each a full mip chain of the same size
                const t = unityz.classes.Texture2D.fromValue(v);
                if (t.width == 0 or t.height == 0) continue;
                var pixels: []const u8 = t.image_data;
                if (pixels.len == 0 and t.stream.size > 0 and t.stream.path.len == 0) {
                    const start: usize = @intCast(sf.data_offset + t.stream.offset);
                    const end = start + t.stream.size;
                    if (end <= sf.source.len) pixels = sf.source[start..end];
                }
                if (pixels.len == 0 and t.stream.size > 0 and t.stream.path.len != 0) {
                    // streamed from a sibling .resS/.resource sidecar
                    pixels = resolveSidecar(sidecars, t.stream.path, t.stream.offset, t.stream.size);
                }
                if (pixels.len == 0) continue;
                const mip0_size = unityz.texture.expectedSize(t.format, t.width, t.height) orelse continue;
                const face_size: usize = @intCast(t.complete_image_size);
                const faces: usize = @intCast(t.image_count);
                if (faces == 0 or face_size == 0) continue;
                const base_name = std.mem.trimEnd(u8, unityz.classes.stringField(v, "m_Name") orelse "", "\x00");
                var name_buf: [96]u8 = undefined;
                const base = sanitizeComponent(if (base_name.len != 0)
                    try std.fmt.bufPrint(&name_buf, "cubemap_{d}_{s}", .{ o.path_id, base_name })
                else
                    try std.fmt.bufPrint(&name_buf, "cubemap_{d}", .{o.path_id}));
                // Serialized face order matches Unity's CubemapFace enum:
                // 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z.
                const face_names = [_][]const u8{ "posx", "negx", "posy", "negy", "posz", "negz" };
                for (0..faces) |fi| {
                    if (fi >= face_names.len) break;
                    const start = fi * face_size;
                    if (start + mip0_size > pixels.len) continue;
                    var tex_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                    defer tex_arena_state.deinit();
                    const tex_arena = tex_arena_state.allocator();
                    const rgba = unityz.texture.decode(tex_arena, t.format, t.width, t.height, pixels[start .. start + mip0_size]) catch |err| {
                        try stdout.print("  cubemap {d}: face {s}: {s} ({s}) unsupported\n", .{ o.path_id, face_names[fi], unityz.texture.format.name(t.format), @errorName(err) });
                        continue;
                    };
                    const flipped = unityz.texture.flipVertical(tex_arena, rgba, t.width, t.height) catch continue;
                    const image = encodeImage(tex_arena, format, t.width, t.height, flipped) catch continue;
                    var face_buf: [160]u8 = undefined;
                    const face_name = sanitizeComponent(try std.fmt.bufPrint(&face_buf, "{s}_{s}.png", .{ base, face_names[fi] }));
                    try extractFile(subdir, face_name, image);
                    try stdout.print("extracted {s} ({s})\n", .{ face_name, unityz.texture.format.name(t.format) });
                    extracted += 1;
                }
                try manifest.append(arena, .{ .path_id = o.path_id, .class_id = o.class_id, .name = unityz.classes.stringField(v, "m_Name") orelse "", .subdir = subdir });
            },
            241 => { // AudioMixerController -> mixer graph JSON
                const ac = unityz.classes.AudioMixerController.fromValue(v);
                try writeMixerFiles(arena, subdir, o.path_id, ac, &sf, basename(path), injected, manifest, &extracted, stdout);
            },
            243 => { // AudioMixerGroupController
                const g = unityz.classes.AudioMixerGroup.fromValue(v);
                try writeMixerGroupFiles(arena, subdir, o.path_id, g, manifest, &extracted, stdout);
            },
            245 => { // AudioMixerSnapshotController
                const s = unityz.classes.AudioMixerSnapshot.fromValue(v);
                try writeMixerSnapshotFiles(arena, subdir, o.path_id, s, manifest, &extracted, stdout);
            },
            198 => { // ParticleSystem -> compact summary JSON
                const ps = unityz.classes.ParticleSystem.fromValue(v);
                try writeParticleFiles(arena, subdir, o.path_id, ps, manifest, &extracted, stdout);
            },
            91 => { // AnimatorController -> layer/state summary JSON
                const ac = unityz.classes.AnimatorController.fromValue(v);
                try writeAnimatorFiles(arena, subdir, o.path_id, ac, manifest, &extracted, stdout);
            },
            221 => { // AnimatorOverrideController -> clip override mapping JSON
                const oc = unityz.classes.AnimatorOverrideController.fromValue(v);
                try writeOverrideFiles(arena, subdir, o.path_id, oc, &sf, basename(path), injected, manifest, &extracted, stdout);
            },
            95 => { // Animator -> component summary JSON
                const an = unityz.classes.Animator.fromValue(v);
                try writeAnimatorComponentFiles(arena, subdir, o.path_id, an, &sf, basename(path), injected, manifest, &extracted, stdout);
            },
            115 => { // MonoScript -> consolidated scripts.json registry
                const ms = unityz.classes.MonoScript.fromValue(v);
                try appendScriptEntry(arena, scripts, v, o.path_id, subdir);
                extracted += 1;
                try manifest.append(arena, .{ .path_id = o.path_id, .class_id = 115, .name = ms.name, .subdir = subdir });
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
            74 => { // AnimationClip -> curves JSON
                const clip_name = std.mem.trimEnd(u8, unityz.classes.stringField(v, "m_Name") orelse "", "\x00");
                const legacy = unityz.classes.boolField(v, "m_Legacy") orelse false;
                const sample_rate: f64 = if (unityz.classes.fieldOf(v, "m_SampleRate")) |sv| sv.asFloat() orelse 0 else 0;
                var buf: std.ArrayList(u8) = .empty;
                var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
                const w = &aw.writer;
                try w.writeAll("{\"name\":");
                try writeJsonString(w, clip_name);
                try w.print(",\"legacy\":{},\"sample_rate\":{d},\"curves\":[", .{ legacy, sample_rate });
                const curve_fields = [_]struct { name: []const u8, default_attr: []const u8 }{
                    .{ .name = "m_EulerCurves", .default_attr = "m_LocalEulerAnglesHint" },
                    .{ .name = "m_PositionCurves", .default_attr = "m_LocalPosition" },
                    .{ .name = "m_ScaleCurves", .default_attr = "m_LocalScale" },
                    .{ .name = "m_QuaternionCurves", .default_attr = "m_LocalRotation" },
                    .{ .name = "m_FloatCurves", .default_attr = "" },
                    .{ .name = "m_PPtrCurves", .default_attr = "" },
                };
                var curve_count: usize = 0;
                for (curve_fields) |cf| {
                    const arr = unityz.classes.fieldOf(v, cf.name) orelse continue;
                    if (arr != .array) continue;
                    for (arr.array) |entry| {
                        if (entry != .obj) continue;
                        const curve_path = unityz.classes.stringField(entry, "path") orelse "";
                        var attr: []const u8 = cf.default_attr;
                        if (unityz.classes.stringField(entry, "m_Attribute")) |a| {
                            if (a.len != 0) attr = a;
                        }
                        const curve_obj = unityz.classes.fieldOf(entry, "curve") orelse continue;
                        const keys = unityz.classes.fieldOf(curve_obj, "m_Curve") orelse continue;
                        if (keys != .array) continue;
                        if (curve_count != 0) try w.writeByte(',');
                        try w.writeAll("{\"path\":");
                        try writeJsonString(w, curve_path);
                        try w.writeAll(",\"attribute\":");
                        try writeJsonString(w, attr);
                        try w.writeAll(",\"keys\":[");
                        for (keys.array, 0..) |k, ki| {
                            if (ki != 0) try w.writeByte(',');
                            // time + value + slopes carry the animation; the
                            // weight fields are defaults and dropped here
                            try w.writeAll("{\"time\":");
                            const t = if (unityz.classes.fieldOf(k, "time")) |tv| tv.asFloat() orelse 0 else 0;
                            try w.print("{d}", .{t});
                            try w.writeAll(",\"value\":");
                            if (unityz.classes.fieldOf(k, "value")) |val| {
                                try unityz.value.jsonWrite(val, w);
                            } else try w.writeAll("null");
                            try w.writeAll(",\"inSlope\":");
                            if (unityz.classes.fieldOf(k, "inSlope")) |val| {
                                try unityz.value.jsonWrite(val, w);
                            } else try w.writeAll("null");
                            try w.writeAll(",\"outSlope\":");
                            if (unityz.classes.fieldOf(k, "outSlope")) |val| {
                                try unityz.value.jsonWrite(val, w);
                            } else try w.writeAll("null");
                            try w.writeByte('}');
                        }
                        try w.writeAll("]}");
                        curve_count += 1;
                    }
                }
                try w.writeByte(']'); // close curves
                // Humanoid muscle clips store their animation in the muscle
                // clip, not the legacy curve arrays; surface the size, the
                // event count, and the generic bindings with paths resolved
                // through the file's AnimatorController TOS tables.
                const muscle_size = unityz.classes.intField(v, "m_MuscleClipSize") orelse 0;
                const events = if (unityz.classes.fieldOf(v, "m_Events")) |ev| (if (ev == .array) ev.array.len else 0) else 0;
                try w.print(",\"muscleClipSize\":{d},\"events\":{d}", .{ muscle_size, events });
                if (unityz.classes.fieldOf(v, "m_ClipBindingConstant")) |cbc| {
                    if (unityz.classes.fieldOf(cbc, "genericBindings")) |gb| {
                        if (gb == .array and gb.array.len != 0) {
                            try w.writeAll(",\"bindings\":[");
                            for (gb.array, 0..) |b, bi| {
                                if (bi != 0) try w.writeByte(',');
                                // The path is a hash of the rig's transform
                                // path; it only resolves through the owning
                                // avatar's TOS, which is usually not in the
                                // bundle, so it is emitted raw.
                                const bp = unityz.classes.intField(b, "path") orelse 0;
                                const attr = unityz.classes.intField(b, "attribute") orelse 0;
                                const tid = unityz.classes.intField(b, "typeID") orelse 0;
                                try w.print("{{\"path\":{d},\"attribute\":\"{s}\",\"typeID\":{d}}}", .{ bp, bindingAttributeName(attr), tid });
                            }
                            try w.writeByte(']');
                        }
                    }
                }
                try w.writeAll("}\n");
                const out = aw.toArrayList();
                var clean_buf: [192]u8 = undefined;
                const clean_name = if (clip_name.len != 0)
                    sanitizeComponent(try std.fmt.bufPrint(&clean_buf, "{s}", .{clip_name}))
                else
                    "";
                var name_buf: [192]u8 = undefined;
                const fname = try std.fmt.bufPrint(&name_buf, "animation_{d}_{s}.json", .{ o.path_id, if (clean_name.len != 0) clean_name else "unnamed" });
                try extractFile(subdir, fname, out.items);
                try stdout.print("extracted {s} ({d} curves)\n", .{ fname, curve_count });
                try manifest.append(arena, .{ .path_id = o.path_id, .class_id = o.class_id, .name = clip_name, .subdir = subdir });
                extracted += 1;
            },
            21 => { // Material -> readable text + structured JSON
                const mat = try writeMaterialText(arena, v);
                var name_buf: [160]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "material_{d}.txt", .{o.path_id});
                try extractFile(subdir, name, mat);
                try stdout.print("extracted {s} ({d} bytes)\n", .{ name, mat.len });
                extracted += 1;
                // Structured export: shader reference + saved properties
                // (texture bindings with scale/offset, floats, colors,
                // ints). UnityPy reads materials generically; this is the
                // "what does this material reference" answer in one file.
                if (try materialJson(arena, v)) |mj| {
                    var jbuf: [160]u8 = undefined;
                    const jname = try std.fmt.bufPrint(&jbuf, "material_{d}.json", .{o.path_id});
                    try extractFile(subdir, jname, mj);
                    try stdout.print("extracted {s} ({d} bytes)\n", .{ jname, mj.len });
                    extracted += 1;
                }
            },
            48 => { // Shader -> readable ShaderLab + structured JSON
                const shd = try writeShaderText(arena, v);
                if (shd.len == 0) continue;
                // the top-level m_Name is often empty for built-ins; the
                // parsed form carries the real one (as in writeShaderText)
                const top_name = std.mem.trimEnd(u8, fieldStr(v, "m_Name"), "\x00");
                var pf_name: []const u8 = top_name;
                if (pf_name.len == 0) {
                    if (unityz.classes.fieldOf(v, "m_ParsedForm")) |pf| {
                        pf_name = std.mem.trimEnd(u8, fieldStr(pf, "m_Name"), "\x00");
                    }
                }
                var name_buf: [192]u8 = undefined;
                const base = if (pf_name.len != 0) try std.fmt.bufPrint(&name_buf, "{s}", .{pf_name}) else "";
                var fname_buf: [256]u8 = undefined;
                const name = sanitizeComponent(try std.fmt.bufPrint(&fname_buf, "shader_{d}_{s}.shader", .{ o.path_id, if (base.len != 0) base else "unnamed" }));
                try extractFile(subdir, name, shd);
                try stdout.print("extracted {s} ({d} bytes)\n", .{ name, shd.len });
                extracted += 1;
                // Structured export: name, keywords, and the parsed-form
                // subshader/pass structure (pass type + state name + LOD).
                if (try shaderJson(arena, v)) |sj| {
                    var jbuf: [160]u8 = undefined;
                    const jname = try std.fmt.bufPrint(&jbuf, "shader_{d}.json", .{o.path_id});
                    try extractFile(subdir, jname, sj);
                    try stdout.print("extracted {s} ({d} bytes)\n", .{ jname, sj.len });
                    extracted += 1;
                }
            },
            213 => { // Sprite -> cropped / mesh-rendered image
                const rr = renderSprite(arena, &sf, sidecars, &sprite_cache, v, o.path_id, basename(path), injected) orelse continue;
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
                    if (p.file_id == 0) ms = monoScriptFor(arena, &sf, &script_cache, p.path_id);
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
    if (summary == null) {
        try stdout.print("{d} assets extracted, {d} skipped\n", .{ extracted, skipped });
        if (typeless_skipped != 0) {
            try stdout.print("  {d} object(s) skipped: this file has no type trees (Mono build); pass --trees <file.json> or --raw to decode them\n", .{typeless_skipped});
        }
    }
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i| return path[i + 1 ..];
    return path;
}

/// Integer square root (Newton), used to size the heightmap image.
fn isqrt(n: usize) usize {
    if (n < 2) return n;
    var x: usize = n;
    var y: usize = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
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
/// filesystems such as /proc. Components come from the platform's path
/// iterator rather than a hardcoded '/' split, so a `--outdir` written
/// with the native separator (`a\b\c` on Windows) still creates parents,
/// and the root prefix (`/`, `C:\`) is never handed to `createDir`.
fn ensureDirPath(io: std.Io, dir_path: []const u8) !void {
    if (dir_path.len == 0) return;
    if (std.Io.Dir.cwd().statFile(io, dir_path, .{})) |st| {
        if (st.kind == .directory) return;
    } else |_| {}
    var it = std.fs.path.componentIterator(dir_path);
    while (it.next()) |component| {
        std.Io.Dir.cwd().createDir(io, component.path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn writeFileToCwd(name: []const u8, contents: []const u8) !void {
    const io = io_global.io;
    const dir = std.Io.Dir.cwd();
    const full_owned = extract_outdir != null;
    const full = if (extract_outdir) |d|
        try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ d, name })
    else
        name;
    // One extracted object per call, so keeping the joined path would leak a
    // page-rounded allocation per file written.
    defer if (full_owned) std.heap.page_allocator.free(full);
    const file = try dir.createFile(io, full, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

/// Reads and type-tree-decodes another object of the same file, or null.
fn readObjectValue(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    path_id: i64,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
) ?unityz.value.Value {
    for (sf.objects) |*other| {
        if (other.path_id != path_id) continue;
        const ti = other.type_index orelse return null;
        if (ti >= sf.types.len) return null;
        const od = sf.objectData(other) orelse return null;
        var tree = sf.types[ti].type_tree;
        if (tree.roots.len == 0) {
            // Typeless Mono file: decode from the injected table.
            if (injected) |inj| {
                if (injectedTreeFor(arena, inj, sf, own_basename, other.class_id, od)) |it| {
                    tree = it.*;
                } else return null;
            } else return null;
        }
        var r2 = unityz.streams.Reader.init(od);
        r2.endian = sf.endian;
        return unityz.object_reader.readObject(arena, &r2, &tree.roots[0]) catch null;
    }
    return null;
}

/// Recursively writes an AudioMixerGroup subtree: the object's name plus its
/// resolved children. The depth cap stops a corrupt cycle from recursing
/// forever; mixer hierarchies are trees in practice.
fn writeMixerGroupJson(
    w: *Io.Writer,
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
    path_id: i64,
    depth: u32,
) !void {
    try w.print("{{\"path_id\":{d}", .{path_id});
    if (readObjectValue(arena, sf, path_id, own_basename, injected)) |obj| {
        const g = unityz.classes.AudioMixerGroup.fromValue(obj);
        try w.print(",\"name\":\"{s}\"", .{g.name});
        if (g.children.len != 0 and depth < 32) {
            try w.writeAll(",\"children\":[");
            for (g.children, 0..) |c, i| {
                if (i != 0) try w.writeByte(',');
                try writeMixerGroupJson(w, arena, sf, own_basename, injected, c.path_id, depth + 1);
            }
            try w.writeByte(']');
        }
    } else {
        try w.writeAll(",\"name\":\"\"");
    }
    try w.writeByte('}');
}

/// AudioMixerController export: the mixer graph with resolved group names,
/// the snapshot list, and the starting snapshot. UnityPy has no mixer
/// export at all; the group hierarchy is resolved through the serialized
/// file's objects (injected trees for typeless Mono files).
fn writeMixerFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    ac: unityz.classes.AudioMixerController,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"name\":\"{s}\",\"masterGroup\":", .{ path_id, ac.name });
    if (ac.master_group) |mg| {
        try writeMixerGroupJson(w, arena, sf, own_basename, injected, mg.path_id, 0);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"snapshots\":[");
    for (ac.snapshots, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"path_id\":{d}", .{s.path_id});
        if (readObjectValue(arena, sf, s.path_id, own_basename, injected)) |sv| {
            const sn = unityz.classes.AudioMixerSnapshot.fromValue(sv);
            try w.print(",\"name\":\"{s}\"", .{sn.name});
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    try w.writeAll(",\"startSnapshot\":");
    if (ac.start_snapshot) |ss| {
        try w.print("{{\"path_id\":{d}", .{ss.path_id});
        if (readObjectValue(arena, sf, ss.path_id, own_basename, injected)) |sv| {
            const sn = unityz.classes.AudioMixerSnapshot.fromValue(sv);
            try w.print(",\"name\":\"{s}\"", .{sn.name});
        }
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"updateMode\":{d}}}", .{ac.update_mode});
    var list = aw.toArrayList();
    const meta = try list.toOwnedSlice(arena);
    const base_name = std.mem.trimEnd(u8, ac.name, "\x00");
    var name_buf: [160]u8 = undefined;
    const name = sanitizeComponent(if (base_name.len != 0)
        try std.fmt.bufPrint(&name_buf, "mixer_{d}_{s}.json", .{ path_id, base_name })
    else
        try std.fmt.bufPrint(&name_buf, "mixer_{d}.json", .{path_id}));
    try extractFile(subdir, name, meta);
    try stdout.print("extracted {s} (mixer graph)\n", .{name});
    extracted.* += 1;
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 241, .name = ac.name, .subdir = subdir });
}

/// AudioMixerGroupController export: name plus the flat child path-id list.
fn writeMixerGroupFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    g: unityz.classes.AudioMixerGroup,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"name\":\"{s}\",\"children\":[", .{ path_id, g.name });
    for (g.children, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{c.path_id});
    }
    try w.writeAll("]}");
    var list = aw.toArrayList();
    const meta = try list.toOwnedSlice(arena);
    const base_name = std.mem.trimEnd(u8, g.name, "\x00");
    var name_buf: [160]u8 = undefined;
    const name = sanitizeComponent(if (base_name.len != 0)
        try std.fmt.bufPrint(&name_buf, "mixer_group_{d}_{s}.json", .{ path_id, base_name })
    else
        try std.fmt.bufPrint(&name_buf, "mixer_group_{d}.json", .{path_id}));
    try extractFile(subdir, name, meta);
    try stdout.print("extracted {s} (mixer group)\n", .{name});
    extracted.* += 1;
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 243, .name = g.name, .subdir = subdir });
}

/// AudioMixerSnapshotController export: name, transition time, and the
/// number of parameter values it sets.
fn writeMixerSnapshotFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    s: unityz.classes.AudioMixerSnapshot,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"name\":\"{s}\",\"time\":{d},\"parameters\":{d}}}", .{ path_id, s.name, s.time, s.values });
    var list = aw.toArrayList();
    const meta = try list.toOwnedSlice(arena);
    const base_name = std.mem.trimEnd(u8, s.name, "\x00");
    var name_buf: [160]u8 = undefined;
    const name = sanitizeComponent(if (base_name.len != 0)
        try std.fmt.bufPrint(&name_buf, "mixer_snapshot_{d}_{s}.json", .{ path_id, base_name })
    else
        try std.fmt.bufPrint(&name_buf, "mixer_snapshot_{d}.json", .{path_id}));
    try extractFile(subdir, name, meta);
    try stdout.print("extracted {s} (mixer snapshot)\n", .{name});
    extracted.* += 1;
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 245, .name = s.name, .subdir = subdir });
}

/// ParticleSystem summary export: the emitter's timeline, the main/emission/
/// shape module values, and the enabled flags of every module. UnityPy has
/// no ParticleSystem export at all.
fn writeParticleFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    ps: unityz.classes.ParticleSystem,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"duration\":{d},\"looping\":{},\"prewarm\":{},\"playOnAwake\":{},\"simulationSpeed\":{d},\"scalingMode\":{d},\"stopAction\":{d},\"cullingMode\":{d}", .{ path_id, ps.duration, ps.looping, ps.prewarm, ps.play_on_awake, ps.simulation_speed, ps.scaling_mode, ps.stop_action, ps.culling_mode });
    if (ps.game_object) |go| try w.print(",\"gameObject\":{d}", .{go.path_id});
    try w.print(",\"main\":{{\"startLifetime\":{d},\"startSpeed\":{d},\"startSize\":{d},\"gravityModifier\":{d},\"maxParticles\":{d}}}", .{ ps.start_lifetime, ps.start_speed, ps.start_size, ps.gravity_modifier, ps.max_particles });
    try w.print(",\"emission\":{{\"enabled\":{},\"rateOverTime\":{d},\"bursts\":{d}}}", .{ ps.emission_enabled, ps.rate_over_time, ps.burst_count });
    try w.print(",\"shape\":{{\"enabled\":{},\"type\":{d},\"angle\":{d},\"radius\":{d}}}", .{ ps.shape_enabled, ps.shape_type, ps.shape_angle, ps.shape_radius });
    const module_names = [_][]const u8{
        "initial",       "emission", "shape",           "size",                   "rotation",     "color",
        "uv",            "velocity", "inheritVelocity", "lifetimeByEmitterSpeed", "force",        "externalForces",
        "clampVelocity", "noise",    "sizeBySpeed",     "rotationBySpeed",        "colorBySpeed", "collision",
        "trigger",       "sub",      "lights",          "trail",
    };
    try w.writeAll(",\"modules\":{");
    for (module_names, 0..) |mn, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"{s}\":{}", .{ mn, ps.module_flags[i] });
    }
    try w.writeAll("}}");
    var list = aw.toArrayList();
    const meta = try list.toOwnedSlice(arena);
    var name_buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "particle_{d}.json", .{path_id});
    try extractFile(subdir, name, meta);
    try stdout.print("extracted {s} (particle system summary)\n", .{name});
    extracted.* += 1;
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 198, .name = "", .subdir = subdir });
}

/// AnimatorController summary export: layers and states with names resolved
/// through the controller's TOS hash table, transition/blend-tree counts,
/// the parameter count, and the referenced clips. UnityPy has no
/// AnimatorController export at all.
fn writeAnimatorFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    ac: unityz.classes.AnimatorController,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"name\":\"{s}\",\"layers\":[", .{ path_id, ac.name });
    for (ac.layers, 0..) |l, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"stateMachineIndex\":{d},\"name\":\"{s}\",\"blendingMode\":{d},\"defaultWeight\":{d},\"ikPass\":{}}}", .{ l.state_machine_index, ac.tosPath(l.binding), l.blending_mode, l.default_weight, l.ik_pass });
    }
    try w.writeByte(']');
    try w.print(",\"stateMachines\":{d},\"states\":[", .{ac.state_machine_count});
    for (ac.states, 0..) |st, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"fullPath\":\"{s}\",\"speed\":{d},\"loop\":{},\"transitions\":{d},\"blendTrees\":{d}}}", .{ ac.tosPath(st.name_id), ac.tosPath(st.full_path_id), st.speed, st.loop, st.transition_count, st.blend_tree_count });
    }
    try w.print("],\"anyStateTransitions\":{d},\"defaultState\":{d},\"parameters\":{d},\"clips\":[", .{ ac.any_state_transitions, ac.default_state, ac.parameters });
    for (ac.clips, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{c.path_id});
    }
    try w.writeByte(']');
    if (ac.tos.len != 0) {
        try w.writeAll(",\"paths\":[");
        for (ac.tos, 0..) |t, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{{\"hash\":{d},\"path\":\"{s}\"}}", .{ t.hash, t.path });
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
    var list = aw.toArrayList();
    const meta = try list.toOwnedSlice(arena);
    const base_name = std.mem.trimEnd(u8, ac.name, "\x00");
    var name_buf: [160]u8 = undefined;
    const name = sanitizeComponent(if (base_name.len != 0)
        try std.fmt.bufPrint(&name_buf, "animator_{d}_{s}.json", .{ path_id, base_name })
    else
        try std.fmt.bufPrint(&name_buf, "animator_{d}.json", .{path_id}));
    try extractFile(subdir, name, meta);
    try stdout.print("extracted {s} (animator controller)\n", .{name});
    extracted.* += 1;
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 91, .name = ac.name, .subdir = subdir });
}

/// AnimatorOverrideController export: the base controller plus the clip
/// override pairs with the clip names resolved through the file's objects.
/// UnityPy has no export for this class.
fn writeOverrideFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    oc: unityz.classes.AnimatorOverrideController,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"name\":\"{s}\",\"controller\":", .{ path_id, oc.name });
    if (oc.controller) |c| {
        try w.print("{{\"path_id\":{d}}}", .{c.path_id});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"overrides\":[");
    for (oc.overrides, 0..) |ov, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"original\":");
        try writeClipRef(w, arena, sf, own_basename, injected, ov.original);
        try w.writeAll(",\"replacement\":");
        try writeClipRef(w, arena, sf, own_basename, injected, ov.replacement);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    var list = aw.toArrayList();
    const meta = try list.toOwnedSlice(arena);
    const base_name = std.mem.trimEnd(u8, oc.name, "\x00");
    var name_buf: [160]u8 = undefined;
    const name = sanitizeComponent(if (base_name.len != 0)
        try std.fmt.bufPrint(&name_buf, "animator_override_{d}_{s}.json", .{ path_id, base_name })
    else
        try std.fmt.bufPrint(&name_buf, "animator_override_{d}.json", .{path_id}));
    try extractFile(subdir, name, meta);
    try stdout.print("extracted {s} ({d} override pairs)\n", .{ name, oc.overrides.len });
    extracted.* += 1;
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 221, .name = oc.name, .subdir = subdir });
}

/// Animator (class 95) export: the component's controller and avatar with
/// their names resolved through the file's objects, plus the playback flags.
fn writeAnimatorComponentFiles(
    arena: std.mem.Allocator,
    subdir: ?[]const u8,
    path_id: i64,
    an: unityz.classes.Animator,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
    manifest: *std.ArrayList(ManifestEntry),
    extracted: *usize,
    stdout: *Io.Writer,
) !void {
    var out = std.ArrayList(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    const w = &aw.writer;
    try w.print("{{\"path_id\":{d},\"gameObject\":", .{path_id});
    if (an.game_object) |go| {
        try w.print("{{\"path_id\":{d}}}", .{go.path_id});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"controller\":");
    try writeNamedRef(w, arena, sf, own_basename, injected, an.controller);
    try w.writeAll(",\"avatar\":");
    try writeNamedRef(w, arena, sf, own_basename, injected, an.avatar);
    try w.print(",\"cullingMode\":{d},\"updateMode\":{d},\"applyRootMotion\":{},\"linearVelocityBlending\":{},\"stabilizeFeet\":{},\"hasTransformHierarchy\":{},\"allowConstantClipSamplingOptimization\":{},\"keepAnimatorStateOnDisable\":{},\"writeDefaultValuesOnDisable\":{}}}", .{
        an.culling_mode,            an.update_mode,                               an.apply_root_motion,              an.linear_velocity_blending,        an.stabilize_feet,
        an.has_transform_hierarchy, an.allow_constant_clip_sampling_optimization, an.keep_animator_state_on_disable, an.write_default_values_on_disable,
    });
    var list = aw.toArrayList();
    const meta = try list.toOwnedSlice(arena);
    var name_buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "animator_{d}.json", .{path_id});
    try extractFile(subdir, name, meta);
    try stdout.print("extracted {s} (animator component)\n", .{name});
    extracted.* += 1;
    try manifest.append(arena, .{ .path_id = path_id, .class_id = 95, .name = "", .subdir = subdir });
}

/// Writes a PPtr as {"path_id": N, "name": "..."} with the target object's
/// m_Name resolved through the file's objects.
fn writeNamedRef(
    w: *Io.Writer,
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
    ref: ?unityz.value.PPtr,
) !void {
    if (ref) |r| {
        try w.print("{{\"path_id\":{d}", .{r.path_id});
        if (readObjectValue(arena, sf, r.path_id, own_basename, injected)) |rv| {
            const n = unityz.classes.stringField(rv, "m_Name") orelse "";
            if (n.len != 0) {
                try w.writeAll(",\"name\":");
                try writeJsonString(w, n);
            }
        }
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }
}

/// Writes an AnimationClip PPtr as {"path_id": N, "name": "..."} with the
/// clip's m_Name resolved through the file's objects.
fn writeClipRef(
    w: *Io.Writer,
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
    clip: ?unityz.value.PPtr,
) !void {
    if (clip) |c| {
        try w.print("{{\"path_id\":{d}", .{c.path_id});
        if (readObjectValue(arena, sf, c.path_id, own_basename, injected)) |cv| {
            const n = unityz.classes.stringField(cv, "m_Name") orelse "";
            if (n.len != 0) {
                try w.writeAll(",\"name\":");
                try writeJsonString(w, n);
            }
        }
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }
}

const MonoScriptCache = std.AutoHashMapUnmanaged(i64, unityz.classes.MonoScript);

/// Reads the file-local MonoScript at `path_id`, memoized in `cache`. An
/// unreadable script yields the empty MonoScript, cached alike so it is not
/// retried per behaviour.
fn monoScriptFor(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    cache: *MonoScriptCache,
    path_id: i64,
) unityz.classes.MonoScript {
    if (cache.get(path_id)) |hit| return hit;
    var ms = unityz.classes.MonoScript{};
    if (readObjectValue(arena, sf, path_id, "", null)) |v| ms = unityz.classes.MonoScript.fromValue(v);
    cache.put(arena, path_id, ms) catch {};
    return ms;
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
    cache: *SpriteCache,
    sidecars: []const Sidecar,
    path_id: i64,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
) ?DecodedTexture {
    if (cache.textures.get(path_id)) |hit| return hit;
    const decoded = decodeSpriteTextureUncached(arena, sf, sidecars, path_id, own_basename, injected);
    // A failed decode is cached too: retrying it per sprite costs the same
    // parse and fails the same way.
    cache.textures.put(arena, path_id, decoded) catch {};
    return decoded;
}

fn decodeSpriteTextureUncached(
    arena: std.mem.Allocator,
    sf: *const unityz.serialized.SerializedFile,
    sidecars: []const Sidecar,
    path_id: i64,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
) ?DecodedTexture {
    const tex_value = readObjectValue(arena, sf, path_id, own_basename, injected) orelse return null;
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
    cache: *SpriteCache,
    v: unityz.value.Value,
    sprite_path_id: i64,
    own_basename: []const u8,
    injected: ?*const InjectedTrees,
) ?RenderResult {
    const sprite = unityz.classes.Sprite.fromValue(v);
    // A {0,0} PPtr is the null reference: atlas-packed sprites leave
    // m_RD.texture empty and name the atlas texture instead.
    const hit = if (sprite.texture) |t| blk: {
        if (t.path_id != 0) break :blk AtlasHit{
            .texture = t,
            .rect = sprite.rect,
            .alpha_texture = sprite.alpha_texture,
            .settings_raw = sprite.settings_raw,
        };
        break :blk (atlasTextureFor(arena, sf, cache, v, sprite_path_id) orelse return null);
    } else (atlasTextureFor(arena, sf, cache, v, sprite_path_id) orelse return null);
    if (hit.texture.file_id != 0) return null; // external file not resolvable here

    const tex = decodeSpriteTexture(arena, sf, cache, sidecars, hit.texture.path_id, own_basename, injected) orelse return null;
    var rgba: []const u8 = tex.rgba;
    // Merge a separate alpha texture if present (packed sprites).
    if (hit.alpha_texture) |at| {
        if (at.path_id != 0 and at.file_id == 0) {
            if (decodeSpriteTexture(arena, sf, cache, sidecars, at.path_id, own_basename, injected)) |alpha_tex| {
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
    // UnityPy's OBJ layout: `g` group names (not `o`), per-submesh group
    // lines, and floats with 9 significant digits.
    const name = std.mem.trimEnd(u8, mesh.name, "\x00");
    try w.print("g {s}\n", .{name});
    for (0..vcount) |i| {
        const x = meshF32(mesh, 0, i, 0, sf.endian) orelse return &.{};
        const y = meshF32(mesh, 0, i, 1, sf.endian) orelse return &.{};
        const z = meshF32(mesh, 0, i, 2, sf.endian) orelse return &.{};
        // Unity is left-handed; OBJ convention is right-handed, so mirror X
        // (UnityPy's exporter does the same, negating vertices and normals).
        try w.print("v ", .{});
        try writeObjFloat(&w, -@as(f64, x));
        try w.print(" ", .{});
        try writeObjFloat(&w, @as(f64, y));
        try w.print(" ", .{});
        try writeObjFloat(&w, @as(f64, z));
        try w.print("\n", .{});
    }
    if (uv) |t| {
        if (t.format == 0 and t.dimension >= 2 and meshF32(mesh, uv_index, 0, 0, sf.endian) != null) {
            for (0..vcount) |i| {
                try w.print("vt ", .{});
                try writeObjFloat(&w, @as(f64, meshF32(mesh, uv_index, i, 0, sf.endian) orelse 0));
                try w.print(" ", .{});
                try writeObjFloat(&w, @as(f64, meshF32(mesh, uv_index, i, 1, sf.endian) orelse 0));
                try w.print("\n", .{});
            }
        }
    }
    if (nrm) |n| {
        if (n.format == 0 and n.dimension >= 3 and meshF32(mesh, 1, 0, 0, sf.endian) != null) {
            for (0..vcount) |i| {
                try w.print("vn ", .{});
                try writeObjFloat(&w, -@as(f64, meshF32(mesh, 1, i, 0, sf.endian) orelse 0));
                try w.print(" ", .{});
                try writeObjFloat(&w, @as(f64, meshF32(mesh, 1, i, 1, sf.endian) orelse 0));
                try w.print(" ", .{});
                try writeObjFloat(&w, @as(f64, meshF32(mesh, 1, i, 2, sf.endian) orelse 0));
                try w.print("\n", .{});
            }
        }
    }

    // faces, grouped by submesh (triangles and quads); each submesh gets
    // its own `g <name>_<N>` group line, matching UnityPy
    const has_n = nrm != null and nrm.?.format == 0 and nrm.?.dimension >= 3;
    const has_t = uv != null and uv.?.format == 0 and uv.?.dimension >= 2;
    var index_cursor: usize = 0;
    if (unityz.classes.fieldOf(v, "m_SubMeshes")) |subs| {
        if (subs == .array) {
            for (subs.array, 0..) |sub, si| {
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
                if (faces == 0) continue;
                try w.print("g {s}_{d}\n", .{ name, si });
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

/// Prints `v` with 9 significant digits, normal form, trailing zeros
/// trimmed - C's `%.9g`, the exact format UnityPy's OBJ exporter uses, so
/// mesh exports match theirs byte for byte. Values outside the normal-form
/// range (|v| >= 1e9 or < 1e-4) would use exponent form in C; mesh
/// coordinates and UVs never reach those, and they still print as a valid
/// decimal here.
/// Rounds `x` to the nearest integer with ties to even (Python's %.9g and
/// C's %g rounding), unlike Zig's @round which ties away from zero.
fn roundHalfEven(x: f64) f64 {
    var r = @round(x);
    if (@abs(x - r) == 0.5 and @mod(@abs(r), 2.0) == 1.0) {
        r = if (x < 0) r + 1.0 else r - 1.0;
    }
    return r;
}

fn writeObjFloat(w: *unityz.streams.Writer, v: f64) !void {
    if (v == 0) {
        // UnityPy prints the negated zero as "-0"; match it.
        const sign: []const u8 = if (std.math.signbit(v)) "-0" else "0";
        return w.print("{s}", .{sign});
    }
    const e = @floor(@log10(@abs(v)));
    // C's %g switches to exponent form when the exponent is < -4 or >= the
    // precision (9). Real meshes carry denormal-scale values (a creature
    // mesh's 8.57252764E-18 vertices), so both forms are exercised.
    if (e < -4 or e >= 9) {
        var exp: i32 = @intFromFloat(e);
        const p10 = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(exp)));
        var mant = roundHalfEven(v / p10 * 1e8) / 1e8;
        if (@abs(mant) >= 10.0) {
            mant /= 10.0;
            exp += 1;
        }
        const exp_sign: []const u8 = if (exp < 0) "-" else "+";
        try w.print("{d}E{s}{d:0>2}", .{ mant, exp_sign, @abs(exp) });
        return;
    }
    const scale = std.math.pow(f64, 10.0, 8 - e); // 10^(8-e)
    try w.print("{d}", .{roundHalfEven(v * scale) / scale});
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
/// Names a Unity binding attribute: the transform components map to the
/// first twelve values, everything else stays numeric.
fn bindingAttributeName(attr: i64) []const u8 {
    return switch (attr) {
        1 => "m_LocalPosition.x",
        2 => "m_LocalPosition.y",
        3 => "m_LocalPosition.z",
        4 => "m_LocalRotation.x",
        5 => "m_LocalRotation.y",
        6 => "m_LocalRotation.z",
        7 => "m_LocalScale.x",
        8 => "m_LocalScale.y",
        9 => "m_LocalScale.z",
        10 => "m_LocalEulerAnglesHint.x",
        11 => "m_LocalEulerAnglesHint.y",
        12 => "m_LocalEulerAnglesHint.z",
        else => "attribute",
    };
}

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

/// Structured Material export: name, shader reference, render queue, and
/// the saved properties (texture bindings with scale/offset, floats,
/// colors, ints). Null when the material has no saved-properties block.
fn materialJson(arena: std.mem.Allocator, v: unityz.value.Value) !?[]u8 {
    const props = unityz.classes.fieldOf(v, "m_SavedProperties") orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const w = &aw.writer;
    try w.writeAll("{\"name\":");
    try writeJsonString(w, fieldStr(v, "m_Name"));
    try w.writeAll(",\"shader\":");
    try w.print("{d}", .{if (unityz.classes.pptrField(v, "m_Shader")) |p| p.path_id else 0});
    if (unityz.classes.intField(v, "m_CustomRenderQueue")) |q| {
        try w.print(",\"render_queue\":{d}", .{q});
    }
    try w.writeAll(",\"textures\":[");
    if (unityz.classes.fieldOf(props, "m_TexEnvs")) |texenvs| {
        if (texenvs == .array) {
            var count: usize = 0;
            for (texenvs.array) |entry| {
                if (entry != .array or entry.array.len < 2) continue;
                const prop_name = switch (entry.array[0]) {
                    .string => |s| s,
                    else => "",
                };
                const val = entry.array[1];
                const tex = if (unityz.classes.pptrField(val, "m_Texture")) |t| t.path_id else 0;
                if (count != 0) try w.writeByte(',');
                try w.writeAll("{\"name\":");
                try writeJsonString(w, prop_name);
                try w.print(",\"texture\":{d}", .{tex});
                if (unityz.classes.fieldOf(val, "m_Scale")) |sc| {
                    try w.print(",\"scale\":[{d},{d}]", .{
                        if (unityz.classes.floatField(sc, "x")) |x| x else 1,
                        if (unityz.classes.floatField(sc, "y")) |y| y else 1,
                    });
                }
                if (unityz.classes.fieldOf(val, "m_Offset")) |off| {
                    try w.print(",\"offset\":[{d},{d}]", .{
                        unityz.classes.floatField(off, "x") orelse 0,
                        unityz.classes.floatField(off, "y") orelse 0,
                    });
                }
                try w.writeByte('}');
                count += 1;
            }
        }
    }
    try w.writeAll("],\"floats\":[");
    if (unityz.classes.fieldOf(props, "m_Floats")) |floats| {
        if (floats == .array) {
            var count: usize = 0;
            for (floats.array) |entry| {
                if (entry != .array or entry.array.len < 2) continue;
                const prop_name = switch (entry.array[0]) {
                    .string => |s| s,
                    else => "",
                };
                if (count != 0) try w.writeByte(',');
                try w.writeAll("{\"name\":");
                try writeJsonString(w, prop_name);
                try w.print(",\"value\":{d}}}", .{entry.array[1].asFloat() orelse 0});
                count += 1;
            }
        }
    }
    try w.writeAll("],\"colors\":[");
    if (unityz.classes.fieldOf(props, "m_Colors")) |colors| {
        if (colors == .array) {
            var count: usize = 0;
            for (colors.array) |entry| {
                if (entry != .array or entry.array.len < 2) continue;
                const prop_name = switch (entry.array[0]) {
                    .string => |s| s,
                    else => "",
                };
                if (count != 0) try w.writeByte(',');
                try w.writeAll("{\"name\":");
                try writeJsonString(w, prop_name);
                try w.writeAll(",\"value\":[");
                const val = entry.array[1];
                try w.print("{d},{d},{d},{d}]}}", .{
                    unityz.classes.floatField(val, "r") orelse 0,
                    unityz.classes.floatField(val, "g") orelse 0,
                    unityz.classes.floatField(val, "b") orelse 0,
                    unityz.classes.floatField(val, "a") orelse 1,
                });
                count += 1;
            }
        }
    }
    try w.writeAll("],\"ints\":[");
    if (unityz.classes.fieldOf(props, "m_Ints")) |ints| {
        if (ints == .array) {
            var count: usize = 0;
            for (ints.array) |entry| {
                if (entry != .array or entry.array.len < 2) continue;
                const prop_name = switch (entry.array[0]) {
                    .string => |s| s,
                    else => "",
                };
                if (count != 0) try w.writeByte(',');
                try w.writeAll("{\"name\":");
                try writeJsonString(w, prop_name);
                try w.print(",\"value\":{d}}}", .{entry.array[1].asInt() orelse 0});
                count += 1;
            }
        }
    }
    try w.writeAll("]}\n");
    const out = aw.toArrayList();
    return try arena.dupe(u8, out.items);
}

/// ShaderLab reconstruction of a Shader object: the parsed form's name,
/// properties, fallback, custom editor, subshader tags/LOD, and pass names,
/// plus a per-stage count of the compiled GPU programs (the original HLSL is
/// compiled away; UnityPy's shader export dumps raw bytes instead).
fn writeShaderText(arena: std.mem.Allocator, v: unityz.value.Value) ![]const u8 {
    // arena-owned buffer; see writeMeshObj for why it is never deinit'd
    var w: unityz.streams.Writer = .init(arena);
    const pf = unityz.classes.fieldOf(v, "m_ParsedForm") orelse return arena.dupe(u8, w.getWritten());
    const top_name = fieldStr(v, "m_Name");
    const real_name = if (top_name.len != 0) top_name else fieldStr(pf, "m_Name");
    try w.print("Shader \"{s}\"\n{{\n", .{real_name});

    // Properties: name, display name, type, and the serialized default.
    if (unityz.classes.fieldOf(pf, "m_PropInfo")) |pi| {
        if (unityz.classes.fieldOf(pi, "m_Props")) |props| {
            if (props == .array and props.array.len != 0) {
                try w.writeBytes("    Properties\n    {\n");
                for (props.array) |prop| try writeShaderProperty(&w, prop);
                try w.writeBytes("    }\n");
            }
        }
    }

    if (fieldStr(pf, "m_FallbackName").len != 0) {
        try w.print("    Fallback \"{s}\"\n", .{fieldStr(pf, "m_FallbackName")});
    }
    if (fieldStr(pf, "m_CustomEditorName").len != 0) {
        try w.print("    CustomEditor \"{s}\"\n", .{fieldStr(pf, "m_CustomEditorName")});
    }
    if (unityz.classes.fieldOf(pf, "m_KeywordNames")) |kw| {
        if (kw == .array and kw.array.len != 0) {
            try w.writeBytes("    // keywords:");
            for (kw.array) |k| {
                if (k != .string) continue;
                try w.print(" {s}", .{k.string});
            }
            try w.writeByte('\n');
        }
    }

    if (unityz.classes.fieldOf(pf, "m_SubShaders")) |subs| {
        if (subs == .array) {
            for (subs.array) |sub| {
                try w.writeBytes("\n    SubShader\n    {\n");
                try writeShaderTags(&w, sub, "        ");
                if (unityz.classes.intField(sub, "m_LOD")) |lod| {
                    if (lod != 0) try w.print("        LOD {d}\n", .{lod});
                }
                if (unityz.classes.fieldOf(sub, "m_Passes")) |passes| {
                    if (passes == .array) {
                        for (passes.array) |pass| {
                            try w.writeBytes("\n        Pass\n        {\n");
                            const state = unityz.classes.fieldOf(pass, "m_State");
                            const pname = if (state) |s| fieldStr(s, "m_Name") else "";
                            if (pname.len != 0) try w.print("            Name \"{s}\"\n", .{pname});
                            try writeShaderTags(&w, pass, "            ");
                            try writeShaderPrograms(&w, pass);
                            const ptype = unityz.classes.intField(pass, "m_Type") orelse 0;
                            if (ptype != 0) try w.print("            // pass type {d}\n", .{ptype});
                            try w.writeBytes("        }\n");
                        }
                    }
                }
                try w.writeBytes("    }\n");
            }
        }
    }
    try w.writeBytes("}\n");
    return arena.dupe(u8, w.getWritten());
}

/// Unity serialized property types (0=Color, 1=Vector, 2=Float, 3=Range,
/// 4=2D, 5=3D, 6=Cube, 7=2DArray, 8=CubeArray).
fn shaderPropTypeName(t: i64) []const u8 {
    return switch (t) {
        0 => "Color",
        1 => "Vector",
        2 => "Float",
        3 => "Range",
        4 => "2D",
        5 => "3D",
        6 => "Cube",
        7 => "2DArray",
        8 => "CubeArray",
        else => "Float",
    };
}

/// One `_Name ("Display", Type) = default` line.
fn writeShaderProperty(w: *unityz.streams.Writer, prop: unityz.value.Value) !void {
    const name = fieldStr(prop, "m_Name");
    const desc = fieldStr(prop, "m_Description");
    const t = unityz.classes.intField(prop, "m_Type") orelse 0;
    try w.print("        {s} (\"{s}\", {s}) = ", .{ name, desc, shaderPropTypeName(t) });
    if (t == 0 or t == 1) {
        // Color / Vector: the four m_DefValue[i] floats, read individually
        // because the fields may be sparse.
        try w.writeByte('(');
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            if (j != 0) try w.writeByte(',');
            var key_buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "m_DefValue[{d}]", .{j});
            const dv = unityz.classes.fieldOf(prop, key);
            try printShaderDefault(w, dv);
        }
        try w.writeByte(')');
    } else if (t >= 4 and t <= 8) {
        // texture: default name + dimension
        var def_name: []const u8 = "";
        var dim: i64 = 1;
        if (unityz.classes.fieldOf(prop, "m_DefTexture")) |dt| {
            def_name = fieldStr(dt, "m_DefaultName");
            dim = unityz.classes.intField(dt, "m_TexDim") orelse 1;
        }
        try w.print("\"{s}\" {{}} // dim {d}", .{ def_name, dim });
    } else {
        try printShaderDefault(w, unityz.classes.fieldOf(prop, "m_DefValue[0]"));
    }
    // attribute annotations, e.g. Toggle / Header / NoScaleOffset (an array
    // of plain strings, e.g. "Toggle(_FOO_ON)")
    if (unityz.classes.fieldOf(prop, "m_Attributes")) |attrs| {
        if (attrs == .array and attrs.array.len != 0) {
            for (attrs.array) |attr| {
                const aname = switch (attr) {
                    .string => |s| s,
                    else => fieldStr(attr, "m_Name"),
                };
                if (aname.len != 0) try w.print(" [{s}]", .{aname});
            }
        }
    }
    try w.writeByte('\n');
}

fn printShaderDefault(w: *unityz.streams.Writer, dv: ?unityz.value.Value) !void {
    if (dv) |d| {
        if (d.asFloat()) |f| {
            try w.print("{d}", .{f});
            return;
        }
        if (d == .int) try w.print("{d}", .{d.int});
    }
    try w.writeByte('0');
}

/// Writes `Tags { "k" = "v" }` when the value carries a `tags` array of
/// [key, value] pairs (the serialized form), indented.
fn writeShaderTags(w: *unityz.streams.Writer, owner: unityz.value.Value, indent: []const u8) !void {
    if (unityz.classes.fieldOf(owner, "m_Tags")) |tags| {
        if (unityz.classes.fieldOf(tags, "tags")) |pairs| {
            if (pairs == .array and pairs.array.len != 0) {
                try w.print("{s}Tags {{ ", .{indent});
                for (pairs.array, 0..) |pair, i| {
                    if (i != 0) try w.writeBytes(" ");
                    if (pair == .array and pair.array.len >= 2) {
                        try w.print("\"{s}\" = \"{s}\"", .{ switch (pair.array[0]) { .string => |s| s, else => "" }, switch (pair.array[1]) { .string => |s| s, else => "" } });
                    }
                }
                try w.writeBytes(" }\n");
            }
        }
    }
}

/// Per-pass compiled program table as comments: each stage that ships
/// sub-programs gets one line with the variant count (the decoded blobs are
/// available via `show`/`shader`).
fn writeShaderPrograms(w: *unityz.streams.Writer, pass: unityz.value.Value) !void {
    const stages = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "progVertex", .label = "vertex" },
        .{ .key = "progFragment", .label = "fragment" },
        .{ .key = "progGeometry", .label = "geometry" },
        .{ .key = "progHull", .label = "hull" },
        .{ .key = "progDomain", .label = "domain" },
    };
    var any = false;
    for (stages) |st| {
        if (unityz.classes.fieldOf(pass, st.key)) |prog| {
            if (unityz.classes.fieldOf(prog, "m_PlayerSubPrograms")) |subs| {
                if (subs == .array) {
                    var count: usize = 0;
                    for (subs.array) |platform| {
                        if (platform == .array) count += platform.array.len;
                    }
                    if (count != 0) {
                        if (!any) {
                            try w.writeBytes("            // compiled programs:\n");
                            any = true;
                        }
                        try w.print("            //   {s}: {d} variant(s)\n", .{ st.label, count });
                    }
                }
            }
        }
    }
}

/// Structured Shader export: name, keywords, and the parsed-form
/// subshader/pass structure (pass type, state name, LOD). Null when the
/// shader has no parsed form.
fn shaderJson(arena: std.mem.Allocator, v: unityz.value.Value) !?[]u8 {
    const pf = unityz.classes.fieldOf(v, "m_ParsedForm") orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const w = &aw.writer;
    // the top-level m_Name is often empty; the parsed form carries the real one
    const top_name = fieldStr(v, "m_Name");
    const real_name = if (top_name.len != 0) top_name else fieldStr(pf, "m_Name");
    try w.writeAll("{\"name\":");
    try writeJsonString(w, real_name);
    try w.writeAll(",\"keywords\":[");
    if (unityz.classes.fieldOf(pf, "m_KeywordNames")) |kw| {
        if (kw == .array) {
            var count: usize = 0;
            for (kw.array) |k| {
                if (k != .string) continue;
                if (count != 0) try w.writeByte(',');
                try writeJsonString(w, k.string);
                count += 1;
            }
        }
    }
    try w.writeAll("],\"subshaders\":[");
    if (unityz.classes.fieldOf(pf, "m_SubShaders")) |subs| {
        if (subs == .array) {
            var scount: usize = 0;
            for (subs.array) |sub| {
                const passes = unityz.classes.fieldOf(sub, "m_Passes") orelse continue;
                if (passes != .array) continue;
                if (scount != 0) try w.writeByte(',');
                try w.writeAll("{\"lod\":");
                try w.print("{d},\"passes\":[", .{unityz.classes.intField(sub, "m_LOD") orelse 0});
                var pcount: usize = 0;
                for (passes.array) |pass| {
                    const state = unityz.classes.fieldOf(pass, "m_State");
                    const pname = if (state) |s| fieldStr(s, "m_Name") else "";
                    if (pcount != 0) try w.writeByte(',');
                    try w.writeAll("{\"type\":");
                    try w.print("{d},\"name\":", .{unityz.classes.intField(pass, "m_Type") orelse 0});
                    try writeJsonString(w, pname);
                    try w.writeByte('}');
                    pcount += 1;
                }
                try w.writeAll("]}");
                scount += 1;
            }
        }
    }
    try w.writeAll("]}\n");
    const out = aw.toArrayList();
    return try arena.dupe(u8, out.items);
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
/// Best-effort `m_Name` of an object, read through its type tree. Empty
/// when the object has no usable tree, no name, or fails to read.
fn objectName(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, o: *const unityz.serialized.ObjectInfo) []const u8 {
    const type_index = o.type_index orelse return "";
    if (type_index >= sf.types.len) return "";
    const tree = sf.types[type_index].type_tree;
    if (tree.roots.len == 0) return "";
    const data = sf.objectData(o) orelse return "";
    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch return "";
    return unityz.classes.stringField(v, "m_Name") orelse "";
}

fn dumpObjectTable(arena: std.mem.Allocator, bytes: []const u8, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    try stdout.print("objects by id:\n", .{});
    for (sf.objects) |*o| {
        const name = className(o.class_id) orelse "Class";
        try stdout.print("  {d}  {s} (class {d})  start {d}  size {d}", .{ o.path_id, name, o.class_id, o.byte_start, o.byte_size });
        const nm = objectName(arena, &sf, o);
        if (nm.len != 0) try stdout.print("  \"{s}\"", .{nm});
        try stdout.writeByte('\n');
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
        const nm = objectName(arena, &sf, o);
        if (nm.len != 0) {
            try stdout.writeAll(",\"name\":");
            try writeJsonString(stdout, std.mem.trimEnd(u8, nm, "\x00"));
        }
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
    // The list is arena-backed like the messages it holds: nothing frees a
    // page_allocator buffer here, and a directory argument runs `verify`
    // once per file, so it would leak one buffer per file with failures.
    try report.failures.append(arena, .{ .path_id = path_id, .message = msg, .node = node });
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
    var trees_path: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, rest[i], "--trees") and i + 1 < rest.len) {
            trees_path = rest[i + 1];
            i += 1;
        } else {
            try stdout.print("unityz: unknown verify option '{s}'\n", .{rest[i]});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;

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
            // Non-serialized sibling nodes are the sidecar data streamed
            // references point into (mirrors extract's resolution domain).
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = n.path, .data = n.data });
                }
            }
            for (try diskSidecars(arena, path)) |sc| try sidecars.append(arena, sc);
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, n.path, sn)) continue;
                    }
                }
                if (!json) try stdout.print("node {s}:\n", .{n.path});
                _ = try verifySerializedBytesSidecars(arena, n.data, n.path, class_filter, if (path_filter) |pf| pf.path_id else null, json, &report, stdout, sidecars.items, basename(n.path), injected);
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
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = e.path, .data = e.data });
                }
            }
            for (try diskSidecars(arena, path)) |sc| try sidecars.append(arena, sc);
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (path_filter) |pf| {
                    if (pf.node) |sn| {
                        if (!std.mem.eql(u8, e.path, sn)) continue;
                    }
                }
                if (!json) try stdout.print("entry {s}:\n", .{e.path});
                _ = try verifySerializedBytesSidecars(arena, e.data, e.path, class_filter, if (path_filter) |pf| pf.path_id else null, json, &report, stdout, sidecars.items, basename(e.path), injected);
            }
        },
        .serialized => {
            if (path_filter) |pf| {
                if (pf.node != null) {
                    try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                    return;
                }
            }
            const sidecars = try diskSidecars(arena, path);
            _ = try verifySerializedBytesSidecars(arena, bytes, null, class_filter, if (path_filter) |pf| pf.path_id else null, json, &report, stdout, sidecars, basename(path), injected);
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
fn verifySerializedBytes(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, class_filter: ?i32, path_filter: ?i64, json: bool, report: *VerifyReport, stdout: *Io.Writer, own_name: []const u8, injected: ?*const InjectedTrees) !void {
    try verifySerializedBytesSidecars(arena, bytes, node, class_filter, path_filter, json, report, stdout, &.{}, own_name, injected);
}

/// `verifySerializedBytes` plus the sibling sidecar nodes (`sidecars`),
/// so streamed references (`m_StreamData`/`m_Resource`) can be checked
/// against the data they point into. Without sidecars (a bare serialized
/// file) only path-less same-file references are checked.
fn verifySerializedBytesSidecars(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, class_filter: ?i32, path_filter: ?i64, json: bool, report: *VerifyReport, stdout: *Io.Writer, sidecars: []const Sidecar, own_name: []const u8, injected: ?*const InjectedTrees) !void {
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
    var typeless_skipped: usize = 0;
    // An object's value tree and its re-serialized bytes are dead once the
    // byte comparison is done, but `arena` spans every object of every node
    // of the file, so taking them from it makes peak memory the sum of the
    // whole bundle rather than its largest object. Reset a scratch arena per
    // object instead. Failure messages keep coming from `arena`: they are
    // held by `report` and outlive the iteration that recorded them.
    var obj_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer obj_arena_state.deinit();
    const obj_arena = obj_arena_state.allocator();
    for (sf.objects) |*o| {
        defer _ = obj_arena_state.reset(.retain_capacity);
        if (class_filter) |cf| {
            if (o.class_id != cf) continue;
        }
        if (path_filter) |pf| {
            if (o.path_id != pf) continue;
        }
        const type_index = o.type_index orelse continue;
        if (type_index >= sf.types.len) continue;
        const data = sf.objectData(o) orelse continue;
        var tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) {
            if (injected) |inj| {
                if (injectedTreeFor(obj_arena, inj, &sf, own_name, o.class_id, data)) |it| {
                    tree = it.*;
                } else {
                    typeless_skipped += 1;
                    continue;
                }
            } else {
                typeless_skipped += 1;
                continue;
            }
        }
        checked += 1;
        report.checked += 1;

        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(obj_arena, &r, &tree.roots[0]) catch |err| {
            if (json) {
                try recordFailure(report, arena, node, o.path_id, "read failed: {s}", .{@errorName(err)});
            } else {
                try stdout.print("  object {d}: read failed: {s}\n", .{ o.path_id, @errorName(err) });
                report.failed += 1;
            }
            failed += 1;
            continue;
        };
        var w: unityz.streams.Writer = .init(obj_arena);
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
            if (!(try unityz.shader.verifyBlob(obj_arena, v))) {
                if (json) {
                    try recordFailure(report, arena, node, o.path_id, "shader sub-program blob does not round-trip", .{});
                } else {
                    try stdout.print("  object {d}: shader sub-program blob does not round-trip\n", .{o.path_id});
                    report.failed += 1;
                }
                failed += 1;
            }
        }
        // Streaming references must resolve: a path-less range must fit in
        // this file, a named range must fit inside the sibling sidecar
        // node it points into. An edit that breaks a reference (a cleared
        // m_StreamData whose pixels are still streamed, a too-small sidecar
        // patch) shows up here instead of failing at extract time.
        // Failure messages go to the outer `arena`, like the other records:
        // they are held by `report` and must outlive the per-object reset.
        failed += try scanStreamingRefs(arena, v, node, o.path_id, bytes.len, sidecars, report, stdout, json);
    }
    if (!json) try stdout.print("  {d} object(s) checked, {d} failed\n", .{ checked, failed });
    if (typeless_skipped != 0) {
        try stdout.print("  {d} object(s) skipped: this file has no type trees (Mono build); pass --trees <file.json> to decode them\n", .{typeless_skipped});
    }
}

/// Walks a value tree and checks every streaming reference
/// (`m_StreamData` in modern files, `m_Resource` in 5.x files) against
/// the data it points into. Returns how many failed.
fn scanStreamingRefs(arena: std.mem.Allocator, v: unityz.value.Value, node: ?[]const u8, path_id: i64, file_len: usize, sidecars: []const Sidecar, report: *VerifyReport, stdout: *Io.Writer, json: bool) !usize {
    var failures: usize = 0;
    switch (v) {
        .obj => |fields| {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, "m_StreamData") or std.mem.eql(u8, f.name, "m_Resource")) {
                    if (try checkStreamRef(arena, f.value, node, path_id, file_len, sidecars, report, stdout, json)) failures += 1;
                } else {
                    failures += try scanStreamingRefs(arena, f.value, node, path_id, file_len, sidecars, report, stdout, json);
                }
            }
        },
        .array => |items| {
            for (items) |item| failures += try scanStreamingRefs(arena, item, node, path_id, file_len, sidecars, report, stdout, json);
        },
        else => {},
    }
    return failures;
}

/// Checks one StreamingInfo value against the data it references. Returns
/// true when the reference is broken; false when it is fine or not a
/// streaming reference (no size, or a zero size: embedded or cleared).
/// Mirrors extract's resolution rule: the first sidecar whose basename
/// matches decides, and the range must fit inside it.
fn checkStreamRef(arena: std.mem.Allocator, info: unityz.value.Value, node: ?[]const u8, path_id: i64, file_len: usize, sidecars: []const Sidecar, report: *VerifyReport, stdout: *Io.Writer, json: bool) !bool {
    const fields = switch (info) {
        .obj => |f| f,
        else => return false,
    };
    var offset: u64 = 0;
    var size: u64 = 0;
    var path: []const u8 = "";
    var have_size = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "offset") or std.mem.eql(u8, f.name, "m_Offset")) {
            offset = std.math.cast(u64, f.value.asInt() orelse continue) orelse continue;
        } else if (std.mem.eql(u8, f.name, "size") or std.mem.eql(u8, f.name, "m_Size")) {
            size = std.math.cast(u64, f.value.asInt() orelse continue) orelse continue;
            have_size = true;
        } else if (std.mem.eql(u8, f.name, "path") or std.mem.eql(u8, f.name, "m_Source")) {
            path = switch (f.value) {
                .string => |s| s,
                else => continue,
            };
        }
    }
    if (!have_size or size == 0) return false;
    if (path.len == 0) {
        if (offset + size <= file_len) return false;
        if (json) {
            try recordFailure(report, arena, node, path_id, "streamed range {d}+{d} exceeds file length {d}", .{ offset, size, file_len });
        } else {
            try stdout.print("  object {d}: streamed range {d}+{d} exceeds file length {d}\n", .{ path_id, offset, size, file_len });
            report.failed += 1;
        }
        return true;
    }
    const base = basename(path);
    for (sidecars) |sc| {
        if (!std.mem.eql(u8, basename(sc.path), base)) continue;
        if (offset + size <= sc.data.len) return false;
        if (json) {
            try recordFailure(report, arena, node, path_id, "streamed range {d}+{d} exceeds sidecar {s} ({d} bytes)", .{ offset, size, sc.path, sc.data.len });
        } else {
            try stdout.print("  object {d}: streamed range {d}+{d} exceeds sidecar {s} ({d} bytes)\n", .{ path_id, offset, size, sc.path, sc.data.len });
            report.failed += 1;
        }
        return true;
    }
    if (json) {
        try recordFailure(report, arena, node, path_id, "no sidecar node named {s}", .{base});
    } else {
        try stdout.print("  object {d}: no sidecar node named {s}\n", .{ path_id, base });
        report.failed += 1;
    }
    return true;
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
fn shaderObjectValue(arena: std.mem.Allocator, sf: *const unityz.serialized.SerializedFile, o: *const unityz.serialized.ObjectInfo, own_name: []const u8, injected: ?*const InjectedTrees) ?unityz.value.Value {
    const ti = o.type_index orelse return null;
    if (ti >= sf.types.len) return null;
    var tree = sf.types[ti].type_tree;
    if (tree.roots.len == 0) {
        if (injected) |inj| {
            const od0 = sf.objectData(o) orelse return null;
            if (injectedTreeFor(arena, inj, sf, own_name, o.class_id, od0)) |it| {
                tree = it.*;
            } else return null;
        } else return null;
    }
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
    own_name: []const u8,
    injected: ?*const InjectedTrees,
) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch return;

    // Per-shader skinning summary.
    for (sf.objects) |*o| {
        if (o.class_id != 48) continue;
        const v = shaderObjectValue(arena, &sf, o, own_name, injected) orelse continue;
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
        const rv = shaderObjectValue(arena, &sf, o, own_name, injected) orelse continue;
        const mats = unityz.classes.fieldOf(rv, "m_Materials") orelse continue;
        const arr = switch (mats) {
            .array => |a| a,
            else => continue,
        };
        for (arr) |mat_ref| {
            const mp = asPPtr(mat_ref) orelse continue;
            if (mp.file_id != 0 or mp.path_id == 0) continue; // external or null
            const mv = readObjectValue(arena, &sf, mp.path_id, "", null) orelse continue;
            const sp = unityz.classes.pptrField(mv, "m_Shader") orelse continue;
            if (sp.file_id != 0 or sp.path_id == 0) continue;
            const sv = readObjectValue(arena, &sf, sp.path_id, "", null) orelse continue;
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
    var trees_path: ?[]const u8 = null;
    var ai: usize = 0;
    while (ai < rest.len) : (ai += 1) {
        const arg = rest[ai];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--trees") and ai + 1 < rest.len) {
            trees_path = rest[ai + 1];
            ai += 1;
        } else {
            try stdout.print("unityz: unknown skin option '{s}'\n", .{arg});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;

    var shaders: std.ArrayList(ShaderSummary) = .empty;
    defer shaders.deinit(arena);
    var failures: std.ArrayList(SkinFailure) = .empty;
    defer failures.deinit(arena);

    switch (unityz.container.sniff(bytes).container) {
        .serialized => try skinSerializedBytes(arena, bytes, null, &shaders, &failures, basename(path), injected),
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try diag(json, stdout, "{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                if (json) try stdout.print("{{\"shaders\":[],\"failures\":[]}}\n", .{});
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try skinSerializedBytes(arena, n.data, n.path, &shaders, &failures, basename(n.path), injected);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try diag(json, stdout, "{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                if (json) try stdout.print("{{\"shaders\":[],\"failures\":[]}}\n", .{});
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try skinSerializedBytes(arena, e.data, e.path, &shaders, &failures, basename(e.path), injected);
            }
        },
        .archive => {
            try diag(json, stdout, "{s}: UnityArchive files are not supported yet\n", .{path});
            if (json) try stdout.print("{{\"shaders\":[],\"failures\":[]}}\n", .{});
            return;
        },
        .unknown => {
            try diag(json, stdout, "{s}: not a recognized Unity asset file\n", .{path});
            if (json) try stdout.print("{{\"shaders\":[],\"failures\":[]}}\n", .{});
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

/// Routes a diagnostic to stderr while `--json` is in effect, so the
/// document a script parses off stdout stays well-formed; without `--json`
/// it stays on stdout with the rest of the human-readable report.
fn diag(json: bool, stdout: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    if (!json) return stdout.print(fmt, args);
    var buf: [512]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io_global.io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch {};
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
    defer dir.close(io);
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
        // `entry.name` borrows the iterator's buffer and is overwritten by the
        // next `next()`, so keep the copy inside `full` instead.
        try files_a.append(std.heap.page_allocator, .{ .name = full[dir_a.len + 1 ..], .hash = std.hash.Wyhash.hash(0, data), .size = data.len });
        // Only the hash and length survive the comparison, so the file bytes
        // must not be held: a large tree would otherwise pin every byte of
        // both directories in memory at once.
        std.heap.page_allocator.free(data);
    }

    var dir2 = std.Io.Dir.cwd().openDir(io, dir_b, .{ .iterate = true }) catch |err| {
        try stdout.print("unityz: {s}: {s}\n", .{ dir_b, @errorName(err) });
        return;
    };
    defer dir2.close(io);
    var it2 = dir2.iterate();
    while (try it2.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_b, entry.name });
        const data = std.Io.Dir.cwd().readFileAlloc(io, full, std.heap.page_allocator, .unlimited) catch |err| {
            warnToStderr(full, err);
            continue;
        };
        try files_b.append(std.heap.page_allocator, .{ .name = full[dir_b.len + 1 ..], .hash = std.hash.Wyhash.hash(0, data), .size = data.len });
        std.heap.page_allocator.free(data);
    }

    var unchanged: usize = 0;
    var changed: usize = 0;
    var only_a: usize = 0;
    var only_b: usize = 0;
    var reported: usize = 0;
    var changed_names: std.ArrayList([]const u8) = .empty;
    var only_a_names: std.ArrayList([]const u8) = .empty;
    var only_b_names: std.ArrayList([]const u8) = .empty;
    // Index by name so matching is linear; the nested scan it replaces was
    // quadratic in the file count, with a string compare per pair.
    var b_by_name: std.StringHashMapUnmanaged(DirFile) = .empty;
    defer b_by_name.deinit(std.heap.page_allocator);
    var a_names: std.StringHashMapUnmanaged(void) = .empty;
    defer a_names.deinit(std.heap.page_allocator);
    for (files_b.items) |fb| try b_by_name.put(std.heap.page_allocator, fb.name, fb);
    for (files_a.items) |fa| try a_names.put(std.heap.page_allocator, fa.name, {});

    for (files_a.items) |fa| {
        var matched = false;
        if (b_by_name.get(fa.name)) |fb| {
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
                    // directory diffs keep pixel/audio as text diagnostics
                    // (on stderr in --json mode); the --json stats arrays
                    // cover single-file diffs
                    var diag_out: *Io.Writer = stdout;
                    var err_buf: [1024]u8 = undefined;
                    var err_writer: Io.File.Writer = undefined;
                    if (json) {
                        err_writer = .init(.stderr(), io, &err_buf);
                        diag_out = &err_writer.interface;
                    }
                    var pixel_stats: std.ArrayList(PixelStat) = .empty;
                    var audio_stats: std.ArrayList(AudioStat) = .empty;
                    if (pixels) {
                        try diag_out.print("  pixels in {s}:\n", .{fa.name});
                        try pixelPass(arena_state.allocator(), data_a, data_b, class_filter, diag_out, &pixel_stats);
                    }
                    if (audio) {
                        try diag_out.print("  audio in {s}:\n", .{fa.name});
                        try audioPass(arena_state.allocator(), data_a, data_b, class_filter, diag_out, &audio_stats);
                    }
                    if (json) try err_writer.flush();
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
        if (!a_names.contains(fb.name)) {
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
const Fp = struct { path_id: i64, class_id: i32, hash: u64, size: u32, node: ?[]const u8 = null, name: []const u8 = "" };

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
                try diag(json, stdout, "{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                if (json) try stdout.print("[]\n", .{});
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
                try diag(json, stdout, "{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                if (json) try stdout.print("[]\n", .{});
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
                    try diag(json, stdout, "unityz: node selector not valid for a serialized file\n", .{});
                    if (json) try stdout.print("[]\n", .{});
                    return;
                }
            }
            try hashSerializedBytes(arena, bytes, null, if (path_filter) |pf| pf.path_id else null, class_filter, json, &entries, stdout);
        },
        else => {
            try diag(json, stdout, "{s}: hash requires a serialized file, bundle, or webfile\n", .{path});
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
            try stdout.print("\"path_id\":{d},\"hash\":\"{x:0>16}\",\"class\":{d},\"size\":{d}", .{ fp.path_id, fp.hash, fp.class_id, fp.size });
            if (fp.name.len != 0) {
                try stdout.writeAll(",\"name\":");
                try writeJsonString(stdout, std.mem.trimEnd(u8, fp.name, "\x00"));
            }
            try stdout.writeByte('}');
        }
        try stdout.print("]\n", .{});
    }
}

fn hashSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, path_filter: ?i64, class_filter: ?i32, json: bool, entries: *std.ArrayList(Fp), stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try diag(json, stdout, "  serialized parse failed: {s}\n", .{@errorName(err)});
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
                .name = objectName(arena, &sf, o),
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
fn pixelPass(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, class_filter: ?i32, stdout: *Io.Writer, stats: *std.ArrayList(PixelStat)) !void {
    var a_list: std.ArrayList(Fp) = .empty;
    var b_list: std.ArrayList(Fp) = .empty;
    try collectFingerprints(arena, a_bytes, class_filter, null, &a_list);
    try collectFingerprints(arena, b_bytes, class_filter, null, &b_list);
    var cache_a: SpriteCache = .{};
    var cache_b: SpriteCache = .{};
    for (a_list.items) |fa| {
        for (b_list.items) |fb| {
            if (fb.path_id != fa.path_id or !sameNode(fb.node, fa.node)) continue;
            switch (fa.class_id) {
                28 => if (try diffTexturePixels(arena, a_bytes, b_bytes, fa, &cache_a, &cache_b, stdout)) |st| {
                    if (st.diff_pixels != 0) try stats.append(arena, st);
                },
                213 => if (try diffSpritePixels(arena, a_bytes, b_bytes, fa, &cache_a, &cache_b, stdout)) |st| {
                    if (st.diff_pixels != 0) try stats.append(arena, st);
                },
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
fn audioPass(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, class_filter: ?i32, stdout: *Io.Writer, stats: *std.ArrayList(AudioStat)) !void {
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
                try stats.append(arena, .{ .path_id = fa.path_id, .size_a = sa.?.len, .size_b = sb.?.len });
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
                try stats.append(arena, .{ .path_id = fa.path_id, .size_a = sa.?.len, .size_b = sb.?.len, .first_diff = first });
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

/// One `diff --fields` entry for the JSON report.
const FieldDiff = struct {
    path_id: i64,
    path: []const u8,
    old: []const u8,
    new: []const u8,
};

/// `diff --fields`: reports the exact fields that changed inside a
/// changed object, by decoding both value trees and walking them. Field
/// paths look like `m_LocalPosition.x` or `m_Children[2]`. With
/// `collect` set (json mode) the entries are appended instead of printed.
fn diffObjectFields(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, fa: Fp, collect: ?*std.ArrayList(FieldDiff), stdout: *Io.Writer) !void {
    const va = try findObjectValue(arena, a_bytes, fa);
    const vb = try findObjectValue(arena, b_bytes, fa);
    if (va == null or vb == null) return;
    var path_buf: [256]u8 = undefined;
    var reported: usize = 0;
    if (collect == null) {
        const cname = className(fa.class_id) orelse "Class";
        try stdout.print("  fields: object {d} ({s}):\n", .{ fa.path_id, cname });
    }
    try diffValueTree(va.?, vb.?, fa.path_id, &path_buf, 0, &reported, collect, stdout);
}

/// Recursive value-tree comparison; `buf[0..len]` is the current field
/// path. Reports at most 10 differing leaves.
fn diffValueTree(a: unityz.value.Value, b: unityz.value.Value, path_id: i64, buf: *[256]u8, len: usize, reported: *usize, collect: ?*std.ArrayList(FieldDiff), stdout: *Io.Writer) !void {
    if (reported.* >= 10) return;
    const path = buf[0..len];
    switch (a) {
        .obj => |af| {
            if (b != .obj) return reportLeaf(a, b, path_id, path, reported, collect, stdout);
            for (af) |f| {
                if (reported.* >= 10) return;
                const bv = unityz.classes.fieldOf(b, f.name) orelse {
                    try emitField(path_id, path, f.name, try renderValue(f.value), "<absent>", reported, collect, stdout);
                    continue;
                };
                const new_len = try appendPath(buf, len, f.name);
                try diffValueTree(f.value, bv, path_id, buf, new_len, reported, collect, stdout);
            }
            // fields present only in b
            for (b.obj) |f| {
                if (reported.* >= 10) return;
                if (unityz.classes.fieldOf(a, f.name) == null) {
                    try emitField(path_id, path, f.name, "<absent>", try renderValue(f.value), reported, collect, stdout);
                }
            }
        },
        .array => |aa| {
            if (b != .array or aa.len != b.array.len) return reportLeaf(a, b, path_id, path, reported, collect, stdout);
            for (aa, 0..) |x, i| {
                if (reported.* >= 10) return;
                const new_len = try appendIndex(buf, len, i);
                try diffValueTree(x, b.array[i], path_id, buf, new_len, reported, collect, stdout);
            }
        },
        else => {
            if (!valuesEqual(a, b)) try reportLeaf(a, b, path_id, path, reported, collect, stdout);
        },
    }
}

/// Renders a leaf value as a short JSON string for the report.
fn renderValue(v: unityz.value.Value) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(std.heap.page_allocator, &buf);
    try unityz.value.jsonWrite(v, &aw.writer);
    const out = aw.toArrayList();
    return try std.heap.page_allocator.dupe(u8, truncateLeaf(out.items));
}

fn emitField(path_id: i64, path: []const u8, name: []const u8, old: []const u8, new: []const u8, reported: *usize, collect: ?*std.ArrayList(FieldDiff), stdout: *Io.Writer) !void {
    const full_path = if (path.len == 0)
        try std.heap.page_allocator.dupe(u8, name)
    else
        try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{s}", .{ path, name });
    if (collect) |c| {
        try c.append(std.heap.page_allocator, .{ .path_id = path_id, .path = full_path, .old = old, .new = new });
    } else {
        try stdout.print("    {s} ({s} -> {s})\n", .{ full_path, old, new });
    }
    reported.* += 1;
}

fn reportLeaf(a: unityz.value.Value, b: unityz.value.Value, path_id: i64, path: []const u8, reported: *usize, collect: ?*std.ArrayList(FieldDiff), stdout: *Io.Writer) !void {
    const old = try renderValue(a);
    const new = try renderValue(b);
    if (collect) |c| {
        try c.append(std.heap.page_allocator, .{ .path_id = path_id, .path = try std.heap.page_allocator.dupe(u8, path), .old = old, .new = new });
    } else {
        try stdout.print("    {s} ({s} -> {s})\n", .{ path, old, new });
    }
    reported.* += 1;
}

fn valuesEqual(a: unityz.value.Value, b: unityz.value.Value) bool {
    if (a.asFloat()) |af| {
        if (b.asFloat()) |bf| return af == bf;
        return false;
    }
    if (a == .string and b == .string) return std.mem.eql(u8, a.string, b.string);
    if (a == .bytes and b == .bytes) return std.mem.eql(u8, a.bytes, b.bytes);
    if (a == .pptr and b == .pptr) return a.pptr.file_id == b.pptr.file_id and a.pptr.path_id == b.pptr.path_id;
    if (a == .bool and b == .bool) return a.bool == b.bool;
    return false;
}

fn appendPath(buf: *[256]u8, len: usize, name: []const u8) !usize {
    if (len == 0) {
        const out = try std.fmt.bufPrint(buf[0..], "{s}", .{name});
        return out.len;
    }
    const out = try std.fmt.bufPrint(buf[len..], ".{s}", .{name});
    return len + out.len;
}

fn appendIndex(buf: *[256]u8, len: usize, index: usize) !usize {
    const out = try std.fmt.bufPrint(buf[len..], "[{d}]", .{index});
    return len + out.len;
}

fn truncateLeaf(s: []const u8) []const u8 {
    if (s.len <= 72) return s;
    return s[0..72];
}

/// Reads an object's value tree from a file (container-aware), or null
/// when absent or unreadable.
fn findObjectValue(arena: std.mem.Allocator, bytes: []const u8, fa: Fp) !?unityz.value.Value {
    var out: ?unityz.value.Value = null;
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = try unityz.bundle.parse(arena, bytes);
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                if (fa.node) |sn| {
                    if (!std.mem.eql(u8, n.path, sn)) continue;
                }
                out = try findObjectValueInSerialized(arena, n.data, fa.path_id);
                if (out != null) return out;
            }
        },
        .webfile => {
            const wf = try unityz.webfile.parse(arena, bytes);
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                if (fa.node) |sn| {
                    if (!std.mem.eql(u8, e.path, sn)) continue;
                }
                out = try findObjectValueInSerialized(arena, e.data, fa.path_id);
                if (out != null) return out;
            }
        },
        .serialized => {
            if (fa.node != null) return null;
            out = try findObjectValueInSerialized(arena, bytes, fa.path_id);
        },
        else => {},
    }
    return out;
}

fn findObjectValueInSerialized(arena: std.mem.Allocator, bytes: []const u8, path_id: i64) !?unityz.value.Value {
    const sf = unityz.serialized.parse(arena, bytes) catch return null;
    const o = for (sf.objects) |*oo| {
        if (oo.path_id == path_id) break oo;
    } else return null;
    const data = sf.objectData(o) orelse return null;
    const ti = o.type_index orelse return null;
    if (ti >= sf.types.len) return null;
    const tree = sf.types[ti].type_tree;
    if (tree.roots.len == 0) return null;
    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    return unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch null;
}

/// `diff --pixels`: decodes a Texture2D object in both files and reports
/// pixel-level differences (per-channel differing-byte counts and the
/// maximum per-channel delta). Node-aware: `fa.node` selects the container
/// entry. Pixels may be embedded in the object, streamed inside the same
/// serialized file, or streamed from a sibling `.resS` / `.resource`
/// sidecar node inside the same container, all resolved here.
fn diffTexturePixels(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, fa: Fp, cache_a: *SpriteCache, cache_b: *SpriteCache, stdout: *Io.Writer) !?PixelStat {
    const rgba_a = try findObjectRgba(arena, a_bytes, fa, .texture, cache_a);
    const rgba_b = try findObjectRgba(arena, b_bytes, fa, .texture, cache_b);
    if (rgba_a == null or rgba_b == null) {
        try stdout.print("    (pixels: object {d} texture could not be decoded in one or both files)\n", .{fa.path_id});
        return null;
    }
    const a = rgba_a.?;
    const b = rgba_b.?;
    if (a.w != b.w or a.h != b.h) {
        try stdout.print("    (pixels: object {d} size differs {d}x{d} vs {d}x{d})\n", .{ fa.path_id, a.w, a.h, b.w, b.h });
        return null;
    }
    return diffRgbaPixels(fa, a.data, b.data, a.w, a.h, stdout);
}

/// `diff --pixels` for a Sprite: renders both sprites (crop rect, packed
/// rotation, alpha-texture merge, tight/polygon mesh) and compares the
/// RGBA. Object bytes are unchanged when only the streamed atlas pixels
/// change, so this is the only diff signal that sees those edits.
fn diffSpritePixels(arena: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8, fa: Fp, cache_a: *SpriteCache, cache_b: *SpriteCache, stdout: *Io.Writer) !?PixelStat {
    // each file gets its own cache: the atlas memoization is per serialized
    // file, so sharing one cache across both files made file B's sprites
    // resolve through file A's atlas data and rendered them identically
    const rgba_a = try findObjectRgba(arena, a_bytes, fa, .sprite, cache_a);
    const rgba_b = try findObjectRgba(arena, b_bytes, fa, .sprite, cache_b);
    if (rgba_a == null or rgba_b == null) {
        try stdout.print("    (pixels: object {d} sprite could not be rendered in one or both files)\n", .{fa.path_id});
        return null;
    }
    const a = rgba_a.?;
    const b = rgba_b.?;
    if (a.w != b.w or a.h != b.h) {
        try stdout.print("    (pixels: object {d} size differs {d}x{d} vs {d}x{d})\n", .{ fa.path_id, a.w, a.h, b.w, b.h });
        return null;
    }
    return diffRgbaPixels(fa, a.data, b.data, a.w, a.h, stdout);
}

/// Shared per-channel RGBA comparison; `width`/`height` describe both
/// buffers (they must have the same length). Prints the text line and
/// returns the structured stat for `diff --json`.
fn diffRgbaPixels(fa: Fp, a: []const u8, b: []const u8, width: u32, height: u32, stdout: *Io.Writer) !?PixelStat {
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
    return .{ .path_id = fa.path_id, .class_id = fa.class_id, .width = width, .height = height, .diff_pixels = diff_pixels, .max_delta = max_delta };
}

/// One differing object's pixel stats, for `diff --json --pixels`.
const PixelStat = struct {
    path_id: i64,
    class_id: i32,
    width: u32,
    height: u32,
    diff_pixels: usize,
    max_delta: [4]u32,
};

/// One differing clip's stream stats, for `diff --json --audio`.
const AudioStat = struct {
    path_id: i64,
    size_a: usize,
    size_b: usize,
    /// First differing byte offset; null when the sizes differ.
    first_diff: ?usize = null,
};

test "diffRgbaPixels counts per-channel diffs and max deltas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    const a = [_]u8{ 10, 20, 30, 40, 255, 255, 255, 255 };
    const b = [_]u8{ 12, 20, 35, 44, 250, 245, 255, 255 };
    _ = try diffRgbaPixels(.{ .path_id = 7, .class_id = 28, .hash = 0, .size = 0 }, &a, &b, 2, 1, &aw.writer);
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
fn findObjectRgba(arena: std.mem.Allocator, bytes: []const u8, fa: Fp, kind: RgbaKind, cache: *SpriteCache) !?Rgba {
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
                out = try findObjectRgbaInSerialized(arena, n.data, fa.path_id, sidecars.items, kind, cache);
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
                out = try findObjectRgbaInSerialized(arena, e.data, fa.path_id, sidecars.items, kind, cache);
                if (out != null) return out;
            }
        },
        .serialized => {
            if (fa.node != null) return null;
            out = try findObjectRgbaInSerialized(arena, bytes, fa.path_id, &.{}, kind, cache);
        },
        else => {},
    }
    return out;
}

fn findObjectRgbaInSerialized(arena: std.mem.Allocator, bytes: []const u8, path_id: i64, sidecars: []const Sidecar, kind: RgbaKind, cache: *SpriteCache) !?Rgba {
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
            const rr = renderSprite(arena, &sf, sidecars, cache, v, path_id, "", null) orelse return null;
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
    var fields = false;
    var class_filter: ?i32 = null;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, rest[i], "--pixels")) {
            pixels = true;
        } else if (std.mem.eql(u8, rest[i], "--audio")) {
            audio = true;
        } else if (std.mem.eql(u8, rest[i], "--fields")) {
            fields = true;
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
    var field_diffs: std.ArrayList(FieldDiff) = .empty;
    // Index both sides by (path_id, node). The nested scans this replaces
    // were quadratic in the object count, which bites on bundles holding
    // thousands of objects.
    var b_by_key: FpMap = .empty;
    defer b_by_key.deinit(std.heap.page_allocator);
    var a_keys: FpMap = .empty;
    defer a_keys.deinit(std.heap.page_allocator);
    // First entry wins, matching the first-match semantics of the scans.
    for (b_list.items) |fb| {
        const gop = try b_by_key.getOrPut(std.heap.page_allocator, .{ .path_id = fb.path_id, .node = fb.node });
        if (!gop.found_existing) gop.value_ptr.* = fb;
    }
    for (a_list.items) |fa| {
        const gop = try a_keys.getOrPut(std.heap.page_allocator, .{ .path_id = fa.path_id, .node = fa.node });
        if (!gop.found_existing) gop.value_ptr.* = fa;
    }

    for (a_list.items) |fa| {
        var matched = false;
        if (b_by_key.get(.{ .path_id = fa.path_id, .node = fa.node })) |fb| {
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
                if (fields) try diffObjectFields(arena, bytes, other_bytes, fa, if (json) &field_diffs else null, stdout);
            } else {
                unchanged += 1;
            }
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
        if (!a_keys.contains(.{ .path_id = fb.path_id, .node = fb.node })) {
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
    // Raw container nodes (sidecar .resS/.resource payloads) are not
    // objects, so the fingerprint pass above never sees them; an edit that
    // patches a raw node (the node-path patch form) must still show up in
    // the diff. Compare the non-serialized nodes of both files by path and
    // content hash, folding them into the same changed/only counts.
    var raw_a: std.ArrayList(Fp) = .empty;
    var raw_b: std.ArrayList(Fp) = .empty;
    try collectRawNodes(arena, bytes, &raw_a);
    try collectRawNodes(arena, other_bytes, &raw_b);
    for (raw_a.items) |fa| {
        var matched = false;
        for (raw_b.items) |fb| {
            if (!std.mem.eql(u8, fa.node.?, fb.node.?)) continue;
            matched = true;
            if (fb.hash != fa.hash or fb.size != fa.size) {
                changed += 1;
                try changed_objs.append(std.heap.page_allocator, fa);
                if (!json and reported < 10) {
                    try stdout.print("  changed: node {s}\n", .{fa.node.?});
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
                try stdout.print("  only in {s}: node {s}\n", .{ path, fa.node.? });
                reported += 1;
            }
        }
    }
    for (raw_b.items) |fb| {
        var matched = false;
        for (raw_a.items) |fa| {
            if (std.mem.eql(u8, fa.node.?, fb.node.?)) {
                matched = true;
                break;
            }
        }
        if (!matched) {
            only_b += 1;
            try only_b_objs.append(std.heap.page_allocator, fb);
            if (!json and reported < 10) {
                try stdout.print("  only in {s}: node {s}\n", .{ rest[0], fb.node.? });
                reported += 1;
            }
        }
    }
    var pixel_stats: std.ArrayList(PixelStat) = .empty;
    var audio_stats: std.ArrayList(AudioStat) = .empty;
    // in --json mode the pixel/audio text diagnostics go to stderr so
    // stdout carries only the JSON document
    var diag_out: *Io.Writer = stdout;
    var err_buf: [1024]u8 = undefined;
    var err_writer: Io.File.Writer = undefined;
    if (json) {
        err_writer = .init(.stderr(), io_global.io, &err_buf);
        diag_out = &err_writer.interface;
    }
    if (pixels) try pixelPass(arena, bytes, other_bytes, class_filter, diag_out, &pixel_stats);
    if (audio) try audioPass(arena, bytes, other_bytes, class_filter, diag_out, &audio_stats);
    if (json) try err_writer.flush();
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
        try stdout.print(",\"pixels\":", .{});
        try writePixelStats(stdout, pixel_stats.items);
        try stdout.print(",\"audio\":", .{});
        try writeAudioStats(stdout, audio_stats.items);
        try stdout.print(",\"fields\":", .{});
        try writeFieldDiffs(stdout, field_diffs.items);
        try stdout.print("}}\n", .{});
    } else {
        try stdout.print("{d} unchanged, {d} changed, {d} only in {s}, {d} only in {s}\n", .{ unchanged, changed, only_a, path, only_b, rest[0] });
    }
}

/// JSON array of `{"path_id":N,"path":"...","old":"...","new":"..."}`
/// for the exact fields that changed inside changed objects.
fn writeFieldDiffs(stdout: *Io.Writer, items: []const FieldDiff) !void {
    try stdout.writeByte('[');
    for (items, 0..) |it, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try stdout.print("{{\"path_id\":{d},\"path\":", .{it.path_id});
        try writeJsonString(stdout, it.path);
        try stdout.writeAll(",\"old\":");
        try writeJsonString(stdout, it.old);
        try stdout.writeAll(",\"new\":");
        try writeJsonString(stdout, it.new);
        try stdout.writeByte('}');
    }
    try stdout.writeByte(']');
}

/// JSON array of `{"path_id":N,"class":N,"width":W,"height":H,
/// "diff_pixels":N,"max_delta":[R,G,B,A]}` for objects whose pixels
/// differ.
fn writePixelStats(stdout: *Io.Writer, items: []const PixelStat) !void {
    try stdout.writeByte('[');
    for (items, 0..) |it, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try stdout.print("{{\"path_id\":{d},\"class\":{d},\"width\":{d},\"height\":{d},\"diff_pixels\":{d},\"max_delta\":[{d},{d},{d},{d}]}}", .{ it.path_id, it.class_id, it.width, it.height, it.diff_pixels, it.max_delta[0], it.max_delta[1], it.max_delta[2], it.max_delta[3] });
    }
    try stdout.writeByte(']');
}

/// JSON array of `{"path_id":N,"size_a":A,"size_b":B,"first_diff":K}`
/// for clips whose streams differ (`first_diff` omitted when the sizes
/// differ).
fn writeAudioStats(stdout: *Io.Writer, items: []const AudioStat) !void {
    try stdout.writeByte('[');
    for (items, 0..) |it, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try stdout.print("{{\"path_id\":{d},\"size_a\":{d},\"size_b\":{d}", .{ it.path_id, it.size_a, it.size_b });
        if (it.first_diff) |fd| {
            try stdout.print(",\"first_diff\":{d}", .{fd});
        }
        try stdout.writeByte('}');
    }
    try stdout.writeByte(']');
}

/// Prints a JSON array of `{"path_id":N,"class":N}` objects.
/// Identity of an object across two files: its path id, qualified by the
/// container node it came from.
const FpKey = struct { path_id: i64, node: ?[]const u8 };

const FpKeyContext = struct {
    pub fn hash(_: FpKeyContext, k: FpKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.path_id));
        if (k.node) |n| h.update(n);
        return h.final();
    }
    pub fn eql(_: FpKeyContext, a: FpKey, b: FpKey) bool {
        return a.path_id == b.path_id and sameNode(a.node, b.node);
    }
};

const FpMap = std.HashMapUnmanaged(FpKey, Fp, FpKeyContext, std.hash_map.default_max_load_percentage);

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

/// Appends one fingerprint per non-serialized container node (a .resS /
/// .resource sidecar): the node path as the key, the content hash as the
/// fingerprint. `diff` uses these so a raw-node edit (the node-path patch
/// form) is reported instead of silently passing as "unchanged".
fn collectRawNodes(arena: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(Fp)) !void {
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = try unityz.bundle.parse(arena, bytes);
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container == .serialized) continue;
                try out.append(arena, .{
                    .path_id = 0,
                    .class_id = -1,
                    .hash = std.hash.Wyhash.hash(0, n.data),
                    .size = @intCast(n.data.len),
                    .node = n.path,
                    .name = n.path,
                });
            }
        },
        .webfile => {
            const wf = try unityz.webfile.parse(arena, bytes);
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container == .serialized) continue;
                try out.append(arena, .{
                    .path_id = 0,
                    .class_id = -1,
                    .hash = std.hash.Wyhash.hash(0, e.data),
                    .size = @intCast(e.data.len),
                    .node = e.path,
                    .name = e.path,
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
    var trees_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--raw")) {
            raw = true;
        } else if (std.mem.eql(u8, rest[i], "--trees") and i + 1 < rest.len) {
            trees_path = rest[i + 1];
            i += 1;
        } else {
            try stdout.print("unityz: unknown show option '{s}'\n", .{rest[i]});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;

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
                if (try showSerializedBytes(arena, n.data, sel.path_id, raw, shader_only, stdout, basename(n.path), injected)) found = true;
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
                if (try showSerializedBytes(arena, e.data, sel.path_id, raw, shader_only, stdout, basename(e.path), injected)) found = true;
            }
        },
        .serialized => {
            if (sel.node != null) {
                try stdout.print("unityz: node selector not valid for a serialized file\n", .{});
                return;
            }
            found = try showSerializedBytes(arena, bytes, sel.path_id, raw, shader_only, stdout, basename(path), injected);
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
fn showSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, path_id: i64, raw: bool, shader_only: bool, stdout: *Io.Writer, own_name: []const u8, injected: ?*const InjectedTrees) !bool {
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
        const data = sf.objectData(o) orelse return false;
        var tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) {
            if (injected) |inj| {
                if (injectedTreeFor(arena, inj, &sf, own_name, o.class_id, data)) |it| {
                    tree = it.*;
                } else return false;
            } else return false;
        }
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
    var any = false;
    var trees_path: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, rest[i], "--any")) {
            any = true;
        } else if (std.mem.eql(u8, rest[i], "--trees") and i + 1 < rest.len) {
            trees_path = rest[i + 1];
            i += 1;
        } else {
            try stdout.print("unityz: unknown find option '{s}'\n", .{rest[i]});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;
    var found: std.ArrayList(FindMatch) = .empty;

    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try diag(json, stdout, "{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                if (json) try stdout.print("[]\n", .{});
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try findSerializedBytes(arena, n.data, n.path, needle, class_filter, exact, any, json, &found, basename(n.path), injected, stdout);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try diag(json, stdout, "{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                if (json) try stdout.print("[]\n", .{});
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try findSerializedBytes(arena, e.data, e.path, needle, class_filter, exact, any, json, &found, basename(e.path), injected, stdout);
            }
        },
        .serialized => try findSerializedBytes(arena, bytes, null, needle, class_filter, exact, any, json, &found, basename(path), injected, stdout),
        else => {
            try diag(json, stdout, "{s}: find requires a serialized file, bundle, or webfile\n", .{path});
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

/// True when any string value anywhere in the value tree contains
/// `needle` (case-insensitive). `find --any` uses this to search fields
/// beyond `m_Name`, e.g. AssetBundle container paths.
fn anyStringContains(v: unityz.value.Value, needle: []const u8) bool {
    return switch (v) {
        .string => |s| std.ascii.indexOfIgnoreCase(s, needle) != null,
        .array => |arr| blk: {
            for (arr) |item| {
                if (anyStringContains(item, needle)) break :blk true;
            }
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| {
                if (anyStringContains(f.value, needle)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Like `anyStringContains`, but exact whole-string equality.
fn anyStringEquals(v: unityz.value.Value, needle: []const u8) bool {
    return switch (v) {
        .string => |s| std.mem.eql(u8, std.mem.trimEnd(u8, s, "\x00"), needle),
        .array => |arr| blk: {
            for (arr) |item| {
                if (anyStringEquals(item, needle)) break :blk true;
            }
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| {
                if (anyStringEquals(f.value, needle)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn findSerializedBytes(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, needle: []const u8, class_filter: ?i32, exact: bool, any: bool, json: bool, found: *std.ArrayList(FindMatch), own_name: []const u8, injected: ?*const InjectedTrees, stdout: *Io.Writer) !void {
    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try diag(json, stdout, "  serialized parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    var matches: usize = 0;
    // `find` decodes a whole value tree per object but keeps only `m_Name`
    // from it, so holding the trees in `arena` — which spans every object of
    // every node — makes peak memory the sum of the file's decoded objects.
    // Reset a scratch arena per object; the name is duped into `arena` at
    // the one point it outlives the iteration (the `found` list).
    var obj_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer obj_arena_state.deinit();
    const obj_arena = obj_arena_state.allocator();
    for (sf.objects) |*o| {
        defer _ = obj_arena_state.reset(.retain_capacity);
        if (class_filter) |cf| {
            if (o.class_id != cf) continue;
        }
        const type_index = o.type_index orelse continue;
        if (type_index >= sf.types.len) continue;
        const data = sf.objectData(o) orelse continue;
        var tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) {
            if (injected) |inj| {
                if (injectedTreeFor(obj_arena, inj, &sf, own_name, o.class_id, data)) |it| {
                    tree = it.*;
                } else continue;
            } else continue;
        }
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(obj_arena, &r, &tree.roots[0]) catch continue;
        const name = unityz.classes.stringField(v, "m_Name") orelse "";
        if (needle.len != 0) {
            if (exact) {
                // exact, case-sensitive whole-name match (names may carry
                // trailing NULs); --any extends the match to every string
                // value in the tree
                const name_eq = std.mem.eql(u8, std.mem.trimEnd(u8, name, "\x00"), needle);
                if (!name_eq and !(any and anyStringEquals(v, needle))) continue;
            } else {
                const name_has = std.ascii.indexOfIgnoreCase(name, needle) != null;
                if (!name_has and !(any and anyStringContains(v, needle))) continue;
            }
        }
        if (json) {
            // Arena-backed: the caller's arena is released on return, whereas
            // a page_allocator buffer would leak once per file when `find` is
            // run over a directory. `name` borrows the per-object arena, which
            // is reset at the end of this iteration, so it has to be copied.
            try found.append(arena, .{ .path_id = o.path_id, .class_id = o.class_id, .name = try arena.dupe(u8, name), .node = node });
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
        try stdout.print("\"{d}\":{{\"name\":", .{c.class_id});
        try writeJsonString(stdout, className(c.class_id) orelse "Class");
        try stdout.print(",\"count\":{d},\"bytes\":{d}}}", .{ c.count, c.bytes });
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
fn cmdEditWebFile(path: []const u8, out_path: ?[]const u8, sel: Selector, pairs: []const []const u8, verify: bool, bytes: []const u8, injected: ?*const InjectedTrees, stdout: *Io.Writer) !void {
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
        const edited = editSerializedObject(arena, e.data, sel.path_id, pairs, basename(e.path), injected) catch |err| {
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
fn cmdEditBundle(path: []const u8, out_path: ?[]const u8, sel: Selector, pairs: []const []const u8, verify: bool, bytes: []const u8, injected: ?*const InjectedTrees, stdout: *Io.Writer) !void {
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
        const edited = editSerializedObject(arena, n.data, sel.path_id, pairs, basename(n.path), injected) catch |err| {
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
fn editSerializedObject(arena: std.mem.Allocator, bytes: []const u8, path_id: i64, pairs: []const []const u8, own_name: []const u8, injected: ?*const InjectedTrees) ![]u8 {
    const sf = try unityz.serialized.parse(arena, bytes);
    const o = sf.findObject(path_id) orelse return error.ObjectNotFound;
    const type_index = o.type_index orelse return error.MissingTypeIndex;
    if (type_index >= sf.types.len) return error.MissingTypeIndex;
    var tree = sf.types[type_index].type_tree;
    if (tree.roots.len == 0) {
        // Typeless Mono file: decode from the injected table.
        if (injected) |inj| {
            const d0 = sf.objectData(o) orelse return error.OutOfMemory;
            tree = (injectedTreeFor(arena, inj, &sf, own_name, o.class_id, d0) orelse return error.MissingTypeIndex).*;
        } else return error.MissingTypeIndex;
    }
    const data = sf.objectData(o) orelse return error.OutOfMemory;
    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    const root = &tree.roots[0];
    var edited = try unityz.object_reader.readObject(arena, &r, root);

    var pair: usize = 0;
    while (pair + 1 < pairs.len) : (pair += 2) {
        const new_value = try parseJsonLiteral(pairs[pair + 1]);
        const segs = try parseFieldPath(pairs[pair]);
        edited = setFieldPath(arena, edited, segs, 0, new_value) catch |err| {
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
/// indexed like the single-object edit. Typeless Mono files decode through
/// the injected tree table (`--trees`), like the single-object form.
fn cmdEditPatch(path: []const u8, out_path: ?[]const u8, patch_text: []const u8, verify: bool, bytes: []const u8, injected: ?*const InjectedTrees, stdout: *Io.Writer) !void {
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
            rewritten = try editSerializedPatches(arena, bytes, entries, basename(path), injected);
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
            // the file having applied only part of the patch. A raw-node
            // key must name an existing non-serialized node.
            for (entries) |entry| {
                if (isRawNodeKey(entry.name)) {
                    var node_found = false;
                    for (b.nodes) |n| {
                        if (!std.mem.eql(u8, entry.name, n.path)) continue;
                        node_found = true;
                        if (unityz.container.sniff(n.data).container == .serialized) {
                            try stdout.print("unityz: entry '{s}' names a serialized node; use 'node:path-id'\n", .{entry.name});
                            return;
                        }
                    }
                    if (!node_found) {
                        try stdout.print("unityz: bad patch entry '{s}': no such node\n", .{entry.name});
                        return;
                    }
                    continue;
                }
                _ = parseSelector(entry.name) catch {
                    try stdout.print("unityz: bad patch entry '{s}'\n", .{entry.name});
                    return;
                };
            }
            var replacements: std.ArrayList(unityz.bundle.NodeReplacement) = .empty;
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container == .serialized) {
                    // collect the patch entries this node contains
                    const node_sf = unityz.serialized.parse(arena, n.data) catch continue;
                    var node_entries: std.ArrayList(unityz.value.Field) = .empty;
                    for (entries) |entry| {
                        if (isRawNodeKey(entry.name)) continue;
                        const sel = parseSelector(entry.name) catch continue;
                        if (sel.node) |sn| {
                            if (!std.mem.eql(u8, n.path, sn)) continue;
                        }
                        if (node_sf.findObject(sel.path_id) != null) try node_entries.append(arena, entry);
                    }
                    if (node_entries.items.len == 0) continue;
                    const edited_node = try editSerializedPatches(arena, n.data, node_entries.items, basename(n.path), injected);
                    try replacements.append(arena, .{ .path = n.path, .data = edited_node });
                    edited_count += node_entries.items.len;
                    continue;
                }
                // raw node: apply every raw-node entry keyed by this path,
                // in patch order, each overwriting the previous result
                var patched: ?[]u8 = null;
                for (entries) |entry| {
                    if (!isRawNodeKey(entry.name)) continue;
                    if (!std.mem.eql(u8, entry.name, n.path)) continue;
                    patched = try applyNodeBytes(arena, patched orelse n.data, entry);
                }
                if (patched) |p| {
                    try replacements.append(arena, .{ .path = n.path, .data = p });
                    edited_count += 1;
                }
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
            // the file having applied only part of the patch. A raw-node
            // key must name an existing non-serialized entry.
            for (entries) |entry| {
                if (isRawNodeKey(entry.name)) {
                    var entry_found = false;
                    for (wf.entries) |e| {
                        if (!std.mem.eql(u8, entry.name, e.path)) continue;
                        entry_found = true;
                        if (unityz.container.sniff(e.data).container == .serialized) {
                            try stdout.print("unityz: entry '{s}' names a serialized entry; use 'node:path-id'\n", .{entry.name});
                            return;
                        }
                    }
                    if (!entry_found) {
                        try stdout.print("unityz: bad patch entry '{s}': no such entry\n", .{entry.name});
                        return;
                    }
                    continue;
                }
                _ = parseSelector(entry.name) catch {
                    try stdout.print("unityz: bad patch entry '{s}'\n", .{entry.name});
                    return;
                };
            }
            var replacements: std.ArrayList(unityz.webfile.EntryReplacement) = .empty;
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container == .serialized) {
                    const entry_sf = unityz.serialized.parse(arena, e.data) catch continue;
                    var entry_entries: std.ArrayList(unityz.value.Field) = .empty;
                    for (entries) |entry| {
                        if (isRawNodeKey(entry.name)) continue;
                        const sel = parseSelector(entry.name) catch continue;
                        if (sel.node) |sn| {
                            if (!std.mem.eql(u8, e.path, sn)) continue;
                        }
                        if (entry_sf.findObject(sel.path_id) != null) try entry_entries.append(arena, entry);
                    }
                    if (entry_entries.items.len == 0) continue;
                    const edited_entry = try editSerializedPatches(arena, e.data, entry_entries.items, basename(e.path), injected);
                    try replacements.append(arena, .{ .path = e.path, .data = edited_entry });
                    edited_count += entry_entries.items.len;
                    continue;
                }
                var patched: ?[]u8 = null;
                for (entries) |entry| {
                    if (!isRawNodeKey(entry.name)) continue;
                    if (!std.mem.eql(u8, entry.name, e.path)) continue;
                    patched = try applyNodeBytes(arena, patched orelse e.data, entry);
                }
                if (patched) |p| {
                    try replacements.append(arena, .{ .path = e.path, .data = p });
                    edited_count += 1;
                }
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
            // The rebuilt bundle's streamed references must resolve against
            // its own sidecar nodes, like `verify` does; without them every
            // streamed AudioClip/Texture2D would fail this check.
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = n.path, .data = n.data });
                }
            }
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try verifySerializedBytesSidecars(arena, n.data, null, null, null, true, &report, stdout, sidecars.items, "", null);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("verify failed: webfile parse error: {s}\n", .{@errorName(err)});
                return false;
            };
            var sidecars: std.ArrayList(Sidecar) = .empty;
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) {
                    try sidecars.append(arena, .{ .path = e.path, .data = e.data });
                }
            }
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try verifySerializedBytesSidecars(arena, e.data, null, null, null, true, &report, stdout, sidecars.items, "", null);
            }
        },
        .serialized => try verifySerializedBytes(arena, bytes, null, null, null, true, &report, stdout, "", null),
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

/// A raw-node patch key: a node path with no `:` and no numeric path id
/// (`CAB-abc123.resS`), meaning "patch this node's raw bytes" rather than
/// one object inside a serialized node.
fn isRawNodeKey(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, ':') != null) return false;
    const v = std.fmt.parseInt(i64, name, 10) catch return true;
    _ = v;
    return false;
}

/// Applies one raw-node patch entry: `{"offset": N, "bytes": "<base64>"}`
/// replaces the decoded bytes at byte offset N within the node's data.
/// The range must fit inside the node, so every sidecar reference (an
/// AudioClip's m_Resource offset/size, a streamed texture's m_StreamData)
/// stays valid; a patch that would write past the end is rejected.
fn applyNodeBytes(arena: std.mem.Allocator, node_data: []const u8, entry: unityz.value.Field) ![]u8 {
    const spec = switch (entry.value) {
        .obj => |f| f,
        else => return error.BadPatchValue,
    };
    var offset: ?usize = null;
    var b64: ?[]const u8 = null;
    for (spec) |f| {
        if (std.mem.eql(u8, f.name, "offset")) {
            offset = std.math.cast(usize, f.value.asInt() orelse return error.BadPatchValue) orelse return error.BadPatchValue;
        } else if (std.mem.eql(u8, f.name, "bytes")) {
            b64 = switch (f.value) {
                .string => |s| s,
                else => return error.BadPatchValue,
            };
        } else return error.BadPatchValue;
    }
    const off = offset orelse return error.BadPatchValue;
    const s = b64 orelse return error.BadPatchValue;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(s);
    if (off > node_data.len or size > node_data.len - off) return error.BadPatchValue;
    const buf = try arena.alloc(u8, size);
    try std.base64.standard.Decoder.decode(buf, s);
    const out = try arena.alloc(u8, node_data.len);
    @memcpy(out, node_data);
    @memcpy(out[off .. off + size], buf);
    return out;
}

/// Applies a list of patch entries (path-id -> fields) to one serialized
/// file and returns the rewritten bytes. All objects are read, edited, and
/// serialized, then the file is rewritten once.
fn editSerializedPatches(arena: std.mem.Allocator, bytes: []const u8, entries: []const unityz.value.Field, own_name: []const u8, injected: ?*const InjectedTrees) ![]u8 {
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
        var tree = sf.types[type_index].type_tree;
        if (tree.roots.len == 0) {
            // Typeless Mono file: decode from the injected table.
            if (injected) |inj| {
                const d0 = sf.objectData(o) orelse return error.OutOfMemory;
                tree = (injectedTreeFor(arena, inj, &sf, own_name, o.class_id, d0) orelse return error.MissingTypeIndex).*;
            } else return error.MissingTypeIndex;
        }
        const data = sf.objectData(o) orelse return error.OutOfMemory;
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const root = &tree.roots[0];
        var edited = try unityz.object_reader.readObject(arena, &r, root);
        for (fields) |f| {
            const segs = try parseFieldPath(f.name);
            edited = setFieldPath(arena, edited, segs, 0, f.value) catch |err| {
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
    var trees_path: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, rest[i], "--trees") and i + 1 < rest.len) {
            trees_path = rest[i + 1];
            i += 1;
        } else {
            try pairs.append(arena, rest[i]);
        }
    }
    const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;
    if (patch_path) |pp| {
        const io = io_global.io;
        const patch_text = std.Io.Dir.cwd().readFileAlloc(io, pp, arena, .unlimited) catch |err| {
            try stdout.print("unityz: {s}: {s}\n", .{ pp, @errorName(err) });
            return;
        };
        return cmdEditPatch(path, out_path, patch_text, verify, bytes, injected, stdout);
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
        .bundle => return cmdEditBundle(path, out_path, sel, pairs.items, verify, bytes, injected, stdout),
        .webfile => return cmdEditWebFile(path, out_path, sel, pairs.items, verify, bytes, injected, stdout),
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
    if (type_index >= sf.types.len) {
        try stdout.print("unityz: object {d} has no type tree\n", .{sel.path_id});
        return;
    }
    var tree = sf.types[type_index].type_tree;
    const data = sf.objectData(o) orelse {
        try stdout.print("unityz: object {d} has no data\n", .{sel.path_id});
        return;
    };
    if (tree.roots.len == 0) {
        // Typeless Mono file: decode from the injected table.
        if (injected) |inj| {
            tree = (injectedTreeFor(arena, inj, &sf, basename(path), o.class_id, data) orelse {
                try stdout.print("unityz: object {d} has no type tree\n", .{sel.path_id});
                return;
            }).*;
        } else {
            try stdout.print("unityz: object {d} has no type tree\n", .{sel.path_id});
            return;
        }
    }

    var r = unityz.streams.Reader.init(data);
    r.endian = sf.endian;
    const root = &tree.roots[0];
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
        edited = setFieldPath(arena, edited, segs, 0, new_value) catch {
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
    /// The whole dot-segment this name came from, including any `[N]`
    /// groups (e.g. `m_MeshMetrics[0]`). Unity type trees occasionally
    /// name plain fields with literal brackets, so the raw text is the
    /// fallback when the name alone does not match.
    raw: []const u8 = "",
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
            try segs.append(allocator, .{ .name = rest[0..open], .raw = raw });
            rest = rest[open..];
            while (rest.len > 0 and rest[0] == '[') {
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.BadPath;
                if (close == 1) return error.BadPath;
                try segs.append(allocator, .{ .index = try std.fmt.parseInt(usize, rest[1..close], 10) });
                rest = rest[close + 1 ..];
            }
            if (rest.len != 0) return error.BadPath;
        } else {
            try segs.append(allocator, .{ .name = rest, .raw = raw });
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
/// leaf. `error.BadPath` means a segment did not exist. A base64 string
/// literal on a byte-array leaf is decoded, so raw binary fields (mesh
/// index/vertex buffers, image data, audio payloads) are patchable.
fn setFieldPath(allocator: std.mem.Allocator, v: unityz.value.Value, segs: []const PathSeg, i: usize, new_value: unityz.value.Value) !unityz.value.Value {
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
        // Some Unity type trees name plain fields with literal brackets
        // (a mesh's "m_MeshMetrics[0]" is a float, not an array access).
        // When the raw dot-segment text matches a field literally, the
        // trailing index segments are part of the name, so the whole
        // dotted field is one leaf.
        if (seg.raw.len != 0 and !std.mem.eql(u8, seg.raw, seg.name)) {
            var j: usize = i;
            while (j < segs.len and (segs[j].name.len == 0 or j == i)) j += 1;
            if (j == segs.len) {
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, seg.raw)) {
                        return replaceObjField(fields, seg.raw, try asTargetValue(allocator, f.value, new_value), true);
                    }
                }
            }
        }
        const child = blk: {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, seg.name)) break :blk f.value;
            }
            break :blk null;
        } orelse return error.BadPath;
        const new_child = if (is_last) try asTargetValue(allocator, child, new_value) else try setFieldPath(allocator, child, segs, i + 1, new_value);
        return replaceObjField(fields, seg.name, new_child, is_last);
    }
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadPath,
    };
    const idx = seg.index orelse return error.BadPath;
    if (idx >= arr.len) return error.BadPath;
    const new_child = if (is_last) try asTargetValue(allocator, arr[idx], new_value) else try setFieldPath(allocator, arr[idx], segs, i + 1, new_value);
    return replaceArrayIndex(arr, idx, new_child);
}

/// Converts `new_value` to the shape of the target `old`: a base64 string
/// literal becomes bytes when the field is a byte array. The conversion is
/// recursive, so a patch that replaces a whole subtree (e.g. a mesh's
/// `m_VertexData`) round-trips the base64 string its embedded byte fields
/// were exported as, not just a directly-addressed leaf.
fn asTargetValue(allocator: std.mem.Allocator, old: unityz.value.Value, new_value: unityz.value.Value) !unityz.value.Value {
    // Byte-array target, base64 string literal: decode to raw bytes.
    if (old == .bytes and new_value == .string) {
        const s = new_value.string;
        const size = try std.base64.standard.Decoder.calcSizeForSlice(s);
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        try std.base64.standard.Decoder.decode(buf, s);
        return .{ .bytes = buf };
    }
    // Same-shaped containers: coerce each child against its counterpart in
    // the target. Elements with no counterpart (a grown array) pass through.
    if (old == .obj and new_value == .obj) {
        var out: std.ArrayList(unityz.value.Field) = .empty;
        try out.ensureTotalCapacity(allocator, new_value.obj.len);
        for (new_value.obj) |f| {
            const old_child = blk: {
                for (old.obj) |of| {
                    if (std.mem.eql(u8, of.name, f.name)) break :blk of.value;
                }
                break :blk null;
            };
            const coerced = if (old_child) |oc| try asTargetValue(allocator, oc, f.value) else f.value;
            try out.append(allocator, .{ .name = f.name, .value = coerced });
        }
        return .{ .obj = try out.toOwnedSlice(allocator) };
    }
    if (old == .array and new_value == .array) {
        const n = @min(old.array.len, new_value.array.len);
        var out: std.ArrayList(unityz.value.Value) = .empty;
        try out.ensureTotalCapacity(allocator, new_value.array.len);
        for (new_value.array, 0..) |item, i| {
            try out.append(allocator, if (i < n) try asTargetValue(allocator, old.array[i], item) else item);
        }
        return .{ .array = try out.toOwnedSlice(allocator) };
    }
    return new_value;
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

/// `hierarchy <path> [--json]` — prints the GameObject/Transform tree of
/// a scene: root transforms first, recursing through m_Children, each
/// node named by its GameObject with the transform path id, component
/// classes, and local position. UnityPy's CLI has no scene-structure
/// view.
fn cmdHierarchy(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var json = false;
    var trees_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--trees") and i + 1 < rest.len) {
            trees_path = rest[i + 1];
            i += 1;
        } else {
            try stdout.print("unityz: unknown hierarchy option '{s}'\n", .{arg});
            return;
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const injected = if (trees_path) |tp| try parseInjectedTrees(arena, tp, stdout) else null;
    switch (unityz.container.sniff(bytes).container) {
        .bundle => {
            const b = unityz.bundle.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: bundle parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (b.nodes) |n| {
                if (unityz.container.sniff(n.data).container != .serialized) continue;
                try printHierarchy(arena, n.data, n.path, json, injected, stdout);
            }
        },
        .webfile => {
            const wf = unityz.webfile.parse(arena, bytes) catch |err| {
                try stdout.print("{s}: webfile parse failed: {s}\n", .{ path, @errorName(err) });
                return;
            };
            for (wf.entries) |e| {
                if (unityz.container.sniff(e.data).container != .serialized) continue;
                try printHierarchy(arena, e.data, e.path, json, injected, stdout);
            }
        },
        .serialized => try printHierarchy(arena, bytes, null, json, injected, stdout),
        else => try stdout.print("{s}: hierarchy requires a serialized file, bundle, or webfile\n", .{path}),
    }
}

/// One transform's scene-graph edges and local position.
const TNode = struct {
    go: i64 = 0,
    father: i64 = 0,
    pos: [3]f32 = .{ 0, 0, 0 },
    children: std.ArrayList(i64) = .empty,
};

const TEntry = struct { path_id: i64, node: TNode };

/// A GameObject's name plus the classes of its components.
const GoInfo = struct {
    path_id: i64,
    name: []const u8 = "",
    components: std.ArrayList(i32) = .empty,
};

/// `managed <dir>` — read a Mono build's managed assemblies and list the
/// MonoBehaviour script classes with their serialized field layouts. This is
/// the layout Unity's serializer uses for class-114 objects, which UnityPy
/// can only reach by loading a full .NET runtime; here it is plain metadata
/// parsing. Accepts a directory (scans *.dll) or a single assembly path.
fn cmdManaged(path: []const u8, rest: []const []const u8, bytes: []const u8, stdout: *Io.Writer) !void {
    var json = false;
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            try stdout.print("unityz: unknown managed option '{s}'\n", .{arg});
            return;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Collect (name, bytes) pairs: the single file, or every *.dll in the dir.
    const Files = struct { names: std.ArrayList([]const u8) = .empty, datas: std.ArrayList([]const u8) = .empty };
    var files: Files = .{};
    const io = io_global.io;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        try stdout.print("unityz: {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    if (stat.kind == .directory) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            try stdout.print("unityz: {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            // the iterator reuses its name buffer on the next call; dupe
            // before anything else touches the iterator
            const ename = try arena.dupe(u8, entry.name);
            if (!std.mem.endsWith(u8, ename, ".dll")) continue;
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, ename });
            const data = std.Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch continue;
            try files.names.append(arena, ename);
            try files.datas.append(arena, data);
        }
    } else {
        try files.names.append(arena, try arena.dupe(u8, basename(path)));
        try files.datas.append(arena, bytes);
    }
    if (files.names.items.len == 0) {
        try stdout.print("unityz: {s}: no assemblies found\n", .{path});
        return;
    }

    if (json) try stdout.writeByte('[');
    var first_asm = true;
    var total_classes: usize = 0;
    for (files.names.items, 0..) |fname, fi| {
        const assembly = unityz.dotnet.parseAssembly(arena, fname, files.datas.items[fi]) catch |err| {
            if (json) {
                if (!first_asm) try stdout.writeByte(',');
                try stdout.print("{{\"file\":\"{s}\",\"error\":\"{s}\"}}", .{ fname, @errorName(err) });
                first_asm = false;
            } else {
                try stdout.print("{s}: {s}\n", .{ fname, @errorName(err) });
            }
            continue;
        };
        // collect MonoBehaviour subclasses
        var scripts: std.ArrayList(unityz.dotnet.TypeDef) = .empty;
        for (assembly.type_defs) |td| {
            if (unityz.dotnet.isMonoBehaviour(arena, td, assembly.type_defs)) try scripts.append(arena, td);
        }
        if (scripts.items.len == 0) {
            if (json) {
                if (!first_asm) try stdout.writeByte(',');
                try stdout.print("{{\"file\":\"{s}\",\"scripts\":[]}}", .{fname});
                first_asm = false;
            } else {
                try stdout.print("{s}: {d} MonoBehaviour class(es)\n", .{ fname, 0 });
            }
            continue;
        }
        total_classes += scripts.items.len;
        if (json) {
            if (!first_asm) try stdout.writeByte(',');
            try stdout.print("{{\"file\":\"{s}\",\"scripts\":[", .{fname});
            for (scripts.items, 0..) |td, si| {
                if (si != 0) try stdout.writeByte(',');
                try stdout.print("{{\"class\":\"{s}\",\"namespace\":\"{s}\",\"base\":\"{s}\",\"fields\":[", .{
                    td.name,
                    td.namespace,
                    td.base_name orelse "",
                });
                for (td.fields, 0..) |f, k| {
                    if (k != 0) try stdout.writeByte(',');
                    try stdout.print("{{\"name\":\"{s}\",\"type\":\"{s}\"", .{ f.name, managedFieldType(f) });
                    if (f.isPublic()) try stdout.writeAll(",\"flags\":\"public\"");
                    if (f.isStatic()) try stdout.writeAll(",\"flags\":\"static\"");
                    try stdout.writeByte('}');
                }
                try stdout.writeAll("]}");
            }
            try stdout.writeAll("]}");
            first_asm = false;
        } else {
            try stdout.print("{s}: {d} MonoBehaviour class(es)\n", .{ fname, scripts.items.len });
            for (scripts.items) |td| {
                try stdout.print("  {s}\n", .{td.fullName(arena)});
                for (td.fields) |f| {
                    try stdout.print("    {s} {s}", .{ managedFieldType(f), f.name });
                    if (f.isPublic()) try stdout.writeAll(" [public]");
                    if (f.isStatic()) try stdout.writeAll(" [static]");
                    try stdout.writeByte('\n');
                }
            }
        }
    }
    if (json) {
        try stdout.writeByte(']');
        try stdout.writeByte('\n');
    } else {
        try stdout.print("{d} MonoBehaviour class(es) total\n", .{total_classes});
    }
}

/// The display name of a managed field's type: the resolved class name for
/// class/valuetype/array signatures, the CLR primitive name otherwise.
fn managedFieldType(f: unityz.dotnet.Field) []const u8 {
    if (f.type_name.len != 0) return f.type_name;
    return unityz.dotnet.elementTypeName(f.elem_type);
}

fn printHierarchy(arena: std.mem.Allocator, bytes: []const u8, node: ?[]const u8, json: bool, injected: ?*const InjectedTrees, stdout: *Io.Writer) !void {    const sf = unityz.serialized.parse(arena, bytes) catch |err| {
        try stdout.print("  serialized parse failed: {s}\n", .{@errorName(err)});
        return;
    };
    if (node) |n| {
        if (json) {
            try stdout.print("{{\"node\":", .{});
            try writeJsonString(stdout, n);
            try stdout.print(",\"hierarchy\":[", .{});
        } else {
            try stdout.print("hierarchy of {s}:\n", .{n});
        }
    } else if (!json) {
        try stdout.print("hierarchy:\n", .{});
    }

    var nodes: std.ArrayList(TEntry) = .empty;
    var gos: std.ArrayList(GoInfo) = .empty;
    var bones: std.ArrayList(i64) = .empty;
    for (sf.objects) |*o| {
        const data = sf.objectData(o) orelse continue;
        const ti = o.type_index orelse continue;
        if (ti >= sf.types.len) continue;
        var tree = sf.types[ti].type_tree;
        if (tree.roots.len == 0) {
            // Typeless Mono file: decode from the injected table.
            if (injected) |inj| {
                if (injectedTreeFor(arena, inj, &sf, basename(node orelse ""), o.class_id, data)) |it| {
                    tree = it.*;
                } else continue;
            } else continue;
        }
        var r = unityz.streams.Reader.init(data);
        r.endian = sf.endian;
        const v = unityz.object_reader.readObject(arena, &r, &tree.roots[0]) catch continue;
        switch (o.class_id) {
            4 => { // Transform
                var tn = TNode{};
                if (unityz.classes.fieldOf(v, "m_GameObject")) |go| tn.go = pptrPathId(go) orelse 0;
                if (unityz.classes.fieldOf(v, "m_Father")) |fa| tn.father = pptrPathId(fa) orelse 0;
                if (unityz.classes.fieldOf(v, "m_LocalPosition")) |lp| {
                    if (unityz.classes.fieldOf(lp, "x")) |x| tn.pos[0] = @floatCast(x.asFloat() orelse 0);
                    if (unityz.classes.fieldOf(lp, "y")) |y| tn.pos[1] = @floatCast(y.asFloat() orelse 0);
                    if (unityz.classes.fieldOf(lp, "z")) |z| tn.pos[2] = @floatCast(z.asFloat() orelse 0);
                }
                if (unityz.classes.fieldOf(v, "m_Children")) |ch| {
                    if (ch == .array) {
                        for (ch.array) |c| {
                            if (pptrPathId(c)) |cid| try tn.children.append(arena, cid);
                        }
                    }
                }
                try nodes.append(arena, .{ .path_id = o.path_id, .node = tn });
            },
            1 => { // GameObject
                var gi = GoInfo{ .path_id = o.path_id };
                gi.name = unityz.classes.stringField(v, "m_Name") orelse "";
                if (unityz.classes.fieldOf(v, "m_Component")) |comp| {
                    if (comp == .array) {
                        for (comp.array) |c| {
                            // each entry wraps the PPtr in a "component" field
                            const wrapped = unityz.classes.fieldOf(c, "component") orelse continue;
                            const cid = pptrPathId(wrapped) orelse continue;
                            // the component object's class, by path id
                            for (sf.objects) |*other| {
                                if (other.path_id == cid) {
                                    try gi.components.append(arena, other.class_id);
                                    break;
                                }
                            }
                        }
                    }
                }
                try gos.append(arena, gi);
            },
            137 => { // SkinnedMeshRenderer: its m_Bones are transforms
                if (unityz.classes.fieldOf(v, "m_Bones")) |b| {
                    if (b == .array) {
                        for (b.array) |bone| {
                            if (pptrPathId(bone)) |bid| try bones.append(arena, bid);
                        }
                    }
                }
            },
            else => {},
        }
    }

    var roots_printed: usize = 0;
    for (nodes.items) |*e| {
        if (e.node.father == 0) {
            if (json and roots_printed != 0) try stdout.writeByte(',');
            roots_printed += 1;
            try printHierarchyNode(nodes.items, gos.items, bones.items, e.path_id, 0, json, stdout);
        }
    }
    if (json) {
        try stdout.print("]", .{});
        if (node != null) try stdout.writeByte('}');
        try stdout.writeByte('\n');
    } else {
        try stdout.writeByte('\n');
    }
}

fn findNode(nodes: []const TEntry, path_id: i64) ?*const TNode {
    for (nodes) |*e| {
        if (e.path_id == path_id) return &e.node;
    }
    return null;
}

fn findGo(gos: []const GoInfo, path_id: i64) ?*const GoInfo {
    for (gos) |*g| {
        if (g.path_id == path_id) return g;
    }
    return null;
}

fn isBone(bones: []const i64, path_id: i64) bool {
    for (bones) |b| {
        if (b == path_id) return true;
    }
    return false;
}

/// Traversal depth limit for `printHierarchyNode`. Children lists are
/// file-supplied and may be cyclic or nest beyond any scene graph, so the
/// recursion must terminate: the bound stops it the way `max_json_depth`
/// and `typetree.max_depth` bound their parsers.
const max_hierarchy_depth: usize = 512;

fn printHierarchyNode(nodes: []const TEntry, gos: []const GoInfo, bones: []const i64, path_id: i64, depth: usize, json: bool, stdout: *Io.Writer) !void {
    if (depth > max_hierarchy_depth) return error.TooDeep;
    const tn = findNode(nodes, path_id) orelse return;
    const go = findGo(gos, tn.go);
    const bone = isBone(bones, path_id);
    if (json) {
        try stdout.writeAll("{\"name\":");
        try writeJsonString(stdout, if (go) |g| g.name else "");
        try stdout.print(",\"transform\":{d},\"gameObject\":{d},\"position\":[{d},{d},{d}],\"components\":[", .{ path_id, tn.go, tn.pos[0], tn.pos[1], tn.pos[2] });
        if (go) |g| {
            for (g.components.items, 0..) |c, i| {
                if (i != 0) try stdout.writeByte(',');
                try stdout.print("{d}", .{c});
            }
        }
        try stdout.print("],\"bone\":{}", .{bone});
        try stdout.writeAll(",\"children\":[");
        for (tn.children.items, 0..) |c, i| {
            if (i != 0) try stdout.writeByte(',');
            try printHierarchyNode(nodes, gos, bones, c, depth + 1, json, stdout);
        }
        try stdout.writeAll("]}");
        return;
    }
    for (0..depth) |_| try stdout.writeAll("  ");
    try stdout.print("{s} (t {d}, go {d})", .{ if (go) |g| g.name else "?", path_id, tn.go });
    if (bone) try stdout.writeAll("  (bone)");
    if (go) |g| {
        if (g.components.items.len != 0) {
            try stdout.writeAll(" [");
            for (g.components.items, 0..) |c, i| {
                if (i != 0) try stdout.writeAll(", ");
                try stdout.writeAll(className(c) orelse "Class");
            }
            try stdout.writeByte(']');
        }
    }
    try stdout.print("  pos({d}, {d}, {d})\n", .{ tn.pos[0], tn.pos[1], tn.pos[2] });
    for (tn.children.items) |c| {
        try printHierarchyNode(nodes, gos, bones, c, depth + 1, json, stdout);
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

test "writeObjFloat matches Python's %.9g" {
    // The golden mesh UVs from UnityPy's test assets: f32-derived values
    // whose 9-significant-digit rounding lands on dyadic midpoints, so the
    // half-even tie rule decides the last digit.
    const cases = [_]struct { v: f64, want: []const u8 }{
        .{ .v = 0.6895492076873779, .want = "0.689549208" },
        .{ .v = 0.00048828125, .want = "0.00048828125" },
        .{ .v = 0.04736328125, .want = "0.0473632812" }, // half-even tie -> 2, not 3
        .{ .v = -1152.0, .want = "-1152" },
        .{ .v = 2047.99999999, .want = "2048" },
        .{ .v = 1.5, .want = "1.5" },
        .{ .v = 0.0, .want = "0" },
        .{ .v = -0.0, .want = "-0" },
        .{ .v = 0.4999999999, .want = "0.5" },
        .{ .v = 0.9999999995, .want = "1" },
        // exponent form: C's %g uses E-notation for |v| < 1e-4 or >= 1e9
        // (real meshes carry denormal-scale values like these)
        .{ .v = 8.57252764e-18, .want = "8.57252764E-18" },
        .{ .v = 1.71450553e-17, .want = "1.71450553E-17" },
        .{ .v = -3.5e-5, .want = "-3.5E-05" },
        .{ .v = 1e9, .want = "1E+09" },
        .{ .v = 1.23456789e-5, .want = "1.23456789E-05" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w: unityz.streams.Writer = .init(std.testing.allocator);
        defer w.deinit();
        try writeObjFloat(&w, c.v);
        const got = try std.fmt.bufPrint(&buf, "{s}", .{w.getWritten()});
        try std.testing.expectEqualStrings(c.want, got);
    }
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

test "sanitizeComponent confines a file-supplied name to one path component" {
    // An asset's `m_Name` reaches the output filename, so the separators
    // that would let it escape the extract directory must be neutralised.
    var traversal = "../../etc/passwd".*;
    try std.testing.expectEqualStrings(".._.._etc_passwd", sanitizeComponent(&traversal));

    var windows = "..\\..\\system32".*;
    try std.testing.expectEqualStrings(".._.._system32", sanitizeComponent(&windows));

    // A NUL truncates the path at the syscall, hiding whatever follows it
    // from the extension checks, so it is replaced too.
    var nul = "evil\x00.png".*;
    try std.testing.expectEqualStrings("evil_.png", sanitizeComponent(&nul));

    // Ordinary names survive untouched, and the returned slice aliases the
    // caller's buffer rather than a copy.
    var plain = "Player_Idle.png".*;
    const out = sanitizeComponent(&plain);
    try std.testing.expectEqualStrings("Player_Idle.png", out);
    try std.testing.expectEqual(@as([*]u8, &plain), out.ptr);

    var empty: [0]u8 = undefined;
    try std.testing.expectEqualStrings("", sanitizeComponent(&empty));
}

/// Test-only field lookup on an `.obj` value.
fn testFieldOf(v: unityz.value.Value, name: []const u8) ?unityz.value.Value {
    for (v.obj) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

test "setFieldPath rebuilds the tree copy-on-write and rejects missing segments" {
    // The tree `edit` walks: a scalar, an array, a nested object and a PPtr.
    const original = unityz.value.Value{ .obj = &[_]unityz.value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Old" } },
        .{ .name = "m_Values", .value = .{ .array = &[_]unityz.value.Value{
            .{ .int = 10 },
            .{ .int = 20 },
            .{ .int = 30 },
        } } },
        .{ .name = "m_Sub", .value = .{ .obj = &[_]unityz.value.Field{
            .{ .name = "count", .value = .{ .int = 1 } },
        } } },
        .{ .name = "m_Script", .value = .{ .pptr = .{ .file_id = 0, .path_id = 42 } } },
    } };

    const set = struct {
        fn apply(a: std.mem.Allocator, v: unityz.value.Value, path: []const u8, new_value: unityz.value.Value) !unityz.value.Value {
            return setFieldPath(a, v, try parseFieldPath(path), 0, new_value);
        }
    }.apply;

    // A nested scalar is replaced and the siblings survive untouched.
    const nested = try set(std.testing.allocator, original, "m_Sub.count", .{ .int = 7 });
    try std.testing.expectEqual(@as(i64, 7), testFieldOf(testFieldOf(nested, "m_Sub").?, "count").?.int);
    try std.testing.expectEqualStrings("Old", testFieldOf(nested, "m_Name").?.string);
    try std.testing.expectEqual(@as(usize, 4), nested.obj.len);
    // copy-on-write: the source tree is not mutated
    try std.testing.expectEqual(@as(i64, 1), testFieldOf(testFieldOf(original, "m_Sub").?, "count").?.int);

    // A base64 string literal patches a byte-array field (raw binary data).
    const with_bytes = unityz.value.Value{ .obj = &[_]unityz.value.Field{
        .{ .name = "m_IndexBuffer", .value = .{ .bytes = &[_]u8{ 0x02, 0x00, 0x01, 0x00 } } },
    } };
    const patched = try set(std.testing.allocator, with_bytes, "m_IndexBuffer", .{ .string = "AwD/AA==" });
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0xff, 0x00 }, patched.obj[0].value.bytes);
    std.testing.allocator.free(patched.obj[0].value.bytes);
    // a bad base64 literal is rejected
    try std.testing.expectError(error.InvalidCharacter, set(std.testing.allocator, with_bytes, "m_IndexBuffer", .{ .string = "!!!not-base64!!!" }));

    // Replacing a whole subtree coerces the base64 strings inside it, so an
    // `extract --json` export fed back through `edit --patch` round-trips
    // its embedded byte fields (a mesh's m_VertexData, not just a leaf).
    const with_subtree = unityz.value.Value{ .obj = &[_]unityz.value.Field{
        .{ .name = "m_VertexData", .value = .{ .obj = &[_]unityz.value.Field{
            .{ .name = "m_VertexCount", .value = .{ .int = 2 } },
            .{ .name = "m_Data", .value = .{ .bytes = &[_]u8{ 0x00, 0x01, 0x02, 0x03 } } },
        } } },
    } };
    const replaced = try set(std.testing.allocator, with_subtree, "m_VertexData", .{ .obj = &[_]unityz.value.Field{
        .{ .name = "m_VertexCount", .value = .{ .int = 1382 } },
        .{ .name = "m_Data", .value = .{ .string = "AwD/AA==" } },
    } });
    const vd = testFieldOf(replaced, "m_VertexData").?;
    try std.testing.expectEqual(@as(i64, 1382), testFieldOf(vd, "m_VertexCount").?.int);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0xff, 0x00 }, testFieldOf(vd, "m_Data").?.bytes);
    std.testing.allocator.free(testFieldOf(vd, "m_Data").?.bytes);
    std.testing.allocator.free(vd.obj);

    // Some type trees name plain fields with literal index brackets (a
    // mesh's "m_MeshMetrics[0]" is a float, not an array access); the path
    // parser must not read the brackets as indexing.
    const with_metric = unityz.value.Value{ .obj = &[_]unityz.value.Field{
        .{ .name = "m_MeshMetrics[0]", .value = .{ .float = 1.0 } },
        .{ .name = "m_MeshMetrics[1]", .value = .{ .float = 2.0 } },
        .{ .name = "m_Values", .value = .{ .array = &[_]unityz.value.Value{
            .{ .int = 10 },
            .{ .int = 20 },
        } } },
    } };
    const metric = try set(std.testing.allocator, with_metric, "m_MeshMetrics[0]", .{ .float = 0.5 });
    try std.testing.expectEqual(@as(f64, 0.5), testFieldOf(metric, "m_MeshMetrics[0]").?.float);
    // the ordinary array-index reading still works alongside
    const idx2 = try set(std.testing.allocator, with_metric, "m_Values[1]", .{ .int = 99 });
    try std.testing.expectEqual(@as(i64, 99), testFieldOf(idx2, "m_Values").?.array[1].int);

    // An indexed segment replaces one element and preserves order.
    const indexed = try set(std.testing.allocator, original, "m_Values[1]", .{ .int = 99 });
    const arr = testFieldOf(indexed, "m_Values").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 10), arr[0].int);
    try std.testing.expectEqual(@as(i64, 99), arr[1].int);
    try std.testing.expectEqual(@as(i64, 30), arr[2].int);

    // PPtrs are stored compactly but expose m_FileID / m_PathID for descent;
    // the untouched half of the pair carries over.
    const repointed = try set(std.testing.allocator, original, "m_Script.m_PathID", .{ .int = 1234 });
    try std.testing.expectEqual(@as(i64, 1234), testFieldOf(repointed, "m_Script").?.pptr.path_id);
    try std.testing.expectEqual(@as(i32, 0), testFieldOf(repointed, "m_Script").?.pptr.file_id);
    const refiled = try set(std.testing.allocator, original, "m_Script.m_FileID", .{ .int = 3 });
    try std.testing.expectEqual(@as(i32, 3), testFieldOf(refiled, "m_Script").?.pptr.file_id);
    try std.testing.expectEqual(@as(i64, 42), testFieldOf(refiled, "m_Script").?.pptr.path_id);

    // Every way a path can fail to name an existing leaf is BadPath, so a
    // typo never silently appends a field or drops the edit.
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "nope", .{ .int = 1 }));
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "m_Sub.nope", .{ .int = 1 }));
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "m_Values[3]", .{ .int = 1 })); // past the end
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "m_Name.x", .{ .int = 1 })); // scalar has no fields
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "m_Sub[0]", .{ .int = 1 })); // obj is not an array
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "m_Script.m_Other", .{ .int = 1 }));
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "m_Script.m_PathID.x", .{ .int = 1 }));
    // a PPtr half only accepts an integer-like value
    try std.testing.expectError(error.BadPath, set(std.testing.allocator, original, "m_Script.m_PathID", .{ .string = "x" }));
}

test "applyNodeBytes replaces a raw node range from base64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };

    // A mid-node range is replaced, the rest survives untouched.
    const patched = try applyNodeBytes(a, &node, .{
        .name = "CAB-x.resS",
        .value = .{
            .obj = &[_]unityz.value.Field{
                .{ .name = "offset", .value = .{ .int = 2 } },
                .{ .name = "bytes", .value = .{ .string = "AwD/" } }, // {0x03,0x00,0xff}
            },
        },
    });
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x03, 0x00, 0xff, 0x05, 0x06, 0x07 }, patched);

    // Out-of-range writes are rejected so sidecar references stay valid.
    try std.testing.expectError(error.BadPatchValue, applyNodeBytes(a, &node, .{ .name = "CAB-x.resS", .value = .{ .obj = &[_]unityz.value.Field{
        .{ .name = "offset", .value = .{ .int = 7 } },
        .{ .name = "bytes", .value = .{ .string = "AwD/" } },
    } } }));
    try std.testing.expectError(error.BadPatchValue, applyNodeBytes(a, &node, .{
        .name = "CAB-x.resS",
        .value = .{
            .obj = &[_]unityz.value.Field{
                .{ .name = "offset", .value = .{ .int = 0 } },
                .{ .name = "bytes", .value = .{ .string = "AwD/AA==AwD/AA==" } }, // 12 bytes > node
            },
        },
    }));
    // a malformed literal is rejected (the length check fires first when
    // the bad text decodes to a size that does not fit)
    try std.testing.expectError(error.BadPatchValue, applyNodeBytes(a, &node, .{ .name = "CAB-x.resS", .value = .{ .obj = &[_]unityz.value.Field{
        .{ .name = "offset", .value = .{ .int = 0 } },
        .{ .name = "bytes", .value = .{ .string = "!!!not-base64!!!" } },
    } } }));
    // the value must be an object of exactly offset + bytes
    try std.testing.expectError(error.BadPatchValue, applyNodeBytes(a, &node, .{ .name = "CAB-x.resS", .value = .{ .string = "AwD/" } }));
    try std.testing.expectError(error.BadPatchValue, applyNodeBytes(a, &node, .{ .name = "CAB-x.resS", .value = .{ .obj = &[_]unityz.value.Field{
        .{ .name = "offset", .value = .{ .int = 0 } },
        .{ .name = "what", .value = .{ .int = 1 } },
    } } }));
    // a node-path key vs a numeric path-id key
    try std.testing.expect(isRawNodeKey("CAB-abc.resS"));
    try std.testing.expect(isRawNodeKey("CAB-abc123.resource"));
    try std.testing.expect(!isRawNodeKey("44"));
    try std.testing.expect(!isRawNodeKey("CAB-abc:44"));
}

test "checkStreamRef flags broken streaming references" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sidecars = [_]Sidecar{
        .{ .path = "CAB-abc.resS", .data = &[_]u8{0} ** 100 },
    };
    const mk_info = struct {
        fn modern(al: std.mem.Allocator, offset: i64, size: i64, path: []const u8) !unityz.value.Value {
            const fields = try al.alloc(unityz.value.Field, 3);
            fields[0] = .{ .name = "offset", .value = .{ .int = offset } };
            fields[1] = .{ .name = "size", .value = .{ .int = size } };
            fields[2] = .{ .name = "path", .value = .{ .string = path } };
            return .{ .obj = fields };
        }
        fn legacy(al: std.mem.Allocator, offset: i64, size: i64, source: []const u8) !unityz.value.Value {
            const fields = try al.alloc(unityz.value.Field, 3);
            fields[0] = .{ .name = "m_Offset", .value = .{ .int = offset } };
            fields[1] = .{ .name = "m_Size", .value = .{ .int = size } };
            fields[2] = .{ .name = "m_Source", .value = .{ .string = source } };
            return .{ .obj = fields };
        }
    };

    const run = struct {
        fn go(arena: std.mem.Allocator, info: unityz.value.Value, sc: []const Sidecar) !VerifyReport {
            var report: VerifyReport = .{};
            _ = try checkStreamRef(arena, info, "CAB-abc", 7, 1000, sc, &report, undefined, true);
            return report;
        }
    }.go;

    // A reference that fits inside its sidecar is fine (both shapes).
    var ok = try run(a, try mk_info.modern(a, 10, 90, "archive:/CAB-abc/CAB-abc.resS"), &sidecars);
    try std.testing.expectEqual(@as(usize, 0), ok.failed);
    ok = try run(a, try mk_info.legacy(a, 10, 90, "archive:/CAB-abc/CAB-abc.resS"), &sidecars);
    try std.testing.expectEqual(@as(usize, 0), ok.failed);
    // zero size: embedded or cleared, not streamed
    ok = try run(a, try mk_info.modern(a, 0, 0, ""), &sidecars);
    try std.testing.expectEqual(@as(usize, 0), ok.failed);

    // Out of range and missing sidecar are flagged with the reason.
    var bad = try run(a, try mk_info.modern(a, 0, 999999, "archive:/CAB-abc/CAB-abc.resS"), &sidecars);
    try std.testing.expectEqual(@as(usize, 1), bad.failed);
    try std.testing.expect(std.mem.indexOf(u8, bad.failures.items[0].message, "exceeds sidecar") != null);
    bad = try run(a, try mk_info.legacy(a, 0, 10, "archive:/CAB-abc/CAB-abc.nope.resS"), &sidecars);
    try std.testing.expectEqual(@as(usize, 1), bad.failed);
    try std.testing.expect(std.mem.indexOf(u8, bad.failures.items[0].message, "no sidecar node") != null);
    // path-less references must fit in the file itself
    bad = try run(a, try mk_info.modern(a, 990, 20, ""), &sidecars);
    try std.testing.expectEqual(@as(usize, 1), bad.failed);
    try std.testing.expect(std.mem.indexOf(u8, bad.failures.items[0].message, "exceeds file length") != null);
    // a non-object is not a streaming reference
    ok = try run(a, .{ .int = 5 }, &sidecars);
    try std.testing.expectEqual(@as(usize, 0), ok.failed);

    // The recursive scan finds references nested in arrays/objects. The
    // tree is arena-built: value trees with runtime values cannot use
    // stack-temporary array literals (they dangle once the expression
    // ends, and the pointer escapes the function that built them).
    const clip_fields = try a.alloc(unityz.value.Field, 1);
    clip_fields[0] = .{ .name = "m_Resource", .value = try mk_info.legacy(a, 0, 999999, "archive:/CAB-abc/CAB-abc.resS") };
    const clips = try a.alloc(unityz.value.Value, 1);
    clips[0] = .{ .obj = clip_fields };
    const root_fields = try a.alloc(unityz.value.Field, 1);
    root_fields[0] = .{ .name = "m_Clips", .value = .{ .array = clips } };
    const tree = unityz.value.Value{ .obj = root_fields };
    var scan_report: VerifyReport = .{};
    const fails = try scanStreamingRefs(a, tree, "CAB-abc", 42, 1000, &sidecars, &scan_report, undefined, true);
    try std.testing.expectEqual(@as(usize, 1), fails);
    try std.testing.expectEqual(@as(usize, 1), scan_report.failed);
}

/// MonoScript flat type tree (preorder), the shape a `--trees` file carries
/// for a built-in class: header + fields, no child list (derived by level).
fn monoScriptFlatNodes(a: std.mem.Allocator) ![]unityz.typetree.Node {
    var flat: std.ArrayList(unityz.typetree.Node) = .empty;
    const n = struct {
        fn add(list: *std.ArrayList(unityz.typetree.Node), al: std.mem.Allocator, level: u32, type_name: []const u8, name: []const u8, meta_flags: i32) !void {
            try list.append(al, .{ .level = level, .type_name = type_name, .name = name, .meta_flags = meta_flags });
        }
    };
    try n.add(&flat, a, 0, "MonoScript", "Base", 32768);
    try n.add(&flat, a, 1, "string", "m_Name", 557057);
    try n.add(&flat, a, 2, "Array", "Array", 540673);
    try n.add(&flat, a, 3, "int", "size", 524289);
    try n.add(&flat, a, 3, "char", "data", 524289);
    try n.add(&flat, a, 1, "int", "m_ExecutionOrder", 16);
    try n.add(&flat, a, 1, "Hash128", "m_PropertiesHash", 16);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try n.add(&flat, a, 2, "UInt8", try std.fmt.allocPrint(a, "bytes[{d}]", .{i}), 16);
    }
    try n.add(&flat, a, 1, "string", "m_ClassName", 32784);
    try n.add(&flat, a, 2, "Array", "Array", 16401);
    try n.add(&flat, a, 3, "int", "size", 17);
    try n.add(&flat, a, 3, "char", "data", 17);
    try n.add(&flat, a, 1, "string", "m_Namespace", 32784);
    try n.add(&flat, a, 2, "Array", "Array", 16401);
    try n.add(&flat, a, 3, "int", "size", 17);
    try n.add(&flat, a, 3, "char", "data", 17);
    try n.add(&flat, a, 1, "string", "m_AssemblyName", 32784);
    try n.add(&flat, a, 2, "Array", "Array", 16401);
    try n.add(&flat, a, 3, "int", "size", 17);
    try n.add(&flat, a, 3, "char", "data", 17);
    return flat.toOwnedSlice(a);
}

/// Serialized bytes of one MonoScript object, laid out exactly as the
/// object_reader reads it with the monoScriptFlatNodes tree (v22, little).
fn monoScriptPayload(a: std.mem.Allocator) ![]u8 {
    var w: unityz.streams.Writer = .init(a);
    defer w.deinit();
    try w.writeInt(i32, 4);
    try w.writeBytes("Test");
    try w.alignTo4();
    try w.writeInt(i32, 0); // m_ExecutionOrder
    try w.writeBytes(&[_]u8{0} ** 16); // m_PropertiesHash
    try w.writeInt(i32, 7);
    try w.writeBytes("MyClass");
    try w.alignTo4();
    try w.writeInt(i32, 0); // m_Namespace ""
    try w.alignTo4();
    try w.writeInt(i32, 15);
    try w.writeBytes("Assembly-CSharp");
    try w.alignTo4();
    return a.dupe(u8, w.getWritten());
}

/// A minimal v22 serialized file with `enable_type_tree = 0` (a Mono build
/// strips the trees): one MonoScript type, one object holding `payload`.
fn typelessMonoFixture(a: std.mem.Allocator, payload: []const u8) ![]u8 {
    var meta: unityz.streams.Writer = .init(a);
    defer meta.deinit();
    try meta.writeStringToNull("2020.1.0f1"); // unity_version
    try meta.writeInt(i32, 3); // target_platform
    try meta.writeByte(0); // enable_type_tree = false: no trees follow
    try meta.writeInt(i32, 1); // one type
    try meta.writeInt(i32, 115); // class_id MonoScript
    try meta.writeByte(0); // is_stripped (v16+)
    try meta.writeInt(i16, -1); // script_type_index (v17+)
    try meta.writeBytes(&[_]u8{0} ** 16); // old_type_hash (v13+)
    try meta.writeInt(i32, 1); // one object
    try meta.alignTo4(); // object records are 4-aligned (v7+)
    try meta.writeInt(i64, 1); // path_id
    try meta.writeInt(i64, 0); // rel_start
    try meta.writeInt(u32, @intCast(payload.len)); // size
    try meta.writeInt(u32, 0); // type_index
    try meta.writeInt(i32, 0); // script types (v11+)
    try meta.writeInt(i32, 0); // externals
    try meta.writeInt(i32, 0); // ref types (v20+)
    try meta.writeStringToNull(""); // user info

    var out: unityz.streams.Writer = .init(a);
    defer out.deinit();
    const meta_len: u32 = @intCast(meta.getWritten().len);
    const data_offset: u64 = 48 + meta_len;
    const file_size: u64 = data_offset + payload.len;
    try out.writeIntWith(u32, 0, .big); // metadata_size placeholder
    try out.writeIntWith(u32, 0, .big); // file_size placeholder
    try out.writeIntWith(u32, 22, .big); // version
    try out.writeIntWith(u32, 0, .big); // data_offset placeholder
    try out.writeByte(0); // endianness: little
    try out.writeBytes(&[_]u8{ 0xa1, 0xb2, 0xc3 }); // reserved
    try out.writeIntWith(u32, meta_len, .big); // metadata_size
    try out.writeIntWith(i64, @intCast(file_size), .big);
    try out.writeIntWith(i64, @intCast(data_offset), .big);
    try out.writeIntWith(i64, 7, .big); // unknown
    try out.writeBytes(meta.getWritten());
    try out.writeBytes(payload);
    return a.dupe(u8, out.getWritten());
}

test "editSerializedPatches decodes a typeless file via injected trees" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const payload = try monoScriptPayload(a);
    const sf_bytes = try typelessMonoFixture(a, payload);

    // The injected table: class 115 -> the MonoScript tree. This is what
    // `--trees file.json` provides for a Mono build; without it the patch
    // must fail (the file itself carries no type trees).
    var inj: InjectedTrees = .{};
    try inj.class_ids.put(a, 115, "MonoScript");
    const tree = try unityz.typetree.fromFlatNodes(a, try monoScriptFlatNodes(a));
    const tp = try a.create(unityz.typetree.TypeTree);
    tp.* = tree;
    try inj.trees.put(a, "MonoScript", tp);

    // Without the table the decode rejects the object (no crash).
    try std.testing.expectError(error.MissingTypeIndex, editSerializedPatches(a, sf_bytes, &.{
        .{ .name = "1", .value = .{ .obj = &.{.{ .name = "m_Name", .value = .{ .string = "Patched" } }} } },
    }, "test.assets", null));

    // With the injected tree the field is patched and the file rewritten.
    const entries = [_]unityz.value.Field{
        .{ .name = "1", .value = .{ .obj = &[_]unityz.value.Field{
            .{ .name = "m_Name", .value = .{ .string = "Patched" } },
        } } },
    };
    const rewritten = try editSerializedPatches(a, sf_bytes, &entries, "test.assets", &inj);

    // Decode the rewritten object through the injected tree: the edit landed
    // and the untouched fields survived byte-for-byte in shape.
    const sf2 = try unityz.serialized.parse(a, rewritten);
    const o = sf2.findObject(1).?;
    const data = sf2.objectData(o).?;
    const tree2 = (injectedTreeFor(a, &inj, &sf2, "test.assets", o.class_id, data)).?;
    var r = unityz.streams.Reader.init(data);
    r.endian = sf2.endian;
    const v = try unityz.object_reader.readObject(a, &r, &tree2.roots[0]);
    try std.testing.expectEqualStrings("Patched", testFieldOf(v, "m_Name").?.string);
    try std.testing.expectEqual(@as(i64, 0), testFieldOf(v, "m_ExecutionOrder").?.int);
    try std.testing.expectEqualStrings("MyClass", testFieldOf(v, "m_ClassName").?.string);
}

test "appendScriptEntry flattens MonoScript metadata for scripts.json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Hash128 decodes as bytes[0..15] int children; each byte i.
    const hash_fields = try a.alloc(unityz.value.Field, 16);
    for (hash_fields, 0..) |*f, i| {
        f.* = .{ .name = try std.fmt.allocPrint(a, "bytes[{d}]", .{i}), .value = .{ .int = @intCast(i) } };
    }
    const fields = try a.alloc(unityz.value.Field, 6);
    fields[0] = .{ .name = "m_Name", .value = .{ .string = "MyScript" } };
    fields[1] = .{ .name = "m_ExecutionOrder", .value = .{ .int = 5 } };
    fields[2] = .{ .name = "m_PropertiesHash", .value = .{ .obj = hash_fields } };
    fields[3] = .{ .name = "m_ClassName", .value = .{ .string = "MyClass" } };
    fields[4] = .{ .name = "m_Namespace", .value = .{ .string = "My.Ns" } };
    fields[5] = .{ .name = "m_AssemblyName", .value = .{ .string = "Assembly-CSharp" } };
    const v = unityz.value.Value{ .obj = fields };

    var scripts: std.ArrayList(ScriptEntry) = .empty;
    try appendScriptEntry(a, &scripts, v, 42, null);
    try std.testing.expectEqual(@as(usize, 1), scripts.items.len);
    try std.testing.expectEqual(@as(i64, 42), scripts.items[0].path_id);
    try std.testing.expectEqualStrings("MyScript", std.mem.trimEnd(u8, scripts.items[0].name, "\x00"));
    try std.testing.expectEqual(@as(i64, 5), scripts.items[0].execution_order);
    try std.testing.expectEqualStrings("MyClass", std.mem.trimEnd(u8, scripts.items[0].class_name, "\x00"));
    try std.testing.expectEqualStrings("My.Ns", std.mem.trimEnd(u8, scripts.items[0].namespace, "\x00"));
    // bytes[i] = i, so the raw hash is 00..0f.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f }, scripts.items[0].properties_hash);
}

test "writeShaderText emits a ShaderLab reconstruction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // One color property with all four defaults.
    const prop = try a.alloc(unityz.value.Field, 5);
    prop[0] = .{ .name = "m_Name", .value = .{ .string = "_Color" } };
    prop[1] = .{ .name = "m_Description", .value = .{ .string = "Main Color" } };
    prop[2] = .{ .name = "m_Type", .value = .{ .int = 0 } };
    prop[3] = .{ .name = "m_DefValue[0]", .value = .{ .int = 1 } };
    prop[4] = .{ .name = "m_DefValue[3]", .value = .{ .int = 1 } };
    const props = try a.alloc(unityz.value.Value, 1);
    props[0] = .{ .obj = prop };
    const prop_info_fields = try a.alloc(unityz.value.Field, 1);
    prop_info_fields[0] = .{ .name = "m_Props", .value = .{ .array = props } };

    // One pass: state name FORWARD, tags, and a vertex program with 5
    // compiled variants across two platforms.
    const tag_pair = try a.alloc(unityz.value.Value, 2);
    tag_pair[0] = .{ .string = "RenderType" };
    tag_pair[1] = .{ .string = "Opaque" };
    const tag_pairs = try a.alloc(unityz.value.Value, 1);
    tag_pairs[0] = .{ .array = tag_pair };
    const tags_fields = try a.alloc(unityz.value.Field, 1);
    tags_fields[0] = .{ .name = "tags", .value = .{ .array = tag_pairs } };

    const state_fields = try a.alloc(unityz.value.Field, 1);
    state_fields[0] = .{ .name = "m_Name", .value = .{ .string = "FORWARD" } };

    const plat0 = try a.alloc(unityz.value.Value, 3);
    plat0[0] = .{ .int = 0 };
    plat0[1] = .{ .int = 0 };
    plat0[2] = .{ .int = 0 };
    const plat1 = try a.alloc(unityz.value.Value, 2);
    plat1[0] = .{ .int = 0 };
    plat1[1] = .{ .int = 0 };
    const platforms = try a.alloc(unityz.value.Value, 2);
    platforms[0] = .{ .array = plat0 };
    platforms[1] = .{ .array = plat1 };
    const prog_fields = try a.alloc(unityz.value.Field, 1);
    prog_fields[0] = .{ .name = "m_PlayerSubPrograms", .value = .{ .array = platforms } };

    const pass = try a.alloc(unityz.value.Field, 4);
    pass[0] = .{ .name = "m_State", .value = .{ .obj = state_fields } };
    pass[1] = .{ .name = "m_Tags", .value = .{ .obj = tags_fields } };
    pass[2] = .{ .name = "progVertex", .value = .{ .obj = prog_fields } };
    pass[3] = .{ .name = "progFragment", .value = .{ .obj = prog_fields } };
    const passes = try a.alloc(unityz.value.Value, 1);
    passes[0] = .{ .obj = pass };

    const sub = try a.alloc(unityz.value.Field, 3);
    sub[0] = .{ .name = "m_Tags", .value = .{ .obj = tags_fields } };
    sub[1] = .{ .name = "m_LOD", .value = .{ .int = 200 } };
    sub[2] = .{ .name = "m_Passes", .value = .{ .array = passes } };
    const subs = try a.alloc(unityz.value.Value, 1);
    subs[0] = .{ .obj = sub };

    const pf = try a.alloc(unityz.value.Field, 4);
    pf[0] = .{ .name = "m_Name", .value = .{ .string = "MyShader" } };
    pf[1] = .{ .name = "m_FallbackName", .value = .{ .string = "Diffuse" } };
    pf[2] = .{ .name = "m_PropInfo", .value = .{ .obj = prop_info_fields } };
    pf[3] = .{ .name = "m_SubShaders", .value = .{ .array = subs } };

    const root = try a.alloc(unityz.value.Field, 1);
    root[0] = .{ .name = "m_ParsedForm", .value = .{ .obj = pf } };
    const v = unityz.value.Value{ .obj = root };

    const text = try writeShaderText(a, v);
    try std.testing.expect(std.mem.indexOf(u8, text, "Shader \"MyShader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Properties") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_Color (\"Main Color\", Color) = (1,0,0,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tags { \"RenderType\" = \"Opaque\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "LOD 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Name \"FORWARD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "//   vertex: 5 variant(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Fallback \"Diffuse\"") != null);
}
