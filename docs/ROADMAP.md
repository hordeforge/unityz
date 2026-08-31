# Roadmap

This is the short navigation view, not a second specification. Link each item
to its PRD or ADR; keep detailed design and acceptance criteria in those files.

## Current

Nothing in flight.

## Planned

- Texture block formats still missing: BC6H (HDR), PVRTC, ATC, EAC,
  ETC-RGB4/RGBA8-3DS, and the DXT1/5Crunched crunch variants (28/29).
  UnityPy decodes all of these; no real asset with them has been located
  to verify against (the DXT-crunched ones need the same vendored
  crunch machinery as formats 64/65), so they are documented as
  unsupported rather than half-tested.
- Parsing the managed .NET object graph inside `m_Script` payloads. Shared
  with UnityPy itself (it needs external .NET assemblies); unityz exposes
  the raw payload, which is at/beyond parity.

## Done

- Clean-room UnityPy rewrite in Zig - format parsers, object reader,
  reserialize/edit, and extraction. See
  [the plan](plans/2026-08-30-clean-room-unitypy-rewrite-format-parsers.md),
  which is marked Complete with per-pass completion notes.
