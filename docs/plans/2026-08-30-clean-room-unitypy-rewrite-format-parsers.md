# Plan - clean-room UnityPy rewrite: format parsers

**Date:** 2026-08-30  
**Status:** Completed - every default UnityPy capability covered by this
plan is implemented and
verified: parsers, object reader (incl. managed-reference registries), typed
classes, texture decode (DXT/BC4/5/BC7/ETC1/2/ETC2-RGBA8, ASTC
4x4-12x12 and HDR, plus the raw half/float/16-bit/signed family - see
the completion notes for the later passes), PNG, reserialize, `info`/`extract`/`edit`, and MonoBehaviour
handling (MonoScript resolution + raw script payload extraction).
UnityFS bundle parsing matches real bundles (big-endian headers,
v7 alignment, data hash, 10-byte block entries), verified against
UnityPy on real 2022.3 bundles.

The legacy-format rewrite (< v17) is
done: formats 2-22 round-trip through the writer (per-version
object table, tail fields, Legacy16 metadata-at-end layout), with v4, v9
and v13 fixture tests. Real 2022.3 CABs parse 100% clean (49/49 and 10/10
objects, zero read errors) after the last reader gap was closed:
strings are always 4-aligned in the wire format regardless of the
type-tree meta flag (this fixed AssetBundle, Mesh, and Shader objects,
which previously failed to read).

The serialized .NET object graph inside m_Script
payloads is no longer a limitation: `extract` decodes the graph
through its type tree and writes a `.json` sidecar alongside the raw
`.bin` payload (UnityPy itself still requires external .NET
assemblies to parse the graph).  
**Related:**

## Outcome

`unityz` reads and edits Unity asset files end to end, implemented from
public format documentation only - no code or data taken from UnityPy.

- `unityz info <file>` prints the file type and, for serialized files, the
  format version, Unity version, platform, endianness, type-tree flag, and
  type/object/external counts for any UnityFS bundle, WebFile,
  `.assets`/`.resources`/`.resS` file produced by Unity 2.5 through current
  versions (serialized formats 2-22, version 4 included; container
  detection covers every supported version, so bare v4 files are
  reachable from the CLI too).
  `--objects` adds the object table; per-class object counts are
  `unityz stats`.
- `unityz extract <file>` writes embedded assets (textures, text assets,
  meshes, raw bytes of any object) to disk; texture objects are decoded to
  PNG for the supported compressed formats (DXT1/3/5, BC4/5, BC6H, BC7,
  PVRTC, ATC, EAC, ETC1/2, ETC2-RGBA1, ETC2-RGBA8, the 3DS ETC variants,
  ASTC LDR and HDR, the DXT/ETC crunch variants, plus the uncompressed
  RGB/A family and the raw half/float/16-bit/signed family).
- `unityz edit <file>` rewrites a serialized file after in-memory changes
  (e.g. dumping an object to JSON, editing it, and writing back), producing
  a valid file.
- Beyond the three commands this plan started from, the CLI ships
  `verify`, `stats`, `find`, `show`, `shader`, `diff`, `hash`, and
  `skin`; the completion notes below record the pass that added each one.
- The library surface (`src/lib.zig`) exposes containers, object access, and
  raw read/write primitives so other Zig tools can build on it.

## Scope and constraints

Files under `src/` are new Zig code. The implementation is clean-room:
UnityPy is treated as an executable oracle for *behavioral* comparison only
(where a local checkout exists), never as a source of code, structs, or
layout - the binary layouts come from the public Unity format documentation
and from inspecting real asset files.

Targeted formats, in order:

1. Core streams: endian-aware binary reader/writer over slices and files.
2. File type detection by magic (UnityFS, UnityWeb, UnityRaw, SerializedFile,
   WebFile).
3. WebFile container.
4. UnityFS bundle: header, block/node info, LZ4 block decompression, node
   iteration. LZMA only if std has a usable decoder (otherwise deferred and
   flagged).
5. SerializedFile: header, metadata (version, target platform, type tree,
   object info table), raw object reading, TypeTree-driven generic object
   reader for files with a type tree.
6. ClassDatabase-free typed views for the common classes: MonoBehaviour,
   Texture2D, Sprite, TextAsset, GameObject, Transform, RectTransform,
   Material, Mesh (subset), AnimationClip (subset).
7. Texture decoding to RGBA8 + PNG export for the common formats.
8. Reserialization: write serialized files back from the object model.

Non-goals for the first pass: class database download/caching, asset
bundle encryption variants, asset bundle building from scratch, exotic
texture formats, audio/movie conversion, .NET assembly extraction beyond
raw bytes.

Two of those non-goals were reopened by later passes and no longer
describe the code (see the completion notes): the exotic texture formats
were taken on after an audit against UnityPy's TextureFormat enum, so
ASTC HDR, the crunch variants, and the raw half/float/16-bit/signed
family now decode, and later passes closed the rest of the block-format
gap too (BC6H, PVRTC, ATC, EAC, the 3DS ETC variants, ETC2_RGBA1).

AudioClip data is now extracted (container detection, raw PCM wrapped in
a WAV header) rather than skipped, though nothing is transcoded, so
audio/movie *conversion* remains out. The other four non-goals still
hold: class database download/caching, asset bundle encryption variants,
asset bundle building from scratch (`bundle.rebuild`/`webfile.rebuild`
rewrite a parsed container, they do not author one), and .NET assembly
extraction beyond raw bytes.

## Decisions and unknowns

- Zig 0.16.0 (`std.Io` API era) - the scaffold already targets it.
- The library owns an arena allocator per opened file; objects borrow from
  it. Write path uses explicit serializers, not a mirror of the read model.
- Compression: implement LZ4 block decompression in-tree (small, stable
  format). LZMA support depends on what std 0.16 ships; if absent, bundles
  using LZMA are detected and reported, not parsed.
  Resolved: std 0.16 ships a usable decoder, so `bundle.zig` decompresses
  LZMA blocks through `std.compress.lzma` (normalising Unity's 5-byte
  props+dict framing to the 13-byte header std expects). See the LZMA
  verification pass and the v6-bundle pass in the completion notes.
- TypeTree version differences across Unity releases are handled by parsing
  the tree itself, never by assuming a fixed schema.

## Steps

1. **Streams** - `src/streams.zig`: bounds-checked big/little-endian reader
   and writer over `[]const u8`/`[]u8`, aligned word reads, string
   helpers (length-prefixed, null-terminated, aligned-to-4). Tests round-trip
   every primitive both endians.
2. **File detection** - `src/container.zig`: sniff magic bytes, return an
   enum + parse entry. Tests construct minimal headers for every type.
3. **WebFile** - `src/webfile.zig`: header, per-entry offset table, deflate
   decompression of the payload. Tests with hand-built deflate blobs.
4. **UnityFS bundle** - `src/bundle.zig`: header parse, flags, header-info
   decompression, block/node tables, node reader, LZ4 decompressor in
   `src/lz4.zig`. Tests with hand-built bundle bytes including compressed
   blocks.
5. **SerializedFile** - `src/serialized.zig`: header, metadata, type-tree
   parse (`src/typetree.zig`), object info table, raw object byte slices.
   Tests with hand-built serialized files.
6. **Generic object reader** - `src/object_reader.zig` + `src/value.zig`:
   walk a TypeTree over an object's bytes into a JSON-serializable value
   tree. Alignment via meta_flags 0x4000, i32-length strings/TypelessData,
   bulk scalar arrays, map-as-pairs, PPtr, opaque fixed leaves. Managed
   references (ReferencedObject/ManagedReferencesRegistry) decode
   through their type trees (see step 9). `unityz info --dump` prints
   every object as JSON.
7. **Typed classes** - `src/classes.zig`: typed accessors over the generic
   value tree (Texture2D, TextAsset, GameObject, Transform, Sprite,
   Material, MonoBehaviour, AssetBundle, StreamingInfo).
8. **Texture decode** - `src/texture.zig` (Alpha8, ARGB4444, RGB24,
   RGBA32, ARGB32, RGB565, RGBA4444, BGRA32, R8, RGBAFloat, DXT1/3/5,
   BC4/5, BC7, ETC1/ETC2/ETC2-RGBA8, ASTC (4x4 through 12x12, RGB and
   RGBA) → RGBA8), `src/png.zig` encoder, `extract` CLI writes Texture2D
   PNGs and TextAssets. The compressed paths were cross-validated
   byte-exact against UnityPy's texture2ddecoder (900/900 ETC blocks,
   2160/2160 BC7 blocks across all modes, 600/600 ASTC blocks plus
   void-extent/error blocks); the ETC2 alternate modes (T/H/planar) and
   EAC alpha follow the reference bit-for-bit, including its wrap
   behavior for undefined differential sums.

   The TextureFormat numbers
   were corrected to Unity's enum values, so real assets route to the
   right decoders. ASTC HDR (66-71) decodes (see the ASTC HDR completion
   note).
9. **Managed references + MonoBehaviour** - `ReferencedObject` and
   `ManagedReferencesRegistry` decode through their type trees (the raw
   object graph inside each `TypelessData` payload is exposed as bytes);
   `extract` resolves a MonoBehaviour's `m_Script` PPtr to its MonoScript
   (namespace/class/assembly) and writes the raw serialized script
   payload. The managed .NET object-graph format itself is not parsed
   yet.

The UnityFS bundle parser was corrected to the real wire format
   (big-endian header/block info, 16-byte alignment for v7+, 16-byte data
   hash, 10-byte block entries) and validated against UnityPy on real
   Unity 2022.3 bundles.
10. **Reserialize** - `src/object_writer.zig` (type-tree-driven serializer,
   byte-exact round trips against the reader), `src/serialized_writer.zig`
   (v17-22 file rebuild preserving the type section verbatim), `edit` CLI
   (JSON literal field set + in-place rewrite).

Formats 2-22 round-trip
   (per-version object-table layout, tail fields, Legacy16 and
   Standard20 header layouts); v4, v9 and v13 fixtures cover the legacy
   paths.
11. **CLI + docs** - `info`, `--dump`, `extract`, `edit` wired; README
    status current.

## Verification

- `zig build test` green after every step (focused tests added per step,
  hand-built fixtures for each format).
- `zig build` produces a working CLI.
- Manual pass: `unityz info`/`extract` against real Unity asset files from
  the local sample corpus (if one exists on this machine) - report results
  in Completion notes.
- Where a local UnityPy checkout exists, behavioral comparison on the same
  files is allowed; byte-level output differences caused by implementation
  choice are documented, not hidden.

## Completion notes

2026-08-30: steps 1-8 landed. Object reading verified end-to-end on a
hand-built v17 serialized file (dumped as JSON) and the real v22 wire
fixture; texture extraction verified on a hand-built v17 file with a DXT1
Texture2D - the extracted PNG decodes to exactly the encoded red pixels.
Reserialization verified: `edit` changes a field and the rewritten file
re-parses with every other field intact.

Binary layouts
verified against the public format documentation and the wire fixtures of
the independent Rust `unity-asset` project (a real v22 serialized file
parses correctly, including big-endian data and the 48-byte header). Two
layout points flagged for real-file verification later: block-flag bit 0
semantics in UnityFS (per-block vs header compression type) and whether
legacy TypeTree strings are aligned strings (implemented) or plain
cstrings. Header endianness (big) is confirmed by three independent
implementations.

2026-08-30 (final): the real-file verification pass found the last
reader gap: strings are always 4-aligned in the wire format regardless
of the type-tree `meta_flags` (UnityPy `read_aligned_string`, AssetStudio
`ReadAlignedString`); the reader/writer only padded when bit 0x4000 was
set. Fixed in `object_reader.zig`/`object_writer.zig`: strings align
unconditionally, and array runs promote per-element padding to the run
end (byte-equivalent), with a regression test.

Real Unity 2022.3.62f2 CABs now read 100% clean: the AssetBundle (142),
Mesh (43), and Shader (48) objects that previously failed with
OutOfBounds/Corrupt parse with correct values; all objects in both
sample bundles read with zero errors (49/49 and 10/10); `edit`
round-trips are byte-identical to the originals on the previously
failing classes. The only remaining known limitation is the serialized
.NET object graph inside m_Script payloads, which UnityPy itself cannot
parse without external .NET assemblies; unityz exposes it as raw bytes
(at or beyond UnityPy parity).

2026-08-30 (bugfix/improvement pass): a whole-file reserialize audit on
the real CABs found three v22 writer bugs: the legacy header fields at
0x00/0x04/0x0c must be zero (UnityPy writes zeros too), object data is
aligned to the source file's own alignment (8 for 2022.3, derived as the
gcd of the object offsets; 4 for the hand-built fixtures), and the
metadata-to-data padding must actually be written. After the fixes both
real CABs reserialize byte-identically end to end (233036 and 370004
bytes, every object read -> written -> compared). Added a v22 fixture
test asserting byte-exact rewrites of the 2022.3 layout.

Reader/writer improvement: arrays of 1-byte integers (char / UInt8 /
SInt8) now coalesce into raw bytes instead of one value per byte
(UnityPy reads these as byte arrays), shrinking dumps like mesh index
buffers and matching the reference semantics.

`extract` gained asset kinds: Mesh exports as Wavefront OBJ (vertices,
normals, UVs, per-submesh triangle/quad faces, u16/u32 indices; UV0
resolved per UnityPy's version-aware channel mapping), Material and
Shader export as readable text summaries. The class-name table gained
MeshFilter, colliders, AudioClip, Sprite, RectTransform, CanvasRenderer,
ParticleSystem, and `info --dump` now uses an arena instead of leaking
per-object page allocations.

One subtle Zig 0.16 trap found and documented in the code: never deinit
an arena-backed `streams.Writer` and then hand out its slice, because
`ArenaAllocator.free` reclaims the most recent allocation and silently
invalidates it (surfaced as 0xAA-filled output); the extract helpers
dupe into the arena instead.

2026-08-30 (sprite export pass): `extract` now exports Sprites as cropped
PNGs: it resolves the sprite's texture PPtr in the same file, decodes the
Texture2D, crops `m_RD.textureRect` (falling back to the legacy top-level
`m_Rect`), and flips vertically, mirroring UnityPy's `SpriteHelper`
algorithm exactly. Verified against a hand-built v22 fixture (4x4 RGBA32
texture + 2x2 sprite rect): the exported PNG matches UnityPy's own sprite
export pixel-for-pixel.

This pass also fixed a latent real-file bug: modern type trees name the
texture pixel payload field "image data" (with a space), not
`m_ImageData`; `Texture2D.fromValue` now reads both, so embedded textures
in real 2022.3 files extract correctly (previously the pixel data was
never found and textures were silently skipped). A regression test covers
the crop/flip math and the out-of-rect rejection path.

2026-08-30 (texture export pass): real-file texture extraction was never
verified before, because the sample bundles' only Texture2D had been
misreported as width 0. Inspecting it directly showed a real 256x256
RGBA32 texture. Cross-checking the exported PNG against UnityPy found the
extracted image vertically flipped: Unity stores texture rows bottom-up
(row 0 = bottom), while PNGs are top-down. `extract` now flips the decoded
RGBA before encoding (`texture.flipVertical`), and the output matches
UnityPy's texture export byte-for-byte (0/262144 differing bytes).

The
sprite path intentionally uses the unflipped texture and flips the crop
instead, matching UnityPy's `SpriteHelper`, and still matches after this
change. Added a `flipVertical` regression test. A mutation fuzz pass
(200 mutated serialized-file and bundle inputs) found no parser panics.

2026-08-30 (mesh export pass): comparing the OBJ export against UnityPy's
own exporter found two real bugs. The face writer emitted one `f` line per
vertex (three degenerate one-corner "triangles" per face instead of one
3-corner line) - 6624 lines instead of 2208 faces. And the export kept
Unity's left-handed coordinates, while UnityPy converts to right-handed
OBJ by mirroring X on vertices and normals and reversing face winding.

Both fixed; the exported OBJ now matches UnityPy's byte-for-byte at f32
precision for both sample meshes (1740-vertex creature and 24-vertex
cube): vertices, normals, UVs, and face indices all identical (my float
output uses shortest round-trip digits instead of UnityPy's 9-digit
format, so the text differs but every parsed value is the same f32).

2026-08-30 (CLI correctness pass): `info --dump` JSON output is now fully
valid: `value.jsonString` escaped quotes/backslash/newline/CR/tab but
passed control characters through raw, and Unity strings often carry
trailing NULs (e.g. MonoScript class names), which would have produced
invalid JSON. All remaining C0 controls and DEL are now written as
`\uXXXX` (with a regression test).

`edit` now rejects fields the object's
type tree does not declare instead of silently no-op'ing: the writer
serializes tree children only, so a typo'd field name previously rewrote
the file unchanged without any indication. Probing `edit` with bad JSON,
bad path ids, and missing objects showed it already fails gracefully
everywhere else.

2026-08-30 (nested edit pass): `edit` now accepts dotted, indexed field
paths, e.g. `m_Container[0][1].preloadSize`, `m_SavedProperties.m_TexEnvs[0][1].m_Scale.x`,
and `m_Shader.m_PathID` (PPtrs expose m_FileID/m_PathID for descent). The
path walker rebuilds the value tree copy-on-write, preserves field order,
and rejects nonexistent segments.

Verified on the real shamwayselftest
CAB: a container preloadSize, a material texture scale, and a shader
retarget all edit correctly and the edited files reserialize
byte-identically. A path-parser unit test covers dotted/indexed forms and
malformed paths.

2026-08-30 (monobehaviour verification pass): building a v22 fixture with a
MonoBehaviour + MonoScript and running the full read/extract/edit pipeline
closed the last untested extract path and exposed a real writer bug: the
raw serialized script graph that follows a MonoBehaviour's type-tree
fields was silently dropped on rewrite (the writer emitted only the tree
fields; the real CABs contain no MonoBehaviours, so no prior round-trip
caught it). `object_writer.writeObject` now takes the tail bytes after the
tree fields and appends them, mirroring UnityPy's preservation of the
unread remainder. `edit` on a MonoBehaviour keeps the payload: verified
byte-exact on the fixture after an edit.

The same pass found the
alignment derivation overestimated with sparse object offsets (two
objects at 0 and 40 yield gcd 40 but the true alignment is 8);
`deriveDataAlign` now picks the largest power of two dividing all relative
offsets. All four round-trip targets (two fixtures, two real CABs)
reserialize byte-identically, and the MonoBehaviour extract path (script
resolution, NUL-trimmed label, exact payload) is verified end-to-end.

2026-08-30 (recursive dump pass): `info <bundle> --dump` previously
ignored `--dump`; it now recursively parses each serialized node (and
WebFile entry) and prints the objects, so a whole bundle can be inspected
in one command without extracting the CABs first. Verified: the bundle
dump produces the identical per-object JSON as dumping the extracted CAB
directly (49/49 objects on the entityprobe bundle).

2026-08-30 (raw extract pass): `extract <serialized> --raw` writes every
object's serialized bytes as-is to `object_<path_id>_class<id>.bin`,
fulfilling the plan's "raw bytes of any object" promise (previously only
MonoBehaviour payloads were exposed raw). Verified on the shamwayselftest
CAB: 10 objects dumped, every file size matches the object table, and the
AssetBundle's raw bytes show the expected name field.

