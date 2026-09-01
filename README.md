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

Linux (x86_64) and macOS (aarch64) are built and tested in CI. There is no
host-endianness or word-size assumption in the parsers (every field is read
and written with an explicit byte order), so other targets `zig build
-Dtarget=...` accepts are expected to work, but are not covered by CI.
Windows is untested.

CI also blocks on formatting and shell lint. Run the same checks before
pushing:

```bash
zig fmt --check build.zig src
shellcheck scripts/*.sh
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
./zig-out/bin/unityz fsb path/to/bank.fsb --outdir out/
./zig-out/bin/unityz hash path/to/asset
./zig-out/bin/unityz diff asset_a asset_b
./zig-out/bin/unityz skin path/to/asset
./zig-out/bin/unityz shader path/to/asset 100
./zig-out/bin/unityz hierarchy path/to/asset
```

Beyond the core `info`/`extract`/`edit`, the CLI adds capabilities UnityPy
does not offer:

- `verify` - read every object through its type tree, write it back, compare
  bytes; non-zero exit on failure
- `stats` - per-class sizes and duplicate-object detection
- `find` - name/class search, with `--exact` for case-sensitive whole-name
  lookups (the default substring match is case-insensitive) and `--any` to
  search every string field (e.g. AssetBundle container paths)
- `show` - one object as JSON, or a hex dump of its bytes with `--raw`
- `diff` - compare two files' objects by content hash, scoped with
  `--class`, or two directories file-by-file
- `hash` - per-object content fingerprints
- `skin` - whether every Shader's vertex stage applies per-vertex bone
  matrices, exiting non-zero when a `SkinnedMeshRenderer` references a
  shader that does not
- `hierarchy` - the GameObject/Transform tree of a scene (root transforms
  first, names, component classes, local positions, with bones of any
  SkinnedMeshRenderer marked; `--json` for nested objects)

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

`--fields` goes inside changed objects: it decodes both
value trees and reports the exact fields that differ, with paths like
`m_LocalPosition.y` or `m_Children[0]` and both values.

All commands accept a directory and process every file in it.

`extract` filters with `--class`/`--path-id`/`--name <substring>`/`--raw`
(case-insensitive name match on `m_Name`, combinable with the others),
exports value trees with
`--json` (plus a `manifest.json` index of every exported object; inside
bundles/webfiles each node's objects land in its own `objects/<node>/`
subdirectory so identical path ids never collide), and
auto-creates `--outdir <dir>`.

Mono builds strip the class type trees from serialized files, leaving
typeless objects undecodable. `--trees <file.json>` supplies them: a
JSON table in the shape `TypeTreeGeneratorAPI.get_nodes_as_json()`
emits (per-class flat node lists plus `__class_ids__` for built-in
classes, `__monoscripts__` for script resolution, and
`__script_trees__` for the MonoBehaviour script trees, keyed by
namespace-qualified name so two assemblies sharing a plain class name
do not collide). MonoBehaviours resolve their script via `m_Script`
against the mono-script table; other classes resolve by class name.
`extract`, `show`, and `verify` decode with the injected trees, and
`verify` round-trips them byte-exactly (the Raft 2021.3.45f2 data
files: 38,212/38,213 objects clean; the two exceptions use custom
serialization). A missing or malformed trees file prints a diagnostic
and continues without the trees.

For a bare serialized file, streamed references (`m_StreamData` /
`m_Resource` pointing at a sibling `.resS`/`.resource`) resolve against
the on-disk sidecar files next to it; `extract` and `verify` load them
automatically, so streamed textures/audio export without bundling the
file first.

There is no off-the-shelf generator for this shape, so unityz ships one:
`scripts/structsdump-to-trees.py` converts the public AssetRipper
TypeTreeDumps `StructsDump/release/<version>.dump` into a trees file for
that exact Unity version:

```bash
curl -sL https://raw.githubusercontent.com/AssetRipper/TypeTreeDumps/main/StructsDump/release/2022.3.62f2.dump -o 2022.3.62f2.dump
uv run scripts/structsdump-to-trees.py 2022.3.62f2.dump -o trees-2022.3.62f2.json
./zig-out/bin/unityz extract game.unity3d --recursive --trees trees-2022.3.62f2.json
```

