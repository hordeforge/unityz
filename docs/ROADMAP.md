# Roadmap

This is the short navigation view, not a second specification. Link each item
to its PRD or ADR; keep detailed design and acceptance criteria in those files.

## Current

Nothing in flight.

## Planned

Nothing open that blocks use. Remaining items need external samples or
tools not available here (see the plan's completion notes).

## Done

- Beyond-parity CLI work: `diff --pixels`/`--audio`/`--fields` compare
  matched objects' decoded pixels, audio streams, and exact field paths
  (text and `--json`); `extract` gains TGA/BMP/raw RGBA output formats,
  `--name` filtering, SpriteAtlas/AssetBundle/AnimationClip/Material/
  Shader structured JSON exports; FSB5 audio decodes to WAV in pure Zig
  (PCM8/16/24/32/FLOAT, GCADPCM, IMA ADPCM); `find --any` searches every
  string field; `info --objects` shows names; a `hierarchy` command
  prints the GameObject/Transform tree with bones marked.
- Multi-stream mesh export: a Mesh whose vertex channels spread over
  `m_Streams_0_..3_` exports an OBJ instead of silently nothing; the
  per-stream stride/offset is derived as UnityPy's MeshHandler does, and
  single-stream output stays byte-identical.
- Serialized format 4 parses and rewrites byte-exactly (Unity 4.x
  metadata/object-info layout, legacy aligned type-tree strings), which
  also fixed two legacy16 rewrite bugs. `container.sniff` still filters
  v4 out, so a bare v4 file is not yet reachable from the CLI.
- The remaining block-format parity gap closes: the 3DS ETC variants
  (ETC_RGB4_3DS 60, ETC_RGBA8_3DS 61) decode as ETC1 (matching UnityPy,
  which routes both to its ETC1 decoder) and ETC2_RGBA1 (46) decodes its
  punch-through alpha, validated pixel-identical to UnityPy's
  texture2ddecoder over a 96-block corpus.
- Managed-reference registries decode through their type trees,
  MonoBehaviours export the decoded managed .NET object graph as a
  `.json` sidecar (resolves the earlier m_Script limitation; UnityPy
  needs external .NET assemblies for the raw graph).
- Clean-room UnityPy rewrite in Zig - format parsers, object reader,
  reserialize/edit, and extraction. See
  [the plan](plans/2026-08-30-clean-room-unitypy-rewrite-format-parsers.md),
  which is marked Complete with per-pass completion notes.
- Crunch DXT variants decode: DXT1Crunched (28) and DXT5Crunched (29)
  route through the same vendored unitycrunch machinery as the ETC crunch
  formats, worth fixing a latent 565→888 truncation so the whole DXT
  family matches UnityPy byte-exact.
- Shader sub-program blobs parse: the per-platform LZ4 blob decodes to its
  parameter and code records, and a shader's vertex stage is reported as
  skinning or not (`info --json`, plus a `skin` command that exits non-zero
  when a SkinnedMeshRenderer references a shader that does not skin).
- Shader sub-program blobs fully decode: each record is listed under
  `show`/`shader <path> <node:path-id>` with its parameter blob (constant
  buffers and member offsets, texture/cbuffer/UAV/sampler entries) or code
  blob (38-byte program-data header, DXBC chunk set, ISGN input signature,
  RDEF member offsets, ParserBindChannels (source,target) pairs), and
  `verify` round-trips the parameter blobs byte for byte. Validated against
  the game bundle and the pipeline-synthesized shader bundle, reproducing
  the Game/SDCS/Skin d3d11 vertex bind tables.
- Sprite export covers packed sprites: separate alpha textures merge in
  (RGB from the main texture, alpha from the alpha texture's R channel),
  packing rotation is applied, and tight/polygon sprites render through
  their mesh (polygon mask or UV texture-map), matching UnityPy.