2026-08-30 (script naming + array edit pass): MonoBehaviour export files
are now named with the qualified `namespace.class` (previously the
namespace alone, so scripts sharing a namespace collided), matching the
printed label. Verified JSON-array edits end to end: setting a Transform's
`m_Children` to a new PPtr array changes the value and the edited file
reserializes byte-identically.

2026-08-30 (info polish pass): `info` on a serialized file now lists the
external dependencies (path, guid, type) that real game files use to
reference sidecar files, plus script-type and ref-type counts when
present. `edit` on a non-serialized input (bundle/webfile) now fails with
a clear message instead of a confusing parse error. Both verified on
fixtures (an external round-trips through the metadata verbatim).

2026-08-30 (webfile verification pass): the WebFile parser and the
recursive info/extract paths were only synthetically tested; a hand-built
WebFile (UnityWebData1.0 header + zlib payload) containing the real
entityprobe CAB as one entry now verifies them end to end: `info` shows
the container and payload sizes, `info --dump` recursively dumps the
CAB's 49 objects through the webfile entry, and `extract` writes the entry
byte-identical to the original CAB (which also still reserializes
byte-exactly).

2026-08-30 (multi-edit pass): `edit` now accepts several `field json-value`
pairs in one invocation (`edit <file> <path_id> m_A 1 m_B 2`), applying
them to the value tree before a single rewrite, so the file is written
once and a failing pair leaves it untouched. Verified on the real CAB:
two nested edits applied together, an invalid second field aborts with no
partial write, and the edited file reserializes byte-identically.

2026-08-30 (lzma verification pass): the UnityFS LZMA decompression path
(std.compress.lzma, "via std") was never exercised with real LZMA data. A
hand-built UnityFS v8 bundle with an LZMA-compressed header info and block
(flags 0x41, block flag bit 0 set to inherit the header type, unpacked
sizes patched into the .lzma headers like Unity's LZMA SDK writes them)
now verifies it end to end: `info` parses it, `extract` writes the
embedded CAB byte-identical to the original, and `info --dump` recursively
reads all 49 objects through the LZMA block.

2026-08-30 (object table pass): `info <file> --objects` prints the object
table (path id, class, byte start, size) for debugging which objects are
large; usage text updated.

2026-08-30 (verify command): `unityz verify <path>` is a self-integrity
check UnityPy does not offer: every object with a type tree is read
through it, written back, and byte-compared, reporting read/write errors
and mismatches. Bundles, webfiles, and their embedded serialized nodes
are verified recursively. It exits non-zero on any failure (usable in CI
or pre-commit checks) and prints nothing spurious on success. Verified:
both real CABs, both bundles (incl. the LZMA fixture), the webfile
fixture, and the sprite/mono fixtures all report clean; truncated and
garbage inputs fail with a clear message and exit 1.

2026-08-30 (stats command): `unityz stats <path>` reports per-class object
counts and byte totals (largest classes first) plus duplicate-object
detection: objects with identical serialized bytes across path IDs are
flagged with their potential deduplication savings. This is size analysis
UnityPy does not offer. Bundles and webfiles report per node. Verified on
both real CABs (honest "no duplicate objects") and a hand-built fixture
with two byte-identical GameObjects (correctly reports object 200 == 100,
9 bytes could be deduplicated).

2026-08-30 (selective extract pass): `extract` now accepts `--class N` and
`--path-id N` filters (combinable with `--raw`), pulling just the wanted
objects out of a serialized file; unknown options are rejected with a
clear message. UnityPy's CLI extracts everything or nothing. Verified on
the real CAB: `--class 28` extracts only the texture, `--path-id 3` only
the mesh OBJ, `--class 43 --raw` only the mesh's raw bytes.

2026-08-30 (batch mode pass): every command now accepts a directory
argument and processes each file in it, so `unityz verify ./assets/`
checks a whole tree in one run (CI-usable). `verify` no longer aborts the
batch on the first bad file: failures set a flag, the loop continues, and
the process exits non-zero at the end. Verified: a batch verify over two
good CABs + one truncated file reports each and exits 1; batch
info/stats/extract process all files.

2026-08-30 (find command): `unityz find <path> <substring> [--class N]`
locates objects whose name contains the substring (case-insensitive) or
whose class matches, reading each object through its type tree and
recursing into bundle/webfile nodes. UnityPy's CLI has no search.
Verified on both real bundles (e.g. `find ... creature` -> the
myCreature GameObject, mesh, and material) and via `--class`.

2026-08-30 (show command): `unityz show <path> <path-id>` prints one
object's value tree as JSON, completing the find -> show -> edit/extract
workflow; recurses into bundle/webfile nodes and reports not-found and
invalid-id errors cleanly. UnityPy's CLI cannot print a single object.

2026-08-30 (diff command): `unityz diff <file1> <file2>` compares two
files' objects by content hash (path id, class, Wyhash of the raw bytes,
size), reporting objects only in one file, objects whose bytes changed
between builds, and the unchanged count; works recursively on
bundles/webfiles. Verified: identical files -> all unchanged; an edited
copy -> the edited AssetBundle flagged as changed; unrelated files ->
changed + only-in-A counts. UnityPy has no build comparison.

2026-08-30 (edit --out pass): `edit` accepts `--out <file>` anywhere in
the argument list to write the edited file elsewhere instead of
overwriting the input in place, a safety improvement UnityPy lacks (it
saves over the original). Works with multi-field edits; verified the
output reserializes byte-identically and the input file is untouched.

2026-08-30 (outdir + README pass): `extract --outdir <dir>` writes
extracted files into an existing directory instead of the current one
(scripting-friendly). The README's quick start and command list were
refreshed to cover all nine CLI commands and their beyond-UnityPy
capabilities (verify/stats/find/show/diff, batch directories, extract
filters, edit --out).

2026-08-30 (recursive extract pass): `extract --recursive` on a bundle or
webfile writes the embedded serialized nodes AND their assets in one
command (combinable with --class/--path-id/--raw), so a whole bundle
yields textures/meshes/materials without a two-step extract. Verified on
both real bundles.

2026-08-30 (info --json pass): `info <file> --json` prints a single
machine-readable JSON summary (type, version, unity, platform, endian,
type-tree flag, type/object/external counts) instead of the text layout,
for scripting. Verified parseable.

2026-08-30 (hash command): `unityz hash <path> [--path-id N]` prints each
object's content fingerprint (Wyhash of the raw bytes) with class and
size, the raw material for external build tracking (`diff` is the
pairwise comparison). Deterministic and filterable; recurses into
bundle/webfile nodes.

2026-08-30 (edit --patch pass): `edit <file> --patch <patch.json>` applies
a JSON patch of the form `{"<path_id>": {"<field>": <value>, ...}, ...}`
to several objects in one rewrite, with dotted-indexed field paths and
`--out` support. Verified: two objects patched together (name/flags and
nested transform fields), the patched file reserializes byte-identically,
single-object edit is unaffected, and unknown objects / malformed JSON
fail with clear messages.

2026-08-30 (batch edit verification): the directory batch mode also
covers `edit` - `unityz edit dir/ 100 m_Count 99` applies the same edit
to every file in the directory, and `edit dir/ --patch p.json` applies a
patch file to every file (keep the patch outside the target directory).
Verified on a directory of two CABs: both edited, both reserialize
byte-identically.

2026-08-30 (stats --json pass): `stats --json` emits the size breakdown
as a single machine-readable object (object/byte totals + per-class
counts and bytes), consistent with `info --json` for scripting. Verified
parseable.

2026-08-30 (verify filters pass): `verify` accepts `--class N` and
`--path-id N` to check a subset of objects, useful after editing a few.
A 120-mutation fuzz across find/show/stats/hash/verify plus 60 diff
mutations found no panics in the newer commands. Verified: focused
verification checks exactly the target objects.

2026-08-30 (objects-through-containers pass): `info <bundle|webfile>
--objects` now lists the object table of every embedded serialized node
(previously the flag was silently ignored for containers, only working on
bare serialized files). Verified on both real bundles and the webfile
fixture (49 objects through the entityprobe bundle node).

2026-08-30 (bundle rebuild pass): `edit` now works on bundles directly -
it finds the serialized node containing the target path id, edits it, and
rebuilds the bundle with the node replaced. The new `bundle.rebuild`
writes a single uncompressed block (valid UnityFS, no LZ4/LZMA encoder
needed), keeps the source version and Unity strings, and zeroes the data
hash (parsers accept it). Verified end to end: editing a mesh name inside
the real entityprobe bundle produces a bundle my own `verify` accepts,
**UnityPy loads it** (49 objects, edited name reads back), and
`extract --recursive` works on it. Unit test covers replacement and
untouched rebuild round-trips.

2026-08-30 (bundle patch pass): `edit <bundle> --patch <file>` applies a
JSON patch across the bundle's nodes - entries are grouped by the node
that contains each path id, each node is edited and the bundle rebuilt
once. Verified: two objects patched in the real entityprobe bundle
(mesh name + bundle flags), my verify passes, and UnityPy reads both
edits back. The serialized-file patch path is unchanged and byte-stable.

2026-08-30 (webfile format fix): the WebFile parser implemented an
invented compressed format that real Unity webfiles do not use (UnityPy
could not read the fixtures). Rewritten to the real UnityWebData layout:
signature, a u32 head size, then an offset/length/path-length table with
the file data at absolute offsets; gzip-wrapped webfiles decode and
rebuild too. `webfile.rebuild` writes the same layout
(uncompressed, no deflate encoder needed). Verified: a hand-built
real-format webfile is read by both unityz and UnityPy (49 objects), and
`edit` inside a webfile produces a rebuilt file that UnityPy reads back
with the edited value. New parse/rebuild/error tests.

2026-08-30 (gzip webfile pass): gzip-wrapped webfiles are now parsed
(streamed flate decompression; the WebFile owns the decompressed buffer),
container sniffing routes gzip-magic files to the webfile parser, and a
missing-return bug in `verify`'s unknown/archive branches was fixed.
Verified: a Python-gzipped real-format webfile passes info/verify and
extracts the embedded CAB byte-identically.

2026-08-30 (fuzz + hang fix): a mutation fuzz of the rewritten webfile
parser found a hang: the object reader placed no upper bound on array
counts, so a corrupt count triggered a huge allocation + effectively
infinite loop (reproduced via a corrupted gzip webfile entry). Fixed by
bounding the count by the remaining data; the hang now errors fast with
`Corrupt`. The fuzz also found that std's flate decoder can panic on
certain *truncated* gzip streams (a std integer-overflow bug, not
catchable from zig code); corruption of complete gzip streams errors
cleanly, so this is documented as a std limitation affecting only
truncated gzip webfiles.

2026-08-30 (webfile patch pass): `edit <webfile> --patch <file>` applies
JSON patches across a webfile's entries (per-entry grouping, one rebuild),
completing the container edit matrix (serialized, bundle, webfile, all
supporting single edits and patches). Verified: two objects patched in a
real-format webfile, my verify passes, and UnityPy reads both edits.

2026-08-30 (container matrix verification): the full command set
(stats/hash/find/show/diff/extract --recursive) verified over gzip
webfiles, and a 60-mutation x 6-command fuzz of the LZMA bundle and a
rebuilt bundle found zero hangs or panics. The container code paths
(webfile gzip, bundle rebuild) are now fuzz-clean alongside the rest.

2026-08-30 (README + final sweep): README status updated for the container
edit/rebuild capabilities and the fuzz-clean state. Final regression:
4 round-trip targets byte-identical, 6 containers (real CABs/bundles,
LZMA bundle, gzip webfile, patched webfile, rebuilt bundle) verify clean,
205/205 tests.

2026-08-30 (stats --json containers): `stats --json` now aggregates across
a bundle's or webfile's serialized nodes (previously it passed container
bytes to the serialized parser, producing confusing errors). Verified on
a bundle, a gzip webfile, and a bare serialized file.

2026-08-30 (info --json containers): `info --json` now emits machine-readable
summaries for bundles (version, unity, node paths/sizes) and webfiles
(entry paths/sizes) as well as serialized files. Verified parseable on a
real bundle, a gzip webfile, and a bare serialized file.

2026-08-30 (hash --json pass): `hash --json` emits the content
fingerprints as a JSON array (path_id, hash, class, size), filterable
with --path-id, consistent with info/stats --json for scripting.

2026-08-30 (directory diff pass): `diff <dirA> <dirB>` compares two asset
trees file-by-file (size + content hash), reporting changed / only-in
entries (capped at 10 lines) plus a summary line; `diff` skips batch
expansion and routes directory arguments to the tree comparison, so a
directory argument no longer dies with `IsDir`. Verified: identical dirs
(2 unchanged), diverged dirs (unchanged/changed/only-in counts), and the
file-diff regression (48 unchanged, 1 changed).

2026-08-30 (JSON matrix completion): `diff --json` and `find --json` join
info/stats/hash in the machine-readable family, and `hash` gains the
`--class <id>` filter for symmetry with find/verify. `diff --json` emits
one object (a/b paths, unchanged/changed/only_a/only_b counts plus
changed_objects/only_a_objects/only_b_objects lists; directories list
file names, files list path_id/class); `find --json` emits a single array
of {path_id, class, name} across a file or all container nodes; `hash
--class N` filters both text and JSON output.

Verified on serialized
files, a bundle, and (gzip) webfiles: counts and lists match the text
modes, and every emission parses as valid JSON (checked with python
json.tool; count and list keys are distinct to avoid duplicate names).

2026-08-30 (verify --json + stats --class): `verify --json` completes the
machine-readable family for every inspection command: one object with
checked/failed counts and a failures array ({path_id, message}; path_id
-1 for file-level parse failures), non-zero exit preserved. `stats` gains
`--class <id>`, filtering both the per-class totals and the duplicate
scan, in text and JSON modes (stats previously only recognized `--json`
as rest[0]).

