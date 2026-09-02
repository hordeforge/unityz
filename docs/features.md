# Capabilities

Detailed reference for what unityz reads and extracts. The README points
here; `unityz --help` is the authoritative flag reference, and each
capability below was verified against real game data (7DTD, Raft, Valheim,
Stranded Deep, Green Hell, The Forest) unless a verification note says
otherwise.

## Containers and formats

- SerializedFile (`.assets` and friends), formats 2-22 including the
  legacy v4 recursive type-tree layout and 64-bit v22 extension.
- Asset bundles: UnityFS (modern), UnityWeb / UnityRaw (legacy), WebFile
  (`UnityWebData1.0`, gzip-wrapped included), and the rare UnityArchive
  container is detected but not yet parsed (no real sample exists).
- `.resources` / `.resS` sidecar files, resolved automatically for
  streamed references.
- Big-endian bundles (Unity 5.x through 2022.3) parse, reserialize
  byte-identically, and are cross-checked against UnityPy.
- Decompression: none (uncompressed), LZ4 (in-tree), LZMA (via std),
  LZHAM (vendored decompressor).

## Object model

Every object payload decodes through its type tree into a
JSON-serializable value model: primitives, strings, arrays, maps, PPtrs,
and raw bytes, honoring Unity's alignment and length-prefix rules.
Objects reserialize byte-exactly (formats 2-22) and can be edited in
place. All parsers are fuzz-clean across thousands of mutated inputs;
crashes found by fuzzing were real and shipped with regression tests.

## Texture decoding

Decodes to RGBA8, exports as PNG by default, or TGA / BMP / raw RGBA8
with `--format`:

- RGB/RGBA8, BGR24, 16-bit R16/RG16, half/float RHalf/RGHalf/RGBAHalf/
  RFloat/RGFloat/RGBAFloat/ARGBFloat/RG32, RGB9e5Float, RGB48/RGBA64,
  and the signed variants
- DXT1/3/5, BC4/5, BC6H (HDR), BC7
- PVRTC (2bpp/4bpp RGB and RGBA), ATC (RGB4/RGBA8), EAC (R/RG, signed
  and unsigned)
- ETC1/ETC2/ETC2-RGBA8, ASTC, ASTC HDR (66-71)
- Crunch-crunched formats (ETC_RGB4, ETC2_RGBA8, DXT1, DXT5) via a
  vendored ZLIB-licensed unitycrunch decompressor, hardened against
  corrupt streams

Pixel-identical to UnityPy for ETC2, the BC family, the crunch variants,
and ASTC (LDR ASTC matches ARM's astcenc byte for byte; ASTC HDR is
verified against astcenc since UnityPy rejects HDR blocks). The raw
half/float/16-bit formats use standard documented conversions where
UnityPy's converters are lossy.

Texture pixels can be embedded, streamed inside the serialized file, or
streamed from a sibling `.resS` / `.resource` sidecar, resolved
automatically.

## Extraction by class

- Textures (28), sprites (213), cubemap faces (89, `_posx`... `_negz`
  PNGs), SpriteAtlas (687078895, packed-sprite mapping JSON)
- Meshes (43) as Wavefront OBJ (vertices, normals, UVs, faces),
  multi-stream vertex layouts included
- TextAssets (49), fonts (128, embedded TTF/OTF + metrics sidecar),
  ComputeShaders (72, DXBC/SPIR-V/GLSL per platform + descriptor JSON)
- AudioClips (83): OGG/FSB banks, WAV-wrapped PCM, MP3, plus an FSB5
  metadata sidecar (sample rate, channels, loop points, format); FSB5
  banks in pure-Zig codecs (PCM8/16/24/32/FLOAT, GCADPCM, IMA ADPCM) also
  export as playable WAV
- VideoClips (329): the streamed video pulled from the `.resource`/
  `.resS` sidecar as `.mp4`/`.webm`/`.ogv`/`.avi` (container sniffed)
  plus a metadata JSON; verified on Green Hell's 1080p60 and 4K
  cutscenes
- TerrainData (156): heightmap as a normalized 16-bit PGM plus metadata
  JSON (resolution, sample count, height range, world scale); the
  2021.x tree ships in `trees/TerrainData-2021.x.json` (see
  Typeless files); verified from 257x257 island zones (Stranded Deep) to
  a 4097x4097 jungle (Green Hell)
- Materials (21): readable text plus structured JSON (shader reference,
  render queue, texture bindings, floats, colors, ints)
- Shaders (48): a readable ShaderLab reconstruction (`Properties` with
  defaults, `Fallback`, keywords, subshader tags/LOD, pass names) plus
  the decoded compiled sub-program blob (record table, parameter blobs,
  code blobs with DXBC chunk sets, ISGN/RDEF, bind channels) under
  `show`/`shader`
- AnimationClips (74): curves as JSON (bone path, attribute, keyframes
  with time/value/slopes); humanoid muscle clips add `muscleClipSize`,
  event counts, and generic bindings
