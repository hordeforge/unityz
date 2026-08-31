# Roadmap

This is the short navigation view, not a second specification. Link each item
to its PRD or ADR; keep detailed design and acceptance criteria in those files.

## Current

Nothing in flight.

## Planned

- Texture block formats still missing: PVRTC, ATC, EAC, and the
  ETC-RGB4/RGBA8-3DS variants. UnityPy decodes these; no real asset with
  them has been located to verify against, so they are documented as
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
- Sprite export covers packed sprites: separate alpha textures merge in
  (RGB from the main texture, alpha from the alpha texture's R channel),
  packing rotation is applied, and tight/polygon sprites render through
  their mesh (polygon mask or UV texture-map), matching UnityPy.