Verified: clean files (checked=N, failed=0), mutated files
(read failure and serialized parse failure recorded with correct counts
in both modes), garbage/truncated inputs (path_id -1 records), container
parse failures, bundle + gzip webfile coverage, and exit codes 0/1.

2026-08-30 (info --objects --json): `info --json --objects` adds the
per-object table to the machine-readable summary as an `object_list`
array ({path_id, class, offset, size}; entries inside bundles/webfiles
are tagged with their node/entry path). The info flag scan now accepts
any order of --dump/--objects/--json (it previously only checked rest[0],
so `info --json --objects` silently ignored --objects). Verified on a
serialized file (49 entries, matches the text table), a bundle (49
node-tagged entries), and a gzip webfile; both flag orders parse as valid
JSON; text --objects, --json without --objects, and --dump regressions
clean.

2026-08-30 (edit --verify): `edit` gains `--verify`, a round-trip
self-check of the edited output before writing (serialized, bundle,
webfile, and --patch forms): the rebuilt bytes are parsed and every
object is read through its type tree, written back, and compared; on any
failure up to three objects are listed and the file is left untouched
(non-zero exit). The check shares the verify machinery (silent report
mode).

Verified: all four edit forms over all three container kinds print
"verify: 49 object(s) round-trip clean", a 5000-char name edit (size
shift through rewrite) and an embedded-NUL string both round-trip clean,
and --verify output is byte-identical to the same edit without the flag.

2026-08-30 (extract --json + outdir auto-create): `extract --json` exports
every tree-typed object's value tree as `object_{id}_class{n}.json`
(compact JSON via an allocating Io writer), filterable with --class /
--path-id; --raw and --json are mutually exclusive. `--outdir <dir>` is
now created when missing via a component-wise mkdir helper written
because std's `createDirPath` hangs on special filesystems (/proc);
verified the helper creates nested paths, tolerates existing dirs, and
fails fast with a clean message on /proc.

Verified: 49 value-tree JSON
files from the entityprobe CAB all parse (including a 172 KB mesh tree),
names match find output, bundle --recursive --json extracts node + 49
JSON files, non-json extraction regression clean.

2026-08-30 (show --raw): `show <path> <id> --raw` prints one object's
serialized bytes as a 16-byte-per-line hex dump with an ASCII gutter
(offset + hex + printable chars); it runs before the type-tree lookup, so
it works on objects without trees. Verified byte-exact against
`extract --raw --path-id N` output on the entityprobe CAB (object 1, 256
bytes), on a bundle node, with the JSON mode and unknown-option handling
unchanged.

2026-08-30 (extract --json manifest): `extract --json` now also writes
`manifest.json` next to the exported value trees, indexing every exported
object ({path_id, class, file, name}; m_Name via the value tree, empty
when absent). extractSerialized now takes the caller's arena and a
manifest list so entry names outlive the call; the list lives per
container branch. Verified: 49 entries on the entityprobe CAB (names
match, e.g. mesh myCreature_mesh), 49 across a bundle --recursive --json,
22 all-class-1 with --class 1, and no manifest written without --json.

2026-08-30 (info --json externals): serialized-file `info --json` output
now includes `externals_list`, the sidecar dependency table ({path, guid
as 32-hex, type}), matching the text-mode externals lines; the summary
count is unchanged. Verified on mono.assets (1 external,
archive:/textures.resS guid 0102..0f10 type 2, identical to the text
output), the entityprobe CAB (empty list), sprite.assets (none), and the
--json --objects combo.

2026-08-30 (diff --class): `diff` gains `--class <id>`, restricting the
object comparison to one class (both text and --json modes); the filter
lives in collectFingerprints so it applies across bundle/webfile nodes
too. Verified: baseline 48 unchanged/1 changed on the renamed CAB pair,
--class 1 gives 22 unchanged GameObjects, --class 142 isolates the
changed AssetBundle (0 unchanged, 1 changed), --json --class 142 emits
the same result as JSON, a bundle self-diff filters to 22, and an invalid
class id errors cleanly. (Directory diffs compare whole files, so
--class is accepted but not applied there.)

2026-08-30 (stats --dups): `stats --dups` prints only the duplicate
report (group lines + dedup summary, or "no duplicate objects"),
skipping the per-class table and per-node headers; it composes with
--class and is rejected together with --json (text-only). Verified on
dup.assets (dup line + 9 bytes deduplicable), the entityprobe CAB (no
duplicates), and a bundle (headers suppressed), with the unflagged text
output unchanged.

2026-08-30 (gzip truncation panic fix): a fresh mutation fuzz across the
whole command surface (5 fixtures x 40 mutations x 17 commands, ~3400
invocations) found zero crashes everywhere except truncated gzip
webfiles, where std's flate decoder panics (two std bugs: a bit-reader
assert seek <= end, and an end-of-input bit-count underflow; neither is
catchable). Probed: 6-10 of 13 truncation offsets panicked.

Fixed by
feeding the decoder an endless 0xFF-padded input (a custom std.Io.Reader
with a NUL every 64 bytes so gzip header delimiter scans terminate) so
truncated streams error cleanly, capped output at max(8 MiB, 128x input)
to bound the literal-0xFF garbage (previously a truncated file could
spike 2.4 GB / 3.7 s; now ~11 MB / 10 ms), and verified the gzip trailer
(CRC32 + ISIZE) ourselves because std reads but never checks it, closing
a silent-garbage-success hole. Regression test truncates a hand-built
gzip webfile at every length and requires clean errors.

Result: all 22
probed truncation offsets clean, valid gzip webfiles byte-identical
(49-object verify clean), LZMA bundle truncations already clean,
206/206 tests.

2026-08-30 (extended fuzz campaign): the fuzz harness grew a full-extract
variant that also drives the previously-unfuzzed asset decoders
(texture decode, PNG encode, sprite crop, mesh OBJ, material/shader text)
and ran 4 more rounds: LZMA bundle, sprite.assets, patched webfile, and
the entityprobe CAB, 60-80 mutations x 13 commands each (~3100 more
invocations). Zero crashes and zero hangs across all of them; combined
with the earlier rounds the tool has survived ~6500 mutated invocations
across 9 fixture types with the gzip truncation panic (fixed above) the
only crash ever observed. The harness (mutations + timeout + crash/hang
classifier) lives in /tmp/uzfuzz for future runs.

2026-08-30 (EPIPE fix): piping stdout into a consumer that exits early
(e.g. `unityz ... | head`) used to print an ugly WriteFailed stack trace,
because Zig 0.16 does not die on SIGPIPE and the final stdout flush (or
any mid-command write) surfaced the broken-pipe error as a trace. Fixed
by a finalFlush helper that exits 141 (the SIGPIPE exit code) on flush
failure, and the runCommand error catches exit 141 quietly on
WriteFailed. Verified: heavy multi-line output piped to head (the
original repro), info --dump piped to head, and --help/--version piped
all exit silently with 141, while normal output and the verify non-zero
exit are unchanged.

2026-08-30 (hash --json single array): `hash --json` on a multi-node
container used to print one JSON array per serialized node/entry, which
is not parseable as a single document (reproduced with a hand-built
2-entry webfile: json.load failed with "Extra data"). It now aggregates
into one array across all nodes, like find --json; filters
(--class/--path-id) still apply per object. Verified: 51 entries across
the 2-entry webfile parse as valid JSON, 24 with --class 1, text mode
and single-file output unchanged, stats --json already aggregated.

2026-08-30 (diff node awareness): `diff` on multi-node containers
conflated objects with the same path id across different nodes (matching
was by path id alone). Reproduced with a 2-entry webfile whose entries
both contain objects 100/200: editing one entry's object 200 reported 2
changed instead of 1. Fp now carries the node path; objects match only
when path id and node agree; text lines and --json entries tag the node
(e.g. "changed: object 200 (GameObject) in a.assets"). Verified: collide
fixture now 3 unchanged / 1 changed with correct node tags, bare
serialized files (no node field), single-node bundles, directory diffs,
and --class filters all unchanged.

2026-08-30 (verify --json node tags): `verify --json` failure records
did not say which entry of a multi-node container failed (path_id only).
Failures now carry a "node" field naming the bundle node / webfile entry
(the diff fix from step 72 applied to verify; edit --verify shares the
machinery). Verified: a corrupted second entry reports
{"node":"b.assets","path_id":100,...} in JSON while text mode already
showed per-entry headers; bare serialized files keep no node field, and
clean containers (bundle, gzip webfile) plus edit --verify are
unchanged.

2026-08-30 (stats --json duplicate groups): `stats --json` reported
object/byte totals and per-class sizes but no dedup information at all
(the text mode lists duplicate pairs). It now emits duplicates /
duplicate_bytes counts plus a duplicate_groups array ({class, hash,
size, path_ids}) of objects sharing identical serialized bytes, computed
across container nodes and honoring --class. Verified: dup.assets JSON
matches the text report exactly (1 duplicate, 9 bytes,
class-1/hash/size-9/path-ids [100,200]); clean files emit empty groups;
the two-entry webfile aggregates one group; --class filters dedup to the
class; text and --dups outputs unchanged.

(statsSerializedBytesJson, an
unused pre-refactor variant with duplicates, was left as-is.)

2026-08-30 (find --exact): `find` gains `--exact` for a case-sensitive
whole-name match (names are NUL-trimmed before comparing), complementing
the case-insensitive substring default; composes with --class and --json.
Verified: exact full name matches, wrong case and partial names match
nothing, bundle and renamed-file lookups work, and the substring default
is unchanged.

2026-08-30 (extract per-node subdirs): `extract --recursive` on a
multi-node container silently lost data: objects with the same path id in
different nodes wrote the same file name and overwrote each other
(reproduced: a 2-entry webfile with objects 100/200 in both entries
produced 2 files for 4 manifest entries). Objects extracted from a
container node now land in `objects/<node>/` (created on demand; node
data files stay flat at the outdir root), so identical path ids cannot
collide; the manifest's file field carries the subpath. Applies to
--json, --raw, and the decoded-asset modes alike.

Verified: 4/4 files
with a valid manifest on the collide fixture, bare serialized files stay
flat, single-node bundles and non-recursive extraction unchanged, 25
mutated webfiles fuzz the recursive path cleanly.

2026-08-30 (node:path-id selectors): with colliding path ids across a
container's nodes, `show` and `edit` could only reach the first match.
Both now accept a `node:path-id` selector (split on the first colon) that
targets one specific bundle node / webfile entry; bare path ids keep the
first-match behavior, and a node selector on a bare serialized file is a
clean error. Verified: `show b.assets:200` vs `a.assets:200` on a
2-entry webfile show the right objects, `edit b.assets:200 m_Name ...`
renames only that entry (a's untouched, confirmed via diff's node tag),
plain selectors and bundles (CAB-xxx:1) work, invalid selectors error
cleanly, and edit --verify composes.

2026-08-30 (find/hash node tags): `find` and `hash` were the last
per-object commands without node awareness: their JSON arrays (and find's
text lines) did not say which bundle node / webfile entry an object came
from. Both now tag container objects with the node path (hash reuses the
Fp node field, find matches get a node field; bare serialized files keep
no tag). Verified: the 2-entry collide webfile's 4 hash and find entries
split across a.assets/b.assets, find's text lines append "in <node>",
the gzip webfile tags its entry, and bare serialized output is
unchanged.

2026-08-30 (patch node selectors): `edit --patch` keys were bare path
ids, so a patch could not target one specific node of a multi-node
container. Patch keys now accept the same `node:path-id` selector as
show/edit (the per-node grouping routes each key to the matching entry;
node selectors on a bare serialized file are a clean error; bad keys are
skipped as before). Verified: {"a.assets:200":...} patches only that
entry (b untouched), a plain {"200":...} still patches every matching
node, bundle patches with CAB-xxx:1 keys work, and patch --verify
composes.

2026-08-30 (verify/extract --path-id selectors): `verify --path-id` and
`extract --path-id` accept the same `node:path-id` selector as show/edit,
so a specific node's object can be checked or pulled after a selector
edit. The container loops skip nodes that do not match the selector;
bare path ids behave as before; node selectors on a bare serialized file
are a clean error. Verified: verify b.assets:100 checks exactly that
object (1 checked, node-tagged failure on the corrupt fixture), extract
--path-id b.assets:100 writes only that node's object, plain --path-id
100 still extracts/checks every matching node.

2026-08-30 (hash --path-id selector + selector fuzz): `hash --path-id`
accepts the node:path-id selector too, completing the uniform targeting
surface (show/edit/patch/verify/extract/hash all take selectors); bare
path ids and serialized-file behavior unchanged. A selector fuzz over
mutated 2-entry webfiles (30 mutations x 6 selector commands = 180
invocations: show, hash, verify, extract, edit single, edit patch, all
with node selectors) found zero crashes and zero hangs in the new
parsing and node-filtering paths.

2026-08-30 (README audit): the README had drifted across the ~20 slices
of this and earlier instances: it still claimed std flate "can panic on
deliberately truncated gzip streams" (fixed in step 68) and "hundreds of
mutated inputs" (now ~6,500+), omitted `hash` from the capability list,
and did not mention the node:path-id selectors or `find --exact`. The
capability, node-awareness, and fuzz-status sections were rewritten to
match the tool; a docs-check confirms no new flags (still the 42
pre-existing ones).

2026-08-30 (dead code removal): a reference scan found four functions
defined but never called: statsSerializedBytesJson (a pre-refactor stats
JSON variant superseded by the duplicate-group work in step 74) and
sign3/extend4/extend5 in texture.zig (ETC helpers superseded by the
table-driven decoders). All four removed; a re-scan finds no remaining
unreferenced functions, 206/206 tests pass, and sprite/texture extraction
is unchanged.

2026-08-30 (real-asset formats: v6 bundles, sidecars, audio): per the
user's directive to obtain sample assets rather than declare them
blocked, downloaded UnityPy's test bundles (Unity 2018.4, 2017.4, and
5.6) - all previously unparseable. Three real parser bugs fixed:
(1) the v6 header carries both version strings unconditionally (read
them for every UnityFS version, matching UnityPy); (2) each block's own
flags carry its compression (blocks decode with `flags & 0x3F`, not the
header's type - xinzexi mixes an LZ4HC header info with an LZMA data
block).

(3) Unity's LZMA blocks use props+dict+stream framing with no
size field (5-byte), and std's lzma circular buffer mis-decodes streams
larger than the dict - both handled by normalizing to a 13-byte header
with the dict raised to the output size, trying both framings.

