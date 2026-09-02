# Roadmap

This is the short navigation view, not a second specification. Link each item
to its PRD or ADR; keep detailed design and acceptance criteria in those files.

## Current

- `managed --trees`: auto-build MonoBehaviour type trees from a game's
  .NET assemblies so typeless MonoBehaviours decode without hand-made
  trees files.
- `stats --trees`: let per-class stats decode typeless Mono files.
- Mesh export as glTF/GLB alongside OBJ.

## Planned

- UnityArchive container parsing. The format is detected but not parsed;
  no real sample exists anywhere in the available games (verified by a
  full-library scan), so it needs an old Unity 4 game or a crafted
  fixture.
- PVRTC verification against real assets. Decoding exists; all available
  games are PC/console builds without PVRTC textures, so the path is
  verified only against synthetic inputs.

## Done

- Post-capstone batch (PRs #102-#104): `managed` reads a Mono build's
  assemblies and lists every MonoBehaviour's serialized field layout
  (no external CLR); `edit --patch` accepts `--trees`; extract writes
  one consolidated `scripts.json` and a dry-run `--summary`; Shader
  objects export readable ShaderLab; VideoClips export their streamed
  video as MP4 (Green Hell cutscenes); TerrainData exports normalized
  heightmap PGM images (Raft, Stranded Deep, Green Hell) with a shipped
  2021.x tree. The earlier "sample-blocked" verdicts for VideoClip and
  TerrainData were class-ID bugs (329 and 156, not 333/334 and 27) and
  were resolved by the sample sweep.
- Beyond-parity CLI work: `diff --pixels`/`--audio`/`--fields` compare
  matched objects' decoded pixels, audio streams, and exact field paths;
  `extract` gains TGA/BMP/raw RGBA output, `--name` filtering, and
  structured JSON exports; FSB5 audio decodes to WAV in pure Zig and
  Vorbis banks remux to a playable Ogg; `find --any`, `info --objects`,
  and a `hierarchy` command.
- Multi-stream mesh export: Meshes whose vertex channels spread over
  `m_Streams_0_..3_` export an OBJ instead of silently nothing.
- Serialized format 4 parses and rewrites byte-exactly.
- The 3DS ETC variants (60/61) decode as ETC1 and ETC2_RGBA1 (46)
  decodes its punch-through alpha, pixel-identical to UnityPy.
- Crunch DXT variants decode through the vendored unitycrunch machinery.
- Shader sub-program blobs fully decode: record tables, parameter blobs,
  code blobs with DXBC chunk sets, ISGN/RDEF, bind channels, and
  skinning detection.
- Sprite export covers packed sprites: alpha merges, packing rotation,
  tight/polygon rendering through the sprite mesh, matching UnityPy.
- Clean-room UnityPy rewrite in Zig - format parsers, object reader,
  reserialize/edit, and extraction. See
  [the plan](plans/2026-08-30-clean-room-unitypy-rewrite-format-parsers.md),
  which is marked Complete with per-pass completion notes.