Verified on the real 7DTD bundle (Unity 2022.3.62f2, typeless): 197
textures, 13 sprites, and 6 meshes export, and 1586/1588 objects in
resources.assets round-trip clean - the two exceptions stream from an
external sidecar file, not a decode failure.

Textures and sprites export as PNG by default or TGA / BMP / raw RGBA8
with `--format tga|bmp|raw` (UnityPy only writes PNG). SpriteAtlas
objects export as a JSON mapping packed sprite path ids to names (so
extracted sprite PNGs can be matched back to their atlas slots), and
each AssetBundle's `m_Container` exports as a JSON manifest of asset
paths to object ids (what is in this bundle, under which path).

`edit` supports
dotted-indexed field paths, `--out <file>`, and `--verify`, which
round-trip-checks the edited output and refuses to write if it does not
pass (UnityPy edits never self-check); a rebuilt bundle keeps its
compression (the output block is LZ4-re-encoded when the source was
compressed). Byte-array fields take base64 string values, so raw binary
payloads are patchable, and the conversion is recursive inside replaced
subtrees: an `extract --json` export feeds back through `edit --patch`
byte-exactly.

Streamed Texture2D pixels
(which live in a `.resS` sidecar, leaving the embedded image field
empty) can be de-streamed by patching the image field with the sidecar
bytes and clearing `m_StreamData`; the rebuilt bundle decodes
pixel-identically.

Streamed payloads can also be patched in place: a patch entry keyed by
a raw container node (a `.resS`/`.resource` sidecar) replaces bytes at
an offset without touching the object tree, so an AudioClip's bank
(still referenced by its `m_Resource` offset/size) swaps cleanly:

```json
{"CAB-abc123.resource": {"offset": 4096, "bytes": "<base64>"}}
```

The range must fit inside the node, keeping every sidecar reference
valid.

`verify` round-trips every object and additionally checks that each
streamed reference resolves: a `m_StreamData`/`m_Resource` range must
fit inside the sibling sidecar node it points into (and a path-less
range must fit in the file itself), so an edit that breaks a reference
(a cleared stream whose pixels are still streamed, a sidecar patch
that cut data short) is caught at verify time instead of failing
silently at extract time.

Inside bundles and webfiles, every object belongs to a container node,
and the tool is node-aware throughout: outputs tag objects with their
node, and `show`/`edit`/`verify`/`extract`/`hash` accept `node:path-id`
selectors (e.g. `show bundle.unity3d CAB-abc123:7` or
`edit bundle.unity3d CAB-abc123:7 m_Name "renamed"`) so colliding path
ids in different nodes can be targeted individually.

`info`, `stats`, `hash`, `find`, `diff`, `verify`, `skin`, and
`hierarchy` also have a `--json` mode for scripting:

- `info --json` - summarizes a file or container (adding `--objects`
  includes the per-object table, tagged with its container node and
  each object's name; serialized
  files list their sidecar `externals_list`; each shader gets a `skins`
  verdict and its bind-channel / bone-matrix evidence)
- `stats --json` - per-class sizes and duplicates
- `hash --json` - per-object content fingerprints
- `find --json` - matching objects as a JSON array
- `diff --json` - the changed/new/deleted objects (or files, for directory
  diffs) with counts, scoped to one class with `--class <id>` where
  useful; with `--pixels`/`--audio`/`--fields` the same document carries
  per-object pixel/audio stats and the exact changed fields, and the text
  diagnostics move to stderr, so stdout
  stays a single parseable JSON document
- `verify --json` - a pass/fail report with per-object failure records
- `skin --json` - the per-shader skinning report plus the skinned-mesh
  failures
- `hierarchy --json` - the GameObject/Transform tree as nested objects

`hash` and `verify` accept `--class <id>` / `--path-id <id>` filters,
`stats` accepts `--class <id>`; `stats --dups` prints only the duplicate
report. Everything else
a script needs is plain text and a non-zero exit code on failure.

## What it is

`unityz` is two things:

- a **library** (`src/lib.zig`, imported as `@import("unityz")`) with parsers
  for Unity's asset formats, and
- a **CLI** (`src/main.zig`, `unityz`) with `info`, `extract`, `edit`,
  `verify`, `stats`, `find`, `show`, `hash`, `diff`, `skin`, `shader`,
  and `hierarchy` subcommands for inspecting, pulling out, modifying,
  checking, and comparing assets. `unityz --help` is the authoritative
  flag reference.

