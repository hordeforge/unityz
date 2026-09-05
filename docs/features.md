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
- `info --objects` lists the object table (path id, class, offset, size,
  name) of every SerializedFile in the input, and `info --dump` prints every
  object decoded as one JSON line; `--objects` also adds the table to
  `--json` output.
- `info --json` reports the metadata of every SerializedFile embedded in a
  bundle or WebFile: its format and Unity versions, platform, endianness,
  type-tree state, counts, and present class IDs. This is distinct from the
  outer UnityFS header's Unity string, which is commonly only `5.x.x`.
  This machine-readable nested metadata is part of unityz 0.1.1 and later;
  consumers that gate on it can reject an older executable through
  `unityz --version` before opening an artifact.
- `info` exits non-zero for an unrecognized or malformed input. Directory
  batches continue through every file but still return failure if any member
  failed, so a diagnostic line can never be mistaken for successful JSON.
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

`hierarchy --json` returns one object per SerializedFile with `node`,
`hierarchy`, and `skipped_children`. A Transform child whose Transform or
GameObject cannot be decoded is counted and omitted; it cannot leave a
dangling comma that makes the rest of the JSON unparseable. Unrecognized,
malformed, and invalid-option inputs return non-zero just as `info` does.
Every hierarchy node also carries the number omitted from its own subtree, so
a caller can mark only the affected prefab as partial while retaining the
file-level total.

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
- Meshes (43) as Wavefront OBJ (vertices, normals, UVs, faces,
  multi-stream vertex layouts included) plus a self-contained glTF/GLB
  (positions, normals, UVs, indices; X mirrored and V flipped to glTF's
  right-handed, top-left-origin conventions). Skinned meshes export the
  rig too: JOINTS_0/WEIGHTS_0 accessors plus a glTF skin whose joints sit
  at their bind world transforms and whose inverseBindMatrices are the
  raw Unity bind poses, so the rest pose round-trips exactly. Skin data
  comes from either storage Unity used: vertex channels 12/13 (2019+,
  verified on a 19-bone creature mesh) or the per-vertex m_Skin /
  m_BoneWeights array (5.x, verified on The Forest: 257 of 1325 meshes,
  rest pose ~5e-7).
- SkinnedMeshRenderers (137) export the bound character as one GLB whose
  joints carry the armature's real names (each m_Bones Transform resolves
  to its GameObject name; the per-Mesh export keeps generic Bone0..N
  joints), so a rigged character drops straight into a DCC tool with its
  skeleton intact.
- TextAssets (49), fonts (128, embedded TTF/OTF + metrics sidecar,
  including 5.x-era fonts whose layout predates m_ShouldRoundAdvanceValue;
  verified on The Forest), ComputeShaders (72, DXBC/SPIR-V/GLSL per
  platform + descriptor JSON)
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

`unityz fsb bank.fsb --json` is the automation contract in unityz 0.1.2 and
later. It parses the bank, decodes or rebuilds every sample in memory, writes
nothing, and reports the codec, sample count, rate, channels, duration, loop
points, and per-sample `decodable` result. Vorbis samples also report the setup
CRC and whether the embedded setup-header catalogue contains it. The top-level
`valid` is false, and the process exits non-zero, if any sample cannot be
reconstructed; malformed banks and failed extraction likewise return non-zero.

## Typeless files (`--trees`)

Mono builds strip the class type trees from serialized files, leaving
typeless objects undecodable. `--trees <file.json>` supplies them:
`extract`, `show`, `verify`, `find`, `skin`, `hierarchy`, `stats`, `edit`,
and `diff --fields` decode with the injected trees, and `verify`
round-trips them byte-exactly.

`show` returns non-zero when the requested object is absent or its value tree
does not decode. When an object has no usable type tree, its diagnostic names
both valid routes: provide `--trees` for JSON or use `--raw` for the serialized
bytes.