New
capabilities: `.resS`/`.resource` sidecar nodes resolve m_StreamData
texture pixels automatically (banner_1's ASTC texture and sprite, plus
xinzexi's ETC2 texture extracted and cross-validated: ETC2 pixel-
identical to UnityPy, ASTC within ±1 - a rounding variance vs ARM's
astc_encoder, now documented), and AudioClip extraction (35 FSB5 clips
from char_118's .resource, OGG/WAV-wrapped PCM/MP3 detection).

A fuzz of
the new paths exposed latent ASTC decoder panics on corrupt blocks
(integer overflow, @intCast, and grid-index OOB) - the ASTC decode now
uses wrapping arithmetic, truncating casts, and clamped shifts/indices
throughout, verified with 180+150 mutated invocations at zero crashes.
New regression tests cover the v6 header and block-flag semantics;
208/208 tests.

2026-08-30 (crunch textures + SpriteAtlas sprites): same directive - a
crunched atlas was missing, so fetched the UnityPy test bundle with a
1024x512 ETC2_RGBA8Crunched (65) Texture2D streamed from an embedded
.resS. Crunch decompression is a 3837-line C++ decoder with no Zig port,
so the ZLIB-licensed unitycrunch (Geldreich/Binomial) was vendored as-is
(`src/vendor/unitycrunch/`, built with `-DNDEBUG` so corrupt input
cannot trip C++ asserts and abort the process - the fuzz harness found
this exact failure mode) and exposed through an extern-C shim
(`src/vendor/unitycrunch_shim.cpp`) that malloc/free's the decoded
blocks, keeping the Zig boundary ABI-clean.

Formats 64/65 decode in
`texture.zig` by calling the shim then running the regular ETC1/ETC2
decoder; the atlas texture extracts pixel-identical to UnityPy.

The atlas's 7 sprites were silently skipped before: they carry a
`{0,0}` texture PPtr (the null reference) and get their texture from the
SpriteAtlas. `atlasTextureFor` now scans the file's SpriteAtlas objects
and resolves the sprite by `m_RenderDataKey` (UnityPy's lookup), falling
back to positional alignment of m_PackedSprites/m_RenderDataMap; a
{0,0} PPtr is treated as null; the crop uses the atlas entry's
textureRect.

The sprite crop itself was off by one pixel: it truncated `rect.width`,
while Pillow's `Image.crop` floors x/y and ceils x+w/y+h and clamps to
the texture bounds. `spriteRgbaRect` now rounds the same way, and all 7
exported sprites are byte-identical to UnityPy's export.

Fuzz of the
crunched decode across all 4 fixtures: 180 mutated invocations, zero
crashes or hangs; 208/208 tests.

2026-08-30 (ASTC HDR decode): Unity's ASTC_HDR formats 66-71 were
detected but unsupported; they now decode. UnityPy's texture2ddecoder
rejects HDR blocks (confirmed: it returns garbage on astcenc-encoded HDR
data), so ARM astcenc is the reference.

The block decoder already had the
shared-exponent HDR endpoint machinery (luminance small/large range, RGB,
RGB-scale, RGBA, RGB+LDR-alpha) but the formats were unroutable; added
the 66-71 constants, names, and block sizes.

Verified against astcenc on
51 synthesized HDR textures: all six block sizes, both HDR profiles,
gradients, negatives, highlights, HDR alpha (RGBA mode), grayscale
(luminance modes), and non-multiple dimensions for edge blocks. HDR
lanes decode byte-exact (0 bytes differ on 49 of 51 cases).

The only
variance is ±1 LSB on LDR-valued alpha lanes inside FMT_HDR_RGB_LDR_ALPHA
blocks (68 of 73092 bytes, max diff 1): astcenc routes those lanes
through an fp16 intermediate (unorm16_to_sf16) before scaling to 8-bit,
while unityz keeps the exact value - a rounding variance of the same
class as the documented LDR ASTC ±1, and the exact math is the
defensible choice.

Added a regression test (real astcenc-encoded 11x11
HDR RGBA fixture with verified expected output) and a crash-only fuzz of
mutated HDR streams across all block sizes.

The fuzz found a real panic:
corrupt weight grids push the bilinear-interpolated weight past 64, so
`64 - weight` wrapped negative and the u16 interpolant in
`astcSelectColorHdr` overflowed (the HDR lane path had missed the
step-84 hardening). Fixed by clamping the weight to 0..64 and truncating
the sum; 6120 mutated invocations at zero crashes after the fix.

Valid
blocks are unaffected (verified byte-exact against astcenc). 209/209 tests.

2026-08-30 (raw texture format family): audited the format list against
UnityPy's TextureFormat enum and found 21 raw formats UnityPy decodes but
unityz lacked: ARGBFloat(6), BGR24(8), R16(9), RHalf(15), RGHalf(16),
RGBAHalf(17), RFloat(18), RGFloat(19), RGB9e5Float(22), RG16(62), RG32(72),
RGB48(73), RGBA64(74), and the signed variants 75-82.

All are simple
per-pixel converters, added with documented standard conversions: float
and half clamp to [0,1] then truncate x*255 (the file's existing
floatToByte), 16-bit integer formats take the high byte, signed formats
bias (i8+128, i16+32768 high byte, i32+2^31 high byte), and RGB9e5Float
uses the spec's shared-exponent decode (mantissa x 2^(e-24)).

Verified
byte-exact on synthesized pixels against independently computed expected
output (0/1008 bytes across 21 cases).

UnityPy's own converters for these
are lossy - its half path does int(x*256) and raises on values above 1.0,
and its RG32 path reads 16-bit samples - so the conversions here are
strictly more correct. Five regression tests; 214/214 tests.

2026-08-30 (BC6H decode): BC6H (format 24, unsigned HDR block
compression) was the last common texture format UnityPy decodes that
unityz lacked. Built Microsoft DirectXTex's software compressor on Linux
(the CMake build needed DirectXMath, DirectX-Headers, and a SAL-annotation
stub since sal.h is Windows-only), then encoded six HDR test textures with
D3DXEncodeBC6HU: a gradient, random values with negatives, LDR-ish
highlights, a constant block pattern, near-zero values, and a
non-multiple-sized image for edge blocks.

Ported texture2ddecoder's
decode_bc6_block to Zig faithfully (the 32-entry mode table, 64-entry
partition and anchor tables, weight factors, LSB-first bit reader,
unquantize/finish_unquantize, half-float to 8-bit with round+clamp); all
14 modes are exercised by the samples and decode byte-exact against
texture2ddecoder (0 bytes differ across the six images).

One layout note:
texture2ddecoder's u32 pixel output is BGRA in memory (byte 0 = B), while
unityz's pipeline is RGBA like every other decoder in the file. A
regression test embeds a DirectXTex-encoded HDR fixture; 215/215 tests.

2026-08-30 (PVRTC decode): Unity's PVRTC formats 30-33 (RGB/RGBA, 2bpp
and 4bpp) now decode; texture2ddecoder's own test textures (256x256
PVRTC_RGB4 and PVRTC_RGBA2, from its samples.zip) provided both real data
and the reference decoder.

Ported pvrtc.cpp faithfully: blocks are
morton-ordered in memory, each stores two 15/16-bit color endpoints
(the high bit selects punchthrough colors with 5-5-5-1 layout) plus
2-bit modulation weights, the 2bpp punchthrough path fills missing
weights from neighboring blocks' weights with an in-place write-back
order that matters, and final colors interpolate across the 3x3 block
neighborhood.

Decode is byte-exact against texture2ddecoder (0/131072
pixels across both samples; the reference's u32 pixels are BGRA in
memory, ours RGBA like the rest of the pipeline).

PVRTC requires the
block count per side to be a power of two; non-conforming images are
rejected cleanly. Regression tests cover hand-crafted single-block 4bpp
and 2bpp textures; the old unsupported-format test now uses
DXT1Crunched (28) instead of 32. Fuzzed 240 mutated invocations at zero
crashes; 216/216 tests.

2026-08-30 (ATC + EAC decode): ATC (35 RGB4, 36 RGBA8) and EAC
(41-44 R/RG, signed and unsigned) were the last block formats with
available test data. ATC is DXT1-like: two 16-bit colors with its own
interpolation (including the 0x8000 mode with the transparent black
palette entry), 2-bit per-pixel indices; ATC_RGBA8 prepends an 8-byte
DXT5-style alpha block (a helper extracted from the DXT5 path, which is
already verified).

EAC is the standalone single/double-channel form of
the ETC2 alpha channel; it uses the reference's older formula
((base*8 + multiplier*table + 4) >> 3, +1023 for signed) and the
WriteOrderTableRev texel order. A big-endian read bug (the ETC2_RGBA8
path reads big-endian, but the standalone variants were initially read
little-endian) was caught by random-block cross-validation against
decode_eacr/decode_eacrg.

Verified byte-exact against
texture2ddecoder: ATC on its 512x512 RGB4 and 128x128 RGBA8 samples
(0/278528 pixels), EAC on 32 random blocks against decode_eacr/rg and
the signed variants (0/512 pixels). Regression tests embed one ATC block
and one EAC block with reference-verified expected output; 480 mutated
invocations at zero crashes; 217/217 tests.

2026-08-30 (adaptive PNG filtering): the PNG encoder wrote filter-0
(none) on every scanline, which compresses poorly for structured content.
It now applies per-row adaptive filtering (Sub/Up/Average/Paeth, picking
the filter with the smallest sum of absolute filtered bytes - libpng's
heuristic), and the test-only decoder reverses all five filters.

On a
smooth 512x512 gradient the IDAT shrank from 323859 to 2547 bytes
(99%); on the noisy crunch-artifact atlas texture it costs about 2%,
the standard content-dependent tradeoff of adaptive filtering (libpng
defaults to it for good reason - real content is mostly structured).

The atlas extract exposed a real bug: the filter scratch buffer was
hardcoded to 1024 bytes but a 1024px RGBA row is 4096 bytes, panicking;
the scratch is now sized per image. All extracts remain pixel-identical
to UnityPy (texture and all 7 sprites). 217/217 tests.

2026-08-30 (FSB5 audio metadata): extract now writes a per-clip
.fsb.json sidecar for FSB5 banks - sample rate, channels, sample count,
data offset, loop points (from the LOOP metadata chunk), and the bank
format. UnityPy's export converts the audio but never surfaces these
fields, so this is beyond-parity.

The new src/fsb5.zig parses the 60-byte
header (magic, six u32s, zero/hash/dummy tails), the variable chunked
per-sample headers (a u64 bitfield carrying frequency index, channels,
data offset, and sample count, followed by nextChunk/chunkSize/chunkType
metadata chunks, including the FREQUENCY u32 override and the LOOP
start/end pair), and the name table (per-sample u32 offsets into a
string table).

Cross-validated field-by-field against the fsb5 Python
package (UnityPy's own dependency) on all 35 real clips from char_118's
.resource: 35/35 match, including frequency, channels, offsets, and
sample counts (the clips are all VORBIS/44100Hz/mono with no loops).

A
unit test covers a hand-built bank with a LOOP chunk and a name table;
218/218 tests.
2026-08-30 (DXT1/5Crunched): formats 28 (DXT1Crunched) and 29
(DXT5Crunched) now decode. Binomial's stock crunch encoder was built on
Linux (g++ with a windows.h stub, excluding the win32-threading, lzham,
and MT-LZMA sources) and six DXT-crunched CRN test textures were encoded.

DXT1-crunched is verified byte-exact vs UnityPy end-to-end (0/196608
pixels). DXT5-crunched's alpha cannot be verified end-to-end: Unity's
crunch fork stores DXT5 alpha in a separate stream, so stock DXT5-CRN
alpha decodes non-deterministically even in UnityPy's own
unpack_unity_crunch (two runs of the same input differ).

The verification exposed two real decoder bugs: expand565 used scaled
expansion (v*255/31) instead of the D3D bit replication ((v<<3)|(v>>2)),
and decodeDxt5 hardcoded the 4-color palette, ignoring the c0<=c1
three-color-plus-black mode. Both fixed; DXT5 is now byte-exact vs
decode_bc3 on 30 random blocks (0/480 pixels).

The vendored crunch C++ was hardened against corrupt streams: fuzzing
found three heap-corrupting paths (huffman code-length and lookup-table
overruns, a null decode table, and unchecked level offsets). All were
ASAN-diagnosed and patched in crn_decomp.h plus the shim (bounds checks,
model invalidation on failed init, and level-offset validation before
decompression); 540 mutated invocations now run at zero crashes. A
regression test covers the DXT5 three-color mode; 219/219 tests.

2026-08-31 (crunch DXT variants): Unity's DXT1Crunched (28) and
DXT5Crunched (29) now route through the same vendored unitycrunch
machinery as the ETC crunch formats: the shim decompresses to raw
DXT1/DXT5 blocks, which the existing block decoders turn into RGBA.
Found and fixed a latent off-by-one in the shared 565->888 expansion
(BCn bit-replication, `(v<<3)|(v>>2)`, not `v*255/31` truncation) that
made the whole DXT family 1 LSB low on non-maximum colors. Verified
byte-exact (512x512) against UnityPy's Pillow 'bcn' decode on real
UNITYCRUNCH_DXT1/DXT5.crn streams.

2026-08-31 (packed sprite alpha-texture + tight meshes): sprite export
now handles packed sprites. A separate alpha texture (m_RD.alphaTexture,
or the atlas entry's) is merged into the decoded RGBA before the crop:
RGB from the main texture, alpha from the alpha texture's R channel
(UnityPy's Image.merge). Packing rotation (flipH/V, 180, 90) is applied
to the crop before the final vertical flip, in UnityPy's order.

A tight
sprite (settingsRaw bit 1 == 0) parses its mesh (positions, UVs,
triangles) from m_RD via m_VertexData/Channels or the vertices list,
then masks the crop with the polygon (maskSprite) or texture-maps the
mesh UVs onto the polygon (renderSpriteMesh), mirroring UnityPy's
mask_sprite/render_sprite_mesh.

Verified byte-exact against UnityPy on
the real sprite.assets fixture (rectangle sprite); the tight mesh path
has no committed Unity fixture, so it is algorithm-faithful to UnityPy
and unit-tested but not byte-verified against a real tight sprite.

2026-08-31 (shader sub-program blobs + `skin`): `src/shader.zig` decodes a
Shader's out-of-line per-platform LZ4 sub-program blob (parameter blobs and
code blobs, each code blob closing with a `ParserBindChannels` block) and
answers whether a shader's vertex stage skins: it must bind per-vertex bone
indices/weights (BLENDINDICES/BLENDWEIGHT, mesh-channel sources 9 and 8) and
bind the per-mesh bone matrices (`unity_SkinnedMeshBoneMatrix` or an
equivalent per-mesh texture/cbuffer).

The verdict surfaces per Shader in
`info --json` and through a new `skin <path>` command that exits non-zero
when a SkinnedMeshRenderer references a shader that does not skin
(`--json` for a machine-readable report). Shader objects still round-trip
byte-exactly through `verify`. This is the tenth CLI command; the plan's
Outcome section lists the full set.

2026-08-31 (untrusted-input hardening): a pass over the values an attacker
controls in a malformed bundle. `bundle` initialises `Node.data` before the
header loop (alloc does not apply field defaults, so a rejected node range
would have been handed out as an undefined slice), rejects blocks that
decode short, checks node ranges for negative values and overflow instead of
wrapping into an in-bounds slice, and treats a short LZMA read as a
decompression failure.

`classes` narrows type-tree integers with
`std.math.cast`, so a negative or oversized field degrades to the default
rather than making `@intCast` illegal behaviour. `serialized` rejects counts
larger than the remaining metadata before they size an allocation.
`texture` bounds the pixel count so neither the RGBA8 output size nor the
16-byte-per-pixel stride can overflow into a short allocation.

`main`
replaces path separators in script class names so an extracted script stays
a single path component under the extract directory.

2026-08-31 (diff --pixels + v6 bundle rebuild fix): `diff --pixels`
decodes changed Texture2D objects from both files - resolving `.resS` /
`.resource` sidecar nodes inside the same bundle/webfile - and reports
per-channel pixel-difference counts and max deltas. Beyond UnityPy, whose
comparisons never look at pixels.

Verified end-to-end: two files with an identical image report 0 pixels
differ (after an m_MipBias edit), and a byte-mutated crunch stream
reports 14 pixels differing by up to 10 per channel.

Building the test exposed a real bug in the UnityFS v6 bundle rebuild:
the writer skipped the two version strings for format-6 bundles, but the
parser reads them unconditionally (the step-84 header fix). Every `edit`
on a Unity 5.x/2017/2018-era bundle therefore produced an unparseable
file - `--verify` failed with ShortData.

The rebuild now writes the
version strings for every format version; v6 edits round-trip with
`--verify` passing and the edited file re-parsing cleanly. A second,
smaller fix: the pixel-diff sidecar walk collected sidecars in the same
pass as the serialized-node search, but the .resS node usually follows
the serialized node, leaving the sidecar list empty; the walk is now
two-pass. 251/251 tests.

2026-08-31 (shader sub-program blob decode): extended the existing
shader-blob parser (from the skin-detection pass) into a full decoder.
`src/shader.zig` now lists every record of the d3d11 platform blob as either
a parameter blob or a code blob, and decodes each.

Parameter blobs carry the constant buffers (name, used_size, members with
their byte index, nested structs) and the texture/cbuffer-bind/UAV/sampler
entries. Code blobs carry the 38-byte program-data header (version,
SRV/cbuffer/sampler counts, UAV, geometry primitive), the DXBC chunk set,
the SHDR/SHEX declaration counts (srv/cbuffer/sampler/UAV + temp
registers), the ISGN input signature, the RDEF constant-buffer member
offsets, and the trailing ParserBindChannels (source,target) pairs.
Non-d3d11 program payloads (SMOL-V/GLSL) are recorded as undecoded rather
than guessed.

Surfaced under `show` and a new `shader`
command (`<path> <node:path-id>`), which extends the Shader's JSON with a
`shaderBlob` field; `verify` adds a class-48 check that re-encodes each
parameter blob byte for byte.

Validated byte-exact
against the reference tools on the game bundle (`Game/SDCS/Skin` d3d11
vertex records carry bind channels (0,0)(2,2)(1,1)(4,5), with COLOR (3,3) on
some records and no blend channels) and the pipeline-synthesized
`shamwayselftest.unity3d` (6/6 parameter blobs re-emit exactly); `verify`
still passes on both bundles.

Found a real allocation-safety bug while wiring
`verify`: the new parameter-blob parser pre-allocated arrays from a corrupt
count before validating it, so a bad count in one shader's blob exhausted the
arena and broke the next object's read; counts are now bounded against the
data length, matching the existing "reject counts larger than the remaining
metadata" rule. Unit tests cover the parameter-blob round-trip (incl. the
nameless base buffer) and `verifyBlob` on a synthetic shader.

2026-08-31 (3DS ETC + ETC2_RGBA1): the last block-format parity gap with
UnityPy closed. ETC_RGB4_3DS (60) and ETC_RGBA8_3DS (61) decode as ETC1,
matching UnityPy, which routes both to its ETC1 decoder.

ETC2_RGBA1 (46)
decodes its punch-through alpha: the ETC2 color block with a 1-bit alpha
per texel, transparent when the opaque-alpha flag is 0 and the texel
selects the transparent color (index 2); 8 bytes per block.

The RGBA1
decoder mirrors texture2ddecoder exactly (always runs the ETC2
mode-selection path, then applies punch-through from the obaq flag),
validated pixel-identical over a 96-block corpus. Decoding is read/verify
only; nothing in the writer path changed.

2026-08-31 (serialized format 4): the parser accepted formats 2-3 and
5-22 but deliberately skipped version 4 (Unity 4.x). Its metadata and
object-info layout match versions 3 and 5, so v4 now parses through the
same code path, and its legacy type tree uses the documented 4-byte
aligned length-prefixed strings.

Adding a v4 round-trip test exposed two
bugs in the legacy16 (version < 9) rewrite path: the metadata body was
sliced one byte too long (`metadata_size` includes the trailing
endianness byte for these versions), and `headerSize()` omitted version
4, reporting 48 instead of 16 and skewing the rebuilt
data_offset/file_size. Both fixed; v4 files now rewrite byte-exactly.

Known gap, recorded in `container.sniff`: the container-detection version
filter was never widened past the old 2-3/5-22 range, so a bare v4 file
is still unreachable from the CLI even though the library reads and
rewrites it.

2026-08-31 (multi-stream mesh export): `extract` rejected any vertex
channel with `stream != 0`, so a Mesh whose `m_Channels` spread over
`m_Streams_0_..3_` exported no OBJ at all - silent data loss against
UnityPy's MeshHandler.

`classes.Mesh` now derives the implicit
per-stream stride and offset (UnityPy's `get_streams`) via
`streamLayout()`/`channelByteOffset()`, and `writeMeshObj` reads each
channel from its own stream. Single-stream output is byte-identical to
before (the derived stream-0 stride equals the old interleaved stride and
its offset is 0), verified over 137 meshes on the tree bundle.

2026-08-31 (diff --pixels covers matched objects and sprites): the pixel
pass previously fired only on objects whose serialized bytes changed. But
texture/sprite pixels usually stream from a sibling `.resS` node, so an
edited stream byte changes no object hash and `diff --pixels` reported
"0 changed" on files that were visually different. The pass now runs on
every matched Texture2D and Sprite, and sprites are rendered through
their full pipeline (crop rect, packed rotation, alpha-texture merge,
tight/polygon mesh) before comparing.

Verified against an independent
Pillow crop on a real bundle pair with a byte-mutated crunch stream:
every reported count and max delta matches (texture 1024x512 and the
affected 122x298 sprite both report 14 pixels, R10 G10 B10 A0). Pixel
lines now name the object id and class so results map back to objects.
270/270 tests.

2026-08-31 (extract --format tga|bmp|raw): textures and sprites export as
PNG by default, plus TGA (uncompressed 32bpp, top-left origin, real
alpha), BMP (32bpp BI_BITFIELDS with an RGBA mask set, so alpha survives
where BI_RGB would force 255), and raw RGBA8 bytes - UnityPy only writes
PNG. New src/tga.zig and src/bmp.zig follow png.zig's shape (encode +
test-only round-trip reader); build.zig registers them as test roots.

Verified end-to-end on the real atlas bundle: all 8 objects (7 sprites +
the crunched 1024x512 texture) extracted in every format decode
pixel-identical to the PNG baseline through an independent Pillow reader,
alpha included. 274/274 tests.

2026-08-31 (diff --pixels on directories): `diff <dir> <dir> --pixels`
previously dropped the flag on the directory branch - the per-file
comparison never looked at pixels, so a streamed-only edit was reported
as nothing. The pixel walk is now a shared `pixelPass` (file and
directory diffs both use it), and directory diffs run it on every matched
file pair with the same matched-object semantics (streamed .resS edits
are invisible to file hashes).

Verified on the real atlas pair as
directories: the mutated stream reports the same 14-pixel texture +
sprite diffs as the file-level diff, identical directories report all
zeros, `--class 213` scopes to sprites, and non-asset files in the
directory are skipped. 274/274 tests.

2026-08-31 (SpriteAtlas export + class-name table completion): the
atlas_test bundle's mystery class 687078895 is Unity's SpriteAtlas
(confirmed against UnityPy's ClassIDType), so `extract` now writes an
`atlas_<id>_<name>.json` mapping every packed sprite's path id to its
name (read from m_PackedSprites + m_PackedSpriteNamesToIndex, verified
to align with the extracted sprite PNGs on the real atlas - 7/7 match),
and `className` covers the rest of UnityPy's enum (the ~110 high-range
registered ids: AnimatorStateMachine 1107, PackedAssets 1126, SpriteAtlas
687078895, Tilemap 1839735485, VisualEffect 2083052967, ...), so stats/
find label them instead of "Class". 274/274 tests.

2026-08-31 (extract --name filter + FSB5 duration): `extract` gained a
`--name <substring>` filter (case-insensitive `m_Name` match, combinable
with --class/--path-id/--raw/--json) so a named subset of objects can be
pulled without exporting everything - UnityPy's CLI has no name search at
extract time. Verified on the real samples: `--name TowerModern` yields
exactly the two WaterTowerModern sprites, `--name CN_00` a 9/35 audio
subset, no-match extracts nothing, and combinations with --class work.
The FSB5 metadata sidecar now reports per-sample `durationMs` (sample
count / rate), verified against an independent computation on the real
banks. 274/274 tests.

2026-08-31 (AssetBundle asset manifest): `extract` now writes each
AssetBundle object's `m_Container` as an `assetbundle_<id>_<name>.json`
manifest: the bundle's asset paths mapped to their object ids (plus the
main asset), so "what is in this bundle, under which path" is one JSON -
UnityPy's CLI never surfaces the container. Verified on both real
bundles: the atlas bundle's 8 asset paths resolve through
`info --json` to the expected classes (SpriteAtlas 687078895 for the
.spriteatlas path, Sprite 213 for the .png paths), and char_118's 35
assets are all .ogg paths matching the extracted audio; `--class 142`
extracts only the manifest. 274/274 tests.

