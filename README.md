# unityz

A Zig library and CLI for reading, extracting, and editing Unity assets.

## Quick start

Requires [Zig](https://ziglang.org/) 0.16.0.

```bash
git clone https://github.com/hordeforge/unityz
cd unityz
zig build test
zig build
```

```bash
./zig-out/bin/unityz --help
./zig-out/bin/unityz info path/to/asset
./zig-out/bin/unityz extract path/to/asset
./zig-out/bin/unityz edit path/to/asset 100 m_Count 99
./zig-out/bin/unityz verify path/to/asset
./zig-out/bin/unityz stats path/to/asset
./zig-out/bin/unityz find path/to/asset Player
./zig-out/bin/unityz show path/to/asset 100
./zig-out/bin/unityz diff asset_a asset_b
```

Linux (x86_64) and macOS (aarch64) are built and tested in CI. The
parsers make no host-endianness or word-size assumptions, so other
targets `zig build -Dtarget=...` accepts should work but are not
covered by CI. CI also blocks on formatting and shell lint:

```bash
zig fmt --check build.zig src
shellcheck scripts/*.sh
```

## What you can do

- **Look inside any Unity asset** - open a bundle, `.assets` file, or
  sidecar and see its containers, objects, and type trees (`info`, `show`).
- **Extract everything** - textures and sprites as images, meshes as OBJ,
  audio as playable files (OGG/FSB/WAV), video cutscenes as MP4, terrain
  heightmaps as PGM, readable ShaderLab for shaders, fonts, and structured
  JSON for most other classes (animations, animator controllers, mixers,
  particle systems, materials, script registries).
- **Edit in place** - change any field of any object, patch streamed
  sidecar bytes, and get byte-exact output that re-verifies before it
  writes (`edit`).
- **Check and compare** - round-trip every object byte-exactly, validate
  streamed references, and diff two files down to the changed pixel,
  audio sample, or field path (`verify`, `diff`).
- **Understand a game** - per-class stats, name/class search, scene
  hierarchy, shader skinning analysis, and the script registry
  (`stats`, `find`, `hierarchy`, `skin`).
- **Work with Mono builds** - decode typeless files via injected type
  trees, or read the game's .NET assemblies directly to list every
  MonoBehaviour's serialized fields (`--trees`, `managed`).

Every command accepts a directory and processes all files in it, and
`--json` modes cover the machine-readable commands. See
[docs/features.md](docs/features.md) for the full capability reference.

## Commands

- `info` - what unityz can read from a file
- `extract` - pull out embedded assets (filters: `--class`, `--path-id`,
  `--name`, `--raw`; `--json` value trees + manifest; `--summary` dry run)
- `edit` - change fields, patch sidecars, verify before writing
- `verify` - byte-exact round-trip check of every object, non-zero exit
  on failure
- `stats` - per-class sizes and duplicate-object detection
- `find` - name/class search over objects (`--any` searches every string
  field)
- `show` - one object as JSON, or a hex dump with `--raw`
- `diff` - compare two files or directories by content hash, with
  optional decoded passes: `--pixels` (texture/sprite pixel diffs),
  `--audio` (streamed audio), `--fields` (exact changed field paths)
- `hash` - per-object content fingerprints
- `skin` - whether every Shader's vertex stage applies bone matrices
- `hierarchy` - the GameObject/Transform tree of a scene
- `shader` - a Shader's decoded compiled sub-program blob table
- `fsb` - decode a raw FSB5 audio bank to playable WAV/OGG
- `managed` - read a Mono build's assemblies and list every
  MonoBehaviour's serialized field layout, straight from the .NET
  metadata with no runtime

### Typeless files

Mono builds strip class type trees, leaving typeless objects
undecodable. `--trees <file.json>` supplies them, and `extract`, `show`,
`verify`, `find`, `skin`, `hierarchy`, and `edit` all decode with the
injected trees. The trees JSON shape is what
`TypeTreeGeneratorAPI.get_nodes_as_json()` emits; `scripts/structsdump-to-trees.py`
converts AssetRipper's public type-tree dumps into the format. Without
trees, a typeless file reports how many objects were skipped.

### Editing

`edit` sets fields by dotted-indexed path, byte-array fields take base64
values, `--verify` round-trip-checks the result before writing, and
`--trees` makes typeless files editable. `edit --patch <file>` applies a
JSON patch atomically. Edits reserialize byte-exactly; rebuilt bundles
keep their compression.

## What it is

- a **library** (`src/lib.zig`, imported as `@import("unityz")`) with
  parsers for Unity's asset formats, and
- a **CLI** (`src/main.zig`, `unityz`) with the subcommands above;
  `unityz --help` is the authoritative flag reference.

Targeted formats: SerializedFile (`.assets`), asset bundles (`.unity3d` /
`.bundle`), and `.resources` / `.resS` sidecar files. The rare
UnityArchive container is detected but not yet parsed.

## Layout

- `src/lib.zig` - library root: public API surface
- `src/main.zig` - CLI entry point and subcommand dispatch
- `src/streams.zig` - endian-aware binary reader/writer
- `src/container.zig` - file type detection by magic/header
- `src/webfile.zig` - WebFile container parser and rebuilder
- `src/bundle.zig` - UnityFS bundle parser (with LZ4/LZMA blocks)
- `src/lz4.zig` - LZ4 block decompression
- `src/serialized.zig` - SerializedFile parser (`.assets` and friends)
- `src/serialized_writer.zig` - SerializedFile rebuild writer
- `src/typetree.zig` - TypeTree parsing + Unity common-string table
- `src/value.zig` - generic object value model + JSON output
- `src/object_reader.zig` - type-tree-driven object reader
- `src/object_writer.zig` - type-tree-driven object writer
- `src/classes.zig` - typed views for the common classes
- `src/dotnet.zig` - .NET assembly metadata reader (the `managed`
  command)
- `src/fsb5.zig` - FSB5 audio bank metadata parser
- `src/audio.zig` - FSB5 sample decoding to 16-bit PCM, no external tools
- `src/vorbis.zig` - FSB5 Vorbis to playable Ogg reconstruction, no
  external tools
- `src/shader.zig` - Shader sub-program blob decoding and skinning
  detection
- `src/texture.zig` - texture format decoding to RGBA8 (DXT, BC, PVRTC,
  ATC, EAC, ETC, ASTC, crunch, and the raw half/float/16-bit formats)
- `src/png.zig`, `src/tga.zig`, `src/bmp.zig` - minimal image encoders
- `src/vendor/unitycrunch/` - vendored unitycrunch decompressor (ZLIB)
- `src/vendor/lzham/` - vendored LZHAM decompressor (MIT)
- `build.zig`, `build.zig.zon` - package metadata and build steps

## Docs

- [docs/features.md](docs/features.md) - the full capability reference
- [docs/ROADMAP.md](docs/ROADMAP.md) - what is current, planned, shipped
- [docs/WORKFLOW.md](docs/WORKFLOW.md) - the delivery lifecycle
- [docs/INDEX.md](docs/INDEX.md) - index of all durable records