The JSON shape is what `TypeTreeGeneratorAPI.get_nodes_as_json()` emits:
per-class flat node lists plus `__class_ids__` (built-in class names),
`__monoscripts__` (script resolution), and `__script_trees__` (the
MonoBehaviour script trees, keyed by namespace-qualified name so two
assemblies sharing a plain class name do not collide). MonoBehaviours
resolve their script via `m_Script` against the mono-script table; other
classes resolve by class name.

`unityz trees <file> --out <out.json>` writes this shape from the trees a
file already carries, adding `m_Version` and `m_ByteSize` per node so a
writer (`create`) can embed the tree with its original metadata; the
reader ignores both when absent. Unity keeps type trees in AssetBundles but strips
them from a player's serialized files, so a game's own bundles are the
closest version-exact source of trees for its typeless `.assets`. Built-in
classes are keyed by class name; a MonoBehaviour tree is keyed by its
script's namespace-qualified class, resolved by following `m_Script` to a
MonoScript object inside the same container, and listed in
`__monoscripts__`. A MonoBehaviour whose MonoScript lives outside the file
is skipped and counted on stderr. Without `--out` the table goes to stdout.

unityz ships two generators and a merge tool for this shape. The
preferred one is in-tree and game-specific: `unityz managed <data-dir>
--trees <out.json>` builds the trees from the Mono build's own
assemblies (its `Managed/` folder) and the MonoScript objects in its
top-level serialized files, so each script class resolves to the fields
that specific game's assemblies declare. For version-generic trees
instead, `scripts/structsdump-to-trees.py` converts the public
AssetRipper TypeTreeDumps `StructsDump/release/<version>.dump` into a
trees file for that exact Unity version:

```bash
curl -sL https://raw.githubusercontent.com/AssetRipper/TypeTreeDumps/main/StructsDump/release/2022.3.62f2.dump -o 2022.3.62f2.dump
uv run scripts/structsdump-to-trees.py 2022.3.62f2.dump -o trees-2022.3.62f2.json
./zig-out/bin/unityz extract game.unity3d --trees trees-2022.3.62f2.json
```

For 2021.x TerrainData, the derived tree in
`trees/TerrainData-2021.x.json` supplies class 156 (the editor tree minus
the stripped base fields, plus a 36-byte runtime-only region the editor
tree does not serialize); add it to any trees file with
`scripts/merge-trees.py`.

For Mono games the script trees can be generated from the game itself:
`managed <dir> --trees out.json` reads every assembly under
`<dir>/Managed` (pure Zig, no CLR) and emits the MonoBehaviour script
trees plus the mono-script mapping. Field visibility follows Unity's
serializer: public instance fields, plus private/protected ones marked
`[SerializeField]`, base-class fields first; `[NonSerialized]` and
`[HideInInspector]` public fields are skipped. Known layout limits fall
back to 4-byte `int` placeholders so byte alignment is preserved.

A typeless file holds built-in objects (Mesh, Texture2D, ...) as well as
scripts, so full coverage needs both generators' output merged: the
built-in class trees from the version dump plus the game's script trees.

```bash
uv run scripts/structsdump-to-trees.py 2021.3.45f2.dump -o class-trees.json
./zig-out/bin/unityz managed Game/Game_Data --trees script-trees.json
uv run scripts/merge-trees.py class-trees.json script-trees.json -o trees.json
```