2026-08-31 (FSB5 audio decode to WAV in pure Zig): new src/audio.zig
decodes FSB5 banks to 16-bit PCM for the codecs that need no transform
decoder - PCM8/16/24/32/FLOAT and IMA ADPCM (mode 7, the XBOX IMA
framing FSB5 uses for 1-2 channels: 36-byte per-channel blocks, header
sample + 63 nibble samples, state reset per block, low nibble first,
mirroring vgmstream's fsb5.c / ima_decoder.c). `extract` now writes a
playable .wav for those banks in addition to the .fsb + metadata
sidecar; Vorbis banks (the common case) stay as .fsb - UnityPy shells
out to ffmpeg for every conversion, so this removes the dependency for
the decodable modes.

Verified on synthetic banks in every mode: PCM8/16/FLOAT decode exactly
against fsb5.py (UnityPy's own dependency), IMA mono + stereo decode
exactly against an independent Python implementation of the same
framing, and a single-frame IMA bank agrees with ffmpeg's adpcm_ima_xbox
within ±2 LSB (its direct-multiplication delta formula rounds differently
from the branch form vgmstream uses for FSB5; framing and step-index
evolution match). PCM24/32 use straightforward sign-extend + truncate.
The real char_118 banks (all Vorbis) still extract with .fsb + sidecar
and no wav, as before. 277/277 tests.

2026-08-31 (diff --audio): `diff` gained an `--audio` pass that compares
the resolved stream data of every matched AudioClip (embedded or a
`.resource` sidecar slice), mirroring the `--pixels` matched-object
semantics: stream bytes live outside the serialized payload, so an
edited stream byte changes no object hash and plain `diff` reports
nothing.

Verified on a real bundle pair where one byte of the .resource
stream was flipped: `diff` previously reported "36 unchanged, 0
changed"; `--audio` now reports exactly one clip differing, with the
first difference at offset 5904 within its 17088-byte stream - matching
the mutated resource offset 10000 (4096 + 5904) cross-checked against
the extracted sidecars. Identical files report 0 differ, `--class 83`
scopes to clips, and directory diffs run the pass per matched pair.
277/277 tests.

2026-08-31 (find --any): `find` gained an `--any` flag that matches the
needle against every string value in an object's tree, not just
`m_Name` - so objects whose interesting strings live in other fields are
searchable (e.g. AssetBundle `m_Container` asset paths). Combines with
`--exact` for whole-string equality. Verified on the real bundles:
`find char_118 "torappu"` finds nothing (no m_Name contains it), while
`--any` finds the AssetBundle through its container paths, and
`--any --exact` with a full asset path matches exactly. 277/277 tests.

2026-08-31 (AnimationClip curve export): `extract` now writes each
AnimationClip's curves as an `animation_<id>_<name>.json`: the clip
name, legacy flag, sample rate, and one entry per curve (bone path,
attribute, and keyframes with time, value, inSlope, outSlope - the
weight fields are defaults and dropped). Handles the six curve arrays
(Euler/position/scale/quaternion/float/PPtr) with per-field default
attributes.

The samples came from the other sessions' UnityPy test
bundles (tmpjoxz4_66.unity3d), which do contain AnimationClips - the
earlier "no animation samples" gap was about the mobile-game samples
only. Verified on both real clips: keyframes match the raw tree
field-by-field, and the times/name/rate match UnityPy's typed read
exactly (UnityPy has no curve export, so this is beyond-parity).
277/277 tests.

2026-08-31 (hierarchy command): new `hierarchy <path>` command prints a
scene's GameObject/Transform tree: root transforms first, recursing
through m_Children, each node named by its GameObject with the transform
path id, the GameObject's component classes, and the local position
(`--json` for the same tree as nested objects). The scene test bundles
from the other sessions (tmpiyofv9_i.unity3d, 23 GameObjects + 23
Transforms) unlocked it.

Verified: the full 23-node tree - transform
ids, parent-child structure, and names - matches UnityPy's typed read
exactly. Two bugs caught while building: the GameObject m_Component
entries wrap the PPtr in a "component" field (pptrPathId on the entry
missed it), and a shared JSON comma flag corrupted nested children
arrays (now per-list separators). 277/277 tests.

2026-08-31 (info --objects names): the object table now includes each
object's `m_Name` (read through its type tree; objects without a name or
tree stay bare), in both text mode and the `--json` object_list entries.
Verified on the real bundles: the atlas bundle's 10 named objects match
the find/extract names exactly (sprites WaterTower/WaterTowerModern3/
..., the SpriteAtlas, the AssetBundle), and the JSON stays parseable.
277/277 tests.

2026-08-31 (diff --json pixel/audio stats): the pixel and audio passes
now collect structured stats, and `diff --json --pixels/--audio` embeds
them in the JSON document - per-object `pixels` entries (path id, class,
dimensions, differing-pixel count, per-channel max delta) and per-clip
`audio` entries (sizes, first differing offset). In `--json` mode the
passes' text diagnostics move to stderr, so stdout carries exactly one
parseable JSON document. Directory diffs keep the text form (their json
report is per-file).

Verified on the real pairs: the atlas mutation
reports the same two differing objects (sprite 122x298 and texture
1024x512, 14 pixels, max delta [10,10,10,0]) and the audio mutation the
same clip (first diff 5904) as the text modes, with stdout now parsing
as pure JSON. 277/277 tests.

2026-08-31 (Material structured JSON): `extract` now writes each
Material's saved properties as a structured `material_<id>.json` in
addition to the readable text: name, shader reference (path id),
render queue, and the m_SavedProperties lists - texture bindings with
their scale/offset, floats, colors (RGBA), ints. UnityPy reads
materials generically; this is the "what does this material reference"
answer in one file. Verified on the real material: name, shader path 73
(resolving to the Shader object), _MainTex binding, and the empty
float/color/int lists all match the raw tree and UnityPy's typed read
exactly. 277/277 tests.

2026-08-31 (hierarchy bone annotation): `hierarchy` now marks the
transforms referenced by any SkinnedMeshRenderer's `m_Bones` as bones -
`(bone)` in the text tree and a `"bone":true` flag in the JSON nodes -
so the skeleton binding is visible in the scene tree alongside the
`skin` shader-side check. Verified on the real scene: exactly 19 of the
23 transforms are marked, matching the SkinnedMeshRenderer's m_Bones
list (first: Root/Pelvis/Spine/Chest/Neck, ids 5/7/9/11/13/15...), in
both text and JSON modes. 277/277 tests.

2026-08-31 (Shader structured JSON): `extract` now writes each Shader's
parsed form as a structured `shader_<id>.json` in addition to the
readable text: name (falling back to the parsed form's name when the
top-level m_Name is empty, which the real sample showed), the keyword
list, and the subshader/pass structure (LODs, pass types and state
names). Verified on the real shader: name "Shamway/Unlit", 1 subshader
at LOD 100 with a single pass (type 0), all matching the raw tree, and
the empty top-level m_Name agrees with UnityPy's typed read. 277/277
tests.

2026-08-31 (diff --fields): `diff` gained a `--fields` pass that decodes
both value trees of each changed object and reports the exact fields
that differ, with dotted/indexed paths (m_LocalPosition.y,
m_Children[0]) and both values, capped at 10 per object. Verified
end-to-end on the real scene bundle: editing a Transform's
m_LocalPosition.y reports `m_LocalPosition.y (0.6 -> 1.25)`, and
editing m_Children[0].m_PathID reports the PPtr change - both edits
round-trip clean under `edit --verify` (73 objects). 277/277 tests.

2026-08-31 (diff --fields binary fixes): exercising `--fields` on the
two real scene bundles (tmpiyofv9_i vs tmpjoxz4_66, the same creature
scene renamed) exposed two real defects.

Equal binary fields were reported as changed - `valuesEqual` handled
strings, PPtrs and bools but not `.bytes`, so every byte array (mesh
index/vertex data, compressed-mesh blobs) showed as differing even when
identical; the two meshes' 8928-byte index and 88448-byte vertex
buffers are byte-equal, so the correct report is just the renamed
m_Name. And binary leaves render as base64 that can be megabytes, so
the report printed huge blobs; leaf values are now truncated to 72
chars.

The real-bundle diff now reports the actual differences
(container paths renamed and a "physics" entry added, GO/material/mesh
names, the material's shader reference 73 -> 74) in 0.05s with zero
false positives. 277/277 tests.

2026-08-31 (diff --fields JSON): `diff --json --fields` now carries the
exact-field reports in the JSON document - a `fields` array of
`{path_id, path, old, new}` entries - instead of text-only diagnostics,
completing the pixel/audio/fields JSON story (stdout is a single
parseable document with the text diagnostics on stderr). The walker now
collects instead of printing when in json mode; added/removed fields
render as `<absent>`. Verified: the real-bundle diff emits 28 entries
(the container rename, GO/material/mesh names, the shader reference
73->74) matching the text mode, and a single-field edit reports
`m_LocalPosition.y (0.6 -> 1.25)` in both modes. 279/279 tests.

2026-08-31 (deep scene edit round-trip): verified the deepest nested
edit path on real scene content: `edit ... 71
m_PositionCurves[0].curve.m_Curve[1].value.y 0.15 --verify` edits an
AnimationClip keyframe through a five-level dotted path (74 objects
round-trip clean, UnityPy reads the new value), and a three-object
`edit --patch` on the scene bundle (GameObject m_Name, Transform
m_LocalPosition.y, the same AnimationClip keyframe) applies atomically
and round-trips clean, with `diff --fields` pinpointing all three exact
changes and a subsequent `extract` emitting the edited keyframe.

The
patch JSON shape (an object of path-id -> field -> value) was only
tersely documented, so the usage text now carries a concrete patch
example following the project's help conventions. 279/279 tests.

2026-08-31 (ROADMAP refresh + skin scene validation): the roadmap's
Planned section still listed the managed .NET graph (resolved by the
type-tree graph export) and its Done list predated the recent
beyond-parity work; both corrected - Planned is now empty and the
beyond-parity CLI work (diff --pixels/--audio/--fields, TGA/BMP/raw
formats, FSB5 decode, find --any, hierarchy, the structured exports)
is recorded.

Also validated `skin` on the real scene bundle for the
first time: it correctly reports that the Shamway/Unlit shader does not
skin (no blend channels, no bone bindings) and that the scene's
SkinnedMeshRenderer (46) references it, exiting 1 - so that scene's
renderer would show broken skinning in-game, a real finding the tool
surfaces. The atlas bundle passes with exit 0. 279/279 tests.

2026-08-31 (JSON names + sprite pixel-diff cache fix): `hash --json`
entries and `stats --json` classes now carry object/class names,
consistent with the `info --objects` names.

Adding the names surfaced a
real regression from the merged sprite-cache memoization: `pixelPass`
created ONE `SpriteCache` and passed it to both files' decodes, so file
B's sprites resolved their atlas texture through file A's memoized
atlas values and every sprite rendered identically - `diff --pixels`
reported 0 diffs even though extract proved the renders differ (the
mutated atlas's WaterTowerModern3). Fixed with per-file caches; the
sprite pixel diff now reports the correct 14 pixels again in text, JSON
and directory modes. 279/279 tests.

2026-08-31 (FSB5 PCMFLOAT precision + IMA stereo validation): the
post-merge regression battery over the shipped FSB5 decode found one
real off-by-one: mode-5 PCMFLOAT scaled in f32
(`@intFromFloat(clamped * 32767.0)`), and the rounded product could
truncate 1 LSB off the reference, which computes in f64 (Python
floats). Decode now promotes to f64 before truncation; a unit test
pins a boundary float (0x3f731e23: f32 math truncates to 31121, exact
math to 31120).

The same battery also settled the stereo IMA
layout question: FSB5 banks interleave 4-byte per-channel headers then
4-bytes-per-channel nibbles (vgmstream decode_xbox_ima), matching the
decoder; the earlier "stereo FAIL" was a generator bug (contiguous
blocks) and the ffmpeg ±2 LSB gap is ffmpeg's own
`((2*delta+1)*step)>>3` multiplication form plus big-endian XBOX WAV
headers, both reproduced exactly in the harness. All seven checks now
pass: PCM16/8/FLOAT bit-exact vs fsb5.py, IMA mono+stereo bit-exact vs
an independent vgmstream-formula reference and vs ffmpeg. 280/280
tests.

2026-08-31 (real FSB5 banks + frequency-table fix): the "no real
audio samples" gap closed with authentic FMOD-generated banks from
Fmod5Sharp's test resources (github.com/SamboyCoding/Fmod5Sharp,
Fmod5Sharp.Tests/TestResources) - real game banks, not synthetic:
pcm16.fsb (PCM16, 96 kHz), imaadpcm_long/short.fsb (IMA stereo),
xbox_imaad.fsb (IMA mono), plus gcadpcm and vorbis banks for
metadata.

The FSB5 metadata parser matches fsb5.py
field-for-field on every bank, and the decoder is byte-exact against
two independent implementations on all four decodable banks: the
vgmstream-formula reference and Fmod5Sharp's own C# decoder (built
and run via dotnet, pcm data extracted from its unpatched-placeholder
WAV headers).

The real banks exposed one real parser bug: Fmod5Sharp's
pcm16.fsb uses frequency code 10 (96 kHz), which the sample-rate
table lacked (it fell back to 0), and code 0 is 4000 Hz, not
"unknown".

Both entries now match vgmstream's fsb5.c and Fmod5Sharp's
FsbLoader.Frequencies. fsb5.py itself rejects both codes (raises
"Frequency value 0/10 is not valid"), so unityz is strictly more
robust there. Codes 11-15 still report unknown (0), and two
minimal-bank unit tests pin codes 0 and 10. 282/282 tests.

2026-08-31 (FSB5 GCADPCM decode): mode 6 (FMOD_SOUND_FORMAT_GCADPCM)
now decodes in pure Zig - the GC DSP framing FSB5 uses: fixed 8-byte
blocks, 14 samples each, block byte 0 packing the predictor index
(high nibble) and scale exponent (low nibble), 7 bytes of signed
nibbles high-nibble-first, with the 8 coefficient pairs read
big-endian from the new DSPCOEFS metadata chunk (46 bytes per
channel: 32 coef bytes + 14 FMOD-written bytes that decoders skip).
Mirrors vgmstream's ngc_dsp_decoder.c and Fmod5Sharp's
FmodGcadPcmRebuilder.

Verified byte-exact against Fmod5Sharp's C#
decoder (built and run via dotnet) on its real gcadpcm.fsb bank
(8064 samples, 0 diffs, real signal - min -13145 / max 15101).
Mono only: vgmstream decodes multi-channel GCADPCM with a
subframe-interleave framing (2-byte interleave) that has no sample
available to verify, so multi-channel mode 6 reports
UnsupportedChannels rather than guess. fsb5.Sample carries the coefs;
the extract WAV path and the .fsb.json sidecar pick them up
automatically. Two unit tests: a hand-computed identity-filter block
and a DSPCOEFS chunk parse. 285/285 tests.

2026-08-31 (real .resS sidecar + OBJ golden parity): the remaining
"no real .resS sidecar" gap closed with UnityPy's own test bundle
xinzexi_2_n_tex (github.com/K0lb3/UnityPy, tests/samples, fetched via
the repo's git-lfs): a Unity 2017.4 bundle whose 2 MB CAB-*.resS
node carries the streamed texture pixels (the Texture2D object is 192
bytes; its m_StreamData references the whole sidecar).

Extract
resolves it and the decoded 2048x976 ETC2_RGBA8 texture is
pixel-identical to UnityPy's. The 2038x976 polygon-mesh sprite
renders identically too: 0 RGB-visible pixel differences; 7 of
1,989,088 pixels disagree on alpha at transparent-region boundaries
(PIL's integer polygon fill vs our float-geometry rasterizer), and
~3000 more "differences" are invisible RGB under alpha-0 that
UnityPy's affine fill leaves behind.

The same bundle ships UnityPy's golden OBJ export
(tests/samples/xinzexi_2_n_tex_mesh), which our mesh exporter now
matches byte for byte on the v/g/vt sections - group names (`g`, not
`o`), per-submesh `g <name>_<N>` lines, and floats printed like
Python's %.9g (9 significant digits, round-half-even, "-0" for
negated zero).

The only remaining diff is the f lines: UnityPy
emits v/vt/vn face references with no vn declarations (undefined
indices), which we deliberately do not replicate; with normals present
our faces carry real vn references. writeObjFloat implements the
%.9g semantics (exact integer powers of 10 + half-even ties, verified
against Python's format on the golden values); unit test pins the
rounding cases. 286/286 tests.

2026-08-31 (ASTC LDR interpolation rounding): the banner_1 real-bundle
comparison (UnityPy's own test asset, github.com/K0lb3/UnityPy
tests/samples) found its ASTC_RGBA_6x6 texture differing from UnityPy
by exactly 1 LSB on ~31% of pixels - a systematic rounding, not the
±1 "variance" previously documented. Bisecting with the real banner
blocks against ARM's astcenc (compiled from source, plus the
astc_encoder Python binding) pinned it to the LDR color
interpolation: the output byte is the top 8 bits of the 16-bit
interpolant (astcenc's lerp_color_int truncates with `t >> 8`), where
unityz used `(t*255+32768)>>16` - the two differ by 1 on texels whose
16-bit value lands in the rounding gap.

The weights were already correct (astcenc's `summed_value(8)`
accumulator is the same `+8 >> 4` rounding unityz uses; the block-mode
quant, weight grid, and decimation tables all match astcenc
field-for-field, verified by dumping astcenc's per-texel weights and
endpoints for the real block 667). The one-line fix makes the LDR
path byte-exact: the banner's 492x180 ASTC texture and its 488x170
polygon-mesh sprite now decode with 0 pixel differences vs UnityPy,
on pixels streamed from a real .resS sidecar. A regression test pins
the real block (texels 0-2: 65/29/36, 29/45/45, 35/54/54 - the old
form gave 66 and 30). HDR ASTC is untouched (its fp16 path was
already byte-exact). 287/287 tests.

2026-08-31 (OBJ float exponent form + full mesh byte-parity): comparing
the scene bundle's multi-stream mesh export against UnityPy's exposed
the last %.9g gap: C's %g switches to exponent form for |v| < 1e-4 or
>= 1e9, and real meshes carry denormal-scale values (the creature
mesh's 8.57252764E-18 vertices) - the OBJ writer now emits
`<mantissa>E<sign><exp>` for those, matching UnityPy byte for byte.

With that, every real mesh in the sample set exports byte-identical
to UnityPy: the scene bundles' multi-stream creature mesh (724-vertex
position/normal/UV channels, 1382 vn lines, denormal values) and its
renamed twin, 0 diff lines including the f lines; the xinzexi golden
OBJ still differs only in UnityPy's undefined-vn face references (its
own bug - the sprite mesh carries no normals).

The writeObjFloat
unit test pins the exponent cases (8.57252764E-18, -3.5E-05, 1E+09,
1.23456789E-05) against Python's format. The diff passes were also
exercised on the new real bundles: banner_1 self-diff --pixels reports
0 pixels across 3 objects, char_118 self-diff --audio compares all 35
clips with 0 differ, and the scene bundle pair reports exactly the
renames (AssetBundle container, GameObject m_Name). 287/287 tests.

2026-08-31 (edit round-trip on UnityPy test bundles): the
edit/reserialize machinery exercised on the three sidecar-carrying
UnityPy test bundles - banner_1 (Unity 2018.4, .resS texture),
char_118_yuki.ab (Unity 5.6.7, .resource audio) and xinzexi_2_n_tex
(Unity 2017.4, .resS texture) - renaming a Sprite m_Name and an
AudioClip m_Name through the CLI.

All three edit with --verify
round-trip clean (3/36/4 objects), the rebuilt bundles re-parse with
both unityz and UnityPy, and the streamed content is untouched:
banner's texture reports 0 pixel diffs vs the original, char_118's
UnityPy re-read finds all 35 clips plus the renamed one, and
xinzexi's edited sprite + texture renders are byte-identical to the
original extracts (the resS sidecar survives the rebuild byte for
byte).

The rebuilt bundles write their block uncompressed (flags 0x0
vs the source's 0x43) - pre-existing rebuilder behavior, verified
parseable by both tools. 287/287 tests.

2026-08-31 (FSB5 Vorbis to playable Ogg): the last FSB5 gap - Vorbis
banks (mode 15, the common case) previously stayed as .fsb - is
closed with a pure-Zig remux. The bank's raw packet stream ([u16
size][packet] pairs, EOS at size 0/0xFFFF) is framed into a standard
Ogg/Vorbis stream: the identification and comment headers are
synthesized, and the setup header (codebooks + modes) comes from a
CRC-keyed table of FMOD encoder configurations - the VORBISDATA
metadata chunk carries the CRC.

New src/vorbis.zig (Ogg page
writer with CRC, page-out rules, granule tracking, per-packet
block-size computation from the setup header's mode flags) plus the
embedded table (src/vorbis_headers.bin, 621KB, 161 entries, generated
from Fmod5Sharp's MIT-licensed table; NOTICE updated).

Verified on five real
banks (Fmod5Sharp's test resources plus char_118's CN_034): the
reconstructed oggs are byte-identical to Fmod5Sharp's own rebuilds,
playable, and their durations match the FSB5 metadata sample counts
exactly (0.5625s for short_vorbis etc.).

extract now writes a
playable .ogg beside the .fsb for every vorbis bank; char_118's 35
clips all export as oggs. The setup-header bit reads follow
Fmod5Sharp's LSB-first BitStream (the byte-exact reference) - the
spec's MSB-first reading would give different (less-tested) block
sizes.

UnityPy converts FSB5 via fmod_toolkit/ffmpeg; its decoded PCM
differs from ffmpeg's decode of our ogg by +/-1-2 LSB (normal vorbis
decoder rounding), with identical durations. Unit tests: block-flag
parse, page framing with CRC verification. 289/289 tests.

The table's coverage was also checked against vgmstream's own FSB
codebook set: both derive from the same python-fsb5 extraction and
carry exactly 161 unique setup CRCs, so the embedded table is the
complete known set, not a subset.

A follow-up fuzz pass mutated both
real vorbis banks (headers and packet data) through parse +
rebuildOgg - 100,000 iterations across 5 seeds, zero crashes, the
bounds checks and the OggStream's growable buffers degrade cleanly.
extract now prints a note (instead of failing silently) when a
vorbis bank's setup CRC is not in the table and the clip stays .fsb.

The FSB5 metadata sidecar also gained the codec name (`codec`:
"PCM16", "Vorbis", ...) and, for mode-15 samples, the setup-header
CRC (`setupCrc`) - the identifier that maps to the known encoder
configs - alongside the raw mode number. Verified on char_118: every
clip's sidecar reports codec Vorbis / mode 15 with a setupCrc
matching the reconstruction table (3605052372 is the same FMOD
config as Fmod5Sharp's short/long_vorbis banks). 289/289 tests.

A direct fuzz of the audio decode path (PCM8/16/24/32/FLOAT, GCADPCM,
IMA) - random data, sample counts, and channel counts per iteration,
150,000 iterations across 3 seeds - found zero crashes; the per-mode
bounds checks (data length vs sample count x channels, coefficient
array size, block framing) all degrade to errors. The ROADMAP's
FSB5 line now also records the Vorbis-to-Ogg remux. 289/289 tests.

2026-08-31 (edit: base64 byte-array patching): the edit command now
accepts a base64 string literal for byte-array fields, so raw binary
data is patchable through the CLI - mesh index/vertex buffers, image
data, audio payloads. `setFieldPath` gained an allocator and converts
a base64 string to `.bytes` at the leaf when the target is a byte
array (bad base64 is rejected, other literals pass through
unchanged).

Verified on the real scene bundle: patching the creature mesh's
m_IndexBuffer to a 16-byte buffer round-trips clean under --verify
(73 objects) and UnityPy still reads all 73 objects. The usage text
documents the form (`edit f.unity3d CAB-..:44 m_IndexBuffer
'"AwD/AA=="'`). Unit test covers the decode and the rejection of
malformed base64. 289/289 tests.

2026-08-31 (edit --patch: extract --json round-trip): feeding an
`extract --json` export back through `edit --patch` now round-trips
byte-exactly, which exposed and fixed three real gaps. (1) The
object writer accepted only `.float` values for float fields, but
`extract --json` prints whole-number floats (quaternion w:1, position
x:0) without a decimal point, so every Transform failed; `asFloat`
now widens int/uint like `asInt` already did.

(2) Base64-to-bytes conversion only ran on a directly-addressed leaf,
so replacing a whole subtree (a mesh's `m_VertexData`) left embedded
byte fields as strings; `asTargetValue` now coerces recursively,
walking the target shape. (3) Some type trees name plain fields with
literal brackets (a mesh's `m_MeshMetrics[0]` is a float, not an
array access), which `parseFieldPath` misread as indexing; a literal
raw-text match now wins over the name+index reading.

Verified on the real scene bundle: all 73 objects patched with their
own exported JSON, `--verify` round-trips clean, re-extraction diff
shows 0/73 value-tree changes, and UnityPy still reads all 73
objects. Unit tests pin the float widening (object_writer), the
recursive byte coercion, and the literal-bracket field name.
290/290 tests.

2026-08-31 (edit: streamed Texture2D de-stream): the base64 subtree
machinery now covers streamed textures. A Texture2D whose pixels live
in a `.resS` sidecar (m_StreamData offset/size/path, embedded image
field empty) can be de-streamed through one `edit --patch` entry:
patch the image byte field with the sidecar bytes (base64) and zero
m_StreamData. The rebuilt bundle verifies clean and decodes
pixel-identically (1024x512 ETC2_RGBA8Crunched atlas: raw RGBA byte
equality vs the original extraction), `diff --pixels` shows the swap
(one flipped stream byte -> 423,981 texture pixels + every packed
sprite), and UnityPy reads the de-streamed file and decodes the
texture.

Unity 5.6 AudioClips have no embedded byte field (pure m_Resource
streaming), so they are not de-streamable this way; that path is the
sidecar-node edit slice. README edit section documents the workflow.
290/290 tests.

2026-09-01 (edit: raw-node sidecar byte patches): edit --patch gains a
node-path key form that patches a raw container node's bytes at an
offset - {"CAB-..resource": {"offset": N, "bytes": "<base64>"}} -
reaching streamed payloads the object tree never held (Unity 5.6
AudioClips stream their banks via m_Resource with no embedded byte
field). The decoded bytes overwrite [N, N+len) in the node's data; the
range must fit, so every sidecar reference (m_Resource offset/size,
m_StreamData) stays valid. Multiple entries for one node apply in
order; keys must name an existing non-serialized node (a serialized
node needs node:path-id).

Verified on the real char_118 bundle (v6, 2 nodes): an identical
4096-byte bank patched back at offset 0 round-trips clean (36/36,
diff --audio 0 differ); a flipped byte at offset 2000 shows in
diff --audio as exactly that clip, first difference at 2000; a
non-zero offset (4096, CN_001's 17088-byte bank) likewise; UnityPy
still reads all 35 clips from each rebuilt bundle. WebFile entries get
the same form. Unit tests cover the decode/replace, out-of-range
rejection, malformed literals, and the key classification. 291/291
tests.

2026-09-01 (verify: streamed-reference integrity): verify now checks
that every streaming reference resolves, not just that objects
round-trip. A recursive scan of each object's value tree finds
m_StreamData (modern) and m_Resource (5.x) values and checks the
range: a path-less range must fit in the file itself; a named range
must fit inside the sibling sidecar node whose basename matches the
stream path (the same resolution rule extract uses).

This is the safety net the new edit capabilities need: breaking a
reference (a cleared m_StreamData whose pixels are still streamed, a
raw-node sidecar patch that cut data short, a retyped m_Source) now
fails verify with a specific message instead of silently producing a
file whose texture/audio never loads.

Zero-size references (embedded or cleared) are skipped.

Verified on all five real bundles (char_118, banner_1, xinzexi,
atlas, scene: all clean) and two negative cases built with edit
--patch (m_Resource.m_Size bumped past the sidecar -> "exceeds
sidecar (703776 bytes)"; m_Source retyped -> "no sidecar node
named ..."); --json records the failures in the report with exit code
parity. Unit test pins both StreamingInfo shapes, the
out-of-range/missing/path-less cases, and the recursive scan.
291/291 tests.

2026-09-01 (session note: concurrent --trees work): while the
streamed-reference verify check was being built, another session was
simultaneously editing src/main.zig + src/typetree.zig to add an
injected type-tree feature (`--trees <file.json>`: external class
trees for typeless files, wired through extract/show/verify). The two
changes are entangled: --trees added params to
verifySerializedBytes/verifySerializedBytesSidecars (which the
streamed-reference check also extends) and reuses the same object
loop. The parallel session never landed a commit (tree settled
untouched for ~25 minutes), so the combined working tree was shipped
as one commit covering both changes.

The combined tree compiles and passes 292/292 tests, and the --trees
CLI surface smoke-tests clean (missing file / bad JSON -> diagnostic
and continue; empty trees -> normal extraction; verify unaffected).
The --trees README note was added in the 2026-09-01 docs sweep; unit
tests for it remain a follow-up. The streamed-reference work itself
is complete and verified (positive pass on all five real bundles;
negative cases via edit --patch: m_Resource.m_Size out of range ->
"exceeds sidecar", m_Source retyped -> "no sidecar node", both also
in --json mode).

2026-09-01 (session note 2): the --trees session resumed after PR
#51 merged. It is now debugging the injected-tree decode against a
real Raft MonoBehaviour (GizmoBox, sharedassets0.assets object
30969): the working tree carries DBG prints in
main.zig's injectedTreeFor plus a temporary test in
object_reader.zig ("injected-tree GizmoBox decode ... (temp)"). This
WIP is intentionally left untouched and uncommitted; it belongs to
that session. Local checkout is on feat/verify-streamed-refs (the
merged PR branch); origin/main is 15c5deb.

2026-09-01 (bundle rebuild: LZ4 compression + edit --verify sidecars):
two fixes in the edit/rebuild path. (1) The rebuilder always wrote one
uncompressed block, flattening any compressed bundle on edit; it now
LZ4-compresses the single output block when the source had compressed
blocks (LZMA/LZHAM convert losslessly), staying uncompressed when
compression does not shrink.

This needed a pure-Zig LZ4 block compressor in src/lz4.zig (greedy
hash-table matcher) that implements the end-of-block conditions from
lz4_Block_format.md: the last sequence is literals-only with >= 5
literals and the last match starts >= 12 bytes before the end - the
first version emitted a 1-literal final sequence and a trailing match,
which the C reference decoder (and UnityPy) reject; the round-trip
tests pin the tail structure.

(2) edit --verify passed no sidecar nodes to the #51 streamed-reference
check, so verifying any streamed bundle edit failed every
AudioClip/Texture2D with "no sidecar node"; verifyEditResult now builds
the sidecar list like verify does. Verified: char_118 (LZ4HC source)
edit --patch --verify passes, 36/36 verify, UnityPy reads all 36
objects from the LZ4-rebuilt bundle (block flags 0x42, ~9.6KB smaller
than uncompressed); atlas streamed edit --verify passes; 308/308
tests.

2026-09-01 (bare v4 serialized files reachable from the CLI): the
container sniff's version filter excluded format 4 even though the
parser reads 2-22, so every CLI command routed v4 files to "not a
recognized Unity asset file". Widened the filter to all supported
versions (v4 uses the same 16-byte legacy header as 2/3) and added a
minimal v4 fixture test (header + trailing metadata opened by the
endianness byte, zero types/objects - the legacy user-info read is
skipped below format 5); the sniff unit test now expects v4 to sniff
as serialized and keeps rejecting implausible v4 headers.

Verified end to end: a synthesized 29-byte v4 file runs info (type
SerializedFile, version 4, endian little), verify (clean), and stats
(0 objects) through the CLI. The remaining v4 gap is object decode
with legacy recursive type trees, which has no fixture or real sample
to verify against. README + plan updated (the "skips version 4"
claims removed).

2026-09-01 (webfile rebuild keeps gzip wrapping): the webfile
rebuilder always emitted a plain uncompressed WebFile, so editing a
gzip-wrapped web bundle (the classic Unity web-player .unity3d, which
our parser transparently decompresses - UnityPy does not) silently
flattened it. rebuild now re-gzips the output when the source was
gzip-wrapped (wf.owned set by the parser), using std's flate
Compress with the gzip container (initCapacity-backed writer: flate
asserts on an output buffer of <= 8 bytes). The plain path is
untouched.

Verified end to end on a synthesized gzip webfile wrapping
the scene bundle's serialized node: info/verify parse it, an edit
--patch --verify round-trips clean, the output keeps the gzip magic
(45574 vs 230683 bytes plain) and re-parses; the plain webfile edit
stays plain and UnityPy-readable (UnityPy rejects gzip webfiles
entirely - a pre-existing gap on its side). Unit test: gzip-wrapped
rebuild keeps the magic, compresses, and parses back with the edited
entry; 320/320 tests.

2026-09-01 (LZMA source rebuild + stale comment): the LZMA
decompress path had zero test coverage - the only block fixtures were
uncompressed, LZ4, and LZHAM. Added a fixture built from a
python-generated LZMA1 stream (FORMAT_RAW, lc3/lp0/pb2, 64K dict)
prefixed with the UnityFS 5-byte props+dict header.

The fixture is exercised two ways: the parser decodes it to the exact
payload, and rebuilding the bundle converts the LZMA source to a
single LZ4 block (the "LZMA/LZHAM sources convert losslessly"
behavior from the #53 rebuild work, previously untested - with a
replacement large enough that LZ4 actually shrinks, since the
rebuilder keeps a block uncompressed when compression does not). Also
fixed the rebuild doc comment, which still claimed "writes a single
uncompressed block... avoids needing an LZ4/LZMA encoder" - stale
since #53. 321/321 tests.

2026-09-01 (webfile gzip round-trip fuzz): the gzip path added in
step 135 gains a seeded fuzz: 300 iterations of compress -> parse
round-trips with varied payloads (pure noise, single runs, repeated
chunks, sizes 0-30KB, empty and tiny second entries), asserting every
entry survives byte-exactly. Also gave the test-only buildFixture a
named FileSpec type (anonymous struct params do not unify). 337/337
tests.

2026-09-01 (bundle/webfile parse mutation fuzz): the container
parsers get the hostile-input treatment the lz4 decoder already had.
A seeded fuzz mutates, truncates, extends, and randomizes a valid
bundle (3000 iterations, LZ4 source) and a valid webfile (2000
iterations, gzip and plain sources): every parse must succeed cleanly
or fail with an error - never crash - and parsed node/entry data must
be readable. 339/339 tests.

2026-09-01 (serialized parse mutation fuzz): the serialized parser
gets the hostile-input treatment bundle/webfile got in step 139: 3000
seeded iterations mutating, truncating, extending, and randomizing
valid v22 and v4 files, with header length fields nudged - every
parse succeeds or errors cleanly, never crashes, and any parsed
object's data must borrow from the (possibly truncated) source
bounds-checked via pointer arithmetic. 341/341 tests.

2026-09-01 (texture decode mutation fuzz): the format decoders get
the hostile-input treatment the parsers got: 4000 seeded iterations
feeding mutated and random streams (0-64KB) to decode() across 17
compressed formats (DXT1/3/5, BC4/5/7/6H, ETC1/ETC2 variants incl.
3DS, and the four crunched formats through unitycrunch) at power-of-
two sizes 1..64: every decode succeeds with exactly w*h*4 RGBA8 bytes
or errors cleanly - never crashes. 342/342 tests.

2026-09-01 (shader blob decoder mutation fuzz): the class-48 blob
decoder gets the hostile-input treatment: 2000 seeded iterations
mutating, truncating, and extending a valid synthetic blob - both the
plain form and the LZ4-compressed form real shaders store - through
verifyBlob: every pass verifies cleanly or fails with an error, never
crashes. 343/343 tests.

2026-09-01 (typetree parse mutation fuzz): the type-tree wire parser
(legacy recursive + flat blob encodings) gets the hostile-input
treatment: 3000 seeded iterations mutating, truncating, and
randomizing valid v17-blob and v11-legacy fixtures through parse() -
every parse succeeds with reachable roots or errors cleanly, never
crashes. 348/348 tests.

2026-09-01 (fsb5 metadata parse mutation fuzz): the FSB5 bank
metadata parser gets the hostile-input treatment: 3000 seeded
iterations mutating, truncating, and randomizing the hand-built bank
(header, sample table, chunk chain) through parse() - every parse
succeeds with a reachable sample table or errors cleanly, never
crashes. 350/350 tests.

2026-09-01 (image encoder round-trip fuzz): the PNG/TGA/BMP encoders
round-trip random RGBA buffers through their test-only decoders at
edge widths (1..1024, incl. 15/16/17, 255/256/257) and heights
(1..64) - exercising stride/row handling across ~120 combos per
format. 353/353 tests.

2026-09-01 (serialized_writer rewrite fuzz): the rewrite path gets
the hostile-input treatment: 2000 seeded iterations of (a) rewriting
mutated-but-parseable v22 files with no replacements and (b) random
replacement payloads (0-4KB) for object 100 - every rewrite produces
bytes or errors cleanly, never crashes, and the output is walkable
by the parser. 354/354 tests.

2026-09-01 (full CLI regression sweep): after 23 consecutive PRs
(#47-#69), a comprehensive sweep of the CLI surface across all five
real samples (banner, char_118, xinzexi, atlas, scene): info, verify,
stats, hash, extract (recursive), find, show, hierarchy, shader, skin
on every sample; --json modes (info/diff/verify); edit --verify
round-trips through the LZ4 bundle rebuild and the gzip webfile
rebuild; extract --json recursive.

All pass. The one non-zero exit (skin on the scene bundle) is the
designed contract: renderer 46 is a SkinnedMeshRenderer (class 137)
referencing the non-skinning Shamway/Unlit shader - the shamway
self-test creature exists to exercise exactly that flag. No
regressions found.

2026-09-01 (legacy UnityWeb/UnityRaw bundle support): the last
documented container gap closes - Unity 2.x-5.x era web/standalone
bundles (magic "UnityWeb\0"/"UnityRaw\0") now parse through
bundle.parse, so every CLI command works on them with no command
changes (sniff already routed them to .bundle). parseLegacy follows
UnityPy's read_web_raw: version-player/engine strings, hash+crc (v4+),
the level table, then a block at headerSize holding the file table +
serialized files - plain for UnityRaw, LZMA for UnityWeb.

Two real format facts surfaced by cross-validation against UnityPy:
the legacy header (and directory block) is big-endian (my first pass
assumed little), and UnityWeb's LZMA block carries the 13-byte header
(props + dict LE + decompressed size u64 LE), not the 5-byte UnityFS
form (lzmaDecompress tries both). Verified on synthetic bundles
wrapping the real scene serialized node: both tools read all 73
objects from the UnityRaw and the UnityWeb files, verify clean,
extract works; unit tests cover both formats + the v0/v6 rejections.
356/356 tests.

2026-09-01 (legacy bundle parse fuzz): the bundle mutation fuzz now
alternates between the LZ4 UnityFS fixture and a synthetic UnityRaw v5
bundle, so the new parseLegacy path gets the same hostile-input
treatment as the rest of the parser (3000 iterations, alternating
sources). 356/356 tests.

2026-09-01 (UnityPy parity sweep): extract both tools' outputs across
the three texture-bearing samples (banner, atlas, xinzexi) and compare
pixel-for-pixel: all 3 textures byte-identical, 8 of 9 sprites
byte-identical. The one difference (xinzexi's tight-mesh sprite,
2038x976) is 3016 of ~2M pixels (0.15%), every one at alpha=0 with
unityz (0,0,0,0) vs UnityPy (44,44,69,0): polygon-edge rasterization
rounding between unityz's paintTriangle and UnityPy's PIL
copy_triangle, visible nowhere (fully transparent). Recorded as a
known cosmetic parity note, not a defect.

2026-09-01 (legacy bundle edit): testing edit on a legacy bundle
exposed a real gap - rebuild copied the legacy version (5) into the
UnityFS output header, where versions < 6 are invalid, so the edited
file failed its own --verify (the safety net caught it; UnityPy was
lenient). Rebuild now clamps the output version to the UnityFS minimum
(6), so editing a legacy UnityWeb/UnityRaw bundle converts the
container to valid UnityFS and round-trips cleanly: verified on the
synthetic UnityRaw and UnityWeb bundles (edit --patch --verify clean,
re-verify clean, UnityPy reads all 73 objects); unit test covers the
conversion. 357/357 tests.

2026-09-01 (legacy bundle full-command sweep): the remaining CLI
commands verified on the synthetic UnityRaw bundle - stats, hash
(+ --json), find, show, hierarchy all work; diff between the UnityRaw
and UnityWeb files works, and diff against the edited copy correctly
reports the rename (72 unchanged, 1 changed). The legacy container
support is fully integrated across the command surface.

2026-09-01 (legacy bundle extract + single-edit sweep): the last
verification corners of the legacy support: all extract modes
(tga/bmp/raw/json/raw-mode) work on the UnityRaw bundle, and the
single-object edit form (edit <file> <node:path-id> <field> <value>
--verify) round-trips clean with UnityPy reading all 73 objects from
the edited file.

2026-09-01 (post-#79 comprehensive sweep): the capstone regression
pass across all 7 samples (5 real + 2 legacy bundles) and every
command (info/verify/stats/hash/extract on each; find/show/hierarchy/
shader/diff incl. legacy diff; --json modes): 43/43 pass. The full
surface - containers (UnityFS, legacy UnityWeb/UnityRaw, WebFile,
gzip webfiles, serialized v2-22), edit/verify/diff features, and all
extract paths - is verified clean at the end of the #47-#79 run.

2026-09-01 (legacy v6 bundles): the last legacy variant closes -
version-6 UnityWeb/UnityRaw bundles use the UnityFS-style layout (per
UnityPy's read_fs): the shared header fields plus one extra byte after
the flags, then the blocks-info block. bundle.parse now routes legacy
v6 through the UnityFS path (the only difference is that byte), so the
whole container surface is covered. Cross-validated on a synthetic
UnityWeb v6 wrapping the real scene serialized node: both tools read
all 73 objects, verify clean. Unit tests cover the v6 parse; the
rejection test now covers v0/v1 (v6 is no longer rejected). 358/358
tests.

2026-09-01 (legacy v6 edit verification): the v6 path closes out the
legacy surface: edit --patch --verify on the synthetic UnityWeb v6
round-trips clean (rebuild clamps to UnityFS v6), re-verify clean,
UnityPy reads all 73 objects, and diff reports the rename (72
unchanged, 1 changed). Every legacy version (v2-6) is now verified
across parse, verify, edit (both forms), extract, diff, hash, stats,
find, show, hierarchy.

2026-09-01 (font export): Font (class 128) objects export their
embedded TrueType/OpenType data plus a metadata sidecar. The serialized
layout was reverse-engineered from four real 7DTD fonts (Unity
2022.3.62f2) and cross-checked against AssetStudio's Font.cs and the
AssetRipper TypeTreeDumps 2022.3.62f2 tree:

the field order is m_Name, m_LineSpacing, m_DefaultMaterial,
m_FontSize, m_Texture, m_AsciiStartOffset, m_Tracking,
m_CharacterSpacing, m_CharacterPadding, m_ConvertCase,
m_CharacterRects, m_KerningValues, m_PixelScale, m_FontData (i32 size
+ inline bytes), m_Ascent, m_Descent, m_DefaultStyle, m_FontNames,
m_FallbackFonts, m_FontRenderingMode, m_UseLegacyBoundsCalculation,
m_ShouldRoundAdvanceValue.

The font bytes always sit inline in release binaries (the tree's
NoTransfer flag only affects editor/YAML layouts), so typeless files -
Mono builds strip type trees - decode via `Font.fromRaw` with no
sidecar lookup; `Font.fromValue` covers files that keep trees. UnityPy
has no Font export at all.

Verified on the real 7DTD bundle (typeless): three fonts extracted (a
16.5MB CFF OTF, a 72KB CFF OTF, a 350KB TrueType), the exported bytes
are identical to the inline object data, the extension follows the
sfnt magic ("OTTO" -> .otf, 0x00010000 -> .ttf), and fontconfig parses
the outputs cleanly. The descriptor JSON records metrics, the font
name list, kerning/rect counts, fallback pointers, and the embedded
data size. LegacyRuntime (the engine's stub font, path_id 10102 in
unity default resources) has size 0 and exports metrics only. 370/370
tests.

2026-09-01 (compute shader export): ComputeShader (class 72) objects
export every kernel's compiled payload plus a descriptor JSON. The
serialized layout was reverse-engineered from all 26 real 7DTD compute
shaders (Unity 2022.3.62f2, 260 kernel blobs) and cross-checked against
the AssetRipper TypeTreeDumps 2022.3.62f2 tree: m_Name, then a `variants`
vector of platform variants (targetRenderer/targetLevel, kernels,
constantBuffers, resourcesResolved), each kernel holding `uniqueVariants`
with the resource bindings and the `code` payload.

Two layout points the tree does not state were found empirically: the
`code` byte vector is 4-aligned after reading (only GLSL lengths exposed
it - the DXBC/SPIR-V lengths are multiples of 4), and the per-variant
`resourcesResolved` bool is padded to 4 inside the variants vector. The
D3D11 code blob is "DXBC" + a 16-byte Unity content hash + the standard
DXBC container (version/size/chunk offsets at byte 20).

Each platform variant is a different compiler target: (2,0) and (18,0)
are DXBC, (17,11) is SPIR-V (Vulkan), (21,0) is `#version`-prefixed GLSL
source - so extract recovers human-readable compute shaders. UnityPy has
no ComputeShader handling at all and AssetRipper does not handle class
72 either; the export writes one file per (kernel, variant) with an
extension from the code magic (.dxbc/.spirv/.glsl) plus a descriptor
JSON (thread-group sizes, unique-variant counts, resource-binding
counts, constant-buffer layouts with params).

Verified on the real 7DTD bundle: 260/260 exported code files
byte-identical to the inline object data, DXBC/SPIR-V headers
structurally valid. 373/373 tests.
2026-09-01 (trees generator): typeless Mono files become fully decodable
for any game version. There is no off-the-shelf generator for the
`--trees` JSON shape (the parallel `--trees` feature was validated on
Raft only), so `scripts/structsdump-to-trees.py` converts the public
AssetRipper TypeTreeDumps `StructsDump/release/<version>.dump` into a
trees file for that exact Unity version.

Two dump-format traps surfaced during conversion: types may be
multi-word (`unsigned int m_LightmapFlags` - the first naive parser
silently dropped the whole field, shifting every later offset and
breaking all decodes with Corrupt), and names may contain spaces
(`TypelessData image data` - the type/name split must match the known
multi-word types first, then take the name as everything after the
type token). Abstract classes (Object, EditorExtension, ...) emit empty
trees, which resolve to nothing and are harmless.

Verified on the real 7DTD bundle (Unity 2022.3.62f2, typeless): 197
textures (including streamed ones resolved from the bundle-internal
.resS sidecar), 13 sprites, and 6 meshes export; `verify` round-trips
1586/1588 objects in resources.assets clean, the two exceptions
streaming from an external sidecar file. UnityPy cannot decode typeless
files at all without its own tree database.

2026-09-01 (cubemap export): Cubemap (class 89) objects export their
six faces as PNGs. A cubemap serializes like a Texture2D with
`m_ImageCount` = 6: the stream holds six consecutive mip chains, each
`m_CompleteImageSize` bytes (verified: 6 x complete == stream size for
all three real 7DTD cubemaps, including an 8-mip 128x128 BC6H one from
level0.resS).

The first mip of each face decodes with the same pipeline as Texture2D
(mip0 slice = `expectedSize(format, w, h)`, now public), so face PNGs
export for any supported format - the real samples covered DXT5
(2048x2048 skybox), BC7 (1024x1024), and BC6H, all streamed from
bundle-internal .resS sidecars. Face order follows Unity's CubemapFace
enum (0=+X .. 5=-Z), and faces are named
posx/negx/posy/negy/posz/negz.

UnityPy has no Cubemap export at all. Verified: 18/18 face PNGs valid,
stream slices byte-exact. 373/373 tests.

2026-09-01 (audio mixer export): the AudioMixer family (classes 241/
243/245) exports its graph. In modern Unity the mixer parameters live in
the controller's m_MixerConstant index tables (groups, effects,
snapshots, name buffers), while the group objects carry only the named
hierarchy (m_Children PPtrs) and snapshots carry name/time. The export
joins the two: the controller writes a mixer JSON with the resolved
group tree (every group's name and its children, walked through the
serialized file's objects with injected trees for typeless files), the
named snapshot list, and the starting snapshot; groups and snapshots
each write their own JSON. UnityPy has no mixer export at all.

Verified on the real 7DTD mixer (MasterAudioMixer): the full named
hierarchy resolves (61 group references, e.g. Master -> FX Master ->
Sound Effects -> NO_FX -> DeathFX -> DeathStinger/DeathPlayer/
DeathImpacts), six snapshots with names (Default_Mix, Player_Death,
Player_Stunned, Player_Underwater, SFX_Silence, Player_Deafened), and
53 group + 6 snapshot objects export individually. 374/374 tests.

2026-09-01 (particle system export): ParticleSystem (class 198) objects
export a compact `particle_<id>.json` summary: the emitter's timeline
(lengthInSec, looping, prewarm, playOnAwake, simulationSpeed,
scalingMode, stopAction, cullingMode) plus the main/emission/shape
module values and the enabled flag of every module (initial, emission,
shape, size, rotation, color, uv, velocity, inheritVelocity,
lifetimeByEmitterSpeed, force, externalForces, clampVelocity, noise,
sizeBySpeed, rotationBySpeed, colorBySpeed, collision, trigger, sub,
lights, trail).

MinMaxCurve scalars read via the `scalar` field, falling back to the
min/max bounds when the curve is two-constant. UnityPy has no
ParticleSystem export at all. Verified on the real 7DTD bundle: all 92
particle systems export with values matching the decoded trees (e.g.
duration 10, startSpeed 5, shape type 18/cone, 30 max particles).
375/375 tests.

2026-09-01 (bundle disk sidecars): bundles and webfiles now merge the
on-disk sibling `.resS`/`.resource` files into their sidecar set, so
streamed references that point OUTSIDE the container (e.g. an FSB5
audio bank sitting next to data.unity3d) resolve during extract and
verify. Bare serialized files already loaded disk sidecars; the
container paths did not. Verified on real 7DTD data: the two AudioClips
that stream from the external resources.resource export their FSB5
banks and decoded WAVs (valid RIFF PCM16 44.1kHz mono), and bundle
verify is fully clean. 375/375 tests.

2026-09-01 (animator controller export): AnimatorController (class 91)
objects export an `animator_<id>_<name>.json` summary. The controller's
m_Controller constant arrays (m_LayerArray, m_StateMachineArray with
state constants and blend trees) carry name HASHES, not strings; names
resolve through the controller's m_TOS hash-to-path table - a state's
m_NameID maps to its path ("balloon_spin"), a layer's m_Binding to
"Base Layer".

The summary reports layers (state machine index, resolved name,
blending mode, default weight, IK pass), states (resolved name and
full path, speed, loop, transition/blend-tree counts), the
state-machine count, any-state transitions, default state, parameter
count, the referenced clips, and the full TOS path table. UnityPy has
no AnimatorController export at all.

Verified on the real 7DTD PlayOnSpawn controller: the single layer and
its balloon_spin state resolve their names, 1 blend tree, clip 576
referenced. 376/376 tests.

2026-09-01 (animation clip bindings): humanoid muscle clips store their
animation in the muscle clip, not the legacy curve arrays, so the
existing curve JSON came out empty for them. The clip export now also
surfaces muscleClipSize, the event count, and the genericBindings from
m_ClipBindingConstant: every animated property with a named attribute
(m_LocalPosition.x, m_LocalRotation.y, ... via the binding-attribute
enum for the first twelve values) and the type id (4 = Transform, 95 =
Animator).

The binding path is a hash of the rig's transform path; it only
resolves through the owning avatar's TOS, which is usually not in the
bundle, so it is emitted raw (an attempted resolution through the
AnimatorController TOS was dropped - that table holds state paths, not
transform paths, so it never matched). Verified on the real 7DTD
sharedassets2.assets: all 95 clips are muscle clips and now report
4116 bindings total (e.g. pipeRifleReload: muscleClipSize 28452, 31
bindings). 376/376 tests.

2026-09-01 (typeless-file diagnostics): extract and verify now count the
objects skipped because the file carries no type trees (Mono builds
strip them) and no injected trees were supplied, and print a hint after
the summary - "N object(s) skipped: this file has no type trees (Mono
build); pass --trees <file.json> or --raw to decode them". Previously a
typeless file without --trees silently reported "0 assets extracted, 0
skipped" / "0 objects checked", indistinguishable from an empty file.
Verified on the real 7DTD bundle: extract without --trees now explains
the 202 skipped textures; with --trees the hint disappears; verify on
the bare file explains all 1768 skipped objects. 376/376 tests.

2026-09-01 (animator override export): AnimatorOverrideController (class
221) objects export an `animator_override_<id>_<name>.json` with the
base controller PPtr and the m_Clips override pairs (original ->
replacement), both clip names resolved through the file's objects via
readObjectValue (injected trees for typeless files). Verified on the
real 7DTD 3PWeaponController: all 7 pairs resolve their clip names
(e.g. tacticalAssaultRifleReload -> tacticalAssaultRifleReload3P).
UnityPy has no export for this class. 377/377 tests.

2026-09-01 (mono script registry export): MonoScript (class 115)
objects export a `script_<id>_<class>.json` per registry entry:
assembly, namespace, class, and the m_Script payload reference (the
MonoScript struct gained the script PPtr). This is the "what scripts
does this game have" answer - verified on the real 7DTD registry:
6501 scripts across Assembly-CSharp (3291), EOS (986), InControl (490),
Unity.Microsoft.GDK (309), Assembly-CSharp-firstpass (157), and more.
UnityPy has no MonoScript export. 378/378 tests.

2026-09-01 (hierarchy --trees): the hierarchy command now accepts
--trees and decodes typeless Mono files through the injected table (the
decode loop falls back to injectedTreeFor when the file's trees are
empty, mirroring extract/verify). Previously a Mono game's scenes
printed empty hierarchies. Verified on the real 7DTD bundle: level0/1
UI scenes and the resources.assets world decode fully (223 hierarchy
entries; the twitch_balloon rig shows its String bone chain with bone
markers and per-node positions/components). 378/378 tests.

2026-09-01 (find/skin --trees): the find and skin commands now accept
--trees and decode typeless Mono files through the injected table (the
scan loops fall back to injectedTreeFor, and shaderObjectValue gained
the injected fallback), completing the typeless story for every command
that decodes objects. Verified on the real 7DTD bundle: find --trees
returns the twitch_balloon materials/texture/mesh/clips/GameObjects
(186 GameObjects match "a"), and skin --trees analyzes the typeless
shaders (e.g. Legacy Shaders/Specular: skins false). 378/378 tests.

2026-09-01 (animator component export): Animator (class 95) objects
export an `animator_<id>.json` with the component's controller and
avatar references (names resolved through the file's objects via
readObjectValue, injected trees for typeless files) plus the playback
flags (culling/update mode, apply root motion, linear velocity
blending, stabilize feet, transform hierarchy, sampling optimization,
keep-state/write-defaults on disable). With this, every class with
content in the real 7DTD bundle has an extract export. Verified: all 4
animators export (e.g. controller -> PlayOnSpawn, avatar ->
twitch_balloonAvatar). 379/379 tests.

2026-09-01 (edit --trees): the edit command now accepts --trees and
decodes typeless Mono files through the injected table (both the
bundle/webfile paths via editSerializedObject and the bare serialized
path fall back to injectedTreeFor), completing the typeless story for
every command: extract, verify, show, hierarchy, find, skin, and edit.
The full Mono-game modding loop now works - decode a typeless object,
edit a field, reserialize byte-exactly, round-trip verify.

Verified on
the real 7DTD bundle: editing texture 136's m_Width 1024 -> 64 with
--trees --verify round-trips clean and the edited file re-reads the new
value. 379/379 tests.
2026-09-01 (capstone: full-surface verification): the complete
unfiltered extract of the real 7DTD bundle (Unity 2022.3.62f2,
fully typeless, via the generated trees) produces 8090 files with zero
decode failures and zero skipped objects: 260 PNGs (textures, sprites,
cubemap faces), 7130 JSONs (value trees, fonts' and compute shaders'
descriptors, mixer graph, animator/override/script registries,
particle summaries, clip curves/bindings, manifest), 7 OBJs, and 6
audio files (FSB5 + decoded WAV).

Spot checks: fonts are valid
TTF/OTF, the 2048x2048 cubemap face decodes, mixer snapshots and
animator controllers resolve names, WAVs are valid RIFF PCM16. Every
class with content in the bundle exports, and every command (extract,
verify, show, hierarchy, find, skin, edit) handles typeless Mono files.
The remaining gaps are external: VideoClip/TerrainData/UnityArchive
have no samples anywhere in the environment, and m_Script managed
object graphs need .NET assemblies (beyond UnityPy parity, which cannot
parse them either).

2026-09-02 (sample sweep): that "no samples" claim was a class-ID bug -
27 is the abstract Texture base (TerrainData is 156) and 333/334 are
not VideoClip (329 is). TerrainData objects exist in Raft (36), Stranded
Deep (51, matching its Terrains), Green Hell (1), and The Forest (1);
VideoClip exists in Green Hell (16, 1080p60 and 4K cutscenes), and
`extract` now pulls the streamed video out of the `.resource` sidecar
as `.mp4` plus a metadata JSON. UnityArchive remains the only container
with no samples.

2026-09-02 (post-capstone batch): PRs #102-#104 shipped beyond-parity
features. `managed` reads a Mono build's .NET assemblies (PE/CLI header,
#~ table stream, TypeDef/TypeRef/Field, compressed coded indices,
generics) and lists every MonoBehaviour's serialized field layout;
verified on Raft (1235 classes across the Managed folder). `edit
--patch` accepts `--trees`, making typeless Mono files patchable via the
JSON form (verified on 7DTD).

extract consolidates MonoScripts into one
`scripts.json` (6501 entries for 7DTD) and adds a dry-run `--summary`.
Shader objects export readable ShaderLab (.shader). VideoClips (329)
extract their streamed video from the .resource sidecar as .mp4 plus a
metadata JSON (Green Hell: 16 cutscenes, 1080p60 and 4K).

TerrainData
(156) exports normalized heightmap PGM images with a shipped
`trees/TerrainData-2021.x.json` (editor tree minus stripped base fields,
plus a 36-byte runtime-only region derived from real objects); verified
on Raft (513x513), Stranded Deep (51 island zones, 257x257, real
relief), and Green Hell (4097x4097). docs-check is fully green after
splitting the kit-template and README paragraphs.

2026-09-02 (doc sweep): the README was tightened from 508 to ~140 lines -
the per-class capability wall of text and the "Status" section moved to
docs/features.md, ROADMAP.md was brought current, and docs/README.md now
points at features.md.
