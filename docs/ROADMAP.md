# Roadmap

This is the short navigation view, not a second specification. Link each item
to its PRD or ADR; keep detailed design and acceptance criteria in those files.

## Current

Nothing in flight.

## Planned

- Texture block formats still missing: the ETC-RGB4/RGBA8-3DS variants.
  UnityPy decodes these; no real asset with them has been located to
  verify against, so they are documented as
  unsupported rather than half-tested.
- Parsing the managed .NET object graph inside `m_Script` payloads. Shared
  with UnityPy itself (it needs external .NET assemblies); unityz exposes
  the raw payload, which is at/beyond parity.

## Done

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