`scripts/merge-trees.py` keeps the dump's class trees and `__class_ids__`
and adds the managed file's `__script_trees__`/`__monoscripts__`; later
files win shared keys, so the managed output goes second (its
MonoBehaviour tree carries the alignment flags verified against the
game's own data). Verified on Raft (Unity 2021.3.45f2): 280 of its
resources.assets meshes decode, 33 of them skinned, and the skinned GLB
export's rest pose round-trips to ~1e-7 on 100-bone characters.

A missing or malformed trees file prints a diagnostic and continues
without the trees; a typeless file without `--trees` reports how many
objects were skipped and why.

## Built-in engine-class trees (`--builtin`)

unityz embeds a release-indexed database of Unity's built-in class type
trees (`src/builtin_trees/<release>.bin`, served by
`src/builtin_trees.zig`). Each file is one release's AssetRipper
TypeTreeDumps StructsDump packed by `scripts/structsdump-to-builtin.py`;
the shipped releases are listed by every "no built-in type trees"
diagnostic. Currently shipped: `2022.3.62f2` (294 concrete classes,
21755 nodes, 416 KB). Matching is by exact release string: there is no
nearest-version fallback, because a neighbouring release's tree can
differ in one field and decode garbage silently. An unknown release or a
class the release has no tree for is an error, never a guess.

`unityz trees --builtin <release> [--class <id>] [--out <file.json>]`
exports the database in the `--trees` JSON shape. Every node carries
`m_Type`, `m_Name`, `m_Level`, `m_MetaFlag` plus `m_ByteSize`,
`m_Version`, `m_TypeFlags` (Unity's array flag) and `m_Index`, so a
consumer can write the tree back into a SerializedFile with Unity's own
sizes and versions; the same fields are now read from any `--trees` file
that has them and ignored when absent. `__class_ids__` maps class names
to ids and `__meta__.source` is `builtin`. Unknown release or class: one
diagnostic on stderr, nothing on stdout, exit 1.

`--builtin` is a global option for `extract`, `show`, `verify`, `find`,
`skin`, `hierarchy`, `stats`, `edit`, and `diff --fields`. When a
SerializedFile carries no type trees, its built-in classes resolve from
the database keyed by the file's own embedded Unity revision; a `--trees`
file given alongside takes precedence for the classes it names.
MonoBehaviour (class 114) script fields are not in the database (it holds
only the plain header), so script trees still come from `--trees` or
`managed --trees`.

A file whose revision is not shipped prints one diagnostic naming the
shipped releases and its typeless objects stay skipped, exactly as
without the flag. Files that embed their trees are unaffected.

Parity evidence: the pipeline-authored 2022.3.62f2 self-test bundle embeds
UnityPy's TPK trees for 17 classes (AssetBundle, Texture2D, TextAsset,
GameObject, Transform, Mesh, Material, SkinnedMeshRenderer, BoxCollider,
CapsuleCollider, AnimationClip, Animation, MeshFilter, MeshRenderer,
Shader, ParticleSystem, ParticleSystemRenderer; 7507 nodes). Exported with
`trees` and compared node by node against `trees --builtin 2022.3.62f2`,
every type, name, level, meta flag, version and byte size is identical.
The single difference is the array flag on the two `TypelessData` nodes
(`image data` in Texture2D and Mesh): Unity and the dump set it, the
pipeline's writer only flags `Array` nodes.

To add a release:

```bash
curl -sL https://raw.githubusercontent.com/AssetRipper/TypeTreeDumps/main/StructsDump/release/2021.3.45f2.dump -o 2021.3.45f2.dump
uv run scripts/structsdump-to-builtin.py 2021.3.45f2.dump -o src/builtin_trees/2021.3.45f2.bin
```

Then add the release to the table in `src/builtin_trees.zig`; the module's
tests link every class of every shipped file.
## Creating files (`create`)

`unityz create <spec.json> --out <file.unity3d>` builds a UnityFS bundle
from empty state: a format-22 little-endian SerializedFile with the
declared type trees embedded, an 8-aligned object table, no script or
reference types, and an optional `.resource` sidecar, packed into one
format-8 archive (`5.x.x` plus the exact revision in the header, the
block/directory table at the head, the data hash zero - the layout Unity
2022.3 itself writes). Before anything reaches disk the result is
re-parsed and every object is round-trip checked, and every streamed
reference is checked against the sidecar, exactly as `verify` does;
`--no-verify` skips that. Output is written to a sibling temp file and
renamed into place. On success stdout carries one JSON line,
`{"file":...,"bytes":N,"objects":N,"verified":true}`.

The spec is one JSON object:

```json
{
  "revision": "2022.3.62f2",
  "platform": 19,
  "cab": "CAB-8c9178dc4d97f09235b2f3b683f22ca0",
  "compression": "none",
  "trees": "trees.json",
  "objects": [
    {"pathId": 1, "class": "AssetBundle", "value": {"m_Name": "...", "m_Container": []}},
    {"pathId": 2, "class": 49, "value": {"m_Name": "notes", "m_Script": "text"}}
  ],
  "resource": {"file": "clips.bin"}
}
```

- `revision` (required): the Unity revision written into the serialized
  file and the archive header.
- `platform` (default 19, StandaloneWindows64): the target platform id.
- `cab` (required): the serialized node's name; the sidecar, when given,
  is `<cab>.resource`.
- `compression`: `none` (default, one stored block) or `lz4` (one LZ4
  block, left stored when compressing does not shrink it, like Unity).
- `trees`: the `--trees` table (see the section above) inline, or a path
  to one. Every class an object uses must have a tree there; `create`
  never guesses a layout. A `unityz trees` export of a real bundle carries
  `m_Version` and `m_ByteSize` per node, so the embedded trees reproduce
  the source's metadata exactly.
- `objects`: in path-id order of your choosing. `class` is an id or a name
  listed in the trees' `__class_ids__`; `value` is the object in the JSON
  shape `show` and `extract --json` print (byte arrays as base64 strings,
  `PPtr` as `{"m_FileID","m_PathID"}`). A `-0` literal is kept as a
  negative-zero float.
- `resource`: a file whose bytes become the `.resource` node. Objects
  reference it through their own `StreamedResource`/`StreamingInfo`
  fields (`m_Source` = `archive:/<cab>/<cab>.resource`, `m_Offset`,
  `m_Size`); the caller lays those out.

Rejections are a stderr diagnostic, exit 1, and no file: bad or
incomplete spec JSON, an unknown key, an unknown compression, a class
without a tree, a zero or duplicate path id, a value missing a field its
tree names (or of the wrong shape), a same-file `PPtr` naming a path id
the bundle does not contain (Unity loads such a reference as "nothing" and
draws nothing, so it is refused up front), any count of `AssetBundle`
(class 142) objects other than one, and a streamed reference that falls
outside the sidecar (caught by the built-in verify pass).

Verified against the 7DTD asset pipeline's synthesized self-test bundle
(Unity 2022.3.62f2, 17 classes, 604 objects): exporting it with `trees`
and `extract --json`, feeding both back through `create` with
`"compression": "none"` reproduces the 9,313,411-byte file byte for byte;
with `lz4` the archive is 3,262,352 bytes, `verify` passes all 604 objects,
and `diff --fields` against the original reports zero changed objects.

Library callers have the same pieces: `typetree.writeBlob`,
`serialized_writer.create` (also takes external file references for
`m_FileID > 0`), and `bundle.create`.

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

## Stats

`stats` reports per-class sizes and duplicate-object detection, with
`--json` for scripts and `--dups` for only the duplicate report (text mode). With `--trees <file.json>`, typeless Mono files also
get a per-script breakdown: MonoBehaviours are decoded through the injected
trees and counted by their resolved script class name, so
`stats <game> --trees trees.json` answers "which scripts does this game
actually instantiate" (verified on Raft: 74 script classes across
resources.assets alone).

