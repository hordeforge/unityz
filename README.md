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

Run the CLI:

```bash
./zig-out/bin/unityz --help
./zig-out/bin/unityz info path/to/asset
./zig-out/bin/unityz info path/to/asset --dump
./zig-out/bin/unityz extract path/to/asset
./zig-out/bin/unityz edit path/to/asset 100 m_Count 99
./zig-out/bin/unityz verify path/to/asset
./zig-out/bin/unityz stats path/to/asset
./zig-out/bin/unityz find path/to/asset Player
./zig-out/bin/unityz show path/to/asset 100
./zig-out/bin/unityz hash path/to/asset
./zig-out/bin/unityz diff asset_a asset_b
./zig-out/bin/unityz skin path/to/asset
```

Beyond the core `info`/`extract`/`edit`, the CLI adds capabilities UnityPy
does not offer:

- `verify` - read every object through its type tree, write it back, compare
  bytes; non-zero exit on failure
- `stats` - per-class sizes and duplicate-object detection
- `find` - name/class search, with `--exact` for whole-name lookups and
  `--any` to search every string field (e.g. AssetBundle container paths)
- `show` - one object as JSON, or a hex dump of its bytes with `--raw`
- `diff` - compare two files' objects by content hash, scoped with
  `--class`, or two directories file-by-file
- `hash` - per-object content fingerprints
- `skin` - whether every Shader's vertex stage applies per-vertex bone
  matrices, exiting non-zero when a `SkinnedMeshRenderer` references a
  shader that does not

`diff` gains `--pixels`: every matched Texture2D and Sprite is decoded
from both files (sprites rendered through their crop rect, packed
rotation, alpha merge, and mesh; `.resS` sidecars inside the containers
resolved) and reported with a per-channel pixel-difference count and max
delta. `--audio` does the same for AudioClips, comparing their resolved
stream data (embedded or `.resource` sidecar slices). Both passes run on
matched objects, not only changed ones, so edits to streamed data -
which never touch an object's serialized bytes and change no content
hash - are caught. Directory diffs apply the passes to every matched
file pair.

All commands accept a directory and process every file in it.

`extract` filters with `--class`/`--path-id`/`--name <substring>`/`--raw`
(case-insensitive name match on `m_Name`, combinable with the others),
exports value trees with
`--json` (plus a `manifest.json` index of every exported object; inside
bundles/webfiles each node's objects land in its own `objects/<node>/`
subdirectory so identical path ids never collide), and
auto-creates `--outdir <dir>`.

Textures and sprites export as PNG by default or TGA / BMP / raw RGBA8
with `--format tga|bmp|raw` (UnityPy only writes PNG). SpriteAtlas
objects export as a JSON mapping packed sprite path ids to names (so
extracted sprite PNGs can be matched back to their atlas slots), and
each AssetBundle's `m_Container` exports as a JSON manifest of asset
paths to object ids (what is in this bundle, under which path).

`edit` supports
dotted-indexed field paths, `--out <file>`, and `--verify`, which
round-trip-checks the edited output and refuses to write if it does not
pass (UnityPy edits never self-check).

Inside bundles and webfiles, every object belongs to a container node,
and the tool is node-aware throughout: outputs tag objects with their
node, and `show`/`edit`/`verify`/`extract`/`hash` accept `node:path-id`
selectors (e.g. `show bundle.unity3d CAB-abc123:7` or
`edit bundle.unity3d CAB-abc123:7 m_Name "renamed"`) so colliding path
ids in different nodes can be targeted individually.

`info`, `stats`, `hash`, `find`, `diff`, `verify`, and `skin` also have a
`--json` mode for scripting:

- `info --json` - summarizes a file or container (adding `--objects`
  includes the per-object table, tagged with its container node; serialized
  files list their sidecar `externals_list`; each shader gets a `skins`
  verdict and its bind-channel / bone-matrix evidence)
- `stats --json` - per-class sizes and duplicates
- `hash --json` - per-object content fingerprints
- `find --json` - matching objects as a JSON array
- `diff --json` - the changed/new/deleted objects (or files, for directory
  diffs) with counts, scoped to one class with `--class <id>` where useful
- `verify --json` - a pass/fail report with per-object failure records
- `skin --json` - the per-shader skinning report plus the skinned-mesh
  failures

`hash`, `stats`, and `verify` accept `--class <id>` / `--path-id <id>`
filters; `stats --dups` prints only the duplicate report. Everything else
a script needs is plain text and a non-zero exit code on failure.

## What it is

`unityz` is two things:

- a **library** (`src/lib.zig`, imported as `@import("unityz")`) with parsers
  for Unity's asset formats, and