- AnimatorControllers (91), AnimatorOverrideControllers (221),
  Animators (95): JSON summaries with names resolved through TOS hash
  tables and the file's objects
- AudioMixers (241/243/245): the resolved group/snapshot graph
- ParticleSystems (198): timeline, module values, enabled flags
- MonoScripts (115): consolidated into one `scripts.json` (name, class,
  namespace, assembly, properties hash, script reference) instead of one
  file per script
- AssetBundles (142): the `m_Container` mapping of asset paths to
  object ids

## Audio: FSB5 and raw banks

`unityz fsb bank.fsb --outdir out/` decodes a raw FSB5 bank (as carved
from an FMOD `.bank` file) to one playable WAV/OGG per sample plus a
`bank.json` metadata sidecar. Vorbis banks (the common case) are remuxed
to a playable Ogg in pure Zig: the identification/comment headers are
synthesized and the setup header (codebooks + modes) comes from a
CRC-keyed table of FMOD encoder configurations, byte-identical to
Fmod5Sharp's reconstruction.

## Typeless files (`--trees`)

Mono builds strip the class type trees from serialized files, leaving
typeless objects undecodable. `--trees <file.json>` supplies them:
`extract`, `show`, `verify`, `find`, `skin`, `hierarchy`, and `edit`
decode with the injected trees, and `verify` round-trips them
byte-exactly.

The JSON shape is what `TypeTreeGeneratorAPI.get_nodes_as_json()` emits:
per-class flat node lists plus `__class_ids__` (built-in class names),
`__monoscripts__` (script resolution), and `__script_trees__` (the
MonoBehaviour script trees, keyed by namespace-qualified name so two
assemblies sharing a plain class name do not collide). MonoBehaviours
resolve their script via `m_Script` against the mono-script table; other
classes resolve by class name.

There is no off-the-shelf generator for this shape, so unityz ships one:
`scripts/structsdump-to-trees.py` converts the public AssetRipper
TypeTreeDumps `StructsDump/release/<version>.dump` into a trees file for
that exact Unity version:

```bash
curl -sL https://raw.githubusercontent.com/AssetRipper/TypeTreeDumps/main/StructsDump/release/2022.3.62f2.dump -o 2022.3.62f2.dump
uv run scripts/structsdump-to-trees.py 2022.3.62f2.dump -o trees-2022.3.62f2.json
./zig-out/bin/unityz extract game.unity3d --recursive --trees trees-2022.3.62f2.json
```

For 2021.x TerrainData, the derived tree in
`trees/TerrainData-2021.x.json` can be merged into a trees file. It is
the editor tree minus the stripped base fields, plus a 36-byte
runtime-only region the editor tree does not serialize.

A missing or malformed trees file prints a diagnostic and continues
without the trees; a typeless file without `--trees` reports how many
objects were skipped and why.

## Editing

`edit` supports dotted-indexed field paths, `--out <file>`, `--verify`
(round-trip-checks and refuses to write on failure), and `--trees` for
typeless files. Byte-array fields take base64 string values, and the
conversion is recursive inside replaced subtrees, so an `extract --json`
export feeds back through `edit --patch` byte-exactly. A rebuilt bundle
keeps its compression (LZ4 re-encoded when the source was compressed).

Streamed payloads can be patched in place: a patch entry keyed by a raw
container node (a `.resS`/`.resource` sidecar) replaces bytes at an
offset without touching the object tree, keeping every sidecar reference
valid.

## Verification

`verify` round-trips every object and checks that each streamed
reference resolves: a `m_StreamData`/`m_Resource` range must fit inside
the sibling sidecar node it points into, so an edit that breaks a
reference is caught at verify time. `diff` compares files by content
hash and optionally decodes matched objects: `--pixels` (per-channel
pixel diffs for textures/sprites), `--audio` (streamed audio data),
`--fields` (the exact changed field paths and values).

## UnityPy parity notes

UnityPy needs an external CLR (pythonnet/Mono.Cecil) to read managed
assemblies; unityz parses the .NET metadata in-tree (`managed`). UnityPy
has no export at all for: fonts, ComputeShaders, Cubemaps, AudioMixers,
ParticleSystems, AnimatorControllers, AnimatorOverrideControllers,
Animators, MonoScripts. UnityPy shells out to ffmpeg for audio
conversion; unityz decodes in pure Zig. UnityPy only writes PNG; unityz
adds TGA, BMP, and raw RGBA. UnityPy raises `NotImplementedError` on
UnityArchive files; unityz detects the container.

## Verification summary

The real 7DTD bundle (Unity 2022.3.62f2, fully typeless) extracts to
8090 files with zero decode failures: 260 PNGs, 7130 JSONs, 7 OBJs, 6
audio files, and every command handles typeless files. Raft (2021.3)
data files round-trip 38,212/38,213 objects byte-exactly; the two
exceptions use custom serialization. See the rewrite plan's completion
notes for the full per-pass evidence.