## Search

`find <path> <substring>` matches object names case-insensitively;
`--exact` requires a case-sensitive whole-name match, `--any` matches any
string field rather than only `m_Name`, `--class <id>` narrows the class,
and `--json` returns the matches as an array of `{node, path_id, class,
name}`.

## Verification

`verify` round-trips every object and checks that each streamed
reference resolves. A `--path-id` that matches no object is reported as a
failure (exit 1), so a script cannot mistake a typo for a clean object.
Streamed references: a `m_StreamData`/`m_Resource` range must fit inside
the sibling sidecar node it points into, so an edit that breaks a
reference is caught at verify time. `diff` compares files by content
hash and optionally decodes matched objects: `--pixels` (per-channel
pixel diffs for textures/sprites), `--audio` (streamed audio data),
`--fields` (the exact changed field paths and values).
Directory diffs run the same three passes on every matched file pair.

## Batch mode

Every command accepts a directory and runs over each regular file in it.
Plain output streams through per file. With `--json`, each file's output
is wrapped as one line, `{"file":"<path>","results":[<doc>, ...]}`, so a
consumer can tell which file produced which document without depending on
directory order. `results` holds every document the command emitted for
that file (normally one; `hierarchy` and `info` emit one per embedded
SerializedFile), and a non-JSON line is kept as a JSON string. A file the
command could not read or decode adds `"error":"<name>"` with the same
diagnostic on stderr; the batch continues and exits 1 at the end.