- a **CLI** (`src/main.zig`, `unityz`) with `info`, `extract`, `edit`,
  `verify`, `stats`, `find`, `show`, `hash`, `diff`, and `skin`
  subcommands for inspecting, pulling out, modifying, checking, and
  comparing assets. `unityz --help` is the authoritative flag reference.

Targeted formats: SerializedFile (`.assets`), asset bundles (`.unity3d` /
`.bundle`), and `.resources` / `.resS` sidecar files.

## Status

The container and file-format parsers have landed: `unityz info` opens
UnityFS bundles, WebFiles, and SerializedFiles (`.assets` and friends)
and prints what it found (header, type tree presence, object table with
per-class counts for serialized files, nodes for bundles). With `--dump`,
objects of a serialized file are read through their type trees and printed
as JSON. Serialized formats 2-22 are supported (version 4 included, whose
legacy recursive type-tree and trailing-metadata layouts are handled);
decompression covers none (uncompressed), LZ4 (in-tree), LZMA (via std),
and LZHAM (vendored decompressor).

The generic object reader is in: object payloads are decoded through
their type trees into a JSON-serializable value model (primitives, strings,
arrays, maps, PPtrs, raw bytes), honoring Unity's alignment and
length-prefix rules.

Texture decoding, reserialization, and the `extract`/`edit` commands have
Texture decoding, reserialization, and the `extract`/`edit` commands have
landed: textures decode to RGBA8 and write as PNG, covering:

- RGB/RGBA8, BGR24, 16-bit R16/RG16, half/float RHalf/RGHalf/RGBAHalf/
  RFloat/RGFloat/RGBAFloat/ARGBFloat/RG32, RGB9e5Float, RGB48/RGBA64, the
  signed variants
- DXT1/3/5, BC4/5, BC6H (HDR), BC7
- PVRTC (2bpp/4bpp RGB and RGBA), ATC (RGB4/RGBA8), EAC (R/RG, signed and
  unsigned)
- ETC1/ETC2/ETC2-RGBA8, ASTC, ASTC HDR (66-71)
- the crunch-crunched formats (ETC_RGB4, ETC2_RGBA8, DXT1, DXT5) through
  a vendored ZLIB-licensed unitycrunch decompressor (hardened against
  corrupt streams)

The 3DS ETC variants (TextureFormat 60/61) decode as ETC1, matching
UnityPy (which routes both to its ETC1 decoder), and ETC2_RGBA1 (46)
decodes its punch-through alpha, matching UnityPy's texture2ddecoder
pixel-for-pixel.

ETC2, the BC family, and the crunch variants decode pixel-identical to
UnityPy (ASTC decodes within ±1 per channel on a small fraction of
pixels, a rounding variance between independent spec-compliant decoders;
UnityPy itself switched from texture2ddecoder to ARM's astc_encoder).

The raw half/float/16-bit formats use standard documented conversions;
UnityPy's converters for those are lossy (its half path truncates x*256
and crashes above 1.0), so unityz is strictly better there.

Texture pixels can be embedded, streamed inside the serialized file, or
streamed from a sibling `.resS` / `.resource` sidecar node, which
`extract` resolves automatically.

ASTC HDR is verified against ARM's astcenc reference instead, because
UnityPy's decoder rejects HDR blocks: HDR lanes decode byte-exact, and
LDR-valued alpha lanes inside HDR blocks differ at most ±1 (astcenc
routes those through an fp16 intermediate; unityz keeps the exact
value).

Sprites packed into a SpriteAtlas
resolve their atlas texture via `m_RenderDataKey` (with a positional
fallback) and crop with Pillow-compatible rounding, so rectangle sprite
exports match UnityPy byte-for-byte. Packed sprites with a separate
alpha texture merge its R channel in as the alpha, the packing rotation
is applied, and tight/polygon sprites render through their sprite mesh
(vertices/UVs/triangles) - either masked to the polygon or texture-mapped,
matching UnityPy's mask_sprite/render_sprite_mesh.

Managed-reference registries decode
through their type trees, MonoBehaviours resolve their MonoScript and
export the raw script payload alongside the decoded managed .NET object
graph (a `.json` sidecar, read off the type tree), Meshes export as
Wavefront OBJ (vertices, normals, UVs, faces), including multi-stream
vertex layouts, Materials and Shaders export as readable text, and
AnimationClips export their curves as JSON (per-curve bone path,
attribute, and keyframes with time, value, and slopes - UnityPy reads
clips generically but never surfaces the curves).