Targeted formats: SerializedFile (`.assets`), asset bundles (`.unity3d` /
`.bundle`), and `.resources` / `.resS` sidecar files.

## Status

The container and file-format parsers have landed: `unityz info` opens
UnityFS bundles, WebFiles, and SerializedFiles (`.assets` and friends)
and prints what it found (header, type tree presence, object table with
per-class counts for serialized files, nodes for bundles). With `--dump`,
objects of a serialized file are read through their type trees and printed
as JSON.

Serialized formats 2-22 are supported by the library's parser
(version 4 included, whose legacy recursive type-tree and
trailing-metadata layouts are handled), and container detection covers
all of them, so even bare v4 files are reachable from the CLI.
Decompression covers none (uncompressed), LZ4 (in-tree), LZMA (via
std), and LZHAM (vendored decompressor).

The generic object reader is in: object payloads are decoded through
their type trees into a JSON-serializable value model (primitives, strings,
arrays, maps, PPtrs, raw bytes), honoring Unity's alignment and
length-prefix rules.

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

ETC2, the BC family, the crunch variants, and ASTC decode
pixel-identical to UnityPy: LDR ASTC matches ARM's astcenc byte for byte
(verified on real assets - the banner_1 test bundle's ASTC_RGBA_6x6
texture and its polygon-mesh sprite, whose streamed pixels live in a
.resS sidecar). UnityPy itself switched from texture2ddecoder to ARM's
astc_encoder.

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
graph (a `.json` sidecar, read off the type tree), and Meshes export as
Wavefront OBJ (vertices, normals, UVs, faces), including multi-stream
vertex layouts.

Materials export as readable text plus a structured JSON
(shader reference, render queue, and the saved properties: texture
bindings with scale/offset, floats, colors, ints), Shaders export as
readable text plus a structured JSON (keywords and the subshader/pass
structure with LODs and pass names - useful for real shaders with
passes like ForwardBase/ShadowCaster), and
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
codecs that decode in pure Zig (PCM8/16/24/32/FLOAT, GCADPCM, IMA ADPCM)
also export as a playable WAV with no external tools. A raw FSB5 bank
(as carved out of an FMOD `.bank` file) is decoded the same way by the
`fsb` command: `unityz fsb bank.fsb --outdir out/` writes one
WAV/OGG per sample plus a `bank.json` metadata sidecar - the audio of
any FMOD-driven Unity game, no external tools.

Vorbis banks
(the common case) are remuxed to a playable Ogg in pure Zig - the
vorbis packets come straight from the bank, the identification/comment
headers are synthesized, and the setup header (codebooks + modes) comes
from a CRC-keyed table of FMOD encoder configurations - byte-identical
to Fmod5Sharp's reconstruction and playable by any decoder. UnityPy
shells out to ffmpeg for every conversion, so even that is at parity.

Fonts (class 128) export their embedded TrueType/OpenType data
(`.ttf`/`.otf`, extension from the sfnt magic) plus a metadata sidecar
(metrics, font name list, kerning/rect counts, fallback pointers, and
the embedded size). The font bytes always sit inline in the object in
release binaries, so typeless files - Mono builds strip type trees -
decode from the raw serialized layout with no sidecar lookup; UnityPy
has no font export at all.

ComputeShaders (class 72) export each kernel's compiled payload - DXBC
(D3D11), SPIR-V (Vulkan), or the `#version`-prefixed GLSL source
(OpenGL) - one file per platform variant, plus a descriptor JSON with
thread-group sizes, resource-binding counts, and the constant-buffer
layouts. The typeless raw layout is self-describing, so Mono builds
extract them with no type trees; neither UnityPy nor AssetRipper
handles ComputeShader at all.

Objects reserialize
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
  32/FLOAT, GCADPCM, IMA ADPCM), no external tools
- `src/vorbis.zig` - FSB5 Vorbis (mode 15) to playable Ogg reconstruction:
  headers synthesized, setup header from the crc-keyed table
  (`src/vorbis_headers.bin`), no external tools
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
- `src/vendor/lzham/` - vendored LZHAM decompressor (MIT-licensed C++, for
  UnityFS LZHAM blocks)
- `build.zig`, `build.zig.zon` - package metadata and build steps