`extract` and `fsb` over a directory write each file's output under its
own `<outdir>/<file name>/` subdirectory (or `./<file name>/` without
`--outdir`). Bundles routinely share node names such as `CAB-...`, so a
flat layout would let one file overwrite another's exports and manifest.

`edit --out` and `trees --out` name one output file, so over a directory
they are usage errors (exit 2): a batch `edit` rewrites each file in place,
and a batch `trees` prints one wrapped JSON line per file.

A file unityz does not recognize as a Unity asset (not a SerializedFile,
bundle, or WebFile) is an error for every command, so a stray file in a
data directory shows up as a failure rather than as an empty success.

## Exit codes

Every command follows one contract, so scripts can branch on the status
without parsing output:

- 0: the command ran; for `verify`, `skin`, and `fsb --json` this also
  means every check passed.
- 1: an input could not be read or decoded, or a check failed. For `edit`
  this covers a missing object, a bad field path or value, a failed
  rebuild, and a `--verify` round-trip failure: nothing is written. For
  `create` it covers every spec rejection and the built-in verify pass:
  nothing is written. Batch runs
  over a directory keep going and return 1 at the end if any member failed.
- 2: a usage error: an unknown flag, a missing argument, or a malformed
  id. The diagnostic goes to stderr and nothing is written to stdout, so a
  bad flag can never be mistaken for a successful machine-readable run.

Whole-file evidence: the real 7DTD bundle (Unity 2022.3.62f2, fully
typeless) extracts to 8090 files with zero decode failures (260 PNGs,
7130 JSONs, 7 OBJs, 6 audio files), and Raft (2021.3) data files
round-trip 38,212/38,213 objects byte-exactly, the two exceptions using
custom serialization. See the rewrite plan's completion notes for the
full per-pass evidence.

## UnityPy parity notes

UnityPy needs an external CLR (pythonnet/Mono.Cecil) to read managed
assemblies; unityz parses the .NET metadata in-tree (`managed`). UnityPy
has no export at all for: fonts, ComputeShaders, Cubemaps, AudioMixers,
ParticleSystems, AnimatorControllers, AnimatorOverrideControllers,
Animators, MonoScripts. UnityPy shells out to ffmpeg for audio
conversion; unityz decodes in pure Zig. UnityPy only writes PNG; unityz
adds TGA, BMP, and raw RGBA. UnityPy raises `NotImplementedError` on
UnityArchive files; unityz detects the container.

UnityPy's TPK database covers every Unity release and picks the nearest
version; unityz's built-in database (`--builtin`, `trees --builtin`) covers
the releases it ships, currently only 2022.3.62f2, and matches exactly.
For a shipped release the trees are node-for-node what UnityPy writes
(see "Built-in engine-class trees"); for any other release a stripped
SerializedFile still needs caller-supplied `--trees`, and the remaining
parity step is packing more releases.

Creating a file no longer depends on it: `create` builds a SerializedFile
and UnityFS bundle from empty input, given the trees (built-in or
supplied), and UnityPy has no equivalent from-scratch writer.
Embedded-tree reading, extraction, verification, diffing, and in-place
edits use the trees already present and are unaffected.