Additionally, each Shader's compiled sub-program blob is decoded and
reported as skinning or not (its vertex stage applies per-vertex bone
matrices), read off the bind-channel block and parameter-blob bindings;
`show`/`shader <path> <node:path-id>` on a Shader decodes the full
sub-program blob: the 12-byte record table, per-record parameter blobs
(constant buffers with member offsets, texture/cbuffer/UAV/sampler
entries) and code blobs (the 38-byte program-data header, the DXBC
chunk set, ISGN input signature, RDEF member offsets, and the trailing
ParserBindChannels block with its (source,target) channel pairs).

AudioClips export their streamed audio (OGG/FSB banks, WAV-wrapped PCM,
MP3) with an FSB5 metadata sidecar (sample rate, channels, loop points,
duration, format - UnityPy never surfaces these). FSB5 banks in the
codecs that decode in pure Zig (PCM8/16/24/32/FLOAT, IMA ADPCM) also
export as a playable WAV with no external tools; Vorbis banks (the
common case) stay as `.fsb` because they carry no codec headers -
UnityPy shells out to ffmpeg for every conversion, so even that is at
parity. Objects reserialize
byte-exactly and can be edited in place
across formats 2-22 (legacy rewrites included).

UnityFS bundles parse
real big-endian files across format versions 6-22 (Unity 5.x through
2022.3, including the older two-string v6 headers, LZ4/LZ4HC blocks, and
both LZMA framings), verified against UnityPy: real Unity 2022.3 CABs
reserialize byte-identically end to end, and the newer container
capabilities are verified the same way: bundles and webfiles (including
gzip-wrapped ones) can be edited in place or via JSON patches, with the
container rebuilt and readable by UnityPy.

The `verify`, `stats`, `find`, `show`, `diff`, and `hash` commands are
covered in the quick start; all commands accept a directory and process
every file in it, and the parsers are fuzz-clean across thousands of
mutated inputs. Crashes found by fuzzing were real and got fixed with
regression tests: a std flate decoder panic on truncated gzip streams,
and an HDR ASTC weight-grid overflow that could wrap the endpoint
interpolation.

## Layout

- `src/lib.zig` - library root: public API surface
- `src/main.zig` - CLI entry point and subcommand dispatch
- `src/streams.zig` - endian-aware binary reader/writer
- `src/container.zig` - file type detection by magic/header
- `src/webfile.zig` - WebFile container parser and rebuilder (transparently
  decompresses gzip-wrapped files)
- `src/bundle.zig` - UnityFS bundle parser (with LZ4/LZMA blocks)
- `src/lz4.zig` - LZ4 block decompression
- `src/serialized.zig` - SerializedFile parser (`.assets` and friends)
- `src/serialized_writer.zig` - SerializedFile rebuild writer (byte-exact
  `edit` output across formats 2-22)
- `src/typetree.zig` - TypeTree parsing + Unity common-string table
- `src/value.zig` - generic object value model + JSON output
- `src/object_reader.zig` - type-tree-driven object reader
- `src/object_writer.zig` - type-tree-driven object writer (byte-exact
  value-model reserialization)
- `src/classes.zig` - typed views for the common classes
- `src/fsb5.zig` - FSB5 audio bank metadata parser (sample rate, channels,
  loop points, format)
- `src/audio.zig` - FSB5 audio sample decoding to 16-bit PCM (PCM8/16/24/
  32/FLOAT, IMA ADPCM), no external tools
- `src/shader.zig` - Shader (class 48) sub-program blob decoding: the LZ4
  per-platform blobs, record table, parameter blobs (constant buffers with
  member offsets, texture/cbuffer/UAV/sampler entries), code blobs (38-byte
  program-data header, DXBC chunk analysis incl. ISGN/RDEF, ParserBindChannels),
  plus skinning detection (BLENDINDICES/BLENDWEIGHT inputs + a bone-matrix
  binding)
- `src/texture.zig` - texture format decoding to RGBA8 (uncompressed
  RGB/RGBA layouts, half/float/16-bit/signed raw formats, DXT1/3/5,
  BC4/5, BC6H, BC7, PVRTC, ATC, EAC, ETC1/ETC2/ETC2-RGBA8, ASTC,
  ASTC HDR (66-71), crunch ETC_RGB4/ETC2_RGBA8/DXT1/DXT5 via
  `src/vendor/unitycrunch/`)
- `src/png.zig` - minimal PNG encoder
- `src/tga.zig` - minimal TGA encoder (uncompressed 32bpp, alpha-carrying)
- `src/bmp.zig` - minimal BMP encoder (32bpp BI_BITFIELDS, alpha-carrying)
- `src/vendor/unitycrunch/` - vendored unitycrunch decompressor
  (ZLIB-licensed C++, built with `-DNDEBUG` so corrupt input can't abort)
- `build.zig`, `build.zig.zon` - package metadata and build steps
